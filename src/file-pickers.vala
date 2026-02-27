using Gtk;
using Adw;

public class FilePickers : Box {
    public Entry input_entry { get; private set; }
    public Entry output_entry { get; private set; }

    public FilePickers () {
        Object (orientation: Orientation.VERTICAL, spacing: 18);

        // === Input File ===
        var input_row = new Box (Orientation.HORIZONTAL, 12);
        var input_label = new Label ("Input File:");
        input_label.set_width_chars (12);

        input_entry = new Entry ();
        input_entry.set_placeholder_text ("No file selected");
        input_entry.set_editable (false);
        input_entry.set_hexpand (true);

        var input_browse = new Button.with_label ("Browse...");
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

        var output_browse = new Button.with_label ("Browse...");
        output_browse.clicked.connect (on_output_browse_clicked);

        output_row.append (output_label);
        output_row.append (output_entry);
        output_row.append (output_browse);
        append (output_row);
    }

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
