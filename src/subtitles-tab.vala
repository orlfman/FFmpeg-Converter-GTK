using Gtk;
using Adw;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  SubtitlesTab — Manage subtitle streams in a video file
// ═══════════════════════════════════════════════════════════════════════════════

public class SubtitlesTab : Box {

    // ── Signals ──────────────────────────────────────────────────────────────
    public signal void subtitle_done (string output_path);
    public signal void subtitle_apply_succeeded (uint64 operation_id, string output_path);
    public signal void subtitle_apply_failed (uint64 operation_id);
    public signal void general_tab_context_changed ();

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
    private uint64 active_apply_operation_id = 0;
    private bool _updating_defaults = false;

    // ── Drag-and-drop state ──────────────────────────────────────────────────
    private int _drag_from_detected = -1;
    private int _drag_from_added    = -1;

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
            count_label.add_css_class ("dim-label");
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
        int drag_idx = idx;
        drag_source.prepare.connect ((x, y) => {
            _drag_from_detected = drag_idx;
            _drag_from_added = -1;
            var val = Value (typeof (string));
            val.set_string ("detected");
            return new Gdk.ContentProvider.for_value (val);
        });
        drag_source.drag_begin.connect ((source, drag) => {
            var paintable = new WidgetPaintable (expander);
            source.set_icon (paintable, 0, 0);
        });
        expander.add_controller (drag_source);

        var drop_target = new DropTarget (typeof (string), Gdk.DragAction.MOVE);
        drop_target.drop.connect ((value, x, y) => {
            if (_drag_from_detected >= 0 && _drag_from_detected != drag_idx) {
                reorder_detected (_drag_from_detected, drag_idx);
            }
            _drag_from_detected = -1;
            return true;
        });
        expander.add_controller (drop_target);

        // ── Include/exclude via enable-switch ────────────────────────────────
        expander.set_show_enable_switch (true);
        expander.set_enable_expansion (!stream.marked_remove);

        // Bind expansion state → marked_remove
        expander.notify["enable-expansion"].connect (() => {
            stream.marked_remove = !expander.get_enable_expansion ();
            update_ui_state ();
        });

        // ── Language ─────────────────────────────────────────────────────────
        var lang_row = new Adw.ActionRow ();
        lang_row.set_title ("Language");
        lang_row.set_subtitle ("ISO 639 code (e.g. eng, spa, jpn, fre)");
        var lang_entry = new Entry ();
        lang_entry.set_text (stream.language);
        lang_entry.set_placeholder_text ("eng");
        lang_entry.set_width_chars (8);
        lang_entry.set_valign (Align.CENTER);
        lang_entry.changed.connect (() => {
            stream.language = lang_entry.get_text ().strip ();
        });
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
        title_entry.changed.connect (() => {
            stream.title = title_entry.get_text ().strip ();
        });
        title_row.add_suffix (title_entry);
        expander.add_row (title_row);

        // ── Default flag ─────────────────────────────────────────────────────
        var default_row = new Adw.ActionRow ();
        default_row.set_title ("Default");
        default_row.set_subtitle ("Automatically selected when the video plays");
        var default_sw = new Switch ();
        default_sw.set_active (stream.is_default);
        default_sw.set_valign (Align.CENTER);
        default_sw.notify["active"].connect (() => {
            if (_updating_defaults) return;
            if (default_sw.active) {
                _updating_defaults = true;
                clear_all_defaults ();
                stream.is_default = true;
                rebuild_detected_group ();
                rebuild_add_group ();
                _updating_defaults = false;
            } else {
                stream.is_default = false;
            }
        });
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
        forced_sw.notify["active"].connect (() => {
            stream.is_forced = forced_sw.active;
        });
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
        up_btn.clicked.connect (() => move_detected (stream, -1));
        move_box.append (up_btn);

