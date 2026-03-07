using Gtk;
using Adw;
using GLib;

public class X265Tab : Box, ICodecTab {

    // ── Signals ───────────────────────────────────────────────────────────────
    public signal void smart_optimizer_requested ();

    // ── Auto-convert (per-tab, session-only) ─────────────────────────────────
    public bool auto_convert_active { get; private set; default = false; }

    // ── Strip audio (per-tab, session-only) ──────────────────────────────────
    public bool strip_audio_active { get; private set; default = false; }

    // ── Preset ───────────────────────────────────────────────────────────────
    public DropDown  quality_profile_combo    { get; private set; }

    // ── Encoding ─────────────────────────────────────────────────────────────
    public DropDown  container_combo    { get; private set; }
    public DropDown  preset_combo       { get; private set; }
    public DropDown  profile_combo      { get; private set; }

    // ── Cross-tab reference (wired in MainWindow) ────────────────────────────
    private GeneralTab? _general_tab = null;
    public GeneralTab? general_tab {
        get { return _general_tab; }
        set {
            _general_tab = value;
            if (_general_tab != null) {
                _general_tab.eight_bit_check.notify["active"].connect (apply_profile_format_requirements);
                _general_tab.ten_bit_check.notify["active"].connect (apply_profile_format_requirements);
                _general_tab.eight_bit_format.notify["selected"].connect (apply_profile_format_requirements);
                _general_tab.ten_bit_format.notify["selected"].connect (apply_profile_format_requirements);
            }
        }
    }

    // ── Rate Control ─────────────────────────────────────────────────────────
    public DropDown   rc_mode_combo     { get; private set; }
    public SpinButton crf_spin          { get; private set; }
    public SpinButton qp_spin           { get; private set; }
    public SpinButton abr_bitrate_spin  { get; private set; }
    public Switch     abr_vbv_switch    { get; private set; }
    public SpinButton cbr_bitrate_spin  { get; private set; }
    public Switch     two_pass_switch    { get; private set; }
    private Adw.ActionRow crf_row;
    private Adw.ActionRow qp_row;
    private Adw.ActionRow abr_row;
    private Adw.ActionRow abr_vbv_row;
    private Adw.ActionRow cbr_row;
    private Adw.ActionRow two_pass_row;

    // ── Quality & Tuning ─────────────────────────────────────────────────────
    public DropDown   tune_combo        { get; private set; }
    public DropDown   level_combo       { get; private set; }
    public DropDown   aq_mode_combo     { get; private set; }
    public SpinButton aq_strength_spin  { get; private set; }

    private Adw.ActionRow aq_strength_row;

    // ── Lookahead ────────────────────────────────────────────────────────────
    public Adw.ExpanderRow lookahead_expander { get; private set; }
    public SpinButton lookahead_spin    { get; private set; }

    // ── Advanced ─────────────────────────────────────────────────────────────
    public Switch     sao_switch        { get; private set; }
    public DropDown   ref_frames_combo  { get; private set; }
    public Switch     weightp_switch    { get; private set; }
    public Switch     pmode_switch      { get; private set; }
    public Adw.ExpanderRow psy_rd_expander { get; private set; }
    public SpinButton psy_rd_spin     { get; private set; }
    public Switch     cutree_switch     { get; private set; }

    // Deblock
    public Adw.ExpanderRow deblock_expander { get; private set; }
    public SpinButton deblock_alpha_spin { get; private set; }
    public SpinButton deblock_beta_spin  { get; private set; }

    // ── Audio ────────────────────────────────────────────────────────────────
    public AudioSettings audio_settings  { get; private set; }

    // ── Threading & Keyframes ────────────────────────────────────────────────
    public DropDown  keyint_combo        { get; private set; }
    public DropDown  custom_keyframe_combo { get; private set; }
    public DropDown  threads_combo       { get; private set; }
    public DropDown  frame_threads_combo { get; private set; }

