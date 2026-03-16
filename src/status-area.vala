using Gtk;
using Adw;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  StatusArea — Unified status + progress display
//
//  All methods are thread-safe (dispatch to the main loop via Idle.add).
//  Components should call these methods instead of reaching into the child
//  widgets directly.  The progress_bar property remains accessible for
//  consumers that need to construct a ProgressTracker for fine-grained
//  time-based updates (Converter, TrimRunner, SubtitlesRunner).
// ═══════════════════════════════════════════════════════════════════════════════

public class StatusArea : Box {
    private const string DEFAULT_STATUS_TEXT = "Ready. Select a file and click Convert.";

    private Label status_label;
    public ProgressBar progress_bar { get; private set; }
    private Mutex status_text_mutex;
    private string requested_status_text = DEFAULT_STATUS_TEXT;

    public StatusArea () {
        Object (orientation: Orientation.VERTICAL, spacing: 12);
        set_margin_top (12);
        set_margin_bottom (12);

        status_label = new Label (DEFAULT_STATUS_TEXT);
        status_label.set_wrap (true);
        status_label.set_justify (Justification.CENTER);
        append (status_label);

        progress_bar = new ProgressBar ();
        progress_bar.set_show_text (true);
        progress_bar.set_text ("Waiting...");
        progress_bar.set_visible (false);
        append (progress_bar);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Thread-safe public API
    // ═════════════════════════════════════════════════════════════════════════

    /** Return the most recently requested status text. Safe from any thread. */
    public string get_status_snapshot () {
        string text;
        status_text_mutex.lock ();
        try {
            text = requested_status_text;
        } finally {
            status_text_mutex.unlock ();
        }
        return text;
    }

    private bool is_current_requested_status (string text) {
        bool matches;
        status_text_mutex.lock ();
        try {
            matches = requested_status_text == text;
        } finally {
            status_text_mutex.unlock ();
        }
        return matches;
    }

    /** Update the status text.  Safe from any thread. */
    public void set_status (string text) {
        status_text_mutex.lock ();
        try {
            requested_status_text = text;
        } finally {
            status_text_mutex.unlock ();
        }

        Idle.add (() => {
            if (is_current_requested_status (text)) {
                status_label.set_text (text);
            }
            return Source.REMOVE;
        });
    }

    /** Replace the current status only if it still matches @expected. */
    public void replace_status_if_current (string expected, string replacement) {
        bool should_replace = false;
        status_text_mutex.lock ();
        try {
            if (requested_status_text == expected) {
                requested_status_text = replacement;
                should_replace = true;
            }
        } finally {
            status_text_mutex.unlock ();
        }

        if (!should_replace) {
            return;
        }

        Idle.add (() => {
            if (is_current_requested_status (replacement)) {
                status_label.set_text (replacement);
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
}
