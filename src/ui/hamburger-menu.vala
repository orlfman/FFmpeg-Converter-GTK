using Gtk;
using Adw;

public class HamburgerMenu {

    private Gtk.MenuButton menu_button;
    private Gtk.Window parent_window;
    private GLib.SimpleAction view_input_action;
    private GLib.SimpleAction view_output_action;
    private GLib.SimpleAction open_output_folder_action;
    private GLib.SimpleAction clear_recent_inputs_action;
    private FilePickers file_pickers;
    private GLib.Menu menu_model;
    private GLib.Menu playback_menu;
    private GLib.Menu recent_inputs_menu;
    private GLib.Menu quit_section;
    private GenericArray<GLib.FileMonitor> recent_input_monitors =
        new GenericArray<GLib.FileMonitor> ();
    private GenericArray<Gtk.Button> recent_input_menu_buttons =
        new GenericArray<Gtk.Button> ();
    private string[] recent_input_paths = {};
    private bool recent_submenu_enabled = false;
    private uint recent_refresh_idle_id = 0;
    private string last_output_file = "";
    private bool bulk_inputs_available = false;
    private bool bulk_outputs_available = false;
    public signal void bulk_playback_requested (bool output);

    public void set_bulk_playback_available (bool inputs, bool outputs) {
        bulk_inputs_available = inputs;
        bulk_outputs_available = outputs;
        update_playback_actions ();
    }
    private void update_playback_actions () {
        bool folder = file_pickers.kind == InputSourceKind.FOLDER;
        view_input_action.set_enabled (folder ? bulk_inputs_available
            : file_pickers.kind == InputSourceKind.FILE
                && FileUtils.test (file_pickers.source_path, FileTest.IS_REGULAR));
        view_output_action.set_enabled (folder ? bulk_outputs_available
            : file_pickers.kind == InputSourceKind.RESOLVING ? false
            : last_output_file.length > 0 && FileUtils.test (last_output_file, FileTest.IS_REGULAR));
    }
    private string last_output_folder = "";

    public HamburgerMenu (Gtk.Window parent_window, FilePickers file_pickers) {
        this.parent_window = parent_window;
        this.file_pickers = file_pickers;

        // ── Playback submenu ─────────────────────────────────────────────────
        playback_menu = new GLib.Menu ();
        playback_menu.append ("View Input Video", "app.view-input");
        playback_menu.append ("View Output Video", "app.view-output");
        playback_menu.append ("Show Output in File Manager", "app.open-output-folder");

        // ── Top-level menu ───────────────────────────────────────────────────
        quit_section = new GLib.Menu ();
        quit_section.append ("Quit", "app.quit");

        menu_model = new GLib.Menu ();
        recent_inputs_menu = new GLib.Menu ();
        initialize_recent_inputs_menu_model ();

        // Create the menu button with the hamburger icon
        menu_button = new Gtk.MenuButton ();
        menu_button.set_icon_name ("open-menu-symbolic");
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

        if (app.lookup_action ("clear-recent-inputs") == null) {
            clear_recent_inputs_action = new GLib.SimpleAction (
                "clear-recent-inputs", null);
            clear_recent_inputs_action.activate.connect (
                on_clear_recent_inputs_action_activate);
            app.add_action (clear_recent_inputs_action);
        } else {
            clear_recent_inputs_action = (GLib.SimpleAction)
                app.lookup_action ("clear-recent-inputs");
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
        file_pickers.input_selection_changed.connect (on_input_entry_changed);

        // Prune locations deleted since the last opening immediately before the
        // menu is shown, then update the stable file/folder button slots.
        menu_button.notify["active"].connect (() => {
            if (menu_button.get_active ())
                refresh_recent_inputs_menu ();
        });

        AppSettings.get_default ().settings_changed.connect (() => {
            if (recent_submenu_enabled
                    != AppSettings.get_default ().recently_opened_enabled) {
                rebuild_top_level_menu ();
            }
            refresh_recent_inputs_menu ();
        });

        rebuild_top_level_menu ();
        refresh_recent_inputs_menu ();
    }

    public void set_last_output_result (OperationOutputResult output_result) {
        last_output_file = output_result.prefers_folder_action ()
            ? ""
            : output_result.primary_file_path;
        last_output_folder = output_result.get_open_folder_target ();

        bool folder_exists = last_output_folder.length > 0
            && FileUtils.test (last_output_folder, FileTest.IS_DIR);

        update_playback_actions ();
        open_output_folder_action.set_enabled (folder_exists);
    }

    public Gtk.MenuButton get_button () {
        return menu_button;
    }

#if COMBINE_WINDOW_TEST_BUILD
    internal Gtk.Button? get_recent_input_button_for_widget_test (int slot) {
        if (slot < 0 || slot >= recent_input_menu_buttons.length)
            return null;
        return recent_input_menu_buttons[slot];
    }
#endif

    // ═════════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    private void initialize_recent_inputs_menu_model () {
        var files_section = new GLib.Menu ();
        for (int i = 0; i < AppSettings.MAX_RECENT_INPUT_FILES; i++) {
            var item = new GLib.MenuItem (null, null);
            item.set_attribute_value (
                "custom",
                new GLib.Variant.string ("recent-input-%d".printf (i))
            );
            files_section.append_item (item);
        }
        recent_inputs_menu.append_section (null, files_section);

        var clear_section = new GLib.Menu ();
        clear_section.append ("Clear History", "app.clear-recent-inputs");
        recent_inputs_menu.append_section (null, clear_section);
    }

