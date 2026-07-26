using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  ChapterInfo — Data object representing a single embedded chapter marker
// ═══════════════════════════════════════════════════════════════════════════════

public class ChapterInfo : Object {
    public int    index      { get; set; default = 0; }
    public string title      { get; set; default = ""; }
    public double start_time { get; set; default = 0.0; }
    public double end_time   { get; set; default = 0.0; }
    public bool   selected   { get; set; default = false; }

    public ChapterInfo (int index, string title, double start, double end) {
        this.index      = index;
        this.title      = title;
        this.start_time = start;
        this.end_time   = end;
    }

    public double get_duration () {
        return (end_time - start_time).clamp (0.0, double.MAX);
    }
}

public class AudioStreamsProbeResult : Object {
    public bool success { get; set; default = false; }
    public string error_message { get; set; default = ""; }
    public double duration_seconds { get; set; default = 0.0; }
    public GenericArray<AudioStreamInfo> streams { get; private set; }

    public AudioStreamsProbeResult () {
        streams = new GenericArray<AudioStreamInfo> ();
    }
}

namespace FfprobeUtils {

    private string summarize_ffprobe_text (string? text, int max_len = 200) {
        if (text == null)
            return "";

        string summary = text.strip ().replace ("\n", " | ");
        if (summary.length > max_len)
            return summary.substring (0, max_len) + "...";

        return summary;
    }

    private void log_ffprobe_debug (string event, string[] cmd, string? detail = null) {
        string cmd_text = ConversionUtils.format_command_for_display (cmd);
        if (detail != null && detail.length > 0) {
            debug ("FfprobeUtils: %s: %s | cmd=%s", event, detail, cmd_text);
        } else {
            debug ("FfprobeUtils: %s | cmd=%s", event, cmd_text);
        }
    }

    private bool run_ffprobe_sync (string[] cmd,
                                   out string stdout_text,
                                   out string stderr_text) {
        stdout_text = "";
        stderr_text = "";
        int status = -1;

        try {
            Process.spawn_sync (null, cmd, null, SpawnFlags.SEARCH_PATH,
                                null, out stdout_text, out stderr_text, out status);
        } catch (Error e) {
            log_ffprobe_debug ("sync spawn failed", cmd, e.message);
            return false;
        }

        if (status != 0) {
            string stderr_summary = summarize_ffprobe_text (stderr_text);
            string detail = "exit=%d".printf (status);
            if (stderr_summary.length > 0)
                detail = @"$detail stderr=$stderr_summary";
            log_ffprobe_debug ("sync probe failed", cmd, detail);
            return false;
        }

        if (stdout_text == null) {
            log_ffprobe_debug ("sync probe returned null stdout", cmd);
            return false;
        }

        return true;
    }

