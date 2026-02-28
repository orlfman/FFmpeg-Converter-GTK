using Gtk;
using Adw;
using GLib;

public class GeneralTab : Box {

    // ── Scaling ──────────────────────────────────────────────────────────────
    public SpinButton scale_width_x    { get; private set; }
    public SpinButton scale_height_x   { get; private set; }
    public DropDown   scale_algorithm  { get; private set; }
    public DropDown   scale_range      { get; private set; }

    // ── Pixel Format ─────────────────────────────────────────────────────────
    public Switch   eight_bit_check    { get; private set; }
    public DropDown eight_bit_format   { get; private set; }
    public Switch   ten_bit_check      { get; private set; }
    public DropDown ten_bit_format     { get; private set; }

    private Adw.ActionRow eight_bit_fmt_row;
    private Adw.ActionRow ten_bit_fmt_row;

    // ── Crop ─────────────────────────────────────────────────────────────────
    public Switch  crop_check          { get; private set; }
    public Button  detect_crop_button  { get; private set; }
    public Entry   crop_value          { get; private set; }

    private Adw.ExpanderRow crop_expander;

    // ── Rotate ───────────────────────────────────────────────────────────────
    public DropDown rotate_combo       { get; private set; }

    // ── Quick Filters ────────────────────────────────────────────────────────
    public Switch deinterlace          { get; private set; }
    public Switch deblock              { get; private set; }
    public Switch denoise              { get; private set; }
    public Switch sharpen              { get; private set; }
    public Switch grain                { get; private set; }

    // ── HDR Tone Mapping ─────────────────────────────────────────────────────
    public Switch     hdr_tonemap      { get; private set; }
    public DropDown   tonemap_mode     { get; private set; }
    public SpinButton tonemap_desat    { get; private set; }

    private Adw.ExpanderRow hdr_expander;
    private Adw.ActionRow   tonemap_desat_row;

    // ── Color Correction ─────────────────────────────────────────────────────
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

    // ── Seek & Time ──────────────────────────────────────────────────────────
    public Switch seek_check           { get; private set; }
    public Entry  seek_hh              { get; private set; }
    public Entry  seek_mm              { get; private set; }
    public Entry  seek_ss              { get; private set; }

    public Switch time_check           { get; private set; }
    public Entry  time_hh              { get; private set; }
    public Entry  time_mm              { get; private set; }
    public Entry  time_ss              { get; private set; }

