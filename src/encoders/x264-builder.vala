using Gtk;

public class X264BuilderSnapshot : Object {
    public string preset = "medium";
    public string profile = "Auto";
    public string rc_mode = RateControl.CRF;
    public int crf = 23;
    public int qp = 23;
    public int abr_bitrate_kbps = 1000;
    public int cbr_bitrate_kbps = 1000;
    public string tune = "Auto";
    public string level = "Auto";
    public string keyint_text = "Auto";
    public string ref_frames = "";
    public int bframes = 3;
    public int b_adapt = 1;
    public bool weightp = true;
    public bool deblock_enabled = false;
    public int deblock_alpha = 0;
    public int deblock_beta = 0;
    public string me = "";
    public int me_range = 16;
    public int subme = 7;
    public bool psy_rd_enabled = false;
    public double psy_rd = 1.0;
    public double psy_trellis = 0.0;
    public bool cabac = true;
    public bool mbtree = true;
    public bool lookahead_enabled = false;
    public int lookahead = 40;
    public string aq_mode = "Automatic";
    public double aq_strength = 1.0;
    public bool abr_vbv = false;
    public bool open_gop = false;
    public string threads = "Auto";
    public GeneralSettingsSnapshot? general_settings { get; set; default = null; }
}

public class X264Builder : Object, ICodecBuilder {

    private const int X264_DEFAULT_BFRAMES = 3;
    private const int X264_DEFAULT_B_ADAPT = 1;
    private const string X264_DEFAULT_ME = "hex";
    private const string X264_DEFAULT_PSY_RD = "psy-rd=1.0,0.00";
    private const int X264_SUBME_NEEDS_TRELLIS_2 = 10;

    private static string format_psy_rd (double psy_rd, double psy_trellis) {
        return "psy-rd=%s,%s".printf (
            ConversionUtils.format_ffmpeg_double (psy_rd, "%.1f"),
            ConversionUtils.format_ffmpeg_double (psy_trellis, "%.2f"));
    }

    /**
     * Whether psy-rd/psy-trellis differ from x264's defaults (1.0, 0.0).
     * At the defaults the selected -tune keeps its own values.
     */
    public static bool psy_differs_from_default (double psy_rd, double psy_trellis) {
        return format_psy_rd (psy_rd, psy_trellis) != X264_DEFAULT_PSY_RD;
    }

    /**
     * The x264 parameters Smart Codec's EncoderTuning decides, written the
     * way build_args_from_snapshot writes them. Calibration and the trim
     * tab's direct arguments use this so they encode what the tab will.
     */
    public static string[] smart_tuning_params (int deblock_offset, int subme,
                                                double psy_trellis) {
        string[] params = {};
        if (deblock_offset != 0)
            params += @"deblock=$deblock_offset,$deblock_offset";
        if (subme > 0 && subme != 7)
            params += "subme=" + subme.to_string ();
        if (subme >= X264_SUBME_NEEDS_TRELLIS_2)
            params += "trellis=2";
        if (psy_differs_from_default (1.0, psy_trellis))
            params += format_psy_rd (1.0, psy_trellis);
        return params;
    }

    private weak X264Tab tab;

    public X264Builder (X264Tab tab) {
        this.tab = tab;
    }

    public string get_codec_name () {
        return "x264";
    }

