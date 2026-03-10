using Gtk;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  ConversionUtils — Pure utility functions for the conversion pipeline
// ═══════════════════════════════════════════════════════════════════════════════

namespace ConversionUtils {

    // ═════════════════════════════════════════════════════════════════════════
    //  OUTPUT PATH COMPUTATION
    // ═════════════════════════════════════════════════════════════════════════

    public string compute_output_path (string input_file,
                                       string output_folder,
                                       ICodecBuilder builder,
                                       ICodecTab codec_tab) {
        string out_folder = (output_folder != "")
            ? output_folder
            : Path.get_dirname (input_file);

        // Ensure the output directory exists — handles volatile paths
        // (e.g. /tmp/work) or directories deleted between sessions.
        if (!FileUtils.test (out_folder, FileTest.IS_DIR)) {
            if (DirUtils.create_with_parents (out_folder, 0755) == 0) {
                message ("ConversionUtils: Created missing output directory: %s", out_folder);
            } else {
                warning ("ConversionUtils: Could not create output directory %s: %s",
                         out_folder, strerror (errno));
            }
        }

        string codec_name = builder.get_codec_name ().down ();
        string codec_suffix = codec_name.contains ("av1") ? "av1" : codec_name;

        string container_ext = codec_tab.get_container ();
        if (container_ext == "") container_ext = ContainerExt.MKV;

        string name_stem = resolve_output_stem (input_file, codec_suffix);

        return @"$out_folder/$name_stem.$container_ext";
    }

    /**
     * Resolve the output filename stem (without extension) based on the
     * current OutputNameMode setting.
     *
     * Each mode produces a different stem:
     *   DEFAULT  → <original_name>-<codec_suffix>
     *   CUSTOM   → <user_custom_name>-<codec_suffix>
     *   RANDOM   → <8-char alphanumeric>-<codec_suffix>
     *   DATE     → <YYYY-MM-DD_HH-MM-SS>-<codec_suffix>
     *   METADATA → <metadata_title>-<codec_suffix>  (falls back to DEFAULT)
     */
    public string resolve_output_stem (string input_file, string codec_suffix) {
        var settings = AppSettings.get_default ();
        OutputNameMode mode = settings.output_name_mode;

        string basename = Path.get_basename (input_file);
        int dot_pos = basename.last_index_of_char ('.');
        string name_no_ext = (dot_pos > 0) ? basename.substring (0, dot_pos) : basename;

        switch (mode) {
            case OutputNameMode.CUSTOM:
                string custom = settings.output_custom_name;
                if (custom.length > 0) {
                    // Sanitize to prevent path traversal or broken filenames
                    string safe_custom = sanitize_name_component (custom);
                    if (safe_custom.length > 0) {
                        return @"$safe_custom-$codec_suffix";
                    }
                }
                // Fall through to default if custom name is empty or fully invalid
                return @"$name_no_ext-$codec_suffix";

            case OutputNameMode.RANDOM:
                string random_str = generate_random_name (8);
                return @"$random_str-$codec_suffix";

            case OutputNameMode.DATE:
                string timestamp = generate_timestamp_name ();
                return @"$timestamp-$codec_suffix";

            case OutputNameMode.METADATA:
                string? title = FfprobeUtils.probe_title (input_file);
                if (title != null && title.length > 0) {
                    // Sanitize the title for use as a filename
                    string safe_title = sanitize_name_component (title);
                    if (safe_title.length > 0) {
                        return @"$safe_title-$codec_suffix";
                    }
                }
                // Fallback: use original filename
                return @"$name_no_ext-$codec_suffix";

            default:  // DEFAULT
                return @"$name_no_ext-$codec_suffix";
        }
    }

    /**
     * Generate a random alphanumeric string of the given length.
     */
    public string generate_random_name (int length) {
        const string CHARS = "abcdefghijklmnopqrstuvwxyz0123456789";
        var sb = new StringBuilder ();
        for (int i = 0; i < length; i++) {
            int idx = Random.int_range (0, CHARS.length);
            sb.append_c (CHARS[idx]);
        }
        return sb.str;
    }

    /**
     * Generate a date-time stamp suitable for filenames.
     * Format: YYYY-MM-DD_HH-MM-SS
     */
    public string generate_timestamp_name () {
        var now = new DateTime.now_local ();
        return now.format ("%Y-%m-%d_%H-%M-%S");
    }

    /**
     * Strip characters unsafe for filenames from a metadata string.
     * Keeps letters, digits, hyphens, underscores, and periods.
     * Collapses whitespace and path separators into single underscores.
     * Strips leading dots to prevent hidden files on Linux.
     * Clamps length to MAX_NAME_COMPONENT_LEN to stay within filesystem limits
     * (ext4 allows 255 bytes for the full filename; we reserve headroom for
     * the codec suffix and container extension).
     */
    private const int MAX_NAME_COMPONENT_LEN = 200;

    public string sanitize_name_component (string raw) {
        var sb = new StringBuilder ();
        unichar c;
        int i = 0;
        bool last_was_space = false;

        while (raw.get_next_char (ref i, out c)) {
            if (c.isalnum () || c == '-' || c == '_' || c == '.') {
                sb.append_unichar (c);
                last_was_space = false;
            } else if (c.isspace () || c == ':' || c == '/' || c == '\\') {
                if (!last_was_space && sb.len > 0) {
                    sb.append_c ('_');
                    last_was_space = true;
                }
            }
            // Skip all other characters silently
        }

        string result = sb.str;

        // Strip leading dots — prevent hidden files on Linux
        while (result.has_prefix (".")) {
            result = result.substring (1);
        }

        // Strip trailing underscores and dots
        while (result.has_suffix ("_") || result.has_suffix (".")) {
            result = result.substring (0, result.length - 1);
        }

        // Clamp length to stay within filesystem limits
        if (result.length > MAX_NAME_COMPONENT_LEN) {
            result = result.substring (0, MAX_NAME_COMPONENT_LEN);
            // Re-trim if the cut landed on a trailing underscore or dot
            while (result.has_suffix ("_") || result.has_suffix (".")) {
                result = result.substring (0, result.length - 1);
            }
        }

        return result;
    }

