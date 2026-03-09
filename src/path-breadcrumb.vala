using Gtk;
using GLib;

public class PathBreadcrumb : Box {
    public signal void changed ();

    private const int MAX_VISIBLE_CRUMBS = 6;
    private const string DEFAULT_FILE_ICON = "video-x-generic-symbolic";

    private string current_path = "";
    private string placeholder_text;
    private bool treat_last_as_file;
    private bool current_path_info_ready = false;
    private bool current_path_exists = false;
    private bool current_path_is_dir = false;
    private bool current_path_is_regular = false;
    private Icon? current_path_icon = null;
    private string[] current_path_icon_names = {};
    private uint path_state_generation = 0;
    private Cancellable? path_state_cancellable = null;

    private Box crumb_box;
    private Label placeholder_label;
    private PopoverMenu path_menu;
    private GLib.Menu path_menu_model;
    private SimpleActionGroup action_group;
    private SimpleAction copy_path_action;
    private SimpleAction open_path_action;
    private SimpleAction reveal_path_action;
    private SimpleAction open_crumb_action;

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
        placeholder_label.set_valign (Align.CENTER);
        placeholder_label.set_ellipsize (Pango.EllipsizeMode.END);
        placeholder_label.add_css_class ("dim-label");
        placeholder_label.add_css_class ("path-placeholder");

