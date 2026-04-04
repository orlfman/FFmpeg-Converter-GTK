using Gtk;

// ═══════════════════════════════════════════════════════════════════════════════
//  FilterBuilder — Pure utility functions for building FFmpeg filter chains
// ═══════════════════════════════════════════════════════════════════════════════

namespace FilterBuilder {

    // Epsilon for floating-point comparisons — SpinButton values can drift
    // from exact representable doubles, so bare == / != is unreliable.
    private const double EPSILON = 1e-9;

    private bool fp_equal (double a, double b) {
        return Math.fabs (a - b) < EPSILON;
    }

    private bool try_get_speed_multiplier (double pct,
                                           string filter_name,
                                           out double multiplier) {
        multiplier = 1.0;

        if (!pct.is_finite ()) {
            warning ("FilterBuilder: Ignoring %s speed percent because it is not finite: %g",
                     filter_name, pct);
            return false;
        }

        if (fp_equal (pct, 0.0)) {
            return false;
        }

        multiplier = 1.0 + pct / 100.0;
        if (!multiplier.is_finite () || multiplier <= 0.0) {
            warning ("FilterBuilder: Ignoring %s speed percent %.6f because it produces "
                     + "an invalid multiplier %.6f", filter_name, pct, multiplier);
            multiplier = 1.0;
            return false;
        }

        return true;
    }

    private string[] get_rotation_filters_from_snapshot (GeneralSettingsSnapshot snapshot) {
        string[] filters = {};
        string rot = snapshot.rotate;
        if (rot == Rotation.CW_90) filters += "transpose=1";
        else if (rot == Rotation.CCW_90) filters += "transpose=2";
        else if (rot == Rotation.ROTATE_180) filters += "transpose=1,transpose=1";
        else if (rot == Rotation.HORIZONTAL_FLIP) filters += "hflip";
        else if (rot == Rotation.VERTICAL_FLIP) filters += "vflip";
        return filters;
    }

    public string build_video_filter_chain (GeneralTab tab,
                                            bool skip_crop = false,
                                            string codec_name = "",
                                            PixelFormatSettingsSnapshot? pixel_format_settings = null) {
        return build_video_filter_chain_from_snapshot (
            tab.snapshot_settings (pixel_format_settings), skip_crop, codec_name);
    }

    private string[] get_rotation_crop_processing_hdr_filters (
        GeneralSettingsSnapshot snapshot,
        bool skip_crop,
        string codec_name) {
        string[] filters = {};
        string[] rot_filters = get_rotation_filters_from_snapshot (snapshot);
        bool has_vflip = false;
        foreach (string f in rot_filters) {
            filters += f;
            if (f == "vflip") has_vflip = true;
        }

        // SVT-AV1 workaround: vflip produces frames with negative line strides
        // which SVT-AV1's API rejects (EB_ErrorBadParameter). A format=
        // filter alone is not enough — ffmpeg's format filter is a no-op when
        // the input already matches (e.g. yuv420p→yuv420p), so negative strides
        // pass through. scale=iw:ih forces swscale to allocate a new buffer
        // with positive strides regardless of pixel format.
        if (has_vflip && codec_name.down ().contains ("svt")) {
            filters += "scale=iw:ih";
        }

        if (!skip_crop && snapshot.crop_enabled) {
            string c = snapshot.crop_value;
            if (c.length > 0 && c != "w:h:x:y") {
                if (c.has_prefix ("crop=")) c = c.substring (5);
                filters += "crop=" + c;
            }
        }

        foreach (string f in snapshot.video_filters.processing_filters) {
            filters += f;
        }

        string hdr = snapshot.video_filters.hdr_filter;
        if (hdr.length > 0) filters += hdr;

        return filters;
    }

