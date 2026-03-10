using Gtk;
using Adw;
using GLib;

public class GeneralTab : Box {

    // ── Scaling ──────────────────────────────────────────────────────────────
    public DropDown   scale_mode       { get; private set; }
    public DropDown   resolution_preset { get; private set; }
    public SpinButton scale_width_x    { get; private set; }
    public SpinButton scale_height_x   { get; private set; }
    public DropDown   scale_algorithm  { get; private set; }
    public DropDown   scale_range      { get; private set; }

    private Adw.ActionRow resolution_preset_row;
    private Adw.ActionRow width_row;
    private Adw.ActionRow height_row;
    private Adw.ActionRow algorithm_row;
    private Adw.ActionRow range_row;

    // ── Rotation & Crop ──────────────────────────────────────────────────────
    public DropDown rotate_combo       { get; private set; }
    public Switch   crop_check         { get; private set; }
    public Button   detect_crop_button { get; private set; }
    public Entry    crop_value         { get; private set; }

    public Adw.ExpanderRow crop_expander;

    // ── Timing ───────────────────────────────────────────────────────────────
    public Switch     seek_check       { get; private set; }
    public SpinButton seek_hh          { get; private set; }
    public SpinButton seek_mm          { get; private set; }
    public SpinButton seek_ss          { get; private set; }

    public Switch     time_check       { get; private set; }
    public SpinButton time_hh          { get; private set; }
    public SpinButton time_mm          { get; private set; }
    public SpinButton time_ss          { get; private set; }

    private Adw.ExpanderRow seek_expander;
    private Adw.ExpanderRow time_expander;

    // ── Pixel Format ─────────────────────────────────────────────────────────
    public Switch   eight_bit_check    { get; private set; }
    public DropDown eight_bit_format   { get; private set; }
    public Switch   ten_bit_check      { get; private set; }
    public DropDown ten_bit_format     { get; private set; }

    private Adw.ActionRow eight_bit_fmt_row;
    private Adw.ActionRow ten_bit_fmt_row;

    // ── Video Filters (separate panel) ───────────────────────────────────────
    public VideoFilters video_filters   { get; private set; }

    // ── Color Correction & HDR ───────────────────────────────────────────────
    private Button color_button;
    private ColorCorrectionDialog? color_dialog = null;

    // ── Frame Rate ───────────────────────────────────────────────────────────
    public DropDown frame_rate_combo   { get; private set; }
    public Entry    custom_frame_rate  { get; private set; }

    private Adw.ActionRow custom_fr_row;

    // ── Speed ────────────────────────────────────────────────────────────────
    public Switch     video_speed_check { get; private set; }
    public SpinButton video_speed       { get; private set; }
    public Switch     audio_speed_check { get; private set; }
    public SpinButton audio_speed       { get; private set; }

    private Adw.ExpanderRow video_speed_expander;
    private Adw.ExpanderRow audio_speed_expander;

    // ── Audio ────────────────────────────────────────────────────────────────
    public Switch normalize_audio      { get; private set; }

    // ── Metadata ─────────────────────────────────────────────────────────────
    public Switch preserve_metadata    { get; private set; }
    public Switch remove_chapters      { get; private set; }

    // ── Forwarding Signals ─────────────────────────────────────────────────
    //    Emitted when the corresponding internal switch/toggle changes state.
    //    AppController and other consumers should connect to these instead of
    //    reaching into the raw Switch widgets directly.

