using Gtk;
using GLib;
using Posix;

internal enum ConversionPhase {
    IDLE,
    PASS1,
    PASS2
}

// ═══════════════════════════════════════════════════════════════════════════════
//  ConversionConfig — Data object bundling everything ConversionRunner needs
//
//  Eliminates deep coupling (#3): ConversionRunner no longer reaches into
//  converter.general_tab, converter.codec_tab, converter.passlog_base, etc.
//  Instead, all data is snapshot into this config before the background thread
//  starts.
// ═══════════════════════════════════════════════════════════════════════════════

public class ConversionConfig : Object {
    // ── FFmpeg arguments ────────────────────────────────────────────────────
    public string video_filters  { get; set; default = ""; }
    public string audio_filters  { get; set; default = ""; }
    public string[] codec_args;
    public string[] audio_args;
    public string codec_name     { get; set; default = ""; }
    public string passlog_base   { get; set; default = ""; }

    // ── Seek / Duration ─────────────────────────────────────────────────────
    public bool   seek_enabled   { get; set; default = false; }
    public string seek_timestamp { get; set; default = "00:00:00"; }
    public bool   time_enabled   { get; set; default = false; }
    public string time_timestamp { get; set; default = "00:00:00"; }

    // ── Metadata ────────────────────────────────────────────────────────────
    public bool preserve_metadata { get; set; default = false; }
    public bool remove_chapters   { get; set; default = false; }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Converter — Orchestrates video conversion lifecycle
//
//  Responsibilities (after refactoring):
//   • Coordinates start/cancel of conversions
//   • Owns the ProcessRunner and ProgressTracker
//   • Snapshots UI state into ConversionConfig for the background thread
//   • Reports status/errors to the UI
//
//  Extracted to separate classes:
//   • Path computation, sanitization, timestamps → ConversionUtils namespace
//   • Progress bar management → ProgressTracker
//   • FFmpeg process execution → ProcessRunner
//   • Cross-component wiring → AppController
// ═══════════════════════════════════════════════════════════════════════════════

public class Converter : Object {
    // Emitted on the main thread after a successful conversion
    public signal void conversion_done (string output_file);

    // ── Stable dependencies ────────────
    private Label status_label;
    private ConsoleTab console_tab;

    public GeneralTab general_tab { get; private set; }

    // ── Shared infrastructure ───────────────────────────────────────────────
    public ProcessRunner process_runner { get; private set; }
    public ProgressTracker progress_tracker { get; private set; }

    // ── Per-conversion state (all guarded by state_mutex) ───────────────────
    private Mutex state_mutex = Mutex ();
    private bool is_converting = false;
    private ConversionPhase current_phase = ConversionPhase.IDLE;
    private double total_duration = 0.0;
    private string _last_output_file = "";
    private string? _passlog_base = null;

    // ── Thread-safe accessors ───────────────────────────────────────────────
    public string last_output_file {
        owned get {
            state_mutex.lock ();
            string v = _last_output_file;
            state_mutex.unlock ();
            return v;
        }
        set {
            state_mutex.lock ();
            _last_output_file = value;
            state_mutex.unlock ();
        }
    }

