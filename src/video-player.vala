using Gtk;

public class VideoPlayer : Box {

    // ── Widgets ──────────────────────────────────────────────────────────────
    private Gtk.Picture picture;
    private Gtk.MediaFile? media = null;
    private Gtk.Scale scrubber;
    private Gtk.Label time_label;
    private Gtk.Label duration_label;
    private Gtk.Button play_button;

    // ── State ────────────────────────────────────────────────────────────────
    private uint update_source = 0;
    private uint prepare_poll  = 0;
    private bool user_scrubbing = false;
    private bool is_playing = false;

    // ── Signals ──────────────────────────────────────────────────────────────
    public signal void position_changed (double seconds);
    public signal void media_ready (double duration_seconds);

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public VideoPlayer () {
        Object (orientation: Orientation.VERTICAL, spacing: 6);
        build_ui ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI CONSTRUCTION
    // ═════════════════════════════════════════════════════════════════════════

    private void build_ui () {

        // ── Video Display ────────────────────────────────────────────────────
        var frame = new Gtk.Frame (null);
        frame.add_css_class ("view");

        picture = new Gtk.Picture ();
        picture.set_size_request (-1, 340);
        picture.set_vexpand (false);
        picture.set_content_fit (ContentFit.CONTAIN);

        frame.set_child (picture);
        append (frame);

        // ── Scrubber ─────────────────────────────────────────────────────────
        scrubber = new Gtk.Scale.with_range (Orientation.HORIZONTAL, 0.0, 1.0, 0.001);
        scrubber.set_draw_value (false);
        scrubber.set_hexpand (true);
        scrubber.set_margin_top (4);

        scrubber.change_value.connect (on_scrubber_changed);
        append (scrubber);

        // ── Transport Controls ───────────────────────────────────────────────
        var controls = new Box (Orientation.HORIZONTAL, 6);
        controls.set_halign (Align.CENTER);
        controls.set_margin_top (2);
        controls.set_margin_bottom (4);

        // Seek back 5 s
        var seek_back = new Button.from_icon_name ("media-seek-backward-symbolic");
        seek_back.set_tooltip_text ("Seek back 5 seconds");
        seek_back.add_css_class ("flat");
        seek_back.clicked.connect (() => seek_relative (-5.0));
        controls.append (seek_back);

        // Frame back
        var frame_back = new Button.from_icon_name ("go-previous-symbolic");
        frame_back.set_tooltip_text ("Step back 1 frame (~33 ms)");
        frame_back.add_css_class ("flat");
        frame_back.clicked.connect (() => step_frame (-1));
        controls.append (frame_back);

        // Play / Pause
        play_button = new Button.from_icon_name ("media-playback-start-symbolic");
        play_button.set_tooltip_text ("Play / Pause");
        play_button.add_css_class ("circular");
        play_button.clicked.connect (toggle_playback);
        controls.append (play_button);

        // Frame forward
        var frame_fwd = new Button.from_icon_name ("go-next-symbolic");
        frame_fwd.set_tooltip_text ("Step forward 1 frame (~33 ms)");
        frame_fwd.add_css_class ("flat");
        frame_fwd.clicked.connect (() => step_frame (1));
        controls.append (frame_fwd);

        // Seek forward 5 s
        var seek_fwd = new Button.from_icon_name ("media-seek-forward-symbolic");
        seek_fwd.set_tooltip_text ("Seek forward 5 seconds");
        seek_fwd.add_css_class ("flat");
        seek_fwd.clicked.connect (() => seek_relative (5.0));
        controls.append (seek_fwd);

        // Separator
        var sep = new Separator (Orientation.VERTICAL);
        sep.set_margin_start (12);
        sep.set_margin_end (12);
        controls.append (sep);

        // Time display
        time_label = new Label ("00:00:00.000");
        time_label.add_css_class ("monospace");
        controls.append (time_label);

        var slash = new Label (" / ");
        slash.add_css_class ("dim-label");
        controls.append (slash);

        duration_label = new Label ("00:00:00.000");
        duration_label.add_css_class ("monospace");
        duration_label.add_css_class ("dim-label");
        controls.append (duration_label);

        append (controls);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PUBLIC API
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Load and prepare a video file for preview.
     */
    public void load_file (string path) {
        stop_update_timer ();
        stop_prepare_poll ();

        if (media != null) {
            media.set_playing (false);
        }

        is_playing = false;
        play_button.set_icon_name ("media-playback-start-symbolic");

        var file = GLib.File.new_for_path (path);
        media = Gtk.MediaFile.for_file (file);
        picture.set_paintable (media);

        // Two-pronged approach to detect when GStreamer finishes probing:
        //  1. Property notification (ideal, fires immediately when ready)
        //  2. Polling fallback (catches cases where notify fires before we connect)
        media.notify["prepared"].connect (() => {
            on_media_prepared ();
        });

        // Poll every 100 ms until prepared (handles the race where notify
        // already fired before our signal handler was connected)
        prepare_poll = Timeout.add (100, () => {
            if (media != null && media.is_prepared ()) {
                on_media_prepared ();
                prepare_poll = 0;
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });
    }

    /**
     * Returns the current playback position in seconds.
     */
    public double get_position_seconds () {
        if (media == null) return 0.0;
        return (double) media.get_timestamp () / 1000000.0;
    }

    /**
     * Returns the total media duration in seconds.
     */
    public double get_duration_seconds () {
        if (media == null) return 0.0;
        return (double) media.get_duration () / 1000000.0;
    }

    /**
     * Seek to an absolute position in seconds.
     */
    public void seek_to (double seconds) {
        if (media == null) return;
        int64 target = (int64) (seconds * 1000000.0);
        int64 dur = media.get_duration ();
        if (dur > 0) {
            target = target.clamp (0, dur);
        }
        media.seek (target);
    }

    /**
     * Stop playback and release timer resources.
     */
    public void cleanup () {
        stop_update_timer ();
        stop_prepare_poll ();
        if (media != null) {
            media.set_playing (false);
        }
        is_playing = false;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  TIME FORMATTING (public static for reuse)
    // ═════════════════════════════════════════════════════════════════════════

    public static string format_time (double seconds) {
        if (seconds < 0) seconds = 0;
        int total_ms = (int) (seconds * 1000.0 + 0.5);
        int h  = total_ms / 3600000;
        int m  = (total_ms % 3600000) / 60000;
        int s  = (total_ms % 60000) / 1000;
        int ms = total_ms % 1000;
        return "%02d:%02d:%02d.%03d".printf (h, m, s, ms);
    }

    /**
     * Parse a time string "HH:MM:SS.mmm" back to seconds.
     * Also accepts "HH:MM:SS" (no millis) and plain decimal seconds.
     */
    public static double parse_time (string text) {
        string t = text.strip ();
        if (t.length == 0) return 0.0;

        // Try HH:MM:SS.mmm or HH:MM:SS
        string[] parts = t.split (":");
        if (parts.length == 3) {
            double h = double.parse (parts[0]);
            double m = double.parse (parts[1]);
            double s = double.parse (parts[2]);
            return h * 3600.0 + m * 60.0 + s;
        }

        // Fallback: plain seconds
        return double.parse (t);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Playback control
    // ═════════════════════════════════════════════════════════════════════════

    private void on_media_prepared () {
        if (media == null || !media.is_prepared ()) return;

        stop_prepare_poll ();

        double dur = get_duration_seconds ();
        if (dur <= 0.0) return; // not actually ready yet

        scrubber.set_range (0.0, dur);
        scrubber.set_value (0.0);
        duration_label.set_text (format_time (dur));
        time_label.set_text (format_time (0.0));

        start_update_timer ();
        media_ready (dur);
    }

    private void toggle_playback () {
        if (media == null) return;

        if (is_playing) {
            // ── Pause ────────────────────────────────────────────────────────
            media.set_playing (false);
            is_playing = false;
            play_button.set_icon_name ("media-playback-start-symbolic");
        } else {
            // ── Play ─────────────────────────────────────────────────────────
            media.set_playing (true);
            is_playing = true;
            play_button.set_icon_name ("media-playback-pause-symbolic");
        }
    }

    private void seek_relative (double seconds) {
        if (media == null) return;
        int64 current = media.get_timestamp ();
        int64 target = current + (int64) (seconds * 1000000.0);
        int64 dur = media.get_duration ();
        if (dur > 0) {
            target = target.clamp (0, dur);
        }
        media.seek (target);
    }

    private void step_frame (int direction) {
        if (media == null) return;

        // Pause first so the user sees the exact frame
        if (is_playing) {
            media.set_playing (false);
            is_playing = false;
            play_button.set_icon_name ("media-playback-start-symbolic");
        }
        // ~33 ms per frame at 30 fps — a reasonable default
        seek_relative (direction * (1.0 / 30.0));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Scrubber
    // ═════════════════════════════════════════════════════════════════════════

    private bool on_scrubber_changed (ScrollType scroll_type, double new_value) {
        if (media == null) return false;

        user_scrubbing = true;

        int64 seek_pos = (int64) (new_value * 1000000.0);
        int64 dur = media.get_duration ();
        if (dur > 0) {
            seek_pos = seek_pos.clamp (0, dur);
        }
        media.seek (seek_pos);
        time_label.set_text (format_time (new_value));

        // Release the flag after a short delay so the update timer
        // doesn't fight with drag events.
        Timeout.add (120, () => {
            user_scrubbing = false;
            return Source.REMOVE;
        });

        return false; // let default handler update scale value
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Periodic position update
    // ═════════════════════════════════════════════════════════════════════════

    private void start_update_timer () {
        stop_update_timer ();
        update_source = Timeout.add (100, () => {
            if (!user_scrubbing && media != null) {
                double pos = get_position_seconds ();
                scrubber.set_value (pos);
                time_label.set_text (format_time (pos));
                position_changed (pos);

                // Sync our play state if GStreamer stopped on its own
                // (e.g. reached end of file)
                bool gst_playing = media.get_playing ();
                if (is_playing && !gst_playing) {
                    is_playing = false;
                    play_button.set_icon_name ("media-playback-start-symbolic");
                }
            }
            return Source.CONTINUE;
        });
    }

    private void stop_update_timer () {
        if (update_source != 0) {
            Source.remove (update_source);
            update_source = 0;
        }
    }

    private void stop_prepare_poll () {
        if (prepare_poll != 0) {
            Source.remove (prepare_poll);
            prepare_poll = 0;
        }
    }
}
