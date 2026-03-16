using Gtk;

public class VideoFilterSettingsSnapshot : Object {
    public string[] processing_filters = {};
    public string hdr_filter = "";
}

public class PixelFormatSettingsSnapshot : Object {
    public bool eight_bit_selected = false;
    public string eight_bit_format_text = "8-bit 4:2:0";
    public bool ten_bit_selected = false;
    public string ten_bit_format_text = "10-bit 4:2:0";

    public PixelFormatSettingsSnapshot copy () {
        var snapshot = new PixelFormatSettingsSnapshot ();
        snapshot.eight_bit_selected = eight_bit_selected;
        snapshot.eight_bit_format_text = eight_bit_format_text;
        snapshot.ten_bit_selected = ten_bit_selected;
        snapshot.ten_bit_format_text = ten_bit_format_text;
        return snapshot;
    }
}

public class GeneralSettingsSnapshot : Object {
    public string scale_mode = ScaleMode.ORIGINAL;
    public string resolution_preset_value = "";
    public string custom_resolution_value = "";
    public double scale_width_multiplier = 1.0;
    public double scale_height_multiplier = 1.0;
    public string scale_algorithm = "lanczos";
    public string scale_range = "input";
    public string rotate = Rotation.NONE;
    public bool crop_enabled = false;
    public string crop_value = "";
    public VideoFilterSettingsSnapshot video_filters { get; set; default = new VideoFilterSettingsSnapshot (); }
    public PixelFormatSettingsSnapshot pixel_format { get; set; default = new PixelFormatSettingsSnapshot (); }
    public string frame_rate_text = FrameRateLabel.ORIGINAL;
    public string custom_frame_rate_text = "";
    public bool video_speed_enabled = false;
    public double video_speed_percent = 0.0;
    public bool audio_speed_enabled = false;
    public double audio_speed_percent = 0.0;
    public string color_filter = "";
    public bool normalize_audio = false;
    public bool preserve_metadata = false;
    public bool remove_chapters = false;
}

public class CodecTabSettingsSnapshot : Object {
    public string container = ContainerExt.MKV;
    public KeyframeSettingsSnapshot keyframe_settings { get; set; default = new KeyframeSettingsSnapshot (); }
    public AudioSettingsSnapshot audio_settings { get; set; default = new AudioSettingsSnapshot (); }
    public PixelFormatSettingsSnapshot pixel_format { get; set; default = new PixelFormatSettingsSnapshot (); }
}

public class KeyframeSettingsSnapshot : Object {
    public string keyint_text = "";
    public int custom_mode = 0;
    public string frame_rate_text = "";
    public string custom_frame_rate_text = "";
}

public class EncodeProfileSnapshot : Object {
    public string codec_name = "";
    public string container = ContainerExt.MKV;
    public string[] codec_args = {};
    public KeyframeSettingsSnapshot? keyframe_settings { get; set; default = null; }
    public string[] audio_args = {};
    public string video_filters = "";
    public string video_filters_skip_crop = "";
    public string audio_filters = "";
    public bool preserve_metadata = false;
    public bool remove_chapters = false;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  CodecUtils — Shared helpers for all codec tabs and builders
//
//  Eliminates duplicated get_dropdown_text() and keyframe resolution that
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

