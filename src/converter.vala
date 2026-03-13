using Gtk;
using GLib;
using Posix;

internal enum ConversionPhase {
    IDLE,
    ENCODING,
    PASS1,
    PASS2
}

// ═══════════════════════════════════════════════════════════════════════════════
//  ConversionConfig — Data object bundling everything ConversionRunner needs
// ═══════════════════════════════════════════════════════════════════════════════

public class ConversionConfig : Object {
    // ── FFmpeg arguments ────────────────────────────────────────────────────
    public EncodeProfileSnapshot profile { get; set; default = new EncodeProfileSnapshot (); }
    public string passlog_base   { get; set; default = ""; }

    // ── Seek / Duration ─────────────────────────────────────────────────────
    public bool   seek_enabled   { get; set; default = false; }
    public string seek_timestamp { get; set; default = "00:00:00"; }
    public bool   time_enabled   { get; set; default = false; }
    public string time_timestamp { get; set; default = "00:00:00"; }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Converter — Orchestrates video conversion lifecycle
//
//  Responsibilities (after refactoring):
//   • Coordinates start/cancel of conversions
//   • Owns the active conversion runner and ProgressTracker
//   • Snapshots UI state into ConversionConfig for the background thread
//   • Reports status/errors to the UI via StatusArea
//
//  Extracted to separate classes:
//   • Path computation, sanitization, timestamps → ConversionUtils namespace
//   • Progress bar management → ProgressTracker
//   • FFmpeg process execution → ProcessRunner
//   • Cross-component wiring → AppController
//   • Duration probing → FfprobeUtils
// ═══════════════════════════════════════════════════════════════════════════════

public class Converter : Object {
    // Emitted on the main thread after a successful conversion
    public signal void conversion_done (string output_file);
    public signal void conversion_succeeded (uint64 operation_id, string output_file);
    public signal void conversion_failed (uint64 operation_id);
    public signal void conversion_cancelled (uint64 operation_id);

    // ── Stable dependencies ─────────────────────────────────────────────────
    private StatusArea status_area;
    private ConsoleTab console_tab;

    public GeneralTab general_tab { get; private set; }

    // ── Shared infrastructure ───────────────────────────────────────────────
    public ProgressTracker progress_tracker { get; private set; }

    // ── Per-conversion state (all guarded by state_mutex) ───────────────────
    private Mutex state_mutex = Mutex ();
    private bool is_converting = false;
    private bool cancel_pending = false;
    private bool cancel_progress_hidden = false;
    private ConversionPhase current_phase = ConversionPhase.IDLE;
    private double total_duration = 0.0;
    private uint64 active_operation_id = 0;
    private ProcessRunner? active_runner = null;
    private string _last_output_file = "";
    private string? _passlog_base = null;

    // ── Thread-safe accessors ───────────────────────────────────────────────
    public string last_output_file {
        owned get {
            string output_file;
            state_mutex.lock ();
            try {
                output_file = _last_output_file;
            } finally {
                state_mutex.unlock ();
            }
            return output_file;
        }
        set {
            state_mutex.lock ();
            try {
                _last_output_file = value;
            } finally {
                state_mutex.unlock ();
            }
        }
    }

