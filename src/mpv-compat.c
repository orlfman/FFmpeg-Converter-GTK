#include "mpv-compat.h"

#include <stdlib.h>
#include <string.h>

#include <glib.h>

mpv_render_context *
fcg_mpv_render_sw_create (mpv_handle *mpv, int *error_out)
{
  mpv_render_context *ctx = NULL;
  char api_type[] = MPV_RENDER_API_TYPE_SW;

  mpv_render_param params[] = {
    { MPV_RENDER_PARAM_API_TYPE, api_type },
    { MPV_RENDER_PARAM_INVALID, NULL }
  };

  int err = mpv_render_context_create (&ctx, mpv, params);

  if (error_out)
    *error_out = err;

  if (err < 0)
    return NULL;

  /* No update callback is installed here. MpvBackend installs its own straight
     after this returns, and clears it again before teardown. */
  return ctx;
}

int
fcg_mpv_render_sw_draw (mpv_render_context *ctx,
                        void *buf,
                        int width,
                        int height,
                        int stride)
{
  int size[2] = { width, height };
  size_t line_bytes = (size_t) stride;
  char format[] = "bgr0";

  /*
   * This is called on the GTK main thread, so it must never wait. libmpv's
   * default is to block until the frame's target display time, and that wait is
   * bounded by the frame interval rather than by video-timing-offset -- 99% of
   * wall time at every frame rate measured, i.e. a main loop that does
   * essentially nothing while a preview plays.
   *
   * MpvBackend pairs this with video-timing-offset=0, which is what actually
   * keeps audio-relative timing correct; disabling the block on its own makes
   * mpv hand over frames up to 50 ms early and then drop the mistimed ones.
   * This parameter is the belt to that option's braces: it guarantees the main
   * thread cannot block here even if the option is overridden or its default
   * changes.
   */
  int block_for_target_time = 0;

  mpv_render_param params[] = {
    { MPV_RENDER_PARAM_SW_SIZE,    size        },
    { MPV_RENDER_PARAM_SW_FORMAT,  format      },
    { MPV_RENDER_PARAM_SW_STRIDE,  &line_bytes },
    { MPV_RENDER_PARAM_SW_POINTER, buf         },
    { MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block_for_target_time },
    { MPV_RENDER_PARAM_INVALID,    NULL        }
  };

  return mpv_render_context_render (ctx, params);
}

void *
fcg_frame_buffer_alloc (int stride, int height, int row_bytes)
{
  if (stride <= 0 || height <= 0 || row_bytes <= 0 || row_bytes > stride)
    return NULL;

  /*
   * libmpv wants both the stride and the pointer aligned to 64 bytes for the
   * software renderer; below that it may take a slower path or copy the whole
   * frame internally (render.h, MPV_RENDER_PARAM_SW_STRIDE). GLib's allocator
   * only promises 8, and glibc happens to give 16.
   *
   * aligned_alloc requires the size to be a multiple of the alignment, which
   * stride * height need not be, so it is rounded up here.
   */
  size_t size = (size_t) stride * (size_t) height;
  size_t padded = (size + 63u) & ~(size_t) 63u;

  unsigned char *buf = aligned_alloc (64, padded);
  if (buf == NULL)
    return NULL;

  /*
   * The pixels are deliberately left uninitialised: mpv writes every byte of
   * the visible area, verified by rendering the same frame into two
   * differently-poisoned buffers and diffing them, so clearing first would cost
   * a full-buffer write per frame -- the exact cost this allocation exists to
   * avoid.
   *
   * The alignment padding at the end of each row is the one part mpv does not
   * touch. GdkMemoryTexture does not read it either, but it is cleared anyway
   * rather than handing uninitialised heap to GTK and on to a graphics driver.
   * At 1080x1920 that is 61 KiB against a 7.9 MiB frame, so it costs under 1%
   * of what a full clear would.
   */
  size_t tail = (size_t) (stride - row_bytes);
  if (tail > 0) {
    for (int y = 0; y < height; y++)
      memset (buf + (size_t) y * (size_t) stride + (size_t) row_bytes, 0, tail);
  }
  /* Round-up slack past the last row, for the same reason. */
  if (padded > size)
    memset (buf + size, 0, padded - size);

  return buf;
}

static void
fcg_frame_buffer_release (gpointer buf)
{
  /* Matches aligned_alloc: C11 requires free () to accept its result. */
  free (buf);
}

void
fcg_frame_buffer_free (void *buf)
{
  fcg_frame_buffer_release (buf);
}

