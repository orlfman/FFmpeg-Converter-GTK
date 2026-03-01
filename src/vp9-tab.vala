using Gtk;
using Adw;
using GLib;

public class Vp9Tab : Box, ICodecTab {

    // ── Preset ───────────────────────────────────────────────────────────────
    public DropDown  quality_profile_combo    { get; private set; }

    // ── Encoding ─────────────────────────────────────────────────────────────
    public DropDown  container_combo    { get; private set; }
    public SpinButton speed_spin       { get; private set; }
    public DropDown  quality_combo     { get; private set; }

    // ── Rate Control ─────────────────────────────────────────────────────────
    public DropDown   rc_mode_combo     { get; private set; }
    public SpinButton crf_spin          { get; private set; }
    public SpinButton cq_level_spin     { get; private set; }
    public SpinButton cq_bitrate_spin   { get; private set; }
    public SpinButton vbr_bitrate_spin  { get; private set; }
    public SpinButton cbr_bitrate_spin  { get; private set; }
    public CheckButton two_pass_check   { get; private set; }

    public Switch two_pass_switch;
    private Adw.ActionRow crf_row;
    private Adw.ActionRow cq_level_row;
    private Adw.ActionRow cq_bitrate_row;
    private Adw.ActionRow vbr_row;
    private Adw.ActionRow cbr_row;
    private Adw.ActionRow two_pass_row;

    // ── Quality & Tuning ─────────────────────────────────────────────────────
    public DropDown   tune_content_combo { get; private set; }
    public DropDown   aq_mode_combo      { get; private set; }

    // ── Lookahead ────────────────────────────────────────────────────────────
    public Adw.ExpanderRow lookahead_expander { get; private set; }
    public SpinButton lag_in_frames_spin { get; private set; }

    // ── Alt-Ref Frames ───────────────────────────────────────────────────────
    public Adw.ExpanderRow altref_expander   { get; private set; }
    public SpinButton arnr_maxframes_spin    { get; private set; }
    public SpinButton arnr_strength_spin     { get; private set; }

    // ── Advanced ─────────────────────────────────────────────────────────────
    public Switch     row_mt_switch         { get; private set; }
    public Switch     frame_parallel_switch { get; private set; }

    public Adw.ExpanderRow undershoot_expander { get; private set; }
    public SpinButton undershoot_spin    { get; private set; }
    public SpinButton overshoot_spin     { get; private set; }

    // ── Audio ────────────────────────────────────────────────────────────────
    public AudioSettings audio_settings  { get; private set; }

    // ── Threading & Keyframes ────────────────────────────────────────────────
    public DropDown  keyint_combo        { get; private set; }
    public DropDown  custom_keyframe_combo { get; private set; }
    public DropDown  threads_combo       { get; private set; }
    public DropDown  tile_columns_combo  { get; private set; }
    public DropDown  tile_rows_combo     { get; private set; }

