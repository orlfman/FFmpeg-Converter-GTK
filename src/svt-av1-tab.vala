using Gtk;
using Adw;

public class SvtAv1Tab : Box, ICodecTab {

    // ── Encoding Basics ──────────────────────────────────────────────────────
    public DropDown  container_combo     { get; private set; }
    public SpinButton preset_spin        { get; private set; }

    // ── Rate Control ─────────────────────────────────────────────────────────
    public DropDown  rc_mode_combo       { get; private set; }
    public SpinButton crf_spin           { get; private set; }
    public SpinButton qp_spin            { get; private set; }
    public SpinButton vbr_bitrate_spin   { get; private set; }
    public CheckButton two_pass_check    { get; private set; }

    private Adw.ActionRow crf_row;
    private Adw.ActionRow qp_row;
    private Adw.ActionRow vbr_row;

    // ── Quality & Tuning ─────────────────────────────────────────────────────
    public DropDown  tune_combo          { get; private set; }
    public DropDown  level_combo         { get; private set; }
    public DropDown  aq_mode_combo       { get; private set; }
    public SpinButton aq_strength_spin   { get; private set; }

    private Adw.ActionRow aq_strength_row;

    // ── Lookahead ────────────────────────────────────────────────────────────
    public Adw.ExpanderRow lookahead_expander { get; private set; }
    public SpinButton lookahead_spin     { get; private set; }

    // ── Film Grain ───────────────────────────────────────────────────────────
    public Adw.ExpanderRow grain_expander { get; private set; }
    public SpinButton grain_strength_spin { get; private set; }
    public DropDown  grain_denoise_combo  { get; private set; }

    // ── In-Loop Filters ──────────────────────────────────────────────────────
    public Switch cdef_switch            { get; private set; }
    public Switch restoration_switch     { get; private set; }
    public Switch tf_switch              { get; private set; }

    public Adw.ExpanderRow dlf_expander  { get; private set; }
    public DropDown  dlf_mode_combo      { get; private set; }

    // ── Advanced ─────────────────────────────────────────────────────────────
    public Switch tpl_switch             { get; private set; }
    public Switch low_latency_switch     { get; private set; }
    public DropDown  scm_combo           { get; private set; }
    public DropDown  fast_decode_combo   { get; private set; }

    public Adw.ExpanderRow superres_expander { get; private set; }
    public DropDown  superres_mode_combo { get; private set; }
    public SpinButton superres_denom_spin { get; private set; }

    public Adw.ExpanderRow sharpness_expander { get; private set; }
    public SpinButton sharpness_spin     { get; private set; }

    public Adw.ExpanderRow qm_expander   { get; private set; }
    public SpinButton qm_min_spin        { get; private set; }
    public SpinButton qm_max_spin        { get; private set; }

    // ── Threading & Keyframes ────────────────────────────────────────────────
    private Switch two_pass_switch;
    public AudioSettings audio_settings  { get; private set; }

    public DropDown  keyint_combo        { get; private set; }
    public DropDown  threads_combo       { get; private set; }
    public DropDown  tile_rows_combo     { get; private set; }
    public DropDown  tile_columns_combo  { get; private set; }
    public DropDown  custom_keyframe_combo { get; private set; }

    private Adw.ActionRow custom_keyframe_row;

