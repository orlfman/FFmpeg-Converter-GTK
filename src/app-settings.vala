using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  AppSettings — Persistent application settings (singleton)
//
//  Stores user preferences in:
//      ~/.config/FFmpeg-Converter-GTK/settings.ini
//
//  Uses GLib.KeyFile for human-readable INI-style storage.
//
//  Settings:
//    [paths]
//    ffmpeg  = /usr/bin/ffmpeg       (default: "ffmpeg" → PATH lookup)
//    ffprobe = /usr/bin/ffprobe      (default: "ffprobe" → PATH lookup)
//    ffplay  = /usr/bin/ffplay       (default: "ffplay" → PATH lookup)
//
//    [output]
//    default_directory = /home/user/Videos   (default: "" → same as input)
//
//    [general]
//    output_name_mode  = default             (default|custom|random|date|metadata)
//    output_custom_name = my_video           (default: "" → used when mode=custom)
//    overwrite_enabled = false               (default: false → prompt before overwriting)
//
//    [smart_optimizer]
//    target_mb = 4                           (default: 4 → 4 MB file size target)
//    auto_convert = false                    (default: false → don't auto-start conversion)
//    strip_audio = false                     (default: false → include audio in output)
//
//  Thread-safe: all reads/writes are mutex-guarded.
// ═══════════════════════════════════════════════════════════════════════════════

public class AppSettings : Object {

    // ── Singleton ─────────────────────────────────────────────────────────────
    private static AppSettings? _instance = null;

    public static AppSettings get_default () {
        if (_instance == null) {
            _instance = new AppSettings ();
        }
        return _instance;
    }

    // ── Thread safety ─────────────────────────────────────────────────────────
    private Mutex mutex = Mutex ();

    // ── Backing fields ────────────────────────────────────────────────────────
    private string _ffmpeg_path  = "ffmpeg";
    private string _ffprobe_path = "ffprobe";
    private string _ffplay_path  = "ffplay";
    private string _default_output_dir = "";
    private OutputNameMode _output_name_mode = OutputNameMode.DEFAULT;
    private string _output_custom_name = "";
    private bool   _overwrite_enabled = false;
    private int    _smart_optimizer_target_mb = 4;
    private bool   _smart_optimizer_auto_convert = false;
    private bool   _smart_optimizer_strip_audio = false;

    // ── File location ─────────────────────────────────────────────────────────
    private string config_dir;
    private string config_file;

    private const string GROUP_PATHS   = "paths";
    private const string GROUP_OUTPUT  = "output";
    private const string GROUP_GENERAL = "general";
    private const string GROUP_SMART   = "smart_optimizer";

    // ── Signal: emitted after settings are saved ──────────────────────────────
    public signal void settings_changed ();
    public signal void default_output_dir_applied (string path);

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR — private
    // ═════════════════════════════════════════════════════════════════════════

    private AppSettings () {
        config_dir  = Path.build_filename (
            Environment.get_user_config_dir (), "FFmpeg-Converter-GTK");
        config_file = Path.build_filename (config_dir, "settings.ini");

        bool normalized_path_settings = load ();
        if (normalized_path_settings) {
            save_internal (false);
        }
        ensure_output_directory ();
    }

    /**
     * Expand a home-relative path for the current user.
     * Leaves bare names and unsupported forms like ~otheruser unchanged.
     */
    public static string expand_home_path (string path) {
        if (path == "~" || path == "~/") {
            return Environment.get_home_dir ();
        }

        if (path.has_prefix ("~/")) {
            return Path.build_filename (Environment.get_home_dir (), path.substring (2));
        }

        return path;
    }

    /**
     * Collapse a path inside the current user's home directory to use ~.
     */
    public static string collapse_home_path (string path) {
        string home = Environment.get_home_dir ();

        if (path == home) {
            return "~";
        }

        string home_prefix = home + "/";
        if (path.has_prefix (home_prefix)) {
            return "~/" + path.substring (home_prefix.length);
        }

        return path;
    }