    private string[] get_scale_filters (GeneralSettingsSnapshot snapshot) {
        string[] filters = {};
        string scale_mode = snapshot.scale_mode;
        string? scale_w = null;
        string? scale_h = null;

        if (scale_mode == ScaleMode.RESOLUTION) {
            string res = snapshot.resolution_preset_value;
            if (res.length > 0 && res.contains (":")) {
                string[] dims = res.split (":");
                scale_w = dims[0];
                scale_h = dims[1];
            }
        } else if (scale_mode == ScaleMode.CUSTOM) {
            string res = snapshot.custom_resolution_value;
            if (res.length > 0 && res.contains (":")) {
                string[] dims = res.split (":");
                scale_w = dims[0];
                scale_h = dims[1];
            }
        } else if (scale_mode == ScaleMode.PERCENTAGE) {
            double sw = snapshot.scale_width_multiplier;
            double sh = snapshot.scale_height_multiplier;
            if (!fp_equal (sw, 1.0) || !fp_equal (sh, 1.0)) {
                scale_w = fp_equal (sw, 1.0)
                    ? "iw"
                    : "trunc(iw*" + ConversionUtils.format_ffmpeg_double (sw, "%.6f") + "/2)*2";
                scale_h = fp_equal (sh, 1.0)
                    ? "ih"
                    : "trunc(ih*" + ConversionUtils.format_ffmpeg_double (sh, "%.6f") + "/2)*2";
            }
        }

        if (scale_w != null && scale_h != null) {
            string alg = snapshot.scale_algorithm.down ();
            if (alg == ScaleAlgorithm.POINT) {
                filters += @"scale=w=$scale_w:h=$scale_h:flags=point";
            } else {
                filters += @"zscale=w=$scale_w:h=$scale_h:filter=$alg";
            }
            string range = snapshot.scale_range;
            if (range != "input") filters += @"zscale=range=$range";
        }

        return filters;
    }

    private string[] get_frame_rate_filters (GeneralSettingsSnapshot snapshot) {
        string[] filters = {};
        string fr = snapshot.frame_rate_text;
        if (fr != FrameRateLabel.ORIGINAL) {
            string fps = (fr == FrameRateLabel.CUSTOM) ? snapshot.custom_frame_rate_text : fr;
            if (fps.length > 0) filters += "fps=" + fps;
        }

        return filters;
    }

    private string[] get_pixel_format_filters (GeneralSettingsSnapshot snapshot) {
        string[] filters = {};
        string pixfmt = "";

        PixelFormatSettingsSnapshot pixel_format = snapshot.pixel_format;

        if (pixel_format.ten_bit_selected) {
            string f = pixel_format.ten_bit_format_text;
            pixfmt = f.contains (Chroma.C420) ? PixelFormat.YUV420P10LE :
                     f.contains (Chroma.C422) ? PixelFormat.YUV422P10LE :
                                                PixelFormat.YUV444P10LE;
        }
        else if (pixel_format.eight_bit_selected) {
            string f = pixel_format.eight_bit_format_text;
            pixfmt = f.contains (Chroma.C420) ? PixelFormat.YUV420P :
                     f.contains (Chroma.C422) ? PixelFormat.YUV422P :
                                                PixelFormat.YUV444P;
        }

        if (pixfmt != "") {
            filters += "format=" + pixfmt;
        }

        return filters;
    }

    public string build_video_filter_chain_from_snapshot (GeneralSettingsSnapshot snapshot,
                                                          bool skip_crop = false,
                                                          string codec_name = "") {
        string[] filters = {};

        foreach (string f in get_rotation_crop_processing_hdr_filters (
                     snapshot, skip_crop, codec_name)) {
            filters += f;
        }
        foreach (string f in get_scale_filters (snapshot)) {
            filters += f;
        }
        foreach (string f in get_frame_rate_filters (snapshot)) {
            filters += f;
        }

        // 7. Video Speed
        if (snapshot.video_speed_enabled) {
            double mult;
            if (try_get_speed_multiplier (snapshot.video_speed_percent, "video", out mult)) {
                double factor = 1.0 / mult;
                filters += "setpts=" + ConversionUtils.format_ffmpeg_double (factor, "%.6f") + "*PTS";
            }
        }

        // 8. Pixel Format
        foreach (string f in get_pixel_format_filters (snapshot)) {
            filters += f;
        }

        // 9. Color Correction
        string cc = snapshot.color_filter;
        if (cc.length > 0)
            filters += cc;

        // 10. Watermark (last — positioned against final output geometry)
        string? wm = build_drawtext_filter (snapshot);
        if (wm != null)
            filters += wm;

        return filters.length > 0 ? string.joinv (",", filters) : "";
    }

    public string build_combine_per_input_video_filters_from_snapshot (
        GeneralSettingsSnapshot snapshot,
        bool skip_crop = true,
        string codec_name = "") {
        string[] filters = {};
        foreach (string f in get_rotation_crop_processing_hdr_filters (
                     snapshot, skip_crop, codec_name)) {
            filters += f;
        }

        string cc = snapshot.color_filter;
        if (cc.length > 0) {
            filters += cc;
        }

        return filters.length > 0 ? string.joinv (",", filters) : "";
    }

