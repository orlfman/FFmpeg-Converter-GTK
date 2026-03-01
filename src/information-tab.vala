using Gtk;
using Adw;
using GLib;

// Internal data class to ferry parsed ffprobe results between threads
internal class VideoInfo : Object {
    // File
    public string filename    = "N/A";
    public string file_size   = "N/A";
    public string container   = "N/A";
    public string duration    = "N/A";
    public string title       = "N/A";

    // Video
    public string resolution  = "N/A";
    public string aspect      = "N/A";
    public string video_codec = "N/A";
    public string video_profile = "N/A";
    public string frame_rate  = "N/A";
    public string bit_rate    = "N/A";
    public string pix_fmt     = "N/A";
    public string color_depth = "N/A";
    public string color_space = "N/A";
    public string hdr_format  = "N/A";
    public string scan_type   = "N/A";
    public string keyframe_count = "N/A";

    // Audio
    public string audio_codec       = "N/A";
    public string audio_channels    = "N/A";
    public string sample_rate       = "N/A";
    public string audio_bitrate     = "N/A";
    public string audio_compression = "N/A";

    // Subtitles
    public string subtitle_info = "N/A";
}

public class InformationTab : Box {

    // ── Stack controls which "page" is visible ────────────────────────────────
    private Stack main_stack;

    // ── Input section value labels ────────────────────────────────────────────
    private Label iv_filename;
    private Label iv_size;
    private Label iv_container;
    private Label iv_duration;
    private Label iv_title;

    private Label iv_resolution;
    private Label iv_aspect;
    private Label iv_vcodec;
    private Label iv_profile;
    private Label iv_fps;
    private Label iv_bitrate;
    private Label iv_pixfmt;
    private Label iv_depth;
    private Label iv_colorspace;
    private Label iv_hdr;
    private Label iv_scan;
    private Label iv_keyframes;

    private Adw.ActionRow iv_profile_row;
    private Adw.ActionRow iv_hdr_row;
    private Adw.ActionRow iv_scan_row;
    private Adw.ActionRow iv_keyframes_row;

    private Label iv_acodec;
    private Label iv_channels;
    private Label iv_samplerate;
    private Label iv_a_bitrate;
    private Label iv_a_compression;

    private Adw.ActionRow iv_a_bitrate_row;
    private Adw.ActionRow iv_a_compression_row;

    private Label iv_subtitle;
    private Adw.PreferencesGroup iv_subtitle_group;

    // ── Output section value labels + revealer ────────────────────────────────
    private Revealer output_revealer;

    private Label ov_filename;
    private Label ov_size;
    private Label ov_container;
    private Label ov_duration;

    private Label ov_resolution;
    private Label ov_aspect;
    private Label ov_vcodec;
    private Label ov_profile;
    private Label ov_fps;
    private Label ov_bitrate;
    private Label ov_pixfmt;
    private Label ov_depth;
    private Label ov_colorspace;
    private Label ov_hdr;
    private Label ov_scan;
    private Label ov_keyframes;

    private Adw.ActionRow ov_profile_row;
    private Adw.ActionRow ov_hdr_row;
    private Adw.ActionRow ov_scan_row;
    private Adw.ActionRow ov_keyframes_row;

    private Label ov_acodec;
    private Label ov_channels;
    private Label ov_samplerate;
    private Label ov_a_bitrate;
    private Label ov_a_compression;

    private Adw.ActionRow ov_a_bitrate_row;
    private Adw.ActionRow ov_a_compression_row;

    private Label ov_subtitle;
    private Adw.PreferencesGroup ov_subtitle_group;

    public InformationTab () {
        Object (orientation: Orientation.VERTICAL, spacing: 0);
        build_ui ();
    }

    // ── UI Construction ───────────────────────────────────────────────────────

    private void build_ui () {
        main_stack = new Stack ();
        main_stack.set_transition_type (StackTransitionType.CROSSFADE);
        main_stack.set_transition_duration (200);
        main_stack.set_vexpand (true);
        main_stack.set_hexpand (true);
        append (main_stack);

        build_empty_page ();
        build_info_page ();

        main_stack.set_visible_child_name ("empty");
    }

