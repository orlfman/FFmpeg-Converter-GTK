using Gtk;
using Adw;

public class FilePickers : Box {
    public PathBreadcrumb input_entry { get; private set; }
    public PathBreadcrumb output_entry { get; private set; }

    private Adw.PreferencesGroup file_group;
    private Box input_row;
    private Box output_row;
    private SizeGroup label_size_group;

    // Known video file extensions for validating text/URI drops
    private const string[] VIDEO_EXTENSIONS = {
        ".mp4", ".mkv", ".webm", ".avi", ".mov", ".flv", ".wmv",
        ".m4v", ".ts", ".mts", ".m2ts", ".vob", ".mpg", ".mpeg",
        ".3gp", ".ogv", ".rm", ".rmvb", ".asf", ".divx", ".f4v",
        ".y4m", ".ivf"
    };

    public FilePickers () {
        Object (orientation: Orientation.VERTICAL, spacing: 0);

        file_group = new Adw.PreferencesGroup ();
        file_group.set_title ("Files");
        label_size_group = new SizeGroup (SizeGroupMode.HORIZONTAL);

        // ── Input File row ───────────────────────────────────────────────────
        input_entry = new PathBreadcrumb ("No file selected", true);

        var input_browse = new Button.from_icon_name ("document-open-symbolic");
        input_browse.set_tooltip_text ("Select a file");
        input_browse.add_css_class ("flat");
        input_browse.set_valign (Align.CENTER);
        input_browse.clicked.connect (on_input_browse_clicked);

        input_row = build_file_row (
            "video-x-generic-symbolic",
            "Input File",
            input_entry,
            input_browse
        );

        file_group.add (input_row);

        // ── Output Folder row ────────────────────────────────────────────────
        output_entry = new PathBreadcrumb ("Same as input");

        var output_browse = new Button.from_icon_name ("folder-open-symbolic");
        output_browse.set_tooltip_text ("Output location");
        output_browse.add_css_class ("flat");
        output_browse.set_valign (Align.CENTER);
        output_browse.clicked.connect (on_output_browse_clicked);

        output_row = build_file_row (
            "folder-symbolic",
            "Output Folder",
            output_entry,
            output_browse
        );

        file_group.add (output_row);
        append (file_group);

        // Pre-populate from settings if a default output directory is configured
        string default_dir = AppSettings.get_default ().default_output_dir;
        if (default_dir.length > 0 && FileUtils.test (default_dir, FileTest.IS_DIR)) {
            output_entry.set_text (default_dir);
        }

        // Only explicit "apply default output directory" actions in
        // Preferences should push a new value into the main window.
        AppSettings.get_default ().default_output_dir_applied.connect ((dir) => {
            if (dir.length > 0 && FileUtils.test (dir, FileTest.IS_DIR)) {
                output_entry.set_text (dir);
            } else if (dir.length == 0) {
                output_entry.set_text ("");
            }
        });

        // === Drag and Drop ===
        setup_drag_drop ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  DRAG & DROP
    //
    //  Drop targets are attached to the entire FilePickers widget for a
    //  generous drop zone.  Visual feedback highlights the whole preferences
    //  group — not just the entry — so the user gets a clear, prominent
    //  "you can drop here" indicator with a dashed accent outline.
    // ═════════════════════════════════════════════════════════════════════════

    private void setup_drag_drop () {
        // Accept GLib.File drops (from file managers)
        var file_drop = new DropTarget (typeof (File), Gdk.DragAction.COPY);

        file_drop.accept.connect ((drop) => {
            return true;
        });

        file_drop.enter.connect ((x, y) => {
            show_drop_highlight ();
            return Gdk.DragAction.COPY;
        });

        file_drop.leave.connect (() => {
            hide_drop_highlight ();
        });

        file_drop.drop.connect ((val, x, y) => {
            hide_drop_highlight ();

            var file = val.get_object () as File;
            if (file == null) return false;

            string? path = file.get_path ();
            if (path == null) return false;

            if (is_video_file (path)) {
                input_entry.set_text (path);
                return true;
            }

            return false;
        });

        add_controller (file_drop);

        // Also accept plain text URI drops (from some terminals / apps)
        var text_drop = new DropTarget (Type.STRING, Gdk.DragAction.COPY);

        text_drop.enter.connect ((x, y) => {
            show_drop_highlight ();
            return Gdk.DragAction.COPY;
        });

        text_drop.leave.connect (() => {
            hide_drop_highlight ();
        });

        text_drop.drop.connect ((val, x, y) => {
            hide_drop_highlight ();

            string? text = val.get_string ();
            if (text == null) return false;

            string path = resolve_dropped_text (text);
            if (path.length > 0 && is_video_file (path)) {
                input_entry.set_text (path);
                return true;
            }

            return false;
        });

        add_controller (text_drop);

        inject_drop_css ();
    }

    private Box build_file_row (string icon_name,
                                string title,
                                Widget path_widget,
                                Widget browse_button) {
        var row = new Box (Orientation.HORIZONTAL, 6);
        row.add_css_class ("file-picker-row");
        row.set_margin_start (12);
        row.set_margin_end (12);
        row.set_margin_top (2);
        row.set_margin_bottom (2);

        var icon = new Image.from_icon_name (icon_name);
        icon.set_valign (Align.CENTER);
        row.append (icon);

        var label_box = new Box (Orientation.VERTICAL, 0);
        label_box.set_valign (Align.CENTER);
        label_size_group.add_widget (label_box);

        var title_label = new Label (title);
        title_label.set_xalign (0.0f);
        title_label.add_css_class ("heading");
        label_box.append (title_label);

        row.append (label_box);

        path_widget.set_hexpand (true);
        row.append (path_widget);

        browse_button.set_valign (Align.CENTER);
        row.append (browse_button);

        return row;
    }

    // ── Drop highlight — covers the whole preferences group card ─────────

    private void show_drop_highlight () {
        add_css_class ("drop-active");
        input_entry.add_css_class ("drop-highlight");
    }

    private void hide_drop_highlight () {
        remove_css_class ("drop-active");
        input_entry.remove_css_class ("drop-highlight");
    }

    /**
     * Resolve a dropped text payload into a local file path.
     * Handles file:// URIs, newline-separated URI lists, and plain paths.
     */
    private static string resolve_dropped_text (string text) {
        string trimmed = text.strip ();
        if (trimmed.length == 0) return "";

        string first_line = trimmed.split ("\n")[0].strip ();
        if (first_line.has_suffix ("\r"))
            first_line = first_line.substring (0, first_line.length - 1);

        if (first_line.has_prefix ("file://")) {
            var gfile = File.new_for_uri (first_line);
            return gfile.get_path () ?? "";
        }

        if (first_line.has_prefix ("/")) {
            return first_line;
        }

        return "";
    }

    /**
     * Quick extension-based check for video files.
     */
    private static bool is_video_file (string path) {
        string lower = path.down ();
        foreach (unowned string ext in VIDEO_EXTENSIONS) {
            if (lower.has_suffix (ext)) return true;
        }
        return false;
    }

    private static bool drop_css_injected = false;

    /**
     * Inject CSS for visual drop-highlight effects.
     *
     * Two-level feedback:
     *  1. The breadcrumb itself gets an accent border + glow
     *  2. The entire FilePickers box gets a dashed accent outline + tint
     */
    private static void inject_drop_css () {
        if (drop_css_injected) return;
        drop_css_injected = true;

        var css = new CssProvider ();
        css.load_from_string (
            ".path-breadcrumb {\n" +
            "    border-radius: 9999px;\n" +
            "    padding: 2px 6px;\n" +
            "    background: alpha(currentColor, 0.04);\n" +
            "}\n" +
            ".file-picker-row {\n" +
            "    min-height: 34px;\n" +
            "}\n" +
            ".file-picker-row > image {\n" +
            "    opacity: 0.85;\n" +
            "}\n" +
            ".path-breadcrumb.drop-highlight {\n" +
            "    box-shadow: 0 0 0 2px alpha(@accent_color, 0.35);\n" +
            "    background: alpha(@accent_color, 0.09);\n" +
            "}\n" +
            ".path-breadcrumb .path-crumb {\n" +
            "    min-height: 24px;\n" +
            "    padding: 1px 7px;\n" +
            "    border-radius: 9999px;\n" +
            "}\n" +
            ".path-breadcrumb .path-overflow {\n" +
            "    min-width: 24px;\n" +
            "    padding-left: 4px;\n" +
            "    padding-right: 4px;\n" +
            "}\n" +
            ".path-breadcrumb .path-crumb.path-current {\n" +
            "    background: alpha(@accent_color, 0.12);\n" +
            "    color: @accent_color;\n" +
            "    font-weight: 600;\n" +
            "}\n" +
            ".path-breadcrumb .path-crumb.path-file {\n" +
            "    background: alpha(currentColor, 0.06);\n" +
            "}\n" +
            ".drop-active {\n" +
            "    outline: 2px dashed @accent_color;\n" +
            "    outline-offset: 4px;\n" +
            "    border-radius: 12px;\n" +
            "    transition: outline 150ms ease;\n" +
            "}\n"
        );
        StyleContext.add_provider_for_display (
            Gdk.Display.get_default (),
            css,
            STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  BROWSE DIALOGS
    // ═════════════════════════════════════════════════════════════════════════

    private void on_input_browse_clicked () {
        var dialog = new FileDialog ();
        dialog.title = "Select Input Video";

        var filter = new FileFilter ();
        filter.name = "Video Files";
        filter.add_mime_type ("video/*");
        dialog.default_filter = filter;

        dialog.open.begin ((Gtk.Window) get_root (), null, (obj, res) => {
            try {
                var file = dialog.open.end (res);
                if (file != null) input_entry.set_text (file.get_path () ?? "");
            } catch (Error e) {
                if (!(e is Gtk.DialogError.DISMISSED)) {
                    warning ("Input file dialog error: %s", e.message);
                }
            }
        });
    }

    private void on_output_browse_clicked () {
        var dialog = new FileDialog ();
        dialog.title = "Select Output Folder";

        dialog.select_folder.begin ((Gtk.Window) get_root (), null, (obj, res) => {
            try {
                var folder = dialog.select_folder.end (res);
                if (folder != null) output_entry.set_text (folder.get_path () ?? "");
            } catch (Error e) {
                if (!(e is Gtk.DialogError.DISMISSED)) {
                    warning ("Output folder dialog error: %s", e.message);
                }
            }
        });
    }
}
