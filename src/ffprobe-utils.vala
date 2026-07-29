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

public class TimedStreamTopologyProbeResult : Object {
    public bool success { get; set; default = false; }
    public bool has_subtitle_stream { get; set; default = false; }
    public bool has_chapters { get; set; default = false; }

    public TimedStreamTopologyProbeResult () {
        success = false;
        has_subtitle_stream = false;
        has_chapters = false;
    }
}

public class VideoTimelineProbeResult : Object {
    public bool success { get; set; default = false; }
    public bool start_time_known { get; set; default = false; }
    public double start_time { get; set; default = 0.0; }
    public double end_time { get; set; default = 0.0; }
    public double last_packet_time { get; set; default = 0.0; }
    public int packet_count { get; set; default = 0; }
    public bool packet_count_complete { get; set; default = false; }

    public VideoTimelineProbeResult () {
        success = false;
        start_time_known = false;
        start_time = 0.0;
        end_time = 0.0;
        last_packet_time = 0.0;
        packet_count = 0;
        packet_count_complete = false;
    }

    public double get_duration () {
        return success
            ? (end_time - start_time).clamp (0.0, double.MAX)
            : 0.0;
    }

    public double get_seek_span () {
        return success
            ? (last_packet_time - start_time).clamp (0.0, double.MAX)
            : 0.0;
    }
}

