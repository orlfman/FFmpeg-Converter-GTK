using Gtk;
using Adw;
using GLib;

public class PixelFormatSelector : Adw.PreferencesGroup {
    public Switch   eight_bit_check  { get; private set; }
    public DropDown eight_bit_format { get; private set; }
    public Switch   ten_bit_check    { get; private set; }
    public DropDown ten_bit_format   { get; private set; }

    private enum DepthPolicy {
        OPTIONAL,
        REQUIRE_ANY,
        LOCK_8BIT,
        LOCK_10BIT
    }

    private DepthPolicy depth_policy = DepthPolicy.OPTIONAL;
    private Adw.ActionRow eight_bit_row;
    private Adw.ActionRow ten_bit_row;
    private Adw.ActionRow eight_bit_fmt_row;
    private Adw.ActionRow ten_bit_fmt_row;

    public signal void changed ();

    public PixelFormatSelector () {
        Object ();

        set_title ("Pixel Format");
        set_description ("Color depth and chroma subsampling");

        build_widgets ();
        connect_signals ();
    }

    private void build_widgets () {
        eight_bit_row = new Adw.ActionRow ();
        eight_bit_row.set_title ("8-Bit Color");
        eight_bit_row.set_subtitle ("Standard dynamic range - compatible with all players");
        eight_bit_check = new Switch ();
        eight_bit_check.set_valign (Align.CENTER);
        eight_bit_check.set_active (false);
        eight_bit_row.add_suffix (eight_bit_check);
        eight_bit_row.set_activatable_widget (eight_bit_check);
        add (eight_bit_row);

        eight_bit_fmt_row = new Adw.ActionRow ();
        eight_bit_fmt_row.set_title ("8-Bit Subsampling");
        eight_bit_format = new DropDown (new StringList (
            { "8-bit 4:2:0", "8-bit 4:2:2", "8-bit 4:4:4" }
        ), null);
        eight_bit_format.set_valign (Align.CENTER);
        eight_bit_format.set_selected (0);
        eight_bit_fmt_row.add_suffix (eight_bit_format);
        eight_bit_fmt_row.set_visible (false);
        add (eight_bit_fmt_row);

        ten_bit_row = new Adw.ActionRow ();
        ten_bit_row.set_title ("10-Bit Color");
        ten_bit_row.set_subtitle ("Higher color depth - better gradients, HDR support");
        ten_bit_check = new Switch ();
        ten_bit_check.set_valign (Align.CENTER);
        ten_bit_check.set_active (false);
        ten_bit_row.add_suffix (ten_bit_check);
        ten_bit_row.set_activatable_widget (ten_bit_check);
        add (ten_bit_row);

        ten_bit_fmt_row = new Adw.ActionRow ();
        ten_bit_fmt_row.set_title ("10-Bit Subsampling");
        ten_bit_format = new DropDown (new StringList (
            { "10-bit 4:2:0", "10-bit 4:2:2", "10-bit 4:4:4" }
        ), null);
        ten_bit_format.set_valign (Align.CENTER);
        ten_bit_format.set_selected (0);
        ten_bit_fmt_row.add_suffix (ten_bit_format);
        ten_bit_fmt_row.set_visible (false);
        add (ten_bit_fmt_row);
    }

    private void connect_signals () {
        eight_bit_check.notify["active"].connect (() => {
            eight_bit_fmt_row.set_visible (eight_bit_check.active);
            if (eight_bit_check.active)
                ten_bit_check.set_active (false);
            refresh_depth_policy_controls ();
            changed ();
        });

        ten_bit_check.notify["active"].connect (() => {
            ten_bit_fmt_row.set_visible (ten_bit_check.active);
            if (ten_bit_check.active)
                eight_bit_check.set_active (false);
            refresh_depth_policy_controls ();
            changed ();
        });

        eight_bit_format.notify["selected"].connect (() => {
            changed ();
        });

        ten_bit_format.notify["selected"].connect (() => {
            changed ();
        });
    }

    public PixelFormatSettingsSnapshot snapshot_settings () {
        var snapshot = new PixelFormatSettingsSnapshot ();
        snapshot.eight_bit_selected = eight_bit_check.active;
        snapshot.eight_bit_format_text = CodecUtils.get_dropdown_text (eight_bit_format);
        snapshot.ten_bit_selected = ten_bit_check.active;
        snapshot.ten_bit_format_text = CodecUtils.get_dropdown_text (ten_bit_format);
        return snapshot;
    }

