using Gtk;
using Adw;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  StatusIcon — Semantic icon + CSS class constants for status messages
//
//  Centralizes the icon-name → CSS-class mapping so callers never need to
//  remember both values.  Each constant is a small struct-like namespace
//  with an ICON and CSS field.
// ═══════════════════════════════════════════════════════════════════════════════

namespace StatusIcon {
    // Ready / neutral / informational
    public const string INFO_ICON = "emblem-default-symbolic";
    public const string INFO_CSS  = "status-area-info";

    // Warning (user needs to take action)
    public const string WARNING_ICON = "dialog-warning-symbolic";
    public const string WARNING_CSS  = "status-area-warning";

    // Error (operation failed)
    public const string ERROR_ICON = "dialog-error-symbolic";
    public const string ERROR_CSS  = "status-area-error";

    // Success (operation completed)
    public const string SUCCESS_ICON = "video-x-generic-symbolic";
    public const string SUCCESS_CSS  = "status-area-success";

    // Progress (encoding / extracting / analyzing)
    public const string PROGRESS_ICON = "media-playback-start-symbolic";
    public const string PROGRESS_CSS  = "status-area-progress";

    // Cancelled / stopped by user
    public const string CANCELLED_ICON = "process-stop-symbolic";
    public const string CANCELLED_CSS  = "status-area-cancelled";

    // Waiting / pending / loading
    public const string WAITING_ICON = "content-loading-symbolic";
    public const string WAITING_CSS  = "status-area-info";

    // Informational notice (distinct from "ready")
    public const string NOTICE_ICON = "dialog-information-symbolic";
    public const string NOTICE_CSS  = "status-area-info";

    // Searching / analyzing (Smart Optimizer probe phase)
    public const string SEARCH_ICON = "system-search-symbolic";
    public const string SEARCH_CSS  = "status-area-progress";

    // Smart Optimizer analysis
    public const string SMART_ICON = "starred-symbolic";
    public const string SMART_CSS  = "status-area-progress";
}

// ═══════════════════════════════════════════════════════════════════════════════
//  StatusArea — Unified status + progress display with semantic icons
//
//  All methods are thread-safe (dispatch to the main loop via Idle.add).
//  Components should call these methods instead of reaching into the child
//  widgets directly.  The progress_bar property remains accessible for
//  consumers that need to construct a ProgressTracker for fine-grained
//  time-based updates (Converter, TrimRunner, SubtitlesRunner).
// ═══════════════════════════════════════════════════════════════════════════════

public class StatusArea : Box {
    private const string DEFAULT_STATUS_TEXT = "Ready. Select a file and click Convert.";
    private const string DEFAULT_STATUS_ICON = StatusIcon.INFO_ICON;
    private const string DEFAULT_STATUS_CSS  = StatusIcon.INFO_CSS;

    private Image status_icon;
    private Label status_label;
    public ProgressBar progress_bar { get; private set; }

    // Thread-safe state — all guarded by status_mutex
    private Mutex status_mutex;
    private string requested_status_text = DEFAULT_STATUS_TEXT;
    private string requested_status_icon = DEFAULT_STATUS_ICON;
    private string requested_status_css  = DEFAULT_STATUS_CSS;

    // Current CSS class applied to icon + label (main thread only)
    private string current_status_css_class = "";

