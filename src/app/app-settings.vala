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
    //    generate_collage_thumbnail = false      (default: false → no automatic
    //                                            4-4-4 PNG collage sidecar)
    //    play_with_ffplay = false                (default: false → use desktop
    //                                            player for Playback menu actions)
    //    hwdec_mode = auto                       (auto|auto_no_vulkan|vaapi|nvdec|
    //                                            vulkan|off)
    //                                           (default: auto → let mpv pick a
    //                                            decoder it considers reliable)
    //    preview_cache_size = small              (small|medium|large)
    //                                           (default: small → 32 MiB of
    //                                            demuxer read-ahead per preview)
    //    preview_quality = fast                  (fast|accurate)
    //                                           (default: fast → cheapest scaling
    //                                            for the software-rendered preview)
    //    hardware_decoding = true                (legacy; read only when hwdec_mode
    //                                            is absent, and kept in sync on save
    //                                            so a downgrade still behaves)
    //    recently_opened_enabled = true          (default: true → remember and
    //                                            show up to 20 input files)
    //    container_default_mode = default        (default|mkv|codec_specific)
    //                                           (default: keep current tab defaults when
    //                                            resetting codec tabs; mkv: prefer MKV;
    //                                            codec_specific: prefer WebM for SVT-AV1/VP9
    //                                            and MP4 for x264/x265)
    //    verify_unknown_audio_copy_preflight = true
    //                                           (default: true → verify audio copy compatibility
    //                                            for MP4/WebM before conversion starts)
    //    show_bit_depth_warning_dialog = true   (default: true → show the modal
    //                                            warning; false → log and continue)
//
//    [smart_optimizer]
//    target_mb = 4                           (default: 4 → 4 MB file size target)
//    auto_convert = false                    (default: false → don't auto-start conversion)
//    strip_audio = false                     (default: false → include audio in output)
//    quality_ceiling = off                   (off|low|medium|high|ultra; default: off →
//                                             codec tabs start on the size target)
//
//  Thread-safe: all reads/writes are mutex-guarded.
// ═══════════════════════════════════════════════════════════════════════════════

public class AppSettings : Object {

    // ── Singleton ─────────────────────────────────────────────────────────────
    private static AppSettings? _instance = null;
    private static Mutex instance_mutex;

    public static AppSettings get_default () {
        instance_mutex.lock ();
        try {
            if (_instance == null) {
                _instance = new AppSettings ();
            }
            return _instance;
        } finally {
            instance_mutex.unlock ();
        }
    }

    // ── Thread safety ─────────────────────────────────────────────────────────
    private Mutex mutex = Mutex ();

    // ── Backing fields ────────────────────────────────────────────────────────
    private string _ffmpeg_path  = "ffmpeg";
    private string _ffprobe_path = "ffprobe";
    private string _ffplay_path  = "ffplay";
    private string _default_output_dir = "";
    private OutputNameMode _output_name_mode = OutputNameMode.DEFAULT;
    private ContainerDefaultMode _container_default_mode = ContainerDefaultMode.DEFAULT;
    private string _output_custom_name = "";
    private bool   _overwrite_enabled = false;
    private bool   _generate_collage_thumbnail = false;
    // Off by default: the XDG handler is whatever the user already chose for
    // video, so overriding it silently would be presumptuous. ffplay is the
    // opt-in for people who want the raw decode rather than their player's.
    private bool   _play_with_ffplay = false;
    private HwdecMode _hwdec_mode = HwdecMode.AUTOMATIC;
    private PreviewQuality _preview_quality = PreviewQuality.FAST;
    private PreviewCacheSize _preview_cache_size = PreviewCacheSize.SMALL;
    private bool   _recently_opened_enabled = true;
    private string[] _recent_input_files = {};
    private bool   _verify_unknown_audio_copy_preflight = true;
    private bool   _show_bit_depth_warning_dialog = true;
    private int    _smart_optimizer_target_mb = 4;
    // On by default: the optimizer exists to configure an encode, so running
    // it is the expected next step rather than an opt-in extra. Turning this
    // off in Preferences hands per-tab control back to the codec tabs.
    private bool   _smart_optimizer_auto_convert = true;
    private bool   _smart_optimizer_strip_audio = false;
    private bool   _smart_optimizer_match_source_size = false;
    // Dropdown index, not a QualityIntent: index 0 is "Off", which the enum
    // deliberately has no member for. Matches BaseCodecTab.get_quality_intent().
    private int    _smart_optimizer_quality_ceiling = 0;

