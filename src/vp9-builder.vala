using Gtk;

public class Vp9Builder : Object, ICodecBuilder {

    public string get_codec_name () {
        return "VP9";
    }

    public string[] get_codec_args (ICodecTab codec_tab) {
        var tab = codec_tab as Vp9Tab;
        if (tab == null) {
            warning ("Vp9Builder received wrong tab type");
            return { "-c:v", "libvpx-vp9", "-crf", "31", "-b:v", "0" };
        }
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
        string deadline = tab.get_dropdown_text (tab.quality_combo);
        if (deadline.length > 0) {
            args += "-deadline";
            args += deadline;
        }

        // ── Rate Control ───────────────────────────────────────────────────
        string rc_mode = tab.get_dropdown_text (tab.rc_mode_combo);

        switch (rc_mode) {
            case "CRF":
                // True constant quality: -crf N -b:v 0
                args += "-crf";
                args += ((int) tab.crf_spin.get_value ()).to_string ();
                args += "-b:v";
                args += "0";
                break;

            case "Constrained Quality":
                // Constrained quality: -crf N -b:v Mk
                args += "-crf";
                args += ((int) tab.cq_level_spin.get_value ()).to_string ();
                args += "-b:v";
                args += ((int) tab.cq_bitrate_spin.get_value ()).to_string () + "k";
                break;

            case "VBR":
                args += "-b:v";
                args += ((int) tab.vbr_bitrate_spin.get_value ()).to_string () + "k";
                break;

            case "CBR":
                args += "-b:v";
                args += ((int) tab.cbr_bitrate_spin.get_value ()).to_string () + "k";
                args += "-minrate";
                args += ((int) tab.cbr_bitrate_spin.get_value ()).to_string () + "k";
                args += "-maxrate";
                args += ((int) tab.cbr_bitrate_spin.get_value ()).to_string () + "k";
                break;
        }

        // ── Tune Content ───────────────────────────────────────────────────
        string tune = tab.get_dropdown_text (tab.tune_content_combo);
        if (tune != "Default" && tune.length > 0) {
            args += "-tune-content";
            args += tune.down ();
        }

        // ── AQ Mode ────────────────────────────────────────────────────────
        int aq = (int) tab.aq_mode_combo.get_selected ();
        if (aq > 0) {
            args += "-aq-mode";
            args += aq.to_string ();
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

        // ── Rate Tolerance (undershoot / overshoot) ────────────────────────
        if (tab.undershoot_expander.enable_expansion) {
            args += "-undershoot-pct";
            args += ((int) tab.undershoot_spin.get_value ()).to_string ();
            args += "-overshoot-pct";
            args += ((int) tab.overshoot_spin.get_value ()).to_string ();
        }

        // ── Keyframe Interval (numeric only; Custom handled by runner) ────
        string keyint = tab.get_dropdown_text (tab.keyint_combo);
        if (keyint != "Auto" && keyint != "Custom" && keyint.length > 0) {
            args += "-g";
            args += keyint;
        }

        // ── Tile Columns ───────────────────────────────────────────────────
        string tcols = tab.get_dropdown_text (tab.tile_columns_combo);
        if (tcols != "Auto" && tcols.length > 0) {
            args += "-tile-columns";
            args += tcols;
        }

        // ── Tile Rows ──────────────────────────────────────────────────────
        string trows = tab.get_dropdown_text (tab.tile_rows_combo);
        if (trows != "Auto" && trows.length > 0) {
            args += "-tile-rows";
            args += trows;
        }

        // ── Threads ────────────────────────────────────────────────────────
        string threads = tab.get_dropdown_text (tab.threads_combo);
        if (threads != "Auto" && threads.length > 0) {
            args += "-threads";
            args += threads;
        }

        return args;
    }
}
