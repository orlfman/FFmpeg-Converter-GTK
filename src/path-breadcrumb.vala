using Gtk;
using GLib;

public class PathBreadcrumb : Box {
    public signal void changed ();

    private const int MAX_VISIBLE_CRUMBS = 4;

    private string current_path = "";
    private string placeholder_text;
    private bool treat_last_as_file;

    private Box crumb_box;
    private Label placeholder_label;
    private PopoverMenu path_menu;
    private GLib.Menu path_menu_model;
    private SimpleActionGroup action_group;
    private SimpleAction copy_path_action;
    private SimpleAction open_path_action;
    private SimpleAction reveal_path_action;

    private class Crumb : Object {
        public string label { get; construct set; }
        public string path { get; construct set; }
        public bool clickable { get; construct set; }

        public Crumb (string label, string path, bool clickable) {
            Object (label: label, path: path, clickable: clickable);
        }
    }

    public PathBreadcrumb (string placeholder_text, bool treat_last_as_file = false) {
        Object (orientation: Orientation.HORIZONTAL, spacing: 0);

        this.placeholder_text = placeholder_text;
        this.treat_last_as_file = treat_last_as_file;

        add_css_class ("path-breadcrumb");
        set_hexpand (true);
        set_valign (Align.CENTER);
        set_tooltip_text (placeholder_text);

        crumb_box = new Box (Orientation.HORIZONTAL, 0);
        crumb_box.set_hexpand (true);
        crumb_box.set_valign (Align.CENTER);
        append (crumb_box);

        placeholder_label = new Label (placeholder_text);
        placeholder_label.set_xalign (0.0f);
        placeholder_label.set_ellipsize (Pango.EllipsizeMode.END);
        placeholder_label.add_css_class ("dim-label");

        setup_actions ();
        setup_context_menu ();
        rebuild ();
    }

    public string get_text () {
        return current_path;
    }

    public void set_text (string path) {
        string normalized = path.strip ();
        if (normalized == current_path) return;

        current_path = normalized;
        set_tooltip_text (current_path.length > 0 ? current_path : placeholder_text);
        rebuild ();
        changed ();
    }

    public void set_placeholder_text (string text) {
        placeholder_text = text;
        if (current_path.length == 0) {
            set_tooltip_text (placeholder_text);
            rebuild ();
        }
    }

    private void rebuild () {
        clear_box (crumb_box);

        if (current_path.length == 0) {
            crumb_box.append (placeholder_label);
            return;
        }

        Crumb[] crumbs = build_crumb_model ();
        int count = crumbs.length;
        if (count == 0) {
            crumb_box.append (placeholder_label);
            return;
        }

        bool[] visible = {};
        for (int i = 0; i < count; i++) visible += true;

        if (count > MAX_VISIBLE_CRUMBS) {
            for (int i = 1; i < count - 2; i++) visible[i] = false;
        }

        bool ellipsis_inserted = false;
        bool needs_separator = false;
        for (int i = 0; i < count; i++) {
            if (!visible[i]) {
                if (!ellipsis_inserted) {
                    if (needs_separator) append_separator ();
                    crumb_box.append (build_hidden_menu (crumbs, count));
                    ellipsis_inserted = true;
                    needs_separator = true;
                }
                continue;
            }

            if (needs_separator) append_separator ();
            crumb_box.append (build_crumb_widget (crumbs[i], i == count - 1));
            needs_separator = true;
        }
    }

