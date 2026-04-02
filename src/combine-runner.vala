using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  CombineRunner — FFmpeg execution for combining multiple video files
//
//  Two paths:
//   A. Copy mode — demuxer concat with explicit -map (lossless, strict match)
//   B. Re-encode mode — filter concat with full normalization per input
//
//  Participates in MainWindow's single-operation model via signals.
// ═══════════════════════════════════════════════════════════════════════════════

public class CombineFile : Object {
    public string path                 { get; set; }
    public string filename             { get; set; }
    public double duration             { get; set; default = 0; }
    public int    width                { get; set; default = 0; }
    public int    height               { get; set; default = 0; }
    public string video_codec          { get; set; default = ""; }
    public string video_profile        { get; set; default = ""; }
    public string pixel_format         { get; set; default = ""; }
    public string frame_rate           { get; set; default = ""; }
    public string sample_aspect_ratio  { get; set; default = ""; }
    public string audio_codec          { get; set; default = ""; }
    public int    audio_sample_rate    { get; set; default = 0; }
    public int    audio_channels       { get; set; default = 0; }
    public string audio_channel_layout { get; set; default = ""; }
    public string extension            { get; set; default = ""; }
    public bool   has_audio            { get; set; default = false; }
    public bool   probe_failed         { get; set; default = false; }
    public Cancellable? probe_cancellable { get; set; default = null; }
}

public class CombineRunner : Object {

    // ── Configuration ───────────────────────────────────────────────────────
    public bool copy_mode { get; set; default = true; }
    public string output_path { get; set; default = ""; }
    public EncodeProfileSnapshot? reencode_profile { get; set; default = null; }
    public bool preserve_metadata { get; set; default = false; }

    // ── Chapter generation ──────────────────────────────────────────────────
    public bool generate_chapters { get; set; default = false; }
    public bool remove_source_chapters { get; set; default = false; }

    // ── Crossfade ───────────────────────────────────────────────────────────
    public bool crossfade_enabled { get; set; default = false; }
    public double crossfade_duration { get; set; default = 0.5; }
    public string crossfade_type { get; set; default = "fade"; }

    // UI references
    public StatusArea? status_area { get; set; default = null; }
    public Gtk.ProgressBar? progress_bar { get; set; default = null; }
    public ConsoleTab? console_tab { get; set; default = null; }

    // ── Files ───────────────────────────────────────────────────────────────
    private GenericArray<CombineFile> files = new GenericArray<CombineFile> ();

    // ── Shared process runner ───────────────────────────────────────────────
    private ProcessRunner runner = new ProcessRunner ();
    private ProgressTracker? tracker = null;
    private double total_duration = 0.0;
#if COMBINE_WINDOW_TEST_BUILD
    private bool capture_ffmpeg_argv_for_test = false;
    private int captured_ffmpeg_exit_code_for_test = 0;
    private string[] last_ffmpeg_argv_for_test = {};
    private string[] last_peak_analysis_argv_for_test = {};
    private bool peak_analysis_ran_for_test = false;
    private bool force_write_chapters_file_failure_for_test = false;
#endif

    // ── Signals ─────────────────────────────────────────────────────────────
    public signal void combine_done (OperationOutputResult output_result);
    public signal void combine_cancelled (string cancel_message);
    public signal void combine_failed (string message);

    // ═════════════════════════════════════════════════════════════════════════
    //  PUBLIC API
    // ═════════════════════════════════════════════════════════════════════════

    public void set_files (GenericArray<CombineFile> file_list) {
        files = file_list;
    }

