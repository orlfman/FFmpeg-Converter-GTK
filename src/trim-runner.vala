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

    // ── Configuration (set before calling run) ──────────────────────────────
    public string input_file { get; set; }
    public string output_folder { get; set; }
    public bool copy_mode { get; set; default = true; }
    public bool keyframe_cut { get; set; default = true; }
    public bool export_separate { get; set; default = false; }
    public string output_suffix { get; set; default = "-trimmed"; }
    public string operation_label { get; set; default = "Trim export"; }
    public int video_width { get; set; default = 0; }
    public int video_height { get; set; default = 0; }

    // Re-encode snapshot (only used when some path needs encoding)
    public EncodeProfileSnapshot? reencode_profile { get; set; default = null; }

    // UI references
    public Label? status_label { get; set; default = null; }
    public ProgressBar? progress_bar { get; set; default = null; }
    public ConsoleTab? console_tab { get; set; default = null; }

    // ── Segments ────────────────────────────────────────────────────────────
    private GenericArray<TrimSegment> segments = new GenericArray<TrimSegment> ();

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

    private string last_output = "";

    private void log_runner_event (string text) {
        if (console_tab != null) {
            Idle.add (() => {
                console_tab.add_line (text);
                return Source.REMOVE;
            });
        }
    }

    // ── Signal ──────────────────────────────────────────────────────────────
    public signal void export_done (string output_path);
    public signal void export_failed (string message);

    // ═════════════════════════════════════════════════════════════════════════
    //  PUBLIC API
    // ═════════════════════════════════════════════════════════════════════════

    public void set_segments (GenericArray<TrimSegment> segs) {
        segments = segs;
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
            report_status ("⚠️ No segments defined — add at least one segment.");
            return;
        }
        if (input_file == null || input_file == "") {
            report_status ("⚠️ Please select an input file first!");
            return;
        }

        runner.set_event_logger (log_runner_event);
        runner.prepare_for_new_execution ();

        resolved_reencode_codec_args = null;

        // Fix #3: Create a ProgressTracker for consistent progress behavior
        if (progress_bar != null) {
            tracker = new ProgressTracker (progress_bar);
            tracker.reset_throttle ();
            tracker.show_determinate ();
        }

        new Thread<void> ("trim-export-thread", () => {
            run_internal ();
        });
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

        // ── PATH A: Concat filter (re-encode + multi-segment + combined) ─────
        // This is the most robust path: a single FFmpeg command that decodes
        // all segments, applies per-segment filters, and encodes once.
        // Note: audio copy is disabled in the UI when this path is active
        // (via AudioSettings.update_for_concat_filter), since -filter_complex
        // decodes audio and makes stream-copy impossible.
        bool use_concat_filter = !copy_mode && !export_separate && segments.length > 1;

        if (use_concat_filter) {
            string output_path = Path.build_filename (
                out_dir, @"$name_no_ext$(output_suffix)$out_ext"
            );

            report_status (@"🔄 $(operation_label) — encoding $(segments.length) segments…");
            update_progress (10.0);

            int exit = run_concat_filter_encode (output_path);
            if (exit != 0) {
                if (runner.is_cancelled ()) {
                    report_cancelled ();
                } else {
                    report_error (@"$(operation_label) failed (exit code $exit).");
                }
            } else {
                last_output = output_path;
                report_status (@"✅ $(operation_label) completed!\n\nSaved to:\n$output_path");
                update_progress (100.0);

                string done = output_path;
                Idle.add (() => {
                    export_done (done);
                    return Source.REMOVE;
                });
            }

            finish_progress ();
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

            // Track used filenames to deduplicate chapters with identical titles
            var used_names = new HashTable<string, bool> (str_hash, str_equal);

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
                    // Use chapter title for filename when available
                    string seg_name;
                    if (seg.label != null && seg.label.strip ().length > 0) {
                        string safe = sanitize_filename (seg.label);
                        string candidate = @"$name_no_ext-$safe";
                        // Deduplicate: append (2), (3)… on collision
                        if (used_names.contains (candidate)) {
                            int dup_count = 2;
                            string deduped = @"$candidate ($dup_count)";
                            while (used_names.contains (deduped)) {
                                dup_count++;
                                deduped = @"$candidate ($dup_count)";
                            }
                            candidate = deduped;
                        }
                        used_names.set (candidate, true);
                        seg_name = @"$candidate$out_ext";
                    } else {
                        seg_name = @"$name_no_ext-segment-$(pad_number (i + 1))$out_ext";
                    }
                    seg_output = Path.build_filename (out_dir, seg_name);
                } else if (direct_output) {
                    seg_output = Path.build_filename (
                        out_dir,
                        @"$name_no_ext$(output_suffix)$out_ext"
                    );
                } else {
                    seg_output = Path.build_filename (
                        tmp_dir,
                        @"segment_$(pad_number (i + 1))$out_ext"
                    );
                }

                report_status (@"🔄 Extracting $seg_label…");
                update_progress ((double) i / segments.length * 100.0);

                int exit = extract_segment (i, seg, seg_output);
                if (exit != 0) {
                    if (runner.is_cancelled ()) {
                        report_cancelled ();
                    } else {
                        report_error (@"$seg_label extraction failed (exit code $exit).");
                    }
                    return;
                }

                segment_files.add (seg_output);
                log_line (@"✅ $seg_label extracted → $seg_output");
            }

            // ── Phase 2: Concatenate (copy-mode multi-segment only) ──────────
            if (export_separate) {
                last_output = segment_files[0];
                report_status (@"✅ $(operation_label) completed — exported $(segments.length) files to:\n$out_dir");
            } else if (segments.length == 1) {
                // Single segment was written directly to the output path
                last_output = segment_files[0];
                report_status (@"✅ $(operation_label) completed!\n\nSaved to:\n$(segment_files[0])");
            } else {
                // Multi-segment copy mode → demuxer concat
                if (runner.is_cancelled ()) {
                    report_cancelled ();
                    return;
                }

                string concat_output = Path.build_filename (
                    out_dir,
                    @"$name_no_ext$(output_suffix)$out_ext"
                );
                last_output = concat_output;

                report_status ("🔄 Concatenating segments…");
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

                report_status (@"✅ $(operation_label) completed!\n\nSaved to:\n$concat_output");
            }

            update_progress (100.0);

            string done_path = last_output;
            Idle.add (() => {
                export_done (done_path);
                return Source.REMOVE;
            });

        } finally {
            if (!export_separate) {
                cleanup_dir (tmp_dir);
            } else {
                DirUtils.remove (tmp_dir);
            }

            finish_progress ();
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

        string general_af = get_general_audio_filters ();

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
                string af;
                if (general_af.length > 0) {
                    af = general_af + ",asetpts=PTS-STARTPTS";
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
        fc.append (@"concat=n=$(segments.length):v=1:a=$a_streams[outv]");
        if (!audio_disabled) {
            fc.append ("[outa]");
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
        if (should_preserve_metadata ()) {
            cmd += "-map_metadata";
            cmd += "0";
        }
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
            cmd += "-to";
            cmd += format_seconds (seg.end_time - seg.start_time);
        }

        if (!seg_reencode) {
            cmd += "-c:v";
            cmd += "copy";
            cmd += "-c:a";
            cmd += "copy";
        } else {
            string vf = build_segment_vf (seg);
            if (vf != "") {
                cmd += "-vf";
                cmd += vf;
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

            string af = get_general_audio_filters ();
            string[] audio_args = get_audio_args_with_filters (af);
            foreach (string a in audio_args) cmd += a;

            if (should_preserve_metadata ()) {
                cmd += "-map_metadata";
                cmd += "0";
            }
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

    private string build_segment_vf (TrimSegment seg) {
        string[] filters = {};

        if (seg.has_crop ()) {
            string c = seg.crop_value.strip ();
            if (c.has_prefix ("crop=")) c = c.substring (5);
            filters += "crop=" + c;
        }

        string general_vf = seg.has_crop ()
            ? get_general_video_filters_skip_crop ()
            : get_general_video_filters ();
        if (general_vf.length > 0) {
            filters += general_vf;
        }

        return string.joinv (",", filters);
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
        string full_cmd = string.joinv (" ", argv);
        log_line ("\n=== FFmpeg command ===\n" + full_cmd);
        if (console_tab != null) {
            console_tab.set_command (full_cmd);
        }

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

    private string get_general_audio_filters () {
        if (reencode_profile != null) {
            return reencode_profile.audio_filters;
        }
        return "";
    }

    private string get_general_video_filters () {
        if (reencode_profile != null) {
            return reencode_profile.video_filters;
        }
        return "";
    }

    private string get_general_video_filters_skip_crop () {
        if (reencode_profile != null) {
            return reencode_profile.video_filters_skip_crop;
        }
        return "";
    }

    private bool should_preserve_metadata () {
        return reencode_profile != null && reencode_profile.preserve_metadata;
    }

    private bool should_remove_chapters () {
        return reencode_profile != null && reencode_profile.remove_chapters;
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

        if (runner.is_cancelled ()) {
            tracker.hide_cancelled ();
        } else {
            tracker.hide ();
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Status reporting (always Idle.add for thread safety)
    // ═════════════════════════════════════════════════════════════════════════

    private void report_status (string message) {
        Idle.add (() => {
            if (status_label != null)
                status_label.set_text (message);
            return Source.REMOVE;
        });
        log_line (message);
    }

    private void report_cancelled () {
        string msg = @"$(operation_label) cancelled.";
        Idle.add (() => {
            if (status_label != null)
                status_label.set_text (@"⏹️ $msg");
            return Source.REMOVE;
        });
        log_line (@"⏹️ $msg");

        Idle.add (() => {
            export_failed (msg);
            return Source.REMOVE;
        });
    }

    private void report_error (string message) {
        Idle.add (() => {
            if (status_label != null)
                status_label.set_text (@"❌ $message\nCheck the console for details.");
            return Source.REMOVE;
        });
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

    private static string sanitize_filename (string name) {
        return ConversionUtils.sanitize_segment_name (name);
    }
}
