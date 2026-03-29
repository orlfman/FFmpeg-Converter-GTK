using Gtk;
using Adw;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  SubtitlesTab — Manage subtitle streams in a video file
// ═══════════════════════════════════════════════════════════════════════════════

private class DetectedDefaultBinding : Object {
    public SubtitleStream stream { get; construct; }
    public Switch sw { get; construct; }

    public DetectedDefaultBinding (SubtitleStream stream, Switch sw) {
        Object (stream: stream, sw: sw);
    }
}

private class AddedDefaultBinding : Object {
    public ExternalSubtitle subtitle { get; construct; }
    public Switch sw { get; construct; }

    public AddedDefaultBinding (ExternalSubtitle subtitle, Switch sw) {
        Object (subtitle: subtitle, sw: sw);
    }
}

    private class DetectedRowBinding : Object {
        public unowned SubtitlesTab owner;
        public SubtitleStream stream;
        public Adw.ExpanderRow expander;
        public Entry lang_entry;
        public Entry title_entry;
        public Switch default_sw;
        public Switch forced_sw;
        public Button? move_up_button;
        public Button? move_down_button;
        public int drag_idx;

    public Gdk.ContentProvider? on_drag_prepare (double x, double y) {
        return owner.begin_detected_drag (drag_idx);
    }

    public void on_drag_begin (DragSource source, Gdk.Drag drag) {
        owner.set_drag_icon_for_expander (source, expander);
    }

    public bool on_drag_cancel (DragSource source, Gdk.Drag drag, Gdk.DragCancelReason reason) {
        return owner.finish_drag_cancel ();
    }

    public void on_drag_end (DragSource source, Gdk.Drag drag, bool delete_data) {
        owner.finish_drag_state ();
    }

    public bool on_drop (Value value, double x, double y) {
        return owner.complete_detected_drop (drag_idx, value);
    }

    public void on_expanded_notify () {
        stream.details_expanded = expander.get_expanded ();
    }

    public void on_enable_expansion_notify () {
        stream.marked_remove = !expander.get_enable_expansion ();
        if (stream.marked_remove) {
            stream.details_expanded = false;
        }
        owner.refresh_ui_state_from_binding ();
    }

    public void on_language_changed () {
        stream.language = lang_entry.get_text ().strip ();
    }

    public void on_title_changed () {
        stream.title = title_entry.get_text ().strip ();
    }

    public void on_default_active_notify () {
        owner.handle_detected_default_toggle (stream, default_sw);
    }

    public void on_forced_active_notify () {
        stream.is_forced = forced_sw.active;
    }

    public void on_move_up_clicked () {
        owner.move_detected_from_binding (stream, -1);
    }

    public void on_move_down_clicked () {
        owner.move_detected_from_binding (stream, 1);
    }
}

    private class AddedRowBinding : Object {
        public unowned SubtitlesTab owner;
        public ExternalSubtitle ext;
        public Adw.ExpanderRow expander;
        public Entry lang_entry;
        public Entry title_entry;
        public Switch default_sw;
        public Switch forced_sw;
        public Switch bitmap_sw;
        public Button? remove_button;
        public Button? move_up_button;
        public Button? move_down_button;
        public int index;
        public int drag_idx;

    public void on_expanded_notify () {
        ext.details_expanded = expander.get_expanded ();
    }

    public Gdk.ContentProvider? on_drag_prepare (double x, double y) {
        return owner.begin_added_drag (drag_idx);
    }

    public void on_drag_begin (DragSource source, Gdk.Drag drag) {
        owner.set_drag_icon_for_expander (source, expander);
    }

    public bool on_drag_cancel (DragSource source, Gdk.Drag drag, Gdk.DragCancelReason reason) {
        return owner.finish_drag_cancel ();
    }

    public void on_drag_end (DragSource source, Gdk.Drag drag, bool delete_data) {
        owner.finish_drag_state ();
    }

    public bool on_drop (Value value, double x, double y) {
        return owner.complete_added_drop (drag_idx, value);
    }

    public void on_remove_clicked () {
        owner.remove_added_from_binding (index);
    }

    public void on_language_changed () {
        ext.language = lang_entry.get_text ().strip ();
        expander.set_subtitle (ext.language.length > 0 ? ext.language : "no language set");
    }

    public void on_title_changed () {
        ext.title = title_entry.get_text ().strip ();
    }

    public void on_default_active_notify () {
        owner.handle_added_default_toggle (ext, default_sw);
    }

    public void on_forced_active_notify () {
        ext.is_forced = forced_sw.active;
    }

    public void on_bitmap_active_notify () {
        ext.is_bitmap = bitmap_sw.active;
    }

    public void on_move_up_clicked () {
        owner.move_added_from_binding (index, -1);
    }

    public void on_move_down_clicked () {
        owner.move_added_from_binding (index, 1);
    }
}

public class SubtitlesTab : Box {
    private const string MISSING_SUBTITLE_INPUT_WARNING =
        "Load a file with subtitle tracks or add external subtitles first!";
    private const string DEFAULT_READY_STATUS =
        "Ready. Select a file and click Convert.";

    // ── Signals ──────────────────────────────────────────────────────────────
    public signal void subtitle_done (OperationOutputResult output_result);
    public signal void subtitle_extract_requested (string input_file,
                                                   SubtitleStream stream,
                                                   string output_path);
    public signal void subtitle_extract_all_requested (string input_file,
                                                       string output_dir,
                                                       string base_name);
    public signal void subtitle_extract_succeeded (uint64 operation_id, OperationOutputResult output_result);
    public signal void subtitle_extract_failed (uint64 operation_id);
    public signal void subtitle_extract_cancelled (uint64 operation_id);
    public signal void subtitle_apply_succeeded (uint64 operation_id, OperationOutputResult output_result);
    public signal void subtitle_apply_failed (uint64 operation_id);
    public signal void subtitle_apply_cancelled (uint64 operation_id);

    // ── Runner ───────────────────────────────────────────────────────────────
    private SubtitlesRunner runner = new SubtitlesRunner ();

    // External reference — set by MainWindow after construction
    public FilePickers? file_pickers { get; set; default = null; }

    // Codec tab references for burn-in re-encode (set by MainWindow)
    public GeneralTab? general_tab { get; set; default = null; }
    public ICodecTab?  svt_tab     { get; set; default = null; }
    public ICodecTab?  x265_tab    { get; set; default = null; }
    public ICodecTab?  x264_tab    { get; set; default = null; }
    public ICodecTab?  vp9_tab     { get; set; default = null; }

    // ── State ────────────────────────────────────────────────────────────────
    private string current_input_file = "";
    private GenericArray<SubtitleStream>   detected_streams = new GenericArray<SubtitleStream> ();
    private GenericArray<ExternalSubtitle> added_subtitles  = new GenericArray<ExternalSubtitle> ();
    private bool _is_busy = false;
    private bool operation_locked = false;
    private uint64 active_extract_operation_id = 0;
    private uint64 active_apply_operation_id = 0;
    private uint64 probe_generation = 0;
    private bool _updating_defaults = false;
    private GenericArray<DetectedDefaultBinding> detected_default_bindings =
        new GenericArray<DetectedDefaultBinding> ();
    private GenericArray<AddedDefaultBinding> added_default_bindings =
        new GenericArray<AddedDefaultBinding> ();
    private GenericArray<DetectedRowBinding> detected_row_bindings =
        new GenericArray<DetectedRowBinding> ();
    private GenericArray<AddedRowBinding> added_row_bindings =
        new GenericArray<AddedRowBinding> ();

    // ── Drag-and-drop state ──────────────────────────────────────────────────
    private int _drag_from_detected = -1;
    private int _drag_from_added    = -1;
    private const string DRAG_ORIGIN_DETECTED = "detected";
    private const string DRAG_ORIGIN_ADDED    = "added";

    // ── Dynamic sections (rebuilt when data changes) ─────────────────────────
    private Box detected_section;
    private Box add_section;

    // ── Static widgets (built once, survive full lifetime) ───────────────────
    private DropDown extract_track_combo;
    private DropDown extract_format_combo;
    private Button   extract_button;
    private Button   extract_all_button;
    private DropDown mode_combo;
    private DropDown container_combo;
    private Adw.ActionRow container_compat_row;

