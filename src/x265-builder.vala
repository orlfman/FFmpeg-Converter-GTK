using Gtk;

public class X265BuilderSnapshot : Object {
    public string preset = "medium";
    public string profile = "Auto";
    public string rc_mode = RateControl.CRF;
    public int crf = 28;
    public int qp = 28;
    public int abr_bitrate_kbps = 1000;
    public int cbr_bitrate_kbps = 1000;
    public string tune = "Auto";
    public string level = "Auto";
    public string keyint_text = "Auto";
    public bool sao = true;
    public string ref_frames = "";
    public bool weightp = true;
    public bool deblock_enabled = false;
    public int deblock_alpha = 0;
    public int deblock_beta = 0;
    public bool pmode = false;
    public bool psy_rd_enabled = false;
    public double psy_rd = 2.0;
    public bool cutree = true;
    public bool lookahead_enabled = false;
    public int lookahead = 20;
    public string aq_mode = "Automatic";
    public double aq_strength = 1.0;
    public bool abr_vbv = false;
    public string threads = "Auto";
    public string frame_threads = "Auto";
    public GeneralSettingsSnapshot? general_settings { get; set; default = null; }
}

public class X265Builder : Object, ICodecBuilder {

    private weak X265Tab tab;

    public X265Builder (X265Tab tab) {
        this.tab = tab;
    }

    public string get_codec_name () {
        return "x265";
    }

    public Object? snapshot_settings (
        GeneralSettingsSnapshot? general_settings = null) {
        var snapshot = new X265BuilderSnapshot ();
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
        snapshot.sao = tab.sao_switch.active;
        snapshot.ref_frames = CodecUtils.get_dropdown_text (tab.ref_frames_combo);
        snapshot.weightp = tab.weightp_switch.active;
        snapshot.deblock_enabled = tab.deblock_expander.enable_expansion;
        snapshot.deblock_alpha = (int) tab.deblock_alpha_spin.get_value ();
        snapshot.deblock_beta = (int) tab.deblock_beta_spin.get_value ();
        snapshot.pmode = tab.pmode_switch.active;
        snapshot.psy_rd_enabled = tab.psy_rd_expander.enable_expansion;
        snapshot.psy_rd = tab.psy_rd_spin.get_value ();
        snapshot.cutree = tab.cutree_switch.active;
        snapshot.lookahead_enabled = tab.lookahead_expander.enable_expansion;
        snapshot.lookahead = (int) tab.lookahead_spin.get_value ();
        snapshot.aq_mode = CodecUtils.get_dropdown_text (tab.aq_mode_combo);
        snapshot.aq_strength = tab.aq_strength_spin.get_value ();
        snapshot.abr_vbv = tab.abr_vbv_switch.active;
        snapshot.threads = CodecUtils.get_dropdown_text (tab.threads_combo);
        snapshot.frame_threads = CodecUtils.get_dropdown_text (tab.frame_threads_combo);
        snapshot.general_settings = general_settings;
        return snapshot;
    }

    public string[] build_codec_args_from_snapshot (Object? builder_snapshot) {
        var snapshot = builder_snapshot as X265BuilderSnapshot;
        if (snapshot == null)
            return {};
        return build_args_from_snapshot (snapshot);
    }

    public string[] get_codec_args () {
        return build_codec_args_from_snapshot (snapshot_settings ());
    }

    public static string[] build_args_from_snapshot (X265BuilderSnapshot snapshot) {
        string[] args = {};

        // ── Codec + Preset ─────────────────────────────────────────────────
        args += "-c:v";
        args += "libx265";
        args += "-preset";
        args += snapshot.preset;

        // ── Profile / Pixel Format ──────────────────────────────────────────
        // Defense in depth: explicit x265 profiles must be paired with a
        // compatible pixel format even if the UI state somehow drifts.
        string profile = snapshot.profile;
        if (profile != "Auto" && profile.length > 0) {
            string forced_pix_fmt = CodecUtils.get_x265_profile_pix_fmt (profile);
            if (forced_pix_fmt.length > 0) {
                args += "-pix_fmt";
                args += forced_pix_fmt;
            }

            args += "-profile:v";
            args += profile.down ();
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

        // ── x265-params ────────────────────────────────────────────────────
        string[] params = {};

        if (!snapshot.sao)
            params += "sao=0";

        string ref_val = snapshot.ref_frames;
        if (ref_val.length > 0)
            params += "ref=" + ref_val;

        if (!snapshot.weightp)
            params += "weightp=0";

        if (snapshot.deblock_enabled) {
            int alpha = snapshot.deblock_alpha;
            int beta  = snapshot.deblock_beta;
            params += @"deblock=$alpha,$beta";
        } else {
            params += "no-deblock=1";
        }

        if (snapshot.pmode)
            params += "pmode=1";

        if (snapshot.psy_rd_enabled) {
            double psy_rd = snapshot.psy_rd;
            params += "psy-rd=" + ConversionUtils.format_ffmpeg_double (psy_rd, "%.1f");
        } else {
            params += "no-psy-rd";
        }

        if (!snapshot.cutree)
            params += "cutree=0";

        if (snapshot.lookahead_enabled) {
            int la = snapshot.lookahead;
            params += "rc-lookahead=" + la.to_string ();
        }

        string aq_mode = snapshot.aq_mode;
        if (aq_mode != "Automatic") {
            int aq_val = 0;
            switch (aq_mode) {
                case "Disabled":                aq_val = 0; break;
                case "Variance":                aq_val = 1; break;
                case "Auto-Variance":           aq_val = 2; break;
                case "Auto-Variance Biased":    aq_val = 3; break;
                case "Auto-Variance + Edge":    aq_val = 4; break;
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

        // VBV + strict CBR for CBR mode
        if (rc_mode == RateControl.CBR) {
            int br = snapshot.cbr_bitrate_kbps;
            params += "vbv-maxrate=" + br.to_string ();
            params += "vbv-bufsize=" + br.to_string ();
            params += "strict-cbr=1";
        }

        string threads = snapshot.threads;
        if (threads != "Auto" && threads.length > 0)
            params += "pools=" + threads;

        string ft = snapshot.frame_threads;
        if (ft != "Auto" && ft.length > 0)
            params += "frame-threads=" + ft;

        if (params.length > 0) {
            args += "-x265-params";
            args += string.joinv (":", params);
        }

        return args;
    }
}
