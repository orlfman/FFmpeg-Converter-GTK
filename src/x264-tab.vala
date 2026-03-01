using Gtk;
using Adw;
using GLib;

public class X264Tab : Box, ICodecTab {

    // ── Encoding ─────────────────────────────────────────────────────────────
    public DropDown  container_combo    { get; private set; }
    public DropDown  preset_combo       { get; private set; }
    public DropDown  profile_combo      { get; private set; }

    // ── Rate Control ─────────────────────────────────────────────────────────
    public DropDown   rc_mode_combo     { get; private set; }
    public SpinButton crf_spin          { get; private set; }
    public SpinButton qp_spin           { get; private set; }
    public SpinButton abr_bitrate_spin  { get; private set; }
    public Switch     abr_vbv_switch    { get; private set; }
    public SpinButton cbr_bitrate_spin  { get; private set; }
    public CheckButton two_pass_check   { get; private set; }

    private Switch two_pass_switch;
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

    // ── Motion Estimation ────────────────────────────────────────────────────
    public DropDown   me_combo          { get; private set; }
    public SpinButton me_range_spin     { get; private set; }
    public DropDown   subme_combo       { get; private set; }

    // ── Advanced ─────────────────────────────────────────────────────────────
    public DropDown   ref_frames_combo  { get; private set; }
    public SpinButton bframes_spin      { get; private set; }
    public DropDown   b_adapt_combo     { get; private set; }
    public Switch     weightp_switch    { get; private set; }
    public Switch     cabac_switch      { get; private set; }
    public Switch     mbtree_switch     { get; private set; }
    public Switch     fast_decode_switch { get; private set; }
    public Switch     open_gop_switch   { get; private set; }

    // Deblock
    public Adw.ExpanderRow deblock_expander { get; private set; }
    public SpinButton deblock_alpha_spin { get; private set; }
    public SpinButton deblock_beta_spin  { get; private set; }

    // Psy-RD
    public Adw.ExpanderRow psy_rd_expander { get; private set; }
    public SpinButton psy_rd_spin       { get; private set; }
    public SpinButton psy_trellis_spin  { get; private set; }

    // ── Audio ────────────────────────────────────────────────────────────────
    public AudioSettings audio_settings  { get; private set; }

    // ── Threading & Keyframes ────────────────────────────────────────────────
    public DropDown  keyint_combo        { get; private set; }
    public DropDown  custom_keyframe_combo { get; private set; }
    public DropDown  threads_combo       { get; private set; }

