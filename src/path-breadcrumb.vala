using Gtk;
using GLib;

// A GTK Box-based widget that displays a filesystem path as a series of
// clickable breadcrumb segments (e.g. Home > Documents > Videos > file.mp4).
// Supports overflow collapsing, async file-type detection, context menus,
// and D-Bus file-manager integration for "Reveal in File Manager".
public class PathBreadcrumb : Box {
    // Emitted whenever the displayed path changes (including being cleared).
    public signal void changed ();

    // Maximum number of crumb segments visible before the middle ones collapse
    // behind an overflow ("...") menu button.
    private const int MAX_VISIBLE_CRUMBS = 6;

    // Fallback icon used when the file's MIME-based icon cannot be resolved.
    private const string DEFAULT_FILE_ICON = "video-x-generic-symbolic";

    // ----- Path state -----
    private string current_path = "";
    private string placeholder_text;
    // When true, the final path segment is rendered as a file chip (icon + label)
    // rather than a clickable directory crumb.
    private bool treat_last_as_file;
    // These flags are populated asynchronously by refresh_path_state().
    private bool current_path_info_ready = false;
    private bool current_path_exists = false;
    private bool current_path_is_dir = false;
    private bool current_path_is_regular = false;
    private Icon? current_path_icon = null;
    private string[] current_path_icon_names = {};
    // Cached pixel size derived from the Pango font for the file-chip icon.
    private int cached_icon_pixel_size = -1;
    // Monotonically increasing counter used to discard stale async results
    // when the path changes faster than the I/O can complete.
    private uint path_state_generation = 0;
    private Cancellable? path_state_cancellable = null;
    private Cancellable? reveal_cancellable = null;

    // ----- UI widgets -----
    private Box crumb_box;              // Horizontal container holding the crumb buttons and separators
    private Label placeholder_label;    // Shown when current_path is empty
    private PopoverMenu path_menu;      // Right-click context menu
    private GLib.Menu path_menu_model;  // Menu model backing the context menu
    // ----- Actions (wired to context menu items and crumb clicks) -----
    private SimpleActionGroup action_group;
    private SimpleAction copy_path_action;
    private SimpleAction? open_path_action;    // Input breadcrumb only: opens the file
    private SimpleAction reveal_path_action;
    private SimpleAction? open_output_action;  // Output breadcrumb only: opens last output file
    private SimpleAction open_crumb_action;    // Opens a directory from the overflow menu
    private string last_output_file = "";

    // Lightweight data model for a single breadcrumb segment.
    private class Crumb : Object {
        public string label { get; construct set; }     // Display text (directory or file name)
        public string path { get; construct set; }      // Full absolute path up to this segment
        public bool clickable { get; construct set; }   // False for the leaf file chip

        public Crumb (string label, string path, bool clickable) {
            Object (label: label, path: path, clickable: clickable);
        }
    }

    // Constructs a new breadcrumb bar.
    // @placeholder_text  Text shown when no path is set (e.g. "Select input file...").
    // @treat_last_as_file  If true, the final segment is rendered as a non-navigable
    //                      file chip with an icon; if false, it is a normal clickable crumb.
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

    // Returns the current absolute path, or "" if none is set.
    public string get_text () {
        return current_path;
    }

