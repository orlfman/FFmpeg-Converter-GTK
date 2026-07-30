using Gtk;

// ═══════════════════════════════════════════════════════════════════════════════
//  MpvFramePaintable — GdkPaintable wrapper around the most recent mpv frame
//
//  Reports the size of the frame mpv draws as its intrinsic size, independent of
//  the resolution we actually rendered at.  That keeps Gtk.Picture's layout
//  stable while the render target follows the widget allocation.
//
//  It is deliberately the *display* size — rotation and sample aspect already
//  applied — not the coded size, so that the aspect Gtk.Picture lays out to
//  matches the aspect of the texture it is handed.  Coded dimensions are a
//  separate concern belonging to crop coordinates; see MpvBackend.video_width.
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
//  Threading: every libmpv call happens on the main thread.  mpv's wakeup and
//  render-update callbacks fire on mpv's own threads, so they are used only as
//  notifications — each does nothing but set a coalescing flag and schedule an
//  idle, and the idle does the actual libmpv work back on the main thread.
//  That keeps the marshalling and lifetime hazards confined to two small
//  handlers while still letting a paused, unchanging preview go completely
//  quiet.  Both callbacks are cleared in close () before the objects they
//  reference are released.
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

    /**
     * How long to wait for the output to settle after a file opens before giving
     * up and using whatever mpv has reported.
     *
     * Normally the settled reconfig arrives within a few milliseconds of the
     * file opening, so this never fires. It exists so that a source which never reaches the
     * expected state — a transpose that failed to insert, or a video track mpv
     * decides it cannot decode and so never reconfigures for — degrades to a
     * possibly-wrong frame rather than to a preview that stays blank forever.
     */
    private const uint SETTLE_DEADLINE_MS = 400;

    // ── Signals ──────────────────────────────────────────────────────────────

    /** Emitted once mpv has opened the media and initial output state is ready. */
    public signal void file_loaded ();

    /**
     * Emitted when the frame size changes after the initial load.
     *
     * mpv reports the container's idea of the dimensions until a frame has
     * actually been decoded, and containers lie, so the first size is not
     * always the final one.
     */
    public signal void video_size_changed ();

    /** Emitted after closing a core that could not open or decode the file. */
    public signal void load_failed (string detail);

    /**
     * Emitted once a seek or frame step has actually landed.
     *
     * Consumers read the position back when this fires rather than polling for
     * it. mpv's seeks are asynchronous, so reading immediately after issuing
     * one returns the old position; this is the point at which the new one is
     * true.
     */
    public signal void playback_restarted ();

    // ── mpv state ────────────────────────────────────────────────────────────

    private Mpv.Handle? handle = null;
    private Mpv.RenderContext? render_ctx = null;
    private bool with_video;
    private string active_hwdec = "";

    // ── Render target ────────────────────────────────────────────────────────

    private Gtk.Picture? target_picture = null;
    private MpvFramePaintable? paintable = null;
    private bool render_notify_installed = false;
    // Accessed from mpv's threads as well as the main one; use AtomicInt only.
    private int render_queued = 0;
    private int buf_width  = 0;
    private int buf_height = 0;
    private int buf_stride = 0;
    private int buf_size   = 0;
    private int buf_row_bytes = 0;   // visible bytes per row, i.e. width * 4

    // ── Cached media properties ──────────────────────────────────────────────

    private bool event_notify_installed = false;
    // Accessed from mpv's threads as well as the main one; use AtomicInt only.
    private int event_drain_queued = 0;
    private bool _loaded = false;
    private double _duration = 0.0;
    private int _video_width  = 0;
    private int _video_height = 0;
    private int _render_width  = 0;
    private int _render_height = 0;
    private int _rotation = 0;
    private bool rotation_applied = false;
    private bool load_announced = false;
    private bool force_settled = false;
    private uint settle_deadline_source = 0;
    private int requested_audio_index = -1;

    public bool loaded { get { return _loaded; } }
    public double duration { get { return _duration; } }

    /**
     * Coded frame dimensions, before rotation and before aspect correction.
     * This is not what ends up on screen — see render_width/render_height.
     */
    public int video_width  { get { return _video_width;  } }
    public int video_height { get { return _video_height; } }

    /**
     * Dimensions of the frame mpv actually draws: rotation and sample aspect
     * already applied. The render target and the paintable's intrinsic size
     * both come from here, because sizing them from the coded dimensions makes
     * mpv letterbox the frame inside the target and bake black bars into the
     * texture.
     */
    public int render_width  { get { return _render_width;  } }
    public int render_height { get { return _render_height; } }

    /** Container rotation in degrees clockwise: 0, 90, 180 or 270. */
    public int rotation { get { return _rotation; } }

    /**
     * Dimensions of the coordinate space ffmpeg's crop filter operates in.
     *
     * This is a third space, equal to neither of the two above. FFmpeg applies
     * the container's rotation before any -vf the application supplies, so crop
     * coordinates are in the *rotated* frame — but it does not scale for
     * non-square pixels, so they are not in the *aspect-corrected* frame either.
     * Coded dimensions with the axes swapped for a quarter turn is exactly that
     * space. Verified by cropping past the coded height on a rotated file, which
     * ffmpeg accepts, and rejects under -noautorotate.
     */
    public int crop_width {
        get { return crop_space_width (_rotation, _video_width, _video_height); }
    }

    public int crop_height {
        get { return crop_space_height (_rotation, _video_width, _video_height); }
    }

    /**
     * A quarter turn swaps the axes; a half turn or none leaves them alone.
     * Anything else has already been normalised away by normalize_rotation.
     */
    internal static bool is_quarter_turn (int rotation) {
        return rotation == 90 || rotation == 270;
    }

    internal static int crop_space_width (int rotation, int coded_w, int coded_h) {
        return is_quarter_turn (rotation) ? coded_h : coded_w;
    }

    internal static int crop_space_height (int rotation, int coded_w, int coded_h) {
        return is_quarter_turn (rotation) ? coded_w : coded_h;
    }

    internal static double aspect_of (int width, int height) {
        if (width <= 0 || height <= 0) return 0.0;
        return (double) width / (double) height;
    }

    /**
     * Aspect ratio of the frame as drawn, or 0.0 when it is not known yet.
     *
     * A consumer that positions something over the preview needs this rather
     * than the crop-space aspect: the two differ whenever pixels are not square.
     * Deliberately an aspect and not a per-axis scale — rotation moves the
     * stretch between axes. A 90-degree-rotated 720x576 frame with 64:45 pixels
     * is drawn 576x1024, so the correction that was horizontal before the
     * rotation is vertical after it, and one scale factor cannot describe both.
     */
    public double display_aspect {
        get { return aspect_of (_render_width, _render_height); }
    }

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
        // Keep this as a named instance handler rather than a closure. Vala
        // emits g_signal_connect_object () for the former, so AppSettings holds
        // only a weak association with this backend and disconnects the handler
        // automatically when the backend is destroyed. A closure that captures
        // `this` would let the process-lifetime singleton keep every backend
        // alive forever.
        AppSettings.get_default ().settings_changed.connect (on_settings_changed);
    }

    private void on_settings_changed () {
        if (handle == null || !with_video) return;

        string wanted = wanted_hwdec ();
        if (wanted == active_hwdec) return;

        active_hwdec = wanted;
        handle.set_property_string ("hwdec", wanted);
    }

    ~MpvBackend () {
        // In practice this always runs after close (), so both fields are
        // already null and it does nothing — not by convention but by
        // construction: an open backend is referenced by its own scheduled
        // idles and by mpv's callbacks, so it cannot be finalised until close ()
        // has released them.
        //
        // The ordering is kept anyway because it is the only correct one if
        // that ever stops holding: the render context must go before the core
        // it was created against, and Vala's default field teardown runs in
        // declaration order, which would destroy the core first.
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
     * could not be created; a file that fails to decode reports
     * load_failed (detail) asynchronously instead.
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

        requested_audio_index = audio_stream_index;
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

        start_event_notify ();
        start_render_notify ();
        return true;
    }

    /**
     * Tear the player down and release its memory. Safe to call when not open.
     */
    public void close () {
        // Clear both notification callbacks before anything they point at goes
        // away. They hold a bare `this` and are called from mpv's threads, so
        // this must happen while the handle and render context are still valid.
        // Both setters take the same lock mpv holds while invoking the
        // callback, so clearing one blocks until any in-flight call has
        // returned and no further call can begin — which is what makes the bare
        // `this` safe rather than merely unlikely to crash.
        stop_render_notify ();
        stop_event_notify ();
        stop_settle_deadline ();

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

        // An idle queued before this point still runs, holding a reference to
        // this backend, and finds the handle and context null — hence the
        // guards in queue_event_drain () and poll_and_render (). The coalescing
        // flags are deliberately not reset here: each is only ever cleared by
        // the idle that set it, so clearing one now would let a second idle be
        // queued for work the first is already going to do.

        buf_width  = 0;
        buf_height = 0;
        buf_stride = 0;
        buf_size   = 0;
        buf_row_bytes = 0;

        _loaded = false;
        _duration = 0.0;
        _video_width  = 0;
        _video_height = 0;
        _render_width  = 0;
        _render_height = 0;
        _rotation = 0;
        rotation_applied = false;
        load_announced = false;
        force_settled = false;
        requested_audio_index = -1;
        active_hwdec = "";
    }

