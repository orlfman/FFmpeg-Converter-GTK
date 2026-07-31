using Gtk;

public class VideoPlayer : Box {

    // ── Widgets ──────────────────────────────────────────────────────────────
    private Gtk.Picture picture;
    private Gtk.Scale scrubber;
    private Gtk.Label time_label;
    private Gtk.Label duration_label;
    private Gtk.Button play_button;
    private Gtk.ToggleButton mute_button;
    private SpeedMenuButton speed_button;
    private Gtk.Button popout_btn;
    private Gtk.Button fullscreen_btn;
    private Gtk.ShortcutController fullscreen_shortcuts;
    private Gtk.Overlay video_overlay;
    private Gtk.Label media_status_label;

    // ── Crop Overlay ─────────────────────────────────────────────────────────
    private CropOverlay _crop_overlay;
    public  CropOverlay crop_overlay { get { return _crop_overlay; } }

    // ── Playback backend ─────────────────────────────────────────────────────
    // libmpv rather than Gtk.MediaFile: the latter is playbin3-based and buffers
    // whole AV1-in-Matroska files into memory.  See
    // docs/upstream-gstreamer-playbin3-matroska-memory.md.
    private MpvBackend backend;

    // ── State ────────────────────────────────────────────────────────────────
    private uint update_source = 0;
    private uint scrub_reset_source = 0;
    private bool user_scrubbing = false;
    private bool is_playing = false;
    private bool prepared_handled = false;

    // ── Video intrinsic size ─────────────────────────────────────────────────
    private int _intrinsic_width  = 0;
    private int _intrinsic_height = 0;
    public  int intrinsic_width  { get { return _intrinsic_width;  } }
    public  int intrinsic_height { get { return _intrinsic_height; } }

