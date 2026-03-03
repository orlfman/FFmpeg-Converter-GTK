using Gtk;
using Adw;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  SubtitlesTab — Manage subtitle streams in a video file
//
//  Features:
//   • Auto-detect subtitle tracks when an input file is loaded
//   • Extract any subtitle track to a standalone file (.srt, .ass, .vtt, .sub)
//   • Add external subtitle files with language, title, default/forced metadata
//   • Remove unwanted subtitle tracks via per-track include/exclude switches
//   • Reorder subtitle tracks (move up / move down)
//   • Set default and forced disposition flags per track
//   • Apply all changes via lossless remux (no video/audio re-encoding)
//
//  Architecture:
//   Follows the same patterns as GeneralTab and TrimTab:
//   • Adw.PreferencesGroup sections for organized layout
//   • Background thread probing via SubtitlesRunner
//   • Thread-safe UI updates via Idle.add
//   • Emits subtitle_done signal for AppController coordination
// ═══════════════════════════════════════════════════════════════════════════════

public class SubtitlesTab : Box {

    // ── Signals ──────────────────────────────────────────────────────────────
    public signal void subtitle_done (string output_path);

    // ── Runner ───────────────────────────────────────────────────────────────
    private SubtitlesRunner runner = new SubtitlesRunner ();

    // External reference — set by MainWindow after construction
    public FilePickers? file_pickers { get; set; default = null; }

    // ── State ────────────────────────────────────────────────────────────────
    private string current_input_file = "";
    private GenericArray<SubtitleStream>   detected_streams = new GenericArray<SubtitleStream> ();
    private GenericArray<ExternalSubtitle> added_subtitles  = new GenericArray<ExternalSubtitle> ();
    private bool _is_busy = false;

    // ── Dynamic sections (rebuilt when data changes) ─────────────────────────
    private Box detected_section;
    private Box add_section;

    // ── Static widgets (built once, survive full lifetime) ───────────────────
    private DropDown extract_track_combo;
    private DropDown extract_format_combo;
    private Button   extract_button;
    private DropDown container_combo;
    private Adw.ActionRow container_compat_row;
    private Button   apply_button;

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