#if MPV_BACKEND_STATE_TEST_BUILD
    internal bool has_core_for_test () {
        return handle != null;
    }

    internal bool has_render_context_for_test () {
        return render_ctx != null;
    }

    internal bool has_event_source_for_test () {
        return event_notify_installed;
    }

    internal bool has_render_tick_for_test () {
        return render_notify_installed;
    }

    /**
     * The "video-timing-offset" the live core is actually running with.
     *
     * Read back from mpv rather than from our own bookkeeping: the option is
     * set before initialize () and mpv validates lazily, so "we called
     * set_option" is not the same as "the core is using it".
     */
    internal double effective_timing_offset_for_test () {
        if (handle == null) return -1.0;

        double value = -1.0;
        if (Mpv.get_double (handle, "video-timing-offset", out value) < 0)
            return -1.0;
        return value;
    }

    internal int audio_track_count_for_test () {
        return count_audio_tracks ();
    }

    /** mpv's "aid" as it stands after selection; "no" means nothing selected. */
    internal string selected_aid_for_test () {
        if (handle == null) return "";
        return handle.get_property_string ("aid") ?? "";
    }

    /**
     * Provoke MPV_EVENT_SHUTDOWN. The application never sends "quit" and has
     * neither terminal nor input bindings enabled, so this event is otherwise
     * unreachable and its handling would go untested.
     */
    internal void request_shutdown_for_test () {
        if (handle != null)
            Mpv.cmd (handle, "quit");
    }