    public Object? snapshot_settings (
        GeneralSettingsSnapshot? general_settings = null) {
        var snapshot = new X264BuilderSnapshot ();
        snapshot.preset = tab.get_active_preset ();
        snapshot.profile = CodecUtils.get_dropdown_text (tab.profile_combo);
        snapshot.rc_mode = CodecUtils.get_dropdown_text (tab.rc_mode_combo);
        snapshot.crf = (int) tab.crf_spin.get_value ();
        snapshot.qp = (int) tab.qp_spin.get_value ();
        snapshot.abr_bitrate_kbps = (int) tab.abr_bitrate_spin.get_value ();
        snapshot.cbr_bitrate_kbps = (int) tab.cbr_bitrate_spin.get_value ();
        snapshot.tune = CodecUtils.get_dropdown_text (tab.tune_combo);
        snapshot.level = CodecUtils.get_dropdown_text (tab.level_combo);
        snapshot.keyint_text = CodecUtils.get_dropdown_text (tab.keyint_combo);
        snapshot.ref_frames = CodecUtils.get_dropdown_text (tab.ref_frames_combo);
        snapshot.bframes = (int) tab.bframes_spin.get_value ();
        snapshot.b_adapt = (int) tab.b_adapt_combo.get_selected ();
        snapshot.weightp = tab.weightp_switch.active;
        snapshot.deblock_enabled = tab.deblock_expander.enable_expansion;
        snapshot.deblock_alpha = (int) tab.deblock_alpha_spin.get_value ();
        snapshot.deblock_beta = (int) tab.deblock_beta_spin.get_value ();
        snapshot.me = CodecUtils.get_dropdown_text (tab.me_combo);
        snapshot.me_range = (int) tab.me_range_spin.get_value ();
        snapshot.subme = (int) tab.subme_combo.get_selected ();
        snapshot.psy_rd_enabled = tab.psy_rd_expander.enable_expansion;
        snapshot.psy_rd = tab.psy_rd_spin.get_value ();
        snapshot.psy_trellis = tab.psy_trellis_spin.get_value ();
        snapshot.cabac = tab.cabac_switch.active;
        snapshot.mbtree = tab.mbtree_switch.active;
        snapshot.lookahead_enabled = tab.lookahead_expander.enable_expansion;
        snapshot.lookahead = (int) tab.lookahead_spin.get_value ();
        snapshot.aq_mode = CodecUtils.get_dropdown_text (tab.aq_mode_combo);
        snapshot.aq_strength = tab.aq_strength_spin.get_value ();
        snapshot.abr_vbv = tab.abr_vbv_switch.active;
        snapshot.open_gop = tab.open_gop_switch.active;
        snapshot.threads = CodecUtils.get_dropdown_text (tab.threads_combo);

        snapshot.general_settings = general_settings;

        return snapshot;
    }

    public string[] build_codec_args_from_snapshot (Object? builder_snapshot) {
        var snapshot = builder_snapshot as X264BuilderSnapshot;
        if (snapshot == null)
            return {};
        return build_args_from_snapshot (snapshot);
    }

    public string[] get_codec_args () {
        return build_codec_args_from_snapshot (snapshot_settings ());
    }

