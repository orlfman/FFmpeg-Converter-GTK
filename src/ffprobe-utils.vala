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

namespace FfprobeUtils {

    /**
     * Probe the frame rate of the first video stream in @input_file
     * using ffprobe.  Returns 0.0 on any failure so callers can fall
     * back to a default.
     */
    public double probe_input_fps (string input_file) {
        try {
            string[] cmd = {
                AppSettings.get_default ().ffprobe_path,
                "-v", "quiet",
                "-select_streams", "v:0",
                "-show_entries", "stream=r_frame_rate",
                "-of", "csv=p=0",
                input_file
            };
            string stdout_text, stderr_text;
            int status;

            Process.spawn_sync (null, cmd, null, SpawnFlags.SEARCH_PATH,
                                null, out stdout_text, out stderr_text, out status);

            if (status != 0 || stdout_text == null)
                return 0.0;

            // Typical output: "24000/1001" or "30/1" or "29.97"
            string raw = stdout_text.strip ();

            if (raw.contains ("/")) {
                string[] parts = raw.split ("/");
                if (parts.length >= 2) {
                    double num = double.parse (parts[0].strip ());
                    double den = double.parse (parts[1].strip ());
                    if (den > 0.0)
                        return num / den;
                }
            }

            double plain = double.parse (raw);
            if (plain > 0.0) return plain;

        } catch (Error e) {
            // probe failed — caller uses fallback
        }
        return 0.0;
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
    public double probe_duration (string input_file) {
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
            print ("ffprobe duration error: %s\n", e.message);
        }
        return 0.0;
    }

    /**
     * Probe the "title" tag from a media file's format-level metadata.
     *
     * Checks both the format-level tags and stream-level tags for a title.
     * Returns null if no title is found so callers can fall back to the
     * filename.
     */
    public string? probe_title (string input_file) {
        try {
            string[] cmd = {
                AppSettings.get_default ().ffprobe_path,
                "-v", "quiet",
                "-print_format", "json",
                "-show_entries", "format_tags=title",
                input_file
            };
            string stdout_text, stderr_text;
            int status;

            Process.spawn_sync (null, cmd, null, SpawnFlags.SEARCH_PATH,
                                null, out stdout_text, out stderr_text, out status);

            if (status == 0 && stdout_text != null && stdout_text.strip ().length > 0) {
                var parser = new Json.Parser ();
                parser.load_from_data (stdout_text);

                var root = parser.get_root ();
                if (root != null && root.get_node_type () == Json.NodeType.OBJECT) {
                    var root_obj = root.get_object ();

                    // Check format.tags.title
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
                }
            }
        } catch (Error e) {
            // probe failed — caller uses fallback
        }

        // Second attempt: try stream-level tags
        try {
            string[] cmd2 = {
                AppSettings.get_default ().ffprobe_path,
                "-v", "quiet",
                "-print_format", "json",
                "-show_entries", "stream_tags=title",
                "-select_streams", "v:0",
                input_file
            };
            string stdout_text2, stderr_text2;
            int status2;

            Process.spawn_sync (null, cmd2, null, SpawnFlags.SEARCH_PATH,
                                null, out stdout_text2, out stderr_text2, out status2);

            if (status2 == 0 && stdout_text2 != null && stdout_text2.strip ().length > 0) {
                var parser2 = new Json.Parser ();
                parser2.load_from_data (stdout_text2);

                var root2 = parser2.get_root ();
                if (root2 != null && root2.get_node_type () == Json.NodeType.OBJECT) {
                    var root_obj2 = root2.get_object ();
                    if (root_obj2.has_member ("streams")) {
                        var streams = root_obj2.get_array_member ("streams");
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
                }
            }
        } catch (Error e) {
            // probe failed — caller uses fallback
        }

        return null;
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
    public GenericArray<ChapterInfo> probe_chapters (string input_file) {
        var chapters = new GenericArray<ChapterInfo> ();

        try {
            string[] cmd = {
                AppSettings.get_default ().ffprobe_path,
                "-v", "quiet",
                "-print_format", "json",
                "-show_chapters",
                input_file
            };
            string stdout_text, stderr_text;
            int status;

            Process.spawn_sync (null, cmd, null, SpawnFlags.SEARCH_PATH,
                                null, out stdout_text, out stderr_text, out status);

            if (status != 0 || stdout_text == null || stdout_text.strip ().length == 0)
                return chapters;

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
                if (ch == null) continue;

                double start = double.parse (
                    ch.get_string_member_with_default ("start_time", "0"));
                double end = double.parse (
                    ch.get_string_member_with_default ("end_time", "0"));

                // Extract title from tags object (may be absent)
                string title = "Chapter %u".printf (i + 1);
                if (ch.has_member ("tags")) {
                    var tags = ch.get_object_member ("tags");
                    if (tags != null && tags.has_member ("title")) {
                        string t = tags.get_string_member ("title");
                        if (t != null && t.strip ().length > 0)
                            title = t.strip ();
                    }
                }

                // Skip zero-duration or invalid chapters
                if (end > start) {
                    chapters.add (new ChapterInfo ((int) i, title, start, end));
                }
            }

        } catch (Error e) {
            print ("ffprobe chapters error: %s\n", e.message);
        }

        return chapters;
    }
}