    public string build_combine_post_output_video_filters_from_snapshot (
        GeneralSettingsSnapshot snapshot) {
        string[] filters = {};
        foreach (string f in get_scale_filters (snapshot)) {
            filters += f;
        }
        foreach (string f in get_frame_rate_filters (snapshot)) {
            filters += f;
        }
        foreach (string f in get_pixel_format_filters (snapshot)) {
            filters += f;
        }

        // Watermark (last — positioned against final combined output geometry)
        string? wm = build_drawtext_filter (snapshot);
        if (wm != null)
            filters += wm;

        return filters.length > 0 ? string.joinv (",", filters) : "";
    }

    public string build_audio_filter_chain (GeneralTab tab) {
        return build_audio_filter_chain_from_snapshot (tab.snapshot_settings ());
    }

    public string build_audio_filter_chain_from_snapshot (GeneralSettingsSnapshot snapshot) {
        string[] filters = {};

        // Audio Speed
        if (snapshot.audio_speed_enabled) {
            double mult;
            if (try_get_speed_multiplier (snapshot.audio_speed_percent, "audio", out mult)) {
                string chain = build_atempo_chain (mult);
                if (chain.length > 0) filters += chain;
            }
        }

        return filters.length > 0 ? string.joinv (",", filters) : "";
    }

    public string merge_profile_audio_filter_chain (
        string base_filters,
        AudioProcessingSettingsSnapshot processing,
        double duration = 0.0,
        bool include_normalization = true,
        bool apply_fade_in = true,
        bool apply_fade_out = true) {
        string processing_filters = AudioProcessingSettings.build_filter_chain_from_snapshot (
            processing,
            duration,
            include_normalization,
            apply_fade_in,
            apply_fade_out
        );

        if (base_filters.length == 0) {
            return processing_filters;
        }
        if (processing_filters.length == 0) {
            return base_filters;
        }

        return base_filters + "," + processing_filters;
    }

    public string build_peak_analysis_audio_filter_chain (
        string base_filters,
        AudioProcessingSettingsSnapshot processing,
        double duration = 0.0,
        bool apply_fade_in = true,
        bool apply_fade_out = true) {
        return merge_profile_audio_filter_chain (
            base_filters,
            processing,
            duration,
            false,
            apply_fade_in,
            apply_fade_out
        );
    }

    public string append_volumedetect (string filter_chain) {
        if (filter_chain.length == 0) {
            return "volumedetect";
        }

        return filter_chain + ",volumedetect";
    }

    public string[] extract_peak_analysis_output_args (string[] audio_args) {
        string[] args = {};

        for (int i = 0; i < audio_args.length; i++) {
            string arg = audio_args[i];

            if ((arg == "-ac" || arg == "-ar") && i + 1 < audio_args.length) {
                args += arg;
                args += audio_args[i + 1];
                i++;
            }
        }

        return args;
    }

    public string[] build_audio_peak_detect_cmd (
        string input_file,
        string filter_chain,
        string[]? pre_input_args = null,
        string[]? post_input_args = null,
        string[]? output_args = null,
        string? audio_map = null) {
        string[] cmd = { AppSettings.get_default ().ffmpeg_path, "-hide_banner" };

        if (pre_input_args != null) {
            foreach (unowned string arg in pre_input_args) {
                cmd += arg;
            }
        }

        cmd += "-i";
        cmd += input_file;

        if (post_input_args != null) {
            foreach (unowned string arg in post_input_args) {
                cmd += arg;
            }
        }

        cmd += "-vn";
        cmd += "-sn";

        if (audio_map != null && audio_map.length > 0) {
            cmd += "-map";
            cmd += audio_map;
        }

        cmd += "-af";
        cmd += append_volumedetect (filter_chain);

        if (output_args != null) {
            foreach (unowned string arg in output_args) {
                cmd += arg;
            }
        }

        cmd += "-f";
        cmd += "null";
        cmd += "-";
        return cmd;
    }

    public string[] build_filter_complex_peak_detect_cmd (
        string[] input_args,
        string filter_complex,
        string output_label,
        string[]? output_args = null) {
        string[] cmd = { AppSettings.get_default ().ffmpeg_path, "-hide_banner" };

        foreach (unowned string arg in input_args) {
            cmd += arg;
        }

        cmd += "-vn";
        cmd += "-sn";
        cmd += "-filter_complex";
        cmd += filter_complex;
        cmd += "-map";
        cmd += output_label;

        if (output_args != null) {
            foreach (unowned string arg in output_args) {
                cmd += arg;
            }
        }

        cmd += "-f";
        cmd += "null";
        cmd += "-";
        return cmd;
    }