    private void build_empty_page () {
        var status = new Adw.StatusPage ();
        status.set_icon_name ("video-x-generic-symbolic");
        status.set_title ("No File Selected");
        status.set_description ("Select an input file to view detailed media information.");
        status.set_vexpand (true);
        main_stack.add_named (status, "empty");
    }

    private void build_info_page () {
        var scroll = new ScrolledWindow ();
        scroll.set_policy (PolicyType.NEVER, PolicyType.AUTOMATIC);
        scroll.set_vexpand (true);

        // Adw.Clamp gives a nice centred, max-width layout
        var clamp = new Adw.Clamp ();
        clamp.set_maximum_size (840);
        clamp.set_tightening_threshold (640);

        var content = new Box (Orientation.VERTICAL, 20);
        content.set_margin_top (28);
        content.set_margin_bottom (40);
        content.set_margin_start (12);
        content.set_margin_end (12);

        // ────────────── Input: File ──────────────────────────────────────────
        var in_file_group = new Adw.PreferencesGroup ();
        in_file_group.set_title ("Input File");
        in_file_group.set_description ("Properties of the selected source file");

        iv_filename  = make_row (in_file_group, "File Name");
        iv_size      = make_row (in_file_group, "File Size");
        iv_container = make_row (in_file_group, "Container");
        iv_duration  = make_row (in_file_group, "Duration");
        iv_title     = make_row (in_file_group, "Title");
        content.append (in_file_group);

        // ────────────── Input: Video ─────────────────────────────────────────
        var in_video_group = new Adw.PreferencesGroup ();
        in_video_group.set_title ("Video Stream");

        iv_resolution = make_row (in_video_group, "Resolution");
        iv_aspect     = make_row (in_video_group, "Aspect Ratio");
        iv_vcodec     = make_row (in_video_group, "Codec");
        iv_profile    = make_row_conditional (in_video_group, "Profile / Level", out iv_profile_row);
        iv_fps        = make_row (in_video_group, "Frame Rate");
        iv_bitrate    = make_row (in_video_group, "Bit Rate");
        iv_pixfmt     = make_row (in_video_group, "Pixel Format");
        iv_depth      = make_row (in_video_group, "Color Depth");
        iv_colorspace = make_row (in_video_group, "Color Space");
        iv_hdr        = make_row_conditional (in_video_group, "HDR", out iv_hdr_row);
        iv_scan       = make_row_conditional (in_video_group, "Scan Type", out iv_scan_row);
        iv_keyframes  = make_row_conditional (in_video_group, "Keyframes", out iv_keyframes_row);
        content.append (in_video_group);

        // ────────────── Input: Audio ─────────────────────────────────────────
        var in_audio_group = new Adw.PreferencesGroup ();
        in_audio_group.set_title ("Audio Stream");

        iv_acodec        = make_row (in_audio_group, "Codec");
        iv_channels      = make_row (in_audio_group, "Channels");
        iv_samplerate    = make_row (in_audio_group, "Sample Rate");
        iv_a_bitrate     = make_row_conditional (in_audio_group, "Bit Rate", out iv_a_bitrate_row);
        iv_a_compression = make_row_conditional (in_audio_group, "Compression Level", out iv_a_compression_row);
        content.append (in_audio_group);

        // ────────────── Input: Subtitles (conditional group) ─────────────────
        iv_subtitle_group = new Adw.PreferencesGroup ();
        iv_subtitle_group.set_title ("Subtitle Streams");
        iv_subtitle_group.set_visible (false);
        iv_subtitle = make_row (iv_subtitle_group, "Tracks");
        content.append (iv_subtitle_group);

        // ────────────── Output (hidden until conversion done) ────────────────
        output_revealer = new Revealer ();
        output_revealer.set_transition_type (RevealerTransitionType.SLIDE_DOWN);
        output_revealer.set_transition_duration (450);
        output_revealer.set_reveal_child (false);

        var out_box = new Box (Orientation.VERTICAL, 20);
        out_box.set_margin_top (4);

        // Decorative section separator
        var sep = new Separator (Orientation.HORIZONTAL);
        sep.set_margin_top (8);
        sep.set_margin_bottom (8);
        out_box.append (sep);

        // Output: File
        var out_file_group = new Adw.PreferencesGroup ();
        out_file_group.set_title ("Output File");
        out_file_group.set_description ("Properties of the encoded output file");

        ov_filename  = make_row (out_file_group, "File Name");
        ov_size      = make_row (out_file_group, "File Size");
        ov_container = make_row (out_file_group, "Container");
        ov_duration  = make_row (out_file_group, "Duration");
        out_box.append (out_file_group);

        // Output: Video
        var out_video_group = new Adw.PreferencesGroup ();
        out_video_group.set_title ("Output Video Stream");

        ov_resolution = make_row (out_video_group, "Resolution");
        ov_aspect     = make_row (out_video_group, "Aspect Ratio");
        ov_vcodec     = make_row (out_video_group, "Codec");
        ov_profile    = make_row_conditional (out_video_group, "Profile / Level", out ov_profile_row);
        ov_fps        = make_row (out_video_group, "Frame Rate");
        ov_bitrate    = make_row (out_video_group, "Bit Rate");
        ov_pixfmt     = make_row (out_video_group, "Pixel Format");
        ov_depth      = make_row (out_video_group, "Color Depth");
        ov_colorspace = make_row (out_video_group, "Color Space");
        ov_hdr        = make_row_conditional (out_video_group, "HDR", out ov_hdr_row);
        ov_scan       = make_row_conditional (out_video_group, "Scan Type", out ov_scan_row);
        ov_keyframes  = make_row_conditional (out_video_group, "Keyframes", out ov_keyframes_row);
        out_box.append (out_video_group);

        // Output: Audio
        var out_audio_group = new Adw.PreferencesGroup ();
        out_audio_group.set_title ("Output Audio Stream");

        ov_acodec        = make_row (out_audio_group, "Codec");
        ov_channels      = make_row (out_audio_group, "Channels");
        ov_samplerate    = make_row (out_audio_group, "Sample Rate");
        ov_a_bitrate     = make_row_conditional (out_audio_group, "Bit Rate", out ov_a_bitrate_row);
        ov_a_compression = make_row_conditional (out_audio_group, "Compression Level", out ov_a_compression_row);
        out_box.append (out_audio_group);

        // Output: Subtitles (conditional group)
        ov_subtitle_group = new Adw.PreferencesGroup ();
        ov_subtitle_group.set_title ("Output Subtitle Streams");
        ov_subtitle_group.set_visible (false);
        ov_subtitle = make_row (ov_subtitle_group, "Tracks");
        out_box.append (ov_subtitle_group);

        output_revealer.set_child (out_box);
        content.append (output_revealer);

        clamp.set_child (content);
        scroll.set_child (clamp);
        main_stack.add_named (scroll, "info");
    }