        setup_actions ();
        setup_context_menu ();
        rebuild ();
        update_action_sensitivity ();
    }

    public string get_text () {
        return current_path;
    }

    public void set_text (string path) {
        string normalized = path.strip ();
        if (normalized == current_path) return;

        cancel_path_state_refresh ();
        current_path = normalized;
        reset_path_state ();
        set_tooltip_text (current_path.length > 0 ? current_path : placeholder_text);
        rebuild ();
        update_action_sensitivity ();

        if (current_path.length > 0) {
            path_state_cancellable = new Cancellable ();
            refresh_path_state.begin (
                current_path,
                ++path_state_generation,
                path_state_cancellable
            );
        }

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

        bool ellipsis_inserted = false;
        bool needs_separator = false;
        for (int i = 0; i < count; i++) {
            if (crumb_is_hidden (i, count)) {
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
        bool show_leaf_as_file = treat_last_as_file &&
                                 current_path_info_ready &&
                                 current_path_is_regular;

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
            file_button.set_halign (Align.START);
            file_button.set_hexpand (false);
            file_button.set_focus_on_click (false);
            file_button.set_tooltip_text (crumb.path);
            file_button.clicked.connect (() => {
                reveal_in_file_manager.begin (crumb.path);
            });

            var file_chip = new Box (Orientation.HORIZONTAL, 6);
            file_chip.add_css_class ("path-file-chip");
            file_chip.set_halign (Align.START);

            var icon = build_file_icon ();
            icon.add_css_class ("path-file-icon");
            file_chip.append (icon);

            var text = new Label (crumb.label);
            text.set_ellipsize (Pango.EllipsizeMode.MIDDLE);
            text.set_xalign (0.0f);
            text.set_hexpand (false);
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
        var menu_model = new GLib.Menu ();

        for (int i = hidden_crumb_start (count); i < hidden_crumb_end (count); i++) {
            if (!crumbs[i].clickable) continue;
            var item = new MenuItem (crumbs[i].label, null);
            item.set_action_and_target_value (
                "crumb.open-crumb",
                new Variant.string (crumbs[i].path)
            );
            menu_model.append_item (item);
        }

        menu_button.set_menu_model (menu_model);
        return menu_button;
    }

    private void append_separator () {
        var sep = new Image.from_icon_name ("go-next-symbolic");
        sep.add_css_class ("dim-label");
        sep.add_css_class ("path-separator");
        sep.set_pixel_size (11);
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

    private bool crumb_is_hidden (int index, int count) {
        return index >= hidden_crumb_start (count) && index < hidden_crumb_end (count);
    }

    private int hidden_crumb_start (int count) {
        return count > MAX_VISIBLE_CRUMBS ? 1 : 0;
    }

    private int hidden_crumb_end (int count) {
        if (count <= MAX_VISIBLE_CRUMBS) return 0;

        int visible_tail = MAX_VISIBLE_CRUMBS - 2;
        return count - visible_tail;
    }

    private Image build_file_icon () {
        var image = new Image ();
        image.set_icon_size (IconSize.INHERIT);

        int pixel_size = get_file_chip_icon_pixel_size ();
        if (pixel_size > 0) image.set_pixel_size (pixel_size);

        Icon? icon = resolve_file_chip_icon ();
        if (icon != null) {
            image.set_from_gicon (icon);
            image.use_fallback = true;
        } else {
            image.set_from_icon_name (DEFAULT_FILE_ICON);
            image.use_fallback = true;
        }

        return image;
    }

    private int get_file_chip_icon_pixel_size () {
        var probe = new Image ();
        probe.set_icon_size (IconSize.INHERIT);

        int pixel_size = probe.get_pixel_size ();
        if (pixel_size > 0) return pixel_size.clamp (12, 32);

        int font_size = 16;
        var context = get_pango_context ();
        if (context != null) {
            var desc = context.get_font_description ();
            if (desc != null) {
                int size = desc.get_size ();
                if (size > 0) {
                    size /= Pango.SCALE;
                    font_size = size.clamp (12, 32);
                }
            }
        }

        return font_size.clamp (12, 32);
    }

    private Icon? resolve_file_chip_icon () {
        var themed_icon = resolve_themed_file_icon ();
        if (themed_icon != null) return themed_icon;
        return current_path_icon;
    }

    private Icon? resolve_themed_file_icon () {
        var display = get_display ();
        if (display == null) return null;

        var theme = IconTheme.get_for_display (display);
        int pixel_size = get_file_chip_icon_pixel_size ();

        foreach (string candidate in get_file_icon_candidates ()) {
            var paintable = theme.lookup_icon (
                candidate,
                null,
                pixel_size,
                get_scale_factor (),
                get_direction (),
                (IconLookupFlags) 0
            );
            if (paintable != null && theme.has_icon (candidate)) {
                return new ThemedIcon (candidate);
            }
        }

        return null;
    }

    private string[] get_file_icon_candidates () {
        string[] candidates = {};

        foreach (unowned string name in current_path_icon_names) {
            if (name.length > 0) candidates += name;
        }

        bool has_default = false;
        foreach (unowned string name in candidates) {
            if (name == DEFAULT_FILE_ICON) {
                has_default = true;
                break;
            }
        }

        if (!has_default) candidates += DEFAULT_FILE_ICON;
        return candidates;
    }

    private static string[] extract_icon_names (Icon? icon) {
        string[] names = {};

        var themed_icon = icon as ThemedIcon;
        if (themed_icon != null) {
            string[] themed_names = themed_icon.get_names ();
            foreach (string name in themed_names) {
                if (name.length > 0) names += name;
            }
            return names;
        }

        var emblemed_icon = icon as EmblemedIcon;
        if (emblemed_icon != null) {
            append_icon_names (ref names, extract_icon_names (emblemed_icon.get_icon ()));
            foreach (unowned Emblem emblem in emblemed_icon.get_emblems ()) {
                var emblem_icon = emblem.icon as Icon;
                if (emblem_icon != null) {
                    append_icon_names (ref names, extract_icon_names (emblem_icon));
                }
            }
        }

        return names;
    }

    private static void append_icon_names (ref string[] names, string[] extra_names) {
        foreach (string name in extra_names) {
            if (name.length > 0) append_icon_name (ref names, name);
        }
    }

    private static void append_icon_name (ref string[] names, string name) {
        string[] expanded = new string[names.length + 1];
        for (int i = 0; i < names.length; i++) {
            expanded[i] = names[i];
        }
        expanded[names.length] = name;
        names = expanded;
    }

    private void cancel_path_state_refresh () {
        if (path_state_cancellable != null) {
            path_state_cancellable.cancel ();
            path_state_cancellable = null;
        }
    }

    private void reset_path_state () {
        current_path_info_ready = false;
        current_path_exists = false;
        current_path_is_dir = false;
        current_path_is_regular = false;
        current_path_icon = null;
        current_path_icon_names = {};
    }

    // Resolve path metadata off the UI thread and rebuild when the result lands.
    private async void refresh_path_state (string path,
                                           uint generation,
                                           Cancellable? cancellable) {
        bool exists = false;
        bool is_dir = false;
        bool is_regular = false;
        Icon? icon = null;
        string[] icon_names = {};

        try {
            var info = yield File.new_for_path (path).query_info_async (
                "%s,%s".printf (FileAttribute.STANDARD_TYPE, FileAttribute.STANDARD_ICON),
                FileQueryInfoFlags.NONE,
                Priority.DEFAULT,
                cancellable
            );

            exists = true;
            is_dir = info.get_file_type () == FileType.DIRECTORY;
            is_regular = info.get_file_type () == FileType.REGULAR;
            icon = info.get_icon ();
            icon_names = extract_icon_names (icon);
        } catch (Error e) {
            if (e is IOError.CANCELLED) return;
            if (!(e is IOError.NOT_FOUND)) {
                warning ("Failed to query breadcrumb path info: %s", e.message);
            }
        }

        if (path_state_cancellable == cancellable) {
            path_state_cancellable = null;
        }

        if (generation != path_state_generation || path != current_path) return;

        current_path_info_ready = true;
        current_path_exists = exists;
        current_path_is_dir = is_dir;
        current_path_is_regular = is_regular;
        current_path_icon = icon;
        current_path_icon_names = icon_names;
        rebuild ();
        update_action_sensitivity ();
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

        open_crumb_action = new SimpleAction ("open-crumb", VariantType.STRING);
        open_crumb_action.activate.connect ((parameter) => {
            if (parameter == null) return;
            open_path (parameter.get_string ());
        });
        action_group.add_action (open_crumb_action);

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

        copy_path_action.set_enabled (has_path);
        open_path_action.set_enabled (has_path && current_path_info_ready && current_path_exists);
        reveal_path_action.set_enabled (
            has_path &&
            current_path_info_ready &&
            current_path_exists &&
            (current_path_is_regular || current_path_is_dir)
        );
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
            var proxy = yield new DBusProxy.for_bus (
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
            var info = yield file.query_info_async (
                FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NONE,
                Priority.DEFAULT,
                null
            );
            var target = info.get_file_type () == FileType.DIRECTORY ? file : file.get_parent ();
            if (target != null) {
                AppInfo.launch_default_for_uri (target.get_uri (), null);
            }
        } catch (Error e) {
            warning ("Failed to reveal path: %s", e.message);
        }
    }
}
