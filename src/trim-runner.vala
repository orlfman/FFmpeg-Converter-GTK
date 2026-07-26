using Gtk;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  TrimRunner — Multi-segment FFmpeg extraction and concatenation
//
//  Three pipeline paths depending on configuration:
//
//  PATH A — Concat Filter (re-encode + multi-segment + combined output):
//    Single FFmpeg command using -filter_complex with the concat filter.
//    Each segment is opened as a separate input with -ss/-t seeking.
//    Per-segment crop and General-tab filters are applied in the filter graph.
//    The concat filter merges all segments, properly resetting timestamps
//    and handling resolution/pixel-format differences between segments.
//    This eliminates frame timing issues, PTS discontinuities, B-frame
//    problems, and resolution mismatch corruption at segment boundaries.
//
//  PATH B — Individual Extract + Demuxer Concat (copy mode, multi-segment):
//    Each segment is extracted via stream-copy into temp files, then the
//    concat demuxer (-f concat -c copy) joins them byte-level.
//
//  PATH C — Individual Extract (single segment, or export-separate):
//    Each segment is extracted individually to its final output path.
//
//  Supports both stream-copy and re-encode modes.
//  In re-encode mode, applies the chosen codec + GeneralTab filters.
// ═══════════════════════════════════════════════════════════════════════════════

public class TrimRunner : Object {
    private const int PEAK_ANALYSIS_FAILED_EXIT = -10001;

    // ── Configuration (set before calling run) ──────────────────────────────
    public string input_file { get; set; }
    public string output_folder { get; set; }
    public bool copy_mode { get; set; default = true; }
    public bool keyframe_cut { get; set; default = true; }
    public bool export_separate { get; set; default = false; }
    public string output_suffix { get; set; default = "-trimmed"; }
    public string primary_output_path { get; set; default = ""; }
    public string operation_label { get; set; default = "Trim export"; }
    public int video_width { get; set; default = 0; }
    public int video_height { get; set; default = 0; }

    // Re-encode snapshot (only used when some path needs encoding)
    public EncodeProfileSnapshot? reencode_profile { get; set; default = null; }

    // UI references
    public StatusArea? status_area { get; set; default = null; }
    public ProgressBar? progress_bar { get; set; default = null; }
    public ConsoleTab? console_tab { get; set; default = null; }

    // ── Segments ────────────────────────────────────────────────────────────
    private GenericArray<TrimSegment> segments = new GenericArray<TrimSegment> ();
    private GenericArray<string> separate_output_paths = new GenericArray<string> ();

    // ── Per-segment Smart Optimizer codec overrides ──────────────────────
    // When non-null, per_segment_codec_args[i] contains FFmpeg video codec
    // arguments for segment i, overriding the shared re-encode profile. Built by
    // TrimTab's per-segment Smart Optimizer pipeline.
    private GenericArray<SegmentCodecArgs>? per_segment_codec_args = null;

    // ── Shared process runner (thread-safe cancel/PID/kill) ─────────────────
    private ProcessRunner runner = new ProcessRunner ();

    // ── Progress tracker (fix #3: consistent with Converter) ────────────────
    private ProgressTracker? tracker = null;
    private string[]? resolved_reencode_codec_args = null;
    private Mutex run_mutex = Mutex ();
    private bool run_active = false;

    private string last_output = "";
    // Set when the user cancelled during the optional post-encode collage
    // pass while the primary output was already on disk. Mirrors
    // ConversionRunner's "completed with notice" handling and tells
    // finish_progress to fade like a normal completion instead of flashing
    // "Cancelled".
    private bool collage_cancellation_consumed = false;
#if TRIM_SUBTITLES_STATE_TEST_BUILD
    private string[] last_ffmpeg_argv_for_test = {};
#endif

    private void log_runner_event (string text) {
        if (console_tab != null) {
            Idle.add (() => {
                console_tab.add_line (text);
                return Source.REMOVE;
            });
        }
    }

    // ── Signal ──────────────────────────────────────────────────────────────
    public signal void export_done (OperationOutputResult output_result);
    public signal void export_cancelled (string cancel_message);
    public signal void export_failed (string message);

    // ═════════════════════════════════════════════════════════════════════════
    //  PUBLIC API
    // ═════════════════════════════════════════════════════════════════════════

    public void set_segments (GenericArray<TrimSegment> segs) {
        segments = segs;
    }

    public void set_separate_output_paths (GenericArray<string> paths) {
        separate_output_paths = paths;
    }

    /**
     * Set per-segment Smart Optimizer codec overrides.
     * When set, segment i uses per_segment_codec_args[i] instead of
     * the shared re-encode profile for its video codec arguments.
     */
    public void set_per_segment_codec_args (GenericArray<SegmentCodecArgs>? args) {
        per_segment_codec_args = args;
    }

