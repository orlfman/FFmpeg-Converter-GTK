using Gtk;

// ═══════════════════════════════════════════════════════════════════════════════
//  FilterBuilder — Pure utility functions for building FFmpeg filter chains
//
//  Converted from a class with only static methods to a namespace (#15).
//  Uses named constants from constants.vala instead of bare strings (#14).
// ═══════════════════════════════════════════════════════════════════════════════

namespace FilterBuilder {

    public string build_video_filter_chain (GeneralTab tab, bool skip_crop = false) {
        string[] filters = {};

        // 1. Rotation / Flip
        string rot = get_dropdown_text (tab.rotate_combo);
        if (rot == Rotation.CW_90) filters += "transpose=1";
        else if (rot == Rotation.CCW_90) filters += "transpose=2";
        else if (rot == Rotation.ROTATE_180) filters += "transpose=1,transpose=1";
        else if (rot == Rotation.HORIZONTAL_FLIP) filters += "hflip";
        else if (rot == Rotation.VERTICAL_FLIP) filters += "vflip";

        // 2. Crop (skipped when the Crop & Trim tab provides its own)
        if (!skip_crop && tab.crop_check.active) {
            string c = tab.crop_value.text.strip ();
            if (c.length > 0 && c != "w:h:x:y") {
                if (c.has_prefix ("crop=")) c = c.substring (5);
                filters += "crop=" + c;
            }
        }

        // 3. Video Processing Filters
        foreach (string f in tab.video_filters.get_processing_filters ()) {
            filters += f;
        }

        // 4. HDR to SDR Tonemap
        string hdr = tab.video_filters.get_hdr_filter ();
        if (hdr.length > 0) filters += hdr;

        // 5. Scale - clean display + zscale for quality filters
        double sw = tab.scale_width_x.get_value ();
        double sh = tab.scale_height_x.get_value ();
        if (sw != 1.0 || sh != 1.0) {
            string w = (sw == 1.0) ? "iw" : @"trunc(iw*%.6f/2)*2".printf (sw);
            string h = (sh == 1.0) ? "ih" : @"trunc(ih*%.6f/2)*2".printf (sh);
            string alg = get_dropdown_text (tab.scale_algorithm).down ();

            if (alg == ScaleAlgorithm.POINT) {
                filters += @"scale=w=$w:h=$h:flags=point";
            } else {
                filters += @"zscale=w=$w:h=$h:filter=$alg";
            }

            string range = get_dropdown_text (tab.scale_range);
            if (range != "input") filters += @"zscale=range=$range";
        }

        // 6. Frame Rate
        string fr = get_dropdown_text (tab.frame_rate_combo);
        if (fr != FrameRateLabel.ORIGINAL) {
            string fps = (fr == FrameRateLabel.CUSTOM) ? tab.custom_frame_rate.text.strip () : fr;
            if (fps.length > 0) filters += "fps=" + fps;
        }

        // 7. Video Speed
        if (tab.video_speed_check.active) {
            double pct = tab.video_speed.get_value ();
            if (pct != 0.0) {
                double mult = 1.0 + pct / 100.0;
                double factor = 1.0 / mult;
                filters += "setpts=%.6f*PTS".printf (factor);
            }
        }

        // 8. Pixel Format
        string pixfmt = "";

        if (tab.ten_bit_check.active) {
            string f = get_dropdown_text (tab.ten_bit_format);
            pixfmt = f.contains (Chroma.C420) ? PixelFormat.YUV420P10LE :
                     f.contains (Chroma.C422) ? PixelFormat.YUV422P10LE :
                                                PixelFormat.YUV444P10LE;
        }
        else if (tab.eight_bit_check.active) {
            string f = get_dropdown_text (tab.eight_bit_format);
            pixfmt = f.contains (Chroma.C420) ? PixelFormat.YUV420P :
                     f.contains (Chroma.C422) ? PixelFormat.YUV422P :
                                                PixelFormat.YUV444P;
        }

        if (pixfmt != "") {
            filters += "format=" + pixfmt;
        }

        // Color Correction
        string cc = tab.get_color_filter ();
        if (cc.length > 0)
            filters += cc;

        return filters.length > 0 ? string.joinv (",", filters) : "";
    }

    public string build_audio_filter_chain (GeneralTab tab) {
        string[] filters = {};

        // Normalize Audio
        if (tab.normalize_audio.active) {
            filters += "loudnorm=I=-23:TP=-1.5:LRA=11";
        }

        // Audio Speed
        if (tab.audio_speed_check.active) {
            double pct = tab.audio_speed.get_value ();
            if (pct != 0.0) {
                double m = 1.0 + pct / 100.0;
                string chain = build_atempo_chain (m);
                if (chain.length > 0) filters += chain;
            }
        }

        return filters.length > 0 ? string.joinv (",", filters) : "";
    }

    public string build_atempo_chain (double multiplier) {
        if (multiplier == 1.0) return "";

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

        if (t != 1.0) {
            parts += "atempo=%.6f".printf (t);
        }

        return string.joinv (",", parts);
    }

    // Detect Crop helper
    public string get_crop_detection_chain (GeneralTab tab) {
        string[] filters = {};

        // 1. Rotation / Flip (must come first)
        string rot = get_dropdown_text (tab.rotate_combo);
        if (rot == Rotation.CW_90) filters += "transpose=1";
        else if (rot == Rotation.CCW_90) filters += "transpose=2";
        else if (rot == Rotation.ROTATE_180) filters += "transpose=1,transpose=1";
        else if (rot == Rotation.HORIZONTAL_FLIP) filters += "hflip";
        else if (rot == Rotation.VERTICAL_FLIP) filters += "vflip";

        // 2. Cropdetect
        filters += "cropdetect=24:2:0";

        return string.joinv (",", filters);
    }

    public string get_dropdown_text (DropDown dropdown) {
        var item = dropdown.selected_item as StringObject;
        return item != null ? item.string : "";
    }
}
