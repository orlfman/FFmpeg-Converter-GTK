using Gtk;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  AudioSegment — Simple start/end time pair for waveform highlight rendering
// ═══════════════════════════════════════════════════════════════════════════════

public class AudioSegment : Object {
    public double start_time { get; set; }
    public double end_time   { get; set; }

    public AudioSegment (double start, double end) {
        this.start_time = start;
        this.end_time   = end;
    }

    public double get_duration () {
        return (end_time - start_time).clamp (0.0, double.MAX);
    }

    public AudioSegment copy () {
        return new AudioSegment (start_time, end_time);
    }
}

class AudioWaveformCacheEntry : Object {
    public ConversionUtils.FileSignature signature;
    public Gdk.Texture texture;

    public AudioWaveformCacheEntry (ConversionUtils.FileSignature signature,
                                    Gdk.Texture texture) {
        this.signature = signature;
        this.texture = texture;
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  AudioPlayer — Waveform-based audio player with segment highlights
//
//  Uses libmpv for playback (audio-only, so no video is ever decoded here) and
//  FFmpeg showwavespic for waveform generation.  The waveform is displayed as a
//  Gtk.Picture with a click-to-seek waveform and segment highlight drawing.
// ═══════════════════════════════════════════════════════════════════════════════

public class AudioPlayer : Box {

    // ── Widgets ──────────────────────────────────────────────────────────────
    private Gtk.Picture waveform_picture;
    private Gtk.Overlay waveform_overlay;
    private Gtk.Frame waveform_frame;
    private Gtk.DrawingArea segment_overlay;
    private Gtk.Spinner waveform_spinner;
    private Gtk.Label spinner_label;
    private Box spinner_box;
    private Gtk.GestureDrag waveform_drag;
    private Gtk.Label time_label;
    private Gtk.Label duration_label;
    private Gtk.Button play_button;
    private Gtk.ToggleButton mute_button;
    private SpeedMenuButton speed_button;
    private Gtk.Label media_status_label;

    // ── Playback backend ─────────────────────────────────────────────────────
    // Audio-only libmpv instance: it selects the wanted audio track directly from
    // the source with video decoding switched off, so no playback proxy has to be
    // extracted and no video pipeline is ever created for this tab.
    private MpvBackend backend;

    // ── State ────────────────────────────────────────────────────────────────
    private uint update_source = 0;
    private uint scrub_reset_source = 0;
    private bool user_scrubbing = false;
    private bool is_playing = false;
    private bool prepared_handled = false;
    private double _duration = 0.0;
    private double fallback_duration = 0.0;
    private string? waveform_tmp_path = null;
    private Cancellable? waveform_cancellable = null;
    private Subprocess? waveform_proc = null;
    private uint waveform_generation = 0;
    private string current_waveform_input_path = "";
    private int current_waveform_stream_index = 0;

    // Waveform rendering is an ffmpeg pass over every audio sample in the source,
    // so it is not started just because a file was selected: the request is held
    // until this player is actually on screen. GTK unmaps the widget both when the
    // Audio tab is not the visible page and while the player itself is hidden
    // (during probing, or when the source has no audio), so map state is a
    // faithful "worth rendering now" signal. The signature cache means returning
    // to the tab after the first render costs nothing.
    private string pending_waveform_path = "";
    private int pending_waveform_stream_index = 0;
    private bool waveform_request_pending = false;
    private bool player_on_screen = false;
    private string? temp_run_dir = null;
    private string? waveform_temp_dir = null;
    private ulong style_manager_dark_handler_id = 0;
    private HashTable<string, AudioWaveformCacheEntry> waveform_cache =
        new HashTable<string, AudioWaveformCacheEntry> (str_hash, str_equal);
    private string[] waveform_cache_lru = {};

    private const int MAX_WAVEFORM_CACHE_ENTRIES = 12;

    // ── Segment highlights ───────────────────────────────────────────────────
    private GenericArray<AudioSegment> highlight_segments = new GenericArray<AudioSegment> ();

    // ── Signals ──────────────────────────────────────────────────────────────
    public signal void position_changed (double seconds);
    public signal void media_ready (double duration_seconds);
    public signal void media_failed (string message);

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public AudioPlayer () {
        Object (orientation: Orientation.VERTICAL, spacing: 0);
        PlayerStyles.ensure_loaded ();
        inject_audio_player_css ();
        build_ui ();
        connect_style_manager ();

        backend = new MpvBackend (false);
        backend.file_loaded.connect (on_media_prepared);
        backend.load_failed.connect (on_backend_load_failed);
        // Seeks land asynchronously; read the new position when mpv reports it
        // has arrived rather than polling for it.
        backend.playback_restarted.connect (sync_position);

        map.connect (() => {
            player_on_screen = true;
            flush_pending_waveform ();
        });
        unmap.connect (() => {
            player_on_screen = false;
        });
    }

    private static bool audio_player_css_injected = false;

    private static void inject_audio_player_css () {
        if (audio_player_css_injected) return;
        audio_player_css_injected = true;

        var css = new CssProvider ();
        css.load_from_string (
            // Waveform container — theme-aware surface
            ".waveform-frame {\n" +
            "    background: mix(@window_bg_color, @window_fg_color, 0.08);\n" +
            "    border-radius: 10px;\n" +
            "    border: 1px solid alpha(@window_fg_color, 0.08);\n" +
            "}\n" +
            // Loading overlay — matches waveform background
            ".waveform-loading {\n" +
            "    background: alpha(mix(@window_bg_color, @window_fg_color, 0.08), 0.9);\n" +
            "    border-radius: 10px;\n" +
            "}\n"
        );
        GtkCompat.add_provider_for_display (
            Gdk.Display.get_default (),
            css,
            STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }

    private void connect_style_manager () {
        var style_manager = Adw.StyleManager.get_default ();
        style_manager_dark_handler_id = style_manager.notify["dark"].connect (() => {
            refresh_waveform_for_theme_change ();
        });
    }

    private void disconnect_style_manager () {
        if (style_manager_dark_handler_id == 0)
            return;

        Adw.StyleManager.get_default ().disconnect (style_manager_dark_handler_id);
        style_manager_dark_handler_id = 0;
    }

    private void refresh_waveform_for_theme_change () {
        if (current_waveform_input_path.length == 0)
            return;

        // Goes through the same visibility gate: the cache is keyed by theme, so a
        // player that is off screen when the theme flips re-renders when it next
        // appears rather than immediately.
        request_waveform (
            current_waveform_input_path,
            current_waveform_stream_index
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI CONSTRUCTION
    // ═════════════════════════════════════════════════════════════════════════

    private void build_ui () {

        // ── Waveform Display ────────────────────────────────────────────────
        waveform_frame = new Gtk.Frame (null);
        waveform_frame.add_css_class ("waveform-frame");

        waveform_picture = new Gtk.Picture ();
        waveform_picture.set_size_request (-1, 140);
        waveform_picture.set_vexpand (false);
        waveform_picture.set_content_fit (ContentFit.FILL);

        // Segment highlight overlay (drawn on top of waveform)
        segment_overlay = new Gtk.DrawingArea ();
        segment_overlay.set_draw_func (draw_segment_highlights);
        segment_overlay.set_sensitive (false);

        // Spinner for waveform generation (fills entire overlay, content centered)
        spinner_box = new Box (Orientation.VERTICAL, 8);
        spinner_box.set_halign (Align.CENTER);
        spinner_box.set_valign (Align.CENTER);
        spinner_box.set_hexpand (true);
        spinner_box.set_vexpand (true);
        spinner_box.add_css_class ("waveform-loading");
        waveform_spinner = new Gtk.Spinner ();
        waveform_spinner.set_size_request (32, 32);
        spinner_label = new Gtk.Label ("Generating waveform…");
        spinner_label.add_css_class ("dim-label");
        spinner_box.append (waveform_spinner);
        spinner_box.append (spinner_label);
        spinner_box.set_visible (false);

        waveform_overlay = new Gtk.Overlay ();
        waveform_overlay.set_child (waveform_picture);
        waveform_overlay.add_overlay (segment_overlay);
        waveform_overlay.add_overlay (spinner_box);

        waveform_frame.set_child (waveform_overlay);
        append (waveform_frame);

        media_status_label = new Gtk.Label ("");
        media_status_label.set_wrap (true);
        media_status_label.set_justify (Justification.CENTER);
        media_status_label.set_margin_top (6);
        media_status_label.set_visible (false);
        append (media_status_label);

        // ── Waveform click/drag seek (on segment_overlay for matched coords) ─
        segment_overlay.set_cursor_from_name ("pointer");

        var click = new Gtk.GestureClick ();
        click.set_button (1);
        click.pressed.connect ((n_press, x, y) => {
            seek_to_waveform_x (x);
        });
        segment_overlay.add_controller (click);

        waveform_drag = new Gtk.GestureDrag ();
        waveform_drag.drag_begin.connect ((start_x, start_y) => {
            user_scrubbing = true;
            seek_to_waveform_x (start_x);
        });
        waveform_drag.drag_update.connect (on_waveform_drag_update);
        waveform_drag.drag_end.connect ((offset_x, offset_y) => {
            cancel_scrub_reset ();
            scrub_reset_source = Timeout.add (120, () => {
                user_scrubbing = false;
                scrub_reset_source = 0;
                return Source.REMOVE;
            });
        });
        segment_overlay.add_controller (waveform_drag);

        // ── Transport Controls ──────────────────────────────────────────────
        var controls = new Box (Orientation.HORIZONTAL, 0);
        controls.set_halign (Align.CENTER);
        controls.set_margin_top (8);
        controls.set_margin_bottom (4);
        controls.add_css_class ("transport-bar");

        // Back seek group — linked. Mirrors VideoPlayer's transport layout, with
        // the innermost pair stepping 0.1 s: audio has no frame to step by, so
        // the generic step arrows are kept rather than the frame icons, which
        // would claim something untrue here.
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

        var fine_back = new Button.from_icon_name ("go-previous-symbolic");
        fine_back.set_tooltip_text ("Step back 0.1 seconds");
        fine_back.clicked.connect (() => {
            ensure_paused ();
            seek_relative (-0.1);
        });
        back_group.append (fine_back);

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

        var fine_fwd = new Button.from_icon_name ("go-next-symbolic");
        fine_fwd.set_tooltip_text ("Step forward 0.1 seconds");
        fine_fwd.clicked.connect (() => {
            ensure_paused ();
            seek_relative (0.1);
        });
        fwd_group.append (fine_fwd);

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

        append (controls);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PUBLIC API
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Load an audio stream for preview.
     *
     * @known_duration is a probe-derived fallback used only when mpv can play
     * the stream but cannot report its duration itself.
     */
    public void load_file (string path,
                           int stream_index = 0,
                           double known_duration = 0.0) {
        reset_player_state ();
        fallback_duration = double.max (known_duration, 0.0);
        current_waveform_input_path = path;
        current_waveform_stream_index = stream_index;

        // Queue the waveform rather than rendering it now; it starts when this
        // player is on screen. The file signature is queried at render time, not
        // here, so a long deferral cannot key the cache against a stale identity.
        request_waveform (path, stream_index);

        if (path.length == 0)
            return;

        // mpv selects the audio track directly from the source with video
        // decoding disabled, so every stream — including the first — plays from
        // the original file. There is no extraction step, no temporary proxy,
        // and the reported duration stays the source's own.
        if (!backend.open (path, stream_index)) {
            handle_load_failure ("Could not start the audio preview.");
            return;
        }

        backend.set_muted (mute_button.get_active ());
        backend.set_speed (speed_button.speed);
    }

    /**
     * Hold a waveform request until the player is visible, then render it.
     *
     * Passing "" cancels any pending or running render without queuing a new one.
     */
    private void request_waveform (string path, int stream_index) {
        cancel_waveform ();

        pending_waveform_path = path;
        pending_waveform_stream_index = stream_index;
        waveform_request_pending = path.length > 0;

        if (player_on_screen)
            flush_pending_waveform ();
    }

    private void flush_pending_waveform () {
        if (!waveform_request_pending)
            return;

        // Own the values before handing them over: generate_waveform_async takes
        // its arguments unowned and calls cancel_waveform first, so passing the
        // fields directly would expose them to being reset mid-call.
        string path = pending_waveform_path;
        int stream_index = pending_waveform_stream_index;

        waveform_request_pending = false;
        generate_waveform_async (path, stream_index);
    }

    private bool ensure_temp_dirs () {
        if (temp_run_dir != null && waveform_temp_dir != null) {
            if (FileUtils.test (temp_run_dir, FileTest.IS_DIR)
                && FileUtils.test (waveform_temp_dir, FileTest.IS_DIR)) {
                return true;
            }

            cleanup_temp_dirs ();
        }

        string? run_dir = ConversionUtils.create_managed_temp_run_dir ("audio-player");
        if (run_dir == null)
            return false;

        string? next_waveform_dir = ConversionUtils.ensure_managed_temp_subdir (
            run_dir,
            "waveform"
        );
        if (next_waveform_dir == null) {
            ConversionUtils.try_remove_empty_dir_chain (
                run_dir,
                ConversionUtils.get_app_temp_root ()
            );
            return false;
        }

        temp_run_dir = run_dir;
        waveform_temp_dir = next_waveform_dir;
        return true;
    }

    private bool create_waveform_temp_path (out string path) {
        path = "";

        if (ensure_temp_dirs () && waveform_temp_dir != null) {
            string? managed_path = ConversionUtils.create_managed_temp_file (
                waveform_temp_dir,
                "waveform",
                ".png"
            );
            if (managed_path != null) {
                path = managed_path;
                return true;
            }
        }

        try {
            int fd = FileUtils.open_tmp ("waveform-XXXXXX.png", out path);
            Posix.close (fd);
            return true;
        } catch (Error e) {
            return false;
        }
    }

    private void cleanup_temp_dirs () {
        string root = ConversionUtils.get_app_temp_root ();

        if (waveform_temp_dir != null) {
            ConversionUtils.try_remove_empty_dir_chain (waveform_temp_dir, root);
        }
        if (temp_run_dir != null) {
            ConversionUtils.try_remove_empty_dir_chain (temp_run_dir, root);
        }

        temp_run_dir = null;
        waveform_temp_dir = null;
    }

    public void clear () {
        reset_player_state ();
        current_waveform_input_path = "";
        current_waveform_stream_index = 0;
        waveform_picture.set_paintable (null);
    }

    public double get_position_seconds () {
        return backend.get_position ();
    }

    public void seek_to (double seconds) {
        backend.seek_absolute (seconds);
    }

    public void set_segments (GenericArray<AudioSegment> segs) {
        highlight_segments = segs;
        segment_overlay.queue_draw ();
    }

    public void cleanup () {
        reset_player_state ();
        current_waveform_input_path = "";
        current_waveform_stream_index = 0;
        clear_waveform_cache ();
        cleanup_temp_dirs ();
    }

    public override void dispose () {
        disconnect_style_manager ();
        cleanup ();
        base.dispose ();
    }

#if COMBINE_WINDOW_TEST_BUILD
    internal void prepare_duration_for_widget_test (double duration_seconds) {
        complete_media_preparation (duration_seconds);
    }

    internal void prepare_duration_with_fallback_for_widget_test (
            double duration_seconds,
            double known_duration) {
        fallback_duration = double.max (known_duration, 0.0);
        complete_media_preparation (duration_seconds);
    }

    internal void fail_for_widget_test (string message) {
        handle_load_failure (message);
    }

    internal string get_duration_text_for_widget_test () {
        return duration_label.get_text ();
    }

    internal double get_duration_for_widget_test () {
        return _duration;
    }

    internal bool is_waveform_seek_sensitive_for_widget_test () {
        return segment_overlay.get_sensitive ();
    }

    internal SpeedMenuButton speed_button_for_widget_test () {
        return speed_button;
    }

    internal bool is_media_status_visible_for_widget_test () {
        return media_status_label.get_visible ();
    }

    internal string get_media_status_for_widget_test () {
        return media_status_label.get_text ();
    }
#endif

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Waveform generation
    // ═════════════════════════════════════════════════════════════════════════

    private void generate_waveform_async (string input_path,
                                          int stream_index = 0,
                                          ConversionUtils.FileSignature? signature = null) {
        cancel_waveform ();

        if (input_path.length == 0)
            return;

        bool is_dark = Adw.StyleManager.get_default ().dark;
        ConversionUtils.FileSignature? effective_signature = signature;
        if (effective_signature == null) {
            effective_signature = ConversionUtils.query_file_signature (input_path);
        }
        if (effective_signature != null) {
            var cached = lookup_waveform_cache (effective_signature, stream_index, is_dark);
            if (cached != null) {
                waveform_picture.set_paintable (cached.texture);
                segment_overlay.queue_draw ();
                hide_spinner ();
                return;
            }
        }

        var cancel = new Cancellable ();
        waveform_cancellable = cancel;
        uint gen = ++waveform_generation;

        spinner_box.set_visible (true);
        waveform_spinner.start ();
        waveform_picture.set_paintable (null);

        string tmp_path;
        if (!create_waveform_temp_path (out tmp_path)) {
            debug ("AudioPlayer: failed to create temp file for waveform");
            spinner_box.set_visible (false);
            waveform_spinner.stop ();
            return;
        }

        waveform_tmp_path = tmp_path;

        // Pick waveform color based on current color scheme
        string waveform_color = is_dark ? "#7ab3e8" : "#2a6db5";

        string[] cmd = {
            AppSettings.get_default ().ffmpeg_path,
            "-i", input_path,
            "-filter_complex",
            "[0:a:%d]aformat=channel_layouts=mono,showwavespic=s=1920x200:colors=%s".printf (stream_index, waveform_color),
            "-frames:v", "1",
            "-y",
            tmp_path
        };

        try {
            var launcher = new SubprocessLauncher (
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            var proc = SubprocessCompat.spawnv (launcher, cmd);
            waveform_proc = proc;

            proc.communicate_utf8_async.begin (null, cancel, (obj, res) => {
                string? stdout_buf, stderr_buf;
                try {
                    proc.communicate_utf8_async.end (res, out stdout_buf, out stderr_buf);
                } catch (Error e) {
                    if (!cancel.is_cancelled ()) {
                        debug ("AudioPlayer: waveform generation failed: %s", e.message);
                    }
                    clear_waveform_proc (proc);
                    FileUtils.unlink (tmp_path);
                    hide_spinner ();
                    return;
                }

                clear_waveform_proc (proc);

                if (cancel.is_cancelled () || gen != waveform_generation) {
                    // Process finished after cancellation — clean up orphaned temp file
                    FileUtils.unlink (tmp_path);
                    hide_spinner ();
                    return;
                }

                if (proc.get_successful ()) {
                    load_waveform_image (tmp_path, effective_signature, stream_index, is_dark);
                } else {
                    debug ("AudioPlayer: waveform ffmpeg failed");
                    FileUtils.unlink (tmp_path);
                }

                hide_spinner ();
            });
        } catch (Error e) {
            debug ("AudioPlayer: failed to spawn waveform process: %s", e.message);
            FileUtils.unlink (tmp_path);
            waveform_tmp_path = null;
            hide_spinner ();
        }
    }

    private void load_waveform_image (string path,
                                      ConversionUtils.FileSignature? signature = null,
                                      int stream_index = 0,
                                      bool dark_theme = false) {
        try {
            var texture = Gdk.Texture.from_filename (path);
            waveform_picture.set_paintable (texture);
            if (signature != null) {
                store_waveform_cache (signature, stream_index, dark_theme, texture);
            }
        } catch (Error e) {
            debug ("AudioPlayer: failed to load waveform image: %s", e.message);
        }
        // Texture is loaded into memory; temp file no longer needed
        FileUtils.unlink (path);
        if (waveform_tmp_path == path) {
            waveform_tmp_path = null;
        }
    }

    private void hide_spinner () {
        Idle.add (() => {
            spinner_box.set_visible (false);
            waveform_spinner.stop ();
            return Source.REMOVE;
        });
    }

    private void cancel_waveform () {
        // Also drops any request still waiting on visibility. This is the single
        // choke point every teardown path reaches (reset_player_state, and so
        // clear/cleanup/load_file), so a cleared player cannot render the previous
        // file's waveform the next time it is shown. request_waveform calls this
        // before queuing, so queuing still works.
        //
        // Only the flag is cleared, deliberately: pending_waveform_path is passed
        // by reference into generate_waveform_async, which calls this function
        // first, so freeing it here would leave that caller holding a dangling
        // string. The flag alone is authoritative — nothing reads the path unless
        // request_waveform has just set it.
        waveform_request_pending = false;

        if (waveform_cancellable != null) {
            waveform_cancellable.cancel ();
            waveform_cancellable = null;
        }

        // Kill the FFmpeg process so it doesn't continue writing to the
        // temp file after we delete it, and to avoid wasting CPU.
        if (waveform_proc != null) {
            waveform_proc.force_exit ();
            waveform_proc = null;
        }

        spinner_box.set_visible (false);
        waveform_spinner.stop ();

        if (waveform_tmp_path != null) {
            FileUtils.unlink (waveform_tmp_path);
            waveform_tmp_path = null;
        }
    }

    private void clear_waveform_proc (Subprocess proc) {
        if (waveform_proc == proc) {
            waveform_proc = null;
        }
    }

    private string build_waveform_cache_key (string path, int stream_index, bool dark_theme) {
        return "%s|%d|%s".printf (path, stream_index, dark_theme ? "dark" : "light");
    }

    private void remove_waveform_cache_key_from_lru (string key) {
        int idx = -1;
        for (int i = 0; i < waveform_cache_lru.length; i++) {
            if (waveform_cache_lru[i] == key) {
                idx = i;
                break;
            }
        }

        if (idx < 0)
            return;

        string[] next = {};
        for (int i = 0; i < waveform_cache_lru.length; i++) {
            if (i != idx)
                next += waveform_cache_lru[i];
        }
        waveform_cache_lru = next;
    }

    private void touch_waveform_cache_key (string key) {
        remove_waveform_cache_key_from_lru (key);
        waveform_cache_lru += key;

        while (waveform_cache_lru.length > MAX_WAVEFORM_CACHE_ENTRIES) {
            string evicted = waveform_cache_lru[0];
            string[] next = {};
            for (int i = 1; i < waveform_cache_lru.length; i++)
                next += waveform_cache_lru[i];
            waveform_cache_lru = next;
            waveform_cache.remove (evicted);
        }
    }

    private void clear_waveform_cache_for_path (string path) {
        string[] keys = waveform_cache_lru;
        for (int i = 0; i < keys.length; i++) {
            string key = keys[i];
            var entry = waveform_cache.lookup (key);
            if (entry != null && entry.signature.path == path) {
                waveform_cache.remove (key);
                remove_waveform_cache_key_from_lru (key);
            }
        }
    }

    private AudioWaveformCacheEntry? lookup_waveform_cache (
        ConversionUtils.FileSignature signature,
        int stream_index,
        bool dark_theme
    ) {
        string key = build_waveform_cache_key (signature.path, stream_index, dark_theme);
        var entry = waveform_cache.lookup (key);
        if (entry == null)
            return null;

        if (!entry.signature.matches (signature)) {
            clear_waveform_cache_for_path (signature.path);
            return null;
        }

        touch_waveform_cache_key (key);
        return entry;
    }

    private void store_waveform_cache (ConversionUtils.FileSignature signature,
                                       int stream_index,
                                       bool dark_theme,
                                       Gdk.Texture texture) {
        string key = build_waveform_cache_key (signature.path, stream_index, dark_theme);
        var existing = waveform_cache.lookup (key);
        if (existing != null && !existing.signature.matches (signature)) {
            clear_waveform_cache_for_path (signature.path);
        }

        waveform_cache.insert (
            key,
            new AudioWaveformCacheEntry (signature, texture)
        );
        touch_waveform_cache_key (key);
    }

    private void clear_waveform_cache () {
        waveform_cache.remove_all ();
        waveform_cache_lru = {};
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Segment highlight drawing
    // ═════════════════════════════════════════════════════════════════════════

    private void draw_segment_highlights (DrawingArea area, Cairo.Context cr,
                                          int width, int height) {
        if (_duration <= 0.0)
            return;

        bool dark = Adw.StyleManager.get_default ().dark;

        // Draw segment regions
        if (highlight_segments.length > 0) {
            for (int i = 0; i < highlight_segments.length; i++) {
                var seg = highlight_segments[i];
                double x_start = (seg.start_time / _duration) * width;
                double x_end = (seg.end_time / _duration) * width;
                double seg_width = (x_end - x_start).clamp (1.0, width);

                // Filled region — brighter tint on dark, deeper on light
                if (dark) {
                    cr.set_source_rgba (0.35, 0.60, 0.90, 0.22);
                } else {
                    cr.set_source_rgba (0.15, 0.40, 0.75, 0.18);
                }
                cr.rectangle (x_start, 0, seg_width, height);
                cr.fill ();

                // Bright edge lines at segment boundaries
                if (dark) {
                    cr.set_source_rgba (0.40, 0.65, 0.95, 0.6);
                } else {
                    cr.set_source_rgba (0.15, 0.40, 0.75, 0.55);
                }
                cr.set_line_width (1.0);
                cr.move_to (x_start, 0);
                cr.line_to (x_start, height);
                cr.stroke ();
                cr.move_to (x_start + seg_width, 0);
                cr.line_to (x_start + seg_width, height);
                cr.stroke ();
            }
        }

        // Playhead — theme-aware line with subtle glow
        double pos = get_position_seconds ();
        if (pos > 0.0) {
            double x = (pos / _duration) * width;

            // Glow
            if (dark) {
                cr.set_source_rgba (1.0, 1.0, 1.0, 0.15);
            } else {
                cr.set_source_rgba (0.0, 0.0, 0.0, 0.12);
            }
            cr.set_line_width (5.0);
            cr.move_to (x, 0);
            cr.line_to (x, height);
            cr.stroke ();

            // Core line
            if (dark) {
                cr.set_source_rgba (1.0, 1.0, 1.0, 0.9);
            } else {
                cr.set_source_rgba (0.15, 0.15, 0.15, 0.9);
            }
            cr.set_line_width (1.5);
            cr.move_to (x, 0);
            cr.line_to (x, height);
            cr.stroke ();
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Playback control
    // ═════════════════════════════════════════════════════════════════════════

    private void reset_player_state () {
        stop_update_timer ();
        cancel_waveform ();
        cancel_scrub_reset ();

        // Tears the mpv core down outright so its demuxer buffers are returned
        // rather than held for as long as the tab stays open.
        backend.close ();

        user_scrubbing = false;
        is_playing = false;
        prepared_handled = false;
        _duration = 0.0;
        fallback_duration = 0.0;
        segment_overlay.set_sensitive (false);
        play_button.set_icon_name ("media-playback-start-symbolic");
        // Rate is per-preview: a 0.25x left over from the previous stream would
        // otherwise sound like the new one decodes badly.
        speed_button.reset ();
        speed_button.set_sensitive (false);
        time_label.set_text (VideoPlayer.format_time (0.0));
        duration_label.set_text (VideoPlayer.format_time (0.0));
        hide_media_status ();
    }

    private void on_backend_load_failed (string detail) {
        handle_load_failure ("Could not load the audio preview (%s).".printf (detail));
    }

    private void handle_load_failure (string message) {
        // A bad or unsupported user-selected file is an expected runtime
        // outcome, already surfaced inline and through media_failed.
        GLib.message ("AudioPlayer: %s", message);
        reset_player_state ();
        current_waveform_input_path = "";
        current_waveform_stream_index = 0;
        waveform_picture.set_paintable (null);
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

    private void ensure_paused () {
        if (is_playing) {
            backend.set_playing (false);
            is_playing = false;
            play_button.set_icon_name ("media-playback-start-symbolic");
        }
    }

    private void on_media_prepared () {
        complete_media_preparation (backend.duration);
    }

    private void complete_media_preparation (double dur) {

        if (prepared_handled) return;
        prepared_handled = true;

        // Unlike waveform seeking, rate selection does not need a known duration.
        speed_button.set_sensitive (true);

        double effective_duration = dur > 0.0 ? dur : fallback_duration;
        _duration = effective_duration;
        if (effective_duration > 0.0) {
            segment_overlay.set_sensitive (true);
            duration_label.set_text (VideoPlayer.format_time (effective_duration));
            hide_media_status ();
        } else {
            segment_overlay.set_sensitive (false);
            duration_label.set_text ("--:--:--.---");
            show_media_status (
                "Duration unavailable — waveform seeking is disabled.",
                false
            );
        }
        time_label.set_text (VideoPlayer.format_time (0.0));

        // Media opens paused; one reading suffices until playback starts.
        sync_position ();
        media_ready (effective_duration);
    }

    private void toggle_playback () {
        if (!backend.loaded) return;

        if (is_playing) {
            backend.set_playing (false);
            is_playing = false;
            play_button.set_icon_name ("media-playback-start-symbolic");
            stop_update_timer ();
            sync_position ();
        } else {
            backend.set_playing (true);
            is_playing = true;
            play_button.set_icon_name ("media-playback-pause-symbolic");
            start_update_timer ();
        }
    }

    private void seek_relative (double seconds) {
        backend.seek_relative (seconds);
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

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Waveform seek
    // ═════════════════════════════════════════════════════════════════════════

    private void seek_to_waveform_x (double x) {
        if (!backend.loaded || _duration <= 0.0) return;

        int width = segment_overlay.get_width ();
        if (width <= 0) return;

        double fraction = (x / (double) width).clamp (0.0, 1.0);
        double seconds = fraction * _duration;

        backend.seek_absolute (seconds);
        time_label.set_text (VideoPlayer.format_time (seconds));
        segment_overlay.queue_draw ();
    }

    private void on_waveform_drag_update (double offset_x, double offset_y) {
        double start_x;
        double start_y;
        if (!waveform_drag.get_start_point (out start_x, out start_y))
            return;
        seek_to_waveform_x (start_x + offset_x);
    }

    private void cancel_scrub_reset () {
        if (scrub_reset_source != 0) {
            Source.remove (scrub_reset_source);
            scrub_reset_source = 0;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Periodic position update
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Run the position timer only while the position can actually change; see
     * VideoPlayer.start_update_timer for the reasoning. Everything else that
     * moves the position calls sync_position () directly.
     */
    private void start_update_timer () {
        stop_update_timer ();
        update_source = Timeout.add (100, () => {
            sync_position ();

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
        time_label.set_text (VideoPlayer.format_time (pos));
        position_changed (pos);
        segment_overlay.queue_draw ();

        if (is_playing && !backend.get_playing ()) {
            is_playing = false;
            play_button.set_icon_name ("media-playback-start-symbolic");
        }
    }
}
