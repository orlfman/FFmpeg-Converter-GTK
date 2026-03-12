using Gtk;
using Adw;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  BaseCodecTab — Abstract base class for codec-specific tabs
//
//  Extracts code duplicated identically across SvtAv1Tab, X265Tab, X264Tab,
//  and Vp9Tab:
//
//   • ICodecTab implementations: get_container, get_two_pass, get_audio_args,
//     snapshot_keyframe_settings
//   • ISmartCodecTab implementations: get_auto_convert_active,
//     get_strip_audio_active, get_audio_settings_ref
//   • Smart Optimizer UI section (smart_row, auto_convert_row, strip_audio_row)
//   • Shared property declarations and the smart_optimizer_requested signal
//
//  Subclasses implement get_codec_builder() and apply_smart_recommendation(),
//  plus build their codec-specific UI.  Shared widgets (container_combo,
//  two_pass_switch, etc.) are declared here as protected and assigned during
//  the subclass's construction.
// ═══════════════════════════════════════════════════════════════════════════════

public abstract class BaseCodecTab : Box, ICodecTab, ISmartCodecTab {

    protected delegate void GeneralTabSyncFunc ();

    // ── Signals ──────────────────────────────────────────────────────────────
    public signal void smart_optimizer_requested ();

    // ── Shared Smart Optimizer State ─────────────────────────────────────────
    public bool auto_convert_active { get; protected set; default = false; }
    public bool strip_audio_active  { get; protected set; default = false; }

    // ── Shared Widgets (assigned by subclass during construction) ─────────────
    public AudioSettings audio_settings       { get; protected set; }
    public DropDown      container_combo       { get; protected set; }
    public Switch        two_pass_switch       { get; protected set; }
    public DropDown      keyint_combo          { get; protected set; }
    public DropDown      custom_keyframe_combo { get; protected set; }

    // ── Shared GeneralTab binding for codec/profile compatibility logic ─────
    protected GeneralTab? profile_general_tab = null;
    public bool general_tab_sync_active { get; set; default = false; }
    private ulong general_tab_8bit_handler = 0;
    private ulong general_tab_10bit_handler = 0;
    private ulong general_tab_8bit_fmt_handler = 0;
    private ulong general_tab_10bit_fmt_handler = 0;
    private bool last_profile_sync_was_auto = true;
    private bool auto_profile_8bit_active = false;
    private string auto_profile_8bit_format = "8-bit 4:2:0";
    private bool auto_profile_10bit_active = false;
    private string auto_profile_10bit_format = "10-bit 4:2:0";

