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

#include <glib.h>

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

/*
 * Allocate a 64-byte-aligned frame buffer of @stride * @height bytes, or NULL.
 * libmpv's software renderer wants that alignment on both the pointer and the
 * stride; the GLib allocator does not promise it.
 *
 * @row_bytes is the visible part of each row (width * bytes-per-pixel). The
 * pixels are left uninitialised because mpv overwrites them; only the
 * stride - row_bytes padding is cleared, so no uninitialised heap is handed on.
 */
void *fcg_frame_buffer_alloc (int stride, int height, int row_bytes);

/* Release a buffer that was never handed to fcg_frame_buffer_to_bytes (). */
void fcg_frame_buffer_free (void *buf);

/*
 * Wrap a buffer from fcg_frame_buffer_alloc () in a GBytes, transferring
 * ownership. No copy is made and the caller must not touch the buffer again:
 * the GBytes releases it, with the deallocator that matches the allocation.
 */
GBytes *fcg_frame_buffer_to_bytes (void *buf, size_t size);

/*
 * Run a command of up to three arguments.  Pass NULL for unused trailing
 * arguments; the terminator is added here.  The list ends at the first NULL, so
 * a NULL followed by a non-NULL argument is a caller error and returns
 * MPV_ERROR_INVALID_PARAMETER rather than quietly running a shorter command.
 */
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
 * *out_end_file_reason receives the mpv_end_file_reason and
 * *out_end_file_error receives mpv_event_end_file.error; otherwise they are
 * set to -1 and 0 respectively.  The event struct itself never escapes this
 * call, so the caller does not have to reason about its lifetime.
 *
 * For MPV_EVENT_LOG_MESSAGE, *out_log_prefix and *out_log_text receive newly
 * allocated copies the caller owns; otherwise they are set to NULL.  Copies
 * rather than borrows because mpv's strings die at the next mpv_wait_event ().
 */
int fcg_mpv_next_event (mpv_handle *h,
                        int *out_end_file_reason,
                        int *out_end_file_error,
                        char **out_log_prefix,
                        char **out_log_text);