    private Adw.ActionRow custom_keyframe_row;

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public X265Tab () {
        Object (orientation: Orientation.VERTICAL, spacing: 24);
        set_margin_top (24);
        set_margin_bottom (24);
        set_margin_start (24);
        set_margin_end (24);

        build_quality_profile_group ();
        build_encoding_group ();
        build_rate_control_group ();
        build_quality_group ();
        build_advanced_group ();
        build_audio_group ();
        build_threading_group ();
        build_reset_button ();

        connect_signals ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  QUALITY PROFILE
    // ═════════════════════════════════════════════════════════════════════════

    private void build_quality_profile_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Quality Profile");
        group.set_description ("One-click configurations — settings can be adjusted individually after");

        var row = new Adw.ActionRow ();
        row.set_title ("Quality Profile");
        row.set_subtitle ("Configures all settings below — you can still adjust individually");
        quality_profile_combo = new DropDown (new StringList ({
            "Custom", "Streaming", "Anime", "Low", "Medium", "High", "Very High"
        }), null);
        quality_profile_combo.set_valign (Align.CENTER);
        quality_profile_combo.set_selected (0);
        row.add_suffix (quality_profile_combo);
        group.add (row);

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

        var strip_audio_row = new Adw.SwitchRow ();
        strip_audio_row.set_title ("No Audio");
        strip_audio_row.set_subtitle ("Strip audio from analysis and output");
        strip_audio_row.set_visible (auto_convert_active);

        bool audio_global = AppSettings.get_default ().smart_optimizer_strip_audio;
        strip_audio_row.set_active (audio_global && auto_convert_active);
        strip_audio_row.set_sensitive (!audio_global);
        strip_audio_active = audio_global && auto_convert_active;

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

        append (group);
    }

