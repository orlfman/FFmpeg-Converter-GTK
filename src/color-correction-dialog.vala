using Gtk;
using Adw;

public class ColorCorrectionDialog : Adw.Window {

    // Basic
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

    // Advanced
    private CheckButton vibrance_enable;
    private Scale       vibrance_scale;
    private SpinButton  vibrance_spin;

    private CheckButton temperature_enable;
    private Scale       temperature_scale;
    private SpinButton  temperature_spin;

    private CheckButton curves_enable;
    private DropDown    curves_drop;

    public ColorCorrectionDialog (Gtk.Window parent) {
        Object ();
        set_transient_for (parent);
        set_modal (true);
        set_title ("🎨 Color Correction");
        set_default_size (740, 620);

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

        // ── Basic Group ──────────────────────────────────────────────────────
        var basic_group = new Adw.PreferencesGroup ();
        basic_group.set_title ("Basic Correction");

        brightness_enable = new CheckButton.with_label ("Brightness");
        brightness_scale  = new Scale.with_range (Orientation.HORIZONTAL, -1.0, 1.0, 0.01);
        brightness_spin   = new SpinButton.with_range (-1.0, 1.0, 0.01);
        brightness_spin.set_digits (2);
        brightness_spin.set_value (0.0);
        brightness_scale.set_value (0.0);
        basic_group.add (make_row (brightness_enable, brightness_scale, brightness_spin));
        wire_row (brightness_enable, brightness_scale, brightness_spin);

        contrast_enable = new CheckButton.with_label ("Contrast");
        contrast_scale  = new Scale.with_range (Orientation.HORIZONTAL, 0.0, 3.0, 0.01);
        contrast_spin   = new SpinButton.with_range (0.0, 3.0, 0.01);
        contrast_spin.set_digits (2);
        contrast_spin.set_value (1.0);
        contrast_scale.set_value (1.0);
        basic_group.add (make_row (contrast_enable, contrast_scale, contrast_spin));
        wire_row (contrast_enable, contrast_scale, contrast_spin);

        saturation_enable = new CheckButton.with_label ("Saturation");
        saturation_scale  = new Scale.with_range (Orientation.HORIZONTAL, 0.0, 3.0, 0.01);
        saturation_spin   = new SpinButton.with_range (0.0, 3.0, 0.01);
        saturation_spin.set_digits (2);
        saturation_spin.set_value (1.0);
        saturation_scale.set_value (1.0);
        basic_group.add (make_row (saturation_enable, saturation_scale, saturation_spin));
        wire_row (saturation_enable, saturation_scale, saturation_spin);

        gamma_enable = new CheckButton.with_label ("Gamma");
        gamma_scale  = new Scale.with_range (Orientation.HORIZONTAL, 0.1, 3.0, 0.01);
        gamma_spin   = new SpinButton.with_range (0.1, 3.0, 0.01);
        gamma_spin.set_digits (2);
        gamma_spin.set_value (1.0);
        gamma_scale.set_value (1.0);
        basic_group.add (make_row (gamma_enable, gamma_scale, gamma_spin));
        wire_row (gamma_enable, gamma_scale, gamma_spin);

        hue_enable = new CheckButton.with_label ("Hue");
        hue_scale  = new Scale.with_range (Orientation.HORIZONTAL, -180.0, 180.0, 1.0);
        hue_spin   = new SpinButton.with_range (-180.0, 180.0, 1.0);
        hue_spin.set_digits (1);
        hue_spin.set_value (0.0);
        hue_scale.set_value (0.0);
        basic_group.add (make_row (hue_enable, hue_scale, hue_spin));
        wire_row (hue_enable, hue_scale, hue_spin);

        content.append (basic_group);

        // ── Advanced Group ───────────────────────────────────────────────────
        var adv_group = new Adw.PreferencesGroup ();
        adv_group.set_title ("Advanced");

        vibrance_enable = new CheckButton.with_label ("Vibrance");
        vibrance_scale  = new Scale.with_range (Orientation.HORIZONTAL, 0.0, 2.0, 0.01);
        vibrance_spin   = new SpinButton.with_range (0.0, 2.0, 0.01);
        vibrance_spin.set_digits (2);
        vibrance_spin.set_value (1.0);
        vibrance_scale.set_value (1.0);
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

        // Curves — special row with a DropDown instead of a scale
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

        content.append (adv_group);
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

    // ── Helpers ──────────────────────────────────────────────────────────────

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

    private void wire_row (CheckButton check, Scale scale, SpinButton spin) {
        scale.set_sensitive (false);
        spin.set_sensitive (false);

        check.toggled.connect (() => {
            scale.set_sensitive (check.active);
            spin.set_sensitive (check.active);
        });

        // Keep scale and spin in sync without looping forever
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

    private void reset_to_defaults () {
        brightness_enable.set_active (false);
        contrast_enable.set_active (false);
        saturation_enable.set_active (false);
        gamma_enable.set_active (false);
        hue_enable.set_active (false);
        vibrance_enable.set_active (false);
        temperature_enable.set_active (false);
        curves_enable.set_active (false);

        brightness_spin.set_value (0.0);
        contrast_spin.set_value (1.0);
        saturation_spin.set_value (1.0);
        gamma_spin.set_value (1.0);
        hue_spin.set_value (0.0);
        vibrance_spin.set_value (1.0);
        temperature_spin.set_value (5500.0);
        curves_drop.set_selected (0);
    }

    // ── FFmpeg filter output ─────────────────────────────────────────────────

    public string get_filter_string () {
        string[] filters = {};

        // Brightness / Contrast / Saturation / Gamma are grouped under one eq= filter
        string[] eq_parts = {};
        if (brightness_enable.active)
            eq_parts += "brightness=%.2f".printf (brightness_spin.get_value ());
        if (contrast_enable.active)
            eq_parts += "contrast=%.2f".printf (contrast_spin.get_value ());
        if (saturation_enable.active)
            eq_parts += "saturation=%.2f".printf (saturation_spin.get_value ());
        if (gamma_enable.active)
            eq_parts += "gamma=%.2f".printf (gamma_spin.get_value ());
        if (eq_parts.length > 0)
            filters += "eq=" + string.joinv (":", eq_parts);

        if (hue_enable.active && hue_spin.get_value () != 0.0)
            filters += "hue=h=%.1f".printf (hue_spin.get_value ());

        if (vibrance_enable.active && vibrance_spin.get_value () != 1.0)
            filters += "vibrance=%.2f".printf (vibrance_spin.get_value ());

        if (temperature_enable.active && (int) temperature_spin.get_value () != 5500)
            filters += "colortemperature=temperature=%d".printf ((int) temperature_spin.get_value ());

        if (curves_enable.active) {
            var item = curves_drop.selected_item as StringObject;
            string curve = item != null ? item.string : "None";
            string preset = curve_name_to_preset (curve);
            if (preset != "")
                filters += "curves=preset=" + preset;
        }

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