    private void rebuild_top_level_menu () {
        // GTK 4.22 retains destroyed custom-slot pointers when a live menu
        // model removes and recreates custom items. Keep the recent model
        // immutable, and discard the whole popover before changing whether
        // that submenu is attached to the top-level model.
        menu_button.set_menu_model (null);
        recent_input_menu_buttons = new GenericArray<Gtk.Button> ();
        menu_model.remove_all ();
        menu_model.append_submenu ("Playback", playback_menu);
        recent_submenu_enabled =
            AppSettings.get_default ().recently_opened_enabled;
        if (recent_submenu_enabled) {
            menu_model.append_submenu ("Recently Opened", recent_inputs_menu);
        }
        menu_model.append ("Combine Videos\u2026", "app.combine-videos");
        menu_model.append ("Generate Collage\u2026", "app.generate-collage");
        menu_model.append ("Preferences", "app.preferences");
        menu_model.append ("About FFmpeg Converter GTK", "app.about");
        menu_model.append_section (null, quit_section);
        menu_button.set_menu_model (menu_model);

        if (recent_submenu_enabled)
            bind_recent_input_menu_buttons ();
    }

    private void refresh_recent_inputs_menu () {
        var settings = AppSettings.get_default ();
        reset_recent_input_monitors ();

        bool enabled = settings.recently_opened_enabled;
        if (!enabled) {
            recent_input_paths = {};
            clear_recent_inputs_action.set_enabled (false);
            return;
        }

        // Keep this guard so a future popover replacement cannot leave its
        // fixed custom slots unbound before the next refresh.
        if (recent_input_menu_buttons.length == 0)
            bind_recent_input_menu_buttons ();

        settings.prune_recent_input_files ();
        string[] files = settings.recent_input_files;
        recent_input_paths = files;

        for (uint i = 0; i < recent_input_menu_buttons.length; i++) {
            var button = recent_input_menu_buttons[i];
            if (i < files.length) {
                string path = files[i];
                button.set_label (recent_input_label (path));
                button.set_tooltip_text (path);
                button.set_sensitive (true);
                button.set_visible (true);
            } else if (files.length == 0 && i == 0) {
                button.set_label ("No Recent Files or Folders");
                button.set_tooltip_text (null);
                button.set_sensitive (false);
                button.set_visible (true);
            } else {
                button.set_label ("");
                button.set_tooltip_text (null);
                button.set_sensitive (false);
                button.set_visible (false);
            }
        }

        clear_recent_inputs_action.set_enabled (files.length > 0);
        monitor_recent_inputs (files);
    }

    private void bind_recent_input_menu_buttons () {
        var popover = menu_button.get_popover () as Gtk.PopoverMenu;
        if (popover == null)
            return;

        for (int i = 0; i < AppSettings.MAX_RECENT_INPUT_FILES; i++) {
            int slot = i;
            var button = create_recent_input_button ("");
            button.set_sensitive (false);
            button.set_visible (false);
            button.clicked.connect (() => {
                activate_recent_input_slot (slot);
            });

            string custom_id = "recent-input-%d".printf (i);
            if (!popover.add_child (button, custom_id)) {
                warning ("Failed to bind recent input menu slot %s", custom_id);
            }
            recent_input_menu_buttons.add (button);
        }
    }

