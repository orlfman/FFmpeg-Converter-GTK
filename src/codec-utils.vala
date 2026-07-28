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
    public bool preserve_metadata = false;
    public bool remove_chapters = false;
    public bool watermark_enabled = false;
    public string watermark_mode = "text";  // "text" or "image"
    public string watermark_text = "";
    public string watermark_position = "Bottom Right";
    public string watermark_color = "ffffff";
    public double watermark_opacity = 0.5;
    public int watermark_margin = 10;
    public int watermark_font_size = 24;
    public string watermark_image_path = "";
    public int watermark_image_width = 150;
    // Logo removal — the inverse of the watermark options above. Regions are
    // "x:y:w:h" entries in source-frame coordinates, comma separated.
    public bool delogo_enabled = false;
    public string delogo_regions = "";
}

public class CodecTabSettingsSnapshot : Object {
    public string container = ContainerExt.MKV;
    public KeyframeSettingsSnapshot keyframe_settings { get; set; default = new KeyframeSettingsSnapshot (); }
    public AudioSettingsSnapshot audio_settings { get; set; default = new AudioSettingsSnapshot (); }
    public AudioProcessingSettingsSnapshot audio_processing { get; set; default = new AudioProcessingSettingsSnapshot (); }
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
    public bool preserve_all_audio_tracks = false;
    public string video_filters = "";
    public string video_filters_skip_crop = "";
    // Logo removal cannot always be pre-rendered with the rest of the chain,
    // because two of its properties depend on the caller rather than the
    // settings:
    //
    //   • Position. delogo's rectangles are source-frame, so a per-segment crop
    //     has to be spliced in *after* them (Crop & Trim supplies one).
    //   • Time. A timed region's interval is on the source timeline, but any
    //     path that seeks its input with -ss ahead of -i is handed frames whose
    //     timestamps start near zero — measured, not assumed.
    //
    // So the regions travel as data and the two chains around them are carried
    // separately, to be reassembled by
    // FilterBuilder.build_video_filter_chain_for_segment.
    public bool delogo_enabled = false;
    public string delogo_regions = "";
    public string video_filters_skip_delogo = "";
    public string video_filters_skip_crop_and_delogo = "";
    public string combine_video_filters_per_input = "";
    public string combine_video_filters_post_output = "";
    public string audio_filters = "";
    public AudioProcessingSettingsSnapshot audio_processing { get; set; default = new AudioProcessingSettingsSnapshot (); }
    public bool preserve_metadata = false;
    public bool remove_chapters = false;
    public bool watermark_enabled = false;
    public string watermark_mode = "text";
    public string watermark_image_path = "";
    public int watermark_image_width = 150;
    public string watermark_position = "Bottom Right";
    public double watermark_opacity = 0.5;
    public int watermark_margin = 10;
    // FFmpeg overlay filter output family selected for the video. Empty keeps
    // the filter's default when the user left output depth/chroma on Auto.
    public string overlay_format = "";
}

// ═══════════════════════════════════════════════════════════════════════════════
//  CodecUtils — Shared helpers for all codec tabs and builders
//
//  Eliminates duplicated get_dropdown_text() and keyframe resolution that
//  were previously copy-pasted identically across SvtAv1Tab, X264Tab, X265Tab,
//  and Vp9Tab.
// ═══════════════════════════════════════════════════════════════════════════════

namespace CodecUtils {
    /**
     * Translate an FFmpeg YUV pixel-format name into the codec-tab selection
     * used by the rest of the app. Unknown formats leave both depth switches
     * unset so callers do not silently invent an output policy.
     */
    public PixelFormatSettingsSnapshot pixel_format_settings_from_ffmpeg_pix_fmt (
        string? pix_fmt
    ) {
        var snapshot = new PixelFormatSettingsSnapshot ();
        if (pix_fmt == null)
            return snapshot;

        switch (pix_fmt.down ()) {
            case PixelFormat.YUV420P:
                snapshot.eight_bit_selected = true;
                snapshot.eight_bit_format_text = "8-bit " + Chroma.C420;
                break;
            case PixelFormat.YUV422P:
                snapshot.eight_bit_selected = true;
                snapshot.eight_bit_format_text = "8-bit " + Chroma.C422;
                break;
            case PixelFormat.YUV444P:
                snapshot.eight_bit_selected = true;
                snapshot.eight_bit_format_text = "8-bit " + Chroma.C444;
                break;
            case PixelFormat.YUV420P10LE:
                snapshot.ten_bit_selected = true;
                snapshot.ten_bit_format_text = "10-bit " + Chroma.C420;
                break;
            case PixelFormat.YUV422P10LE:
                snapshot.ten_bit_selected = true;
                snapshot.ten_bit_format_text = "10-bit " + Chroma.C422;
                break;
            case PixelFormat.YUV444P10LE:
                snapshot.ten_bit_selected = true;
                snapshot.ten_bit_format_text = "10-bit " + Chroma.C444;
                break;
            default:
                break;
        }

        return snapshot;
    }

