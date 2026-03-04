using Gtk;
using Adw;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  TrimSegment — Data object for a start/end time range + optional crop
// ═══════════════════════════════════════════════════════════════════════════════

public class TrimSegment : Object {
    public double start_time  { get; set; }
    public double end_time    { get; set; }
    public string crop_value  { get; set; default = ""; }

    public TrimSegment (double start, double end) {
        this.start_time = start;
        this.end_time   = end;
    }

    public double get_duration () {
        return (end_time - start_time).clamp (0.0, double.MAX);
    }

    public bool has_crop () {
        return crop_value != null && crop_value.strip ().length > 0;
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  TrimTab — Video trimming, cropping, and segment management
//
//  Modes:
//    • Trim Only   — cut segments (original behaviour)
//    • Crop Only   — crop the entire video with interactive overlay
//    • Crop & Trim — segments with optional per-segment or global crop
//
//  The crop rectangle is drawn interactively on the video player and maps
//  directly to FFmpeg's  crop=W:H:X:Y  filter.
// ═══════════════════════════════════════════════════════════════════════════════

public class TrimTab : Box, ICodecTab {

    // ── Mode ─────────────────────────────────────────────────────────────────
    public enum Mode { TRIM_ONLY, CROP_ONLY, TRIM_AND_CROP }
    private Mode current_mode = Mode.TRIM_ONLY;
    private DropDown mode_dropdown;

    // ── Video Player ─────────────────────────────────────────────────────────
    private VideoPlayer player;

    // ── Mark In / Out state ──────────────────────────────────────────────────
    private double mark_in  = 0.0;
    private double mark_out = 0.0;
    private Label mark_in_label;
    private Label mark_out_label;

    // ── Segment list ─────────────────────────────────────────────────────────
    private GenericArray<TrimSegment> segments = new GenericArray<TrimSegment> ();
    private Adw.PreferencesGroup segments_group;
    private Gtk.ListBox segment_listbox;
    private Label segment_count_label;

    // ── Crop Controls ────────────────────────────────────────────────────────
    private Adw.PreferencesGroup crop_group;
    private Label crop_value_label;
    private Entry crop_entry;
    private Switch crop_scope_switch;        // ON = per-segment, OFF = global
    private Adw.ActionRow crop_scope_row;
    private Button crop_reset_btn;
    private Button crop_apply_all_btn;
    private string global_crop_value = "";   // stored global crop

    // ── Output mode ──────────────────────────────────────────────────────────
    private Switch copy_mode_switch;
    private Switch keyframe_cut_switch;
    private Adw.ActionRow keyframe_cut_row;
    private Adw.ActionRow reencode_codec_row;
    private DropDown codec_choice;
    private Switch export_separate_switch;

    // ── Sections (for visibility toggling) ───────────────────────────────────
    private Adw.PreferencesGroup mark_group;
    private Adw.PreferencesGroup output_group;

    // ── External references (set by MainWindow) ──────────────────────────────
    public GeneralTab? general_tab  { get; set; default = null; }
    public SvtAv1Tab?  svt_tab      { get; set; default = null; }
    public X265Tab?    x265_tab     { get; set; default = null; }
    public X264Tab?    x264_tab     { get; set; default = null; }
    public Vp9Tab?     vp9_tab      { get; set; default = null; }

    // ── Trim runner ──────────────────────────────────────────────────────────
    private TrimRunner? active_runner = null;
    private bool speed_locked = false;  // true when speed filters force re-encode

    // ── Signals ──────────────────────────────────────────────────────────────
    public signal void trim_done (string output_path);
    public signal void mode_changed (int mode);

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public TrimTab () {
        Object (orientation: Orientation.VERTICAL, spacing: 24);
        set_margin_top (24);
        set_margin_bottom (24);
        set_margin_start (24);
        set_margin_end (24);

        inject_segment_css ();

        build_mode_selector ();
        build_player_section ();
        build_crop_controls ();
        build_mark_controls ();
        build_segment_list ();
        build_output_settings ();

        // Apply initial mode visibility
        apply_mode (Mode.TRIM_ONLY);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ICodecTab INTERFACE
    // ═════════════════════════════════════════════════════════════════════════

    public ICodecBuilder get_codec_builder () {
        if (copy_mode_switch.active) {
            return new TrimBuilder ();
        }
        int sel = (int) codec_choice.get_selected ();
        if (sel == 0 && svt_tab != null)  return svt_tab.get_codec_builder ();
        if (sel == 1 && x265_tab != null) return x265_tab.get_codec_builder ();
        if (sel == 2 && x264_tab != null) return x264_tab.get_codec_builder ();
        if (sel == 3 && vp9_tab != null)  return vp9_tab.get_codec_builder ();
        return new TrimBuilder ();
    }

    public bool get_two_pass () { return false; }
    public string get_container () { return "mkv"; }
    public string[] resolve_keyframe_args (string input_file, GeneralTab general_tab) { return {}; }
    public string[] get_audio_args () { return { "-c:a", "copy" }; }

    public void load_video (string path) {
        if (path.length > 0) {
            // Clear any stale crop from the previous video
            player.crop_overlay.clear_crop ();
            global_crop_value = "";
            update_crop_display ("", 0, 0, 0, 0);

            // Clear any stale trim state from the previous video
            reset_trim_state ();

            player.load_file (path);
        }
    }

    /**
     * Launch the trim/crop/export pipeline.
     */
    public void start_trim_export (string input_file,
                                   string output_folder,
                                   Label status_label,
                                   ProgressBar progress_bar,
                                   ConsoleTab console_tab) {

        // For Crop Only mode, create a virtual full-video segment
        if (current_mode == Mode.CROP_ONLY) {
            if (input_file == null || input_file.strip () == "") {
                status_label.set_text ("⚠️ Please select an input file first.");
                return;
            }
            if (global_crop_value.strip () == "") {
                status_label.set_text ("⚠️ Draw a crop rectangle on the video first.");
                return;
            }
            // Create one segment spanning the whole file
            var full_seg = new TrimSegment (0, player.get_duration_seconds ());
            full_seg.crop_value = global_crop_value;

            var segs = new GenericArray<TrimSegment> ();
            segs.add (full_seg);

            launch_runner (input_file, output_folder, status_label,
                           progress_bar, console_tab, segs, true);
            return;
        }

        // Trim Only or Crop & Trim
        if (input_file == null || input_file.strip () == "") {
            status_label.set_text ("⚠️ Please select an input file first.");
            return;
        }
        if (segments.length == 0) {
            status_label.set_text ("⚠️ Add at least one segment before exporting.");
            return;
        }

        // If global crop and Crop & Trim mode, stamp global crop onto any
        // segment that doesn't already have its own
        if (current_mode == Mode.TRIM_AND_CROP && !crop_scope_switch.active
            && global_crop_value.strip ().length > 0) {
            for (int i = 0; i < segments.length; i++) {
                if (!segments[i].has_crop ()) {
                    segments[i].crop_value = global_crop_value;
                }
            }
        }

        var segs = new GenericArray<TrimSegment> ();
        for (int i = 0; i < segments.length; i++) {
            segs.add (segments[i]);
        }

        // Determine if any segment has a crop (forces re-encode)
        bool any_crop = false;
        for (int i = 0; i < segs.length; i++) {
            if (segs[i].has_crop ()) { any_crop = true; break; }
        }

        launch_runner (input_file, output_folder, status_label,
                       progress_bar, console_tab, segs, any_crop);
    }

    private void launch_runner (string input_file,
                                string output_folder,
                                Label status_label,
                                ProgressBar progress_bar,
                                ConsoleTab console_tab,
                                GenericArray<TrimSegment> segs,
                                bool force_reencode) {

        var runner = new TrimRunner ();
        runner.input_file      = input_file;
        runner.output_folder   = output_folder;
        // When exporting separate files, each segment can independently
        // decide copy vs re-encode, so don't globally force re-encode
        bool global_force = force_reencode && !export_separate_switch.active;
        runner.copy_mode       = copy_mode_switch.active && !global_force;
        runner.keyframe_cut    = keyframe_cut_switch.active;
        runner.export_separate = export_separate_switch.active;
        runner.video_width     = player.intrinsic_width;
        runner.video_height    = player.intrinsic_height;
        runner.status_label    = status_label;
        runner.progress_bar    = progress_bar;
        runner.console_tab     = console_tab;

        // Set output suffix and status label based on mode
        if (current_mode == Mode.CROP_ONLY) {
            runner.output_suffix   = "-cropped";
            runner.operation_label = "Crop";
        } else if (current_mode == Mode.TRIM_AND_CROP) {
            runner.output_suffix   = "-cropped-trimmed";
            runner.operation_label = "Crop & Trim export";
        } else {
            runner.output_suffix   = "-trimmed";
            runner.operation_label = "Trim export";
        }

        // Set up re-encode delegates when not in copy mode,
        // or when some segments need crop (which requires re-encoding)
        if (!runner.copy_mode || force_reencode) {
            runner.general_tab = general_tab;
            int sel = (int) codec_choice.get_selected ();
            if (sel == 0 && svt_tab != null) {
                runner.reencode_builder   = new SvtAv1Builder ();
                runner.reencode_codec_tab = svt_tab;
            } else if (sel == 1 && x265_tab != null) {
                runner.reencode_builder   = new X265Builder ();
                runner.reencode_codec_tab = x265_tab;
            } else if (sel == 2 && x264_tab != null) {
                runner.reencode_builder   = new X264Builder ();
                runner.reencode_codec_tab = x264_tab;
            } else if (sel == 3 && vp9_tab != null) {
                runner.reencode_builder   = new Vp9Builder ();
                runner.reencode_codec_tab = vp9_tab;
            }
        }

        runner.set_segments (segs);

        runner.export_done.connect ((path) => {
            active_runner = null;
            trim_done (path);
        });
        runner.export_failed.connect ((msg) => {
            active_runner = null;
        });

        active_runner = runner;
        runner.run ();
    }

    public void cancel_trim () {
        if (active_runner != null) {
            active_runner.cancel ();
            active_runner = null;
        }
    }

    public bool is_exporting () {
        return active_runner != null;
    }

    /**
     * Compute the expected output path(s) for the overwrite check.
     * Returns the first path that already exists on disk, or "" if none exist.
     * Handles both combined output and export-separate modes.
     */
    public string get_expected_output_path (string input_file, string output_folder) {
        string basename = Path.get_basename (input_file);
        int dot = basename.last_index_of_char ('.');
        string name_no_ext = (dot > 0) ? basename.substring (0, dot) : basename;
        string input_ext = (dot > 0) ? basename.substring (dot) : ".mkv";

        // Determine extension
        string out_ext;
        if (copy_mode_switch.active) {
            out_ext = input_ext;
        } else {
            int sel = (int) codec_choice.get_selected ();
            ICodecTab? tab = null;
            if (sel == 0) tab = svt_tab;
            else if (sel == 1) tab = x265_tab;
            else if (sel == 2) tab = x264_tab;
            else if (sel == 3) tab = vp9_tab;

            if (tab != null) {
                string container = tab.get_container ();
                out_ext = (container.length > 0) ? "." + container : ".mkv";
            } else {
                out_ext = ".mkv";
            }
        }

        string out_dir = (output_folder != null && output_folder != "")
            ? output_folder
            : Path.get_dirname (input_file);

        if (export_separate_switch.active) {
            // Check each expected segment file
            int count = (current_mode == Mode.CROP_ONLY) ? 1 : segments.length;
            for (int i = 0; i < count; i++) {
                string num = pad_segment_number (i + 1);
                string seg_path = Path.build_filename (
                    out_dir, @"$name_no_ext-segment-$num$out_ext"
                );
                if (FileUtils.test (seg_path, FileTest.EXISTS)) {
                    return seg_path;
                }
            }
            return "";
        }

        // Combined output
        string suffix;
        if (current_mode == Mode.CROP_ONLY) suffix = "-cropped";
        else if (current_mode == Mode.TRIM_AND_CROP) suffix = "-cropped-trimmed";
        else suffix = "-trimmed";

        return Path.build_filename (out_dir, @"$name_no_ext$suffix$out_ext");
    }

    private static string pad_segment_number (int n) {
        if (n < 10) return "00" + n.to_string ();
        if (n < 100) return "0" + n.to_string ();
        return n.to_string ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CSS — Segment time entry validation styles
    //
    //  Injected once for the entire app. Uses translucent borders that work
    //  well with both light and dark Adwaita themes.
    // ═════════════════════════════════════════════════════════════════════════

    private static bool segment_css_injected = false;

    private static void inject_segment_css () {
        if (segment_css_injected) return;
        segment_css_injected = true;

        var css = new CssProvider ();
        css.load_from_string (
            "entry.segment-valid {\n" +
            "    border-color: @success_color;\n" +
            "    box-shadow: 0 0 0 1px alpha(@success_color, 0.35);\n" +
            "    transition: border-color 150ms ease, box-shadow 150ms ease;\n" +
            "}\n" +
            "entry.segment-error {\n" +
            "    border-color: @error_color;\n" +
            "    box-shadow: 0 0 0 1px alpha(@error_color, 0.35);\n" +
            "    transition: border-color 150ms ease, box-shadow 150ms ease;\n" +
            "}\n"
        );
        StyleContext.add_provider_for_display (
            Gdk.Display.get_default (),
            css,
            STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SEGMENT TIME VALIDATION
    //
    //  Fix #6: Validate start/end time entries and show red/green borders.
    //
    //  Checks:
    //   • Value is non-negative
    //   • Start time < end time for the same segment
    //   • Value does not exceed video duration (when known)
    //
    //  Called on every keystroke (changed signal) for live feedback,
    //  and on Enter (activate signal) to gate whether the edit is committed.
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Validate a time entry and apply the appropriate CSS class.
     *
     * @param entry          The Entry widget to style
     * @param parsed_value   The parsed time in seconds
     * @param other_value    The other boundary of the segment (end if this is start, vice versa)
     * @param is_start       true if this entry is the start time, false for end time
     * @return               true if the value is valid
     */
    private bool validate_segment_time (Entry entry, double parsed_value,
                                        double other_value, bool is_start) {
        string? error_reason = null;

        // 1. Non-negative
        if (parsed_value < 0.0) {
            error_reason = "Time cannot be negative";
        }

        // 2. Start must be before end
        if (error_reason == null) {
            if (is_start && parsed_value >= other_value) {
                error_reason = "Start must be before end";
            } else if (!is_start && parsed_value <= other_value) {
                error_reason = "End must be after start";
            }
        }

        // 3. Within video duration (when known)
        if (error_reason == null) {
            double duration = player.get_duration_seconds ();
            if (duration > 0.0 && parsed_value > duration) {
                error_reason = "Exceeds video duration";
            }
        }

        // Apply visual feedback
        entry.remove_css_class ("segment-valid");
        entry.remove_css_class ("segment-error");

        if (error_reason != null) {
            entry.add_css_class ("segment-error");
            entry.set_tooltip_text (error_reason);
            return false;
        } else {
            entry.add_css_class ("segment-valid");
            entry.set_tooltip_text ("Valid");
            return true;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI — Mode Selector
    // ═════════════════════════════════════════════════════════════════════════

    private void build_mode_selector () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Mode");
        group.set_description ("Choose what you would like to do");

        var mode_row = new Adw.ActionRow ();
        mode_row.set_title ("Operation");
        mode_row.set_subtitle ("Select between trimming, cropping, or both");
        mode_row.set_icon_name ("applications-multimedia-symbolic");

        mode_dropdown = new DropDown (new StringList (
            { "✂️  Trim Only", "🔲  Crop Only", "🔲✂️  Crop & Trim" }
        ), null);
        mode_dropdown.set_valign (Align.CENTER);
        mode_dropdown.set_selected (0);
        mode_dropdown.notify["selected"].connect (() => {
            int sel = (int) mode_dropdown.get_selected ();
            Mode m = (sel == 0) ? Mode.TRIM_ONLY :
                     (sel == 1) ? Mode.CROP_ONLY : Mode.TRIM_AND_CROP;
            apply_mode (m);
        });
        mode_row.add_suffix (mode_dropdown);
        group.add (mode_row);

        append (group);
    }

    private void apply_mode (Mode m) {
        current_mode = m;

        bool show_crop = (m == Mode.CROP_ONLY || m == Mode.TRIM_AND_CROP);
        bool show_trim = (m == Mode.TRIM_ONLY || m == Mode.TRIM_AND_CROP);

        // Toggle crop overlay on the video player
        player.set_crop_active (show_crop);

        // Toggle section visibility
        crop_group.set_visible (show_crop);
        mark_group.set_visible (show_trim);
        segments_group.set_visible (show_trim);

        // Crop scope row only makes sense in Crop & Trim mode
        crop_scope_row.set_visible (m == Mode.TRIM_AND_CROP);
        crop_apply_all_btn.set_visible (m == Mode.TRIM_AND_CROP);

        // In Crop Only mode, disable export-separate (doesn't apply)
        if (m == Mode.CROP_ONLY) {
            export_separate_switch.set_active (false);
        }
        export_separate_switch.set_sensitive (show_trim);

        // Crop always requires re-encode (both Crop Only and Crop & Trim)
        if (m == Mode.CROP_ONLY || m == Mode.TRIM_AND_CROP) {
            copy_mode_switch.set_active (false);
            copy_mode_switch.set_sensitive (false);
        } else if (speed_locked) {
            // Speed filters are active — keep re-encode forced
            copy_mode_switch.set_active (false);
            copy_mode_switch.set_sensitive (false);
        } else {
            copy_mode_switch.set_sensitive (true);
        }

        update_codec_row_visibility ();
        mode_changed ((int) m);
    }

    /**
     * Show the re-encode codec row whenever re-encoding will be needed:
     *  - Copy mode is OFF (user chose re-encode)
     *  - Crop Only mode (always re-encodes)
     *  - Crop & Trim mode (crop segments will need re-encoding regardless of copy setting)
     */
    private void update_codec_row_visibility () {
        bool show = !copy_mode_switch.active
                    || current_mode == Mode.CROP_ONLY
                    || current_mode == Mode.TRIM_AND_CROP;
        reencode_codec_row.set_visible (show);

        // Adjust subtitle to clarify when copy is ON but crop forces re-encode
        if (copy_mode_switch.active && current_mode == Mode.TRIM_AND_CROP) {
            reencode_codec_row.set_subtitle ("Segments with crop will be re-encoded using this codec");
        } else {
            reencode_codec_row.set_subtitle ("Uses the settings from the selected codec tab + all General tab options");
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI — Video Player
    // ═════════════════════════════════════════════════════════════════════════

    private void build_player_section () {
        player = new VideoPlayer ();
        append (player);

        // Wire crop overlay changes to our display
        player.crop_overlay.crop_changed.connect (on_crop_overlay_changed);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI — Crop Controls
    // ═════════════════════════════════════════════════════════════════════════

    private void build_crop_controls () {
        crop_group = new Adw.PreferencesGroup ();
        crop_group.set_title ("Crop");
        crop_group.set_description ("Draw a rectangle on the video to define the crop area, or type values manually. Hold Shift while dragging to lock aspect ratio");
        crop_group.set_visible (false);

        // ── Crop value display ───────────────────────────────────────────────
        var value_row = new Adw.ActionRow ();
        value_row.set_title ("Crop Value");
        value_row.set_subtitle ("W:H:X:Y — all values snapped to even numbers");
        value_row.set_icon_name ("image-crop-symbolic");

        crop_value_label = new Label ("No crop defined");
        crop_value_label.add_css_class ("dim-label");
        crop_value_label.set_valign (Align.CENTER);
        value_row.add_suffix (crop_value_label);

        crop_group.add (value_row);

        // ── Manual entry ─────────────────────────────────────────────────────
        var entry_row = new Adw.ActionRow ();
        entry_row.set_title ("Manual Entry");
        entry_row.set_subtitle ("Type W:H:X:Y and press Enter to apply");

        crop_entry = new Entry ();
        crop_entry.set_placeholder_text ("w:h:x:y");
        crop_entry.set_width_chars (20);
        crop_entry.set_valign (Align.CENTER);
        crop_entry.add_css_class ("monospace");
        crop_entry.activate.connect (() => {
            string val = crop_entry.get_text ().strip ();
            player.crop_overlay.set_crop_string (val);
        });
        entry_row.add_suffix (crop_entry);
        crop_group.add (entry_row);

        // ── Crop scope (global vs per-segment) ──────────────────────────────
        crop_scope_row = new Adw.ActionRow ();
        crop_scope_row.set_title ("Per-Segment Crop");
        crop_scope_row.set_subtitle ("When enabled, each segment stores its own crop. When off, one crop applies to all.");
        crop_scope_row.set_icon_name ("view-list-symbolic");

        crop_scope_switch = new Switch ();
        crop_scope_switch.set_valign (Align.CENTER);
        crop_scope_switch.set_active (false);
        crop_scope_switch.notify["active"].connect (() => {
            rebuild_segment_rows ();
        });
        crop_scope_row.add_suffix (crop_scope_switch);
        crop_scope_row.set_activatable_widget (crop_scope_switch);
        crop_scope_row.set_visible (false);
        crop_group.add (crop_scope_row);

        // ── Action buttons ───────────────────────────────────────────────────
        var actions_row = new Adw.ActionRow ();
        actions_row.set_title ("Actions");

        crop_reset_btn = new Button.with_label ("Reset");
        crop_reset_btn.add_css_class ("destructive-action");
        crop_reset_btn.set_valign (Align.CENTER);
        crop_reset_btn.set_tooltip_text ("Clear the crop rectangle");
        crop_reset_btn.clicked.connect (() => {
            player.crop_overlay.clear_crop ();
            global_crop_value = "";
            update_crop_display ("", 0, 0, 0, 0);
        });
        actions_row.add_suffix (crop_reset_btn);

        crop_apply_all_btn = new Button.with_label ("Apply to All Segments");
        crop_apply_all_btn.add_css_class ("suggested-action");
        crop_apply_all_btn.set_valign (Align.CENTER);
        crop_apply_all_btn.set_tooltip_text ("Copy the current crop to every segment");
        crop_apply_all_btn.set_visible (false);
        crop_apply_all_btn.clicked.connect (() => {
            string cv = player.crop_overlay.get_crop_string ();
            if (cv == "") return;
            for (int i = 0; i < segments.length; i++) {
                segments[i].crop_value = cv;
            }
            rebuild_segment_rows ();
        });
        actions_row.add_suffix (crop_apply_all_btn);

        crop_group.add (actions_row);

        append (crop_group);
    }

    private void on_crop_overlay_changed (int w, int h, int x, int y) {
        string val = (w > 0 && h > 0)
            ? "%d:%d:%d:%d".printf (w, h, x, y)
            : "";

        // Update global crop
        global_crop_value = val;

        update_crop_display (val, w, h, x, y);
    }

    private void update_crop_display (string val, int w, int h, int x, int y) {
        if (val == "") {
            crop_value_label.set_text ("No crop defined");
            crop_value_label.add_css_class ("dim-label");
            crop_entry.set_text ("");
        } else {
            crop_value_label.set_text ("%d × %d  at  (%d, %d)".printf (w, h, x, y));
            crop_value_label.remove_css_class ("dim-label");
            crop_entry.set_text (val);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI — Mark In / Mark Out / Add Segment
    // ═════════════════════════════════════════════════════════════════════════

    private void build_mark_controls () {
        mark_group = new Adw.PreferencesGroup ();
        mark_group.set_title ("Segment Controls");
        mark_group.set_description ("Mark time points and create segments from the current playback position");

        // ── Mark In ──────────────────────────────────────────────────────────
        var in_row = new Adw.ActionRow ();
        in_row.set_title ("Mark In");
        in_row.set_subtitle ("Start point for the next segment");

        mark_in_label = new Label ("00:00:00.000");
        mark_in_label.add_css_class ("monospace");
        mark_in_label.set_valign (Align.CENTER);
        in_row.add_suffix (mark_in_label);

        var mark_in_btn = new Button.with_label ("Set");
        mark_in_btn.set_valign (Align.CENTER);
        mark_in_btn.add_css_class ("suggested-action");
        mark_in_btn.set_tooltip_text ("Mark current position as segment start");
        mark_in_btn.clicked.connect (() => {
            mark_in = player.get_position_seconds ();
            mark_in_label.set_text (VideoPlayer.format_time (mark_in));
        });
        in_row.add_suffix (mark_in_btn);
        mark_group.add (in_row);

        // ── Mark Out ─────────────────────────────────────────────────────────
        var out_row = new Adw.ActionRow ();
        out_row.set_title ("Mark Out");
        out_row.set_subtitle ("End point for the next segment");

        mark_out_label = new Label ("00:00:00.000");
        mark_out_label.add_css_class ("monospace");
        mark_out_label.set_valign (Align.CENTER);
        out_row.add_suffix (mark_out_label);

        var mark_out_btn = new Button.with_label ("Set");
        mark_out_btn.set_valign (Align.CENTER);
        mark_out_btn.add_css_class ("suggested-action");
        mark_out_btn.set_tooltip_text ("Mark current position as segment end");
        mark_out_btn.clicked.connect (() => {
            mark_out = player.get_position_seconds ();
            mark_out_label.set_text (VideoPlayer.format_time (mark_out));
        });
        out_row.add_suffix (mark_out_btn);
        mark_group.add (out_row);

        // ── Add Segment button ───────────────────────────────────────────────
        var add_row = new Adw.ActionRow ();
        add_row.set_title ("Add Segment");
        add_row.set_subtitle ("Create a new segment from the current In/Out marks");

        var add_btn = new Button.with_label ("Add");
        add_btn.set_valign (Align.CENTER);
        add_btn.add_css_class ("suggested-action");
        add_btn.clicked.connect (on_add_segment);
        add_row.add_suffix (add_btn);

        var add_at_btn = new Button.with_label ("Add at Position");
        add_at_btn.set_valign (Align.CENTER);
        add_at_btn.add_css_class ("flat");
        add_at_btn.set_tooltip_text ("Add a 10-second segment starting at the current position");
        add_at_btn.clicked.connect (on_add_at_position);
        add_row.add_suffix (add_at_btn);

        var reset_segments_btn = new Button.with_label ("Reset");
        reset_segments_btn.set_valign (Align.CENTER);
        reset_segments_btn.add_css_class ("destructive-action");
        reset_segments_btn.set_tooltip_text ("Remove all segments and reset marks");
        reset_segments_btn.clicked.connect (reset_trim_state);
        add_row.add_suffix (reset_segments_btn);

        mark_group.add (add_row);
        append (mark_group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI — Segment List
    // ═════════════════════════════════════════════════════════════════════════

    private void build_segment_list () {
        segments_group = new Adw.PreferencesGroup ();
        segments_group.set_title ("Segments");

        segment_count_label = new Label ("No segments defined");
        segment_count_label.add_css_class ("dim-label");
        segments_group.set_description ("Segments will be exported in the order listed below");

        segment_listbox = new Gtk.ListBox ();
        segment_listbox.set_selection_mode (SelectionMode.NONE);
        segment_listbox.add_css_class ("boxed-list");
        segment_listbox.set_margin_top (8);
        segments_group.add (segment_listbox);
        segments_group.add (segment_count_label);

        append (segments_group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI — Output Settings
    // ═════════════════════════════════════════════════════════════════════════

    private void build_output_settings () {
        output_group = new Adw.PreferencesGroup ();
        output_group.set_title ("Output Settings");
        output_group.set_description ("Choose how segments are encoded and exported");

        // ── Copy Streams toggle ──────────────────────────────────────────────
        var copy_row = new Adw.ActionRow ();
        copy_row.set_title ("Copy Streams (Fast)");
        copy_row.set_subtitle ("No re-encoding — fast stream copy");

        copy_mode_switch = new Switch ();
        copy_mode_switch.set_valign (Align.CENTER);
        copy_mode_switch.set_active (true);
        copy_row.add_suffix (copy_mode_switch);
        copy_row.set_activatable_widget (copy_mode_switch);
        output_group.add (copy_row);

        // ── Keyframe Cut toggle (only visible when copy mode is ON) ──────────
        keyframe_cut_row = new Adw.ActionRow ();
        keyframe_cut_row.set_title ("Cut at Nearest Keyframe");
        keyframe_cut_row.set_subtitle ("Faster but may shift cut points to the nearest keyframe. Disable for precise timestamps (slower).");

        keyframe_cut_switch = new Switch ();
        keyframe_cut_switch.set_valign (Align.CENTER);
        keyframe_cut_switch.set_active (true);
        keyframe_cut_row.add_suffix (keyframe_cut_switch);
        keyframe_cut_row.set_activatable_widget (keyframe_cut_switch);
        keyframe_cut_row.set_visible (copy_mode_switch.active);
        output_group.add (keyframe_cut_row);

        // ── Re-encode Codec selector ─────────────────────────────────────────
        reencode_codec_row = new Adw.ActionRow ();
        reencode_codec_row.set_title ("Re-encode Codec");
        reencode_codec_row.set_subtitle ("Uses the settings from the selected codec tab + all General tab options");

        codec_choice = new DropDown (new StringList ({ "SVT-AV1", "x265", "x264", "VP9" }), null);
        codec_choice.set_valign (Align.CENTER);
        codec_choice.set_selected (0);
        reencode_codec_row.add_suffix (codec_choice);
        reencode_codec_row.set_visible (false);
        output_group.add (reencode_codec_row);

        copy_mode_switch.notify["active"].connect (() => {
            update_codec_row_visibility ();
            update_concat_audio_constraint ();
            keyframe_cut_row.set_visible (copy_mode_switch.active);
        });

        // ── Export as separate files ─────────────────────────────────────────
        var separate_row = new Adw.ActionRow ();
        separate_row.set_title ("Export as Separate Files");
        separate_row.set_subtitle ("Each segment becomes its own numbered file instead of concatenating");

        export_separate_switch = new Switch ();
        export_separate_switch.set_valign (Align.CENTER);
        export_separate_switch.set_active (false);
        export_separate_switch.notify["active"].connect (() => {
            update_concat_audio_constraint ();
        });
        separate_row.add_suffix (export_separate_switch);
        separate_row.set_activatable_widget (export_separate_switch);
        output_group.add (separate_row);

        append (output_group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SPEED CONSTRAINT — force re-encode when speed filters are active
    // ═════════════════════════════════════════════════════════════════════════

    public void update_for_speed (bool video_speed_on, bool audio_speed_on) {
        speed_locked = video_speed_on || audio_speed_on;
        if (speed_locked) {
            copy_mode_switch.set_active (false);
            copy_mode_switch.set_sensitive (false);
        } else {
            // Restore sensitivity unless crop-only mode overrides
            if (current_mode != Mode.CROP_ONLY && current_mode != Mode.TRIM_AND_CROP) {
                copy_mode_switch.set_sensitive (true);
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CONCAT FILTER AUDIO CONSTRAINT
    //
    //  PATH A (concat filter) routes audio through -filter_complex, which
    //  decodes it — making -c:a copy impossible.  When PATH A will be used,
    //  disable "Copy" in all codec tabs' audio dropdowns so the user picks
    //  a real codec.  When the conditions change, re-enable it.
    //
    //  PATH A conditions: re-encode + multi-segment + combined output
    //   → !copy_mode && !export_separate && segments.length > 1
    // ═════════════════════════════════════════════════════════════════════════

    private void update_concat_audio_constraint () {
        bool would_use_concat_filter = !copy_mode_switch.active
                                       && !export_separate_switch.active
                                       && segments.length > 1;

        if (svt_tab != null)  svt_tab.audio_settings.update_for_concat_filter (would_use_concat_filter);
        if (x265_tab != null) x265_tab.audio_settings.update_for_concat_filter (would_use_concat_filter);
        if (x264_tab != null) x264_tab.audio_settings.update_for_concat_filter (would_use_concat_filter);
        if (vp9_tab != null)  vp9_tab.audio_settings.update_for_concat_filter (would_use_concat_filter);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SEGMENT MANAGEMENT — Reset
    // ═════════════════════════════════════════════════════════════════════════

    private void reset_trim_state () {
        // Clear all segments
        segments = new GenericArray<TrimSegment> ();
        rebuild_segment_rows ();

        // Reset mark in/out
        mark_in = 0.0;
        mark_out = 0.0;
        mark_in_label.set_text ("00:00:00.000");
        mark_out_label.set_text ("00:00:00.000");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SEGMENT MANAGEMENT — Add
    // ═════════════════════════════════════════════════════════════════════════

    private void on_add_segment () {
        double start = mark_in;
        double end   = mark_out;

        if (start > end) {
            double tmp = start;
            start = end;
            end = tmp;
        }

        if (end - start < 0.001) {
            mark_out_label.set_text ("⚠️ Set a different Out point");
            return;
        }

        var seg = new TrimSegment (start, end);

        // In Crop & Trim mode, stamp the current crop onto the segment
        if (current_mode == Mode.TRIM_AND_CROP) {
            if (crop_scope_switch.active) {
                // Per-segment: use the live overlay crop
                string cv = player.crop_overlay.get_crop_string ();
                if (cv != "") seg.crop_value = cv;
            } else {
                // Global: stamp the global crop value
                if (global_crop_value.strip ().length > 0)
                    seg.crop_value = global_crop_value;
            }
        }

        add_segment_to_list (seg);
    }

    private void on_add_at_position () {
        double pos = player.get_position_seconds ();
        double dur = player.get_duration_seconds ();
        double end = (pos + 10.0).clamp (0.0, dur);
        if (end <= pos) end = dur;

        var seg = new TrimSegment (pos, end);

        // In Crop & Trim mode, stamp the current crop
        if (current_mode == Mode.TRIM_AND_CROP) {
            if (crop_scope_switch.active) {
                string cv = player.crop_overlay.get_crop_string ();
                if (cv != "") seg.crop_value = cv;
            } else {
                if (global_crop_value.strip ().length > 0)
                    seg.crop_value = global_crop_value;
            }
        }

        add_segment_to_list (seg);

        mark_in = pos;
        mark_out = end;
        mark_in_label.set_text (VideoPlayer.format_time (pos));
        mark_out_label.set_text (VideoPlayer.format_time (end));
    }

    private void add_segment_to_list (TrimSegment seg) {
        segments.add (seg);
        rebuild_segment_rows ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SEGMENT MANAGEMENT — Rebuild ListBox rows
    // ═════════════════════════════════════════════════════════════════════════

    private void rebuild_segment_rows () {
        Gtk.Widget? child = segment_listbox.get_first_child ();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling ();
            segment_listbox.remove (child);
            child = next;
        }

        for (int i = 0; i < segments.length; i++) {
            var row = build_segment_row (i);
            segment_listbox.append (row);
        }

        if (segments.length == 0) {
            segment_count_label.set_text ("No segments defined");
        } else {
            double total = 0.0;
            for (int i = 0; i < segments.length; i++) {
                total += segments[i].get_duration ();
            }
            segment_count_label.set_text (
                "%d segment%s — total duration %s".printf (
                    segments.length,
                    segments.length == 1 ? "" : "s",
                    VideoPlayer.format_time (total)
                )
            );
        }

        // Update audio copy constraint — PATH A (concat filter) can't do
        // audio copy, so disable it when that path would be active
        update_concat_audio_constraint ();
    }

    private Gtk.Widget build_segment_row (int index) {
        var seg = segments[index];

        // ── Closure safety ───────────────────────────────────────────────────
        // Vala closures capture variables by reference.  Although `index` is a
        // method parameter (not a loop variable), we capture it into a single
        // local so that every lambda below closes over the same per-row value.
        // Do NOT remove this — without it, future refactors that inline this
        // method into a loop would silently break.
        int idx = index;

        var row = new Adw.ActionRow ();
        row.set_title ("#%d".printf (idx + 1));

        // Build subtitle with optional crop indicator
        string time_str = "%s → %s  (%s)".printf (
            VideoPlayer.format_time (seg.start_time),
            VideoPlayer.format_time (seg.end_time),
            format_duration (seg.get_duration ())
        );
        if (seg.has_crop ()) {
            time_str += "  🔲 " + seg.crop_value;
        }
        row.set_subtitle (time_str);

        // ── Start time editor ────────────────────────────────────────────────
        var start_entry = new Entry ();
        start_entry.set_text (VideoPlayer.format_time (seg.start_time));
        start_entry.set_width_chars (13);
        start_entry.set_max_width_chars (13);
        start_entry.set_valign (Align.CENTER);
        start_entry.add_css_class ("monospace");
        start_entry.set_tooltip_text ("Start time (editable)");

        // Fix #6: Live validation on every keystroke
        start_entry.changed.connect (() => {
            double parsed = VideoPlayer.parse_time (start_entry.get_text ());
            validate_segment_time (start_entry, parsed, segments[idx].end_time, true);
        });

        // Fix #6: Only commit the value if validation passes
        start_entry.activate.connect (() => {
            double new_val = VideoPlayer.parse_time (start_entry.get_text ());
            bool valid = validate_segment_time (start_entry, new_val, segments[idx].end_time, true);
            if (valid) {
                segments[idx].start_time = new_val;
                rebuild_segment_rows ();
            }
        });
        row.add_suffix (start_entry);

        var arrow = new Label ("→");
        arrow.set_valign (Align.CENTER);
        arrow.add_css_class ("dim-label");
        arrow.set_margin_start (4);
        arrow.set_margin_end (4);
        row.add_suffix (arrow);

        // ── End time editor ──────────────────────────────────────────────────
        var end_entry = new Entry ();
        end_entry.set_text (VideoPlayer.format_time (seg.end_time));
        end_entry.set_width_chars (13);
        end_entry.set_max_width_chars (13);
        end_entry.set_valign (Align.CENTER);
        end_entry.add_css_class ("monospace");
        end_entry.set_tooltip_text ("End time (editable)");

        // Fix #6: Live validation on every keystroke
        end_entry.changed.connect (() => {
            double parsed = VideoPlayer.parse_time (end_entry.get_text ());
            validate_segment_time (end_entry, parsed, segments[idx].start_time, false);
        });

        // Fix #6: Only commit the value if validation passes
        end_entry.activate.connect (() => {
            double new_val = VideoPlayer.parse_time (end_entry.get_text ());
            bool valid = validate_segment_time (end_entry, new_val, segments[idx].start_time, false);
            if (valid) {
                segments[idx].end_time = new_val;
                rebuild_segment_rows ();
            }
        });
        row.add_suffix (end_entry);

        // ── Crop button (Crop & Trim per-segment mode) ──────────────────────
        if (current_mode == Mode.TRIM_AND_CROP && crop_scope_switch.active) {
            var crop_btn = new Button.from_icon_name (
                seg.has_crop () ? "image-crop-symbolic" : "list-add-symbolic"
            );
            crop_btn.set_tooltip_text (
                seg.has_crop () ? "Update crop from current overlay" : "Set crop from current overlay"
            );
            crop_btn.set_valign (Align.CENTER);
            crop_btn.add_css_class ("flat");
            if (seg.has_crop ()) crop_btn.add_css_class ("accent");
            crop_btn.clicked.connect (() => {
                string cv = player.crop_overlay.get_crop_string ();
                segments[idx].crop_value = cv;
                rebuild_segment_rows ();
            });
            row.add_suffix (crop_btn);
        }

        // ── Seek button ──────────────────────────────────────────────────────
        var seek_btn = new Button.from_icon_name ("find-location-symbolic");
        seek_btn.set_tooltip_text ("Seek player to segment start");
        seek_btn.set_valign (Align.CENTER);
        seek_btn.add_css_class ("flat");
        seek_btn.clicked.connect (() => {
            player.seek_to (segments[idx].start_time);
        });
        row.add_suffix (seek_btn);

        // ── Move Up ──────────────────────────────────────────────────────────
        var up_btn = new Button.from_icon_name ("go-up-symbolic");
        up_btn.set_tooltip_text ("Move segment up");
        up_btn.set_valign (Align.CENTER);
        up_btn.add_css_class ("flat");
        up_btn.set_sensitive (index > 0);
        up_btn.clicked.connect (() => {
            if (idx > 0) swap_segments (idx, idx - 1);
        });
        row.add_suffix (up_btn);

        // ── Move Down ────────────────────────────────────────────────────────
        var down_btn = new Button.from_icon_name ("go-down-symbolic");
        down_btn.set_tooltip_text ("Move segment down");
        down_btn.set_valign (Align.CENTER);
        down_btn.add_css_class ("flat");
        down_btn.set_sensitive (index < segments.length - 1);
        down_btn.clicked.connect (() => {
            if (idx < segments.length - 1) swap_segments (idx, idx + 1);
        });
        row.add_suffix (down_btn);

        // ── Delete ───────────────────────────────────────────────────────────
        var delete_btn = new Button.from_icon_name ("user-trash-symbolic");
        delete_btn.set_tooltip_text ("Remove this segment");
        delete_btn.set_valign (Align.CENTER);
        delete_btn.add_css_class ("flat");
        delete_btn.add_css_class ("error");
        delete_btn.clicked.connect (() => {
            remove_segment (idx);
        });
        row.add_suffix (delete_btn);

        return row;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SEGMENT MANAGEMENT — Reorder & Delete
    // ═════════════════════════════════════════════════════════════════════════

    private void swap_segments (int a, int b) {
        if (a < 0 || b < 0 || a >= segments.length || b >= segments.length) return;
        var tmp = segments[a];
        segments[a] = segments[b];
        segments[b] = tmp;
        rebuild_segment_rows ();
    }

    private void remove_segment (int index) {
        if (index < 0 || index >= segments.length) return;
        segments.remove_index (index);
        rebuild_segment_rows ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    private static string format_duration (double secs) {
        if (secs < 0) secs = 0;

        if (secs < 60.0) {
            return "%.1fs".printf (secs);
        }

        int total = (int) secs;
        int h = total / 3600;
        int m = (total % 3600) / 60;
        int s = total % 60;

        if (h > 0)
            return "%dh %dm %ds".printf (h, m, s);
        return "%dm %ds".printf (m, s);
    }
}
