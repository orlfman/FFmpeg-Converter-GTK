using Gtk;
using Adw;

public class AudioProcessingSettings : Object {
    private Adw.PreferencesGroup group;
    private bool allow_peak_normalization = true;

    private Adw.SwitchRow normalize_row_switch;
    private Adw.ActionRow normalize_mode_row;
    private DropDown normalize_mode_combo;
    private Adw.ActionRow fade_in_row;
    private Switch fade_in_switch;
    private SpinButton fade_in_spin;
    private Adw.ActionRow fade_out_row;
    private Switch fade_out_switch;
    private SpinButton fade_out_spin;
    private Adw.ActionRow channel_row;
    private DropDown channel_combo;

    public signal void changed ();

    public AudioProcessingSettings (bool allow_peak_normalization = true,
                                    string title = "Audio Processing",
                                    string description = "Optional audio filters and transformations") {
        this.allow_peak_normalization = allow_peak_normalization;
        build_ui (title, description);
        connect_signals ();
    }

    public Adw.PreferencesGroup get_widget () {
        return group;
    }

    private void build_ui (string title, string description) {
        group = new Adw.PreferencesGroup ();
        group.set_title (title);
        group.set_description (description);

        normalize_row_switch = new Adw.SwitchRow ();
        normalize_row_switch.set_title ("Audio Normalization");
        normalize_row_switch.set_subtitle ("Re-encode audio and normalize output levels");
        normalize_row_switch.set_active (false);
        group.add (normalize_row_switch);

        normalize_mode_row = new Adw.ActionRow ();
        normalize_mode_row.set_title ("Normalization Method");
        string[] normalize_modes;
        if (allow_peak_normalization) {
            normalize_modes = { "Loudness (EBU R128)", "Peak Normalize" };
        } else {
            normalize_modes = { "Loudness (EBU R128)" };
        }
        normalize_mode_combo = new DropDown (
            CodecUtils.build_dropdown_string_list (normalize_modes),
            null
        );
        normalize_mode_combo.set_valign (Align.CENTER);
        normalize_mode_row.add_suffix (normalize_mode_combo);
        normalize_mode_row.set_visible (false);
        group.add (normalize_mode_row);

        fade_in_row = new Adw.ActionRow ();
        fade_in_row.set_title ("Fade In");
        fade_in_row.set_subtitle ("Audio starts silent and slowly gets louder over this many seconds");
        fade_in_switch = new Switch ();
        fade_in_switch.set_valign (Align.CENTER);
        fade_in_switch.set_active (false);
        fade_in_spin = new SpinButton.with_range (0.1, 30.0, 0.1);
        fade_in_spin.set_value (2.0);
        fade_in_spin.set_valign (Align.CENTER);
        fade_in_spin.set_sensitive (false);
        fade_in_row.add_suffix (fade_in_switch);
        fade_in_row.add_suffix (fade_in_spin);
        group.add (fade_in_row);

        fade_out_row = new Adw.ActionRow ();
        fade_out_row.set_title ("Fade Out");
        fade_out_row.set_subtitle ("Audio slowly goes quiet and ends in silence over this many seconds");
        fade_out_switch = new Switch ();
        fade_out_switch.set_valign (Align.CENTER);
        fade_out_switch.set_active (false);
        fade_out_spin = new SpinButton.with_range (0.1, 30.0, 0.1);
        fade_out_spin.set_value (2.0);
        fade_out_spin.set_valign (Align.CENTER);
        fade_out_spin.set_sensitive (false);
        fade_out_row.add_suffix (fade_out_switch);
        fade_out_row.add_suffix (fade_out_spin);
        group.add (fade_out_row);

        channel_row = new Adw.ActionRow ();
        channel_row.set_title ("Channel Layout");
        channel_combo = new DropDown (CodecUtils.build_dropdown_string_list (
            { "Source", "Stereo", "Mono" }
        ), null);
        channel_combo.set_valign (Align.CENTER);
        channel_row.add_suffix (channel_combo);
        group.add (channel_row);
    }

    private void connect_signals () {
        normalize_row_switch.notify["active"].connect (() => {
            normalize_mode_row.set_visible (
                normalize_row_switch.get_active () && allow_peak_normalization
            );
            changed ();
        });

        normalize_mode_combo.notify["selected"].connect (() => {
            changed ();
        });

        fade_in_switch.notify["active"].connect (() => {
            fade_in_spin.set_sensitive (fade_in_switch.active);
            changed ();
        });
        fade_in_spin.value_changed.connect (() => {
            changed ();
        });

        fade_out_switch.notify["active"].connect (() => {
            fade_out_spin.set_sensitive (fade_out_switch.active);
            changed ();
        });
        fade_out_spin.value_changed.connect (() => {
            changed ();
        });

        channel_combo.notify["selected"].connect (() => {
            changed ();
        });
    }