    private async bool run_ffprobe_async (string[] cmd,
                                          Cancellable? cancellable,
                                          out string stdout_text,
                                          out string stderr_text) {
        stdout_text = "";
        stderr_text = "";

        try {
            var launcher = new SubprocessLauncher (
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            var proc = SubprocessCompat.spawnv (launcher, cmd);

            try {
                yield proc.communicate_utf8_async (null, cancellable,
                                                   out stdout_text, out stderr_text);
            } catch (Error e) {
                if (cancellable != null && cancellable.is_cancelled ()) {
                    log_ffprobe_debug ("async probe cancelled", cmd);
                } else {
                    log_ffprobe_debug ("async communication failed", cmd, e.message);
                }
                proc.force_exit ();
                return false;
            }

            if (!proc.get_successful ()) {
                string detail;
                if (proc.get_if_exited ()) {
                    detail = "exit=%d".printf (proc.get_exit_status ());
                } else if (proc.get_if_signaled ()) {
                    detail = "signal=%d".printf (proc.get_term_sig ());
                } else {
                    detail = "subprocess unsuccessful";
                }

                string stderr_summary = summarize_ffprobe_text (stderr_text);
                if (stderr_summary.length > 0)
                    detail = @"$detail stderr=$stderr_summary";

                log_ffprobe_debug ("async probe failed", cmd, detail);
                return false;
            }

            if (stdout_text == null) {
                log_ffprobe_debug ("async probe returned null stdout", cmd);
                return false;
            }

            return true;
        } catch (Error e) {
            log_ffprobe_debug ("async spawn failed", cmd, e.message);
            return false;
        }
    }

    internal int infer_bit_depth_from_pix_fmt (string pix_fmt) {
        string pix = pix_fmt.down ().strip ();

        if (pix.contains ("p16") || pix.contains ("16le") || pix.contains ("16be"))
            return 16;
        if (pix.contains ("p14") || pix.contains ("14le") || pix.contains ("14be"))
            return 14;
        if (pix.contains ("p12") || pix.contains ("12le") || pix.contains ("12be"))
            return 12;
        if (pix.contains ("p10") || pix.contains ("10le") || pix.contains ("10be"))
            return 10;
        if (pix.contains ("p9") || pix.contains ("9le") || pix.contains ("9be"))
            return 9;

        return 8;
    }

    private int parse_video_bit_depth_output (string stdout_text) {
        if (stdout_text == null || stdout_text.strip ().length == 0)
            return 0;

        try {
            var parser = new Json.Parser ();
            parser.load_from_data (stdout_text);

            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
                return 0;

            var root_obj = root.get_object ();
            if (!root_obj.has_member ("streams"))
                return 0;

            var streams = root_obj.get_array_member ("streams");
            if (streams == null || streams.get_length () == 0)
                return 0;

            var stream = streams.get_object_element (0);
            if (stream == null)
                return 0;

            string bits_raw = stream.get_string_member_with_default ("bits_per_raw_sample", "");
            if (bits_raw != null && bits_raw.strip ().length > 0) {
                int bits = 0;
                if (int.try_parse (bits_raw.strip (), out bits) && bits > 0)
                    return bits;
            }

            string pix_fmt = stream.get_string_member_with_default ("pix_fmt", "");
            if (pix_fmt != null && pix_fmt.strip ().length > 0)
                return infer_bit_depth_from_pix_fmt (pix_fmt);
        } catch (Error e) {
            debug ("FfprobeUtils: failed to parse bit-depth probe output: %s | stdout=%s",
                   e.message, summarize_ffprobe_text (stdout_text));
        }

        return 0;
    }

    private double parse_ffprobe_fps_output (string stdout_text) {
        if (stdout_text == null)
            return 0.0;

        string raw = stdout_text.strip ();
        if (raw.length == 0)
            return 0.0;

        // Typical output: "24000/1001" or "30/1" or "29.97"
        if (raw.contains ("/")) {
            string[] parts = raw.split ("/");
            if (parts.length >= 2) {
                double num = 0.0;
                double den = 0.0;
                if (double.try_parse (parts[0].strip (), out num)
                    && double.try_parse (parts[1].strip (), out den)
                    && den > 0.0) {
                    return num / den;
                }
            }
        }

        double plain = 0.0;
        if (double.try_parse (raw, out plain) && plain > 0.0)
            return plain;

        debug ("FfprobeUtils: invalid fps probe output: %s",
               summarize_ffprobe_text (stdout_text));
        return 0.0;
    }

    private double parse_ffprobe_duration_output (string stdout_text) {
        if (stdout_text == null)
            return 0.0;

        string raw = stdout_text.strip ();
        if (raw.length == 0)
            return 0.0;

        double dur = 0.0;
        if (double.try_parse (raw, out dur) && dur > 0.0)
            return dur;

        debug ("FfprobeUtils: invalid duration probe output: %s",
               summarize_ffprobe_text (stdout_text));
        return 0.0;
    }

    private string? parse_ffprobe_title_output (string stdout_text) {
        if (stdout_text == null || stdout_text.strip ().length == 0)
            return null;

        try {
            var parser = new Json.Parser ();
            parser.load_from_data (stdout_text);

            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
                return null;

            var root_obj = root.get_object ();

            // Prefer format-level title
            if (root_obj.has_member ("format")) {
                var format = root_obj.get_object_member ("format");
                if (format != null && format.has_member ("tags")) {
                    var tags = format.get_object_member ("tags");
                    if (tags != null && tags.has_member ("title")) {
                        string title = tags.get_string_member ("title");
                        if (title != null && title.strip ().length > 0)
                            return title.strip ();
                    }
                }
            }

            // Fall back to first video stream title
            if (root_obj.has_member ("streams")) {
                var streams = root_obj.get_array_member ("streams");
                if (streams != null && streams.get_length () > 0) {
                    var stream = streams.get_object_element (0);
                    if (stream != null && stream.has_member ("tags")) {
                        var tags = stream.get_object_member ("tags");
                        if (tags != null && tags.has_member ("title")) {
                            string title = tags.get_string_member ("title");
                            if (title != null && title.strip ().length > 0)
                                return title.strip ();
                        }
                    }
                }
            }
        } catch (Error e) {
            debug ("FfprobeUtils: failed to parse title probe output: %s | stdout=%s",
                   e.message, summarize_ffprobe_text (stdout_text));
        }

        return null;
    }

    private GenericArray<ChapterInfo> parse_ffprobe_chapters_output (string stdout_text) {
        var chapters = new GenericArray<ChapterInfo> ();

        if (stdout_text == null || stdout_text.strip ().length == 0)
            return chapters;

        try {
            var parser = new Json.Parser ();
            parser.load_from_data (stdout_text);

            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
                return chapters;

            var root_obj = root.get_object ();
            if (!root_obj.has_member ("chapters"))
                return chapters;

            var chapter_array = root_obj.get_array_member ("chapters");
            if (chapter_array == null)
                return chapters;

            for (uint i = 0; i < chapter_array.get_length (); i++) {
                var ch = chapter_array.get_object_element (i);
                if (ch == null)
                    continue;

                string start_raw =
                    ch.get_string_member_with_default ("start_time", "0");
                string end_raw =
                    ch.get_string_member_with_default ("end_time", "0");
                double start = 0.0;
                double end = 0.0;

                if (!double.try_parse (start_raw, out start)
                    || !double.try_parse (end_raw, out end)) {
                    debug ("FfprobeUtils: invalid chapter timing at index %u: start=%s end=%s",
                           i, summarize_ffprobe_text (start_raw), summarize_ffprobe_text (end_raw));
                    continue;
                }

                string title = "Chapter %u".printf (i + 1);
                if (ch.has_member ("tags")) {
                    var tags = ch.get_object_member ("tags");
                    if (tags != null && tags.has_member ("title")) {
                        string t = tags.get_string_member ("title");
                        if (t != null && t.strip ().length > 0)
                            title = t.strip ();
                    }
                }

                if (end > start) {
                    chapters.add (new ChapterInfo ((int) i, title, start, end));
                }
            }
        } catch (Error e) {
            debug ("FfprobeUtils: failed to parse chapter probe output: %s | stdout=%s",
                   e.message, summarize_ffprobe_text (stdout_text));
        }

        return chapters;
    }

    private AudioStreamProbeResult parse_primary_audio_stream_output (string stdout_text) {
        var result = new AudioStreamProbeResult ();
        if (stdout_text == null) {
            return result;
        }

        string cleaned = stdout_text.strip ();
        if (cleaned.length == 0) {
            result.presence = MediaStreamPresence.ABSENT;
            return result;
        }

        string[] lines = cleaned.split ("\n");
        foreach (unowned string line in lines) {
            string[] parts = line.strip ().split (",");
            if (parts.length == 0) {
                continue;
            }

            string codec = parts[0].strip ();
            if (codec.length == 0) {
                continue;
            }

            result.presence = MediaStreamPresence.PRESENT;
            result.codec_name = codec.down ();
            if (parts.length >= 2) {
                result.sample_fmt = parts[1].strip ().down ();
            }
            if (parts.length >= 3) {
                int channels = 0;
                if (int.try_parse (parts[2].strip (), out channels) && channels > 0) {
                    result.channels = channels;
                }
            }
            if (parts.length >= 4) {
                int bits_per_raw_sample = 0;
                if (int.try_parse (parts[3].strip (), out bits_per_raw_sample)
                    && bits_per_raw_sample > 0) {
                    result.bits_per_raw_sample = bits_per_raw_sample;
                }
            }
            return result;
        }

        result.presence = MediaStreamPresence.ABSENT;
        return result;
    }

    private AudioStreamsProbeResult parse_all_audio_streams_output (string stdout_text) {
        var result = new AudioStreamsProbeResult ();

        if (stdout_text == null || stdout_text.strip ().length == 0) {
            result.success = true;
            return result;
        }

        try {
            var parser = new Json.Parser ();
            parser.load_from_data (stdout_text);

            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                result.error_message = "ffprobe returned malformed audio stream data.";
                return result;
            }

            var root_obj = root.get_object ();
            if (root_obj.has_member ("format")) {
                var format = root_obj.get_object_member ("format");
                if (format != null) {
                    string duration_str = format.get_string_member_with_default ("duration", "0");
                    double duration = 0.0;
                    if (double.try_parse (duration_str, out duration) && duration > 0.0) {
                        result.duration_seconds = duration;
                    }
                }
            }
            if (!root_obj.has_member ("streams")) {
                result.error_message = "ffprobe audio stream data did not contain a streams array.";
                return result;
            }

            var stream_array = root_obj.get_array_member ("streams");
            if (stream_array == null) {
                result.error_message = "ffprobe returned an invalid audio streams array.";
                return result;
            }

            int audio_idx = 0;
            for (uint i = 0; i < stream_array.get_length (); i++) {
                var s = stream_array.get_object_element (i);
                if (s == null)
                    continue;

                var info = new AudioStreamInfo ();
                info.audio_index = audio_idx++;
                info.codec_name = s.get_string_member_with_default ("codec_name", "");
                info.channels = (int) s.get_int_member_with_default ("channels", 0);
                info.sample_fmt = s.get_string_member_with_default ("sample_fmt", "").down ();

                string bits_str = s.get_string_member_with_default ("bits_per_raw_sample", "");
                int bits = 0;
                if (bits_str.strip ().length > 0 && int.try_parse (bits_str, out bits) && bits > 0) {
                    info.bits_per_raw_sample = bits;
                }

                string sr_str = s.get_string_member_with_default ("sample_rate", "0");
                int sr = 0;
                if (int.try_parse (sr_str, out sr))
                    info.sample_rate = sr;

                if (s.has_member ("tags")) {
                    var tags = s.get_object_member ("tags");
                    if (tags != null) {
                        info.language = tags.get_string_member_with_default ("language", "");
                    }
                }

                result.streams.add (info);
            }
            result.success = true;
        } catch (Error e) {
            result.error_message = "Failed to parse ffprobe audio stream data.";
            debug ("FfprobeUtils: failed to parse audio streams probe: %s | stdout=%s",
                   e.message, summarize_ffprobe_text (stdout_text));
        }

        return result;
    }

#if FFPROBE_UTILS_TEST_BUILD
    internal AudioStreamProbeResult parse_primary_audio_stream_output_for_test (string stdout_text) {
        return parse_primary_audio_stream_output (stdout_text);
    }

