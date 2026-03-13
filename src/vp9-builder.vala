using Gtk;

public class Vp9BuilderSnapshot : Object {
    public int speed = 4;
    public string quality_deadline = "good";
    public string profile = "Auto";
    public string rc_mode = RateControl.CRF;
    public int crf = 31;
    public int cq_level = 31;
    public int cq_bitrate_kbps = 1000;
    public int vbr_bitrate_kbps = 1000;
    public int cbr_bitrate_kbps = 1000;
    public string tune_content = "Default";
    public string aq_mode = "Disabled";
    public bool lookahead_enabled = false;
    public int lag_in_frames = 25;
    public bool altref_enabled = false;
    public int arnr_maxframes = 7;
    public int arnr_strength = 5;
    public bool row_mt = true;
    public bool frame_parallel = false;
    public bool undershoot_enabled = false;
    public int undershoot = 100;
    public int overshoot = 100;
    public string keyint_text = "Auto";
    public string tile_columns = "Auto";
    public string tile_rows = "Auto";
    public string threads = "Auto";
    public GeneralSettingsSnapshot? general_settings { get; set; default = null; }
}

public class Vp9Builder : Object, ICodecBuilder {

    private weak Vp9Tab tab;

    public Vp9Builder (Vp9Tab tab) {
        this.tab = tab;
    }

    public string get_codec_name () {
        return "VP9";
    }

    public Object? snapshot_settings (
        GeneralSettingsSnapshot? general_settings = null) {
        var snapshot = new Vp9BuilderSnapshot ();
        snapshot.speed = (int) tab.speed_spin.get_value ();
        snapshot.quality_deadline = CodecUtils.get_dropdown_text (tab.quality_combo);
        snapshot.profile = CodecUtils.get_dropdown_text (tab.profile_combo);
        snapshot.rc_mode = CodecUtils.get_dropdown_text (tab.rc_mode_combo);
        snapshot.crf = (int) tab.crf_spin.get_value ();
        snapshot.cq_level = (int) tab.cq_level_spin.get_value ();
        snapshot.cq_bitrate_kbps = (int) tab.cq_bitrate_spin.get_value ();
        snapshot.vbr_bitrate_kbps = (int) tab.vbr_bitrate_spin.get_value ();
        snapshot.cbr_bitrate_kbps = (int) tab.cbr_bitrate_spin.get_value ();
        snapshot.tune_content = CodecUtils.get_dropdown_text (tab.tune_content_combo);
        snapshot.aq_mode = CodecUtils.get_dropdown_text (tab.aq_mode_combo);
        snapshot.lookahead_enabled = tab.lookahead_expander.enable_expansion;
        snapshot.lag_in_frames = (int) tab.lag_in_frames_spin.get_value ();
        snapshot.altref_enabled = tab.altref_expander.enable_expansion;
        snapshot.arnr_maxframes = (int) tab.arnr_maxframes_spin.get_value ();
        snapshot.arnr_strength = (int) tab.arnr_strength_spin.get_value ();
        snapshot.row_mt = tab.row_mt_switch.active;
        snapshot.frame_parallel = tab.frame_parallel_switch.active;
        snapshot.undershoot_enabled = tab.undershoot_expander.enable_expansion;
        snapshot.undershoot = (int) tab.undershoot_spin.get_value ();
        snapshot.overshoot = (int) tab.overshoot_spin.get_value ();
        snapshot.keyint_text = CodecUtils.get_dropdown_text (tab.keyint_combo);
        snapshot.tile_columns = CodecUtils.get_dropdown_text (tab.tile_columns_combo);
        snapshot.tile_rows = CodecUtils.get_dropdown_text (tab.tile_rows_combo);
        snapshot.threads = CodecUtils.get_dropdown_text (tab.threads_combo);

        snapshot.general_settings = general_settings;

        return snapshot;
    }

    public string[] build_codec_args_from_snapshot (Object? builder_snapshot) {
        var snapshot = builder_snapshot as Vp9BuilderSnapshot;
        if (snapshot == null)
            return {};
        return build_args_from_snapshot (snapshot);
    }

    public string[] get_codec_args () {
        return build_codec_args_from_snapshot (snapshot_settings ());
    }

