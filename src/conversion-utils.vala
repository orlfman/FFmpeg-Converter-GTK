using Gtk;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  ConversionUtils — Pure utility functions for the conversion pipeline
// ═══════════════════════════════════════════════════════════════════════════════

namespace ConversionUtils {
    private const int ASCII_FORMAT_BUFFER_SIZE = 64;
    private enum DirectoryStatus {
        DIRECTORY,
        MISSING,
        NOT_DIRECTORY,
        ERROR,
        CANCELLED
    }

    private string describe_file_path (File file) {
        string? path = file.get_path ();
        return (path != null) ? path : file.get_uri ();
    }

    private string resolve_output_folder_path (string input_file, string output_folder) {
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

        return out_folder;
    }

    private async DirectoryStatus query_directory_status_async (File dir,
                                                                Cancellable? cancellable = null) {
        try {
            FileInfo info = yield dir.query_info_async (
                FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NONE,
                Priority.DEFAULT,
                cancellable
            );
            return (info.get_file_type () == FileType.DIRECTORY)
                ? DirectoryStatus.DIRECTORY
                : DirectoryStatus.NOT_DIRECTORY;
        } catch (Error e) {
            if (e is IOError.NOT_FOUND)
                return DirectoryStatus.MISSING;
            if (e is IOError.CANCELLED)
                return DirectoryStatus.CANCELLED;

            warning ("ConversionUtils: Could not query output directory %s: %s",
                     describe_file_path (dir), e.message);
            return DirectoryStatus.ERROR;
        }
    }

    private async bool ensure_directory_tree_async (File dir,
                                                    Cancellable? cancellable = null) {
        DirectoryStatus status = yield query_directory_status_async (dir, cancellable);
        switch (status) {
            case DirectoryStatus.DIRECTORY:
                return true;

            case DirectoryStatus.NOT_DIRECTORY:
                warning ("ConversionUtils: Output path exists but is not a directory: %s",
                         describe_file_path (dir));
                return false;

            case DirectoryStatus.ERROR:
            case DirectoryStatus.CANCELLED:
                return false;

            case DirectoryStatus.MISSING:
                break;
        }

        File? parent = dir.get_parent ();
        if (parent != null) {
            if (!(yield ensure_directory_tree_async (parent, cancellable)))
                return false;
        }

        try {
            yield dir.make_directory_async (Priority.DEFAULT, cancellable);
            return true;
        } catch (Error e) {
            if (e is IOError.EXISTS) {
                DirectoryStatus after_race = yield query_directory_status_async (dir, cancellable);
                return after_race == DirectoryStatus.DIRECTORY;
            }
            if (e is IOError.CANCELLED)
                return false;

            warning ("ConversionUtils: Could not create output directory %s: %s",
                     describe_file_path (dir), e.message);
            return false;
        }
    }

    private async string resolve_output_folder_path_async (string input_file,
                                                           string output_folder,
                                                           Cancellable? cancellable = null) {
        string out_folder = (output_folder != "")
            ? output_folder
            : Path.get_dirname (input_file);

        File out_dir = File.new_for_path (out_folder);
        DirectoryStatus status = yield query_directory_status_async (out_dir, cancellable);
        switch (status) {
            case DirectoryStatus.DIRECTORY:
                return out_folder;

            case DirectoryStatus.NOT_DIRECTORY:
                warning ("ConversionUtils: Output path exists but is not a directory: %s",
                         describe_file_path (out_dir));
                return out_folder;

            case DirectoryStatus.ERROR:
            case DirectoryStatus.CANCELLED:
                return out_folder;

            case DirectoryStatus.MISSING:
                if (yield ensure_directory_tree_async (out_dir, cancellable)) {
                    message ("ConversionUtils: Created missing output directory: %s", out_folder);
                }
                return out_folder;
        }

        return out_folder;
    }

    private string resolve_codec_suffix (ICodecBuilder builder) {
        string codec_name = builder.get_codec_name ().down ();
        return codec_name.contains ("av1") ? "av1" : codec_name;
    }

    private string resolve_container_extension (ICodecTab codec_tab) {
        string container_ext = codec_tab.get_container ();
        return (container_ext != "") ? container_ext : ContainerExt.MKV;
    }

    private string build_default_output_stem (string name_no_ext, string codec_suffix) {
        return @"$name_no_ext-$codec_suffix";
    }

    private string build_sanitized_named_output_stem (string? raw_name,
                                                      string codec_suffix,
                                                      string fallback_stem) {
        if (raw_name == null || raw_name.length == 0)
            return fallback_stem;

        string safe_name = sanitize_name_component (raw_name);
        if (safe_name.length == 0)
            return fallback_stem;

        return @"$safe_name-$codec_suffix";
    }