    internal AudioStreamsProbeResult parse_all_audio_streams_output_for_test (string stdout_text) {
        return parse_all_audio_streams_output (stdout_text);
    }
#endif

    /**
     * Probe the source video stream bit depth. Returns 0 on failure.
     *
     * Prefers bits_per_raw_sample when ffprobe exposes it, then falls back to
     * inferring from the pixel-format name.
     */
    public async int probe_video_bit_depth_async (string input_file,
                                                  Cancellable? cancellable = null) {
        string[] cmd = {
            AppSettings.get_default ().ffprobe_path,
            "-v", "quiet",
            "-print_format", "json",
            "-select_streams", "v:0",
            "-show_entries", "stream=bits_per_raw_sample,pix_fmt",
            input_file
        };
        string stdout_text;
        string stderr_text;

        if (!(yield run_ffprobe_async (cmd, cancellable, out stdout_text, out stderr_text)))
            return 0;

        return parse_video_bit_depth_output (stdout_text);
    }

    /**
     * Probe the frame rate of the first video stream in @input_file
     * using ffprobe.  Returns 0.0 on any failure so callers can fall
     * back to a default.
     */
    public async double probe_input_fps_async (string input_file,
                                               Cancellable? cancellable = null) {
        string[] cmd = {
            AppSettings.get_default ().ffprobe_path,
            "-v", "quiet",
            "-select_streams", "v:0",
            "-show_entries", "stream=r_frame_rate",
            "-of", "csv=p=0",
            input_file
        };
        string stdout_text;
        string stderr_text;

        if (!(yield run_ffprobe_async (cmd, cancellable, out stdout_text, out stderr_text)))
            return 0.0;

        return parse_ffprobe_fps_output (stdout_text);
    }