    // Sets (and normalizes) the displayed path, triggering an async metadata
    // refresh and a full UI rebuild.  Emits the `changed` signal.
    public void set_text (string path) {
        string normalized = normalize_path (path);
        if (normalized == current_path) return;

        cancel_path_state_refresh ();
        current_path = normalized;
        reset_path_state ();
        set_tooltip_text (current_path.length > 0 ? current_path : placeholder_text);
        rebuild ();
        update_action_sensitivity ();

        // Kick off an async I/O query to learn whether the path exists,
        // its type (file vs directory), and its icon.
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

    // Updates the placeholder text shown when no path is active.
    public void set_placeholder_text (string text) {
        placeholder_text = text;
        if (current_path.length == 0) {
            set_tooltip_text (placeholder_text);
            rebuild ();
        }
    }

    // Stores the path to the most recently created output file so the
    // "Open Output File" context menu action can open it.
    // No-op when called on an input breadcrumb (treat_last_as_file == true).
    public void set_last_output_file (string path) {
        if (open_output_action == null) return;
        last_output_file = path;
        bool exists = path.length > 0 && FileUtils.test (path, FileTest.EXISTS);
        open_output_action.set_enabled (exists);
    }

    // -----------------------------------------------------------------------
    // UI rebuild — tears down and recreates the crumb_box children
    // -----------------------------------------------------------------------

    // Clears the crumb box and repopulates it from the current path.
    // Shows the placeholder label when there is no path.
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

        // Walk the crumb array and emit visible crumbs, a single overflow menu
        // for the hidden middle section, and separators between segments.
        bool ellipsis_inserted = false;
        bool needs_separator = false;
        for (int i = 0; i < count; i++) {
            if (crumb_is_hidden (i, count)) {
                // Replace the first hidden crumb with an overflow menu button;
                // skip subsequent hidden crumbs silently.
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

    // Splits current_path into an array of Crumb objects.
    // The first crumb is either "Home" (if path is under $HOME) or "/" (root).
    // Intermediate crumbs are individual directory names.
    // The last crumb may be marked non-clickable if treat_last_as_file is set.
    private Crumb[] build_crumb_model () {
        Crumb[] crumbs = {};
        string path = current_path;
        // Determine whether the final segment should display as a file chip.
        bool show_leaf_as_file = treat_last_as_file &&
                                 (!current_path_info_ready || current_path_is_regular);

        // Detect whether the path lives under the user's home directory.
        string home = Environment.get_home_dir ();
        bool under_home = home != null && home.length > 1 &&
                          (path == home || path.has_prefix (home + "/"));

        string[] parts = {};
        string remainder = path;

        // Build the root crumb and strip its prefix from the remainder.
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

        // Split the remaining relative path into individual directory/file names.
        if (remainder.length > 0) {
            foreach (string raw in remainder.split ("/")) {
                if (raw.length > 0) parts += raw;
            }
        }

        // Incrementally build the absolute path for each segment.
        string cursor = under_home ? home : (path.has_prefix ("/") ? "/" : "");

        for (int i = 0; i < parts.length; i++) {
            string part = parts[i];
            if (cursor == "" || cursor == "/") {
                cursor += part;
            } else {
                cursor = Path.build_filename (cursor, part);
            }

            bool is_last = (i == parts.length - 1);
            // The leaf file crumb is non-clickable (it opens via reveal instead).
            bool crumb_clickable = !(show_leaf_as_file && is_last);

            crumbs += new Crumb (part, cursor, crumb_clickable);
        }

        return crumbs;
    }

    // Creates the GTK widget for a single crumb segment.
    // Non-clickable (file) crumbs become a styled chip with an icon and label
    // that reveals the file in the system file manager on click.
    // Clickable (directory) crumbs become flat buttons that open the directory.
    private Widget build_crumb_widget (Crumb crumb,
                                       bool is_last) {
        if (!crumb.clickable) {
            // --- File chip: icon + truncated filename, click to reveal ---
            var file_button = new Button ();
            file_button.add_css_class ("flat");
            file_button.add_css_class ("path-crumb");
            file_button.add_css_class ("path-file");
            file_button.set_halign (Align.START);
            file_button.set_hexpand (false);
            file_button.set_focus_on_click (false);
            file_button.set_tooltip_text (crumb.path);
            file_button.clicked.connect (() => {
                cancel_reveal ();
                reveal_cancellable = new Cancellable ();
                reveal_in_file_manager.begin (crumb.path, reveal_cancellable);
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

        // --- Directory crumb: flat button that opens the directory ---
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

    // Builds a "..." overflow MenuButton containing all the hidden middle crumbs.
    // Each menu item triggers the "open-crumb" action with the crumb's path.
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

    // Appends a small ">" chevron separator icon between crumb widgets.
    private void append_separator () {
        var sep = new Image.from_icon_name ("go-next-symbolic");
        sep.add_css_class ("dim-label");
        sep.add_css_class ("path-separator");
        sep.set_pixel_size (11);
        sep.set_margin_start (2);
        sep.set_margin_end (2);
        crumb_box.append (sep);
    }

    // Removes all children from a Box widget.
    private static void clear_box (Box box) {
        Widget? child = box.get_first_child ();
        while (child != null) {
            Widget? next = child.get_next_sibling ();
            box.remove (child);
            child = next;
        }
    }

    // -----------------------------------------------------------------------
    // Path normalization and overflow index math
    // -----------------------------------------------------------------------

    // Normalizes a raw user-supplied path: trims whitespace, resolves relative
    // paths against the CWD, canonicalizes symlinks/".."/".", and strips
    // trailing slashes (except for the root "/").
    private static string normalize_path (string path) {
        string normalized = path.strip ();
        if (normalized.length == 0) return "";

        string? relative_to = null;
        if (!Path.is_absolute (normalized)) {
            relative_to = Environment.get_current_dir ();
        }

        normalized = Filename.canonicalize (normalized, relative_to);

        while (normalized.length > 1 && normalized.has_suffix ("/")) {
            normalized = normalized.substring (0, normalized.length - 1);
        }

        return normalized;
    }

    // Returns true if the crumb at `index` should be hidden behind the overflow menu.
    private bool crumb_is_hidden (int index, int count) {
        return index >= hidden_crumb_start (count) && index < hidden_crumb_end (count);
    }

    // Returns the first index (inclusive) of the hidden range.
    // The root crumb (index 0) is always visible.
    private int hidden_crumb_start (int count) {
        return count > MAX_VISIBLE_CRUMBS ? 1 : 0;
    }

    // Returns the end index (exclusive) of the hidden range.
    // We keep the root crumb, the overflow button itself, and
    // (MAX_VISIBLE_CRUMBS - 2) tail crumbs visible.
    private int hidden_crumb_end (int count) {
        if (count <= MAX_VISIBLE_CRUMBS) return 0;

        int visible_tail = MAX_VISIBLE_CRUMBS - 2;
        return count - visible_tail;
    }

    // -----------------------------------------------------------------------
    // File icon resolution
    // -----------------------------------------------------------------------

    // Builds an Image widget for the file chip icon, using the best available
    // icon from the file's MIME info or falling back to DEFAULT_FILE_ICON.
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

    // Derives a pixel size for the file icon from the widget's Pango font
    // description, clamped to [12, 32].  The result is cached for efficiency.
    private int get_file_chip_icon_pixel_size () {
        if (cached_icon_pixel_size > 0) return cached_icon_pixel_size;

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

        cached_icon_pixel_size = font_size.clamp (12, 32);
        return cached_icon_pixel_size;
    }

    // Attempts to resolve the file chip icon, preferring a themed icon that
    // actually exists in the current icon theme over the raw GIcon from GIO.
    private Icon? resolve_file_chip_icon () {
        var themed_icon = resolve_themed_file_icon ();
        if (themed_icon != null) return themed_icon;
        return current_path_icon;
    }

    // Looks up each icon candidate name in the current icon theme at the
    // appropriate pixel size and returns the first match as a ThemedIcon.
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

    // Returns a deduplicated list of icon name candidates: the names extracted
    // from the file's GIcon followed by the default fallback icon.
    private string[] get_file_icon_candidates () {
        string[] candidates = {};

        foreach (unowned string name in current_path_icon_names) {
            if (name.length > 0 && !strv_contains (candidates, name)) {
                candidates += name;
            }
        }

        if (!strv_contains (candidates, DEFAULT_FILE_ICON)) {
            candidates += DEFAULT_FILE_ICON;
        }
        return candidates;
    }

    // Simple linear search for a string in an array (Vala lacks built-in strv_contains).
    private static bool strv_contains (string[] arr, string needle) {
        foreach (unowned string s in arr) {
            if (s == needle) return true;
        }
        return false;
    }

    // Extracts human-readable icon names from a GIcon.
    // Handles ThemedIcon (returns its name list) and EmblemedIcon (recurses
    // into both the base icon and each emblem's icon).
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
            foreach (string name in extract_icon_names (emblemed_icon.get_icon ())) {
                if (name.length > 0) names += name;
            }
            foreach (unowned Emblem emblem in emblemed_icon.get_emblems ()) {
                var emblem_icon = emblem.icon as Icon;
                if (emblem_icon != null) {
                    foreach (string name in extract_icon_names (emblem_icon)) {
                        if (name.length > 0) names += name;
                    }
                }
            }
        }

        return names;
    }

    // -----------------------------------------------------------------------
    // Async cancellation helpers
    // -----------------------------------------------------------------------

    // Cancels any in-flight async path metadata query.
    private void cancel_path_state_refresh () {
        if (path_state_cancellable != null) {
            path_state_cancellable.cancel ();
            path_state_cancellable = null;
        }
    }

    // Cancels any in-flight "reveal in file manager" D-Bus call.
    private void cancel_reveal () {
        if (reveal_cancellable != null) {
            reveal_cancellable.cancel ();
            reveal_cancellable = null;
        }
    }

    // Cleans up async operations and detaches the context menu popover.
    public override void dispose () {
        cancel_path_state_refresh ();
        cancel_reveal ();

        if (path_menu != null) {
            path_menu.unparent ();
        }

        insert_action_group ("crumb", null);

        base.dispose ();
    }

    // Resets all cached path metadata to their default (unknown) values.
    private void reset_path_state () {
        current_path_info_ready = false;
        current_path_exists = false;
        current_path_is_dir = false;
        current_path_is_regular = false;
        current_path_icon = null;
        current_path_icon_names = {};
    }

    // Asynchronously queries the filesystem for the given path's type and icon.
    // Uses a generation counter to discard stale results when the path changes
    // before the I/O completes.  On success, updates the cached state and
    // triggers a UI rebuild so the file chip icon and action sensitivity reflect
    // the actual file state.
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

        // Discard the result if the path or generation has moved on.
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

    // -----------------------------------------------------------------------
    // Actions and context menu
    // -----------------------------------------------------------------------

    // Opens a path with the system's default application via its URI.
    private static void open_path (string path) {
        if (path.length == 0) return;

        try {
            var file = File.new_for_path (path);
            AppInfo.launch_default_for_uri (file.get_uri (), null);
        } catch (Error e) {
            warning ("Failed to open path: %s", e.message);
        }
    }

    // Registers GActions used by the context menu and overflow crumb menu.
    // Actions are scoped under the "crumb" action group prefix.
    private void setup_actions () {
        action_group = new SimpleActionGroup ();

        // "Copy Path" — copies the full path to the system clipboard.
        copy_path_action = new SimpleAction ("copy-path", null);
        copy_path_action.activate.connect (() => {
            if (current_path.length == 0) return;
            var clipboard = lookup_clipboard ();
            if (clipboard != null) clipboard.set_text (current_path);
        });
        action_group.add_action (copy_path_action);

        if (treat_last_as_file) {
            // Input breadcrumb: open the file itself
            open_path_action = new SimpleAction ("open-path", null);
            open_path_action.activate.connect (() => {
                open_path (current_path);
            });
            action_group.add_action (open_path_action);
        } else {
            // Output breadcrumb: open last created output file
            open_output_action = new SimpleAction ("open-output", null);
            open_output_action.set_enabled (false);
            open_output_action.activate.connect (() => {
                if (last_output_file.length > 0) open_path (last_output_file);
            });
            action_group.add_action (open_output_action);
        }

        // "Reveal in File Manager" — highlights the file/folder in the native
        // file manager via D-Bus (org.freedesktop.FileManager1).
        reveal_path_action = new SimpleAction ("reveal-path", null);
        reveal_path_action.activate.connect (() => {
            cancel_reveal ();
            reveal_cancellable = new Cancellable ();
            reveal_in_file_manager.begin (current_path, reveal_cancellable);
        });
        action_group.add_action (reveal_path_action);

        // "Open Crumb" — parameterized action triggered from the overflow menu
        // to open a hidden directory segment.
        open_crumb_action = new SimpleAction ("open-crumb", VariantType.STRING);
        open_crumb_action.activate.connect ((parameter) => {
            if (parameter == null) return;
            open_path (parameter.get_string ());
        });
        action_group.add_action (open_crumb_action);

        insert_action_group ("crumb", action_group);
    }

    // Builds the right-click context menu (PopoverMenu) and attaches a
    // secondary-click gesture controller to show it at the pointer position.
    private void setup_context_menu () {
        path_menu_model = new GLib.Menu ();
        path_menu_model.append ("Copy Path", "crumb.copy-path");
        if (treat_last_as_file) {
            // Input file breadcrumb: open the file, reveal in file manager
            path_menu_model.append ("Open Input File", "crumb.open-path");
            path_menu_model.append ("Reveal in File Manager", "crumb.reveal-path");
        } else {
            // Output folder breadcrumb: open output file, reveal folder
            path_menu_model.append ("Open Output File", "crumb.open-output");
            path_menu_model.append ("Reveal in File Manager", "crumb.reveal-path");
        }

        path_menu = new PopoverMenu.from_model (path_menu_model);
        path_menu.set_has_arrow (false);
        path_menu.set_parent (this);

        // Attach a right-click (secondary button) gesture to show the context menu.
        var right_click = new GestureClick ();
        right_click.set_button (Gdk.BUTTON_SECONDARY);
        right_click.pressed.connect ((n_press, x, y) => {
            if (current_path.length == 0) return;
            update_action_sensitivity ();

            // Position the popover at the click coordinates.
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

    // Enables or disables context-menu actions based on the current path state.
    // Called after every path change and after async metadata arrives.
    private void update_action_sensitivity () {
        bool has_path = current_path.length > 0;

        copy_path_action.set_enabled (has_path);

        // "Open" requires the file to actually exist on disk.
        if (open_path_action != null) {
            open_path_action.set_enabled (has_path && current_path_info_ready && current_path_exists);
        }

        // "Open Output File" checks whether the last output file still exists.
        if (open_output_action != null) {
            bool output_exists = last_output_file.length > 0 &&
                                 FileUtils.test (last_output_file, FileTest.EXISTS);
            open_output_action.set_enabled (output_exists);
        }

        // "Reveal" requires an existing regular file or directory.
        reveal_path_action.set_enabled (
            has_path &&
            current_path_info_ready &&
            current_path_exists &&
            (current_path_is_regular || current_path_is_dir)
        );
    }

    // Returns the default display's clipboard, or null if unavailable.
    private Gdk.Clipboard? lookup_clipboard () {
        var display = Gdk.Display.get_default ();
        return display != null ? display.get_clipboard () : null;
    }

    // Asynchronously reveals a file or folder in the user's file manager.
    // Strategy:
    //   1. Try the org.freedesktop.FileManager1 D-Bus interface (ShowItems for
    //      files, ShowFolders for directories) — this highlights the item.
    //   2. On failure, fall back to opening the containing directory (or the
    //      directory itself) with the default URI handler.
    private static async void reveal_in_file_manager (string path,
                                                       Cancellable? cancellable = null) {
        if (path.length == 0) return;

        var file = File.new_for_path (path);
        FileType file_type = FileType.UNKNOWN;

        // Query the file type so we know whether to call ShowItems or ShowFolders.
        try {
            var info = yield file.query_info_async (
                FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NONE,
                Priority.DEFAULT,
                cancellable
            );
            file_type = info.get_file_type ();
        } catch (Error e) {
            if (e is IOError.CANCELLED) return;
            // Fall back to the best-effort parent open below.
        }

        // Attempt D-Bus reveal via org.freedesktop.FileManager1.
        try {
            var uri = file.get_uri ();
            var proxy = yield new DBusProxy.for_bus (
                BusType.SESSION,
                DBusProxyFlags.NONE,
                null,
                "org.freedesktop.FileManager1",
                "/org/freedesktop/FileManager1",
                "org.freedesktop.FileManager1",
                cancellable
            );
            if (proxy.get_name_owner () == null) {
                throw new IOError.FAILED ("No file manager owner available");
            }

            string[] uris = { uri };
            // ShowFolders opens a directory; ShowItems highlights a file within its parent.
            string method = file_type == FileType.DIRECTORY ? "ShowFolders" : "ShowItems";
            Variant? reply = yield proxy.call (
                method,
                new Variant.tuple ({
                    new Variant.strv (uris),
                    new Variant.string ("")
                }),
                DBusCallFlags.NONE,
                -1,
                cancellable
            );
            if (reply != null) return;
        } catch (Error e) {
            if (e is IOError.CANCELLED) return;
            // Fall back to opening the containing folder when item reveal is unavailable.
        }

        // Fallback: open the directory (or the file's parent) with the default handler.
        try {
            var target = file_type == FileType.DIRECTORY ? file : file.get_parent ();
            if (target != null) {
                AppInfo.launch_default_for_uri (target.get_uri (), null);
            }
        } catch (Error e) {
            warning ("Failed to reveal path: %s", e.message);
        }
    }
}