    /** Fired when the audio speed toggle changes. */
    public signal void audio_speed_toggled (bool active);
    /** Fired when the video speed toggle changes. */
    public signal void video_speed_toggled (bool active);
    /** Fired when the normalize audio toggle changes. */
    public signal void normalize_toggled (bool active);
    /** Fired when the Detect Crop button is clicked. */
    public signal void crop_detect_clicked ();

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public GeneralTab () {
        Object (orientation: Orientation.VERTICAL, spacing: 24);
        set_margin_top (32);
        set_margin_bottom (24);
        set_margin_start (24);
        set_margin_end (24);

        // 1. Scaling, rotation, crop — all geometry transforms together
        build_scaling_transform_group ();

        // 2. Seek & duration — right below scaling for quick trim control
        build_timing_group ();

        // 3. Pixel format
        build_pixel_format_group ();

        // 4. Video processing filters (restoration, noise, sharpen, blur, grain)
        video_filters = new VideoFilters ();
        video_filters.set_ten_bit_reference (ten_bit_check);
        append (video_filters.get_widget ());

        // 5. Color correction + HDR tone mapping
        build_color_hdr_group ();

        // 6. Frame rate & speed adjustments
        build_frame_rate_speed_group ();

        // 7. Audio normalization
        build_audio_group ();

        // 8. Metadata controls
        build_metadata_group ();

        connect_signals ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  1. SCALING & TRANSFORM
    // ═════════════════════════════════════════════════════════════════════════

    private void build_scaling_transform_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Scaling &amp; Transform");
        group.set_description ("Resize, rotate, and crop the video");

        // ── Scaling Mode ─────────────────────────────────────────────────────
        var mode_row = new Adw.ActionRow ();
        mode_row.set_title ("Scaling");
        mode_row.set_subtitle ("Choose how to resize the video");
        scale_mode = new DropDown (new StringList (
            { ScaleMode.ORIGINAL, ScaleMode.RESOLUTION, ScaleMode.PERCENTAGE }
        ), null);
        scale_mode.set_valign (Align.CENTER);
        scale_mode.set_selected (0);
        mode_row.add_suffix (scale_mode);
        group.add (mode_row);

        // ── Resolution Preset (visible in Resolution mode) ───────────────────
        resolution_preset_row = new Adw.ActionRow ();
        resolution_preset_row.set_title ("Resolution");
        resolution_preset_row.set_subtitle ("Select a target resolution");
        resolution_preset = new DropDown (new StringList ({
            "7680×4320 (16:9)",
            "7680×4800 (16:10)",
            "3840×2160 (16:9)",
            "3840×2400 (16:10)",
            "2960×1440 (18.5:9)",
            "2868×1320 (19.5:9)",
            "2778×1284 (19.5:9)",
            "2622×1206 (19.5:9)",
            "2560×1440 (16:9)",
            "2560×1600 (16:10)",
            "2556×1179 (19.5:9)",
            "2532×1170 (19.5:9)",
            "2436×1125 (19.5:9)",
            "2400×1080 (20:9)",
            "2340×1080 (19.5:9)",
            "2160×1080 (18:9)",
            "1920×1080 (16:9)",
            "1920×1200 (16:10)",
            "1280×720 (16:9)",
            "1280×800 (16:10)",
            "1080×2400 (9:20)",
            "1080×2340 (9:19.5)",
            "1080×1920 (9:16)",
            "854×480 (16:9)",
            "960×600 (16:10)",
            "800×480 (5:3)",
            "768×480 (16:10)",
            "720×1280 (9:16)",
            "640×480 (4:3)"
        }), null);
        resolution_preset.set_valign (Align.CENTER);
        resolution_preset.set_selected (16);  // default to 1920×1080
        resolution_preset_row.add_suffix (resolution_preset);
        resolution_preset_row.set_visible (false);
        group.add (resolution_preset_row);

        // ── Width Multiplier (visible in Percentage mode) ────────────────────
        width_row = new Adw.ActionRow ();
        width_row.set_title ("Width Multiplier");
        width_row.set_subtitle ("1.00 = original width");
        scale_width_x = new SpinButton.with_range (0.05, 10.0, 0.05);
        scale_width_x.set_value (1.0);
        scale_width_x.set_digits (2);
        scale_width_x.set_valign (Align.CENTER);
        width_row.add_suffix (scale_width_x);
        width_row.set_visible (false);
        group.add (width_row);

        // ── Height Multiplier (visible in Percentage mode) ───────────────────
        height_row = new Adw.ActionRow ();
        height_row.set_title ("Height Multiplier");
        height_row.set_subtitle ("1.00 = original height");
        scale_height_x = new SpinButton.with_range (0.05, 10.0, 0.05);
        scale_height_x.set_value (1.0);
        scale_height_x.set_digits (2);
        scale_height_x.set_valign (Align.CENTER);
        height_row.add_suffix (scale_height_x);
        height_row.set_visible (false);
        group.add (height_row);

        // ── Algorithm (visible in Resolution or Percentage mode) ─────────────
        algorithm_row = new Adw.ActionRow ();
        algorithm_row.set_title ("Algorithm");
        algorithm_row.set_subtitle ("Scaling filter — Lanczos is best for most content");
        scale_algorithm = new DropDown (new StringList (
            { "lanczos", "point", "bilinear", "bicubic", "spline16", "spline36" }
        ), null);
        scale_algorithm.set_valign (Align.CENTER);
        scale_algorithm.set_selected (0);
        algorithm_row.add_suffix (scale_algorithm);
        algorithm_row.set_visible (false);
        group.add (algorithm_row);

        // ── Color Range (visible in Resolution or Percentage mode) ───────────
        range_row = new Adw.ActionRow ();
        range_row.set_title ("Color Range");
        range_row.set_subtitle ("Input preserves the original range");
        scale_range = new DropDown (new StringList (
            { "input", "limited", "full" }
        ), null);
        scale_range.set_valign (Align.CENTER);
        scale_range.set_selected (0);
        range_row.add_suffix (scale_range);
        range_row.set_visible (false);
        group.add (range_row);

        // ── Rotate / Flip ────────────────────────────────────────────────────
        var rotate_row = new Adw.ActionRow ();
        rotate_row.set_title ("Rotate / Flip");
        rotate_row.set_subtitle ("Transform the video orientation");
        rotate_combo = new DropDown (new StringList (
            { Rotation.NONE, Rotation.CW_90, Rotation.CCW_90, Rotation.ROTATE_180,
              Rotation.HORIZONTAL_FLIP, Rotation.VERTICAL_FLIP }
        ), null);
        rotate_combo.set_valign (Align.CENTER);
        rotate_combo.set_selected (0);
        rotate_row.add_suffix (rotate_combo);
        group.add (rotate_row);

        // ── Crop ─────────────────────────────────────────────────────────────
        crop_check = new Switch ();
        crop_check.set_active (false);

        crop_expander = new Adw.ExpanderRow ();
        crop_expander.set_title ("Crop");
        crop_expander.set_subtitle ("Remove black bars or unwanted borders");
        crop_expander.set_show_enable_switch (true);
        crop_expander.set_enable_expansion (false);

        crop_check.bind_property ("active", crop_expander, "enable-expansion",
            BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        var detect_row = new Adw.ActionRow ();
        detect_row.set_title ("Auto-Detect");
        detect_row.set_subtitle ("Analyze 30 seconds of video for black bars");
        detect_crop_button = new Button.with_label ("Detect");
        detect_crop_button.add_css_class ("suggested-action");
        detect_crop_button.set_valign (Align.CENTER);
        detect_row.add_suffix (detect_crop_button);
        detect_row.set_activatable_widget (detect_crop_button);
        crop_expander.add_row (detect_row);

        var value_row = new Adw.ActionRow ();
        value_row.set_title ("Crop Value");
        value_row.set_subtitle ("Format: width:height:x:y");
        crop_value = new Entry ();
        crop_value.set_placeholder_text ("w:h:x:y");
        crop_value.set_editable (false);
        crop_value.set_valign (Align.CENTER);
        crop_value.set_width_chars (20);
        value_row.add_suffix (crop_value);
        crop_expander.add_row (value_row);

        group.add (crop_expander);
        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  2. TIMING
    // ═════════════════════════════════════════════════════════════════════════

    private void build_timing_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Timing");
        group.set_description ("Control which portion of the video to encode");

        // ── Seek ─────────────────────────────────────────────────────────────
        seek_check = new Switch ();
        seek_check.set_active (false);

        seek_expander = new Adw.ExpanderRow ();
        seek_expander.set_title ("Seek");
        seek_expander.set_subtitle ("Start encoding from a specific timestamp");
        seek_expander.set_show_enable_switch (true);
        seek_expander.set_enable_expansion (false);

        seek_check.bind_property ("active", seek_expander, "enable-expansion",
            BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        var seek_entries_row = new Adw.ActionRow ();
        seek_entries_row.set_title ("Start Time");

        seek_hh = new SpinButton.with_range (0, 99, 1);
        seek_mm = new SpinButton.with_range (0, 59, 1);
        seek_ss = new SpinButton.with_range (0, 59, 1);

        var seek_box = build_time_box (seek_hh, seek_mm, seek_ss);
        seek_entries_row.add_suffix (seek_box);
        seek_expander.add_row (seek_entries_row);
        group.add (seek_expander);

        // ── Duration ─────────────────────────────────────────────────────────
        time_check = new Switch ();
        time_check.set_active (false);

        time_expander = new Adw.ExpanderRow ();
        time_expander.set_title ("Duration");
        time_expander.set_subtitle ("Limit the output to a specific length");
        time_expander.set_show_enable_switch (true);
        time_expander.set_enable_expansion (false);

        time_check.bind_property ("active", time_expander, "enable-expansion",
            BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        var time_entries_row = new Adw.ActionRow ();
        time_entries_row.set_title ("Length");

        time_hh = new SpinButton.with_range (0, 99, 1);
        time_mm = new SpinButton.with_range (0, 59, 1);
        time_ss = new SpinButton.with_range (0, 59, 1);

        var time_box = build_time_box (time_hh, time_mm, time_ss);
        time_entries_row.add_suffix (time_box);
        time_expander.add_row (time_entries_row);
        group.add (time_expander);

        append (group);
    }

    /**
     * Build an HH : MM : SS box from three SpinButtons.
     */
    private Box build_time_box (SpinButton hh, SpinButton mm, SpinButton ss) {
        hh.set_width_chars (3);
        mm.set_width_chars (3);
        ss.set_width_chars (3);
        hh.set_valign (Align.CENTER);
        mm.set_valign (Align.CENTER);
        ss.set_valign (Align.CENTER);

        var box = new Box (Orientation.HORIZONTAL, 4);
        box.set_valign (Align.CENTER);
        box.append (hh);
        box.append (new Label (":"));
        box.append (mm);
        box.append (new Label (":"));
        box.append (ss);
        return box;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  3. PIXEL FORMAT
    // ═════════════════════════════════════════════════════════════════════════

    private void build_pixel_format_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Pixel Format");
        group.set_description ("Color depth and chroma subsampling");

        var eight_row = new Adw.ActionRow ();
        eight_row.set_title ("8-Bit Color");
        eight_row.set_subtitle ("Standard dynamic range — compatible with all players");
        eight_bit_check = new Switch ();
        eight_bit_check.set_valign (Align.CENTER);
        eight_bit_check.set_active (false);
        eight_row.add_suffix (eight_bit_check);
        eight_row.set_activatable_widget (eight_bit_check);
        group.add (eight_row);

        eight_bit_fmt_row = new Adw.ActionRow ();
        eight_bit_fmt_row.set_title ("8-Bit Subsampling");
        eight_bit_format = new DropDown (new StringList (
            { "8-bit 4:2:0", "8-bit 4:2:2", "8-bit 4:4:4" }
        ), null);
        eight_bit_format.set_valign (Align.CENTER);
        eight_bit_format.set_selected (0);
        eight_bit_fmt_row.add_suffix (eight_bit_format);
        eight_bit_fmt_row.set_visible (false);
        group.add (eight_bit_fmt_row);

        var ten_row = new Adw.ActionRow ();
        ten_row.set_title ("10-Bit Color");
        ten_row.set_subtitle ("Higher color depth — better gradients, HDR support");
        ten_bit_check = new Switch ();
        ten_bit_check.set_valign (Align.CENTER);
        ten_bit_check.set_active (false);
        ten_row.add_suffix (ten_bit_check);
        ten_row.set_activatable_widget (ten_bit_check);
        group.add (ten_row);

        ten_bit_fmt_row = new Adw.ActionRow ();
        ten_bit_fmt_row.set_title ("10-Bit Subsampling");
        ten_bit_format = new DropDown (new StringList (
            { "10-bit 4:2:0", "10-bit 4:2:2", "10-bit 4:4:4" }
        ), null);
        ten_bit_format.set_valign (Align.CENTER);
        ten_bit_format.set_selected (0);
        ten_bit_fmt_row.add_suffix (ten_bit_format);
        ten_bit_fmt_row.set_visible (false);
        group.add (ten_bit_fmt_row);

        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  5. COLOR & HDR
    // ═════════════════════════════════════════════════════════════════════════

    private void build_color_hdr_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Color &amp; HDR");
        group.set_description ("Color grading and HDR tone mapping");

        // ── Manual Color Correction ──────────────────────────────────────────
        var color_row = new Adw.ActionRow ();
        color_row.set_title ("Adjust Colors");
        color_row.set_subtitle ("Brightness, contrast, saturation, gamma, hue, and more");
        color_button = new Button.with_label ("Open");
        color_button.add_css_class ("suggested-action");
        color_button.set_valign (Align.CENTER);
        color_row.add_suffix (color_button);
        color_row.set_activatable_widget (color_button);
        group.add (color_row);

        // ── HDR to SDR ───────────
        group.add (video_filters.get_hdr_expander ());

        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  6. FRAME RATE & SPEED
    // ═════════════════════════════════════════════════════════════════════════

    private void build_frame_rate_speed_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Frame Rate &amp; Speed");
        group.set_description ("Playback rate adjustments for video and audio");

        // ── Frame Rate ───────────────────────────────────────────────────────
        var fr_row = new Adw.ActionRow ();
        fr_row.set_title ("Frame Rate");
        fr_row.set_subtitle ("Original preserves the source frame rate");
        frame_rate_combo = new DropDown (new StringList (
            { FrameRateLabel.ORIGINAL, "24", "30", "60", FrameRateLabel.CUSTOM }
        ), null);
        frame_rate_combo.set_valign (Align.CENTER);
        frame_rate_combo.set_selected (0);
        fr_row.add_suffix (frame_rate_combo);
        group.add (fr_row);

        custom_fr_row = new Adw.ActionRow ();
        custom_fr_row.set_title ("Custom Frame Rate");
        custom_fr_row.set_subtitle ("Enter a specific frame rate value");
        custom_frame_rate = new Entry ();
        custom_frame_rate.set_placeholder_text ("e.g. 23.976");
        custom_frame_rate.set_valign (Align.CENTER);
        custom_frame_rate.set_width_chars (10);
        custom_frame_rate.set_input_purpose (InputPurpose.NUMBER);

        // Only allow digits and a single decimal point
        custom_frame_rate.changed.connect (() => {
            string txt = custom_frame_rate.text;
            var cleaned = new StringBuilder ();
            bool has_dot = false;
            for (int i = 0; i < txt.length; i++) {
                unichar c = txt[i];
                if (c >= '0' && c <= '9') {
                    cleaned.append_unichar (c);
                } else if (c == '.' && !has_dot) {
                    cleaned.append_unichar (c);
                    has_dot = true;
                }
            }
            string result = cleaned.str;
            if (result != txt) {
                custom_frame_rate.set_text (result);
            }
        });
        custom_fr_row.add_suffix (custom_frame_rate);
        custom_fr_row.set_visible (false);
        group.add (custom_fr_row);

        // ── Video Speed ──────────────────────────────────────────────────────
        video_speed_check = new Switch ();
        video_speed_check.set_active (false);

        video_speed_expander = new Adw.ExpanderRow ();
        video_speed_expander.set_title ("Video Speed");
        video_speed_expander.set_subtitle ("Adjust playback speed of the video stream");
        video_speed_expander.set_show_enable_switch (true);
        video_speed_expander.set_enable_expansion (false);

        video_speed_check.bind_property ("active", video_speed_expander, "enable-expansion",
            BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        var vspeed_row = new Adw.ActionRow ();
        vspeed_row.set_title ("Speed Adjustment");
        vspeed_row.set_subtitle ("Percentage change (−95 to +100)");
        video_speed = new SpinButton.with_range (-95, 100, 5);
        video_speed.set_value (0);
        video_speed.set_valign (Align.CENTER);
        vspeed_row.add_suffix (video_speed);
        video_speed_expander.add_row (vspeed_row);
        group.add (video_speed_expander);

        // ── Audio Speed ──────────────────────────────────────────────────────
        audio_speed_check = new Switch ();
        audio_speed_check.set_active (false);

        audio_speed_expander = new Adw.ExpanderRow ();
        audio_speed_expander.set_title ("Audio Speed");
        audio_speed_expander.set_subtitle ("Adjust playback speed of the audio stream");
        audio_speed_expander.set_show_enable_switch (true);
        audio_speed_expander.set_enable_expansion (false);

        audio_speed_check.bind_property ("active", audio_speed_expander, "enable-expansion",
            BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        var aspeed_row = new Adw.ActionRow ();
        aspeed_row.set_title ("Speed Adjustment");
        aspeed_row.set_subtitle ("Percentage change (−95 to +100)");
        audio_speed = new SpinButton.with_range (-95, 100, 5);
        audio_speed.set_value (0);
        audio_speed.set_valign (Align.CENTER);
        aspeed_row.add_suffix (audio_speed);
        audio_speed_expander.add_row (aspeed_row);
        group.add (audio_speed_expander);

        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  7. AUDIO
    // ═════════════════════════════════════════════════════════════════════════

    private void build_audio_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Audio");

        var norm_row = new Adw.ActionRow ();
        norm_row.set_title ("Normalize Audio");
        norm_row.set_subtitle ("Standardize loudness levels across the file");
        normalize_audio = new Switch ();
        normalize_audio.set_valign (Align.CENTER);
        normalize_audio.set_active (false);
        norm_row.add_suffix (normalize_audio);
        norm_row.set_activatable_widget (normalize_audio);
        group.add (norm_row);

        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  8. METADATA
    // ═════════════════════════════════════════════════════════════════════════

    private void build_metadata_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Metadata");
        group.set_description ("Control file metadata and chapter markers");

        var meta_row = new Adw.ActionRow ();
        meta_row.set_title ("Preserve Metadata");
        meta_row.set_subtitle ("Copy metadata tags from the source file");
        preserve_metadata = new Switch ();
        preserve_metadata.set_valign (Align.CENTER);
        preserve_metadata.set_active (false);
        meta_row.add_suffix (preserve_metadata);
        meta_row.set_activatable_widget (preserve_metadata);
        group.add (meta_row);

        var chap_row = new Adw.ActionRow ();
        chap_row.set_title ("Remove Chapters");
        chap_row.set_subtitle ("Strip chapter markers from the output");
        remove_chapters = new Switch ();
        remove_chapters.set_valign (Align.CENTER);
        remove_chapters.set_active (false);
        chap_row.add_suffix (remove_chapters);
        chap_row.set_activatable_widget (remove_chapters);
        group.add (chap_row);

        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SIGNALS
    // ═════════════════════════════════════════════════════════════════════════

    private void connect_signals () {
        scale_mode.notify["selected"].connect (() => {
            update_scaling_visibility ();
        });

        eight_bit_check.notify["active"].connect (() => {
            eight_bit_fmt_row.set_visible (eight_bit_check.active);
            if (eight_bit_check.active) ten_bit_check.active = false;
        });
        ten_bit_check.notify["active"].connect (() => {
            ten_bit_fmt_row.set_visible (ten_bit_check.active);
            if (ten_bit_check.active) eight_bit_check.active = false;
        });

        frame_rate_combo.notify["selected"].connect (() => {
            custom_fr_row.set_visible (get_frame_rate_text () == FrameRateLabel.CUSTOM);
        });

        color_button.clicked.connect (() => {
            if (color_dialog == null)
                color_dialog = new ColorCorrectionDialog (get_root () as Gtk.Window);
            color_dialog.present ();
        });

        // ── Forwarding signals ───────────────────────────────────────────────
        audio_speed_check.notify["active"].connect (() => {
            audio_speed_toggled (audio_speed_check.active);
        });
        video_speed_check.notify["active"].connect (() => {
            video_speed_toggled (video_speed_check.active);
        });
        normalize_audio.notify["active"].connect (() => {
            normalize_toggled (normalize_audio.active);
        });
        detect_crop_button.clicked.connect (() => {
            crop_detect_clicked ();
        });
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    public string get_scale_mode_text () {
        var item = scale_mode.selected_item as StringObject;
        return item != null ? item.string : ScaleMode.ORIGINAL;
    }

    /**
     * Returns the selected resolution preset as "WxH" (e.g. "1920x1080"),
     * or "" if no preset is selected.
     */
    public string get_resolution_preset_value () {
        var item = resolution_preset.selected_item as StringObject;
        if (item == null) return "";
        // Format is "1920×1080 (16:9)" — extract before the space
        string text = item.string;
        int space = text.index_of_char (' ');
        string res = (space > 0) ? text.substring (0, space) : text;
        // Normalize the × (Unicode multiply) to x for FFmpeg
        return res.replace ("×", ":");
    }

    public string get_frame_rate_text () {
        var item = frame_rate_combo.selected_item as StringObject;
        return item != null ? item.string : "";
    }

    public string get_color_filter () {
        return color_dialog != null ? color_dialog.get_filter_string () : "";
    }

    private void update_scaling_visibility () {
        string mode = get_scale_mode_text ();
        bool is_resolution  = (mode == ScaleMode.RESOLUTION);
        bool is_percentage  = (mode == ScaleMode.PERCENTAGE);
        bool is_scaling     = is_resolution || is_percentage;

        resolution_preset_row.set_visible (is_resolution);
        width_row.set_visible (is_percentage);
        height_row.set_visible (is_percentage);
        algorithm_row.set_visible (is_scaling);
        range_row.set_visible (is_scaling);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CROP & TRIM TAB COORDINATION
    //
    //  Called by TrimTab whenever its operation mode changes so that conflicting
    //  controls in the General tab are locked out:
    //
    //    • Trim Only  (mode 0) — seek/time are owned by the trim segments;
    //                            lock seek + duration here.
    //    • Crop Only  (mode 1) — crop is handled by the interactive overlay;
    //                            lock crop here.
    //    • Crop&Trim  (mode 2) — both apply; lock seek/time AND crop here.
    //
    //  When a group is locked we:
    //    1. Force-collapse and deactivate the expander so no stale values leak
    //       into the FFmpeg command line.
    //    2. Mark the row insensitive so it is visually greyed out.
    //    3. Set a tooltip explaining why.
    //
    //  When unlocked we restore sensitivity and clear the tooltip.  We do NOT
    //  re-expand or re-activate — the user may have intentionally left them off.
    // ═════════════════════════════════════════════════════════════════════════

    private const string LOCK_REASON = "Disabled while using segment-based modes in the Crop & Trim tab — navigate away or switch to Crop Only mode to unlock";
    private const string LOCK_REASON_CROP = "Disabled while using crop modes in the Crop & Trim tab — switch to Trim Only or Chapter Split mode to unlock";

    /**
     * Called by AppController whenever the Crop & Trim tab gains or loses
     * focus, and whenever its operation mode changes while in focus.
     *
     * @param mode  0 = Trim Only  → lock seek/time only
     *              1 = Crop Only  → lock crop only
     *              2 = Crop&Trim  → lock seek/time AND crop
     *             -1 = tab not in focus → unlock everything
     */
    public void notify_trim_tab_mode (int mode) {
        if (mode == -1) {
            // Crop & Trim tab is not the active tab — unlock everything so
            // the General tab can be used freely with any codec tab.
            set_timing_locked (false);
            set_crop_locked (false);
            return;
        }

        // Seek / Duration are conflicted when trim segments are in play
        // (TRIM_ONLY=0, TRIM_AND_CROP=2, CHAPTER_SPLIT=3 all use segments
        //  with their own start/end times)
        bool lock_timing = (mode == 0 || mode == 2 || mode == 3);
        // Crop is conflicted when the interactive overlay is in play
        bool lock_crop   = (mode == 1 || mode == 2);   // CROP_ONLY or TRIM_AND_CROP

        set_timing_locked (lock_timing);
        set_crop_locked (lock_crop);
    }

    private void set_timing_locked (bool locked) {
        if (locked) {
            // Collapse and deactivate first so the values don't reach ffmpeg
            seek_check.set_active (false);
            time_check.set_active (false);
            seek_expander.set_enable_expansion (false);
            time_expander.set_enable_expansion (false);

            seek_expander.set_sensitive (false);
            time_expander.set_sensitive (false);

            seek_expander.set_tooltip_text (LOCK_REASON);
            time_expander.set_tooltip_text (LOCK_REASON);
        } else {
            seek_expander.set_sensitive (true);
            time_expander.set_sensitive (true);

            seek_expander.set_tooltip_text (null);
            time_expander.set_tooltip_text (null);
        }
    }

    private void set_crop_locked (bool locked) {
        if (locked) {
            // Collapse and deactivate so the crop value doesn't reach ffmpeg
            crop_check.set_active (false);
            crop_expander.set_enable_expansion (false);

            crop_expander.set_sensitive (false);
            crop_expander.set_tooltip_text (LOCK_REASON_CROP);
        } else {
            crop_expander.set_sensitive (true);
            crop_expander.set_tooltip_text (null);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CROP DETECTION
    // ═════════════════════════════════════════════════════════════════════════

    public void start_crop_detection (string input_file, ConsoleTab console_tab) {
        if (input_file == "") {
            crop_value.set_text ("⚠️ Please select an input file first");
            return;
        }

        detect_crop_button.sensitive = false;
        crop_value.set_text ("🔍 Analyzing for crop (30 seconds)...");
        crop_check.active = true;

        console_tab.add_line ("=== Crop Detection Started ===");
        console_tab.add_line ("Filter chain: " + FilterBuilder.get_crop_detection_chain (this));

        new Thread<void> ("crop-detect-thread", () => {
            perform_crop_detection (input_file, console_tab);
        });
    }

    private void perform_crop_detection (string input_file, ConsoleTab console_tab) {
        string vf = FilterBuilder.get_crop_detection_chain (this);

        string[] cmd = {
            AppSettings.get_default ().ffmpeg_path,
            "-hide_banner", "-loglevel", "info", "-nostats",
            "-i", input_file,
            "-vf", vf,
            "-f", "null",
            "-t", "30",
            "-"
        };

        string last_crop = "";

        try {
            var launcher = new SubprocessLauncher (
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_MERGE
            );
            var process = launcher.spawnv (cmd);
            var reader = new DataInputStream (process.get_stdout_pipe ());

            string line;
            while ((line = reader.read_line (null)) != null) {
                if (line.contains ("crop=")) {
                    string crop_val = extract_crop_value (line);
                    if (crop_val.length > 5 && crop_val.contains (":")) {
                        string[] parts = crop_val.split (":");
                        if (parts.length == 4 &&
                            int.parse (parts[0]) > 0 &&
                            int.parse (parts[1]) > 0) {
                            last_crop = crop_val;
                            string log_msg = line.strip ();
                            Idle.add (() => {
                                console_tab.add_line ("[CropDetect] " + log_msg);
                                return Source.REMOVE;
                            });
                        }
                    }
                }
            }

            process.wait ();

            string result_crop = last_crop;
            Idle.add (() => {
                if (result_crop.length > 8) {
                    crop_value.set_text (result_crop);
                    console_tab.add_line (@"✅ Detected stable crop: $result_crop");
                } else {
                    crop_value.set_text ("No crop detected");
                    console_tab.add_line ("⚠️ No valid crop= format found");
                }
                detect_crop_button.sensitive = true;
                return Source.REMOVE;
            });

        } catch (GLib.Error e) {
            string err_msg = e.message;
            Idle.add (() => {
                crop_value.set_text ("❌ Detection error");
                console_tab.add_line ("Crop detection failed: " + err_msg);
                detect_crop_button.sensitive = true;
                return Source.REMOVE;
            });
        }
    }

    private string extract_crop_value (string line) {
        int pos = line.index_of ("crop=");
        if (pos == -1) return "";
        string part = line.substring (pos + 5);
        int end = part.index_of_char (' ');
        return ((end > 0) ? part.substring (0, end) : part).strip ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SEMANTIC ACCESSORS
    //
    //  Encapsulate widget state so consumers don't depend on the internal
    //  widget structure.  New code should use these instead of reaching into
    //  the raw Switch / SpinButton / DropDown properties directly.
    // ═════════════════════════════════════════════════════════════════════════

    // ── Seek / Time ──────────────────────────────────────────────────────────

    public bool is_seek_enabled ()      { return seek_check.active; }
    public bool is_time_enabled ()      { return time_check.active; }

    public string get_seek_timestamp () {
        return ConversionUtils.build_timestamp (seek_hh, seek_mm, seek_ss);
    }

    public string get_time_timestamp () {
        return ConversionUtils.build_timestamp (time_hh, time_mm, time_ss);
    }

    public double get_seek_seconds () {
        return seek_hh.get_value () * 3600.0
             + seek_mm.get_value () * 60.0
             + seek_ss.get_value ();
    }

    public double get_time_seconds () {
        return time_hh.get_value () * 3600.0
             + time_mm.get_value () * 60.0
             + time_ss.get_value ();
    }

    // ── Metadata ─────────────────────────────────────────────────────────────

    public bool is_preserve_metadata () { return preserve_metadata.active; }
    public bool is_remove_chapters ()   { return remove_chapters.active; }

    // ── Speed & Audio ────────────────────────────────────────────────────────

    public bool is_video_speed_enabled ()  { return video_speed_check.active; }
    public bool is_audio_speed_enabled ()  { return audio_speed_check.active; }
    public bool is_normalize_enabled ()    { return normalize_audio.active; }

    // ── Crop ─────────────────────────────────────────────────────────────────

    public bool is_crop_enabled ()         { return crop_check.active; }
    public string get_crop_value_text ()   { return crop_value.text.strip (); }

    // ── Frame Rate ───────────────────────────────────────────────────────────

    public string get_custom_frame_rate_text () { return custom_frame_rate.text.strip (); }
}
