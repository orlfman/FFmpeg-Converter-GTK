using Gtk;
using Adw;

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
    public Label status_label { get; private set; }
    public ProgressBar progress_bar { get; private set; }

    public StatusArea () {
        Object (orientation: Orientation.VERTICAL, spacing: 12);
        set_margin_top (12);
        set_margin_bottom (12);

        status_label = new Label ("Ready. Select a file and click Convert.");
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

    /** Update the status text.  Safe from any thread. */
    public void set_status (string text) {
        Idle.add (() => {
            status_label.set_text (text);
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
