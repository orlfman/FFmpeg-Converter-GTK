using Gtk;
using Adw;

// ═══════════════════════════════════════════════════════════════════════════════
//  ConsoleTab
// ═══════════════════════════════════════════════════════════════════════════════

public class ConsoleTab : Box {

    // ── Core widgets ──────────────────────────────────────────────────────────
    public TextView console_view { get; private set; }
    private Button clear_button;
    private Button search_button;
    private Button copy_button;
    private Button save_button;
    private Entry command_entry;

    // ── Search widgets ────────────────────────────────────────────────────────
    private Revealer search_revealer;
    private SearchEntry search_entry;
    private Button search_prev_button;
    private Button search_next_button;
    private Label search_status_label;

    // ── Filter bar widgets ────────────────────────────────────────────────────
    private ToggleButton filter_error_btn;
    private ToggleButton filter_warning_btn;
    private ToggleButton filter_success_btn;
    private ToggleButton filter_info_btn;
    private ToggleButton filter_progress_btn;

    // ── Font size ─────────────────────────────────────────────────────────────
    private Button font_down_btn;
    private Button font_up_btn;
    private string base_font_family = "monospace";
    private int base_font_size_pt = 10;
    private int font_size_offset = 0;
    private CssProvider? font_css = null;

    // ── Stats bar ─────────────────────────────────────────────────────────────
    private Button stats_error_btn;
    private Button stats_warning_btn;
    private Label stats_line_label;
    private int error_count = 0;
    private int warning_count = 0;
    private int success_count = 0;
    private int total_line_count = 0;
    private int nav_error_index = -1;
    private int nav_warning_index = -1;

    // ── Clickable errors ──────────────────────────────────────────────────────
    private Popover error_popover;
    private Label error_popover_label;
    private TextTag tag_error_click;

    // ── Text tags for coloring & filtering ────────────────────────────────────
    private TextTag tag_error;
    private TextTag tag_success;
    private TextTag tag_warning;
    private TextTag tag_info;
    private TextTag tag_progress;
    private TextTag tag_search_highlight;
    private TextTag tag_search_active;

    // ── Progress line collapsing ──────────────────────────────────────────────
    private TextMark? progress_mark = null;
    private bool has_active_progress = false;

    // ── Throttle machinery ────────────────────────────────────────────────────
    private StringBuilder pending_lines = new StringBuilder ();
    private bool flush_scheduled = false;
    private const uint FLUSH_INTERVAL_MS = 200;
    private const int MAX_BUFFER_CHARS = 200000;

