using Gtk;

public class FilterBuilder {

    public static string build_video_filter_chain (GeneralTab tab) {
        string[] filters = {};

        // 1. Rotation / Flip
        string rot = get_dropdown_text (tab.rotate_combo);
        if (rot == "90° Clockwise") filters += "transpose=1";
        else if (rot == "90° Counterclockwise") filters += "transpose=2";
        else if (rot == "180°") filters += "transpose=1,transpose=1";
        else if (rot == "Horizontal Flip") filters += "hflip";
        else if (rot == "Vertical Flip") filters += "vflip";

        // 2. Crop
        if (tab.crop_check.active) {
            string c = tab.crop_value.text.strip ();
            if (c.length > 0 && c != "w:h:x:y") {
                if (c.has_prefix ("crop=")) c = c.substring (5);
                filters += "crop=" + c;
            }
        }

        // 3. Quick Filters
        if (tab.deinterlace.active) filters += "yadif";
        if (tab.deblock.active) filters += "deblock";
        if (tab.denoise.active) filters += "hqdn3d=4:3:6:4.5";
        if (tab.sharpen.active) filters += "unsharp=5:5:0.8:3:3:0.4";
        if (tab.grain.active) filters += "noise=alls=12:allf=t";

        // 4. HDR to SDR Tonemap
        if (tab.hdr_tonemap.active) {
            string desat = "0.35";
            string mode = get_dropdown_text (tab.tonemap_mode);
            if (mode == "Less Saturation") desat = "0.00";
            else if (mode == "Custom") desat = tab.tonemap_desat.get_value ().to_string ();

            filters += @"zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=$desat,zscale=t=bt709:m=bt709:r=tv";
        }

        // 5. Scale - clean display + zscale for quality filters
        double sw = tab.scale_width_x.get_value ();
        double sh = tab.scale_height_x.get_value ();
        if (sw != 1.0 || sh != 1.0) {
            // prevents the ugly long decimal
            string w = (sw == 1.0) ? "iw" : @"trunc(iw*%.6f/2)*2".printf (sw);
            string h = (sh == 1.0) ? "ih" : @"trunc(ih*%.6f/2)*2".printf (sh);
            string alg = get_dropdown_text (tab.scale_algorithm).down ();

            if (alg == "point") {
                filters += @"scale=w=$w:h=$h:flags=point";
            } else {
                filters += @"zscale=w=$w:h=$h:filter=$alg";
            }

            string range = get_dropdown_text (tab.scale_range);
            if (range != "input") filters += @"zscale=range=$range";
        }

        // 6. Frame Rate
        string fr = get_dropdown_text (tab.frame_rate_combo);
        if (fr != "Original") {
            string fps = (fr == "Custom") ? tab.custom_frame_rate.text.strip () : fr;
            if (fps.length > 0) filters += "fps=" + fps;
        }

        // 7. Video Speed
        if (tab.video_speed_check.active) {
            double pct = tab.video_speed.get_value ();
            if (pct != 0.0) {
                double mult = 1.0 + pct / 100.0;
                double factor = 1.0 / mult;
                filters += @"setpts=$factor*PTS";
            }
        }

        // 8. Pixel Format
        string pixfmt = "";

        if (tab.ten_bit_check.active) {
            string f = get_dropdown_text (tab.ten_bit_format);
            pixfmt = (f.contains("4:2:0")) ? "yuv420p10le" :
                     (f.contains("4:2:2")) ? "yuv422p10le" : "yuv444p10le";
        } 
        else if (tab.eight_bit_check.active) {
            string f = get_dropdown_text (tab.eight_bit_format);
            pixfmt = (f.contains("4:2:0")) ? "yuv420p" :
                     (f.contains("4:2:2")) ? "yuv422p" : "yuv444p";
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

    private static string get_dropdown_text (DropDown dropdown) {
        var item = dropdown.selected_item as StringObject;
        return item != null ? item.string : "";
    }
    
        public static string build_audio_filter_chain (GeneralTab tab) {
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

    private static string build_atempo_chain (double multiplier) {
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
            parts += @"atempo=$t";
        }

        return string.joinv (",", parts);
    }
    
        // Detect Crop helper
    public static string get_crop_detection_chain (GeneralTab tab) {
        string[] filters = {};

        // 1. Rotation / Flip (must come first)
        string rot = get_dropdown_text (tab.rotate_combo);
        if (rot == "90° Clockwise") filters += "transpose=1";
        else if (rot == "90° Counterclockwise") filters += "transpose=2";
        else if (rot == "180°") filters += "transpose=1,transpose=1";
        else if (rot == "Horizontal Flip") filters += "hflip";
        else if (rot == "Vertical Flip") filters += "vflip";

        // 2. Scale check
        double sw = tab.scale_width_x.get_value ();
        double sh = tab.scale_height_x.get_value ();
        if (sw != 1.0 || sh != 1.0) {
            // Scale is active
        }

        // 3. Cropdetect
        filters += "cropdetect=24:2:0";

        return string.joinv (",", filters);
    }
    
}
