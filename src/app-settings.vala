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
//    [smart_optimizer]
//    target_mb = 4                           (default: 4 → 4 MB file size target)
//    auto_convert = false                    (default: false → don't auto-start conversion)
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
    private int    _smart_optimizer_target_mb = 4;
    private bool   _smart_optimizer_auto_convert = false;

    // ── File location ─────────────────────────────────────────────────────────
    private string config_dir;
    private string config_file;

    private const string GROUP_PATHS  = "paths";
    private const string GROUP_OUTPUT = "output";
    private const string GROUP_SMART  = "smart_optimizer";

    // ── Signal: emitted after settings are saved ──────────────────────────────
    public signal void settings_changed ();

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR — private
    // ═════════════════════════════════════════════════════════════════════════

    private AppSettings () {
        config_dir  = Path.build_filename (
            Environment.get_user_config_dir (), "FFmpeg-Converter-GTK");
        config_file = Path.build_filename (config_dir, "settings.ini");

        load ();
        ensure_output_directory ();
    }

    public string ffmpeg_path {
        owned get {
            mutex.lock ();
            string v = _ffmpeg_path;
            mutex.unlock ();
            return v;
        }
        set {
            mutex.lock ();
            _ffmpeg_path = (value.strip ().length > 0) ? value.strip () : "ffmpeg";
            mutex.unlock ();
        }
    }

    public string ffprobe_path {
        owned get {
            mutex.lock ();
            string v = _ffprobe_path;
            mutex.unlock ();
            return v;
        }
        set {
            mutex.lock ();
            _ffprobe_path = (value.strip ().length > 0) ? value.strip () : "ffprobe";
            mutex.unlock ();
        }
    }

    public string ffplay_path {
        owned get {
            mutex.lock ();
            string v = _ffplay_path;
            mutex.unlock ();
            return v;
        }
        set {
            mutex.lock ();
            _ffplay_path = (value.strip ().length > 0) ? value.strip () : "ffplay";
            mutex.unlock ();
        }
    }

    public string default_output_dir {
        owned get {
            mutex.lock ();
            string v = _default_output_dir;
            mutex.unlock ();
            return v;
        }
        set {
            mutex.lock ();
            _default_output_dir = value.strip ();
            mutex.unlock ();
        }
    }

    public int smart_optimizer_target_mb {
        get {
            mutex.lock ();
            int v = _smart_optimizer_target_mb;
            mutex.unlock ();
            return v;
        }
        set {
            mutex.lock ();
            _smart_optimizer_target_mb = value.clamp (1, 4096);
            mutex.unlock ();
        }
    }

    public bool smart_optimizer_auto_convert {
        get {
            mutex.lock ();
            bool v = _smart_optimizer_auto_convert;
            mutex.unlock ();
            return v;
        }
        set {
            mutex.lock ();
            _smart_optimizer_auto_convert = value;
            mutex.unlock ();
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  LOAD — Read settings from disk
    // ═════════════════════════════════════════════════════════════════════════

    private void load () {
        if (!FileUtils.test (config_file, FileTest.EXISTS)) {
            return;  // First run — use defaults
        }

        var kf = new KeyFile ();
        try {
            kf.load_from_file (config_file, KeyFileFlags.NONE);
        } catch (Error e) {
            warning ("AppSettings: Failed to load %s: %s", config_file, e.message);
            return;
        }

        mutex.lock ();
        _ffmpeg_path        = read_string (kf, GROUP_PATHS,  "ffmpeg",            "ffmpeg");
        _ffprobe_path       = read_string (kf, GROUP_PATHS,  "ffprobe",           "ffprobe");
        _ffplay_path        = read_string (kf, GROUP_PATHS,  "ffplay",            "ffplay");
        _default_output_dir = read_string (kf, GROUP_OUTPUT, "default_directory", "");
        _smart_optimizer_target_mb = read_int (kf, GROUP_SMART, "target_mb", 4);
        _smart_optimizer_auto_convert = read_bool (kf, GROUP_SMART, "auto_convert", false);
        mutex.unlock ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SAVE — Write settings to disk
    // ═════════════════════════════════════════════════════════════════════════

    public void save () {
        DirUtils.create_with_parents (config_dir, 0755);

        var kf = new KeyFile ();

        mutex.lock ();
        kf.set_string (GROUP_PATHS,  "ffmpeg",            _ffmpeg_path);
        kf.set_string (GROUP_PATHS,  "ffprobe",           _ffprobe_path);
        kf.set_string (GROUP_PATHS,  "ffplay",            _ffplay_path);
        kf.set_string (GROUP_OUTPUT, "default_directory",  _default_output_dir);
        kf.set_integer (GROUP_SMART, "target_mb",          _smart_optimizer_target_mb);
        kf.set_boolean (GROUP_SMART, "auto_convert",       _smart_optimizer_auto_convert);
        mutex.unlock ();

        try {
            kf.save_to_file (config_file);
        } catch (Error e) {
            warning ("AppSettings: Failed to save %s: %s", config_file, e.message);
        }

        ensure_output_directory ();
        settings_changed ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  RESET — Restore all settings to defaults
    // ═════════════════════════════════════════════════════════════════════════

    public void reset_to_defaults () {
        mutex.lock ();
        _ffmpeg_path        = "ffmpeg";
        _ffprobe_path       = "ffprobe";
        _ffplay_path        = "ffplay";
        _default_output_dir = "";
        _smart_optimizer_target_mb = 4;
        _smart_optimizer_auto_convert = false;
        mutex.unlock ();

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

    private static bool read_bool (KeyFile kf, string group,
                                   string key, bool fallback) {
        try {
            return kf.get_boolean (group, key);
        } catch (KeyFileError e) {
            return fallback;
        }
    }
}
