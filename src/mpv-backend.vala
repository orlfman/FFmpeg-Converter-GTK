using Gtk;

// ═══════════════════════════════════════════════════════════════════════════════
//  MpvFramePaintable — GdkPaintable wrapper around the most recent mpv frame
//
//  Reports the *video's* dimensions as its intrinsic size, independent of the
//  resolution we actually rendered at.  That keeps Gtk.Picture's layout stable
//  while the render target follows the widget allocation, and it means
//  CropOverlay's coordinate mapping — which is computed from the video size and
//  CONTAIN letterboxing — stays valid without any changes.
// ═══════════════════════════════════════════════════════════════════════════════

private class MpvFramePaintable : Object, Gdk.Paintable {

    private Gdk.Texture? current = null;
    private int intrinsic_w = 0;
    private int intrinsic_h = 0;

    public void set_video_size (int width, int height) {
        if (width == intrinsic_w && height == intrinsic_h)
            return;

        intrinsic_w = width;
        intrinsic_h = height;
        invalidate_size ();
    }

    public void set_frame (Gdk.Texture texture) {
        current = texture;
        invalidate_contents ();
    }

    public void clear_frame () {
        current = null;
        invalidate_contents ();
    }

    // ── Gdk.Paintable ────────────────────────────────────────────────────────

    public void snapshot (Gdk.Snapshot snapshot, double width, double height) {
        if (current != null) {
            current.snapshot (snapshot, width, height);
        }
    }

    public Gdk.PaintableFlags get_flags () {
        // Neither flag applies: contents change per frame, and the intrinsic size
        // changes once per load, when the new file's dimensions arrive. Claiming
        // STATIC_SIZE here would make the invalidate_size () above illegal.
        // Per-frame invalidate_contents () still only queues a redraw, so nothing
        // is lost by leaving this empty.
        return 0;
    }

    public int get_intrinsic_width () {
        return intrinsic_w;
    }

    public int get_intrinsic_height () {
        return intrinsic_h;
    }

