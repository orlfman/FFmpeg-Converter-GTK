using Gtk;

// ═══════════════════════════════════════════════════════════════════════════════
//  CodecUtils — Shared helpers for all codec tabs and builders
//
//  Eliminates duplicated get_dropdown_text() and resolve_keyframe_args() that
//  were previously copy-pasted identically across SvtAv1Tab, X264Tab, X265Tab,
//  and Vp9Tab.
// ═══════════════════════════════════════════════════════════════════════════════

namespace CodecUtils {

    public StringList build_dropdown_string_list (string[] options) {
        var model = new StringList (null);
        foreach (unowned string option in options) {
            model.append (option);
        }
        return model;
    }

    public bool dropdown_matches_options (DropDown dropdown, string[] options) {
        var model = dropdown.get_model ();
        if (model == null || model.get_n_items () != options.length) {
            return false;
        }

        for (uint i = 0; i < model.get_n_items (); i++) {
            var item = model.get_item (i) as StringObject;
            if (item == null || item.get_string () != options[i]) {
                return false;
            }
        }

        return true;
    }

    public void set_dropdown_options (DropDown dropdown,
                                      string[] options,
                                      string fallback_option) {
        string current = get_dropdown_text (dropdown);
        int selected = 0;

        for (int i = 0; i < options.length; i++) {
            if (options[i] == current) {
                selected = i;
                break;
            }
            if (options[i] == fallback_option) {
                selected = i;
            }
        }

        if (!dropdown_matches_options (dropdown, options)) {
            dropdown.set_model (build_dropdown_string_list (options));
        }

        if (dropdown.get_selected () != selected) {
            dropdown.set_selected (selected);
        }
    }

    /**
     * Extract the display string from a StringList-backed DropDown.
     * Returns "" if the model or selected item is null.
     */
    public string get_dropdown_text (DropDown dropdown) {
        var item = dropdown.selected_item as StringObject;
        return item != null ? item.string : "";
    }

    /**
     * Map explicit x265 profile selections to the pixel format they require.
     * Returns "" for Auto or any profile that does not need a forced pix_fmt.
     */
    public string get_x265_profile_pix_fmt (string profile) {
        switch (profile) {
            case "Main":
                return PixelFormat.YUV420P;
            case "Main10":
                return PixelFormat.YUV420P10LE;
            default:
                return "";
        }
    }

    /**
     * Map explicit x264 profile selections to the exact pixel format they
     * require for truthful output-profile matching.
     *
     * High422 and High444 preserve an explicit 10-bit selection when present;
     * otherwise they default to their 8-bit variants.
     */
    public string get_x264_profile_pix_fmt (string profile, GeneralTab? general_tab) {
        switch (profile) {
            case "Baseline":
            case "Main":
            case "High":
                return PixelFormat.YUV420P;
            case "High10":
                return PixelFormat.YUV420P10LE;
            case "High422":
                if (general_tab != null && general_tab.ten_bit_check.active)
                    return PixelFormat.YUV422P10LE;
                return PixelFormat.YUV422P;
            case "High444":
                if (general_tab != null && general_tab.ten_bit_check.active)
                    return PixelFormat.YUV444P10LE;
                return PixelFormat.YUV444P;
            default:
                return "";
        }
    }

    /**
     * Map explicit VP9 profile labels to the numeric -profile:v value.
     * Returns "" for Auto or unknown labels.
     */
    public string get_vp9_profile_arg (string profile) {
        switch (profile) {
            case "Profile 0 (8-bit 4:2:0)":
                return "0";
            case "Profile 1 (8-bit 4:2:2 / 4:4:4)":
                return "1";
            case "Profile 2 (10-bit 4:2:0)":
                return "2";
            case "Profile 3 (10-bit 4:2:2 / 4:4:4)":
                return "3";
            default:
                return "";
        }
    }

    /**
     * Map explicit VP9 profile selections to an exact pixel format so the
     * encoded bitstream profile matches the user's chosen profile.
     *
     * Profiles 1 and 3 preserve an explicit 4:4:4 selection when present;
     * otherwise they default to their 4:2:2 variants.
     */
    public string get_vp9_profile_pix_fmt (string profile, GeneralTab? general_tab) {
        switch (profile) {
            case "Profile 0 (8-bit 4:2:0)":
                return PixelFormat.YUV420P;
            case "Profile 1 (8-bit 4:2:2 / 4:4:4)":
                if (general_tab != null
                    && general_tab.eight_bit_check.active
                    && get_dropdown_text (general_tab.eight_bit_format).contains (Chroma.C444)) {
                    return PixelFormat.YUV444P;
                }
                return PixelFormat.YUV422P;
            case "Profile 2 (10-bit 4:2:0)":
                return PixelFormat.YUV420P10LE;
            case "Profile 3 (10-bit 4:2:2 / 4:4:4)":
                if (general_tab != null
                    && general_tab.ten_bit_check.active
                    && get_dropdown_text (general_tab.ten_bit_format).contains (Chroma.C444)) {
                    return PixelFormat.YUV444P10LE;
                }
                return PixelFormat.YUV422P10LE;
            default:
                return "";
        }
    }

    /**
     * Map the active General tab depth selection to the SVT-AV1 pixel format
     * this app/runtime supports. Returns "" when no output depth override is
     * currently selected.
     */
    public string get_svt_av1_pix_fmt (GeneralTab? general_tab) {
        if (general_tab == null)
            return "";

        if (general_tab.ten_bit_check.active)
            return PixelFormat.YUV420P10LE;

        if (general_tab.eight_bit_check.active)
            return PixelFormat.YUV420P;

        return "";
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
                // Pure VBR two-pass for size-targeted encodes — no CRF floor
                // so the encoder can allocate bits strictly to hit the
                // target bitrate without a quality minimum pulling it up.
                args += "-b:v";
                args += "%dk".printf (rec.target_bitrate_kbps);
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
