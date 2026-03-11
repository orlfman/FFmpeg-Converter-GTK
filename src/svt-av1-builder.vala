using Gtk;

public class SvtAv1Builder : Object, ICodecBuilder {

    private weak SvtAv1Tab tab;

    public SvtAv1Builder (SvtAv1Tab tab) {
        this.tab = tab;
    }

    public string get_codec_name () {
        return "SVT-AV1";
    }

    public string[] get_codec_args () {
        return build_args (tab);
    }

    private static string[] build_args (SvtAv1Tab tab) {
        string[] args = {};

        // ── Codec & Preset ───────────────────────────────────────────────────
        args += "-c:v";
        args += "libsvtav1";
        args += "-preset";
        args += ((int) tab.preset_spin.get_value ()).to_string ();

        // ── Pixel Format ────────────────────────────────────────────────────
        // This SVT-AV1 path currently produces 4:2:0 output. Emit -pix_fmt
        // explicitly whenever the user selected 8-bit or 10-bit so ffmpeg
        // does not silently downgrade 4:2:2/4:4:4 behind the UI's back.
        string svt_pix_fmt = CodecUtils.get_svt_av1_pix_fmt (tab.general_tab);
        if (svt_pix_fmt.length > 0) {
            args += "-pix_fmt";
            args += svt_pix_fmt;
        }

        // ── Rate Control ────────────────────────────────────────────────────
        // SVT-AV1 CRF valid range is 1–63; CRF/QP 0 means lossless, which
        // requires the svtav1-params lossless flag instead.
        string rc_mode = CodecUtils.get_dropdown_text (tab.rc_mode_combo);
        bool lossless = false;

        if (rc_mode == RateControl.CRF) {
            int crf = (int) tab.crf_spin.get_value ();
            if (crf == 0) {
                lossless = true;
            } else {
                args += "-crf";
                args += crf.to_string ();
            }
        } else if (rc_mode == RateControl.QP) {
            int qp = (int) tab.qp_spin.get_value ();
            if (qp == 0) {
                lossless = true;
            } else {
                args += "-qp";
                args += qp.to_string ();
            }
        } else if (rc_mode == RateControl.VBR) {
            args += "-b:v";
            args += ((int) tab.vbr_bitrate_spin.get_value ()).to_string () + "k";
        }

        // ── Level ────────────────────────────────────────────────────────────
        string level = CodecUtils.get_dropdown_text (tab.level_combo);
        if (level != "Auto" && level.length > 0) {
            args += "-level";
            args += level;
        }

        // ── Keyframe Interval ────────────────────────────────────────────────
        string keyint = CodecUtils.get_dropdown_text (tab.keyint_combo);
        if (keyint != "Auto" && keyint != "Custom" && keyint.length > 0) {
            args += "-g";
            args += keyint;
        }

        // ── SVT-AV1 Specific Parameters ─────────────────────────────────────
        string[] svt_params = {};

        if (lossless)
            svt_params += "lossless=1";

        int tune_sel = (int) tab.tune_combo.get_selected ();
        if (tune_sel > 0)
            svt_params += "tune=%d".printf (tune_sel - 1);

        if (tab.lookahead_expander.enable_expansion) {
            svt_params += "lookahead=%d".printf ((int) tab.lookahead_spin.get_value ());
        }

        string aq = CodecUtils.get_dropdown_text (tab.aq_mode_combo);
        if (aq != "Automatic") {
            int aq_val = 0;
            if (aq == "Disabled")       aq_val = 0;
            else if (aq == "Variance")  aq_val = 1;
            else if (aq == "Complexity") aq_val = 2;
            svt_params += "aq-mode=%d".printf (aq_val);

            if (aq == "Variance") {
                svt_params += "enable-variance-boost=1";
                svt_params += "variance-boost-strength=%d".printf (
                    (int) tab.aq_strength_spin.get_value ());
            }
        }

        if (tab.grain_expander.enable_expansion) {
            svt_params += "film-grain=%d".printf (
                (int) tab.grain_strength_spin.get_value ());
            svt_params += "film-grain-denoise=%d".printf (
                (int) tab.grain_denoise_combo.get_selected ());
        }

        if (!tab.cdef_switch.active)
            svt_params += "enable-cdef=0";

        if (!tab.restoration_switch.active)
            svt_params += "enable-restoration=0";

        if (!tab.dlf_switch.active)
            svt_params += "enable-dlf=0";

        if (!tab.tf_switch.active)
            svt_params += "enable-tf=0";

        if (!tab.tpl_switch.active)
            svt_params += "enable-tpl-la=0";

        if (tab.low_latency_switch.active)
            svt_params += "pred-struct=1";

        if (tab.superres_expander.enable_expansion) {
            int sr_mode = (int) tab.superres_mode_combo.get_selected () + 1;
            svt_params += "superres-mode=%d".printf (sr_mode);
            svt_params += "superres-denom=%d".printf (
                (int) tab.superres_denom_spin.get_value ());
        }

        if (tab.sharpness_expander.enable_expansion) {
            svt_params += "sharpness=%d".printf (
                (int) tab.sharpness_spin.get_value ());
        }

        string scm = CodecUtils.get_dropdown_text (tab.scm_combo);
        if (scm != "Auto-Detect") {
            int scm_val = (scm == "Forced") ? 1 : 0;
            svt_params += "scm=%d".printf (scm_val);
        }

        string fd = CodecUtils.get_dropdown_text (tab.fast_decode_combo);
        if (fd != "Disabled") {
            int fd_val = fd.contains ("1") ? 1 : 2;
            svt_params += "fast-decode=%d".printf (fd_val);
        }

        if (tab.qm_expander.enable_expansion) {
            svt_params += "enable-qm=1";
            svt_params += "qm-min=%d".printf (
                (int) tab.qm_min_spin.get_value ());
            svt_params += "qm-max=%d".printf (
                (int) tab.qm_max_spin.get_value ());
        }

        string tile_r = CodecUtils.get_dropdown_text (tab.tile_rows_combo);
        if (tile_r != "Auto") {
            int tile_r_val = int.parse (tile_r);
            int tile_r_log2 = 0;
            while ((1 << tile_r_log2) < tile_r_val) tile_r_log2++;
            svt_params += "tile-rows=%d".printf (tile_r_log2);
        }

        string tile_c = CodecUtils.get_dropdown_text (tab.tile_columns_combo);
        if (tile_c != "Auto") {
            int tile_c_val = int.parse (tile_c);
            int tile_c_log2 = 0;
            while ((1 << tile_c_log2) < tile_c_val) tile_c_log2++;
            svt_params += "tile-columns=%d".printf (tile_c_log2);
        }

        string threads = CodecUtils.get_dropdown_text (tab.threads_combo);
        if (threads != "Auto")
            svt_params += "lp=%s".printf (threads);

        if (svt_params.length > 0) {
            args += "-svtav1-params";
            args += string.joinv (":", svt_params);
        }

        return args;
    }
}