    // ── Signals ──────────────────────────────────────────────────────────────
    public signal void position_changed (double seconds);
    public signal void media_ready (double duration_seconds);
    public signal void media_failed (string message);
    public signal void popout_requested ();
    public signal void fullscreen_requested ();

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public VideoPlayer () {
        Object (orientation: Orientation.VERTICAL, spacing: 6);
        PlayerStyles.ensure_loaded ();
        build_ui ();

        backend = new MpvBackend (true);
        backend.attach_picture (picture);
        backend.file_loaded.connect (on_media_prepared);
        backend.video_size_changed.connect (on_video_size_changed);
        backend.load_failed.connect (on_backend_load_failed);
        // Seeks and frame steps land asynchronously, so the transport reads the
        // new position when mpv says it has arrived rather than polling for it.
        backend.playback_restarted.connect (sync_position);
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

        // Wrap picture in an Overlay so the crop overlay can sit on top
        video_overlay = new Gtk.Overlay ();
        video_overlay.set_child (picture);

        // Create crop overlay (hidden by default)
        _crop_overlay = new CropOverlay ();
        _crop_overlay.set_visible (false);
        video_overlay.add_overlay (_crop_overlay);

        frame.set_child (video_overlay);
        append (frame);

        media_status_label = new Gtk.Label ("");
        media_status_label.set_wrap (true);
        media_status_label.set_justify (Justification.CENTER);
        media_status_label.set_margin_top (6);
        media_status_label.set_visible (false);
        append (media_status_label);

        // ── Scrubber ─────────────────────────────────────────────────────────
        scrubber = new Gtk.Scale.with_range (Orientation.HORIZONTAL, 0.0, 1.0, 0.001);
        scrubber.set_draw_value (false);
        scrubber.set_hexpand (true);
        scrubber.set_margin_top (4);
        scrubber.set_sensitive (false);

        scrubber.change_value.connect (on_scrubber_changed);
        append (scrubber);

        // ── Transport Controls ───────────────────────────────────────────────
        var controls = new Box (Orientation.HORIZONTAL, 0);
        controls.set_halign (Align.CENTER);
        controls.set_margin_top (8);
        controls.set_margin_bottom (4);
        controls.add_css_class ("transport-bar");

        // Back seek group — linked
        var back_group = new Box (Orientation.HORIZONTAL, 0);
        back_group.add_css_class ("linked");

        var seek_back = new Button.from_icon_name (
            "video-seek-backward-five-seconds-symbolic"
        );
        seek_back.set_tooltip_text ("Seek back 5 seconds");
        seek_back.clicked.connect (() => seek_relative (-5.0));
        back_group.append (seek_back);

        var seek_back_one = new Button.from_icon_name (
            "video-seek-backward-one-second-symbolic"
        );
        seek_back_one.set_tooltip_text ("Seek back 1 second");
        seek_back_one.clicked.connect (() => seek_relative (-1.0));
        back_group.append (seek_back_one);

        var frame_back = new Button.from_icon_name (
            "video-seek-backward-frame-symbolic"
        );
        frame_back.set_tooltip_text ("Step back exactly 1 frame");
        frame_back.clicked.connect (() => step_frame (-1));
        back_group.append (frame_back);

        controls.append (back_group);

        // Play / Pause — center focus
        play_button = new Button.from_icon_name ("media-playback-start-symbolic");
        play_button.set_tooltip_text ("Play / Pause");
        play_button.add_css_class ("suggested-action");
        play_button.add_css_class ("circular");
        play_button.set_margin_start (10);
        play_button.set_margin_end (10);
        play_button.clicked.connect (toggle_playback);
        controls.append (play_button);

        // Forward seek group — linked
        var fwd_group = new Box (Orientation.HORIZONTAL, 0);
        fwd_group.add_css_class ("linked");

        var frame_fwd = new Button.from_icon_name (
            "video-seek-forward-frame-symbolic"
        );
        frame_fwd.set_tooltip_text ("Step forward exactly 1 frame");
        frame_fwd.clicked.connect (() => step_frame (1));
        fwd_group.append (frame_fwd);

        var seek_fwd_one = new Button.from_icon_name (
            "video-seek-forward-one-second-symbolic"
        );
        seek_fwd_one.set_tooltip_text ("Seek forward 1 second");
        seek_fwd_one.clicked.connect (() => seek_relative (1.0));
        fwd_group.append (seek_fwd_one);

        var seek_fwd = new Button.from_icon_name (
            "video-seek-forward-five-seconds-symbolic"
        );
        seek_fwd.set_tooltip_text ("Seek forward 5 seconds");
        seek_fwd.clicked.connect (() => seek_relative (5.0));
        fwd_group.append (seek_fwd);

        controls.append (fwd_group);

        // Mute toggle
        mute_button = new Gtk.ToggleButton ();
        mute_button.set_icon_name ("audio-volume-high-symbolic");
        mute_button.set_tooltip_text ("Mute audio");
        mute_button.set_margin_start (10);
        mute_button.toggled.connect (on_mute_toggled);
        controls.append (mute_button);

        // Playback speed
        speed_button = new SpeedMenuButton ();
        speed_button.set_margin_start (6);
        speed_button.set_sensitive (false);
        speed_button.speed_changed.connect (on_speed_changed);
        controls.append (speed_button);

        // Time display — styled readout
        var time_box = new Box (Orientation.HORIZONTAL, 4);
        time_box.add_css_class ("transport-time");
        time_box.set_margin_start (14);

        time_label = new Label ("00:00:00.000");
        time_label.add_css_class ("monospace");
        time_box.append (time_label);

        var slash = new Label ("/");
        slash.add_css_class ("dim-label");
        time_box.append (slash);

        duration_label = new Label ("00:00:00.000");
        duration_label.add_css_class ("monospace");
        duration_label.add_css_class ("dim-label");
        time_box.append (duration_label);

        controls.append (time_box);

        // Pop-out button — detach the player into its own window
        popout_btn = new Button.from_icon_name ("view-fullscreen-symbolic");
        popout_btn.set_tooltip_text ("Pop out video player into separate window");
        popout_btn.set_margin_start (10);
        popout_btn.clicked.connect (() => popout_requested ());
        controls.append (popout_btn);

        // Fullscreen is separate from pop-out. The containing window owns the
        // actual window-state transition because this widget is also embedded
        // directly in Crop & Trim, where fullscreening its root would enlarge
        // the whole application rather than the preview.
        fullscreen_btn = new Button.from_icon_name (
            "video-fullscreen-symbolic"
        );
        fullscreen_btn.set_tooltip_text ("Enter fullscreen");
        fullscreen_btn.set_margin_start (6);
        fullscreen_btn.clicked.connect (() => fullscreen_requested ());
        controls.append (fullscreen_btn);

        append (controls);

        // Global means F11 works anywhere in the window that currently owns a
        // visible player. When Crop & Trim is embedded this opens its existing
        // pop-out directly into fullscreen; after reparenting, the same
        // controller naturally follows the player into the preview window.
        fullscreen_shortcuts = new Gtk.ShortcutController ();
        fullscreen_shortcuts.set_scope (Gtk.ShortcutScope.GLOBAL);
        fullscreen_shortcuts.add_shortcut (new Gtk.Shortcut (
            new Gtk.KeyvalTrigger (Gdk.Key.F11, (Gdk.ModifierType) 0),
            new Gtk.CallbackAction (activate_fullscreen_shortcut)
        ));
        add_controller (fullscreen_shortcuts);
    }

