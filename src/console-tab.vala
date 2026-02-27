using Gtk;
using Adw;

public class ConsoleTab : Box {
    public TextView console_view { get; private set; }
    private Button clear_button;
    private Button search_button;
    private Entry command_entry;

    // --- Search widgets ---
    private Revealer search_revealer;
    private SearchEntry search_entry;
    private Button search_prev_button;
    private Button search_next_button;
    private Label search_status_label;

    // --- Text tags for coloring ---
    private TextTag tag_error;
    private TextTag tag_success;
    private TextTag tag_warning;
    private TextTag tag_search_highlight;
    private TextTag tag_search_active;

    // --- Throttle machinery ---
    private StringBuilder pending_lines = new StringBuilder ();
    private bool flush_scheduled = false;
    private const uint FLUSH_INTERVAL_MS = 200;

    // Cap the buffer so multi-hour encodes don't eat RAM.
    // ~200 000 chars ≈ 4 000–6 000 lines of typical FFmpeg output.
    private const int MAX_BUFFER_CHARS = 200000;

    // Track search matches for prev/next navigation
    private int search_match_count = 0;
    private int search_current_index = -1;

    public ConsoleTab () {
        Object (orientation: Orientation.VERTICAL, spacing: 6);
        set_margin_top (12);
        set_margin_bottom (12);
        set_margin_start (12);
        set_margin_end (12);

        // Top bar: Command display + Search + Clear
        var top_bar = new Box (Orientation.HORIZONTAL, 8);
        top_bar.set_hexpand (true);

        // Read-only command display (left side)
        command_entry = new Entry ();
        command_entry.set_editable (false);
        command_entry.set_placeholder_text ("FFmpeg command will appear here…");
        command_entry.set_hexpand (true);
        top_bar.append (command_entry);

        // Search toggle button
        search_button = new Button.from_icon_name ("system-search-symbolic");
        search_button.set_tooltip_text ("Search console output");
        search_button.add_css_class ("flat");
        top_bar.append (search_button);

        // Clear button
        clear_button = new Button.from_icon_name ("user-trash-symbolic");
        clear_button.set_tooltip_text ("Clear console");
        clear_button.add_css_class ("flat");
        top_bar.append (clear_button);

        append (top_bar);

        // --- Search bar (hidden by default) ---
        build_search_bar ();
        append (search_revealer);

        // --- Console text view ---
        console_view = new TextView ();
        console_view.editable = false;
        console_view.cursor_visible = false;
        console_view.wrap_mode = WrapMode.WORD_CHAR;
        console_view.top_margin = 8;
        console_view.bottom_margin = 8;
        console_view.left_margin = 8;
        console_view.right_margin = 8;

        apply_system_monospace_font ();
        create_text_tags ();

        var scrolled = new ScrolledWindow ();
        scrolled.set_vexpand (true);
        scrolled.set_child (console_view);
        append (scrolled);

        // --- Connect signals ---
        clear_button.clicked.connect (() => {
            console_view.buffer.text = "";
            command_entry.set_text ("");
            lock (pending_lines) {
                pending_lines.truncate (0);
                flush_scheduled = false;
            }
            clear_search_highlights ();
        });

        search_button.clicked.connect (toggle_search);
    }

    // -------------------------------------------------------
    //  System monospace font
    // -------------------------------------------------------

    /**
     * Read the user's preferred monospace font from the GNOME
     * desktop settings (org.gnome.desktop.interface monospace-font-name).
     * Falls back to Gtk.TextView.monospace = true if unavailable.
     */
    private void apply_system_monospace_font () {
        try {
            var settings = new GLib.Settings ("org.gnome.desktop.interface");
            string font_name = settings.get_string ("monospace-font-name");

            if (font_name != null && font_name.length > 0) {
                var font_desc = Pango.FontDescription.from_string (font_name);
                var css = new CssProvider ();
                css.load_from_string (
                    "textview { font-family: \"%s\"; font-size: %dpt; }".printf (
                        font_desc.get_family (),
                        font_desc.get_size () / Pango.SCALE
                    )
                );
                console_view.get_style_context ().add_provider (
                    css, STYLE_PROVIDER_PRIORITY_APPLICATION
                );
                return;
            }
        } catch (Error e) {
            // GSettings schema not available (non-GNOME desktop) — fall through
        }

        // Fallback: let GTK pick its default monospace font
        console_view.monospace = true;
    }