    public SvtAv1Tab () {
        Object (orientation: Orientation.VERTICAL, spacing: 24);
        set_margin_top (24);
        set_margin_bottom (24);
        set_margin_start (24);
        set_margin_end (24);

        build_encoding_group ();
        build_rate_control_group ();
        build_quality_group ();
        build_grain_group ();
        build_in_loop_filters_group ();
	build_advanced_group ();
        build_audio_group ();
        build_threading_group ();
        build_reset_button ();

        connect_signals ();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  ENCODING BASICS
    // ═══════════════════════════════════════════════════════════════════════════

    private void build_encoding_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Encoding");
        group.set_description ("Core encoder settings");

        // Container
        var container_row = new Adw.ActionRow ();
        container_row.set_title ("Container");
        container_row.set_subtitle ("MKV for general use, WebM for web playback");
        container_combo = new DropDown (new StringList ({ "mkv", "webm" }), null);
        container_combo.set_valign (Align.CENTER);
        container_combo.set_selected (0);
        container_row.add_suffix (container_combo);
        group.add (container_row);

        // Preset
        var preset_row = new Adw.ActionRow ();
        preset_row.set_title ("Preset");
        preset_row.set_subtitle ("Lower = better quality but slower (0–13)");
        preset_spin = new SpinButton.with_range (0, 13, 1);
        preset_spin.set_value (8);
        preset_spin.set_valign (Align.CENTER);
        preset_row.add_suffix (preset_spin);
        group.add (preset_row);

        append (group);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  RATE CONTROL
    // ═══════════════════════════════════════════════════════════════════════════

    private void build_rate_control_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Rate Control");
        group.set_description ("How the encoder allocates bits");

        // Mode
        var mode_row = new Adw.ActionRow ();
        mode_row.set_title ("Mode");
        mode_row.set_subtitle ("CRF balances quality and size automatically");
        rc_mode_combo = new DropDown (new StringList ({ "CRF", "QP", "VBR" }), null);
        rc_mode_combo.set_valign (Align.CENTER);
        rc_mode_combo.set_selected (0);
        mode_row.add_suffix (rc_mode_combo);
        group.add (mode_row);

        // CRF Value
        crf_row = new Adw.ActionRow ();
        crf_row.set_title ("CRF Value");
        crf_row.set_subtitle ("Lower = better quality, larger file (0–63)");
        crf_spin = new SpinButton.with_range (0, 63, 1);
        crf_spin.set_value (28);
        crf_spin.set_valign (Align.CENTER);
        crf_row.add_suffix (crf_spin);
        group.add (crf_row);

        // QP Value
        qp_row = new Adw.ActionRow ();
        qp_row.set_title ("QP Value");
        qp_row.set_subtitle ("Fixed quantizer — simple quality control (0–63)");
        qp_spin = new SpinButton.with_range (0, 63, 1);
        qp_spin.set_value (28);
        qp_spin.set_valign (Align.CENTER);
        qp_row.add_suffix (qp_spin);
        qp_row.set_visible (false);
        group.add (qp_row);

        // VBR Bitrate
        vbr_row = new Adw.ActionRow ();
        vbr_row.set_title ("VBR Bitrate");
        vbr_row.set_subtitle ("Target average bitrate in kbps");
        vbr_bitrate_spin = new SpinButton.with_range (100, 50000, 100);
        vbr_bitrate_spin.set_value (2000);
        vbr_bitrate_spin.set_valign (Align.CENTER);
        vbr_row.add_suffix (vbr_bitrate_spin);
        vbr_row.set_visible (false);
        group.add (vbr_row);

        // Two-Pass
        var two_pass_row = new Adw.ActionRow ();
        two_pass_row.set_title ("Two-Pass Encoding");
        two_pass_row.set_subtitle ("Slower but better quality distribution");
        two_pass_check = new CheckButton ();
        two_pass_check.set_valign (Align.CENTER);
        two_pass_check.set_active (false);
        // Use a Switch for visual consistency
        two_pass_switch = new Switch ();
        two_pass_switch.set_valign (Align.CENTER);
        two_pass_row.add_suffix (two_pass_switch);
        two_pass_row.set_activatable_widget (two_pass_switch);
        // Keep the CheckButton in sync for converter.vala compatibility
        two_pass_switch.notify["active"].connect (() => {
            two_pass_check.set_active (two_pass_switch.active);
        });
        group.add (two_pass_row);

        append (group);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  QUALITY & TUNING
    // ═══════════════════════════════════════════════════════════════════════════

    private void build_quality_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Quality & Tuning");

	// Tune
	var tune_row = new Adw.ActionRow ();
	tune_row.set_title ("Tune");
	tune_row.set_subtitle ("Optimize for a specific quality metric");
	tune_combo = new DropDown (new StringList ({
    		"VQ (Subjective SSIM)", "PSNR", "SSIM"
	}), null);
	tune_combo.set_valign (Align.CENTER);
	tune_combo.set_selected (0);
	tune_row.add_suffix (tune_combo);
	group.add (tune_row);

        // Level
        var level_row = new Adw.ActionRow ();
        level_row.set_title ("Encoding Level");
        level_row.set_subtitle ("AV1 compatibility level — Auto works for most players");
        level_combo = new DropDown (new StringList ({
            "Auto", "2.0", "2.1", "3.0", "3.1", "4.0", "4.1",
            "5.0", "5.1", "5.2", "5.3", "6.0", "6.1", "6.2", "6.3"
        }), null);
        level_combo.set_valign (Align.CENTER);
        level_combo.set_selected (0);
        level_row.add_suffix (level_combo);
        group.add (level_row);

        // Lookahead (ExpanderRow)
        lookahead_expander = new Adw.ExpanderRow ();
        lookahead_expander.set_title ("Lookahead");
        lookahead_expander.set_subtitle ("Look ahead for better compression decisions");
        lookahead_expander.set_show_enable_switch (true);
        lookahead_expander.set_enable_expansion (false);

        var la_frames_row = new Adw.ActionRow ();
        la_frames_row.set_title ("Frames");
        la_frames_row.set_subtitle ("Higher = slower but better (0–120)");
        lookahead_spin = new SpinButton.with_range (0, 120, 1);
        lookahead_spin.set_value (35);
        lookahead_spin.set_valign (Align.CENTER);
        la_frames_row.add_suffix (lookahead_spin);
        lookahead_expander.add_row (la_frames_row);
        group.add (lookahead_expander);

        // AQ Mode
        var aq_row = new Adw.ActionRow ();
        aq_row.set_title ("AQ Mode");
        aq_row.set_subtitle ("Adaptive quantization adjusts quality per-region");
        aq_mode_combo = new DropDown (new StringList ({
            "Automatic", "Disabled", "Variance", "Complexity"
        }), null);
        aq_mode_combo.set_valign (Align.CENTER);
        aq_mode_combo.set_selected (0);
        aq_row.add_suffix (aq_mode_combo);
        group.add (aq_row);

        // AQ Strength
        aq_strength_row = new Adw.ActionRow ();
        aq_strength_row.set_title ("AQ Strength");
        aq_strength_row.set_subtitle ("Variance boost strength (1–4)");
        aq_strength_spin = new SpinButton.with_range (1, 4, 1);
        aq_strength_spin.set_value (2);
        aq_strength_spin.set_valign (Align.CENTER);
        aq_strength_row.add_suffix (aq_strength_spin);
        aq_strength_row.set_sensitive (false);
        group.add (aq_strength_row);

        append (group);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  FILM GRAIN
    // ═══════════════════════════════════════════════════════════════════════════

    private void build_grain_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Film Grain");
        group.set_description ("Native AV1 grain synthesis for a film-like look");

        grain_expander = new Adw.ExpanderRow ();
        grain_expander.set_title ("Film Grain Synthesis");
        grain_expander.set_subtitle ("Adds grain directly in the AV1 bitstream — better for compression than FFmpeg filters");
        grain_expander.set_show_enable_switch (true);
        grain_expander.set_enable_expansion (false);

        var strength_row = new Adw.ActionRow ();
        strength_row.set_title ("Strength");
        strength_row.set_subtitle ("0 = none, 50 = maximum (0–50)");
        grain_strength_spin = new SpinButton.with_range (0, 50, 1);
        grain_strength_spin.set_value (0);
        grain_strength_spin.set_valign (Align.CENTER);
        strength_row.add_suffix (grain_strength_spin);
        grain_expander.add_row (strength_row);

        var denoise_row = new Adw.ActionRow ();
        denoise_row.set_title ("Grain Denoise");
        denoise_row.set_subtitle ("Denoise first, then add clean synthetic grain");
        grain_denoise_combo = new DropDown (new StringList ({
            "Off — add grain on top of existing noise",
            "On — denoise then add grain"
        }), null);
        grain_denoise_combo.set_valign (Align.CENTER);
        grain_denoise_combo.set_selected (0);
        denoise_row.add_suffix (grain_denoise_combo);
        grain_expander.add_row (denoise_row);

        group.add (grain_expander);
        append (group);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  IN-LOOP FILTERS
    // ═══════════════════════════════════════════════════════════════════════════

    private void build_in_loop_filters_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("In-Loop Filters");
        group.set_description ("AV1 decoder-side quality enhancement filters");

        // CDEF
        var cdef_row = new Adw.ActionRow ();
        cdef_row.set_title ("CDEF");
        cdef_row.set_subtitle ("Constrained Directional Enhancement Filter — reduces ringing artifacts");
        cdef_switch = new Switch ();
        cdef_switch.set_valign (Align.CENTER);
        cdef_switch.set_active (false);
        cdef_row.add_suffix (cdef_switch);
        cdef_row.set_activatable_widget (cdef_switch);
        group.add (cdef_row);

        // Loop Restoration
        var restore_row = new Adw.ActionRow ();
        restore_row.set_title ("Loop Restoration");
        restore_row.set_subtitle ("One of the strongest quality features in SVT-AV1 — highly recommended");
        restoration_switch = new Switch ();
        restoration_switch.set_valign (Align.CENTER);
        restoration_switch.set_active (false);
        restore_row.add_suffix (restoration_switch);
        restore_row.set_activatable_widget (restoration_switch);
        group.add (restore_row);

        // Deblocking Filter (ExpanderRow)
        dlf_expander = new Adw.ExpanderRow ();
        dlf_expander.set_title ("Deblocking Filter");
        dlf_expander.set_subtitle ("Reduces blocking artifacts at transform boundaries");
        dlf_expander.set_show_enable_switch (true);
        dlf_expander.set_enable_expansion (false);

        var dlf_mode_row = new Adw.ActionRow ();
        dlf_mode_row.set_title ("Mode");
        dlf_mode_combo = new DropDown (new StringList ({
            "Standard", "Strong"
        }), null);
        dlf_mode_combo.set_valign (Align.CENTER);
        dlf_mode_combo.set_selected (0);
        dlf_mode_row.add_suffix (dlf_mode_combo);
        dlf_expander.add_row (dlf_mode_row);
        group.add (dlf_expander);

        // Temporal Filtering
        var tf_row = new Adw.ActionRow ();
        tf_row.set_title ("Temporal Filtering");
        tf_row.set_subtitle ("Smooths motion for better compression — good for noisy videos");
        tf_switch = new Switch ();
        tf_switch.set_valign (Align.CENTER);
        tf_switch.set_active (false);
        tf_row.add_suffix (tf_switch);
        tf_row.set_activatable_widget (tf_switch);
        group.add (tf_row);

        append (group);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  ADVANCED
    // ═══════════════════════════════════════════════════════════════════════════

    private void build_advanced_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Advanced");
        group.set_description ("Fine-grained encoder control");

        // Spatio-Temporal Prediction
        var tpl_row = new Adw.ActionRow ();
        tpl_row.set_title ("Spatio-Temporal Prediction");
        tpl_row.set_subtitle ("Improves quality ~3–5% at cost of speed");
        tpl_switch = new Switch ();
        tpl_switch.set_valign (Align.CENTER);
        tpl_switch.set_active (false);
        tpl_row.add_suffix (tpl_switch);
        tpl_row.set_activatable_widget (tpl_switch);
        group.add (tpl_row);

        // Low Latency
        var ll_row = new Adw.ActionRow ();
        ll_row.set_title ("Low Latency");
        ll_row.set_subtitle ("Reduces delay for live streaming — disables lookahead");
        low_latency_switch = new Switch ();
        low_latency_switch.set_valign (Align.CENTER);
        low_latency_switch.set_active (false);
        ll_row.add_suffix (low_latency_switch);
        ll_row.set_activatable_widget (low_latency_switch);
        group.add (ll_row);

        // Super-Resolution (ExpanderRow)
        superres_expander = new Adw.ExpanderRow ();
        superres_expander.set_title ("Super-Resolution");
        superres_expander.set_subtitle ("Internal upscaling for better quality at low bitrates");
        superres_expander.set_show_enable_switch (true);
        superres_expander.set_enable_expansion (false);

        var sr_mode_row = new Adw.ActionRow ();
        sr_mode_row.set_title ("Mode");
        superres_mode_combo = new DropDown (new StringList ({
            "1 — Fastest", "2 — Fast", "3 — All", "4 — Random"
        }), null);
        superres_mode_combo.set_valign (Align.CENTER);
        superres_mode_combo.set_selected (0);
        sr_mode_row.add_suffix (superres_mode_combo);
        superres_expander.add_row (sr_mode_row);

        var sr_denom_row = new Adw.ActionRow ();
        sr_denom_row.set_title ("Denominator");
        sr_denom_row.set_subtitle ("Higher = more upscaling (8–16)");
        superres_denom_spin = new SpinButton.with_range (8, 16, 1);
        superres_denom_spin.set_value (8);
        superres_denom_spin.set_valign (Align.CENTER);
        sr_denom_row.add_suffix (superres_denom_spin);
        superres_expander.add_row (sr_denom_row);
        group.add (superres_expander);

        // SVT Sharpness (ExpanderRow)
        sharpness_expander = new Adw.ExpanderRow ();
        sharpness_expander.set_title ("SVT Sharpness");
        sharpness_expander.set_subtitle ("Built-in detail preservation — more natural than FFmpeg unsharp");
        sharpness_expander.set_show_enable_switch (true);
        sharpness_expander.set_enable_expansion (false);

        var sharp_level_row = new Adw.ActionRow ();
        sharp_level_row.set_title ("Level");
        sharp_level_row.set_subtitle ("Higher = more detail preservation (0–7)");
        sharpness_spin = new SpinButton.with_range (0, 7, 1);
        sharpness_spin.set_value (1);
        sharpness_spin.set_valign (Align.CENTER);
        sharp_level_row.add_suffix (sharpness_spin);
        sharpness_expander.add_row (sharp_level_row);
        group.add (sharpness_expander);

        // Screen Content Mode
        var scm_row = new Adw.ActionRow ();
        scm_row.set_title ("Screen Content Mode");
        scm_row.set_subtitle ("Optimizes for screen recordings and graphics");
        scm_combo = new DropDown (new StringList ({
            "Disabled", "Forced", "Auto-Detect"
        }), null);
        scm_combo.set_valign (Align.CENTER);
        scm_combo.set_selected (0);
        scm_row.add_suffix (scm_combo);
        group.add (scm_row);

        // Fast Decode
        var fd_row = new Adw.ActionRow ();
        fd_row.set_title ("Fast Decode");
        fd_row.set_subtitle ("Speeds up playback decoding — may reduce quality");
        fast_decode_combo = new DropDown (new StringList ({
            "Disabled", "Level 1", "Level 2"
        }), null);
        fast_decode_combo.set_valign (Align.CENTER);
        fast_decode_combo.set_selected (0);
        fd_row.add_suffix (fast_decode_combo);
        group.add (fd_row);

        // Quantization Matrices (ExpanderRow)
        qm_expander = new Adw.ExpanderRow ();
        qm_expander.set_title ("Quantization Matrices");
        qm_expander.set_subtitle ("Custom QM levels for advanced quality control");
        qm_expander.set_show_enable_switch (true);
        qm_expander.set_enable_expansion (false);

        var qm_min_row = new Adw.ActionRow ();
        qm_min_row.set_title ("QM Min");
        qm_min_row.set_subtitle ("Minimum quantization matrix level (0–15)");
        qm_min_spin = new SpinButton.with_range (0, 15, 1);
        qm_min_spin.set_value (8);
        qm_min_spin.set_valign (Align.CENTER);
        qm_min_row.add_suffix (qm_min_spin);
        qm_expander.add_row (qm_min_row);

        var qm_max_row = new Adw.ActionRow ();
        qm_max_row.set_title ("QM Max");
        qm_max_row.set_subtitle ("Maximum quantization matrix level (0–15)");
        qm_max_spin = new SpinButton.with_range (0, 15, 1);
        qm_max_spin.set_value (11);
        qm_max_spin.set_valign (Align.CENTER);
        qm_max_row.add_suffix (qm_max_spin);
        qm_expander.add_row (qm_max_row);
        group.add (qm_expander);

        append (group);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  THREADING & KEYFRAMES
    // ═══════════════════════════════════════════════════════════════════════════

    private void build_audio_group () {
        audio_settings = new AudioSettings ();
        append (audio_settings.get_widget ());
    }
    
    private void build_threading_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Threading & Keyframes");

        // Keyframe Interval
        var keyint_row = new Adw.ActionRow ();
        keyint_row.set_title ("Keyframe Interval");
        keyint_row.set_subtitle ("Higher = smaller file, slower seeking");
        keyint_combo = new DropDown (new StringList ({
            "Auto", "Custom", "30", "60", "120", "240", "360", "480", "720", "960", "1440", "1920"
        }), null);
        keyint_combo.set_valign (Align.CENTER);
        keyint_combo.set_selected (0);
        keyint_row.add_suffix (keyint_combo);
        group.add (keyint_row);

        // Custom Keyframe Mode (visible only when "Custom" is selected)
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

        // Tile Rows
        var trows_row = new Adw.ActionRow ();
        trows_row.set_title ("Tile Rows");
        trows_row.set_subtitle ("Splits frame vertically for parallel encoding");
        tile_rows_combo = new DropDown (new StringList ({
            "Auto", "1", "2", "4", "8"
        }), null);
        tile_rows_combo.set_valign (Align.CENTER);
        tile_rows_combo.set_selected (0);
        trows_row.add_suffix (tile_rows_combo);
        group.add (trows_row);

        // Tile Columns
        var tcols_row = new Adw.ActionRow ();
        tcols_row.set_title ("Tile Columns");
        tcols_row.set_subtitle ("Splits frame horizontally for parallel encoding");
        tile_columns_combo = new DropDown (new StringList ({
            "Auto", "1", "2", "4", "8"
        }), null);
        tile_columns_combo.set_valign (Align.CENTER);
        tile_columns_combo.set_selected (0);
        tcols_row.add_suffix (tile_columns_combo);
        group.add (tcols_row);

        append (group);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  RESET BUTTON
    // ═══════════════════════════════════════════════════════════════════════════

    private void build_reset_button () {
        var reset_box = new Box (Orientation.HORIZONTAL, 0);
        reset_box.set_halign (Align.END);
        reset_box.set_margin_top (8);

        var reset_btn = new Button.with_label ("Reset to Defaults");
        reset_btn.add_css_class ("destructive-action");
        reset_btn.clicked.connect (reset_defaults);
        reset_box.append (reset_btn);

        append (reset_box);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  SIGNALS
    // ═══════════════════════════════════════════════════════════════════════════

    private void connect_signals () {
        // Rate control mode → show/hide appropriate value row
        rc_mode_combo.notify["selected"].connect (update_rc_visibility);
        update_rc_visibility ();

        // AQ Mode → enable/disable strength
        aq_mode_combo.notify["selected"].connect (() => {
            string mode = get_dropdown_text (aq_mode_combo);
            aq_strength_row.set_sensitive (mode == "Variance");
        });

        // Low latency ↔ lookahead mutual exclusion
        low_latency_switch.notify["active"].connect (() => {
            if (low_latency_switch.active && lookahead_expander.enable_expansion) {
                lookahead_expander.set_enable_expansion (false);
            }
        });
        lookahead_expander.notify["enable-expansion"].connect (() => {
            if (lookahead_expander.enable_expansion && low_latency_switch.active) {
                low_latency_switch.set_active (false);
            }
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
        vbr_row.set_visible (mode == "VBR");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    public string get_dropdown_text (DropDown dropdown) {
        var item = dropdown.selected_item as StringObject;
        return item != null ? item.string : "";
    }

    public string get_container () {
        return get_dropdown_text (container_combo);
    }

    public ICodecBuilder get_codec_builder () {
        return new SvtAv1Builder ();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  RESET
    // ═══════════════════════════════════════════════════════════════════════════

    public void reset_defaults () {
        // Encoding
        container_combo.set_selected (0);
        preset_spin.set_value (8);

        // Rate Control
        rc_mode_combo.set_selected (0);
        crf_spin.set_value (28);
        qp_spin.set_value (28);
        vbr_bitrate_spin.set_value (2000);
        two_pass_check.set_active (false);
        two_pass_switch.set_active (false);

        // Quality & Tuning
        tune_combo.set_selected (0);
        level_combo.set_selected (0);
        lookahead_expander.set_enable_expansion (false);
        lookahead_spin.set_value (35);
        aq_mode_combo.set_selected (0);
        aq_strength_spin.set_value (2);

        // Film Grain
        grain_expander.set_enable_expansion (false);
        grain_strength_spin.set_value (0);
        grain_denoise_combo.set_selected (0);

        // In-Loop Filters
        cdef_switch.set_active (false);
        restoration_switch.set_active (false);
        dlf_expander.set_enable_expansion (false);
        dlf_mode_combo.set_selected (0);
        tf_switch.set_active (false);

        // Advanced
        tpl_switch.set_active (false);
        low_latency_switch.set_active (false);
        superres_expander.set_enable_expansion (false);
        superres_mode_combo.set_selected (0);
        superres_denom_spin.set_value (8);
        sharpness_expander.set_enable_expansion (false);
        sharpness_spin.set_value (1);
        scm_combo.set_selected (0);
        fast_decode_combo.set_selected (0);
        qm_expander.set_enable_expansion (false);
        qm_min_spin.set_value (8);
        qm_max_spin.set_value (11);

	audio_settings.reset_defaults ();

        // Threading & Keyframes
        keyint_combo.set_selected (0);
        custom_keyframe_combo.set_selected (3);
        threads_combo.set_selected (0);
        tile_rows_combo.set_selected (0);
        tile_columns_combo.set_selected (0);

        update_rc_visibility ();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  CUSTOM KEYFRAME RESOLUTION
    // ═══════════════════════════════════════════════════════════════════════════

    // Called from ConversionRunner on the encoding thread.
    // Returns the FFmpeg args for keyframe placement, or {} if the builder
    // already handles it (i.e. the user picked a numeric interval or Auto).
    public string[] resolve_keyframe_args (string input_file, GeneralTab general_tab) {
        string keyint = get_dropdown_text (keyint_combo);

        // Not "Custom" — the builder emits -g for numeric values
        if (keyint != "Custom")
            return {};

        int mode = (int) custom_keyframe_combo.get_selected ();
        // 0 = 2 s fixed, 1 = 2 s × fps, 2 = 5 s fixed, 3 = 5 s × fps
        int seconds = (mode == 0 || mode == 1) ? 2 : 5;
        bool use_fixed_time = (mode == 0 || mode == 2);

        if (use_fixed_time) {
            return { "-force_key_frames",
                     @"expr:gte(t,n_forced*$seconds)" };
        }

        // ── fps-based: check General tab first, then probe ───────────────────
        double fps = 0.0;

        string fr_text = get_dropdown_text (general_tab.frame_rate_combo);
        if (fr_text == "Custom") {
            string custom_fr = general_tab.custom_frame_rate.text.strip ();
            if (custom_fr.length > 0)
                fps = double.parse (custom_fr);
        } else if (fr_text != "Original") {
            fps = double.parse (fr_text);
        }

        // If still unknown, probe the input file
        if (fps < 5.0)
            fps = probe_input_fps (input_file);

        // Sanity — fall back to a safe default
        if (fps < 5.0 || fps > 500.0)
            return { "-g", "240" };

        int gop = (int) Math.round (seconds * fps);
        if (gop < 10) gop = 240;

        return { "-g", gop.to_string () };
    }

    // Runs ffprobe synchronously to extract the frame rate from the input file.
    // Safe to call from a background thread.
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

            // Typical output: "24000/1001" or "30/1" or "29.97"
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
            // probe failed — caller uses fallback
        }
        return 0.0;
    }
}
