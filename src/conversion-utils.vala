using Gtk;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  ConversionUtils — Pure utility functions for the conversion pipeline
// ═══════════════════════════════════════════════════════════════════════════════

namespace ConversionUtils {
    private const int ASCII_FORMAT_BUFFER_SIZE = 64;
    private const int MAX_UNIQUE_PATH_ATTEMPTS = 10000;
    private const int MAX_RANDOM_UNIQUE_PATH_ATTEMPTS = 256;
    private const int MAX_MANAGED_TEMP_FILE_ATTEMPTS = 32;
    private const int STALE_MANAGED_RUN_MAX_AGE_SECONDS = 24 * 60 * 60;
    private const int TEMP_DIR_MODE = 448; // 0700
    public const double PEAK_NORMALIZE_TARGET_DB = -1.0;
    private Mutex managed_temp_file_mutex;
    private uint managed_temp_file_sequence = 0;
    private enum DirectoryStatus {
        DIRECTORY,
        MISSING,
        NOT_DIRECTORY,
        ERROR,
        CANCELLED
    }

    public bool audio_processing_needs_peak_analysis (
        AudioProcessingSettingsSnapshot processing) {
        return processing.normalize_enabled && !processing.normalize_ebu;
    }

    public bool try_parse_max_volume_db (string line, out double max_volume_db) {
        max_volume_db = 0.0;

        int marker = line.index_of ("max_volume:");
        if (marker < 0)
            return false;

        string value = line.substring (marker + "max_volume:".length).strip ();
        if (value.has_suffix (" dB")) {
            value = value.substring (0, value.length - 3).strip ();
        }

        return double.try_parse (value, out max_volume_db);
    }

    public double compute_peak_normalize_gain_db (double max_volume_db) {
        return PEAK_NORMALIZE_TARGET_DB - max_volume_db;
    }

    /**
     * Format an argv array for shell-display (logs, console previews, copy-paste).
     *
     * Arguments that are safe bare tokens are left unquoted; everything else
     * is single-quoted with internal ' escaped as '\''.
     */
    public string format_command_for_display (string[] argv) {
        string[] quoted = new string[argv.length];
        for (int i = 0; i < argv.length; i++) {
            quoted[i] = shell_quote_arg (argv[i]);
        }
        return string.joinv (" ", quoted);
    }

