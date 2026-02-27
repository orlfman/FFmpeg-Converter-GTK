using Gtk;
using GLib;
using Posix;

internal enum ConversionPhase {
    IDLE,
    PASS1,
    PASS2
}

public class Converter : Object {
    // Emitted on the main thread after a successful conversion
    public signal void conversion_done (string output_file);

    private bool is_converting = false;
    private Pid? current_pid = null;
    private Label status_label;
    private ProgressBar progress_bar;
    private double total_duration = 0.0;
    private ConsoleTab console_tab;

    public GeneralTab general_tab;
    public SvtAv1Tab svt_tab;
    public string? passlog_base = null;
    public Object codec_tab;
    public ICodecBuilder codec_builder;
    public string last_output_file = "";
    
    private ConversionPhase current_phase = ConversionPhase.IDLE;
    
    private bool use_pulse_mode = false;
    private uint pulse_source = 0;

    public void start_conversion (string input_file,
                                  string output_folder,
                                  Object codec_tab,
                                  ICodecBuilder builder,
                                  GeneralTab general_tab,
                                  Label status_label,
                                  ProgressBar progress_bar,
                                  ConsoleTab console_tab) {
        this.status_label = status_label;
        this.progress_bar = progress_bar;
        this.console_tab = console_tab;
        this.general_tab = general_tab;
        this.codec_tab = codec_tab;
        this.codec_builder = builder;

        if (is_converting) {
            status_label.set_text ("⚠️ A conversion is already running!");
            return;
        }
        if (input_file == "") {
            status_label.set_text ("⚠️ Please select an input file first!");
            return;
        }

        string out_folder = output_folder != "" ? output_folder : Path.get_dirname (input_file);

        bool two_pass = false;
        if (codec_tab is SvtAv1Tab) {
            two_pass = ((SvtAv1Tab) codec_tab).two_pass_check.get_active();
        } else if (codec_tab is X265Tab) {
            two_pass = ((X265Tab) codec_tab).two_pass_check.get_active();
        }

	string codec_name = builder.get_codec_name ().down ();
        string codec_suffix = (codec_name.contains ("av1")) ? "av1" : codec_name;
        string container_ext = "mkv";
	if (codec_tab is SvtAv1Tab) {
            container_ext = ((SvtAv1Tab) codec_tab).get_container ();
        } else if (codec_tab is X265Tab) {
            container_ext = ((X265Tab) codec_tab).get_container ();
        }
        string basename = Path.get_basename (input_file);
        int dot_pos = basename.last_index_of_char ('.');
        string name_no_ext = (dot_pos > 0) ? basename.substring (0, dot_pos) : basename;
        string output_file = @"$out_folder/$name_no_ext-$codec_suffix.$container_ext";

        status_label.set_text (@"🚀 Starting conversion...\nOutput will be:\n$output_file");

        this.last_output_file = output_file;

        total_duration = get_video_duration (input_file);
        if (total_duration <= 0) {
            use_pulse_mode = true;
        } else {
            use_pulse_mode = false;
        }

        is_converting = true;
        current_pid = null;
        show_progress ();

        new Thread<void> ("ffmpeg-thread", () => {
            run_conversion (input_file, output_file, two_pass);
        });
    }

    private void run_conversion (string input, string output, bool two_pass) {
        var runner = new ConversionRunner (this, codec_builder);
        runner.run (input, output, two_pass);
    }
    
    private inline bool wif_exited (int status) {
        return (status & 0x7f) == 0;
    }

    private inline int wexit_status (int status) {
        return (status >> 8) & 0xff;
    }

    internal int execute_ffmpeg (string[] argv, bool is_pass1 = false) {
        try {
            var launcher = new SubprocessLauncher (SubprocessFlags.STDERR_PIPE);
            var process = launcher.spawnv (argv);
            current_pid = (Pid) int.parse (process.get_identifier () ?? "0");

            var reader = new DataInputStream (process.get_stderr_pipe ());

            double pass_start = is_pass1 ? 0.0 : 50.0;
            double pass_range = 50.0;

            string line;
            while ((line = reader.read_line (null)) != null) {
                string clean = line.strip ();
                if (clean.length == 0) continue;

                bool is_noisy = clean.has_prefix("frame=") || clean.has_prefix("fps=") ||
                               clean.has_prefix("stream_") || clean.has_prefix("bitrate=") ||
                               clean.has_prefix("total_size=") || clean.has_prefix("out_time") ||
                               clean.has_prefix("dup_frames=") || clean.has_prefix("drop_frames=") ||
                               clean.has_prefix("speed=") || clean.has_prefix("progress=");

                if (!is_noisy || clean.contains("Lsize=") || clean.contains("Error") ||
                    clean.contains("Warning") || clean.contains("failed")) {
                    console_tab.add_line (clean);
                }

                double current_sec = -1.0;

                if (clean.contains ("out_time_us=")) {
                    string[] parts = clean.split ("out_time_us=");
                    if (parts.length >= 2) {
                        string us_str = parts[1].split (" ")[0].strip();
                        int64 us = int64.parse (us_str);
                        current_sec = us / 1000000.0;
                    }
                }
                else if (clean.contains ("time=") || clean.contains ("out_time=")) {
                    string key = clean.contains ("out_time=") ? "out_time=" : "time=";
                    string time_str = clean.split (key)[1].split (" ")[0].strip();
                    current_sec = parse_ffmpeg_timestamp (time_str);
                }

                // Update progress bar
                if (current_sec >= 0 && total_duration > 0.0) {
                    double fraction = (current_sec / total_duration).clamp (0.0, 1.0);
                    double percent = pass_start + (fraction * pass_range);
                    update_progress (percent);
                }
            }

            process.wait ();
            int exit_status = process.get_exit_status ();

            print ("\n=== FFmpeg command ===\n%s\n", string.joinv (" ", argv));
            console_tab.set_command (string.joinv (" ", argv));

            return exit_status;

        } catch (Error e) {
            print ("Failed to launch FFmpeg: %s\n", e.message);
            console_tab.add_line ("❌ FFmpeg launch error: " + e.message);
            return -1;
        }
    }