    /**
     * Run the full trim/export pipeline on a background thread.
     * Safe to call from the main thread — starts its own Thread.
     */
    public void run () {
        if (segments.length == 0) {
            report_status ("No segments defined — add at least one segment.",
                StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
            return;
        }
        if (input_file == null || input_file == "") {
            report_status ("Please select an input file first!",
                StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
            return;
        }
        if (!try_begin_run ()) {
            warning ("TrimRunner.run() ignored while another execution is already active.");
            log_line ("⚠️ Ignored duplicate trim export request while another export is already running.");
            return;
        }

        runner.set_event_logger (log_runner_event);
        runner.prepare_for_new_execution ();

        resolved_reencode_codec_args = null;
        collage_cancellation_consumed = false;

        // Fix #3: Create a ProgressTracker for consistent progress behavior
        if (progress_bar != null) {
            tracker = new ProgressTracker (progress_bar);
            tracker.reset_throttle ();
            tracker.show_determinate ();
        }

        try {
            new Thread<void>.try ("trim-export-thread", () => {
                try {
                    run_internal ();
                } finally {
                    finish_progress ();
                    end_run ();
                }
            });
        } catch (Error e) {
            reset_progress_display ();
            end_run ();
            report_error ("Failed to start trim export thread: " + e.message);
        }
    }

    /**
     * Cancel any running FFmpeg process.
     * Thread-safe — delegates to ProcessRunner which uses proper
     * mutex-guarded PID tracking and Posix.kill() return-value checking.
     */
    public void cancel () {
        runner.cancel ();
    }

    public bool is_cancelled () {
        return runner.is_cancelled ();
    }

    public string get_cancel_completion_message () {
        return runner.get_cancel_completion_message ();
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

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Main pipeline
    // ═════════════════════════════════════════════════════════════════════════

    private void run_internal () {
        string basename = Path.get_basename (input_file);
        int dot = basename.last_index_of_char ('.');
        string name_no_ext = (dot > 0) ? basename.substring (0, dot) : basename;
        string input_ext = (dot > 0) ? basename.substring (dot) : ".mkv";

        // Determine output extension
        string out_ext = determine_extension (input_ext);

        string out_dir = (output_folder != null && output_folder != "")
            ? output_folder
            : Path.get_dirname (input_file);

        // Ensure the output directory exists — handles volatile paths
        // (e.g. /tmp/work) or directories deleted between sessions.
        if (!FileUtils.test (out_dir, FileTest.IS_DIR)) {
            if (DirUtils.create_with_parents (out_dir, 0755) == 0) {
                message ("TrimRunner: Created missing output directory: %s", out_dir);
            } else {
                warning ("TrimRunner: Could not create output directory %s: %s",
                         out_dir, strerror (errno));
            }
        }

        string primary_output = primary_output_path;
        if (primary_output == null || primary_output == "") {
            primary_output = Path.build_filename (
                out_dir, @"$name_no_ext$(output_suffix)$out_ext"
            );
        }

        // Temp segment files should match the resolved target container, not
        // just the initially computed extension, so concat paths stay aligned
        // with the actual output plan after rename/policy resolution.
        string runtime_out_ext = path_extension_or_fallback (primary_output, out_ext);
        if (export_separate && separate_output_paths.length > 0) {
            runtime_out_ext = path_extension_or_fallback (
                separate_output_paths[0], out_ext);
        }

        // ── PATH A: Concat filter (re-encode + multi-segment + combined) ─────
        // This is the most robust path: a single FFmpeg command that decodes
        // all segments, applies per-segment filters, and encodes once.
        // Note: audio copy is disabled in the UI when this path is active
        // (via AudioSettings.update_for_concat_filter), since -filter_complex
        // decodes audio and makes stream-copy impossible.
        bool use_concat_filter = !copy_mode && !export_separate && segments.length > 1;

        if (use_concat_filter) {
            string output_path = primary_output;

            report_status (@"$(operation_label) — encoding $(segments.length) segments…",
                StatusIcon.PROGRESS_ICON, StatusIcon.PROGRESS_CSS);
            update_progress (10.0);

            if (!prepare_peak_normalization_for_concat ()) {
                if (runner.is_cancelled ()) {
                    report_cancelled ();
                }
                return;
            }

            int exit = run_concat_filter_encode (output_path);
            if (exit != 0) {
                if (runner.is_cancelled ()) {
                    report_cancelled ();
                } else {
                    report_error (@"$(operation_label) failed (exit code $exit).");
                }
            } else {
                last_output = output_path;
                var primary_outputs = new GenericArray<string> ();
                primary_outputs.add (output_path);
                complete_export_success (primary_outputs, out_dir, false);
            }

            return;
        }

        // ── PATH B & C: Individual extraction (copy mode, separate, or single) ─
        // Create temp directory
        string tmp_dir;
        try {
            tmp_dir = DirUtils.make_tmp ("ffmpeg-trim-XXXXXX");
        } catch (Error e) {
            report_error ("Failed to create temp directory: " + e.message);
            return;
        }

        try {
            // ── Phase 1: Extract each segment ────────────────────────────────
            var segment_files = new GenericArray<string> ();

            for (int i = 0; i < segments.length; i++) {
                if (runner.is_cancelled ()) {
                    report_cancelled ();
                    return;
                }

                var seg = segments[i];
                // Use chapter label for status messages when available
                string seg_label;
                if (seg.label != null && seg.label.strip ().length > 0) {
                    seg_label = "\"%s\" (%d/%d)".printf (seg.label, i + 1, segments.length);
                } else {
                    seg_label = "Segment %d/%d".printf (i + 1, segments.length);
                }

                // For single-segment non-separate exports, write directly to
                // final output path (avoids an unnecessary concat pass)
                bool direct_output = !export_separate && segments.length == 1;

                string seg_output;
                if (export_separate) {
                    seg_output = (i < separate_output_paths.length)
                        ? separate_output_paths[i]
                        : Path.build_filename (
                            out_dir,
                            @"$name_no_ext-segment-$(pad_number (i + 1))$out_ext"
                        );
                } else if (direct_output) {
                    seg_output = primary_output;
                } else {
                    seg_output = Path.build_filename (
                        tmp_dir,
                        @"segment_$(pad_number (i + 1))$runtime_out_ext"
                    );
                }

                report_status (@"Extracting $seg_label…",
                    StatusIcon.PROGRESS_ICON, StatusIcon.PROGRESS_CSS);
                update_progress ((double) i / segments.length * 100.0);

                int exit = extract_segment (i, seg, seg_output);
                if (exit != 0) {
                    if (runner.is_cancelled ()) {
                        report_cancelled ();
                    } else if (exit == PEAK_ANALYSIS_FAILED_EXIT) {
                        return;
                    } else {
                        report_error (@"$seg_label extraction failed (exit code $exit).");
                    }
                    return;
                }

                segment_files.add (seg_output);
                log_line (@"✅ $seg_label extracted → $seg_output");
            }

            // ── Phase 2: Concatenate (copy-mode multi-segment only) ──────────
            var final_outputs = new GenericArray<string> ();
            bool separate_export_completed = false;

            if (export_separate && segment_files.length == 1) {
                last_output = segment_files[0];
                final_outputs.add (segment_files[0]);
            } else if (export_separate) {
                last_output = segment_files[0];
                for (int i = 0; i < segment_files.length; i++) {
                    final_outputs.add (segment_files[i]);
                }
                separate_export_completed = true;
            } else if (segments.length == 1) {
                // Single segment was written directly to the output path
                last_output = segment_files[0];
                final_outputs.add (segment_files[0]);
            } else {
                // Multi-segment copy mode → demuxer concat
                if (runner.is_cancelled ()) {
                    report_cancelled ();
                    return;
                }

                string concat_output = primary_output;
                last_output = concat_output;

                report_status ("Concatenating segments…",
                    StatusIcon.PROGRESS_ICON, StatusIcon.PROGRESS_CSS);
                update_progress (90.0);

                int concat_exit = concat_demuxer (segment_files, tmp_dir, concat_output);
                if (concat_exit != 0) {
                    if (runner.is_cancelled ()) {
                        report_cancelled ();
                    } else {
                        report_error ("Concatenation failed (exit code %d).".printf (concat_exit));
                    }
                    return;
                }

                final_outputs.add (concat_output);
            }

            complete_export_success (final_outputs, out_dir, separate_export_completed);

        } finally {
            if (!export_separate) {
                cleanup_dir (tmp_dir);
            } else {
                DirUtils.remove (tmp_dir);
            }

        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PATH A — Single-pass concat filter encode
    // ═════════════════════════════════════════════════════════════════════════

    private int run_concat_filter_encode (string output) {
        string[] cmd = { AppSettings.get_default ().ffmpeg_path, "-y" };

        // ── Add each segment as a separate input with seeking ────────────────
        for (int i = 0; i < segments.length; i++) {
            var seg = segments[i];
            cmd += "-ss";
            cmd += format_seconds (seg.start_time);
            cmd += "-t";
            cmd += format_seconds (seg.end_time - seg.start_time);
            cmd += "-i";
            cmd += input_file;
        }

        // ── Determine if audio is disabled ───────────────────────────────────
        string[] raw_audio_args = get_audio_args ();
        bool audio_disabled = (raw_audio_args.length > 0 && raw_audio_args[0] == "-an");

        // ── Determine target resolution for concat normalization ─────────────
        int target_w = 0;
        int target_h = 0;
        bool needs_scale_normalize = false;

        int[] seg_widths  = new int[segments.length];
        int[] seg_heights = new int[segments.length];

        for (int i = 0; i < segments.length; i++) {
            parse_segment_output_size (segments[i], out seg_widths[i], out seg_heights[i]);
        }

        target_w = seg_widths[0];
        target_h = seg_heights[0];

        for (int i = 1; i < segments.length; i++) {
            if (seg_widths[i] != target_w || seg_heights[i] != target_h) {
                needs_scale_normalize = true;
                break;
            }
        }

        if (needs_scale_normalize && target_w > 0 && target_h > 0) {
            log_line ("📐 Normalizing all segments to %d×%d (first segment's dimensions)".printf (target_w, target_h));
        }

        // ── Build filter_complex ─────────────────────────────────────────────
        var fc = new StringBuilder ();

        AudioProcessingSettingsSnapshot processing = get_audio_processing_settings ();
        bool normalize_after_concat = processing.normalize_enabled && processing.normalize_ebu;

        for (int i = 0; i < segments.length; i++) {
            var seg = segments[i];

            string vf = build_segment_vf (seg);

            if (needs_scale_normalize && target_w > 0 && target_h > 0) {
                string scale_filter = "scale=%d:%d:force_original_aspect_ratio=decrease,setsar=1,pad=%d:%d:-1:-1:color=black".printf (
                    target_w, target_h, target_w, target_h);
                if (vf.length > 0) {
                    vf += "," + scale_filter;
                } else {
                    vf = scale_filter;
                }
            }

            if (vf.length > 0) {
                vf += ",setpts=PTS-STARTPTS";
            } else {
                vf = "setpts=PTS-STARTPTS";
            }

            fc.append (@"[$i:v]$(vf)[v$i]; ");

            if (!audio_disabled) {
                string af = build_audio_filters_for_segment (
                    seg.end_time - seg.start_time,
                    i == 0,
                    i == segments.length - 1,
                    !normalize_after_concat
                );
                if (af.length > 0) {
                    af += ",asetpts=PTS-STARTPTS";
                } else {
                    af = "asetpts=PTS-STARTPTS";
                }

                fc.append (@"[$i:a]$(af)[a$i]; ");
            }
        }

        // ── Concat filter ────────────────────────────────────────────────────
        for (int i = 0; i < segments.length; i++) {
            fc.append (@"[v$i]");
            if (!audio_disabled) {
                fc.append (@"[a$i]");
            }
        }

        int a_streams = audio_disabled ? 0 : 1;
        if (!audio_disabled && normalize_after_concat) {
            fc.append (@"concat=n=$(segments.length):v=1:a=$a_streams[outv][concata]");
            fc.append ("[concata]%s[outa]".printf (AudioNormalization.EBU_R128_FILTER));
        } else {
            fc.append (@"concat=n=$(segments.length):v=1:a=$a_streams[outv]");
            if (!audio_disabled) {
                fc.append ("[outa]");
            }
        }

        // ── Image watermark overlay (post-concat) ───────────────────────────
        bool has_image_watermark = is_trim_image_watermark_active ();
        if (has_image_watermark) {
            int wm_input_index = segments.length;  // watermark is the last input
            cmd += "-i";
            cmd += reencode_profile.watermark_image_path;

            // Rename [outv] -> [outv_pre], then overlay -> [outv]
            string fc_str = fc.str;
            fc_str = fc_str.replace ("[outv]", "[outv_pre]");
            fc = new StringBuilder ();
            fc.append (fc_str);
            fc.append ("; ");
            fc.append (FilterBuilder.build_image_overlay_fragment (
                @"[$wm_input_index:v]", "[outv_pre]", "[outv]",
                reencode_profile.watermark_position,
                reencode_profile.watermark_margin,
                reencode_profile.watermark_opacity,
                reencode_profile.watermark_image_width));
        }

        cmd += "-filter_complex";
        cmd += fc.str;

        cmd += "-map";
        cmd += "[outv]";
        if (!audio_disabled) {
            cmd += "-map";
            cmd += "[outa]";
        }

        // ── Video codec args ─────────────────────────────────────────────────
        string[] codec_args = get_reencode_codec_args ();
        if (codec_args.length > 0) {
            foreach (string arg in codec_args) cmd += arg;
        } else {
            log_line ("⚠️ No codec builder set — using fallback: libx264 crf 18 medium");
            cmd += "-c:v";
            cmd += "libx264";
            cmd += "-crf";
            cmd += "18";
            cmd += "-preset";
            cmd += "medium";
        }

        // ── Audio codec args ─────────────────────────────────────────────────
        if (audio_disabled) {
            cmd += "-an";
        } else {
            string[] audio_codec = get_audio_codec_args_for_concat ();
            foreach (string a in audio_codec) cmd += a;
        }

        // ── Metadata ─────────────────────────────────────────────────────────
        cmd += "-map_metadata";
        cmd += should_preserve_metadata () ? "0" : "-1";
        if (should_remove_chapters ()) {
            cmd += "-map_chapters";
            cmd += "-1";
        }

        cmd += "-progress";
        cmd += "pipe:2";
        cmd += output;

        log_line (@"🎬 Using concat filter for $(segments.length) segments (single-pass encode)");
        return execute_ffmpeg (cmd);
    }

    private bool needs_peak_analysis () {
        string[] audio_args = get_audio_args ();
        if (audio_args.length > 0 && audio_args[0] == "-an") {
            return false;
        }

        return reencode_profile != null
            && ConversionUtils.audio_processing_needs_peak_analysis (
                reencode_profile.audio_processing);
    }

    private bool prepare_peak_normalization_for_concat () {
        if (!needs_peak_analysis () || reencode_profile == null) {
            return true;
        }

        reencode_profile.audio_processing.peak_normalize_gain_db = 0.0;
        report_status ("Analyzing audio peak for normalization...",
            StatusIcon.PROGRESS_ICON, StatusIcon.PROGRESS_CSS);

        string[] input_args = {};
        var fc = new StringBuilder ();

        for (int i = 0; i < segments.length; i++) {
            var seg = segments[i];
            string duration_text = ConversionUtils.format_ffmpeg_double (
                seg.get_duration (), "%.6f");
            string start_text = ConversionUtils.format_ffmpeg_double (
                seg.start_time, "%.6f");

            input_args += "-ss";
            input_args += start_text;
            input_args += "-t";
            input_args += duration_text;
            input_args += "-i";
            input_args += input_file;

            string filters = build_audio_filters_for_segment (
                seg.get_duration (),
                i == 0,
                i == segments.length - 1,
                false
            );

            if (filters.length > 0) {
                fc.append ("[%d:a]%s,asetpts=PTS-STARTPTS[a%d]; ".printf (
                    i, filters, i));
            } else {
                fc.append ("[%d:a]asetpts=PTS-STARTPTS[a%d]; ".printf (i, i));
            }
        }

        for (int i = 0; i < segments.length; i++) {
            fc.append ("[a%d]".printf (i));
        }
        fc.append ("concat=n=%d:v=0:a=1[concat]; ".printf (segments.length));
        fc.append ("[concat]%s[out]".printf (
            FilterBuilder.append_volumedetect ("")
        ));

        string[] cmd = FilterBuilder.build_filter_complex_peak_detect_cmd (
            input_args,
            fc.str,
            "[out]",
            FilterBuilder.extract_peak_analysis_output_args (
                get_audio_codec_args_for_concat ())
        );

        return execute_peak_analysis (cmd);
    }

    private bool prepare_peak_normalization_for_segment (TrimSegment seg,
                                                         bool apply_fade_in = true,
                                                         bool apply_fade_out = true) {
        if (!needs_peak_analysis () || reencode_profile == null) {
            return true;
        }

        reencode_profile.audio_processing.peak_normalize_gain_db = 0.0;
        report_status ("Analyzing audio peak for normalization...",
            StatusIcon.PROGRESS_ICON, StatusIcon.PROGRESS_CSS);

        string[] cmd = build_peak_detect_cmd_for_segment (
            seg, apply_fade_in, apply_fade_out);

        return execute_peak_analysis (cmd);
    }

    private string[] build_peak_detect_cmd_for_segment (TrimSegment seg,
                                                        bool apply_fade_in = true,
                                                        bool apply_fade_out = true) {
        string[] pre_input_args = {
            "-ss", format_seconds (seg.start_time)
        };
        string[] post_input_args = {
            "-t", format_seconds (seg.end_time - seg.start_time)
        };
        string filter_chain = build_audio_filters_for_segment (
            seg.end_time - seg.start_time,
            apply_fade_in,
            apply_fade_out,
            false
        );
        return FilterBuilder.build_audio_peak_detect_cmd (
            input_file,
            filter_chain,
            pre_input_args,
            post_input_args,
            FilterBuilder.extract_peak_analysis_output_args (get_audio_args ()),
            "0:a:0?"
        );
    }

    private bool execute_peak_analysis (string[] cmd) {
        string full_cmd = ConversionUtils.format_command_for_display (cmd);
        log_line ("\n=== Peak Normalization Analysis ===\n" + full_cmd);
        if (console_tab != null) {
            console_tab.set_command (full_cmd);
        }
#if TRIM_SUBTITLES_STATE_TEST_BUILD
        last_ffmpeg_argv_for_test = {};
#endif

        double max_volume_db = 0.0;
        bool found_max_volume = false;
        int exit = runner.execute (cmd, (clean) => {
            double parsed_max = 0.0;
            if (ConversionUtils.try_parse_max_volume_db (clean, out parsed_max)) {
                max_volume_db = parsed_max;
                found_max_volume = true;
            }

            if (ConversionUtils.should_log_ffmpeg_line (clean)) {
                log_line (clean);
            }
        });

        if (runner.is_cancelled ()) {
            return false;
        }

        if (exit != 0) {
            report_error ("Peak normalization analysis failed.");
            return false;
        }

        if (!found_max_volume || reencode_profile == null) {
            report_error ("Peak normalization analysis did not report a max volume.");
            return false;
        }

        reencode_profile.audio_processing.peak_normalize_gain_db =
            ConversionUtils.compute_peak_normalize_gain_db (max_volume_db);
        log_line ("[Audio] Peak normalization target %.2f dBFS, measured %.2f dBFS, gain %.2f dB"
            .printf (
                ConversionUtils.PEAK_NORMALIZE_TARGET_DB,
                max_volume_db,
                reencode_profile.audio_processing.peak_normalize_gain_db
            ));
        return true;
    }

    private string[] get_audio_codec_args_for_concat () {
        string[] audio_args = get_audio_args ();

        if (audio_args.length >= 2 && audio_args[0] == "-c:a" && audio_args[1] == "copy") {
            string container = (reencode_profile != null)
                ? reencode_profile.container : ContainerExt.MKV;

            if (container == ContainerExt.WEBM) {
                return { "-c:a", "libopus", "-b:a", "128k" };
            }
            return { "-c:a", "aac", "-b:a", "192k" };
        }

        string[] result = {};
        for (int i = 0; i < audio_args.length; i++) {
            if (audio_args[i] == "-af" && i + 1 < audio_args.length) {
                i++;  // skip -af and its value
            } else {
                result += audio_args[i];
            }
        }

        return result;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PATH B/C — Individual segment extraction
    // ═════════════════════════════════════════════════════════════════════════

    private int extract_segment (int seg_index, TrimSegment seg, string output) {
        string[] cmd = { AppSettings.get_default ().ffmpeg_path, "-y" };
        string? deferred_to = null;

        bool seg_has_crop = seg.has_crop ();
        bool seg_reencode = !copy_mode || seg_has_crop;

        // When copy mode with keyframe cut enabled (default), place -ss before
        // -i for fast input-level seeking (snaps to nearest keyframe).
        // When keyframe cut is disabled, place -ss after -i for precise
        // timestamp positioning (slower, reads from beginning).
        bool input_seeking = !seg_reencode && keyframe_cut;

        if (input_seeking) {
            // Input seeking: -ss before -i, duration-based -to
            cmd += "-ss";
            cmd += format_seconds (seg.start_time);
            cmd += "-i";
            cmd += input_file;
            cmd += "-to";
            cmd += format_seconds (seg.end_time - seg.start_time);
        } else if (!seg_reencode) {
            // Copy mode with precise cut: -ss after -i, absolute -to
            cmd += "-i";
            cmd += input_file;
            cmd += "-ss";
            cmd += format_seconds (seg.start_time);
            cmd += "-to";
            cmd += format_seconds (seg.end_time);
        } else {
            // Re-encode: input seeking is fine (will decode anyway)
            cmd += "-ss";
            cmd += format_seconds (seg.start_time);
            cmd += "-i";
            cmd += input_file;
            // Defer -to until after all inputs so it keeps applying to the
            // trimmed video even when image watermarking adds a second -i.
            deferred_to = format_seconds (seg.end_time - seg.start_time);
        }

        if (!seg_reencode) {
            cmd += "-c:v";
            cmd += "copy";
            cmd += "-c:a";
            cmd += "copy";
        } else {
            if (!prepare_peak_normalization_for_segment (seg)) {
                return runner.is_cancelled () ? 1 : PEAK_ANALYSIS_FAILED_EXIT;
            }

            string vf = build_segment_vf (seg);
            bool seg_image_wm = is_trim_image_watermark_active ();

            if (seg_image_wm) {
                cmd += "-i";
                cmd += reencode_profile.watermark_image_path;

                string fc;
                if (vf.length > 0) {
                    fc = "[0:v]" + vf + "[vf_out]; ";
                    fc += FilterBuilder.build_image_overlay_fragment (
                        "[1:v]", "[vf_out]", "[outv]",
                        reencode_profile.watermark_position,
                        reencode_profile.watermark_margin,
                        reencode_profile.watermark_opacity,
                        reencode_profile.watermark_image_width);
                } else {
                    fc = FilterBuilder.build_image_overlay_fragment (
                        "[1:v]", "[0:v]", "[outv]",
                        reencode_profile.watermark_position,
                        reencode_profile.watermark_margin,
                        reencode_profile.watermark_opacity,
                        reencode_profile.watermark_image_width);
                }

                cmd += "-filter_complex";
                cmd += fc;
                cmd += "-map";
                cmd += "[outv]";

                string[] raw_audio = get_audio_args ();
                bool audio_disabled = raw_audio.length > 0 && raw_audio[0] == "-an";
                if (!audio_disabled) {
                    cmd += "-map";
                    cmd += "0:a:0?";
                }
            } else if (vf != "") {
                cmd += "-vf";
                cmd += vf;
            }

            if (deferred_to != null) {
                cmd += "-to";
                cmd += deferred_to;
            }

            // ── Video codec args: per-segment Smart Optimizer or shared builder ──
            bool used_smart_args = false;
            if (per_segment_codec_args != null
                && seg_index >= 0
                && seg_index < per_segment_codec_args.length) {
                var smart = per_segment_codec_args[seg_index];
                if (smart != null && !smart.is_empty ()) {
                    foreach (string arg in smart.args) cmd += arg;
                    used_smart_args = true;
                    log_line ("🧠 Segment %d: using Smart Optimizer codec args".printf (seg_index + 1));
                }
            }

            if (!used_smart_args) {
                string[] codec_args = get_reencode_codec_args ();
                if (codec_args.length > 0) {
                    foreach (string arg in codec_args) cmd += arg;
                } else {
                    log_line ("⚠️ No codec builder set — using fallback: libx264 crf 18 medium");
                    cmd += "-c:v";
                    cmd += "libx264";
                    cmd += "-crf";
                    cmd += "18";
                    cmd += "-preset";
                    cmd += "medium";
                }
            }

            string af = build_audio_filters_for_segment (seg.end_time - seg.start_time);
            string[] audio_args = get_audio_args_with_filters (af);
            foreach (string a in audio_args) cmd += a;

            cmd += "-map_metadata";
            cmd += should_preserve_metadata () ? "0" : "-1";
            if (should_remove_chapters ()) {
                cmd += "-map_chapters";
                cmd += "-1";
            }
        }

        cmd += "-progress";
        cmd += "pipe:2";
        cmd += output;

        return execute_ffmpeg (cmd);
    }

    /**
     * A segment's video chain differs from the General tab's in two ways that
     * both land on logo removal, so the chain is reassembled around it rather
     * than taken pre-rendered.
     *
     * Position: the segment's own crop has to follow delogo, whose rectangles
     * are source-frame. Cropping first moves the frame out from under them, and
     * delogo blurs whatever now sits at those coordinates while the watermark
     * survives untouched.
     *
     * Time: a segment is decoded with -ss ahead of -i, so its frames arrive
     * with timestamps starting near zero. A timed region's interval is on the
     * source timeline, so it is shifted back by the segment's start.
     */
    private string build_segment_vf (TrimSegment seg) {
        if (reencode_profile == null) {
            return seg.has_crop () ? "crop=" + strip_crop_prefix (seg.crop_value) : "";
        }

        return FilterBuilder.build_video_filter_chain_for_segment (
            reencode_profile,
            seg.start_time,
            seg.has_crop () ? seg.crop_value : null,
            seg.get_duration ());
    }

    private string strip_crop_prefix (string crop_value) {
        string c = crop_value.strip ();
        return c.has_prefix ("crop=") ? c.substring (5) : c;
    }

    private void parse_segment_output_size (TrimSegment seg, out int w, out int h) {
        w = video_width;
        h = video_height;

        if (!seg.has_crop ()) return;

        string c = seg.crop_value.strip ();
        if (c.has_prefix ("crop=")) c = c.substring (5);

        string[] parts = c.split (":");
        if (parts.length >= 2) {
            w = int.parse (parts[0]);
            h = int.parse (parts[1]);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PATH B — Demuxer concat (copy-mode multi-segment)
    // ═════════════════════════════════════════════════════════════════════════

    private int concat_demuxer (GenericArray<string> segment_files,
                                string tmp_dir,
                                string output) {
        string list_path = Path.build_filename (tmp_dir, "concat_list.txt");

        try {
            var sb = new StringBuilder ();
            for (int i = 0; i < segment_files.length; i++) {
                string safe_path = segment_files[i].replace ("'", "'\\''" );
                sb.append (@"file '$safe_path'\n");
            }

            var file = File.new_for_path (list_path);
            file.replace_contents (
                sb.str.data,
                null, false,
                FileCreateFlags.REPLACE_DESTINATION,
                null, null
            );
        } catch (Error e) {
            log_line ("❌ Failed to write concat list: " + e.message);
            return -1;
        }

        string[] cmd = {
            AppSettings.get_default ().ffmpeg_path, "-y",
            "-f", "concat",
            "-safe", "0",
            "-i", list_path,
            "-c", "copy",
            "-progress", "pipe:2",
            output
        };

        return execute_ffmpeg (cmd);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — FFmpeg process execution (delegates to ProcessRunner)
    //
    //  This replaces the old TrimRunner.execute_ffmpeg which had:
    //   • No mutex on current_pid (#8)
    //   • Broken try/catch on Posix.kill() (#6)
    //   • Duplicated stderr parsing logic (#5)
    // ═════════════════════════════════════════════════════════════════════════

    private int execute_ffmpeg (string[] argv) {
        string full_cmd = ConversionUtils.format_command_for_display (argv);
        log_line ("\n=== FFmpeg command ===\n" + full_cmd);
        if (console_tab != null) {
            console_tab.set_command (full_cmd);
        }
#if TRIM_SUBTITLES_STATE_TEST_BUILD
        last_ffmpeg_argv_for_test = argv;
#endif

        int exit = runner.execute (argv, (clean) => {
            // Filter noisy progress lines — only log interesting ones
            if (ConversionUtils.should_log_ffmpeg_line (clean)) {
                log_line (clean);
            }
        });

        return exit;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Audio args helpers
    // ═════════════════════════════════════════════════════════════════════════

    private string[] get_audio_args_with_filters (string af) {
        return FilterBuilder.merge_audio_filters (af, get_audio_args ());
    }

    private string[] get_audio_args () {
        if (reencode_profile != null && reencode_profile.audio_args.length > 0) {
            return reencode_profile.audio_args;
        }
        return { "-c:a", "copy" };
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Extension / container helpers
    // ═════════════════════════════════════════════════════════════════════════

    private string determine_extension (string input_ext) {
        if (copy_mode) {
            return input_ext;
        }

        if (reencode_profile != null && reencode_profile.container.length > 0) {
            return "." + reencode_profile.container;
        }

        return ".mkv";
    }

    private string[] get_reencode_codec_args () {
        if (reencode_profile != null) {
            if (resolved_reencode_codec_args == null) {
                resolved_reencode_codec_args = CodecUtils.build_codec_args_from_snapshot (
                    reencode_profile, input_file);
            }
            return resolved_reencode_codec_args;
        }
        return {};
    }

    private string build_audio_filters_for_segment (double duration,
                                                    bool apply_fade_in = true,
                                                    bool apply_fade_out = true,
                                                    bool include_normalization = true) {
        if (reencode_profile == null) {
            return "";
        }

        return FilterBuilder.merge_profile_audio_filter_chain (
            reencode_profile.audio_filters,
            reencode_profile.audio_processing,
            duration,
            include_normalization,
            apply_fade_in,
            apply_fade_out
        );
    }

    private AudioProcessingSettingsSnapshot get_audio_processing_settings () {
        if (reencode_profile != null) {
            return reencode_profile.audio_processing;
        }
        return new AudioProcessingSettingsSnapshot ();
    }

    private bool should_preserve_metadata () {
        return reencode_profile != null && reencode_profile.preserve_metadata;
    }

    private bool should_remove_chapters () {
        return reencode_profile != null && reencode_profile.remove_chapters;
    }

    private bool is_trim_image_watermark_active () {
        return reencode_profile != null
            && reencode_profile.watermark_enabled
            && reencode_profile.watermark_mode == "image"
            && reencode_profile.watermark_image_path.length > 0;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Progress helpers (fix #3: delegates to ProgressTracker)
    //
    //  Using ProgressTracker provides:
    //   • Throttled updates (~4/sec) to avoid main loop flooding
    //   • Consistent hide behavior (shows "Done" briefly, then fades)
    //   • Proper cancelled state (immediate hide with "Cancelled" text)
    //   • Same visual behavior as Converter's progress
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Update progress as a percentage (0–100).
     * No-op if no ProgressBar was provided.
     */
    private void update_progress (double percent) {
        if (tracker != null) {
            tracker.update_percent (percent);
        }
    }

    /**
     * Complete the progress display.
     * Uses hide_cancelled() if the operation was cancelled, otherwise hide().
     */
    private void finish_progress () {
        if (tracker == null) return;

        if (runner.is_cancelled () && !collage_cancellation_consumed) {
            tracker.hide_cancelled ();
        } else {
            tracker.hide ();
        }
    }

    private void reset_progress_display () {
        if (progress_bar == null) return;

        Idle.add (() => {
            progress_bar.set_visible (false);
            progress_bar.set_fraction (0.0);
            progress_bar.set_text ("Waiting...");
            return Source.REMOVE;
        });
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Status reporting (always Idle.add for thread safety)
    // ═════════════════════════════════════════════════════════════════════════

    private void update_status (string message,
                               string icon_name = StatusIcon.INFO_ICON,
                               string css_class = StatusIcon.INFO_CSS) {
        if (status_area != null) {
            status_area.set_status (message, icon_name, css_class);
        }
    }

    private void report_status (string message,
                                string icon_name = StatusIcon.INFO_ICON,
                                string css_class = StatusIcon.INFO_CSS) {
        update_status (message, icon_name, css_class);
        log_line (message);
    }

    private void report_cancelled () {
        string msg = @"$(operation_label) cancelled.\n$(runner.get_cancel_completion_message ())";
        update_status (msg, StatusIcon.CANCELLED_ICON, StatusIcon.CANCELLED_CSS);
        log_line (@"$(operation_label) cancelled.");

        Idle.add (() => {
            export_cancelled (msg);
            return Source.REMOVE;
        });
    }

    private void report_error (string message) {
        update_status (@"$message\nCheck the console for details.",
            StatusIcon.ERROR_ICON, StatusIcon.ERROR_CSS);
        log_line ("❌ " + message);

        string err = message;
        Idle.add (() => {
            export_failed (err);
            return Source.REMOVE;
        });
    }

    private void log_line (string text) {
        if (console_tab != null) {
            console_tab.add_line (text);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Utilities
    // ═════════════════════════════════════════════════════════════════════════

    private static string format_seconds (double secs) {
        if (secs < 0) secs = 0;
        int h = (int) (secs / 3600.0);
        int m = ((int) (secs / 60.0)) % 60;
        double s = secs - h * 3600.0 - m * 60.0;
        return "%02d:%02d:%06.3f".printf (h, m, s);
    }

    private static string pad_number (int n) {
        return ConversionUtils.pad_segment_number (n);
    }

    private static void cleanup_dir (string path) {
        try {
            var dir = Dir.open (path);
            string? name;
            while ((name = dir.read_name ()) != null) {
                string full = Path.build_filename (path, name);
                if (FileUtils.test (full, FileTest.IS_DIR)) {
                    cleanup_dir (full);
                } else {
                    FileUtils.unlink (full);
                }
            }
            DirUtils.remove (path);
        } catch (Error e) {
            // Best-effort cleanup — log so orphaned temp files are visible
            print ("TrimRunner: cleanup_dir failed for %s: %s\n", path, e.message);
        }
    }

    private static string path_extension_or_fallback (string path, string fallback_ext) {
        if (path == null || path == "") {
            return fallback_ext;
        }

        string basename = Path.get_basename (path);
        int dot = basename.last_index_of_char ('.');
        return (dot > 0) ? basename.substring (dot) : fallback_ext;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Collage thumbnail generation
    //
    //  Mirrors ConversionRunner's collage pass: when AppSettings has
    //  generate_collage_thumbnail enabled, write a "<name>-collage.png"
    //  sidecar next to each finished trim/crop output. Pure command
    //  construction lives in ConversionUtils so both runners share it.
    // ═════════════════════════════════════════════════════════════════════════

    private class CollageRunSummary {
        public GenericArray<string> paths = new GenericArray<string> ();
        public bool attempted = false;
        public bool cancelled = false;
        public bool failed = false;
    }

    private CollageRunSummary generate_collages_for_outputs (
            GenericArray<string> outputs,
            double[] fallback_durations = {}) {
        var summary = new CollageRunSummary ();
        if (!AppSettings.get_default ().generate_collage_thumbnail) {
            return summary;
        }
        if (outputs.length == 0) {
            return summary;
        }

        var reserved = new HashTable<string, bool> (str_hash, str_equal);

        for (int i = 0; i < outputs.length; i++) {
            if (runner.is_cancelled ()) {
                summary.cancelled = true;
                break;
            }

            string output_path = outputs[i];
            if (!FfprobeUtils.has_video_stream (output_path)) {
                log_line ("[Collage] %s has no video stream; skipping collage generation."
                    .printf (output_path));
                continue;
            }

            summary.attempted = true;

            string? collage_output_path =
                ConversionUtils.resolve_collage_output_path_with_reserved (
                    output_path, reserved);
            if (collage_output_path == null || collage_output_path.length == 0) {
                log_line ("[Collage] Could not determine a writable output path for %s; skipping."
                    .printf (output_path));
                summary.failed = true;
                continue;
            }

            double duration_seconds = FfprobeUtils.probe_duration (output_path);
            if (duration_seconds <= 0.0
                && i < fallback_durations.length
                && fallback_durations[i] > 0.0) {
                duration_seconds = fallback_durations[i];
                log_line ("[Collage] ffprobe could not read duration of %s; using segment-derived %.3fs."
                    .printf (output_path, duration_seconds));
            }
            if (duration_seconds <= 0.0) {
                log_line ("[Collage] Could not determine duration of %s; skipping collage generation."
                    .printf (output_path));
                summary.failed = true;
                continue;
            }

            string label = (outputs.length > 1)
                ? "Generating 4-4-4 collage thumbnail (%d/%d)…".printf (
                    i + 1, (int) outputs.length)
                : "Generating 4-4-4 collage thumbnail…";
            report_status (label, StatusIcon.PROGRESS_ICON, StatusIcon.PROGRESS_CSS);

            string[] collage_cmd = ConversionUtils.build_collage_argv (
                AppSettings.get_default ().ffmpeg_path,
                output_path,
                collage_output_path,
                duration_seconds
            );
            log_line ("Collage command: "
                + ConversionUtils.format_command_for_display (collage_cmd));

            int exit = runner.execute (collage_cmd, (clean) => {
                if (ConversionUtils.should_log_ffmpeg_line (clean)) {
                    log_line (clean);
                }
            });

            if (exit != 0) {
                if (runner.is_cancelled ()) {
                    summary.cancelled = true;
                    break;
                }
                log_line ("[Collage] FFmpeg failed while generating the PNG collage thumbnail for "
                    + output_path);
                summary.failed = true;
                continue;
            }

            if (!FileUtils.test (collage_output_path, FileTest.EXISTS)) {
                log_line ("[Collage] FFmpeg completed but the PNG collage file was not created for "
                    + output_path);
                summary.failed = true;
                continue;
            }

            log_line ("[Collage] Created " + collage_output_path);
            summary.paths.add (collage_output_path);
        }

        return summary;
    }

    private void emit_export_done (OperationOutputResult result) {
        Idle.add (() => {
            export_done (result);
            return Source.REMOVE;
        });
    }

    private void complete_export_success (
            GenericArray<string> primary_outputs,
            string out_dir,
            bool separate_export) {

        // Trimming is the operation most likely to produce a technically
        // successful encode containing nothing: a range that starts past the
        // end of the real content yields no frames, and ffmpeg exits 0 having
        // written only a container header. Verify every output before telling
        // the user the export succeeded.
        for (int i = 0; i < primary_outputs.length; i++) {
            string problem;
            if (!FfprobeUtils.output_file_is_usable (primary_outputs[i], out problem)) {
                export_failed ("%s\n\n%s".printf (problem, primary_outputs[i]));
                return;
            }
        }

        double[] fallback_durations = compute_fallback_durations (
            primary_outputs, separate_export);
        CollageRunSummary collages = generate_collages_for_outputs (
            primary_outputs, fallback_durations);

        // The primary trim/crop output is already on disk at this point.
        // If the user cancelled during the optional collage pass, mirror
        // ConversionRunner: complete the export with a notice instead of
        // emitting export_cancelled (which would make the app discard a
        // file that's actually saved).
        if (collages.cancelled) {
            collage_cancellation_consumed = true;
        }

        bool any_collages = collages.paths.length > 0;
        bool has_failure = collages.failed
            || (collages.attempted && !any_collages && !collages.cancelled);
        bool has_notice = has_failure || collages.cancelled;

        var status = new StringBuilder ();
        status.append (operation_label);

        if (separate_export && primary_outputs.length > 1) {
            status.append (" completed");
            if (any_collages) {
                status.append (
                    @" — exported $(primary_outputs.length) files (+ $(collages.paths.length) collage PNG"
                );
                if (collages.paths.length != 1) status.append ("s");
                status.append (") to:\n");
            } else {
                status.append (@" — exported $(primary_outputs.length) files to:\n");
            }
            status.append (out_dir);
        } else if (primary_outputs.length >= 1) {
            status.append ("!\n\nSaved");
            if (any_collages || primary_outputs.length > 1) {
                status.append (" files");
            } else {
                status.append (" to");
            }
            status.append (":\n");
            for (int i = 0; i < primary_outputs.length; i++) {
                if (i > 0) status.append ("\n");
                status.append (primary_outputs[i]);
            }
            for (int i = 0; i < collages.paths.length; i++) {
                status.append ("\n");
                status.append (collages.paths[i]);
            }
        }

        if (collages.cancelled) {
            status.append ("\n\nCollage PNG generation was cancelled.");
        } else if (has_failure) {
            status.append ("\n\nCollage PNG was not generated for every output. Check the console for details.");
        }

        string icon = has_notice ? StatusIcon.NOTICE_ICON : StatusIcon.SUCCESS_ICON;
        string css = has_notice ? StatusIcon.NOTICE_CSS : StatusIcon.SUCCESS_CSS;
        report_status (status.str, icon, css);
        update_progress (100.0);

        OperationOutputResult done_result = build_export_output_result (
            primary_outputs, collages.paths, out_dir, separate_export);
        emit_export_done (done_result);
    }

    private double[] compute_fallback_durations (
            GenericArray<string> primary_outputs,
            bool separate_export) {
        double[] durations = new double[primary_outputs.length];
        if (separate_export
            && primary_outputs.length > 1
            && primary_outputs.length == segments.length) {
            for (int i = 0; i < primary_outputs.length; i++) {
                durations[i] = segments[i].get_duration ();
            }
            return durations;
        }

        if (primary_outputs.length == 1) {
            double total = 0.0;
            for (int i = 0; i < segments.length; i++) {
                total += segments[i].get_duration ();
            }
            durations[0] = total;
        }
        return durations;
    }

    private OperationOutputResult build_export_output_result (
            GenericArray<string> primary_outputs,
            GenericArray<string> collage_paths,
            string out_dir,
            bool separate_export) {
        if (primary_outputs.length == 0) {
            // Defensive: should not happen, but fall back to a directory result.
            return new OperationOutputResult.for_directory (out_dir);
        }

        if (collage_paths.length == 0
            && !separate_export
            && primary_outputs.length == 1) {
            return new OperationOutputResult.for_file (primary_outputs[0]);
        }

        if (separate_export && primary_outputs.length > 1 && collage_paths.length == 0) {
            return OperationOutputResult.from_paths (
                OperationOutputResult.copy_paths (primary_outputs),
                out_dir
            );
        }

        var combined = new GenericArray<string> ();
        for (int i = 0; i < primary_outputs.length; i++) combined.add (primary_outputs[i]);
        for (int i = 0; i < collage_paths.length; i++) combined.add (collage_paths[i]);

        string primary = primary_outputs[0];
        string folder = (out_dir != null && out_dir.length > 0)
            ? out_dir : Path.get_dirname (primary);

        return new OperationOutputResult.for_multiple_files (
            OperationOutputResult.copy_paths (combined),
            folder,
            primary
        );
    }

#if TRIM_SUBTITLES_STATE_TEST_BUILD
    internal double[] compute_fallback_durations_for_test (
            GenericArray<string> primary_outputs,
            bool separate_export) {
        return compute_fallback_durations (primary_outputs, separate_export);
    }

    internal OperationOutputResult build_export_output_result_for_test (
            GenericArray<string> primary_outputs,
            GenericArray<string> collage_paths,
            string out_dir,
            bool separate_export) {
        return build_export_output_result (
            primary_outputs, collage_paths, out_dir, separate_export);
    }

    internal string[] build_peak_detect_command_for_widget_test (int seg_index,
                                                                 bool apply_fade_in = true,
                                                                 bool apply_fade_out = true) {
        if (seg_index < 0 || seg_index >= segments.length) {
            return {};
        }

        return build_peak_detect_cmd_for_segment (
            segments[seg_index], apply_fade_in, apply_fade_out);
    }

    internal string[] get_last_ffmpeg_argv_for_widget_test () {
        return last_ffmpeg_argv_for_test;
    }

    internal string build_segment_vf_for_test (TrimSegment seg) {
        return build_segment_vf (seg);
    }

    internal int run_extract_segment_for_widget_test (int seg_index, string output) {
        if (seg_index < 0 || seg_index >= segments.length) {
            return -1;
        }

        return extract_segment (seg_index, segments[seg_index], output);
    }
#endif
}
