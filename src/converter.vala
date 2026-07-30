using Gtk;
using GLib;
using Posix;

internal enum ConversionPhase {
    IDLE,
    ENCODING,
    PASS1,
    PASS2,
    FINALIZING,
    COLLAGE
}

// ═══════════════════════════════════════════════════════════════════════════════
//  ConversionConfig — Data object bundling everything ConversionRunner needs
// ═══════════════════════════════════════════════════════════════════════════════

public class ConversionConfig : Object {
    // ── FFmpeg arguments ────────────────────────────────────────────────────
    public EncodeProfileSnapshot profile { get; set; default = new EncodeProfileSnapshot (); }
    public string passlog_base   { get; set; default = ""; }
    public SvtAv1CrfTwoPassCapabilityStatus svt_crf_two_pass_status {
        get; set; default = SvtAv1CrfTwoPassCapabilityStatus.UNKNOWN;
    }
    public string? svt_crf_two_pass_reason { get; set; default = null; }

    // ── Seek / Duration ─────────────────────────────────────────────────────
    public bool   seek_enabled   { get; set; default = false; }
    public string seek_timestamp { get; set; default = "00:00:00"; }
    public bool   time_enabled   { get; set; default = false; }
    public string time_timestamp { get; set; default = "00:00:00"; }
    public double source_span_seconds { get; set; default = 0.0; }
    public double video_source_span_seconds { get; set; default = 0.0; }

    // Timed input content that FFmpeg may carry into the output implicitly.
    // A failed probe remains "unknown" so timestamp normalization can fail
    // closed rather than shifting video independently of another timeline.
    public bool timed_stream_topology_known { get; set; default = false; }
    public bool input_has_subtitle_stream { get; set; default = false; }
    public bool input_has_chapters { get; set; default = false; }

    // Set only when this conversion follows a successful size-pinned Smart
    // Optimizer recommendation. The runner uses it for an actual-vs-requested
    // report after the output has passed ffprobe validation.
    public int smart_requested_size_kib { get; set; default = 0; }
    public int smart_planned_size_kib { get; set; default = 0; }
    public double smart_planning_uncertainty { get; set; default = 0.0; }

    // ── Frame-based progress ───────────────────────────────────────────────
    //    Effective output fps resolved at snapshot time from the General tab's
    //    frame rate setting.  0.0 means "use probed input fps".
    public double output_fps { get; set; default = 0.0; }
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
    public signal void conversion_done (OperationOutputResult output_result);
    public signal void conversion_succeeded (uint64 operation_id, OperationOutputResult output_result);
    public signal void conversion_failed (uint64 operation_id);
    public signal void conversion_cancelled (uint64 operation_id, string cancel_message);

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
    private string? _passlog_run_dir = null;
    private string pending_smart_size_codec = "";
    private int pending_smart_target_size_kib = 0;
    private int pending_smart_planned_size_kib = 0;
    private double pending_smart_planning_uncertainty = 0.0;
    private SvtAv1CrfTwoPassCapability svt_crf_two_pass_capability =
        new SvtAv1CrfTwoPassCapability ();

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

    public void set_svt_crf_two_pass_capability (SvtAv1CrfTwoPassCapability capability) {
        svt_crf_two_pass_capability = capability.copy ();
    }

    public SvtAv1CrfTwoPassCapability get_svt_crf_two_pass_capability () {
        return svt_crf_two_pass_capability.copy ();
    }

    /** Stage a one-shot final-size report for the next conversion. */
    public void stage_smart_size_report (string codec,
                                         int target_size_kib,
                                         int planned_size_kib,
                                         double planning_uncertainty) {
        state_mutex.lock ();
        try {
            if (target_size_kib > 0 && codec.length > 0) {
                pending_smart_size_codec = codec.down ();
                pending_smart_target_size_kib = target_size_kib;
                pending_smart_planned_size_kib = int.max (
                    0, planned_size_kib);
                pending_smart_planning_uncertainty = planning_uncertainty.clamp (
                    0.0, 0.50);
            } else {
                pending_smart_size_codec = "";
                pending_smart_target_size_kib = 0;
                pending_smart_planned_size_kib = 0;
                pending_smart_planning_uncertainty = 0.0;
            }
        } finally {
            state_mutex.unlock ();
        }
    }