    private Adw.ActionRow custom_keyframe_row;

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public X264Tab () {
        Object (orientation: Orientation.VERTICAL, spacing: 24);
        set_margin_top (24);
        set_margin_bottom (24);
        set_margin_start (24);
        set_margin_end (24);

        build_encoding_group ();
        build_rate_control_group ();
        build_quality_group ();
        build_motion_group ();
        build_advanced_group ();
        build_audio_group ();
        build_threading_group ();
        build_reset_button ();

        connect_signals ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ENCODING
    // ═════════════════════════════════════════════════════════════════════════

    private void build_encoding_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Encoding");
        group.set_description ("Core x264 encoder settings");

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
        preset_combo.set_selected (5);   // medium
        preset_row.add_suffix (preset_combo);
        group.add (preset_row);

        // Profile
        var profile_row = new Adw.ActionRow ();
        profile_row.set_title ("Profile");
        profile_row.set_subtitle ("Higher profiles support more features — Auto selects based on settings");
        profile_combo = new DropDown (new StringList ({
            "Auto", "Baseline", "Main", "High", "High10"
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
        crf_row.set_subtitle ("Lower = better quality (0–51, default 23)");
        crf_spin = new SpinButton.with_range (0, 51, 1);
        crf_spin.set_value (23);
        crf_spin.set_valign (Align.CENTER);
        crf_row.add_suffix (crf_spin);
        group.add (crf_row);

        // QP value
        qp_row = new Adw.ActionRow ();
        qp_row.set_title ("QP Value");
        qp_row.set_subtitle ("Fixed quantization parameter (0–69, default 23)");
        qp_spin = new SpinButton.with_range (0, 69, 1);
        qp_spin.set_value (23);
        qp_spin.set_valign (Align.CENTER);
        qp_row.add_suffix (qp_spin);
        qp_row.set_visible (false);
        group.add (qp_row);

        // ABR bitrate
        abr_row = new Adw.ActionRow ();
        abr_row.set_title ("Average Bitrate");
        abr_row.set_subtitle ("Target average bitrate in kbps (100–50000)");
        abr_bitrate_spin = new SpinButton.with_range (100, 50000, 100);
        abr_bitrate_spin.set_value (2000);
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
        cbr_row.set_subtitle ("Fixed bitrate in kbps (100–50000)");
        cbr_bitrate_spin = new SpinButton.with_range (100, 50000, 100);
        cbr_bitrate_spin.set_value (2000);
        cbr_bitrate_spin.set_valign (Align.CENTER);
        cbr_row.add_suffix (cbr_bitrate_spin);
        cbr_row.set_visible (false);
        group.add (cbr_row);

        // Two-pass
        two_pass_row = new Adw.ActionRow ();
        two_pass_row.set_title ("Two-Pass Encoding");
        two_pass_row.set_subtitle ("Better quality — available for ABR and CBR modes");

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

        // Tune
        var tune_row = new Adw.ActionRow ();
        tune_row.set_title ("Tune");
        tune_row.set_subtitle ("Optimize for specific content types");
        tune_combo = new DropDown (new StringList ({
            "Auto", "film", "animation", "grain", "stillimage",
            "psnr", "ssim", "fastdecode", "zerolatency"
        }), null);
        tune_combo.set_valign (Align.CENTER);
        tune_combo.set_selected (0);
        tune_row.add_suffix (tune_combo);
        group.add (tune_row);

        // Level
        var level_row = new Adw.ActionRow ();
        level_row.set_title ("Level");
        level_row.set_subtitle ("Constrains resolution, bitrate, and buffers for compatibility");
        level_combo = new DropDown (new StringList ({
            "Auto", "1", "1.1", "1.2", "1.3",
            "2", "2.1", "2.2",
            "3", "3.1", "3.2",
            "4", "4.1", "4.2",
            "5", "5.1", "5.2"
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
            "Automatic", "Disabled", "Variance", "Auto-Variance", "Auto-Variance Biased"
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
    //  MOTION ESTIMATION
    // ═════════════════════════════════════════════════════════════════════════

    private void build_motion_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Motion Estimation");
        group.set_description ("Controls how the encoder searches for motion between frames");

        // ME Algorithm
        var me_row = new Adw.ActionRow ();
        me_row.set_title ("Algorithm");
        me_row.set_subtitle ("Higher quality algorithms are slower but find better matches");
        me_combo = new DropDown (new StringList ({
            "dia", "hex", "umh", "esa", "tesa"
        }), null);
        me_combo.set_valign (Align.CENTER);
        me_combo.set_selected (1);   // hex — x264 default
        me_row.add_suffix (me_combo);
        group.add (me_row);

        // ME Range
        var mer_row = new Adw.ActionRow ();
        mer_row.set_title ("Search Range");
        mer_row.set_subtitle ("Pixel radius for motion search (4–64, default 16)");
        me_range_spin = new SpinButton.with_range (4, 64, 1);
        me_range_spin.set_value (16);
        me_range_spin.set_valign (Align.CENTER);
        mer_row.add_suffix (me_range_spin);
        group.add (mer_row);

        // Subpixel Refinement
        var subme_row = new Adw.ActionRow ();
        subme_row.set_title ("Subpixel Refinement");
        subme_row.set_subtitle ("Higher = sharper motion compensation, slower (0–11)");
        subme_combo = new DropDown (new StringList ({
            "0 — Fullpel only",
            "1 — QPel SAD",
            "2 — QPel SATD",
            "3 — HPel + QPel",
            "4 — Always QPel",
            "5 — Multi QPel",
            "6 — RD on I/P",
            "7 — RD on all",
            "8 — RD refine I/P",
            "9 — RD refine all",
            "10 — QP-RD",
            "11 — Full RD"
        }), null);
        subme_combo.set_valign (Align.CENTER);
        subme_combo.set_selected (7);   // x264 default
        subme_row.add_suffix (subme_combo);
        group.add (subme_row);

        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ADVANCED
    // ═════════════════════════════════════════════════════════════════════════

    private void build_advanced_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Advanced");

        // Reference Frames
        var ref_row = new Adw.ActionRow ();
        ref_row.set_title ("Reference Frames");
        ref_row.set_subtitle ("More = better compression, slower encoding (1–16)");
        ref_frames_combo = new DropDown (new StringList (
            { "1", "2", "3", "4", "5", "6", "8", "12", "16" }
        ), null);
        ref_frames_combo.set_valign (Align.CENTER);
        ref_frames_combo.set_selected (2);   // 3 — x264 default
        ref_row.add_suffix (ref_frames_combo);
        group.add (ref_row);

        // B-Frames
        var bf_row = new Adw.ActionRow ();
        bf_row.set_title ("B-Frames");
        bf_row.set_subtitle ("Consecutive bidirectional frames (0–16, default 3)");
        bframes_spin = new SpinButton.with_range (0, 16, 1);
        bframes_spin.set_value (3);
        bframes_spin.set_valign (Align.CENTER);
        bf_row.add_suffix (bframes_spin);
        group.add (bf_row);

        // B-Frame Adaptation
        var ba_row = new Adw.ActionRow ();
        ba_row.set_title ("B-Frame Adaptation");
        ba_row.set_subtitle ("How the encoder decides where to place B-frames");
        b_adapt_combo = new DropDown (new StringList ({
            "Disabled", "Fast", "Optimal"
        }), null);
        b_adapt_combo.set_valign (Align.CENTER);
        b_adapt_combo.set_selected (1);   // Fast — x264 default
        ba_row.add_suffix (b_adapt_combo);
        group.add (ba_row);

        // Weighted Prediction
        var wp_row = new Adw.ActionRow ();
        wp_row.set_title ("Weighted Prediction");
        wp_row.set_subtitle ("Improves fades and scene transitions");
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
        alpha_row.set_title ("Alpha");
        alpha_row.set_subtitle ("In-loop filter strength (−6 to +6, default 0)");
        deblock_alpha_spin = new SpinButton.with_range (-6, 6, 1);
        deblock_alpha_spin.set_value (0);
        deblock_alpha_spin.set_valign (Align.CENTER);
        alpha_row.add_suffix (deblock_alpha_spin);
        deblock_expander.add_row (alpha_row);

        var beta_row = new Adw.ActionRow ();
        beta_row.set_title ("Beta");
        beta_row.set_subtitle ("Block boundary threshold (−6 to +6, default 0)");
        deblock_beta_spin = new SpinButton.with_range (-6, 6, 1);
        deblock_beta_spin.set_value (0);
        deblock_beta_spin.set_valign (Align.CENTER);
        beta_row.add_suffix (deblock_beta_spin);
        deblock_expander.add_row (beta_row);
        group.add (deblock_expander);

        // Psy-RD (ExpanderRow with RD + Trellis)
        psy_rd_expander = new Adw.ExpanderRow ();
        psy_rd_expander.set_title ("Psychovisual Optimization");
        psy_rd_expander.set_subtitle ("Tunes decisions for perceptual quality rather than raw metrics");
        psy_rd_expander.set_show_enable_switch (true);
        psy_rd_expander.set_enable_expansion (true);

        var psy_rd_row = new Adw.ActionRow ();
        psy_rd_row.set_title ("Psy-RD Strength");
        psy_rd_row.set_subtitle ("Rate-distortion optimization (0.0–2.0, default 1.0)");
        psy_rd_spin = new SpinButton.with_range (0.0, 2.0, 0.1);
        psy_rd_spin.set_digits (1);
        psy_rd_spin.set_value (1.0);
        psy_rd_spin.set_valign (Align.CENTER);
        psy_rd_row.add_suffix (psy_rd_spin);
        psy_rd_expander.add_row (psy_rd_row);

        var psy_trellis_row = new Adw.ActionRow ();
        psy_trellis_row.set_title ("Psy-Trellis");
        psy_trellis_row.set_subtitle ("Trellis quantization tuning (0.0–2.0, default 0.0)");
        psy_trellis_spin = new SpinButton.with_range (0.0, 2.0, 0.05);
        psy_trellis_spin.set_digits (2);
        psy_trellis_spin.set_value (0.0);
        psy_trellis_spin.set_valign (Align.CENTER);
        psy_trellis_row.add_suffix (psy_trellis_spin);
        psy_rd_expander.add_row (psy_trellis_row);
        group.add (psy_rd_expander);

        // CABAC
        var cabac_row = new Adw.ActionRow ();
        cabac_row.set_title ("CABAC");
        cabac_row.set_subtitle ("Context-Adaptive Binary Arithmetic Coding — ~10–15% better compression");
        cabac_switch = new Switch ();
        cabac_switch.set_valign (Align.CENTER);
        cabac_switch.set_active (true);
        cabac_row.add_suffix (cabac_switch);
        cabac_row.set_activatable_widget (cabac_switch);
        group.add (cabac_row);

        // MB-Tree
        var mbtree_row = new Adw.ActionRow ();
        mbtree_row.set_title ("MB-Tree");
        mbtree_row.set_subtitle ("Macroblock-tree rate control for smarter bit allocation");
        mbtree_switch = new Switch ();
        mbtree_switch.set_valign (Align.CENTER);
        mbtree_switch.set_active (true);
        mbtree_row.add_suffix (mbtree_switch);
        mbtree_row.set_activatable_widget (mbtree_switch);
        group.add (mbtree_row);

        // Fast Decode
        var fd_row = new Adw.ActionRow ();
        fd_row.set_title ("Fast Decode");
        fd_row.set_subtitle ("Disables CABAC and loop filter for faster playback on weak devices");
        fast_decode_switch = new Switch ();
        fast_decode_switch.set_valign (Align.CENTER);
        fast_decode_switch.set_active (false);
        fd_row.add_suffix (fast_decode_switch);
        fd_row.set_activatable_widget (fast_decode_switch);
        group.add (fd_row);

        // Open GOP
        var ogop_row = new Adw.ActionRow ();
        ogop_row.set_title ("Open GOP");
        ogop_row.set_subtitle ("Allows B-frames to reference across GOPs — smaller files, less seeking precision");
        open_gop_switch = new Switch ();
        open_gop_switch.set_valign (Align.CENTER);
        open_gop_switch.set_active (false);
        ogop_row.add_suffix (open_gop_switch);
        ogop_row.set_activatable_widget (open_gop_switch);
        group.add (ogop_row);

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
        // Rate control mode → show/hide rows
        rc_mode_combo.notify["selected"].connect (update_rc_visibility);
        update_rc_visibility ();

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

        // Fast decode ↔ CABAC mutual exclusion
        fast_decode_switch.notify["active"].connect (() => {
            if (fast_decode_switch.active) {
                cabac_switch.set_active (false);
                deblock_expander.set_enable_expansion (false);
            }
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
    //  HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    public string get_dropdown_text (DropDown dropdown) {
        var item = dropdown.selected_item as StringObject;
        return item != null ? item.string : "";
    }

    public string get_container () {
        return get_dropdown_text (container_combo);
    }

    public string get_active_preset () {
        return get_dropdown_text (preset_combo);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ICodecTab INTERFACE
    // ═════════════════════════════════════════════════════════════════════════

    public ICodecBuilder get_codec_builder () {
        return new X264Builder ();
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
        preset_combo.set_selected (5);
        profile_combo.set_selected (0);

        // Rate Control
        rc_mode_combo.set_selected (0);
        crf_spin.set_value (23);
        qp_spin.set_value (23);
        abr_bitrate_spin.set_value (2000);
        abr_vbv_switch.set_active (false);
        cbr_bitrate_spin.set_value (2000);
        two_pass_check.set_active (false);
        two_pass_switch.set_active (false);

        // Quality & Tuning
        tune_combo.set_selected (0);
        level_combo.set_selected (0);
        lookahead_expander.set_enable_expansion (false);
        lookahead_spin.set_value (40);
        aq_mode_combo.set_selected (0);
        aq_strength_spin.set_value (1.0);

        // Motion Estimation
        me_combo.set_selected (1);
        me_range_spin.set_value (16);
        subme_combo.set_selected (7);

        // Advanced
        ref_frames_combo.set_selected (2);
        bframes_spin.set_value (3);
        b_adapt_combo.set_selected (1);
        weightp_switch.set_active (true);
        deblock_expander.set_enable_expansion (true);
        deblock_alpha_spin.set_value (0);
        deblock_beta_spin.set_value (0);
        psy_rd_expander.set_enable_expansion (true);
        psy_rd_spin.set_value (1.0);
        psy_trellis_spin.set_value (0.0);
        cabac_switch.set_active (true);
        mbtree_switch.set_active (true);
        fast_decode_switch.set_active (false);
        open_gop_switch.set_active (false);

        // Audio
        audio_settings.reset_defaults ();

        // Threading & Keyframes
        keyint_combo.set_selected (0);
        custom_keyframe_combo.set_selected (3);
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