    private static string[] build_args_from_snapshot (Vp9BuilderSnapshot snapshot) {
        string[] args = {};

        // ── Codec ──────────────────────────────────────────────────────────
        args += "-c:v";
        args += "libvpx-vp9";

        // ── Speed (cpu-used) ───────────────────────────────────────────────
        args += "-cpu-used";
        args += snapshot.speed.to_string ();

        // ── Quality Deadline ───────────────────────────────────────────────
        string deadline = snapshot.quality_deadline;
        if (deadline.length > 0) {
            args += "-deadline";
            args += deadline;
        }

        // ── Profile ────────────────────────────────────────────────────────
        string profile = snapshot.profile;
        string profile_arg = CodecUtils.get_vp9_profile_arg (profile);
        if (profile_arg.length > 0) {
            args += "-profile:v";
            args += profile_arg;

            string forced_pix_fmt = CodecUtils.get_vp9_profile_pix_fmt_from_snapshot (
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
            args += "-b:v";
            args += "0";
        } else if (rc_mode == RateControl.CONSTRAINED_QUALITY) {
            args += "-crf";
            args += snapshot.cq_level.to_string ();
            args += "-b:v";
            args += snapshot.cq_bitrate_kbps.to_string () + "k";
        } else if (rc_mode == RateControl.VBR) {
            args += "-b:v";
            args += snapshot.vbr_bitrate_kbps.to_string () + "k";
        } else if (rc_mode == RateControl.CBR) {
            args += "-b:v";
            args += snapshot.cbr_bitrate_kbps.to_string () + "k";
            args += "-minrate";
            args += snapshot.cbr_bitrate_kbps.to_string () + "k";
            args += "-maxrate";
            args += snapshot.cbr_bitrate_kbps.to_string () + "k";
        }

        // ── Tune Content ───────────────────────────────────────────────────
        string tune = snapshot.tune_content;
        if (tune != "Default" && tune.length > 0) {
            args += "-tune-content";
            args += tune.down ();
        }

        // ── AQ Mode (#5: uses string matching for consistency with other tabs) ──
        string aq = snapshot.aq_mode;
        if (aq != "Disabled") {
            int aq_val = 0;
            switch (aq) {
                case "Variance":        aq_val = 1; break;
                case "Complexity":      aq_val = 2; break;
                case "Cyclic Refresh":  aq_val = 3; break;
                case "Equator360":      aq_val = 4; break;
            }
            if (aq_val > 0) {
                args += "-aq-mode";
                args += aq_val.to_string ();
            }
        }

        // ── Lookahead (lag-in-frames) ──────────────────────────────────────
        if (snapshot.lookahead_enabled) {
            args += "-lag-in-frames";
            args += snapshot.lag_in_frames.to_string ();
        }

        // ── Alt-Ref Frames ─────────────────────────────────────────────────
        if (snapshot.altref_enabled) {
            args += "-auto-alt-ref";
            args += "1";
            args += "-arnr-maxframes";
            args += snapshot.arnr_maxframes.to_string ();
            args += "-arnr-strength";
            args += snapshot.arnr_strength.to_string ();
        } else {
            args += "-auto-alt-ref";
            args += "0";
        }

        // ── Row-Based Multithreading ───────────────────────────────────────
        args += "-row-mt";
        args += snapshot.row_mt ? "1" : "0";

        // ── Frame Parallel Decoding ────────────────────────────────────────
        if (snapshot.frame_parallel) {
            args += "-frame-parallel";
            args += "1";
        }

        // ── Rate Tolerance ─────────────────────────────────────────────────
        if (snapshot.undershoot_enabled) {
            args += "-undershoot-pct";
            args += snapshot.undershoot.to_string ();
            args += "-overshoot-pct";
            args += snapshot.overshoot.to_string ();
        }

        // ── Keyframe Interval ──────────────────────────────────────────────
        string keyint = snapshot.keyint_text;
        if (keyint != "Auto" && keyint != "Custom" && keyint.length > 0) {
            args += "-g";
            args += keyint;
        }

        // ── Tile Columns ───────────────────────────────────────────────────
        string tcols = snapshot.tile_columns;
        if (tcols != "Auto" && tcols.length > 0) {
            args += "-tile-columns";
            args += tcols;
        }

        // ── Tile Rows ──────────────────────────────────────────────────────
        string trows = snapshot.tile_rows;
        if (trows != "Auto" && trows.length > 0) {
            args += "-tile-rows";
            args += trows;
        }

        // ── Threads ────────────────────────────────────────────────────────
        string threads = snapshot.threads;
        if (threads != "Auto" && threads.length > 0) {
            args += "-threads";
            args += threads;
        }

        return args;
    }
}