    public void set_dropdown_selection_by_text (DropDown dropdown,
                                                string value,
                                                uint fallback_index = 0) {
        var model = dropdown.get_model ();
        if (model == null) {
            return;
        }

        uint n_items = model.get_n_items ();
        uint selected = fallback_index;
        if (selected >= n_items) {
            selected = 0;
        }

        for (uint i = 0; i < n_items; i++) {
            var item = model.get_item (i) as StringObject;
            if (item != null && item.get_string () == value) {
                selected = i;
                break;
            }
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
    public string get_x264_profile_pix_fmt_from_snapshot (string profile,
                                                          GeneralSettingsSnapshot? general_settings) {
        PixelFormatSettingsSnapshot? pixel_format =
            (general_settings != null) ? general_settings.pixel_format : null;

        switch (profile) {
            case "Baseline":
            case "Main":
            case "High":
                return PixelFormat.YUV420P;
            case "High10":
                return PixelFormat.YUV420P10LE;
            case "High422":
                if (pixel_format != null && pixel_format.ten_bit_selected)
                    return PixelFormat.YUV422P10LE;
                return PixelFormat.YUV422P;
            case "High444":
                if (pixel_format != null && pixel_format.ten_bit_selected)
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
    public string get_vp9_profile_pix_fmt_from_snapshot (string profile,
                                                         GeneralSettingsSnapshot? general_settings) {
        PixelFormatSettingsSnapshot? pixel_format =
            (general_settings != null) ? general_settings.pixel_format : null;

        switch (profile) {
            case "Profile 0 (8-bit 4:2:0)":
                return PixelFormat.YUV420P;
            case "Profile 1 (8-bit 4:2:2 / 4:4:4)":
                if (pixel_format != null
                    && pixel_format.eight_bit_selected
                    && pixel_format.eight_bit_format_text.contains (Chroma.C444)) {
                    return PixelFormat.YUV444P;
                }
                return PixelFormat.YUV422P;
            case "Profile 2 (10-bit 4:2:0)":
                return PixelFormat.YUV420P10LE;
            case "Profile 3 (10-bit 4:2:2 / 4:4:4)":
                if (pixel_format != null
                    && pixel_format.ten_bit_selected
                    && pixel_format.ten_bit_format_text.contains (Chroma.C444)) {
                    return PixelFormat.YUV444P10LE;
                }
                return PixelFormat.YUV422P10LE;
            default:
                return "";
        }
    }

    /**
     * Map the active codec-local depth selection to the SVT-AV1 pixel format
     * this app/runtime supports. Returns "" when no output depth override is
     * currently selected.
     */
    public string get_svt_av1_pix_fmt_from_snapshot (GeneralSettingsSnapshot? general_settings) {
        if (general_settings == null)
            return "";

        PixelFormatSettingsSnapshot pixel_format = general_settings.pixel_format;

        if (pixel_format.ten_bit_selected)
            return PixelFormat.YUV420P10LE;

        if (pixel_format.eight_bit_selected)
            return PixelFormat.YUV420P;

        return "";
    }

    /**
     * Resolve custom keyframe settings from a previously captured snapshot.
     *
     * All four codec tabs share identical keyframe logic:
     *  • "Auto" or a numeric value → handled by the builder (returns {})
     *  • "Custom" → one of four strategies (2s/5s × fixed-time/fps-based)
     *
     * The snapshot must be captured on the main thread before starting worker
     * processing. Any fallback ffprobe work happens here, off the UI thread.
     *
     * @param snapshot    Main-thread snapshot of keyframe + frame-rate state
     * @param input_file  Path to the source file (for fps probing fallback)
     * @return FFmpeg keyframe arguments, or {} if the builder handles it
     */
    public string[] resolve_custom_keyframe_args_from_snapshot (
        KeyframeSettingsSnapshot? snapshot,
        string input_file) {
        if (snapshot == null)
            return {};

        string keyint = snapshot.keyint_text;

        // Not "Custom" — the builder emits -g for numeric values
        if (keyint != "Custom")
            return {};

        int mode = snapshot.custom_mode;
        // 0 = 2 s fixed, 1 = 2 s × fps, 2 = 5 s fixed, 3 = 5 s × fps
        int seconds = (mode == 0 || mode == 1) ? 2 : 5;
        bool use_fixed_time = (mode == 0 || mode == 2);

        if (use_fixed_time) {
            return { "-force_key_frames",
                     @"expr:gte(t,n_forced*$seconds)" };
        }

        // ── fps-based: check General tab first, then probe ───────────────
        double fps = 0.0;

        string fr_text = snapshot.frame_rate_text;
        if (fr_text == FrameRateLabel.CUSTOM) {
            string custom_fr = snapshot.custom_frame_rate_text;
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
     * Snapshot all encode-relevant UI state on the main thread into a plain
     * data object that background workers can consume safely.
     */
    public EncodeProfileSnapshot snapshot_encode_profile (
        ICodecBuilder builder,
        ICodecTab codec_tab,
        GeneralSettingsSnapshot? general_settings) {
        var snapshot = new EncodeProfileSnapshot ();
        CodecTabSettingsSnapshot codec_settings = codec_tab.snapshot_settings (general_settings);
        if (general_settings != null) {
            general_settings.pixel_format = codec_settings.pixel_format.copy ();
        }
        Object? builder_snapshot = builder.snapshot_settings (general_settings);

        snapshot.codec_name = builder.get_codec_name ();
        snapshot.codec_args = builder.build_codec_args_from_snapshot (builder_snapshot);
        snapshot.keyframe_settings = codec_settings.keyframe_settings;

        string container = codec_settings.container;
        if (container.length > 0) {
            snapshot.container = container;
        }

        AudioSettings.coerce_copy_selection_for_container (
            codec_settings.audio_settings,
            snapshot.container
        );
        snapshot.audio_args = AudioSettings.build_audio_args_from_snapshot (
            codec_settings.audio_settings);

        if (general_settings != null) {
            snapshot.video_filters = FilterBuilder.build_video_filter_chain_from_snapshot (
                general_settings, false, snapshot.codec_name);
            snapshot.video_filters_skip_crop = FilterBuilder.build_video_filter_chain_from_snapshot (
                general_settings, true, snapshot.codec_name);
            snapshot.audio_filters = FilterBuilder.build_audio_filter_chain_from_snapshot (
                general_settings);
            snapshot.preserve_metadata = general_settings.preserve_metadata;
            snapshot.remove_chapters = general_settings.remove_chapters;
        }

        return snapshot;
    }

    public string[] build_codec_args_from_snapshot (EncodeProfileSnapshot? snapshot,
                                                    string input_file) {
        if (snapshot == null)
            return {};

        string[] codec_args = snapshot.codec_args;
        foreach (string arg in resolve_custom_keyframe_args_from_snapshot (
                     snapshot.keyframe_settings, input_file)) {
            codec_args += arg;
        }
        return codec_args;
    }

    /**
     * Build FFmpeg video codec arguments directly from a SmartOptimizer
     * recommendation, without going through a codec tab's live UI state.
     *
     * Used for per-segment Smart Optimization in the Crop & Trim tab,
     * where each segment gets its own recommendation and needs its own
     * codec args independently of the codec tab widgets.
     *
     * When a General-tab snapshot is available, codec-specific hardening can
     * still mirror the normal builder path. This currently matters for the
     * SVT-AV1 trim path, which must keep an explicit 4:2:0 pix_fmt in sync
     * with the selected output depth.
     */
    public string[] build_smart_codec_args (OptimizationRecommendation rec,
                                            GeneralSettingsSnapshot? general_settings = null) {
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

            string svt_pix_fmt = CodecUtils.get_svt_av1_pix_fmt_from_snapshot (
                general_settings);
            if (svt_pix_fmt.length > 0) {
                args += "-pix_fmt";
                args += svt_pix_fmt;
            }

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