    /**
     * Resolve the General tab's configured output frame rate.
     * Returns false for "Original" so callers can use the probed source rate.
     * This deliberately accepts every positive finite value that FFmpeg's fps
     * filter accepts instead of imposing a second, optimizer-only range.
     */
    public bool try_resolve_output_fps (string selected_text,
                                        string custom_text,
                                        out double fps) {
        fps = 0.0;
        if (selected_text == FrameRateLabel.ORIGINAL)
            return false;

        string value = (selected_text == FrameRateLabel.CUSTOM)
            ? custom_text : selected_text;
        double parsed = 0.0;
        if (!double.try_parse (value, out parsed)
                || !parsed.is_finite () || parsed <= 0.0)
            return false;

        fps = parsed;
        return true;
    }

    public bool try_resolve_output_fps_from_snapshot (
        GeneralSettingsSnapshot snapshot,
        out double fps
    ) {
        return try_resolve_output_fps (
            snapshot.frame_rate_text, snapshot.custom_frame_rate_text, out fps);
    }

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
     * Format a byte count as a human-readable file size string.
     *
     * Uses binary units (1024-based):
     *   0         → "0 B"
     *   < 1 KiB   → "N B"
     *   < 1 MiB   → "N.NN KB"
     *   < 1 GiB   → "N.NN MB"
     *   ≥ 1 GiB   → "N.NN GB"
     */
    public string format_file_size (int64 bytes) {
        if (bytes <= 0)
            return "0 B";

        double kb = (double) bytes / 1024.0;
        if (kb < 1.0)
            return bytes.to_string () + " B";

        double mb = kb / 1024.0;
        if (mb < 1.0)
            return "%.2f KB".printf (kb);

        double gb = mb / 1024.0;
        if (gb < 1.0)
            return "%.2f MB".printf (mb);

        return "%.2f GB".printf (gb);
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
        try_resolve_output_fps (
            snapshot.frame_rate_text, snapshot.custom_frame_rate_text, out fps);

        // If still unknown, probe the input file
        if (fps <= 0.0)
            fps = FfprobeUtils.probe_input_fps (input_file);

        // Sanity — fall back to a safe default
        if (!fps.is_finite () || fps <= 0.0)
            return { "-g", "240" };

        double requested_gop = Math.round (seconds * fps);
        int gop = (requested_gop > (double) int.MAX)
            ? int.MAX : int.max (1, (int) requested_gop);

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
        var audio_args = new GenericArray<string> ();
        foreach (string arg in AudioSettings.build_audio_args_from_snapshot (
            codec_settings.audio_settings,
            codec_settings.audio_processing.channel_downmix)) {
            audio_args.add (arg);
        }
        foreach (string arg in AudioProcessingSettings.build_output_args_from_snapshot (
            codec_settings.audio_processing)) {
            audio_args.add (arg);
        }
        snapshot.audio_args = StringArrayUtils.copy_generic_array (audio_args);
        snapshot.preserve_all_audio_tracks =
            codec_settings.audio_settings.preserve_all_audio_tracks;
        snapshot.audio_processing = codec_settings.audio_processing.copy ();

        if (general_settings != null) {
            snapshot.video_filters = FilterBuilder.build_video_filter_chain_from_snapshot (
                general_settings, false, snapshot.codec_name);
            snapshot.video_filters_skip_crop = FilterBuilder.build_video_filter_chain_from_snapshot (
                general_settings, true, snapshot.codec_name);
            snapshot.delogo_enabled = general_settings.delogo_enabled;
            snapshot.delogo_regions = general_settings.delogo_regions;
            snapshot.video_filters_skip_delogo =
                FilterBuilder.build_video_filter_chain_from_snapshot (
                    general_settings, false, snapshot.codec_name, true);
            snapshot.video_filters_skip_crop_and_delogo =
                FilterBuilder.build_video_filter_chain_from_snapshot (
                    general_settings, true, snapshot.codec_name, true);
            snapshot.combine_video_filters_per_input =
                FilterBuilder.build_combine_per_input_video_filters_from_snapshot (
                    general_settings, true, snapshot.codec_name);
            snapshot.combine_video_filters_post_output =
                FilterBuilder.build_combine_post_output_video_filters_from_snapshot (
                    general_settings);
            snapshot.audio_filters = FilterBuilder.build_audio_filter_chain_from_snapshot (
                general_settings);
            snapshot.preserve_metadata = general_settings.preserve_metadata;
            snapshot.remove_chapters = general_settings.remove_chapters;
            snapshot.watermark_enabled = general_settings.watermark_enabled;
            snapshot.watermark_mode = general_settings.watermark_mode;
            snapshot.watermark_image_path = general_settings.watermark_image_path;
            snapshot.watermark_image_width = general_settings.watermark_image_width;
            snapshot.watermark_position = general_settings.watermark_position;
            snapshot.watermark_opacity = general_settings.watermark_opacity;
            snapshot.watermark_margin = general_settings.watermark_margin;
            snapshot.overlay_format = FilterBuilder.get_overlay_output_format (
                general_settings.pixel_format);
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

            if (rec.lookahead_frames > 0) {
                args += "-x264-params";
                args += "rc-lookahead=%d".printf (rec.lookahead_frames);
            }

        } else if (rec.codec == "vp9") {
            args += "-c:v";
            args += "libvpx-vp9";

            // rec.preset for VP9 is "cpu-used N" — extract the number
            string speed_str = rec.preset.replace ("cpu-used ", "");

            // VP9 requires profile 2 for 10-bit
            bool vp9_10bit = (rec.recommended_pix_fmt != null
                && rec.recommended_pix_fmt.contains ("10"));
            if (vp9_10bit) {
                args += "-profile:v";
                args += "2";
            }

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
            if (rec.lookahead_frames > 0) {
                args += "-lag-in-frames";
                args += rec.lookahead_frames.to_string ();
            }
            if (rec.native_sharpness > 0) {
                args += "-sharpness";
                args += rec.native_sharpness.to_string ();
            }

        } else if (rec.codec == "x265") {
            args += "-c:v";
            args += "libx265";

            // x265 requires main10 profile for 10-bit
            bool x265_10bit = (rec.recommended_pix_fmt != null
                && rec.recommended_pix_fmt.contains ("10"));
            if (x265_10bit) {
                args += "-profile:v";
                args += "main10";
            }

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
            if (rec.lookahead_frames > 0) {
                args += "-x265-params";
                args += "rc-lookahead=%d".printf (rec.lookahead_frames);
            }

        } else if (rec.codec == "svt-av1") {
            args += "-c:v";
            args += "libsvtav1";

            // rec.preset for SVT-AV1 is "preset N" — extract the number
            string preset_str = rec.preset.replace ("preset ", "");

            // Prefer smart optimizer's recommended pixel format over snapshot
            if (rec.recommended_pix_fmt != null && rec.recommended_pix_fmt.length > 0) {
                args += "-pix_fmt";
                args += rec.recommended_pix_fmt;
            } else {
                string svt_pix_fmt = CodecUtils.get_svt_av1_pix_fmt_from_snapshot (
                    general_settings);
                if (svt_pix_fmt.length > 0) {
                    args += "-pix_fmt";
                    args += svt_pix_fmt;
                }
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

            string[] svt_params = {};
            if (rec.lookahead_frames > 0)
                svt_params += "lookahead=%d".printf (rec.lookahead_frames);
            if (rec.native_sharpness > 0)
                svt_params += "sharpness=%d".printf (rec.native_sharpness);
            if (svt_params.length > 0) {
                args += "-svtav1-params";
                args += string.joinv (":", svt_params);
            }
        }

        if (rec.keyint_frames > 0) {
            args += "-g";
            args += rec.keyint_frames.to_string ();
        }

        // Emit -pix_fmt for non-SVT-AV1 codecs when recommended and not
        // already emitted by the codec-specific block above.
        if (rec.codec != "svt-av1"
                && rec.recommended_pix_fmt != null
                && rec.recommended_pix_fmt.length > 0) {
            args += "-pix_fmt";
            args += rec.recommended_pix_fmt;
        }

        // VBV peak-rate constraint for two-pass encodes.
        // Prevents complex scenes from consuming a disproportionate share
        // of the bitrate budget, which can push the final file size above
        // the target.  Bufsize = maxrate gives one second of peak-rate
        // buffer, standard for file-based encoding.
        // Note: SVT-AV1 does not support VBV (mbr) in VBR/bitrate mode —
        // only in CRF mode — so it is excluded here.
        if (rec.two_pass && rec.target_bitrate_kbps > 0
                && rec.codec != "svt-av1") {
            int maxrate = (int) (rec.target_bitrate_kbps * 1.5);
            args += "-maxrate";
            args += "%dk".printf (maxrate);
            args += "-bufsize";
            args += "%dk".printf (maxrate);
        }

        return args;
    }
}
