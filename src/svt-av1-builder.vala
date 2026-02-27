using Gtk;

public class SvtAv1Builder : Object, ICodecBuilder {

    public string get_codec_name () {
        return "SVT-AV1";
    }

    public string[] get_codec_args (Object codec_tab) {
        var tab = codec_tab as SvtAv1Tab;
        if (tab == null) {
            warning ("SvtAv1Builder received wrong tab type");
            return { "-c:v", "libsvtav1", "-preset", "8", "-crf", "28" };
        }
        return build_args (tab);
    }

    private static string[] build_args (SvtAv1Tab tab) {
        string[] args = {};

        // ── Codec & Preset ───────────────────────────────────────────────────
        args += "-c:v";
        args += "libsvtav1";
        args += "-preset";
        args += ((int) tab.preset_spin.get_value ()).to_string ();

        // ── Rate Control ─────────────────────────────────────────────────────
        string rc_mode = tab.get_dropdown_text (tab.rc_mode_combo);

        if (rc_mode == "CRF") {
            args += "-crf";
            args += ((int) tab.crf_spin.get_value ()).to_string ();
        } else if (rc_mode == "QP") {
            args += "-qp";
            args += ((int) tab.qp_spin.get_value ()).to_string ();
        } else if (rc_mode == "VBR") {
            args += "-b:v";
            args += ((int) tab.vbr_bitrate_spin.get_value ()).to_string () + "k";
        }

        // ── Level ────────────────────────────────────────────────────────────
        string level = tab.get_dropdown_text (tab.level_combo);
        if (level != "Auto" && level.length > 0) {
            args += "-level";
            args += level;
        }

        // ── Keyframe Interval ────────────────────────────────────────────────
        string keyint = tab.get_dropdown_text (tab.keyint_combo);
        if (keyint != "Auto" && keyint != "Custom" && keyint.length > 0) {
            args += "-g";
            args += keyint;
        }

        // ── SVT-AV1 Specific Parameters ─────────────────────────────────────
        string[] svt_params = {};

	// Tune (Auto = don't pass anything, 1 = VQ/0, 2 = PSNR/1, 3 = SSIM/2)
	int tune_sel = (int) tab.tune_combo.get_selected ();
	if (tune_sel > 0)
    		svt_params += "tune=%d".printf (tune_sel - 1);

        // Lookahead
        if (tab.lookahead_expander.enable_expansion) {
            svt_params += "lookahead=%d".printf ((int) tab.lookahead_spin.get_value ());
        }

        // AQ Mode
        string aq = tab.get_dropdown_text (tab.aq_mode_combo);
        if (aq != "Automatic") {
            int aq_val = 0;
            if (aq == "Disabled")       aq_val = 0;
            else if (aq == "Variance")  aq_val = 1;
            else if (aq == "Complexity") aq_val = 2;
            svt_params += "aq-mode=%d".printf (aq_val);

            // AQ Strength — uses variance boost (only meaningful for Variance mode)
            if (aq == "Variance") {
                svt_params += "enable-variance-boost=1";
                svt_params += "variance-boost-strength=%d".printf (
                    (int) tab.aq_strength_spin.get_value ());
            }
        }

        // Film Grain
        if (tab.grain_expander.enable_expansion) {
            svt_params += "film-grain=%d".printf (
                (int) tab.grain_strength_spin.get_value ());
            svt_params += "film-grain-denoise=%d".printf (
                (int) tab.grain_denoise_combo.get_selected ());
        }

        // CDEF (default is enabled; switch OFF = disable)
        if (!tab.cdef_switch.active)
            svt_params += "enable-cdef=0";

        // Loop Restoration (default is enabled; switch OFF = disable)
        if (!tab.restoration_switch.active)
            svt_params += "enable-restoration=0";

        // Deblocking Filter (default is enabled; expander ON = override to disable)
	if (!tab.dlf_switch.active)
    	    svt_params += "enable-dlf=0";

        // Temporal Filtering (default is enabled; switch OFF = disable)
        if (!tab.tf_switch.active)
            svt_params += "enable-tf=0";

        // Spatio-Temporal Prediction (default is enabled; switch OFF = disable)
        if (!tab.tpl_switch.active)
            svt_params += "enable-tpl-la=0";

        // Low Latency (1 = low delay, default is 2 = random access)
        if (tab.low_latency_switch.active)
            svt_params += "pred-struct=1";

        // Super-Resolution
        if (tab.superres_expander.enable_expansion) {
            // DropDown: "1 — Fastest" = index 0 → mode 1, etc.
            int sr_mode = (int) tab.superres_mode_combo.get_selected () + 1;
            svt_params += "superres-mode=%d".printf (sr_mode);
            svt_params += "superres-denom=%d".printf (
                (int) tab.superres_denom_spin.get_value ());
        }

        // SVT Sharpness
        if (tab.sharpness_expander.enable_expansion) {
            svt_params += "sharpness=%d".printf (
                (int) tab.sharpness_spin.get_value ());
        }

        // Screen Content Mode (default is scm=2 auto-detect)
        string scm = tab.get_dropdown_text (tab.scm_combo);
        if (scm != "Auto-Detect") {
            int scm_val = (scm == "Forced") ? 1 : 0;
            svt_params += "scm=%d".printf (scm_val);
        }

        // Fast Decode
        string fd = tab.get_dropdown_text (tab.fast_decode_combo);
        if (fd != "Disabled") {
            int fd_val = fd.contains ("1") ? 1 : 2;
            svt_params += "fast-decode=%d".printf (fd_val);
        }

        // Quantization Matrices
        if (tab.qm_expander.enable_expansion) {
            svt_params += "enable-qm=1";
            svt_params += "min-qm-level=%d".printf (
                (int) tab.qm_min_spin.get_value ());
            svt_params += "max-qm-level=%d".printf (
                (int) tab.qm_max_spin.get_value ());
        }

        // Tile Rows & Columns (SVT-AV1 takes log2 values)
        string tile_r = tab.get_dropdown_text (tab.tile_rows_combo);
        if (tile_r != "Auto") {
            int tile_r_val = int.parse (tile_r);
            int tile_r_log2 = 0;
            while ((1 << tile_r_log2) < tile_r_val) tile_r_log2++;
            svt_params += "tile-rows=%d".printf (tile_r_log2);
        }

        string tile_c = tab.get_dropdown_text (tab.tile_columns_combo);
        if (tile_c != "Auto") {
            int tile_c_val = int.parse (tile_c);
            int tile_c_log2 = 0;
            while ((1 << tile_c_log2) < tile_c_val) tile_c_log2++;
            svt_params += "tile-columns=%d".printf (tile_c_log2);
        }

        // Threads
        string threads = tab.get_dropdown_text (tab.threads_combo);
        if (threads != "Auto")
            svt_params += "lp=%s".printf (threads);

        // ── Assemble -svtav1-params ──────────────────────────────────────────
        if (svt_params.length > 0) {
            args += "-svtav1-params";
            args += string.joinv (":", svt_params);
        }

        return args;
    }
}
