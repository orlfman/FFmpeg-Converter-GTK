using Gtk;
using Adw;

public class ColorCorrectionDialog : Adw.Window {

    // ── Basic ────────────────────────────────────────────────────────────────
    private CheckButton brightness_enable;
    private Scale       brightness_scale;
    private SpinButton  brightness_spin;

    private CheckButton contrast_enable;
    private Scale       contrast_scale;
    private SpinButton  contrast_spin;

    private CheckButton saturation_enable;
    private Scale       saturation_scale;
    private SpinButton  saturation_spin;

    private CheckButton gamma_enable;
    private Scale       gamma_scale;
    private SpinButton  gamma_spin;

    private CheckButton hue_enable;
    private Scale       hue_scale;
    private SpinButton  hue_spin;

    private CheckButton exposure_enable;
    private Scale       exposure_scale;
    private SpinButton  exposure_spin;

    // ── RGB Channels ─────────────────────────────────────────────────────────
    private CheckButton red_gamma_enable;
    private Scale       red_gamma_scale;
    private SpinButton  red_gamma_spin;

    private CheckButton green_gamma_enable;
    private Scale       green_gamma_scale;
    private SpinButton  green_gamma_spin;

    private CheckButton blue_gamma_enable;
    private Scale       blue_gamma_scale;
    private SpinButton  blue_gamma_spin;

    // ── Levels ───────────────────────────────────────────────────────────────
    private CheckButton levels_enable;
    private SpinButton  levels_rimin;
    private SpinButton  levels_gimin;
    private SpinButton  levels_bimin;
    private SpinButton  levels_rimax;
    private SpinButton  levels_gimax;
    private SpinButton  levels_bimax;
    private SpinButton  levels_romin;
    private SpinButton  levels_gomin;
    private SpinButton  levels_bomin;
    private SpinButton  levels_romax;
    private SpinButton  levels_gomax;
    private SpinButton  levels_bomax;

    // ── Color Balance ────────────────────────────────────────────────────────
    private CheckButton colorbal_enable;
    private Scale       shadows_r_scale;
    private SpinButton  shadows_r_spin;
    private Scale       shadows_g_scale;
    private SpinButton  shadows_g_spin;
    private Scale       shadows_b_scale;
    private SpinButton  shadows_b_spin;
    private Scale       midtones_r_scale;
    private SpinButton  midtones_r_spin;
    private Scale       midtones_g_scale;
    private SpinButton  midtones_g_spin;
    private Scale       midtones_b_scale;
    private SpinButton  midtones_b_spin;
    private Scale       highlights_r_scale;
    private SpinButton  highlights_r_spin;
    private Scale       highlights_g_scale;
    private SpinButton  highlights_g_spin;
    private Scale       highlights_b_scale;
    private SpinButton  highlights_b_spin;

    // ── Advanced ─────────────────────────────────────────────────────────────
    private CheckButton vibrance_enable;
    private Scale       vibrance_scale;
    private SpinButton  vibrance_spin;

    private CheckButton temperature_enable;
    private Scale       temperature_scale;
    private SpinButton  temperature_spin;

    private CheckButton curves_enable;
    private DropDown    curves_drop;

    private CheckButton vignette_enable;
    private Scale       vignette_scale;
    private SpinButton  vignette_spin;