    public double probe_input_fps (string input_file) {
        string[] cmd = {
            AppSettings.get_default ().ffprobe_path,
            "-v", "quiet",
            "-select_streams", "v:0",
            "-show_entries", "stream=r_frame_rate",
            "-of", "csv=p=0",
            input_file
        };
        string stdout_text;
        string stderr_text;

        if (!run_ffprobe_sync (cmd, out stdout_text, out stderr_text))
            return 0.0;

        return parse_ffprobe_fps_output (stdout_text);
    }

    public bool has_video_stream (string input_file) {
        string[] cmd = {
            AppSettings.get_default ().ffprobe_path,
            "-v", "quiet",
            "-select_streams", "v:0",
            "-show_entries", "stream=index",
            "-of", "csv=p=0",
            input_file
        };
        string stdout_text;
        string stderr_text;

        if (!run_ffprobe_sync (cmd, out stdout_text, out stderr_text))
            return false;

        return stdout_text.strip ().length > 0;
    }

    /**
     * Probe the total duration of @input_file in seconds using ffprobe.
     * Returns 0.0 on any failure so callers can treat it as "unknown duration"
     * and fall back to pulse-mode progress.
     *
     * Previously lived in Converter — moved here so any component that needs
     * duration (Converter, TrimRunner, SubtitlesRunner) can use it without
     * depending on Converter.
     */
    public async double probe_duration_async (string input_file,
                                              Cancellable? cancellable = null) {
        string[] cmd = {
            AppSettings.get_default ().ffprobe_path,
            "-v", "quiet",
            "-print_format", "csv=p=0",
            "-show_entries", "format=duration",
            input_file
        };
        string stdout_buf;
        string stderr_buf;

        if (!(yield run_ffprobe_async (cmd, cancellable, out stdout_buf, out stderr_buf)))
            return 0.0;

        return parse_ffprobe_duration_output (stdout_buf);
    }