    private Adw.ActionRow custom_keyframe_row;

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public Vp9Tab () {
        Object (orientation: Orientation.VERTICAL, spacing: 24);
        set_margin_top (24);
        set_margin_bottom (24);
        set_margin_start (24);
        set_margin_end (24);

        build_quality_profile_group ();
        build_encoding_group ();
        build_rate_control_group ();
        build_quality_group ();
        build_altref_group ();
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
            "Custom", "Streaming", "Anime", "Low", "Medium", "High", "Very High",
            "Imageboards"
        }), null);
        quality_profile_combo.set_valign (Align.CENTER);
        quality_profile_combo.set_selected (0);
        row.add_suffix (quality_profile_combo);
        group.add (row);

        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ENCODING
    // ═════════════════════════════════════════════════════════════════════════

    private void build_encoding_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Encoding");
        group.set_description ("Core VP9 encoder settings");

        // Container
        var container_row = new Adw.ActionRow ();
        container_row.set_title ("Container");
        container_row.set_subtitle ("WebM is the native VP9 container, MKV also works well");
        container_combo = new DropDown (new StringList ({ "webm", "mkv" }), null);
        container_combo.set_valign (Align.CENTER);
        container_combo.set_selected (0);
        container_row.add_suffix (container_combo);
        group.add (container_row);

        // Speed (cpu-used)
        var speed_row = new Adw.ActionRow ();
        speed_row.set_title ("Speed");
        speed_row.set_subtitle ("Lower = better quality but much slower (0–8, recommended 1–4)");
        speed_spin = new SpinButton.with_range (0, 8, 1);
        speed_spin.set_value (4);
        speed_spin.set_valign (Align.CENTER);
        speed_row.add_suffix (speed_spin);
        group.add (speed_row);

        // Quality deadline
        var quality_row = new Adw.ActionRow ();
        quality_row.set_title ("Quality Deadline");
        quality_row.set_subtitle ("Good balances speed and quality — Best is extremely slow");
        quality_combo = new DropDown (new StringList ({
            "good", "best", "realtime"
        }), null);
        quality_combo.set_valign (Align.CENTER);
        quality_combo.set_selected (0);
        quality_row.add_suffix (quality_combo);
        group.add (quality_row);

        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  RATE CONTROL
    // ═════════════════════════════════════════════════════════════════════════

    private void build_rate_control_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Rate Control");
        group.set_description ("VP9 rate control — two-pass is highly recommended for VBR");

        // Mode selector
        var mode_row = new Adw.ActionRow ();
        mode_row.set_title ("Mode");
        mode_row.set_subtitle ("CRF for constant quality, CQ for quality-capped bitrate");
        rc_mode_combo = new DropDown (new StringList (
            { "CRF", "Constrained Quality", "VBR", "CBR" }
        ), null);
        rc_mode_combo.set_valign (Align.CENTER);
        rc_mode_combo.set_selected (0);
        mode_row.add_suffix (rc_mode_combo);
        group.add (mode_row);

        // CRF value (used with -b:v 0 for true constant quality)
        crf_row = new Adw.ActionRow ();
        crf_row.set_title ("CRF Value");
        crf_row.set_subtitle ("Lower = better quality (0–63, recommended 15–35)");
        crf_spin = new SpinButton.with_range (0, 63, 1);
        crf_spin.set_value (31);
        crf_spin.set_valign (Align.CENTER);
        crf_row.add_suffix (crf_spin);
        group.add (crf_row);

        // CQ level (quality floor for constrained quality mode)
        cq_level_row = new Adw.ActionRow ();
        cq_level_row.set_title ("CQ Level");
        cq_level_row.set_subtitle ("Minimum quality level — encoder won't go worse than this (0–63)");
        cq_level_spin = new SpinButton.with_range (0, 63, 1);
        cq_level_spin.set_value (31);
        cq_level_spin.set_valign (Align.CENTER);
        cq_level_row.add_suffix (cq_level_spin);
        cq_level_row.set_visible (false);
        group.add (cq_level_row);

        // CQ bitrate cap
        cq_bitrate_row = new Adw.ActionRow ();
        cq_bitrate_row.set_title ("Bitrate Cap");
        cq_bitrate_row.set_subtitle ("Maximum average bitrate in kbps for constrained quality");
        cq_bitrate_spin = new SpinButton.with_range (100, 50000, 100);
        cq_bitrate_spin.set_value (2000);
        cq_bitrate_spin.set_valign (Align.CENTER);
        cq_bitrate_row.add_suffix (cq_bitrate_spin);
        cq_bitrate_row.set_visible (false);
        group.add (cq_bitrate_row);

        // VBR bitrate
        vbr_row = new Adw.ActionRow ();
        vbr_row.set_title ("Target Bitrate");
        vbr_row.set_subtitle ("Average bitrate in kbps — use with two-pass for best results");
        vbr_bitrate_spin = new SpinButton.with_range (100, 50000, 100);
        vbr_bitrate_spin.set_value (2000);
        vbr_bitrate_spin.set_valign (Align.CENTER);
        vbr_row.add_suffix (vbr_bitrate_spin);
        vbr_row.set_visible (false);
        group.add (vbr_row);

        // CBR bitrate
        cbr_row = new Adw.ActionRow ();
        cbr_row.set_title ("Constant Bitrate");
        cbr_row.set_subtitle ("Fixed bitrate in kbps — for streaming and real-time");
        cbr_bitrate_spin = new SpinButton.with_range (100, 50000, 100);
        cbr_bitrate_spin.set_value (2000);
        cbr_bitrate_spin.set_valign (Align.CENTER);
        cbr_row.add_suffix (cbr_bitrate_spin);
        cbr_row.set_visible (false);
        group.add (cbr_row);

        // Two-pass
        two_pass_row = new Adw.ActionRow ();
        two_pass_row.set_title ("Two-Pass Encoding");
        two_pass_row.set_subtitle ("Strongly recommended for VP9 — much better quality distribution");

        two_pass_check = new CheckButton ();
        two_pass_check.set_visible (false);

        two_pass_switch = new Switch ();
        two_pass_switch.set_valign (Align.CENTER);
        two_pass_switch.set_active (false);
        two_pass_row.add_suffix (two_pass_switch);
        two_pass_row.set_activatable_widget (two_pass_switch);
        two_pass_row.set_visible (false);

        two_pass_switch.notify["active"].connect (() => {
            two_pass_check.set_active (two_pass_switch.active);
        });

        group.add (two_pass_row);
        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  QUALITY & TUNING
    // ═════════════════════════════════════════════════════════════════════════

    private void build_quality_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Quality & Tuning");

        // Tune Content
        var tune_row = new Adw.ActionRow ();
        tune_row.set_title ("Content Type");
        tune_row.set_subtitle ("Optimize encoding decisions for specific content");
        tune_content_combo = new DropDown (new StringList ({
            "Default", "Screen", "Film"
        }), null);
        tune_content_combo.set_valign (Align.CENTER);
        tune_content_combo.set_selected (0);
        tune_row.add_suffix (tune_content_combo);
        group.add (tune_row);

        // AQ Mode
        var aq_row = new Adw.ActionRow ();
        aq_row.set_title ("AQ Mode");
        aq_row.set_subtitle ("Adaptive Quantization distributes bits across the frame");
        aq_mode_combo = new DropDown (new StringList ({
            "Disabled", "Variance", "Complexity", "Cyclic Refresh", "Equator360"
        }), null);
        aq_mode_combo.set_valign (Align.CENTER);
        aq_mode_combo.set_selected (0);
        aq_row.add_suffix (aq_mode_combo);
        group.add (aq_row);

        // Lookahead (lag-in-frames)
        lookahead_expander = new Adw.ExpanderRow ();
        lookahead_expander.set_title ("Lookahead");
        lookahead_expander.set_subtitle ("Frames to buffer for better rate control decisions (0–25)");
        lookahead_expander.set_show_enable_switch (true);
        lookahead_expander.set_enable_expansion (false);

        var la_row = new Adw.ActionRow ();
        la_row.set_title ("Frames");
        lag_in_frames_spin = new SpinButton.with_range (0, 25, 1);
        lag_in_frames_spin.set_value (25);
        lag_in_frames_spin.set_valign (Align.CENTER);
        la_row.add_suffix (lag_in_frames_spin);
        lookahead_expander.add_row (la_row);
        group.add (lookahead_expander);

        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ALT-REF FRAMES
    // ═════════════════════════════════════════════════════════════════════════

    private void build_altref_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Alternate Reference Frames");
        group.set_description ("Invisible reference frames that improve compression in static scenes");

        altref_expander = new Adw.ExpanderRow ();
        altref_expander.set_title ("Enable Alt-Ref Frames");
        altref_expander.set_subtitle ("Synthesized reference frames — best used with lookahead");
        altref_expander.set_show_enable_switch (true);
        altref_expander.set_enable_expansion (true);

        // ARNR Max Frames
        var arnr_frames_row = new Adw.ActionRow ();
        arnr_frames_row.set_title ("Filter Frames");
        arnr_frames_row.set_subtitle ("Temporal filter range for alt-ref synthesis (1–15)");
        arnr_maxframes_spin = new SpinButton.with_range (1, 15, 1);
        arnr_maxframes_spin.set_value (7);
        arnr_maxframes_spin.set_valign (Align.CENTER);
        arnr_frames_row.add_suffix (arnr_maxframes_spin);
        altref_expander.add_row (arnr_frames_row);

        // ARNR Strength
        var arnr_strength_row = new Adw.ActionRow ();
        arnr_strength_row.set_title ("Filter Strength");
        arnr_strength_row.set_subtitle ("Temporal noise reduction strength (0–6)");
        arnr_strength_spin = new SpinButton.with_range (0, 6, 1);
        arnr_strength_spin.set_value (5);
        arnr_strength_spin.set_valign (Align.CENTER);
        arnr_strength_row.add_suffix (arnr_strength_spin);
        altref_expander.add_row (arnr_strength_row);

        group.add (altref_expander);
        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ADVANCED
    // ═════════════════════════════════════════════════════════════════════════

    private void build_advanced_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Advanced");

        // Row-based Multithreading
        var rowmt_row = new Adw.ActionRow ();
        rowmt_row.set_title ("Row-Based Multithreading");
        rowmt_row.set_subtitle ("Major speedup — splits each frame row across threads");
        row_mt_switch = new Switch ();
        row_mt_switch.set_valign (Align.CENTER);
        row_mt_switch.set_active (true);
        rowmt_row.add_suffix (row_mt_switch);
        rowmt_row.set_activatable_widget (row_mt_switch);
        group.add (rowmt_row);

        // Frame Parallel Decoding
        var fp_row = new Adw.ActionRow ();
        fp_row.set_title ("Frame Parallel Decoding");
        fp_row.set_subtitle ("Enables parallel decode — slightly reduces compression efficiency");
        frame_parallel_switch = new Switch ();
        frame_parallel_switch.set_valign (Align.CENTER);
        frame_parallel_switch.set_active (false);
        fp_row.add_suffix (frame_parallel_switch);
        fp_row.set_activatable_widget (frame_parallel_switch);
        group.add (fp_row);

        // Undershoot / Overshoot (rate control tolerance)
        undershoot_expander = new Adw.ExpanderRow ();
        undershoot_expander.set_title ("Rate Tolerance");
        undershoot_expander.set_subtitle ("How far the encoder may deviate from target bitrate");
        undershoot_expander.set_show_enable_switch (true);
        undershoot_expander.set_enable_expansion (false);

        var under_row = new Adw.ActionRow ();
        under_row.set_title ("Undershoot");
        under_row.set_subtitle ("Allowed percentage below target (0–100, default 25)");
        undershoot_spin = new SpinButton.with_range (0, 100, 5);
        undershoot_spin.set_value (25);
        undershoot_spin.set_valign (Align.CENTER);
        under_row.add_suffix (undershoot_spin);
        undershoot_expander.add_row (under_row);

        var over_row = new Adw.ActionRow ();
        over_row.set_title ("Overshoot");
        over_row.set_subtitle ("Allowed percentage above target (0–100, default 25)");
        overshoot_spin = new SpinButton.with_range (0, 100, 5);
        overshoot_spin.set_value (25);
        overshoot_spin.set_valign (Align.CENTER);
        over_row.add_suffix (overshoot_spin);
        undershoot_expander.add_row (over_row);

        group.add (undershoot_expander);
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

        // Tile Columns
        var tcols_row = new Adw.ActionRow ();
        tcols_row.set_title ("Tile Columns");
        tcols_row.set_subtitle ("Parallel column encoding — higher values need more threads");
        tile_columns_combo = new DropDown (new StringList ({
            "Auto", "0", "1", "2", "3", "4", "5", "6"
        }), null);
        tile_columns_combo.set_valign (Align.CENTER);
        tile_columns_combo.set_selected (0);
        tcols_row.add_suffix (tile_columns_combo);
        group.add (tcols_row);

        // Tile Rows
        var trows_row = new Adw.ActionRow ();
        trows_row.set_title ("Tile Rows");
        trows_row.set_subtitle ("Parallel row encoding (0–2, log₂ scale)");
        tile_rows_combo = new DropDown (new StringList ({
            "Auto", "0", "1", "2"
        }), null);
        tile_rows_combo.set_valign (Align.CENTER);
        tile_rows_combo.set_selected (0);
        trows_row.add_suffix (tile_rows_combo);
        group.add (trows_row);

        // Threads
        var threads_row = new Adw.ActionRow ();
        threads_row.set_title ("Threads");
        threads_row.set_subtitle ("CPU threads — Auto detects your system");
        threads_combo = new DropDown (new StringList ({
            "Auto", "1", "2", "4", "6", "8", "12", "16", "24", "32"
        }), null);
        threads_combo.set_valign (Align.CENTER);
        threads_combo.set_selected (0);
        threads_row.add_suffix (threads_combo);
        group.add (threads_row);

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
        reset_btn.clicked.connect (reset_defaults);
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
                CodecPresets.apply_vp9 (this, item.string);
        });

        // Rate control mode → show/hide rows
        rc_mode_combo.notify["selected"].connect (update_rc_visibility);
        update_rc_visibility ();

        // Container → update audio codec list
        container_combo.notify["selected"].connect (() => {
            audio_settings.update_for_container (get_container ());
        });

        // Custom keyframe mode visibility
        keyint_combo.notify["selected"].connect (() => {
            string ki = get_dropdown_text (keyint_combo);
            custom_keyframe_row.set_visible (ki == "Custom");
        });

        // Alt-ref ↔ lookahead recommendation:
        // When alt-ref is enabled, auto-enable lookahead if not already on
        altref_expander.notify["enable-expansion"].connect (() => {
            if (altref_expander.enable_expansion && !lookahead_expander.enable_expansion) {
                lookahead_expander.set_enable_expansion (true);
            }
        });
    }

    private void update_rc_visibility () {
        string mode = get_dropdown_text (rc_mode_combo);
        crf_row.set_visible (mode == "CRF");
        cq_level_row.set_visible (mode == "Constrained Quality");
        cq_bitrate_row.set_visible (mode == "Constrained Quality");
        vbr_row.set_visible (mode == "VBR");
        cbr_row.set_visible (mode == "CBR");
        // Two-pass for bitrate-targeting modes (CQ, VBR, CBR) — not pure CRF
        bool can_two_pass = (mode != "CRF");
        two_pass_row.set_visible (can_two_pass);
        if (!can_two_pass) {
            two_pass_switch.set_active (false);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    public string get_dropdown_text (DropDown dropdown) {
        var item = dropdown.selected_item as StringObject;
        return item != null ? item.string : "";
    }

    public string get_container () {
        return get_dropdown_text (container_combo);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ICodecTab INTERFACE
    // ═════════════════════════════════════════════════════════════════════════

    public ICodecBuilder get_codec_builder () {
        return new Vp9Builder ();
    }

    public bool get_two_pass () {
        return two_pass_check.get_active ();
    }

    public string[] get_audio_args () {
        return audio_settings.get_audio_args ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  RESET
    // ═════════════════════════════════════════════════════════════════════════

    public void reset_defaults () {
        // Encoding
        container_combo.set_selected (0);
        speed_spin.set_value (4);
        quality_combo.set_selected (0);

        // Rate Control
        rc_mode_combo.set_selected (0);
        crf_spin.set_value (31);
        cq_level_spin.set_value (31);
        cq_bitrate_spin.set_value (2000);
        vbr_bitrate_spin.set_value (2000);
        cbr_bitrate_spin.set_value (2000);
        two_pass_check.set_active (false);
        two_pass_switch.set_active (false);

        // Quality & Tuning
        tune_content_combo.set_selected (0);
        aq_mode_combo.set_selected (0);
        lookahead_expander.set_enable_expansion (false);
        lag_in_frames_spin.set_value (25);

        // Alt-Ref
        altref_expander.set_enable_expansion (true);
        arnr_maxframes_spin.set_value (7);
        arnr_strength_spin.set_value (5);

        // Advanced
        row_mt_switch.set_active (true);
        frame_parallel_switch.set_active (false);
        undershoot_expander.set_enable_expansion (false);
        undershoot_spin.set_value (25);
        overshoot_spin.set_value (25);

        // Audio
        audio_settings.reset_defaults ();

        // Threading & Keyframes
        keyint_combo.set_selected (0);
        custom_keyframe_combo.set_selected (3);
        tile_columns_combo.set_selected (0);
        tile_rows_combo.set_selected (0);
        threads_combo.set_selected (0);

        update_rc_visibility ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CUSTOM KEYFRAME RESOLUTION
    // ═════════════════════════════════════════════════════════════════════════

    public string[] resolve_keyframe_args (string input_file, GeneralTab general_tab) {
        string keyint = get_dropdown_text (keyint_combo);

        if (keyint != "Custom")
            return {};

        int mode = (int) custom_keyframe_combo.get_selected ();
        int seconds = (mode == 0 || mode == 1) ? 2 : 5;
        bool use_fixed_time = (mode == 0 || mode == 2);

        if (use_fixed_time) {
            return { "-force_key_frames",
                     @"expr:gte(t,n_forced*$seconds)" };
        }

        double fps = 0.0;

        string fr_text = get_dropdown_text (general_tab.frame_rate_combo);
        if (fr_text == "Custom") {
            string custom_fr = general_tab.custom_frame_rate.text.strip ();
            if (custom_fr.length > 0)
                fps = double.parse (custom_fr);
        } else if (fr_text != "Original") {
            fps = double.parse (fr_text);
        }

        if (fps < 5.0)
            fps = probe_input_fps (input_file);

        if (fps < 5.0 || fps > 500.0)
            return { "-g", "240" };

        int gop = (int) (seconds * fps + 0.5);
        if (gop < 10) gop = 240;

        return { "-g", gop.to_string () };
    }

    private static double probe_input_fps (string input_file) {
        try {
            string[] cmd = {
                "ffprobe", "-v", "quiet",
                "-select_streams", "v:0",
                "-show_entries", "stream=r_frame_rate",
                "-of", "csv=p=0",
                input_file
            };
            string stdout_text, stderr_text;
            int status;

            Process.spawn_sync (null, cmd, null, SpawnFlags.SEARCH_PATH,
                                null, out stdout_text, out stderr_text, out status);

            if (status != 0 || stdout_text == null)
                return 0.0;

            string raw = stdout_text.strip ();

            if (raw.contains ("/")) {
                string[] parts = raw.split ("/");
                if (parts.length >= 2) {
                    double num = double.parse (parts[0].strip ());
                    double den = double.parse (parts[1].strip ());
                    if (den > 0.0)
                        return num / den;
                }
            }

            double plain = double.parse (raw);
            if (plain > 0.0) return plain;

        } catch (Error e) {
            // probe failed
        }
        return 0.0;
    }
}