    // Creates a display row: title on the left, selectable value label on the right
    private Label make_row (Adw.PreferencesGroup group, string title) {
        var row = new Adw.ActionRow ();
        row.set_title (title);

        var val = new Label ("—");
        val.add_css_class ("dim-label");
        val.set_selectable (true);
        val.set_ellipsize (Pango.EllipsizeMode.MIDDLE);
        val.set_max_width_chars (42);
        val.set_halign (Align.END);
        row.add_suffix (val);

        group.add (row);
        return val;
    }

    // Same as make_row but also returns the ActionRow via an out parameter
    // so the caller can toggle its visibility.
    private Label make_row_conditional (Adw.PreferencesGroup group, string title,
                                        out Adw.ActionRow out_row) {
        out_row = new Adw.ActionRow ();
        out_row.set_title (title);
        out_row.set_visible (false);

        var val = new Label ("—");
        val.add_css_class ("dim-label");
        val.set_selectable (true);
        val.set_ellipsize (Pango.EllipsizeMode.MIDDLE);
        val.set_max_width_chars (42);
        val.set_halign (Align.END);
        out_row.add_suffix (val);

        group.add (out_row);
        return val;
    }

    // ── Public API ────────────────────────────────────────────────────────────

    // Call when the input file path changes (even to "")
    public void load_input_info (string file_path) {
        if (file_path.strip () == "") {
            main_stack.set_visible_child_name ("empty");
            return;
        }

        main_stack.set_visible_child_name ("info");
        set_input_loading ();

        new Thread<void> ("info-input", () => {
            var info = probe_file (file_path);
            Idle.add (() => {
                populate_input (info);
                return Source.REMOVE;
            });
        });
    }

