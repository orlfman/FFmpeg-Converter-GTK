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
    public bool export_separate { get; set; default = false; }
    public string output_suffix { get; set; default = "-trimmed"; }
    public string operation_label { get; set; default = "Trim export"; }
    public int video_width { get; set; default = 0; }
    public int video_height { get; set; default = 0; }

    // Re-encode delegates (only used when copy_mode == false)
    public ICodecBuilder? reencode_builder { get; set; default = null; }
    public ICodecTab? reencode_codec_tab { get; set; default = null; }
    public GeneralTab? general_tab { get; set; default = null; }

    // UI references
    public Label? status_label { get; set; default = null; }
    public ProgressBar? progress_bar { get; set; default = null; }
    public ConsoleTab? console_tab { get; set; default = null; }

    // ── Segments ────────────────────────────────────────────────────────────
    private GenericArray<TrimSegment> segments = new GenericArray<TrimSegment> ();

    // ── State ───────────────────────────────────────────────────────────────
    private bool cancelled = false;
    private Pid? current_pid = null;
    private string last_output = "";

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
     * Run the full trim/export pipeline on a background thread.
     * Safe to call from the main thread — starts its own Thread.
     */
    public void run () {
        cancelled = false;
        current_pid = null;

        if (segments.length == 0) {
            report_status ("⚠️ No segments defined — add at least one segment.");
            return;
        }
        if (input_file == null || input_file == "") {
            report_status ("⚠️ Please select an input file first!");
            return;
        }

        show_progress ();

        new Thread<void> ("trim-export-thread", () => {
            run_internal ();
        });
    }

    /**
     * Cancel any running FFmpeg process.
     */
    public void cancel () {
        cancelled = true;
        if (current_pid != null) {
            try {
                Posix.kill (current_pid, Posix.Signal.TERM);
            } catch (Error e) {
                // ignore
            }
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

        // ── PATH A: Concat filter (re-encode + multi-segment + combined) ─────
        // This is the most robust path: a single FFmpeg command that decodes
        // all segments, applies per-segment filters, and encodes once.
        bool use_concat_filter = !copy_mode && !export_separate && segments.length > 1;

        if (use_concat_filter) {
            string output_path = Path.build_filename (
                out_dir, @"$name_no_ext$(output_suffix)$out_ext"
            );

            report_status (@"🔄 $(operation_label) — encoding $(segments.length) segments…");
            update_progress_fraction (0.1);

            int exit = run_concat_filter_encode (output_path);
            if (exit != 0) {
                report_error (@"$(operation_label) failed (exit code $exit).");
            } else {
                last_output = output_path;
                report_status (@"✅ $(operation_label) completed!\n\nSaved to:\n$output_path");
                update_progress_fraction (1.0);

                string done = output_path;
                Idle.add (() => {
                    export_done (done);
                    return Source.REMOVE;
                });
            }

            hide_progress ();
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
                if (cancelled) {
                    report_status (@"⏹️ $(operation_label) cancelled.");
                    return;
                }

                var seg = segments[i];
                string seg_label = "Segment %d/%d".printf (i + 1, segments.length);

                // For single-segment non-separate exports, write directly to
                // final output path (avoids an unnecessary concat pass)
                bool direct_output = !export_separate && segments.length == 1;

                string seg_output;
                if (export_separate) {
                    seg_output = Path.build_filename (
                        out_dir,
                        @"$name_no_ext-segment-$(pad_number (i + 1))$out_ext"
                    );
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
                update_progress_fraction ((double) i / segments.length);

                int exit = extract_segment (seg, seg_output);
                if (exit != 0) {
                    report_error (@"$seg_label extraction failed (exit code $exit).");
                    return;
                }

                segment_files.add (seg_output);
                log_line (@"✅ $seg_label extracted → $seg_output");
            }

            // ── Phase 2: Concatenate (copy-mode multi-segment only) ──────────
            if (export_separate) {
                last_output = segment_files[0];
                report_status (@"✅ Exported $(segments.length) segments to:\n$out_dir");
            } else if (segments.length == 1) {
                // Single segment was written directly to the output path
                last_output = segment_files[0];
                report_status (@"✅ $(operation_label) completed!\n\nSaved to:\n$(segment_files[0])");
            } else {
                // Multi-segment copy mode → demuxer concat
                if (cancelled) {
                    report_status (@"⏹️ $(operation_label) cancelled.");
                    return;
                }

                string concat_output = Path.build_filename (
                    out_dir,
                    @"$name_no_ext$(output_suffix)$out_ext"
                );
                last_output = concat_output;

                report_status ("🔄 Concatenating segments…");
                update_progress_fraction (0.9);

                int concat_exit = concat_demuxer (segment_files, tmp_dir, concat_output);
                if (concat_exit != 0) {
                    report_error ("Concatenation failed (exit code %d).".printf (concat_exit));
                    return;
                }

                report_status (@"✅ $(operation_label) completed!\n\nSaved to:\n$concat_output");
            }

            update_progress_fraction (1.0);

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

            hide_progress ();
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PATH A — Single-pass concat filter encode
    //
    //  Builds a single FFmpeg command like:
    //
    //    ffmpeg -y
    //      -ss START0 -t DUR0 -i input.mp4
    //      -ss START1 -t DUR1 -i input.mp4
    //      -filter_complex "
    //        [0:v]crop=...,scale=...,setpts=PTS-STARTPTS[v0];
    //        [0:a]asetpts=PTS-STARTPTS[a0];
    //        [1:v]crop=...,scale=...,setpts=PTS-STARTPTS[v1];
    //        [1:a]asetpts=PTS-STARTPTS[a1];
    //        [v0][a0][v1][a1]concat=n=2:v=1:a=1[outv][outa]
    //      "
    //      -map [outv] -map [outa]
    //      <codec_args> <audio_codec_args>
    //      output.mkv
    //
    //  All segments are decoded, filtered, and concatenated within FFmpeg's
    //  filter graph in a single pass. The concat filter properly resets PTS,
    //  handles resolution differences, and produces clean segment transitions.
    // ═════════════════════════════════════════════════════════════════════════

    private int run_concat_filter_encode (string output) {
        string[] cmd = { "ffmpeg", "-y" };

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
        // The concat filter requires all inputs to have the same resolution.
        // Use the first segment's output dimensions as the target, then scale
        // all other segments to match.
        int target_w = 0;
        int target_h = 0;
        bool needs_scale_normalize = false;

        // Collect each segment's output dimensions
        int[] seg_widths  = new int[segments.length];
        int[] seg_heights = new int[segments.length];

        for (int i = 0; i < segments.length; i++) {
            parse_segment_output_size (segments[i], out seg_widths[i], out seg_heights[i]);
        }

        target_w = seg_widths[0];
        target_h = seg_heights[0];

        // Check if any segment differs from the target
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

        // Get the GeneralTab audio filter chain (normalize, speed, etc.)
        string general_af = (general_tab != null)
            ? FilterBuilder.build_audio_filter_chain (general_tab) : "";

        for (int i = 0; i < segments.length; i++) {
            var seg = segments[i];

            // ── Video chain for this segment ─────────────────────────────────
            // Per-segment crop + General-tab filters (scale, rotate, pix fmt, etc.)
            string vf = build_segment_vf (seg);

            // Scale to target resolution if segments have differing dimensions
            if (needs_scale_normalize && target_w > 0 && target_h > 0) {
                string scale_filter = "scale=%d:%d:force_original_aspect_ratio=decrease,setsar=1,pad=%d:%d:-1:-1:color=black".printf (
                    target_w, target_h, target_w, target_h);
                if (vf.length > 0) {
                    vf += "," + scale_filter;
                } else {
                    vf = scale_filter;
                }
            }

            // Append PTS reset at the end (ensures clean timestamps)
            if (vf.length > 0) {
                vf += ",setpts=PTS-STARTPTS";
            } else {
                vf = "setpts=PTS-STARTPTS";
            }

            fc.append (@"[$i:v]$(vf)[v$i]; ");

            // ── Audio chain for this segment (if audio enabled) ──────────────
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

        // ── Map output streams ───────────────────────────────────────────────
        cmd += "-map";
        cmd += "[outv]";
        if (!audio_disabled) {
            cmd += "-map";
            cmd += "[outa]";
        }

        // ── Video codec args ─────────────────────────────────────────────────
        if (reencode_builder != null && reencode_codec_tab != null) {
            string[] codec_args = reencode_builder.get_codec_args (reencode_codec_tab);

            if (general_tab != null) {
                foreach (string kf in reencode_codec_tab.resolve_keyframe_args (
                             input_file, general_tab)) {
                    codec_args += kf;
                }
            }

            foreach (string arg in codec_args) cmd += arg;
        } else {
            // Fallback default codec
            cmd += "-c:v";
            cmd += "libx264";
            cmd += "-crf";
            cmd += "18";
            cmd += "-preset";
            cmd += "medium";
        }

        // ── Audio codec args ─────────────────────────────────────────────────
        // With filter_complex, audio goes through the filter graph and MUST be
        // re-encoded. If the user's codec tab says "-c:a copy", we substitute
        // a sensible default.
        if (audio_disabled) {
            cmd += "-an";
        } else {
            string[] audio_codec = get_audio_codec_args_for_concat ();
            foreach (string a in audio_codec) cmd += a;
        }

        // ── Metadata ─────────────────────────────────────────────────────────
        if (general_tab != null) {
            if (general_tab.preserve_metadata.active) {
                cmd += "-map_metadata";
                cmd += "0";
            }
            if (general_tab.remove_chapters.active) {
                cmd += "-map_chapters";
                cmd += "-1";
            }
        }

        cmd += "-progress";
        cmd += "pipe:2";
        cmd += output;

        log_line (@"🎬 Using concat filter for $(segments.length) segments (single-pass encode)");
        return execute_ffmpeg (cmd);
    }

    /**
     * Get audio codec args suitable for the concat filter path.
     * The concat filter requires decoded audio, so "-c:a copy" cannot be used.
     * In that case, substitute a sensible default encoder.
     */
    private string[] get_audio_codec_args_for_concat () {
        string[] audio_args = get_audio_args ();

        // Can't use copy with filter_complex — audio must be re-encoded
        if (audio_args.length >= 2 && audio_args[0] == "-c:a" && audio_args[1] == "copy") {
            // Determine a good fallback based on the output container
            string container = (reencode_codec_tab != null)
                ? reencode_codec_tab.get_container () : "mkv";

            if (container == "webm") {
                return { "-c:a", "libopus", "-b:a", "128k" };
            }
            return { "-c:a", "aac", "-b:a", "192k" };
        }

        // Strip any -af entries — audio filters are in the filter_complex now
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

    private int extract_segment (TrimSegment seg, string output) {
        string[] cmd = { "ffmpeg", "-y" };

        // Seek to start (input seeking = fast for copy mode)
        cmd += "-ss";
        cmd += format_seconds (seg.start_time);

        cmd += "-i";
        cmd += input_file;

        // Duration of this segment
        cmd += "-to";
        cmd += format_seconds (seg.end_time - seg.start_time);

        // Determine if THIS segment needs re-encoding
        bool seg_has_crop = seg.has_crop ();
        bool seg_reencode = !copy_mode || seg_has_crop;

        if (!seg_reencode) {
            // Stream copy — no re-encoding
            cmd += "-c:v";
            cmd += "copy";
            cmd += "-c:a";
            cmd += "copy";
        } else {
            // Re-encode with chosen codec + filters
            // Build the video filter chain, prepending crop if present
            string vf = build_segment_vf (seg);
            if (vf != "") {
                cmd += "-vf";
                cmd += vf;
            }

            if (reencode_builder != null && reencode_codec_tab != null) {
                string[] codec_args = reencode_builder.get_codec_args (reencode_codec_tab);

                if (general_tab != null) {
                    foreach (string kf in reencode_codec_tab.resolve_keyframe_args (
                                 input_file, general_tab)) {
                        codec_args += kf;
                    }
                }

                foreach (string arg in codec_args) cmd += arg;
            } else {
                // Fallback — if no codec builder but we need re-encode (crop-only case),
                // use a sensible default
                cmd += "-c:v";
                cmd += "libx264";
                cmd += "-crf";
                cmd += "18";
                cmd += "-preset";
                cmd += "medium";
            }

            // Audio (with filter chain merged in)
            string af = (general_tab != null)
                ? FilterBuilder.build_audio_filter_chain (general_tab) : "";
            string[] audio_args = get_audio_args_with_filters (af);
            foreach (string a in audio_args) cmd += a;

            // Metadata
            if (general_tab != null) {
                if (general_tab.preserve_metadata.active) {
                    cmd += "-map_metadata";
                    cmd += "0";
                }
                if (general_tab.remove_chapters.active) {
                    cmd += "-map_chapters";
                    cmd += "-1";
                }
            }
        }

        cmd += "-progress";
        cmd += "pipe:2";
        cmd += output;

        return execute_ffmpeg (cmd);
    }

    /**
     * Build the -vf chain for a single segment, injecting the segment's
     * crop filter before the rest of the General-tab filter chain.
     */
    private string build_segment_vf (TrimSegment seg) {
        string[] filters = {};

        // 1. Per-segment crop (injected FIRST — before any other transforms)
        if (seg.has_crop ()) {
            string c = seg.crop_value.strip ();
            if (c.has_prefix ("crop=")) c = c.substring (5);
            filters += "crop=" + c;
        }

        // 2. General-tab video filter chain (scale, rotate, pixel format, etc.)
        if (general_tab != null) {
            string general_vf = FilterBuilder.build_video_filter_chain (general_tab, seg.has_crop ());
            if (general_vf.length > 0) {
                filters += general_vf;
            }
        }

        return string.joinv (",", filters);
    }

    /**
     * Determine the output dimensions for a segment after its crop is applied.
     * If the segment has a crop "W:H:X:Y", returns (W, H).
     * If no crop, returns the video's native dimensions.
     */
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
                string safe_path = segment_files[i].replace ("'", "'\\''");
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
            "ffmpeg", "-y",
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
    //  INTERNAL — FFmpeg process execution
    // ═════════════════════════════════════════════════════════════════════════

    private int execute_ffmpeg (string[] argv) {
        try {
            var launcher = new SubprocessLauncher (SubprocessFlags.STDERR_PIPE);
            var process = launcher.spawnv (argv);
            current_pid = (Pid) int.parse (process.get_identifier () ?? "0");

            var reader = new DataInputStream (process.get_stderr_pipe ());

            string line;
            while ((line = reader.read_line (null)) != null) {
                string clean = line.strip ();
                if (clean.length == 0) continue;

                bool is_noisy = clean.has_prefix ("frame=") || clean.has_prefix ("fps=") ||
                                clean.has_prefix ("stream_") || clean.has_prefix ("bitrate=") ||
                                clean.has_prefix ("total_size=") || clean.has_prefix ("out_time") ||
                                clean.has_prefix ("dup_frames=") || clean.has_prefix ("drop_frames=") ||
                                clean.has_prefix ("speed=") || clean.has_prefix ("progress=");

                if (!is_noisy || clean.contains ("Lsize=") || clean.contains ("Error") ||
                    clean.contains ("Warning") || clean.contains ("failed")) {
                    log_line (clean);
                }
            }

            process.wait ();

            string full_cmd = string.joinv (" ", argv);
            log_line ("\n=== FFmpeg command ===\n" + full_cmd);
            if (console_tab != null) {
                console_tab.set_command (full_cmd);
            }

            current_pid = null;
            return process.get_exit_status ();

        } catch (Error e) {
            log_line ("❌ FFmpeg launch error: " + e.message);
            current_pid = null;
            return -1;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Audio args helpers
    // ═════════════════════════════════════════════════════════════════════════

    private string[] get_audio_args_with_filters (string af) {
        string[] audio_args = get_audio_args ();

        if (af == "") return audio_args;

        if (audio_args.length > 0 && (audio_args[0] == "-an" ||
            (audio_args.length >= 2 && audio_args[0] == "-c:a" && audio_args[1] == "copy")))
            return audio_args;

        string[] merged = {};
        bool found_af = false;
        for (int i = 0; i < audio_args.length; i++) {
            if (audio_args[i] == "-af" && i + 1 < audio_args.length) {
                merged += "-af";
                merged += af + "," + audio_args[i + 1];
                i++;
                found_af = true;
            } else {
                merged += audio_args[i];
            }
        }

        if (!found_af) {
            merged += "-af";
            merged += af;
        }

        return merged;
    }

    private string[] get_audio_args () {
        if (reencode_codec_tab != null) {
            return reencode_codec_tab.get_audio_args ();
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

        if (reencode_codec_tab != null) {
            string container = reencode_codec_tab.get_container ();
            if (container.length > 0) return "." + container;
        }

        return ".mkv";
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — UI update helpers (always Idle.add for thread safety)
    // ═════════════════════════════════════════════════════════════════════════

    private void report_status (string message) {
        Idle.add (() => {
            if (status_label != null)
                status_label.set_text (message);
            return Source.REMOVE;
        });
        log_line (message);
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

    private void show_progress () {
        Idle.add (() => {
            if (progress_bar != null) {
                progress_bar.set_visible (true);
                progress_bar.set_fraction (0.0);
                progress_bar.set_text (@"$(operation_label)…");
            }
            return Source.REMOVE;
        });
    }

    private void update_progress_fraction (double fraction) {
        Idle.add (() => {
            if (progress_bar != null) {
                progress_bar.set_fraction (fraction.clamp (0.0, 1.0));
                progress_bar.set_text ("%.0f%%".printf (fraction * 100.0));
            }
            return Source.REMOVE;
        });
    }

    private void hide_progress () {
        Idle.add (() => {
            if (progress_bar != null) {
                progress_bar.set_fraction (1.0);
                progress_bar.set_text ("Done");
                Timeout.add (800, () => {
                    progress_bar.set_visible (false);
                    progress_bar.set_text ("Waiting…");
                    return Source.REMOVE;
                });
            }
            return Source.REMOVE;
        });
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
        if (n < 10) return "00" + n.to_string ();
        if (n < 100) return "0" + n.to_string ();
        return n.to_string ();
    }

    private static void cleanup_dir (string path) {
        try {
            var dir = Dir.open (path);
            string? name;
            while ((name = dir.read_name ()) != null) {
                string full = Path.build_filename (path, name);
                FileUtils.unlink (full);
            }
            DirUtils.remove (path);
        } catch (Error e) {
            // Best-effort cleanup
        }
    }
}