GBytes *
fcg_frame_buffer_to_bytes (void *buf, size_t size)
{
  /*
   * Hands the buffer to GLib rather than copying it. GdkMemoryTexture keeps a
   * reference to the GBytes and reads through it for as long as GTK needs the
   * frame, so ownership has to transfer: the caller must not touch buf again.
   * The free func is what makes that safe with an aligned_alloc block, which
   * g_free would not necessarily be able to release on every platform.
   */
  return g_bytes_new_with_free_func (buf, size, fcg_frame_buffer_release, buf);
}

int
fcg_mpv_cmd (mpv_handle *h, const char *a1, const char *a2, const char *a3)
{
  /*
   * Trailing-null contract: the argument list ends at the first NULL.
   *
   * This used to collapse the non-NULL arguments instead, which silently
   * promoted a later argument into an earlier slot -- ("vf", NULL, "set")
   * became the two-argument command ("vf", "set"). That is not a malformed
   * command mpv would reject, it is a different well-formed one, so the
   * mistake would run and produce a wrong result rather than an error. Reject
   * it here instead, where the caller's bug is still visible.
   */
  if (a1 == NULL)
    return MPV_ERROR_INVALID_PARAMETER;
  if (a2 == NULL && a3 != NULL)
    return MPV_ERROR_INVALID_PARAMETER;

  const char *args[4] = { a1, a2, a3, NULL };

  return mpv_command (h, args);
}

int
fcg_mpv_get_double (mpv_handle *h, const char *name, double *out_value)
{
  double value = 0.0;
  int err = mpv_get_property (h, name, MPV_FORMAT_DOUBLE, &value);

  if (err >= 0 && out_value)
    *out_value = value;

  return err;
}

int
fcg_mpv_get_int64 (mpv_handle *h, const char *name, int64_t *out_value)
{
  int64_t value = 0;
  int err = mpv_get_property (h, name, MPV_FORMAT_INT64, &value);

  if (err >= 0 && out_value)
    *out_value = value;

  return err;
}

int
fcg_mpv_get_flag (mpv_handle *h, const char *name, int *out_value)
{
  int value = 0;
  int err = mpv_get_property (h, name, MPV_FORMAT_FLAG, &value);

  if (err >= 0 && out_value)
    *out_value = value;

  return err;
}

int
fcg_mpv_set_double (mpv_handle *h, const char *name, double value)
{
  return mpv_set_property (h, name, MPV_FORMAT_DOUBLE, &value);
}

int
fcg_mpv_set_flag (mpv_handle *h, const char *name, int value)
{
  return mpv_set_property (h, name, MPV_FORMAT_FLAG, &value);
}

char *
fcg_mpv_get_property_string (mpv_handle *h, const char *name)
{
  char *value = mpv_get_property_string (h, name);
  if (value == NULL)
    return NULL;

  /* Hand back GLib-allocated memory so the caller can free it the usual way. */
  char *copy = g_strdup (value);
  mpv_free (value);
  return copy;
}

int
fcg_mpv_next_event (mpv_handle *h,
                    int *out_end_file_reason,
                    int *out_end_file_error,
                    char **out_log_prefix,
                    char **out_log_text)
{
  if (out_end_file_reason)
    *out_end_file_reason = -1;
  if (out_end_file_error)
    *out_end_file_error = 0;
  if (out_log_prefix)
    *out_log_prefix = NULL;
  if (out_log_text)
    *out_log_text = NULL;

  /* Timeout 0: return immediately with MPV_EVENT_NONE if nothing is queued. */
  mpv_event *event = mpv_wait_event (h, 0.0);
  if (event == NULL)
    return MPV_EVENT_NONE;

  if (event->event_id == MPV_EVENT_END_FILE) {
    mpv_event_end_file *end_file = (mpv_event_end_file *) event->data;
    if (end_file) {
      if (out_end_file_reason)
        *out_end_file_reason = (int) end_file->reason;
      if (out_end_file_error)
        *out_end_file_error = end_file->error;
    }
  }

  /* The event's strings belong to mpv and are only valid until the next
     mpv_wait_event () on this handle, so hand back copies the caller owns. */
  if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
    mpv_event_log_message *msg = (mpv_event_log_message *) event->data;
    if (msg) {
      if (out_log_prefix)
        *out_log_prefix = g_strdup (msg->prefix ? msg->prefix : "");
      if (out_log_text)
        *out_log_text = g_strdup (msg->text ? msg->text : "");
    }
  }

  return (int) event->event_id;
}