    // Call after a successful conversion with the output file path
    public void load_output_info (string file_path) {
        if (file_path.strip () == "") return;

        new Thread<void> ("info-output", () => {
            var info = probe_file (file_path);
            Idle.add (() => {
                populate_output (info);
                output_revealer.set_reveal_child (true);
                return Source.REMOVE;
            });
        });
    }

    // Call when a new input file is selected so stale output data is hidden
    public void reset_output () {
        Idle.add (() => {
            output_revealer.set_reveal_child (false);
            return Source.REMOVE;
        });
    }

    // ── Internal label helpers ────────────────────────────────────────────────

    private void set_input_loading () {
        iv_filename.set_text ("…");
        iv_size.set_text ("…");
        iv_container.set_text ("…");
        iv_duration.set_text ("…");
        iv_title.set_text ("…");

        iv_resolution.set_text ("…");
        iv_aspect.set_text ("…");
        iv_vcodec.set_text ("…");
        iv_profile_row.set_visible (false);
        iv_fps.set_text ("…");
        iv_bitrate.set_text ("…");
        iv_pixfmt.set_text ("…");
        iv_depth.set_text ("…");
        iv_colorspace.set_text ("…");
        iv_hdr_row.set_visible (false);
        iv_scan_row.set_visible (false);
        iv_keyframes_row.set_visible (false);

        iv_acodec.set_text ("…");
        iv_channels.set_text ("…");
        iv_samplerate.set_text ("…");
        iv_a_bitrate_row.set_visible (false);
        iv_a_compression_row.set_visible (false);

        iv_subtitle_group.set_visible (false);
    }

    private void populate_input (VideoInfo i) {
        iv_filename.set_text (i.filename);
        iv_size.set_text (i.file_size);
        iv_container.set_text (i.container);
        iv_duration.set_text (i.duration);
        iv_title.set_text (i.title);

        iv_resolution.set_text (i.resolution);
        iv_aspect.set_text (i.aspect);
        iv_vcodec.set_text (i.video_codec);
        show_conditional (iv_profile_row, iv_profile, i.video_profile);
        iv_fps.set_text (i.frame_rate);
        iv_bitrate.set_text (i.bit_rate);
        iv_pixfmt.set_text (i.pix_fmt);
        iv_depth.set_text (i.color_depth);
        iv_colorspace.set_text (i.color_space);
        show_conditional (iv_hdr_row, iv_hdr, i.hdr_format);
        show_conditional (iv_scan_row, iv_scan, i.scan_type);
        show_conditional (iv_keyframes_row, iv_keyframes, i.keyframe_count);

        iv_acodec.set_text (i.audio_codec);
        iv_channels.set_text (i.audio_channels);
        iv_samplerate.set_text (i.sample_rate);
        show_conditional (iv_a_bitrate_row, iv_a_bitrate, i.audio_bitrate);
        show_conditional (iv_a_compression_row, iv_a_compression, i.audio_compression);

        bool has_subs = (i.subtitle_info != "N/A");
        iv_subtitle_group.set_visible (has_subs);
        if (has_subs) iv_subtitle.set_text (i.subtitle_info);
    }

