using Gtk;
using Adw;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  TrimSegment — Simple data object for a start/end time range
// ═══════════════════════════════════════════════════════════════════════════════

public class TrimSegment : Object {
    public double start_time { get; set; }
    public double end_time   { get; set; }

    public TrimSegment (double start, double end) {
        this.start_time = start;
        this.end_time   = end;
    }

    public double get_duration () {
        return (end_time - start_time).clamp (0.0, double.MAX);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  TrimTab — Video trimming and segment management tab
//
//  Implements ICodecTab so it participates in the notebook-based conversion
//  flow.  When the user clicks Convert with this tab active, MainWindow
//  delegates to start_trim_export() instead of the normal converter path.
//
//  Layout:
//    • VideoPlayer — embedded preview with scrubber and transport
//    • Mark In / Mark Out / Add Segment controls
//    • Dynamic segment list with editable times, reorder, and delete
//    • Output mode: Copy Streams (fast) or Re-encode (uses codec tab)
//    • Export option: single concatenated file or separate numbered files
// ═══════════════════════════════════════════════════════════════════════════════

public class TrimTab : Box, ICodecTab {

    // ── Video Player ────────────────────────────────────────────────────────
    private VideoPlayer player;

    // ── Mark In / Out state ─────────────────────────────────────────────────
    private double mark_in  = 0.0;
    private double mark_out = 0.0;
    private Label mark_in_label;
    private Label mark_out_label;

    // ── Segment list ────────────────────────────────────────────────────────
    private GenericArray<TrimSegment> segments = new GenericArray<TrimSegment> ();
    private Adw.PreferencesGroup segments_group;
    private Gtk.ListBox segment_listbox;
    private Label segment_count_label;

    // ── Output mode ─────────────────────────────────────────────────────────
    private Switch copy_mode_switch;
    private Adw.ActionRow reencode_codec_row;
    private DropDown codec_choice;
    private Switch export_separate_switch;

    // ── External references (set by MainWindow) ─────────────────────────────
    public GeneralTab? general_tab  { get; set; default = null; }
    public SvtAv1Tab?  svt_tab      { get; set; default = null; }
    public X265Tab?    x265_tab     { get; set; default = null; }
    public X264Tab?    x264_tab     { get; set; default = null; }

    // ── Trim runner ─────────────────────────────────────────────────────────
    private TrimRunner? active_runner = null;

    // ── Signals ─────────────────────────────────────────────────────────────
    public signal void trim_done (string output_path);

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public TrimTab () {
        Object (orientation: Orientation.VERTICAL, spacing: 24);
        set_margin_top (24);
        set_margin_bottom (24);
        set_margin_start (24);
        set_margin_end (24);

        build_player_section ();
        build_mark_controls ();
        build_segment_list ();
        build_output_settings ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ICodecTab INTERFACE
    // ═════════════════════════════════════════════════════════════════════════

    public ICodecBuilder get_codec_builder () {
        // In copy mode, return the simple copy builder.
        // In re-encode mode, delegate to the chosen codec tab.
        if (copy_mode_switch.active) {
            return new TrimBuilder ();
        }

        int sel = (int) codec_choice.get_selected ();
        if (sel == 0 && svt_tab != null) {
            return svt_tab.get_codec_builder ();
        } else if (sel == 1 && x265_tab != null) {
            return x265_tab.get_codec_builder ();
        } else if (sel == 2 && x264_tab != null) {
            return x264_tab.get_codec_builder ();
        }

        return new TrimBuilder ();
    }

    // (#6) ICodecTab stubs — TrimTab uses its own conversion path,
    //       so these are only here to satisfy the interface contract.
    public bool get_two_pass () { return false; }
    public string get_container () { return "mkv"; }
    public string[] resolve_keyframe_args (string input_file, GeneralTab general_tab) { return {}; }
    public string[] get_audio_args () { return { "-c:a", "copy" }; }

    // ═════════════════════════════════════════════════════════════════════════
    //  PUBLIC API
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Load a video into the player.  Called from MainWindow when the
     * input file changes.
     */
    public void load_video (string path) {
        if (path.length > 0) {
            player.load_file (path);
        }
    }

    /**
     * Launch the trim/export pipeline.  Called from MainWindow
     * when Convert is clicked while this tab is active.
     */
    public void start_trim_export (string input_file,
                                   string output_folder,
                                   Label status_label,
                                   ProgressBar progress_bar,
                                   ConsoleTab console_tab) {

        if (segments.length == 0) {
            status_label.set_text ("⚠️ Add at least one segment before exporting.");
            return;
        }

        var runner = new TrimRunner ();
        runner.input_file      = input_file;
        runner.output_folder   = output_folder;
        runner.copy_mode       = copy_mode_switch.active;
        runner.export_separate = export_separate_switch.active;
        runner.status_label    = status_label;
        runner.progress_bar    = progress_bar;
        runner.console_tab     = console_tab;

        // Set up re-encode delegates when not in copy mode
        if (!copy_mode_switch.active) {
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
            }
        }

        // Copy segments to the runner
        var segs = new GenericArray<TrimSegment> ();
        for (int i = 0; i < segments.length; i++) {
            segs.add (segments[i]);
        }
        runner.set_segments (segs);

        // Wire up completion
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

    /**
     * Cancel a running export.
     */
    public void cancel_trim () {
        if (active_runner != null) {
            active_runner.cancel ();
            active_runner = null;
        }
    }

    /**
     * Returns true if an export is in progress.
     */
    public bool is_exporting () {
        return active_runner != null;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI — Video Player
    // ═════════════════════════════════════════════════════════════════════════

    private void build_player_section () {
        player = new VideoPlayer ();
        append (player);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI — Mark In / Mark Out / Add Segment
    // ═════════════════════════════════════════════════════════════════════════

    private void build_mark_controls () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Segment Controls");
        group.set_description ("Mark time points and create segments from the current playback position");

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
        group.add (in_row);

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
        group.add (out_row);

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

        group.add (add_row);
        append (group);
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

        // ListBox for dynamic segment rows
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
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Output Settings");
        group.set_description ("Choose how segments are encoded and exported");

        // ── Copy Streams toggle ──────────────────────────────────────────────
        var copy_row = new Adw.ActionRow ();
        copy_row.set_title ("Copy Streams (Fast)");
        copy_row.set_subtitle ("No re-encoding — cuts at nearest keyframes, supports out-of-order segments");

        copy_mode_switch = new Switch ();
        copy_mode_switch.set_valign (Align.CENTER);
        copy_mode_switch.set_active (true);
        copy_row.add_suffix (copy_mode_switch);
        copy_row.set_activatable_widget (copy_mode_switch);
        group.add (copy_row);

        // ── Re-encode Codec selector ─────────────────────────────────────────
        reencode_codec_row = new Adw.ActionRow ();
        reencode_codec_row.set_title ("Re-encode Codec");
        reencode_codec_row.set_subtitle ("Uses the settings from the selected codec tab + all General tab options");

        codec_choice = new DropDown (new StringList ({ "SVT-AV1", "x265", "x264" }), null);
        codec_choice.set_valign (Align.CENTER);
        codec_choice.set_selected (0);
        reencode_codec_row.add_suffix (codec_choice);
        reencode_codec_row.set_visible (false);
        group.add (reencode_codec_row);

        // Toggle visibility based on copy mode
        copy_mode_switch.notify["active"].connect (() => {
            reencode_codec_row.set_visible (!copy_mode_switch.active);
        });

        // ── Export as separate files ─────────────────────────────────────────
        var separate_row = new Adw.ActionRow ();
        separate_row.set_title ("Export as Separate Files");
        separate_row.set_subtitle ("Each segment becomes its own numbered file instead of concatenating");

        export_separate_switch = new Switch ();
        export_separate_switch.set_valign (Align.CENTER);
        export_separate_switch.set_active (false);
        separate_row.add_suffix (export_separate_switch);
        separate_row.set_activatable_widget (export_separate_switch);
        group.add (separate_row);

        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SPEED CONSTRAINT — force re-encode when speed filters are active
    // ═════════════════════════════════════════════════════════════════════════

    // Call this when the general tab's video/audio speed toggles change.
    public void update_for_speed (bool video_speed_on, bool audio_speed_on) {
        bool needs_reencode = video_speed_on || audio_speed_on;
        if (needs_reencode) {
            copy_mode_switch.set_active (false);
            copy_mode_switch.set_sensitive (false);
        } else {
            copy_mode_switch.set_sensitive (true);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SEGMENT MANAGEMENT — Add
    // ═════════════════════════════════════════════════════════════════════════

    private void on_add_segment () {
        double start = mark_in;
        double end   = mark_out;

        // Auto-swap if the user marked them in reverse order
        if (start > end) {
            double tmp = start;
            start = end;
            end = tmp;
        }

        if (end - start < 0.001) {
            // In/Out are the same — give a sensible hint
            mark_out_label.set_text ("⚠️ Set a different Out point");
            return;
        }

        add_segment_to_list (new TrimSegment (start, end));
    }

    private void on_add_at_position () {
        double pos = player.get_position_seconds ();
        double dur = player.get_duration_seconds ();
        double end = (pos + 10.0).clamp (0.0, dur);
        if (end <= pos) end = dur;

        add_segment_to_list (new TrimSegment (pos, end));

        // Also update Mark In/Out for convenience
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
        // Remove all existing rows
        Gtk.Widget? child = segment_listbox.get_first_child ();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling ();
            segment_listbox.remove (child);
            child = next;
        }

        // Rebuild from the segments array
        for (int i = 0; i < segments.length; i++) {
            var row = build_segment_row (i);
            segment_listbox.append (row);
        }

        // Update count label
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
    }

    private Gtk.Widget build_segment_row (int index) {
        var seg = segments[index];

        var row = new Adw.ActionRow ();
        row.set_title ("#%d".printf (index + 1));
        row.set_subtitle ("%s → %s  (%s)".printf (
            VideoPlayer.format_time (seg.start_time),
            VideoPlayer.format_time (seg.end_time),
            format_duration (seg.get_duration ())
        ));

        // ── Start time editor ────────────────────────────────────────────────
        var start_entry = new Entry ();
        start_entry.set_text (VideoPlayer.format_time (seg.start_time));
        start_entry.set_width_chars (13);
        start_entry.set_max_width_chars (13);
        start_entry.set_valign (Align.CENTER);
        start_entry.add_css_class ("monospace");
        start_entry.set_tooltip_text ("Start time (editable)");

        int idx_start = index; // capture for closure
        start_entry.activate.connect (() => {
            double new_val = VideoPlayer.parse_time (start_entry.get_text ());
            segments[idx_start].start_time = new_val;
            rebuild_segment_rows ();
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

        int idx_end = index; // capture for closure
        end_entry.activate.connect (() => {
            double new_val = VideoPlayer.parse_time (end_entry.get_text ());
            segments[idx_end].end_time = new_val;
            rebuild_segment_rows ();
        });
        row.add_suffix (end_entry);

        // ── Seek button — jump player to segment start ───────────────────────
        var seek_btn = new Button.from_icon_name ("find-location-symbolic");
        seek_btn.set_tooltip_text ("Seek player to segment start");
        seek_btn.set_valign (Align.CENTER);
        seek_btn.add_css_class ("flat");
        int idx_seek = index;
        seek_btn.clicked.connect (() => {
            player.seek_to (segments[idx_seek].start_time);
        });
        row.add_suffix (seek_btn);

        // ── Move Up ──────────────────────────────────────────────────────────
        var up_btn = new Button.from_icon_name ("go-up-symbolic");
        up_btn.set_tooltip_text ("Move segment up");
        up_btn.set_valign (Align.CENTER);
        up_btn.add_css_class ("flat");
        up_btn.set_sensitive (index > 0);
        int idx_up = index;
        up_btn.clicked.connect (() => {
            if (idx_up > 0) {
                swap_segments (idx_up, idx_up - 1);
            }
        });
        row.add_suffix (up_btn);

        // ── Move Down ────────────────────────────────────────────────────────
        var down_btn = new Button.from_icon_name ("go-down-symbolic");
        down_btn.set_tooltip_text ("Move segment down");
        down_btn.set_valign (Align.CENTER);
        down_btn.add_css_class ("flat");
        down_btn.set_sensitive (index < segments.length - 1);
        int idx_down = index;
        down_btn.clicked.connect (() => {
            if (idx_down < segments.length - 1) {
                swap_segments (idx_down, idx_down + 1);
            }
        });
        row.add_suffix (down_btn);

        // ── Delete ───────────────────────────────────────────────────────────
        var delete_btn = new Button.from_icon_name ("user-trash-symbolic");
        delete_btn.set_tooltip_text ("Remove this segment");
        delete_btn.set_valign (Align.CENTER);
        delete_btn.add_css_class ("flat");
        delete_btn.add_css_class ("error");
        int idx_del = index;
        delete_btn.clicked.connect (() => {
            remove_segment (idx_del);
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

    /**
     * Format a duration in seconds to a human-friendly string like
     * "1m 23s" or "45.2s" or "1h 5m 10s".
     */
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