    /**
     * Normalize an executable setting.
     * Empty values fall back to the default bare executable name.
     */
    public static string normalize_executable_path (string value, string default_name) {
        string path = value.strip ();
        if (path.length == 0) {
            return default_name;
        }

        path = expand_home_path (path);

        // Stabilize explicit relative paths before persistence/runtime use so
        // they do not depend on the process working directory on a later launch.
        if (path.contains ("/") && !Path.is_absolute (path) && !path.has_prefix ("~")) {
            return Filename.canonicalize (path, Environment.get_current_dir ());
        }

        return path;
    }

    public string ffmpeg_path {
        owned get {
            string ffmpeg_path;
            mutex.lock ();
            try {
                ffmpeg_path = _ffmpeg_path;
            } finally {
                mutex.unlock ();
            }
            return ffmpeg_path;
        }
        set {
            mutex.lock ();
            try {
                _ffmpeg_path = normalize_executable_path (value, "ffmpeg");
            } finally {
                mutex.unlock ();
            }
        }
    }

    public string ffprobe_path {
        owned get {
            string ffprobe_path;
            mutex.lock ();
            try {
                ffprobe_path = _ffprobe_path;
            } finally {
                mutex.unlock ();
            }
            return ffprobe_path;
        }
        set {
            mutex.lock ();
            try {
                _ffprobe_path = normalize_executable_path (value, "ffprobe");
            } finally {
                mutex.unlock ();
            }
        }
    }

    public string ffplay_path {
        owned get {
            string ffplay_path;
            mutex.lock ();
            try {
                ffplay_path = _ffplay_path;
            } finally {
                mutex.unlock ();
            }
            return ffplay_path;
        }
        set {
            mutex.lock ();
            try {
                _ffplay_path = normalize_executable_path (value, "ffplay");
            } finally {
                mutex.unlock ();
            }
        }
    }

    public string default_output_dir {
        owned get {
            string default_output_dir;
            mutex.lock ();
            try {
                default_output_dir = _default_output_dir;
            } finally {
                mutex.unlock ();
            }
            return default_output_dir;
        }
        set {
            mutex.lock ();
            try {
                _default_output_dir = value.strip ();
            } finally {
                mutex.unlock ();
            }
        }
    }

    public OutputNameMode output_name_mode {
        get {
            OutputNameMode output_name_mode;
            mutex.lock ();
            try {
                output_name_mode = _output_name_mode;
            } finally {
                mutex.unlock ();
            }
            return output_name_mode;
        }
        set {
            mutex.lock ();
            try {
                _output_name_mode = value;
            } finally {
                mutex.unlock ();
            }
        }
    }

    public string output_custom_name {
        owned get {
            string output_custom_name;
            mutex.lock ();
            try {
                output_custom_name = _output_custom_name;
            } finally {
                mutex.unlock ();
            }
            return output_custom_name;
        }
        set {
            mutex.lock ();
            try {
                _output_custom_name = value.strip ();
            } finally {
                mutex.unlock ();
            }
        }
    }

    public bool overwrite_enabled {
        get {
            bool overwrite_enabled;
            mutex.lock ();
            try {
                overwrite_enabled = _overwrite_enabled;
            } finally {
                mutex.unlock ();
            }
            return overwrite_enabled;
        }
        set {
            mutex.lock ();
            try {
                _overwrite_enabled = value;
            } finally {
                mutex.unlock ();
            }
        }
    }

    public int smart_optimizer_target_mb {
        get {
            int target_mb;
            mutex.lock ();
            try {
                target_mb = _smart_optimizer_target_mb;
            } finally {
                mutex.unlock ();
            }
            return target_mb;
        }
        set {
            mutex.lock ();
            try {
                _smart_optimizer_target_mb = clamp_smart_optimizer_target_mb (value);
            } finally {
                mutex.unlock ();
            }
        }
    }

    public bool smart_optimizer_auto_convert {
        get {
            bool auto_convert;
            mutex.lock ();
            try {
                auto_convert = _smart_optimizer_auto_convert;
            } finally {
                mutex.unlock ();
            }
            return auto_convert;
        }
        set {
            mutex.lock ();
            try {
                _smart_optimizer_auto_convert = value;
            } finally {
                mutex.unlock ();
            }
        }
    }