    public string build_atempo_chain (double multiplier) {
        if (!multiplier.is_finite () || multiplier <= 0.0) {
            warning ("FilterBuilder: Ignoring invalid atempo multiplier %.6f", multiplier);
            return "";
        }

        if (fp_equal (multiplier, 1.0)) return "";

        string[] parts = {};
        double t = multiplier;

        if (multiplier > 1.0) {
            while (t > 2.0) {
                parts += "atempo=2.0";
                t /= 2.0;
            }
        } else if (multiplier < 1.0) {
            while (t < 0.5) {
                parts += "atempo=0.5";
                t /= 0.5;
            }
        }

        if (!fp_equal (t, 1.0)) {
            parts += "atempo=" + ConversionUtils.format_ffmpeg_double (t, "%.6f");
        }

        return string.joinv (",", parts);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  AUDIO FILTER
    // ═════════════════════════════════════════════════════════════════════════

    /**
     *
     * Returns audio_args unmodified when:
     *  • af is empty (nothing to merge)
     *  • audio is disabled (-an)
     *  • audio is stream-copied (-c:a copy) — filters require re-encoding
     *
     * Otherwise, if audio_args already contains -af, the new filters are
     * prepended to the existing chain. If no -af exists, one is appended.
     *
     * @param af          Comma-separated audio filter chain (e.g. "loudnorm=...")
     * @param audio_args  Existing audio arguments from the codec tab
     * @return            Merged audio arguments
     */
    public string[] merge_audio_filters (string af, string[] audio_args) {
        // Nothing to merge
        if (af == "") return audio_args;

        // Cannot apply filters when audio is disabled or stream-copied.
        // The UI prevents copy-mode selections while processing requires
        // re-encoding, so the copy case here is only reached when no audio
        // filters are actually applicable.
        if (audio_args.length > 0 && audio_args[0] == "-an")
            return audio_args;
        if (audio_args.length >= 2 && audio_args[0] == "-c:a" && audio_args[1] == "copy")
            return audio_args;

        // Merge: prepend new filters to any existing -af value
        string[] merged = {};
        bool found_af = false;
        for (int i = 0; i < audio_args.length; i++) {
            if (audio_args[i] == "-af" && i + 1 < audio_args.length) {
                merged += "-af";
                merged += af + "," + audio_args[i + 1];
                i++;
                found_af = true;
            } else {
                merged += audio_args[i];
            }
        }

        // No existing -af — append one
        if (!found_af) {
            merged += "-af";
            merged += af;
        }

        return merged;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  WATERMARK (DRAWTEXT)
    // ═════════════════════════════════════════════════════════════════════════

    private string escape_drawtext_text (string text) {
        // FFmpeg drawtext uses : as key-value separator and \ as escape.
        // With expansion=none, % is safe, but we still escape the structural chars.
        // Use get_char / next_char for proper UTF-8 iteration.
        var escaped = new StringBuilder ();
        int idx = 0;
        unichar c;
        while (text.get_next_char (ref idx, out c)) {
            if (c == '\\' || c == ':' || c == '\'' || c == '[' || c == ']') {
                escaped.append_unichar ('\\');
            }
            escaped.append_unichar (c);
        }
        return escaped.str;
    }

    private bool is_color_bright (string hex) {
        // Relative luminance check (ITU-R BT.601):
        //   L = 0.299*R + 0.587*G + 0.114*B
        // Bright colors get a dark shadow; dark colors get a light shadow.
        uint64 val;
        if (!uint64.try_parse ("0x" + hex, out val)) return true;
        double r = ((val >> 16) & 0xff) / 255.0;
        double g = ((val >> 8) & 0xff) / 255.0;
        double b = (val & 0xff) / 255.0;
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.5;
    }

    private string? build_drawtext_filter (GeneralSettingsSnapshot snapshot) {
        if (!snapshot.watermark_enabled) return null;
        if (snapshot.watermark_mode == "image") return null;

        string text = snapshot.watermark_text;
        if (text.length == 0) return null;

        double opacity = snapshot.watermark_opacity.clamp (0.05, 1.0);
        int margin = int.max (0, snapshot.watermark_margin);
        int font_size = int.max (8, snapshot.watermark_font_size);

        string x_expr;
        string y_expr;
        get_drawtext_position_exprs (snapshot.watermark_position, margin,
            out x_expr, out y_expr);

        string escaped_text = escape_drawtext_text (text);
        string color_hex = snapshot.watermark_color;
        if (color_hex.length != 6) color_hex = "ffffff";

        string alpha_str = ConversionUtils.format_ffmpeg_double (opacity, "%.2f");
        string shadow_color = is_color_bright (color_hex) ? "black" : "white";

        return "drawtext=text='%s':fontsize=%d:fontcolor=0x%s@%s:shadowcolor=%s@0.5:shadowx=2:shadowy=2:x=%s:y=%s:expansion=none".printf (
            escaped_text, font_size, color_hex, alpha_str, shadow_color, x_expr, y_expr);
    }

    // ── Shared watermark position helpers ────────────────────────────────────
    //
    // drawtext uses: w/h for video dimensions, text_w/text_h for text size.
    // overlay uses: main_w/main_h (or W/H) for main video, overlay_w/overlay_h
    //               (or w/h) for the overlay input.

    public static void get_drawtext_position_exprs (string position, int margin,
                                                     out string x_expr,
                                                     out string y_expr) {
        if (position == "Top Left") {
            x_expr = "%d".printf (margin);
            y_expr = "%d".printf (margin);
        } else if (position == "Top Right") {
            x_expr = "w-text_w-%d".printf (margin);
            y_expr = "%d".printf (margin);
        } else if (position == "Bottom Left") {
            x_expr = "%d".printf (margin);
            y_expr = "h-text_h-%d".printf (margin);
        } else if (position == "Bottom Right") {
            x_expr = "w-text_w-%d".printf (margin);
            y_expr = "h-text_h-%d".printf (margin);
        } else {
            // Center
            x_expr = "(w-text_w)/2";
            y_expr = "(h-text_h)/2";
        }
    }

    public static void get_overlay_position_exprs (string position, int margin,
                                                    out string x_expr,
                                                    out string y_expr) {
        if (position == "Top Left") {
            x_expr = "%d".printf (margin);
            y_expr = "%d".printf (margin);
        } else if (position == "Top Right") {
            x_expr = "main_w-overlay_w-%d".printf (margin);
            y_expr = "%d".printf (margin);
        } else if (position == "Bottom Left") {
            x_expr = "%d".printf (margin);
            y_expr = "main_h-overlay_h-%d".printf (margin);
        } else if (position == "Bottom Right") {
            x_expr = "main_w-overlay_w-%d".printf (margin);
            y_expr = "main_h-overlay_h-%d".printf (margin);
        } else {
            // Center
            x_expr = "(main_w-overlay_w)/2";
            y_expr = "(main_h-overlay_h)/2";
        }
    }

    /**
     * Build the overlay filter fragment for image watermarking.
     *
     * Returns the filter text only (e.g. "scale=150:-1,format=rgba,...overlay=x=...:y=...").
     * The caller is responsible for adding the second -i input and wiring
     * the filter_complex labels.
     *
     * @param wm_input_label  label for the watermark input (e.g. "[1:v]" or "[wm]")
     * @param video_label     label for the video input (e.g. "[0:v]" or "[outv_pre]")
     * @param output_label    label for the output (e.g. "[outv]")
     * @param position        position preset string
     * @param margin          margin in pixels
     * @param opacity         opacity 0.05–1.0
     * @param image_width     desired width in pixels, -1 for original
     */
    public static string build_image_overlay_fragment (
        string wm_input_label,
        string video_label,
        string output_label,
        string position,
        int margin,
        double opacity,
        int image_width) {

        string x_expr;
        string y_expr;
        get_overlay_position_exprs (position, int.max (0, margin),
            out x_expr, out y_expr);

        // Build the watermark preparation chain: scale (optional) + format rgba
        string wm_prep = "";
        if (image_width > 0) {
            wm_prep = "scale=%d:-1,".printf (image_width);
        }
        wm_prep += "format=rgba";

        double clamped_opacity = opacity.clamp (0.05, 1.0);
        if (clamped_opacity < 1.0) {
            string alpha_str = ConversionUtils.format_ffmpeg_double (clamped_opacity, "%.2f");
            wm_prep += ",colorchannelmixer=aa=%s".printf (alpha_str);
        }

        return "%s%s[wm_ready]; %s[wm_ready]overlay=x=%s:y=%s%s".printf (
            wm_input_label, wm_prep,
            video_label, x_expr, y_expr, output_label);
    }

    // Detect Crop helper
    public string get_crop_detection_chain (GeneralTab tab) {
        string[] filters = {};
        GeneralSettingsSnapshot snapshot = tab.snapshot_settings ();

        // 1. Rotation / Flip (must come first)
        foreach (string f in get_rotation_filters_from_snapshot (snapshot)) filters += f;

        // 2. Cropdetect
        filters += "cropdetect=24:2:0";

        return string.joinv (",", filters);
    }

    public string get_dropdown_text (DropDown dropdown) {
        var item = dropdown.selected_item as StringObject;
        return item != null ? item.string : "";
    }
}