    public string? passlog_base {
        owned get {
            state_mutex.lock ();
            string? v = _passlog_base;
            state_mutex.unlock ();
            return v;
        }
        set {
            state_mutex.lock ();
            _passlog_base = value;
            state_mutex.unlock ();
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public Converter (Label status_label,
                      ProgressBar progress_bar,
                      ConsoleTab console_tab,
                      GeneralTab general_tab) {
        this.status_label   = status_label;
        this.console_tab    = console_tab;
        this.general_tab    = general_tab;
        this.process_runner = new ProcessRunner ();
        this.progress_tracker = new ProgressTracker (progress_bar);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  OUTPUT PATH COMPUTATION (backward-compat wrappers → ConversionUtils)
    // ═════════════════════════════════════════════════════════════════════════

    public static string compute_output_path (string input_file,
                                              string output_folder,
                                              ICodecBuilder builder,
                                              ICodecTab codec_tab) {
        return ConversionUtils.compute_output_path (input_file, output_folder, builder, codec_tab);
    }

    public static string find_unique_path (string path) {
        return ConversionUtils.find_unique_path (path);
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

        last_output_file = output_file;

        status_label.set_text (@"🚀 Starting conversion...\nOutput will be:\n$output_file");

        bool two_pass = codec_tab.get_two_pass ();

        // Snapshot all UI state into a ConversionConfig (#3)
        var config = snapshot_config (input_file, output_file, codec_tab, builder);

        state_mutex.lock ();
        is_converting = true;
        current_phase = ConversionPhase.IDLE;
        state_mutex.unlock ();

        process_runner.reset ();
        progress_tracker.reset_throttle ();
        progress_tracker.show_pulse ();

        new Thread<void> ("ffmpeg-thread", () => {
            // Probe duration on background thread (avoids UI freeze)
            double dur = get_video_duration (input_file);
            state_mutex.lock ();
            total_duration = dur;
            state_mutex.unlock ();

            bool pulse = (dur <= 0);
            progress_tracker.set_pulse_mode (pulse);

            if (!pulse) {
                progress_tracker.switch_to_determinate ();
            }

            run_conversion (input_file, output_file, two_pass, config);
        });
    }

    /**
     * Snapshot all relevant UI state into a ConversionConfig.
     * Called on the main thread before spawning the background thread.
     * This decouples ConversionRunner from live widget state (#3).
     */
    private ConversionConfig snapshot_config (string input_file,
                                              string output_file,
                                              ICodecTab codec_tab,
                                              ICodecBuilder builder) {
        var config = new ConversionConfig ();

        // Passlog
        string plog = "/tmp/ffmpeg_passlog_" + GLib.get_real_time ().to_string ();
        passlog_base = plog;
        config.passlog_base = plog;

        // Filters
        config.video_filters = FilterBuilder.build_video_filter_chain (general_tab);
        config.audio_filters = FilterBuilder.build_audio_filter_chain (general_tab);

        // Codec
        config.codec_name = builder.get_codec_name ();
        string[] built_codec_args = builder.get_codec_args (codec_tab);
        foreach (string kf in codec_tab.resolve_keyframe_args (input_file, general_tab)) {
            built_codec_args += kf;
        }
        config.codec_args = built_codec_args;

        // Audio
        config.audio_args = codec_tab.get_audio_args ();

        // Seek / Duration
        config.seek_enabled = general_tab.seek_check.active;
        if (config.seek_enabled) {
            config.seek_timestamp = ConversionUtils.build_timestamp (
                general_tab.seek_hh, general_tab.seek_mm, general_tab.seek_ss);
        }
        config.time_enabled = general_tab.time_check.active;
        if (config.time_enabled) {
            config.time_timestamp = ConversionUtils.build_timestamp (
                general_tab.time_hh, general_tab.time_mm, general_tab.time_ss);
        }

        // Metadata
        config.preserve_metadata = general_tab.preserve_metadata.active;
        config.remove_chapters   = general_tab.remove_chapters.active;

        return config;
    }

    private void run_conversion (string input, string output, bool two_pass,
                                 ConversionConfig config) {
        var runner = new ConversionRunner (this, config);
        runner.run (input, output, two_pass);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  FFMPEG PROCESS EXECUTION (delegates to ProcessRunner)
    // ═════════════════════════════════════════════════════════════════════════

    internal int execute_ffmpeg (string[] argv, bool is_pass1 = false) {
        double pass_start = is_pass1 ? 0.0 : 50.0;
        double pass_range = 50.0;

        int exit = process_runner.execute (argv, (clean) => {
            // Logging: filter out noisy progress lines
            bool is_noisy = clean.has_prefix ("frame=") || clean.has_prefix ("fps=") ||
                           clean.has_prefix ("stream_") || clean.has_prefix ("bitrate=") ||
                           clean.has_prefix ("total_size=") || clean.has_prefix ("out_time") ||
                           clean.has_prefix ("dup_frames=") || clean.has_prefix ("drop_frames=") ||
                           clean.has_prefix ("speed=") || clean.has_prefix ("progress=");

            if (!is_noisy || clean.contains ("Lsize=") || clean.contains ("Error") ||
                clean.contains ("Warning") || clean.contains ("failed")) {
                console_tab.add_line (clean);
            }

            // Progress parsing
            double current_sec = -1.0;

            if (clean.has_prefix ("out_time_us=")) {
                string us_str = clean.substring ("out_time_us=".length).strip ();
                int64 us = int64.parse (us_str);
                current_sec = us / 1000000.0;
            }
            else if (clean.has_prefix ("out_time=")) {
                string time_str = clean.substring ("out_time=".length).strip ();
                current_sec = ConversionUtils.parse_ffmpeg_timestamp (time_str);
            }

            state_mutex.lock ();
            double dur = total_duration;
            state_mutex.unlock ();

            if (current_sec >= 0 && dur > 0.0) {
                progress_tracker.update_from_time (current_sec, dur, pass_start, pass_range);
            }
        });

        print ("\n=== FFmpeg command ===\n%s\n", string.joinv (" ", argv));
        console_tab.set_command (string.joinv (" ", argv));

        return exit;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CANCELLATION
    // ═════════════════════════════════════════════════════════════════════════

    public void cancel () {
        state_mutex.lock ();
        if (!is_converting) {
            state_mutex.unlock ();
            return;
        }
        var phase = current_phase;
        is_converting = false;
        current_phase = ConversionPhase.IDLE;
        state_mutex.unlock ();

        string cancel_msg = "⏹️ Cancelling conversion...";
        if (phase == ConversionPhase.PASS1) {
            cancel_msg = "⏹️ Cancelling Pass 1 (analysis)...";
        } else if (phase == ConversionPhase.PASS2) {
            cancel_msg = "⏹️ Cancelling Pass 2 (encoding)...";
        }

        update_status (cancel_msg);
        progress_tracker.hide_cancelled ();
        progress_tracker.stop_pulsing ();

        // Delegate to ProcessRunner (proper kill + SIGKILL escalation)
        process_runner.cancel ();

        cleanup_passlog ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  STATUS HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    internal void report_error (string message) {
        Idle.add (() => {
            status_label.set_text (@"❌ $message\nCheck the console for details.");
            console_tab.add_line ("❌ " + message);
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
    //  PASSLOG CLEANUP
    // ═════════════════════════════════════════════════════════════════════════

    private void cleanup_passlog () {
        string? plog = passlog_base;
        if (plog == null) return;

        string[] suffixes = {
            "-0.log", "-0.log.mbtree", "-0.log.cutree",
            "-0.log.temp", ".log", ".log.mbtree"
        };

        foreach (string suffix in suffixes) {
            try {
                var f = File.new_for_path (plog + suffix);
                if (f.query_exists ()) f.delete ();
            } catch (Error e) {
                // Best effort
            }
        }

        passlog_base = null;
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
        return process_runner.is_cancelled ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  POST-CONVERSION CLEANUP
    // ═════════════════════════════════════════════════════════════════════════

    public void cleanup_after_conversion () {
        state_mutex.lock ();
        is_converting = false;
        current_phase = ConversionPhase.IDLE;
        state_mutex.unlock ();

        progress_tracker.stop_pulsing ();
        progress_tracker.hide ();
        cleanup_passlog ();
    }
}