    private void populate_output (VideoInfo i) {
        ov_filename.set_text (i.filename);
        ov_size.set_text (i.file_size);
        ov_container.set_text (i.container);
        ov_duration.set_text (i.duration);

        ov_resolution.set_text (i.resolution);
        ov_aspect.set_text (i.aspect);
        ov_vcodec.set_text (i.video_codec);
        show_conditional (ov_profile_row, ov_profile, i.video_profile);
        ov_fps.set_text (i.frame_rate);
        ov_bitrate.set_text (i.bit_rate);
        ov_pixfmt.set_text (i.pix_fmt);
        ov_depth.set_text (i.color_depth);
        ov_colorspace.set_text (i.color_space);
        show_conditional (ov_hdr_row, ov_hdr, i.hdr_format);
        show_conditional (ov_scan_row, ov_scan, i.scan_type);
        show_conditional (ov_keyframes_row, ov_keyframes, i.keyframe_count);

        ov_acodec.set_text (i.audio_codec);
        ov_channels.set_text (i.audio_channels);
        ov_samplerate.set_text (i.sample_rate);
        show_conditional (ov_a_bitrate_row, ov_a_bitrate, i.audio_bitrate);
        show_conditional (ov_a_compression_row, ov_a_compression, i.audio_compression);

        bool has_subs = (i.subtitle_info != "N/A");
        ov_subtitle_group.set_visible (has_subs);
        if (has_subs) ov_subtitle.set_text (i.subtitle_info);
    }

    /**
     * Show a conditional row if the value is not "N/A", otherwise hide it.
     */
    private static void show_conditional (Adw.ActionRow row, Label label, string val) {
        bool show = (val != "N/A");
        row.set_visible (show);
        if (show) label.set_text (val);
    }

    // ── ffprobe probing (runs on background thread) ───────────────────────────

    private VideoInfo probe_file (string file_path) {
        var info = new VideoInfo ();

        // ── Basic filesystem metadata ─────────────────────────────────────────
        info.filename = Path.get_basename (file_path);

        int dot = file_path.last_index_of_char ('.');
        info.container = (dot >= 0) ? file_path.substring (dot + 1).up () : "N/A";

        try {
            var f  = GLib.File.new_for_path (file_path);
            var fi = f.query_info ("standard::size", GLib.FileQueryInfoFlags.NONE);
            int64 bytes = fi.get_size ();
            if (bytes > 0) {
                double mb = (double) bytes / 1024.0 / 1024.0;
                if (mb >= 1024.0)
                    info.file_size = "%.2f GB".printf (mb / 1024.0);
                else
                    info.file_size = "%.2f MB".printf (mb);
            }
        } catch (Error e) {}

        // ── Run ffprobe ───────────────────────────────────────────────────────
        try {
            string[] cmd = {
                "ffprobe", "-v", "error",
                "-show_format", "-show_streams",
                file_path
            };
            string stdout_text, stderr_text;
            int exit_status;

            Process.spawn_sync (null, cmd, null, SpawnFlags.SEARCH_PATH,
                                null, out stdout_text, out stderr_text, out exit_status);

            if (exit_status == 0 && stdout_text != null && stdout_text.length > 0)
                parse_ffprobe (stdout_text, info);
        } catch (Error e) {
            info.video_codec = "Probe failed";
        }

        // ── Count keyframes (separate fast probe via packet flags) ────────────
        info.keyframe_count = count_keyframes (file_path);

        return info;
    }

