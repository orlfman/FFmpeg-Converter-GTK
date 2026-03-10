using Gtk;

public class X264Builder : Object, ICodecBuilder {

    private weak X264Tab tab;

    public X264Builder (X264Tab tab) {
        this.tab = tab;
    }

    public string get_codec_name () {
        return "x264";
    }

    public string[] get_codec_args () {
        return build_args (tab);
    }

    private static string[] build_args (X264Tab tab) {
        string[] args = {};

        // ── Codec + Preset ─────────────────────────────────────────────────
        args += "-c:v";
        args += "libx264";
        args += "-preset";
        args += tab.get_active_preset ();

        // ── Profile ────────────────────────────────────────────────────────
        string profile = CodecUtils.get_dropdown_text (tab.profile_combo);
        if (profile != "Auto" && profile.length > 0) {
            args += "-profile:v";
            args += profile.down ();
        }

        // ── Rate Control ──────────────────────────────────────────────────
        string rc_mode = CodecUtils.get_dropdown_text (tab.rc_mode_combo);

        if (rc_mode == RateControl.CRF) {
            args += "-crf";
            args += ((int) tab.crf_spin.get_value ()).to_string ();
        } else if (rc_mode == RateControl.QP) {
            args += "-qp";
            args += ((int) tab.qp_spin.get_value ()).to_string ();
        } else if (rc_mode == RateControl.ABR) {
            args += "-b:v";
            args += ((int) tab.abr_bitrate_spin.get_value ()).to_string () + "k";
        } else if (rc_mode == RateControl.CBR) {
            args += "-b:v";
            args += ((int) tab.cbr_bitrate_spin.get_value ()).to_string () + "k";
        }

        // ── Tune ───────────────────────────────────────────────────────────
        string tune = CodecUtils.get_dropdown_text (tab.tune_combo);
        if (tune != "Auto" && tune.length > 0) {
            args += "-tune";
            args += tune;
        }

        // ── Level ──────────────────────────────────────────────────────────
        string level = CodecUtils.get_dropdown_text (tab.level_combo);
        if (level != "Auto" && level.length > 0) {
            args += "-level:v";
            args += level;
        }

        // ── Keyframe Interval ──────────────────────────────────────────────
        string keyint = CodecUtils.get_dropdown_text (tab.keyint_combo);
        if (keyint != "Auto" && keyint != "Custom" && keyint.length > 0) {
            args += "-g";
            args += keyint;
        }

        // ── x264-params ──────────────────────────────────────────────────────
        string[] params = {};

        string ref_val = CodecUtils.get_dropdown_text (tab.ref_frames_combo);
        if (ref_val.length > 0)
            params += "ref=" + ref_val;

        int bframes = (int) tab.bframes_spin.get_value ();
        params += "bframes=" + bframes.to_string ();

        int b_adapt = (int) tab.b_adapt_combo.get_selected ();
        params += "b-adapt=" + b_adapt.to_string ();

        if (!tab.weightp_switch.active)
            params += "weightp=0";

        if (tab.deblock_expander.enable_expansion) {
            int alpha = (int) tab.deblock_alpha_spin.get_value ();
            int beta  = (int) tab.deblock_beta_spin.get_value ();
            params += @"deblock=$alpha,$beta";
        } else {
            params += "no-deblock=1";
        }

        string me = CodecUtils.get_dropdown_text (tab.me_combo);
        if (me.length > 0)
            params += "me=" + me;

        int mer = (int) tab.me_range_spin.get_value ();
        if (mer != 16)
            params += "merange=" + mer.to_string ();

        int subme = (int) tab.subme_combo.get_selected ();
        if (subme != 7)
            params += "subme=" + subme.to_string ();

        if (tab.psy_rd_expander.enable_expansion) {
            double psy_rd = tab.psy_rd_spin.get_value ();
            double psy_trellis = tab.psy_trellis_spin.get_value ();
            params += "psy-rd=%.1f,%.2f".printf (psy_rd, psy_trellis);
        } else {
            params += "no-psy";
        }

        if (!tab.cabac_switch.active)
            params += "no-cabac";

        if (!tab.mbtree_switch.active)
            params += "no-mbtree";

        if (tab.lookahead_expander.enable_expansion) {
            int la = (int) tab.lookahead_spin.get_value ();
            params += "rc-lookahead=" + la.to_string ();
        }

        string aq_mode = CodecUtils.get_dropdown_text (tab.aq_mode_combo);
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
                double strength = tab.aq_strength_spin.get_value ();
                params += "aq-strength=" + "%.1f".printf (strength);
            }
        }

        // VBV for ABR mode
        if (rc_mode == RateControl.ABR && tab.abr_vbv_switch.active) {
            int br = (int) tab.abr_bitrate_spin.get_value ();
            params += "vbv-maxrate=" + br.to_string ();
            params += "vbv-bufsize=" + br.to_string ();
        }

        // VBV + NAL HRD for CBR mode
        if (rc_mode == RateControl.CBR) {
            int br = (int) tab.cbr_bitrate_spin.get_value ();
            params += "vbv-maxrate=" + br.to_string ();
            params += "vbv-bufsize=" + br.to_string ();
            params += "nal-hrd=cbr";
        }

        if (tab.open_gop_switch.active)
            params += "open-gop=1";

        string threads = CodecUtils.get_dropdown_text (tab.threads_combo);
        if (threads != "Auto" && threads.length > 0)
            params += "threads=" + threads;

        if (params.length > 0) {
            args += "-x264-params";
            args += string.joinv (":", params);
        }

        return args;
    }
}