    public bool smart_optimizer_strip_audio {
        get {
            bool strip_audio;
            mutex.lock ();
            try {
                strip_audio = _smart_optimizer_strip_audio;
            } finally {
                mutex.unlock ();
            }
            return strip_audio;
        }
        set {
            mutex.lock ();
            try {
                _smart_optimizer_strip_audio = value;
            } finally {
                mutex.unlock ();
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  LOAD — Read settings from disk
    // ═════════════════════════════════════════════════════════════════════════

    private bool load () {
        if (!FileUtils.test (config_file, FileTest.EXISTS)) {
            return false;  // First run — use defaults
        }

        var kf = new KeyFile ();
        try {
            kf.load_from_file (config_file, KeyFileFlags.NONE);
        } catch (Error e) {
            warning ("AppSettings: Failed to load %s: %s", config_file, e.message);
            return false;
        }

        string raw_ffmpeg_path = read_string (kf, GROUP_PATHS,  "ffmpeg",            "ffmpeg");
        string raw_ffprobe_path = read_string (kf, GROUP_PATHS,  "ffprobe",           "ffprobe");
        string raw_ffplay_path = read_string (kf, GROUP_PATHS,  "ffplay",            "ffplay");
        string ffmpeg_path = normalize_executable_path (raw_ffmpeg_path, "ffmpeg");
        string ffprobe_path = normalize_executable_path (raw_ffprobe_path, "ffprobe");
        string ffplay_path = normalize_executable_path (raw_ffplay_path, "ffplay");
        string default_output_dir = read_string (kf, GROUP_OUTPUT, "default_directory", "");
        OutputNameMode output_name_mode = OutputNameMode.from_string (
            read_string (kf, GROUP_GENERAL, "output_name_mode", "default"));
        string output_custom_name = read_string (kf, GROUP_GENERAL, "output_custom_name", "");
        bool overwrite_enabled = read_bool (kf, GROUP_GENERAL, "overwrite_enabled", false);
        int smart_optimizer_target_mb = clamp_smart_optimizer_target_mb (
            read_int (kf, GROUP_SMART, "target_mb", 4));
        bool smart_optimizer_auto_convert = read_bool (kf, GROUP_SMART, "auto_convert", false);
        bool smart_optimizer_strip_audio = read_bool (kf, GROUP_SMART, "strip_audio", false);

        mutex.lock ();
        try {
            _ffmpeg_path = ffmpeg_path;
            _ffprobe_path = ffprobe_path;
            _ffplay_path = ffplay_path;
            _default_output_dir = default_output_dir;
            _output_name_mode = output_name_mode;
            _output_custom_name = output_custom_name;
            _overwrite_enabled = overwrite_enabled;
            _smart_optimizer_target_mb = smart_optimizer_target_mb;
            _smart_optimizer_auto_convert = smart_optimizer_auto_convert;
            _smart_optimizer_strip_audio = smart_optimizer_strip_audio;
        } finally {
            mutex.unlock ();
        }

        return ffmpeg_path != raw_ffmpeg_path
            || ffprobe_path != raw_ffprobe_path
            || ffplay_path != raw_ffplay_path;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SAVE — Write settings to disk
    // ═════════════════════════════════════════════════════════════════════════

    public void save () {
        save_internal (true);
    }

    private void save_internal (bool emit_signal) {
        DirUtils.create_with_parents (config_dir, 0755);

        var kf = new KeyFile ();

        string ffmpeg_path;
        string ffprobe_path;
        string ffplay_path;
        string default_output_dir;
        OutputNameMode output_name_mode;
        string output_custom_name;
        bool overwrite_enabled;
        int smart_optimizer_target_mb;
        bool smart_optimizer_auto_convert;
        bool smart_optimizer_strip_audio;

        mutex.lock ();
        try {
            ffmpeg_path = _ffmpeg_path;
            ffprobe_path = _ffprobe_path;
            ffplay_path = _ffplay_path;
            default_output_dir = _default_output_dir;
            output_name_mode = _output_name_mode;
            output_custom_name = _output_custom_name;
            overwrite_enabled = _overwrite_enabled;
            smart_optimizer_target_mb = _smart_optimizer_target_mb;
            smart_optimizer_auto_convert = _smart_optimizer_auto_convert;
            smart_optimizer_strip_audio = _smart_optimizer_strip_audio;
        } finally {
            mutex.unlock ();
        }

        kf.set_string (GROUP_PATHS, "ffmpeg", ffmpeg_path);
        kf.set_string (GROUP_PATHS, "ffprobe", ffprobe_path);
        kf.set_string (GROUP_PATHS, "ffplay", ffplay_path);
        kf.set_string (GROUP_OUTPUT, "default_directory", default_output_dir);
        kf.set_string (GROUP_GENERAL, "output_name_mode", output_name_mode.to_string ());
        kf.set_string (GROUP_GENERAL, "output_custom_name", output_custom_name);
        kf.set_boolean (GROUP_GENERAL, "overwrite_enabled", overwrite_enabled);
        kf.set_integer (GROUP_SMART, "target_mb", smart_optimizer_target_mb);
        kf.set_boolean (GROUP_SMART, "auto_convert", smart_optimizer_auto_convert);
        kf.set_boolean (GROUP_SMART, "strip_audio", smart_optimizer_strip_audio);

        try {
            kf.save_to_file (config_file);
        } catch (Error e) {
            warning ("AppSettings: Failed to save %s: %s", config_file, e.message);
        }

        ensure_output_directory ();
        if (emit_signal) {
            settings_changed ();
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  RESET — Restore all settings to defaults
    // ═════════════════════════════════════════════════════════════════════════

    public void reset_to_defaults () {
        mutex.lock ();
        try {
            _ffmpeg_path        = "ffmpeg";
            _ffprobe_path       = "ffprobe";
            _ffplay_path        = "ffplay";
            _default_output_dir = "";
            _output_name_mode   = OutputNameMode.DEFAULT;
            _output_custom_name = "";
            _overwrite_enabled  = false;
            _smart_optimizer_target_mb = clamp_smart_optimizer_target_mb (4);
            _smart_optimizer_auto_convert = false;
            _smart_optimizer_strip_audio = false;
        } finally {
            mutex.unlock ();
        }

        save ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  OUTPUT DIRECTORY — Ensure it exists on disk
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * If a default output directory is configured, create it (and any parent
     * directories) if it doesn't already exist.
     *
     * This handles the common case where the directory is volatile (e.g.
     * /tmp/work) or was manually deleted between sessions. Called at startup
     * after loading settings, and can be called any time the directory is
     * about to be used.
     *
     * Returns true if the directory exists (or was created), false on failure.
     */
    public bool ensure_output_directory () {
        string dir = default_output_dir;
        if (dir.length == 0) return true;  // No directory configured — nothing to do

        if (FileUtils.test (dir, FileTest.IS_DIR)) return true;  // Already exists

        int result = DirUtils.create_with_parents (dir, 0755);
        if (result == 0) {
            message ("AppSettings: Created missing output directory: %s", dir);
            return true;
        } else {
            warning ("AppSettings: Could not create output directory %s: %s",
                     dir, strerror (errno));
            return false;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    private static string read_string (KeyFile kf, string group,
                                       string key, string fallback) {
        try {
            string val = kf.get_string (group, key);
            return (val.strip ().length > 0) ? val.strip () : fallback;
        } catch (KeyFileError e) {
            return fallback;
        }
    }

    private static int read_int (KeyFile kf, string group,
                                 string key, int fallback) {
        try {
            return kf.get_integer (group, key);
        } catch (KeyFileError e) {
            return fallback;
        }
    }

    private static int clamp_smart_optimizer_target_mb (int value) {
        return value.clamp (1, 4096);
    }

    private static bool read_bool (KeyFile kf, string group,
                                   string key, bool fallback) {
        try {
            return kf.get_boolean (group, key);
        } catch (KeyFileError e) {
            return fallback;
        }
    }
}