    private void activate_recent_input_slot (int slot) {
        if (slot < 0 || slot >= recent_input_paths.length)
            return;

        string path = recent_input_paths[slot];
        menu_button.set_active (false);
        open_recent_input_path (path);
    }

    private static string recent_input_label (string path) {
        string name = Path.get_basename (path);
        return FileUtils.test (path, FileTest.IS_DIR)
            ? "%s (Folder)".printf (name) : name;
    }

    internal static Gtk.Button create_recent_input_button (string path) {
        var button = new Gtk.Button.with_label (recent_input_label (path));
        button.set_tooltip_text (path);
        button.set_hexpand (true);
        button.set_halign (Gtk.Align.FILL);
        button.add_css_class ("flat");
        button.add_css_class ("model");
        return button;
    }

    private void reset_recent_input_monitors () {
        for (uint i = 0; i < recent_input_monitors.length; i++)
            recent_input_monitors[i].cancel ();
        recent_input_monitors = new GenericArray<GLib.FileMonitor> ();
    }

    private void monitor_recent_inputs (string[] files) {
        foreach (unowned string path in files) {
            try {
                var monitor = File.new_for_path (path).monitor_file (
                    FileMonitorFlags.WATCH_MOVES, null);
                monitor.changed.connect ((file, other_file, event_type) => {
                    if (event_type == FileMonitorEvent.DELETED
                            || event_type == FileMonitorEvent.MOVED_OUT
                            || event_type == FileMonitorEvent.RENAMED) {
                        schedule_recent_inputs_refresh ();
                    }
                });
                recent_input_monitors.add (monitor);
            } catch (Error e) {
                // Some remote or unusual filesystems cannot be monitored.
                // The menu-open prune above remains the reliable fallback.
            }
        }
    }

    private void schedule_recent_inputs_refresh () {
        if (recent_refresh_idle_id != 0)
            return;

        recent_refresh_idle_id = Idle.add (() => {
            recent_refresh_idle_id = 0;
            refresh_recent_inputs_menu ();
            return Source.REMOVE;
        });
    }

    private static void open_with_default_player (string path) {
        if (path.length == 0) return;
        try { PlaybackLauncher.launch (path); }
        catch (Error e) { warning ("Failed to open video: %s", e.message); }
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
        if (file_pickers.kind == InputSourceKind.FOLDER) {
            if (bulk_inputs_available) bulk_playback_requested (false);
        } else if (file_pickers.kind == InputSourceKind.FILE)
            open_with_default_player (file_pickers.source_path);
    }

    private void on_view_output_action_activate (GLib.Variant? parameter) {
        if (file_pickers.kind == InputSourceKind.FOLDER) {
            if (bulk_outputs_available) bulk_playback_requested (true);
        } else if (file_pickers.kind != InputSourceKind.RESOLVING) {
            open_with_default_player (last_output_file);
        }
    }

    private void on_open_output_folder_action_activate (GLib.Variant? parameter) {
        open_in_file_manager (last_output_folder);
    }

    private void open_recent_input_path (string path) {
        if (!AppSettings.get_default ().recently_opened_enabled)
            return;

        if (AppSettings.is_recent_input_location (path)) {
            file_pickers.request_input (path);
        } else {
            AppSettings.get_default ().prune_recent_input_files ();
            refresh_recent_inputs_menu ();
        }
    }

    private void on_clear_recent_inputs_action_activate (GLib.Variant? parameter) {
        AppSettings.get_default ().clear_recent_input_files ();
    }

    private void on_input_entry_changed () {
        string path = file_pickers.source_path;
        bool is_file = file_pickers.kind == InputSourceKind.FILE && path.length > 0
            && FileUtils.test (path, FileTest.IS_REGULAR);
        bool is_folder = file_pickers.kind == InputSourceKind.FOLDER && path.length > 0
            && FileUtils.test (path, FileTest.IS_DIR);
        update_playback_actions ();
        // Only accepted selections enter history. RESOLVING/INVALID and input
        // changes refused during an operation must not promote a recent item.
        if (is_file || is_folder)
            AppSettings.get_default ().record_recent_input_file (path);
    }
}
