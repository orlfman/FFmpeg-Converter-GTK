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
                               [CCode (array_length = false)] uint8[] buf,
                               int width,
                               int height,
                               int stride);

    [CCode (cname = "MPV_RENDER_UPDATE_FRAME")]
    public const uint64 RENDER_UPDATE_FRAME;

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
    public int next_event (Handle h, out int end_file_reason);

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

    [CCode (cname = "MPV_END_FILE_REASON_ERROR")]
    public const int END_FILE_REASON_ERROR;
}