    private Crumb[] build_crumb_model () {
        Crumb[] crumbs = {};
        string path = current_path;
        bool path_is_dir = FileUtils.test (path, FileTest.IS_DIR);
        bool show_leaf_as_file = treat_last_as_file && !path_is_dir;

        string home = Environment.get_home_dir ();
        bool under_home = home != null && home.length > 1 &&
                          (path == home || path.has_prefix (home + "/"));

        string[] parts = {};
        string remainder = path;

        if (under_home) {
            crumbs += new Crumb ("Home", home, true);

            remainder = path.substring (home.length);
            if (remainder.has_prefix ("/")) {
                remainder = remainder.substring (1);
            }
        } else if (path.has_prefix ("/")) {
            crumbs += new Crumb ("/", "/", true);

            remainder = path.substring (1);
        }

        if (remainder.length > 0) {
            foreach (string raw in remainder.split ("/")) {
                if (raw.length > 0) parts += raw;
            }
        }

        string cursor = under_home ? home : (path.has_prefix ("/") ? "/" : "");

        for (int i = 0; i < parts.length; i++) {
            string part = parts[i];
            if (cursor == "" || cursor == "/") {
                cursor += part;
            } else {
                cursor = Path.build_filename (cursor, part);
            }

            bool is_last = (i == parts.length - 1);
            bool crumb_clickable = !(show_leaf_as_file && is_last);

            crumbs += new Crumb (part, cursor, crumb_clickable);
        }

        return crumbs;
    }

    private Widget build_crumb_widget (Crumb crumb,
                                       bool is_last) {
        if (!crumb.clickable) {
            var file_button = new Button ();
            file_button.add_css_class ("flat");
            file_button.add_css_class ("path-crumb");
            file_button.add_css_class ("path-file");
            file_button.set_focus_on_click (false);
            file_button.set_tooltip_text (crumb.path);
            file_button.clicked.connect (() => {
                reveal_in_file_manager.begin (crumb.path);
            });

            var file_chip = new Box (Orientation.HORIZONTAL, 6);

            var icon = new Image.from_icon_name ("video-x-generic-symbolic");
            icon.set_icon_size (IconSize.INHERIT);
            file_chip.append (icon);

            var text = new Label (crumb.label);
            text.set_ellipsize (Pango.EllipsizeMode.MIDDLE);
            text.set_xalign (0.0f);
            text.set_hexpand (true);
            text.set_max_width_chars (42);
            file_chip.append (text);

            file_button.set_child (file_chip);
            return file_button;
        }

        var button = new Button.with_label (crumb.label);
        button.add_css_class ("flat");
        button.add_css_class ("path-crumb");
        if (is_last) button.add_css_class ("path-current");
        button.set_focus_on_click (false);
        button.set_tooltip_text (crumb.path);
        button.set_valign (Align.CENTER);
        button.clicked.connect (() => {
            open_path (crumb.path);
        });
        return button;
    }

    private Widget build_hidden_menu (Crumb[] crumbs, int count) {
        var menu_button = new MenuButton ();
        menu_button.set_icon_name ("view-more-symbolic");
        menu_button.add_css_class ("flat");
        menu_button.add_css_class ("path-crumb");
        menu_button.add_css_class ("path-overflow");
        menu_button.set_tooltip_text ("Show hidden path segments");

        var popover = new Popover ();
        var box = new Box (Orientation.VERTICAL, 0);
        box.set_margin_top (6);
        box.set_margin_bottom (6);
        box.set_margin_start (6);
        box.set_margin_end (6);

        for (int i = 1; i < count - 2; i++) {
            if (!crumbs[i].clickable) continue;

            var row = new Button.with_label (crumbs[i].label);
            row.add_css_class ("flat");
            row.set_halign (Align.FILL);
            row.set_tooltip_text (crumbs[i].path);
            string target_path = crumbs[i].path;
            row.clicked.connect (() => {
                popover.popdown ();
                open_path (target_path);
            });
            box.append (row);
        }

        popover.set_child (box);
        menu_button.set_popover (popover);
        return menu_button;
    }

    private void append_separator () {
        var sep = new Image.from_icon_name ("go-next-symbolic");
        sep.add_css_class ("dim-label");
        sep.set_margin_start (2);
        sep.set_margin_end (2);
        crumb_box.append (sep);
    }

    private static void clear_box (Box box) {
        Widget? child = box.get_first_child ();
        while (child != null) {
            Widget? next = child.get_next_sibling ();
            box.remove (child);
            child = next;
        }
    }

