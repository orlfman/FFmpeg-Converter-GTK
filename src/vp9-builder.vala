using Gtk;

public class Vp9Builder : Object, ICodecBuilder {

    private weak Vp9Tab tab;

    public Vp9Builder (Vp9Tab tab) {
        this.tab = tab;
    }

    public string get_codec_name () {
        return "VP9";
    }

    public string[] get_codec_args () {
        return build_args (tab);
    }

    private static string[] build_args (Vp9Tab tab) {
        string[] args = {};

        // ── Codec ──────────────────────────────────────────────────────────
        args += "-c:v";
        args += "libvpx-vp9";

        // ── Speed (cpu-used) ───────────────────────────────────────────────
        args += "-cpu-used";
        args += ((int) tab.speed_spin.get_value ()).to_string ();

        // ── Quality Deadline ───────────────────────────────────────────────
        string deadline = CodecUtils.get_dropdown_text (tab.quality_combo);
        if (deadline.length > 0) {
            args += "-deadline";
            args += deadline;
        }

        // ── Rate Control ──────────────────────────────────────────────────
        string rc_mode = CodecUtils.get_dropdown_text (tab.rc_mode_combo);

        if (rc_mode == RateControl.CRF) {
            args += "-crf";
            args += ((int) tab.crf_spin.get_value ()).to_string ();
            args += "-b:v";
            args += "0";
        } else if (rc_mode == RateControl.CONSTRAINED_QUALITY) {
            args += "-crf";
            args += ((int) tab.cq_level_spin.get_value ()).to_string ();
            args += "-b:v";
            args += ((int) tab.cq_bitrate_spin.get_value ()).to_string () + "k";
        } else if (rc_mode == RateControl.VBR) {
            args += "-b:v";
            args += ((int) tab.vbr_bitrate_spin.get_value ()).to_string () + "k";
        } else if (rc_mode == RateControl.CBR) {
            args += "-b:v";
            args += ((int) tab.cbr_bitrate_spin.get_value ()).to_string () + "k";
            args += "-minrate";
            args += ((int) tab.cbr_bitrate_spin.get_value ()).to_string () + "k";
            args += "-maxrate";
            args += ((int) tab.cbr_bitrate_spin.get_value ()).to_string () + "k";
        }

        // ── Tune Content ───────────────────────────────────────────────────
        string tune = CodecUtils.get_dropdown_text (tab.tune_content_combo);
        if (tune != "Default" && tune.length > 0) {
            args += "-tune-content";
            args += tune.down ();
        }

        // ── AQ Mode (#5: uses string matching for consistency with other tabs) ──
        string aq = CodecUtils.get_dropdown_text (tab.aq_mode_combo);
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
        if (tab.lookahead_expander.enable_expansion) {
            args += "-lag-in-frames";
            args += ((int) tab.lag_in_frames_spin.get_value ()).to_string ();
        }

        // ── Alt-Ref Frames ─────────────────────────────────────────────────
        if (tab.altref_expander.enable_expansion) {
            args += "-auto-alt-ref";
            args += "1";
            args += "-arnr-maxframes";
            args += ((int) tab.arnr_maxframes_spin.get_value ()).to_string ();
            args += "-arnr-strength";
            args += ((int) tab.arnr_strength_spin.get_value ()).to_string ();
        } else {
            args += "-auto-alt-ref";
            args += "0";
        }

        // ── Row-Based Multithreading ───────────────────────────────────────
        args += "-row-mt";
        args += tab.row_mt_switch.active ? "1" : "0";

        // ── Frame Parallel Decoding ────────────────────────────────────────
        if (tab.frame_parallel_switch.active) {
            args += "-frame-parallel";
            args += "1";
        }

        // ── Rate Tolerance ─────────────────────────────────────────────────
        if (tab.undershoot_expander.enable_expansion) {
            args += "-undershoot-pct";
            args += ((int) tab.undershoot_spin.get_value ()).to_string ();
            args += "-overshoot-pct";
            args += ((int) tab.overshoot_spin.get_value ()).to_string ();
        }

        // ── Keyframe Interval ──────────────────────────────────────────────
        string keyint = CodecUtils.get_dropdown_text (tab.keyint_combo);
        if (keyint != "Auto" && keyint != "Custom" && keyint.length > 0) {
            args += "-g";
            args += keyint;
        }

        // ── Tile Columns ───────────────────────────────────────────────────
        string tcols = CodecUtils.get_dropdown_text (tab.tile_columns_combo);
        if (tcols != "Auto" && tcols.length > 0) {
            args += "-tile-columns";
            args += tcols;
        }

        // ── Tile Rows ──────────────────────────────────────────────────────
        string trows = CodecUtils.get_dropdown_text (tab.tile_rows_combo);
        if (trows != "Auto" && trows.length > 0) {
            args += "-tile-rows";
            args += trows;
        }

        // ── Threads ────────────────────────────────────────────────────────
        string threads = CodecUtils.get_dropdown_text (tab.threads_combo);
        if (threads != "Auto" && threads.length > 0) {
            args += "-threads";
            args += threads;
        }

        return args;
    }
}
