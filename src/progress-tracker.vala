using Gtk;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  ProgressTracker — Progress bar and pulsing management
//
//  Extracted from Converter to give it a single responsibility.
//  Handles determinate progress, indeterminate pulsing, and visibility
//  transitions. All UI updates are dispatched via Idle.add for thread safety.
// ═══════════════════════════════════════════════════════════════════════════════

public class ProgressTracker : Object {

    private ProgressBar progress_bar;
    private uint pulse_source = 0;

    // ── Thread-safe progress state ──────────────────────────────────────────
    private Mutex progress_mutex = Mutex ();
    private bool use_pulse_mode = false;
    private int64 last_progress_update = 0;

    public ProgressTracker (ProgressBar bar) {
        this.progress_bar = bar;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PULSE MODE STATE (thread-safe)
    // ═════════════════════════════════════════════════════════════════════════

    public void set_pulse_mode (bool pulse) {
        progress_mutex.lock ();
        use_pulse_mode = pulse;
        progress_mutex.unlock ();
    }

    public bool get_pulse_mode () {
        progress_mutex.lock ();
        bool p = use_pulse_mode;
        progress_mutex.unlock ();
        return p;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SHOW / HIDE
    // ═════════════════════════════════════════════════════════════════════════

    /** Show pulsing progress (used initially, before duration is known). */
    public void show_pulse () {
        Idle.add (() => {
            progress_bar.set_visible (true);
            progress_bar.set_text ("Processing...");
            start_pulsing ();
            return Source.REMOVE;
        });
    }

    /** Show determinate progress starting from 0%. */
    public void show_determinate () {
        Idle.add (() => {
            stop_pulsing ();
            progress_bar.set_visible (true);
            progress_bar.set_fraction (0.0);
            progress_bar.set_text ("0.0%");
            return Source.REMOVE;
        });
    }

    /** Switch from pulse to determinate mode (e.g. once duration is known). */
    public void switch_to_determinate () {
        set_pulse_mode (false);
        Idle.add (() => {
            stop_pulsing ();
            progress_bar.set_fraction (0.0);
            progress_bar.set_text ("0.0%");
            return Source.REMOVE;
        });
    }

    public void hide () {
        Idle.add (() => {
            stop_pulsing ();
            bool pulse = get_pulse_mode ();
            progress_bar.set_fraction (1.0);
            progress_bar.set_text (pulse ? "Done" : "100%");

            Timeout.add (800, () => {
                progress_bar.set_visible (false);
                progress_bar.set_text ("Waiting...");
                return Source.REMOVE;
            });
            return Source.REMOVE;
        });
    }

    public void hide_cancelled () {
        Idle.add (() => {
            stop_pulsing ();
            progress_bar.set_visible (false);
            progress_bar.set_text ("Cancelled");
            return Source.REMOVE;
        });
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UPDATE (throttled to ~4/sec for thread-safe progress from background)
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Update progress as a percentage (0–100).
     * Throttled to avoid flooding the main loop.
     */
    public void update_percent (double percent) {
        Idle.add (() => {
            progress_bar.set_fraction (percent / 100.0);
            progress_bar.set_text (@"%.1f%%".printf (percent));
            return Source.REMOVE;
        });
    }

    /**
     * Update progress based on current time vs total duration.
     * Applies throttling (~4 updates/sec). Returns true if an update was sent.
     *
     * @param current_sec  Current position in seconds (from FFmpeg stderr)
     * @param total_dur    Total duration in seconds
     * @param pass_start   Start percentage for this pass (0 or 50 for two-pass)
     * @param pass_range   Range percentage for this pass (50 or 100)
     */
    public bool update_from_time (double current_sec, double total_dur,
                                  double pass_start, double pass_range) {
        if (current_sec < 0 || total_dur <= 0) return false;

        progress_mutex.lock ();
        int64 now = GLib.get_monotonic_time ();
        bool should_update = (now - last_progress_update > 250000);
        if (should_update) last_progress_update = now;
        progress_mutex.unlock ();

        if (!should_update) return false;

        double fraction = (current_sec / total_dur).clamp (0.0, 1.0);
        double percent = pass_start + (fraction * pass_range);
        update_percent (percent);
        return true;
    }

    /**
     * Reset the throttle timer (call at the start of each new operation).
     */
    public void reset_throttle () {
        progress_mutex.lock ();
        last_progress_update = 0;
        progress_mutex.unlock ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PULSING
    // ═════════════════════════════════════════════════════════════════════════

    private void start_pulsing () {
        stop_pulsing ();
        pulse_source = Timeout.add (320, () => {
            Idle.add (() => {
                progress_bar.pulse ();
                return Source.REMOVE;
            });
            return Source.CONTINUE;
        });
    }

    public void stop_pulsing () {
        if (pulse_source != 0) {
            Source.remove (pulse_source);
            pulse_source = 0;
        }
    }
}