    public string find_unique_path (string path) {
        if (!FileUtils.test (path, FileTest.EXISTS))
            return path;

        string dir = Path.get_dirname (path);
        string basename = Path.get_basename (path);

        int dot_pos = basename.last_index_of_char ('.');
        string stem = (dot_pos > 0) ? basename.substring (0, dot_pos) : basename;
        string ext  = (dot_pos > 0) ? basename.substring (dot_pos) : "";

        int counter = 1;
        string candidate = path;
        do {
            candidate = Path.build_filename (dir, @"$stem-$counter$ext");
            counter++;
        } while (FileUtils.test (candidate, FileTest.EXISTS));

        return candidate;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  FILENAME SANITIZATION
    // ═════════════════════════════════════════════════════════════════════════

    public string sanitize_filename (string path) {
        string dir = Path.get_dirname (path);
        string name = Path.get_basename (path);

        string safe = name
            .replace ("：", "_")
            .replace ("？", "_")
            .replace ("*", "_")
            .replace ("\"", "_")
            .replace ("<", "_")
            .replace (">", "_")
            .replace ("|", "_")
            .replace ("/", "_")
            .replace ("\\", "_")
            .replace (":", "_");

        safe = safe.strip ().replace (". ", ".").replace (" .", ".");

        return Path.build_filename (dir, safe);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  TIMESTAMP BUILDING & VALIDATION
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Build a validated HH:MM:SS string from SpinButton widgets.
     */
    public string build_timestamp (SpinButton hh, SpinButton mm, SpinButton ss) {
        int h = hh.get_value_as_int ();
        int m = mm.get_value_as_int ();
        int s = ss.get_value_as_int ();
        return "%02d:%02d:%02d".printf (h, m, s);
    }

    /**
     * Parse an FFmpeg "HH:MM:SS.mmm" timestamp into total seconds.
     * Returns -1.0 for unparseable values.
     */
    public double parse_ffmpeg_timestamp (string time_str) {
        if (time_str == "N/A" || time_str.length == 0) {
            return -1.0;
        }
        string[] parts = time_str.split (":");
        if (parts.length < 3) return -1.0;

        int hours   = int.parse (parts[0]);
        int minutes = int.parse (parts[1]);
        double seconds = double.parse (parts[2]);

        return hours * 3600.0 + minutes * 60.0 + seconds;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  FFMPEG LOG LINE FILTERING
    //
    //  Shared by Converter and TrimRunner to decide which FFmpeg stderr lines
    //  should be written to the console tab. FFmpeg's -progress pipe:2 output
    //  produces high-frequency key=value lines (frame=, fps=, speed=, etc.)
    //  that are useful for progress parsing but clutter the console log.
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Returns true if the line is a high-frequency FFmpeg progress key=value
     * line that would clutter the console (frame=, fps=, speed=, etc.).
     */
    public bool is_noisy_ffmpeg_line (string line) {
        return line.has_prefix ("frame=")       || line.has_prefix ("fps=")        ||
               line.has_prefix ("stream_")      || line.has_prefix ("bitrate=")    ||
               line.has_prefix ("total_size=")  || line.has_prefix ("out_time")    ||
               line.has_prefix ("dup_frames=")  || line.has_prefix ("drop_frames=") ||
               line.has_prefix ("speed=")       || line.has_prefix ("progress=");
    }

    /**
     * Returns true if the line should be logged to the console tab.
     *
     * All non-noisy lines are logged. Noisy lines are only logged if they
     * contain important markers (final Lsize summary, errors, warnings).
     */
    public bool should_log_ffmpeg_line (string line) {
        if (!is_noisy_ffmpeg_line (line)) return true;

        // These markers within noisy lines are still worth logging
        return line.contains ("Lsize=")  || line.contains ("Error")   ||
               line.contains ("Warning") || line.contains ("failed");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SEGMENT HELPERS — shared by TrimTab and TrimRunner
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Sanitize a string for use as a filename component.
     * Replaces filesystem-unsafe characters with underscores.
     */
    public string sanitize_segment_name (string name) {
        var sb = new StringBuilder ();
        unichar c;
        int i = 0;
        while (name.get_next_char (ref i, out c)) {
            if (c == '/' || c == '\\' || c == ':' || c == '*'
                || c == '?' || c == '"' || c == '<' || c == '>'
                || c == '|' || c == '\0') {
                sb.append_c ('_');
            } else {
                sb.append_unichar (c);
            }
        }
        string result = sb.str.strip ();
        while (result.has_suffix (".")) {
            result = result.substring (0, result.length - 1);
        }
        return result.length > 0 ? result : "untitled";
    }

    /**
     * Zero-pad a segment number to 3 digits (001, 012, 123).
     */
    public string pad_segment_number (int n) {
        if (n < 10) return "00" + n.to_string ();
        if (n < 100) return "0" + n.to_string ();
        return n.to_string ();
    }
}
