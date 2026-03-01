using Gtk;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  TrimRunner — Multi-segment FFmpeg extraction and concatenation
//
//  Workflow for N segments:
//    1. Create a temp directory.
//    2. For each segment, run FFmpeg with -ss/-to to extract it.
//    3. If not exporting separately:
//       a. Write a concat demuxer file listing all segment outputs.
//       b. Run FFmpeg with -f concat to join them into one file.
//    4. Clean up temp files (unless exporting separately).
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
                    report_status ("⏹️ Trim export cancelled.");
                    return;
                }

                var seg = segments[i];
                string seg_label = "Segment %d/%d".printf (i + 1, segments.length);

                string seg_output;
                if (export_separate) {
                    // Final named files go directly to output dir
                    seg_output = Path.build_filename (
                        out_dir,
                        @"$name_no_ext-segment-$(pad_number (i + 1))$out_ext"
                    );
                } else {
                    // Temp files for later concatenation
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

            // ── Phase 2: Concatenate (unless exporting separately) ───────────
            if (export_separate) {
                last_output = segment_files[0];
                report_status (@"✅ Exported $(segments.length) segments to:\n$out_dir");
            } else {
                if (cancelled) {
                    report_status ("⏹️ Trim export cancelled.");
                    return;
                }

                string concat_output = Path.build_filename (
                    out_dir,
                    @"$name_no_ext-trimmed$out_ext"
                );
                last_output = concat_output;

                report_status ("🔄 Concatenating segments…");
                update_progress_fraction (0.9);

                int concat_exit = concat_segments (segment_files, tmp_dir, concat_output);
                if (concat_exit != 0) {
                    report_error ("Concatenation failed (exit code %d).".printf (concat_exit));
                    return;
                }

                report_status (@"✅ Trim export completed!\n\nSaved to:\n$concat_output");
            }

            update_progress_fraction (1.0);

            // Notify main thread
            string done_path = last_output;
            Idle.add (() => {
                export_done (done_path);
                return Source.REMOVE;
            });

        } finally {
            // ── Cleanup temp dir ─────────────────────────────────────────────
            if (!export_separate) {
                cleanup_dir (tmp_dir);
            } else {
                // Just remove the empty temp dir
                DirUtils.remove (tmp_dir);
            }

            hide_progress ();
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Segment extraction
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

        if (copy_mode) {
            // Stream copy — no re-encoding
            cmd += "-c:v";
            cmd += "copy";
            cmd += "-c:a";
            cmd += "copy";
        } else {
            // Re-encode with chosen codec + filters
            if (general_tab != null) {
                string vf = FilterBuilder.build_video_filter_chain (general_tab);
                if (vf != "") {
                    cmd += "-vf";
                    cmd += vf;
                }
            }

            if (reencode_builder != null && reencode_codec_tab != null) {
                string[] codec_args = reencode_builder.get_codec_args (reencode_codec_tab);

                // Resolve keyframe args via the interface
                if (general_tab != null) {
                    foreach (string kf in reencode_codec_tab.resolve_keyframe_args (
                                 input_file, general_tab)) {
                        codec_args += kf;
                    }
                }

                foreach (string arg in codec_args) cmd += arg;
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

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Concatenation
    // ═════════════════════════════════════════════════════════════════════════

    private int concat_segments (GenericArray<string> segment_files,
                                 string tmp_dir,
                                 string output) {
        // Write the concat demuxer list file
        string list_path = Path.build_filename (tmp_dir, "concat_list.txt");

        try {
            var sb = new StringBuilder ();
            for (int i = 0; i < segment_files.length; i++) {
                // Escape single quotes in the path
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

        // Run concat
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

                // Filter noisy progress lines from the console
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
    //  INTERNAL — Audio args helper
    // ═════════════════════════════════════════════════════════════════════════

    private string[] get_audio_args_with_filters (string af) {
        string[] audio_args = get_audio_args ();

        if (af == "") return audio_args;

        // Cannot apply audio filters when audio is disabled or stream-copied
        if (audio_args.length > 0 && (audio_args[0] == "-an" ||
            (audio_args.length >= 2 && audio_args[0] == "-c:a" && audio_args[1] == "copy")))
            return audio_args;

        // Merge with any -af already emitted by audio-settings
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
            // Preserve input container for stream copy
            return input_ext;
        }

        // Re-encode: use the codec tab's container
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
                progress_bar.set_text ("Trimming…");
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
