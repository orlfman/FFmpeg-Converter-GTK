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

    // ── File location ─────────────────────────────────────────────────────────
    private string config_dir;
    private string config_file;

    private const string GROUP_PATHS  = "paths";
    private const string GROUP_OUTPUT = "output";

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
        mutex.unlock ();

        try {
            kf.save_to_file (config_file);
        } catch (Error e) {
            warning ("AppSettings: Failed to save %s: %s", config_file, e.message);
        }

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
        mutex.unlock ();

        save ();
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
}