    public async AudioStreamProbeResult probe_primary_audio_stream_async (
        string input_file,
        Cancellable? cancellable = null) {
        var result = new AudioStreamProbeResult ();
        string[] cmd = {
            AppSettings.get_default ().ffprobe_path,
            "-v", "quiet",
            "-select_streams", "a:0",
            "-show_entries", "stream=codec_name,channels,sample_fmt,bits_per_raw_sample",
            "-of", "csv=p=0",
            input_file
        };
        string stdout_text;
        string stderr_text;

        if (!(yield run_ffprobe_async (cmd, cancellable, out stdout_text, out stderr_text))) {
            result.presence = MediaStreamPresence.ERROR;
            return result;
        }

        return parse_primary_audio_stream_output (stdout_text);
    }

    /**
     * Verify that a file ffmpeg just wrote is actually usable.
     *
     * ffmpeg's exit status is not sufficient evidence that an encode produced
     * anything. When a filter chain yields no frames — a trim starting past
     * the end of the real content, a concat whose every segment falls outside
     * the decodable range — ffmpeg reports:
     *
     *     "Output file is empty, nothing was encoded"
     *
     * and **exits 0**, leaving a header-only container behind (measured: 262
     * bytes for MP4, 581 for Matroska). Callers that trust the exit code then
     * tell the user their conversion succeeded and hand them an unplayable
     * file.
     *
     * (Encoder-open failures — x264 refusing odd dimensions, say — DO exit
     * non-zero, 187 and 183 respectively, so those are already caught. The
     * empty-output case is the one that slips through.)
     *
     * Size alone cannot decide it either: a header-only file is small but not
     * zero, and a legitimately tiny clip is also small. Asking ffprobe for a
     * duration is what actually separates them — it fails outright on the
     * stubs above.
     *
     * @reason is a short user-facing explanation when the file is unusable.
     */
    public bool output_file_is_usable (string path, out string reason) {
        reason = "";

        if (path.length == 0 || !FileUtils.test (path, FileTest.EXISTS)) {
            reason = "FFmpeg reported success but no output file was created.";
            return false;
        }

        int64 size = 0;
        try {
            var info = File.new_for_path (path).query_info (
                FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
            size = info.get_size ();
        } catch (Error e) {
            reason = "The output file could not be read: %s".printf (e.message);
            return false;
        }
        if (size <= 0) {
            reason = "FFmpeg reported success but the output file is empty.";
            return false;
        }

        // The decisive check. A header-only container has a plausible size but
        // no readable duration.
        if (probe_duration (path) <= 0.0) {
            reason = "FFmpeg reported success but the output contains no media "
                   + "— it may have been asked to encode a range with no frames "
                   + "in it.";
            return false;
        }

        return true;
    }

    public double probe_duration (string input_file) {
        string[] cmd = {
            AppSettings.get_default ().ffprobe_path,
            "-v", "quiet",
            "-print_format", "csv=p=0",
            "-show_entries", "format=duration",
            input_file
        };
        string stdout_buf;
        string stderr_buf;

        if (!run_ffprobe_sync (cmd, out stdout_buf, out stderr_buf))
            return 0.0;

        return parse_ffprobe_duration_output (stdout_buf);
    }

    /**
     * Probe the "title" tag from a media file's format-level metadata.
     *
     * Queries both format-level and stream-level tags in a single ffprobe
     * call.  Prefers the format title; falls back to the first video
     * stream title.  Returns null if no title is found so callers can
     * fall back to the filename.
     */
    public async string? probe_title_async (string input_file,
                                            Cancellable? cancellable = null) {
        string[] cmd = {
            AppSettings.get_default ().ffprobe_path,
            "-v", "quiet",
            "-print_format", "json",
            "-show_entries", "format_tags=title:stream_tags=title",
            "-select_streams", "v:0",
            input_file
        };
        string stdout_text;
        string stderr_text;

        if (!(yield run_ffprobe_async (cmd, cancellable, out stdout_text, out stderr_text)))
            return null;

        return parse_ffprobe_title_output (stdout_text);
    }

    public string? probe_title (string input_file) {
        string[] cmd = {
            AppSettings.get_default ().ffprobe_path,
            "-v", "quiet",
            "-print_format", "json",
            "-show_entries", "format_tags=title:stream_tags=title",
            "-select_streams", "v:0",
            input_file
        };
        string stdout_text;
        string stderr_text;

        if (!run_ffprobe_sync (cmd, out stdout_text, out stderr_text))
            return null;

        return parse_ffprobe_title_output (stdout_text);
    }

    /**
     * Probe embedded chapter markers from @input_file using ffprobe.
     *
     * Uses JSON output for reliable parsing of chapter start/end times
     * and titles.  Returns an empty array on failure or if the file has
     * no chapters.
     *
     * Typical ffprobe JSON structure:
     *   { "chapters": [ { "start_time": "0.000", "end_time": "180.000",
     *                      "tags": { "title": "Intro" } }, … ] }
     */
    public async GenericArray<ChapterInfo> probe_chapters_async (string input_file,
                                                                 Cancellable? cancellable = null) {
        string[] cmd = {
            AppSettings.get_default ().ffprobe_path,
            "-v", "quiet",
            "-print_format", "json",
            "-show_chapters",
            input_file
        };
        string stdout_text;
        string stderr_text;

        if (!(yield run_ffprobe_async (cmd, cancellable, out stdout_text, out stderr_text)))
            return new GenericArray<ChapterInfo> ();

        return parse_ffprobe_chapters_output (stdout_text);
    }

    /**
     * Probe ALL audio streams in an input file.
     *
     * Returns a list of AudioStreamInfo objects with codec, channels,
     * sample rate, and language for each audio stream.
     * Used by AudioTab for Extract All Tracks and stream info display.
     */
    public async AudioStreamsProbeResult probe_all_audio_streams_async (
        string input_file,
        Cancellable? cancellable = null) {
        var result = new AudioStreamsProbeResult ();

        string[] cmd = {
            AppSettings.get_default ().ffprobe_path,
            "-v", "error",
            "-select_streams", "a",
            "-show_entries",
            "format=duration:stream=codec_name,channels,sample_rate,sample_fmt,bits_per_raw_sample:stream_tags=language",
            "-print_format", "json",
            input_file
        };
        string stdout_text;
        string stderr_text;

        if (!(yield run_ffprobe_async (cmd, cancellable, out stdout_text, out stderr_text))) {
            result.error_message = "ffprobe execution failed.";
            return result;
        }

        return parse_all_audio_streams_output (stdout_text);
    }
}