    public string? passlog_base {
        owned get {
            string? passlog;
            state_mutex.lock ();
            try {
                passlog = _passlog_base;
            } finally {
                state_mutex.unlock ();
            }
            return passlog;
        }
        set {
            state_mutex.lock ();
            try {
                _passlog_base = value;
            } finally {
                state_mutex.unlock ();
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    //
    //  Accepts StatusArea instead of raw Label + ProgressBar so that callers
    //  (MainWindow) don't need to reach into StatusArea's internals.
    // ═════════════════════════════════════════════════════════════════════════

    public Converter (StatusArea status_area,
                      ConsoleTab console_tab,
                      GeneralTab general_tab) {
        this.status_area    = status_area;
        this.console_tab    = console_tab;
        this.general_tab    = general_tab;
        this.progress_tracker = new ProgressTracker (status_area.progress_bar);
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

    public static async string compute_output_path_async (string input_file,
                                                          string output_folder,
                                                          ICodecBuilder builder,
                                                          ICodecTab codec_tab,
                                                          Cancellable? cancellable = null) {
        return yield ConversionUtils.compute_output_path_async (
            input_file, output_folder, builder, codec_tab, cancellable);
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
    private bool try_reserve_conversion_start (uint64 operation_id,
                                               ProcessRunner runner) {
        state_mutex.lock ();
        try {
            if (is_converting) {
                return false;
            }

            is_converting = true;
            cancel_pending = false;
            cancel_progress_hidden = false;
            current_phase = ConversionPhase.IDLE;
            total_duration = 0.0;
            active_operation_id = operation_id;
            active_runner = runner;
            return true;
        } finally {
            state_mutex.unlock ();
        }
    }

    private void rollback_conversion_start (uint64 operation_id,
                                           ProcessRunner runner) {
        state_mutex.lock ();
        try {
            if (active_operation_id == operation_id && active_runner == runner) {
                is_converting = false;
                cancel_pending = false;
                cancel_progress_hidden = false;
                current_phase = ConversionPhase.IDLE;
                total_duration = 0.0;
                active_operation_id = 0;
                active_runner = null;
            }
        } finally {
            state_mutex.unlock ();
        }
    }

    public bool start_conversion (string input_file,
                                  string output_file,
                                  ICodecTab codec_tab,
                                  ICodecBuilder builder,
                                  uint64 operation_id) {
        if (input_file == "") {
            status_area.set_status ("⚠️ Please select an input file first!");
            return false;
        }

        var runner = new ProcessRunner ();
        runner.set_event_logger ((message) => {
            Idle.add (() => {
                console_tab.add_line (message);
                return Source.REMOVE;
            });
        });

        if (!try_reserve_conversion_start (operation_id, runner)) {
            status_area.set_status ("⚠️ A conversion is already running!");
            return false;
        }

        last_output_file = output_file;

        status_area.set_status (@"🚀 Starting conversion...\nOutput will be:\n$output_file");

        bool two_pass = codec_tab.get_two_pass ();

        // Snapshot all UI state into a ConversionConfig
        var config = snapshot_config (input_file, output_file, codec_tab, builder);

        progress_tracker.reset_throttle ();
        progress_tracker.show_pulse ();

        try {
            new Thread<void>.try ("ffmpeg-thread", () => {
                // Probe duration on background thread via shared utility
                double dur = FfprobeUtils.probe_duration (input_file);
                bool still_active;

                state_mutex.lock ();
                try {
                    still_active = (active_operation_id == operation_id &&
                                    active_runner == runner);
                    if (still_active) {
                        total_duration = dur;
                    }
                } finally {
                    state_mutex.unlock ();
                }

                if (!still_active) {
                    return;
                }

                bool pulse = (dur <= 0);
                if (!accepts_runner_updates (runner)) {
                    finish_conversion (operation_id, runner, false);
                    return;
                }
                progress_tracker.set_pulse_mode (pulse);

                if (!pulse) {
                    if (!accepts_runner_updates (runner)) {
                        finish_conversion (operation_id, runner, false);
                        return;
                    }
                    progress_tracker.switch_to_determinate ();
                }

                run_conversion (input_file, output_file, two_pass, runner, config, operation_id);
            });
        } catch (Error e) {
            rollback_conversion_start (operation_id, runner);
            progress_tracker.hide ();
            cleanup_passlog ();
            report_error ("Failed to start conversion thread: " + e.message);
            return false;
        }

        return true;
    }

    /**
     * Snapshot all relevant UI state into a ConversionConfig.
     * Called on the main thread before spawning the background thread.
     * This decouples ConversionRunner from live widget state.
     */
    private ConversionConfig snapshot_config (string input_file,
                                              string output_file,
                                              ICodecTab codec_tab,
                                              ICodecBuilder builder) {
        var config = new ConversionConfig ();

        // Passlog — use $TMPDIR-respecting path
        string plog = Path.build_filename (
            Environment.get_tmp_dir (),
            "ffmpeg_passlog_" + GLib.get_real_time ().to_string ()
        );
        passlog_base = plog;
        config.passlog_base = plog;

        PixelFormatSettingsSnapshot? pixel_format =
            (codec_tab is BaseCodecTab)
            ? ((BaseCodecTab) codec_tab).snapshot_pixel_format_settings ()
            : null;
        GeneralSettingsSnapshot general_settings = general_tab.snapshot_settings (pixel_format);
        config.profile = CodecUtils.snapshot_encode_profile (builder, codec_tab, general_settings);

        // Seek / Duration
        config.seek_enabled = general_tab.is_seek_enabled ();
        if (config.seek_enabled) {
            config.seek_timestamp = general_tab.get_seek_timestamp ();
        }
        config.time_enabled = general_tab.is_time_enabled ();
        if (config.time_enabled) {
            config.time_timestamp = general_tab.get_time_timestamp ();
        }

        // Metadata
        return config;
    }

    private void run_conversion (string input, string output, bool two_pass,
                                 ProcessRunner process_runner,
                                 ConversionConfig config,
                                 uint64 operation_id) {
        var runner = new ConversionRunner (this, process_runner, config);
        runner.run (input, output, two_pass, operation_id);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  FFMPEG PROCESS EXECUTION (delegates to ProcessRunner)
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Execute an FFmpeg command with progress tracking.
     *
     * @param argv        The full FFmpeg command-line arguments
     * @param pass_start  Starting percentage for progress display (default 0)
     * @param pass_range  Percentage range for this pass (default 100)
     */
    internal int execute_ffmpeg (ProcessRunner process_runner,
                                 string[] argv,
                                 double pass_start = 0.0,
                                 double pass_range = 100.0) {
        int exit = process_runner.execute (argv, (clean) => {
            if (!accepts_runner_updates (process_runner)) {
                return;
            }

            // Logging: filter out noisy progress lines
            if (ConversionUtils.should_log_ffmpeg_line (clean)) {
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

            double dur;
            state_mutex.lock ();
            try {
                dur = total_duration;
            } finally {
                state_mutex.unlock ();
            }

            if (current_sec >= 0 && dur > 0.0) {
                progress_tracker.update_from_time (current_sec, dur, pass_start, pass_range);
            }
        });

        print ("\n=== FFmpeg command ===\n%s\n", string.joinv (" ", argv));
        if (accepts_runner_updates (process_runner)) {
            console_tab.set_command (string.joinv (" ", argv));
        }

        return exit;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CANCELLATION
    // ═════════════════════════════════════════════════════════════════════════

    public void cancel () {
        ProcessRunner? runner_to_cancel = null;
        ConversionPhase phase = ConversionPhase.IDLE;
        bool hide_cancelled_progress = false;

        state_mutex.lock ();
        try {
            if (!is_converting) {
                return;
            }
            phase = current_phase;
            cancel_pending = true;
            hide_cancelled_progress = !cancel_progress_hidden;
            cancel_progress_hidden = true;
            runner_to_cancel = active_runner;
        } finally {
            state_mutex.unlock ();
        }

        string cancel_msg = "⏹️ Cancelling conversion...";
        if (phase == ConversionPhase.ENCODING) {
            cancel_msg = "⏹️ Cancelling encoding...";
        } else if (phase == ConversionPhase.PASS1) {
            cancel_msg = "⏹️ Cancelling Pass 1 (analysis)...";
        } else if (phase == ConversionPhase.PASS2) {
            cancel_msg = "⏹️ Cancelling Pass 2 (encoding)...";
        }

        update_status (cancel_msg);
        if (hide_cancelled_progress) {
            progress_tracker.hide_cancelled ();
        }

        if (runner_to_cancel != null) {
            runner_to_cancel.cancel ();
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  STATUS HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    internal void report_error (string message) {
        status_area.set_status (@"❌ $message\nCheck the console for details.");
        console_tab.add_line ("❌ " + message);
    }

    internal void report_error_if_active (ProcessRunner process_runner, string message) {
        if (!accepts_runner_updates (process_runner)) {
            return;
        }

        report_error (message);
    }

    internal void update_status (string message) {
        status_area.set_status (message);
        console_tab.add_line (message);
    }

    internal void update_status_if_active (ProcessRunner process_runner, string message) {
        if (!accepts_runner_updates (process_runner)) {
            return;
        }

        update_status (message);
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

    internal void set_phase_if_active (ProcessRunner process_runner, ConversionPhase phase) {
        state_mutex.lock ();
        try {
            if (active_runner != process_runner || cancel_pending) {
                return;
            }
            current_phase = phase;
        } finally {
            state_mutex.unlock ();
        }
    }

    internal bool is_cancelled (ProcessRunner process_runner) {
        return process_runner.is_cancelled ();
    }

    internal bool accepts_runner_updates (ProcessRunner process_runner) {
        bool accepts_updates;
        state_mutex.lock ();
        try {
            accepts_updates = (active_runner == process_runner && !cancel_pending);
        } finally {
            state_mutex.unlock ();
        }

        return accepts_updates;
    }

    internal void finish_conversion (uint64 operation_id,
                                     ProcessRunner process_runner,
                                     bool succeeded,
                                     string? output_file = null) {
        string? completed_output = output_file;

        Idle.add (() => {
            bool should_emit;
            bool was_cancelled = false;
            bool hide_cancelled_progress = false;

            state_mutex.lock ();
            try {
                should_emit = (active_operation_id == operation_id &&
                               active_runner == process_runner);
                if (should_emit) {
                    was_cancelled = cancel_pending;
                    hide_cancelled_progress = was_cancelled && !cancel_progress_hidden;
                    is_converting = false;
                    cancel_pending = false;
                    cancel_progress_hidden = false;
                    current_phase = ConversionPhase.IDLE;
                    active_operation_id = 0;
                    active_runner = null;
                }
            } finally {
                state_mutex.unlock ();
            }

            if (!should_emit) {
                return Source.REMOVE;
            }

            cleanup_passlog ();

            if (was_cancelled) {
                if (hide_cancelled_progress) {
                    progress_tracker.hide_cancelled ();
                }
                conversion_cancelled (operation_id);
                return Source.REMOVE;
            }

            progress_tracker.hide ();

            if (succeeded && completed_output != null) {
                conversion_done (completed_output);
                conversion_succeeded (operation_id, completed_output);
            } else if (!succeeded) {
                conversion_failed (operation_id);
            }

            return Source.REMOVE;
        });
    }
}
