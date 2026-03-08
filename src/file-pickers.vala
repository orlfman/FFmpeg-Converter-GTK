using Gtk;
using Adw;

public class FilePickers : Box {
    public Entry input_entry { get; private set; }
    public Entry output_entry { get; private set; }

    private Adw.PreferencesGroup file_group;
    private Adw.ActionRow input_row;
    private Adw.ActionRow output_row;

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

        // ── Input File row ───────────────────────────────────────────────────
        input_row = new Adw.ActionRow ();
        input_row.set_title ("Input File");
        input_row.set_subtitle ("Select a video file");
        input_row.add_prefix (new Gtk.Image.from_icon_name ("video-x-generic-symbolic"));

        input_entry = new Entry ();
        input_entry.set_placeholder_text ("No file selected");
        input_entry.set_editable (false);
        input_entry.set_hexpand (true);
        input_entry.set_valign (Align.CENTER);
        input_entry.set_width_chars (48);
        input_row.add_suffix (input_entry);

        var input_browse = new Button.from_icon_name ("document-open-symbolic");
        input_browse.set_tooltip_text ("Select a file");
        input_browse.add_css_class ("flat");
        input_browse.set_valign (Align.CENTER);
        input_browse.clicked.connect (on_input_browse_clicked);
        input_row.add_suffix (input_browse);

        file_group.add (input_row);

        // ── Output Folder row ────────────────────────────────────────────────
        output_row = new Adw.ActionRow ();
        output_row.set_title ("Output Folder");
        output_row.set_subtitle ("Output location");
        output_row.add_prefix (new Gtk.Image.from_icon_name ("folder-symbolic"));

        output_entry = new Entry ();
        output_entry.set_placeholder_text ("Same as input");
        output_entry.set_editable (false);
        output_entry.set_hexpand (true);
        output_entry.set_valign (Align.CENTER);
        output_entry.set_width_chars (48);
        output_row.add_suffix (output_entry);

        var output_browse = new Button.from_icon_name ("folder-open-symbolic");
        output_browse.set_tooltip_text ("Output location");
        output_browse.add_css_class ("flat");
        output_browse.set_valign (Align.CENTER);
        output_browse.clicked.connect (on_output_browse_clicked);
        output_row.add_suffix (output_browse);

        file_group.add (output_row);
        append (file_group);

        // Pre-populate from settings if a default output directory is configured
        string default_dir = AppSettings.get_default ().default_output_dir;
        if (default_dir.length > 0 && FileUtils.test (default_dir, FileTest.IS_DIR)) {
            output_entry.set_text (default_dir);
        }

        // Update the output entry when settings change (e.g. user sets a new
        // default output directory in preferences)
        AppSettings.get_default ().settings_changed.connect (() => {
            string dir = AppSettings.get_default ().default_output_dir;
            if (dir.length > 0 && FileUtils.test (dir, FileTest.IS_DIR)) {
                output_entry.set_text (dir);
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
     *  1. The entry itself gets an accent border + glow
     *  2. The entire FilePickers box gets a dashed accent outline + tint
     */
    private static void inject_drop_css () {
        if (drop_css_injected) return;
        drop_css_injected = true;

        var css = new CssProvider ();
        css.load_from_string (
            /* Entry-level highlight */
            "entry.drop-highlight {\n" +
            "    border-color: @accent_color;\n" +
            "    box-shadow: 0 0 0 2px alpha(@accent_color, 0.35);\n" +
            "    transition: border-color 150ms ease, box-shadow 150ms ease;\n" +
            "}\n" +
            /* Widget-level highlight — dashed outline around the whole group */
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