    public void cancel () {
        if (!is_converting || current_pid == null) return;

        string cancel_msg = "⏹️ Cancelling conversion...";
        if (current_phase == ConversionPhase.PASS1) {
            cancel_msg = "⏹️ Cancelling Pass 1 (analysis)...";
        } else if (current_phase == ConversionPhase.PASS2) {
            cancel_msg = "⏹️ Cancelling Pass 2 (encoding)...";
        }

        update_status (cancel_msg);
        hide_progress_cancelled ();
        stop_pulsing ();

        try {
            Posix.kill (current_pid, Posix.Signal.TERM);
            print ("Sent SIGTERM to FFmpeg (PID %d) during %s\n", current_pid, current_phase.to_string ());
        } catch (Error e) {
            print ("Failed to send cancel signal: %s\n", e.message);
        }

        cleanup_passlog ();

        is_converting = false;
        current_pid = null;
        current_phase = ConversionPhase.IDLE;
    }

    internal void report_error (string message) {
        Idle.add (() => {
            status_label.set_text (@"❌ $message\nCheck the console for details.");
            console_tab.add_line ("❌ " + message);
            return Source.REMOVE;
        });
    }
    
    private void show_progress () {
        Idle.add (() => {
            progress_bar.set_visible (true);
            if (use_pulse_mode) {
                progress_bar.set_text ("Processing...");
                start_pulsing ();
            } else {
                progress_bar.set_fraction (0.0);
                progress_bar.set_text ("0.0%");
            }
            return Source.REMOVE;
        });
    }

    private void hide_progress () {
        Idle.add (() => {
            stop_pulsing ();
            progress_bar.set_fraction (1.0);
            progress_bar.set_text (use_pulse_mode ? "Done" : "100%");

            Timeout.add (800, () => {
                progress_bar.set_visible (false);
                progress_bar.set_text ("Waiting...");
                return Source.REMOVE;
            });
            return Source.REMOVE;
        });
    }

    private void hide_progress_cancelled () {
        Idle.add (() => {
            stop_pulsing ();
            progress_bar.set_visible (false);
            progress_bar.set_text ("Cancelled");
            return Source.REMOVE;
        });
    }
    
    private double get_video_duration (string input_file) {
        try {
            string[] cmd = { "ffprobe", "-v", "quiet", "-print_format", "csv=p=0", "-show_entries", "format=duration", input_file };
            string stdout, stderr;
            int status;

            Process.spawn_sync (null, cmd, null, SpawnFlags.SEARCH_PATH, null, out stdout, out stderr, out status);

            if (status == 0) {
                double dur = double.parse (stdout.strip ());
                if (dur > 0) return dur;
            }
        } catch (Error e) {
            print ("ffprobe error: %s\n", e.message);
        }
        return 0.0;
    }
    
    private void update_progress (double percent) {
        Idle.add (() => {
            progress_bar.set_fraction (percent / 100.0);
            progress_bar.set_text (@"%.1f%%".printf (percent));
            return Source.REMOVE;
        });
    }

    private double parse_ffmpeg_timestamp (string time_str) {
        if (time_str == "N/A" || time_str.length == 0) {
            return -1.0;
        }
        string[] parts = time_str.split (":");
        if (parts.length < 3) return -1.0;

        int hours   = int.parse (parts[0]);
        int minutes = int.parse (parts[1]);
        double seconds = double.parse (parts[2]);

        return hours * 3600.0 + minutes * 60.0 + seconds;
    }
    
    private void cleanup_passlog () {
        if (passlog_base == null) return;

        try {
            var log1 = File.new_for_path (passlog_base + "-0.log");
            var log2 = File.new_for_path (passlog_base + "-0.log.mbtree");

            if (log1.query_exists ()) log1.delete ();
            if (log2.query_exists ()) log2.delete ();
        } catch (Error e) {
            print ("Warning: Could not delete passlog files: %s\n", e.message);
        }

        passlog_base = null;
    }
    
    internal void update_status (string message) {
        Idle.add (() => {
            status_label.set_text (message);
            console_tab.add_line (message);
            return Source.REMOVE;
        });
    }
    
    private void start_pulsing () {
        stop_pulsing ();
        pulse_source = Timeout.add (320, () => {
            Idle.add (() => {
                progress_bar.pulse ();
                return Source.REMOVE;
            });
            return Source.CONTINUE;
        });
    }

    private void stop_pulsing () {
        if (pulse_source != 0) {
            Source.remove (pulse_source);
            pulse_source = 0;
        }
    }
    
    internal void set_phase (ConversionPhase phase) {
        current_phase = phase;
    }
    
    internal string sanitize_filename (string path) {
        string dir = Path.get_dirname (path);
        string name = Path.get_basename (path);

        string safe = name
            .replace ("：", ":")
            .replace ("？", "?")
            .replace ("*", "_")
            .replace ("\"", "_")
            .replace ("<", "_")
            .replace (">", "_")
            .replace ("|", "_")
            .replace ("/", "_")
            .replace ("\\", "_")
            .replace (":", "_");

        safe = safe.strip ().replace (". ", ".").replace (" .", ".");

        return Path.build_filename (dir, safe);
    }
    
    public void cleanup_after_conversion () {
        is_converting = false;
        current_pid = null;
        current_phase = ConversionPhase.IDLE;
        stop_pulsing ();
        hide_progress ();
        cleanup_passlog ();
    }
}