    public void apply_snapshot (PixelFormatSettingsSnapshot snapshot) {
        if (snapshot.ten_bit_selected) {
            ten_bit_check.set_active (true);
            CodecUtils.set_dropdown_selection_by_text (
                ten_bit_format, snapshot.ten_bit_format_text);
            return;
        }

        if (snapshot.eight_bit_selected) {
            eight_bit_check.set_active (true);
            CodecUtils.set_dropdown_selection_by_text (
                eight_bit_format, snapshot.eight_bit_format_text);
            return;
        }

        if (eight_bit_check.active)
            eight_bit_check.set_active (false);
        if (ten_bit_check.active)
            ten_bit_check.set_active (false);
    }

    public void allow_optional_depth_selection () {
        depth_policy = DepthPolicy.OPTIONAL;
        refresh_depth_policy_controls ();
    }

    public void require_depth_selection () {
        depth_policy = DepthPolicy.REQUIRE_ANY;
        refresh_depth_policy_controls ();
    }

    public void lock_to_eight_bit () {
        depth_policy = DepthPolicy.LOCK_8BIT;
        refresh_depth_policy_controls ();
    }

    public void lock_to_ten_bit () {
        depth_policy = DepthPolicy.LOCK_10BIT;
        refresh_depth_policy_controls ();
    }

    private void refresh_depth_policy_controls () {
        bool eight_sensitive = true;
        bool ten_sensitive = true;

        switch (depth_policy) {
        case DepthPolicy.LOCK_8BIT:
            eight_sensitive = false;
            ten_sensitive = false;
            break;
        case DepthPolicy.LOCK_10BIT:
            eight_sensitive = false;
            ten_sensitive = false;
            break;
        case DepthPolicy.REQUIRE_ANY:
            if (eight_bit_check.active && !ten_bit_check.active) {
                eight_sensitive = false;
            } else if (ten_bit_check.active && !eight_bit_check.active) {
                ten_sensitive = false;
            }
            break;
        case DepthPolicy.OPTIONAL:
        default:
            break;
        }

        eight_bit_check.set_sensitive (eight_sensitive);
        ten_bit_check.set_sensitive (ten_sensitive);
        eight_bit_row.set_sensitive (eight_sensitive);
        ten_bit_row.set_sensitive (ten_sensitive);
    }
}

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
    protected PixelFormatSelector pixel_format_selector;

    private uint pixel_format_sync_idle_id = 0;

    public override void dispose () {
        cancel_pending_pixel_format_sync ();
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
        snapshot.pixel_format = snapshot_pixel_format_settings ();
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

    protected void add_pixel_format_group () {
        pixel_format_selector = new PixelFormatSelector ();
        pixel_format_selector.changed.connect (() => {
            queue_pixel_format_sync ();
        });
        append (pixel_format_selector);
    }

    public PixelFormatSettingsSnapshot snapshot_pixel_format_settings () {
        return pixel_format_selector.snapshot_settings ();
    }

    public abstract void sync_pixel_format_now ();

    private void cancel_pending_pixel_format_sync () {
        if (pixel_format_sync_idle_id != 0) {
            Source.remove (pixel_format_sync_idle_id);
            pixel_format_sync_idle_id = 0;
        }
    }

    private void queue_pixel_format_sync () {
        cancel_pending_pixel_format_sync ();
        pixel_format_sync_idle_id = Idle.add (() => {
            pixel_format_sync_idle_id = 0;
            sync_pixel_format_now ();
            return Source.REMOVE;
        });
    }

    protected void set_dropdown_options (DropDown dropdown,
                                         string[] options,
                                         string fallback_option) {
        CodecUtils.set_dropdown_options (dropdown, options, fallback_option);
    }

    protected void reset_pixel_format_selection () {
        pixel_format_selector.apply_snapshot (new PixelFormatSettingsSnapshot ());
    }

    protected void reset_pixel_format_defaults () {
        reset_pixel_format_selection ();
        sync_pixel_format_now ();
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