    public void run () {
        if (files.length < 2) {
            report_status ("Need at least 2 files to combine.",
                StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
            return;
        }
        if (output_path == null || output_path == "") {
            report_status ("No output path specified.",
                StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
            return;
        }

        runner.set_event_logger (log_runner_event);
        runner.prepare_for_new_execution ();

        // Compute total duration for progress
        total_duration = 0.0;
        for (int i = 0; i < files.length; i++) {
            total_duration += files[i].duration;
        }
        if (crossfade_enabled && files.length > 1) {
            total_duration -= (files.length - 1) * crossfade_duration;
        }

        if (progress_bar != null) {
            tracker = new ProgressTracker (progress_bar);
            tracker.reset_throttle ();
            tracker.show_determinate ();
        }

        try {
            new Thread<void>.try ("combine-thread", () => {
                try {
                    run_internal ();
                } finally {
                    finish_progress ();
                }
            });
        } catch (Error e) {
            reset_progress_display ();
            report_error ("Failed to start combine thread: " + e.message);
        }
    }

    public void cancel () {
        runner.cancel ();
    }

    public bool is_cancelled () {
        return runner.is_cancelled ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Main execution dispatcher
    // ═════════════════════════════════════════════════════════════════════════

    private void run_internal () {
        // Validate crossfade duration against shortest clip
        if (crossfade_enabled) {
            double min_dur = double.MAX;
            for (int i = 0; i < files.length; i++) {
                if (files[i].duration < min_dur) min_dur = files[i].duration;
            }
            if (crossfade_duration >= min_dur) {
                report_error ("Crossfade duration (%.1fs) must be less than the shortest clip (%.1fs).".printf (
                    crossfade_duration, min_dur));
                return;
            }
        }

        report_status ("Combining files...",
            StatusIcon.PROGRESS_ICON, StatusIcon.PROGRESS_CSS);

        int exit;
        if (copy_mode) {
            exit = run_copy_mode ();
        } else {
            exit = run_reencode_mode ();
        }

        if (exit != 0) {
            if (runner.is_cancelled ()) {
                report_cancelled ();
            } else {
                report_error (@"Combine failed (exit code $exit).");
            }
            return;
        }

        report_status (@"Combine completed!\n\nSaved to:\n$output_path",
            StatusIcon.SUCCESS_ICON, StatusIcon.SUCCESS_CSS);
        update_progress (100.0);

        var done = build_done_result ();
        Idle.add (() => {
            combine_done (done);
            return Source.REMOVE;
        });
    }

    private OperationOutputResult build_done_result () {
        string source_summary = "Combined %d files".printf (files.length);
        return new OperationOutputResult.for_file (
            output_path,
            OperationOutputSource.COMBINE,
            source_summary
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PATH A — Copy mode (demuxer concat with explicit -map)
    // ═════════════════════════════════════════════════════════════════════════

    private int run_copy_mode () {
        // Determine if any file has audio
        bool any_audio = false;
        for (int i = 0; i < files.length; i++) {
            if (files[i].has_audio) {
                any_audio = true;
                break;
            }
        }

        // Write concat list to managed temp dir
        string? tmp_dir = ConversionUtils.create_managed_temp_run_dir ("combine", "copy");
        if (tmp_dir == null) {
            log_line ("Failed to create temp directory for combine");
            return -1;
        }

        string list_path = Path.build_filename (tmp_dir, "concat_list.txt");

        try {
            var sb = new StringBuilder ();
            for (int i = 0; i < files.length; i++) {
                string safe_path = files[i].path.replace ("'", "'\\''");
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
            log_line ("Failed to write concat list: " + e.message);
            cleanup_dir (tmp_dir);
            return -1;
        }

        // Write chapter metadata if enabled
        string? chapters_path = null;
        if (generate_chapters) {
            string cp;
            if (!write_chapters_file (tmp_dir, out cp)) {
                cleanup_dir (tmp_dir);
                return -1;
            }
            chapters_path = cp;
        }

        string[] cmd = {
            AppSettings.get_default ().ffmpeg_path, "-y",
            "-f", "concat",
            "-safe", "0",
            "-i", list_path
        };

        // Chapter metadata input (index 1)
        if (chapters_path != null) {
            cmd += "-f";
            cmd += "ffmetadata";
            cmd += "-i";
            cmd += chapters_path;
        }

        cmd += "-map";
        cmd += "0:v:0";

        if (any_audio) {
            cmd += "-map";
            cmd += "0:a:0";
        }

        cmd += "-c";
        cmd += "copy";

        if (!any_audio) {
            cmd += "-an";
        }

        if (preserve_metadata) {
            cmd += "-map_metadata";
            cmd += "0";
        }

        // Chapter policy
        if (generate_chapters) {
            cmd += "-map_chapters";
            cmd += "1";
        } else if (remove_source_chapters) {
            cmd += "-map_chapters";
            cmd += "-1";
        }

        cmd += "-progress";
        cmd += "pipe:2";
        cmd += output_path;

        log_line (@"Using demuxer concat for $(files.length) files (copy mode)");
        int exit = execute_ffmpeg (cmd);

        cleanup_dir (tmp_dir);
        return exit;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PATH B — Re-encode mode (filter concat with full normalization)
    // ═════════════════════════════════════════════════════════════════════════

    private int run_reencode_mode () {
        // ── Create managed temp dir for chapter metadata if needed ──────────
        string? reencode_tmp_dir = null;
        string? chapters_path = null;
        int chapters_input_idx = -1;

        if (generate_chapters) {
            reencode_tmp_dir = ConversionUtils.create_managed_temp_run_dir ("combine", "reencode");
            if (reencode_tmp_dir == null) {
                log_line ("Failed to create temp directory for re-encode chapters");
                return -1;
            }

            string cp;
            if (!write_chapters_file (reencode_tmp_dir, out cp)) {
                cleanup_dir (reencode_tmp_dir);
                return -1;
            }
            chapters_path = cp;
            chapters_input_idx = files.length;  // metadata input comes after all video inputs
        }

        try {
            string[] cmd = { AppSettings.get_default ().ffmpeg_path, "-y" };

            // ── Add each file as a separate input ───────────────────────────
            for (int i = 0; i < files.length; i++) {
                cmd += "-i";
                cmd += files[i].path;
            }

            // ── Chapter metadata input ──────────────────────────────────────
            if (chapters_path != null) {
                cmd += "-f";
                cmd += "ffmetadata";
                cmd += "-i";
                cmd += chapters_path;
            }

            // ── Determine normalization targets ─────────────────────────────
            // Video target: first file
            int target_w = get_square_pixel_width (files[0]);
            int target_h = files[0].height;
            string target_fps = files[0].frame_rate;
            string target_pix_fmt = files[0].pixel_format;

            // Audio target: prefer the first file with complete audio metadata,
            // fall back to any file with audio, then to defaults.
            int audio_target_idx = -1;
            int audio_fallback_idx = -1;
            for (int i = 0; i < files.length; i++) {
                if (files[i].has_audio) {
                    if (audio_fallback_idx < 0) {
                        audio_fallback_idx = i;
                    }
                    if (files[i].audio_sample_rate > 0 && files[i].audio_channel_layout.length > 0) {
                        audio_target_idx = i;
                        break;
                    }
                }
            }
            if (audio_target_idx < 0) {
                audio_target_idx = audio_fallback_idx;
            }

            bool has_audio_target = (audio_target_idx >= 0);
            bool audio_disabled = profile_disables_audio_output ();
            bool output_has_audio = has_audio_target && !audio_disabled;
            int target_sample_rate = 0;
            string target_layout = "";
            if (has_audio_target) {
                target_sample_rate = files[audio_target_idx].audio_sample_rate;
                target_layout = files[audio_target_idx].audio_channel_layout;
            }
            // Fall back to sensible defaults if no file had complete audio metadata
            if (has_audio_target && target_sample_rate <= 0) {
                target_sample_rate = 48000;
            }
            if (has_audio_target && target_layout.length == 0) {
                target_layout = "stereo";
            }

            // ── Resolve profile filters ─────────────────────────────────────
            string profile_video_filters_per_input = "";
            string profile_video_filters_post_output = "";
            string profile_audio_filters = "";
            AudioProcessingSettingsSnapshot? audio_processing = null;
            bool ebu_post_combine = false;

            if (reencode_profile != null) {
                // Combine keeps clip-local transforms per input and applies
                // output shaping (scale/fps/pix_fmt) once after concat/xfade.
                profile_video_filters_per_input = strip_video_speed_filters (
                    reencode_profile.combine_video_filters_per_input);
                profile_video_filters_post_output =
                    reencode_profile.combine_video_filters_post_output;

                // Backward-compatible fallback for tests or older snapshots
                // that only populated the legacy combined chain.
                if (profile_video_filters_per_input.length == 0
                    && profile_video_filters_post_output.length == 0) {
                    profile_video_filters_per_input = strip_video_speed_filters (
                        reencode_profile.video_filters_skip_crop);
                }

                profile_audio_filters = strip_audio_speed_filters (
                    reencode_profile.audio_filters);
                audio_processing = reencode_profile.audio_processing;

                // EBU normalization must apply post-combine (after concat/acrossfade)
                if (audio_processing != null
                    && audio_processing.normalize_enabled
                    && audio_processing.normalize_ebu) {
                    ebu_post_combine = true;
                }
            }

            // ── Peak normalization analysis (must run before main encode) ───
            if (needs_peak_analysis () && audio_processing != null && output_has_audio) {
                if (!prepare_peak_normalization_for_reencode (
                        target_sample_rate, target_layout,
                        profile_audio_filters, audio_processing,
                        output_has_audio)) {
                    if (runner.is_cancelled ()) {
                        return 1;
                    }
                    return -1;
                }
                if (runner.is_cancelled ()) {
                    return 1;
                }
            }

            // ── Build filter_complex ────────────────────────────────────────
            var fc = new StringBuilder ();

            for (int i = 0; i < files.length; i++) {
                var f = files[i];

                // ── Per-input video chain ───────────────────────────────────
                fc.append (build_video_chain_for_input (f, i,
                    target_w, target_h, target_fps, target_pix_fmt,
                    profile_video_filters_per_input));

                // ── Per-input audio chain ───────────────────────────────────
                if (output_has_audio) {
                    fc.append (build_audio_chain_for_input (f, i,
                        target_sample_rate, target_layout,
                        profile_audio_filters, audio_processing,
                        ebu_post_combine));
                }
            }

            // ── Combine filter (concat or crossfade) ────────────────────────
            if (crossfade_enabled && files.length > 1) {
                build_crossfade_filters (fc, output_has_audio);
            } else {
                for (int i = 0; i < files.length; i++) {
                    fc.append (@"[v$i]");
                    if (output_has_audio) {
                        fc.append (@"[a$i]");
                    }
                }

                int a_streams = output_has_audio ? 1 : 0;
                fc.append ("concat=n=%d:v=1:a=%d[outv]".printf (files.length, a_streams));
                if (output_has_audio) {
                    fc.append ("[outa]");
                }
            }

            // ── Video output shaping post-combine ──────────────────────────
            if (profile_video_filters_post_output.length > 0) {
                string fc_str = fc.str;
                fc_str = fc_str.replace ("[outv]", "[outv_pre]");
                fc_str = ensure_filter_chain_separator (fc_str);
                fc = new StringBuilder ();
                fc.append (fc_str);
                fc.append ("[outv_pre]%s[outv]".printf (
                    profile_video_filters_post_output));
            }

            // ── EBU normalization post-combine ──────────────────────────────
            if (ebu_post_combine && output_has_audio) {
                // Rewire: rename [outa] to [outa_pre], apply EBU, output [outa]
                string fc_str = fc.str;
                fc_str = fc_str.replace ("[outa]", "[outa_pre]");
                fc_str = ensure_filter_chain_separator (fc_str);
                fc = new StringBuilder ();
                fc.append (fc_str);
                fc.append ("[outa_pre]%s[outa]".printf (AudioNormalization.EBU_R128_FILTER));
            }

            cmd += "-filter_complex";
            cmd += fc.str;

            cmd += "-map";
            cmd += "[outv]";
            if (output_has_audio) {
                cmd += "-map";
                cmd += "[outa]";
            }

            // ── Video codec args ────────────────────────────────────────────
            if (reencode_profile != null) {
                string[] codec_args = CodecUtils.build_codec_args_from_snapshot (
                    reencode_profile, files[0].path);
                foreach (string arg in codec_args) cmd += arg;
            } else {
                log_line ("No codec builder set - using fallback: libx264 crf 18 medium");
                cmd += "-c:v";
                cmd += "libx264";
                cmd += "-crf";
                cmd += "18";
                cmd += "-preset";
                cmd += "medium";
            }

            // ── Audio codec args ────────────────────────────────────────────
            if (!output_has_audio) {
                cmd += "-an";
            } else if (reencode_profile != null && reencode_profile.audio_args.length > 0) {
                foreach (string a in reencode_profile.audio_args) cmd += a;
            } else {
                cmd += "-c:a";
                cmd += "aac";
                cmd += "-b:a";
                cmd += "192k";
            }

            // ── Metadata ────────────────────────────────────────────────────
            if (reencode_profile != null && reencode_profile.preserve_metadata) {
                cmd += "-map_metadata";
                cmd += "0";
            }

            // Chapter policy uses request-level generate_chapters / remove_source_chapters.
            // reencode_profile.remove_chapters is intentionally ignored here — Combine
            // has its own chapter semantics that take precedence over the General tab setting.
            if (generate_chapters && chapters_input_idx >= 0) {
                cmd += "-map_chapters";
                cmd += chapters_input_idx.to_string ();
            } else if (remove_source_chapters) {
                cmd += "-map_chapters";
                cmd += "-1";
            }

            cmd += "-progress";
            cmd += "pipe:2";
            cmd += output_path;

            if (crossfade_enabled && files.length > 1) {
                log_line (@"Using crossfade filters for $(files.length) files (re-encode mode)");
            } else {
                log_line (@"Using filter concat for $(files.length) files (re-encode mode)");
            }
            return execute_ffmpeg (cmd);
        } finally {
            if (reencode_tmp_dir != null) {
                cleanup_dir (reencode_tmp_dir);
            }
        }
    }

    private bool profile_disables_audio_output () {
        return reencode_profile != null
            && reencode_profile.audio_args.length > 0
            && reencode_profile.audio_args[0] == "-an";
    }

    private static int get_square_pixel_width (CombineFile file) {
        if (file.width <= 0) {
            return file.width;
        }

        double sar = parse_sample_aspect_ratio (file.sample_aspect_ratio);
        int width = (int) Math.round (file.width * sar);
        if (width <= 0) {
            return file.width;
        }

        return width;
    }

    private static double parse_sample_aspect_ratio (string ratio) {
        if (ratio == null || ratio.length == 0 || ratio == "N/A") {
            return 1.0;
        }

        int sep = ratio.index_of_char (':');
        if (sep <= 0 || sep >= ratio.length - 1) {
            return 1.0;
        }

        string numerator_text = ratio.substring (0, sep).strip ();
        string denominator_text = ratio.substring (sep + 1).strip ();
        int numerator = 0;
        int denominator = 0;
        if (!int.try_parse (numerator_text, out numerator)
            || !int.try_parse (denominator_text, out denominator)
            || numerator <= 0
            || denominator <= 0) {
            return 1.0;
        }

        return (double) numerator / (double) denominator;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Speed filter stripping
    //
    //  Combine's timing model (crossfade offsets, chapter boundaries, progress)
    //  depends on raw source durations. Speed filters change effective output
    //  duration, making them incompatible. Strip them from the profile filters
    //  so the rest of the combine pipeline stays consistent.
    // ═════════════════════════════════════════════════════════════════════════

    internal static string strip_video_speed_filters (string filters) {
        if (filters.length == 0) return "";

        string[] parts = filters.split (",");
        string[] kept = {};
        foreach (unowned string part in parts) {
            string trimmed = part.strip ();
            // Speed filters are "setpts=<factor>*PTS" — strip any setpts
            // that contains a multiplication with PTS (but not bare PTS resets)
            if (trimmed.has_prefix ("setpts=") && trimmed.contains ("*PTS")) {
                continue;
            }
            kept += trimmed;
        }
        return kept.length > 0 ? string.joinv (",", kept) : "";
    }

    internal static string strip_audio_speed_filters (string filters) {
        if (filters.length == 0) return "";

        string[] parts = filters.split (",");
        string[] kept = {};
        foreach (unowned string part in parts) {
            string trimmed = part.strip ();
            if (trimmed.has_prefix ("atempo=")) {
                continue;
            }
            kept += trimmed;
        }
        return kept.length > 0 ? string.joinv (",", kept) : "";
    }

    private static string ensure_filter_chain_separator (string filter_graph) {
        string trimmed = filter_graph.strip ();
        if (trimmed.length == 0) {
            return "";
        }

        if (trimmed.has_suffix (";")) {
            return filter_graph.has_suffix (" ") ? filter_graph : filter_graph + " ";
        }

        return filter_graph + "; ";
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Peak normalization analysis
    // ═════════════════════════════════════════════════════════════════════════

    private bool needs_peak_analysis () {
        if (reencode_profile == null) return false;

        // Skip when audio is disabled in the profile
        if (profile_disables_audio_output ()) {
            return false;
        }

        return ConversionUtils.audio_processing_needs_peak_analysis (
            reencode_profile.audio_processing);
    }

    private bool prepare_peak_normalization_for_reencode (
        int target_sample_rate,
        string target_layout,
        string profile_audio_filters,
        AudioProcessingSettingsSnapshot audio_processing,
        bool has_audio_target) {
        if (!has_audio_target) return true;

        audio_processing.peak_normalize_gain_db = 0.0;

        report_status ("Analyzing audio peak levels for normalization...",
            StatusIcon.PROGRESS_ICON, StatusIcon.PROGRESS_CSS);

        // Build an analysis filter_complex: per-input audio chains (excluding
        // normalization) → same combine stage as real output → volumedetect
        var fc = new StringBuilder ();

        for (int i = 0; i < files.length; i++) {
            var f = files[i];
            if (f.has_audio) {
                var af = new StringBuilder ();

                if (f.audio_sample_rate != target_sample_rate && target_sample_rate > 0) {
                    af.append (@"aresample=$(target_sample_rate)");
                }
                if (f.audio_channel_layout != target_layout && target_layout.length > 0) {
                    if (af.len > 0) af.append (",");
                    af.append (@"aformat=channel_layouts=$(target_layout)");
                }
                if (profile_audio_filters.length > 0) {
                    if (af.len > 0) af.append (",");
                    af.append (profile_audio_filters);
                }
                // Include non-normalization audio processing (fades, etc.)
                // Fades suppressed under crossfade, same as real path
                bool apply_fade_in = !crossfade_enabled && audio_processing.fade_in_enabled;
                bool apply_fade_out = !crossfade_enabled && audio_processing.fade_out_enabled;
                string processing = AudioProcessingSettings.build_filter_chain_from_snapshot (
                    audio_processing, f.duration, false, apply_fade_in, apply_fade_out);
                if (processing.length > 0) {
                    if (af.len > 0) af.append (",");
                    af.append (processing);
                }

                if (af.len > 0) af.append (",");
                af.append ("asetpts=PTS-STARTPTS");
                fc.append ("[%d:a:0]%s[a%d]; ".printf (i, af.str, i));
            } else {
                string dur_str = ConversionUtils.format_ffmpeg_double (f.duration, "%.6f");
                fc.append ("anullsrc=channel_layout=%s:sample_rate=%d[silence%d]; ".printf (
                    target_layout, target_sample_rate, i));
                fc.append ("[silence%d]atrim=duration=%s,asetpts=PTS-STARTPTS[a%d]; ".printf (
                    i, dur_str, i));
            }
        }

        // Combine stage must match real output to account for acrossfade peak summing
        if (crossfade_enabled && files.length > 1) {
            string dur_str = ConversionUtils.format_ffmpeg_double (crossfade_duration, "%.6f");
            for (int i = 0; i < files.length - 1; i++) {
                string in_a = (i == 0) ? "[a0]" : "[xa%d]".printf (i);
                string out_a = (i == files.length - 2) ? "[outa]" : "[xa%d]".printf (i + 1);
                fc.append ("%s[a%d]acrossfade=d=%s:c1=tri:c2=tri%s; ".printf (
                    in_a, i + 1, dur_str, out_a));
            }
        } else {
            for (int i = 0; i < files.length; i++) {
                fc.append (@"[a$i]");
            }
            fc.append ("concat=n=%d:v=0:a=1[outa]".printf (files.length));
        }

        // Append volumedetect to the combined output
        string fc_str = fc.str;
        fc_str = fc_str.replace ("[outa]", "[outa_pre]");
        fc_str = ensure_filter_chain_separator (fc_str);
        fc_str += "[outa_pre]volumedetect[outa]";

        // Build input args
        string[] input_args = {};
        for (int i = 0; i < files.length; i++) {
            input_args += "-i";
            input_args += files[i].path;
        }

        // Include output-side audio args (-ac, -ar) so the analysis measures
        // the same signal as the final encode (e.g. after downmix).
        string[]? peak_output_args = null;
        if (reencode_profile != null) {
            peak_output_args = FilterBuilder.extract_peak_analysis_output_args (
                reencode_profile.audio_args);
        }

        string[] cmd = FilterBuilder.build_filter_complex_peak_detect_cmd (
            input_args, fc_str, "[outa]", peak_output_args);

        string full_cmd = ConversionUtils.format_command_for_display (cmd);
        log_line ("\n=== Peak analysis command ===\n" + full_cmd);

#if COMBINE_WINDOW_TEST_BUILD
        if (capture_ffmpeg_argv_for_test) {
            last_peak_analysis_argv_for_test = cmd;
            peak_analysis_ran_for_test = true;
            return !runner.is_cancelled ();
        }
#endif

        double max_volume_db = 0.0;
        bool found_max_volume = false;

        int exit = runner.execute (cmd, (line) => {
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
            return false;
        }

        if (exit != 0) {
            report_error ("Peak normalization analysis failed.");
            return false;
        }

        if (!found_max_volume) {
            report_error ("Peak normalization analysis did not report a max volume.");
            return false;
        }

        audio_processing.peak_normalize_gain_db =
            ConversionUtils.compute_peak_normalize_gain_db (max_volume_db);
        log_line ("[Combine] Peak normalization measured %.2f dBFS, gain %.2f dB".printf (
            max_volume_db, audio_processing.peak_normalize_gain_db));

        return true;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Per-input filter chain helpers
    // ═════════════════════════════════════════════════════════════════════════

    private string build_video_chain_for_input (CombineFile f, int i,
                                                int target_w, int target_h,
                                                string target_fps, string target_pix_fmt,
                                                string profile_video_filters) {
        var vf = new StringBuilder ();

        // 1. FPS normalization
        if (f.frame_rate != target_fps && target_fps.length > 0) {
            vf.append (@"fps=$(target_fps)");
        }

        // 2. Pixel format normalization
        if (f.pixel_format != target_pix_fmt && target_pix_fmt.length > 0) {
            if (vf.len > 0) vf.append (",");
            vf.append (@"format=$(target_pix_fmt)");
        }

        // 3. Scale/pad normalization
        int square_pixel_width = get_square_pixel_width (f);
        bool needs_scale = target_w > 0 && target_h > 0
            && (f.width != target_w
                || f.height != target_h
                || square_pixel_width != target_w);
        if (needs_scale) {
            if (vf.len > 0) vf.append (",");
            vf.append ("scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:-1:-1:color=black".printf (
                target_w, target_h, target_w, target_h));
        }

        // 4. Clip-local General video filters from profile (rotation, visual
        //    processing, tonemap, color correction). Output-shaping filters
        //    like scale/fps/format are applied once after combine.
        if (profile_video_filters.length > 0) {
            if (vf.len > 0) vf.append (",");
            vf.append (profile_video_filters);
        }

        // 5. Timestamp normalization (always last)
        if (vf.len > 0) vf.append (",");
        vf.append ("setsar=1,settb=AVTB,setpts=PTS-STARTPTS");

        return "[%d:v:0]%s[v%d]; ".printf (i, vf.str, i);
    }

    private string build_audio_chain_for_input (CombineFile f, int i,
                                                int target_sample_rate,
                                                string target_layout,
                                                string profile_audio_filters,
                                                AudioProcessingSettingsSnapshot? audio_processing,
                                                bool ebu_post_combine) {
        if (f.has_audio) {
            return build_real_audio_chain (f, i,
                target_sample_rate, target_layout,
                profile_audio_filters, audio_processing,
                ebu_post_combine);
        } else {
            return build_silence_audio_chain (f, i,
                target_sample_rate, target_layout);
        }
    }

    private string build_real_audio_chain (CombineFile f, int i,
                                           int target_sample_rate,
                                           string target_layout,
                                           string profile_audio_filters,
                                           AudioProcessingSettingsSnapshot? audio_processing,
                                           bool ebu_post_combine) {
        var af = new StringBuilder ();

        // 1. Sample rate normalization
        if (f.audio_sample_rate != target_sample_rate && target_sample_rate > 0) {
            af.append (@"aresample=$(target_sample_rate)");
        }

        // 2. Channel layout normalization
        if (f.audio_channel_layout != target_layout && target_layout.length > 0) {
            if (af.len > 0) af.append (",");
            af.append (@"aformat=channel_layouts=$(target_layout)");
        }

        // 3. General audio filters from profile (e.g. audio speed)
        if (profile_audio_filters.length > 0) {
            if (af.len > 0) af.append (",");
            af.append (profile_audio_filters);
        }

        // 4. Audio processing chain (normalization, fades)
        if (audio_processing != null) {
            // Determine fade suppression: always suppress when crossfade is active
            bool apply_fade_in = !crossfade_enabled && audio_processing.fade_in_enabled;
            bool apply_fade_out = !crossfade_enabled && audio_processing.fade_out_enabled;

            // EBU normalization is post-combine; peak normalization is per-input
            bool include_normalization = !ebu_post_combine;

            string processing_chain = AudioProcessingSettings.build_filter_chain_from_snapshot (
                audio_processing,
                f.duration,
                include_normalization,
                apply_fade_in,
                apply_fade_out
            );
            if (processing_chain.length > 0) {
                if (af.len > 0) af.append (",");
                af.append (processing_chain);
            }
        }

        // 5. Timestamp reset
        if (af.len > 0) af.append (",");
        af.append ("asetpts=PTS-STARTPTS");

        return "[%d:a:0]%s[a%d]; ".printf (i, af.str, i);
    }

    private string build_silence_audio_chain (CombineFile f, int i,
                                              int target_sample_rate,
                                              string target_layout) {
        // Silence-generated inputs use an explicitly defined subset of the
        // audio chain. Normalization (both EBU and peak) is excluded.
        // Sample rate and channel layout are set via anullsrc parameters.
        var sb = new StringBuilder ();
        string dur_str = ConversionUtils.format_ffmpeg_double (f.duration, "%.6f");
        sb.append ("anullsrc=channel_layout=%s:sample_rate=%d[silence%d]; ".printf (
            target_layout, target_sample_rate, i));
        sb.append ("[silence%d]atrim=duration=%s,asetpts=PTS-STARTPTS[a%d]; ".printf (
            i, dur_str, i));
        return sb.str;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Crossfade filter construction
    // ═════════════════════════════════════════════════════════════════════════

    private void build_crossfade_filters (StringBuilder fc, bool has_audio_target) {
        string dur_str = ConversionUtils.format_ffmpeg_double (crossfade_duration, "%.6f");

        // Video: chained xfade filters
        double cumulative = 0.0;
        for (int i = 0; i < files.length - 1; i++) {
            string in_v = (i == 0) ? "[v0]" : "[xv%d]".printf (i);
            string out_v = (i == files.length - 2) ? "[outv]" : "[xv%d]".printf (i + 1);
            cumulative += files[i].duration;
            double xfade_offset = cumulative - (i + 1) * crossfade_duration;
            string offset_str = ConversionUtils.format_ffmpeg_double (xfade_offset, "%.6f");
            fc.append ("%s[v%d]xfade=transition=%s:duration=%s:offset=%s%s; ".printf (
                in_v, i + 1, crossfade_type, dur_str, offset_str, out_v));
        }

        // Audio: chained acrossfade filters
        if (has_audio_target) {
            for (int i = 0; i < files.length - 1; i++) {
                string in_a = (i == 0) ? "[a0]" : "[xa%d]".printf (i);
                string out_a = (i == files.length - 2) ? "[outa]" : "[xa%d]".printf (i + 1);
                fc.append ("%s[a%d]acrossfade=d=%s:c1=tri:c2=tri%s; ".printf (
                    in_a, i + 1, dur_str, out_a));
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Chapter metadata generation
    // ═════════════════════════════════════════════════════════════════════════

    internal static string escape_ffmetadata_value (string value) {
        var sb = new StringBuilder ();
        for (int i = 0; i < value.length; i++) {
            char c = value[i];
            switch (c) {
                case '=':
                case ';':
                case '#':
                case '\\':
                    sb.append_c ('\\');
                    sb.append_c (c);
                    break;
                case '\n':
                case '\r':
                    // FFMETADATA1 has no escape form for newlines — bare newlines
                    // terminate the field. Normalize to spaces to keep a valid
                    // single-line value.
                    sb.append_c (' ');
                    break;
                default:
                    sb.append_c (c);
                    break;
            }
        }
        return sb.str;
    }

    internal string? build_chapters_metadata_content (double crossfade_dur = 0.0) {
        if (files.length < 1) return null;

        var sb = new StringBuilder ();
        sb.append (";FFMETADATA1\n");

        double cursor = 0.0;
        for (int i = 0; i < files.length; i++) {
            double start = cursor;
            double end;
            if (i < files.length - 1 && crossfade_dur > 0.0) {
                end = start + files[i].duration - crossfade_dur;
            } else {
                end = start + files[i].duration;
            }

            int start_ms = (int) Math.round (start * 1000.0);
            int end_ms = (int) Math.round (end * 1000.0);

            // Strip extension from filename for chapter title
            string title = files[i].filename;
            int dot = title.last_index_of_char ('.');
            if (dot > 0) {
                title = title.substring (0, dot);
            }

            sb.append ("\n[CHAPTER]\n");
            sb.append ("TIMEBASE=1/1000\n");
            sb.append ("START=%d\n".printf (start_ms));
            sb.append ("END=%d\n".printf (end_ms));
            sb.append ("title=%s\n".printf (escape_ffmetadata_value (title)));

            cursor = end;
        }

        return sb.str;
    }

    private bool write_chapters_file (string dir, out string chapters_path) {
        chapters_path = Path.build_filename (dir, "chapters.ffmeta");
        double xfade_dur = crossfade_enabled ? crossfade_duration : 0.0;
        string? content = build_chapters_metadata_content (xfade_dur);
        if (content == null) {
            log_line ("Failed to build chapter metadata content");
            return false;
        }

#if COMBINE_WINDOW_TEST_BUILD
        if (force_write_chapters_file_failure_for_test) {
            log_line ("Forced chapter metadata write failure for test");
            return false;
        }
#endif

        try {
            var file = File.new_for_path (chapters_path);
            file.replace_contents (
                content.data,
                null, false,
                FileCreateFlags.REPLACE_DESTINATION,
                null, null
            );
        } catch (Error e) {
            log_line ("Failed to write chapter metadata: " + e.message);
            return false;
        }

        return true;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — FFmpeg process execution
    // ═════════════════════════════════════════════════════════════════════════

    private int execute_ffmpeg (string[] argv) {
        string full_cmd = ConversionUtils.format_command_for_display (argv);
        log_line ("\n=== FFmpeg command ===\n" + full_cmd);
        if (console_tab != null) {
            console_tab.set_command (full_cmd);
        }

#if COMBINE_WINDOW_TEST_BUILD
        if (capture_ffmpeg_argv_for_test) {
            last_ffmpeg_argv_for_test = argv;
            return captured_ffmpeg_exit_code_for_test;
        }
#endif

        int exit = runner.execute (argv, (clean) => {
            parse_progress (clean);

            if (ConversionUtils.should_log_ffmpeg_line (clean)) {
                log_line (clean);
            }
        });

        return exit;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Progress parsing
    // ═════════════════════════════════════════════════════════════════════════

    private void parse_progress (string line) {
        if (tracker == null || total_duration <= 0.0) return;

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
            double frac = (current_sec / total_duration).clamp (0.0, 1.0);
            tracker.update_percent (frac * 100.0);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Reporting helpers
    // ═════════════════════════════════════════════════════════════════════════

    private void report_status (string message, string icon, string css) {
        Idle.add (() => {
            if (status_area != null) {
                status_area.set_status (message, icon, css);
            }
            return Source.REMOVE;
        });
    }

    private void report_error (string message) {
        report_status (message, StatusIcon.ERROR_ICON, StatusIcon.ERROR_CSS);
        log_line ("ERROR: " + message);

        Idle.add (() => {
            combine_failed (message);
            return Source.REMOVE;
        });
    }

    private void report_cancelled () {
        string cancel_message = runner.get_cancel_completion_message ();
        report_status (cancel_message,
            StatusIcon.CANCELLED_ICON, StatusIcon.CANCELLED_CSS);

        Idle.add (() => {
            combine_cancelled (cancel_message);
            return Source.REMOVE;
        });
    }

    private void update_progress (double percent) {
        if (tracker != null) {
            tracker.update_percent (percent);
        }
    }

    private void finish_progress () {
        if (tracker == null) return;
        Idle.add (() => {
            if (progress_bar != null) {
                progress_bar.set_visible (false);
            }
            return Source.REMOVE;
        });
    }

    private void reset_progress_display () {
        Idle.add (() => {
            if (progress_bar != null) {
                progress_bar.set_fraction (0.0);
                progress_bar.set_visible (false);
            }
            return Source.REMOVE;
        });
    }

    private void log_line (string message) {
        print ("%s\n", message);
        if (console_tab != null) {
            Idle.add (() => {
                console_tab.add_line (message);
                return Source.REMOVE;
            });
        }
    }

    private void log_runner_event (string message) {
        log_line (message);
    }

    private void cleanup_dir (string dir) {
        try {
            var d = Dir.open (dir);
            string? name;
            while ((name = d.read_name ()) != null) {
                FileUtils.unlink (Path.build_filename (dir, name));
            }
        } catch (FileError e) {
            // ignore
        }
        DirUtils.remove (dir);

        string managed_root = ConversionUtils.get_app_temp_root ();
        if (ConversionUtils.is_same_or_descendant_path (dir, managed_root)) {
            ConversionUtils.try_remove_empty_dir_chain (
                Path.get_dirname (dir), managed_root
            );
        }
    }

#if COMBINE_WINDOW_TEST_BUILD
    internal OperationOutputResult build_done_result_for_widget_test () {
        return build_done_result ();
    }

    internal void enable_ffmpeg_capture_for_widget_test (int exit_code = 0) {
        capture_ffmpeg_argv_for_test = true;
        captured_ffmpeg_exit_code_for_test = exit_code;
        last_ffmpeg_argv_for_test = {};
    }

    internal string[] get_last_ffmpeg_argv_for_widget_test () {
        return last_ffmpeg_argv_for_test;
    }

    internal int run_copy_mode_for_widget_test () {
        return run_copy_mode ();
    }

    internal int run_reencode_mode_for_widget_test () {
        return run_reencode_mode ();
    }

    internal bool get_peak_analysis_ran_for_widget_test () {
        return peak_analysis_ran_for_test;
    }

    internal string[] get_last_peak_analysis_argv_for_widget_test () {
        return last_peak_analysis_argv_for_test;
    }

    internal void force_write_chapters_file_failure_for_widget_test (bool enabled = true) {
        force_write_chapters_file_failure_for_test = enabled;
    }
#endif
}

// ═══════════════════════════════════════════════════════════════════════════════
//  CombineCodecBuilder + CombineCodecTab — Lightweight stubs for copy-mode
//  output path computation via ConversionUtils.compute_output_path()
// ═══════════════════════════════════════════════════════════════════════════════

public class CombineCodecBuilder : Object, ICodecBuilder {
    public string get_codec_name () { return "combined"; }
    public Object? snapshot_settings (GeneralSettingsSnapshot? general_settings = null) { return null; }
    public string[] build_codec_args_from_snapshot (Object? snapshot) { return {}; }
    public string[] get_codec_args () { return {}; }
}

public class CombineCodecTab : Object, ICodecTab {
    private string _container;
    private CombineCodecBuilder _builder = new CombineCodecBuilder ();

    public CombineCodecTab (string container) {
        _container = container;
    }

    public ICodecBuilder get_codec_builder () { return _builder; }
    public bool get_two_pass () { return false; }
    public string get_container () { return _container; }
    public CodecTabSettingsSnapshot snapshot_settings (GeneralSettingsSnapshot? general_settings = null) {
        return new CodecTabSettingsSnapshot ();
    }
    public KeyframeSettingsSnapshot snapshot_keyframe_settings (GeneralSettingsSnapshot? general_settings) {
        return new KeyframeSettingsSnapshot ();
    }
    public string[] get_audio_args () { return {}; }
}