    private static void open_path (string path) {
        if (path.length == 0) return;

        try {
            var file = File.new_for_path (path);
            AppInfo.launch_default_for_uri (file.get_uri (), null);
        } catch (Error e) {
            warning ("Failed to open path: %s", e.message);
        }
    }

    private void setup_actions () {
        action_group = new SimpleActionGroup ();

        copy_path_action = new SimpleAction ("copy-path", null);
        copy_path_action.activate.connect (() => {
            if (current_path.length == 0) return;
            var clipboard = lookup_clipboard ();
            if (clipboard != null) clipboard.set_text (current_path);
        });
        action_group.add_action (copy_path_action);

        open_path_action = new SimpleAction ("open-path", null);
        open_path_action.activate.connect (() => {
            open_path (current_path);
        });
        action_group.add_action (open_path_action);

        reveal_path_action = new SimpleAction ("reveal-path", null);
        reveal_path_action.activate.connect (() => {
            reveal_in_file_manager.begin (current_path);
        });
        action_group.add_action (reveal_path_action);

        insert_action_group ("crumb", action_group);
    }

    private void setup_context_menu () {
        path_menu_model = new GLib.Menu ();
        path_menu_model.append ("Copy Path", "crumb.copy-path");
        path_menu_model.append ("Open", "crumb.open-path");
        path_menu_model.append ("Reveal in File Manager", "crumb.reveal-path");

        path_menu = new PopoverMenu.from_model (path_menu_model);
        path_menu.set_has_arrow (false);
        path_menu.set_parent (this);

        var right_click = new GestureClick ();
        right_click.set_button (Gdk.BUTTON_SECONDARY);
        right_click.pressed.connect ((n_press, x, y) => {
            if (current_path.length == 0) return;
            update_action_sensitivity ();

            var rect = Gdk.Rectangle ();
            rect.x = (int) x;
            rect.y = (int) y;
            rect.width = 1;
            rect.height = 1;
            path_menu.set_pointing_to (rect);
            path_menu.popup ();
        });
        add_controller (right_click);
    }

    private void update_action_sensitivity () {
        bool has_path = current_path.length > 0;
        bool exists = has_path && FileUtils.test (current_path, FileTest.EXISTS);
        bool is_file = exists && FileUtils.test (current_path, FileTest.IS_REGULAR);

        copy_path_action.set_enabled (has_path);
        open_path_action.set_enabled (exists);
        reveal_path_action.set_enabled (exists && (is_file || FileUtils.test (current_path, FileTest.IS_DIR)));
    }

    private Gdk.Clipboard? lookup_clipboard () {
        var display = Gdk.Display.get_default ();
        return display != null ? display.get_clipboard () : null;
    }

    private static async void reveal_in_file_manager (string path) {
        if (path.length == 0) return;

        try {
            var file = File.new_for_path (path);
            var uri = file.get_uri ();

            var proxy = new DBusProxy.for_bus_sync (
                BusType.SESSION,
                DBusProxyFlags.NONE,
                null,
                "org.freedesktop.FileManager1",
                "/org/freedesktop/FileManager1",
                "org.freedesktop.FileManager1",
                null
            );
            string[] uris = { uri };
            yield proxy.call (
                "ShowItems",
                new Variant.tuple ({
                    new Variant.strv (uris),
                    new Variant.string ("")
                }),
                DBusCallFlags.NONE,
                -1,
                null
            );
            return;
        } catch (Error e) {
            // Fall back to opening the containing folder when item reveal is unavailable.
        }

        try {
            var file = File.new_for_path (path);
            var target = file.query_file_type (FileQueryInfoFlags.NONE, null) == FileType.DIRECTORY
                ? file
                : file.get_parent ();
            if (target != null) {
                AppInfo.launch_default_for_uri (target.get_uri (), null);
            }
        } catch (Error e) {
            warning ("Failed to reveal path: %s", e.message);
        }
    }
}