    /**
     * Build a tinted prefix icon for the Smart Optimizer row.
     */
    private static Image make_smart_icon () {
        var img = new Image.from_icon_name ("starred-symbolic");
        img.set_pixel_size (24);
        img.set_valign (Align.CENTER);
        img.add_css_class ("accent");
        return img;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ENCODING
    // ═════════════════════════════════════════════════════════════════════════

    private void build_encoding_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Encoding");
        group.set_description ("Core x265 encoder settings");

        // Container
        var container_row = new Adw.ActionRow ();
        container_row.set_title ("Container");
        container_row.set_subtitle ("MKV supports more features, MP4 is more compatible");
        container_combo = new DropDown (new StringList ({ "mkv", "mp4" }), null);
        container_combo.set_valign (Align.CENTER);
        container_combo.set_selected (0);
        container_row.add_suffix (container_combo);
        group.add (container_row);

        // Preset
        var preset_row = new Adw.ActionRow ();
        preset_row.set_title ("Preset");
        preset_row.set_subtitle ("Slower = better quality at the same bitrate");
        preset_combo = new DropDown (new StringList ({
            "ultrafast", "superfast", "veryfast", "faster", "fast",
            "medium", "slow", "slower", "veryslow", "placebo"
        }), null);
        preset_combo.set_valign (Align.CENTER);
        preset_combo.set_selected (5);
        preset_row.add_suffix (preset_combo);
        group.add (preset_row);

        // Profile (#8)
        var profile_row = new Adw.ActionRow ();
        profile_row.set_title ("Profile");
        profile_row.set_subtitle ("Higher profiles support more features — Auto selects based on input");
        profile_combo = new DropDown (new StringList ({
            "Auto", "Main", "Main10", "Main12"
        }), null);
        profile_combo.set_valign (Align.CENTER);
        profile_combo.set_selected (0);
        profile_row.add_suffix (profile_combo);
        group.add (profile_row);

        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  RATE CONTROL
    // ═════════════════════════════════════════════════════════════════════════

    private void build_rate_control_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Rate Control");

        // Mode selector
        var mode_row = new Adw.ActionRow ();
        mode_row.set_title ("Mode");
        mode_row.set_subtitle ("CRF is recommended for general use");
        rc_mode_combo = new DropDown (new StringList (
            { "CRF", "QP", "ABR", "CBR" }
        ), null);
        rc_mode_combo.set_valign (Align.CENTER);
        rc_mode_combo.set_selected (0);
        mode_row.add_suffix (rc_mode_combo);
        group.add (mode_row);

        // CRF value
        crf_row = new Adw.ActionRow ();
        crf_row.set_title ("CRF Value");
        crf_row.set_subtitle ("Lower = better quality (0–51, encoder default 28)");
        crf_spin = new SpinButton.with_range (0, 51, 1);
        crf_spin.set_value (28);
        crf_spin.set_valign (Align.CENTER);
        crf_row.add_suffix (crf_spin);
        group.add (crf_row);

        // QP value
        qp_row = new Adw.ActionRow ();
        qp_row.set_title ("QP Value");
        qp_row.set_subtitle ("Fixed quantization parameter (0–51, default 28)");
        qp_spin = new SpinButton.with_range (0, 51, 1);
        qp_spin.set_value (28);
        qp_spin.set_valign (Align.CENTER);
        qp_row.add_suffix (qp_spin);
        qp_row.set_visible (false);
        group.add (qp_row);

        // ABR bitrate
        abr_row = new Adw.ActionRow ();
        abr_row.set_title ("Average Bitrate");
        abr_row.set_subtitle ("Target average bitrate in kbps (100–10000)");
        abr_bitrate_spin = new SpinButton.with_range (100, 10000, 100);
        abr_bitrate_spin.set_value (1000);
        abr_bitrate_spin.set_valign (Align.CENTER);
        abr_row.add_suffix (abr_bitrate_spin);
        abr_row.set_visible (false);
        group.add (abr_row);

        // ABR VBV constraint
        abr_vbv_row = new Adw.ActionRow ();
        abr_vbv_row.set_title ("Enable VBV");
        abr_vbv_row.set_subtitle ("Constrains bitrate fluctuations for ABR");
        abr_vbv_switch = new Switch ();
        abr_vbv_switch.set_valign (Align.CENTER);
        abr_vbv_switch.set_active (false);
        abr_vbv_row.add_suffix (abr_vbv_switch);
        abr_vbv_row.set_activatable_widget (abr_vbv_switch);
        abr_vbv_row.set_visible (false);
        group.add (abr_vbv_row);

        // CBR bitrate
        cbr_row = new Adw.ActionRow ();
        cbr_row.set_title ("Constant Bitrate");
        cbr_row.set_subtitle ("Fixed bitrate in kbps (100–10000)");
        cbr_bitrate_spin = new SpinButton.with_range (100, 10000, 100);
        cbr_bitrate_spin.set_value (1000);
        cbr_bitrate_spin.set_valign (Align.CENTER);
        cbr_row.add_suffix (cbr_bitrate_spin);
        cbr_row.set_visible (false);
        group.add (cbr_row);

        // Two-pass (#2: simplified — no hidden CheckButton)
        two_pass_row = new Adw.ActionRow ();
        two_pass_row.set_title ("Two-Pass Encoding");
        two_pass_row.set_subtitle ("Better quality — available for ABR and CBR modes");

        two_pass_switch = new Switch ();
        two_pass_switch.set_valign (Align.CENTER);
        two_pass_switch.set_active (false);
        two_pass_row.add_suffix (two_pass_switch);
        two_pass_row.set_activatable_widget (two_pass_switch);
        two_pass_row.set_visible (false);

        group.add (two_pass_row);
        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  QUALITY & TUNING
    // ═════════════════════════════════════════════════════════════════════════

    private void build_quality_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Quality & Tuning");

        // Tune
        var tune_row = new Adw.ActionRow ();
        tune_row.set_title ("Tune");
        tune_row.set_subtitle ("Optimize for specific content types");
        tune_combo = new DropDown (new StringList ({
            "Auto", "psnr", "ssim", "grain", "zerolatency", "fastdecode", "animation"
        }), null);
        tune_combo.set_valign (Align.CENTER);
        tune_combo.set_selected (0);
        tune_row.add_suffix (tune_combo);
        group.add (tune_row);

        // Level
        var level_row = new Adw.ActionRow ();
        level_row.set_title ("Level");
        level_row.set_subtitle ("Constrains resolution and bitrate for compatibility");
        level_combo = new DropDown (new StringList ({
            "Auto", "1", "2", "2.1", "3", "3.1", "4", "4.1",
            "5", "5.1", "5.2", "6", "6.1", "6.2"
        }), null);
        level_combo.set_valign (Align.CENTER);
        level_combo.set_selected (0);
        level_row.add_suffix (level_combo);
        group.add (level_row);

        // Lookahead (ExpanderRow)
        lookahead_expander = new Adw.ExpanderRow ();
        lookahead_expander.set_title ("Lookahead");
        lookahead_expander.set_subtitle ("More frames = better quality, slower encode (0–250)");
        lookahead_expander.set_show_enable_switch (true);
        lookahead_expander.set_enable_expansion (false);

        var la_row = new Adw.ActionRow ();
        la_row.set_title ("Frames");
        lookahead_spin = new SpinButton.with_range (0, 250, 5);
        lookahead_spin.set_value (40);
        lookahead_spin.set_valign (Align.CENTER);
        la_row.add_suffix (lookahead_spin);
        lookahead_expander.add_row (la_row);
        group.add (lookahead_expander);

        // AQ Mode
        var aq_row = new Adw.ActionRow ();
        aq_row.set_title ("AQ Mode");
        aq_row.set_subtitle ("Adaptive Quantization distributes bits across the frame");
        aq_mode_combo = new DropDown (new StringList ({
            "Automatic", "Disabled", "Variance", "Auto-Variance", "Auto-Variance Biased",
            "Auto-Variance + Edge"
        }), null);
        aq_mode_combo.set_valign (Align.CENTER);
        aq_mode_combo.set_selected (0);
        aq_row.add_suffix (aq_mode_combo);
        group.add (aq_row);

        // AQ Strength
        aq_strength_row = new Adw.ActionRow ();
        aq_strength_row.set_title ("AQ Strength");
        aq_strength_row.set_subtitle ("Higher = more adaptive (0.0–3.0, default 1.0)");
        aq_strength_spin = new SpinButton.with_range (0.0, 3.0, 0.1);
        aq_strength_spin.set_digits (1);
        aq_strength_spin.set_value (1.0);
        aq_strength_spin.set_valign (Align.CENTER);
        aq_strength_row.add_suffix (aq_strength_spin);
        aq_strength_row.set_sensitive (false);
        group.add (aq_strength_row);

        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ADVANCED
    // ═════════════════════════════════════════════════════════════════════════

    private void build_advanced_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Advanced");

        // SAO Filtering
        var sao_row = new Adw.ActionRow ();
        sao_row.set_title ("SAO Filtering");
        sao_row.set_subtitle ("Sample Adaptive Offset — reduces banding and artifacts");
        sao_switch = new Switch ();
        sao_switch.set_valign (Align.CENTER);
        sao_switch.set_active (true);
        sao_row.add_suffix (sao_switch);
        sao_row.set_activatable_widget (sao_switch);
        group.add (sao_row);

        // Ref Frames
        var ref_row = new Adw.ActionRow ();
        ref_row.set_title ("Reference Frames");
        ref_row.set_subtitle ("More = better compression, slower encoding");
        ref_frames_combo = new DropDown (new StringList (
            { "1", "2", "3", "4", "5" }
        ), null);
        ref_frames_combo.set_valign (Align.CENTER);
        ref_frames_combo.set_selected (2);
        ref_row.add_suffix (ref_frames_combo);
        group.add (ref_row);

        // Weighted Prediction
        var wp_row = new Adw.ActionRow ();
        wp_row.set_title ("Weighted Prediction");
        wp_row.set_subtitle ("Improves P-frame efficiency — typically ~10% gain");
        weightp_switch = new Switch ();
        weightp_switch.set_valign (Align.CENTER);
        weightp_switch.set_active (true);
        wp_row.add_suffix (weightp_switch);
        wp_row.set_activatable_widget (weightp_switch);
        group.add (wp_row);

        // Deblock Filter (ExpanderRow with alpha/beta)
        deblock_expander = new Adw.ExpanderRow ();
        deblock_expander.set_title ("Deblock Filter");
        deblock_expander.set_subtitle ("Reduce blockiness — negative values preserve detail");
        deblock_expander.set_show_enable_switch (true);
        deblock_expander.set_enable_expansion (true);

        var alpha_row = new Adw.ActionRow ();
        alpha_row.set_title ("tC Offset");
        alpha_row.set_subtitle ("Transform coefficient boundary strength (−6 to +6, default 0)");
        deblock_alpha_spin = new SpinButton.with_range (-6, 6, 1);
        deblock_alpha_spin.set_value (0);
        deblock_alpha_spin.set_valign (Align.CENTER);
        alpha_row.add_suffix (deblock_alpha_spin);
        deblock_expander.add_row (alpha_row);

        var beta_row = new Adw.ActionRow ();
        beta_row.set_title ("Beta Offset");
        beta_row.set_subtitle ("Boundary detection threshold (−6 to +6, default 0)");
        deblock_beta_spin = new SpinButton.with_range (-6, 6, 1);
        deblock_beta_spin.set_value (0);
        deblock_beta_spin.set_valign (Align.CENTER);
        beta_row.add_suffix (deblock_beta_spin);
        deblock_expander.add_row (beta_row);
        group.add (deblock_expander);

        // PMode
        var pmode_row = new Adw.ActionRow ();
        pmode_row.set_title ("PMode");
        pmode_row.set_subtitle ("Parallel motion estimation — speeds up multi-core CPUs");
        pmode_switch = new Switch ();
        pmode_switch.set_valign (Align.CENTER);
        pmode_switch.set_active (false);
        pmode_row.add_suffix (pmode_switch);
        pmode_row.set_activatable_widget (pmode_switch);
        group.add (pmode_row);

        // Psy-RD (ExpanderRow with value)
        psy_rd_expander = new Adw.ExpanderRow ();
        psy_rd_expander.set_title ("Psy-RD");
        psy_rd_expander.set_subtitle ("Psychovisual optimization for better subjective quality");
        psy_rd_expander.set_show_enable_switch (true);
        psy_rd_expander.set_enable_expansion (true);

        var psy_rd_row = new Adw.ActionRow ();
        psy_rd_row.set_title ("Strength");
        psy_rd_spin = new SpinButton.with_range (0.0, 5.0, 0.1);
        psy_rd_spin.set_digits (1);
        psy_rd_spin.set_value (2.0);
        psy_rd_spin.set_valign (Align.CENTER);
        psy_rd_row.add_suffix (psy_rd_spin);
        psy_rd_expander.add_row (psy_rd_row);
        group.add (psy_rd_expander);

        // Cutree
        var cutree_row = new Adw.ActionRow ();
        cutree_row.set_title ("Cutree");
        cutree_row.set_subtitle ("Complexity-based rate control for better bit allocation (enabled by default)");
        cutree_switch = new Switch ();
        cutree_switch.set_valign (Align.CENTER);
        cutree_switch.set_active (true);
        cutree_row.add_suffix (cutree_switch);
        cutree_row.set_activatable_widget (cutree_switch);
        group.add (cutree_row);

        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  AUDIO
    // ═════════════════════════════════════════════════════════════════════════

    private void build_audio_group () {
        audio_settings = new AudioSettings ();
        append (audio_settings.get_widget ());
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  THREADING & KEYFRAMES
    // ═════════════════════════════════════════════════════════════════════════

    private void build_threading_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Threading & Keyframes");

        // Keyframe Interval
        var keyint_row = new Adw.ActionRow ();
        keyint_row.set_title ("Keyframe Interval");
        keyint_row.set_subtitle ("Higher = smaller file, slower seeking");
        keyint_combo = new DropDown (new StringList ({
            "Auto", "Custom", "15", "30", "60", "120", "240", "360", "480", "720", "960", "1440", "1920"
        }), null);
        keyint_combo.set_valign (Align.CENTER);
        keyint_combo.set_selected (0);
        keyint_row.add_suffix (keyint_combo);
        group.add (keyint_row);

        // Custom Keyframe Mode (visible only when "Custom" selected)
        custom_keyframe_row = new Adw.ActionRow ();
        custom_keyframe_row.set_title ("Custom Mode");
        custom_keyframe_row.set_subtitle ("Choose how the keyframe interval is calculated");
        custom_keyframe_combo = new DropDown (new StringList ({
            "Every 2 seconds — fixed time",
            "Every 2 seconds × framerate",
            "Every 5 seconds — fixed time",
            "Every 5 seconds × framerate"
        }), null);
        custom_keyframe_combo.set_valign (Align.CENTER);
        custom_keyframe_combo.set_selected (3);
        custom_keyframe_row.add_suffix (custom_keyframe_combo);
        custom_keyframe_row.set_visible (false);
        group.add (custom_keyframe_row);

        // Threads
        var threads_row = new Adw.ActionRow ();
        threads_row.set_title ("Threads");
        threads_row.set_subtitle ("CPU threads — Auto detects your system");
        threads_combo = new DropDown (new StringList ({
            "Auto", "1", "2", "4", "8", "12", "16"
        }), null);
        threads_combo.set_valign (Align.CENTER);
        threads_combo.set_selected (0);
        threads_row.add_suffix (threads_combo);
        group.add (threads_row);

        // Frame Threads
        var ft_row = new Adw.ActionRow ();
        ft_row.set_title ("Frame Threads");
        ft_row.set_subtitle ("Parallel frame encoding — Auto is usually best");
        frame_threads_combo = new DropDown (new StringList ({
            "Auto", "1", "2", "3", "4"
        }), null);
        frame_threads_combo.set_valign (Align.CENTER);
        frame_threads_combo.set_selected (0);
        ft_row.add_suffix (frame_threads_combo);
        group.add (ft_row);

        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  RESET BUTTON
    // ═════════════════════════════════════════════════════════════════════════

    private void build_reset_button () {
        var reset_box = new Box (Orientation.HORIZONTAL, 0);
        reset_box.set_halign (Align.END);
        reset_box.set_margin_top (12);

        var reset_btn = new Button.with_label ("Reset to Defaults");
        reset_btn.add_css_class ("destructive-action");
        reset_btn.clicked.connect (() => {
            quality_profile_combo.set_selected (0);   // Custom
            reset_defaults ();
        });
        reset_box.append (reset_btn);

        append (reset_box);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SIGNALS
    // ═════════════════════════════════════════════════════════════════════════

    private void connect_signals () {
        // Preset → apply preset configuration
        quality_profile_combo.notify["selected"].connect (() => {
            var item = quality_profile_combo.selected_item as StringObject;
            if (item != null)
                CodecPresets.apply_x265 (this, item.string);
        });

        // Rate control mode → show/hide rows
        rc_mode_combo.notify["selected"].connect (update_rc_visibility);
        update_rc_visibility ();

        // Profile → auto-configure General tab pixel format for compatibility
        profile_combo.notify["selected"].connect (apply_profile_format_requirements);

        // AQ Mode → enable/disable strength
        aq_mode_combo.notify["selected"].connect (() => {
            string mode = get_dropdown_text (aq_mode_combo);
            aq_strength_row.set_sensitive (mode != "Automatic" && mode != "Disabled");
        });

        // Container → update audio codec list
        container_combo.notify["selected"].connect (() => {
            audio_settings.update_for_container (get_container ());
        });

        // Custom keyframe mode visibility
        keyint_combo.notify["selected"].connect (() => {
            string ki = get_dropdown_text (keyint_combo);
            custom_keyframe_row.set_visible (ki == "Custom");
        });
    }

    private void update_rc_visibility () {
        string mode = get_dropdown_text (rc_mode_combo);
        crf_row.set_visible (mode == "CRF");
        qp_row.set_visible (mode == "QP");
        abr_row.set_visible (mode == "ABR");
        abr_vbv_row.set_visible (mode == "ABR");
        cbr_row.set_visible (mode == "CBR");
        // Two-pass only available for ABR and CBR
        bool can_two_pass = (mode == "ABR" || mode == "CBR");
        two_pass_row.set_visible (can_two_pass);
        if (!can_two_pass) {
            two_pass_switch.set_active (false);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PROFILE → PIXEL FORMAT AUTO-CONFIGURATION
    //
    //  x265 profile constraints:
    //    Main           → 8-bit only, 4:2:0 only
    //    Main10         → 8 or 10-bit, 4:2:0 only
    //    Main12         → 8 or 10-bit, 4:2:0 only
    // ═════════════════════════════════════════════════════════════════════════

    private bool _applying_profile = false;

    private void apply_profile_format_requirements () {
        if (_general_tab == null || _applying_profile) return;

        string profile = get_dropdown_text (profile_combo);

        if (profile == "Auto") return;

        _applying_profile = true;

        bool has_8bit  = _general_tab.eight_bit_check.active;
        bool has_10bit = _general_tab.ten_bit_check.active;

        if (profile == "Main") {
            // 8-bit only, 4:2:0 only
            if (has_10bit) _general_tab.ten_bit_check.set_active (false);
            if (!has_8bit) _general_tab.eight_bit_check.set_active (true);
            _general_tab.eight_bit_format.set_selected (0);  // 4:2:0
        }
        else if (profile == "Main10" || profile == "Main12") {
            // 8 or 10-bit, 4:2:0 only
            if (has_8bit)  _general_tab.eight_bit_format.set_selected (0);   // 4:2:0
            if (has_10bit) _general_tab.ten_bit_format.set_selected (0);     // 4:2:0
        }

        _applying_profile = false;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  HELPERS (#1: delegated to CodecUtils)
    // ═════════════════════════════════════════════════════════════════════════

    public string get_dropdown_text (DropDown dropdown) {
        return CodecUtils.get_dropdown_text (dropdown);
    }

    public string get_container () {
        return CodecUtils.get_dropdown_text (container_combo);
    }

    public string get_active_preset () {
        return CodecUtils.get_dropdown_text (preset_combo);
    }

    public ICodecBuilder get_codec_builder () {
        return new X265Builder (this);
    }

    // (#2) Read the Switch directly — no hidden CheckButton needed
    public bool get_two_pass () {
        return two_pass_switch.active;
    }

    // get_container() already exists above

    // resolve_keyframe_args() below

    public string[] get_audio_args () {
        return audio_settings.get_audio_args ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SMART OPTIMIZER
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Apply a SmartOptimizer recommendation to this tab's widgets.
     * Called by AppController after the async analysis completes.
     */
    public void apply_smart_recommendation (OptimizationRecommendation rec) {
        CodecPresets.apply_smart_x265 (this, rec);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  RESET
    // ═════════════════════════════════════════════════════════════════════════

    public void reset_defaults () {
        // Encoding
        container_combo.set_selected (0);
        preset_combo.set_selected (5);
        profile_combo.set_selected (0);

        // Rate Control
        rc_mode_combo.set_selected (0);
        crf_spin.set_value (28);
        qp_spin.set_value (28);
        abr_bitrate_spin.set_value (1000);
        abr_vbv_switch.set_active (false);
        cbr_bitrate_spin.set_value (1000);
        two_pass_switch.set_active (false);

        // Quality & Tuning
        tune_combo.set_selected (0);
        level_combo.set_selected (0);
        lookahead_expander.set_enable_expansion (false);
        lookahead_spin.set_value (40);
        aq_mode_combo.set_selected (0);
        aq_strength_spin.set_value (1.0);

        // Advanced
        sao_switch.set_active (true);
        ref_frames_combo.set_selected (2);
        weightp_switch.set_active (true);
        deblock_expander.set_enable_expansion (true);
        deblock_alpha_spin.set_value (0);
        deblock_beta_spin.set_value (0);
        pmode_switch.set_active (false);
        psy_rd_expander.set_enable_expansion (true);
        psy_rd_spin.set_value (2.0);
        cutree_switch.set_active (true);

        // Audio
        audio_settings.reset_defaults ();

        // Threading & Keyframes
        keyint_combo.set_selected (0);
        custom_keyframe_combo.set_selected (3);
        threads_combo.set_selected (0);
        frame_threads_combo.set_selected (0);

        update_rc_visibility ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CUSTOM KEYFRAME RESOLUTION
    // ═════════════════════════════════════════════════════════════════════════

    // (#1) Delegate to shared implementation in CodecUtils
    public string[] resolve_keyframe_args (string input_file, GeneralTab general_tab) {
        return CodecUtils.resolve_custom_keyframe_args (
            keyint_combo, custom_keyframe_combo, input_file, general_tab);
    }

}