    // ── File location ─────────────────────────────────────────────────────────
    private string config_dir;
    private string config_file;

    private const string GROUP_PATHS   = "paths";
    private const string GROUP_OUTPUT  = "output";
    private const string GROUP_GENERAL = "general";
    private const string GROUP_SMART   = "smart_optimizer";
    private const string GROUP_RECENT  = "recent_files";
    public const int MAX_RECENT_INPUT_FILES = 20;

    // ── Signal: emitted after settings are saved ──────────────────────────────
    public signal void settings_changed ();
    public signal void default_output_dir_applied (string path);

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR — private
    // ═════════════════════════════════════════════════════════════════════════

    private AppSettings (string? config_root = null) {
        string resolved_config_root = config_root ?? Environment.get_user_config_dir ();
        config_dir  = Path.build_filename (
            resolved_config_root, "FFmpeg-Converter-GTK");
        config_file = Path.build_filename (config_dir, "settings.ini");

        bool normalized_path_settings = load ();
        if (normalized_path_settings) {
            save_internal (false);
        }
        ensure_output_directory ();
    }

#if COMBINE_WINDOW_TEST_BUILD
    internal static AppSettings create_for_test (string config_root) {
        return new AppSettings (config_root);
    }
#endif

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

    public ContainerDefaultMode container_default_mode {
        get {
            ContainerDefaultMode container_default_mode;
            mutex.lock ();
            try {
                container_default_mode = _container_default_mode;
            } finally {
                mutex.unlock ();
            }
            return container_default_mode;
        }
        set {
            mutex.lock ();
            try {
                _container_default_mode = value;
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

    public bool generate_collage_thumbnail {
        get {
            bool generate_collage_thumbnail;
            mutex.lock ();
            try {
                generate_collage_thumbnail = _generate_collage_thumbnail;
            } finally {
                mutex.unlock ();
            }
            return generate_collage_thumbnail;
        }
        set {
            mutex.lock ();
            try {
                _generate_collage_thumbnail = value;
            } finally {
                mutex.unlock ();
            }
        }
    }

    public bool play_with_ffplay {
        get {
            bool play_with_ffplay;
            mutex.lock ();
            try {
                play_with_ffplay = _play_with_ffplay;
            } finally {
                mutex.unlock ();
            }
            return play_with_ffplay;
        }
        set {
            mutex.lock ();
            try {
                _play_with_ffplay = value;
            } finally {
                mutex.unlock ();
            }
        }
    }

    /**
     * Which decoder the preview players ask mpv for.
     *
     * Automatic by default: hardware decoding lowers system memory use and, on
     * machines whose CPU struggles with 4K AV1, is the difference between a
     * usable preview and a stuttering one. The forced modes exist because a
     * driver that decodes incorrectly — or aborts, as in
     * docs/mpv-hwdec-vulkan-crash.md — should cost the user one decoder rather
     * than all of them.
     */
    public HwdecMode hwdec_mode {
        get {
            HwdecMode hwdec_mode;
            mutex.lock ();
            try {
                hwdec_mode = _hwdec_mode;
            } finally {
                mutex.unlock ();
            }
            return hwdec_mode;
        }
        set {
            mutex.lock ();
            try {
                _hwdec_mode = value;
            } finally {
                mutex.unlock ();
            }
        }
    }

    /**
     * How much CPU the preview players may spend scaling each frame.
     *
     * Fast by default: the preview renders in software on one thread, and the
     * machines this has to stay usable on are the ones with the least to
     * spare. Accurate is for judging banding and chroma before committing to
     * a long encode.
     */
    public PreviewQuality preview_quality {
        get {
            PreviewQuality preview_quality;
            mutex.lock ();
            try {
                preview_quality = _preview_quality;
            } finally {
                mutex.unlock ();
            }
            return preview_quality;
        }
        set {
            mutex.lock ();
            try {
                _preview_quality = value;
            } finally {
                mutex.unlock ();
            }
        }
    }

    /**
     * How much of the input each preview player keeps buffered.
     *
     * Small by default, which is the bound the backend has always used. Larger
     * values buy smoother scrubbing on slow or network storage and cost
     * exactly that much resident memory per open preview.
     */
    public PreviewCacheSize preview_cache_size {
        get {
            PreviewCacheSize preview_cache_size;
            mutex.lock ();
            try {
                preview_cache_size = _preview_cache_size;
            } finally {
                mutex.unlock ();
            }
            return preview_cache_size;
        }
        set {
            mutex.lock ();
            try {
                _preview_cache_size = value;
            } finally {
                mutex.unlock ();
            }
        }
    }

    public bool recently_opened_enabled {
        get {
            bool enabled;
            mutex.lock ();
            try {
                enabled = _recently_opened_enabled;
            } finally {
                mutex.unlock ();
            }
            return enabled;
        }
        set {
            mutex.lock ();
            try {
                _recently_opened_enabled = value;
                // Disabling history is also a privacy action: forget paths
                // already collected so the next save removes them from
                // settings.ini instead of merely hiding them from the menu.
                if (!value)
                    _recent_input_files = {};
            } finally {
                mutex.unlock ();
            }
        }
    }

    public string[] recent_input_files {
        owned get {
            string[] files;
            mutex.lock ();
            try {
                files = new string[_recent_input_files.length];
                for (int i = 0; i < _recent_input_files.length; i++)
                    files[i] = _recent_input_files[i];
            } finally {
                mutex.unlock ();
            }
            return files;
        }
    }

    /**
     * Return a newest-first, de-duplicated and bounded recent-file list.
     * Missing files are discarded when `require_existing` is true.
     */
    internal static string[] sanitize_recent_input_files (
        string[] paths,
        bool require_existing = true
    ) {
        string[] clean = {};

        foreach (unowned string path in paths) {
            if (path.length == 0)
                continue;

            string canonical = Filename.canonicalize (
                path, Environment.get_current_dir ());
            if (require_existing
                    && !FileUtils.test (canonical, FileTest.IS_REGULAR)) {
                continue;
            }

            bool duplicate = false;
            foreach (unowned string existing in clean) {
                if (existing == canonical) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate)
                continue;

            clean += canonical;
            if (clean.length >= MAX_RECENT_INPUT_FILES)
                break;
        }

        return clean;
    }

    /** Record an existing input file and move it to the front of the list. */
    public void record_recent_input_file (string path) {
        if (path.length == 0 || !recently_opened_enabled)
            return;

        string canonical = Filename.canonicalize (
            path, Environment.get_current_dir ());
        if (!FileUtils.test (canonical, FileTest.IS_REGULAR))
            return;

        bool changed = false;
        mutex.lock ();
        try {
            string[] candidates = { canonical };
            foreach (unowned string existing in _recent_input_files)
                candidates += existing;
            string[] updated = sanitize_recent_input_files (candidates);
            if (!string_arrays_equal (updated, _recent_input_files)) {
                _recent_input_files = updated;
                changed = true;
            }
        } finally {
            mutex.unlock ();
        }

        if (changed)
            save_internal (true);
    }

    /** Remove missing files from history and persist the cleaned list. */
    public bool prune_recent_input_files () {
        bool changed = false;
        mutex.lock ();
        try {
            string[] updated = sanitize_recent_input_files (_recent_input_files);
            if (!string_arrays_equal (updated, _recent_input_files)) {
                _recent_input_files = updated;
                changed = true;
            }
        } finally {
            mutex.unlock ();
        }

        // Pruning is maintenance, not a preference change. Avoid recursively
        // rebuilding an open hamburger menu through settings_changed.
        if (changed)
            save_internal (false);
        return changed;
    }

    public void clear_recent_input_files () {
        bool changed = false;
        mutex.lock ();
        try {
            if (_recent_input_files.length > 0) {
                _recent_input_files = {};
                changed = true;
            }
        } finally {
            mutex.unlock ();
        }

        if (changed)
            save_internal (true);
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

    public bool verify_unknown_audio_copy_preflight {
        get {
            bool verify_unknown_audio_copy_preflight;
            mutex.lock ();
            try {
                verify_unknown_audio_copy_preflight = _verify_unknown_audio_copy_preflight;
            } finally {
                mutex.unlock ();
            }
            return verify_unknown_audio_copy_preflight;
        }
        set {
            mutex.lock ();
            try {
                _verify_unknown_audio_copy_preflight = value;
            } finally {
                mutex.unlock ();
            }
        }
    }

    public bool show_bit_depth_warning_dialog {
        get {
            bool show_dialog;
            mutex.lock ();
            try {
                show_dialog = _show_bit_depth_warning_dialog;
            } finally {
                mutex.unlock ();
            }
            return show_dialog;
        }
        set {
            mutex.lock ();
            try {
                _show_bit_depth_warning_dialog = value;
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

    public int smart_optimizer_quality_ceiling {
        get {
            int quality_ceiling;
            mutex.lock ();
            try {
                quality_ceiling = _smart_optimizer_quality_ceiling;
            } finally {
                mutex.unlock ();
            }
            return quality_ceiling;
        }
        set {
            mutex.lock ();
            try {
                _smart_optimizer_quality_ceiling =
                    clamp_smart_optimizer_quality_ceiling (value);
            } finally {
                mutex.unlock ();
            }
        }
    }

    public bool smart_optimizer_match_source_size {
        get {
            bool match_source_size;
            mutex.lock ();
            try {
                match_source_size = _smart_optimizer_match_source_size;
            } finally {
                mutex.unlock ();
            }
            return match_source_size;
        }
        set {
            mutex.lock ();
            try {
                _smart_optimizer_match_source_size = value;
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
        ContainerDefaultMode container_default_mode = ContainerDefaultMode.from_string (
            read_string (kf, GROUP_GENERAL, "container_default_mode", "default"));
        string output_custom_name = read_string (kf, GROUP_GENERAL, "output_custom_name", "");
        bool overwrite_enabled = read_bool (kf, GROUP_GENERAL, "overwrite_enabled", false);
        bool generate_collage_thumbnail = read_bool (
            kf, GROUP_GENERAL, "generate_collage_thumbnail", false);
        bool verify_unknown_audio_copy_preflight = read_bool (
            kf, GROUP_GENERAL, "verify_unknown_audio_copy_preflight", true);
        bool show_bit_depth_warning_dialog = read_bool (
            kf, GROUP_GENERAL, "show_bit_depth_warning_dialog", true);
        bool play_with_ffplay = read_bool (
            kf, GROUP_GENERAL, "play_with_ffplay", false);
        // Before the mode existed this preference was a bool. An absent
        // hwdec_mode means a file written by that version, so fall back to it:
        // "off" is the only intent the default cannot stand in for.
        string hwdec_token = read_string (kf, GROUP_GENERAL, "hwdec_mode", "");
        HwdecMode hwdec_mode = hwdec_token == ""
            ? (read_bool (kf, GROUP_GENERAL, "hardware_decoding", true)
                ? HwdecMode.AUTOMATIC
                : HwdecMode.OFF)
            : HwdecMode.from_string (hwdec_token);
        PreviewQuality preview_quality = PreviewQuality.from_string (
            read_string (kf, GROUP_GENERAL, "preview_quality", "fast"));
        PreviewCacheSize preview_cache_size = PreviewCacheSize.from_string (
            read_string (kf, GROUP_GENERAL, "preview_cache_size", "small"));
        bool recently_opened_enabled = read_bool (
            kf, GROUP_GENERAL, "recently_opened_enabled", true);
        string[] raw_recent_input_files = read_string_list (
            kf, GROUP_RECENT, "input_files");
        string[] recent_input_files = sanitize_recent_input_files (
            raw_recent_input_files);
        int smart_optimizer_target_mb = clamp_smart_optimizer_target_mb (
            read_int (kf, GROUP_SMART, "target_mb", 4));
        // Fallback applies only when the key is absent — a fresh install or a
        // config predating this setting. save() always writes the key, so an
        // existing user who turned auto-convert off keeps it off.
        bool smart_optimizer_auto_convert = read_bool (kf, GROUP_SMART, "auto_convert", true);
        bool smart_optimizer_strip_audio = read_bool (kf, GROUP_SMART, "strip_audio", false);
        bool smart_optimizer_match_source_size = read_bool (
            kf, GROUP_SMART, "match_source_size", false);
        int smart_optimizer_quality_ceiling = quality_ceiling_from_key (
            read_string (kf, GROUP_SMART, "quality_ceiling", "off"));

        mutex.lock ();
        try {
            _ffmpeg_path = ffmpeg_path;
            _ffprobe_path = ffprobe_path;
            _ffplay_path = ffplay_path;
            _default_output_dir = default_output_dir;
            _output_name_mode = output_name_mode;
            _container_default_mode = container_default_mode;
            _output_custom_name = output_custom_name;
            _overwrite_enabled = overwrite_enabled;
            _generate_collage_thumbnail = generate_collage_thumbnail;
            _play_with_ffplay = play_with_ffplay;
            _hwdec_mode = hwdec_mode;
            _preview_quality = preview_quality;
            _preview_cache_size = preview_cache_size;
            _recently_opened_enabled = recently_opened_enabled;
            _recent_input_files = recent_input_files;
            _verify_unknown_audio_copy_preflight = verify_unknown_audio_copy_preflight;
            _show_bit_depth_warning_dialog = show_bit_depth_warning_dialog;
            _smart_optimizer_target_mb = smart_optimizer_target_mb;
            _smart_optimizer_auto_convert = smart_optimizer_auto_convert;
            _smart_optimizer_strip_audio = smart_optimizer_strip_audio;
            _smart_optimizer_match_source_size = smart_optimizer_match_source_size;
            _smart_optimizer_quality_ceiling = smart_optimizer_quality_ceiling;
        } finally {
            mutex.unlock ();
        }

        return ffmpeg_path != raw_ffmpeg_path
            || ffprobe_path != raw_ffprobe_path
            || ffplay_path != raw_ffplay_path
            || !string_arrays_equal (
                recent_input_files, raw_recent_input_files);
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
        ContainerDefaultMode container_default_mode;
        string output_custom_name;
        bool overwrite_enabled;
        bool generate_collage_thumbnail;
        bool play_with_ffplay;
        HwdecMode hwdec_mode;
        PreviewQuality preview_quality;
        PreviewCacheSize preview_cache_size;
        bool recently_opened_enabled;
        string[] recent_input_files;
        bool verify_unknown_audio_copy_preflight;
        bool show_bit_depth_warning_dialog;
        int smart_optimizer_target_mb;
        bool smart_optimizer_auto_convert;
        bool smart_optimizer_strip_audio;
        bool smart_optimizer_match_source_size;
        int smart_optimizer_quality_ceiling;

        mutex.lock ();
        try {
            ffmpeg_path = _ffmpeg_path;
            ffprobe_path = _ffprobe_path;
            ffplay_path = _ffplay_path;
            default_output_dir = _default_output_dir;
            output_name_mode = _output_name_mode;
            container_default_mode = _container_default_mode;
            output_custom_name = _output_custom_name;
            overwrite_enabled = _overwrite_enabled;
            generate_collage_thumbnail = _generate_collage_thumbnail;
            play_with_ffplay = _play_with_ffplay;
            hwdec_mode = _hwdec_mode;
            preview_quality = _preview_quality;
            preview_cache_size = _preview_cache_size;
            recently_opened_enabled = _recently_opened_enabled;
            recent_input_files = new string[_recent_input_files.length];
            for (int i = 0; i < _recent_input_files.length; i++)
                recent_input_files[i] = _recent_input_files[i];
            verify_unknown_audio_copy_preflight = _verify_unknown_audio_copy_preflight;
            show_bit_depth_warning_dialog = _show_bit_depth_warning_dialog;
            smart_optimizer_target_mb = _smart_optimizer_target_mb;
            smart_optimizer_auto_convert = _smart_optimizer_auto_convert;
            smart_optimizer_strip_audio = _smart_optimizer_strip_audio;
            smart_optimizer_match_source_size = _smart_optimizer_match_source_size;
            smart_optimizer_quality_ceiling = _smart_optimizer_quality_ceiling;
        } finally {
            mutex.unlock ();
        }

        kf.set_string (GROUP_PATHS, "ffmpeg", ffmpeg_path);
        kf.set_string (GROUP_PATHS, "ffprobe", ffprobe_path);
        kf.set_string (GROUP_PATHS, "ffplay", ffplay_path);
        kf.set_string (GROUP_OUTPUT, "default_directory", default_output_dir);
        kf.set_string (GROUP_GENERAL, "output_name_mode", output_name_mode.to_string ());
        kf.set_string (GROUP_GENERAL, "container_default_mode", container_default_mode.to_string ());
        kf.set_string (GROUP_GENERAL, "output_custom_name", output_custom_name);
        kf.set_boolean (GROUP_GENERAL, "overwrite_enabled", overwrite_enabled);
        kf.set_boolean (
            GROUP_GENERAL,
            "generate_collage_thumbnail",
            generate_collage_thumbnail
        );
        kf.set_boolean (
            GROUP_GENERAL,
            "verify_unknown_audio_copy_preflight",
            verify_unknown_audio_copy_preflight
        );
        kf.set_boolean (
            GROUP_GENERAL,
            "show_bit_depth_warning_dialog",
            show_bit_depth_warning_dialog
        );
        kf.set_boolean (GROUP_GENERAL, "play_with_ffplay", play_with_ffplay);
        kf.set_string (GROUP_GENERAL, "hwdec_mode", hwdec_mode.to_string ());
        kf.set_string (GROUP_GENERAL, "preview_quality",
                       preview_quality.to_string ());
        kf.set_string (GROUP_GENERAL, "preview_cache_size",
                       preview_cache_size.to_string ());
        // Kept in sync purely so downgrading to a version that predates the
        // mode reads the user's intent rather than silently defaulting back on.
        kf.set_boolean (GROUP_GENERAL, "hardware_decoding",
                        hwdec_mode != HwdecMode.OFF);
        kf.set_boolean (
            GROUP_GENERAL,
            "recently_opened_enabled",
            recently_opened_enabled
        );
        if (recent_input_files.length > 0)
            kf.set_string_list (GROUP_RECENT, "input_files", recent_input_files);
        kf.set_integer (GROUP_SMART, "target_mb", smart_optimizer_target_mb);
        kf.set_boolean (GROUP_SMART, "auto_convert", smart_optimizer_auto_convert);
        kf.set_boolean (GROUP_SMART, "strip_audio", smart_optimizer_strip_audio);
        kf.set_boolean (GROUP_SMART, "match_source_size", smart_optimizer_match_source_size);
        kf.set_string (GROUP_SMART, "quality_ceiling",
            quality_ceiling_to_key (smart_optimizer_quality_ceiling));

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
            _container_default_mode = ContainerDefaultMode.DEFAULT;
            _output_custom_name = "";
            _overwrite_enabled  = false;
            _generate_collage_thumbnail = false;
            _play_with_ffplay = false;
            _hwdec_mode = HwdecMode.AUTOMATIC;
            _preview_quality = PreviewQuality.FAST;
            _preview_cache_size = PreviewCacheSize.SMALL;
            _recently_opened_enabled = true;
            _verify_unknown_audio_copy_preflight = true;
            _show_bit_depth_warning_dialog = true;
            _smart_optimizer_target_mb = clamp_smart_optimizer_target_mb (4);
            _smart_optimizer_auto_convert = true;
            _smart_optimizer_strip_audio = false;
            _smart_optimizer_match_source_size = false;
            _smart_optimizer_quality_ceiling = 0;
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
        return SmartOptimizerLogic.clamp_target_mb (value);
    }

    // Stored as a name rather than the raw index so the config file stays
    // readable and survives any future reordering of the dropdown.
    private const string[] QUALITY_CEILING_KEYS = {
        "off", "low", "medium", "high", "ultra"
    };

    public static int clamp_smart_optimizer_quality_ceiling (int value) {
        // The cast is load-bearing. `.length` on a const array becomes
        // G_N_ELEMENTS, which is gsize — unsigned. CLAMP then compares the
        // signed input against an unsigned bound, promoting any negative
        // value to a huge one, and clamps it UP to Ultra instead of down to
        // Off. Forcing the bound to int keeps the comparison signed.
        return value.clamp (0, (int) QUALITY_CEILING_KEYS.length - 1);
    }

    private static string quality_ceiling_to_key (int value) {
        return QUALITY_CEILING_KEYS[clamp_smart_optimizer_quality_ceiling (value)];
    }

    private static int quality_ceiling_from_key (string key) {
        string needle = key.down ().strip ();
        for (int i = 0; i < QUALITY_CEILING_KEYS.length; i++) {
            if (QUALITY_CEILING_KEYS[i] == needle)
                return i;
        }
        // An unrecognised value means a hand-edited or newer config; falling
        // back to Off keeps the size target as the constraint rather than
        // silently pinning a quality tier the user never chose.
        return 0;
    }

    private static bool read_bool (KeyFile kf, string group,
                                   string key, bool fallback) {
        try {
            return kf.get_boolean (group, key);
        } catch (KeyFileError e) {
            return fallback;
        }
    }

    private static string[] read_string_list (KeyFile kf, string group,
                                              string key) {
        try {
            return kf.get_string_list (group, key);
        } catch (KeyFileError e) {
            return {};
        }
    }

    private static bool string_arrays_equal (string[] a, string[] b) {
        if (a.length != b.length)
            return false;
        for (int i = 0; i < a.length; i++) {
            if (a[i] != b[i])
                return false;
        }
        return true;
    }
}
