using Gtk;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  AudioRunner — FFmpeg execution pipeline for audio extraction
//
//  Handles:
//   • Basic extraction (no segments) — copy or transcode
//   • Single segment extraction
//   • Multi-segment separate — each segment to its own file
//   • Multi-segment combined — concat filter (transcode) or concat demuxer (copy)
//   • Extract all tracks — batch copy of every audio stream
//
//  Follows the same thread-safety pattern as TrimRunner: spawns a background
//  thread, uses ProcessRunner for cancellation, reports results via signals
//  dispatched to the main thread.
// ═══════════════════════════════════════════════════════════════════════════════

public class AudioRunner : Object {

    // ── Configuration ────────────────────────────────────────────────────────
    public string input_file { get; set; default = ""; }
    public string source_codec { get; set; default = ""; }
    public AudioExtractConfig? config { get; set; default = null; }

    // UI references
    public StatusArea? status_area { get; set; default = null; }
    public ProgressBar? progress_bar { get; set; default = null; }
    public ConsoleTab? console_tab { get; set; default = null; }

    // ── Segments ─────────────────────────────────────────────────────────────
    private GenericArray<AudioSegment> segments = new GenericArray<AudioSegment> ();
    private GenericArray<string> output_paths = new GenericArray<string> ();
    private string primary_output_path = "";
    private double total_duration = 0.0;
    private double progress_duration = 0.0;
    private double progress_offset = 0.0;

    // ── State ────────────────────────────────────────────────────────────────
    private ProcessRunner runner = new ProcessRunner ();
    private ProgressTracker? tracker = null;
    private Mutex run_mutex = Mutex ();
    private bool run_active = false;

    // ── Signals ──────────────────────────────────────────────────────────────
    public signal void extract_done (OperationOutputResult output_result);
    public signal void extract_failed (string message);

    // ═════════════════════════════════════════════════════════════════════════
    //  PUBLIC API
    // ═════════════════════════════════════════════════════════════════════════

    public void set_segments (GenericArray<AudioSegment> segs) {
        var snapshot = new GenericArray<AudioSegment> ();
        for (int i = 0; i < segs.length; i++) {
            snapshot.add (segs[i].copy ());
        }
        segments = snapshot;
    }

    public void set_output_paths (GenericArray<string> paths) {
        var snapshot = new GenericArray<string> ();
        for (int i = 0; i < paths.length; i++) {
            snapshot.add (paths[i]);
        }
        output_paths = snapshot;
        if (snapshot.length > 0) {
            primary_output_path = snapshot[0];
        }
    }

    public void set_primary_output (string path) {
        primary_output_path = path;
    }

    public void set_total_duration (double dur) {
        total_duration = dur;
    }