public delegate int FfprobeCaptureRunner (string[] argv,
                                          out string stdout_text,
                                          out string stderr_text);

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

    private bool run_ffprobe_controlled (string[] cmd,
                                         FfprobeCaptureRunner? capture_runner,
                                         out string stdout_text,
                                         out string stderr_text) {
        if (capture_runner == null) {
            return run_ffprobe_sync (
                cmd, out stdout_text, out stderr_text);
        }

        stdout_text = "";
        stderr_text = "";
        int status = capture_runner (
            cmd, out stdout_text, out stderr_text);
        if (status == 0 && stdout_text != null)
            return true;

        string detail = "exit=%d".printf (status);
        string stderr_summary = summarize_ffprobe_text (stderr_text);
        if (stderr_summary.length > 0)
            detail = @"$detail stderr=$stderr_summary";
        log_ffprobe_debug ("controlled probe failed", cmd, detail);
        return false;
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

    private TimedStreamTopologyProbeResult parse_timed_stream_topology_output (
        string stdout_text
    ) {
        var result = new TimedStreamTopologyProbeResult ();
        if (stdout_text == null || stdout_text.strip ().length == 0)
            return result;

        try {
            var parser = new Json.Parser ();
            parser.load_from_data (stdout_text);

            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
                return result;

            var root_obj = root.get_object ();
            if (!root_obj.has_member ("streams")
                || !root_obj.has_member ("chapters"))
                return result;

            var streams_node = root_obj.get_member ("streams");
            var chapters_node = root_obj.get_member ("chapters");
            if (streams_node == null || chapters_node == null
                || streams_node.get_node_type () != Json.NodeType.ARRAY
                || chapters_node.get_node_type () != Json.NodeType.ARRAY)
                return result;

            var streams = streams_node.get_array ();
            for (uint i = 0; i < streams.get_length (); i++) {
                var stream_node = streams.get_element (i);
                if (stream_node == null
                    || stream_node.get_node_type () != Json.NodeType.OBJECT)
                    return result;

                var stream = stream_node.get_object ();
                if (!stream.has_member ("codec_type"))
                    return result;

                var codec_type_node = stream.get_member ("codec_type");
                if (codec_type_node == null
                    || codec_type_node.get_node_type () != Json.NodeType.VALUE
                    || codec_type_node.get_value_type () != typeof (string))
                    return result;

                if (stream.get_string_member ("codec_type") == "subtitle") {
                    result.has_subtitle_stream = true;
                }
            }

            var chapters = chapters_node.get_array ();
            for (uint i = 0; i < chapters.get_length (); i++) {
                var chapter_node = chapters.get_element (i);
                if (chapter_node == null
                    || chapter_node.get_node_type () != Json.NodeType.OBJECT) {
                    return result;
                }
            }

            result.has_chapters = chapters.get_length () > 0;

            result.success = true;
        } catch (Error e) {
            debug ("FfprobeUtils: failed to parse timed-stream topology: %s | stdout=%s",
                   e.message, summarize_ffprobe_text (stdout_text));
        }

        return result;
    }

    private VideoTimelineProbeResult parse_video_packet_timeline_output (
        string stdout_text
    ) {
        var result = new VideoTimelineProbeResult ();
        if (stdout_text == null || stdout_text.strip ().length == 0)
            return result;

        bool found_packet = false;
        int packet_count = 0;
        double first_pts = double.MAX;
        double final_pts = -double.MAX;
        double final_end = -double.MAX;

        foreach (unowned string raw_line in stdout_text.split ("\n")) {
            string line = raw_line.strip ();
            if (line.length == 0)
                continue;

            string[] fields = line.split (",");
            if (fields.length == 0)
                continue;

            double pts = 0.0;
            if (!double.try_parse (fields[0].strip (), out pts) || !pts.is_finite ())
                continue;

            double packet_duration = 0.0;
            if (fields.length > 1) {
                double parsed_duration = 0.0;
                if (double.try_parse (fields[1].strip (), out parsed_duration)
                    && parsed_duration.is_finite ()
                    && parsed_duration > 0.0) {
                    packet_duration = parsed_duration;
                }
            }

            found_packet = true;
            packet_count++;
            first_pts = double.min (first_pts, pts);
            final_pts = double.max (final_pts, pts);
            final_end = double.max (final_end, pts + packet_duration);
        }

        if (found_packet) {
            result.success = true;
            result.start_time_known = true;
            result.start_time = first_pts;
            result.end_time = double.max (first_pts, final_end);
            result.last_packet_time = double.max (first_pts, final_pts);
            result.packet_count = packet_count;
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

    internal TimedStreamTopologyProbeResult parse_timed_stream_topology_output_for_test (
        string stdout_text
    ) {
        return parse_timed_stream_topology_output (stdout_text);
    }

    internal VideoTimelineProbeResult parse_video_packet_timeline_output_for_test (
        string stdout_text
    ) {
        return parse_video_packet_timeline_output (stdout_text);
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

    public TimedStreamTopologyProbeResult probe_timed_stream_topology (
        string input_file,
        FfprobeCaptureRunner? capture_runner = null
    ) {
        string[] cmd = {
            AppSettings.get_default ().ffprobe_path,
            "-v", "error",
            "-show_entries", "stream=codec_type:chapter=start_time,end_time",
            "-of", "json",
            input_file
        };
        string stdout_text;
        string stderr_text;

        if (!run_ffprobe_controlled (
                cmd, capture_runner, out stdout_text, out stderr_text))
            return new TimedStreamTopologyProbeResult ();

        return parse_timed_stream_topology_output (stdout_text);
    }

    /**
     * Read the first video stream's real packet timeline. Container duration
     * cannot be used for thumbnails: it may include a leading timestamp gap,
     * a longer audio/subtitle stream, or chapter metadata beyond the video.
     */
    public VideoTimelineProbeResult probe_video_timeline (
        string input_file,
        FfprobeCaptureRunner? capture_runner = null
    ) {
        // Read just the first packet. This establishes the real video origin
        // without trusting the container's start time.
        string[] first_cmd = {
            AppSettings.get_default ().ffprobe_path,
            "-v", "error",
            "-select_streams", "v:0",
            "-read_intervals", "%+#1",
            "-show_packets",
            "-show_entries", "packet=pts_time,duration_time",
            "-of", "csv=p=0",
            input_file
        };
        string stdout_text;
        string stderr_text;

        if (!run_ffprobe_controlled (
                first_cmd, capture_runner, out stdout_text, out stderr_text))
            return new VideoTimelineProbeResult ();

        VideoTimelineProbeResult first =
            parse_video_packet_timeline_output (stdout_text);
        if (!first.success)
            return new VideoTimelineProbeResult ();

        // Preserve the trustworthy first-packet timestamp even if the bounded
        // tail lookup fails. Callers may combine it with a duration derived
        // from their own encode/trim request, but never with container duration.
        var partial = new VideoTimelineProbeResult ();
        partial.success = false;
        partial.start_time_known = true;
        partial.start_time = first.start_time;
        partial.end_time = first.start_time;
        partial.last_packet_time = first.last_packet_time;
        partial.packet_count = first.packet_count;
        partial.packet_count_complete = false;

        // Container duration is only a hint for locating a small tail window;
        // it is never returned as the video duration. This keeps the original
        // leading-gap bug from reappearing when metadata is misleading.
        string[] duration_cmd = {
            AppSettings.get_default ().ffprobe_path,
            "-v", "quiet",
            "-print_format", "csv=p=0",
            "-show_entries", "format=duration",
            input_file
        };
        if (!run_ffprobe_controlled (
                duration_cmd, capture_runner, out stdout_text, out stderr_text))
            return partial;

        double duration_hint = parse_ffprobe_duration_output (stdout_text);
        if (duration_hint <= 0.0)
            return partial;

        double approximate_end = duration_hint;
        if (approximate_end <= first.start_time) {
            approximate_end = first.start_time + duration_hint;
        }

        // Normal files succeed with the five-second window. Larger windows
        // handle containers whose duration is governed by a longer subtitle
        // or audio stream, while bounding captured packet output to roughly
        // two minutes instead of scanning every packet in a long movie.
        double[] tail_windows = { 5.0, 15.0, 30.0, 60.0, 120.0 };
        double previous_start = double.MAX;

        foreach (double window in tail_windows) {
            double tail_start = double.max (
                first.start_time, approximate_end - window);
            if (Math.fabs (tail_start - previous_start) < 0.000001)
                continue;
            previous_start = tail_start;

            // An explicit end keeps the probe truly bounded and avoids an
            // ffprobe edge case where an open-ended interval beginning at
            // exactly zero can return no packets under allocator poisoning.
            double tail_end = approximate_end + 1.0;
            string interval = ConversionUtils.format_ffmpeg_double (
                tail_start, "%.6f") + "%"
                + ConversionUtils.format_ffmpeg_double (tail_end, "%.6f");
            string[] tail_cmd = {
                AppSettings.get_default ().ffprobe_path,
                "-v", "error",
                "-select_streams", "v:0",
                "-read_intervals", interval,
                "-show_packets",
                "-show_entries", "packet=pts_time,duration_time",
                "-of", "csv=p=0",
                input_file
            };

            if (!run_ffprobe_controlled (
                    tail_cmd, capture_runner, out stdout_text, out stderr_text))
                return partial;

            VideoTimelineProbeResult tail =
                parse_video_packet_timeline_output (stdout_text);
            bool covers_entire_timeline =
                tail_start <= first.start_time + 0.000001;
            bool confirmed_single_packet = covers_entire_timeline
                && tail.success
                && tail.packet_count == 1
                && Math.fabs (tail.start_time - first.start_time) < 0.000001;
            if (!tail.success
                || (tail.end_time <= first.start_time
                    && !confirmed_single_packet))
                continue;

            var result = new VideoTimelineProbeResult ();
            result.success = true;
            result.start_time_known = true;
            result.start_time = first.start_time;
            result.end_time = tail.end_time;
            result.last_packet_time = tail.last_packet_time;
            result.packet_count_complete = covers_entire_timeline;
            result.packet_count = result.packet_count_complete
                ? tail.packet_count
                : tail.packet_count + first.packet_count;
            return result;
        }

        return partial;
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

    /**
     * Probe a file's container and stream metadata, returning ffprobe's raw
     * key=value text for the caller to parse.
     *
     * This reads headers only — it does not demux packets — so it stays cheap
     * regardless of file size.
     *
     * Returns null if ffprobe could not be run or exited non-zero.
     */
    public async string? probe_format_and_streams_async (string input_file,
                                                         Cancellable? cancellable = null) {
        string[] cmd = {
            AppSettings.get_default ().ffprobe_path, "-v", "error",
            "-show_format", "-show_streams",
            input_file
        };
        string stdout_text;
        string stderr_text;

        if (!(yield run_ffprobe_async (cmd, cancellable, out stdout_text, out stderr_text)))
            return null;

        return stdout_text;
    }

    /**
     * Incremental keyframe counter over ffprobe's `packet=flags` CSV output.
     *
     * ffprobe emits one flags field per packet, one per line, and a keyframe
     * packet carries 'K'. Scanning raw bytes rather than splitting strings keeps
     * the pass allocation-free across a file that can emit hundreds of thousands
     * of lines, and lets the caller feed arbitrary chunk boundaries: a line split
     * across two reads is still counted exactly once.
     */
    internal class KeyframeFlagScanner : Object {
        private bool pending_line_has_key = false;
        private int _count = 0;

        /** Keyframes seen in the bytes fed so far. */
        public int count { get { return _count; } }

        public void feed (uint8[] chunk, ssize_t length) {
            for (ssize_t i = 0; i < length; i++) {
                uint8 b = chunk[i];
                if (b == (uint8) '\n') {
                    if (pending_line_has_key)
                        _count++;
                    pending_line_has_key = false;
                } else if (b == (uint8) 'K') {
                    pending_line_has_key = true;
                }
            }
        }

        /**
         * Account for a trailing line that had no terminating newline. Safe to
         * call when the stream did end with one: an empty pending line carries
         * no 'K' and so contributes nothing.
         */
        public void finish () {
            if (pending_line_has_key)
                _count++;
            pending_line_has_key = false;
        }
    }

    /**
     * Counts keyframes in a file's first video stream, reporting a running total
     * while it works.
     *
     * There is no cheap exact count available: `-show_entries packet=flags`
     * demuxes every packet in the file by design, and ffprobe exposes no way to
     * read a container index alone. The cost is therefore inherent to wanting an
     * exact number, so this streams the output — staying cancellable and
     * reporting progress — rather than blocking on a single capture.
     */
    public class VideoKeyframeCounter : Object {
        // ffprobe line-buffers into the pipe, so a plain read_async returns a
        // single short line per call — tens of thousands of main-context
        // dispatches for a long file. read_all_async fills the buffer instead,
        // which at this size is roughly one dispatch per 4000 packets: frequent
        // enough to keep progress moving, rare enough not to compete with frame
        // callbacks while the user is interacting.
        private const size_t READ_CHUNK = 16384;

        // Emit no more often than this, so a long count updates visibly without
        // flooding the main loop with label updates.
        private const int64 PROGRESS_INTERVAL_US = 250000;

        /** Running keyframe total, emitted on the main context while counting. */
        public signal void progress (int running_count);

        public async bool count (string input_file,
                                 Cancellable? cancellable,
                                 out int total) {
            total = 0;

            string[] cmd = {
                AppSettings.get_default ().ffprobe_path, "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "packet=flags",
                "-of", "csv=p=0",
                input_file
            };

            Subprocess proc;
            try {
                var launcher = new SubprocessLauncher (
                    SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
                proc = SubprocessCompat.spawnv (launcher, cmd);
            } catch (Error e) {
                log_ffprobe_debug ("keyframe count spawn failed", cmd, e.message);
                return false;
            }

            var scanner = new KeyframeFlagScanner ();
            var stdout_stream = proc.get_stdout_pipe ();
            var buffer = new uint8[READ_CHUNK];
            int64 last_emit = GLib.get_monotonic_time ();

            try {
                while (true) {
                    size_t got;
                    yield stdout_stream.read_all_async (
                        buffer, Priority.LOW, cancellable, out got);

                    if (got > 0) {
                        scanner.feed (buffer, (ssize_t) got);

                        int64 now = GLib.get_monotonic_time ();
                        if (now - last_emit >= PROGRESS_INTERVAL_US) {
                            last_emit = now;
                            progress (scanner.count);
                        }
                    }

                    // A short fill means the stream ended.
                    if (got < buffer.length)
                        break;
                }
            } catch (Error e) {
                // Cancellation surfaces here as IOError.CANCELLED. Kill the
                // probe so an abandoned full-file demux stops reading.
                proc.force_exit ();
                if (cancellable == null || !cancellable.is_cancelled ())
                    log_ffprobe_debug ("keyframe count read failed", cmd, e.message);
                return false;
            }

            scanner.finish ();

            try {
                yield proc.wait_async (cancellable);
            } catch (Error e) {
                proc.force_exit ();
                return false;
            }

            if (!proc.get_successful ()) {
                string detail = proc.get_if_exited ()
                    ? "exit=%d".printf (proc.get_exit_status ())
                    : "subprocess unsuccessful";
                log_ffprobe_debug ("keyframe count probe failed", cmd, detail);
                return false;
            }

            total = scanner.count;
            return true;
        }
    }
}