    public StatusArea () {
        Object (orientation: Orientation.VERTICAL, spacing: 12);
        set_margin_top (12);
        set_margin_bottom (12);

        inject_status_area_css ();

        // Horizontal row: icon + label
        var status_row = new Box (Orientation.HORIZONTAL, 8);
        status_row.set_halign (Align.CENTER);

        status_icon = new Image.from_icon_name (DEFAULT_STATUS_ICON);
        status_icon.set_pixel_size (16);
        status_icon.set_valign (Align.CENTER);
        status_row.append (status_icon);

        status_label = new Label (DEFAULT_STATUS_TEXT);
        status_label.set_wrap (true);
        status_label.set_justify (Justification.CENTER);
        status_row.append (status_label);

        append (status_row);

        // Apply default CSS class
        apply_css_class (DEFAULT_STATUS_CSS);

        progress_bar = new ProgressBar ();
        progress_bar.set_show_text (true);
        progress_bar.set_text ("Waiting...");
        progress_bar.set_visible (false);
        append (progress_bar);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CSS injection (once per display)
    // ═════════════════════════════════════════════════════════════════════════

    private static bool css_injected = false;

    private static void inject_status_area_css () {
        if (css_injected) return;
        css_injected = true;

        var css = new CssProvider ();
        css.load_from_string (
            ".status-area-info {\n" +
            "    color: @window_fg_color;\n" +
            "}\n" +
            ".status-area-warning {\n" +
            "    color: @warning_color;\n" +
            "}\n" +
            ".status-area-error {\n" +
            "    color: @error_color;\n" +
            "}\n" +
            ".status-area-success {\n" +
            "    color: @success_color;\n" +
            "}\n" +
            ".status-area-progress {\n" +
            "    color: @accent_color;\n" +
            "}\n" +
            ".status-area-cancelled {\n" +
            "    color: @warning_color;\n" +
            "}\n"
        );
        StyleContext.add_provider_for_display (
            Gdk.Display.get_default (),
            css,
            STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Thread-safe public API
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Snapshot the full status state (text, icon, CSS class).
     * Safe from any thread. Use with replace_status_if_current() to
     * temporarily change the status and then restore the original.
     */
    public void get_full_status_snapshot (out string text,
                                          out string icon_name,
                                          out string css_class) {
        status_mutex.lock ();
        try {
            text      = requested_status_text;
            icon_name = requested_status_icon;
            css_class = requested_status_css;
        } finally {
            status_mutex.unlock ();
        }
    }

    private bool is_current_requested (string text, string icon_name, string css_class) {
        bool matches;
        status_mutex.lock ();
        try {
            matches = requested_status_text == text
                   && requested_status_icon == icon_name
                   && requested_status_css  == css_class;
        } finally {
            status_mutex.unlock ();
        }
        return matches;
    }

    /** Update the status text, icon, and semantic style. Safe from any thread. */
    public void set_status (string text,
                            string icon_name = StatusIcon.INFO_ICON,
                            string css_class = StatusIcon.INFO_CSS) {
        status_mutex.lock ();
        try {
            requested_status_text = text;
            requested_status_icon = icon_name;
            requested_status_css  = css_class;
        } finally {
            status_mutex.unlock ();
        }

        Idle.add (() => {
            if (is_current_requested (text, icon_name, css_class)) {
                apply_visuals (icon_name, text, css_class);
            }
            return Source.REMOVE;
        });
    }

    /** Replace the current status only if it still matches @expected. */
    public void replace_status_if_current (string expected, string replacement,
                                           string icon_name = StatusIcon.INFO_ICON,
                                           string css_class = StatusIcon.INFO_CSS) {
        bool should_replace = false;
        status_mutex.lock ();
        try {
            if (requested_status_text == expected) {
                requested_status_text = replacement;
                requested_status_icon = icon_name;
                requested_status_css  = css_class;
                should_replace = true;
            }
        } finally {
            status_mutex.unlock ();
        }

        if (!should_replace) {
            return;
        }

        Idle.add (() => {
            if (is_current_requested (replacement, icon_name, css_class)) {
                apply_visuals (icon_name, replacement, css_class);
            }
            return Source.REMOVE;
        });
    }

    /** Show the progress bar and start pulsing.  Safe from any thread. */
    public void start_progress () {
        Idle.add (() => {
            progress_bar.set_visible (true);
            progress_bar.pulse ();
            return Source.REMOVE;
        });
    }

    /** Hide the progress bar.  Safe from any thread. */
    public void stop_progress () {
        Idle.add (() => {
            progress_bar.set_visible (false);
            return Source.REMOVE;
        });
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Private helpers (main thread only)
    // ═════════════════════════════════════════════════════════════════════════

    private void apply_visuals (string icon_name, string text, string css_class) {
        status_icon.set_from_icon_name (icon_name);
        status_label.set_text (text);
        apply_css_class (css_class);
    }

    private void apply_css_class (string css_class) {
        if (current_status_css_class == css_class) {
            return;
        }

        if (current_status_css_class.length > 0) {
            status_icon.remove_css_class (current_status_css_class);
            status_label.remove_css_class (current_status_css_class);
        }

        status_icon.add_css_class (css_class);
        status_label.add_css_class (css_class);
        current_status_css_class = css_class;
    }
}
