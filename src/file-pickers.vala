using Gtk;
using Adw;

public class FilePickers : Box {
    public Entry input_entry { get; private set; }
    public Entry output_entry { get; private set; }

    private Box input_row;

    // Known video file extensions for validating text/URI drops
    private const string[] VIDEO_EXTENSIONS = {
        ".mp4", ".mkv", ".webm", ".avi", ".mov", ".flv", ".wmv",
        ".m4v", ".ts", ".mts", ".m2ts", ".vob", ".mpg", ".mpeg",
        ".3gp", ".ogv", ".rm", ".rmvb", ".asf", ".divx", ".f4v",
        ".y4m", ".ivf"
    };

    public FilePickers () {
        Object (orientation: Orientation.VERTICAL, spacing: 18);

        // === Input File ===
        input_row = new Box (Orientation.HORIZONTAL, 12);
        var input_label = new Label ("Input File:");
        input_label.set_width_chars (12);

        input_entry = new Entry ();
        input_entry.set_placeholder_text ("Drop a video file here or click Browse…");
        input_entry.set_editable (false);
        input_entry.set_hexpand (true);

        var input_browse = new Button.with_label ("Browse…");
        input_browse.clicked.connect (on_input_browse_clicked);

        input_row.append (input_label);
        input_row.append (input_entry);
        input_row.append (input_browse);
        append (input_row);

        // === Output Folder ===
        var output_row = new Box (Orientation.HORIZONTAL, 12);
        var output_label = new Label ("Output Folder:");
        output_label.set_width_chars (12);

        output_entry = new Entry ();
        output_entry.set_placeholder_text ("No folder selected");
        output_entry.set_editable (false);
        output_entry.set_hexpand (true);

        var output_browse = new Button.with_label ("Browse…");
        output_browse.clicked.connect (on_output_browse_clicked);

        output_row.append (output_label);
        output_row.append (output_entry);
        output_row.append (output_browse);
        append (output_row);

        // === Drag & Drop ===
        setup_drag_drop ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  DRAG & DROP
    // ═════════════════════════════════════════════════════════════════════════

    private void setup_drag_drop () {
        // Accept GLib.File drops (from file managers)
        var file_drop = new DropTarget (typeof (File), Gdk.DragAction.COPY);

        file_drop.accept.connect ((drop) => {
            // Accept any drop that offers GLib.File content
            return true;
        });

        file_drop.enter.connect ((x, y) => {
            input_entry.add_css_class ("drop-highlight");
            return Gdk.DragAction.COPY;
        });

        file_drop.leave.connect (() => {
            input_entry.remove_css_class ("drop-highlight");
        });

        file_drop.drop.connect ((val, x, y) => {
            input_entry.remove_css_class ("drop-highlight");

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

        // Attach to the entire FilePickers box so the drop zone is generous
        add_controller (file_drop);

        // Also accept plain text URI drops (from some terminals / apps)
        var text_drop = new DropTarget (Type.STRING, Gdk.DragAction.COPY);

        text_drop.enter.connect ((x, y) => {
            input_entry.add_css_class ("drop-highlight");
            return Gdk.DragAction.COPY;
        });

        text_drop.leave.connect (() => {
            input_entry.remove_css_class ("drop-highlight");
        });

        text_drop.drop.connect ((val, x, y) => {
            input_entry.remove_css_class ("drop-highlight");

            string? text = val.get_string ();
            if (text == null) return false;

            // Handle file:// URIs (one or more, take the first)
            string path = resolve_dropped_text (text);
            if (path.length > 0 && is_video_file (path)) {
                input_entry.set_text (path);
                return true;
            }

            return false;
        });

        add_controller (text_drop);

        // Inject CSS for the drop highlight effect
        inject_drop_css ();
    }

    /**
     * Resolve a dropped text payload into a local file path.
     * Handles file:// URIs, newline-separated URI lists, and plain paths.
     */
    private static string resolve_dropped_text (string text) {
        string trimmed = text.strip ();
        if (trimmed.length == 0) return "";

        // Take only the first line (URI lists can be multi-line)
        string first_line = trimmed.split ("\n")[0].strip ();
        // Remove trailing \r from Windows-style line endings
        if (first_line.has_suffix ("\r"))
            first_line = first_line.substring (0, first_line.length - 1);

        // file:// URI → local path
        if (first_line.has_prefix ("file://")) {
            var gfile = File.new_for_uri (first_line);
            return gfile.get_path () ?? "";
        }

        // Already a plain path (e.g. from a terminal drag)
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
     * Inject a small CSS snippet for the visual drop-highlight on the entry.
     * Only runs once regardless of how many FilePickers are created.
     */
    private static void inject_drop_css () {
        if (drop_css_injected) return;
        drop_css_injected = true;

        var css = new CssProvider ();
        css.load_from_string (
            "entry.drop-highlight {\n" +
            "    border-color: @accent_color;\n" +
            "    box-shadow: 0 0 0 2px alpha(@accent_color, 0.35);\n" +
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
    //  BROWSE DIALOGS (unchanged)
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

            }
        });
    }
}
