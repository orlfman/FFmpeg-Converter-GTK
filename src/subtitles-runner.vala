using Gtk;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  SubtitleStream — Parsed data for a single subtitle track in the input file
// ═══════════════════════════════════════════════════════════════════════════════

public class SubtitleStream : Object {
    public int    stream_index   { get; set; default = -1; }   // absolute index in container
    public int    sub_index      { get; set; default = 0; }    // relative subtitle index (0, 1, 2…)
    public string codec_name     { get; set; default = ""; }
    public string language       { get; set; default = ""; }
    public string title          { get; set; default = ""; }
    public bool   is_default     { get; set; default = false; }
    public bool   is_forced      { get; set; default = false; }
    public bool   marked_remove  { get; set; default = false; }

    public string display_label () {
        var parts = new GenericArray<string> ();
        parts.add (@"#$(sub_index)");
        if (codec_name.length > 0) parts.add (codec_name);
        if (language.length > 0 && language != "und") parts.add (language);
        if (title.length > 0) parts.add (@"\"$(title)\"");
        if (is_default) parts.add ("[default]");
        if (is_forced) parts.add ("[forced]");
        return string.joinv ("  ·  ", parts.data);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  ExternalSubtitle — A subtitle file the user wants to add
// ═══════════════════════════════════════════════════════════════════════════════

public class ExternalSubtitle : Object {
    public string file_path  { get; set; default = ""; }
    public string language   { get; set; default = "eng"; }
    public string title      { get; set; default = ""; }
    public bool   is_default { get; set; default = false; }
    public bool   is_forced  { get; set; default = false; }
    public bool   is_bitmap  { get; set; default = false; }

    /**
     * Guess whether a subtitle file is bitmap-based from its extension.
     * .sup = PGS (Blu-ray bitmap), .idx/.sub pair = VobSub (DVD bitmap).
     * Note: .sub alone is ambiguous (could be MicroDVD text) — defaults to
     * bitmap since VobSub is far more common for that extension.
     */
    public static bool guess_bitmap_from_path (string path) {
        string lower = path.down ();
        return lower.has_suffix (".sup") || lower.has_suffix (".sub");
    }

    public string display_label () {
        string basename = Path.get_basename (file_path);
        var parts = new GenericArray<string> ();
        parts.add (basename);
        if (language.length > 0) parts.add (language);
        if (title.length > 0) parts.add (@"\"$(title)\"");
        if (is_default) parts.add ("[default]");
        if (is_forced) parts.add ("[forced]");
        return string.joinv ("  ·  ", parts.data);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SubtitlesRunner — FFmpeg operations for subtitle stream management
//
//  Operations:
//   • Probe:   Discover subtitle streams via ffprobe
//   • Extract: Pull a single subtitle track to a standalone file
//   • Remux:   Copy video+audio, apply subtitle add/remove/reorder changes
//
//  Uses ProcessRunner for thread-safe FFmpeg execution with proper
//  cancellation and PID management.
// ═══════════════════════════════════════════════════════════════════════════════

public class SubtitlesRunner : Object {

    private ProcessRunner runner = new ProcessRunner ();

    // UI references (nullable — set before run)
    public Label?       status_label { get; set; default = null; }
    public ProgressBar? progress_bar { get; set; default = null; }
    public ConsoleTab?  console_tab  { get; set; default = null; }

    // Signals
    public signal void operation_done (string output_path);
    public signal void operation_failed (string message);

    // ═════════════════════════════════════════════════════════════════════════
    //  PROBE — Discover subtitle streams in an input file (synchronous)
    //
    //  Called from load_video()'s background thread.  Returns the parsed
    //  stream list directly — the caller is responsible for marshalling
    //  back to the main thread via Idle.add().
    // ═════════════════════════════════════════════════════════════════════════

    public GenericArray<SubtitleStream> probe_sync (string input_file) {
        var streams = new GenericArray<SubtitleStream> ();

        try {
            string[] cmd = {
                AppSettings.get_default ().ffprobe_path,
                "-v", "error",
                "-show_streams",
                "-select_streams", "s",
                input_file
            };

            string stdout_buf, stderr_buf;
            int status;

            Process.spawn_sync (null, cmd, null,
                                SpawnFlags.SEARCH_PATH,
                                null, out stdout_buf, out stderr_buf, out status);

            if (status != 0 || stdout_buf == null) return streams;

            HashTable<string, string>? current = null;
            int sub_idx = 0;

            foreach (string raw in stdout_buf.split ("\n")) {
                string line = raw.strip ();

                if (line == "[STREAM]") {
                    current = new HashTable<string, string> (str_hash, str_equal);
                } else if (line == "[/STREAM]") {
                    if (current != null) {
                        var s = new SubtitleStream ();
                        s.sub_index    = sub_idx++;
                        s.stream_index = int.parse (current.get ("index") ?? "-1");
                        s.codec_name   = current.get ("codec_name") ?? "";
                        s.language     = current.get ("TAG:language") ?? "";
                        s.title        = current.get ("TAG:title") ?? "";

                        string disp_default = current.get ("disposition:default") ?? "0";
                        s.is_default = (disp_default == "1");

                        string disp_forced = current.get ("disposition:forced") ?? "0";
                        s.is_forced = (disp_forced == "1");

                        streams.add (s);
                    }
                    current = null;
                } else if (current != null) {
                    int eq = line.index_of_char ('=');
                    if (eq > 0) {
                        string key = line.substring (0, eq).strip ();
                        string val = line.substring (eq + 1).strip ();
                        current.set (key, val);
                    }
                }
            }
        } catch (Error e) {
            log_line ("ffprobe error: " + e.message);
        }

        return streams;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  EXTRACT — Pull a subtitle track to a standalone file
    // ═════════════════════════════════════════════════════════════════════════

    public void extract_subtitle (string input_file,
                                  SubtitleStream stream,
                                  string output_path) {
        runner.reset ();
        report_status (@"🔄 Extracting subtitle track #$(stream.sub_index)…");

        new Thread<void> ("subtitle-extract", () => {
            string[] cmd = {
                AppSettings.get_default ().ffmpeg_path, "-y",
                "-i", input_file,
                "-map", @"0:s:$(stream.sub_index)",
                "-c:s", "copy",
                output_path
            };

            log_line ("=== Subtitle Extract ===");
            log_line (string.joinv (" ", cmd));

            int exit = runner.execute (cmd, (line) => {
                log_line (line);
            });

            if (runner.is_cancelled ()) {
                report_status ("⏹️ Extraction cancelled.");
                return;
            }

            if (exit != 0) {
                string codec = stream.codec_name.down ();
                string out_lower = output_path.down ();
                bool text_output = out_lower.has_suffix (".srt")
                                || out_lower.has_suffix (".ass")
                                || out_lower.has_suffix (".ssa")
                                || out_lower.has_suffix (".vtt");

                if (is_bitmap_codec (codec) && text_output) {
                    // No point retrying — bitmap → text requires OCR
                    report_error (
                        "Cannot extract bitmap subtitles to a text format.\n\n" +
                        @"This track uses $(stream.codec_name), which is an image-based " +
                        "format. Converting to SRT, ASS, or VTT would require OCR " +
                        "(optical character recognition), which FFmpeg does not support.\n\n" +
                        "Use \"Copy Original\" to extract the track in its native format (.sup)."
                    );
                    return;
                }

                // Retry without -c:s copy for codec mismatches (e.g. mov_text → srt)
                report_status (@"🔄 Retrying extraction with codec conversion…");
                string[] retry_cmd = {
                    AppSettings.get_default ().ffmpeg_path, "-y",
                    "-i", input_file,
                    "-map", @"0:s:$(stream.sub_index)",
                    output_path
                };
                exit = runner.execute (retry_cmd, (line) => {
                    log_line (line);
                });
            }

            string result_path = output_path;
            if (exit == 0) {
                // Verify the output file isn't empty — FFmpeg can exit 0
                // but produce an empty file when converting bitmap subs
                // (PGS, VobSub, DVB) to text formats (SRT, ASS, VTT).
                int64 file_size = 0;
                try {
                    var info = File.new_for_path (output_path)
                        .query_info ("standard::size", FileQueryInfoFlags.NONE);
                    file_size = info.get_size ();
                } catch (Error e) {
                    // File doesn't exist at all
                }

                if (file_size == 0) {
                    // Clean up the empty file
                    FileUtils.remove (output_path);
                    report_error (
                        "Extraction produced an empty file.\n\n" +
                        "This usually means the source is a bitmap subtitle format " +
                        "(PGS, VobSub, DVB) which cannot be converted to a text format " +
                        "like SRT or ASS — that would require OCR.\n\n" +
                        "Try extracting with \"Copy Original\" to preserve the original format."
                    );
                } else {
                    report_status (@"✅ Subtitle extracted!\n\nSaved to:\n$result_path");
                    Idle.add (() => {
                        operation_done (result_path);
                        return Source.REMOVE;
                    });
                }
            } else {
                report_error (@"Extraction failed (exit code $exit).");
            }
        });
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  EXTRACT ALL — Pull every subtitle track to individual files
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Extract all subtitle tracks using Copy Original (native codec).
     * Each track is saved as: {output_dir}/{base}.{lang}.track{N}.{ext}
     *
     * @param input_file   Source video
     * @param output_dir   Directory to write extracted files
     * @param base_name    Filename stem (no extension) for output files
     * @param streams      The subtitle streams to extract
     */
    public void extract_all_subtitles (string input_file,
                                       string output_dir,
                                       string base_name,
                                       GenericArray<SubtitleStream> streams) {
        runner.reset ();
        report_status (@"🔄 Extracting all $(streams.length) subtitle tracks…");

        // Snapshot streams for background thread
        var snap = new GenericArray<SubtitleStream> ();
        for (int i = 0; i < streams.length; i++)
            snap.add (streams[i]);

        new Thread<void> ("subtitle-extract-all", () => {
            int success = 0;
            int failed = 0;

            for (int i = 0; i < snap.length; i++) {
                if (runner.is_cancelled ()) {
                    report_status (@"⏹️ Extraction cancelled after $success of $(snap.length) tracks.");
                    return;
                }

                var s = snap[i];
                string ext = native_extension_for_codec (s.codec_name.down ());
                string lang_part = (s.language.length > 0 && s.language != "und")
                    ? @".$(s.language)" : "";
                string out_path = Path.build_filename (
                    output_dir, @"$(base_name)$(lang_part).track$(s.sub_index)$(ext)");

                report_status (@"🔄 Extracting track #$(s.sub_index) ($(i + 1)/$(snap.length))…");

                string[] cmd = {
                    AppSettings.get_default ().ffmpeg_path, "-y",
                    "-i", input_file,
                    "-map", @"0:s:$(s.sub_index)",
                    "-c:s", "copy",
                    out_path
                };

                log_line (@"=== Extract All — Track #$(s.sub_index) ===");
                log_line (string.joinv (" ", cmd));

                int exit = runner.execute (cmd, (line) => {
                    log_line (line);
                });

                if (exit == 0) {
                    success++;
                } else {
                    log_line (@"⚠ Track #$(s.sub_index) failed (exit $exit), skipping.");
                    failed++;
                }
            }

            if (runner.is_cancelled ()) {
                report_status (@"⏹️ Extraction cancelled after $success of $(snap.length) tracks.");
                return;
            }

            string msg = @"✅ Extracted $success of $(snap.length) subtitle tracks";
            if (failed > 0) msg += @" ($failed failed)";
            msg += @"\n\nSaved to:\n$output_dir";
            report_status (msg);

            Idle.add (() => {
                operation_done (output_dir);
                return Source.REMOVE;
            });
        });
    }

    /** Map a subtitle codec name to its native file extension. */
    public static string native_extension_for_codec (string codec) {
        if (codec == "subrip" || codec == "srt")              return ".srt";
        if (codec == "ass" || codec == "ssa")                  return ".ass";
        if (codec == "webvtt")                                 return ".vtt";
        if (codec == "mov_text")                               return ".srt";
        if (codec == "hdmv_pgs_subtitle" || codec == "pgssub") return ".sup";
        if (codec == "dvd_subtitle" || codec == "dvdsub")      return ".sub";
        if (codec == "dvb_subtitle" || codec == "dvbsub")      return ".sub";
        return ".srt";
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  REMUX — Apply subtitle changes (add/remove/reorder) without re-encoding
    //
    //  Copies video and audio streams untouched; only subtitle streams are
    //  modified according to the user's configuration.
    // ═════════════════════════════════════════════════════════════════════════

    public void remux_subtitles (string input_file,
                                 string output_path,
                                 GenericArray<SubtitleStream> existing_streams,
                                 GenericArray<ExternalSubtitle> added_subs,
                                 GenericArray<int> final_order) {
        runner.reset ();
        report_status ("🔄 Applying subtitle changes…");

        // Create tracker on main thread (GTK widgets must not be touched from bg)
        ProgressTracker? tracker = null;
        if (progress_bar != null) {
            tracker = new ProgressTracker (progress_bar);
            tracker.reset_throttle ();
            tracker.show_pulse ();
        }

        // Snapshot all data for the background thread
        var snap_existing = new GenericArray<SubtitleStream> ();
        for (int i = 0; i < existing_streams.length; i++)
            snap_existing.add (existing_streams[i]);

        var snap_added = new GenericArray<ExternalSubtitle> ();
        for (int i = 0; i < added_subs.length; i++)
            snap_added.add (added_subs[i]);

        var snap_order = new GenericArray<int> ();
        for (int i = 0; i < final_order.length; i++)
            snap_order.add (final_order[i]);

        new Thread<void> ("subtitle-remux", () => {
            run_remux (input_file, output_path, snap_existing, snap_added, snap_order, tracker);
        });
    }

    private void run_remux (string input_file,
                            string output_path,
                            GenericArray<SubtitleStream> existing,
                            GenericArray<ExternalSubtitle> added,
                            GenericArray<int> order,
                            ProgressTracker? tracker) {

        // Probe duration for progress tracking
        double duration = probe_duration (input_file);
        if (tracker != null) {
            if (duration > 0) {
                tracker.switch_to_determinate ();
            }
        }

        // Build command:
        //   ffmpeg -y -i input [-i sub1.srt] [-i sub2.ass]
        //     -map 0:v -map 0:a
        //     -map 0:s:0 -map 0:s:2 -map 1:0 ...  (ordered subtitle maps)
        //     -c:v copy -c:a copy -c:s copy
        //     -metadata:s:s:0 language=eng -metadata:s:s:0 title="..."
        //     -disposition:s:0 default ...
        //     output.mkv

        string[] cmd = { AppSettings.get_default ().ffmpeg_path, "-y" };

        // Input 0 = main video file
        cmd += "-i"; cmd += input_file;

        // Additional inputs for external subtitle files
        // input_index 1, 2, 3… correspond to added[0], added[1], added[2]…
        for (int i = 0; i < added.length; i++) {
            cmd += "-i"; cmd += added[i].file_path;
        }

        // Map all video and audio streams from input 0
        cmd += "-map"; cmd += "0:v?";
        cmd += "-map"; cmd += "0:a?";

        // Build subtitle maps in the requested order
        // order[] contains indices where:
        //   0..existing.length-1 = existing stream at that sub_index
        //   existing.length..N   = added subtitle at index (val - existing.length)
        bool has_subtitle_maps = false;
        for (int i = 0; i < order.length; i++) {
            int idx = order[i];

            if (idx < existing.length) {
                // Existing stream — skip if marked for removal
                var s = existing[idx];
                if (s.marked_remove) continue;

                cmd += "-map"; cmd += @"0:s:$(s.sub_index)";
                has_subtitle_maps = true;
            } else {
                // External subtitle file
                int ext_idx = idx - existing.length;
                if (ext_idx >= 0 && ext_idx < added.length) {
                    int input_num = 1 + ext_idx;
                    cmd += "-map"; cmd += @"$(input_num):0";
                    has_subtitle_maps = true;
                }
            }
        }

        // If no subtitle maps were added, explicitly disable subtitles
        if (!has_subtitle_maps) {
            cmd += "-sn";
        }

        // Copy all codecs (no re-encoding)
        cmd += "-c:v"; cmd += "copy";
        cmd += "-c:a"; cmd += "copy";

        // For subtitles: choose the right codec for the target container.
        //  • MP4/M4V → mov_text (only text subtitle format MP4 supports)
        //  • WebM    → webvtt   (only subtitle format WebM supports)
        //  • MKV/other → copy   (MKV supports virtually all subtitle formats)
        string out_ext = output_path.down ();
        if (out_ext.has_suffix (".mp4") || out_ext.has_suffix (".m4v")) {
            cmd += "-c:s"; cmd += "mov_text";
        } else if (out_ext.has_suffix (".webm")) {
            cmd += "-c:s"; cmd += "webvtt";
        } else {
            cmd += "-c:s"; cmd += "copy";
        }

        // Apply metadata and disposition for each output subtitle stream
        int meta_idx = 0;
        for (int i = 0; i < order.length; i++) {
            int idx = order[i];

            string lang = "";
            string stitle = "";
            bool def = false;
            bool forced = false;

            if (idx < existing.length) {
                var s = existing[idx];
                if (s.marked_remove) continue;
                lang   = s.language;
                stitle = s.title;
                def    = s.is_default;
                forced = s.is_forced;
            } else {
                int ext_idx = idx - existing.length;
                if (ext_idx >= 0 && ext_idx < added.length) {
                    var ext = added[ext_idx];
                    lang   = ext.language;
                    stitle = ext.title;
                    def    = ext.is_default;
                    forced = ext.is_forced;
                }
            }

            // Language metadata
            if (lang.length > 0) {
                cmd += @"-metadata:s:s:$(meta_idx)";
                cmd += @"language=$(lang)";
            }

            // Title metadata
            if (stitle.length > 0) {
                cmd += @"-metadata:s:s:$(meta_idx)";
                cmd += @"title=$(stitle)";
            }

            // Disposition flags
            string disp = "0";
            if (def && forced)      disp = "default+forced";
            else if (def)           disp = "default";
            else if (forced)        disp = "forced";
            cmd += @"-disposition:s:$(meta_idx)";
            cmd += disp;

            meta_idx++;
        }

        cmd += "-progress";
        cmd += "pipe:2";
        cmd += output_path;

        log_line ("=== Subtitle Remux ===");
        log_line (string.joinv (" ", cmd));

        bool saw_format_mismatch = false;
        int exit = runner.execute (cmd, (line) => {
            if (ConversionUtils.should_log_ffmpeg_line (line)) {
                log_line (line);
            }

            if (line.contains ("only possible from text to text or bitmap to bitmap")) {
                saw_format_mismatch = true;
            }

            // Progress parsing
            if (tracker != null && duration > 0) {
                double current = parse_progress_time (line);
                if (current >= 0) {
                    tracker.update_from_time (current, duration, 0.0, 100.0);
                }
            }
        });

        // Cleanup tracker
        if (tracker != null) {
            if (runner.is_cancelled ()) {
                tracker.hide_cancelled ();
            } else {
                tracker.hide ();
            }
        }

        if (runner.is_cancelled ()) {
            report_status ("⏹️ Remux cancelled.");
            return;
        }

        string result = output_path;
        if (exit == 0) {
            report_status (@"✅ Subtitle changes applied!\n\nSaved to:\n$result");
            Idle.add (() => {
                operation_done (result);
                return Source.REMOVE;
            });
        } else if (saw_format_mismatch) {
            report_error (
                "Subtitle format mismatch — cannot convert between text and bitmap formats.\n\n" +
                "Text formats (SRT, ASS, VTT) and bitmap formats (PGS, VobSub, DVB) " +
                "are not interchangeable. Use a container that supports the original format (MKV is safest), " +
                "or use Burn In mode to hardcode bitmap subtitles into the video."
            );
        } else {
            report_error (@"Remux failed (exit code $exit).");
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  BURN IN — Hardcode subtitles into video frames (full re-encode)
    //
    //  Two filter paths:
    //   • Text subs (SRT, ASS, VTT, SSA):  -vf "subtitles=..."
    //   • Bitmap subs (PGS, VobSub, DVB):  -filter_complex "[0:v][0:s:N]overlay"
    //
    //  All config is snapshot on the main thread and passed as params
    //  to avoid cross-thread widget access.
    // ═════════════════════════════════════════════════════════════════════════

    public void burn_in_subtitle (string input_file,
                                   string output_path,
                                   int sub_stream_index,
                                   string? external_sub_path,
                                   bool is_bitmap,
                                   owned string[] codec_args,
                                   owned string[] audio_args,
                                   string video_filters,
                                   string audio_filters,
                                   bool preserve_metadata,
                                   bool remove_chapters) {
        runner.reset ();
        report_status ("🔄 Burning in subtitles (full re-encode)…");

        // Create tracker on main thread (GTK widgets must not be touched from bg)
        ProgressTracker? tracker = null;
        if (progress_bar != null) {
            tracker = new ProgressTracker (progress_bar);
            tracker.reset_throttle ();
            tracker.show_pulse ();
        }

        new Thread<void> ("subtitle-burn-in", () => {
            // Probe duration for progress tracking
            double duration = probe_duration (input_file);

            if (tracker != null) {
                if (duration > 0) {
                    tracker.switch_to_determinate ();
                }
            }

            // ── Build FFmpeg command ─────────────────────────────────────────
            string[] cmd = { AppSettings.get_default ().ffmpeg_path, "-y" };

            bool has_external_bitmap = (external_sub_path != null && is_bitmap);

            cmd += "-i";
            cmd += input_file;

            // External bitmap subs need a second input
            if (has_external_bitmap) {
                cmd += "-i";
                cmd += external_sub_path;
            }

            // ── Determine audio state ────────────────────────────────────────
            bool audio_disabled = (audio_args.length > 0 && audio_args[0] == "-an");

            // ── Build subtitle filter + combine with general video filters ───
            if (is_bitmap) {
                // Bitmap path → -filter_complex with overlay
                string overlay_src;
                if (has_external_bitmap) {
                    overlay_src = "[0:v][1:0]overlay";
                } else {
                    overlay_src = @"[0:v][0:s:$(sub_stream_index)]overlay";
                }

                string fc;
                if (video_filters.length > 0) {
                    fc = overlay_src + "," + video_filters + "[outv]";
                } else {
                    fc = overlay_src + "[outv]";
                }

                cmd += "-filter_complex";
                cmd += fc;
                cmd += "-map";
                cmd += "[outv]";
                if (!audio_disabled) {
                    cmd += "-map";
                    cmd += "0:a?";
                }
            } else {
                // Text path → -vf with subtitles= filter
                string sub_filter;
                if (external_sub_path != null) {
                    sub_filter = "subtitles=" + escape_filter_path (external_sub_path);
                } else {
                    sub_filter = "subtitles=" + escape_filter_path (input_file)
                                 + @":si=$(sub_stream_index)";
                }

                string full_vf;
                if (video_filters.length > 0) {
                    full_vf = sub_filter + "," + video_filters;
                } else {
                    full_vf = sub_filter;
                }

                cmd += "-vf";
                cmd += full_vf;
                cmd += "-map";
                cmd += "0:v";
                if (!audio_disabled) {
                    cmd += "-map";
                    cmd += "0:a?";
                }
            }

            // ── Codec args ───────────────────────────────────────────────────
            foreach (string arg in codec_args) cmd += arg;

            // ── Audio args (merged with General-tab audio filters) ───────────
            if (audio_disabled) {
                cmd += "-an";
            } else {
                string[] merged = FilterBuilder.merge_audio_filters (audio_filters, audio_args);
                foreach (string a in merged) cmd += a;
            }

            // ── Metadata ─────────────────────────────────────────────────────
            if (preserve_metadata) { cmd += "-map_metadata"; cmd += "0"; }
            if (remove_chapters)   { cmd += "-map_chapters"; cmd += "-1"; }

            cmd += "-progress";
            cmd += "pipe:2";
            cmd += output_path;

            log_line ("=== Subtitle Burn-In ===");
            log_line (string.joinv (" ", cmd));
            if (console_tab != null) {
                string full_cmd = string.joinv (" ", cmd);
                Idle.add (() => {
                    console_tab.set_command (full_cmd);
                    return Source.REMOVE;
                });
            }

            bool saw_format_mismatch = false;
            int exit = runner.execute (cmd, (line) => {
                // Log interesting lines only
                if (ConversionUtils.should_log_ffmpeg_line (line)) {
                    log_line (line);
                }

                if (line.contains ("only possible from text to text or bitmap to bitmap")) {
                    saw_format_mismatch = true;
                }

                // Progress parsing
                if (tracker != null && duration > 0) {
                    double current = parse_progress_time (line);
                    if (current >= 0) {
                        tracker.update_from_time (current, duration, 0.0, 100.0);
                    }
                }
            });

            // Cleanup tracker
            if (tracker != null) {
                if (runner.is_cancelled ()) {
                    tracker.hide_cancelled ();
                } else {
                    tracker.hide ();
                }
            }

            if (runner.is_cancelled ()) {
                report_status ("⏹️ Burn-in cancelled.");
                return;
            }

            if (exit == 0) {
                string result = output_path;
                report_status (@"✅ Subtitles burned in!\n\nSaved to:\n$result");
                Idle.add (() => {
                    operation_done (result);
                    return Source.REMOVE;
                });
            } else if (saw_format_mismatch) {
                report_error (
                    "Subtitle format mismatch — cannot convert between text and bitmap formats.\n\n" +
                    "Text formats (SRT, ASS, VTT) and bitmap formats (PGS, VobSub, DVB) " +
                    "are not interchangeable. For bitmap subtitles, make sure the burn-in track " +
                    "is correctly detected as bitmap — the overlay filter will be used automatically."
                );
            } else {
                report_error (@"Burn-in failed (exit code $exit).");
            }
        });
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CANCEL
    // ═════════════════════════════════════════════════════════════════════════

    public void cancel () {
        runner.cancel ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  STATUS HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    /** Check if a codec is a bitmap-based subtitle format. */
    public static bool is_bitmap_codec (string codec) {
        return codec == "hdmv_pgs_subtitle"
            || codec == "pgssub"
            || codec == "dvd_subtitle"
            || codec == "dvdsub"
            || codec == "dvb_subtitle"
            || codec == "dvbsub"
            || codec == "xsub";
    }

    private void report_status (string message) {
        Idle.add (() => {
            if (status_label != null)
                status_label.set_text (message);
            return Source.REMOVE;
        });
        log_line (message);
    }

    private void report_error (string message) {
        log_line ("❌ " + message);

        string err = message;
        Idle.add (() => {
            if (status_label != null)
                status_label.set_text (@"❌ $err\nCheck the console for details.");
            operation_failed (err);
            return Source.REMOVE;
        });
    }

    private void log_line (string text) {
        if (console_tab != null) {
            Idle.add (() => {
                console_tab.add_line (text);
                return Source.REMOVE;
            });
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  BURN-IN HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    /** Probe video duration in seconds (runs synchronously — call from bg thread). */
    private double probe_duration (string input_file) {
        try {
            string[] cmd = {
                AppSettings.get_default ().ffprobe_path,
                "-v", "quiet",
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
            log_line ("ffprobe duration error: " + e.message);
        }
        return 0.0;
    }

    /**
     * Escape a file path for use inside FFmpeg's subtitles= filter option.
     *
     * FFmpeg filter syntax has two escaping levels:
     *  • Option-value level:  \  :  '  =       (separator/quoting chars)
     *  • Filter-graph level:  [  ]  ;  ,       (link labels, chain/graph separators)
     *
     * All of these must be backslash-escaped so the filter parser reads
     * the path literally.
     */
    private static string escape_filter_path (string path) {
        var sb = new StringBuilder ();
        for (int i = 0; i < path.length; i++) {
            uint8 c = path.data[i];
            if (c == '\\' || c == ':' || c == '\'' || c == '=' ||
                c == '['  || c == ']' || c == ';'  || c == ',') {
                sb.append_c ('\\');
            }
            sb.append_c ((char) c);
        }
        return sb.str;
    }

    /** Parse FFmpeg progress output for current encoding position. */
    private static double parse_progress_time (string line) {
        if (line.has_prefix ("out_time_us=")) {
            string val = line.substring ("out_time_us=".length).strip ();
            int64 us = int64.parse (val);
            return us / 1000000.0;
        }
        if (line.has_prefix ("out_time=")) {
            string val = line.substring ("out_time=".length).strip ();
            return ConversionUtils.parse_ffmpeg_timestamp (val);
        }
        return -1.0;
    }
}
