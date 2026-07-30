using Gtk;
using Adw;
using GLib;

public class GeneralSpeedSettingsSnapshot : Object {
    public bool video_speed_enabled = false;
    public double video_speed_percent = 0.0;
    public bool audio_speed_enabled = false;
    public double audio_speed_percent = 0.0;
}

public class GeneralCropSettingsSnapshot : Object {
    public bool crop_enabled = false;
    public string crop_value = "";
}

public class GeneralTimingSettingsSnapshot : Object {
    public bool seek_enabled = false;
    public double seek_hours = 0.0;
    public double seek_minutes = 0.0;
    public double seek_seconds = 0.0;
    public bool time_enabled = false;
    public double time_hours = 0.0;
    public double time_minutes = 0.0;
    public double time_seconds = 0.0;
}

public class GeneralTab : Box {
    private const double SPEED_MIN_PERCENT = -99.0;
    private const double SPEED_MAX_PERCENT = 100.0;
    private const double SPEED_STEP_PERCENT = 1.0;
    private const double SPEED_EPSILON = 1e-9;
    private const string VIDEO_SPEED_SUBTITLE_DEFAULT =
        "Adjust playback speed of the video stream";
    private const string AUDIO_SPEED_SUBTITLE_DEFAULT =
        "Adjust playback speed of the audio stream";
    private const string LOCK_REASON_SPEED =
        "Disabled while Combine re-encode is active — Combine does not support General speed changes";
    private const string CROP_SUBTITLE_DEFAULT =
        "Remove black bars or unwanted borders";
    private const string LOCK_REASON_CROP_COMBINE =
        "Disabled while Combine re-encode is active — Combine does not support General crop";
    private const string SEEK_SUBTITLE_DEFAULT =
        "Start encoding from a specific timestamp";
    private const string TIME_SUBTITLE_DEFAULT =
        "Encode only this much of the source, starting from the start time";
    private const string LOCK_REASON_TIMING_TRIM =
        "Disabled while using segment-based modes in the Crop & Trim tab — navigate away or switch to Crop Only mode to unlock";
    private const string LOCK_REASON_TIMING_COMBINE =
        "Disabled while Combine is open — trim clips before combining";
    private const string WATERMARK_SUBTITLE_DEFAULT =
        "Overlay text or an image on the video";
    private const string WATERMARK_DRAWTEXT_UNAVAILABLE =
        "Unavailable — the selected FFmpeg build does not include the drawtext filter";
    private const string WATERMARK_OVERLAY_UNAVAILABLE =
        "Unavailable — the selected FFmpeg build does not include the overlay filter";
    private const string DELOGO_SUBTITLE_DEFAULT =
        "Find a station logo or watermark and paint it out";
    private const string DELOGO_UNAVAILABLE =
        "Unavailable — the selected FFmpeg build does not include the delogo filter";
    private const string DELOGO_DETECT_SUBTITLE_DEFAULT =
        "Scan the video for a watermark that stays in one place";
    private const string DELOGO_MOVING_SUBTITLE_DEFAULT =
        "For a logo that jumps between positions — reads the whole video, so it takes longer";

    // ── Scaling ──────────────────────────────────────────────────────────────
    public DropDown   scale_mode       { get; private set; }
    public DropDown   resolution_preset { get; private set; }
    public SpinButton custom_width     { get; private set; }
    public SpinButton custom_height    { get; private set; }
    public SpinButton scale_width_x    { get; private set; }
    public SpinButton scale_height_x   { get; private set; }
    public DropDown   scale_algorithm  { get; private set; }
    public DropDown   scale_range      { get; private set; }

    private Adw.ActionRow resolution_preset_row;
    private Adw.ActionRow custom_width_row;
    private Adw.ActionRow custom_height_row;
    private Adw.ActionRow width_row;
    private Adw.ActionRow height_row;
    private Adw.ActionRow algorithm_row;
    private Adw.ActionRow range_row;

    // ── Rotation & Crop ──────────────────────────────────────────────────────
    public DropDown rotate_combo       { get; private set; }
    public Switch   crop_check         { get; private set; }
    public Button   detect_crop_button { get; private set; }
    public Entry    crop_value         { get; private set; }
    private uint    crop_detect_gen    = 0;

    public Adw.ExpanderRow crop_expander;
    private bool trim_crop_locked = false;
    private bool combine_crop_locked = false;

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
    private bool trim_timing_locked = false;
    private bool combine_timing_locked = false;

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
    private bool last_video_speed_effective = false;
    private bool last_audio_speed_effective = false;

    // ── Metadata ─────────────────────────────────────────────────────────────
    public Switch preserve_metadata    { get; private set; }
    public Switch remove_chapters      { get; private set; }

    // ── Watermark ───────────────────────────────────────────────────────────
    public Switch     watermark_check    { get; private set; }
    public DropDown   watermark_mode     { get; private set; }
    public Entry      watermark_text     { get; private set; }
    public DropDown   watermark_position { get; private set; }
    public SpinButton watermark_opacity  { get; private set; }
    public SpinButton watermark_margin   { get; private set; }
    public SpinButton watermark_font_size { get; private set; }
    public SpinButton watermark_image_width { get; private set; }
    public Gtk.ColorDialogButton watermark_color_button { get; private set; }

    private Adw.ExpanderRow watermark_expander;
    private Adw.ActionRow watermark_text_row;
    private Adw.ActionRow watermark_color_row;
    private Adw.ActionRow watermark_font_row;
    private Adw.ActionRow watermark_image_source_row;
    private Adw.ActionRow watermark_image_width_row;
    private string watermark_image_path = "";
    private bool last_watermark_effective = false;
    private bool drawtext_available = true;
    private string? drawtext_unavailable_reason = null;
    private bool overlay_available = true;
    private string? overlay_unavailable_reason = null;

    // ── Logo Removal (delogo) ───────────────────────────────────────────────
    public Switch delogo_check        { get; private set; }
    public Button detect_logo_button  { get; private set; }
    public Button detect_moving_logo_button { get; private set; }
    public Entry  delogo_value        { get; private set; }

    private Adw.ExpanderRow delogo_expander;
    private Adw.ActionRow delogo_detect_row;
    private Adw.ActionRow delogo_moving_row;
    private uint delogo_detect_gen = 0;
    private bool last_delogo_effective = false;
    private bool delogo_available = true;
    private string? delogo_unavailable_reason = null;

