using Gtk;
using Adw;

public class HamburgerMenu {

    private Gtk.MenuButton menu_button;
    private Gtk.Window parent_window;
    private GLib.SimpleAction view_input_action;
    private GLib.SimpleAction view_output_action;
    private GLib.SimpleAction open_output_folder_action;
    private FilePickers file_pickers;
    private string last_output_file = "";
    private string last_output_folder = "";

    public HamburgerMenu (Gtk.Window parent_window, FilePickers file_pickers) {
        this.parent_window = parent_window;
        this.file_pickers = file_pickers;

        // ── Playback submenu ─────────────────────────────────────────────────
        var playback_menu = new GLib.Menu ();
        playback_menu.append ("View Input Video", "app.view-input");
        playback_menu.append ("View Output Video", "app.view-output");
        playback_menu.append ("Show Output in File Manager", "app.open-output-folder");

        // ── Top-level menu ───────────────────────────────────────────────────
        var quit_section = new GLib.Menu ();
        quit_section.append ("Quit", "app.quit");

        var menu_model = new GLib.Menu ();
        menu_model.append_submenu ("Playback", playback_menu);
        menu_model.append ("Combine Videos\u2026", "app.combine-videos");
        menu_model.append ("Preferences", "app.preferences");
        menu_model.append ("About FFmpeg Converter GTK", "app.about");
        menu_model.append_section (null, quit_section);

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
            about_action.activate.connect (on_about_action_activate);
            app.add_action (about_action);
        }

        // Quit — triggers close_request so the in-progress operation guard works
        if (app.lookup_action ("quit") == null) {
            var quit_action = new GLib.SimpleAction ("quit", null);
            quit_action.activate.connect (on_quit_action_activate);
            app.add_action (quit_action);
        }

        // Preferences
        if (app.lookup_action ("preferences") == null) {
            var prefs_action = new GLib.SimpleAction ("preferences", null);
            prefs_action.activate.connect (on_preferences_action_activate);
            app.add_action (prefs_action);
        }

        // View Input Video
        if (app.lookup_action ("view-input") == null) {
            view_input_action = new GLib.SimpleAction ("view-input", null);
            view_input_action.set_enabled (false);
            view_input_action.activate.connect (on_view_input_action_activate);
            app.add_action (view_input_action);
        } else {
            view_input_action = (GLib.SimpleAction) app.lookup_action ("view-input");
        }

        // View Output Video
        if (app.lookup_action ("view-output") == null) {
            view_output_action = new GLib.SimpleAction ("view-output", null);
            view_output_action.set_enabled (false);
            view_output_action.activate.connect (on_view_output_action_activate);
            app.add_action (view_output_action);
        } else {
            view_output_action = (GLib.SimpleAction) app.lookup_action ("view-output");
        }

        // Show Output in File Manager
        if (app.lookup_action ("open-output-folder") == null) {
            open_output_folder_action = new GLib.SimpleAction ("open-output-folder", null);
            open_output_folder_action.set_enabled (false);
            open_output_folder_action.activate.connect (on_open_output_folder_action_activate);
            app.add_action (open_output_folder_action);
        } else {
            open_output_folder_action = (GLib.SimpleAction) app.lookup_action ("open-output-folder");
        }

        // ── Track input file changes to enable/disable action ────────────────
        file_pickers.input_entry.changed.connect (on_input_entry_changed);
    }

    public void set_last_output_result (OperationOutputResult output_result) {
        last_output_file = output_result.prefers_folder_action ()
            ? ""
            : output_result.primary_file_path;
        last_output_folder = output_result.get_open_folder_target ();

        bool file_exists = last_output_file.length > 0
            && FileUtils.test (last_output_file, FileTest.EXISTS);
        bool folder_exists = last_output_folder.length > 0
            && FileUtils.test (last_output_folder, FileTest.IS_DIR);

        view_output_action.set_enabled (file_exists);
        open_output_folder_action.set_enabled (folder_exists);
    }

    public Gtk.MenuButton get_button () {
        return menu_button;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    private static void open_with_default_player (string path) {
        if (path.length == 0) return;

        var settings = AppSettings.get_default ();
        string ffplay = settings.ffplay_path;
        string? resolved = ffplay.contains ("/")
            ? ffplay : Environment.find_program_in_path (ffplay);
        var route = PlaybackLauncherLogic.resolve_route (
            settings.play_with_ffplay, ffplay, resolved);
        if (settings.play_with_ffplay && route
                == PlaybackLauncherLogic.Route.DESKTOP_DEFAULT) {
            warning ("ffplay playback requested but '%s' is not on PATH — "
                + "falling back to the default player", ffplay);
        }
        if (route == PlaybackLauncherLogic.Route.FFPLAY
                && launch_in_ffplay (path, ffplay)) {
            return;
        }

        try {
            var file = File.new_for_path (path);
            AppInfo.launch_default_for_uri (file.get_uri (), null);
        } catch (Error e) {
            warning ("Failed to open video: %s", e.message);
        }
    }

    /**
     * Play @path in ffplay. Returns false if it could not be started, so the
     * caller can fall back to the desktop handler rather than leaving the user
     * with a menu item that silently does nothing — ffplay is a separate
     * package from ffmpeg on several distros and may simply be absent.
     *
     * Spawned detached: ffplay owns its own window and must outlive the
     * calling context, and its exit is not something to report on.
     */
    private static bool launch_in_ffplay (string path, string ffplay) {
        try {
            Pid pid;
            Process.spawn_async (
                null,
                PlaybackLauncherLogic.build_ffplay_argv (ffplay, path),
                null,
                SpawnFlags.SEARCH_PATH | SpawnFlags.STDOUT_TO_DEV_NULL
                    | SpawnFlags.STDERR_TO_DEV_NULL | SpawnFlags.DO_NOT_REAP_CHILD,
                null,
                out pid);
            // DO_NOT_REAP_CHILD without a watch would leave a zombie.
            ChildWatch.add (pid, (child_pid, status) => {
                Process.close_pid (child_pid);
            });
            return true;
        } catch (SpawnError e) {
            warning ("Failed to launch ffplay (%s) — falling back to the "
                + "default player", e.message);
            return false;
        }
    }

    private static void open_in_file_manager (string path) {
        if (path.length == 0) return;
        string target = FileUtils.test (path, FileTest.IS_DIR)
            ? path
            : Path.get_dirname (path);
        if (target.length == 0 || !FileUtils.test (target, FileTest.IS_DIR)) return;

        try {
            var folder = File.new_for_path (target);
            AppInfo.launch_default_for_uri (folder.get_uri (), null);
        } catch (Error e) {
            warning ("Failed to open file manager: %s", e.message);
        }
    }

    private void on_about_action_activate (GLib.Variant? parameter) {
        AboutDialog.show_about (parent_window);
    }

    private void on_quit_action_activate (GLib.Variant? parameter) {
        parent_window.close ();
    }

    private void on_preferences_action_activate (GLib.Variant? parameter) {
        var dialog = new SettingsDialog ();
        dialog.present (parent_window);
    }

    private void on_view_input_action_activate (GLib.Variant? parameter) {
        open_with_default_player (file_pickers.input_entry.get_text ());
    }

    private void on_view_output_action_activate (GLib.Variant? parameter) {
        open_with_default_player (last_output_file);
    }

    private void on_open_output_folder_action_activate (GLib.Variant? parameter) {
        open_in_file_manager (last_output_folder);
    }

    private void on_input_entry_changed () {
        string path = file_pickers.input_entry.get_text ();
        view_input_action.set_enabled (
            path.length > 0 && FileUtils.test (path, FileTest.EXISTS));
    }
}