    public override void dispose () {
        disconnect_general_tab_signals ();
        profile_general_tab = null;
        base.dispose ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ICodecTab — Concrete implementations (identical across all 4 tabs)
    // ═════════════════════════════════════════════════════════════════════════

    public string get_container () {
        return CodecUtils.get_dropdown_text (container_combo);
    }

    public bool get_two_pass () {
        return two_pass_switch.active;
    }

    public string[] get_audio_args () {
        return audio_settings.get_audio_args ();
    }

    public CodecTabSettingsSnapshot snapshot_settings (
        GeneralSettingsSnapshot? general_settings = null) {
        var snapshot = new CodecTabSettingsSnapshot ();
        string container = get_container ();
        if (container.length > 0)
            snapshot.container = container;
        snapshot.keyframe_settings = snapshot_keyframe_settings (general_settings);
        snapshot.audio_settings = audio_settings.snapshot_settings ();
        return snapshot;
    }

    public KeyframeSettingsSnapshot snapshot_keyframe_settings (
        GeneralSettingsSnapshot? general_settings) {
        var snapshot = new KeyframeSettingsSnapshot ();
        snapshot.keyint_text = CodecUtils.get_dropdown_text (keyint_combo);
        snapshot.custom_mode = (int) custom_keyframe_combo.get_selected ();

        if (general_settings != null) {
            snapshot.frame_rate_text = general_settings.frame_rate_text;
            snapshot.custom_frame_rate_text = general_settings.custom_frame_rate_text;
        }

        return snapshot;
    }

    // Each codec provides its own builder
    public abstract ICodecBuilder get_codec_builder ();

    // ═════════════════════════════════════════════════════════════════════════
    //  ISmartCodecTab — Concrete implementations
    // ═════════════════════════════════════════════════════════════════════════

    public bool get_auto_convert_active ()       { return auto_convert_active; }
    public bool get_strip_audio_active ()        { return strip_audio_active; }
    public AudioSettings get_audio_settings_ref () { return audio_settings; }

    // Each codec applies recommendations differently
    public abstract void apply_smart_recommendation (OptimizationRecommendation rec);

    protected void rebind_general_tab (GeneralTab? value, GeneralTabSyncFunc sync_func) {
        if (value == profile_general_tab) {
            sync_func ();
            return;
        }

        disconnect_general_tab_signals ();
        profile_general_tab = value;
        connect_general_tab_signals (sync_func);
        sync_func ();
    }

    public abstract void sync_general_tab_now ();

    private void disconnect_general_tab_signals () {
        if (profile_general_tab == null) {
            general_tab_8bit_handler = 0;
            general_tab_10bit_handler = 0;
            general_tab_8bit_fmt_handler = 0;
            general_tab_10bit_fmt_handler = 0;
            return;
        }

        if (general_tab_8bit_handler != 0) {
            SignalHandler.disconnect (profile_general_tab.eight_bit_check, general_tab_8bit_handler);
            general_tab_8bit_handler = 0;
        }
        if (general_tab_10bit_handler != 0) {
            SignalHandler.disconnect (profile_general_tab.ten_bit_check, general_tab_10bit_handler);
            general_tab_10bit_handler = 0;
        }
        if (general_tab_8bit_fmt_handler != 0) {
            SignalHandler.disconnect (profile_general_tab.eight_bit_format, general_tab_8bit_fmt_handler);
            general_tab_8bit_fmt_handler = 0;
        }
        if (general_tab_10bit_fmt_handler != 0) {
            SignalHandler.disconnect (profile_general_tab.ten_bit_format, general_tab_10bit_fmt_handler);
            general_tab_10bit_fmt_handler = 0;
        }
    }

    private void connect_general_tab_signals (GeneralTabSyncFunc sync_func) {
        if (profile_general_tab == null) return;

        general_tab_8bit_handler =
            profile_general_tab.eight_bit_check.notify["active"].connect (() => sync_func ());
        general_tab_10bit_handler =
            profile_general_tab.ten_bit_check.notify["active"].connect (() => sync_func ());
        general_tab_8bit_fmt_handler =
            profile_general_tab.eight_bit_format.notify["selected"].connect (() => sync_func ());
        general_tab_10bit_fmt_handler =
            profile_general_tab.ten_bit_format.notify["selected"].connect (() => sync_func ());
    }

    protected void set_dropdown_options (DropDown dropdown,
                                         string[] options,
                                         string fallback_option) {
        CodecUtils.set_dropdown_options (dropdown, options, fallback_option);
    }

    protected bool was_last_profile_sync_auto () {
        return last_profile_sync_was_auto;
    }

    protected void mark_last_profile_sync_auto (bool is_auto) {
        last_profile_sync_was_auto = is_auto;
    }

    protected void capture_auto_profile_general_state () {
        if (profile_general_tab == null) {
            return;
        }

        auto_profile_8bit_active = profile_general_tab.eight_bit_check.active;
        auto_profile_8bit_format = CodecUtils.get_dropdown_text (
            profile_general_tab.eight_bit_format);
        auto_profile_10bit_active = profile_general_tab.ten_bit_check.active;
        auto_profile_10bit_format = CodecUtils.get_dropdown_text (
            profile_general_tab.ten_bit_format);
    }

    protected void restore_auto_profile_general_state () {
        if (profile_general_tab == null) {
            return;
        }

        if (auto_profile_8bit_active) {
            if (!profile_general_tab.eight_bit_check.active) {
                profile_general_tab.eight_bit_check.set_active (true);
            }
            CodecUtils.set_dropdown_selection_by_text (
                profile_general_tab.eight_bit_format,
                auto_profile_8bit_format
            );
            return;
        }

        if (auto_profile_10bit_active) {
            if (!profile_general_tab.ten_bit_check.active) {
                profile_general_tab.ten_bit_check.set_active (true);
            }
            CodecUtils.set_dropdown_selection_by_text (
                profile_general_tab.ten_bit_format,
                auto_profile_10bit_format
            );
            return;
        }

        if (profile_general_tab.eight_bit_check.active) {
            profile_general_tab.eight_bit_check.set_active (false);
        }
        if (profile_general_tab.ten_bit_check.active) {
            profile_general_tab.ten_bit_check.set_active (false);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SHARED SMART OPTIMIZER UI BUILDER
    //
    //  Adds the Smart Optimizer button, Auto-Convert toggle, and No Audio
    //  toggle to the provided PreferencesGroup.  Called by each subclass
    //  in its build_quality_profile_group() method.
    // ═════════════════════════════════════════════════════════════════════════

    protected void add_smart_optimizer_rows (Adw.PreferencesGroup group) {
        // Smart Optimizer — ActionRow with button suffix for content-aware analysis
        var smart_row = new Adw.ActionRow ();
        smart_row.set_title ("Smart Optimizer");
        smart_row.set_subtitle ("Analyze the video and auto-configure CRF and speed for your target size");
        smart_row.add_prefix (make_smart_icon ());
        var smart_btn = new Button.with_label ("Optimize");
        smart_btn.add_css_class ("suggested-action");
        smart_btn.set_valign (Align.CENTER);
        smart_btn.clicked.connect (() => {
            smart_optimizer_requested ();
        });
        smart_row.add_suffix (smart_btn);
        smart_row.set_activatable_widget (smart_btn);
        group.add (smart_row);

        // Auto-convert toggle — per-tab, session-only.
        // When the global override in Preferences is ON, this is forced active
        // and locked insensitive. Disable the global override to control per-tab.
        var auto_convert_row = new Adw.SwitchRow ();
        auto_convert_row.set_title ("Auto-Convert");
        auto_convert_row.set_subtitle ("Start conversion automatically when optimization completes");

        bool global_on = AppSettings.get_default ().smart_optimizer_auto_convert;
        auto_convert_row.set_active (global_on);
        auto_convert_row.set_sensitive (!global_on);
        auto_convert_active = global_on;

        group.add (auto_convert_row);

        // No Audio toggle — per-tab, session-only.
        // Only visible when auto-convert is enabled on this tab.
        var strip_audio_row = new Adw.SwitchRow ();
        strip_audio_row.set_title ("No Audio");
        strip_audio_row.set_subtitle ("Strip audio from analysis and output");
        strip_audio_row.set_visible (auto_convert_active);

        bool audio_global = AppSettings.get_default ().smart_optimizer_strip_audio;
        strip_audio_row.set_active (audio_global && auto_convert_active);
        strip_audio_row.set_sensitive (!audio_global);
        strip_audio_active = audio_global && auto_convert_active;

        // Wire auto-convert → strip_audio visibility after both rows exist
        auto_convert_row.notify["active"].connect (() => {
            auto_convert_active = auto_convert_row.get_active ();
            strip_audio_row.set_visible (auto_convert_active);
            if (!auto_convert_active) {
                strip_audio_row.set_active (false);
            } else {
                bool sa_locked = AppSettings.get_default ().smart_optimizer_strip_audio;
                if (sa_locked) {
                    strip_audio_row.set_active (true);
                    strip_audio_row.set_sensitive (false);
                }
            }
        });

        // React to global override changes from Preferences.
        AppSettings.get_default ().settings_changed.connect (() => {
            bool locked = AppSettings.get_default ().smart_optimizer_auto_convert;
            if (locked) {
                auto_convert_row.set_active (true);
                auto_convert_row.set_sensitive (false);
            } else if (!auto_convert_row.get_sensitive ()) {
                auto_convert_row.set_sensitive (true);
                auto_convert_row.set_active (false);
            }
        });

        strip_audio_row.notify["active"].connect (() => {
            strip_audio_active = strip_audio_row.get_active ();
        });

        AppSettings.get_default ().settings_changed.connect (() => {
            bool locked = AppSettings.get_default ().smart_optimizer_strip_audio;
            if (!strip_audio_row.get_visible ()) return;
            if (locked) {
                strip_audio_row.set_active (true);
                strip_audio_row.set_sensitive (false);
            } else if (!strip_audio_row.get_sensitive ()) {
                strip_audio_row.set_sensitive (true);
                strip_audio_row.set_active (false);
            }
        });
        group.add (strip_audio_row);
    }

    /**
     * Build a tinted prefix icon for the Smart Optimizer row.
     */
    protected static Image make_smart_icon () {
        var img = new Image.from_icon_name ("starred-symbolic");
        img.set_pixel_size (24);
        img.set_valign (Align.CENTER);
        img.add_css_class ("accent");
        return img;
    }
}