    // ── Forwarding Signals ─────────────────────────────────────────────────
    //    Emitted when the corresponding effective feature state changes.
    //    For speed controls, that means the toggle is on and the percent is
    //    a non-zero sanitized value. AppController and other consumers should
    //    connect to these instead of reaching into the raw widgets directly.

    /** Fired when effective audio speed filtering changes state. */
    public signal void audio_speed_toggled (bool active);
    /** Fired when effective video speed filtering changes state. */
    public signal void video_speed_toggled (bool active);
    /** Fired when the Detect Crop button is clicked. */
    public signal void crop_detect_clicked ();
    /** Fired when effective watermark state changes. */
    public signal void watermark_toggled (bool active);
    /** Fired when the Detect Watermark button is clicked. */
    public signal void logo_detect_clicked ();

    public signal void logo_detect_moving_clicked ();
    /** Fired when effective logo removal state changes. */
    public signal void logo_removal_toggled (bool active);

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

        // 3. Video processing filters (restoration, noise, sharpen, blur, grain)
        video_filters = new VideoFilters ();
        append (video_filters.get_widget ());

        // 4. Color correction + HDR tone mapping
        build_color_hdr_group ();

        // 5. Frame rate & speed adjustments
        build_frame_rate_speed_group ();

        // 6. Watermark
        build_watermark_group ();

        // 7. Metadata controls
        build_metadata_group ();

