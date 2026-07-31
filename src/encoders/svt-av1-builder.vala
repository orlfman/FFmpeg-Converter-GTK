using Gtk;

public class SvtAv1BuilderSnapshot : Object {
    public int preset = 8;
    public string rc_mode = RateControl.CRF;
    public int crf = 28;
    public int qp = 28;
    public int vbr_bitrate_kbps = 2000;
    public bool mbr_enabled = false;
    public int mbr_bitrate_kbps = 4000;
    public string level = "Auto";
    public string keyint_text = "Auto";
    public int tune_selected = 0;
    public bool lookahead_enabled = false;
    public int lookahead = 40;
    public string aq_mode = "Automatic";
    public int aq_strength = 2;
    public bool grain_enabled = false;
    public int grain_strength = 8;
    public int grain_denoise_selected = 0;
    public bool cdef = true;
    public bool restoration = true;
    public bool dlf = true;
    public bool tf = true;
    public bool tpl = true;
    public bool low_latency = false;
    public bool superres_enabled = false;
    public int superres_mode_selected = 0;
    public int superres_denom = 8;
    public bool sharpness_enabled = false;
    public int sharpness = 0;
    public string scm = "Auto-Detect";
    public string fast_decode = "Disabled";
    public bool qm_enabled = false;
    public int qm_min = 8;
    public int qm_max = 11;
    public string tile_rows = "Auto";
    public string tile_columns = "Auto";
    public string threads = "Auto";
    public GeneralSettingsSnapshot? general_settings { get; set; default = null; }
}

public class SvtAv1Builder : Object, ICodecBuilder {

    private weak SvtAv1Tab tab;

    public SvtAv1Builder (SvtAv1Tab tab) {
        this.tab = tab;
    }

    public string get_codec_name () {
        return "SVT-AV1";
    }

    public Object? snapshot_settings (
        GeneralSettingsSnapshot? general_settings = null) {
        var snapshot = new SvtAv1BuilderSnapshot ();
        snapshot.preset = (int) tab.preset_spin.get_value ();
        snapshot.rc_mode = CodecUtils.get_dropdown_text (tab.rc_mode_combo);
        snapshot.crf = (int) tab.crf_spin.get_value ();
        snapshot.qp = (int) tab.qp_spin.get_value ();
        snapshot.vbr_bitrate_kbps = (int) tab.vbr_bitrate_spin.get_value ();
        snapshot.mbr_enabled = tab.mbr_expander.enable_expansion;
        snapshot.mbr_bitrate_kbps = (int) tab.mbr_bitrate_spin.get_value ();
        snapshot.level = CodecUtils.get_dropdown_text (tab.level_combo);
        snapshot.keyint_text = CodecUtils.get_dropdown_text (tab.keyint_combo);
        snapshot.tune_selected = (int) tab.tune_combo.get_selected ();
        snapshot.lookahead_enabled = tab.lookahead_expander.enable_expansion;
        snapshot.lookahead = (int) tab.lookahead_spin.get_value ();
        snapshot.aq_mode = CodecUtils.get_dropdown_text (tab.aq_mode_combo);
        snapshot.aq_strength = (int) tab.aq_strength_spin.get_value ();
        snapshot.grain_enabled = tab.grain_expander.enable_expansion;
        snapshot.grain_strength = (int) tab.grain_strength_spin.get_value ();
        snapshot.grain_denoise_selected = (int) tab.grain_denoise_combo.get_selected ();
        snapshot.cdef = tab.cdef_switch.active;
        snapshot.restoration = tab.restoration_switch.active;
        snapshot.dlf = tab.dlf_switch.active;
        snapshot.tf = tab.tf_switch.active;
        snapshot.tpl = tab.tpl_switch.active;
        snapshot.low_latency = tab.low_latency_switch.active;
        snapshot.superres_enabled = tab.superres_expander.enable_expansion;
        snapshot.superres_mode_selected = (int) tab.superres_mode_combo.get_selected ();
        snapshot.superres_denom = (int) tab.superres_denom_spin.get_value ();
        snapshot.sharpness_enabled = tab.sharpness_expander.enable_expansion;
        snapshot.sharpness = (int) tab.sharpness_spin.get_value ();
        snapshot.scm = CodecUtils.get_dropdown_text (tab.scm_combo);
        snapshot.fast_decode = CodecUtils.get_dropdown_text (tab.fast_decode_combo);
        snapshot.qm_enabled = tab.qm_expander.enable_expansion;
        snapshot.qm_min = (int) tab.qm_min_spin.get_value ();
        snapshot.qm_max = (int) tab.qm_max_spin.get_value ();
        snapshot.tile_rows = CodecUtils.get_dropdown_text (tab.tile_rows_combo);
        snapshot.tile_columns = CodecUtils.get_dropdown_text (tab.tile_columns_combo);
        snapshot.threads = CodecUtils.get_dropdown_text (tab.threads_combo);

        snapshot.general_settings = general_settings;

        return snapshot;
    }

