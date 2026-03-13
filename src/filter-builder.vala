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

    public string build_video_filter_chain_from_snapshot (GeneralSettingsSnapshot snapshot,
                                                          bool skip_crop = false,
                                                          string codec_name = "") {
        string[] filters = {};

        // 1. Rotation / Flip
        string[] rot_filters = get_rotation_filters_from_snapshot (snapshot);
        bool has_vflip = false;
        foreach (string f in rot_filters) {
            filters += f;
            if (f == "vflip") has_vflip = true;
        }

        // SVT-AV1 workaround: vflip produces frames with negative line strides
        // which SVT-AV1's API rejects (EB_ErrorBadParameter).  A format=
        // filter alone is not enough — ffmpeg's format filter is a no-op when
        // the input already matches (e.g. yuv420p→yuv420p), so negative strides
        // pass through.  scale=iw:ih forces swscale to allocate a new buffer
        // with positive strides regardless of pixel format.
        if (has_vflip && codec_name.down ().contains ("svt")) {
            filters += "scale=iw:ih";
        }

        // 2. Crop (skipped when the Crop & Trim tab provides its own)
        if (!skip_crop && snapshot.crop_enabled) {
            string c = snapshot.crop_value;
            if (c.length > 0 && c != "w:h:x:y") {
                if (c.has_prefix ("crop=")) c = c.substring (5);
                filters += "crop=" + c;
            }
        }

        // 3. Video Processing Filters
        foreach (string f in snapshot.video_filters.processing_filters) {
            filters += f;
        }

        // 4. HDR to SDR Tonemap
        string hdr = snapshot.video_filters.hdr_filter;
        if (hdr.length > 0) filters += hdr;

        // 5. Scale
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

        // 6. Frame Rate
        string fr = snapshot.frame_rate_text;
        if (fr != FrameRateLabel.ORIGINAL) {
            string fps = (fr == FrameRateLabel.CUSTOM) ? snapshot.custom_frame_rate_text : fr;
            if (fps.length > 0) filters += "fps=" + fps;
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

        // 9. Color Correction
        string cc = snapshot.color_filter;
        if (cc.length > 0)
            filters += cc;

        return filters.length > 0 ? string.joinv (",", filters) : "";
    }

    public string build_audio_filter_chain (GeneralTab tab) {
        return build_audio_filter_chain_from_snapshot (tab.snapshot_settings ());
    }

    public string build_audio_filter_chain_from_snapshot (GeneralSettingsSnapshot snapshot) {
        string[] filters = {};

        // Normalize Audio
        if (snapshot.normalize_audio) {
            filters += "loudnorm=I=-23:TP=-1.5:LRA=11";
        }

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
        // Note: AudioSettings.update_for_normalize() prevents the user from
        // selecting "Copy" when normalize is enabled, so the copy case here
        // is only reached when no audio filters are actually needed.
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
