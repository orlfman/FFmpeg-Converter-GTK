using Gtk;

// ═══════════════════════════════════════════════════════════════════════════════
//  CodecUtils — Shared helpers for all codec tabs and builders
//
//  Eliminates duplicated get_dropdown_text() and resolve_keyframe_args() that
//  were previously copy-pasted identically across SvtAv1Tab, X264Tab, X265Tab,
//  and Vp9Tab.
// ═══════════════════════════════════════════════════════════════════════════════

namespace CodecUtils {

    /**
     * Extract the display string from a StringList-backed DropDown.
     * Returns "" if the model or selected item is null.
     */
    public string get_dropdown_text (DropDown dropdown) {
        var item = dropdown.selected_item as StringObject;
        return item != null ? item.string : "";
    }

    /**
     * Resolve the custom keyframe interval into FFmpeg arguments.
     *
     * All four codec tabs share identical keyframe logic:
     *  • "Auto" or a numeric value → handled by the builder (returns {})
     *  • "Custom" → one of four strategies (2s/5s × fixed-time/fps-based)
     *
     * @param keyint_combo            The Keyframe Interval dropdown
     * @param custom_keyframe_combo   The Custom Mode dropdown
     * @param input_file              Path to the source file (for fps probing)
     * @param general_tab             General settings tab (for frame rate info)
     * @return FFmpeg keyframe arguments, or {} if the builder handles it
     */
    public string[] resolve_custom_keyframe_args (DropDown keyint_combo,
                                                   DropDown custom_keyframe_combo,
                                                   string input_file,
                                                   GeneralTab general_tab) {
        string keyint = get_dropdown_text (keyint_combo);

        // Not "Custom" — the builder emits -g for numeric values
        if (keyint != "Custom")
            return {};

        int mode = (int) custom_keyframe_combo.get_selected ();
        // 0 = 2 s fixed, 1 = 2 s × fps, 2 = 5 s fixed, 3 = 5 s × fps
        int seconds = (mode == 0 || mode == 1) ? 2 : 5;
        bool use_fixed_time = (mode == 0 || mode == 2);

        if (use_fixed_time) {
            return { "-force_key_frames",
                     @"expr:gte(t,n_forced*$seconds)" };
        }

        // ── fps-based: check General tab first, then probe ───────────────
        double fps = 0.0;

        string fr_text = general_tab.get_frame_rate_text ();
        if (fr_text == FrameRateLabel.CUSTOM) {
            string custom_fr = general_tab.get_custom_frame_rate_text ();
            if (custom_fr.length > 0)
                fps = double.parse (custom_fr);
        } else if (fr_text != FrameRateLabel.ORIGINAL) {
            fps = double.parse (fr_text);
        }

        // If still unknown, probe the input file
        if (fps < 5.0)
            fps = FfprobeUtils.probe_input_fps (input_file);

        // Sanity — fall back to a safe default
        if (fps < 5.0 || fps > 500.0)
            return { "-g", "240" };

        int gop = (int) Math.round (seconds * fps);
        if (gop < 10) gop = 240;

        return { "-g", gop.to_string () };
    }

    /**
     * Build FFmpeg video codec arguments directly from a SmartOptimizer
     * recommendation, without going through a codec tab's UI state.
     *
     * Used for per-segment Smart Optimization in the Crop & Trim tab,
     * where each segment gets its own recommendation and needs its own
     * codec args independently of the codec tab widgets.
     */
    public string[] build_smart_codec_args (OptimizationRecommendation rec) {
        string[] args = {};

        if (rec.codec == "x264") {
            args += "-c:v";
            args += "libx264";

            if (rec.two_pass && rec.target_bitrate_kbps > 0) {
                args += "-b:v";
                args += "%dk".printf (rec.target_bitrate_kbps);
            } else {
                args += "-crf";
                args += rec.crf.to_string ();
            }

            args += "-preset";
            args += rec.preset;

            args += "-profile:v";
            args += "high";

            // Content-aware tune
            switch (rec.content_type) {
                case ContentType.ANIME:
                    args += "-tune";
                    args += "animation";
                    break;
                case ContentType.SCREENCAST:
                    args += "-tune";
                    args += "stillimage";
                    break;
                default:
                    break;
            }

        } else if (rec.codec == "vp9") {
            args += "-c:v";
            args += "libvpx-vp9";

            // rec.preset for VP9 is "cpu-used N" — extract the number
            string speed_str = rec.preset.replace ("cpu-used ", "");

            if (rec.two_pass && rec.target_bitrate_kbps > 0) {
                args += "-b:v";
                args += "%dk".printf (rec.target_bitrate_kbps);
                args += "-crf";
                args += rec.crf.to_string ();
            } else {
                args += "-crf";
                args += rec.crf.to_string ();
                args += "-b:v";
                args += "0";
            }

            args += "-cpu-used";
            args += speed_str;
            args += "-quality";
            args += "good";
            args += "-row-mt";
            args += "1";

            if (rec.content_type == ContentType.SCREENCAST) {
                args += "-tune-content";
                args += "screen";
            }

        } else if (rec.codec == "x265") {
            args += "-c:v";
            args += "libx265";

            if (rec.two_pass && rec.target_bitrate_kbps > 0) {
                args += "-b:v";
                args += "%dk".printf (rec.target_bitrate_kbps);
            } else {
                args += "-crf";
                args += rec.crf.to_string ();
            }

            args += "-preset";
            args += rec.preset;

            // Content-aware tune
            if (rec.content_type == ContentType.ANIME) {
                args += "-tune";
                args += "animation";
            }

        } else if (rec.codec == "svt-av1") {
            args += "-c:v";
            args += "libsvtav1";

            // rec.preset for SVT-AV1 is "preset N" — extract the number
            string preset_str = rec.preset.replace ("preset ", "");

            if (rec.two_pass && rec.target_bitrate_kbps > 0) {
                args += "-b:v";
                args += "%dk".printf (rec.target_bitrate_kbps);
            } else {
                args += "-crf";
                args += rec.crf.to_string ();
            }

            args += "-preset";
            args += preset_str;
        }

        return args;
    }
}