        // 4. Apply (built once)
        build_apply_group ();

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
                group.add (build_detected_row (detected_streams[i]));
            }
        }

        detected_section.append (group);
    }

    private Adw.ExpanderRow build_detected_row (SubtitleStream stream) {
        var expander = new Adw.ExpanderRow ();

        // Title: "#0  ·  subrip  ·  eng"
        string codec = stream.codec_name.length > 0 ? stream.codec_name : "unknown";
        string lang  = (stream.language.length > 0 && stream.language != "und")
            ? stream.language : "no language";
        expander.set_title (@"Track #$(stream.sub_index)  ·  $(codec)  ·  $(lang)");

        if (stream.title.length > 0)
            expander.set_subtitle (stream.title);

        expander.add_prefix (make_icon ("media-view-subtitles-symbolic"));

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
            stream.is_default = default_sw.active;
            if (default_sw.active) {
                // Only one track should be default — clear all others
                clear_all_defaults ();
                stream.is_default = true;
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
            ext.is_default = default_sw.active;
            if (default_sw.active) {
                clear_all_defaults ();
                ext.is_default = true;
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
    //  4. APPLY CHANGES (static — built once)
    // ═════════════════════════════════════════════════════════════════════════

    private void build_apply_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Apply Changes");
        group.set_description (
            "Remux the video with your subtitle modifications — video and audio stay untouched (fast, no re-encoding)"
        );

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

        // Apply button
        var apply_row = new Adw.ActionRow ();
        apply_row.set_title ("Apply Subtitle Changes");
        apply_row.set_subtitle ("Write the output file with all modifications");
        apply_button = new Button.with_label ("Apply");
        apply_button.add_css_class ("suggested-action");
        apply_button.set_valign (Align.CENTER);
        apply_button.set_sensitive (false);
        apply_row.add_suffix (apply_button);
        apply_row.set_activatable_widget (apply_button);
        group.add (apply_row);

        append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SIGNAL WIRING (runs once at construction for static widgets)
    // ═════════════════════════════════════════════════════════════════════════

    private void connect_signals () {
        extract_button.clicked.connect (on_extract_clicked);
        apply_button.clicked.connect (on_apply_clicked);

        runner.operation_done.connect ((path) => {
            _is_busy = false;
            update_ui_state ();
            subtitle_done (path);
        });

        runner.operation_failed.connect ((msg) => {
            _is_busy = false;
            update_ui_state ();
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
                update_ui_state ();
                return Source.REMOVE;
            });
        });
    }

    public void cancel_operation () {
        runner.cancel ();
        _is_busy = false;
        update_ui_state ();
    }

    public bool is_busy () {
        return _is_busy;
    }

    public void set_ui_refs (Label status, ProgressBar bar, ConsoleTab console) {
        runner.status_label = status;
        runner.progress_bar = bar;
        runner.console_tab  = console;
    }

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

        string codec = detected_streams[(int) selected].codec_name.down ();

        if (codec == "subrip" || codec == "srt")              return ".srt";
        if (codec == "ass" || codec == "ssa")                  return ".ass";
        if (codec == "webvtt")                                 return ".vtt";
        if (codec == "mov_text")                               return ".srt";
        if (codec == "hdmv_pgs_subtitle" || codec == "pgssub") return ".sup";
        if (codec == "dvd_subtitle" || codec == "dvdsub")      return ".sub";
        if (codec == "dvb_subtitle" || codec == "dvbsub")      return ".sub";

        return ".srt";  // safe fallback
    }

    /**
     * Update the compatibility info row based on the selected container.
     */
    private void update_container_compat_info () {
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
                    added_subtitles.add (s);
                }

                rebuild_add_group ();
                update_ui_state ();
            } catch (Error e) {
                // User cancelled
            }
        });
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  APPLY HANDLER
    // ═════════════════════════════════════════════════════════════════════════

    private void on_apply_clicked () {
        if (current_input_file == "") return;

        string basename = Path.get_basename (current_input_file);
        int dot = basename.last_index_of_char ('.');
        string name = (dot > 0) ? basename.substring (0, dot) : basename;

        // Use the output folder if set, otherwise fall back to input file's directory
        string dir = Path.get_dirname (current_input_file);
        if (file_pickers != null) {
            string out_dir = file_pickers.output_entry.get_text ().strip ();
            if (out_dir.length > 0)
                dir = out_dir;
        }

        string ext = get_output_extension ();
        string output = find_unique (Path.build_filename (dir, name + "-subs" + ext));

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
        runner.remux_subtitles (current_input_file, output, detected_streams, added_subtitles, order);
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
    }

    private void move_added (int index, int dir) {
        int n = index + dir;
        if (n < 0 || n >= added_subtitles.length) return;

        var tmp = added_subtitles[index];
        added_subtitles[index] = added_subtitles[n];
        added_subtitles[n] = tmp;

        rebuild_add_group ();
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
            string lbl = @"#$(i) — $(c)";
            if (l.length > 0)       lbl += @" ($(l))";
            if (s.title.length > 0) lbl += @" — $(s.title)";
            labels += lbl;
        }

        extract_track_combo.set_model (new StringList (labels));
        extract_track_combo.set_selected (0);
        extract_track_combo.set_sensitive (true);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI STATE
    // ═════════════════════════════════════════════════════════════════════════

    private void update_ui_state () {
        bool has_file    = (current_input_file.length > 0);
        bool has_streams = (detected_streams.length > 0);
        bool has_added   = (added_subtitles.length > 0);
        bool actionable  = has_streams || has_added;

        extract_button.set_sensitive (has_file && has_streams && !_is_busy);
        apply_button.set_sensitive   (has_file && actionable  && !_is_busy);

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
