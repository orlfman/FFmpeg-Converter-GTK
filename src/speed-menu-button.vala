using Gtk;

// ═══════════════════════════════════════════════════════════════════════════════
//  SpeedMenuButton — Playback rate selector shared by AudioPlayer and VideoPlayer
//
//  Drives mpv's "speed" property, which scales playback without touching the
//  media clock: time-pos still reports source time, so trim points read back at
//  0.5x are the same coordinates they would be at 1x.  This is a preview
//  convenience only and never reaches the FFmpeg command line.
//
//  The rate stays on the button face rather than living only inside the popover.
//  A transport quietly left at 0.25x reads as a stuttering decoder rather than a
//  setting, and the first instinct is to blame the file.
//
//  Wraps a Gtk.MenuButton rather than deriving from one: GtkMenuButton is final
//  in GTK4 and cannot be subclassed.
// ═══════════════════════════════════════════════════════════════════════════════

public class SpeedMenuButton : Box {

    // Deliberately narrower than mpv's own 0.01–100 range. Past roughly half to
    // double, scaletempo2 — the pitch correction mpv inserts by default — starts
    // smearing speech badly enough that the preview stops being useful for
    // picking cut points by ear.
    private const double[] RATES = {
        0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0
    };
    private const string[] RATE_LABELS = {
        "0.25×", "0.5×", "0.75×", "1×",
        "1.25×", "1.5×", "2×"
    };
    private const int NORMAL_INDEX = 3;

    private Gtk.MenuButton button;
    private Gtk.Label face;
    private Gtk.CheckButton[] items;
    private int active_index = NORMAL_INDEX;

    // Set while the selection is being put back programmatically, so reset ()
    // does not report a rate change at a player that is closing its backend.
    private bool restoring = false;

    /** Emitted only for user-driven changes, never for reset (). */
    public signal void speed_changed (double speed);

    /** The selected rate, ready to hand to MpvBackend.set_speed (). */
    public double speed {
        get { return RATES[active_index]; }
    }

    public SpeedMenuButton () {
        Object (orientation: Orientation.HORIZONTAL, spacing: 0);

        // The three constants above have to move together. Inserting a rate
        // into RATES alone would shift NORMAL_INDEX off 1.0, and every "reset
        // to normal" would quietly land on a different speed instead.
        assert (RATES.length == RATE_LABELS.length);
        assert (RATES[NORMAL_INDEX] == 1.0);

        items = new Gtk.CheckButton[RATES.length];

        face = new Gtk.Label (RATE_LABELS[NORMAL_INDEX]);
        // Fixed width: the face swings between "1x" and "0.25x", and a button
        // that resized with it would shunt the time readout and pop-out button
        // sideways every time the rate changed.
        face.set_width_chars (5);

        button = new Gtk.MenuButton ();
        button.set_child (face);
        button.set_always_show_arrow (true);
        button.set_tooltip_text ("Playback speed — affects preview only, not output");

        var list = new Box (Orientation.VERTICAL, 0);
        list.set_margin_top (6);
        list.set_margin_bottom (6);
        list.set_margin_start (6);
        list.set_margin_end (6);

        for (int i = 0; i < RATES.length; i++) {
            var item = new Gtk.CheckButton.with_label (RATE_LABELS[i]);
            if (i > 0) {
                item.set_group (items[0]);
            }
            item.set_active (i == NORMAL_INDEX);

            // Bind the index per iteration. Capturing the loop variable itself
            // would leave every handler reading its final value.
            int index = i;
            item.toggled.connect (() => on_item_toggled (index));

            items[i] = item;
            list.append (item);
        }

        var popover = new Gtk.Popover ();
        popover.set_child (list);
        button.set_popover (popover);

        append (button);
    }

    /**
     * Return to 1x without reporting a change.
     *
     * Called from the players' reset path, where the mpv core is being torn
     * down and has no rate left to set. The next load re-applies the selection
     * from `speed`, so nothing is lost by staying quiet here.
     */
    public void reset () {
        if (active_index == NORMAL_INDEX) return;

        restoring = true;
        items[NORMAL_INDEX].set_active (true);
        restoring = false;
    }

    private void on_item_toggled (int index) {
        // Switching radio buttons toggles two of them; only the one being
        // selected carries the new rate.
        if (!items[index].get_active ()) return;

        active_index = index;
        face.set_text (RATE_LABELS[index]);
        button.popdown ();

        if (!restoring) {
            speed_changed (RATES[index]);
        }
    }

#if COMBINE_WINDOW_TEST_BUILD
    internal string get_face_text_for_widget_test () {
        return face.get_text ();
    }

    internal void select_rate_for_widget_test (double rate) {
        for (int i = 0; i < RATES.length; i++) {
            if (RATES[i] == rate) {
                items[i].set_active (true);
                return;
            }
        }
        assert_not_reached ();
    }
#endif
}