    public ColorCorrectionDialog (Gtk.Window parent) {
        Object ();
        set_transient_for (parent);
        set_modal (true);
        set_title ("🎨 Color Correction");
        set_default_size (780, 720);

        var toolbar_view = new Adw.ToolbarView ();
        var header = new Adw.HeaderBar ();
        toolbar_view.add_top_bar (header);

        var main_box = new Box (Orientation.VERTICAL, 0);

        var scroll = new ScrolledWindow ();
        scroll.set_policy (PolicyType.NEVER, PolicyType.AUTOMATIC);
        scroll.set_vexpand (true);

        var content = new Box (Orientation.VERTICAL, 20);
        content.set_margin_top (20);
        content.set_margin_bottom (20);
        content.set_margin_start (24);
        content.set_margin_end (24);

        build_basic_group (content);
        build_rgb_channels_group (content);
        build_levels_group (content);
        build_color_balance_group (content);
        build_advanced_group (content);

        scroll.set_child (content);
        main_box.append (scroll);

        // ── Buttons ──────────────────────────────────────────────────────────
        var btn_box = new Box (Orientation.HORIZONTAL, 12);
        btn_box.set_margin_top (12);
        btn_box.set_margin_bottom (16);
        btn_box.set_margin_start (24);
        btn_box.set_margin_end (24);

        var reset_btn  = new Button.with_label ("Reset All");
        reset_btn.add_css_class ("destructive-action");

        var spacer = new Box (Orientation.HORIZONTAL, 0);
        spacer.set_hexpand (true);

        var cancel_btn = new Button.with_label ("Cancel");
        var ok_btn     = new Button.with_label ("OK");
        ok_btn.add_css_class ("suggested-action");

        btn_box.append (reset_btn);
        btn_box.append (spacer);
        btn_box.append (cancel_btn);
        btn_box.append (ok_btn);
        main_box.append (btn_box);

        reset_btn.clicked.connect (reset_to_defaults);
        ok_btn.clicked.connect (hide);
        cancel_btn.clicked.connect (hide);

        toolbar_view.set_content (main_box);
        set_content (toolbar_view);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  BASIC CORRECTION
    // ═════════════════════════════════════════════════════════════════════════

    private void build_basic_group (Box content) {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Basic Correction");
        group.set_description ("Fundamental image adjustments");

        brightness_enable = new CheckButton.with_label ("Brightness");
        brightness_scale  = new Scale.with_range (Orientation.HORIZONTAL, -1.0, 1.0, 0.01);
        brightness_spin   = new SpinButton.with_range (-1.0, 1.0, 0.01);
        brightness_spin.set_digits (2);
        brightness_spin.set_value (0.0);
        brightness_scale.set_value (0.0);
        group.add (make_row (brightness_enable, brightness_scale, brightness_spin));
        wire_row (brightness_enable, brightness_scale, brightness_spin);

        contrast_enable = new CheckButton.with_label ("Contrast");
        contrast_scale  = new Scale.with_range (Orientation.HORIZONTAL, 0.0, 3.0, 0.01);
        contrast_spin   = new SpinButton.with_range (0.0, 3.0, 0.01);
        contrast_spin.set_digits (2);
        contrast_spin.set_value (1.0);
        contrast_scale.set_value (1.0);
        group.add (make_row (contrast_enable, contrast_scale, contrast_spin));
        wire_row (contrast_enable, contrast_scale, contrast_spin);

        saturation_enable = new CheckButton.with_label ("Saturation");
        saturation_scale  = new Scale.with_range (Orientation.HORIZONTAL, 0.0, 3.0, 0.01);
        saturation_spin   = new SpinButton.with_range (0.0, 3.0, 0.01);
        saturation_spin.set_digits (2);
        saturation_spin.set_value (1.0);
        saturation_scale.set_value (1.0);
        group.add (make_row (saturation_enable, saturation_scale, saturation_spin));
        wire_row (saturation_enable, saturation_scale, saturation_spin);

        gamma_enable = new CheckButton.with_label ("Gamma");
        gamma_scale  = new Scale.with_range (Orientation.HORIZONTAL, 0.1, 3.0, 0.01);
        gamma_spin   = new SpinButton.with_range (0.1, 3.0, 0.01);
        gamma_spin.set_digits (2);
        gamma_spin.set_value (1.0);
        gamma_scale.set_value (1.0);
        group.add (make_row (gamma_enable, gamma_scale, gamma_spin));
        wire_row (gamma_enable, gamma_scale, gamma_spin);

        hue_enable = new CheckButton.with_label ("Hue");
        hue_scale  = new Scale.with_range (Orientation.HORIZONTAL, -180.0, 180.0, 1.0);
        hue_spin   = new SpinButton.with_range (-180.0, 180.0, 1.0);
        hue_spin.set_digits (1);
        hue_spin.set_value (0.0);
        hue_scale.set_value (0.0);
        group.add (make_row (hue_enable, hue_scale, hue_spin));
        wire_row (hue_enable, hue_scale, hue_spin);

        exposure_enable = new CheckButton.with_label ("Exposure");
        exposure_scale  = new Scale.with_range (Orientation.HORIZONTAL, -3.0, 3.0, 0.1);
        exposure_spin   = new SpinButton.with_range (-3.0, 3.0, 0.1);
        exposure_spin.set_digits (1);
        exposure_spin.set_value (0.0);
        exposure_scale.set_value (0.0);
        group.add (make_row (exposure_enable, exposure_scale, exposure_spin));
        wire_row (exposure_enable, exposure_scale, exposure_spin);

        content.append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  RGB CHANNELS
    // ═════════════════════════════════════════════════════════════════════════

    private void build_rgb_channels_group (Box content) {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("RGB Channels");
        group.set_description ("Per-channel gamma adjustment — shift color balance via individual channels");

        red_gamma_enable = new CheckButton.with_label ("Red Gamma");
        red_gamma_scale  = new Scale.with_range (Orientation.HORIZONTAL, 0.1, 3.0, 0.01);
        red_gamma_spin   = new SpinButton.with_range (0.1, 3.0, 0.01);
        red_gamma_spin.set_digits (2);
        red_gamma_spin.set_value (1.0);
        red_gamma_scale.set_value (1.0);
        group.add (make_row (red_gamma_enable, red_gamma_scale, red_gamma_spin));
        wire_row (red_gamma_enable, red_gamma_scale, red_gamma_spin);

        green_gamma_enable = new CheckButton.with_label ("Green Gamma");
        green_gamma_scale  = new Scale.with_range (Orientation.HORIZONTAL, 0.1, 3.0, 0.01);
        green_gamma_spin   = new SpinButton.with_range (0.1, 3.0, 0.01);
        green_gamma_spin.set_digits (2);
        green_gamma_spin.set_value (1.0);
        green_gamma_scale.set_value (1.0);
        group.add (make_row (green_gamma_enable, green_gamma_scale, green_gamma_spin));
        wire_row (green_gamma_enable, green_gamma_scale, green_gamma_spin);

        blue_gamma_enable = new CheckButton.with_label ("Blue Gamma");
        blue_gamma_scale  = new Scale.with_range (Orientation.HORIZONTAL, 0.1, 3.0, 0.01);
        blue_gamma_spin   = new SpinButton.with_range (0.1, 3.0, 0.01);
        blue_gamma_spin.set_digits (2);
        blue_gamma_spin.set_value (1.0);
        blue_gamma_scale.set_value (1.0);
        group.add (make_row (blue_gamma_enable, blue_gamma_scale, blue_gamma_spin));
        wire_row (blue_gamma_enable, blue_gamma_scale, blue_gamma_spin);

        content.append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  LEVELS
    // ═════════════════════════════════════════════════════════════════════════

    private void build_levels_group (Box content) {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Levels");
        group.set_description ("Set input/output black and white points per channel (0.0 – 1.0)");

        // Enable toggle
        levels_enable = new CheckButton.with_label ("Enable Levels");
        var enable_row = new Adw.ActionRow ();
        enable_row.set_child (levels_enable);
        group.add (enable_row);

        // Input Levels
        var in_label = new Adw.PreferencesGroup ();
        in_label.set_title ("Input Range");

        levels_rimin = make_level_spin (0.0);
        levels_rimax = make_level_spin (1.0);
        in_label.add (make_level_row ("Red", levels_rimin, levels_rimax));

        levels_gimin = make_level_spin (0.0);
        levels_gimax = make_level_spin (1.0);
        in_label.add (make_level_row ("Green", levels_gimin, levels_gimax));

        levels_bimin = make_level_spin (0.0);
        levels_bimax = make_level_spin (1.0);
        in_label.add (make_level_row ("Blue", levels_bimin, levels_bimax));

        content.append (group);
        content.append (in_label);

        // Output Levels
        var out_label = new Adw.PreferencesGroup ();
        out_label.set_title ("Output Range");

        levels_romin = make_level_spin (0.0);
        levels_romax = make_level_spin (1.0);
        out_label.add (make_level_row ("Red", levels_romin, levels_romax));

        levels_gomin = make_level_spin (0.0);
        levels_gomax = make_level_spin (1.0);
        out_label.add (make_level_row ("Green", levels_gomin, levels_gomax));

        levels_bomin = make_level_spin (0.0);
        levels_bomax = make_level_spin (1.0);
        out_label.add (make_level_row ("Blue", levels_bomin, levels_bomax));

        content.append (out_label);

        // Wire enable for all level spins
        SpinButton[] all_levels = {
            levels_rimin, levels_rimax, levels_gimin, levels_gimax, levels_bimin, levels_bimax,
            levels_romin, levels_romax, levels_gomin, levels_gomax, levels_bomin, levels_bomax
        };
        foreach (var s in all_levels) s.set_sensitive (false);
        levels_enable.toggled.connect (() => {
            foreach (var s in all_levels) s.set_sensitive (levels_enable.active);
        });
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  COLOR BALANCE
    // ═════════════════════════════════════════════════════════════════════════

    private void build_color_balance_group (Box content) {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Color Balance");
        group.set_description ("Adjust RGB balance in shadows, midtones, and highlights");

        colorbal_enable = new CheckButton.with_label ("Enable Color Balance");
        var enable_row = new Adw.ActionRow ();
        enable_row.set_child (colorbal_enable);
        group.add (enable_row);

        content.append (group);

        // Shadows
        var shadows_group = new Adw.PreferencesGroup ();
        shadows_group.set_title ("Shadows");

        shadows_r_scale = new Scale.with_range (Orientation.HORIZONTAL, -1.0, 1.0, 0.01);
        shadows_r_spin  = new SpinButton.with_range (-1.0, 1.0, 0.01);
        shadows_r_spin.set_digits (2); shadows_r_spin.set_value (0.0); shadows_r_scale.set_value (0.0);
        shadows_group.add (make_balance_row ("Red", shadows_r_scale, shadows_r_spin));

        shadows_g_scale = new Scale.with_range (Orientation.HORIZONTAL, -1.0, 1.0, 0.01);
        shadows_g_spin  = new SpinButton.with_range (-1.0, 1.0, 0.01);
        shadows_g_spin.set_digits (2); shadows_g_spin.set_value (0.0); shadows_g_scale.set_value (0.0);
        shadows_group.add (make_balance_row ("Green", shadows_g_scale, shadows_g_spin));

        shadows_b_scale = new Scale.with_range (Orientation.HORIZONTAL, -1.0, 1.0, 0.01);
        shadows_b_spin  = new SpinButton.with_range (-1.0, 1.0, 0.01);
        shadows_b_spin.set_digits (2); shadows_b_spin.set_value (0.0); shadows_b_scale.set_value (0.0);
        shadows_group.add (make_balance_row ("Blue", shadows_b_scale, shadows_b_spin));

        content.append (shadows_group);

        // Midtones
        var mid_group = new Adw.PreferencesGroup ();
        mid_group.set_title ("Midtones");

        midtones_r_scale = new Scale.with_range (Orientation.HORIZONTAL, -1.0, 1.0, 0.01);
        midtones_r_spin  = new SpinButton.with_range (-1.0, 1.0, 0.01);
        midtones_r_spin.set_digits (2); midtones_r_spin.set_value (0.0); midtones_r_scale.set_value (0.0);
        mid_group.add (make_balance_row ("Red", midtones_r_scale, midtones_r_spin));

        midtones_g_scale = new Scale.with_range (Orientation.HORIZONTAL, -1.0, 1.0, 0.01);
        midtones_g_spin  = new SpinButton.with_range (-1.0, 1.0, 0.01);
        midtones_g_spin.set_digits (2); midtones_g_spin.set_value (0.0); midtones_g_scale.set_value (0.0);
        mid_group.add (make_balance_row ("Green", midtones_g_scale, midtones_g_spin));

        midtones_b_scale = new Scale.with_range (Orientation.HORIZONTAL, -1.0, 1.0, 0.01);
        midtones_b_spin  = new SpinButton.with_range (-1.0, 1.0, 0.01);
        midtones_b_spin.set_digits (2); midtones_b_spin.set_value (0.0); midtones_b_scale.set_value (0.0);
        mid_group.add (make_balance_row ("Blue", midtones_b_scale, midtones_b_spin));

        content.append (mid_group);

        // Highlights
        var hi_group = new Adw.PreferencesGroup ();
        hi_group.set_title ("Highlights");

        highlights_r_scale = new Scale.with_range (Orientation.HORIZONTAL, -1.0, 1.0, 0.01);
        highlights_r_spin  = new SpinButton.with_range (-1.0, 1.0, 0.01);
        highlights_r_spin.set_digits (2); highlights_r_spin.set_value (0.0); highlights_r_scale.set_value (0.0);
        hi_group.add (make_balance_row ("Red", highlights_r_scale, highlights_r_spin));

        highlights_g_scale = new Scale.with_range (Orientation.HORIZONTAL, -1.0, 1.0, 0.01);
        highlights_g_spin  = new SpinButton.with_range (-1.0, 1.0, 0.01);
        highlights_g_spin.set_digits (2); highlights_g_spin.set_value (0.0); highlights_g_scale.set_value (0.0);
        hi_group.add (make_balance_row ("Green", highlights_g_scale, highlights_g_spin));

        highlights_b_scale = new Scale.with_range (Orientation.HORIZONTAL, -1.0, 1.0, 0.01);
        highlights_b_spin  = new SpinButton.with_range (-1.0, 1.0, 0.01);
        highlights_b_spin.set_digits (2); highlights_b_spin.set_value (0.0); highlights_b_scale.set_value (0.0);
        hi_group.add (make_balance_row ("Blue", highlights_b_scale, highlights_b_spin));

        content.append (hi_group);

        // Wire enable for all color balance controls
        Scale[] bal_scales = {
            shadows_r_scale, shadows_g_scale, shadows_b_scale,
            midtones_r_scale, midtones_g_scale, midtones_b_scale,
            highlights_r_scale, highlights_g_scale, highlights_b_scale
        };
        SpinButton[] bal_spins = {
            shadows_r_spin, shadows_g_spin, shadows_b_spin,
            midtones_r_spin, midtones_g_spin, midtones_b_spin,
            highlights_r_spin, highlights_g_spin, highlights_b_spin
        };
        foreach (var s in bal_scales) s.set_sensitive (false);
        foreach (var s in bal_spins)  s.set_sensitive (false);
        colorbal_enable.toggled.connect (() => {
            foreach (var s in bal_scales) s.set_sensitive (colorbal_enable.active);
            foreach (var s in bal_spins)  s.set_sensitive (colorbal_enable.active);
        });

        // Wire scale ↔ spin sync
        wire_scale_spin (shadows_r_scale, shadows_r_spin);
        wire_scale_spin (shadows_g_scale, shadows_g_spin);
        wire_scale_spin (shadows_b_scale, shadows_b_spin);
        wire_scale_spin (midtones_r_scale, midtones_r_spin);
        wire_scale_spin (midtones_g_scale, midtones_g_spin);
        wire_scale_spin (midtones_b_scale, midtones_b_spin);
        wire_scale_spin (highlights_r_scale, highlights_r_spin);
        wire_scale_spin (highlights_g_scale, highlights_g_spin);
        wire_scale_spin (highlights_b_scale, highlights_b_spin);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ADVANCED
    // ═════════════════════════════════════════════════════════════════════════

    private void build_advanced_group (Box content) {
        var adv_group = new Adw.PreferencesGroup ();
        adv_group.set_title ("Advanced");

        vibrance_enable = new CheckButton.with_label ("Vibrance");
        vibrance_scale  = new Scale.with_range (Orientation.HORIZONTAL, -2.0, 2.0, 0.01);
        vibrance_spin   = new SpinButton.with_range (-2.0, 2.0, 0.01);
        vibrance_spin.set_digits (2);
        vibrance_spin.set_value (0.0);
        vibrance_scale.set_value (0.0);
        adv_group.add (make_row (vibrance_enable, vibrance_scale, vibrance_spin));
        wire_row (vibrance_enable, vibrance_scale, vibrance_spin);

        temperature_enable = new CheckButton.with_label ("Color Temp (K)");
        temperature_scale  = new Scale.with_range (Orientation.HORIZONTAL, 2500.0, 8500.0, 100.0);
        temperature_spin   = new SpinButton.with_range (2500.0, 8500.0, 100.0);
        temperature_spin.set_digits (0);
        temperature_spin.set_value (5500.0);
        temperature_scale.set_value (5500.0);
        adv_group.add (make_row (temperature_enable, temperature_scale, temperature_spin));
        wire_row (temperature_enable, temperature_scale, temperature_spin);

        // Curves — special row with a DropDown
        curves_enable = new CheckButton.with_label ("Curves Preset");
        string[] curve_items = {
            "None", "Cross Process", "Vintage", "Darker", "Lighter",
            "Linear Contrast", "Medium Contrast", "Strong Contrast",
            "Increase Contrast", "Negative"
        };
        curves_drop = new DropDown (new StringList (curve_items), null);
        curves_drop.set_selected (0);
        curves_drop.set_hexpand (true);
        curves_drop.set_sensitive (false);
        curves_enable.toggled.connect (() => curves_drop.set_sensitive (curves_enable.active));

        curves_enable.set_size_request (160, -1);
        var curves_box = new Box (Orientation.HORIZONTAL, 12);
        curves_box.append (curves_enable);
        curves_box.append (curves_drop);
        var curves_action_row = new Adw.ActionRow ();
        curves_action_row.set_child (curves_box);
        adv_group.add (curves_action_row);

        // Vignette
        vignette_enable = new CheckButton.with_label ("Vignette");
        vignette_scale  = new Scale.with_range (Orientation.HORIZONTAL, 0.0, 1.0, 0.01);
        vignette_spin   = new SpinButton.with_range (0.0, 1.0, 0.01);
        vignette_spin.set_digits (2);
        vignette_spin.set_value (0.3);
        vignette_scale.set_value (0.3);
        adv_group.add (make_row (vignette_enable, vignette_scale, vignette_spin));
        wire_row (vignette_enable, vignette_scale, vignette_spin);

        content.append (adv_group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  HELPERS — Row builders
    // ═════════════════════════════════════════════════════════════════════════

    private Adw.ActionRow make_row (CheckButton check, Scale scale, SpinButton spin) {
        check.set_size_request (160, -1);
        scale.set_hexpand (true);
        scale.set_draw_value (false);
        spin.set_size_request (90, -1);

        var box = new Box (Orientation.HORIZONTAL, 12);
        box.append (check);
        box.append (scale);
        box.append (spin);

        var row = new Adw.ActionRow ();
        row.set_child (box);
        return row;
    }

    private Adw.ActionRow make_balance_row (string label, Scale scale, SpinButton spin) {
        var lbl = new Label (label);
        lbl.set_size_request (80, -1);
        lbl.set_xalign (0);

        scale.set_hexpand (true);
        scale.set_draw_value (false);
        spin.set_size_request (90, -1);

        var box = new Box (Orientation.HORIZONTAL, 12);
        box.append (lbl);
        box.append (scale);
        box.append (spin);

        var row = new Adw.ActionRow ();
        row.set_child (box);
        return row;
    }

    private SpinButton make_level_spin (double initial) {
        var spin = new SpinButton.with_range (0.0, 1.0, 0.01);
        spin.set_digits (2);
        spin.set_value (initial);
        spin.set_size_request (90, -1);
        return spin;
    }

    private Adw.ActionRow make_level_row (string channel, SpinButton min_spin, SpinButton max_spin) {
        var lbl = new Label (channel);
        lbl.set_size_request (80, -1);
        lbl.set_xalign (0);

        var min_lbl = new Label ("Min");
        var max_lbl = new Label ("Max");

        var box = new Box (Orientation.HORIZONTAL, 12);
        box.append (lbl);
        box.append (min_lbl);
        box.append (min_spin);
        box.append (max_lbl);
        box.append (max_spin);

        var row = new Adw.ActionRow ();
        row.set_child (box);
        return row;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  HELPERS — Wiring
    // ═════════════════════════════════════════════════════════════════════════

    private void wire_row (CheckButton check, Scale scale, SpinButton spin) {
        scale.set_sensitive (false);
        spin.set_sensitive (false);

        check.toggled.connect (() => {
            scale.set_sensitive (check.active);
            spin.set_sensitive (check.active);
        });

        wire_scale_spin (scale, spin);
    }

    private void wire_scale_spin (Scale scale, SpinButton spin) {
        bool updating = false;
        scale.value_changed.connect (() => {
            if (updating) return;
            updating = true;
            spin.set_value (scale.get_value ());
            updating = false;
        });
        spin.value_changed.connect (() => {
            if (updating) return;
            updating = true;
            scale.set_value (spin.get_value ());
            updating = false;
        });
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  RESET
    // ═════════════════════════════════════════════════════════════════════════

    private void reset_to_defaults () {
        // Basic
        brightness_enable.set_active (false);
        contrast_enable.set_active (false);
        saturation_enable.set_active (false);
        gamma_enable.set_active (false);
        hue_enable.set_active (false);
        exposure_enable.set_active (false);

        brightness_spin.set_value (0.0);
        contrast_spin.set_value (1.0);
        saturation_spin.set_value (1.0);
        gamma_spin.set_value (1.0);
        hue_spin.set_value (0.0);
        exposure_spin.set_value (0.0);

        // RGB Channels
        red_gamma_enable.set_active (false);
        green_gamma_enable.set_active (false);
        blue_gamma_enable.set_active (false);

        red_gamma_spin.set_value (1.0);
        green_gamma_spin.set_value (1.0);
        blue_gamma_spin.set_value (1.0);

        // Levels
        levels_enable.set_active (false);
        levels_rimin.set_value (0.0); levels_rimax.set_value (1.0);
        levels_gimin.set_value (0.0); levels_gimax.set_value (1.0);
        levels_bimin.set_value (0.0); levels_bimax.set_value (1.0);
        levels_romin.set_value (0.0); levels_romax.set_value (1.0);
        levels_gomin.set_value (0.0); levels_gomax.set_value (1.0);
        levels_bomin.set_value (0.0); levels_bomax.set_value (1.0);

        // Color Balance
        colorbal_enable.set_active (false);
        shadows_r_spin.set_value (0.0); shadows_g_spin.set_value (0.0); shadows_b_spin.set_value (0.0);
        midtones_r_spin.set_value (0.0); midtones_g_spin.set_value (0.0); midtones_b_spin.set_value (0.0);
        highlights_r_spin.set_value (0.0); highlights_g_spin.set_value (0.0); highlights_b_spin.set_value (0.0);

        // Advanced
        vibrance_enable.set_active (false);
        temperature_enable.set_active (false);
        curves_enable.set_active (false);
        vignette_enable.set_active (false);

        vibrance_spin.set_value (0.0);
        temperature_spin.set_value (5500.0);
        curves_drop.set_selected (0);
        vignette_spin.set_value (0.3);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  FFMPEG FILTER OUTPUT
    // ═════════════════════════════════════════════════════════════════════════

    public string get_filter_string () {
        string[] filters = {};

        // ── eq= filter (brightness, contrast, saturation, gamma, RGB gamma) ─
        string[] eq_parts = {};

        if (brightness_enable.active)
            eq_parts += "brightness=%.2f".printf (brightness_spin.get_value ());
        if (contrast_enable.active)
            eq_parts += "contrast=%.2f".printf (contrast_spin.get_value ());
        if (saturation_enable.active)
            eq_parts += "saturation=%.2f".printf (saturation_spin.get_value ());
        if (gamma_enable.active)
            eq_parts += "gamma=%.2f".printf (gamma_spin.get_value ());

        // Per-channel gamma (part of the eq filter)
        if (red_gamma_enable.active)
            eq_parts += "gamma_r=%.2f".printf (red_gamma_spin.get_value ());
        if (green_gamma_enable.active)
            eq_parts += "gamma_g=%.2f".printf (green_gamma_spin.get_value ());
        if (blue_gamma_enable.active)
            eq_parts += "gamma_b=%.2f".printf (blue_gamma_spin.get_value ());

        if (eq_parts.length > 0)
            filters += "eq=" + string.joinv (":", eq_parts);

        // ── Hue ──────────────────────────────────────────────────────────────
        if (hue_enable.active && hue_spin.get_value () != 0.0)
            filters += "hue=h=%.1f".printf (hue_spin.get_value ());

        // ── Exposure ─────────────────────────────────────────────────────────
        if (exposure_enable.active && exposure_spin.get_value () != 0.0)
            filters += "exposure=exposure=%.1f".printf (exposure_spin.get_value ());

        // ── Color Levels ─────────────────────────────────────────────────────
        if (levels_enable.active) {
            string[] lp = {};
            // Only emit parameters that differ from defaults
            if (levels_rimin.get_value () != 0.0) lp += "rimin=%.2f".printf (levels_rimin.get_value ());
            if (levels_rimax.get_value () != 1.0) lp += "rimax=%.2f".printf (levels_rimax.get_value ());
            if (levels_gimin.get_value () != 0.0) lp += "gimin=%.2f".printf (levels_gimin.get_value ());
            if (levels_gimax.get_value () != 1.0) lp += "gimax=%.2f".printf (levels_gimax.get_value ());
            if (levels_bimin.get_value () != 0.0) lp += "bimin=%.2f".printf (levels_bimin.get_value ());
            if (levels_bimax.get_value () != 1.0) lp += "bimax=%.2f".printf (levels_bimax.get_value ());
            if (levels_romin.get_value () != 0.0) lp += "romin=%.2f".printf (levels_romin.get_value ());
            if (levels_romax.get_value () != 1.0) lp += "romax=%.2f".printf (levels_romax.get_value ());
            if (levels_gomin.get_value () != 0.0) lp += "gomin=%.2f".printf (levels_gomin.get_value ());
            if (levels_gomax.get_value () != 1.0) lp += "gomax=%.2f".printf (levels_gomax.get_value ());
            if (levels_bomin.get_value () != 0.0) lp += "bomin=%.2f".printf (levels_bomin.get_value ());
            if (levels_bomax.get_value () != 1.0) lp += "bomax=%.2f".printf (levels_bomax.get_value ());
            if (lp.length > 0)
                filters += "colorlevels=" + string.joinv (":", lp);
        }

        // ── Color Balance ────────────────────────────────────────────────────
        if (colorbal_enable.active) {
            string[] bp = {};
            if (shadows_r_spin.get_value () != 0.0) bp += "rs=%.2f".printf (shadows_r_spin.get_value ());
            if (shadows_g_spin.get_value () != 0.0) bp += "gs=%.2f".printf (shadows_g_spin.get_value ());
            if (shadows_b_spin.get_value () != 0.0) bp += "bs=%.2f".printf (shadows_b_spin.get_value ());
            if (midtones_r_spin.get_value () != 0.0) bp += "rm=%.2f".printf (midtones_r_spin.get_value ());
            if (midtones_g_spin.get_value () != 0.0) bp += "gm=%.2f".printf (midtones_g_spin.get_value ());
            if (midtones_b_spin.get_value () != 0.0) bp += "bm=%.2f".printf (midtones_b_spin.get_value ());
            if (highlights_r_spin.get_value () != 0.0) bp += "rh=%.2f".printf (highlights_r_spin.get_value ());
            if (highlights_g_spin.get_value () != 0.0) bp += "gh=%.2f".printf (highlights_g_spin.get_value ());
            if (highlights_b_spin.get_value () != 0.0) bp += "bh=%.2f".printf (highlights_b_spin.get_value ());
            if (bp.length > 0)
                filters += "colorbalance=" + string.joinv (":", bp);
        }

        // ── Vibrance ─────────────────────────────────────────────────────────
        if (vibrance_enable.active && vibrance_spin.get_value () != 0.0)
            filters += "vibrance=intensity=%.2f".printf (vibrance_spin.get_value ());

        // ── Color Temperature ────────────────────────────────────────────────
        if (temperature_enable.active && (int) temperature_spin.get_value () != 5500)
            filters += "colortemperature=temperature=%d".printf ((int) temperature_spin.get_value ());

        // ── Curves Preset ────────────────────────────────────────────────────
        if (curves_enable.active) {
            var item = curves_drop.selected_item as StringObject;
            string curve = item != null ? item.string : "None";
            string preset = curve_name_to_preset (curve);
            if (preset != "")
                filters += "curves=preset=" + preset;
        }

        // ── Vignette ─────────────────────────────────────────────────────────
        if (vignette_enable.active)
            filters += "vignette=angle=%.2f".printf (vignette_spin.get_value ());

        return string.joinv (",", filters);
    }

    private string curve_name_to_preset (string name) {
        switch (name) {
            case "Cross Process":     return "cross_process";
            case "Vintage":           return "vintage";
            case "Darker":            return "darker";
            case "Lighter":           return "lighter";
            case "Linear Contrast":   return "linear_contrast";
            case "Medium Contrast":   return "medium_contrast";
            case "Strong Contrast":   return "strong_contrast";
            case "Increase Contrast": return "increase_contrast";
            case "Negative":          return "negative";
            default:                  return "";
        }
    }
}
