using Gtk;

public class X264Builder : Object, ICodecBuilder {

    public string get_codec_name () {
        return "x264";
    }

    public string[] get_codec_args (ICodecTab codec_tab) {
        var tab = codec_tab as X264Tab;
        if (tab == null) {
            warning ("X264Builder received wrong tab type");
            return { "-c:v", "libx264", "-preset", "medium", "-crf", "23" };
        }
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
        string profile = tab.get_dropdown_text (tab.profile_combo);
        if (profile != "Auto" && profile.length > 0) {
            args += "-profile:v";
            args += profile.down ();
        }

        // ── Rate Control ───────────────────────────────────────────────────
        string rc_mode = tab.get_dropdown_text (tab.rc_mode_combo);

        switch (rc_mode) {
            case "CRF":
                args += "-crf";
                args += ((int) tab.crf_spin.get_value ()).to_string ();
                break;
            case "QP":
                args += "-qp";
                args += ((int) tab.qp_spin.get_value ()).to_string ();
                break;
            case "ABR":
                args += "-b:v";
                args += ((int) tab.abr_bitrate_spin.get_value ()).to_string () + "k";
                break;
            case "CBR":
                args += "-b:v";
                args += ((int) tab.cbr_bitrate_spin.get_value ()).to_string () + "k";
                break;
        }

        // ── Tune ───────────────────────────────────────────────────────────
        string tune = tab.get_dropdown_text (tab.tune_combo);
        if (tune != "Auto" && tune.length > 0) {
            args += "-tune";
            args += tune;
        }

        // ── Level ──────────────────────────────────────────────────────────
        string level = tab.get_dropdown_text (tab.level_combo);
        if (level != "Auto" && level.length > 0) {
            args += "-level:v";
            args += level;
        }

        // ── Keyframe Interval (numeric only; Custom handled by runner) ────
        string keyint = tab.get_dropdown_text (tab.keyint_combo);
        if (keyint != "Auto" && keyint != "Custom" && keyint.length > 0) {
            args += "-g";
            args += keyint;
        }

        // ── x264opts ───────────────────────────────────────────────────────
        string[] params = {};

        // Reference frames
        string ref_val = tab.get_dropdown_text (tab.ref_frames_combo);
        if (ref_val.length > 0)
            params += "ref=" + ref_val;

        // B-Frames
        int bframes = (int) tab.bframes_spin.get_value ();
        params += "bframes=" + bframes.to_string ();

        // B-Frame adaptation
        int b_adapt = (int) tab.b_adapt_combo.get_selected ();
        params += "b-adapt=" + b_adapt.to_string ();

        // Weighted prediction (default is smart/2, disabled = 0)
        if (!tab.weightp_switch.active)
            params += "weightp=0";

        // Deblock filter
        if (tab.deblock_expander.enable_expansion) {
            int alpha = (int) tab.deblock_alpha_spin.get_value ();
            int beta  = (int) tab.deblock_beta_spin.get_value ();
            params += @"deblock=$alpha,$beta";
        } else {
            params += "no-deblock=1";
        }

        // Motion estimation
        string me = tab.get_dropdown_text (tab.me_combo);
        if (me.length > 0)
            params += "me=" + me;

        // ME range
        int mer = (int) tab.me_range_spin.get_value ();
        if (mer != 16)
            params += "merange=" + mer.to_string ();

        // Subpixel refinement (extract leading number from "7 — RD on all")
        int subme = (int) tab.subme_combo.get_selected ();
        if (subme != 7)
            params += "subme=" + subme.to_string ();

        // Psychovisual optimization
        if (tab.psy_rd_expander.enable_expansion) {
            double psy_rd = tab.psy_rd_spin.get_value ();
            double psy_trellis = tab.psy_trellis_spin.get_value ();
            params += "psy-rd=%.1f,%.2f".printf (psy_rd, psy_trellis);
        } else {
            params += "no-psy";
        }

        // CABAC (default enabled, only emit when disabled)
        if (!tab.cabac_switch.active)
            params += "no-cabac";

        // MB-Tree (default enabled, only emit when disabled)
        if (!tab.mbtree_switch.active)
            params += "no-mbtree";

        // Lookahead
        if (tab.lookahead_expander.enable_expansion) {
            int la = (int) tab.lookahead_spin.get_value ();
            params += "rc-lookahead=" + la.to_string ();
        }

        // AQ Mode (Automatic = don't set, Disabled = 0, Variance = 1,
        //          Auto-Variance = 2, Auto-Variance Biased = 3)
        string aq_mode = tab.get_dropdown_text (tab.aq_mode_combo);
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

        // VBV for ABR mode (when enabled)
        if (rc_mode == "ABR" && tab.abr_vbv_switch.active) {
            int br = (int) tab.abr_bitrate_spin.get_value ();
            params += "vbv-maxrate=" + br.to_string ();
            params += "vbv-bufsize=" + br.to_string ();
        }

        // VBV + NAL HRD for CBR mode
        if (rc_mode == "CBR") {
            int br = (int) tab.cbr_bitrate_spin.get_value ();
            params += "vbv-maxrate=" + br.to_string ();
            params += "vbv-bufsize=" + br.to_string ();
            params += "nal-hrd=cbr";
        }

        // Open GOP
        if (tab.open_gop_switch.active)
            params += "open-gop=1";

        // Threads
        string threads = tab.get_dropdown_text (tab.threads_combo);
        if (threads != "Auto" && threads.length > 0)
            params += "threads=" + threads;

        // ── Emit the params string ─────────────────────────────────────────
        if (params.length > 0) {
            args += "-x264opts";
            args += string.joinv (":", params);
        }

        return args;
    }
}
