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
    private class SmartOptimizerRowsBinding : Object {
        public unowned BaseCodecTab owner;
        public Adw.SwitchRow auto_convert_row;
        public Adw.SwitchRow strip_audio_row;

        public void on_auto_convert_active_notify () {
            owner.handle_auto_convert_active_notify (auto_convert_row, strip_audio_row);
        }

        public void on_match_source_size_active_notify () {
            owner.handle_match_source_size_active_notify ();
        }

        public void on_settings_changed_for_match_source_size () {
            owner.handle_match_source_size_settings_changed ();
        }

        public void on_settings_changed_for_auto_convert () {
            owner.handle_auto_convert_settings_changed (auto_convert_row);
        }

        public void on_strip_audio_active_notify () {
            owner.handle_strip_audio_active_notify (strip_audio_row);
        }

        public void on_settings_changed_for_strip_audio () {
            owner.handle_strip_audio_settings_changed (strip_audio_row);
        }
    }

    // ── Signals ──────────────────────────────────────────────────────────────
    public signal void smart_optimizer_requested ();

    // ── Shared Smart Optimizer State ─────────────────────────────────────────
    public bool auto_convert_active { get; protected set; default = false; }
    public bool strip_audio_active  { get; protected set; default = false; }
    public bool match_source_size_active { get; protected set; default = false; }
    private SmartOptimizerRowsBinding? smart_optimizer_rows_binding = null;

    // ── Shared Widgets (assigned by subclass during construction) ─────────────
    public AudioSettings audio_settings        { get; protected set; }
    public AudioProcessingSettings audio_processing_settings { get; protected set; }
    public DropDown      container_combo       { get; protected set; }
    public Switch        two_pass_switch       { get; protected set; }
    public DropDown      keyint_combo          { get; protected set; }
    public DropDown      custom_keyframe_combo { get; protected set; }
    protected PixelFormatSelector pixel_format_selector;

    // ── Per-Tab Target Size ────────────────────────────────────────────────
    private const string TARGET_ROW_SUBTITLE_MANUAL =
        "Per-tab target — does not change your stored preference";

    private SpinButton target_mb_spin;
    private Adw.ActionRow? target_row = null;
    private Adw.SwitchRow? match_source_size_row = null;
    private Adw.ComboRow? quality_intent_row = null;
    private Adw.ComboRow? content_override_row = null;
    private Adw.SwitchRow? delivery_row = null;

    // Index maps directly onto ContentOverride.
    private const string[] CONTENT_OVERRIDE_LABELS = {
        "Auto-detect",
        "Live-action",
        "Anime / Animation",
        "Screencast / Static"
    };

    // Index 0 is "Off" (size mode); 1..4 map to the quality intents. The two
    // axes are mutually exclusive — whichever the user pins becomes the
    // constraint and the other becomes the prediction.
    private const string[] QUALITY_INTENT_LABELS = {
        "Off — target a size instead",
        "Low — acceptable (VMAF 88)",
        "Medium — good (VMAF 92)",
        "High — visually near-transparent (VMAF 95)",
        "Ultra — archival (VMAF 97)"
    };
    private int last_synced_target_mb;
    private ContainerDefaultMode last_synced_container_default_mode =
        ContainerDefaultMode.DEFAULT;

    // ── Source File Size Status ──────────────────────────────────────────────
    private Image  file_size_icon;
    private Label  file_size_label;
    private string current_file_size_css_class = "source-file-size-none";
    private uint   file_size_generation = 0;
    private int64  source_file_size_bytes = -1;

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
        snapshot.audio_processing = audio_processing_settings.snapshot_settings ();
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
    public int get_target_mb ()                  { return (int) target_mb_spin.get_value (); }

    public bool get_quality_mode_active () {
        return quality_intent_row != null && quality_intent_row.get_selected () > 0;
    }

    public bool get_optimize_for_delivery () {
        return delivery_row != null && delivery_row.get_active ();
    }

    public ContentOverride get_content_override () {
        uint sel = (content_override_row != null)
            ? content_override_row.get_selected () : 0;
        switch (sel) {
            case 1:  return ContentOverride.LIVE_ACTION;
            case 2:  return ContentOverride.ANIME;
            case 3:  return ContentOverride.SCREENCAST;
            default: return ContentOverride.AUTO;
        }
    }

    public SmartOptimizerLogic.QualityIntent get_quality_intent () {
        uint sel = (quality_intent_row != null) ? quality_intent_row.get_selected () : 0;
        switch (sel) {
            case 1:  return SmartOptimizerLogic.QualityIntent.LOW;
            case 2:  return SmartOptimizerLogic.QualityIntent.MEDIUM;
            case 3:  return SmartOptimizerLogic.QualityIntent.HIGH;
            case 4:  return SmartOptimizerLogic.QualityIntent.ULTRA;
            default: return SmartOptimizerLogic.QualityIntent.MEDIUM;
        }
    }

    /**
     * Enforce the mutual exclusion between the two axes: pinning a quality
     * target makes the size controls meaningless, because size becomes the
     * prediction rather than the constraint.
     */
    private void sync_quality_mode_sensitivity () {
        bool quality = get_quality_mode_active ();
        if (target_row != null)
            target_row.set_sensitive (!quality);
        if (target_mb_spin != null)
            target_mb_spin.set_sensitive (!quality && !match_source_size_active);
        if (match_source_size_row != null) {
            match_source_size_row.set_sensitive (
                !quality && !AppSettings.get_default ().smart_optimizer_match_source_size);
        }
        if (target_row != null) {
            if (quality) {
                target_row.set_subtitle (
                    "Ignored — quality is pinned, so size is the prediction");
            } else if (match_source_size_active) {
                // Rebuild from the source file rather than reading back the
                // row's own subtitle, which at this point still holds the
                // "Ignored" text from quality mode.
                apply_match_source_size ();
            } else {
                target_row.set_subtitle (TARGET_ROW_SUBTITLE_MANUAL);
            }
        }
    }
    public int64 get_source_file_size_bytes ()   { return source_file_size_bytes; }

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

    protected void apply_preferred_default_container (string codec_name) {
        string preferred_container =
            AppSettings.get_default ().container_default_mode.resolve_container_for_codec (codec_name);
        CodecUtils.set_dropdown_selection_by_text (
            container_combo,
            preferred_container,
            container_combo.get_selected ()
        );
    }

    protected void bind_container_default_preference (string codec_name) {
        last_synced_container_default_mode = AppSettings.get_default ().container_default_mode;
        AppSettings.get_default ().settings_changed.connect (() => {
            ContainerDefaultMode new_mode = AppSettings.get_default ().container_default_mode;
            if (new_mode == last_synced_container_default_mode) {
                return;
            }

            last_synced_container_default_mode = new_mode;
            apply_preferred_default_container (codec_name);
            audio_settings.update_for_container (get_container ());
        });
    }

    public void set_combine_crossfade_fade_constraint (bool constrained) {
        if (constrained) {
            audio_processing_settings.clear_fades ();
            audio_processing_settings.set_fade_controls_sensitive (false);
        } else {
            audio_processing_settings.set_fade_controls_sensitive (true);
        }
    }

    protected void build_shared_audio_groups () {
        audio_settings = new AudioSettings ();
        append (audio_settings.get_widget ());

        audio_processing_settings = new AudioProcessingSettings (true);
        append (audio_processing_settings.get_widget ());

        audio_settings.changed.connect (() => {
            sync_audio_processing_visibility ();
        });
        audio_processing_settings.changed.connect (() => {
            sync_audio_processing_visibility ();
        });

        sync_audio_processing_visibility ();
    }

    protected void sync_audio_processing_visibility () {
        bool audio_enabled = audio_settings.is_audio_enabled_for_output ();
        bool processing_active = audio_processing_settings.requires_audio_reencode ();
        bool copy_selected = audio_settings.snapshot_settings ().codec == AudioCodecName.COPY;

        audio_settings.update_for_processing (processing_active);
        audio_processing_settings.get_widget ().set_visible (audio_enabled && !copy_selected);
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
        // ── Source file size status (header suffix) ─────────────────────────
        inject_file_size_css ();
        inject_target_mb_css ();
        build_file_size_header (group);

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

        // Quality Target — the second solver. Selecting anything other than
        // "Off" pins a perceptual score and lets size float, which is the
        // mirror image of the size target below. The two are mutually
        // exclusive: whichever the user pins is the constraint, the other is
        // reported as the prediction.
        quality_intent_row = new Adw.ComboRow ();
        quality_intent_row.set_title ("Quality Target");
        quality_intent_row.set_subtitle (
            "Measure this video and solve for the CRF that hits the target");
        quality_intent_row.add_prefix (new Image.from_icon_name ("emblem-ok-symbolic"));
        quality_intent_row.set_model (new StringList (QUALITY_INTENT_LABELS));
        quality_intent_row.set_selected (0);
        quality_intent_row.notify["selected"].connect (() => {
            sync_quality_mode_sensitivity ();
        });
        group.add (quality_intent_row);

        // Content Type — a user assertion, not a quality setting, so it
        // applies in both modes. Auto-detection cannot identify animation
        // (every available signal overlaps slow, flat live-action), which
        // makes this the reliable path rather than a convenience.
        content_override_row = new Adw.ComboRow ();
        content_override_row.set_title ("Content Type");
        content_override_row.set_subtitle (
            "Override detection — animation in particular cannot be detected reliably");
        content_override_row.add_prefix (new Image.from_icon_name ("view-list-symbolic"));
        content_override_row.set_model (new StringList (CONTENT_OVERRIDE_LABELS));
        content_override_row.set_selected (0);
        group.add (content_override_row);

        // Streaming — a delivery constraint, composable with either axis.
        // "Streaming + High" is a coherent request; folding this into the
        // quality list would make it unexpressible.
        delivery_row = new Adw.SwitchRow ();
        delivery_row.set_title ("Optimize for Streaming");
        delivery_row.set_subtitle (
            "Cheaper decode and wider device compatibility, at a small cost in efficiency");
        delivery_row.set_active (false);
        group.add (delivery_row);

        // Target Size — per-tab, volatile spin button.
        // Initializes from the stored preference but is independent of it.
        // Text is blue when the value matches the stored preference.
        target_row = new Adw.ActionRow ();
        target_row.set_title ("Target Size (MB)");
        target_row.set_subtitle (TARGET_ROW_SUBTITLE_MANUAL);
        target_row.add_prefix (new Image.from_icon_name ("drive-harddisk-symbolic"));

        last_synced_target_mb = AppSettings.get_default ().smart_optimizer_target_mb;
        target_mb_spin = new SpinButton.with_range (
            SmartOptimizerLogic.TARGET_MB_MIN, SmartOptimizerLogic.TARGET_MB_MAX, 1);
        target_mb_spin.set_value (last_synced_target_mb);
        target_mb_spin.set_valign (Align.CENTER);
        target_mb_spin.set_width_chars (5);
        target_mb_spin.add_css_class ("target-mb-stored");
        target_row.add_suffix (target_mb_spin);

        target_mb_spin.value_changed.connect (() => {
            sync_target_mb_css ();
        });

        // React to preference changes — if the stored target changed,
        // update the spin box (preferences is the master).  Per-tab
        // overrides are only preserved when the stored value is unchanged.
        AppSettings.get_default ().settings_changed.connect (() => {
            int new_stored = AppSettings.get_default ().smart_optimizer_target_mb;
            if (new_stored != last_synced_target_mb) {
                last_synced_target_mb = new_stored;
                // While matching the source size the box is driven by the file,
                // not the preference — leave it alone.
                if (!match_source_size_active)
                    target_mb_spin.set_value (new_stored);
            }
            sync_target_mb_css ();
        });

        group.add (target_row);

        // Match Source Size — per-tab, session-only.  While active the target
        // box is locked and driven from the source file's own size, rounded to
        // the nearest whole MB.  Forced on and locked when the global override
        // in Preferences is enabled, same as Auto-Convert.
        match_source_size_row = new Adw.SwitchRow ();
        match_source_size_row.set_title ("Match Source Size");
        match_source_size_row.set_subtitle (
            "Re-encode to the source file's own size instead of a fixed target");

        bool match_global_on = AppSettings.get_default ().smart_optimizer_match_source_size;
        match_source_size_row.set_active (match_global_on);
        match_source_size_row.set_sensitive (!match_global_on);
        match_source_size_active = match_global_on;
        apply_match_source_size ();

        group.add (match_source_size_row);

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
        var binding = new SmartOptimizerRowsBinding ();
        binding.owner = this;
        binding.auto_convert_row = auto_convert_row;
        binding.strip_audio_row = strip_audio_row;
        smart_optimizer_rows_binding = binding;
        auto_convert_row.notify["active"].connect (binding.on_auto_convert_active_notify);

        match_source_size_row.notify["active"].connect (
            binding.on_match_source_size_active_notify);
        AppSettings.get_default ().settings_changed.connect (
            binding.on_settings_changed_for_match_source_size);

        // React to global override changes from Preferences.
        AppSettings.get_default ().settings_changed.connect (
            binding.on_settings_changed_for_auto_convert);

        strip_audio_row.notify["active"].connect (binding.on_strip_audio_active_notify);

        AppSettings.get_default ().settings_changed.connect (
            binding.on_settings_changed_for_strip_audio);
        group.add (strip_audio_row);

        // Reflect the initial (size-mode) state onto the controls.
        sync_quality_mode_sensitivity ();
    }

    internal void handle_auto_convert_active_notify (Adw.SwitchRow auto_convert_row,
                                                     Adw.SwitchRow strip_audio_row) {
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
    }

    internal void handle_auto_convert_settings_changed (Adw.SwitchRow auto_convert_row) {
        bool locked = AppSettings.get_default ().smart_optimizer_auto_convert;
        if (locked) {
            auto_convert_row.set_active (true);
            auto_convert_row.set_sensitive (false);
        } else if (!auto_convert_row.get_sensitive ()) {
            auto_convert_row.set_sensitive (true);
            auto_convert_row.set_active (false);
        }
    }

    internal void handle_match_source_size_active_notify () {
        if (match_source_size_row == null) return;
        match_source_size_active = match_source_size_row.get_active ();
        apply_match_source_size ();
    }

    internal void handle_match_source_size_settings_changed () {
        if (match_source_size_row == null) return;
        bool locked = AppSettings.get_default ().smart_optimizer_match_source_size;
        if (locked) {
            match_source_size_row.set_active (true);
            match_source_size_row.set_sensitive (false);
        } else if (!match_source_size_row.get_sensitive ()) {
            match_source_size_row.set_sensitive (true);
            match_source_size_row.set_active (false);
        }
    }

    /**
     * Reflect the current Match Source Size state onto the target size box.
     *
     * While matching, the box is locked and holds the source file's size
     * rounded to the nearest whole MB (the optimizer only accepts integer
     * targets).  Turning it off returns the box to manual control with the
     * matched value still in place, so it can be adjusted from there.
     */
    private void apply_match_source_size () {
        if (target_mb_spin == null || target_row == null) return;

        target_mb_spin.set_sensitive (
            !match_source_size_active && !get_quality_mode_active ());

        if (!match_source_size_active) {
            target_row.set_subtitle (TARGET_ROW_SUBTITLE_MANUAL);
            sync_target_mb_css ();
            return;
        }

        if (source_file_size_bytes <= 0) {
            // Nothing to match — hold the stored default rather than leaving a
            // locked box showing the size of a file that is no longer loaded.
            target_mb_spin.set_value (AppSettings.get_default ().smart_optimizer_target_mb);
            target_row.set_subtitle ("Matching source size — no file selected yet");
            sync_target_mb_css ();
            return;
        }

        int matched = SmartOptimizerLogic.match_source_target_mb (source_file_size_bytes);
        target_mb_spin.set_value (matched);
        target_row.set_subtitle (
            "Matching source size — %d MB, rounded from %s".printf (
                matched, CodecUtils.format_file_size (source_file_size_bytes)));
        sync_target_mb_css ();
    }

    internal void handle_strip_audio_active_notify (Adw.SwitchRow strip_audio_row) {
        strip_audio_active = strip_audio_row.get_active ();
    }

    internal void handle_strip_audio_settings_changed (Adw.SwitchRow strip_audio_row) {
        bool locked = AppSettings.get_default ().smart_optimizer_strip_audio;
        if (!strip_audio_row.get_visible ())
            return;
        if (locked) {
            strip_audio_row.set_active (true);
            strip_audio_row.set_sensitive (false);
        } else if (!strip_audio_row.get_sensitive ()) {
            strip_audio_row.set_sensitive (true);
            strip_audio_row.set_active (false);
        }
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

    // ═════════════════════════════════════════════════════════════════════════
    //  SOURCE FILE SIZE STATUS
    //
    //  Displays the input file's size in the Quality Profile group header,
    //  giving quick visibility when using Smart Optimizer without switching
    //  to the Information tab.
    // ═════════════════════════════════════════════════════════════════════════

    // ── Target MB CSS ─────────────────────────────────────────────────────

    private static bool target_mb_css_injected = false;

    private static void inject_target_mb_css () {
        if (target_mb_css_injected) return;
        target_mb_css_injected = true;

        var css = new CssProvider ();
        css.load_from_string (
            "spinbutton.target-mb-stored text {\n" +
            "    color: @accent_color;\n" +
            "}\n"
        );
        GtkCompat.add_provider_for_display (
            Gdk.Display.get_default (),
            css,
            STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }

    private void sync_target_mb_css () {
        int current = (int) target_mb_spin.get_value ();
        int stored  = AppSettings.get_default ().smart_optimizer_target_mb;
        if (current == stored) {
            if (!target_mb_spin.has_css_class ("target-mb-stored"))
                target_mb_spin.add_css_class ("target-mb-stored");
        } else {
            target_mb_spin.remove_css_class ("target-mb-stored");
        }
    }

    /**
     * Reset the per-tab target size to the stored preference value.
     * Called by each codec tab's reset_defaults().
     */
    protected void reset_target_mb () {
        // Clearing the toggle re-enables the box via its notify handler; when
        // the global override holds it on, re-apply the matched value instead.
        if (match_source_size_row != null
            && !AppSettings.get_default ().smart_optimizer_match_source_size) {
            match_source_size_row.set_active (false);
        }

        last_synced_target_mb = AppSettings.get_default ().smart_optimizer_target_mb;
        if (match_source_size_active) {
            apply_match_source_size ();
        } else {
            target_mb_spin.set_value (last_synced_target_mb);
        }
    }

    private static bool file_size_css_injected = false;

    private static void inject_file_size_css () {
        if (file_size_css_injected) return;
        file_size_css_injected = true;

        var css = new CssProvider ();
        css.load_from_string (
            ".source-file-size {\n" +
            "    color: @success_color;\n" +
            "    font-size: 0.85em;\n" +
            "}\n" +
            ".source-file-size-none {\n" +
            "    color: @window_fg_color;\n" +
            "    font-size: 0.85em;\n" +
            "    opacity: 0.55;\n" +
            "}\n"
        );
        GtkCompat.add_provider_for_display (
            Gdk.Display.get_default (),
            css,
            STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }

    private void build_file_size_header (Adw.PreferencesGroup group) {
        var header = new Box (Orientation.HORIZONTAL, 6);
        header.set_halign (Align.END);
        header.set_valign (Align.CENTER);

        file_size_icon = new Image.from_icon_name ("drive-harddisk-symbolic");
        file_size_icon.set_valign (Align.CENTER);
        file_size_icon.add_css_class ("source-file-size-none");
        header.append (file_size_icon);

        file_size_label = new Label ("No file selected");
        file_size_label.set_xalign (0.0f);
        file_size_label.set_halign (Align.END);
        file_size_label.set_wrap (false);
        file_size_label.set_ellipsize (Pango.EllipsizeMode.END);
        file_size_label.add_css_class ("source-file-size-none");
        header.append (file_size_label);

        group.set_header_suffix (header);
    }

    /**
     * Update the source file size display.
     *
     * Called by AppController when the input file changes.
     * Queries the file size asynchronously and updates the icon/label
     * with a formatted value or a placeholder when no file is selected.
     * Generation tracking discards stale results from superseded queries.
     */
    public void update_source_file_size (string file_path) {
        file_size_generation++;

        if (file_path.strip ().length == 0) {
            source_file_size_bytes = -1;
            apply_file_size_display ("No file selected", "source-file-size-none");
            apply_match_source_size ();
            return;
        }

        uint my_generation = file_size_generation;
        query_file_size_async.begin (file_path, my_generation);
    }

    private async void query_file_size_async (string file_path, uint generation) {
        try {
            var f = GLib.File.new_for_path (file_path);
            var fi = yield f.query_info_async (
                "standard::size", GLib.FileQueryInfoFlags.NONE,
                Priority.DEFAULT, null);

            if (generation != file_size_generation) return;

            int64 bytes = fi.get_size ();
            source_file_size_bytes = bytes;
            string formatted = "Source: %s".printf (
                CodecUtils.format_file_size (bytes));
            apply_file_size_display (formatted, "source-file-size");
            apply_match_source_size ();
        } catch (Error e) {
            if (generation != file_size_generation) return;
            source_file_size_bytes = -1;
            apply_file_size_display ("File unavailable", "source-file-size-none");
            apply_match_source_size ();
        }
    }

    private void apply_file_size_display (string text, string css_class) {
        file_size_label.set_text (text);

        if (current_file_size_css_class == css_class) return;

        if (current_file_size_css_class.length > 0) {
            file_size_icon.remove_css_class (current_file_size_css_class);
            file_size_label.remove_css_class (current_file_size_css_class);
        }
        file_size_icon.add_css_class (css_class);
        file_size_label.add_css_class (css_class);
        current_file_size_css_class = css_class;
    }
}