    private Adw.ExpanderRow seek_expander;
    private Adw.ExpanderRow time_expander;

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public GeneralTab () {
        Object (orientation: Orientation.VERTICAL, spacing: 24);
        set_margin_top (24);
        set_margin_bottom (24);
        set_margin_start (24);
        set_margin_end (24);

        build_scaling_group ();
        build_pixel_format_group ();
        build_rotation_crop_group ();
        build_filters_group ();
        build_color_correction_group ();
        build_frame_rate_speed_group ();
        build_audio_group ();
        build_timing_group ();

        connect_signals ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SCALING
    // ═════════════════════════════════════════════════════════════════════════

    private void build_scaling_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Scaling");
        group.set_description ("Resize the video output");

        // Width multiplier
        var w_row = new Adw.ActionRow ();
        w_row.set_title ("Width Multiplier");
        w_row.set_subtitle ("1.00 = original width");
        scale_width_x = new SpinButton.with_range (0.0, 10.0, 0.05);
        scale_width_x.set_value (1.0);
        scale_width_x.set_digits (2);
        scale_width_x.set_valign (Align.CENTER);
        w_row.add_suffix (scale_width_x);
        group.add (w_row);

        // Height multiplier
        var h_row = new Adw.ActionRow ();
        h_row.set_title ("Height Multiplier");
        h_row.set_subtitle ("1.00 = original height");
        scale_height_x = new SpinButton.with_range (0.0, 10.0, 0.05);
        scale_height_x.set_value (1.0);
        scale_height_x.set_digits (2);
        scale_height_x.set_valign (Align.CENTER);
        h_row.add_suffix (scale_height_x);
        group.add (h_row);

        // Algorithm
        var alg_row = new Adw.ActionRow ();
        alg_row.set_title ("Algorithm");
        alg_row.set_subtitle ("Scaling filter — Lanczos is best for most content");
        scale_algorithm = new DropDown (new StringList (
            { "lanczos", "point", "bilinear", "bicubic", "spline16", "spline36" }
        ), null);
        scale_algorithm.set_valign (Align.CENTER);
        scale_algorithm.set_selected (0);
        alg_row.add_suffix (scale_algorithm);
        group.add (alg_row);

        // Range
        var range_row = new Adw.ActionRow ();
        range_row.set_title ("Color Range");
        range_row.set_subtitle ("Input preserves the original range");
        scale_range = new DropDown (new StringList (
            { "input", "limited", "full" }
        ), null);
        scale_range.set_valign (Align.CENTER);
        scale_range.set_selected (0);
        range_row.add_suffix (scale_range);
        group.add (range_row);

        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PIXEL FORMAT
    // ═════════════════════════════════════════════════════════════════════════

    private void build_pixel_format_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Pixel Format");
        group.set_description ("Color depth and chroma subsampling");

        // 8-Bit toggle
        var eight_row = new Adw.ActionRow ();
        eight_row.set_title ("8-Bit Color");
        eight_row.set_subtitle ("Standard dynamic range — compatible with all players");
        eight_bit_check = new Switch ();
        eight_bit_check.set_valign (Align.CENTER);
        eight_bit_check.set_active (false);
        eight_row.add_suffix (eight_bit_check);
        eight_row.set_activatable_widget (eight_bit_check);
        group.add (eight_row);

        // 8-Bit format (hidden until enabled)
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

        // 10-Bit toggle
        var ten_row = new Adw.ActionRow ();
        ten_row.set_title ("10-Bit Color");
        ten_row.set_subtitle ("Higher color depth — better gradients, HDR support");
        ten_bit_check = new Switch ();
        ten_bit_check.set_valign (Align.CENTER);
        ten_bit_check.set_active (false);
        ten_row.add_suffix (ten_bit_check);
        ten_row.set_activatable_widget (ten_bit_check);
        group.add (ten_row);

        // 10-Bit format (hidden until enabled)
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
    //  ROTATION & CROP
    // ═════════════════════════════════════════════════════════════════════════

    private void build_rotation_crop_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Rotation &amp; Crop");

        // Rotate / Flip
        var rotate_row = new Adw.ActionRow ();
        rotate_row.set_title ("Rotate / Flip");
        rotate_row.set_subtitle ("Transform the video orientation");
        rotate_combo = new DropDown (new StringList (
            { "No Rotation", "90° Clockwise", "90° Counterclockwise", "180°",
              "Horizontal Flip", "Vertical Flip" }
        ), null);
        rotate_combo.set_valign (Align.CENTER);
        rotate_combo.set_selected (0);
        rotate_row.add_suffix (rotate_combo);
        group.add (rotate_row);

        // Crop (ExpanderRow)
        crop_check = new Switch ();
        crop_check.set_active (false);

        crop_expander = new Adw.ExpanderRow ();
        crop_expander.set_title ("Crop");
        crop_expander.set_subtitle ("Remove black bars or unwanted borders");
        crop_expander.set_show_enable_switch (true);
        crop_expander.set_enable_expansion (false);

        // Sync hidden Switch ↔ ExpanderRow
        crop_check.bind_property ("active", crop_expander, "enable-expansion",
            BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        // Detect button row
        var detect_row = new Adw.ActionRow ();
        detect_row.set_title ("Auto-Detect");
        detect_row.set_subtitle ("Analyze 30 seconds of video for black bars");
        detect_crop_button = new Button.with_label ("Detect");
        detect_crop_button.add_css_class ("suggested-action");
        detect_crop_button.set_valign (Align.CENTER);
        detect_row.add_suffix (detect_crop_button);
        detect_row.set_activatable_widget (detect_crop_button);
        crop_expander.add_row (detect_row);

        // Crop value row
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
    //  FILTERS & ENHANCEMENT
    // ═════════════════════════════════════════════════════════════════════════

    private void build_filters_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Filters &amp; Enhancement");
        group.set_description ("Video processing filters");

        // Deinterlace
        var di_row = new Adw.ActionRow ();
        di_row.set_title ("Deinterlace");
        di_row.set_subtitle ("Remove interlacing artifacts from older video sources");
        deinterlace = new Switch ();
        deinterlace.set_valign (Align.CENTER);
        di_row.add_suffix (deinterlace);
        di_row.set_activatable_widget (deinterlace);
        group.add (di_row);

        // Deblock
        var db_row = new Adw.ActionRow ();
        db_row.set_title ("Deblock");
        db_row.set_subtitle ("Reduce blocky compression artifacts");
        deblock = new Switch ();
        deblock.set_valign (Align.CENTER);
        db_row.add_suffix (deblock);
        db_row.set_activatable_widget (deblock);
        group.add (db_row);

        // Denoise
        var dn_row = new Adw.ActionRow ();
        dn_row.set_title ("Denoise");
        dn_row.set_subtitle ("Remove video noise and grain with hqdn3d");
        denoise = new Switch ();
        denoise.set_valign (Align.CENTER);
        dn_row.add_suffix (denoise);
        dn_row.set_activatable_widget (denoise);
        group.add (dn_row);

        // Sharpen
        var sh_row = new Adw.ActionRow ();
        sh_row.set_title ("Super Sharp");
        sh_row.set_subtitle ("Increase edge sharpness with unsharp mask");
        sharpen = new Switch ();
        sharpen.set_valign (Align.CENTER);
        sh_row.add_suffix (sharpen);
        sh_row.set_activatable_widget (sharpen);
        group.add (sh_row);

        // Grain
        var gr_row = new Adw.ActionRow ();
        gr_row.set_title ("Add Grain");
        gr_row.set_subtitle ("Add a film-like grain texture");
        grain = new Switch ();
        grain.set_valign (Align.CENTER);
        gr_row.add_suffix (grain);
        gr_row.set_activatable_widget (grain);
        group.add (gr_row);

        // HDR Tone Mapping (ExpanderRow)
        hdr_tonemap = new Switch ();
        hdr_tonemap.set_active (false);

        hdr_expander = new Adw.ExpanderRow ();
        hdr_expander.set_title ("HDR to SDR");
        hdr_expander.set_subtitle ("Tone map HDR content for standard displays");
        hdr_expander.set_show_enable_switch (true);
        hdr_expander.set_enable_expansion (false);

        hdr_tonemap.bind_property ("active", hdr_expander, "enable-expansion",
            BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        var mode_row = new Adw.ActionRow ();
        mode_row.set_title ("Mode");
        tonemap_mode = new DropDown (new StringList (
            { "Standard", "Less Saturation", "Custom" }
        ), null);
        tonemap_mode.set_valign (Align.CENTER);
        tonemap_mode.set_selected (0);
        mode_row.add_suffix (tonemap_mode);
        hdr_expander.add_row (mode_row);

        tonemap_desat_row = new Adw.ActionRow ();
        tonemap_desat_row.set_title ("Desaturation");
        tonemap_desat_row.set_subtitle ("Custom desaturation level (0.00 – 1.00)");
        tonemap_desat = new SpinButton.with_range (0.0, 1.0, 0.01);
        tonemap_desat.set_value (0.35);
        tonemap_desat.set_digits (2);
        tonemap_desat.set_valign (Align.CENTER);
        tonemap_desat_row.add_suffix (tonemap_desat);
        tonemap_desat_row.set_visible (false);
        hdr_expander.add_row (tonemap_desat_row);

        group.add (hdr_expander);
        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  COLOR CORRECTION
    // ═════════════════════════════════════════════════════════════════════════

    private void build_color_correction_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Color Correction");

        var color_row = new Adw.ActionRow ();
        color_row.set_title ("Adjust Colors");
        color_row.set_subtitle ("Brightness, contrast, saturation, gamma, hue, and more");
        color_button = new Button.with_label ("Open");
        color_button.add_css_class ("suggested-action");
        color_button.set_valign (Align.CENTER);
        color_row.add_suffix (color_button);
        color_row.set_activatable_widget (color_button);
        group.add (color_row);

        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  FRAME RATE & SPEED
    // ═════════════════════════════════════════════════════════════════════════

    private void build_frame_rate_speed_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Frame Rate &amp; Speed");

        // Frame Rate
        var fr_row = new Adw.ActionRow ();
        fr_row.set_title ("Frame Rate");
        fr_row.set_subtitle ("Original preserves the source frame rate");
        frame_rate_combo = new DropDown (new StringList (
            { "Original", "24", "30", "60", "Custom" }
        ), null);
        frame_rate_combo.set_valign (Align.CENTER);
        frame_rate_combo.set_selected (0);
        fr_row.add_suffix (frame_rate_combo);
        group.add (fr_row);

        // Custom Frame Rate (hidden until "Custom" selected)
        custom_fr_row = new Adw.ActionRow ();
        custom_fr_row.set_title ("Custom Frame Rate");
        custom_fr_row.set_subtitle ("Enter a specific frame rate value");
        custom_frame_rate = new Entry ();
        custom_frame_rate.set_placeholder_text ("e.g. 23.976");
        custom_frame_rate.set_valign (Align.CENTER);
        custom_frame_rate.set_width_chars (10);
        custom_fr_row.add_suffix (custom_frame_rate);
        custom_fr_row.set_visible (false);
        group.add (custom_fr_row);

        // Video Speed (ExpanderRow)
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
        vspeed_row.set_subtitle ("Percentage change (−100 to +100)");
        video_speed = new SpinButton.with_range (-100, 100, 5);
        video_speed.set_value (0);
        video_speed.set_valign (Align.CENTER);
        vspeed_row.add_suffix (video_speed);
        video_speed_expander.add_row (vspeed_row);
        group.add (video_speed_expander);

        // Audio Speed (ExpanderRow)
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
        aspeed_row.set_subtitle ("Percentage change (−100 to +100)");
        audio_speed = new SpinButton.with_range (-100, 100, 5);
        audio_speed.set_value (0);
        audio_speed.set_valign (Align.CENTER);
        aspeed_row.add_suffix (audio_speed);
        audio_speed_expander.add_row (aspeed_row);
        group.add (audio_speed_expander);

        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  AUDIO
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
    //  TIMING & METADATA
    // ═════════════════════════════════════════════════════════════════════════

    private void build_timing_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Timing &amp; Metadata");

        // Preserve Metadata
        var meta_row = new Adw.ActionRow ();
        meta_row.set_title ("Preserve Metadata");
        meta_row.set_subtitle ("Copy metadata tags from the source file");
        preserve_metadata = new Switch ();
        preserve_metadata.set_valign (Align.CENTER);
        preserve_metadata.set_active (false);
        meta_row.add_suffix (preserve_metadata);
        meta_row.set_activatable_widget (preserve_metadata);
        group.add (meta_row);

        // Remove Chapters
        var chap_row = new Adw.ActionRow ();
        chap_row.set_title ("Remove Chapters");
        chap_row.set_subtitle ("Strip chapter markers from the output");
        remove_chapters = new Switch ();
        remove_chapters.set_valign (Align.CENTER);
        remove_chapters.set_active (false);
        chap_row.add_suffix (remove_chapters);
        chap_row.set_activatable_widget (remove_chapters);
        group.add (chap_row);

        // Seek (ExpanderRow)
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

        seek_hh = new Entry (); seek_hh.set_text ("0"); seek_hh.set_width_chars (3);
        seek_mm = new Entry (); seek_mm.set_text ("0"); seek_mm.set_width_chars (3);
        seek_ss = new Entry (); seek_ss.set_text ("0"); seek_ss.set_width_chars (3);

        var seek_box = new Box (Orientation.HORIZONTAL, 4);
        seek_box.set_valign (Align.CENTER);
        seek_box.append (seek_hh);
        seek_box.append (new Label (":"));
        seek_box.append (seek_mm);
        seek_box.append (new Label (":"));
        seek_box.append (seek_ss);
        seek_entries_row.add_suffix (seek_box);
        seek_expander.add_row (seek_entries_row);
        group.add (seek_expander);

        // Time / Duration (ExpanderRow)
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

        time_hh = new Entry (); time_hh.set_text ("0"); time_hh.set_width_chars (3);
        time_mm = new Entry (); time_mm.set_text ("0"); time_mm.set_width_chars (3);
        time_ss = new Entry (); time_ss.set_text ("0"); time_ss.set_width_chars (3);

        var time_box = new Box (Orientation.HORIZONTAL, 4);
        time_box.set_valign (Align.CENTER);
        time_box.append (time_hh);
        time_box.append (new Label (":"));
        time_box.append (time_mm);
        time_box.append (new Label (":"));
        time_box.append (time_ss);
        time_entries_row.add_suffix (time_box);
        time_expander.add_row (time_entries_row);
        group.add (time_expander);

        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SIGNALS
    // ═════════════════════════════════════════════════════════════════════════

    private void connect_signals () {
        // 8-Bit / 10-Bit mutual exclusion
        eight_bit_check.notify["active"].connect (() => {
            eight_bit_fmt_row.set_visible (eight_bit_check.active);
            if (eight_bit_check.active) ten_bit_check.active = false;
        });
        ten_bit_check.notify["active"].connect (() => {
            ten_bit_fmt_row.set_visible (ten_bit_check.active);
            if (ten_bit_check.active) eight_bit_check.active = false;
        });

        // HDR tonemap: show/hide desaturation based on mode
        tonemap_mode.notify["selected"].connect (() => {
            tonemap_desat_row.set_visible (get_tonemap_text () == "Custom");
        });

        // Frame Rate: show/hide custom entry
        frame_rate_combo.notify["selected"].connect (() => {
            custom_fr_row.set_visible (get_frame_rate_text () == "Custom");
        });

        // Color Correction dialog
        color_button.clicked.connect (() => {
            if (color_dialog == null)
                color_dialog = new ColorCorrectionDialog (get_root () as Gtk.Window);
            color_dialog.present ();
        });
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    private string get_tonemap_text () {
        var item = tonemap_mode.selected_item as StringObject;
        return item != null ? item.string : "";
    }

    private string get_frame_rate_text () {
        var item = frame_rate_combo.selected_item as StringObject;
        return item != null ? item.string : "";
    }

    public string get_color_filter () {
        return color_dialog != null ? color_dialog.get_filter_string () : "";
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
            "ffmpeg", "-hide_banner", "-loglevel", "info", "-nostats",
            "-i", input_file,
            "-vf", vf,
            "-f", "null",
            "-t", "30",
            "-"
        };

        string last_crop = "";
        GLib.Error? crop_error = null;

        try {
            var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_MERGE);
            var process = launcher.spawnv (cmd);

            string stdout_text, stderr_text;
            try {
                process.communicate_utf8 (null, null, out stdout_text, out stderr_text);
            } catch (Error e) {
                stdout_text = "";
                stderr_text = "";
            }

            string output = stdout_text + "\n" + stderr_text;
            string[] lines = output.split ("\n");

            for (int i = 0; i < lines.length; i++) {
                string line = lines[i];
                if (line.contains ("crop=")) {
                    string crop_val = extract_crop_value (line);
                    if (crop_val.length > 5 && crop_val.contains (":")) {
                        string[] parts = crop_val.split (":");
                        if (parts.length == 4 &&
                            int.parse (parts[0]) > 0 &&
                            int.parse (parts[1]) > 0) {
                            last_crop = crop_val;
                            Idle.add (() => {
                                console_tab.add_line ("[CropDetect] " + line.strip ());
                                return Source.REMOVE;
                            });
                        }
                    }
                }
            }

            process.wait ();

            Idle.add (() => {
                if (last_crop.length > 8) {
                    crop_value.set_text (last_crop);
                    console_tab.add_line (@"✅ Detected stable crop: $last_crop");
                } else {
                    crop_value.set_text ("No crop detected");
                    console_tab.add_line ("⚠️ No valid crop= format found");
                }
                detect_crop_button.sensitive = true;
                return Source.REMOVE;
            });

        } catch (GLib.Error e) {
            crop_error = e;
            Idle.add (() => {
                crop_value.set_text ("❌ Detection error");
                console_tab.add_line ("Crop detection failed: " + crop_error.message);
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
        return (end > 0) ? part.substring (0, end) : part;
    }
}