#endif

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
            // mpv's own autorotate filter crashes the software renderer: any
            // file whose container asks for 90 or 270 degrees aborts the
            // process inside mpv_render_context_render () with
            // "mp_image_crop: Assertion `x1 <= img->w && y1 <= img->h'".
            // 180 is unaffected, which points at the width/height swap.
            //
            // So rotation is handled here instead — the flag is ignored and an
            // equivalent transpose is inserted once the file is open, which
            // reaches the same pixels without the crashing code path. Because
            // this also disables the 180 case that mpv handles correctly, the
            // transpose below must cover every angle, not just 90 and 270.
            // DevTools/mpv-render-probe.c reproduces both halves.
            set_option ("video-rotate", "no");
            // Software rendering does colour conversion and scaling on one CPU
            // thread; sw-fast trades filter quality for the throughput a preview
            // needs.
            set_option ("profile", "sw-fast");
            // How far ahead of a frame's display time mpv prepares it, before
            // blocking inside mpv_render_context_render () until that time
            // arrives. That wait is paid by whoever calls render — here the GTK
            // main thread.
            //
            // The default 50 ms is not the real bound: mpv cannot start the next
            // frame until the previous one is displayed, so the wait is really
            // min (offset, frame interval), and the whole interval is spent in
            // it — 99% of wall time at every frame rate measured. When rendering
            // was driven by a GTK frame-clock tick, 60 fps sources escaped this,
            // which is why it was easy to miss; now that rendering is driven by
            // mpv's notification, no rate escapes.
            //
            // Zero keeps mpv's audio-relative timing and only removes the
            // lookahead: the frame becomes available at its display time, so the
            // render returns immediately. Measured |avsync| stays under 8 ms and
            // playback CPU goes down, not up. Paused work — exact seeks and
            // frame stepping, which is most of what this preview is used for —
            // is unaffected either way; it never had a display time to wait for.
            // Do not "fix" this by disabling the render block alone — that
            // presents frames early and makes mpv drop them.
            // DevTools/mpv-render-timing-probe.c measures all of this.
            set_option ("video-timing-offset", "0");
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
            set_option ("aid", aid_option_for_index (audio_stream_index));
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

    /**
     * Ask mpv to tell us when events are queued, instead of asking it 20 times
     * a second whether any are.
     *
     * The callback runs on an mpv thread and does nothing but schedule; every
     * libmpv call still happens on the main thread, which is the property the
     * previous polling design existed to guarantee.
     */
    private void start_event_notify () {
        if (handle == null) return;

        event_notify_installed = true;
        Mpv.set_wakeup_callback (handle, on_mpv_wakeup, this);

        // mpv only signals on the queue going from empty to non-empty, so
        // anything queued between initialize () and this point would otherwise
        // wait for the next unrelated event.
        queue_event_drain ();
    }

    private void stop_event_notify () {
        if (handle != null) {
            Mpv.set_wakeup_callback (handle, null, null);
        }
        event_notify_installed = false;
    }

    /**
     * Runs on an mpv thread. Must not touch libmpv or any backend state beyond
     * the coalescing flag, which is why it immediately hands off to the main
     * loop.
     *
     * `this` stays valid because the handle owns this callback and the backend
     * owns the handle: stop_event_notify () clears the callback before the
     * handle is released, and the backend outlives its own handle.
     */
    private static void on_mpv_wakeup (void* user_data) {
        unowned MpvBackend self = (MpvBackend) user_data;
        self.queue_event_drain ();
    }

    private void queue_event_drain () {
        // Coalesce: a burst of events on mpv's side must not turn into a burst
        // of idle callbacks, because one drain_events () consumes the lot.
        if (!AtomicInt.compare_and_exchange (ref event_drain_queued, 0, 1))
            return;

        // Capturing `this` makes Vala hold a reference for the lifetime of the
        // source, so the backend cannot be finalised with a drain outstanding.
        Idle.add (() => {
            AtomicInt.set (ref event_drain_queued, 0);
            if (handle != null) {
                drain_events ();
            }
            return Source.REMOVE;
        });
    }

    private void drain_events () {
        // Handlers of the signals emitted below may call close (), which nulls
        // the handle — so re-check it on every iteration rather than once.
        while (handle != null) {
            int end_file_reason = -1;
            int end_file_error = 0;
            int event_id = Mpv.next_event (handle,
                                           out end_file_reason,
                                           out end_file_error);

            if (event_id == Mpv.EVENT_NONE)
                return;

            if (event_id == Mpv.EVENT_FILE_LOADED) {
                on_file_loaded ();
            } else if (event_id == Mpv.EVENT_VIDEO_RECONFIG) {
                on_video_reconfig ();
            } else if (event_id == Mpv.EVENT_PLAYBACK_RESTART) {
                playback_restarted ();
            } else if (event_id == Mpv.EVENT_END_FILE) {
                if (end_file_reason == Mpv.END_FILE_REASON_ERROR) {
                    string detail = end_file_error < 0
                        ? Mpv.error_string (end_file_error)
                        : "unknown playback error";

                    // An "aid" naming a stream the file does not have leaves
                    // mpv with nothing selected, and it reports that as the
                    // generic "no audio or video data played" rather than as a
                    // bad selection. The track list is already torn down by the
                    // time this arrives, so the requested index cannot be
                    // checked against it — but it is the only selection this
                    // backend makes, so naming it is still the most useful
                    // thing that can be said.
                    if (end_file_error == Mpv.ERROR_NOTHING_TO_PLAY
                        && requested_audio_index >= 0
                        && !load_announced) {
                        detail = "could not select audio stream %d (%s)"
                            .printf (requested_audio_index, detail);
                    }

                    // Failure is a terminal state for this load. Tear down the
                    // event source, render callback and core before notifying
                    // consumers, so even an error after FILE_LOADED cannot
                    // leave the transport pointing at a dead player.
                    close ();
                    load_failed (detail);
                }
            } else if (event_id == Mpv.EVENT_SHUTDOWN) {
                // Destruction is the only legal operation on the handle from
                // here, so this is terminal in the same way an END_FILE error
                // is. Returning without tearing down used to leave the core and
                // both timers alive, and because Vala's Timeout closures hold a
                // reference to this object, that pinned the whole backend --
                // core, render context and demuxer buffers -- behind a 20 Hz
                // poll that could never do anything again.
                close ();
                load_failed ("the mpv core shut down unexpectedly");
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

        apply_container_rotation ();
        verify_audio_selection ();
        report_active_decoder ();

        _loaded = true;

        // Dimensions here are still whatever the container claimed, and the
        // transpose just installed has not reconfigured the output yet, so hold
        // the announcement until VIDEO_RECONFIG reports what is really being
        // drawn. A file with no video track never produces one, so those are
        // announced here instead.
        if (has_video_track ()) {
            start_settle_deadline ();
        } else {
            refresh_video_size ();
            announce_load ();
        }
    }

    private void start_settle_deadline () {
        stop_settle_deadline ();
        settle_deadline_source = Timeout.add (SETTLE_DEADLINE_MS, () => {
            settle_deadline_source = 0;

            // Stop holding out for the state we expected and take what we have,
            // so a file that never gets there is merely drawn wrong rather than
            // never drawn and never announced.
            force_settled = true;
            refresh_video_size ();
            announce_load ();
            return Source.REMOVE;
        });
    }

    private void stop_settle_deadline () {
        if (settle_deadline_source != 0) {
            Source.remove (settle_deadline_source);
            settle_deadline_source = 0;
        }
    }

    private void on_video_reconfig () {
        refresh_video_size ();

        if (load_announced) {
            video_size_changed ();
        } else {
            announce_load ();
        }
    }

    private void announce_load () {
        if (load_announced) return;
        load_announced = true;
        file_loaded ();
    }

    /**
     * Check that the requested audio stream actually exists, and fall back to
     * mpv's own choice when it does not.
     *
     * The index is handed to mpv as an "aid" option before the file is open, so
     * there is nothing to validate it against until now.
     *
     * This covers the case where the file still loads with a bad index — a
     * backend that is also decoding video, which has something to play whether
     * or not the audio selection worked. There mpv resets "aid" to "no" without
     * reporting anything, and the preview is silently mute. When there is no
     * video to fall back on, mpv instead fails the load outright with
     * MPV_ERROR_NOTHING_TO_PLAY and never reaches this point; drain_events
     * handles that case.
     *
     * Falling back rather than failing is deliberate here: video is playing, so
     * a preview using mpv's default track is more useful than a mute one.
     */
    private void verify_audio_selection () {
        if (handle == null || requested_audio_index < 0) return;

        int audio_tracks = count_audio_tracks ();
        if (!audio_index_is_out_of_range (requested_audio_index, audio_tracks))
            return;

        warning ("MpvBackend: audio stream %d requested but the file has only %d;"
                 + " falling back to mpv's default track",
                 requested_audio_index, audio_tracks);
        handle.set_property_string ("aid", "auto");
    }

    /**
     * Number of audio tracks in the open file, or 0 when the list is not
     * available. Note mpv empties the track list as the file ends, so this is
     * only meaningful between FILE_LOADED and END_FILE.
     */
    private int count_audio_tracks () {
        if (handle == null) return 0;

        int64 total = 0;
        if (Mpv.get_int64 (handle, "track-list/count", out total) < 0) return 0;

        int audio = 0;
        for (int i = 0; i < (int) total; i++) {
            string? type = handle.get_property_string (
                "track-list/%d/type".printf (i));
            if (type == "audio") audio++;
        }
        return audio;
    }

    /**
     * True when the loaded file has a video track selected. Distinguishes "the
     * output has not been configured yet" from "there will never be video", so
     * an audio-only file opened in a video player still reports its duration.
     */
    private bool has_video_track () {
        if (handle == null || !with_video) return false;

        int64 id = 0;
        return Mpv.get_int64 (handle, "current-tracks/video/id", out id) >= 0;
    }

    /**
     * Rotate the frame ourselves, standing in for the autorotate filter that
     * apply_options () had to switch off.
     */
    private void apply_container_rotation () {
        if (handle == null || !with_video || rotation_applied) return;
        rotation_applied = true;

        int64 rot = 0;
        // The only rotation property that carries the angle this early.
        // "video-dec-params/rotate" does not exist until the first
        // VIDEO_RECONFIG, by which point a sideways frame has already been
        // rendered; "video-params/rotate" reads 0 because video-rotate is off.
        // It is absent rather than 0 when the container asks for no rotation.
        if (Mpv.get_int64 (handle, "current-tracks/video/demux-rotation", out rot) < 0)
            rot = 0;

        _rotation = normalize_rotation ((int) rot);

        string? filter = rotation_filter (_rotation);
        if (filter != null) {
            Mpv.cmd (handle, "vf", "set", filter);
        }
    }

    /**
     * mpv numbers audio tracks from 1; callers use a zero-based index over the
     * file's audio streams, matching ffmpeg's -map 0:a:N.
     */
    internal static string aid_option_for_index (int zero_based_index) {
        return (zero_based_index + 1).to_string ();
    }

    /**
     * Whether a requested stream index names a track the file does not have.
     *
     * A file with no audio at all is not "out of range": there is nothing to
     * select and no fallback that would help, so it is left alone.
     */
    internal static bool audio_index_is_out_of_range (int requested, int available) {
        if (requested < 0) return false;
        if (available <= 0) return false;
        return requested >= available;
    }

    internal static int normalize_rotation (int degrees) {
        int r = degrees % 360;
        if (r < 0) r += 360;

        // Anything off the four right angles cannot be expressed as a
        // transpose; treat it as upright rather than guessing at a filter.
        return (r == 90 || r == 180 || r == 270) ? r : 0;
    }

    /**
     * The filter chain equivalent to rotating clockwise by @rotation degrees,
     * which is what mpv's angle means and what ffmpeg's own autorotate does.
     * Verified against ffmpeg's decode of clips carrying each flag — see
     * DevTools/mpv-render-probe.c.
     */
    internal static string? rotation_filter (int rotation) {
        switch (rotation) {
            case 90:  return "transpose=clock";
            case 180: return "transpose=clock,transpose=clock";
            case 270: return "transpose=cclock";
            default:  return null;
        }
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

        // "width"/"height" are the coded dimensions: no rotation, no aspect
        // correction. Useful as the basis for crop coordinates, but not for
        // anything to do with what appears on screen.
        if (Mpv.get_int64 (handle, "width", out w) < 0) return;
        if (Mpv.get_int64 (handle, "height", out h) < 0) return;
        if (w <= 0 || h <= 0) return;

        _video_width  = (int) w;
        _video_height = (int) h;

        // "dwidth"/"dheight" are post-filter and post-aspect — the frame mpv is
        // going to hand back. Falling back to the coded size keeps a source
        // that never reports these renderable rather than blank.
        int64 dw = 0;
        int64 dh = 0;
        if (Mpv.get_int64 (handle, "dwidth",  out dw) < 0 || dw <= 0) dw = w;
        if (Mpv.get_int64 (handle, "dheight", out dh) < 0 || dh <= 0) dh = h;

        _render_width  = (int) dw;
        _render_height = (int) dh;

        if (paintable != null) {
            paintable.set_video_size (_render_width, _render_height);
        }

        // Hold the first attach until the transpose has taken effect. mpv
        // reconfigures several times over the ~8 ms after the filter is
        // installed, and the early ones still describe the pre-transpose frame;
        // attaching on one of those puts a sideways frame on screen and snaps
        // it upright again. Now that events arrive on notification rather than
        // on a 50 ms poll, every one of those reconfigs is seen rather than
        // most being coalesced away, so this guard matters more than it did.
        if (target_picture != null
            && target_picture.get_paintable () == null
            && rotation_settled ()) {
            target_picture.set_paintable (paintable);

            // Attached, so the deadline has nothing left to rescue.
            stop_settle_deadline ();
        }
    }

    /**
     * Whether the drawn frame already reflects the rotation filter.
     *
     * A quarter turn swaps the axes, so the frame mpv reports must be the
     * opposite orientation to the coded one; while it is not, this reconfig
     * still describes the pre-transpose frame. A square frame is the same either
     * way, so there is nothing to wait for — without that case a square source
     * would never be considered settled and would never get a paintable.
     */
    private bool rotation_settled () {
        if (force_settled) return true;
        return rotation_is_settled (_rotation, _video_width, _video_height,
                                    _render_width, _render_height);
    }

    internal static bool rotation_is_settled (int rotation,
                                              int coded_w, int coded_h,
                                              int drawn_w, int drawn_h) {
        if (!is_quarter_turn (rotation)) return true;
        if (drawn_w == drawn_h) return true;

        return (coded_w > coded_h) != (drawn_w > drawn_h);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Rendering
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Render when mpv says there is a frame, rather than checking at display
     * rate whether there is one.
     *
     * The previous GTK tick callback was never removed while a preview was
     * open, so the frame clock could not idle even with playback paused and the
     * image unchanged — and paused on a trim point is this player's normal
     * resting state. Driving from mpv's own update callback also means exactly
     * one render per frame produced instead of one per display refresh, which
     * is strictly fewer wakeups even during playback.
     */
    private void start_render_notify () {
        if (render_ctx == null || target_picture == null) return;

        render_notify_installed = true;
        Mpv.set_render_update_callback (render_ctx, on_mpv_render_update, this);

        // The first frame can be ready before the callback is installed.
        queue_render ();
    }

    private void stop_render_notify () {
        if (render_ctx != null) {
            Mpv.set_render_update_callback (render_ctx, null, null);
        }
        render_notify_installed = false;
    }

    /** Runs on an mpv thread; see on_mpv_wakeup for why this only schedules. */
    private static void on_mpv_render_update (void* user_data) {
        unowned MpvBackend self = (MpvBackend) user_data;
        self.queue_render ();
    }

    private void queue_render () {
        if (!AtomicInt.compare_and_exchange (ref render_queued, 0, 1))
            return;

        // Above GDK_PRIORITY_REDRAW, so the new frame is in the paintable
        // before GTK draws rather than one refresh behind it.
        Idle.add (() => {
            AtomicInt.set (ref render_queued, 0);
            poll_and_render ();
            return Source.REMOVE;
        }, Priority.HIGH_IDLE);
    }

    private void poll_and_render () {
        if (render_ctx == null) return;

        if ((render_ctx.update () & Mpv.RENDER_UPDATE_FRAME) == 0)
            return;

        int width, height;
        if (!compute_render_size (out width, out height))
            return;

        if (!ensure_frame_geometry (width, height))
            return;

        // Each frame gets its own 64-byte-aligned buffer, which is then handed
        // to the texture outright.
        //
        // A GdkTexture must be immutable, so this used to render into one
        // reusable scratch buffer and copy the frame out of it — mpv would
        // otherwise overwrite pixels GTK was still compositing. Transferring
        // ownership removes the copy without reintroducing that hazard: nothing
        // here touches the buffer again, and GTK releases it when the texture
        // goes. The alignment is what libmpv asks for on the render target and
        // is not something the GLib allocator promises.
        void* buf = Mpv.frame_buffer_alloc (buf_stride, buf_height, buf_row_bytes);
        if (buf == null) {
            warning ("MpvBackend: could not allocate a %d byte frame buffer",
                     buf_size);
            return;
        }

        int err = Mpv.render_sw_draw (render_ctx, buf,
                                      buf_width, buf_height, buf_stride);
        if (err < 0) {
            debug ("MpvBackend: software render failed: %s", Mpv.error_string (err));
            // Ownership has not transferred yet, so release it here.
            Mpv.frame_buffer_free (buf);
            return;
        }

        var texture = new Gdk.MemoryTexture (
            buf_width, buf_height,
            Gdk.MemoryFormat.B8G8R8X8,
            Mpv.frame_buffer_to_bytes (buf, buf_size),
            buf_stride);

        if (paintable != null) {
            paintable.set_frame (texture);
        }
    }

    /**
     * Render at the aspect ratio of the frame mpv is going to draw, scaled to
     * the widget — never at the widget's own aspect, and never at the coded
     * aspect. mpv fits the frame into whatever target it is given and pads the
     * remainder with black, so a target that disagrees with the drawn frame
     * bakes bars into the texture instead of letting Gtk.Picture's CONTAIN fit
     * show the themed background. That is why this works from the render
     * dimensions rather than the coded ones: they differ whenever the source is
     * rotated or has non-square pixels.
     */
    private bool compute_render_size (out int width, out int height) {
        width = 0;
        height = 0;

        if (target_picture == null || _render_width <= 0 || _render_height <= 0)
            return false;

        int scale = target_picture.get_scale_factor ().clamp (1, 4);
        return fit_render_size (target_picture.get_width ()  * scale,
                                target_picture.get_height () * scale,
                                _render_width, _render_height,
                                out width, out height);
    }

    /**
     * The arithmetic of compute_render_size, with the widget already read.
     *
     * @param avail_w device pixels the widget offers, scale factor applied
     * @param drawn_w the size of the frame mpv will draw, not the coded size
     */
    internal static bool fit_render_size (int avail_w, int avail_h,
                                          int drawn_w, int drawn_h,
                                          out int width, out int height) {
        width = 0;
        height = 0;

        if (drawn_w <= 0 || drawn_h <= 0) return false;
        if (avail_w <= 0 || avail_h <= 0) return false;

        avail_w = int.min (avail_w, MAX_RENDER_WIDTH);
        avail_h = int.min (avail_h, MAX_RENDER_HEIGHT);

        // Never render above source resolution; upscaling on the CPU buys
        // nothing that GTK cannot do for free when it draws the texture.
        avail_w = int.min (avail_w, drawn_w);
        avail_h = int.min (avail_h, drawn_h);

        double scale_factor = double.min (
            (double) avail_w / (double) drawn_w,
            (double) avail_h / (double) drawn_h
        );
        if (scale_factor <= 0.0)
            return false;

        width  = int.max (2, (int) Math.round (drawn_w * scale_factor));
        height = int.max (2, (int) Math.round (drawn_h * scale_factor));
        return true;
    }

    /**
     * Latch the geometry every frame buffer for this size will use.
     *
     * Only the numbers are cached; the storage itself is allocated per frame in
     * poll_and_render (), because each one is given away to a texture.
     */
    private bool ensure_frame_geometry (int width, int height) {
        if (width == buf_width && height == buf_height && buf_size > 0)
            return true;

        int stride, size, row_bytes;
        if (!frame_geometry_for (width, height, out stride, out size, out row_bytes))
            return false;

        buf_width  = width;
        buf_height = height;
        buf_stride = stride;
        buf_size   = size;
        buf_row_bytes = row_bytes;
        return true;
    }

    /**
     * Stride, allocation size and visible row length for a render target.
     *
     * mpv asks for a stride that is a multiple of 64 so its scaler can use
     * aligned SIMD paths instead of copying the whole frame.
     */
    internal static bool frame_geometry_for (int width, int height,
                                             out int stride, out int size,
                                             out int row_bytes) {
        stride = 0;
        size = 0;
        row_bytes = 0;

        if (width <= 0 || height <= 0) return false;

        stride = ((width * 4) + 63) & ~63;
        size = stride * height;
        row_bytes = width * 4;
        return size > 0;
    }
}