        connect_signals ();
    }

    private double sanitize_speed_percent_value (double value, string control_name) {
        if (!value.is_finite ()) {
            warning ("GeneralTab: Resetting %s speed percent because it is not finite: %g",
                     control_name, value);
            return 0.0;
        }

        return Math.round (value).clamp (SPEED_MIN_PERCENT, SPEED_MAX_PERCENT);
    }

    private double get_sanitized_speed_percent (SpinButton spin, string control_name) {
        update_speed_spin_if_needed (spin, control_name);
        return spin.get_value ();
    }

    private bool is_speed_effectively_enabled (bool toggle_active,
                                               double value,
                                               string control_name) {
        if (!toggle_active) {
            return false;
        }

        double sanitized = sanitize_speed_percent_value (value, control_name);
        return Math.fabs (sanitized) > SPEED_EPSILON;
    }

    private bool update_speed_spin_if_needed (SpinButton spin, string control_name) {
        double current = spin.get_value ();
        double sanitized = sanitize_speed_percent_value (current, control_name);

        if (!current.is_finite () || Math.fabs (current - sanitized) > SPEED_EPSILON) {
            spin.set_value (sanitized);
            return true;
        }

        return false;
    }

    private void emit_audio_speed_if_changed () {
        bool active = is_audio_speed_enabled ();
        if (active == last_audio_speed_effective) {
            return;
        }

        last_audio_speed_effective = active;
        audio_speed_toggled (active);
    }

    private void emit_video_speed_if_changed () {
        bool active = is_video_speed_enabled ();
        if (active == last_video_speed_effective) {
            return;
        }

        last_video_speed_effective = active;
        video_speed_toggled (active);
    }

    private void emit_watermark_if_changed () {
        bool active = is_watermark_effectively_enabled ();
        if (active == last_watermark_effective) {
            return;
        }

        last_watermark_effective = active;
        watermark_toggled (active);
    }

    private void emit_logo_removal_if_changed () {
        bool active = is_logo_removal_effectively_enabled ();
        if (active == last_delogo_effective) {
            return;
        }

        last_delogo_effective = active;
        logo_removal_toggled (active);
    }

    private SpinButton create_speed_spin () {
        var spin = new SpinButton.with_range (SPEED_MIN_PERCENT,
                                              SPEED_MAX_PERCENT,
                                              SPEED_STEP_PERCENT);
        spin.set_digits (0);
        spin.set_numeric (true);
        spin.set_snap_to_ticks (true);
        spin.set_update_policy (SpinButtonUpdatePolicy.IF_VALID);
        spin.set_value (0);
        spin.set_valign (Align.CENTER);
        return spin;
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
            { ScaleMode.ORIGINAL, ScaleMode.RESOLUTION, ScaleMode.CUSTOM, ScaleMode.PERCENTAGE }
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

        // ── Custom Width (visible in Custom Resolution mode) ─────────────────
        custom_width_row = new Adw.ActionRow ();
        custom_width_row.set_title ("Width");
        custom_width_row.set_subtitle ("Target width in pixels (auto-rounded to even)");
        custom_width = new SpinButton.with_range (2, 15360, 2);
        custom_width.set_value (1920);
        custom_width.set_valign (Align.CENTER);
        custom_width_row.add_suffix (custom_width);
        custom_width_row.set_visible (false);
        group.add (custom_width_row);

        // ── Custom Height (visible in Custom Resolution mode) ────────────────
        custom_height_row = new Adw.ActionRow ();
        custom_height_row.set_title ("Height");
        custom_height_row.set_subtitle ("Target height in pixels (auto-rounded to even)");
        custom_height = new SpinButton.with_range (2, 8640, 2);
        custom_height.set_value (1080);
        custom_height.set_valign (Align.CENTER);
        custom_height_row.add_suffix (custom_height);
        custom_height_row.set_visible (false);
        group.add (custom_height_row);

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
        crop_expander.set_subtitle (CROP_SUBTITLE_DEFAULT);
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
        seek_expander.set_subtitle (SEEK_SUBTITLE_DEFAULT);
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
        time_expander.set_subtitle (TIME_SUBTITLE_DEFAULT);
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
    //  4. COLOR & HDR
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
    //  5. FRAME RATE & SPEED
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
        video_speed_expander.set_subtitle (VIDEO_SPEED_SUBTITLE_DEFAULT);
        video_speed_expander.set_show_enable_switch (true);
        video_speed_expander.set_enable_expansion (false);

        video_speed_check.bind_property ("active", video_speed_expander, "enable-expansion",
            BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        var vspeed_row = new Adw.ActionRow ();
        vspeed_row.set_title ("Speed Adjustment");
        vspeed_row.set_subtitle ("Percentage change (−99 to +100)");
        video_speed = create_speed_spin ();
        vspeed_row.add_suffix (video_speed);
        video_speed_expander.add_row (vspeed_row);
        group.add (video_speed_expander);

        // ── Audio Speed ──────────────────────────────────────────────────────
        audio_speed_check = new Switch ();
        audio_speed_check.set_active (false);

        audio_speed_expander = new Adw.ExpanderRow ();
        audio_speed_expander.set_title ("Audio Speed");
        audio_speed_expander.set_subtitle (AUDIO_SPEED_SUBTITLE_DEFAULT);
        audio_speed_expander.set_show_enable_switch (true);
        audio_speed_expander.set_enable_expansion (false);

        audio_speed_check.bind_property ("active", audio_speed_expander, "enable-expansion",
            BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        var aspeed_row = new Adw.ActionRow ();
        aspeed_row.set_title ("Speed Adjustment");
        aspeed_row.set_subtitle ("Percentage change (−99 to +100)");
        audio_speed = create_speed_spin ();
        aspeed_row.add_suffix (audio_speed);
        audio_speed_expander.add_row (aspeed_row);
        group.add (audio_speed_expander);

        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  6. WATERMARK
    // ═════════════════════════════════════════════════════════════════════════

    private void build_watermark_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Watermark");
        group.set_description ("Add a watermark to the output — or take one out of the source");

        watermark_check = new Switch ();
        watermark_check.set_active (false);

        watermark_expander = new Adw.ExpanderRow ();
        watermark_expander.set_title ("Watermark");
        watermark_expander.set_subtitle (WATERMARK_SUBTITLE_DEFAULT);
        watermark_expander.set_show_enable_switch (true);
        watermark_expander.set_enable_expansion (false);

        watermark_check.bind_property ("active", watermark_expander, "enable-expansion",
            BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        // ── Mode ─────────────────────────────────────────────────────────────
        var mode_row = new Adw.ActionRow ();
        mode_row.set_title ("Mode");
        mode_row.set_subtitle ("Text overlay or image overlay");
        watermark_mode = new DropDown (new StringList (
            { "Text", "Image" }
        ), null);
        watermark_mode.set_valign (Align.CENTER);
        watermark_mode.set_selected (0);  // default: Text
        mode_row.add_suffix (watermark_mode);
        watermark_expander.add_row (mode_row);

        // ── Text ─────────────────────────────────────────────────────────────
        watermark_text_row = new Adw.ActionRow ();
        watermark_text_row.set_title ("Text");
        watermark_text_row.set_subtitle ("The text to display on the video");
        watermark_text = new Entry ();
        watermark_text.set_placeholder_text ("e.g. © My Video");
        watermark_text.set_valign (Align.CENTER);
        watermark_text.set_width_chars (20);
        watermark_text_row.add_suffix (watermark_text);
        watermark_expander.add_row (watermark_text_row);

        // ── Image Source ─────────────────────────────────────────────────────
        watermark_image_source_row = new Adw.ActionRow ();
        watermark_image_source_row.set_title ("No file selected");
        watermark_image_source_row.set_subtitle ("Choose a watermark image (png, jpg, webp, bmp)");
        watermark_image_source_row.add_prefix (make_watermark_icon ("image-x-generic-symbolic"));

        var wm_browse_btn = new Button.with_label ("Browse…");
        wm_browse_btn.add_css_class ("suggested-action");
        wm_browse_btn.set_valign (Align.CENTER);
        wm_browse_btn.clicked.connect (on_watermark_image_browse_clicked);
        watermark_image_source_row.add_suffix (wm_browse_btn);

        var wm_clear_btn = new Button.from_icon_name ("edit-clear-symbolic");
        wm_clear_btn.set_tooltip_text ("Clear selected watermark image");
        wm_clear_btn.add_css_class ("flat");
        wm_clear_btn.set_valign (Align.CENTER);
        wm_clear_btn.clicked.connect (() => {
            watermark_image_path = "";
            watermark_image_source_row.set_title ("No file selected");
            watermark_image_source_row.set_subtitle ("Choose a watermark image (png, jpg, webp, bmp)");
            emit_watermark_if_changed ();
        });
        watermark_image_source_row.add_suffix (wm_clear_btn);
        watermark_image_source_row.set_visible (false);
        watermark_expander.add_row (watermark_image_source_row);

        // ── Image Width ──────────────────────────────────────────────────────
        watermark_image_width_row = new Adw.ActionRow ();
        watermark_image_width_row.set_title ("Width");
        watermark_image_width_row.set_subtitle ("Scale the watermark image to this width in pixels (-1 = original)");
        watermark_image_width = new SpinButton.with_range (-1, 3840, 1);
        watermark_image_width.set_value (150);
        watermark_image_width.set_valign (Align.CENTER);
        watermark_image_width_row.add_suffix (watermark_image_width);
        watermark_image_width_row.set_visible (false);
        watermark_expander.add_row (watermark_image_width_row);

        // ── Position ─────────────────────────────────────────────────────────
        var pos_row = new Adw.ActionRow ();
        pos_row.set_title ("Position");
        pos_row.set_subtitle ("Where to place the watermark");
        watermark_position = new DropDown (new StringList (
            { "Top Left", "Top Right", "Bottom Left", "Bottom Right", "Center" }
        ), null);
        watermark_position.set_valign (Align.CENTER);
        watermark_position.set_selected (3);  // default: Bottom Right
        pos_row.add_suffix (watermark_position);
        watermark_expander.add_row (pos_row);

        // ── Color ─────────────────────────────────────────────────────────────
        watermark_color_row = new Adw.ActionRow ();
        watermark_color_row.set_title ("Color");
        watermark_color_row.set_subtitle ("Text color — shadow adapts automatically");
        var color_dialog = new Gtk.ColorDialog ();
        color_dialog.set_with_alpha (false);
        watermark_color_button = new Gtk.ColorDialogButton (color_dialog);
        var default_color = Gdk.RGBA ();
        default_color.red = 1.0f;
        default_color.green = 1.0f;
        default_color.blue = 1.0f;
        default_color.alpha = 1.0f;
        watermark_color_button.set_rgba (default_color);
        watermark_color_button.set_valign (Align.CENTER);
        watermark_color_row.add_suffix (watermark_color_button);
        watermark_expander.add_row (watermark_color_row);

        // ── Opacity ──────────────────────────────────────────────────────────
        var opacity_row = new Adw.ActionRow ();
        opacity_row.set_title ("Opacity");
        opacity_row.set_subtitle ("0.05 = nearly invisible, 1.0 = fully opaque");
        watermark_opacity = new SpinButton.with_range (0.05, 1.0, 0.05);
        watermark_opacity.set_value (0.5);
        watermark_opacity.set_digits (2);
        watermark_opacity.set_valign (Align.CENTER);
        opacity_row.add_suffix (watermark_opacity);
        watermark_expander.add_row (opacity_row);

        // ── Margin ───────────────────────────────────────────────────────────
        var margin_row = new Adw.ActionRow ();
        margin_row.set_title ("Margin");
        margin_row.set_subtitle ("Distance from the edge in pixels");
        watermark_margin = new SpinButton.with_range (0, 500, 1);
        watermark_margin.set_value (10);
        watermark_margin.set_valign (Align.CENTER);
        margin_row.add_suffix (watermark_margin);
        watermark_expander.add_row (margin_row);

        // ── Font Size ────────────────────────────────────────────────────────
        watermark_font_row = new Adw.ActionRow ();
        watermark_font_row.set_title ("Font Size");
        watermark_font_row.set_subtitle ("Text size in pixels");
        watermark_font_size = new SpinButton.with_range (8, 200, 1);
        watermark_font_size.set_value (24);
        watermark_font_size.set_valign (Align.CENTER);
        watermark_font_row.add_suffix (watermark_font_size);
        watermark_expander.add_row (watermark_font_row);

        // ── Mode toggle visibility ───────────────────────────────────────────
        watermark_mode.notify["selected"].connect (() => {
            update_watermark_mode_visibility ();
            update_watermark_availability ();
            emit_watermark_if_changed ();
        });

        group.add (watermark_expander);
        build_logo_removal_rows (group);
        append (group);
    }

    // ── Logo Removal ─────────────────────────────────────────────────────────
    //    The inverse of the rows above: instead of stamping a watermark on the
    //    output, find the one already burned into the source and paint it out
    //    with delogo.  The user is not expected to know where the watermark is
    //    or how big it is — that is what the Detect button is for.

    private void build_logo_removal_rows (Adw.PreferencesGroup group) {
        delogo_check = new Switch ();
        delogo_check.set_active (false);

        delogo_expander = new Adw.ExpanderRow ();
        delogo_expander.set_title ("Logo Removal");
        delogo_expander.set_subtitle (DELOGO_SUBTITLE_DEFAULT);
        delogo_expander.set_show_enable_switch (true);
        delogo_expander.set_enable_expansion (false);

        delogo_check.bind_property ("active", delogo_expander, "enable-expansion",
            BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        // ── Detect ───────────────────────────────────────────────────────────
        delogo_detect_row = new Adw.ActionRow ();
        delogo_detect_row.set_title ("Auto-Detect");
        delogo_detect_row.set_subtitle (DELOGO_DETECT_SUBTITLE_DEFAULT);

        detect_logo_button = new Button.with_label ("Detect Watermark");
        detect_logo_button.add_css_class ("suggested-action");
        detect_logo_button.set_valign (Align.CENTER);
        detect_logo_button.set_tooltip_text (
            "Sample the video and locate a watermark that stays in one place");
        delogo_detect_row.add_suffix (detect_logo_button);
        delogo_expander.add_row (delogo_detect_row);

        // ── Detect moving ────────────────────────────────────────────────────
        //    The secondary path, for the logos the scan above is built to turn
        //    away: ones that hold a position for a while and then jump. It reads
        //    the whole video in short windows rather than sampling three
        //    stretches of it, so it is the slower of the two and stays opt-in.
        delogo_moving_row = new Adw.ActionRow ();
        delogo_moving_row.set_title ("Moving Watermark");
        delogo_moving_row.set_subtitle (DELOGO_MOVING_SUBTITLE_DEFAULT);

        detect_moving_logo_button = new Button.with_label ("Detect Moving");
        detect_moving_logo_button.set_valign (Align.CENTER);
        detect_moving_logo_button.set_tooltip_text (
            "Scan the whole video for a watermark that changes position, and "
            + "switch removal on and off around it");
        delogo_moving_row.add_suffix (detect_moving_logo_button);
        delogo_expander.add_row (delogo_moving_row);

        // ── Region ───────────────────────────────────────────────────────────
        //    Filled in by detection.  Editable so an off-by-a-few result can be
        //    nudged without re-scanning, but nobody has to touch it.
        var region_row = new Adw.ActionRow ();
        region_row.set_title ("Region");
        region_row.set_subtitle (
            "Filled in automatically — x:y:w:h, or start-end:x:y:w:h when timed");
        delogo_value = new Entry ();
        delogo_value.set_placeholder_text ("Press Detect Watermark");
        delogo_value.set_valign (Align.CENTER);
        delogo_value.set_width_chars (22);
        region_row.add_suffix (delogo_value);
        delogo_expander.add_row (region_row);

        group.add (delogo_expander);
    }

    private void update_watermark_mode_visibility () {
        bool is_image = watermark_mode.get_selected () == 1;

        // Text-only rows
        watermark_text_row.set_visible (!is_image);
        watermark_color_row.set_visible (!is_image);
        watermark_font_row.set_visible (!is_image);

        // Image-only rows
        watermark_image_source_row.set_visible (is_image);
        watermark_image_width_row.set_visible (is_image);
    }

    private Gtk.Image make_watermark_icon (string icon_name) {
        var icon = new Gtk.Image.from_icon_name (icon_name);
        icon.set_pixel_size (16);
        return icon;
    }

    private void on_watermark_image_browse_clicked () {
        var dialog = new FileDialog ();
        dialog.title = "Select Watermark Image";

        var image_filter = new FileFilter ();
        image_filter.name = "Image files (.png, .jpg, .jpeg, .webp, .bmp)";
        image_filter.add_pattern ("*.png");
        image_filter.add_pattern ("*.jpg");
        image_filter.add_pattern ("*.jpeg");
        image_filter.add_pattern ("*.webp");
        image_filter.add_pattern ("*.bmp");

        var all_filter = new FileFilter ();
        all_filter.name = "All files";
        all_filter.add_pattern ("*");

        var filters = new GLib.ListStore (typeof (FileFilter));
        filters.append (image_filter);
        filters.append (all_filter);
        dialog.set_filters (filters);

        dialog.open.begin (get_root () as Gtk.Window, null, (obj, res) => {
            try {
                var file = dialog.open.end (res);
                if (file == null) return;
                string? path = file.get_path ();
                if (path == null) return;
                apply_watermark_image_path (path);
            } catch (Error e) {
                // User cancelled — ignore
            }
        });
    }

    private void apply_watermark_image_path (string path) {
        watermark_image_path = path;
        string basename = Path.get_basename (path);
        watermark_image_source_row.set_title (basename);
        watermark_image_source_row.set_subtitle (path);
        emit_watermark_if_changed ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  7. METADATA
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
            emit_audio_speed_if_changed ();
        });
        video_speed_check.notify["active"].connect (() => {
            emit_video_speed_if_changed ();
        });
        audio_speed.value_changed.connect (() => {
            if (update_speed_spin_if_needed (audio_speed, "audio")) {
                return;
            }
            emit_audio_speed_if_changed ();
        });
        video_speed.value_changed.connect (() => {
            if (update_speed_spin_if_needed (video_speed, "video")) {
                return;
            }
            emit_video_speed_if_changed ();
        });
        detect_crop_button.clicked.connect (() => {
            crop_detect_clicked ();
        });

        // ── Watermark forwarding ────────────────────────────────────────────
        watermark_check.notify["active"].connect (() => {
            emit_watermark_if_changed ();
        });
        watermark_text.changed.connect (() => {
            emit_watermark_if_changed ();
        });
        // Mode and image path changes are wired in build_watermark_group().

        // ── Logo removal forwarding ─────────────────────────────────────────
        detect_moving_logo_button.clicked.connect (() => {
            logo_detect_moving_clicked ();
        });
        detect_logo_button.clicked.connect (() => {
            logo_detect_clicked ();
        });
        delogo_check.notify["active"].connect (() => {
            emit_logo_removal_if_changed ();
        });
        delogo_value.changed.connect (() => {
            emit_logo_removal_if_changed ();
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

    /**
     * Returns the custom resolution as "W:H" with values rounded to even,
     * or "" if either dimension is too small.
     */
    public string get_custom_resolution_value () {
        int w = ((int) custom_width.get_value ()) & ~1;   // round down to even
        int h = ((int) custom_height.get_value ()) & ~1;
        if (w < 2 || h < 2) return "";
        return @"$w:$h";
    }

    public string get_frame_rate_text () {
        var item = frame_rate_combo.selected_item as StringObject;
        return item != null ? item.string : "";
    }

    public string get_color_filter () {
        return color_dialog != null ? color_dialog.get_filter_string () : "";
    }

    public GeneralSettingsSnapshot snapshot_settings (
        PixelFormatSettingsSnapshot? pixel_format_settings = null) {
        var snapshot = new GeneralSettingsSnapshot ();
        snapshot.scale_mode = get_scale_mode_text ();
        snapshot.resolution_preset_value = get_resolution_preset_value ();
        snapshot.custom_resolution_value = get_custom_resolution_value ();
        snapshot.scale_width_multiplier = scale_width_x.get_value ();
        snapshot.scale_height_multiplier = scale_height_x.get_value ();
        snapshot.scale_algorithm = CodecUtils.get_dropdown_text (scale_algorithm);
        snapshot.scale_range = CodecUtils.get_dropdown_text (scale_range);
        snapshot.rotate = CodecUtils.get_dropdown_text (rotate_combo);
        snapshot.crop_enabled = crop_check.active;
        snapshot.crop_value = crop_value.text.strip ();
        snapshot.frame_rate_text = get_frame_rate_text ();
        snapshot.custom_frame_rate_text = get_custom_frame_rate_text ();
        snapshot.video_speed_enabled = is_video_speed_enabled ();
        snapshot.video_speed_percent = get_sanitized_speed_percent (video_speed, "video");
        snapshot.audio_speed_enabled = is_audio_speed_enabled ();
        snapshot.audio_speed_percent = get_sanitized_speed_percent (audio_speed, "audio");
        if (pixel_format_settings != null) {
            snapshot.pixel_format = pixel_format_settings.copy ();
        }
        snapshot.color_filter = get_color_filter ();
        snapshot.preserve_metadata = preserve_metadata.active;
        snapshot.remove_chapters = remove_chapters.active;
        snapshot.video_filters = video_filters.snapshot_settings (
            snapshot.pixel_format.ten_bit_selected);
        snapshot.watermark_enabled = is_watermark_effectively_enabled ();
        snapshot.watermark_mode = get_watermark_mode_text ();
        snapshot.watermark_text = watermark_text.text.strip ();
        snapshot.watermark_position = get_watermark_position_text ();
        snapshot.watermark_color = get_watermark_color_hex ();
        snapshot.watermark_opacity = watermark_opacity.get_value ();
        snapshot.watermark_margin = (int) watermark_margin.get_value ();
        snapshot.watermark_font_size = (int) watermark_font_size.get_value ();
        snapshot.watermark_image_path = watermark_image_path;
        snapshot.watermark_image_width = (int) watermark_image_width.get_value ();
        snapshot.delogo_enabled = is_logo_removal_effectively_enabled ();
        snapshot.delogo_regions = get_delogo_regions_text ();
        return snapshot;
    }

    public GeneralSpeedSettingsSnapshot snapshot_speeds_only () {
        var snapshot = new GeneralSpeedSettingsSnapshot ();
        snapshot.video_speed_enabled = video_speed_check.active;
        snapshot.video_speed_percent = video_speed.get_value ();
        snapshot.audio_speed_enabled = audio_speed_check.active;
        snapshot.audio_speed_percent = audio_speed.get_value ();
        return snapshot;
    }

    public void restore_speeds_only (GeneralSpeedSettingsSnapshot snapshot) {
        video_speed.set_value (snapshot.video_speed_percent);
        audio_speed.set_value (snapshot.audio_speed_percent);
        video_speed_check.set_active (snapshot.video_speed_enabled);
        audio_speed_check.set_active (snapshot.audio_speed_enabled);
    }

    public void set_combine_speed_constraint (bool constrained) {
        if (constrained) {
            video_speed_check.set_active (false);
            audio_speed_check.set_active (false);
            set_speed_locked (true);
        } else {
            set_speed_locked (false);
        }
    }

    public GeneralCropSettingsSnapshot snapshot_crop_only () {
        var snapshot = new GeneralCropSettingsSnapshot ();
        snapshot.crop_enabled = crop_check.active;
        snapshot.crop_value = crop_value.text;
        return snapshot;
    }

    public void restore_crop_only (GeneralCropSettingsSnapshot snapshot) {
        crop_value.set_text (snapshot.crop_value);
        crop_check.set_active (snapshot.crop_enabled && !is_crop_locked_effective ());
    }

    public void set_combine_crop_constraint (bool constrained) {
        combine_crop_locked = constrained;
        update_crop_lock_state ();
    }

    public GeneralTimingSettingsSnapshot snapshot_timing_only () {
        var snapshot = new GeneralTimingSettingsSnapshot ();
        snapshot.seek_enabled = seek_check.active;
        snapshot.seek_hours = seek_hh.get_value ();
        snapshot.seek_minutes = seek_mm.get_value ();
        snapshot.seek_seconds = seek_ss.get_value ();
        snapshot.time_enabled = time_check.active;
        snapshot.time_hours = time_hh.get_value ();
        snapshot.time_minutes = time_mm.get_value ();
        snapshot.time_seconds = time_ss.get_value ();
        return snapshot;
    }

    public void restore_timing_only (GeneralTimingSettingsSnapshot snapshot) {
        seek_hh.set_value (snapshot.seek_hours);
        seek_mm.set_value (snapshot.seek_minutes);
        seek_ss.set_value (snapshot.seek_seconds);
        time_hh.set_value (snapshot.time_hours);
        time_mm.set_value (snapshot.time_minutes);
        time_ss.set_value (snapshot.time_seconds);
        seek_check.set_active (snapshot.seek_enabled && !is_timing_locked_effective ());
        time_check.set_active (snapshot.time_enabled && !is_timing_locked_effective ());
    }

    public void set_combine_timing_constraint (bool constrained) {
        combine_timing_locked = constrained;
        update_timing_lock_state ();
    }

    private void update_scaling_visibility () {
        string mode = get_scale_mode_text ();
        bool is_resolution  = (mode == ScaleMode.RESOLUTION);
        bool is_custom      = (mode == ScaleMode.CUSTOM);
        bool is_percentage  = (mode == ScaleMode.PERCENTAGE);
        bool is_scaling     = is_resolution || is_custom || is_percentage;

        resolution_preset_row.set_visible (is_resolution);
        custom_width_row.set_visible (is_custom);
        custom_height_row.set_visible (is_custom);
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
            trim_timing_locked = false;
            update_timing_lock_state ();
            trim_crop_locked = false;
            update_crop_lock_state ();
            return;
        }

        // Seek / Duration are conflicted when trim segments are in play
        // (TRIM_ONLY=0, TRIM_AND_CROP=2, CHAPTER_SPLIT=3 all use segments
        //  with their own start/end times)
        bool lock_timing = (mode == 0 || mode == 2 || mode == 3);
        // Crop is conflicted when the interactive overlay is in play
        bool lock_crop   = (mode == 1 || mode == 2);   // CROP_ONLY or TRIM_AND_CROP

        trim_timing_locked = lock_timing;
        update_timing_lock_state ();
        trim_crop_locked = lock_crop;
        update_crop_lock_state ();
    }

    private bool is_timing_locked_effective () {
        return trim_timing_locked || combine_timing_locked;
    }

    private void update_timing_lock_state () {
        bool locked = is_timing_locked_effective ();
        if (locked) {
            // Collapse and deactivate first so the values don't reach ffmpeg
            seek_check.set_active (false);
            time_check.set_active (false);
            seek_expander.set_enable_expansion (false);
            time_expander.set_enable_expansion (false);

            seek_expander.set_sensitive (false);
            time_expander.set_sensitive (false);
        } else {
            seek_expander.set_sensitive (true);
            time_expander.set_sensitive (true);
        }

        if (combine_timing_locked) {
            seek_expander.set_subtitle (LOCK_REASON_TIMING_COMBINE);
            time_expander.set_subtitle (LOCK_REASON_TIMING_COMBINE);
            seek_expander.set_tooltip_text (LOCK_REASON_TIMING_COMBINE);
            time_expander.set_tooltip_text (LOCK_REASON_TIMING_COMBINE);
        } else if (trim_timing_locked) {
            seek_expander.set_subtitle (SEEK_SUBTITLE_DEFAULT);
            time_expander.set_subtitle (TIME_SUBTITLE_DEFAULT);
            seek_expander.set_tooltip_text (LOCK_REASON_TIMING_TRIM);
            time_expander.set_tooltip_text (LOCK_REASON_TIMING_TRIM);
        } else {
            seek_expander.set_subtitle (SEEK_SUBTITLE_DEFAULT);
            time_expander.set_subtitle (TIME_SUBTITLE_DEFAULT);
            seek_expander.set_tooltip_text (null);
            time_expander.set_tooltip_text (null);
        }
    }

    private bool is_crop_locked_effective () {
        return trim_crop_locked || combine_crop_locked;
    }

    private void update_crop_lock_state () {
        bool locked = is_crop_locked_effective ();
        if (locked) {
            // Collapse and deactivate so the crop value doesn't reach ffmpeg
            crop_check.set_active (false);
            crop_expander.set_enable_expansion (false);
            crop_expander.set_sensitive (false);
        } else {
            crop_expander.set_sensitive (true);
        }

        if (combine_crop_locked) {
            crop_expander.set_subtitle (LOCK_REASON_CROP_COMBINE);
            crop_expander.set_tooltip_text (LOCK_REASON_CROP_COMBINE);
        } else if (trim_crop_locked) {
            crop_expander.set_subtitle (CROP_SUBTITLE_DEFAULT);
            crop_expander.set_tooltip_text (LOCK_REASON_CROP);
        } else {
            crop_expander.set_subtitle (CROP_SUBTITLE_DEFAULT);
            crop_expander.set_tooltip_text (null);
        }
    }

    private void set_speed_locked (bool locked) {
        set_speed_expander_locked (
            video_speed_expander,
            VIDEO_SPEED_SUBTITLE_DEFAULT,
            locked
        );
        set_speed_expander_locked (
            audio_speed_expander,
            AUDIO_SPEED_SUBTITLE_DEFAULT,
            locked
        );
    }

    private void set_speed_expander_locked (Adw.ExpanderRow expander,
                                            string default_subtitle,
                                            bool locked) {
        if (locked) {
            expander.set_enable_expansion (false);
            expander.set_sensitive (false);
            expander.set_subtitle (LOCK_REASON_SPEED);
            expander.set_tooltip_text (LOCK_REASON_SPEED);
        } else {
            expander.set_sensitive (true);
            expander.set_subtitle (default_subtitle);
            expander.set_tooltip_text (null);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CROP DETECTION
    // ═════════════════════════════════════════════════════════════════════════

    public void start_crop_detection (string input_file, ConsoleTab console_tab) {
        if (input_file == "") {
            crop_value.set_text ("Please select an input file first");
            return;
        }

        detect_crop_button.sensitive = false;
        crop_value.set_text ("Analyzing for crop (30 seconds)...");
        crop_check.active = true;

        console_tab.add_line ("=== Crop Detection Started ===");
        console_tab.add_line ("Filter chain: " + FilterBuilder.get_crop_detection_chain (this));

        uint gen = crop_detect_gen;
        new Thread<void> ("crop-detect-thread", () => {
            perform_crop_detection (input_file, console_tab, gen);
        });
    }

    private void perform_crop_detection (string input_file, ConsoleTab console_tab, uint gen) {
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
            var process = SubprocessCompat.spawnv (launcher, cmd);
            var reader = new DataInputStream (process.get_stdout_pipe ());

            string line;
            while ((line = reader.read_line (null)) != null) {
                if (line.contains ("crop=")) {
                    string crop_val = extract_crop_value (line);
                    if (is_valid_crop_value (crop_val)) {
                        last_crop = crop_val;
                        string log_msg = line.strip ();
                        Idle.add (() => {
                            console_tab.add_line ("[CropDetect] " + log_msg);
                            return Source.REMOVE;
                        });
                    }
                }
            }

            process.wait ();

            string result_crop = last_crop;
            Idle.add (() => {
                if (gen != crop_detect_gen) return Source.REMOVE;
                if (is_valid_crop_value (result_crop)) {
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
                if (gen != crop_detect_gen) return Source.REMOVE;
                crop_value.set_text ("Detection error");
                console_tab.add_line ("Crop detection failed: " + err_msg);
                detect_crop_button.sensitive = true;
                return Source.REMOVE;
            });
        }
    }

    /**
     * Validates a crop string in the format "w:h:x:y".
     * Width/height must be positive integers and x/y must be non-negative
     * integers with no trailing junk accepted.
     */
    private bool is_valid_crop_value (string crop) {
        string[] parts = crop.split (":");
        if (parts.length != 4)
            return false;

        int w = 0;
        int h = 0;
        int x = 0;
        int y = 0;
        if (!ConversionUtils.try_parse_non_negative_int_strict (parts[0], out w)
            || !ConversionUtils.try_parse_non_negative_int_strict (parts[1], out h)
            || !ConversionUtils.try_parse_non_negative_int_strict (parts[2], out x)
            || !ConversionUtils.try_parse_non_negative_int_strict (parts[3], out y)) {
            return false;
        }

        return w > 0 && h > 0 && x >= 0 && y >= 0;
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

    public bool is_video_speed_enabled ()  {
        return is_speed_effectively_enabled (
            video_speed_check.active,
            video_speed.get_value (),
            "video"
        );
    }

    public bool is_audio_speed_enabled ()  {
        return is_speed_effectively_enabled (
            audio_speed_check.active,
            audio_speed.get_value (),
            "audio"
        );
    }

#if COMBINE_WINDOW_TEST_BUILD
    internal bool get_video_speed_expander_sensitive_for_widget_test () {
        return video_speed_expander.get_sensitive ();
    }

    internal bool get_audio_speed_expander_sensitive_for_widget_test () {
        return audio_speed_expander.get_sensitive ();
    }

    internal string get_video_speed_subtitle_for_widget_test () {
        return video_speed_expander.get_subtitle () ?? "";
    }

    internal string get_audio_speed_subtitle_for_widget_test () {
        return audio_speed_expander.get_subtitle () ?? "";
    }

    internal bool get_crop_expander_sensitive_for_widget_test () {
        return crop_expander.get_sensitive ();
    }

    internal string get_crop_subtitle_for_widget_test () {
        return crop_expander.get_subtitle () ?? "";
    }

    internal bool get_seek_expander_sensitive_for_widget_test () {
        return seek_expander.get_sensitive ();
    }

    internal bool get_time_expander_sensitive_for_widget_test () {
        return time_expander.get_sensitive ();
    }

    internal string get_seek_subtitle_for_widget_test () {
        return seek_expander.get_subtitle () ?? "";
    }

    internal string get_time_subtitle_for_widget_test () {
        return time_expander.get_subtitle () ?? "";
    }
#endif

    // ── Crop ─────────────────────────────────────────────────────────────────

    public bool is_crop_enabled ()         { return crop_check.active; }
    public string get_crop_value_text ()   { return crop_value.text.strip (); }

    public void reset_crop () {
        crop_detect_gen++;
        crop_check.active = false;
        crop_value.text = "";
        detect_crop_button.sensitive = true;
    }

    /**
     * Clears a previous detection. Regions are in source-frame pixels, so they
     * are meaningless against a different file — the caller resets on every
     * input change.
     */
    public void reset_logo_removal () {
        delogo_detect_gen++;
        delogo_check.active = false;
        delogo_value.text = "";
        set_logo_detect_buttons_sensitive (true);
        delogo_detect_row.set_subtitle (DELOGO_DETECT_SUBTITLE_DEFAULT);
        delogo_moving_row.set_subtitle (DELOGO_MOVING_SUBTITLE_DEFAULT);
        delogo_expander.set_subtitle (
            delogo_available ? DELOGO_SUBTITLE_DEFAULT : DELOGO_UNAVAILABLE);
        emit_logo_removal_if_changed ();
    }

    // ── Frame Rate ───────────────────────────────────────────────────────────

    public string get_custom_frame_rate_text () { return custom_frame_rate.text.strip (); }

    // ── Watermark ────────────────────────────────────────────────────────────

    public bool is_watermark_effectively_enabled () {
        if (!watermark_check.active) return false;

        if (get_watermark_mode_text () == "image") {
            return overlay_available
                && watermark_image_path.length > 0
                && FileUtils.test (watermark_image_path, FileTest.EXISTS);
        }

        // text mode
        return drawtext_available
            && watermark_text.text.strip ().length > 0;
    }

    public bool is_watermark_image_mode () {
        return is_watermark_effectively_enabled ()
            && get_watermark_mode_text () == "image";
    }

    public void set_drawtext_available (bool available, string? reason = null) {
        drawtext_available = available;
        drawtext_unavailable_reason = reason;
        update_watermark_availability ();
    }

    public void set_overlay_available (bool available, string? reason = null) {
        overlay_available = available;
        overlay_unavailable_reason = reason;
        update_watermark_availability ();
    }

    private void update_watermark_availability () {
        bool either_available = drawtext_available || overlay_available;
        bool is_image = watermark_mode.get_selected () == 1;
        bool current_mode_available = is_image ? overlay_available : drawtext_available;

        if (!either_available) {
            // Neither filter available — fully disable watermark
            watermark_check.set_active (false);
            watermark_expander.set_enable_expansion (false);
            watermark_expander.set_sensitive (false);
            string reason = drawtext_unavailable_reason
                ?? overlay_unavailable_reason
                ?? WATERMARK_DRAWTEXT_UNAVAILABLE;
            watermark_expander.set_subtitle (reason);
            watermark_expander.set_tooltip_text (reason);
        } else {
            // At least one filter available — expander stays usable
            watermark_expander.set_sensitive (true);

            if (!current_mode_available) {
                // Current mode's filter is missing — show a hint but let the
                // user switch modes.  Deactivate the enable switch so we don't
                // claim an effective watermark while the active mode can't run.
                watermark_check.set_active (false);
                string hint;
                if (is_image) {
                    hint = overlay_unavailable_reason ?? WATERMARK_OVERLAY_UNAVAILABLE;
                } else {
                    hint = drawtext_unavailable_reason ?? WATERMARK_DRAWTEXT_UNAVAILABLE;
                }
                watermark_expander.set_subtitle (hint);
                watermark_expander.set_tooltip_text (hint);
            } else {
                watermark_expander.set_subtitle (WATERMARK_SUBTITLE_DEFAULT);
                watermark_expander.set_tooltip_text (null);
            }
        }

        emit_watermark_if_changed ();
    }

    private string get_watermark_mode_text () {
        var item = watermark_mode.selected_item as StringObject;
        return item != null ? item.string.down () : "text";
    }

    private string get_watermark_position_text () {
        var item = watermark_position.selected_item as StringObject;
        return item != null ? item.string : "Bottom Right";
    }

    private string get_watermark_color_hex () {
        Gdk.RGBA rgba = watermark_color_button.get_rgba ();
        int r = (int) Math.round (rgba.red * 255.0).clamp (0, 255);
        int g = (int) Math.round (rgba.green * 255.0).clamp (0, 255);
        int b = (int) Math.round (rgba.blue * 255.0).clamp (0, 255);
        return "%02x%02x%02x".printf (r, g, b);
    }

    // ── Logo Removal ─────────────────────────────────────────────────────────

    /**
     * Logo removal only counts as active once detection (or a hand-typed
     * region) has produced something delogo can actually use.
     */
    public bool is_logo_removal_effectively_enabled () {
        if (!delogo_check.active || !delogo_available) return false;
        // Either form counts: plain rectangles from the static scan, or timed
        // ones from the moving scan.
        return LogoDetectorLogic.has_any_regions (delogo_value.text);
    }

    public string get_delogo_regions_text () {
        return delogo_value.text.strip ();
    }

    public void set_delogo_available (bool available, string? reason = null) {
        delogo_available = available;
        delogo_unavailable_reason = reason;

        if (!available) {
            delogo_check.set_active (false);
            delogo_expander.set_enable_expansion (false);
        }
        delogo_expander.set_sensitive (available);

        string hint = available
            ? DELOGO_SUBTITLE_DEFAULT
            : (delogo_unavailable_reason ?? DELOGO_UNAVAILABLE);
        delogo_expander.set_subtitle (hint);
        delogo_expander.set_tooltip_text (available ? null : hint);

        emit_logo_removal_if_changed ();
    }

    /**
     * Kicks off a watermark scan on a worker thread. Mirrors crop detection:
     * a generation counter retires results that land after the user has moved
     * on to another file.
     */
    public void start_logo_detection (string input_file, ConsoleTab console_tab,
                                      bool moving = false) {
        Adw.ActionRow row = moving ? delogo_moving_row : delogo_detect_row;

        if (input_file.strip () == "") {
            row.set_subtitle ("Please select an input file first");
            return;
        }
        if (!delogo_available) {
            row.set_subtitle (delogo_unavailable_reason ?? DELOGO_UNAVAILABLE);
            return;
        }

        // Either scan blocks the other: they write to the same Region entry, and
        // whichever finished last would win by accident.
        set_logo_detect_buttons_sensitive (false);
        row.set_subtitle (moving
            ? "Reading the whole video for a watermark that moves…"
            : "Scanning the video for a watermark…");

        console_tab.add_line (moving
            ? "=== Moving Watermark Detection Started ==="
            : "=== Watermark Detection Started ===");

        uint generation = ++delogo_detect_gen;
        new Thread<void> ("logo-detect-thread", () => {
            perform_logo_detection (input_file, console_tab, generation, moving);
        });
    }

    private void set_logo_detect_buttons_sensitive (bool sensitive) {
        detect_logo_button.sensitive = sensitive;
        detect_moving_logo_button.sensitive = sensitive;
    }

    private void perform_logo_detection (string input_file,
                                         ConsoleTab console_tab,
                                         uint generation,
                                         bool moving) {
        var settings = AppSettings.get_default ();

        LogoDetectLogFunc log = (line) => {
            string message = line;
            Idle.add (() => {
                console_tab.add_line (message);
                return Source.REMOVE;
            });
        };

        LogoDetectionResult result = moving
            ? LogoDetector.run_moving (input_file, settings.ffmpeg_path,
                                       settings.ffprobe_path, log)
            : LogoDetector.run (input_file, settings.ffmpeg_path,
                                settings.ffprobe_path, log);

        Idle.add (() => {
            if (generation != delogo_detect_gen) return Source.REMOVE;
            apply_logo_detection_result (result, console_tab, moving);
            return Source.REMOVE;
        });
    }

    private void apply_logo_detection_result (LogoDetectionResult result,
                                              ConsoleTab console_tab,
                                              bool moving) {
        set_logo_detect_buttons_sensitive (true);
        Adw.ActionRow row = moving ? delogo_moving_row : delogo_detect_row;

        if (result.success) {
            delogo_value.set_text (result.regions);
            row.set_subtitle (result.message);
            delogo_check.set_active (true);
            console_tab.add_line ("✅ " + result.message + " — " + result.regions);
        } else {
            delogo_value.set_text ("");
            row.set_subtitle (result.message);
            console_tab.add_line ("⚠️ " + result.message);
        }

        // The other row still shows whatever it last said, which would read as
        // two competing answers to the same question.
        Adw.ActionRow other = moving ? delogo_detect_row : delogo_moving_row;
        other.set_subtitle (moving
            ? DELOGO_DETECT_SUBTITLE_DEFAULT
            : DELOGO_MOVING_SUBTITLE_DEFAULT);

        emit_logo_removal_if_changed ();
    }

#if COMBINE_WINDOW_TEST_BUILD
    internal bool get_watermark_expander_sensitive_for_widget_test () {
        return watermark_expander.get_sensitive ();
    }

    internal string get_watermark_subtitle_for_widget_test () {
        return watermark_expander.get_subtitle () ?? "";
    }
#endif
}
