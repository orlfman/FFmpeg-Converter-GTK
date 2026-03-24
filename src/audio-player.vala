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

// ═══════════════════════════════════════════════════════════════════════════════
//  AudioPlayer — Waveform-based audio player with segment highlights
//
//  Uses Gtk.MediaFile for playback and FFmpeg showwavespic for waveform
//  generation.  The waveform is displayed as a Gtk.Picture with an
//  overlay scrubber and segment highlight drawing.
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
    private Gtk.Scale scrubber;
    private Gtk.Label time_label;
    private Gtk.Label duration_label;
    private Gtk.Button play_button;
    private Gtk.MediaFile? media = null;

    // ── State ────────────────────────────────────────────────────────────────
    private uint update_source = 0;
    private uint prepare_poll = 0;
    private uint scrub_reset_source = 0;
    private ulong media_prepared_handler_id = 0;
    private bool user_scrubbing = false;
    private bool is_playing = false;
    private bool prepared_handled = false;
    private double _duration = 0.0;
    private string? waveform_tmp_path = null;
    private Cancellable? waveform_cancellable = null;
    private Subprocess? waveform_proc = null;
    private uint waveform_generation = 0;

    // ── Segment highlights ───────────────────────────────────────────────────
    private GenericArray<AudioSegment> highlight_segments = new GenericArray<AudioSegment> ();

    // ── Signals ──────────────────────────────────────────────────────────────
    public signal void position_changed (double seconds);
    public signal void media_ready (double duration_seconds);

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public AudioPlayer () {
        Object (orientation: Orientation.VERTICAL, spacing: 6);
        build_ui ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI CONSTRUCTION
    // ═════════════════════════════════════════════════════════════════════════

    private void build_ui () {

        // ── Waveform Display ────────────────────────────────────────────────
        waveform_frame = new Gtk.Frame (null);
        waveform_frame.add_css_class ("view");

        waveform_picture = new Gtk.Picture ();
        waveform_picture.set_size_request (-1, 140);
        waveform_picture.set_vexpand (false);
        waveform_picture.set_content_fit (ContentFit.FILL);

        // Segment highlight overlay (drawn on top of waveform)
        segment_overlay = new Gtk.DrawingArea ();
        segment_overlay.set_draw_func (draw_segment_highlights);

        // Spinner for waveform generation
        spinner_box = new Box (Orientation.VERTICAL, 8);
        spinner_box.set_halign (Align.CENTER);
        spinner_box.set_valign (Align.CENTER);
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

        // ── Scrubber ────────────────────────────────────────────────────────
        scrubber = new Gtk.Scale.with_range (Orientation.HORIZONTAL, 0.0, 1.0, 0.001);
        scrubber.set_draw_value (false);
        scrubber.set_hexpand (true);
        scrubber.set_margin_top (4);
        scrubber.change_value.connect (on_scrubber_changed);
        append (scrubber);

        // ── Transport Controls ──────────────────────────────────────────────
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

        // Fine step back 0.1 s
        var fine_back = new Button.from_icon_name ("go-previous-symbolic");
        fine_back.set_tooltip_text ("Step back 0.1 seconds");
        fine_back.add_css_class ("flat");
        fine_back.clicked.connect (() => {
            ensure_paused ();
            seek_relative (-0.1);
        });
        controls.append (fine_back);

        // Play / Pause
        play_button = new Button.from_icon_name ("media-playback-start-symbolic");
        play_button.set_tooltip_text ("Play / Pause");
        play_button.add_css_class ("circular");
        play_button.clicked.connect (toggle_playback);
        controls.append (play_button);

        // Fine step forward 0.1 s
        var fine_fwd = new Button.from_icon_name ("go-next-symbolic");
        fine_fwd.set_tooltip_text ("Step forward 0.1 seconds");
        fine_fwd.add_css_class ("flat");
        fine_fwd.clicked.connect (() => {
            ensure_paused ();
            seek_relative (0.1);
        });
        controls.append (fine_fwd);

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

    public void load_file (string path) {
        reset_player_state ();

        var file = GLib.File.new_for_path (path);
        media = Gtk.MediaFile.for_file (file);
        // Audio-only: no picture paintable needed

        // Start waveform generation
        generate_waveform_async (path);

        // Detect when media is prepared
        media_prepared_handler_id = media.notify["prepared"].connect (on_media_prepared_notify);

        prepare_poll = Timeout.add (100, () => {
            if (media != null && media.is_prepared ()) {
                on_media_prepared (media);
                prepare_poll = 0;
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });
    }

    public void clear () {
        reset_player_state ();
        media = null;
        scrubber.set_range (0.0, 1.0);
        scrubber.set_value (0.0);
        time_label.set_text (VideoPlayer.format_time (0.0));
        duration_label.set_text (VideoPlayer.format_time (0.0));
        waveform_picture.set_paintable (null);
        _duration = 0.0;
    }

    public double get_position_seconds () {
        if (media == null) return 0.0;
        return (double) media.get_timestamp () / 1000000.0;
    }

    public void seek_to (double seconds) {
        if (media == null) return;
        int64 target = (int64) (seconds * 1000000.0);
        int64 dur = media.get_duration ();
        if (dur > 0) {
            target = target.clamp (0, dur);
        }
        media.seek (target);
    }

    public void set_segments (GenericArray<AudioSegment> segs) {
        highlight_segments = segs;
        segment_overlay.queue_draw ();
    }

    public void cleanup () {
        reset_player_state ();
    }

    public override void dispose () {
        cleanup ();
        base.dispose ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Waveform generation
    // ═════════════════════════════════════════════════════════════════════════

    private void generate_waveform_async (string input_path) {
        cancel_waveform ();

        var cancel = new Cancellable ();
        waveform_cancellable = cancel;
        uint gen = ++waveform_generation;

        spinner_box.set_visible (true);
        waveform_spinner.start ();
        waveform_picture.set_paintable (null);

        string tmp_path;
        try {
            int fd;
            fd = FileUtils.open_tmp ("waveform-XXXXXX.png", out tmp_path);
            Posix.close (fd);
        } catch (Error e) {
            debug ("AudioPlayer: failed to create temp file for waveform: %s", e.message);
            spinner_box.set_visible (false);
            waveform_spinner.stop ();
            return;
        }

        waveform_tmp_path = tmp_path;

        string[] cmd = {
            AppSettings.get_default ().ffmpeg_path,
            "-i", input_path,
            "-filter_complex",
            "aformat=channel_layouts=mono,showwavespic=s=1920x200:colors=#4a90d9",
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
                    load_waveform_image (tmp_path);
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

    private void load_waveform_image (string path) {
        try {
            var texture = Gdk.Texture.from_filename (path);
            waveform_picture.set_paintable (texture);
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

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Segment highlight drawing
    // ═════════════════════════════════════════════════════════════════════════

    private void draw_segment_highlights (DrawingArea area, Cairo.Context cr,
                                          int width, int height) {
        if (_duration <= 0.0 || highlight_segments.length == 0)
            return;

        cr.set_source_rgba (0.29, 0.56, 0.85, 0.25);

        for (int i = 0; i < highlight_segments.length; i++) {
            var seg = highlight_segments[i];
            double x_start = (seg.start_time / _duration) * width;
            double x_end = (seg.end_time / _duration) * width;
            double seg_width = (x_end - x_start).clamp (1.0, width);
            cr.rectangle (x_start, 0, seg_width, height);
            cr.fill ();
        }

        // Draw playhead
        double pos = get_position_seconds ();
        if (pos > 0.0) {
            double x = (pos / _duration) * width;
            cr.set_source_rgba (1.0, 1.0, 1.0, 0.8);
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
        stop_prepare_poll ();
        cancel_waveform ();
        cancel_scrub_reset ();
        disconnect_media_prepared_handler ();

        if (media != null) {
            media.set_playing (false);
        }

        user_scrubbing = false;
        is_playing = false;
        prepared_handled = false;
        play_button.set_icon_name ("media-playback-start-symbolic");
    }

    private void ensure_paused () {
        if (media == null) return;
        if (is_playing) {
            media.set_playing (false);
            is_playing = false;
            play_button.set_icon_name ("media-playback-start-symbolic");
        }
    }

    private void disconnect_media_prepared_handler () {
        if (media != null && media_prepared_handler_id != 0) {
            media.disconnect (media_prepared_handler_id);
            media_prepared_handler_id = 0;
        }
    }

    private void on_media_prepared_notify (Object source_object, ParamSpec pspec) {
        var source_media = source_object as Gtk.MediaFile;
        if (source_media != null) {
            on_media_prepared (source_media);
        }
    }

    private void on_media_prepared (Gtk.MediaFile source_media) {
        if (media == null || source_media != media || !source_media.is_prepared ()) return;

        double dur = (double) source_media.get_duration () / 1000000.0;
        if (dur <= 0.0) return;

        if (prepared_handled) return;
        prepared_handled = true;

        stop_prepare_poll ();
        disconnect_media_prepared_handler ();

        _duration = dur;
        scrubber.set_range (0.0, dur);
        scrubber.set_value (0.0);
        duration_label.set_text (VideoPlayer.format_time (dur));
        time_label.set_text (VideoPlayer.format_time (0.0));

        start_update_timer ();
        media_ready (dur);
    }

    private void toggle_playback () {
        if (media == null) return;

        if (is_playing) {
            media.set_playing (false);
            is_playing = false;
            play_button.set_icon_name ("media-playback-start-symbolic");
        } else {
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
        time_label.set_text (VideoPlayer.format_time (new_value));

        cancel_scrub_reset ();
        scrub_reset_source = Timeout.add (120, () => {
            user_scrubbing = false;
            scrub_reset_source = 0;
            return Source.REMOVE;
        });

        return false;
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

    private void start_update_timer () {
        stop_update_timer ();
        update_source = Timeout.add (100, () => {
            if (!user_scrubbing && media != null) {
                double pos = get_position_seconds ();
                scrubber.set_value (pos);
                time_label.set_text (VideoPlayer.format_time (pos));
                position_changed (pos);
                segment_overlay.queue_draw ();

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
