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

    // ── Stable dependencies ────────────
    private Label status_label;
    private ProgressBar progress_bar;
    private ConsoleTab console_tab;

    public GeneralTab general_tab { get; private set; }

    // ── Per-conversion state ────────────────────────────────────────────────
    public ICodecTab codec_tab;
    public ICodecBuilder codec_builder;
    public string? passlog_base = null;
    public string last_output_file = "";

    // ── Thread-safe shared state ───────────────────────────────────────
    private Mutex state_mutex = Mutex ();
    private bool is_converting = false;
    private Pid current_pid = 0;
    private ConversionPhase current_phase = ConversionPhase.IDLE;
    private bool cancelled = false;

    // ── Duration / progress ─────────────────────────────────────────────────
    private double total_duration = 0.0;
    private bool use_pulse_mode = false;
    private uint pulse_source = 0;
    private int64 last_progress_update = 0;

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public Converter (Label status_label,
                      ProgressBar progress_bar,
                      ConsoleTab console_tab,
                      GeneralTab general_tab) {
        this.status_label = status_label;
        this.progress_bar = progress_bar;
        this.console_tab  = console_tab;
        this.general_tab  = general_tab;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  OUTPUT PATH COMPUTATION (extracted for overwrite check in main.vala) (#5)
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Compute the output file path for a given input file, codec, and folder.
     * Does NOT start conversion — call start_conversion() afterwards.
     */
    public static string compute_output_path (string input_file,
                                              string output_folder,
                                              ICodecBuilder builder,
                                              ICodecTab codec_tab) {
        string out_folder = (output_folder != "")
            ? output_folder
            : Path.get_dirname (input_file);

        string codec_name = builder.get_codec_name ().down ();
        string codec_suffix = codec_name.contains ("av1") ? "av1" : codec_name;

        string container_ext = codec_tab.get_container ();
        if (container_ext == "") container_ext = "mkv";

        string basename = Path.get_basename (input_file);
        int dot_pos = basename.last_index_of_char ('.');
        string name_no_ext = (dot_pos > 0) ? basename.substring (0, dot_pos) : basename;

        return @"$out_folder/$name_no_ext-$codec_suffix.$container_ext";
    }

    /**
     * Given a path, find a non-conflicting variant by appending -1, -2, etc.
     */
    public static string find_unique_path (string path) {
        if (!FileUtils.test (path, FileTest.EXISTS))
            return path;

        string dir = Path.get_dirname (path);
        string basename = Path.get_basename (path);

        int dot_pos = basename.last_index_of_char ('.');
        string stem = (dot_pos > 0) ? basename.substring (0, dot_pos) : basename;
        string ext  = (dot_pos > 0) ? basename.substring (dot_pos) : "";

        int counter = 1;
        string candidate = path;
        do {
            candidate = Path.build_filename (dir, @"$stem-$counter$ext");
            counter++;
        } while (FileUtils.test (candidate, FileTest.EXISTS));

        return candidate;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  START CONVERSION
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Begin encoding.  The output_file should already be resolved
     * (including any overwrite / rename decision made in the UI).
     */
    public void start_conversion (string input_file,
                                  string output_file,
                                  ICodecTab codec_tab,
                                  ICodecBuilder builder) {
        state_mutex.lock ();
        if (is_converting) {
            state_mutex.unlock ();
            status_label.set_text ("⚠️ A conversion is already running!");
            return;
        }
        state_mutex.unlock ();

        if (input_file == "") {
            status_label.set_text ("⚠️ Please select an input file first!");
            return;
        }

        this.codec_tab    = codec_tab;
        this.codec_builder = builder;
        this.last_output_file = output_file;

        status_label.set_text (@"🚀 Starting conversion...\nOutput will be:\n$output_file");

        bool two_pass = codec_tab.get_two_pass ();

        state_mutex.lock ();
        is_converting = true;
        current_pid   = 0;
        cancelled     = false;
        state_mutex.unlock ();

        show_progress_pulse ();

        new Thread<void> ("ffmpeg-thread", () => {
            // (#10) Move ffprobe to the background thread so it doesn't freeze UI
            total_duration = get_video_duration (input_file);
            use_pulse_mode = (total_duration <= 0);

            if (!use_pulse_mode) {
                // Switch from pulse to determinate mode
                Idle.add (() => {
                    stop_pulsing ();
                    progress_bar.set_fraction (0.0);
                    progress_bar.set_text ("0.0%");
                    return Source.REMOVE;
                });
            }

            run_conversion (input_file, output_file, two_pass);
        });
    }

    private void run_conversion (string input, string output, bool two_pass) {
        var runner = new ConversionRunner (this, codec_builder);
        runner.run (input, output, two_pass);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  FFMPEG PROCESS EXECUTION
    // ═════════════════════════════════════════════════════════════════════════

    internal int execute_ffmpeg (string[] argv, bool is_pass1 = false) {
        try {
            var launcher = new SubprocessLauncher (SubprocessFlags.STDERR_PIPE);
            var process = launcher.spawnv (argv);

            // (#2) Safe PID handling — never store PID 0 or negative
            string? id_str = process.get_identifier ();
            if (id_str != null) {
                int parsed = int.parse (id_str);
                if (parsed > 0) {
                    state_mutex.lock ();
                    current_pid = (Pid) parsed;
                    state_mutex.unlock ();
                }
            }

            var reader = new DataInputStream (process.get_stderr_pipe ());

            double pass_start = is_pass1 ? 0.0 : 50.0;
            double pass_range = 50.0;

            string line;
            while ((line = reader.read_line (null)) != null) {
                // Early exit if cancelled
                state_mutex.lock ();
                bool was_cancelled = cancelled;
                state_mutex.unlock ();
                if (was_cancelled) break;

                string clean = line.strip ();
                if (clean.length == 0) continue;

                bool is_noisy = clean.has_prefix ("frame=") || clean.has_prefix ("fps=") ||
                               clean.has_prefix ("stream_") || clean.has_prefix ("bitrate=") ||
                               clean.has_prefix ("total_size=") || clean.has_prefix ("out_time") ||
                               clean.has_prefix ("dup_frames=") || clean.has_prefix ("drop_frames=") ||
                               clean.has_prefix ("speed=") || clean.has_prefix ("progress=");

                if (!is_noisy || clean.contains ("Lsize=") || clean.contains ("Error") ||
                    clean.contains ("Warning") || clean.contains ("failed")) {
                    console_tab.add_line (clean);
                }

                double current_sec = -1.0;

                if (clean.has_prefix ("out_time_us=")) {
                    string us_str = clean.substring ("out_time_us=".length).strip ();
                    int64 us = int64.parse (us_str);
                    current_sec = us / 1000000.0;
                }
                else if (clean.has_prefix ("out_time=")) {
                    string time_str = clean.substring ("out_time=".length).strip ();
                    current_sec = parse_ffmpeg_timestamp (time_str);
                }

                // Throttle progress updates to ~4/sec
                if (current_sec >= 0 && total_duration > 0.0) {
                    int64 now = GLib.get_monotonic_time ();
                    if (now - last_progress_update > 250000) {
                        double fraction = (current_sec / total_duration).clamp (0.0, 1.0);
                        double percent = pass_start + (fraction * pass_range);
                        update_progress (percent);
                        last_progress_update = now;
                    }
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

    // ═════════════════════════════════════════════════════════════════════════
    //  CANCELLATION
    // ═════════════════════════════════════════════════════════════════════════

    public void cancel () {
        // Lock to safely read/write shared state
        state_mutex.lock ();
        if (!is_converting || current_pid <= 0) {
            state_mutex.unlock ();
            return;
        }
        // Grab local copies, set cancelled flag
        Pid pid_to_kill = current_pid;
        var phase = current_phase;
        cancelled = true;
        is_converting = false;
        current_pid = 0;
        current_phase = ConversionPhase.IDLE;
        state_mutex.unlock ();

        string cancel_msg = "⏹️ Cancelling conversion...";
        if (phase == ConversionPhase.PASS1) {
            cancel_msg = "⏹️ Cancelling Pass 1 (analysis)...";
        } else if (phase == ConversionPhase.PASS2) {
            cancel_msg = "⏹️ Cancelling Pass 2 (encoding)...";
        }

        update_status (cancel_msg);
        hide_progress_cancelled ();
        stop_pulsing ();

        // Posix.kill returns int, does NOT throw — check return value
        if (Posix.kill (pid_to_kill, Posix.Signal.TERM) != 0) {
            print ("Failed to send SIGTERM to PID %d: errno %d\n",
                   pid_to_kill, Posix.errno);
        } else {
            print ("Sent SIGTERM to FFmpeg (PID %d) during %s\n",
                   pid_to_kill, phase.to_string ());
        }

        // Escalate to SIGKILL after 3 seconds if process is still alive
        Pid kill_pid = pid_to_kill;
        Timeout.add (3000, () => {
            // Check if process is still running (signal 0 = probe only)
            if (Posix.kill (kill_pid, 0) == 0) {
                print ("FFmpeg PID %d still alive after 3 s — sending SIGKILL\n", kill_pid);
                Posix.kill (kill_pid, Posix.Signal.KILL);
            }
            return Source.REMOVE;
        });

        cleanup_passlog ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  STATUS / PROGRESS HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    internal void report_error (string message) {
        Idle.add (() => {
            status_label.set_text (@"❌ $message\nCheck the console for details.");
            console_tab.add_line ("❌ " + message);
            return Source.REMOVE;
        });
    }

    /** Show pulsing progress (used initially, before duration is known). */
    private void show_progress_pulse () {
        Idle.add (() => {
            progress_bar.set_visible (true);
            progress_bar.set_text ("Processing...");
            start_pulsing ();
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

    private void update_progress (double percent) {
        Idle.add (() => {
            progress_bar.set_fraction (percent / 100.0);
            progress_bar.set_text (@"%.1f%%".printf (percent));
            return Source.REMOVE;
        });
    }

    internal void update_status (string message) {
        Idle.add (() => {
            status_label.set_text (message);
            console_tab.add_line (message);
            return Source.REMOVE;
        });
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  DURATION PROBING
    // ═════════════════════════════════════════════════════════════════════════

    private double get_video_duration (string input_file) {
        try {
            string[] cmd = {
                "ffprobe", "-v", "quiet",
                "-print_format", "csv=p=0",
                "-show_entries", "format=duration",
                input_file
            };
            string stdout_buf, stderr_buf;
            int status;

            Process.spawn_sync (null, cmd, null,
                                SpawnFlags.SEARCH_PATH,
                                null, out stdout_buf, out stderr_buf, out status);

            if (status == 0) {
                double dur = double.parse (stdout_buf.strip ());
                if (dur > 0) return dur;
            }
        } catch (Error e) {
            print ("ffprobe error: %s\n", e.message);
        }
        return 0.0;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  TIMESTAMP PARSING
    // ═════════════════════════════════════════════════════════════════════════

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

    // ═════════════════════════════════════════════════════════════════════════
    //  PASSLOG CLEANUP
    // ═════════════════════════════════════════════════════════════════════════

    private void cleanup_passlog () {
        if (passlog_base == null) return;

        // Common passlog file patterns for both svt-av1 and x265
        string[] suffixes = {
            "-0.log", "-0.log.mbtree", "-0.log.cutree",
            "-0.log.temp", ".log", ".log.mbtree"
        };

        foreach (string suffix in suffixes) {
            try {
                var f = File.new_for_path (passlog_base + suffix);
                if (f.query_exists ()) f.delete ();
            } catch (Error e) {
                // Best effort
            }
        }

        passlog_base = null;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PULSING
    // ═════════════════════════════════════════════════════════════════════════

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

    // ═════════════════════════════════════════════════════════════════════════
    //  PHASE MANAGEMENT
    // ═════════════════════════════════════════════════════════════════════════

    internal void set_phase (ConversionPhase phase) {
        state_mutex.lock ();
        current_phase = phase;
        state_mutex.unlock ();
    }

    internal bool is_cancelled () {
        state_mutex.lock ();
        bool c = cancelled;
        state_mutex.unlock ();
        return c;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  FILENAME SANITIZATION
    // ═════════════════════════════════════════════════════════════════════════

    internal string sanitize_filename (string path) {
        string dir = Path.get_dirname (path);
        string name = Path.get_basename (path);

        // Map everything directly to _ — no confusing intermediate step
        string safe = name
            .replace ("：", "_")
            .replace ("？", "_")
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

    // ═════════════════════════════════════════════════════════════════════════
    //  SEEK / TIME VALIDATION
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Build a validated HH:MM:SS string from the seek/time entry widgets.
     * Returns a safe timestamp even if entries are empty or non-numeric.
     */
    internal static string build_timestamp (Entry hh, Entry mm, Entry ss) {
        string h = validate_time_field (hh.text, 0, 99);
        string m = validate_time_field (mm.text, 0, 59);
        string s = validate_time_field (ss.text, 0, 59);
        return @"$h:$m:$s";
    }

    private static string validate_time_field (string raw, int min_val, int max_val) {
        string trimmed = raw.strip ();
        if (trimmed.length == 0) return "00";

        int val = int.parse (trimmed);
        if (val < min_val) val = min_val;
        if (val > max_val) val = max_val;
        return "%02d".printf (val);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  POST-CONVERSION CLEANUP
    // ═════════════════════════════════════════════════════════════════════════

    public void cleanup_after_conversion () {
        state_mutex.lock ();
        is_converting = false;
        current_pid   = 0;
        current_phase = ConversionPhase.IDLE;
        state_mutex.unlock ();

        stop_pulsing ();
        hide_progress ();
        cleanup_passlog ();
    }
}
