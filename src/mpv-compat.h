/*
 * mpv-compat.h — thin C helpers over libmpv.
 *
 * libmpv's render API takes NULL-terminated arrays of tagged unions
 * (mpv_render_param), and its property API is void*-based.  Both marshal
 * badly from Vala, so the awkward parts live here and the VAPI binds these
 * helpers instead.  Nothing here holds state; the mpv handle is owned by
 * MpvBackend on the Vala side.
 */

#pragma once

#include <stddef.h>
#include <stdint.h>

#include <mpv/client.h>
#include <mpv/render.h>

/*
 * Create a software render context for an initialized mpv handle.
 * Returns NULL on failure; *error_out receives the mpv error code.
 */
mpv_render_context *fcg_mpv_render_sw_create (mpv_handle *mpv, int *error_out);

/*
 * Render the current frame into a caller-owned BGRX buffer.  The buffer must
 * hold at least (stride * height) bytes.  Returns an mpv error code (0 = ok).
 */
int fcg_mpv_render_sw_draw (mpv_render_context *ctx,
                            void *buf,
                            int width,
                            int height,
                            int stride);

/* Run a command of up to three arguments.  Pass NULL for unused trailing
 * arguments; the terminator is added here. */
int fcg_mpv_cmd (mpv_handle *h, const char *a1, const char *a2, const char *a3);

/* Typed property access.  Each returns an mpv error code (0 = ok) and only
 * writes through the out pointer on success. */
int fcg_mpv_get_double (mpv_handle *h, const char *name, double *out_value);
int fcg_mpv_get_int64  (mpv_handle *h, const char *name, int64_t *out_value);
int fcg_mpv_get_flag   (mpv_handle *h, const char *name, int *out_value);
int fcg_mpv_set_double (mpv_handle *h, const char *name, double value);
int fcg_mpv_set_flag   (mpv_handle *h, const char *name, int value);

/*
 * Read a string property.  mpv hands back memory that must be released with
 * mpv_free (), so the value is copied onto the GLib allocator here and the
 * caller frees it normally.  Returns NULL if the property is unavailable.
 */
char *fcg_mpv_get_property_string (mpv_handle *h, const char *name);

/*
 * Pop one queued event without blocking.  Returns the mpv_event_id, or
 * MPV_EVENT_NONE when the queue is empty.  For MPV_EVENT_END_FILE,
 * *out_end_file_reason receives the mpv_end_file_reason; otherwise it is set
 * to -1.  The event struct itself never escapes this call, so the caller does
 * not have to reason about its lifetime.
 */
int fcg_mpv_next_event (mpv_handle *h, int *out_end_file_reason);