    // ── Burn-in widgets ──────────────────────────────────────────────────────
    private Adw.PreferencesGroup burn_in_group;
    private DropDown burn_track_combo;
    private DropDown burn_codec_combo;

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public SubtitlesTab () {
        Object (orientation: Orientation.VERTICAL, spacing: 24);
        set_margin_top (32);
        set_margin_bottom (24);
        set_margin_start (24);
        set_margin_end (24);

        // 1. Detected streams (rebuilt dynamically)
        detected_section = new Box (Orientation.VERTICAL, 0);
        append (detected_section);
        rebuild_detected_group ();

        // 2. Extract (built once)
        build_extract_group ();

        // 3. Add subtitles (rebuilt dynamically)
        add_section = new Box (Orientation.VERTICAL, 0);
        append (add_section);
        rebuild_add_group ();

        // 4. Output settings (built once)
        build_output_group ();

        // 5. Burn-in config (built once, shown/hidden by mode)
        build_burn_in_group ();

        connect_signals ();
        update_ui_state ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  1. DETECTED SUBTITLE STREAMS (dynamic — rebuilt on probe/reorder)
    // ═════════════════════════════════════════════════════════════════════════

    private void rebuild_detected_group () {
        detected_default_bindings = new GenericArray<DetectedDefaultBinding> ();
        detected_row_bindings = new GenericArray<DetectedRowBinding> ();
        clear_box (detected_section);

        var group = new Adw.PreferencesGroup ();
        group.set_title ("Detected Subtitle Streams");
        group.set_description (
            "Subtitle tracks found in the input file — expand a row to edit metadata or reorder"
        );

        // Content
        if (current_input_file == "") {
            var row = new Adw.ActionRow ();
            row.set_title ("No File Loaded");
            row.set_subtitle ("Select an input file to detect subtitle tracks");
            row.add_prefix (make_icon ("document-open-symbolic"));
            group.add (row);
        } else if (detected_streams.length == 0) {
            var row = new Adw.ActionRow ();
            row.set_title ("No Subtitles Found");
            row.set_subtitle ("This file does not contain any subtitle streams");
            row.add_prefix (make_icon ("dialog-information-symbolic"));
            group.add (row);
        } else {
            // Stream count badge
            int count = detected_streams.length;
            var count_label = new Label (@"$count found");
            count_label.add_css_class ("source-file-size");
            count_label.set_valign (Align.CENTER);
            group.set_header_suffix (count_label);

            for (int i = 0; i < detected_streams.length; i++) {
                group.add (build_detected_row (detected_streams[i], i));
            }
        }

        detected_section.append (group);
    }

    private Adw.ExpanderRow build_detected_row (SubtitleStream stream, int idx) {
        var expander = new Adw.ExpanderRow ();
        var binding = new DetectedRowBinding ();
        binding.owner = this;
        binding.stream = stream;
        binding.expander = expander;
        binding.drag_idx = idx;
        detected_row_bindings.add (binding);

        // Title: "#0  ·  subrip  ·  eng"
        string codec = stream.codec_name.length > 0 ? stream.codec_name : "unknown";
        string lang  = (stream.language.length > 0 && stream.language != "und")
            ? stream.language : "no language";
        expander.set_title (@"Track #$(stream.sub_index)  ·  $(codec)  ·  $(lang)");

        if (stream.title.length > 0)
            expander.set_subtitle (stream.title);

        expander.add_prefix (make_icon ("media-view-subtitles-symbolic"));

        // ── Drag-and-drop reorder ────────────────────────────────────────────
        var drag_source = new DragSource ();
        drag_source.set_actions (Gdk.DragAction.MOVE);
        drag_source.prepare.connect (binding.on_drag_prepare);
        drag_source.drag_begin.connect (binding.on_drag_begin);
        drag_source.drag_cancel.connect (binding.on_drag_cancel);
        drag_source.drag_end.connect (binding.on_drag_end);
        expander.add_controller (drag_source);

        var drop_target = new DropTarget (typeof (string), Gdk.DragAction.MOVE);
        drop_target.drop.connect (binding.on_drop);
        expander.add_controller (drop_target);

        // ── Include/exclude via enable-switch ────────────────────────────────
        expander.set_show_enable_switch (true);
        expander.set_enable_expansion (!stream.marked_remove);
        expander.set_expanded (!stream.marked_remove && stream.details_expanded);

        // Keep persistent row UI state on the stream so rebuilds can restore it.
        expander.notify["expanded"].connect (binding.on_expanded_notify);

        // Bind inclusion switch state → marked_remove
        expander.notify["enable-expansion"].connect (binding.on_enable_expansion_notify);

        // ── Language ─────────────────────────────────────────────────────────
        var lang_row = new Adw.ActionRow ();
        lang_row.set_title ("Language");
        lang_row.set_subtitle ("ISO 639 code (e.g. eng, spa, jpn, fre)");
        var lang_entry = new Entry ();
        lang_entry.set_text (stream.language);
        lang_entry.set_placeholder_text ("eng");
        lang_entry.set_width_chars (8);
        lang_entry.set_valign (Align.CENTER);
        binding.lang_entry = lang_entry;
        lang_entry.changed.connect (binding.on_language_changed);
        lang_row.add_suffix (lang_entry);
        expander.add_row (lang_row);

        // ── Title ────────────────────────────────────────────────────────────
        var title_row = new Adw.ActionRow ();
        title_row.set_title ("Title");
        title_row.set_subtitle ("Descriptive label shown in media players");
        var title_entry = new Entry ();
        title_entry.set_text (stream.title);
        title_entry.set_placeholder_text ("e.g. English (SDH)");
        title_entry.set_width_chars (20);
        title_entry.set_valign (Align.CENTER);
        binding.title_entry = title_entry;
        title_entry.changed.connect (binding.on_title_changed);
        title_row.add_suffix (title_entry);
        expander.add_row (title_row);

        // ── Default flag ─────────────────────────────────────────────────────
        var default_row = new Adw.ActionRow ();
        default_row.set_title ("Default");
        default_row.set_subtitle ("Automatically selected when the video plays");
        var default_sw = new Switch ();
        default_sw.set_active (stream.is_default);
        default_sw.set_valign (Align.CENTER);
        register_detected_default_switch (stream, default_sw);
        binding.default_sw = default_sw;
        default_sw.notify["active"].connect (binding.on_default_active_notify);
        default_row.add_suffix (default_sw);
        default_row.set_activatable_widget (default_sw);
        expander.add_row (default_row);

        // ── Forced flag ──────────────────────────────────────────────────────
        var forced_row = new Adw.ActionRow ();
        forced_row.set_title ("Forced");
        forced_row.set_subtitle ("Shown only for foreign-language dialogue sections");
        var forced_sw = new Switch ();
        forced_sw.set_active (stream.is_forced);
        forced_sw.set_valign (Align.CENTER);
        binding.forced_sw = forced_sw;
        forced_sw.notify["active"].connect (binding.on_forced_active_notify);
        forced_row.add_suffix (forced_sw);
        forced_row.set_activatable_widget (forced_sw);
        expander.add_row (forced_row);

        // ── Reorder ──────────────────────────────────────────────────────────
        var move_row = new Adw.ActionRow ();
        move_row.set_title ("Reorder");
        move_row.set_subtitle ("Move this track up or down in the output order");

        var move_box = new Box (Orientation.HORIZONTAL, 8);
        move_box.set_valign (Align.CENTER);

        var up_btn = new Button.from_icon_name ("go-up-symbolic");
        up_btn.add_css_class ("flat");
        up_btn.set_tooltip_text ("Move up");
        binding.move_up_button = up_btn;
        up_btn.clicked.connect (binding.on_move_up_clicked);
        move_box.append (up_btn);

        var down_btn = new Button.from_icon_name ("go-down-symbolic");
        down_btn.add_css_class ("flat");
        down_btn.set_tooltip_text ("Move down");
        binding.move_down_button = down_btn;
        down_btn.clicked.connect (binding.on_move_down_clicked);
        move_box.append (down_btn);

        move_row.add_suffix (move_box);
        expander.add_row (move_row);

        return expander;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  2. EXTRACT (static — built once, only the combo model changes)
    // ═════════════════════════════════════════════════════════════════════════

    private void build_extract_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Extract Subtitle");
        group.set_description ("Save a subtitle track from the video as a standalone file");

        // Track selector
        var track_row = new Adw.ActionRow ();
        track_row.set_title ("Track");
        track_row.set_subtitle ("Choose which subtitle stream to extract");
        extract_track_combo = new DropDown (CodecUtils.build_dropdown_string_list ({ "No tracks available" }), null);
        extract_track_combo.set_valign (Align.CENTER);
        extract_track_combo.set_sensitive (false);
        track_row.add_suffix (extract_track_combo);
        group.add (track_row);

        // Format selector
        var fmt_row = new Adw.ActionRow ();
        fmt_row.set_title ("Output Format");
        fmt_row.set_subtitle ("Target subtitle file format");
        extract_format_combo = new DropDown (CodecUtils.build_dropdown_string_list (
            { "SRT (.srt)", "ASS (.ass)", "WebVTT (.vtt)", "SubStation Alpha (.ssa)", "Copy Original" }
        ), null);
        extract_format_combo.set_valign (Align.CENTER);
        extract_format_combo.set_selected (4);
        fmt_row.add_suffix (extract_format_combo);
        group.add (fmt_row);

        // Extract button
        var btn_row = new Adw.ActionRow ();
        btn_row.set_title ("Extract to File");
        btn_row.set_subtitle ("Opens a save dialog for the extracted subtitle");
        extract_button = new Button.with_label ("Extract");
        extract_button.add_css_class ("suggested-action");
        extract_button.set_valign (Align.CENTER);
        extract_button.set_sensitive (false);
        btn_row.add_suffix (extract_button);
        btn_row.set_activatable_widget (extract_button);
        group.add (btn_row);

        // Extract All button
        var all_row = new Adw.ActionRow ();
        all_row.set_title ("Extract All Tracks");
        all_row.set_subtitle ("Save every subtitle track to a folder using native formats");
        extract_all_button = new Button.with_label ("Extract All");
        extract_all_button.set_valign (Align.CENTER);
        extract_all_button.set_sensitive (false);
        all_row.add_suffix (extract_all_button);
        all_row.set_activatable_widget (extract_all_button);
        group.add (all_row);

        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  3. ADD EXTERNAL SUBTITLES (dynamic — rebuilt when files are added/removed)
    // ═════════════════════════════════════════════════════════════════════════

    private void rebuild_add_group () {
        added_default_bindings = new GenericArray<AddedDefaultBinding> ();
        added_row_bindings = new GenericArray<AddedRowBinding> ();
        clear_box (add_section);

        var group = new Adw.PreferencesGroup ();
        group.set_title ("Add External Subtitles");
        group.set_description (
            "Import subtitle files to embed in the video — configure language and flags per track"
        );

        // "+" button (signal connected inline — safe across rebuilds)
        var add_btn = new Button.from_icon_name ("list-add-symbolic");
        add_btn.add_css_class ("flat");
        add_btn.set_tooltip_text ("Add subtitle files (.srt, .ass, .vtt, .ssa, .sub)");
        add_btn.set_valign (Align.CENTER);
        add_btn.set_sensitive (!_is_busy);
        add_btn.clicked.connect (on_add_file_clicked);
        group.set_header_suffix (add_btn);

        if (added_subtitles.length == 0) {
            var row = new Adw.ActionRow ();
            row.set_title ("No Subtitles Added");
            row.set_subtitle ("Click the + button above to add subtitle files");
            row.add_prefix (make_icon ("list-add-symbolic"));
            group.add (row);
        } else {
            for (int i = 0; i < added_subtitles.length; i++) {
                group.add (build_added_row (added_subtitles[i], i));
            }
        }

        add_section.append (group);
    }

    private Adw.ExpanderRow build_added_row (ExternalSubtitle ext, int index) {
        var expander = new Adw.ExpanderRow ();
        var binding = new AddedRowBinding ();
        binding.owner = this;
        binding.ext = ext;
        binding.expander = expander;
        binding.index = index;
        binding.drag_idx = index;
        added_row_bindings.add (binding);

        string basename = Path.get_basename (ext.file_path);
        expander.set_title (basename);
        expander.set_subtitle (ext.language.length > 0 ? ext.language : "no language set");
        expander.add_prefix (make_icon ("document-new-symbolic"));
        expander.set_expanded (ext.details_expanded);

        // Keep persistent row UI state on the subtitle so rebuilds can restore it.
        expander.notify["expanded"].connect (binding.on_expanded_notify);

        // ── Drag-and-drop reorder ────────────────────────────────────────────
        var drag_source = new DragSource ();
        drag_source.set_actions (Gdk.DragAction.MOVE);
        drag_source.prepare.connect (binding.on_drag_prepare);
        drag_source.drag_begin.connect (binding.on_drag_begin);
        drag_source.drag_cancel.connect (binding.on_drag_cancel);
        drag_source.drag_end.connect (binding.on_drag_end);
        expander.add_controller (drag_source);

        var drop_target = new DropTarget (typeof (string), Gdk.DragAction.MOVE);
        drop_target.drop.connect (binding.on_drop);
        expander.add_controller (drop_target);

        // Remove button
        var rm_btn = new Button.from_icon_name ("user-trash-symbolic");
        rm_btn.add_css_class ("flat");
        rm_btn.add_css_class ("error");
        rm_btn.set_valign (Align.CENTER);
        rm_btn.set_tooltip_text ("Remove this subtitle");
        binding.remove_button = rm_btn;
        rm_btn.clicked.connect (binding.on_remove_clicked);
        expander.add_suffix (rm_btn);

        // ── Language ─────────────────────────────────────────────────────────
        var lang_row = new Adw.ActionRow ();
        lang_row.set_title ("Language");
        lang_row.set_subtitle ("ISO 639 code (e.g. eng, spa, jpn, fre)");
        var lang_entry = new Entry ();
        lang_entry.set_text (ext.language);
        lang_entry.set_placeholder_text ("eng");
        lang_entry.set_width_chars (8);
        lang_entry.set_valign (Align.CENTER);
        binding.lang_entry = lang_entry;
        lang_entry.changed.connect (binding.on_language_changed);
        lang_row.add_suffix (lang_entry);
        expander.add_row (lang_row);

        // ── Title ────────────────────────────────────────────────────────────
        var title_row = new Adw.ActionRow ();
        title_row.set_title ("Title");
        title_row.set_subtitle ("Descriptive label shown in media players");
        var title_entry = new Entry ();
        title_entry.set_text (ext.title);
        title_entry.set_placeholder_text ("e.g. English (SDH)");
        title_entry.set_width_chars (20);
        title_entry.set_valign (Align.CENTER);
        binding.title_entry = title_entry;
        title_entry.changed.connect (binding.on_title_changed);
        title_row.add_suffix (title_entry);
        expander.add_row (title_row);

        // ── Default flag ─────────────────────────────────────────────────────
        var default_row = new Adw.ActionRow ();
        default_row.set_title ("Default");
        default_row.set_subtitle ("Automatically selected when the video plays");
        var default_sw = new Switch ();
        default_sw.set_active (ext.is_default);
        default_sw.set_valign (Align.CENTER);
        register_added_default_switch (ext, default_sw);
        binding.default_sw = default_sw;
        default_sw.notify["active"].connect (binding.on_default_active_notify);
        default_row.add_suffix (default_sw);
        default_row.set_activatable_widget (default_sw);
        expander.add_row (default_row);

        // ── Forced flag ──────────────────────────────────────────────────────
        var forced_row = new Adw.ActionRow ();
        forced_row.set_title ("Forced");
        forced_row.set_subtitle ("Shown only for foreign-language dialogue sections");
        var forced_sw = new Switch ();
        forced_sw.set_active (ext.is_forced);
        forced_sw.set_valign (Align.CENTER);
        binding.forced_sw = forced_sw;
        forced_sw.notify["active"].connect (binding.on_forced_active_notify);
        forced_row.add_suffix (forced_sw);
        forced_row.set_activatable_widget (forced_sw);
        expander.add_row (forced_row);

        // ── Bitmap flag ─────────────────────────────────────────────────────
        var bitmap_row = new Adw.ActionRow ();
        bitmap_row.set_title ("Bitmap Subtitle");
        bitmap_row.set_subtitle ("Enable for image-based formats (PGS/VobSub) — uses overlay filter for burn-in");
        var bitmap_sw = new Switch ();
        bitmap_sw.set_active (ext.is_bitmap);
        bitmap_sw.set_valign (Align.CENTER);
        binding.bitmap_sw = bitmap_sw;
        bitmap_sw.notify["active"].connect (binding.on_bitmap_active_notify);
        bitmap_row.add_suffix (bitmap_sw);
        bitmap_row.set_activatable_widget (bitmap_sw);
        expander.add_row (bitmap_row);

        // ── Reorder ──────────────────────────────────────────────────────────
        var move_row = new Adw.ActionRow ();
        move_row.set_title ("Reorder");
        var move_box = new Box (Orientation.HORIZONTAL, 8);
        move_box.set_valign (Align.CENTER);

        var up_btn = new Button.from_icon_name ("go-up-symbolic");
        up_btn.add_css_class ("flat");
        up_btn.set_tooltip_text ("Move up");
        binding.move_up_button = up_btn;
        up_btn.clicked.connect (binding.on_move_up_clicked);
        move_box.append (up_btn);

        var down_btn = new Button.from_icon_name ("go-down-symbolic");
        down_btn.add_css_class ("flat");
        down_btn.set_tooltip_text ("Move down");
        binding.move_down_button = down_btn;
        down_btn.clicked.connect (binding.on_move_down_clicked);
        move_box.append (down_btn);

        move_row.add_suffix (move_box);
        expander.add_row (move_row);

        // ── File path (informational) ────────────────────────────────────────
        var path_row = new Adw.ActionRow ();
        path_row.set_title ("File Path");
        var path_label = new Label (ext.file_path);
        path_label.set_ellipsize (Pango.EllipsizeMode.MIDDLE);
        path_label.set_max_width_chars (40);
        path_label.set_valign (Align.CENTER);
        path_label.add_css_class ("dim-label");
        path_row.add_suffix (path_label);
        expander.add_row (path_row);

        return expander;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  4. OUTPUT SETTINGS (static — built once)
    // ═════════════════════════════════════════════════════════════════════════

    private void build_output_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Output Settings");
        group.set_description (
            "Configure how subtitle changes are applied to the output file"
        );

        // Mode selector: Remux or Burn In
        var mode_row = new Adw.ActionRow ();
        mode_row.set_title ("Mode");
        mode_row.set_subtitle ("Remux is fast (no re-encode) — Burn In draws text onto every frame");
        mode_combo = new DropDown (CodecUtils.build_dropdown_string_list (
            { "Remux (soft subtitles)", "Burn In (hardcode into video)" }
        ), null);
        mode_combo.set_valign (Align.CENTER);
        mode_combo.set_selected (0);
        mode_row.add_suffix (mode_combo);
        group.add (mode_row);

        // Container format
        var container_row = new Adw.ActionRow ();
        container_row.set_title ("Output Container");
        container_row.set_subtitle ("Source preserves the original container format");
        container_combo = new DropDown (CodecUtils.build_dropdown_string_list (
            { "Source (original format)", "MKV (.mkv)", "MP4 (.mp4)", "WebM (.webm)" }
        ), null);
        container_combo.set_valign (Align.CENTER);
        container_combo.set_selected (0);
        container_row.add_suffix (container_combo);
        group.add (container_row);

        // Compatibility info (updates dynamically when container changes)
        container_compat_row = new Adw.ActionRow ();
        container_compat_row.add_prefix (make_icon ("dialog-information-symbolic"));
        update_container_compat_info ();
        group.add (container_compat_row);

        container_combo.notify["selected"].connect (() => {
            update_container_compat_info ();
        });

        // Mode switching — show/hide burn-in group
        mode_combo.notify["selected"].connect (() => {
            bool burn_in = (mode_combo.get_selected () == 1);
            burn_in_group.set_visible (burn_in);
            update_container_compat_info ();
            update_ui_state ();
        });

        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  5. BURN-IN CONFIGURATION (static — built once, visibility toggles)
    // ═════════════════════════════════════════════════════════════════════════

    private void build_burn_in_group () {
        burn_in_group = new Adw.PreferencesGroup ();
        burn_in_group.set_title ("Burn-In Configuration");
        burn_in_group.set_description (
            "Full video re-encode — subtitles are permanently drawn onto every frame"
        );

        // Track to burn in
        var track_row = new Adw.ActionRow ();
        track_row.set_title ("Subtitle Track");
        track_row.set_subtitle ("Which subtitle to hardcode into the video");
        burn_track_combo = new DropDown (CodecUtils.build_dropdown_string_list ({ "No tracks available" }), null);
        burn_track_combo.set_valign (Align.CENTER);
        burn_track_combo.set_sensitive (false);
        track_row.add_suffix (burn_track_combo);
        burn_in_group.add (track_row);

        // Codec selector
        var codec_row = new Adw.ActionRow ();
        codec_row.set_title ("Video Codec");
        codec_row.set_subtitle ("Encoding settings are taken from the selected codec tab");
        burn_codec_combo = new DropDown (CodecUtils.build_dropdown_string_list (
            { "SVT-AV1", "x265", "x264", "VP9" }
        ), null);
        burn_codec_combo.set_valign (Align.CENTER);
        burn_codec_combo.set_selected (0);
        codec_row.add_suffix (burn_codec_combo);
        burn_in_group.add (codec_row);

        // Info row
        var info_row = new Adw.ActionRow ();
        info_row.set_title ("Re-encode Required");
        info_row.set_subtitle (
            "This will re-encode the entire video using the selected codec tab plus shared General settings - " +
            "much slower than remux, but produces a single self-contained file"
        );
        info_row.add_prefix (make_icon ("dialog-warning-symbolic"));
        burn_in_group.add (info_row);

        // Hidden by default — shown when mode = Burn In
        burn_in_group.set_visible (false);

        append (burn_in_group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SIGNAL WIRING (runs once at construction for static widgets)
    // ═════════════════════════════════════════════════════════════════════════

    private void connect_signals () {
        extract_button.clicked.connect (on_extract_clicked);
        extract_all_button.clicked.connect (on_extract_all_clicked);
        runner.operation_done.connect (on_runner_operation_done);
        runner.operation_failed.connect (on_runner_operation_failed);
        runner.operation_cancelled.connect (on_runner_operation_cancelled);
        runner.apply_done.connect (on_runner_apply_done);
        runner.apply_failed.connect (on_runner_apply_failed);
        runner.apply_cancelled.connect (on_runner_apply_cancelled);
    }

    private void on_runner_operation_done (OperationOutputResult output_result) {
        uint64 operation_id = active_extract_operation_id;
        active_extract_operation_id = 0;
        set_busy (false);
        subtitle_done (output_result);
        if (operation_id != 0) {
            subtitle_extract_succeeded (operation_id, output_result);
        }
    }

    private void on_runner_operation_failed (string msg) {
        uint64 operation_id = active_extract_operation_id;
        active_extract_operation_id = 0;
        set_busy (false);
        if (operation_id != 0) {
            subtitle_extract_failed (operation_id);
        }
    }

    private void on_runner_operation_cancelled () {
        uint64 operation_id = active_extract_operation_id;
        active_extract_operation_id = 0;
        set_busy (false);
        if (operation_id != 0) {
            subtitle_extract_cancelled (operation_id);
        }
    }

    private void on_runner_apply_done (uint64 operation_id,
                                       OperationOutputResult output_result) {
        if (active_apply_operation_id != operation_id) {
            return;
        }

        active_apply_operation_id = 0;
        set_busy (false);
        subtitle_done (output_result);
        subtitle_apply_succeeded (operation_id, output_result);
    }

    private void on_runner_apply_failed (uint64 operation_id, string msg) {
        if (active_apply_operation_id != operation_id) {
            return;
        }

        active_apply_operation_id = 0;
        set_busy (false);
        subtitle_apply_failed (operation_id);
    }

    private void on_runner_apply_cancelled (uint64 operation_id) {
        if (active_apply_operation_id != operation_id) {
            return;
        }

        active_apply_operation_id = 0;
        set_busy (false);
        subtitle_apply_cancelled (operation_id);
    }

    internal Gdk.ContentProvider begin_detected_drag (int drag_idx) {
        _drag_from_detected = drag_idx;
        _drag_from_added = -1;
        var val = Value (typeof (string));
        val.set_string (DRAG_ORIGIN_DETECTED);
        return new Gdk.ContentProvider.for_value (val);
    }

    internal Gdk.ContentProvider begin_added_drag (int drag_idx) {
        _drag_from_added = drag_idx;
        _drag_from_detected = -1;
        var val = Value (typeof (string));
        val.set_string (DRAG_ORIGIN_ADDED);
        return new Gdk.ContentProvider.for_value (val);
    }

    internal void set_drag_icon_for_expander (DragSource source, Adw.ExpanderRow expander) {
        var paintable = new WidgetPaintable (expander);
        source.set_icon (paintable, 0, 0);
    }

    internal bool finish_drag_cancel () {
        clear_drag_state ();
        return false;
    }

    internal void finish_drag_state () {
        clear_drag_state ();
    }

    internal bool complete_detected_drop (int drag_idx, Value value) {
        string? drag_origin = value.get_string ();
        if (drag_origin != DRAG_ORIGIN_DETECTED) {
            clear_drag_state ();
            return false;
        }
        if (_drag_from_detected >= 0 && _drag_from_detected != drag_idx) {
            reorder_detected (_drag_from_detected, drag_idx);
        }
        clear_drag_state ();
        return true;
    }

    internal bool complete_added_drop (int drag_idx, Value value) {
        string? drag_origin = value.get_string ();
        if (drag_origin != DRAG_ORIGIN_ADDED) {
            clear_drag_state ();
            return false;
        }
        if (_drag_from_added >= 0 && _drag_from_added != drag_idx) {
            reorder_added (_drag_from_added, drag_idx);
        }
        clear_drag_state ();
        return true;
    }

    internal void refresh_ui_state_from_binding () {
        update_ui_state ();
    }

    internal void handle_detected_default_toggle (SubtitleStream stream, Switch default_sw) {
        if (_updating_defaults)
            return;
        if (default_sw.active) {
            _updating_defaults = true;
            clear_all_defaults ();
            stream.is_default = true;
            sync_default_switches ();
            _updating_defaults = false;
        } else {
            stream.is_default = false;
        }
    }

    internal void handle_added_default_toggle (ExternalSubtitle ext, Switch default_sw) {
        if (_updating_defaults)
            return;
        if (default_sw.active) {
            _updating_defaults = true;
            clear_all_defaults ();
            ext.is_default = true;
            sync_default_switches ();
            _updating_defaults = false;
        } else {
            ext.is_default = false;
        }
    }

    internal void move_detected_from_binding (SubtitleStream stream, int dir) {
        move_detected (stream, dir);
    }

    internal void move_added_from_binding (int index, int dir) {
        move_added (index, dir);
    }

    internal void remove_added_from_binding (int index) {
        if (index >= 0 && index < added_subtitles.length) {
            added_subtitles.remove_index (index);
            rebuild_add_group ();
            rebuild_burn_track_combo ();
            update_ui_state ();
        }
    }

    private void set_busy (bool busy) {
        if (_is_busy == busy) {
            return;
        }

        _is_busy = busy;
        update_ui_state ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PUBLIC API — Called by AppController when input file changes
    // ═════════════════════════════════════════════════════════════════════════

    public void load_video (string file_path) {
        uint64 request_generation = ++probe_generation;
        string previous_input_file = current_input_file;
        bool input_changed = previous_input_file != file_path;
        current_input_file = file_path;

        if (input_changed) {
            detected_streams = new GenericArray<SubtitleStream> ();

            if (added_subtitles.length > 0) {
                added_subtitles = new GenericArray<ExternalSubtitle> ();
                rebuild_add_group ();
            }

            rebuild_extract_combo ();
            rebuild_burn_track_combo ();
            update_ui_state ();
        }

        if (file_path == "") {
            detected_streams = new GenericArray<SubtitleStream> ();
            rebuild_detected_group ();
            rebuild_extract_combo ();
            rebuild_burn_track_combo ();
            update_ui_state ();
            return;
        }

        // Show scanning placeholder
        clear_box (detected_section);
        var tmp_group = new Adw.PreferencesGroup ();
        tmp_group.set_title ("Detected Subtitle Streams");
        tmp_group.set_description ("Scanning…");
        var scan_row = new Adw.ActionRow ();
        scan_row.set_title ("Scanning…");
        scan_row.set_subtitle ("Probing subtitle streams in the file");
        var spinner = new Gtk.Spinner ();
        spinner.set_spinning (true);
        spinner.set_valign (Align.CENTER);
        scan_row.add_prefix (spinner);
        tmp_group.add (scan_row);
        detected_section.append (tmp_group);

        // Run probe on background thread, update UI via Idle.add
        string probe_path = file_path;
        new Thread<void> ("subtitle-probe", () => {
            GenericArray<SubtitleStream> streams = runner.probe_sync (probe_path);
            Idle.add (() => {
                if (request_generation != probe_generation || current_input_file != probe_path) {
                    return Source.REMOVE;
                }

                detected_streams = streams;
                rebuild_detected_group ();
                rebuild_extract_combo ();
                rebuild_burn_track_combo ();
                update_ui_state ();
                return Source.REMOVE;
            });
        });
    }

    public void cancel_operation () {
        if (!_is_busy && active_extract_operation_id == 0 && active_apply_operation_id == 0) {
            return;
        }
        runner.cancel ();
    }

    public bool is_busy () {
        return _is_busy;
    }

    public void set_operation_locked (bool locked) {
        if (operation_locked == locked) {
            return;
        }

        operation_locked = locked;
        update_ui_state ();
    }

    public void set_ui_refs (StatusArea status_area, ConsoleTab console) {
        runner.status_area = status_area;
        runner.progress_bar = status_area.progress_bar;
        runner.console_tab  = console;
        _status_area = status_area;
    }

    private StatusArea? _status_area = null;

    // ═════════════════════════════════════════════════════════════════════════
    //  EXTRACT HANDLER
    // ═════════════════════════════════════════════════════════════════════════

    private void on_extract_clicked () {
        if (current_input_file == "" || detected_streams.length == 0) return;

        uint selected = extract_track_combo.get_selected ();
        if (selected >= detected_streams.length) return;

        var stream = detected_streams[(int) selected];
        string ext = get_extract_extension ();

        // Build default output filename
        string basename = Path.get_basename (current_input_file);
        int dot = basename.last_index_of_char ('.');
        string name_no_ext = (dot > 0) ? basename.substring (0, dot) : basename;

        string lang_part = (stream.language.length > 0 && stream.language != "und")
            ? @".$(stream.language)" : "";
        string default_name = @"$(name_no_ext)$(lang_part).track$(stream.sub_index)$(ext)";

        // Show save dialog
        var dialog = new FileDialog ();
        dialog.set_initial_name (default_name);

        // Default to output folder if set
        if (file_pickers != null) {
            string out_dir = file_pickers.output_entry.get_text ().strip ();
            if (out_dir.length > 0) {
                dialog.set_initial_folder (File.new_for_path (out_dir));
            }
        }

        var sub_filter = new FileFilter ();
        sub_filter.name = "Subtitle files";
        sub_filter.add_pattern ("*.srt");
        sub_filter.add_pattern ("*.ass");
        sub_filter.add_pattern ("*.ssa");
        sub_filter.add_pattern ("*.vtt");
        sub_filter.add_pattern ("*.sub");
        sub_filter.add_pattern ("*.sup");

        var all_filter = new FileFilter ();
        all_filter.name = "All files";
        all_filter.add_pattern ("*");

        var filters = new GLib.ListStore (typeof (FileFilter));
        filters.append (sub_filter);
        filters.append (all_filter);
        dialog.set_filters (filters);

        dialog.save.begin (get_root () as Gtk.Window, null, (obj, res) => {
            try {
                var file = dialog.save.end (res);
                if (file != null) {
                    string? path = file.get_path ();
                    if (path == null || path.length == 0) {
                        return;
                    }

                    subtitle_extract_requested (current_input_file, stream, path);
                }
            } catch (Error e) {
                // User cancelled
            }
        });
    }

    private string get_extract_extension () {
        switch (extract_format_combo.get_selected ()) {
            case 0:  return ".srt";
            case 1:  return ".ass";
            case 2:  return ".vtt";
            case 3:  return ".ssa";
            case 4:  return get_native_extension ();  // Copy Original
            default: return ".srt";
        }
    }

    /** Map a subtitle codec to its native file extension. */
    private string get_native_extension () {
        uint selected = extract_track_combo.get_selected ();
        if (selected >= detected_streams.length) return ".srt";
        return SubtitlesRunner.native_extension_for_codec (
            detected_streams[(int) selected].codec_name.down ());
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  EXTRACT ALL HANDLER
    // ═════════════════════════════════════════════════════════════════════════

    private void on_extract_all_clicked () {
        if (current_input_file == "" || detected_streams.length == 0) return;

        // Use a folder chooser — all tracks are saved into the selected directory
        var dialog = new FileDialog ();

        // Default to output folder if set, otherwise input file's directory
        string default_dir = Path.get_dirname (current_input_file);
        if (file_pickers != null) {
            string out_dir = file_pickers.output_entry.get_text ().strip ();
            if (out_dir.length > 0) default_dir = out_dir;
        }
        dialog.set_initial_folder (File.new_for_path (default_dir));

        dialog.select_folder.begin (get_root () as Gtk.Window, null, (obj, res) => {
            try {
                var folder = dialog.select_folder.end (res);
                if (folder == null) return;
                string? dir_path = folder.get_path ();
                if (dir_path == null) return;

                // Build base name from input filename
                string basename = Path.get_basename (current_input_file);
                int dot = basename.last_index_of_char ('.');
                string name_no_ext = (dot > 0) ? basename.substring (0, dot) : basename;

                subtitle_extract_all_requested (current_input_file, dir_path, name_no_ext);
            } catch (Error e) {
                // User cancelled
            }
        });
    }

    /**
     * Update the compatibility info row based on the selected container.
     */
    private void update_container_compat_info () {
        bool editable = !_is_busy && !operation_locked;

        // In burn-in mode, show re-encode info instead of subtitle compat
        if (is_burn_in_mode ()) {
            container_compat_row.set_title ("Burn-In — Container from codec tab");
            container_compat_row.set_subtitle (
                "Output container is determined by the selected codec tab's settings"
            );
            // Container combo is irrelevant in burn-in mode
            container_combo.set_sensitive (false);
            return;
        }

        container_combo.set_sensitive (editable);
        string ext = get_output_extension ();
        string title;
        string subtitle;

        if (ext == ".mkv" || ext == ".mka") {
            title = "MKV — Supports nearly all subtitle formats";
            subtitle = "SRT, ASS/SSA, VTT, PGS (bitmap), VobSub, HDMV text, and more";
        } else if (ext == ".mp4" || ext == ".m4v") {
            title = "MP4 — Limited subtitle support";
            subtitle = "mov_text (TX3G) only — SRT and ASS will be converted automatically";
        } else if (ext == ".webm") {
            title = "WebM — WebVTT subtitles only";
            subtitle = "Text subtitles will be converted to WebVTT; bitmap subs are not supported";
        } else if (ext == ".avi") {
            title = "AVI — Very limited subtitle support";
            subtitle = "SRT only via XSUB; consider switching to MKV for best compatibility";
        } else if (ext == ".ts" || ext == ".m2ts") {
            title = "MPEG-TS — DVB/PGS subtitles";
            subtitle = "DVB subtitle and PGS (bitmap); text subs may not mux cleanly";
        } else {
            title = @"$(ext.up ().substring (1)) — Unknown subtitle compatibility";
            subtitle = "MKV is the safest choice if you need reliable subtitle support";
        }

        // When Source is active, replace the subtitle with a recommendation
        if (container_combo.get_selected () == 0) {
            if (current_input_file.length > 0) {
                title = "Source → " + title;
            } else {
                title = "Source — No file loaded yet";
            }
            subtitle = "Uses the source file extension — MKV is recommended as the most compatible for subtitles";
        }

        container_compat_row.set_title (title);
        container_compat_row.set_subtitle (subtitle);
    }

    /**
     * Resolve the output container extension based on the dropdown selection.
     * "Source" reads the input file's original extension.
     */
    private string get_output_extension () {
        switch (container_combo.get_selected ()) {
            case 1:  return ".mkv";
            case 2:  return ".mp4";
            case 3:  return ".webm";
            default: break;  // 0 = Source
        }

        // Source: extract the input file's extension
        int dot = current_input_file.last_index_of_char ('.');
        if (dot >= 0) return current_input_file.substring (dot).down ();
        return ".mkv";  // fallback
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ADD FILE HANDLER
    // ═════════════════════════════════════════════════════════════════════════

    private void on_add_file_clicked () {
        var dialog = new FileDialog ();

        var sub_filter = new FileFilter ();
        sub_filter.name = "Subtitle files (.srt, .ass, .ssa, .vtt, .sub, .sup)";
        sub_filter.add_pattern ("*.srt");
        sub_filter.add_pattern ("*.ass");
        sub_filter.add_pattern ("*.ssa");
        sub_filter.add_pattern ("*.vtt");
        sub_filter.add_pattern ("*.sub");
        sub_filter.add_pattern ("*.sup");

        var all_filter = new FileFilter ();
        all_filter.name = "All files";
        all_filter.add_pattern ("*");

        var filters = new GLib.ListStore (typeof (FileFilter));
        filters.append (sub_filter);
        filters.append (all_filter);
        dialog.set_filters (filters);

        dialog.open_multiple.begin (get_root () as Gtk.Window, null, (obj, res) => {
            try {
                var files = dialog.open_multiple.end (res);
                if (files == null) return;

                for (uint i = 0; i < files.get_n_items (); i++) {
                    var file = files.get_item (i) as GLib.File;
                    if (file == null) continue;
                    string? path = file.get_path ();
                    if (path == null) continue;

                    var s = new ExternalSubtitle ();
                    s.file_path  = path;
                    s.language   = SubtitleLanguageGuesser.guess_from_path (path);
                    s.title      = "";
                    s.is_default = false;
                    s.is_forced  = false;
                    s.is_bitmap  = ExternalSubtitle.guess_bitmap_from_path (path);
                    added_subtitles.add (s);
                }

                rebuild_add_group ();
                rebuild_burn_track_combo ();
                update_ui_state ();
            } catch (Error e) {
                // User cancelled
            }
        });
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  APPLY HANDLER
    // ═════════════════════════════════════════════════════════════════════════

    /** Whether the subtitles tab has enough state to apply changes. */
    /** Whether the current mode is burn-in. */
    public bool is_burn_in_mode () {
        return mode_combo.get_selected () == 1;
    }

    /** Current input file used by the subtitles workflow. */
    public string get_input_file () {
        return current_input_file;
    }

    /** True when burn-in mode will re-encode through SVT-AV1. */
    public bool will_use_svt_av1_burn_in () {
        return is_burn_in_mode () && burn_codec_combo.get_selected () == 0;
    }

    public BaseCodecTab? get_selected_reencode_codec_tab () {
        if (!is_burn_in_mode ())
            return null;

        switch (burn_codec_combo.get_selected ()) {
            case 0:  return svt_tab as BaseCodecTab;
            case 1:  return x265_tab as BaseCodecTab;
            case 2:  return x264_tab as BaseCodecTab;
            case 3:  return vp9_tab as BaseCodecTab;
            default: return null;
        }
    }

    public bool selected_burn_in_audio_probe_pending () {
        BaseCodecTab? codec_tab = get_selected_reencode_codec_tab ();
        return codec_tab != null && codec_tab.audio_settings.is_audio_probe_pending ();
    }

    public bool can_apply () {
        if (current_input_file.length == 0) return false;
        if (_is_busy) return false;

        if (is_burn_in_mode ()) {
            // Burn-in needs at least one track to burn
            return has_burn_tracks ();
        } else {
            // Remux needs at least one stream or added file
            bool has_streams = (detected_streams.length > 0);
            bool has_added   = (added_subtitles.length > 0);
            return has_streams || has_added;
        }
    }

    /** Compute the output path that start_apply() would produce. */
    public string get_expected_output_path () {
        if (current_input_file == "") return "";

        string basename = Path.get_basename (current_input_file);
        int dot = basename.last_index_of_char ('.');
        string name = (dot > 0) ? basename.substring (0, dot) : basename;

        string dir = Path.get_dirname (current_input_file);
        if (file_pickers != null) {
            string out_dir = file_pickers.output_entry.get_text ().strip ();
            if (out_dir.length > 0)
                dir = out_dir;
        }

        string suffix = is_burn_in_mode () ? "-burnin" : "-subs";
        string ext = is_burn_in_mode () ? get_burn_in_extension () : get_output_extension ();
        return Path.build_filename (dir, name + suffix + ext);
    }

    public bool start_extract (uint64 operation_id,
                               string input_file,
                               SubtitleStream stream,
                               string output_path) {
        if (current_input_file == "" || current_input_file != input_file) {
            report_local_warning ("The input file changed before subtitle extraction started.");
            return false;
        }
        if (_is_busy || active_extract_operation_id != 0 || active_apply_operation_id != 0) {
            return false;
        }

        active_extract_operation_id = operation_id;
        set_busy (true);
        runner.extract_subtitle (input_file, stream, output_path);
        return true;
    }

    public bool start_extract_all (uint64 operation_id,
                                   string input_file,
                                   string output_dir,
                                   string base_name) {
        if (current_input_file == "" || current_input_file != input_file) {
            report_local_warning ("The input file changed before subtitle extraction started.");
            return false;
        }
        if (_is_busy || active_extract_operation_id != 0 || active_apply_operation_id != 0) {
            return false;
        }

        active_extract_operation_id = operation_id;
        set_busy (true);
        runner.extract_all_subtitles (input_file, output_dir, base_name, detected_streams);
        return true;
    }

    public bool start_apply (uint64 operation_id, bool allow_overwrite = false) {
        if (current_input_file == "") return false;
        if (_is_busy || active_extract_operation_id != 0 || active_apply_operation_id != 0) {
            return false;
        }

        bool started;
        if (is_burn_in_mode ()) {
            started = start_burn_in (operation_id, allow_overwrite);
        } else {
            started = start_remux (operation_id, allow_overwrite);
        }

        if (started) {
            active_apply_operation_id = operation_id;
        }

        return started;
    }

    // ── Remux path (existing logic) ──────────────────────────────────────────

    private bool start_remux (uint64 operation_id, bool allow_overwrite) {
        string basename = Path.get_basename (current_input_file);
        int dot = basename.last_index_of_char ('.');
        string name = (dot > 0) ? basename.substring (0, dot) : basename;

        string dir = Path.get_dirname (current_input_file);
        if (file_pickers != null) {
            string out_dir = file_pickers.output_entry.get_text ().strip ();
            if (out_dir.length > 0)
                dir = out_dir;
        }

        string ext = get_output_extension ();
        string raw_path = Path.build_filename (dir, name + "-subs" + ext);
        string output = allow_overwrite ? raw_path : find_unique (raw_path);

        // Build final order: existing (non-removed) in current order, then added
        var order = new GenericArray<int> ();
        for (int i = 0; i < detected_streams.length; i++) {
            if (!detected_streams[i].marked_remove)
                order.add (i);
        }
        for (int i = 0; i < added_subtitles.length; i++)
            order.add (detected_streams.length + i);

        set_busy (true);
        runner.remux_subtitles (
            operation_id, current_input_file, output, detected_streams, added_subtitles, order
        );
        return true;
    }

    // ── Burn-in path (full re-encode) ────────────────────────────────────────

    private bool start_burn_in (uint64 operation_id, bool allow_overwrite) {
        string basename = Path.get_basename (current_input_file);
        int dot = basename.last_index_of_char ('.');
        string name = (dot > 0) ? basename.substring (0, dot) : basename;

        string dir = Path.get_dirname (current_input_file);
        if (file_pickers != null) {
            string out_dir = file_pickers.output_entry.get_text ().strip ();
            if (out_dir.length > 0)
                dir = out_dir;
        }

        string ext = get_burn_in_extension ();
        string raw_path = Path.build_filename (dir, name + "-burnin" + ext);
        string output = allow_overwrite ? raw_path : find_unique (raw_path);

        // Resolve which track to burn in
        int combo_sel = (int) burn_track_combo.get_selected ();
        int sub_stream_index = -1;
        string? external_sub_path = null;
        bool is_bitmap = false;

        // Map combo index to internal/external track
        // The combo lists non-removed internal tracks first, then external files
        int non_removed_count = 0;
        for (int i = 0; i < detected_streams.length; i++) {
            if (!detected_streams[i].marked_remove) {
                if (non_removed_count == combo_sel) {
                    sub_stream_index = detected_streams[i].sub_index;
                    is_bitmap = SubtitlesRunner.is_bitmap_codec (
                        detected_streams[i].codec_name.down ());
                    break;
                }
                non_removed_count++;
            }
        }

        if (sub_stream_index < 0) {
            // Must be an external file
            int ext_idx = combo_sel - non_removed_count;
            if (ext_idx >= 0 && ext_idx < added_subtitles.length) {
                external_sub_path = added_subtitles[ext_idx].file_path;
                is_bitmap = added_subtitles[ext_idx].is_bitmap;
            }
        }

        // Snapshot codec + general tab settings on the main thread
        ICodecTab? codec_tab = get_selected_codec_tab ();

        if (codec_tab == null) {
            report_burn_in_error ("No codec tab available for the selected codec.");
            return false;
        }

        if (selected_burn_in_audio_probe_pending ()) {
            report_burn_in_error (
                "Checking source audio stream. Please wait a moment and try again.");
            return false;
        }

        ICodecBuilder builder = codec_tab.get_codec_builder ();
        PixelFormatSettingsSnapshot? pixel_format =
            (codec_tab is BaseCodecTab)
            ? ((BaseCodecTab) codec_tab).snapshot_pixel_format_settings ()
            : null;
        GeneralSettingsSnapshot general_settings = general_tab.snapshot_settings (pixel_format);
        EncodeProfileSnapshot profile = CodecUtils.snapshot_encode_profile (
            builder, codec_tab, general_settings);

        set_busy (true);

        runner.burn_in_subtitle (
            operation_id,
            current_input_file, output,
            sub_stream_index, external_sub_path, is_bitmap,
            profile
        );
        return true;
    }

    /** Get the ICodecTab for the burn-in codec selector. */
    private ICodecTab? get_selected_codec_tab () {
        switch (burn_codec_combo.get_selected ()) {
            case 0:  return svt_tab;
            case 1:  return x265_tab;
            case 2:  return x264_tab;
            case 3:  return vp9_tab;
            default: return svt_tab;
        }
    }

    /** Output extension for burn-in — comes from the selected codec tab's container. */
    private string get_burn_in_extension () {
        ICodecTab? tab = get_selected_codec_tab ();
        if (tab != null) {
            string container = tab.get_container ();
            if (container.length > 0) return "." + container;
        }
        return ".mkv";
    }

    private void report_burn_in_error (string message) {
        if (_status_area != null)
            _status_area.set_status (message,
                StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
    }

    private void report_local_warning (string message) {
        if (_status_area != null) {
            _status_area.set_status (message,
                StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  REORDER
    // ═════════════════════════════════════════════════════════════════════════

    private void move_detected (SubtitleStream stream, int dir) {
        int idx = -1;
        for (int i = 0; i < detected_streams.length; i++) {
            if (detected_streams[i] == stream) { idx = i; break; }
        }
        if (idx < 0) return;

        int n = idx + dir;
        if (n < 0 || n >= detected_streams.length) return;

        var tmp = detected_streams[idx];
        detected_streams[idx] = detected_streams[n];
        detected_streams[n] = tmp;

        rebuild_detected_group ();
        rebuild_extract_combo ();
        rebuild_burn_track_combo ();
    }

    private void move_added (int index, int dir) {
        int n = index + dir;
        if (n < 0 || n >= added_subtitles.length) return;

        var tmp = added_subtitles[index];
        added_subtitles[index] = added_subtitles[n];
        added_subtitles[n] = tmp;

        rebuild_add_group ();
        rebuild_burn_track_combo ();
    }

    private static void swap_detected_streams (GenericArray<SubtitleStream> detected_streams,
                                               int from,
                                               int to) {
        if (from == to) return;
        if (from < 0 || from >= detected_streams.length) return;
        if (to   < 0 || to   >= detected_streams.length) return;

        var tmp = detected_streams[from];
        detected_streams[from] = detected_streams[to];
        detected_streams[to] = tmp;
    }

    private static void swap_added_subtitles (GenericArray<ExternalSubtitle> added_subtitles,
                                              int from,
                                              int to) {
        if (from == to) return;
        if (from < 0 || from >= added_subtitles.length) return;
        if (to   < 0 || to   >= added_subtitles.length) return;

        var tmp = added_subtitles[from];
        added_subtitles[from] = added_subtitles[to];
        added_subtitles[to] = tmp;
    }

    /** Drag-and-drop: swap two detected streams. */
    private void reorder_detected (int from, int to) {
        swap_detected_streams (detected_streams, from, to);
        rebuild_detected_group ();
        rebuild_extract_combo ();
        rebuild_burn_track_combo ();
    }

    /** Drag-and-drop: swap two added subtitles. */
    private void reorder_added (int from, int to) {
        swap_added_subtitles (added_subtitles, from, to);
        rebuild_add_group ();
        rebuild_burn_track_combo ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  DEFAULT FLAG — Only one track across all lists
    // ═════════════════════════════════════════════════════════════════════════

    private void clear_all_defaults () {
        for (int i = 0; i < detected_streams.length; i++)
            detected_streams[i].is_default = false;
        for (int i = 0; i < added_subtitles.length; i++)
            added_subtitles[i].is_default = false;
    }

    private void register_detected_default_switch (SubtitleStream stream, Switch sw) {
        detected_default_bindings.add (new DetectedDefaultBinding (stream, sw));
    }

    private void register_added_default_switch (ExternalSubtitle ext, Switch sw) {
        added_default_bindings.add (new AddedDefaultBinding (ext, sw));
    }

    private void sync_default_switches () {
        for (int i = 0; i < detected_default_bindings.length; i++) {
            detected_default_bindings[i].sw.set_active (
                detected_default_bindings[i].stream.is_default);
        }

        for (int i = 0; i < added_default_bindings.length; i++) {
            added_default_bindings[i].sw.set_active (
                added_default_bindings[i].subtitle.is_default);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  EXTRACT COMBO
    // ═════════════════════════════════════════════════════════════════════════

    private void rebuild_extract_combo () {
        if (detected_streams.length == 0) {
            extract_track_combo.set_model (CodecUtils.build_dropdown_string_list ({ "No tracks available" }));
            extract_track_combo.set_sensitive (false);
            return;
        }

        string[] labels = {};
        for (int i = 0; i < detected_streams.length; i++) {
            var s = detected_streams[i];
            string c = s.codec_name.length > 0 ? s.codec_name : "unknown";
            string l = (s.language.length > 0 && s.language != "und") ? s.language : "";
            string lbl = @"#$(s.sub_index) — $(c)";
            if (l.length > 0)       lbl += @" ($(l))";
            if (s.title.length > 0) lbl += @" — $(s.title)";
            labels += lbl;
        }

        extract_track_combo.set_model (CodecUtils.build_dropdown_string_list (labels));
        extract_track_combo.set_selected (0);
        extract_track_combo.set_sensitive (true);
    }

    /**
     * Rebuild the burn-in track combo — lists both detected internal tracks
     * and added external files.
     */
    private void rebuild_burn_track_combo () {
        int total = detected_streams.length + added_subtitles.length;
        if (total == 0) {
            burn_track_combo.set_model (CodecUtils.build_dropdown_string_list ({ "No tracks available" }));
            burn_track_combo.set_sensitive (false);
            return;
        }

        string[] labels = {};

        // Internal detected tracks
        for (int i = 0; i < detected_streams.length; i++) {
            var s = detected_streams[i];
            if (s.marked_remove) continue;  // skip removed tracks
            string c = s.codec_name.length > 0 ? s.codec_name : "unknown";
            string l = (s.language.length > 0 && s.language != "und") ? s.language : "";
            string lbl = @"Internal #$(s.sub_index) — $(c)";
            if (l.length > 0)       lbl += @" ($(l))";
            if (s.title.length > 0) lbl += @" — $(s.title)";
            labels += lbl;
        }

        // External added files
        for (int i = 0; i < added_subtitles.length; i++) {
            string basename = Path.get_basename (added_subtitles[i].file_path);
            labels += @"External — $(basename)";
        }

        if (labels.length == 0) {
            burn_track_combo.set_model (CodecUtils.build_dropdown_string_list ({ "No tracks available" }));
            burn_track_combo.set_sensitive (false);
            return;
        }

        burn_track_combo.set_model (CodecUtils.build_dropdown_string_list (labels));
        burn_track_combo.set_selected (0);
        burn_track_combo.set_sensitive (true);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI STATE
    // ═════════════════════════════════════════════════════════════════════════

    private void update_ui_state () {
        bool has_file = (current_input_file.length > 0);
        bool has_streams = (detected_streams.length > 0);
        bool editable = !_is_busy && !operation_locked;
        bool has_burn_tracks = has_burn_tracks ();

        detected_section.set_sensitive (editable);
        add_section.set_sensitive (editable);
        extract_track_combo.set_sensitive (has_streams && editable);
        extract_format_combo.set_sensitive (has_streams && editable);
        extract_button.set_sensitive (has_file && has_streams && editable);
        extract_all_button.set_sensitive (has_file && has_streams && editable);
        mode_combo.set_sensitive (editable);
        container_combo.set_sensitive (!is_burn_in_mode () && editable);
        burn_in_group.set_sensitive (editable);
        burn_track_combo.set_sensitive (has_burn_tracks && editable);
        burn_codec_combo.set_sensitive (editable);

        // Refresh compat info in case the input file changed (affects "Source")
        if (container_compat_row != null)
            update_container_compat_info ();

        if (_status_area != null && can_apply ()) {
            _status_area.replace_status_if_current (
                MISSING_SUBTITLE_INPUT_WARNING,
                DEFAULT_READY_STATUS
            );
        }
    }

    private bool has_burn_tracks () {
        if (added_subtitles.length > 0)
            return true;

        for (int i = 0; i < detected_streams.length; i++) {
            if (!detected_streams[i].marked_remove) {
                return true;
            }
        }

        return false;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UTILITY
    // ═════════════════════════════════════════════════════════════════════════

    private Image make_icon (string name) {
        var img = new Image.from_icon_name (name);
        img.set_pixel_size (24);
        img.set_valign (Align.CENTER);
        img.add_css_class ("dim-label");
        return img;
    }

    private void clear_box (Box box) {
        var child = box.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            box.remove (child);
            child = next;
        }
    }

    private void clear_drag_state () {
        _drag_from_detected = -1;
        _drag_from_added = -1;
    }

    /**
     * Guess language from filename patterns:
     *   movie.eng.srt → eng
     *   movie_en.srt  → en
     *   movie-jpn.srt → jpn
     */

    private static string find_unique (string path) {
        if (!FileUtils.test (path, FileTest.EXISTS)) return path;
        int dot = path.last_index_of_char ('.');
        string b = (dot > 0) ? path.substring (0, dot) : path;
        string e = (dot > 0) ? path.substring (dot) : "";
        int c = 2;
        string p = @"$(b)_$(c)$(e)";
        while (FileUtils.test (p, FileTest.EXISTS)) {
            c++;
            p = @"$(b)_$(c)$(e)";
        }
        return p;
    }

#if TRIM_SUBTITLES_STATE_TEST_BUILD
    internal static void move_detected_for_test (GenericArray<SubtitleStream> detected_streams,
                                                 SubtitleStream stream,
                                                 int dir) {
        int idx = -1;
        for (int i = 0; i < detected_streams.length; i++) {
            if (detected_streams[i] == stream) {
                idx = i;
                break;
            }
        }
        if (idx < 0)
            return;

        int n = idx + dir;
        if (n < 0 || n >= detected_streams.length)
            return;

        var tmp = detected_streams[idx];
        detected_streams[idx] = detected_streams[n];
        detected_streams[n] = tmp;
    }

    internal static void move_added_for_test (GenericArray<ExternalSubtitle> added_subtitles,
                                              int index,
                                              int dir) {
        int n = index + dir;
        if (index < 0 || index >= added_subtitles.length || n < 0 || n >= added_subtitles.length)
            return;

        var tmp = added_subtitles[index];
        added_subtitles[index] = added_subtitles[n];
        added_subtitles[n] = tmp;
    }

    internal static void reorder_detected_for_test (GenericArray<SubtitleStream> detected_streams,
                                                    int from,
                                                    int to) {
        swap_detected_streams (detected_streams, from, to);
    }

    internal static void reorder_added_for_test (GenericArray<ExternalSubtitle> added_subtitles,
                                                 int from,
                                                 int to) {
        swap_added_subtitles (added_subtitles, from, to);
    }

    internal static void remove_added_for_test (GenericArray<ExternalSubtitle> added_subtitles,
                                                int index) {
        if (index < 0 || index >= added_subtitles.length)
            return;
        added_subtitles.remove_index (index);
    }

    internal static void set_detected_default_for_test (GenericArray<SubtitleStream> detected_streams,
                                                        GenericArray<ExternalSubtitle> added_subtitles,
                                                        SubtitleStream stream,
                                                        bool active) {
        if (active) {
            clear_all_defaults_for_test (detected_streams, added_subtitles);
            stream.is_default = true;
        } else {
            stream.is_default = false;
        }
    }

    internal static void set_added_default_for_test (GenericArray<SubtitleStream> detected_streams,
                                                     GenericArray<ExternalSubtitle> added_subtitles,
                                                     ExternalSubtitle ext,
                                                     bool active) {
        if (active) {
            clear_all_defaults_for_test (detected_streams, added_subtitles);
            ext.is_default = true;
        } else {
            ext.is_default = false;
        }
    }

    internal static GenericArray<int> build_remux_order_for_test (
        GenericArray<SubtitleStream> detected_streams,
        GenericArray<ExternalSubtitle> added_subtitles) {
        var order = new GenericArray<int> ();
        for (int i = 0; i < detected_streams.length; i++) {
            if (!detected_streams[i].marked_remove)
                order.add (i);
        }
        for (int i = 0; i < added_subtitles.length; i++)
            order.add (detected_streams.length + i);
        return order;
    }

    internal static uint64 finish_extract_operation_for_test (ref bool busy,
                                                              ref uint64 active_extract_operation_id) {
        uint64 operation_id = active_extract_operation_id;
        active_extract_operation_id = 0;
        busy = false;
        return operation_id;
    }

    internal static bool finish_apply_operation_for_test (ref bool busy,
                                                          ref uint64 active_apply_operation_id,
                                                          uint64 callback_operation_id) {
        if (active_apply_operation_id != callback_operation_id)
            return false;
        active_apply_operation_id = 0;
        busy = false;
        return true;
    }

    private static void clear_all_defaults_for_test (GenericArray<SubtitleStream> detected_streams,
                                                     GenericArray<ExternalSubtitle> added_subtitles) {
        for (int i = 0; i < detected_streams.length; i++)
            detected_streams[i].is_default = false;
        for (int i = 0; i < added_subtitles.length; i++)
            added_subtitles[i].is_default = false;
    }
#endif
}
