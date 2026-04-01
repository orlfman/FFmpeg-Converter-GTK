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
    public CombineEncodeProfileSnapshot? reencode_profile { get; set; default = null; }

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

        var done = new OperationOutputResult.for_file (output_path);
        Idle.add (() => {
            combine_done (done);
            return Source.REMOVE;
        });
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

        cmd += "-map_metadata";
        cmd += "0";

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

        string[] cmd = { AppSettings.get_default ().ffmpeg_path, "-y" };

        // ── Add each file as a separate input ───────────────────────────────
        for (int i = 0; i < files.length; i++) {
            cmd += "-i";
            cmd += files[i].path;
        }

        // ── Chapter metadata input ──────────────────────────────────────────
        if (chapters_path != null) {
            cmd += "-f";
            cmd += "ffmetadata";
            cmd += "-i";
            cmd += chapters_path;
        }

        // ── Determine normalization targets ─────────────────────────────────
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

        // ── Build filter_complex ────────────────────────────────────────────
        var fc = new StringBuilder ();

        for (int i = 0; i < files.length; i++) {
            var f = files[i];

            // Video chain
            var vf = new StringBuilder ();

            if (f.frame_rate != target_fps && target_fps.length > 0) {
                vf.append (@"fps=$(target_fps)");
            }

            if (f.pixel_format != target_pix_fmt && target_pix_fmt.length > 0) {
                if (vf.len > 0) vf.append (",");
                vf.append (@"format=$(target_pix_fmt)");
            }

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

            if (vf.len > 0) vf.append (",");
            vf.append ("setsar=1,settb=AVTB,setpts=PTS-STARTPTS");

            fc.append ("[%d:v:0]%s[v%d]; ".printf (i, vf.str, i));

            // Audio chain
            if (has_audio_target) {
                if (f.has_audio) {
                    var af = new StringBuilder ();

                    if (f.audio_sample_rate != target_sample_rate && target_sample_rate > 0) {
                        af.append (@"aresample=$(target_sample_rate)");
                    }

                    if (f.audio_channel_layout != target_layout && target_layout.length > 0) {
                        if (af.len > 0) af.append (",");
                        af.append (@"aformat=channel_layouts=$(target_layout)");
                    }

                    if (af.len > 0) af.append (",");
                    af.append ("asetpts=PTS-STARTPTS");

                    fc.append ("[%d:a:0]%s[a%d]; ".printf (i, af.str, i));
                } else {
                    // Generate silence for files without audio
                    string dur_str = ConversionUtils.format_ffmpeg_double (f.duration, "%.6f");
                    fc.append ("anullsrc=channel_layout=%s:sample_rate=%d[silence%d]; ".printf (
                        target_layout, target_sample_rate, i));
                    fc.append ("[silence%d]atrim=duration=%s,asetpts=PTS-STARTPTS[a%d]; ".printf (
                        i, dur_str, i));
                }
            }
        }

        // ── Combine filter (concat or crossfade) ────────────────────────────
        if (crossfade_enabled && files.length > 1) {
            build_crossfade_filters (fc, has_audio_target);
        } else {
            for (int i = 0; i < files.length; i++) {
                fc.append (@"[v$i]");
                if (has_audio_target) {
                    fc.append (@"[a$i]");
                }
            }

            int a_streams = has_audio_target ? 1 : 0;
            fc.append ("concat=n=%d:v=1:a=%d[outv]".printf (files.length, a_streams));
            if (has_audio_target) {
                fc.append ("[outa]");
            }
        }

        cmd += "-filter_complex";
        cmd += fc.str;

        cmd += "-map";
        cmd += "[outv]";
        if (has_audio_target) {
            cmd += "-map";
            cmd += "[outa]";
        }

        // ── Video codec args ────────────────────────────────────────────────
        if (reencode_profile != null) {
            string[] codec_args = CodecUtils.build_combine_codec_args_from_snapshot (
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

        // ── Audio codec args ────────────────────────────────────────────────
        if (!has_audio_target) {
            cmd += "-an";
        } else if (reencode_profile != null && reencode_profile.audio_args.length > 0) {
            foreach (string a in reencode_profile.audio_args) cmd += a;
        } else {
            cmd += "-c:a";
            cmd += "aac";
            cmd += "-b:a";
            cmd += "192k";
        }

        // ── Metadata ────────────────────────────────────────────────────────
        if (reencode_profile != null && reencode_profile.preserve_metadata) {
            cmd += "-map_metadata";
            cmd += "0";
        }

        // Chapter policy (request-level, not from reencode_profile)
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

        log_line (@"Using filter concat for $(files.length) files (re-encode mode)");
        int exit = execute_ffmpeg (cmd);

        if (reencode_tmp_dir != null) {
            cleanup_dir (reencode_tmp_dir);
        }

        return exit;
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