    public AudioProcessingSettingsSnapshot snapshot_settings () {
        var snapshot = new AudioProcessingSettingsSnapshot ();
        snapshot.normalize_enabled = normalize_row_switch.get_active ();
        snapshot.normalize_ebu = !allow_peak_normalization
            || normalize_mode_combo.get_selected () == 0;
        snapshot.fade_in_enabled = fade_in_switch.active;
        snapshot.fade_in_duration = fade_in_spin.get_value ();
        snapshot.fade_out_enabled = fade_out_switch.active;
        snapshot.fade_out_duration = fade_out_spin.get_value ();
        snapshot.channel_downmix = (int) channel_combo.get_selected ();
        return snapshot;
    }

    public AudioProcessingSettingsSnapshot snapshot_fades_only () {
        var snapshot = new AudioProcessingSettingsSnapshot ();
        snapshot.fade_in_enabled = fade_in_switch.active;
        snapshot.fade_in_duration = fade_in_spin.get_value ();
        snapshot.fade_out_enabled = fade_out_switch.active;
        snapshot.fade_out_duration = fade_out_spin.get_value ();
        return snapshot;
    }

    public void apply_snapshot (AudioProcessingSettingsSnapshot snapshot) {
        normalize_row_switch.set_active (snapshot.normalize_enabled);
        if (allow_peak_normalization) {
            normalize_mode_combo.set_selected (snapshot.normalize_ebu ? 0U : 1U);
        } else {
            normalize_mode_combo.set_selected (0);
        }

        fade_in_switch.set_active (snapshot.fade_in_enabled);
        fade_in_spin.set_value (snapshot.fade_in_duration);
        fade_out_switch.set_active (snapshot.fade_out_enabled);
        fade_out_spin.set_value (snapshot.fade_out_duration);
        channel_combo.set_selected ((uint) snapshot.channel_downmix);
    }

    public void restore_fades_only (AudioProcessingSettingsSnapshot snapshot) {
        fade_in_switch.set_active (snapshot.fade_in_enabled);
        fade_in_spin.set_value (snapshot.fade_in_duration);
        fade_out_switch.set_active (snapshot.fade_out_enabled);
        fade_out_spin.set_value (snapshot.fade_out_duration);
    }

    public void reset_defaults () {
        apply_snapshot (new AudioProcessingSettingsSnapshot ());
    }

    public bool requires_audio_reencode () {
        return snapshot_settings ().requires_audio_reencode ();
    }

    public void clear_fades () {
        fade_in_switch.set_active (false);
        fade_out_switch.set_active (false);
        changed ();
    }

    public void set_fade_controls_sensitive (bool sensitive) {
        fade_in_switch.set_sensitive (sensitive);
        fade_out_switch.set_sensitive (sensitive);
        fade_in_spin.set_sensitive (sensitive && fade_in_switch.active);
        fade_out_spin.set_sensitive (sensitive && fade_out_switch.active);
    }

    public static string build_normalization_filter_from_snapshot (
        AudioProcessingSettingsSnapshot snapshot) {
        if (!snapshot.normalize_enabled) {
            return "";
        }

        if (snapshot.normalize_ebu) {
            return AudioNormalization.EBU_R128_FILTER;
        }

        if (Math.fabs (snapshot.peak_normalize_gain_db) >= 0.005) {
            return "volume=%sdB".printf (
                ConversionUtils.format_ffmpeg_double (
                    snapshot.peak_normalize_gain_db, "%.2f"));
        }

        return "";
    }

    public static string build_filter_chain_from_snapshot (
        AudioProcessingSettingsSnapshot snapshot,
        double duration = 0.0,
        bool include_normalization = true,
        bool apply_fade_in = true,
        bool apply_fade_out = true) {
        var filters = new GenericArray<string> ();

        if (include_normalization) {
            string normalization_filter =
                build_normalization_filter_from_snapshot (snapshot);
            if (normalization_filter.length > 0) {
                filters.add (normalization_filter);
            }
        }

        if (apply_fade_in && snapshot.fade_in_enabled && snapshot.fade_in_duration > 0.0) {
            filters.add ("afade=t=in:d=%s".printf (
                ConversionUtils.format_ffmpeg_double (snapshot.fade_in_duration, "%.2f")));
        }

        if (apply_fade_out
            && snapshot.fade_out_enabled
            && snapshot.fade_out_duration > 0.0
            && duration > 0.0) {
            double fade_start = duration - snapshot.fade_out_duration;
            if (fade_start < 0.0) {
                fade_start = 0.0;
            }
            filters.add ("afade=t=out:st=%s:d=%s".printf (
                ConversionUtils.format_ffmpeg_double (fade_start, "%.2f"),
                ConversionUtils.format_ffmpeg_double (snapshot.fade_out_duration, "%.2f")));
        }

        if (filters.length == 0) {
            return "";
        }

        return string.joinv (",", StringArrayUtils.copy_generic_array (filters));
    }

    public static string[] build_output_args_from_snapshot (
        AudioProcessingSettingsSnapshot snapshot) {
        var args = new GenericArray<string> ();

        if (snapshot.channel_downmix == 1) {
            args.add ("-ac");
            args.add ("2");
        } else if (snapshot.channel_downmix == 2) {
            args.add ("-ac");
            args.add ("1");
        }

        return StringArrayUtils.copy_generic_array (args);
    }
}
