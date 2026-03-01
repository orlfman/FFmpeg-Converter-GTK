using Gtk;
using Adw;

public class HamburgerMenu {

    private Gtk.MenuButton menu_button;
    private GLib.SimpleAction view_input_action;
    private GLib.SimpleAction view_output_action;
    private FilePickers file_pickers;
    private string last_output_file = "";

    public HamburgerMenu (Gtk.Window parent_window, FilePickers file_pickers) {
        this.file_pickers = file_pickers;

        // ── Playback submenu ─────────────────────────────────────────────────
        var playback_menu = new GLib.Menu ();
        playback_menu.append ("View Input Video", "app.view-input");
        playback_menu.append ("View Output Video", "app.view-output");

        // ── Top-level menu ───────────────────────────────────────────────────
        var menu_model = new GLib.Menu ();
        menu_model.append_submenu ("Playback", playback_menu);
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

        // View Input Video
        view_input_action = new GLib.SimpleAction ("view-input", null);
        view_input_action.set_enabled (false);
        view_input_action.activate.connect (() => {
            open_with_default_player (file_pickers.input_entry.get_text ());
        });
        app.add_action (view_input_action);

        // View Output Video
        view_output_action = new GLib.SimpleAction ("view-output", null);
        view_output_action.set_enabled (false);
        view_output_action.activate.connect (() => {
            open_with_default_player (last_output_file);
        });
        app.add_action (view_output_action);

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
        view_output_action.set_enabled (
            path.length > 0 && FileUtils.test (path, FileTest.EXISTS));
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
}