    private string shell_quote_arg (string arg) {
        if (arg.length == 0) return "''";

        for (int i = 0; i < arg.length; i++) {
            char c = arg[i];
            if (c == ' ' || c == '\'' || c == '"' || c == '$' || c == '&'
                || c == '|' || c == ';' || c == '(' || c == ')' || c == '*'
                || c == '?' || c == '[' || c == '\\' || c == '!' || c == '{'
                || c == '}' || c == '<' || c == '>' || c == '`' || c == '~'
                || c == '#' || c == '\n' || c == '\t') {
                return "'" + arg.replace ("'", "'\\''") + "'";
            }
        }

        return arg;
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

    public string get_app_temp_root () {
        return Path.build_filename (
            Environment.get_tmp_dir (),
            "ffmpeg-converter-gtk-%u".printf ((uint) Posix.getuid ())
        );
    }

    public string sanitize_temp_component (string value) {
        if (value.length == 0)
            return "default";

        var builder = new StringBuilder ();
        for (int i = 0; i < value.length; i++) {
            char c = value[i];
            if ((c >= 'a' && c <= 'z')
                || (c >= 'A' && c <= 'Z')
                || (c >= '0' && c <= '9')
                || c == '-' || c == '_' || c == '.') {
                builder.append_c (c);
            } else {
                builder.append_c ('-');
            }
        }

        return (builder.len > 0) ? builder.str : "default";
    }

    public string? create_managed_temp_run_dir (string feature,
                                                string detail = "") {
        string root = get_app_temp_root ();
        string feature_dir = Path.build_filename (root, sanitize_temp_component (feature));
        string base_dir = feature_dir;
        if (detail.length > 0) {
            base_dir = Path.build_filename (feature_dir, sanitize_temp_component (detail));
        }

        if (DirUtils.create_with_parents (base_dir, TEMP_DIR_MODE) != 0) {
            return null;
        }

        // Use sequence counter + exclusive mkdir to guarantee uniqueness,
        // mirroring the pattern in create_managed_temp_file().
        for (int attempt = 0; attempt < MAX_MANAGED_TEMP_FILE_ATTEMPTS; attempt++) {
            string run_dir = Path.build_filename (
                base_dir,
                "run-%s-%d-%u".printf (
                    GLib.get_real_time ().to_string (),
                    (int) Posix.getpid (),
                    next_managed_temp_file_sequence ()
                )
            );

            if (DirUtils.create (run_dir, TEMP_DIR_MODE) == 0) {
                return run_dir;
            }

            // EEXIST means collision — retry with a new sequence number.
            // Any other error is a real failure.
            if (errno != Posix.EEXIST) {
                return null;
            }
        }

        return null;
    }

    internal bool is_same_or_descendant_path (string path, string ancestor) {
        if (path == ancestor)
            return true;

        string prefix = ancestor;
        if (!prefix.has_suffix (Path.DIR_SEPARATOR_S))
            prefix += Path.DIR_SEPARATOR_S;

        return path.has_prefix (prefix);
    }

    public string? ensure_managed_temp_subdir (string run_dir, string name) {
        string root = get_app_temp_root ();
        if (!is_same_or_descendant_path (run_dir, root)) {
            return null;
        }

        string subdir = Path.build_filename (run_dir, sanitize_temp_component (name));
        if (DirUtils.create_with_parents (subdir, TEMP_DIR_MODE) != 0) {
            return null;
        }

        return subdir;
    }

    private uint next_managed_temp_file_sequence () {
        managed_temp_file_mutex.lock ();
        managed_temp_file_sequence++;
        uint next_value = managed_temp_file_sequence;
        managed_temp_file_mutex.unlock ();
        return next_value;
    }

    public string? create_managed_temp_file (string dir,
                                             string prefix,
                                             string suffix = "") {
        string root = get_app_temp_root ();
        if (!is_same_or_descendant_path (dir, root)) {
            return null;
        }
        if (!FileUtils.test (dir, FileTest.IS_DIR)) {
            return null;
        }

        string safe_prefix = sanitize_temp_component (prefix);
        string safe_suffix = "";
        if (suffix.length > 0) {
            safe_suffix = (suffix[0] == '.')
                ? "." + sanitize_temp_component (suffix.substring (1))
                : sanitize_temp_component (suffix);
        }

        for (int attempt = 0; attempt < MAX_MANAGED_TEMP_FILE_ATTEMPTS; attempt++) {
            string candidate = Path.build_filename (
                dir,
                "%s-%s-%u%s".printf (
                    safe_prefix,
                    GLib.get_real_time ().to_string (),
                    next_managed_temp_file_sequence (),
                    safe_suffix
                )
            );

            try {
                var stream = File.new_for_path (candidate).create (FileCreateFlags.PRIVATE);
                stream.close ();
                return candidate;
            } catch (Error e) {
                FileUtils.unlink (candidate);
                continue;
            }
        }

        return null;
    }

    private bool try_parse_managed_run_dir_name (string name, out int pid) {
        pid = 0;

        if (!name.has_prefix ("run-"))
            return false;

        string suffix = name.substring (4);
        string[] parts = suffix.split ("-");
        if (parts.length != 2 && parts.length != 3)
            return false;

        string created_part = parts[0];
        string pid_part = parts[1];
        int64 created_usec = 0;

        if (!int64.try_parse (created_part, out created_usec)
            || !int.try_parse (pid_part, out pid)) {
            return false;
        }

        if (parts.length == 3) {
            uint seq = 0;
            if (!uint.try_parse (parts[2], out seq) || seq == 0)
                return false;
        }

        return created_usec > 0 && pid > 0;
    }

    private bool is_process_alive_for_pid (int pid) {
        if (pid <= 0)
            return false;

        string proc_path = Path.build_filename ("/proc", pid.to_string ());
        return FileUtils.test (proc_path, FileTest.IS_DIR);
    }

    private int64 query_file_modified_usec (File file) {
        try {
            FileInfo info = file.query_info (
                "%s,%s".printf (
                    FileAttribute.TIME_MODIFIED,
                    FileAttribute.TIME_MODIFIED_USEC
                ),
                FileQueryInfoFlags.NONE
            );

            return ((int64) info.get_attribute_uint64 (FileAttribute.TIME_MODIFIED) * 1000000)
                + (int64) info.get_attribute_uint32 (FileAttribute.TIME_MODIFIED_USEC);
        } catch (Error e) {
            return 0;
        }
    }

    private bool should_remove_stale_managed_run_dir (File dir, string name) {
        int pid;
        if (try_parse_managed_run_dir_name (name, out pid)) {
            return !is_process_alive_for_pid (pid);
        }

        if (!name.has_prefix ("run-"))
            return false;

        int64 modified_usec = query_file_modified_usec (dir);
        if (modified_usec <= 0)
            return false;

        return (GLib.get_real_time () - modified_usec)
            > ((int64) STALE_MANAGED_RUN_MAX_AGE_SECONDS * 1000000);
    }

    private void delete_directory_tree (File dir) {
        FileEnumerator? enumerator = null;
        try {
            enumerator = dir.enumerate_children (
                "%s,%s".printf (
                    FileAttribute.STANDARD_NAME,
                    FileAttribute.STANDARD_TYPE
                ),
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS
            );

            FileInfo? info;
            while ((info = enumerator.next_file ()) != null) {
                var child = dir.get_child (info.get_name ());
                if (info.get_file_type () == FileType.DIRECTORY) {
                    delete_directory_tree (child);
                } else {
                    try {
                        child.delete ();
                    } catch (Error e) {
                        // Best effort cleanup for stale temp artifacts.
                    }
                }
            }
        } catch (Error e) {
            // Best effort cleanup for stale temp artifacts.
        } finally {
            if (enumerator != null) {
                try {
                    enumerator.close ();
                } catch (Error e) {
                    // Best effort cleanup for stale temp artifacts.
                }
            }
        }

        try {
            dir.delete ();
        } catch (Error e) {
            // Best effort cleanup for stale temp artifacts.
        }
    }

    private void cleanup_stale_managed_run_dirs_in_tree (File dir, string root) {
        FileEnumerator? enumerator = null;
        try {
            enumerator = dir.enumerate_children (
                "%s,%s".printf (
                    FileAttribute.STANDARD_NAME,
                    FileAttribute.STANDARD_TYPE
                ),
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS
            );

            FileInfo? info;
            while ((info = enumerator.next_file ()) != null) {
                if (info.get_file_type () != FileType.DIRECTORY)
                    continue;

                var child = dir.get_child (info.get_name ());
                string? child_path = child.get_path ();
                if (child_path == null || !is_same_or_descendant_path (child_path, root))
                    continue;

                if (should_remove_stale_managed_run_dir (child, info.get_name ())) {
                    delete_directory_tree (child);
                    try_remove_empty_dir_chain (Path.get_dirname (child_path), root);
                    continue;
                }

                cleanup_stale_managed_run_dirs_in_tree (child, root);
            }
        } catch (Error e) {
            // Best effort cleanup for stale temp artifacts.
        } finally {
            if (enumerator != null) {
                try {
                    enumerator.close ();
                } catch (Error e) {
                    // Best effort cleanup for stale temp artifacts.
                }
            }
        }
    }

    private string[] get_managed_temp_top_level_branches () {
        return {
            "conversion",
            "audio-player",
            "audio-runner",
            "smart-optimizer",
            "combine"
        };
    }

    public void cleanup_stale_managed_temp_runs () {
        string root = get_app_temp_root ();
        if (!FileUtils.test (root, FileTest.IS_DIR))
            return;

        foreach (string branch_name in get_managed_temp_top_level_branches ()) {
            string branch_path = Path.build_filename (root, branch_name);
            if (!FileUtils.test (branch_path, FileTest.IS_DIR))
                continue;

            cleanup_stale_managed_run_dirs_in_tree (
                File.new_for_path (branch_path),
                root
            );
            try_remove_empty_dir_chain (branch_path, root);
        }

        try_remove_empty_dir_chain (root, root);
    }

    public void try_remove_empty_dir_chain (string start_dir, string stop_dir) {
        if (start_dir.length == 0 || stop_dir.length == 0)
            return;

        string current = start_dir;
        while (is_same_or_descendant_path (current, stop_dir)) {
            try {
                File.new_for_path (current).delete ();
            } catch (Error e) {
                break;
            }

            if (current == stop_dir)
                break;

            string parent = Path.get_dirname (current);
            if (parent == current)
                break;

            current = parent;
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

        return sanitize_filename (@"$out_folder/$name_stem.$container_ext");
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

        return sanitize_filename (@"$out_folder/$name_stem.$container_ext");
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

        // Strip leading dots and hyphens — prevent hidden files on Linux
        // and avoid option-like filenames.
        while (result.has_prefix (".") || result.has_prefix ("-")) {
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

    public string? find_unique_path (string path) {
        return find_unique_path_internal (path, null);
    }

    public string? find_unique_path_with_reserved (string path,
                                                   HashTable<string, bool>? reserved_paths = null) {
        return find_unique_path_internal (path, reserved_paths);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  FILENAME SANITIZATION
    // ═════════════════════════════════════════════════════════════════════════

    public string sanitize_filename (string path) {
        string dir = Path.get_dirname (path);
        string name = Path.get_basename (path);

        string safe = sanitize_file_component (name);
        safe = safe.replace (". ", ".").replace (" .", ".");
        if (safe.length == 0)
            safe = "untitled";

        return Path.build_filename (dir, safe);
    }

    public bool try_parse_non_negative_int_strict (string text, out int value) {
        value = 0;
        if (text.length == 0)
            return false;

        for (int i = 0; i < text.length; i++) {
            char c = text[i];
            if (c < '0' || c > '9')
                return false;

            int digit = c - '0';
            if (value > (int.MAX - digit) / 10)
                return false;
            value = (value * 10) + digit;
        }

        return true;
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
        int hours = 0;
        int minutes = 0;
        int seconds_whole = 0;
        if (!try_parse_non_negative_int_strict (parts[0], out hours))
            return -1.0;
        if (parts[1].length != 2 || !try_parse_non_negative_int_strict (parts[1], out minutes))
            return -1.0;

        string seconds_part = parts[2];
        int frac_sep = seconds_part.index_of_char ('.');
        string whole_seconds = (frac_sep >= 0) ? seconds_part.substring (0, frac_sep) : seconds_part;
        string fraction = (frac_sep >= 0) ? seconds_part.substring (frac_sep + 1) : "";

        if (whole_seconds.length != 2
            || !try_parse_non_negative_int_strict (whole_seconds, out seconds_whole))
            return -1.0;
        if (frac_sep >= 0 && (fraction.length == 0 || !is_ascii_digits (fraction)))
            return -1.0;

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
        string result = sanitize_file_component (name);
        while (result.has_suffix (".")) {
            result = result.substring (0, result.length - 1);
        }
        return result.length > 0 ? result : "untitled";
    }

    /**
     * Zero-pad a segment number to 3 digits (001, 012, 123).
     */
    public string pad_segment_number (int n) {
        if (n <= 0)
            return "000";
        if (n < 10) return "00" + n.to_string ();
        if (n < 100) return "0" + n.to_string ();
        return n.to_string ();
    }

    private string? find_unique_path_internal (string path,
                                               HashTable<string, bool>? reserved_paths) {
        if (!path_conflicts (path, reserved_paths))
            return path;

        string dir = Path.get_dirname (path);
        string basename = Path.get_basename (path);

        int dot_pos = basename.last_index_of_char ('.');
        string stem = (dot_pos > 0) ? basename.substring (0, dot_pos) : basename;
        string ext  = (dot_pos > 0) ? basename.substring (dot_pos) : "";

        for (int counter = 1; counter <= MAX_UNIQUE_PATH_ATTEMPTS; counter++) {
            string candidate = build_unique_path_candidate (
                dir, stem, ext, counter.to_string ());
            if (!path_conflicts (candidate, reserved_paths))
                return candidate;
        }

        warning ("ConversionUtils: Exhausted %d numeric suffixes for %s; falling back to randomized path",
                 MAX_UNIQUE_PATH_ATTEMPTS, path);

        string seed = Uuid.string_random ();
        for (uint64 attempt = 0; attempt < MAX_RANDOM_UNIQUE_PATH_ATTEMPTS; attempt++) {
            string suffix = (attempt == 0) ? seed : @"$seed-$attempt";
            string candidate = build_unique_path_candidate (dir, stem, ext, suffix);
            if (!path_conflicts (candidate, reserved_paths))
                return candidate;
        }

        warning ("ConversionUtils: Could not derive a unique output path for %s after %d randomized attempts",
                 path, MAX_RANDOM_UNIQUE_PATH_ATTEMPTS);
        return null;
    }

    private bool path_conflicts (string path,
                                 HashTable<string, bool>? reserved_paths = null) {
        return FileUtils.test (path, FileTest.EXISTS)
            || (reserved_paths != null && reserved_paths.contains (path));
    }

    private string build_unique_path_candidate (string dir,
                                                string stem,
                                                string ext,
                                                string suffix) {
        return Path.build_filename (dir, @"$stem-$suffix$ext");
    }

    private string sanitize_file_component (string name) {
        var sb = new StringBuilder ();
        unichar c;
        int i = 0;
        while (name.get_next_char (ref i, out c)) {
            if (is_disallowed_filename_char (c)) {
                sb.append_c ('_');
            } else {
                sb.append_unichar (c);
            }
        }
        string result = sb.str.strip ();
        while (result.has_prefix (".") || result.has_prefix ("-")) {
            result = result.substring (1);
        }
        return result;
    }

    private bool is_disallowed_filename_char (unichar c) {
        return c == '\0' || c == '\n' || c == '\r' || c == '\t'
            || c == '/' || c == '\\' || c == ':' || c == '*'
            || c == '?' || c == '"' || c == '<' || c == '>'
            || c == '|' || c == '：' || c == '？'
            || c < 0x20 || c == 0x7f;
    }
}
