using Gtk;

public class X265Builder : Object, ICodecBuilder {

    public string get_codec_name () {
        return "x265";
    }

    public string[] get_codec_args (Object codec_tab) {
        var tab = codec_tab as X265Tab;
        if (tab == null) {
            warning ("X265Builder received wrong tab type");
            return { "-c:v", "libx265", "-preset", "medium", "-crf", "23" };
        }
        return build_args (tab);
    }

    public static string[] build_args (X265Tab tab) {
        string[] args = {};

        // ── Codec + Preset ─────────────────────────────────────────────────
        args += "-c:v";
        args += "libx265";
        args += "-preset";
        args += tab.get_active_preset ();

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

        // ── x265-params ────────────────────────────────────────────────────
        string[] params = {};

        // SAO (default is enabled, so only pass when disabled)
        if (!tab.sao_switch.active)
            params += "sao=0";

        // Reference frames
        string ref_val = tab.get_dropdown_text (tab.ref_frames_combo);
        if (ref_val.length > 0)
            params += "ref=" + ref_val;

        // Weighted prediction (default enabled, so only pass when disabled)
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

        // PMode
        if (tab.pmode_switch.active)
            params += "pmode=1";

        // Psy-RD (default enabled at 2.0, emit no-psy-rd when disabled)
        if (tab.psy_rd_expander.enable_expansion) {
            double psy_rd = tab.psy_rd_spin.get_value ();
            params += "psy-rd=%.1f".printf (psy_rd);
        } else {
            params += "no-psy-rd";
        }

        // Cutree (default enabled, only emit when disabled)
        if (!tab.cutree_switch.active)
            params += "cutree=0";

        // Lookahead
        if (tab.lookahead_expander.enable_expansion) {
            int la = (int) tab.lookahead_spin.get_value ();
            params += "rc-lookahead=" + la.to_string ();
        }

        // AQ Mode (Automatic=don't set, Disabled=0, Variance=1,
        //          Auto-Variance=2, Auto-Variance Biased=3,
        //          Auto-Variance + Edge=4)
        string aq_mode = tab.get_dropdown_text (tab.aq_mode_combo);
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

        // Threads (pools)
        string threads = tab.get_dropdown_text (tab.threads_combo);
        if (threads != "Auto" && threads.length > 0)
            params += "pools=" + threads;

        // Frame threads
        string ft = tab.get_dropdown_text (tab.frame_threads_combo);
        if (ft != "Auto" && ft.length > 0)
            params += "frame-threads=" + ft;

        // ── Emit the params string ─────────────────────────────────────────
        if (params.length > 0) {
            args += "-x265-params";
            args += string.joinv (":", params);
        }

        return args;
    }
}
