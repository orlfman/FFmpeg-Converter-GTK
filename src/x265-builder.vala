using Gtk;

public class X265Builder : Object, ICodecBuilder {

    private weak X265Tab tab;

    public X265Builder (X265Tab tab) {
        this.tab = tab;
    }

    public string get_codec_name () {
        return "x265";
    }

    public string[] get_codec_args () {
        return build_args (tab);
    }

    public static string[] build_args (X265Tab tab) {
        string[] args = {};

        // ── Codec + Preset ─────────────────────────────────────────────────
        args += "-c:v";
        args += "libx265";
        args += "-preset";
        args += tab.get_active_preset ();

        // ── Profile / Pixel Format ──────────────────────────────────────────
        // Defense in depth: explicit x265 profiles must be paired with a
        // compatible pixel format even if the UI state somehow drifts.
        string profile = CodecUtils.get_dropdown_text (tab.profile_combo);
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

        // ── x265-params ────────────────────────────────────────────────────
        string[] params = {};

        if (!tab.sao_switch.active)
            params += "sao=0";

        string ref_val = CodecUtils.get_dropdown_text (tab.ref_frames_combo);
        if (ref_val.length > 0)
            params += "ref=" + ref_val;

        if (!tab.weightp_switch.active)
            params += "weightp=0";

        if (tab.deblock_expander.enable_expansion) {
            int alpha = (int) tab.deblock_alpha_spin.get_value ();
            int beta  = (int) tab.deblock_beta_spin.get_value ();
            params += @"deblock=$alpha,$beta";
        } else {
            params += "no-deblock=1";
        }

        if (tab.pmode_switch.active)
            params += "pmode=1";

        if (tab.psy_rd_expander.enable_expansion) {
            double psy_rd = tab.psy_rd_spin.get_value ();
            params += "psy-rd=%.1f".printf (psy_rd);
        } else {
            params += "no-psy-rd";
        }

        if (!tab.cutree_switch.active)
            params += "cutree=0";

        if (tab.lookahead_expander.enable_expansion) {
            int la = (int) tab.lookahead_spin.get_value ();
            params += "rc-lookahead=" + la.to_string ();
        }

        string aq_mode = CodecUtils.get_dropdown_text (tab.aq_mode_combo);
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

        // VBV + strict CBR for CBR mode
        if (rc_mode == RateControl.CBR) {
            int br = (int) tab.cbr_bitrate_spin.get_value ();
            params += "vbv-maxrate=" + br.to_string ();
            params += "vbv-bufsize=" + br.to_string ();
            params += "strict-cbr=1";
        }

        string threads = CodecUtils.get_dropdown_text (tab.threads_combo);
        if (threads != "Auto" && threads.length > 0)
            params += "pools=" + threads;

        string ft = CodecUtils.get_dropdown_text (tab.frame_threads_combo);
        if (ft != "Auto" && ft.length > 0)
            params += "frame-threads=" + ft;

        if (params.length > 0) {
            args += "-x265-params";
            args += string.joinv (":", params);
        }

        return args;
    }
}