    // -------------------------------------------------------
    //  Text tags for colored output
    // -------------------------------------------------------

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
        tag_search_highlight = buffer.create_tag ("search-highlight",
            "background", "#fce94f80"   // Translucent yellow
        );
        tag_search_active = buffer.create_tag ("search-active",
            "background", "#f57900",    // Orange
            "foreground", "#ffffff"
        );
    }

    /**
     * Classify a single line of FFmpeg output and return the
     * appropriate tag, or null for default-colored text.
     */
    private unowned TextTag? classify_line (string line) {
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

        return null;
    }

    // -------------------------------------------------------
    //  Search
    // -------------------------------------------------------

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

        // Signals
        search_entry.search_changed.connect (on_search_changed);
        search_prev_button.clicked.connect (search_prev);
        search_next_button.clicked.connect (search_next);
        close_button.clicked.connect (() => {
            search_revealer.set_reveal_child (false);
            clear_search_highlights ();
        });
    }

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

    /**
     * Walk the buffer and apply the highlight tag to every occurrence
     * of the query string (case-insensitive).
     */
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
            search_next ();  // Jump to the first match
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

    /**
     * Scroll to the Nth match and apply the "active" highlight.
     */
    private void jump_to_match (int index) {
        string query = search_entry.get_text ().strip ();
        if (query.length == 0) return;

        var buffer = console_view.buffer;
        TextIter search_start;
        TextIter match_start;
        TextIter match_end;

        // Remove previous active highlight, keep passive highlights
        TextIter buf_start, buf_end;
        buffer.get_bounds (out buf_start, out buf_end);
        buffer.remove_tag (tag_search_active, buf_start, buf_end);

        // Walk to the Nth match
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

    // -------------------------------------------------------
    //  Public API
    // -------------------------------------------------------

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

    // -------------------------------------------------------
    //  Flush / insert
    // -------------------------------------------------------

    /**
     * Runs on the main thread via Timeout.  Grabs everything
     * accumulated since the last flush, inserts line-by-line
     * with color tags, and trims the buffer if needed.
     */
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

        // Insert each line with its appropriate color tag
        string[] lines = chunk.split ("\n");
        foreach (unowned string line in lines) {
            if (line.length == 0) continue;

            buffer.get_end_iter (out end_iter);
            int start_offset = end_iter.get_offset ();
            buffer.insert (ref end_iter, line + "\n", -1);

            unowned TextTag? tag = classify_line (line);
            if (tag != null) {
                TextIter tag_start;
                buffer.get_iter_at_offset (out tag_start, start_offset);
                buffer.get_end_iter (out end_iter);
                buffer.apply_tag (tag, tag_start, end_iter);
            }
        }

        // Trim oldest text when the buffer exceeds the cap.
        // We trim to a newline boundary so we don't leave a partial line.
        if (buffer.get_char_count () > MAX_BUFFER_CHARS) {
            TextIter trim_start;
            TextIter trim_end;
            int excess = buffer.get_char_count () - MAX_BUFFER_CHARS;

            buffer.get_start_iter (out trim_start);
            buffer.get_iter_at_offset (out trim_end, excess);

            // Advance to the next newline so we cut on a clean boundary
            if (!trim_end.ends_line ()) {
                trim_end.forward_to_line_end ();
                trim_end.forward_char ();
            }

            buffer.@delete (ref trim_start, ref trim_end);
        }

        // Auto-scroll to the bottom so the latest output is visible
        buffer.get_end_iter (out end_iter);
        console_view.scroll_to_iter (end_iter, 0.0, false, 0.0, 1.0);

        return Source.REMOVE;
    }
}