    private string build_output_stem_for_mode (OutputNameMode mode,
                                               string name_no_ext,
                                               string codec_suffix,
                                               string custom_name,
                                               string? metadata_title = null) {
        string fallback_stem = build_default_output_stem (name_no_ext, codec_suffix);

        switch (mode) {
            case OutputNameMode.CUSTOM:
                return build_sanitized_named_output_stem (
                    custom_name, codec_suffix, fallback_stem);

            case OutputNameMode.RANDOM:
                return @"$(generate_random_name (8))-$codec_suffix";

            case OutputNameMode.DATE:
                return @"$(generate_timestamp_name ())-$codec_suffix";

            case OutputNameMode.METADATA:
                return build_sanitized_named_output_stem (
                    metadata_title, codec_suffix, fallback_stem);

            default:
                return fallback_stem;
        }
    }

    private void resolve_output_stem_context (string input_file,
                                              out OutputNameMode mode,
                                              out string custom_name,
                                              out string name_no_ext) {
        var settings = AppSettings.get_default ();
        mode = settings.output_name_mode;
        custom_name = settings.output_custom_name;

        string basename = Path.get_basename (input_file);
        int dot_pos = basename.last_index_of_char ('.');
        name_no_ext = (dot_pos > 0) ? basename.substring (0, dot_pos) : basename;
    }

    public class FileSignature : Object {
        public string path { get; construct set; }
        public int64 size { get; construct set; }
        public uint64 mtime { get; construct set; }
        public uint32 mtime_usec { get; construct set; }

        public FileSignature (string path,
                              int64 size,
                              uint64 mtime,
                              uint32 mtime_usec) {
            Object (
                path: path,
                size: size,
                mtime: mtime,
                mtime_usec: mtime_usec
            );
        }

        public bool matches (FileSignature other) {
            return path == other.path
                && size == other.size
                && mtime == other.mtime
                && mtime_usec == other.mtime_usec;
        }
    }

    public class CachedFileProbeEntry<G> : Object {
        public FileSignature signature;
        public G value;

        public CachedFileProbeEntry (FileSignature signature, G value) {
            this.signature = signature;
            this.value = value;
        }
    }

    public class CachedFileProbe<G> : Object {
        public const int DEFAULT_MAX_ENTRIES = 32;
        // Current use is main-context only: MainWindow owns this cache and does
        // not share it with worker threads.
        private HashTable<string, CachedFileProbeEntry<G>> entries =
            new HashTable<string, CachedFileProbeEntry<G>> (str_hash, str_equal);
        private string[] lru_paths = {};
        private int max_entries;

        public CachedFileProbe (int max_entries = DEFAULT_MAX_ENTRIES) {
            this.max_entries = (max_entries > 0) ? max_entries : DEFAULT_MAX_ENTRIES;
        }

        private void remove_path_from_lru (string path) {
            int idx = -1;
            for (int i = 0; i < lru_paths.length; i++) {
                if (lru_paths[i] == path) {
                    idx = i;
                    break;
                }
            }

            if (idx < 0)
                return;

            string[] next = {};
            for (int i = 0; i < lru_paths.length; i++) {
                if (i != idx)
                    next += lru_paths[i];
            }
            lru_paths = next;
        }

        private void touch_path (string path) {
            remove_path_from_lru (path);
            lru_paths += path;

            while (lru_paths.length > max_entries) {
                string evicted = lru_paths[0];
                string[] next = {};
                for (int i = 1; i < lru_paths.length; i++)
                    next += lru_paths[i];
                lru_paths = next;
                entries.remove (evicted);
            }
        }

        public CachedFileProbeEntry<G>? lookup (FileSignature signature) {
            var entry = entries.lookup (signature.path);
            if (entry != null && entry.signature.matches (signature)) {
                touch_path (signature.path);
                return entry;
            }
            if (entry != null) {
                entries.remove (signature.path);
                remove_path_from_lru (signature.path);
            }
            return null;
        }

        public void store (FileSignature signature, G value) {
            entries.insert (signature.path, new CachedFileProbeEntry<G> (signature, value));
            touch_path (signature.path);
        }

        public void clear_path (string path) {
            entries.remove (path);
            remove_path_from_lru (path);
        }

        public void clear () {
            entries.remove_all ();
            lru_paths = {};
        }
    }

    public FileSignature? query_file_signature (string path) {
        try {
            var info = File.new_for_path (path).query_info (
                "%s,%s,%s".printf (
                    FileAttribute.STANDARD_SIZE,
                    FileAttribute.TIME_MODIFIED,
                    FileAttribute.TIME_MODIFIED_USEC
                ),
                FileQueryInfoFlags.NONE
            );

            return new FileSignature (
                path,
                info.get_size (),
                info.get_attribute_uint64 (FileAttribute.TIME_MODIFIED),
                info.get_attribute_uint32 (FileAttribute.TIME_MODIFIED_USEC)
            );
        } catch (Error e) {
            return null;
        }
    }