    public static string[] build_args_from_snapshot (X264BuilderSnapshot snapshot) {
        string[] args = {};

        // ── Codec + Preset ─────────────────────────────────────────────────
        args += "-c:v";
        args += "libx264";
        args += "-preset";
        args += snapshot.preset;

        // ── Profile ────────────────────────────────────────────────────────
        string profile = snapshot.profile;
        if (profile != "Auto" && profile.length > 0) {
            args += "-profile:v";
            args += profile.down ();

            string forced_pix_fmt = CodecUtils.get_x264_profile_pix_fmt_from_snapshot (
                profile, snapshot.general_settings);
            if (forced_pix_fmt.length > 0) {
                args += "-pix_fmt";
                args += forced_pix_fmt;
            }
        }

        // ── Rate Control ──────────────────────────────────────────────────
        string rc_mode = snapshot.rc_mode;

        if (rc_mode == RateControl.CRF) {
            args += "-crf";
            args += snapshot.crf.to_string ();
        } else if (rc_mode == RateControl.QP) {
            args += "-qp";
            args += snapshot.qp.to_string ();
        } else if (rc_mode == RateControl.ABR) {
            args += "-b:v";
            args += snapshot.abr_bitrate_kbps.to_string () + "k";
        } else if (rc_mode == RateControl.CBR) {
            args += "-b:v";
            args += snapshot.cbr_bitrate_kbps.to_string () + "k";
        }

        // ── Tune ───────────────────────────────────────────────────────────
        string tune = snapshot.tune;
        if (tune != "Auto" && tune.length > 0) {
            args += "-tune";
            args += tune;
        }

        // ── Level ──────────────────────────────────────────────────────────
        string level = snapshot.level;
        if (level != "Auto" && level.length > 0) {
            args += "-level:v";
            args += level;
        }

        // ── Keyframe Interval ──────────────────────────────────────────────
        string keyint = snapshot.keyint_text;
        if (keyint != "Auto" && keyint != "Custom" && keyint.length > 0) {
            args += "-g";
            args += keyint;
        }

        // ── x264-params ──────────────────────────────────────────────────────
        string[] params = {};
        bool fast_decode = (snapshot.tune == "fastdecode");

        // ref, bframes, b-adapt, deblock, me and psy-rd are sent only when
        // they differ from x264's own defaults. -x264-params is applied after
        // -preset and -tune, so sending a default would undo what they chose.
        string ref_val = snapshot.ref_frames;
        if (ref_val.length > 0 && ref_val != "Auto")
            params += "ref=" + ref_val;

        if (profile == "Baseline") {
            params += "bframes=0";
            params += "b-adapt=0";
        } else {
            if (snapshot.bframes != X264_DEFAULT_BFRAMES)
                params += "bframes=" + snapshot.bframes.to_string ();
            if (snapshot.b_adapt != X264_DEFAULT_B_ADAPT)
                params += "b-adapt=" + snapshot.b_adapt.to_string ();
        }

        if (!snapshot.weightp)
            params += "weightp=0";

        bool deblock_enabled = snapshot.deblock_enabled && !fast_decode;
        if (!deblock_enabled) {
            params += "no-deblock=1";
        } else if (snapshot.deblock_alpha != 0 || snapshot.deblock_beta != 0) {
            int alpha = snapshot.deblock_alpha;
            int beta  = snapshot.deblock_beta;
            params += @"deblock=$alpha,$beta";
        }

        string me = snapshot.me;
        if (me.length > 0 && me != X264_DEFAULT_ME)
            params += "me=" + me;

        int mer = snapshot.me_range;
        if (mer != 16)
            params += "merange=" + mer.to_string ();

        int subme = snapshot.subme;
        if (subme != 7)
            params += "subme=" + subme.to_string ();
        // x264 lowers subme 10 and 11 to 9 unless trellis is 2.
        if (subme >= X264_SUBME_NEEDS_TRELLIS_2)
            params += "trellis=2";

        if (!snapshot.psy_rd_enabled) {
            params += "psy=0";
        } else if (psy_differs_from_default (snapshot.psy_rd, snapshot.psy_trellis)) {
            params += format_psy_rd (snapshot.psy_rd, snapshot.psy_trellis);
        }

        // FFmpeg's -x264-params needs key=value. A bare "no-cabac" is either
        // rejected or swallows the parameter after it.
        if (profile == "Baseline" || fast_decode || !snapshot.cabac)
            params += "cabac=0";

        if (!snapshot.mbtree)
            params += "mbtree=0";

        if (snapshot.lookahead_enabled) {
            int la = snapshot.lookahead;
            params += "rc-lookahead=" + la.to_string ();
        }

        string aq_mode = snapshot.aq_mode;
        if (aq_mode != "Automatic") {
            int aq_val = 0;
            switch (aq_mode) {
                case "Disabled":              aq_val = 0; break;
                case "Variance":              aq_val = 1; break;
                case "Auto-Variance":         aq_val = 2; break;
                case "Auto-Variance Biased":  aq_val = 3; break;
            }
            params += "aq-mode=" + aq_val.to_string ();

            if (aq_val > 0) {
                double strength = snapshot.aq_strength;
                params += "aq-strength="
                    + ConversionUtils.format_ffmpeg_double (strength, "%.1f");
            }
        }

        // VBV for ABR mode
        if (rc_mode == RateControl.ABR && snapshot.abr_vbv) {
            int br = snapshot.abr_bitrate_kbps;
            params += "vbv-maxrate=" + br.to_string ();
            params += "vbv-bufsize=" + br.to_string ();
        }

        // VBV + NAL HRD for CBR mode
        if (rc_mode == RateControl.CBR) {
            int br = snapshot.cbr_bitrate_kbps;
            params += "vbv-maxrate=" + br.to_string ();
            params += "vbv-bufsize=" + br.to_string ();
            params += "nal-hrd=cbr";
        }

        if (snapshot.open_gop)
            params += "open-gop=1";

        string threads = snapshot.threads;
        if (threads != "Auto" && threads.length > 0)
            params += "threads=" + threads;

        if (params.length > 0) {
            args += "-x264-params";
            args += string.joinv (":", params);
        }

        return args;
    }
}