    public double get_intrinsic_aspect_ratio () {
        if (intrinsic_w <= 0 || intrinsic_h <= 0)
            return 0.0;
        return (double) intrinsic_w / (double) intrinsic_h;
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MpvBackend — libmpv playback for the preview players
//
//  Replaces Gtk.MediaFile, whose playbin3 pipeline buffers entire AV1-in-Matroska
//  files into memory (see docs/upstream-gstreamer-playbin3-matroska-memory.md).
//  mpv's demuxer read-ahead is bounded by option, so the pathology cannot occur.
//
//  Threading: every libmpv call happens on the main thread.  New frames are
//  discovered by polling mpv_render_context_update() from the GTK frame clock and
//  events by polling mpv_wait_event() with a zero timeout, rather than acting on
//  mpv's callbacks directly.  The callbacks fire on mpv's own threads, so driving
//  from the main loop instead avoids marshalling and the lifetime hazards that
//  come with it.
// ═══════════════════════════════════════════════════════════════════════════════

public class MpvBackend : Object {

    // Bound the demuxer so a large input cannot balloon resident memory. These
    // are well above what preview scrubbing needs and far below the unbounded
    // growth this backend exists to avoid.
    private const string DEMUXER_MAX_BYTES      = "32MiB";
    private const string DEMUXER_MAX_BACK_BYTES = "16MiB";

    // Software rendering is single-threaded on the CPU, so cap the render target
    // regardless of how large the widget gets. Upscaling the result costs the GPU
    // nothing and keeps a maximised pop-out window from stalling playback.
    private const int MAX_RENDER_WIDTH  = 1920;
    private const int MAX_RENDER_HEIGHT = 1080;

    private const uint EVENT_POLL_INTERVAL_MS = 50;

    // ── Signals ──────────────────────────────────────────────────────────────

    /** Emitted once per load, when duration and dimensions are known. */
    public signal void file_loaded ();

    /** Emitted when mpv could not open or decode the file. */
    public signal void load_failed ();

    // ── mpv state ────────────────────────────────────────────────────────────

    private Mpv.Handle? handle = null;
    private Mpv.RenderContext? render_ctx = null;
    private bool with_video;
    private ulong settings_changed_handler_id = 0;
    private string active_hwdec = "";

    // ── Render target ────────────────────────────────────────────────────────

    private Gtk.Picture? target_picture = null;
    private MpvFramePaintable? paintable = null;
    private uint tick_id = 0;
    private uint8[]? frame_buf = null;
    private int buf_width  = 0;
    private int buf_height = 0;
    private int buf_stride = 0;

    // ── Cached media properties ──────────────────────────────────────────────

    private uint event_source = 0;
    private bool _loaded = false;
    private double _duration = 0.0;
    private int _video_width  = 0;
    private int _video_height = 0;

    public bool loaded { get { return _loaded; } }
    public double duration { get { return _duration; } }
    public int video_width  { get { return _video_width;  } }
    public int video_height { get { return _video_height; } }

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTION
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * @param with_video false for audio-only playback, which skips video
     *                   decoding entirely rather than decoding and discarding.
     */
    public MpvBackend (bool with_video) {
        this.with_video = with_video;

        // Apply a Preferences change to an already-open player, so toggling
        // hardware decoding does not appear to do nothing until the next input
        // is loaded. mpv honours a runtime "hwdec" change by reinitialising its
        // decoder, which keeps playback position and trim state intact — far
        // less disruptive than reloading the file.
        settings_changed_handler_id =
            AppSettings.get_default ().settings_changed.connect (() => {
                if (handle == null || !with_video) return;

                string wanted = wanted_hwdec ();
                if (wanted == active_hwdec) return;

                active_hwdec = wanted;
                handle.set_property_string ("hwdec", wanted);
            });
    }

    ~MpvBackend () {
        if (settings_changed_handler_id != 0) {
            AppSettings.get_default ().disconnect (settings_changed_handler_id);
            settings_changed_handler_id = 0;
        }

        // Both owners must be released in this order, and Vala's default field
        // teardown runs in declaration order — which would destroy the core
        // first. Callers normally reach here having already called close (), in
        // which case both are null and this does nothing.
        render_ctx = null;
        handle = null;
    }

    /**
     * Route rendered frames into a Gtk.Picture. Video-mode backends only; must
     * be called before the first open ().
     */
    public void attach_picture (Gtk.Picture picture) {
        target_picture = picture;
        paintable = new MpvFramePaintable ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  LIFECYCLE
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Open a file for playback, starting paused. Returns false if the mpv core
     * could not be created; a file that fails to decode reports load_failed ()
     * asynchronously instead.
     *
     * @param audio_stream_index zero-based index among the file's audio streams,
     *                           or -1 to let mpv choose.
     */
    public bool open (string path, int audio_stream_index = -1) {
        close ();

        ensure_c_numeric_locale ();

        handle = Mpv.Handle.create ();
        if (handle == null) {
            warning ("MpvBackend: mpv_create failed");
            return false;
        }

        apply_options (audio_stream_index);

        int err = handle.initialize ();
        if (err < 0) {
            warning ("MpvBackend: mpv_initialize failed: %s", Mpv.error_string (err));
            handle = null;
            return false;
        }

        // The render context must exist before the file is loaded, otherwise the
        // libmpv video output has nowhere to draw and disables video.
        if (with_video && target_picture != null) {
            int render_err = 0;
            render_ctx = Mpv.render_sw_create (handle, out render_err);
            if (render_ctx == null) {
                warning ("MpvBackend: render context creation failed: %s",
                         Mpv.error_string (render_err));
                handle = null;
                return false;
            }
        }

        err = Mpv.cmd (handle, "loadfile", path);
        if (err < 0) {
            warning ("MpvBackend: loadfile failed: %s", Mpv.error_string (err));
            close ();
            return false;
        }

        start_event_poll ();
        start_render_tick ();
        return true;
    }

    /**
     * Tear the player down and release its memory. Safe to call when not open.
     */
    public void close () {
        stop_render_tick ();
        stop_event_poll ();

        if (target_picture != null) {
            target_picture.set_paintable (null);
        }
        if (paintable != null) {
            paintable.clear_frame ();
        }

        // Order matters: the render context must go before the core it was
        // created against, or libmpv's behaviour is undefined.
        render_ctx = null;
        handle = null;

        frame_buf = null;
        buf_width  = 0;
        buf_height = 0;
        buf_stride = 0;

        _loaded = false;
        _duration = 0.0;
        _video_width  = 0;
        _video_height = 0;
        active_hwdec = "";
    }

    private void apply_options (int audio_stream_index) {
        // Ignore the user's mpv.conf, scripts and OSC: this is an embedded
        // preview, and inherited settings would change decode behaviour
        // unpredictably.
        set_option ("config", "no");
        set_option ("load-scripts", "no");
        set_option ("osc", "no");
        set_option ("terminal", "no");
        set_option ("input-default-bindings", "no");
        set_option ("input-vo-keyboard", "no");
        set_option ("ytdl", "no");

        // Don't pick up sidecar audio or subtitle files next to the input.
        set_option ("audio-file-auto", "no");
        set_option ("sub-auto", "no");
        set_option ("sid", "no");

        // Stay loaded and paused at EOF so the position remains seekable, which
        // is what the transport controls expect.
        set_option ("idle", "yes");
        set_option ("keep-open", "yes");
        set_option ("pause", "yes");

        set_option ("demuxer-max-bytes", DEMUXER_MAX_BYTES);
        set_option ("demuxer-max-back-bytes", DEMUXER_MAX_BACK_BYTES);

        if (with_video && target_picture != null) {
            set_option ("vo", "libmpv");
            // Software rendering does colour conversion and scaling on one CPU
            // thread; sw-fast trades filter quality for the throughput a preview
            // needs.
            set_option ("profile", "sw-fast");
            // A "-copy" mode is mandatory: the software renderer needs frames in
            // system memory, so the decoder must read them back rather than hand
            // over a GPU surface. "safe" restricts this to hardware decoders mpv
            // considers reliable and falls back to software when there is no
            // trustworthy one, which matters because this runs on hardware we
            // cannot test. On a fast CPU it is roughly a wash — measured 264 ms
            // vs 240 ms per exact seek on a 24-core desktop — but on the weaker
            // machines this preview is meant to stay usable on, offloading the
            // decode is the difference that counts. Users can force software
            // decoding from Preferences when a driver misbehaves.
            active_hwdec = wanted_hwdec ();
            set_option ("hwdec", active_hwdec);
        } else {
            set_option ("vo", "null");
            set_option ("vid", "no");
            set_option ("audio-display", "no");
        }

        if (audio_stream_index >= 0) {
            // mpv numbers audio tracks from 1; callers use a zero-based index
            // over the file's audio streams, matching ffmpeg's -map 0:a:N.
            set_option ("aid", (audio_stream_index + 1).to_string ());
        }
    }

    /**
     * The hwdec mode the current preference asks for.
     *
     * "-copy" is not optional — the software renderer needs frames in system
     * memory, so a plain GPU-surface mode would render nothing.
     */
    private static string wanted_hwdec () {
        return AppSettings.get_default ().hardware_decoding ? "auto-copy-safe" : "no";
    }

    private static bool c_numeric_locale_set = false;

    /**
     * mpv_create () refuses to run unless LC_NUMERIC is "C", and GTK sets the
     * locale from the environment during initialisation — so under any locale
     * that uses a comma decimal separator the player would simply never start.
     *
     * Forcing it back is what libmpv hosts are expected to do, and it is the
     * right setting for this application besides: the numbers it formats end up
     * in FFmpeg command lines and mpv commands, both of which parse C-locale
     * decimals. Only numeric formatting is affected; messages and dates keep the
     * user's locale.
     */
    private static void ensure_c_numeric_locale () {
        if (c_numeric_locale_set) return;
        c_numeric_locale_set = true;
        Intl.setlocale (LocaleCategory.NUMERIC, "C");
    }

    private void set_option (string name, string value) {
        if (handle == null) return;

        int err = handle.set_option_string (name, value);
        if (err < 0) {
            debug ("MpvBackend: option %s=%s rejected: %s",
                   name, value, Mpv.error_string (err));
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  TRANSPORT
    // ═════════════════════════════════════════════════════════════════════════

    public double get_position () {
        if (handle == null) return 0.0;

        double value = 0.0;
        if (Mpv.get_double (handle, "time-pos", out value) < 0)
            return 0.0;
        return value;
    }

    /**
     * True while playback is running. Reads mpv rather than a cached flag so
     * that stopping at end of file is observed without extra bookkeeping.
     */
    public bool get_playing () {
        if (handle == null) return false;

        int paused = 0;
        if (Mpv.get_flag (handle, "pause", out paused) < 0)
            return false;
        return paused == 0;
    }

    public void set_playing (bool playing) {
        if (handle == null) return;

        // Restart from the beginning when play is pressed at end of file;
        // otherwise unpausing leaves the player sitting on the last frame.
        if (playing && at_end_of_file ()) {
            seek_absolute (0.0);
        }

        Mpv.set_flag (handle, "pause", playing ? 0 : 1);
    }

    public void set_muted (bool muted) {
        if (handle == null) return;
        Mpv.set_flag (handle, "mute", muted ? 1 : 0);
    }

    private bool at_end_of_file () {
        if (handle == null) return false;

        int eof = 0;
        if (Mpv.get_flag (handle, "eof-reached", out eof) < 0)
            return false;
        return eof != 0;
    }

    /**
     * Seek to an absolute position, always landing on the exact frame.
     *
     * Deliberately never snaps to keyframes. Callers read get_position () back
     * to populate trim points, so an approximate position would silently become
     * an approximate cut.
     */
    public void seek_absolute (double seconds) {
        if (handle == null || !_loaded) return;

        double target = double.max (0.0, seconds);
        if (_duration > 0.0) {
            target = double.min (target, _duration);
        }

        // "exact" forces a precise seek rather than snapping to the nearest
        // keyframe, which is what trim-point selection needs.
        Mpv.cmd (handle, "seek", "%.6f".printf (target), "absolute+exact");
    }

    public void seek_relative (double seconds) {
        if (handle == null || !_loaded) return;
        seek_absolute (get_position () + seconds);
    }

    /**
     * Step exactly one frame in either direction, pausing first so the frame is
     * visible. Uses mpv's own frame stepping, which is frame-accurate rather
     * than seeking by an assumed frame duration.
     */
    public void frame_step (int direction) {
        if (handle == null || !_loaded) return;

        Mpv.set_flag (handle, "pause", 1);
        Mpv.cmd (handle, direction < 0 ? "frame-back-step" : "frame-step");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Event pump
    // ═════════════════════════════════════════════════════════════════════════

    private void start_event_poll () {
        stop_event_poll ();
        event_source = Timeout.add (EVENT_POLL_INTERVAL_MS, () => {
            drain_events ();
            return (event_source != 0) ? Source.CONTINUE : Source.REMOVE;
        });
    }

    private void stop_event_poll () {
        if (event_source != 0) {
            Source.remove (event_source);
            event_source = 0;
        }
    }

    private void drain_events () {
        // Handlers of the signals emitted below may call close (), which nulls
        // the handle — so re-check it on every iteration rather than once.
        while (handle != null) {
            int end_file_reason = -1;
            int event_id = Mpv.next_event (handle, out end_file_reason);

            if (event_id == Mpv.EVENT_NONE)
                return;

            if (event_id == Mpv.EVENT_FILE_LOADED) {
                on_file_loaded ();
            } else if (event_id == Mpv.EVENT_VIDEO_RECONFIG) {
                refresh_video_size ();
            } else if (event_id == Mpv.EVENT_END_FILE) {
                if (end_file_reason == Mpv.END_FILE_REASON_ERROR) {
                    load_failed ();
                }
            } else if (event_id == Mpv.EVENT_SHUTDOWN) {
                return;
            }
        }
    }

    private void on_file_loaded () {
        if (handle == null) return;

        double dur = 0.0;
        if (Mpv.get_double (handle, "duration", out dur) >= 0 && dur > 0.0) {
            _duration = dur;
        }

        refresh_video_size ();
        report_active_decoder ();

        _loaded = true;
        file_loaded ();
    }

    /**
     * Log which decoder mpv actually chose.
     *
     * mpv accepts any string for "hwdec" without validating it — a misspelled
     * value returns success and then silently decodes in software forever. This
     * reads back what is really in use so that failure mode is visible in a
     * debug log instead of being invisible. Expect "vulkan-copy", "vaapi-copy"
     * and similar when hardware decoding took, or "no" when it fell back.
     */
    private void report_active_decoder () {
        if (handle == null || !with_video) return;

        string current = handle.get_property_string ("hwdec-current") ?? "unknown";
        debug ("MpvBackend: decoding via %s", current);
    }

    private void refresh_video_size () {
        if (handle == null || !with_video) return;

        int64 w = 0;
        int64 h = 0;

        // "width"/"height" are the coded dimensions, which is the coordinate
        // space ffmpeg's crop filter operates in — unlike display dimensions,
        // which differ for anamorphic sources.
        if (Mpv.get_int64 (handle, "width", out w) < 0) return;
        if (Mpv.get_int64 (handle, "height", out h) < 0) return;
        if (w <= 0 || h <= 0) return;

        _video_width  = (int) w;
        _video_height = (int) h;

        if (paintable != null) {
            paintable.set_video_size (_video_width, _video_height);
        }
        if (target_picture != null && target_picture.get_paintable () == null) {
            target_picture.set_paintable (paintable);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Rendering
    // ═════════════════════════════════════════════════════════════════════════

    private void start_render_tick () {
        if (render_ctx == null || target_picture == null) return;
        if (tick_id != 0) return;

        tick_id = target_picture.add_tick_callback ((widget, clock) => {
            poll_and_render ();
            return Source.CONTINUE;
        });
    }

    private void stop_render_tick () {
        if (tick_id != 0 && target_picture != null) {
            target_picture.remove_tick_callback (tick_id);
        }
        tick_id = 0;
    }

    private void poll_and_render () {
        if (render_ctx == null) return;

        if ((render_ctx.update () & Mpv.RENDER_UPDATE_FRAME) == 0)
            return;

        int width, height;
        if (!compute_render_size (out width, out height))
            return;

        if (!ensure_frame_buffer (width, height))
            return;

        int err = Mpv.render_sw_draw (render_ctx, frame_buf,
                                      buf_width, buf_height, buf_stride);
        if (err < 0) {
            debug ("MpvBackend: software render failed: %s", Mpv.error_string (err));
            return;
        }

        // A GdkTexture must be immutable, so the frame is copied out of the
        // reusable scratch buffer rather than aliasing it — otherwise GTK could
        // composite a buffer we are already overwriting.
        var bytes = new Bytes (frame_buf);
        var texture = new Gdk.MemoryTexture (buf_width, buf_height,
                                             Gdk.MemoryFormat.B8G8R8X8,
                                             bytes, buf_stride);

        if (paintable != null) {
            paintable.set_frame (texture);
        }
    }

    /**
     * Render at the video's aspect ratio scaled to the widget, not at the
     * widget's own aspect. mpv would otherwise pad the target with black bars,
     * which would show inside the frame instead of the themed background that
     * Gtk.Picture's CONTAIN fit produces.
     */
    private bool compute_render_size (out int width, out int height) {
        width = 0;
        height = 0;

        if (target_picture == null || _video_width <= 0 || _video_height <= 0)
            return false;

        int scale = target_picture.get_scale_factor ().clamp (1, 4);
        int avail_w = target_picture.get_width ()  * scale;
        int avail_h = target_picture.get_height () * scale;
        if (avail_w <= 0 || avail_h <= 0)
            return false;

        avail_w = int.min (avail_w, MAX_RENDER_WIDTH);
        avail_h = int.min (avail_h, MAX_RENDER_HEIGHT);

        // Never render above source resolution; upscaling on the CPU buys
        // nothing that GTK cannot do for free when it draws the texture.
        avail_w = int.min (avail_w, _video_width);
        avail_h = int.min (avail_h, _video_height);

        double scale_factor = double.min (
            (double) avail_w / (double) _video_width,
            (double) avail_h / (double) _video_height
        );
        if (scale_factor <= 0.0)
            return false;

        width  = int.max (2, (int) Math.round (_video_width  * scale_factor));
        height = int.max (2, (int) Math.round (_video_height * scale_factor));
        return true;
    }

    private bool ensure_frame_buffer (int width, int height) {
        if (frame_buf != null && width == buf_width && height == buf_height)
            return true;

        // mpv asks for a stride that is a multiple of 64 so its scaler can use
        // aligned SIMD paths instead of copying the whole frame.
        int stride = ((width * 4) + 63) & ~63;
        int size = stride * height;
        if (size <= 0)
            return false;

        frame_buf  = new uint8[size];
        buf_width  = width;
        buf_height = height;
        buf_stride = stride;
        return true;
    }
}