    // Parses the key=value ffprobe output.
    private void parse_ffprobe (string output, VideoInfo info) {
        // Each section maps key→value; we build them on the fly
        HashTable<string, string>? current_map    = null;
        HashTable<string, string>? current_stream = null;
        HashTable<string, string>? best_video     = null;
        HashTable<string, string>? first_audio    = null;
        HashTable<string, string>? format_map     = null;

        bool current_is_video        = false;
        bool current_is_audio        = false;
        bool current_is_subtitle     = false;
        bool current_is_attached_pic = false;
        bool best_is_preferred       = false;

        int  subtitle_count = 0;
        GenericArray<string> subtitle_langs = new GenericArray<string> ();

        // Prefer real video streams over raw/other streams
        string[] preferred_codecs = { "h264", "hevc", "av1", "vp9", "vp8" };

        foreach (string raw in output.split ("\n")) {
            string line = raw.strip ();

            if (line == "[STREAM]") {
                current_stream        = new HashTable<string, string> (str_hash, str_equal);
                current_is_video      = false;
                current_is_audio      = false;
                current_is_subtitle   = false;
                current_is_attached_pic = false;
                current_map           = current_stream;

            } else if (line == "[/STREAM]") {
                if (current_stream != null && !current_is_attached_pic) {
                    if (current_is_video) {
                        // Keep this stream if it's preferred (or if we have nothing yet)
                        string codec = current_stream.get ("codec_name") ?? "";
                        bool is_pref = false;
                        foreach (string p in preferred_codecs) {
                            if (codec == p) { is_pref = true; break; }
                        }
                        if (best_video == null || (is_pref && !best_is_preferred)) {
                            best_video       = current_stream;
                            best_is_preferred = is_pref;
                        }
                    } else if (current_is_audio && first_audio == null) {
                        first_audio = current_stream;
                    } else if (current_is_subtitle) {
                        subtitle_count++;
                        string lang = current_stream.get ("TAG:language") ?? "";
                        if (lang.length > 0 && lang != "und")
                            subtitle_langs.add (lang);
                    }
                }
                current_stream = null;
                current_map    = null;

            } else if (line == "[FORMAT]") {
                format_map  = new HashTable<string, string> (str_hash, str_equal);
                current_map = format_map;

            } else if (line == "[/FORMAT]") {
                current_map = null;

            } else if (current_map != null) {
                int eq = line.index_of_char ('=');
                if (eq <= 0) continue;

                string key = line.substring (0, eq).strip ();
                string val = line.substring (eq + 1).strip ();
                current_map.set (key, val);

                // Track stream type as we go so we know what section we're in
                if (current_stream != null) {
                    if (key == "codec_type") {
                        current_is_video    = (val == "video");
                        current_is_audio    = (val == "audio");
                        current_is_subtitle = (val == "subtitle");
                    } else if (key == "disposition:attached_pic" && val == "1") {
                        current_is_attached_pic = true; // cover art — skip
                    }
                }
            }
        }

        // ── Extract video stream data ─────────────────────────────────────────
        if (best_video != null) {
            string w = best_video.get ("width")  ?? "?";
            string h = best_video.get ("height") ?? "?";
            info.resolution = w + " × " + h;

            info.aspect      = best_video.get ("display_aspect_ratio") ?? "N/A";
            info.video_codec = best_video.get ("codec_name") ?? "N/A";

            // Profile / Level
            string profile = best_video.get ("profile") ?? "";
            string level   = best_video.get ("level")   ?? "";
            if (profile.length > 0 && profile != "unknown") {
                if (level.length > 0 && level != "unknown" && level != "-99") {
                    // ffprobe reports level as an integer (e.g. 41 → 4.1)
                    int64 lv = int64.parse (level);
                    if (lv > 9)
                        info.video_profile = "%s @ %.1f".printf (profile, lv / 10.0);
                    else
                        info.video_profile = "%s @ %s".printf (profile, level);
                } else {
                    info.video_profile = profile;
                }
            }

            string fps_raw = best_video.get ("avg_frame_rate") ?? "N/A";
            if (fps_raw == "N/A" || fps_raw == "0/0")
                fps_raw = best_video.get ("r_frame_rate") ?? "N/A";
            info.frame_rate = format_fps (fps_raw);

            // Bit rate: prefer stream-level, fall back to TAG:BPS (Matroska), then container-level
            string br = best_video.get ("bit_rate") ?? "N/A";
            if (br == "N/A" || br == "0" || int64.parse (br) <= 0)
                br = best_video.get ("TAG:BPS") ?? "N/A";
            if (br == "N/A" || br == "0" || int64.parse (br) <= 0)
                br = best_video.get ("TAG:BPS-eng") ?? "N/A";
            if (br == "N/A" || br == "0" || int64.parse (br) <= 0)
                br = (format_map != null) ? (format_map.get ("bit_rate") ?? "N/A") : "N/A";
            if (br != "N/A") {
                int64 bri = int64.parse (br);
                if (bri > 0)
                    info.bit_rate = (bri / 1000).to_string () + " kbps";
            }

            // Pixel format and inferred color depth
            string pix = best_video.get ("pix_fmt") ?? "N/A";
            info.pix_fmt = pix;
            if (pix.contains ("12le") || pix.contains ("12be"))
                info.color_depth = "12-bit";
            else if (pix.contains ("10le") || pix.contains ("10be") || pix.contains ("p010"))
                info.color_depth = "10-bit";
            else if (pix != "N/A")
                info.color_depth = "8-bit";

            info.color_space = best_video.get ("color_space") ?? "N/A";

            // HDR detection via color transfer characteristics
            string transfer  = best_video.get ("color_transfer")  ?? "";
            string primaries = best_video.get ("color_primaries") ?? "";
            if (transfer == "smpte2084")
                info.hdr_format = "HDR10 (PQ)";
            else if (transfer == "arib-std-b67")
                info.hdr_format = "HLG";
            else if (primaries == "bt2020")
                info.hdr_format = "BT.2020 (wide gamut)";
            // else stays "N/A" → row hidden

            // Interlacing detection via field_order
            string fo = best_video.get ("field_order") ?? "";
            if (fo == "tt")
                info.scan_type = "Interlaced (TFF)";
            else if (fo == "bb")
                info.scan_type = "Interlaced (BFF)";
            else if (fo == "tb")
                info.scan_type = "Interlaced (TFF, mixed)";
            else if (fo == "bt")
                info.scan_type = "Interlaced (BFF, mixed)";
            // "progressive" and "" → stays "N/A" → row hidden
        }

        // ── Extract audio stream data ─────────────────────────────────────────
        if (first_audio != null) {
            info.audio_codec = first_audio.get ("codec_name") ?? "N/A";

            // Channels
            string layout = first_audio.get ("channel_layout") ?? "";
            string ch_str = first_audio.get ("channels") ?? "";
            if (layout.length > 0) {
                info.audio_channels = format_channel_layout (layout);
            } else if (ch_str.length > 0) {
                int ch = int.parse (ch_str);
                info.audio_channels = format_channel_count (ch);
            }

            string sr = first_audio.get ("sample_rate") ?? "N/A";
            if (sr != "N/A" && sr.length > 0) {
                int sr_int = int.parse (sr);
                info.sample_rate = (sr_int >= 1000)
                    ? "%.1f kHz".printf (sr_int / 1000.0)
                    : sr + " Hz";
            }

            // Audio bit rate — fall back to TAG:BPS (Matroska/WebM) for VBR codecs like Opus
            string abr = first_audio.get ("bit_rate") ?? "N/A";
            if (abr == "N/A" || abr == "0" || int64.parse (abr) <= 0)
                abr = first_audio.get ("TAG:BPS") ?? "N/A";
            if (abr == "N/A" || abr == "0" || int64.parse (abr) <= 0)
                abr = first_audio.get ("TAG:BPS-eng") ?? "N/A";
            if (abr != "N/A" && abr.length > 0) {
                int64 abri = int64.parse (abr);
                if (abri > 0)
                    info.audio_bitrate = (abri / 1000).to_string () + " kbps";
            }

            // FLAC compression level (only present for FLAC streams)
            string cl = first_audio.get ("compression_level") ?? "";
            if (cl.length > 0 && cl != "N/A")
                info.audio_compression = cl;
        }

        // ── Subtitle info ─────────────────────────────────────────────────────
        if (subtitle_count > 0) {
            if (subtitle_langs.length > 0) {
                var sb = new StringBuilder ();
                sb.append ("%d track%s (".printf (
                    subtitle_count, subtitle_count == 1 ? "" : "s"));
                for (int i = 0; i < subtitle_langs.length; i++) {
                    if (i > 0) sb.append (", ");
                    sb.append (subtitle_langs[i]);
                }
                sb.append (")");
                info.subtitle_info = sb.str;
            } else {
                info.subtitle_info = "%d track%s".printf (
                    subtitle_count, subtitle_count == 1 ? "" : "s");
            }
        }

        // ── Extract format (container) data ──────────────────────────────────
        if (format_map != null) {
            string dur_str = format_map.get ("duration") ?? "0";
            double dur = double.parse (dur_str);
            if (dur > 0) {
                int total_sec = (int) dur;
                int hr = total_sec / 3600;
                int mn = (total_sec - hr * 3600) / 60;
                int sc = total_sec - hr * 3600 - mn * 60;
                info.duration = "%02d:%02d:%02d".printf (hr, mn, sc);
            }

            // Title: prefer metadata tag, then fall back to filename stem
            string t = format_map.get ("TAG:title") ?? format_map.get ("title") ?? "";
            if (t.strip ().length > 0) {
                info.title = t.strip ();
            } else {
                int d = info.filename.last_index_of_char ('.');
                info.title = (d > 0) ? info.filename.substring (0, d) : info.filename;
            }
        }
    }

