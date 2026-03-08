using Gtk;
using Adw;

public class HamburgerMenu {

    private Gtk.MenuButton menu_button;
    private GLib.SimpleAction view_input_action;
    private GLib.SimpleAction view_output_action;
    private GLib.SimpleAction open_output_folder_action;
    private FilePickers file_pickers;
    private string last_output_file = "";

    public HamburgerMenu (Gtk.Window parent_window, FilePickers file_pickers) {
        this.file_pickers = file_pickers;

        // ── Playback submenu ─────────────────────────────────────────────────
        var playback_menu = new GLib.Menu ();
        playback_menu.append ("View Input Video", "app.view-input");
        playback_menu.append ("View Output Video", "app.view-output");
        playback_menu.append ("Show Output in File Manager", "app.open-output-folder");

        // ── Top-level menu ───────────────────────────────────────────────────
        var menu_model = new GLib.Menu ();
        menu_model.append_submenu ("Playback", playback_menu);
        menu_model.append ("Preferences", "app.preferences");
        menu_model.append ("About FFmpeg Converter GTK", "app.about");

        // Create the menu button with the hamburger icon
        menu_button = new Gtk.MenuButton ();
        menu_button.set_icon_name ("open-menu-symbolic");
        menu_button.set_menu_model (menu_model);
        menu_button.set_tooltip_text ("Menu");

        // ── Register actions ─────────────────────────────────────────────────
        var app = parent_window.get_application ();

        // About (unchanged)
        if (app.lookup_action ("about") == null) {
            var about_action = new GLib.SimpleAction ("about", null);
            about_action.activate.connect (() => {
                AboutDialog.show_about (parent_window);
            });
            app.add_action (about_action);
        }

        // Preferences
        if (app.lookup_action ("preferences") == null) {
            var prefs_action = new GLib.SimpleAction ("preferences", null);
            prefs_action.activate.connect (() => {
                var dialog = new SettingsDialog ();
                dialog.present (parent_window);
            });
            app.add_action (prefs_action);
        }

        // View Input Video
        if (app.lookup_action ("view-input") == null) {
            view_input_action = new GLib.SimpleAction ("view-input", null);
            view_input_action.set_enabled (false);
            view_input_action.activate.connect (() => {
                open_with_default_player (file_pickers.input_entry.get_text ());
            });
            app.add_action (view_input_action);
        } else {
            view_input_action = (GLib.SimpleAction) app.lookup_action ("view-input");
        }

        // View Output Video
        if (app.lookup_action ("view-output") == null) {
            view_output_action = new GLib.SimpleAction ("view-output", null);
            view_output_action.set_enabled (false);
            view_output_action.activate.connect (() => {
                open_with_default_player (last_output_file);
            });
            app.add_action (view_output_action);
        } else {
            view_output_action = (GLib.SimpleAction) app.lookup_action ("view-output");
        }

        // Show Output in File Manager
        if (app.lookup_action ("open-output-folder") == null) {
            open_output_folder_action = new GLib.SimpleAction ("open-output-folder", null);
            open_output_folder_action.set_enabled (false);
            open_output_folder_action.activate.connect (() => {
                open_in_file_manager (last_output_file);
            });
            app.add_action (open_output_folder_action);
        } else {
            open_output_folder_action = (GLib.SimpleAction) app.lookup_action ("open-output-folder");
        }

        // ── Track input file changes to enable/disable action ────────────────
        file_pickers.input_entry.changed.connect (() => {
            string path = file_pickers.input_entry.get_text ();
            view_input_action.set_enabled (
                path.length > 0 && FileUtils.test (path, FileTest.EXISTS));
        });
    }

    /**
     * Call this after a successful conversion or trim export so the
     * "View Output Video" action knows which file to open.
     */
    public void set_last_output_file (string path) {
        last_output_file = path;
        bool exists = path.length > 0 && FileUtils.test (path, FileTest.EXISTS);
        view_output_action.set_enabled (exists);
        open_output_folder_action.set_enabled (exists);
    }

    public Gtk.MenuButton get_button () {
        return menu_button;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    private static void open_with_default_player (string path) {
        if (path.length == 0) return;
        try {
            var file = File.new_for_path (path);
            AppInfo.launch_default_for_uri (file.get_uri (), null);
        } catch (Error e) {
            warning ("Failed to open video: %s", e.message);
        }
    }

    /**
     * Open the parent directory of @path in the system file manager.
     */
    private static void open_in_file_manager (string path) {
        if (path.length == 0) return;
        string parent = Path.get_dirname (path);
        if (parent.length == 0 || !FileUtils.test (parent, FileTest.IS_DIR)) return;

        try {
            var folder = File.new_for_path (parent);
            AppInfo.launch_default_for_uri (folder.get_uri (), null);
        } catch (Error e) {
            warning ("Failed to open file manager: %s", e.message);
        }
    }
}
