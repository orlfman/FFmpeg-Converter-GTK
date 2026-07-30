/*
 * mpv.vapi — Vala bindings for the subset of libmpv this project uses.
 *
 * Plain client.h calls are bound directly.  The render API and the void*-based
 * property API go through the helpers in src/mpv-compat.c, which is why some
 * symbols here carry a different cheader_filename.
 */

[CCode (cheader_filename = "mpv/client.h,mpv/render.h,mpv-compat.h")]
namespace Mpv {

    // ── Core handle ──────────────────────────────────────────────────────────
    //
    // Freed with mpv_terminate_destroy, which shuts the player core down as
    // well as detaching this client.  A render context created against the
    // handle MUST be freed first — see MpvBackend.close ().

    [Compact]
    [CCode (cname = "mpv_handle", free_function = "mpv_terminate_destroy",
            has_type_id = false)]
    public class Handle {
        [CCode (cname = "mpv_create")]
        public static Handle? create ();

        [CCode (cname = "mpv_initialize")]
        public int initialize ();

        [CCode (cname = "mpv_set_option_string")]
        public int set_option_string (string name, string data);

        [CCode (cname = "mpv_set_property_string")]
        public int set_property_string (string name, string data);

        // Goes through the shim: mpv's own getter returns memory that must be
        // released with mpv_free (), which Vala's ownership rules cannot express.
        [CCode (cname = "fcg_mpv_get_property_string")]
        public string? get_property_string (string name);
    }

    // ── Software render context ──────────────────────────────────────────────

    [Compact]
    [CCode (cname = "mpv_render_context", free_function = "mpv_render_context_free",
            has_type_id = false)]
    public class RenderContext {
        [CCode (cname = "mpv_render_context_update")]
        public uint64 update ();
    }

    [CCode (cname = "fcg_mpv_render_sw_create")]
    public RenderContext? render_sw_create (Handle mpv, out int error);

    [CCode (cname = "fcg_mpv_render_sw_draw")]
    public int render_sw_draw (RenderContext ctx,
                               void* buf,
                               int width,
                               int height,
                               int stride);

    // ── Frame buffers ────────────────────────────────────────────────────────
    //
    // Raw pointers rather than uint8[]: the buffer's ownership is handed to a
    // GBytes and from there to GdkMemoryTexture, which is a transfer Vala's
    // array ownership cannot express. Allocate, render into it, wrap it once,
    // and never touch it again.

    [CCode (cname = "fcg_frame_buffer_alloc")]
    public void* frame_buffer_alloc (int stride, int height, int row_bytes);

    [CCode (cname = "fcg_frame_buffer_free")]
    public void frame_buffer_free (void* buf);

    [CCode (cname = "fcg_frame_buffer_to_bytes")]
    public GLib.Bytes frame_buffer_to_bytes (void* buf, size_t size);

    [CCode (cname = "MPV_RENDER_UPDATE_FRAME")]
    public const uint64 RENDER_UPDATE_FRAME;

    // ── Wakeup notification ──────────────────────────────────────────────────
    //
    // Both callbacks below are invoked on mpv's own threads. libmpv forbids
    // calling any mpv API from inside them, so they may only schedule work back
    // onto the main loop — see MpvBackend's notify handlers.
    //
    // Deliberately has_target = false: the handler must be a plain function
    // pointer with an explicit user_data, because mpv stores it and Vala has no
    // way to attach a destroy notify to a closure passed to these. The backend
    // passes itself and clears both callbacks before teardown.

    [CCode (cname = "mpv_wakeup_callback_fn", has_target = false)]
    public delegate void NotifyFunc (void* user_data);

    [CCode (cname = "mpv_set_wakeup_callback")]
    public void set_wakeup_callback (Handle h, NotifyFunc? fn, void* user_data);

    [CCode (cname = "mpv_render_context_set_update_callback")]
    public void set_render_update_callback (RenderContext ctx,
                                            NotifyFunc? fn,
                                            void* user_data);

    // ── Commands and properties ──────────────────────────────────────────────

    [CCode (cname = "fcg_mpv_cmd")]
    public int cmd (Handle h, string a1, string? a2 = null, string? a3 = null);

    [CCode (cname = "fcg_mpv_get_double")]
    public int get_double (Handle h, string name, out double value);

    [CCode (cname = "fcg_mpv_get_int64")]
    public int get_int64 (Handle h, string name, out int64 value);

    [CCode (cname = "fcg_mpv_get_flag")]
    public int get_flag (Handle h, string name, out int value);

    [CCode (cname = "fcg_mpv_set_double")]
    public int set_double (Handle h, string name, double value);

    [CCode (cname = "fcg_mpv_set_flag")]
    public int set_flag (Handle h, string name, int value);

    [CCode (cname = "mpv_error_string")]
    public unowned string error_string (int error);

    // ── Events ───────────────────────────────────────────────────────────────

    [CCode (cname = "fcg_mpv_next_event")]
    public int next_event (Handle h,
                           out int end_file_reason,
                           out int end_file_error,
                           out string? log_prefix,
                           out string? log_text);

    // Which decoder mpv picked, and on what, is not exposed as a property —
    // "hwdec-interop" belongs to vo=gpu and reads "(unavailable)" under the
    // software render API this application uses. The log stream is the only
    // place the device is named. See MpvBackend.on_log_message.
    [CCode (cname = "mpv_request_log_messages")]
    public int request_log_messages (Handle h, string min_level);

    [CCode (cname = "MPV_EVENT_LOG_MESSAGE")]
    public const int EVENT_LOG_MESSAGE;

    // Observed with MPV_FORMAT_NONE: the event carries no value, so it needs no
    // shim to unpack, and the property is read back the usual way once the
    // notification says it is worth reading. See MpvBackend.report_active_decoder.
    [CCode (cname = "mpv_observe_property")]
    public int observe_property (Handle h, uint64 reply_userdata,
                                 string name, int format);

    [CCode (cname = "MPV_FORMAT_NONE")]
    public const int FORMAT_NONE;

    [CCode (cname = "MPV_EVENT_PROPERTY_CHANGE")]
    public const int EVENT_PROPERTY_CHANGE;

    [CCode (cname = "MPV_EVENT_NONE")]
    public const int EVENT_NONE;
    [CCode (cname = "MPV_EVENT_SHUTDOWN")]
    public const int EVENT_SHUTDOWN;
    [CCode (cname = "MPV_EVENT_END_FILE")]
    public const int EVENT_END_FILE;
    [CCode (cname = "MPV_EVENT_FILE_LOADED")]
    public const int EVENT_FILE_LOADED;
    [CCode (cname = "MPV_EVENT_VIDEO_RECONFIG")]
    public const int EVENT_VIDEO_RECONFIG;
    /** Playback resumed after a seek or a frame step, i.e. the position moved. */
    [CCode (cname = "MPV_EVENT_PLAYBACK_RESTART")]
    public const int EVENT_PLAYBACK_RESTART;

    [CCode (cname = "MPV_END_FILE_REASON_ERROR")]
    public const int END_FILE_REASON_ERROR;

    /**
     * mpv found nothing it could decode. Reported when every track is
     * deselected, which includes an "aid" that names a stream the file does
     * not have.
     */
    [CCode (cname = "MPV_ERROR_NOTHING_TO_PLAY")]
    public const int ERROR_NOTHING_TO_PLAY;
}