        var down_btn = new Button.from_icon_name ("go-down-symbolic");
        down_btn.add_css_class ("flat");
        down_btn.set_tooltip_text ("Move down");
        down_btn.clicked.connect (() => move_detected (stream, 1));
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
        extract_track_combo = new DropDown (new StringList ({ "No tracks available" }), null);
        extract_track_combo.set_valign (Align.CENTER);
        extract_track_combo.set_sensitive (false);
        track_row.add_suffix (extract_track_combo);
        group.add (track_row);

        // Format selector
        var fmt_row = new Adw.ActionRow ();
        fmt_row.set_title ("Output Format");
        fmt_row.set_subtitle ("Target subtitle file format");
        extract_format_combo = new DropDown (new StringList (
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

        string basename = Path.get_basename (ext.file_path);
        expander.set_title (basename);
        expander.set_subtitle (ext.language.length > 0 ? ext.language : "no language set");
        expander.add_prefix (make_icon ("document-new-symbolic"));

        // ── Drag-and-drop reorder ────────────────────────────────────────────
        var drag_source = new DragSource ();
        drag_source.set_actions (Gdk.DragAction.MOVE);
        int drag_idx = index;
        drag_source.prepare.connect ((x, y) => {
            _drag_from_added = drag_idx;
            _drag_from_detected = -1;
            var val = Value (typeof (string));
            val.set_string ("added");
            return new Gdk.ContentProvider.for_value (val);
        });
        drag_source.drag_begin.connect ((source, drag) => {
            var paintable = new WidgetPaintable (expander);
            source.set_icon (paintable, 0, 0);
        });
        expander.add_controller (drag_source);

        var drop_target = new DropTarget (typeof (string), Gdk.DragAction.MOVE);
        drop_target.drop.connect ((value, x, y) => {
            if (_drag_from_added >= 0 && _drag_from_added != drag_idx) {
                reorder_added (_drag_from_added, drag_idx);
            }
            _drag_from_added = -1;
            return true;
        });
        expander.add_controller (drop_target);

        // Remove button
        var rm_btn = new Button.from_icon_name ("user-trash-symbolic");
        rm_btn.add_css_class ("flat");
        rm_btn.add_css_class ("error");
        rm_btn.set_valign (Align.CENTER);
        rm_btn.set_tooltip_text ("Remove this subtitle");
        int idx = index;
        rm_btn.clicked.connect (() => {
            if (idx >= 0 && idx < added_subtitles.length) {
                added_subtitles.remove_index (idx);
                rebuild_add_group ();
                rebuild_burn_track_combo ();
                update_ui_state ();
            }
        });
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
        lang_entry.changed.connect (() => {
            ext.language = lang_entry.get_text ().strip ();
            expander.set_subtitle (
                ext.language.length > 0 ? ext.language : "no language set"
            );
        });
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
        title_entry.changed.connect (() => {
            ext.title = title_entry.get_text ().strip ();
        });
        title_row.add_suffix (title_entry);
        expander.add_row (title_row);

        // ── Default flag ─────────────────────────────────────────────────────
        var default_row = new Adw.ActionRow ();
        default_row.set_title ("Default");
        default_row.set_subtitle ("Automatically selected when the video plays");
        var default_sw = new Switch ();
        default_sw.set_active (ext.is_default);
        default_sw.set_valign (Align.CENTER);
        default_sw.notify["active"].connect (() => {
            if (_updating_defaults) return;
            if (default_sw.active) {
                _updating_defaults = true;
                clear_all_defaults ();
                ext.is_default = true;
                rebuild_detected_group ();
                rebuild_add_group ();
                _updating_defaults = false;
            } else {
                ext.is_default = false;
            }
        });
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
        forced_sw.notify["active"].connect (() => {
            ext.is_forced = forced_sw.active;
        });
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
        bitmap_sw.notify["active"].connect (() => {
            ext.is_bitmap = bitmap_sw.active;
        });
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
        int up_idx = index;
        up_btn.clicked.connect (() => move_added (up_idx, -1));
        move_box.append (up_btn);

        var down_btn = new Button.from_icon_name ("go-down-symbolic");
        down_btn.add_css_class ("flat");
        down_btn.set_tooltip_text ("Move down");
        int down_idx = index;
        down_btn.clicked.connect (() => move_added (down_idx, 1));
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
        mode_combo = new DropDown (new StringList (
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
        container_combo = new DropDown (new StringList (
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
        burn_track_combo = new DropDown (new StringList ({ "No tracks available" }), null);
        burn_track_combo.set_valign (Align.CENTER);
        burn_track_combo.set_sensitive (false);
        track_row.add_suffix (burn_track_combo);
        burn_in_group.add (track_row);

        // Codec selector
        var codec_row = new Adw.ActionRow ();
        codec_row.set_title ("Video Codec");
        codec_row.set_subtitle ("Encoding settings are taken from the selected codec tab");
        burn_codec_combo = new DropDown (new StringList (
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
            "This will re-encode the entire video using the codec and General tab settings — " +
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
        mode_combo.notify["selected"].connect (() => {
            general_tab_context_changed ();
        });
        burn_codec_combo.notify["selected"].connect (() => {
            general_tab_context_changed ();
        });

        runner.operation_done.connect ((path) => {
            _is_busy = false;
            update_ui_state ();
            subtitle_done (path);
        });

        runner.operation_failed.connect ((msg) => {
            _is_busy = false;
            update_ui_state ();
        });

        runner.apply_done.connect ((operation_id, path) => {
            if (active_apply_operation_id != operation_id) {
                return;
            }

            _is_busy = false;
            active_apply_operation_id = 0;
            update_ui_state ();
            subtitle_done (path);
            subtitle_apply_succeeded (operation_id, path);
        });

        runner.apply_failed.connect ((operation_id, msg) => {
            if (active_apply_operation_id != operation_id) {
                return;
            }

            _is_busy = false;
            active_apply_operation_id = 0;
            update_ui_state ();
            subtitle_apply_failed (operation_id);
        });
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PUBLIC API — Called by AppController when input file changes
    // ═════════════════════════════════════════════════════════════════════════

    public void load_video (string file_path) {
        current_input_file = file_path;

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
        runner.cancel ();
        _is_busy = false;
        active_apply_operation_id = 0;
        update_ui_state ();
    }

    public bool is_busy () {
        return _is_busy;
    }

    public void set_ui_refs (StatusArea status_area, ConsoleTab console) {
        runner.status_label = status_area.status_label;
        runner.progress_bar = status_area.progress_bar;
        runner.console_tab  = console;
        _status_label = status_area.status_label;
    }

    private Label? _status_label = null;

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
                    string path = file.get_path ();
                    _is_busy = true;
                    update_ui_state ();
                    runner.extract_subtitle (current_input_file, stream, path);
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

                _is_busy = true;
                update_ui_state ();
                runner.extract_all_subtitles (
                    current_input_file, dir_path, name_no_ext, detected_streams);
            } catch (Error e) {
                // User cancelled
            }
        });
    }

    /**
     * Update the compatibility info row based on the selected container.
     */
    private void update_container_compat_info () {
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

        container_combo.set_sensitive (true);
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
                    s.language   = guess_language (path);
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

    public BaseCodecTab? get_general_tab_sync_owner () {
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

    public bool can_apply () {
        if (current_input_file.length == 0) return false;
        if (_is_busy) return false;

        if (is_burn_in_mode ()) {
            // Burn-in needs at least one track to burn
            return burn_track_combo.get_sensitive ();
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

    public bool start_apply (uint64 operation_id, bool allow_overwrite = false) {
        if (current_input_file == "") return false;

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

        _is_busy = true;
        update_ui_state ();
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

        ICodecBuilder builder = codec_tab.get_codec_builder ();
        GeneralSettingsSnapshot general_settings = general_tab.snapshot_settings ();
        EncodeProfileSnapshot profile = CodecUtils.snapshot_encode_profile (
            builder, codec_tab, general_settings);

        _is_busy = true;
        update_ui_state ();

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
        if (_status_label != null)
            _status_label.set_text (@"⚠️ $message");
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

    /** Drag-and-drop: move a detected stream from one position to another. */
    private void reorder_detected (int from, int to) {
        if (from == to) return;
        if (from < 0 || from >= detected_streams.length) return;
        if (to   < 0 || to   >= detected_streams.length) return;

        var stream = detected_streams[from];
        if (from < to) {
            for (int i = from; i < to; i++)
                detected_streams[i] = detected_streams[i + 1];
        } else {
            for (int i = from; i > to; i--)
                detected_streams[i] = detected_streams[i - 1];
        }
        detected_streams[to] = stream;

        rebuild_detected_group ();
        rebuild_extract_combo ();
        rebuild_burn_track_combo ();
    }

    /** Drag-and-drop: move an added subtitle from one position to another. */
    private void reorder_added (int from, int to) {
        if (from == to) return;
        if (from < 0 || from >= added_subtitles.length) return;
        if (to   < 0 || to   >= added_subtitles.length) return;

        var ext = added_subtitles[from];
        if (from < to) {
            for (int i = from; i < to; i++)
                added_subtitles[i] = added_subtitles[i + 1];
        } else {
            for (int i = from; i > to; i--)
                added_subtitles[i] = added_subtitles[i - 1];
        }
        added_subtitles[to] = ext;

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

    // ═════════════════════════════════════════════════════════════════════════
    //  EXTRACT COMBO
    // ═════════════════════════════════════════════════════════════════════════

    private void rebuild_extract_combo () {
        if (detected_streams.length == 0) {
            extract_track_combo.set_model (new StringList ({ "No tracks available" }));
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

        extract_track_combo.set_model (new StringList (labels));
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
            burn_track_combo.set_model (new StringList ({ "No tracks available" }));
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
            burn_track_combo.set_model (new StringList ({ "No tracks available" }));
            burn_track_combo.set_sensitive (false);
            return;
        }

        burn_track_combo.set_model (new StringList (labels));
        burn_track_combo.set_selected (0);
        burn_track_combo.set_sensitive (true);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI STATE
    // ═════════════════════════════════════════════════════════════════════════

    private void update_ui_state () {
        bool has_file    = (current_input_file.length > 0);
        bool has_streams = (detected_streams.length > 0);

        extract_button.set_sensitive (has_file && has_streams && !_is_busy);
        extract_all_button.set_sensitive (has_file && has_streams && !_is_busy);

        // Burn-in widgets
        burn_codec_combo.set_sensitive (!_is_busy);

        // Refresh compat info in case the input file changed (affects "Source")
        if (container_compat_row != null)
            update_container_compat_info ();
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

    /**
     * Guess language from filename patterns:
     *   movie.eng.srt → eng
     *   movie_en.srt  → en
     *   movie-jpn.srt → jpn
     */
    private string guess_language (string path) {
        string bn = Path.get_basename (path);
        int dot = bn.last_index_of_char ('.');
        if (dot <= 0) return "und";
        string stem = bn.substring (0, dot);

        // Dot-separated: movie.eng.srt
        int pd = stem.last_index_of_char ('.');
        if (pd >= 0 && pd < stem.length - 1) {
            string m = stem.substring (pd + 1).down ();
            if (m.length >= 2 && m.length <= 3) return m;
        }

        // Underscore/hyphen: movie_eng.srt
        int sep = int.max (stem.last_index_of_char ('_'), stem.last_index_of_char ('-'));
        if (sep >= 0 && sep < stem.length - 1) {
            string m = stem.substring (sep + 1).down ();
            if (m.length >= 2 && m.length <= 3) return m;
        }

        return "und";
    }

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
}