    /**
     * Run the extraction pipeline on a background thread.
     */
    public void run () {
        if (input_file == "" || config == null) {
            report_status ("Please select an input file first!",
                StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
            return;
        }

        if (!try_begin_run ()) {
            warning ("AudioRunner.run() ignored while another execution is already active.");
            return;
        }

        runner.set_event_logger (log_runner_event);
        runner.prepare_for_new_execution ();

        if (progress_bar != null) {
            tracker = new ProgressTracker (progress_bar);
            tracker.reset_throttle ();
            tracker.show_pulse ();
        }

        try {
            new Thread<void>.try ("audio-extract-thread", () => {
                try {
                    run_internal ();
                } finally {
                    finish_progress ();
                    end_run ();
                }
            });
        } catch (Error e) {
            reset_progress ();
            end_run ();
            report_error ("Failed to start audio extraction thread: " + e.message);
        }
    }

    /**
     * Run batch extraction of all audio tracks (copy mode, no segments).
     */
    public void run_extract_all (GenericArray<AudioStreamInfo> tracks,
                                  string output_dir, string base_name,
                                  bool allow_overwrite = false) {
        if (input_file == "" || tracks.length == 0) {
            report_status ("No audio tracks to extract.",
                StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
            return;
        }

        if (!try_begin_run ()) {
            warning ("AudioRunner.run_extract_all() ignored while another execution is active.");
            return;
        }

        runner.set_event_logger (log_runner_event);
        runner.prepare_for_new_execution ();

        if (progress_bar != null) {
            tracker = new ProgressTracker (progress_bar);
            tracker.reset_throttle ();
            tracker.show_pulse ();
        }

        // Snapshot tracks and paths for the background thread
        var track_list = new GenericArray<AudioStreamInfo> ();
        var path_list = new GenericArray<string> ();
        for (int i = 0; i < tracks.length; i++) {
            track_list.add (tracks[i]);
            string ext = AudioBuilder.get_extension_for_codec (tracks[i].codec_name);
            string filename = "%s-track-%s%s".printf (
                base_name,
                ConversionUtils.pad_segment_number (i + 1),
                ext);
            string out_path = Path.build_filename (output_dir, filename);
            if (allow_overwrite) {
                path_list.add (out_path);
            } else {
                string? unique = ConversionUtils.find_unique_path (out_path);
                path_list.add (unique ?? out_path);
            }
        }

        try {
            new Thread<void>.try ("audio-extract-all-thread", () => {
                try {
                    run_extract_all_internal (track_list, path_list);
                } finally {
                    finish_progress ();
                    end_run ();
                }
            });
        } catch (Error e) {
            reset_progress ();
            end_run ();
            report_error ("Failed to start extract-all thread: " + e.message);
        }
    }

    public void cancel () {
        runner.cancel ();
    }

    public bool is_cancelled () {
        return runner.is_cancelled ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Main pipeline
    // ═════════════════════════════════════════════════════════════════════════

    private void run_internal () {
        if (segments.length == 0) {
            // No segments — basic full-file extraction
            run_basic_extract ();
            return;
        }

        if (segments.length == 1 || config.export_separate) {
            run_separate_segments ();
            return;
        }

        // Multi-segment combined
        if (config.copy_mode) {
            run_concat_demuxer ();
        } else {
            run_concat_filter ();
        }
    }

    private void run_basic_extract () {
        if (primary_output_path == "") {
            report_error ("No output path specified.");
            return;
        }

        if (needs_peak_analysis ()) {
            string[] analyze_cmd = AudioBuilder.build_basic_peak_detect_cmd (
                input_file, config, total_duration);
            if (!prepare_peak_normalization (
                "Analyzing audio peak levels…", analyze_cmd)) {
                return;
            }
        }

        report_status ("Extracting audio…",
            StatusIcon.PROGRESS_ICON, StatusIcon.PROGRESS_CSS);
        log_line ("[Audio] Extracting audio from: " + input_file);

        progress_offset = 0.0;
        progress_duration = total_duration;
        refresh_progress_mode ();

        string[] cmd = AudioBuilder.build_basic_extract_cmd (
            input_file, primary_output_path, config, total_duration);

        show_command (cmd);

        int exit_code = runner.execute (cmd, handle_ffmpeg_line);

        if (runner.is_cancelled ()) {
            report_status ("Audio extraction cancelled.",
                StatusIcon.CANCELLED_ICON, StatusIcon.CANCELLED_CSS);
            emit_failed ("Cancelled");
            return;
        }

        if (exit_code != 0) {
            report_error ("Audio extraction failed (exit %d).".printf (exit_code));
            return;
        }

        report_status ("Audio extraction complete!",
            StatusIcon.SUCCESS_ICON, StatusIcon.SUCCESS_CSS);
        emit_done_file (primary_output_path);
    }

    private void run_separate_segments () {
        int total = segments.length;
        var completed_paths = new GenericArray<string> ();

        double seg_total = 0.0;
        for (int i = 0; i < total; i++)
            seg_total += segments[i].get_duration ();
        progress_duration = seg_total;
        progress_offset = 0.0;
        refresh_progress_mode ();

        for (int i = 0; i < total; i++) {
            if (runner.is_cancelled ()) {
                report_status ("Audio extraction cancelled.",
                    StatusIcon.CANCELLED_ICON, StatusIcon.CANCELLED_CSS);
                emit_failed ("Cancelled");
                return;
            }

            var seg = segments[i];
            string out_path = (i < output_paths.length) ? output_paths[i] : primary_output_path;

            report_status ("Extracting segment %d of %d…".printf (i + 1, total),
                StatusIcon.PROGRESS_ICON, StatusIcon.PROGRESS_CSS);
            log_line ("[Audio] Segment %d: %.3f → %.3f".printf (i + 1, seg.start_time, seg.end_time));

            if (needs_peak_analysis ()) {
                string[] analyze_cmd = AudioBuilder.build_segment_peak_detect_cmd (
                    input_file, config, seg.start_time, seg.get_duration ());
                if (!prepare_peak_normalization (
                    "Analyzing audio peak levels for segment %d of %d…".printf (i + 1, total),
                    analyze_cmd)) {
                    return;
                }
            }

            string[] cmd = AudioBuilder.build_segment_extract_cmd (
                input_file, out_path, config,
                seg.start_time, seg.get_duration ());

            show_command (cmd);

            int exit_code = runner.execute (cmd, handle_ffmpeg_line);

            if (runner.is_cancelled ()) {
                report_status ("Audio extraction cancelled.",
                    StatusIcon.CANCELLED_ICON, StatusIcon.CANCELLED_CSS);
                emit_failed ("Cancelled");
                return;
            }

            if (exit_code != 0) {
                report_error ("Segment %d extraction failed (exit %d).".printf (i + 1, exit_code));
                return;
            }

            completed_paths.add (out_path);
            progress_offset += seg.get_duration ();
        }

        string folder = Path.get_dirname (
            completed_paths.length > 0 ? completed_paths[0] : input_file);
        report_status ("Audio extraction complete! (%d segments)".printf (total),
            StatusIcon.SUCCESS_ICON, StatusIcon.SUCCESS_CSS);

        if (completed_paths.length == 1) {
            emit_done_file (completed_paths[0]);
        } else {
            emit_done_multiple (completed_paths, folder);
        }
    }

    private void run_concat_filter () {
        if (primary_output_path == "") {
            report_error ("No output path specified.");
            return;
        }

        report_status ("Extracting and combining %d segments…".printf (segments.length),
            StatusIcon.PROGRESS_ICON, StatusIcon.PROGRESS_CSS);

        double seg_total = 0.0;
        for (int i = 0; i < segments.length; i++)
            seg_total += segments[i].get_duration ();
        progress_offset = 0.0;
        progress_duration = seg_total;
        refresh_progress_mode ();

        if (needs_peak_analysis ()) {
            string[] analyze_cmd = AudioBuilder.build_concat_peak_detect_cmd (
                input_file, config, segments);
            if (!prepare_peak_normalization (
                "Analyzing combined audio peak levels…", analyze_cmd)) {
                return;
            }
        }

        string[] cmd = AudioBuilder.build_concat_filter_cmd (
            input_file, primary_output_path, config, segments);

        show_command (cmd);

        int exit_code = runner.execute (cmd, handle_ffmpeg_line);

        if (runner.is_cancelled ()) {
            report_status ("Audio extraction cancelled.",
                StatusIcon.CANCELLED_ICON, StatusIcon.CANCELLED_CSS);
            emit_failed ("Cancelled");
            return;
        }

        if (exit_code != 0) {
            report_error ("Combined extraction failed (exit %d).".printf (exit_code));
            return;
        }

        report_status ("Audio extraction complete! (combined)",
            StatusIcon.SUCCESS_ICON, StatusIcon.SUCCESS_CSS);
        emit_done_file (primary_output_path);
    }

    private void run_concat_demuxer () {
        if (primary_output_path == "") {
            report_error ("No output path specified.");
            return;
        }

        report_status ("Extracting %d segments for concatenation…".printf (segments.length),
            StatusIcon.PROGRESS_ICON, StatusIcon.PROGRESS_CSS);

        // Create temp directory for intermediate files
        string tmp_dir;
        try {
            tmp_dir = DirUtils.make_tmp ("audio-concat-XXXXXX");
        } catch (Error e) {
            report_error ("Failed to create temp directory: " + e.message);
            return;
        }

        var temp_files = new GenericArray<string> ();

        // Cumulative progress across extraction + concat phases
        double seg_total = 0.0;
        for (int i = 0; i < segments.length; i++)
            seg_total += segments[i].get_duration ();
        progress_duration = seg_total * 2.0;
        progress_offset = 0.0;
        refresh_progress_mode ();

        // Extract each segment to temp file
        for (int i = 0; i < segments.length; i++) {
            if (runner.is_cancelled ()) {
                cleanup_temp_files (temp_files, tmp_dir);
                report_status ("Audio extraction cancelled.",
                    StatusIcon.CANCELLED_ICON, StatusIcon.CANCELLED_CSS);
                emit_failed ("Cancelled");
                return;
            }

            var seg = segments[i];
            string ext = AudioBuilder.get_output_extension (config, source_codec);
            string tmp_path = Path.build_filename (tmp_dir, "seg_%d%s".printf (i, ext));
            temp_files.add (tmp_path);

            report_status ("Extracting segment %d of %d…".printf (i + 1, segments.length),
                StatusIcon.PROGRESS_ICON, StatusIcon.PROGRESS_CSS);

            string[] cmd = AudioBuilder.build_segment_extract_cmd (
                input_file, tmp_path, config,
                seg.start_time, seg.get_duration ());

            show_command (cmd);

            int exit_code = runner.execute (cmd, handle_ffmpeg_line);

            if (runner.is_cancelled () || exit_code != 0) {
                cleanup_temp_files (temp_files, tmp_dir);
                if (runner.is_cancelled ()) {
                    report_status ("Audio extraction cancelled.",
                        StatusIcon.CANCELLED_ICON, StatusIcon.CANCELLED_CSS);
                    emit_failed ("Cancelled");
                } else {
                    report_error ("Segment %d extraction failed (exit %d).".printf (i + 1, exit_code));
                }
                return;
            }

            progress_offset += seg.get_duration ();
        }

        // Write concat list file
        string concat_list_path = Path.build_filename (tmp_dir, "concat_list.txt");
        try {
            var sb = new StringBuilder ();
            for (int i = 0; i < temp_files.length; i++) {
                sb.append ("file '%s'\n".printf (temp_files[i].replace ("'", "'\\''")));
            }
            FileUtils.set_contents (concat_list_path, sb.str);
        } catch (Error e) {
            cleanup_temp_files (temp_files, tmp_dir);
            report_error ("Failed to write concat list: " + e.message);
            return;
        }

        // Run concat demuxer — progress_offset already at seg_total
        report_status ("Concatenating segments…",
            StatusIcon.PROGRESS_ICON, StatusIcon.PROGRESS_CSS);

        string[] concat_cmd = {
            AppSettings.get_default ().ffmpeg_path,
            "-y",
            "-f", "concat",
            "-safe", "0",
            "-i", concat_list_path,
            "-c:a", "copy",
            "-progress", "pipe:2",
            primary_output_path
        };

        if (config != null && config.strip_metadata) {
            concat_cmd = {
                AppSettings.get_default ().ffmpeg_path,
                "-y",
                "-f", "concat",
                "-safe", "0",
                "-i", concat_list_path,
                "-map_metadata", "-1",
                "-c:a", "copy",
                "-progress", "pipe:2",
                primary_output_path
            };
        }

        show_command (concat_cmd);

        int exit_code = runner.execute (concat_cmd, handle_ffmpeg_line);

        cleanup_temp_files (temp_files, tmp_dir);

        if (runner.is_cancelled ()) {
            report_status ("Audio extraction cancelled.",
                StatusIcon.CANCELLED_ICON, StatusIcon.CANCELLED_CSS);
            emit_failed ("Cancelled");
            return;
        }

        if (exit_code != 0) {
            report_error ("Concatenation failed (exit %d).".printf (exit_code));
            return;
        }

        report_status ("Audio extraction complete! (combined)",
            StatusIcon.SUCCESS_ICON, StatusIcon.SUCCESS_CSS);
        emit_done_file (primary_output_path);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Extract all tracks
    // ═════════════════════════════════════════════════════════════════════════

    private void run_extract_all_internal (GenericArray<AudioStreamInfo> tracks,
                                            GenericArray<string> paths) {
        var completed_paths = new GenericArray<string> ();

        progress_duration = total_duration * tracks.length;
        progress_offset = 0.0;
        refresh_progress_mode ();

        for (int i = 0; i < tracks.length; i++) {
            if (runner.is_cancelled ()) {
                report_status ("Extract all cancelled.",
                    StatusIcon.CANCELLED_ICON, StatusIcon.CANCELLED_CSS);
                emit_failed ("Cancelled");
                return;
            }

            report_status ("Extracting track %d of %d…".printf (i + 1, tracks.length),
                StatusIcon.PROGRESS_ICON, StatusIcon.PROGRESS_CSS);

            string[] cmd = AudioBuilder.build_extract_track_cmd (
                input_file, paths[i], tracks[i].audio_index);

            show_command (cmd);

            int exit_code = runner.execute (cmd, handle_ffmpeg_line);

            if (runner.is_cancelled ()) {
                report_status ("Extract all cancelled.",
                    StatusIcon.CANCELLED_ICON, StatusIcon.CANCELLED_CSS);
                emit_failed ("Cancelled");
                return;
            }

            if (exit_code != 0) {
                log_line ("[Audio] Track %d extraction failed (exit %d), skipping."
                    .printf (i + 1, exit_code));
            } else {
                completed_paths.add (paths[i]);
            }

            progress_offset += total_duration;
        }

        if (completed_paths.length == 0) {
            report_error ("All track extractions failed.");
            return;
        }

        string summary = AudioExtractLogic.build_extract_all_summary (
            completed_paths.length,
            tracks.length
        );

        string folder = Path.get_dirname (completed_paths[0]);
        report_status (summary + "!",
            StatusIcon.SUCCESS_ICON, StatusIcon.SUCCESS_CSS);
        emit_done_multiple_with_summary (completed_paths, folder, summary);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Helpers
    // ═════════════════════════════════════════════════════════════════════════

    private void parse_progress (string line) {
        if (tracker == null || progress_duration <= 0.0) return;

        // -progress pipe:2 outputs "out_time_us=<microseconds>" and
        // "out_time=HH:MM:SS.ffffff" as newline-delimited key=value pairs.
        double current_sec = -1.0;

        if (line.has_prefix ("out_time_us=")) {
            string us_str = line.substring ("out_time_us=".length).strip ();
            int64 us = int64.parse (us_str);
            current_sec = us / 1000000.0;
        } else if (line.has_prefix ("out_time=")) {
            string time_str = line.substring ("out_time=".length).strip ();
            current_sec = ConversionUtils.parse_ffmpeg_timestamp (time_str);
        }

        if (current_sec > 0.0) {
            double frac = ((progress_offset + current_sec) / progress_duration).clamp (0.0, 1.0);
            tracker.update_percent (frac * 100.0);
        }
    }

    private void refresh_progress_mode () {
        if (tracker == null) return;

        tracker.reset_throttle ();

        if (progress_duration > 0.0) {
            tracker.show_determinate ();
        } else {
            tracker.show_pulse ();
        }
    }

    private void cleanup_temp_files (GenericArray<string> files, string dir) {
        for (int i = 0; i < files.length; i++) {
            if (FileUtils.unlink (files[i]) != 0) {
                warning ("AudioRunner: failed to remove temp file %s", files[i]);
            }
        }
        // Try to remove concat list and directory
        string concat_list = Path.build_filename (dir, "concat_list.txt");
        if (FileUtils.unlink (concat_list) != 0) {
            warning ("AudioRunner: failed to remove concat list %s", concat_list);
        }
        if (DirUtils.remove (dir) != 0) {
            warning ("AudioRunner: failed to remove temp directory %s", dir);
        }
    }

    private bool needs_peak_analysis () {
        return config != null
            && !config.copy_mode
            && ConversionUtils.audio_processing_needs_peak_analysis (config.processing);
    }

    private bool prepare_peak_normalization (string status_message,
                                             string[] analyze_cmd) {
        if (config == null) {
            report_error ("Audio extraction configuration is missing.");
            return false;
        }

        config.peak_normalize_gain_db = 0.0;

        report_status (status_message,
            StatusIcon.PROGRESS_ICON, StatusIcon.PROGRESS_CSS);
        show_command (analyze_cmd);

        double max_volume_db = 0.0;
        bool found_max_volume = false;

        int exit_code = runner.execute (analyze_cmd, (line) => {
            double parsed_max = 0.0;
            if (ConversionUtils.try_parse_max_volume_db (line, out parsed_max)) {
                max_volume_db = parsed_max;
                found_max_volume = true;
            }

            if (ConversionUtils.should_log_ffmpeg_line (line)) {
                log_line (line);
            }
        });

        if (runner.is_cancelled ()) {
            report_status ("Audio extraction cancelled.",
                StatusIcon.CANCELLED_ICON, StatusIcon.CANCELLED_CSS);
            emit_failed ("Cancelled");
            return false;
        }

        if (exit_code != 0) {
            report_error ("Peak normalization analysis failed (exit %d).".printf (exit_code));
            return false;
        }

        if (!found_max_volume) {
            report_error ("Peak normalization analysis did not report a max volume.");
            return false;
        }

        config.peak_normalize_gain_db = ConversionUtils.compute_peak_normalize_gain_db (max_volume_db);
        log_line ("[Audio] Peak normalization target %.2f dBFS, measured %.2f dBFS, gain %.2f dB"
            .printf (ConversionUtils.PEAK_NORMALIZE_TARGET_DB, max_volume_db, config.peak_normalize_gain_db));
        return true;
    }

    private bool try_begin_run () {
        bool can_start = false;
        run_mutex.lock ();
        try {
            if (!run_active) {
                run_active = true;
                can_start = true;
            }
        } finally {
            run_mutex.unlock ();
        }
        return can_start;
    }

    private void end_run () {
        run_mutex.lock ();
        try {
            run_active = false;
        } finally {
            run_mutex.unlock ();
        }
    }

    private void finish_progress () {
        if (tracker == null) return;

        if (runner.is_cancelled ()) {
            tracker.hide_cancelled ();
        } else {
            tracker.hide ();
        }
    }

    private void reset_progress () {
        if (progress_bar == null) return;

        Idle.add (() => {
            progress_bar.set_visible (false);
            progress_bar.set_fraction (0.0);
            progress_bar.set_text ("Waiting...");
            return Source.REMOVE;
        });
    }

    private void handle_ffmpeg_line (string line) {
        parse_progress (line);
        if (ConversionUtils.should_log_ffmpeg_line (line)) {
            log_line (line);
        }
    }

    private void show_command (string[] cmd) {
        string full_cmd = ConversionUtils.format_command_for_display (cmd);
        log_line ("[Audio] " + full_cmd);
        if (console_tab != null) {
            Idle.add (() => {
                console_tab.set_command (full_cmd);
                return Source.REMOVE;
            });
        }
    }

    private void log_line (string text) {
        if (console_tab != null) {
            Idle.add (() => {
                console_tab.add_line (text);
                return Source.REMOVE;
            });
        }
    }

    private void log_runner_event (string text) {
        log_line (text);
    }

    private void report_status (string text, string icon, string css) {
        if (status_area != null) {
            status_area.set_status (text, icon, css);
        }
    }

    private void report_error (string message) {
        report_status (message, StatusIcon.ERROR_ICON, StatusIcon.ERROR_CSS);
        log_line ("[Audio] ERROR: " + message);
        emit_failed (message);
    }

    private void emit_done_file (string path) {
        var result = new OperationOutputResult.for_file (path);
        Idle.add (() => {
            extract_done (result);
            return Source.REMOVE;
        });
    }

    private void emit_done_multiple (GenericArray<string> paths, string folder) {
        string[] path_arr = OperationOutputResult.copy_paths (paths);
        var result = OperationOutputResult.from_paths ((owned) path_arr, folder);
        Idle.add (() => {
            extract_done (result);
            return Source.REMOVE;
        });
    }

    private void emit_done_multiple_with_summary (GenericArray<string> paths,
                                                   string folder,
                                                   string summary) {
        string[] path_arr = OperationOutputResult.copy_paths (paths);
        var result = OperationOutputResult.from_paths ((owned) path_arr, folder);
        result.summary = summary;
        Idle.add (() => {
            extract_done (result);
            return Source.REMOVE;
        });
    }

    private void emit_failed (string message) {
        Idle.add (() => {
            extract_failed (message);
            return Source.REMOVE;
        });
    }
}