    private int search_match_count = 0;
    private int search_current_index = -1;

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public ConsoleTab () {
        Object (orientation: Orientation.VERTICAL, spacing: 0);
        set_margin_top (12);
        set_margin_bottom (12);
        set_margin_start (12);
        set_margin_end (12);

        inject_console_css ();

        build_top_bar ();
        build_search_bar ();
        build_filter_bar ();
        build_console_view ();
        build_stats_bar ();
        build_error_popover ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CSS — Injected once for all ConsoleTab instances
    // ═════════════════════════════════════════════════════════════════════════

    private static bool css_injected = false;

    private static void inject_console_css () {
        if (css_injected) return;
        css_injected = true;

        var css = new CssProvider ();
        css.load_from_string (
            // Filter toggle buttons (pill-shaped)
            ".console-filter-btn {\n" +
            "    padding: 2px 10px;\n" +
            "    min-height: 22px;\n" +
            "    border-radius: 99px;\n" +
            "    font-size: 0.85em;\n" +
            "    font-weight: 500;\n" +
            "}\n" +
            ".console-filter-btn:checked {\n" +
            "    background: alpha(@card_bg_color, 0.7);\n" +
            "}\n" +
            ".console-filter-btn:not(:checked) {\n" +
            "    opacity: 0.45;\n" +
            "}\n" +
            // Stats bar
            ".console-stats-bar {\n" +
            "    padding: 4px 2px;\n" +
            "    font-size: 0.85em;\n" +
            "}\n" +
            ".console-stat-btn {\n" +
            "    padding: 1px 8px;\n" +
            "    min-height: 20px;\n" +
            "    border-radius: 99px;\n" +
            "    font-size: 0.85em;\n" +
            "    font-weight: 600;\n" +
            "}\n" +
            ".console-stat-error {\n" +
            "    color: #e74856;\n" +
            "}\n" +
            ".console-stat-warning {\n" +
            "    color: #e5a50a;\n" +
            "}\n" +
            // Font size buttons
            ".console-font-btn {\n" +
            "    padding: 0px 4px;\n" +
            "    min-height: 22px;\n" +
            "    min-width: 22px;\n" +
            "    font-size: 0.85em;\n" +
            "}\n" +
            // Error click popover
            ".error-popover-content {\n" +
            "    padding: 8px;\n" +
            "}\n" +
            ".error-popover-text {\n" +
            "    font-family: monospace;\n" +
            "    font-size: 0.9em;\n" +
            "    padding: 6px 8px;\n" +
            "    background: alpha(@error_color, 0.08);\n" +
            "    border-radius: 6px;\n" +
            "}\n"
        );
        StyleContext.add_provider_for_display (
            Gdk.Display.get_default (),
            css,
            STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI — Top Bar (command + search + copy + save + clear)
    // ═════════════════════════════════════════════════════════════════════════

    private void build_top_bar () {
        var top_bar = new Box (Orientation.HORIZONTAL, 6);
        top_bar.set_hexpand (true);
        top_bar.set_margin_bottom (6);

        // Read-only command display
        command_entry = new Entry ();
        command_entry.set_editable (false);
        command_entry.set_placeholder_text ("FFmpeg command will appear here…");
        command_entry.set_hexpand (true);
        top_bar.append (command_entry);

        // Search toggle
        search_button = new Button.from_icon_name ("system-search-symbolic");
        search_button.set_tooltip_text ("Search console output");
        search_button.add_css_class ("flat");
        search_button.clicked.connect (toggle_search);
        top_bar.append (search_button);

        // Copy to clipboard
        copy_button = new Button.from_icon_name ("edit-copy-symbolic");
        copy_button.set_tooltip_text ("Copy console text to clipboard");
        copy_button.add_css_class ("flat");
        copy_button.clicked.connect (on_copy_clicked);
        top_bar.append (copy_button);

        // Save to file
        save_button = new Button.from_icon_name ("document-save-symbolic");
        save_button.set_tooltip_text ("Save console log to file");
        save_button.add_css_class ("flat");
        save_button.clicked.connect (on_save_clicked);
        top_bar.append (save_button);

        // Clear
        clear_button = new Button.from_icon_name ("user-trash-symbolic");
        clear_button.set_tooltip_text ("Clear console");
        clear_button.add_css_class ("flat");
        clear_button.clicked.connect (on_clear_clicked);
        top_bar.append (clear_button);

        append (top_bar);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI — Search Bar
    // ═════════════════════════════════════════════════════════════════════════

    private void build_search_bar () {
        search_revealer = new Revealer ();
        search_revealer.set_transition_type (RevealerTransitionType.SLIDE_DOWN);
        search_revealer.set_reveal_child (false);

        var search_box = new Box (Orientation.HORIZONTAL, 6);
        search_box.set_margin_top (4);
        search_box.set_margin_bottom (4);

        search_entry = new SearchEntry ();
        search_entry.set_placeholder_text ("Search console…");
        search_entry.set_hexpand (true);
        search_box.append (search_entry);

        search_status_label = new Label ("");
        search_status_label.add_css_class ("dim-label");
        search_box.append (search_status_label);

        search_prev_button = new Button.from_icon_name ("go-up-symbolic");
        search_prev_button.set_tooltip_text ("Previous match");
        search_prev_button.add_css_class ("flat");
        search_prev_button.set_sensitive (false);
        search_box.append (search_prev_button);

        search_next_button = new Button.from_icon_name ("go-down-symbolic");
        search_next_button.set_tooltip_text ("Next match");
        search_next_button.add_css_class ("flat");
        search_next_button.set_sensitive (false);
        search_box.append (search_next_button);

        var close_button = new Button.from_icon_name ("window-close-symbolic");
        close_button.set_tooltip_text ("Close search");
        close_button.add_css_class ("flat");
        search_box.append (close_button);

        search_revealer.set_child (search_box);

        search_entry.search_changed.connect (on_search_changed);
        search_prev_button.clicked.connect (search_prev);
        search_next_button.clicked.connect (search_next);
        close_button.clicked.connect (() => {
            search_revealer.set_reveal_child (false);
            clear_search_highlights ();
        });

        append (search_revealer);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI — Filter Bar + Font Size Controls
    // ═════════════════════════════════════════════════════════════════════════

    private void build_filter_bar () {
        var filter_box = new Box (Orientation.HORIZONTAL, 4);
        filter_box.set_margin_top (2);
        filter_box.set_margin_bottom (6);

        // Filter toggles — all start active (showing lines)
        filter_error_btn    = make_filter_toggle ("⏺ Errors",    "error");
        filter_warning_btn  = make_filter_toggle ("⏺ Warnings",  "warning");
        filter_success_btn  = make_filter_toggle ("⏺ Success",   "success");
        filter_info_btn     = make_filter_toggle ("⏺ Info",      "info");
        filter_progress_btn = make_filter_toggle ("⏺ Progress",  "progress");

        filter_box.append (filter_error_btn);
        filter_box.append (filter_warning_btn);
        filter_box.append (filter_success_btn);
        filter_box.append (filter_info_btn);
        filter_box.append (filter_progress_btn);

        // Spacer pushes font controls to the right
        var spacer = new Box (Orientation.HORIZONTAL, 0);
        spacer.set_hexpand (true);
        filter_box.append (spacer);

        // Font size controls
        font_down_btn = new Button.with_label ("A−");
        font_down_btn.add_css_class ("flat");
        font_down_btn.add_css_class ("console-font-btn");
        font_down_btn.set_tooltip_text ("Decrease font size");
        font_down_btn.clicked.connect (() => {
            font_size_offset -= 1;
            apply_font_size ();
        });
        filter_box.append (font_down_btn);

        font_up_btn = new Button.with_label ("A+");
        font_up_btn.add_css_class ("flat");
        font_up_btn.add_css_class ("console-font-btn");
        font_up_btn.set_tooltip_text ("Increase font size");
        font_up_btn.clicked.connect (() => {
            font_size_offset += 1;
            apply_font_size ();
        });
        filter_box.append (font_up_btn);

        append (filter_box);
    }

    private ToggleButton make_filter_toggle (string label, string category) {
        var btn = new ToggleButton.with_label (label);
        btn.set_active (true);
        btn.add_css_class ("flat");
        btn.add_css_class ("console-filter-btn");

        btn.toggled.connect (() => {
            apply_filter (category, btn.active);
        });

        return btn;
    }

    private void apply_filter (string category, bool visible) {
        TextTag? tag = null;
        if (category == "error")         tag = tag_error;
        else if (category == "warning")  tag = tag_warning;
        else if (category == "success")  tag = tag_success;
        else if (category == "info")     tag = tag_info;
        else if (category == "progress") tag = tag_progress;

        if (tag != null) {
            tag.invisible = !visible;
            tag.invisible_set = true;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI — Console View
    // ═════════════════════════════════════════════════════════════════════════

    private void build_console_view () {
        console_view = new TextView ();
        console_view.editable = false;
        console_view.cursor_visible = false;
        console_view.wrap_mode = WrapMode.WORD_CHAR;
        console_view.top_margin = 8;
        console_view.bottom_margin = 8;
        console_view.left_margin = 8;
        console_view.right_margin = 8;

        resolve_system_font ();
        apply_font_size ();
        create_text_tags ();
        setup_click_handler ();

        var scrolled = new ScrolledWindow ();
        scrolled.set_vexpand (true);
        scrolled.set_child (console_view);

        append (scrolled);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI — Stats Bar (footer)
    // ═════════════════════════════════════════════════════════════════════════

    private void build_stats_bar () {
        var bar = new Box (Orientation.HORIZONTAL, 8);
        bar.add_css_class ("console-stats-bar");
        bar.set_margin_top (6);

        stats_error_btn = new Button.with_label ("0 errors");
        stats_error_btn.add_css_class ("flat");
        stats_error_btn.add_css_class ("console-stat-btn");
        stats_error_btn.add_css_class ("console-stat-error");
        stats_error_btn.set_tooltip_text ("Click to jump to next error");
        stats_error_btn.clicked.connect (() => {
            jump_to_next_tagged_line (tag_error, ref nav_error_index);
        });
        bar.append (stats_error_btn);

        var sep1 = new Label ("·");
        sep1.add_css_class ("dim-label");
        bar.append (sep1);

        stats_warning_btn = new Button.with_label ("0 warnings");
        stats_warning_btn.add_css_class ("flat");
        stats_warning_btn.add_css_class ("console-stat-btn");
        stats_warning_btn.add_css_class ("console-stat-warning");
        stats_warning_btn.set_tooltip_text ("Click to jump to next warning");
        stats_warning_btn.clicked.connect (() => {
            jump_to_next_tagged_line (tag_warning, ref nav_warning_index);
        });
        bar.append (stats_warning_btn);

        var sep2 = new Label ("·");
        sep2.add_css_class ("dim-label");
        bar.append (sep2);

        stats_line_label = new Label ("0 lines");
        stats_line_label.add_css_class ("dim-label");
        bar.append (stats_line_label);

        append (bar);
    }

    /**
     * Walk the buffer line-by-line starting from the line after the
     * last navigation hit, wrapping around, to find the next line
     * with the given tag.  Scrolls to it when found.
     */
    private void jump_to_next_tagged_line (TextTag tag, ref int nav_index) {
        var buffer = console_view.buffer;
        int line_count = buffer.get_line_count ();
        if (line_count == 0) return;

        int start = (nav_index + 1) % line_count;
        for (int i = 0; i < line_count; i++) {
            int check = (start + i) % line_count;

            TextIter line_iter;
            buffer.get_iter_at_line (out line_iter, check);
            if (line_iter.has_tag (tag)) {
                nav_index = check;
                console_view.scroll_to_iter (line_iter, 0.1, true, 0.0, 0.5);
                return;
            }
        }
    }

    private void refresh_stats () {
        stats_error_btn.set_label ("%d error%s".printf (
            error_count, error_count == 1 ? "" : "s"));
        stats_warning_btn.set_label ("%d warning%s".printf (
            warning_count, warning_count == 1 ? "" : "s"));
        stats_line_label.set_text ("%d line%s".printf (
            total_line_count, total_line_count == 1 ? "" : "s"));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI — Error Click Popover
    // ═════════════════════════════════════════════════════════════════════════

    private void build_error_popover () {
        error_popover = new Popover ();
        error_popover.set_autohide (true);
        error_popover.set_has_arrow (true);

        var vbox = new Box (Orientation.VERTICAL, 8);
        vbox.add_css_class ("error-popover-content");

        var header = new Label ("Error Details");
        header.add_css_class ("heading");
        header.set_halign (Align.START);
        vbox.append (header);

        error_popover_label = new Label ("");
        error_popover_label.add_css_class ("error-popover-text");
        error_popover_label.set_wrap (true);
        error_popover_label.set_max_width_chars (60);
        error_popover_label.set_selectable (true);
        error_popover_label.set_halign (Align.START);
        vbox.append (error_popover_label);

        var btn_box = new Box (Orientation.HORIZONTAL, 6);
        btn_box.set_halign (Align.END);

        var copy_btn = new Button.with_label ("Copy");
        copy_btn.add_css_class ("suggested-action");
        copy_btn.clicked.connect (() => {
            var clipboard = console_view.get_clipboard ();
            clipboard.set_text (error_popover_label.get_text ());
            error_popover.popdown ();
        });
        btn_box.append (copy_btn);

        var dismiss_btn = new Button.with_label ("Close");
        dismiss_btn.add_css_class ("flat");
        dismiss_btn.clicked.connect (() => { error_popover.popdown (); });
        btn_box.append (dismiss_btn);

        vbox.append (btn_box);
        error_popover.set_child (vbox);
        error_popover.set_parent (console_view);

        // Clear error highlights when the popover closes
        error_popover.closed.connect (clear_error_highlights);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Click handler — Clickable error lines
    // ═════════════════════════════════════════════════════════════════════════

    private void setup_click_handler () {
        var click = new GestureClick ();
        click.set_button (Gdk.BUTTON_PRIMARY);
        click.pressed.connect ((n_press, x, y) => {
            if (n_press != 1) return;

            // Convert widget coordinates to buffer coordinates
            int bx, by;
            console_view.window_to_buffer_coords (
                TextWindowType.WIDGET, (int) x, (int) y, out bx, out by);

            TextIter iter;
            console_view.get_iter_at_location (out iter, bx, by);

            if (iter.has_tag (tag_error)) {
                on_error_line_clicked (iter, (int) x, (int) y);
            }
        });
        console_view.add_controller (click);
    }

    private void on_error_line_clicked (TextIter clicked_iter, int x, int y) {
        var buffer = console_view.buffer;

        // Extract the full line text
        TextIter line_start = clicked_iter;
        line_start.set_line_offset (0);
        TextIter line_end = line_start;
        line_end.forward_to_line_end ();
        string line_text = buffer.get_text (line_start, line_end, false);

        // Highlight ALL error lines in the buffer
        clear_error_highlights ();

        TextIter scan;
        buffer.get_start_iter (out scan);

        while (!scan.is_end ()) {
            if (scan.starts_line () && scan.has_tag (tag_error)) {
                TextIter err_end = scan;
                if (!err_end.ends_line ()) err_end.forward_to_line_end ();
                err_end.forward_char ();
                buffer.apply_tag (tag_error_click, scan, err_end);
            }
            if (!scan.forward_line ()) break;
        }

        // Position and show the popover
        error_popover_label.set_text (line_text.strip ());
        var rect = Gdk.Rectangle () { x = x, y = y, width = 1, height = 1 };
        error_popover.set_pointing_to (rect);
        error_popover.popup ();
    }

    private void clear_error_highlights () {
        var buffer = console_view.buffer;
        TextIter start, end;
        buffer.get_bounds (out start, out end);
        buffer.remove_tag (tag_error_click, start, end);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  System monospace font + font size
    // ═════════════════════════════════════════════════════════════════════════

    private void resolve_system_font () {
        var schema_source = SettingsSchemaSource.get_default ();
        if (schema_source != null) {
            var schema = schema_source.lookup ("org.gnome.desktop.interface", true);
            if (schema != null && schema.has_key ("monospace-font-name")) {
                var settings = new GLib.Settings.full (schema, null, null);
                string font_name = settings.get_string ("monospace-font-name");

                if (font_name != null && font_name.length > 0) {
                    var font_desc = Pango.FontDescription.from_string (font_name);
                    var font_family = font_desc.get_family ();
                    if (font_family != null && font_family.length > 0) {
                        base_font_family = font_family;
                    }

                    base_font_size_pt = font_desc.get_size () / Pango.SCALE;
                    if (base_font_size_pt <= 0) base_font_size_pt = 10;
                    return;
                }
            }
        }

        base_font_family = "monospace";
        base_font_size_pt = 10;
    }

    private void apply_font_size () {
        int size = (base_font_size_pt + font_size_offset).clamp (6, 32);

        if (font_css != null && console_view != null) {
            console_view.get_style_context ().remove_provider (font_css);
        }

        font_css = new CssProvider ();
        font_css.load_from_string (
            "textview { font-family: \"%s\"; font-size: %dpt; }".printf (
                base_font_family, size
            )
        );

        if (console_view != null) {
            console_view.get_style_context ().add_provider (
                font_css, STYLE_PROVIDER_PRIORITY_APPLICATION
            );
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Text tags — coloring, filtering, and special highlights
    // ═════════════════════════════════════════════════════════════════════════

    private void create_text_tags () {
        var buffer = console_view.buffer;

        tag_error = buffer.create_tag ("error",
            "foreground", "#e74856"     // Soft red
        );
        tag_success = buffer.create_tag ("success",
            "foreground", "#16c464"     // Soft green
        );
        tag_warning = buffer.create_tag ("warning",
            "foreground", "#e5a50a"     // Amber
        );
        tag_info = buffer.create_tag ("info"
            // No special color — uses theme default
        );
        tag_progress = buffer.create_tag ("progress",
            "foreground", "#888888"     // Dimmed gray
        );
        tag_search_highlight = buffer.create_tag ("search-highlight",
            "background", "#fce94f80"   // Translucent yellow
        );
        tag_search_active = buffer.create_tag ("search-active",
            "background", "#f57900",    // Orange
            "foreground", "#ffffff"
        );
        tag_error_click = buffer.create_tag ("error-click",
            "background", "#e7485620"   // Translucent red
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Line classification
    // ═════════════════════════════════════════════════════════════════════════

    private unowned TextTag classify_line (string line) {
        // Progress lines first — they may contain numeric "error" counts
        if (is_progress_line (line)) {
            return tag_progress;
        }
        // Errors
        if (line.contains ("Error")   || line.contains ("error")   ||
            line.contains ("failed")  || line.contains ("Failed")  ||
            line.contains ("Invalid") || line.contains ("❌")      ||
            line.contains ("No such")) {
            return tag_error;
        }
        // Success / completion
        if (line.contains ("✅")                  ||
            line.contains ("Conversion completed") ||
            line.contains ("Lsize=")               ||
            line.contains ("muxing overhead")) {
            return tag_success;
        }
        // Warnings
        if (line.contains ("Warning")    || line.contains ("warning") ||
            line.contains ("deprecated") || line.contains ("⚠")) {
            return tag_warning;
        }

        return tag_info;
    }

    private static bool is_progress_line (string line) {
        if (line.contains ("frame=") &&
            (line.contains ("speed=") || line.contains ("time=") || line.contains ("bitrate="))) {
            return true;
        }
        if (line.has_prefix ("frame=")      || line.has_prefix ("fps=")        ||
            line.has_prefix ("bitrate=")    || line.has_prefix ("total_size=") ||
            line.has_prefix ("out_time")    || line.has_prefix ("speed=")      ||
            line.has_prefix ("progress=")   || line.has_prefix ("drop_frames=") ||
            line.has_prefix ("dup_frames=") || line.has_prefix ("stream_")) {
            return true;
        }
        return false;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Search
    // ═════════════════════════════════════════════════════════════════════════

    private void toggle_search () {
        bool visible = search_revealer.get_reveal_child ();
        search_revealer.set_reveal_child (!visible);

        if (!visible) {
            search_entry.grab_focus ();
        } else {
            clear_search_highlights ();
        }
    }

    private void on_search_changed () {
        clear_search_highlights ();

        string query = search_entry.get_text ().strip ();
        if (query.length == 0) {
            search_status_label.set_text ("");
            search_prev_button.set_sensitive (false);
            search_next_button.set_sensitive (false);
            search_match_count = 0;
            search_current_index = -1;
            return;
        }

        highlight_all_matches (query);
    }

    private void highlight_all_matches (string query) {
        var buffer = console_view.buffer;
        TextIter search_start;
        TextIter match_start;
        TextIter match_end;

        buffer.get_start_iter (out search_start);
        search_match_count = 0;

        while (search_start.forward_search (
                   query,
                   TextSearchFlags.CASE_INSENSITIVE,
                   out match_start,
                   out match_end,
                   null)) {
            buffer.apply_tag (tag_search_highlight, match_start, match_end);
            search_match_count++;
            search_start = match_end;
        }

        bool has_matches = search_match_count > 0;
        search_prev_button.set_sensitive (has_matches);
        search_next_button.set_sensitive (has_matches);

        if (has_matches) {
            search_current_index = -1;
            search_next ();
        } else {
            search_status_label.set_text ("No matches");
            search_current_index = -1;
        }
    }

    private void search_next () {
        if (search_match_count == 0) return;
        search_current_index = (search_current_index + 1) % search_match_count;
        jump_to_match (search_current_index);
    }

    private void search_prev () {
        if (search_match_count == 0) return;
        search_current_index = (search_current_index - 1 + search_match_count) % search_match_count;
        jump_to_match (search_current_index);
    }

    private void jump_to_match (int index) {
        string query = search_entry.get_text ().strip ();
        if (query.length == 0) return;

        var buffer = console_view.buffer;
        TextIter search_start;
        TextIter match_start;
        TextIter match_end;

        TextIter buf_start, buf_end;
        buffer.get_bounds (out buf_start, out buf_end);
        buffer.remove_tag (tag_search_active, buf_start, buf_end);

        buffer.get_start_iter (out search_start);
        int current = 0;

        while (search_start.forward_search (
                   query,
                   TextSearchFlags.CASE_INSENSITIVE,
                   out match_start,
                   out match_end,
                   null)) {
            if (current == index) {
                buffer.apply_tag (tag_search_active, match_start, match_end);
                console_view.scroll_to_iter (match_start, 0.1, true, 0.0, 0.5);
                search_status_label.set_text (
                    "%d of %d".printf (index + 1, search_match_count)
                );
                return;
            }
            current++;
            search_start = match_end;
        }
    }

    private void clear_search_highlights () {
        var buffer = console_view.buffer;
        TextIter start, end;
        buffer.get_bounds (out start, out end);
        buffer.remove_tag (tag_search_highlight, start, end);
        buffer.remove_tag (tag_search_active, start, end);
        search_match_count = 0;
        search_current_index = -1;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Actions — Clear, Copy, Save
    // ═════════════════════════════════════════════════════════════════════════

    private void on_clear_clicked () {
        console_view.buffer.text = "";
        command_entry.set_text ("");

        lock (pending_lines) {
            pending_lines.truncate (0);
            flush_scheduled = false;
        }

        clear_search_highlights ();
        clear_error_highlights ();

        // Reset all counters
        error_count = 0;
        warning_count = 0;
        success_count = 0;
        total_line_count = 0;
        nav_error_index = -1;
        nav_warning_index = -1;
        has_active_progress = false;
        refresh_stats ();
    }

    private void on_copy_clicked () {
        string text = console_view.buffer.text;
        if (text.length == 0) return;

        var clipboard = console_view.get_clipboard ();
        clipboard.set_text (text);

        // Brief visual feedback — flash a check mark icon
        copy_button.set_icon_name ("object-select-symbolic");
        Timeout.add (1200, () => {
            copy_button.set_icon_name ("edit-copy-symbolic");
            return Source.REMOVE;
        });
    }

    private void on_save_clicked () {
        string text = console_view.buffer.text;
        if (text.length == 0) return;

        var dialog = new Gtk.FileDialog ();
        dialog.set_initial_name ("console-log.txt");

        dialog.save.begin ((Gtk.Window) get_root (), null, (obj, res) => {
            try {
                var file = dialog.save.end (res);
                file.replace_contents (
                    text.data,
                    null, false,
                    FileCreateFlags.REPLACE_DESTINATION,
                    null, null
                );
            } catch (Error e) {
                // User canceled or write error — silent
            }
        });
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Public API
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Show the full FFmpeg command in the top bar.
     * Called once per encode so Idle.add is fine here.
     */
    public void set_command (string full_command) {
        Idle.add (() => {
            command_entry.set_text (full_command);
            return Source.REMOVE;
        });
    }

    /**
     * Append a line of FFmpeg output.
     *
     * Safe to call from any thread. Lines are accumulated and
     * flushed to the TextView at most once every FLUSH_INTERVAL_MS,
     * keeping the main loop free even under heavy -progress output.
     */
    public void add_line (string line) {
        lock (pending_lines) {
            pending_lines.append (line);
            pending_lines.append_c ('\n');

            if (!flush_scheduled) {
                flush_scheduled = true;
                Timeout.add (FLUSH_INTERVAL_MS, flush_pending);
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Flush / insert — with progress collapsing & stats tracking
    //
    //  Progress collapsing: consecutive FFmpeg progress lines are folded
    //  into a single live-updating line instead of flooding the console.
    //  A TextMark tracks the start of the current progress line so it
    //  can be replaced in-place when the next update arrives.
    // ═════════════════════════════════════════════════════════════════════════

    private bool flush_pending () {
        string chunk;

        lock (pending_lines) {
            chunk = pending_lines.str;
            pending_lines.truncate (0);
            flush_scheduled = false;
        }

        if (chunk.length == 0) {
            return Source.REMOVE;
        }

        var buffer = console_view.buffer;
        TextIter end_iter;

        string[] lines = chunk.split ("\n");
        foreach (unowned string line in lines) {
            if (line.length == 0) continue;

            unowned TextTag tag = classify_line (line);
            bool is_progress = (tag == tag_progress);

            // ── Progress collapsing: replace the previous progress line ───
            if (is_progress && has_active_progress && progress_mark != null) {
                TextIter mark_iter;
                buffer.get_iter_at_mark (out mark_iter, progress_mark);

                TextIter old_end = mark_iter;
                if (!old_end.ends_line ()) old_end.forward_to_line_end ();
                old_end.forward_char ();  // past the newline

                buffer.@delete (ref mark_iter, ref old_end);

                // Re-get iter at the (now-moved) mark and insert
                buffer.get_iter_at_mark (out mark_iter, progress_mark);
                buffer.insert (ref mark_iter, line + "\n", -1);

                // Re-tag the replacement line
                TextIter tag_start;
                buffer.get_iter_at_mark (out tag_start, progress_mark);
                TextIter tag_end = tag_start;
                if (!tag_end.ends_line ()) tag_end.forward_to_line_end ();
                tag_end.forward_char ();
                buffer.apply_tag (tag, tag_start, tag_end);

                continue;  // don't increment line count — same slot
            }

            // ── Non-progress line breaks the collapsing chain ────────────
            if (!is_progress) {
                has_active_progress = false;
            }

            // ── Normal insert ────────────────────────────────────────────
            buffer.get_end_iter (out end_iter);
            int start_offset = end_iter.get_offset ();
            buffer.insert (ref end_iter, line + "\n", -1);

            // Apply the category tag
            TextIter tag_start;
            buffer.get_iter_at_offset (out tag_start, start_offset);
            buffer.get_end_iter (out end_iter);
            buffer.apply_tag (tag, tag_start, end_iter);

            // Start a new progress collapsing region
            if (is_progress) {
                buffer.get_iter_at_offset (out tag_start, start_offset);
                if (progress_mark == null) {
                    progress_mark = buffer.create_mark (
                        "progress-line", tag_start, true);
                } else {
                    buffer.move_mark (progress_mark, tag_start);
                }
                has_active_progress = true;
            }

            // Update stats
            total_line_count++;
            if (tag == tag_error)        error_count++;
            else if (tag == tag_warning) warning_count++;
            else if (tag == tag_success) success_count++;
        }

        // ── Trim oldest text when the buffer exceeds the cap ─────────────
        if (buffer.get_char_count () > MAX_BUFFER_CHARS) {
            TextIter trim_start;
            TextIter trim_end;
            int excess = buffer.get_char_count () - MAX_BUFFER_CHARS;

            buffer.get_start_iter (out trim_start);
            buffer.get_iter_at_offset (out trim_end, excess);

            // Advance to a newline boundary
            if (!trim_end.ends_line ()) {
                trim_end.forward_to_line_end ();
                trim_end.forward_char ();
            }

            buffer.@delete (ref trim_start, ref trim_end);

            // Progress mark may have been pushed — reset collapsing
            has_active_progress = false;
        }

        // Auto-scroll to the bottom so the latest output is visible
        buffer.get_end_iter (out end_iter);
        console_view.scroll_to_iter (end_iter, 0.0, false, 0.0, 1.0);

        refresh_stats ();

        return Source.REMOVE;
    }
}