    public string[] build_codec_args_from_snapshot (Object? builder_snapshot) {
        var snapshot = builder_snapshot as SvtAv1BuilderSnapshot;
        if (snapshot == null)
            return {};
        return build_args_from_snapshot (snapshot);
    }

    public string[] get_codec_args () {
        return build_codec_args_from_snapshot (snapshot_settings ());
    }

    private static string[] build_args_from_snapshot (SvtAv1BuilderSnapshot snapshot) {
        string[] args = {};

        // ── Codec & Preset ───────────────────────────────────────────────────
        args += "-c:v";
        args += "libsvtav1";
        args += "-preset";
        args += snapshot.preset.to_string ();

        // ── Pixel Format ────────────────────────────────────────────────────
        // This SVT-AV1 path currently produces 4:2:0 output. Emit -pix_fmt
        // explicitly whenever the user selected 8-bit or 10-bit so ffmpeg
        // does not silently downgrade 4:2:2/4:4:4 behind the UI's back.
        string svt_pix_fmt = CodecUtils.get_svt_av1_pix_fmt_from_snapshot (
            snapshot.general_settings);
        if (svt_pix_fmt.length > 0) {
            args += "-pix_fmt";
            args += svt_pix_fmt;
        }

        // ── Rate Control ────────────────────────────────────────────────────
        // SVT-AV1 CRF valid range is 1–63; CRF/QP 0 means lossless, which
        // requires the svtav1-params lossless flag instead.
        string rc_mode = snapshot.rc_mode;
        bool lossless = false;

        if (rc_mode == RateControl.CRF) {
            int crf = snapshot.crf;
            if (crf == 0) {
                lossless = true;
            } else {
                args += "-crf";
                args += crf.to_string ();
            }
        } else if (rc_mode == RateControl.QP) {
            int qp = snapshot.qp;
            if (qp == 0) {
                lossless = true;
            } else {
                args += "-qp";
                args += qp.to_string ();
            }
        } else if (rc_mode == RateControl.VBR) {
            args += "-b:v";
            args += snapshot.vbr_bitrate_kbps.to_string () + "k";
        }

        // ── Level ────────────────────────────────────────────────────────────
        string level = snapshot.level;
        if (level != "Auto" && level.length > 0) {
            args += "-level";
            args += level;
        }

        // ── Keyframe Interval ────────────────────────────────────────────────
        string keyint = snapshot.keyint_text;
        if (keyint != "Auto" && keyint != "Custom" && keyint.length > 0) {
            args += "-g";
            args += keyint;
        }

        // ── SVT-AV1 Specific Parameters ─────────────────────────────────────
        string[] svt_params = {};

        if (lossless)
            svt_params += "lossless=1";

        int tune_sel = snapshot.tune_selected;
        if (tune_sel > 0)
            svt_params += "tune=%d".printf (tune_sel - 1);

        if (snapshot.lookahead_enabled) {
            svt_params += "lookahead=%d".printf (snapshot.lookahead);
        }

        string aq = snapshot.aq_mode;
        if (aq != "Automatic") {
            int aq_val = 0;
            if (aq == "Disabled")       aq_val = 0;
            else if (aq == "Variance")  aq_val = 1;
            else if (aq == "Complexity") aq_val = 2;
            svt_params += "aq-mode=%d".printf (aq_val);

            if (aq == "Variance") {
                svt_params += "enable-variance-boost=1";
                svt_params += "variance-boost-strength=%d".printf (
                    snapshot.aq_strength);
            }
        }

        if (snapshot.grain_enabled) {
            svt_params += "film-grain=%d".printf (
                snapshot.grain_strength);
            svt_params += "film-grain-denoise=%d".printf (
                snapshot.grain_denoise_selected);
        }

        if (!snapshot.cdef)
            svt_params += "enable-cdef=0";

        if (!snapshot.restoration)
            svt_params += "enable-restoration=0";

        if (!snapshot.dlf)
            svt_params += "enable-dlf=0";

        if (!snapshot.tf)
            svt_params += "enable-tf=0";

        if (!snapshot.tpl)
            svt_params += "enable-tpl-la=0";

        if (snapshot.low_latency)
            svt_params += "pred-struct=1";

        if (snapshot.superres_enabled) {
            int sr_mode = snapshot.superres_mode_selected + 1;
            svt_params += "superres-mode=%d".printf (sr_mode);
            svt_params += "superres-denom=%d".printf (
                snapshot.superres_denom);
        }

        if (snapshot.sharpness_enabled) {
            svt_params += "sharpness=%d".printf (
                snapshot.sharpness);
        }

        string scm = snapshot.scm;
        if (scm != "Auto-Detect") {
            int scm_val = (scm == "Forced") ? 1 : 0;
            svt_params += "scm=%d".printf (scm_val);
        }

        string fd = snapshot.fast_decode;
        if (fd != "Disabled") {
            int fd_val = fd.contains ("1") ? 1 : 2;
            svt_params += "fast-decode=%d".printf (fd_val);
        }

        if (snapshot.qm_enabled) {
            int qm_min = int.min (snapshot.qm_min, snapshot.qm_max);
            int qm_max = int.max (snapshot.qm_min, snapshot.qm_max);
            svt_params += "enable-qm=1";
            svt_params += "qm-min=%d".printf (qm_min);
            svt_params += "qm-max=%d".printf (qm_max);
        }

        string tile_r = snapshot.tile_rows;
        if (tile_r != "Auto") {
            int tile_r_val = int.parse (tile_r);
            int tile_r_log2 = 0;
            while ((1 << tile_r_log2) < tile_r_val) tile_r_log2++;
            svt_params += "tile-rows=%d".printf (tile_r_log2);
        }

        string tile_c = snapshot.tile_columns;
        if (tile_c != "Auto") {
            int tile_c_val = int.parse (tile_c);
            int tile_c_log2 = 0;
            while ((1 << tile_c_log2) < tile_c_val) tile_c_log2++;
            svt_params += "tile-columns=%d".printf (tile_c_log2);
        }

        string threads = snapshot.threads;
        if (threads != "Auto")
            svt_params += "lp=%s".printf (threads);

        // Max Bitrate (CRF mode only — SVT-AV1's mbr param caps peak
        // bitrate to prevent complex scenes from spiking).
        if (rc_mode == RateControl.CRF && snapshot.mbr_enabled) {
            svt_params += "mbr=%d".printf (snapshot.mbr_bitrate_kbps);
            svt_params += "buf-sz=1000";
        }

        if (svt_params.length > 0) {
            args += "-svtav1-params";
            args += string.joinv (":", svt_params);
        }

        return args;
    }
}