    private void consume_smart_size_report (string codec,
                                            out int target,
                                            out int planned,
                                            out double uncertainty) {
        target = 0;
        planned = 0;
        uncertainty = 0.0;
        state_mutex.lock ();
        try {
            if (pending_smart_target_size_kib > 0
                    && pending_smart_size_codec == codec.down ()) {
                target = pending_smart_target_size_kib;
                planned = pending_smart_planned_size_kib;
                uncertainty = pending_smart_planning_uncertainty;
            }
            // Any conversion consumes the one-shot association. If the user
            // changed codec after optimization, do not let the old target
            // attach itself to an unrelated later conversion.
            pending_smart_size_codec = "";
            pending_smart_target_size_kib = 0;
            pending_smart_planned_size_kib = 0;
            pending_smart_planning_uncertainty = 0.0;
        } finally {
            state_mutex.unlock ();
        }
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

    public static string? find_unique_path (string path) {
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
            status_area.set_status ("Please select an input file first!",
                StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
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
            status_area.set_status ("A conversion is already running!",
                StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
            return false;
        }

        last_output_file = output_file;

        string codec_name = builder.get_codec_name ();
        console_tab.add_section_header (
            "Conversion #%s — %s".printf (operation_id.to_string (), codec_name.up ()),
            {
                "Input:  " + input_file,
                "Output: " + output_file
            }
        );

        status_area.set_status (@"Starting conversion...\nOutput will be:\n$output_file",
            StatusIcon.PROGRESS_ICON, StatusIcon.PROGRESS_CSS);

        bool two_pass = codec_tab.get_two_pass ();

        // Snapshot all UI state into a ConversionConfig
        var config = snapshot_config (input_file, output_file, codec_tab, builder, two_pass);

        progress_tracker.reset_throttle ();
        progress_tracker.show_pulse ();

        try {
            new Thread<void>.try ("ffmpeg-thread", () => {
                // Probe duration and fps on background thread
                double dur = FfprobeUtils.probe_duration (input_file);
                double probed_fps = FfprobeUtils.probe_input_fps (input_file);
                TimedStreamTopologyProbeResult timed_topology =
                    FfprobeUtils.probe_timed_stream_topology (
                        input_file, runner.execute_capture);
                VideoTimelineProbeResult video_timeline =
                    FfprobeUtils.probe_video_timeline (
                        input_file, runner.execute_capture);
                bool still_active;

                state_mutex.lock ();
                try {
                    still_active = (active_operation_id == operation_id &&
                                    active_runner == runner);
                    if (still_active) {
                        total_duration = dur;
                        config.source_span_seconds = compute_source_span_seconds (
                            dur, config.seek_enabled ? config.seek_timestamp : "",
                            config.time_enabled ? config.time_timestamp : ""
                        );
                        double video_duration = video_timeline.get_duration ();
                        config.video_source_span_seconds = video_duration > 0.0
                            ? compute_source_span_seconds (
                                video_duration,
                                config.seek_enabled ? config.seek_timestamp : "",
                                config.time_enabled ? config.time_timestamp : ""
                            )
                            : 0.0;
                        config.timed_stream_topology_known = timed_topology.success;
                        config.input_has_subtitle_stream =
                            timed_topology.has_subtitle_stream;
                        config.input_has_chapters = timed_topology.has_chapters;
                    }
                } finally {
                    state_mutex.unlock ();
                }

                if (!still_active) {
                    return;
                }

                // Compute expected output frames for frame-based progress.
                // Use effective output fps: custom frame rate from the profile
                // takes precedence over the probed input fps.
                double output_fps = resolve_output_fps (config, probed_fps);
                int64 expected_frames = compute_expected_frame_count (
                    config, output_fps);
                progress_tracker.set_expected_frames (expected_frames);

                // The packet timeline may still provide a reliable video
                // duration when container duration metadata is unavailable.
                bool pulse = expected_frames <= 0;
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
                                              ICodecBuilder builder,
                                              bool two_pass) {
        var config = new ConversionConfig ();

        passlog_base = null;
        _passlog_run_dir = null;

        if (two_pass) {
            string codec_name = builder.get_codec_name ();
            string? managed_run_dir = ConversionUtils.create_managed_temp_run_dir (
                "conversion",
                codec_name
            );

            if (managed_run_dir != null) {
                _passlog_run_dir = managed_run_dir;
                string plog = Path.build_filename (managed_run_dir, "passlog");
                passlog_base = plog;
                config.passlog_base = plog;
            } else {
                // Fall back to the legacy temp-file base if the managed run
                // directory cannot be created.
                string plog = Path.build_filename (
                    Environment.get_tmp_dir (),
                    "ffmpeg_passlog_" + GLib.get_real_time ().to_string ()
                );
                passlog_base = plog;
                config.passlog_base = plog;
            }
        }

        PixelFormatSettingsSnapshot? pixel_format =
            (codec_tab is BaseCodecTab)
            ? ((BaseCodecTab) codec_tab).snapshot_pixel_format_settings ()
            : null;
        GeneralSettingsSnapshot general_settings = general_tab.snapshot_settings (pixel_format);
        config.profile = CodecUtils.snapshot_encode_profile (builder, codec_tab, general_settings);
        int smart_requested_size_kib;
        int smart_planned_size_kib;
        double smart_planning_uncertainty;
        consume_smart_size_report (
            config.profile.codec_name,
            out smart_requested_size_kib,
            out smart_planned_size_kib,
            out smart_planning_uncertainty);
        config.smart_requested_size_kib = smart_requested_size_kib;
        config.smart_planned_size_kib = smart_planned_size_kib;
        config.smart_planning_uncertainty = smart_planning_uncertainty;
        SvtAv1CrfTwoPassCapability svt_capability = get_svt_crf_two_pass_capability ();
        config.svt_crf_two_pass_status = svt_capability.status;
        config.svt_crf_two_pass_reason = svt_capability.reason;

        // Seek / Duration
        config.seek_enabled = general_tab.is_seek_enabled ();
        if (config.seek_enabled) {
            config.seek_timestamp = general_tab.get_seek_timestamp ();
        }
        config.time_enabled = general_tab.is_time_enabled ();
        if (config.time_enabled) {
            config.time_timestamp = general_tab.get_time_timestamp ();
        }

        // Effective output fps from the General tab frame rate setting.
        // 0.0 means "use probed input fps" (resolved on background thread).
        config.output_fps = resolve_output_fps_from_settings (general_settings);

        return config;
    }

    private void run_conversion (string input, string output, bool two_pass,
                                 ProcessRunner process_runner,
                                 ConversionConfig config,
                                 uint64 operation_id) {
        var runner = new ConversionRunner (this, process_runner, config);
        runner.run (input, output, two_pass, operation_id);
    }

    /**
     * The stretch of source an encode will read: the input duration, less the
     * seek, capped by the requested length.
     *
     * This is source time, not output time. A speed filter makes the two
     * differ, so anything that needs the output's own length has to divide by
     * the matching speed multiplier — video and audio separately, since those
     * rates are set independently. See compute_expected_frame_count and
     * ConversionRunner's audio fade placement.
     */
    private static double compute_source_span_seconds (double input_duration,
                                                       string seek_timestamp,
                                                       string time_timestamp) {
        double duration = input_duration;
        if (seek_timestamp.length > 0) {
            duration -= ConversionUtils.parse_ffmpeg_timestamp (seek_timestamp);
        }
        if (duration < 0.0) {
            duration = 0.0;
        }
        if (time_timestamp.length > 0) {
            double requested = ConversionUtils.parse_ffmpeg_timestamp (time_timestamp);
            if (requested > 0.0) {
                duration = (duration > 0.0 && requested < duration) ? requested : duration;
                if (duration <= 0.0) {
                    duration = requested;
                }
            }
        }
        return duration;
    }

    /**
     * Resolve the effective output fps from the General tab's frame rate
     * setting, snapshotted into general_settings.  Returns 0.0 if the
     * setting is "Original" (meaning: use the probed input fps).
     */
    private static double resolve_output_fps_from_settings (
        GeneralSettingsSnapshot general_settings) {
        double fps = 0.0;
        return CodecUtils.try_resolve_output_fps_from_snapshot (
            general_settings, out fps) ? fps : 0.0;
    }

    /**
     * Determine the effective output fps for frame-based progress, preferring
     * the user's configured output fps over the probed input fps.
     */
    private static double resolve_output_fps (ConversionConfig config,
                                              double probed_fps) {
        return config.output_fps > 0 ? config.output_fps : probed_fps;
    }

    private static int64 compute_expected_frame_count (ConversionConfig config,
                                                       double output_fps) {
        double source_span =
            config.video_source_span_seconds > 0.0
                ? config.video_source_span_seconds
                : config.source_span_seconds;
        if (output_fps <= 0.0 || source_span <= 0.0)
            return 0;

        // The span is source time; the frames being counted are the output's.
        // A speed filter compresses or stretches one into the other, and
        // FFmpeg re-times to the output frame rate rather than carrying every
        // source frame across — so at 2x this counts twice the frames that
        // actually get written, and the bar stalls at half.
        double speed = config.profile.video_speed_multiplier;
        if (!speed.is_finite () || speed <= 0.0) speed = 1.0;

        return (int64) Math.round (output_fps * (source_span / speed));
    }

#if COMBINE_WINDOW_TEST_BUILD
    internal static int64 compute_expected_frame_count_for_test (
        ConversionConfig config,
        double output_fps
    ) {
        return compute_expected_frame_count (config, output_fps);
    }
#endif

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
        string display_cmd = ConversionUtils.format_command_for_display (argv);
        print ("\n=== FFmpeg command ===\n%s\n", display_cmd);
        if (accepts_runner_updates (process_runner)) {
            console_tab.add_line ("Command: " + display_cmd);
            console_tab.set_command (display_cmd);
        }

        int exit = process_runner.execute (argv, (clean) => {
            if (!accepts_runner_updates (process_runner)) {
                return;
            }

            // Logging: filter out noisy progress lines
            if (ConversionUtils.should_log_ffmpeg_line (clean)) {
                console_tab.add_line (clean);
            }

            // Progress parsing — prefer frame-based when available,
            // fall back to time-based.  Frame-based progress is reliable
            // even on multi-audio-stream inputs where out_time_us can
            // stall at the shortest audio stream's duration.
            if (clean.has_prefix ("frame=")) {
                string frame_str = clean.substring ("frame=".length).strip ();
                int64 frame = int64.parse (frame_str);
                if (frame > 0) {
                    if (progress_tracker.update_from_frame (frame, pass_start, pass_range)) {
                        return;
                    }
                }
            }

            // Time-based fallback (used when expected frames is 0, or
            // for lines that aren't frame= lines)
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

        string cancel_msg = "Cancelling conversion...";
        if (phase == ConversionPhase.ENCODING) {
            cancel_msg = "Cancelling encoding...";
        } else if (phase == ConversionPhase.PASS1) {
            cancel_msg = "Cancelling Pass 1 (analysis)...";
        } else if (phase == ConversionPhase.PASS2) {
            cancel_msg = "Cancelling Pass 2 (encoding)...";
        } else if (phase == ConversionPhase.FINALIZING) {
            cancel_msg = "Finishing conversion...";
        } else if (phase == ConversionPhase.COLLAGE) {
            cancel_msg = "Cancelling collage thumbnail generation...";
        }

        update_status (cancel_msg, StatusIcon.CANCELLED_ICON, StatusIcon.CANCELLED_CSS);
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
        status_area.set_status (@"$message\nCheck the console for details.",
            StatusIcon.ERROR_ICON, StatusIcon.ERROR_CSS);
        console_tab.add_line ("❌ " + message);
    }

    internal void report_error_if_active (ProcessRunner process_runner, string message) {
        if (!accepts_runner_updates (process_runner)) {
            return;
        }

        report_error (message);
    }

    internal void update_status (string message,
                                 string icon_name = StatusIcon.INFO_ICON,
                                 string css_class = StatusIcon.INFO_CSS) {
        status_area.set_status (message, icon_name, css_class);
        console_tab.add_line (message);
    }

    internal void update_status_if_active (ProcessRunner process_runner,
                                           string message,
                                           string icon_name = StatusIcon.INFO_ICON,
                                           string css_class = StatusIcon.INFO_CSS) {
        if (!accepts_runner_updates (process_runner)) {
            return;
        }

        update_status (message, icon_name, css_class);
    }

    internal void log_console_if_active (ProcessRunner process_runner, string message) {
        if (!accepts_runner_updates (process_runner)) {
            return;
        }

        console_tab.add_line (message);
    }

    internal void show_command_if_active (ProcessRunner process_runner, string[] argv) {
        string full_cmd = ConversionUtils.format_command_for_display (argv);
        print ("\n=== FFmpeg command ===\n%s\n", full_cmd);

        if (!accepts_runner_updates (process_runner)) {
            return;
        }

        console_tab.add_line ("Analysis command: " + full_cmd);
        console_tab.set_command (full_cmd);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PASSLOG CLEANUP
    // ═════════════════════════════════════════════════════════════════════════

    private void cleanup_passlog () {
        string? plog = passlog_base;
        if (plog != null) {
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
        }

        string? run_dir = _passlog_run_dir;
        if (run_dir != null) {
            ConversionUtils.try_remove_empty_dir_chain (
                run_dir,
                ConversionUtils.get_app_temp_root ()
            );
        }

        passlog_base = null;
        _passlog_run_dir = null;
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

    internal void set_optional_phase_if_active (ProcessRunner process_runner,
                                                ConversionPhase phase) {
        state_mutex.lock ();
        try {
            if (active_runner != process_runner) {
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

    internal bool consume_optional_cancellation_if_active (ProcessRunner process_runner) {
        bool consumed = false;

        state_mutex.lock ();
        try {
            if (active_runner == process_runner
                && cancel_pending
                && (current_phase == ConversionPhase.FINALIZING
                    || current_phase == ConversionPhase.COLLAGE)) {
                cancel_pending = false;
                cancel_progress_hidden = false;
                consumed = true;
            }
        } finally {
            state_mutex.unlock ();
        }

        return consumed;
    }

    internal void finish_conversion (uint64 operation_id,
                                     ProcessRunner process_runner,
                                     bool succeeded,
                                     OperationOutputResult? output_result = null) {
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
                conversion_cancelled (
                    operation_id,
                    process_runner.get_cancel_completion_message ()
                );
                return Source.REMOVE;
            }

            progress_tracker.hide ();

            if (succeeded && output_result != null) {
                conversion_done (output_result);
                conversion_succeeded (operation_id, output_result);
            } else if (!succeeded) {
                conversion_failed (operation_id);
            }

            return Source.REMOVE;
        });
    }
}