    // Keep this callback static. Gtk.CallbackAction retains its callback data,
    // so capturing `this` here would create a cycle through the shortcut that
    // prevents a closed VideoPlayer from ever being finalized.
    private static bool activate_fullscreen_shortcut (Gtk.Widget widget,
                                                      Variant? args) {
        var target = widget as VideoPlayer;
        if (target == null) return false;
        target.fullscreen_requested ();
        return true;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PUBLIC API
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Load and prepare a video file for preview.
     */
    public void load_file (string path) {
        reset_player_state ();

        if (!backend.open (path)) {
            handle_load_failure ("Could not start the video preview.");
            return;
        }

        backend.set_muted (mute_button.get_active ());
        backend.set_speed (speed_button.speed);
    }

    /**
     * Clear the current preview and reset all playback state.
     */
    public void clear () {
        reset_player_state ();
    }

    /**
     * Returns the current playback position in seconds.
     */
    public double get_position_seconds () {
        return backend.get_position ();
    }

    /**
     * Returns the total media duration in seconds.
     */
    public double get_duration_seconds () {
        return backend.duration;
    }

    /**
     * Seek to an absolute position in seconds.
     */
    public void seek_to (double seconds) {
        backend.seek_absolute (seconds);
    }

    /**
     * Show or hide the interactive crop overlay on top of the video.
     */
    public void set_crop_active (bool active) {
        _crop_overlay.set_visible (active);
        if (active && _intrinsic_width > 0) {
            push_crop_overlay_size ();
        }
    }

    /**
     * Hand the crop overlay its coordinate space. The display aspect has to
     * travel with the dimensions every time — passing the size alone would
     * quietly fall back to square pixels and shift the rectangle away from the
     * video on an anamorphic source.
     */
    private void push_crop_overlay_size () {
        _crop_overlay.set_video_size (_intrinsic_width, _intrinsic_height,
                                      backend.display_aspect);
    }

    /**
     * Update the pop-out button icon to reflect the current state.
     */
    public void set_popout_icon (bool is_popped_out) {
        popout_btn.set_icon_name (is_popped_out
            ? "view-restore-symbolic"
            : "view-fullscreen-symbolic");
        popout_btn.set_tooltip_text (is_popped_out
            ? "Return video player to main window"
            : "Pop out video player into separate window");
    }

    /**
     * Show or hide the pop-out button for contexts that do not support it.
     */
    public void set_popout_visible (bool visible) {
        popout_btn.set_visible (visible);
    }

    /**
     * Synchronize presentation after the containing preview window actually
     * enters or leaves fullscreen. Watching the window's state rather than the
     * button request also handles compositor shortcuts and rejected requests.
     */
    public void set_fullscreen_state (bool fullscreen) {
        fullscreen_btn.set_icon_name (fullscreen
            ? "video-unfullscreen-symbolic"
            : "video-fullscreen-symbolic");
        fullscreen_btn.set_tooltip_text (fullscreen
            ? "Exit fullscreen"
            : "Enter fullscreen");

        // The embedded player intentionally stays 340 px high. In a dedicated
        // fullscreen window, let the picture claim the remaining vertical
        // space; the backend independently caps CPU rendering at 1920x1080.
        picture.set_vexpand (fullscreen);
    }

    /**
     * Stop playback and release timer resources.
     */
    public void cleanup () {
        reset_player_state ();
    }

    public override void dispose () {
        cleanup ();
        base.dispose ();
    }

#if COMBINE_WINDOW_TEST_BUILD
    internal bool is_popout_visible_for_widget_test () {
        return popout_btn.get_visible ();
    }

    internal bool is_fullscreen_visible_for_widget_test () {
        return fullscreen_btn.get_visible ();
    }

    internal string fullscreen_icon_for_widget_test () {
        return fullscreen_btn.get_icon_name () ?? "";
    }

    internal string popout_icon_for_widget_test () {
        return popout_btn.get_icon_name () ?? "";
    }

    internal string fullscreen_tooltip_for_widget_test () {
        return fullscreen_btn.get_tooltip_text () ?? "";
    }

    internal bool picture_expands_for_widget_test () {
        return picture.get_vexpand ();
    }

    internal int picture_height_for_widget_test () {
        return picture.get_height ();
    }

    internal void click_fullscreen_for_widget_test () {
        fullscreen_btn.clicked ();
    }

    internal void click_popout_for_widget_test () {
        popout_btn.clicked ();
    }

    internal string fullscreen_shortcut_trigger_for_widget_test () {
        var shortcut = fullscreen_shortcuts.get_item (0) as Gtk.Shortcut;
        return shortcut != null && shortcut.get_trigger () != null
            ? shortcut.get_trigger ().to_string ()
            : "";
    }

    internal bool fullscreen_shortcut_is_global_for_widget_test () {
        return fullscreen_shortcuts.get_scope () == Gtk.ShortcutScope.GLOBAL;
    }

    internal bool activate_fullscreen_shortcut_for_widget_test () {
        var shortcut = fullscreen_shortcuts.get_item (0) as Gtk.Shortcut;
        if (shortcut == null || shortcut.get_action () == null) return false;
        return shortcut.get_action ().activate (
            Gtk.ShortcutActionFlags.EXCLUSIVE, this, null);
    }

    internal void prepare_duration_for_widget_test (double duration_seconds) {
        complete_media_preparation (duration_seconds);
    }

    internal void fail_for_widget_test (string message) {
        handle_load_failure (message);
    }

    internal string get_duration_text_for_widget_test () {
        return duration_label.get_text ();
    }

    internal double get_scrubber_upper_for_widget_test () {
        return scrubber.get_adjustment ().get_upper ();
    }

    internal bool is_scrubber_sensitive_for_widget_test () {
        return scrubber.get_sensitive ();
    }

    internal SpeedMenuButton speed_button_for_widget_test () {
        return speed_button;
    }

    internal double backend_speed_for_widget_test () {
        return backend.get_speed ();
    }

    internal bool is_media_status_visible_for_widget_test () {
        return media_status_label.get_visible ();
    }

    internal string get_media_status_for_widget_test () {
        return media_status_label.get_text ();
    }

    internal bool is_backend_core_active_for_widget_test () {
        return backend.has_core_for_test ();
    }

    internal bool is_backend_render_context_active_for_widget_test () {
        return backend.has_render_context_for_test ();
    }

    internal bool is_backend_event_source_active_for_widget_test () {
        return backend.has_event_source_for_test ();
    }

    internal bool is_backend_render_tick_active_for_widget_test () {
        return backend.has_render_tick_for_test ();
    }

    internal double backend_timing_offset_for_widget_test () {
        return backend.effective_timing_offset_for_test ();
    }
#endif

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
    public static bool try_parse_time (string text, out double seconds) {
        seconds = 0.0;

        string t = text.strip ();
        if (t.length == 0) return false;

        // Try HH:MM:SS.mmm or HH:MM:SS
        string[] parts = t.split (":");
        if (parts.length == 3) {
            if (!Regex.match_simple ("^[0-9]+$", parts[0])
                || !Regex.match_simple ("^[0-9]{1,2}$", parts[1])
                || !Regex.match_simple ("^[0-9]{1,2}(\\.[0-9]+)?$", parts[2])) {
                return false;
            }

            double h = double.parse (parts[0]);
            double m = double.parse (parts[1]);
            double s = double.parse (parts[2]);
            if (m >= 60.0 || s >= 60.0) {
                return false;
            }

            seconds = h * 3600.0 + m * 60.0 + s;
            return true;
        }

        // Fallback: plain seconds
        if (!Regex.match_simple ("^[0-9]+(\\.[0-9]+)?$", t)) {
            return false;
        }

        seconds = double.parse (t);
        return true;
    }

    public static double parse_time (string text) {
        double seconds = 0.0;
        try_parse_time (text, out seconds);
        return seconds;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Playback control
    // ═════════════════════════════════════════════════════════════════════════

    private void cancel_scrub_reset () {
        if (scrub_reset_source != 0) {
            Source.remove (scrub_reset_source);
            scrub_reset_source = 0;
        }
    }

    private void reset_player_state () {
        stop_update_timer ();
        cancel_scrub_reset ();

        // Tears the mpv core down outright rather than leaving it idle, so the
        // demuxer buffers and decoder working set are handed back immediately.
        backend.close ();

        user_scrubbing = false;
        is_playing = false;
        _intrinsic_width  = 0;
        _intrinsic_height = 0;
        prepared_handled = false;
        play_button.set_icon_name ("media-playback-start-symbolic");
        // Rate is per-preview: a 0.25x left over from the previous file would
        // otherwise look like the new one decodes badly.
        speed_button.reset ();
        speed_button.set_sensitive (false);
        scrubber.set_range (0.0, 1.0);
        scrubber.set_value (0.0);
        scrubber.set_sensitive (false);
        time_label.set_text (format_time (0.0));
        duration_label.set_text (format_time (0.0));
        hide_media_status ();
    }

    private void on_backend_load_failed (string detail) {
        handle_load_failure ("Could not load the video preview (%s).".printf (detail));
    }

    private void handle_load_failure (string message) {
        // A bad or unsupported user-selected file is an expected runtime
        // outcome, already surfaced inline and through media_failed.
        GLib.message ("VideoPlayer: %s", message);
        reset_player_state ();
        show_media_status (message, true);
        media_failed (message);
    }

    private void show_media_status (string message, bool is_error) {
        media_status_label.set_text (message);
        media_status_label.remove_css_class ("error");
        media_status_label.remove_css_class ("warning");
        media_status_label.add_css_class (is_error ? "error" : "warning");
        media_status_label.set_visible (true);
    }

    private void hide_media_status () {
        media_status_label.set_visible (false);
        media_status_label.set_text ("");
        media_status_label.remove_css_class ("error");
        media_status_label.remove_css_class ("warning");
    }

    private void on_media_prepared () {
        complete_media_preparation (backend.duration);
    }

    private void complete_media_preparation (double dur) {

        // mpv reports file-loaded once per load, but stay idempotent so a
        // repeated notification cannot restart the update timer.
        if (prepared_handled) return;
        prepared_handled = true;

        // Unlike the scrubber, rate selection does not need a known duration.
        speed_button.set_sensitive (true);

        if (dur > 0.0) {
            scrubber.set_range (0.0, dur);
            scrubber.set_sensitive (true);
            duration_label.set_text (format_time (dur));
            hide_media_status ();
        } else {
            scrubber.set_range (0.0, 1.0);
            scrubber.set_sensitive (false);
            duration_label.set_text ("--:--:--.---");
            show_media_status (
                "Duration unavailable — timeline seeking is disabled.",
                false
            );
        }
        scrubber.set_value (0.0);
        time_label.set_text (format_time (0.0));

        // The coordinate space ffmpeg's crop filter works in: rotation applied,
        // sample aspect not. TrimRunner reports output sizes in it too, so it
        // must match what goes into the crop string.
        _intrinsic_width  = backend.crop_width;
        _intrinsic_height = backend.crop_height;

        // Keep the crop overlay informed of the video size
        push_crop_overlay_size ();

        // Media opens paused, so there is nothing to track yet — one reading is
        // enough until the user starts playback.
        sync_position ();
        media_ready (dur);
    }

    /**
     * Re-latch the video dimensions when mpv corrects them.
     *
     * Not redundant with on_media_prepared (): the first size mpv reports can be
     * the container's claim rather than the decoder's, and containers get it
     * wrong. Without this the crop coordinate space would stay wrong for the
     * whole session on such a file.
     */
    private void on_video_size_changed () {
        int w = backend.crop_width;
        int h = backend.crop_height;

        if (w <= 0 || h <= 0) return;

        _intrinsic_width  = w;
        _intrinsic_height = h;

        // Always re-push: the display aspect can settle on a later reconfig even
        // when the crop dimensions themselves did not change.
        push_crop_overlay_size ();
    }

    private void toggle_playback () {
        if (!backend.loaded) return;

        if (is_playing) {
            // ── Pause ────────────────────────────────────────────────────────
            backend.set_playing (false);
            is_playing = false;
            play_button.set_icon_name ("media-playback-start-symbolic");
            // Nothing will move the position again until the user does, so take
            // a final reading and stop waking for it.
            stop_update_timer ();
            sync_position ();
        } else {
            // ── Play ─────────────────────────────────────────────────────────
            backend.set_playing (true);
            is_playing = true;
            play_button.set_icon_name ("media-playback-pause-symbolic");
            start_update_timer ();
        }
    }

    private void on_mute_toggled () {
        bool muted = mute_button.get_active ();

        backend.set_muted (muted);

        mute_button.set_icon_name (muted
            ? "audio-volume-muted-symbolic"
            : "audio-volume-high-symbolic");
        mute_button.set_tooltip_text (muted
            ? "Unmute audio"
            : "Mute audio");
    }

    private void on_speed_changed (double speed) {
        backend.set_speed (speed);
    }

    private void seek_relative (double seconds) {
        backend.seek_relative (seconds);
    }

    private void step_frame (int direction) {
        if (!backend.loaded) return;

        // Pause first so the user sees the exact frame
        if (is_playing) {
            is_playing = false;
            play_button.set_icon_name ("media-playback-start-symbolic");
            stop_update_timer ();
        }

        // mpv steps by decoded frames, so this lands on the true adjacent frame
        // instead of seeking by an assumed frame duration.
        backend.frame_step (direction);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Scrubber
    // ═════════════════════════════════════════════════════════════════════════

    private bool on_scrubber_changed (ScrollType scroll_type, double new_value) {
        if (!backend.loaded) return false;

        user_scrubbing = true;

        // Always an exact seek, never a keyframe one. TrimTab reads
        // get_position_seconds () straight from the backend when a trim point is
        // set, so the real position must match the frame on screen at every
        // instant — deferring precision to the end of the drag would leave a
        // window where a trim point captures the preceding keyframe instead.
        backend.seek_absolute (new_value);
        time_label.set_text (format_time (new_value));

        // Cancel any previous anti-fight timeout to prevent stacking
        if (scrub_reset_source != 0) {
            Source.remove (scrub_reset_source);
            scrub_reset_source = 0;
        }

        // Release the flag after a short delay so the update timer
        // doesn't fight with drag events.
        scrub_reset_source = Timeout.add (120, () => {
            user_scrubbing = false;
            scrub_reset_source = 0;
            return Source.REMOVE;
        });

        return false; // let default handler update scale value
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Periodic position update
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Run the position timer only while the position can actually change.
     *
     * A paused preview sat on a trim point was previously still waking ten
     * times a second to read back a position that could not have moved. Every
     * other thing that moves the position — seeking, frame stepping, loading —
     * calls sync_position () directly instead.
     */
    private void start_update_timer () {
        stop_update_timer ();
        update_source = Timeout.add (100, () => {
            sync_position ();

            // Playback can stop on its own at end of file. Once it has, there
            // is nothing left to track until the user starts it again.
            if (!is_playing) {
                update_source = 0;
                return Source.REMOVE;
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

    /** One-shot equivalent of a timer tick, for the paused transitions. */
    private void sync_position () {
        if (user_scrubbing || !backend.loaded) return;

        double pos = get_position_seconds ();
        scrubber.set_value (pos);
        time_label.set_text (format_time (pos));
        position_changed (pos);

        // Sync the play state if playback stopped on its own
        // (e.g. reached end of file)
        if (is_playing && !backend.get_playing ()) {
            is_playing = false;
            play_button.set_icon_name ("media-playback-start-symbolic");
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  PreviewFullscreenController — one fullscreen state machine for every video
//  preview window. Window ownership remains outside VideoPlayer so an embedded
//  player can never accidentally fullscreen the whole converter UI.
// ═══════════════════════════════════════════════════════════════════════════════

public class PreviewFullscreenController : Object {
    private Gtk.Window? window;
    private VideoPlayer? player;
    private Gtk.Widget? chrome;
    private Gtk.EventControllerKey? escape_keys;
    private ulong fullscreen_notify_handler_id = 0;
    private bool requested_fullscreen = false;
    private bool transition_pending = false;
    private uint transition_timeout_id = 0;

    // A compositor normally acknowledges immediately. This deadline is only a
    // recovery path for a rejected request, and prevents requested state from
    // remaining stale forever on an unusual window manager.
    private const uint TRANSITION_TIMEOUT_MS = 1500;

    public PreviewFullscreenController (Gtk.Window target_window,
                                        VideoPlayer target_player,
                                        Gtk.Widget? fullscreen_chrome = null) {
        window = target_window;
        player = target_player;
        chrome = fullscreen_chrome;
        requested_fullscreen = target_window.fullscreened;

        fullscreen_notify_handler_id = target_window.notify["fullscreened"].connect (
            on_window_fullscreen_changed);

        escape_keys = new Gtk.EventControllerKey ();
        // CropOverlay also uses Escape. Window capture makes leaving fullscreen
        // take precedence while preserving the crop selection underneath.
        escape_keys.set_propagation_phase (PropagationPhase.CAPTURE);
        escape_keys.key_pressed.connect (on_key_pressed);
        ((Gtk.Widget) target_window).add_controller (escape_keys);

        sync_actual_state ();
    }

    public void toggle () {
        if (window == null) return;

        // During a compositor round-trip, toggle the desired state rather than
        // the last acknowledged one. Two quick activations therefore cancel
        // one another instead of issuing the same request twice.
        bool base_state = transition_pending
            ? requested_fullscreen
            : window.fullscreened;
        request_state (!base_state);
    }

    public bool request_exit () {
        if (window == null) return false;
        if (!window.fullscreened
            && !(transition_pending && requested_fullscreen)) {
            return false;
        }

        request_state (false);
        return true;
    }

    public void detach () {
        stop_transition_timeout ();
        transition_pending = false;
        requested_fullscreen = false;

        if (window != null) {
            if (fullscreen_notify_handler_id != 0) {
                window.disconnect (fullscreen_notify_handler_id);
                fullscreen_notify_handler_id = 0;
            }
            if (escape_keys != null) {
                ((Gtk.Widget) window).remove_controller (escape_keys);
            }
        }
        escape_keys = null;

        if (player != null) {
            player.set_fullscreen_state (false);
        }
        if (chrome != null) {
            chrome.set_visible (true);
        }

        window = null;
        player = null;
        chrome = null;
    }

    private void request_state (bool fullscreen) {
        if (window == null) return;

        requested_fullscreen = fullscreen;
        transition_pending = true;
        start_transition_timeout ();

        if (fullscreen) {
            window.fullscreen ();
        } else {
            window.unfullscreen ();
        }
    }

    private void on_window_fullscreen_changed () {
        if (window == null) return;

        bool actual = window.fullscreened;
        if (transition_pending) {
            if (actual == requested_fullscreen) {
                transition_pending = false;
                stop_transition_timeout ();
            } else {
                // The compositor acknowledged an earlier request after the
                // user had already toggled again. Reassert the latest desired
                // state now that the intermediate transition has landed.
                start_transition_timeout ();
                if (requested_fullscreen) {
                    window.fullscreen ();
                } else {
                    window.unfullscreen ();
                }
            }
        } else {
            // Covers compositor-initiated transitions outside this controller.
            requested_fullscreen = actual;
        }

        sync_actual_state ();
    }

    private void sync_actual_state () {
        bool actual = window != null && window.fullscreened;
        if (player != null) {
            player.set_fullscreen_state (actual);
        }
        if (chrome != null) {
            chrome.set_visible (!actual);
        }
    }

    private bool on_key_pressed (uint keyval, uint keycode,
                                 Gdk.ModifierType state) {
        if (keyval == Gdk.Key.Escape) {
            return request_exit ();
        }
        return false;
    }

    private void start_transition_timeout () {
        stop_transition_timeout ();
        transition_timeout_id = Timeout.add (TRANSITION_TIMEOUT_MS, () => {
            transition_timeout_id = 0;
            transition_pending = false;
            if (window != null) {
                requested_fullscreen = window.fullscreened;
            }
            sync_actual_state ();
            return Source.REMOVE;
        });
    }

    private void stop_transition_timeout () {
        if (transition_timeout_id != 0) {
            Source.remove (transition_timeout_id);
            transition_timeout_id = 0;
        }
    }

#if COMBINE_WINDOW_TEST_BUILD
    internal bool requested_fullscreen_for_widget_test () {
        return requested_fullscreen;
    }

    internal bool transition_pending_for_widget_test () {
        return transition_pending;
    }

    internal bool handle_escape_for_widget_test () {
        return on_key_pressed (Gdk.Key.Escape, 0, (Gdk.ModifierType) 0);
    }

    internal bool escape_handler_uses_capture_for_widget_test () {
        return escape_keys != null
            && escape_keys.get_propagation_phase () == PropagationPhase.CAPTURE;
    }
#endif
}