    // FFmpeg expressions and encoder params require '.' as the decimal
    // separator regardless of the user's locale.
    public string format_ffmpeg_double (double value, string format = "%g") {
        char[] buffer = new char[ASCII_FORMAT_BUFFER_SIZE];
        value.format (buffer, format);
        return (string) buffer;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  OUTPUT PATH COMPUTATION
    // ═════════════════════════════════════════════════════════════════════════

    public string compute_output_path (string input_file,
                                       string output_folder,
                                       ICodecBuilder builder,
                                       ICodecTab codec_tab) {
        string out_folder = resolve_output_folder_path (input_file, output_folder);
        string codec_suffix = resolve_codec_suffix (builder);
        string container_ext = resolve_container_extension (codec_tab);

        string name_stem = resolve_output_stem (input_file, codec_suffix);

        return @"$out_folder/$name_stem.$container_ext";
    }

    public async string compute_output_path_async (string input_file,
                                                   string output_folder,
                                                   ICodecBuilder builder,
                                                   ICodecTab codec_tab,
                                                   Cancellable? cancellable = null) {
        string out_folder = yield resolve_output_folder_path_async (
            input_file, output_folder, cancellable);
        string codec_suffix = resolve_codec_suffix (builder);
        string container_ext = resolve_container_extension (codec_tab);

        string name_stem = yield resolve_output_stem_async (input_file, codec_suffix, cancellable);

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
        OutputNameMode mode;
        string custom_name;
        string name_no_ext;
        resolve_output_stem_context (input_file, out mode, out custom_name, out name_no_ext);
        string? metadata_title = null;
        if (mode == OutputNameMode.METADATA)
            metadata_title = FfprobeUtils.probe_title (input_file);

        return build_output_stem_for_mode (
            mode,
            name_no_ext,
            codec_suffix,
            custom_name,
            metadata_title
        );
    }

    public async string resolve_output_stem_async (string input_file,
                                                   string codec_suffix,
                                                   Cancellable? cancellable = null) {
        OutputNameMode mode;
        string custom_name;
        string name_no_ext;
        resolve_output_stem_context (input_file, out mode, out custom_name, out name_no_ext);
        string? metadata_title = null;
        if (mode == OutputNameMode.METADATA)
            metadata_title = yield FfprobeUtils.probe_title_async (input_file, cancellable);

        return build_output_stem_for_mode (
            mode,
            name_no_ext,
            codec_suffix,
            custom_name,
            metadata_title
        );
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

    public string find_unique_path_with_reserved (string path,
                                                  HashTable<string, bool>? reserved_paths = null) {
        bool reserved_collision = reserved_paths != null && reserved_paths.contains (path);
        if (!reserved_collision && !FileUtils.test (path, FileTest.EXISTS)) {
            return path;
        }

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
        } while (FileUtils.test (candidate, FileTest.EXISTS)
                 || (reserved_paths != null && reserved_paths.contains (candidate)));

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
        string cleaned = time_str.strip ();
        if (cleaned == "N/A" || cleaned.length == 0) {
            return -1.0;
        }

        string[] parts = cleaned.split (":");
        if (parts.length != 3) return -1.0;
        if (!is_ascii_digits (parts[0]) || parts[1].length != 2 || !is_ascii_digits (parts[1]))
            return -1.0;

        string seconds_part = parts[2];
        int frac_sep = seconds_part.index_of_char ('.');
        string whole_seconds = (frac_sep >= 0) ? seconds_part.substring (0, frac_sep) : seconds_part;
        string fraction = (frac_sep >= 0) ? seconds_part.substring (frac_sep + 1) : "";

        if (whole_seconds.length != 2 || !is_ascii_digits (whole_seconds))
            return -1.0;
        if (frac_sep >= 0 && (fraction.length == 0 || !is_ascii_digits (fraction)))
            return -1.0;

        int hours = int.parse (parts[0]);
        int minutes = int.parse (parts[1]);
        int seconds_whole = int.parse (whole_seconds);
        if (minutes >= 60 || seconds_whole >= 60)
            return -1.0;

        double seconds = (double) seconds_whole;
        if (fraction.length > 0)
            seconds += parse_fractional_seconds (fraction);

        return hours * 3600.0 + minutes * 60.0 + seconds;
    }

    private double parse_fractional_seconds (string fraction) {
        double scale = 0.1;
        double result = 0.0;

        for (int i = 0; i < fraction.length; i++) {
            int digit = fraction[i] - '0';
            result += (double) digit * scale;
            scale /= 10.0;
        }

        return result;
    }

    private bool is_ascii_digits (string text) {
        if (text.length == 0)
            return false;

        for (int i = 0; i < text.length; i++) {
            char c = text[i];
            if (c < '0' || c > '9')
                return false;
        }
        return true;
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
