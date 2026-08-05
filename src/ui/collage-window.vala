using Gtk;
using Adw;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  CollageWindow — Standalone window for building a collage from any video
//
//  Preferences already offers a "<name>-collage.png" sidecar written after each
//  encode. This window exposes the same 4-4-4 collage for a file the user picks
//  directly, so an existing video can get one without being re-encoded. The
//  image is always written beside its source: the source folder is the output
//  folder, and the main window's output picker is deliberately not consulted.
// ═══════════════════════════════════════════════════════════════════════════════

public class CollageWindow : Adw.Window {

    // ── Emitted when the window is going away, so MainWindow drops its ref ──
    public signal void window_closing ();

    private ConsoleTab? main_console_tab;

    private Adw.PreferencesGroup source_group;
    private Button browse_button;
    private PathBreadcrumb source_entry;
    private ulong settings_handler_id = 0;
    private Adw.ActionRow output_row;
    private Button generate_button;
    private Button cancel_button;
    private Label status_label;

    private CollageRunner? active_runner = null;
    private bool generating = false;

    public CollageWindow (ConsoleTab? console_tab, Gtk.Window? parent_window = null) {
        Object ();
        this.main_console_tab = console_tab;

        set_title ("Generate Collage");
        set_default_size (620, 300);
        if (parent_window != null) {
            set_transient_for (parent_window);
        }

        build_ui ();
        update_output_preview ();
        update_generate_sensitivity ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI CONSTRUCTION
    // ═════════════════════════════════════════════════════════════════════════

    private void build_ui () {
        var toolbar_view = new Adw.ToolbarView ();
        toolbar_view.add_top_bar (new Adw.HeaderBar ());

        var content = new Box (Orientation.VERTICAL, 12);
        content.set_margin_top (12);
        content.set_margin_bottom (12);
        content.set_margin_start (12);
        content.set_margin_end (12);

        // ── Source group ────────────────────────────────────────────────────
        source_group = new Adw.PreferencesGroup ();
        source_group.set_title ("Source");
        refresh_size_description ();

        // The size lives in Preferences so the sidecar and this window cannot
        // disagree. Track changes rather than snapshotting at construction —
        // this window is long-lived and Preferences can be edited behind it.
        settings_handler_id = AppSettings.get_default ().settings_changed.connect (() => {
            refresh_size_description ();
        });

        source_entry = new PathBreadcrumb ("No file selected", true);
        source_entry.changed.connect (() => {
            update_output_preview ();
            update_generate_sensitivity ();
        });

        browse_button = new Button.from_icon_name ("document-open-symbolic");
        browse_button.set_tooltip_text ("Select a video file");
        browse_button.add_css_class ("flat");
        browse_button.set_valign (Align.CENTER);
        browse_button.clicked.connect (on_browse_clicked);

        source_group.add (build_file_row (
            "video-x-generic-symbolic",
            "Video File",
            source_entry,
            browse_button
        ));
        content.append (source_group);

        // ── Output group ────────────────────────────────────────────────────
        var output_group = new Adw.PreferencesGroup ();
        output_group.set_title ("Output");

        output_row = new Adw.ActionRow ();
        output_row.set_title ("Saved beside the source file");
        output_row.set_subtitle_selectable (true);
        output_group.add (output_row);
        content.append (output_group);

        setup_drag_drop (content);

        // ── Action area ─────────────────────────────────────────────────────
        var action_box = new Box (Orientation.HORIZONTAL, 8);
        action_box.set_halign (Align.END);
        action_box.set_margin_top (8);

        cancel_button = new Button.with_label ("Cancel");
        cancel_button.add_css_class ("destructive-action");
        cancel_button.set_visible (false);
        cancel_button.clicked.connect (on_cancel_clicked);

        generate_button = new Button.with_label ("Generate");
        generate_button.add_css_class ("suggested-action");
        generate_button.clicked.connect (on_generate_clicked);

        action_box.append (cancel_button);
        action_box.append (generate_button);
        content.append (action_box);

        status_label = new Label ("");
        status_label.set_wrap (true);
        status_label.set_xalign (0);
        status_label.set_selectable (true);
        status_label.set_visible (false);
        content.append (status_label);

        toolbar_view.set_content (content);
        set_content (toolbar_view);

        close_request.connect (on_close_request);
    }

    private Box build_file_row (string icon_name,
                                string title,
                                Widget path_widget,
                                Widget browse_button) {
        var row = new Box (Orientation.HORIZONTAL, 6);
        row.set_margin_start (12);
        row.set_margin_end (12);
        row.set_margin_top (2);
        row.set_margin_bottom (2);

        var icon = new Image.from_icon_name (icon_name);
        icon.set_valign (Align.CENTER);
        row.append (icon);

        var title_label = new Label (title);
        title_label.set_xalign (0.0f);
        title_label.add_css_class ("heading");
        title_label.set_valign (Align.CENTER);
        row.append (title_label);

        path_widget.set_hexpand (true);
        row.append (path_widget);

        browse_button.set_valign (Align.CENTER);
        browse_button.add_css_class ("circular");
        row.append (browse_button);

        return row;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  FILE SELECTION
    // ═════════════════════════════════════════════════════════════════════════

    private void on_browse_clicked () {
        var dialog = new FileDialog ();
        dialog.title = "Select Video File";

        var filter = new FileFilter ();
        filter.name = "Video Files";
        filter.add_mime_type ("video/*");
        dialog.default_filter = filter;

        string current = source_entry.get_text ();
        if (current.length > 0) {
            string dir = Path.get_dirname (current);
            if (FileUtils.test (dir, FileTest.IS_DIR)) {
                dialog.set_initial_folder (File.new_for_path (dir));
            }
        }

        dialog.open.begin (this, null, (obj, res) => {
            try {
                var file = dialog.open.end (res);
                if (file != null) {
                    set_source_path (file.get_path () ?? "");
                }
            } catch (Error e) {
                // Dismissing the picker raises DISMISSED — not worth reporting.
            }
        });
    }

    private void setup_drag_drop (Widget target) {
        var file_drop = new DropTarget (typeof (File), Gdk.DragAction.COPY);
        file_drop.drop.connect ((val, x, y) => {
            if (generating) return false;

            var file = val.get_object () as File;
            if (file == null) return false;

            string? path = file.get_path ();
            if (path == null || !is_video_file (path)) return false;

            set_source_path (path);
            return true;
        });
        target.add_controller (file_drop);

        var text_drop = new DropTarget (Type.STRING, Gdk.DragAction.COPY);
        text_drop.drop.connect ((val, x, y) => {
            if (generating) return false;

            string? text = val.get_string ();
            if (text == null) return false;

            // Dropping a selection hands over a newline-separated list. This
            // window takes one file, so read the first entry rather than
            // testing the whole blob — which passes has_suffix and would set a
            // multi-line string as the path.
            string line = text.strip ().split ("\n")[0].strip ();
            if (line.has_suffix ("\r"))
                line = line.substring (0, line.length - 1);

            string path = line.has_prefix ("file://")
                ? (File.new_for_uri (line).get_path () ?? "")
                : line;
            if (path.length == 0 || !is_video_file (path)) return false;

            set_source_path (path);
            return true;
        });
        target.add_controller (text_drop);
    }

    private void set_source_path (string path) {
        source_entry.set_text (path);
        set_status ("");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  OUTPUT PREVIEW
    // ═════════════════════════════════════════════════════════════════════════

    private void refresh_size_description () {
        CollageSize size = AppSettings.get_default ().collage_size;
        source_group.set_description (
            "Twelve frames from 8%% to 96%% of the video, tiled into one 4×3 PNG — %s. Change the size in Preferences → General.".printf (
                size.get_description ())
        );
    }

    private void update_output_preview () {
        string source = source_entry.get_text ();
        if (source.length == 0) {
            output_row.set_subtitle ("Select a video file to see where it lands.");
            return;
        }

        // resolve_ rather than build_ so the preview shows the numbered name the
        // run will actually pick when overwriting is off and the file is there.
        string? target = ConversionUtils.resolve_collage_output_path (source);
        output_row.set_subtitle (
            (target != null && target.length > 0)
                ? target
                : ConversionUtils.build_collage_output_path (source)
        );
    }

    private void update_generate_sensitivity () {
        string source = source_entry.get_text ();
        bool ready = !generating
            && source.length > 0
            && FileUtils.test (source, FileTest.IS_REGULAR);
        generate_button.set_sensitive (ready);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  GENERATION
    // ═════════════════════════════════════════════════════════════════════════

    private void on_generate_clicked () {
        if (generating) return;

        // Re-checked here rather than trusted from selection time: the file can
        // be moved or deleted while the window sits open, and the breadcrumb
        // does not re-emit for an unchanged path.
        string source = source_entry.get_text ();
        if (source.length == 0) {
            set_status ("Select a video file first.");
            update_generate_sensitivity ();
            return;
        }
        if (!FileUtils.test (source, FileTest.IS_REGULAR)) {
            set_status (@"That file is no longer there:\n$source");
            update_generate_sensitivity ();
            return;
        }

        set_generating (true);
        set_status ("Starting…");

        active_runner = new CollageRunner ();
        active_runner.console_tab = main_console_tab;
        active_runner.collage_progress.connect (on_runner_progress);
        active_runner.collage_done.connect (on_runner_done);
        active_runner.collage_failed.connect (on_runner_failed);
        active_runner.collage_cancelled.connect (on_runner_cancelled);
        active_runner.run (source);
    }

    /**
     * Stop an in-flight collage from outside the window. Staying out of the
     * single-operation model means MainWindow will happily close while a
     * collage runs, and nothing reaps the FFmpeg child when the process exits —
     * so MainWindow calls this on its way out.
     */
    public void cancel_active_collage () {
        if (active_runner != null) {
            active_runner.cancel ();
        }
    }

    public bool is_generating () {
        return generating;
    }

    private void on_cancel_clicked () {
        if (active_runner != null) {
            cancel_button.set_sensitive (false);
            set_status ("Cancelling…");
            active_runner.cancel ();
        }
    }

    private void on_runner_progress (string message) {
        set_status (message);
    }

    private void on_runner_done (OperationOutputResult output_result) {
        finish_run ();
        set_status (@"Collage created.\n\n$(output_result.primary_file_path)");
        // Report the file that exists rather than re-predicting. Refreshing the
        // preview here would roll the row forward to the next numbered name —
        // a path that does not exist yet — while the status names a different
        // one. The prediction returns as soon as the source changes.
        output_row.set_title ("Saved beside the source file");
        output_row.set_subtitle (output_result.primary_file_path);
    }

    private void on_runner_failed (string message) {
        finish_run ();
        set_status (message);
    }

    private void on_runner_cancelled (string cancel_message) {
        finish_run ();
        set_status (@"Collage cancelled.\n$cancel_message");
    }

    private void finish_run () {
        active_runner = null;
        set_generating (false);
    }

    private void set_generating (bool value) {
        generating = value;
        // The run captured its own source path, so letting the picker change
        // underneath it would leave the window describing one file while the
        // result reports another. Drops are already refused while generating.
        browse_button.set_sensitive (!value);
        cancel_button.set_visible (value);
        cancel_button.set_sensitive (value);
        generate_button.set_visible (!value);
        update_generate_sensitivity ();
    }

    private void set_status (string message) {
        status_label.set_text (message);
        status_label.set_visible (message.length > 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CLOSE REQUEST — Prevent orphaned FFmpeg processes
    // ═════════════════════════════════════════════════════════════════════════

    private bool on_close_request () {
        if (generating) {
            var dialog = new Adw.AlertDialog (
                "Collage in Progress",
                "A collage is currently being generated. Cancel it before "
                + "closing this window."
            );
            dialog.add_response ("ok", "OK");
            dialog.set_default_response ("ok");
            dialog.set_close_response ("ok");
            dialog.present (this);
            return true;  // Block the close
        }

        // AppSettings is a singleton that outlives this window, so leaving the
        // handler connected would strand the window in its signal list.
        if (settings_handler_id != 0) {
            AppSettings.get_default ().disconnect (settings_handler_id);
            settings_handler_id = 0;
        }

        window_closing ();
        return false;
    }

    private static bool is_video_file (string path) {
        string lower = path.down ();
        foreach (unowned string ext in VideoFileConstants.VIDEO_EXTENSIONS) {
            if (lower.has_suffix (ext)) return true;
        }
        return false;
    }

#if COMBINE_WINDOW_TEST_BUILD
    internal bool is_browse_enabled_for_widget_test () {
        return browse_button.get_sensitive ();
    }

    internal void set_generating_for_widget_test (bool value) {
        set_generating (value);
    }

    internal string get_output_subtitle_for_widget_test () {
        return output_row.get_subtitle () ?? "";
    }

    internal void set_source_path_for_widget_test (string path) {
        set_source_path (path);
    }

    internal bool is_generate_enabled_for_widget_test () {
        return generate_button.get_sensitive ();
    }

    internal string get_output_preview_for_widget_test () {
        return output_row.get_subtitle () ?? "";
    }
#endif
}