    // ── Keyframe counting ─────────────────────────────────────────────────────

    /**
     * Count keyframes by reading packet flags from the demuxer.
     * This is fast (no decoding) — it reads the container index only.
     * Returns "N/A" on any failure so the row stays hidden.
     */
    private static string count_keyframes (string file_path) {
        try {
            string[] cmd = {
                "ffprobe", "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "packet=flags",
                "-of", "csv=p=0",
                file_path
            };
            string stdout_text, stderr_text;
            int exit_status;

            Process.spawn_sync (null, cmd, null, SpawnFlags.SEARCH_PATH,
                                null, out stdout_text, out stderr_text, out exit_status);

            if (exit_status != 0 || stdout_text == null || stdout_text.length == 0)
                return "N/A";

            int key_count = 0;
            foreach (string line in stdout_text.split ("\n")) {
                // Keyframe packets have "K" in the flags field
                if (line.contains ("K"))
                    key_count++;
            }

            if (key_count > 0)
                return key_count.to_string ();
        } catch (Error e) {
            // probe failed
        }
        return "N/A";
    }

    // ── Formatting helpers ────────────────────────────────────────────────────

    // Converts a rational fps string like "24000/1001" into "23.976 fps"
    // Uses only integer arithmetic — no floating-point printf, no libm/fmod needed.
    private string format_fps (string raw) {
        if (raw == "N/A" || raw.length == 0 || raw == "0/0") return "N/A";
        int slash = raw.index_of_char ('/');
        if (slash > 0) {
            int64 num = int64.parse (raw.substring (0, slash));
            int64 den = int64.parse (raw.substring (slash + 1));
            if (den <= 0 || num <= 0) return "N/A";

            // Integer whole + 3 fractional digits (avoids double % → fmod)
            int64 whole  = num / den;
            int64 frac3  = (num * 1000) / den - whole * 1000;

            if (frac3 == 0) {
                return whole.to_string () + " fps";
            } else if (frac3 % 100 == 0) {
                return whole.to_string () + "." + (frac3 / 100).to_string () + " fps";
            } else if (frac3 % 10 == 0) {
                return "%lld.%02lld fps".printf (whole, frac3 / 10);
            } else {
                return "%lld.%03lld fps".printf (whole, frac3);
            }
        }
        return raw + " fps";
    }

    /**
     * Format a channel_layout string from ffprobe into a friendly label.
     */
    private static string format_channel_layout (string layout) {
        string lo = layout.down ();
        if (lo == "mono")           return "Mono";
        if (lo == "stereo")         return "Stereo";
        if (lo == "2.1")            return "2.1";
        if (lo == "3.0")            return "3.0 Surround";
        if (lo == "4.0" || lo == "quad") return "4.0 Surround";
        if (lo == "5.0" || lo == "5.0(side)") return "5.0 Surround";
        if (lo == "5.1" || lo == "5.1(side)") return "5.1 Surround";
        if (lo == "6.1")            return "6.1 Surround";
        if (lo == "7.1")            return "7.1 Surround";
        return layout;
    }

    /**
     * Format a bare channel count into a friendly label.
     */
    private static string format_channel_count (int channels) {
        switch (channels) {
            case 1:  return "Mono";
            case 2:  return "Stereo";
            case 3:  return "2.1";
            case 6:  return "5.1 Surround";
            case 8:  return "7.1 Surround";
            default: return "%d channels".printf (channels);
        }
    }
}
