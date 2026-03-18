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

public enum MediaStreamPresence {
    UNKNOWN,
    ABSENT,
    PRESENT
}

public class AudioStreamProbeResult : Object {
    public MediaStreamPresence presence { get; set; default = MediaStreamPresence.UNKNOWN; }
    public string codec_name { get; set; default = ""; }
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
        string cmd_text = string.joinv (" ", cmd);
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
            var proc = launcher.spawnv (cmd);

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
            string codec = line.strip ();
            if (codec.length == 0) {
                continue;
            }

            result.presence = MediaStreamPresence.PRESENT;
            result.codec_name = codec.down ();
            return result;
        }

        result.presence = MediaStreamPresence.ABSENT;
        return result;
    }

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
        string[] cmd = {
            AppSettings.get_default ().ffprobe_path,
            "-v", "quiet",
            "-select_streams", "a:0",
            "-show_entries", "stream=codec_name",
            "-of", "csv=p=0",
            input_file
        };
        string stdout_text;
        string stderr_text;

        if (!(yield run_ffprobe_async (cmd, cancellable, out stdout_text, out stderr_text)))
            return new AudioStreamProbeResult ();

        return parse_primary_audio_stream_output (stdout_text);
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
}
