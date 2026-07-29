#include "mpv-compat.h"

#include <stdlib.h>
#include <glib.h>

/*
 * mpv notifies "a new frame is ready" through this callback, which runs on
 * mpv's own render thread.  We do not use it: MpvBackend polls
 * mpv_render_context_update() from the GTK frame clock instead, which keeps
 * every mpv call on the main thread and removes the whole class of
 * cross-thread lifetime bugs.  The callback is still installed because mpv
 * expects a notification sink to exist; it deliberately touches no state, so
 * it stays safe no matter when it fires relative to teardown.
 */
static void
fcg_mpv_noop_update (void *ctx)
{
  (void) ctx;
}

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

  mpv_render_context_set_update_callback (ctx, fcg_mpv_noop_update, NULL);
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

  mpv_render_param params[] = {
    { MPV_RENDER_PARAM_SW_SIZE,    size        },
    { MPV_RENDER_PARAM_SW_FORMAT,  format      },
    { MPV_RENDER_PARAM_SW_STRIDE,  &line_bytes },
    { MPV_RENDER_PARAM_SW_POINTER, buf         },
    { MPV_RENDER_PARAM_INVALID,    NULL        }
  };

  return mpv_render_context_render (ctx, params);
}

int
fcg_mpv_cmd (mpv_handle *h, const char *a1, const char *a2, const char *a3)
{
  /* Collapse the arguments so a NULL in the middle still terminates cleanly. */
  const char *args[4];
  int n = 0;
  if (a1) args[n++] = a1;
  if (a2) args[n++] = a2;
  if (a3) args[n++] = a3;
  args[n] = NULL;

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
fcg_mpv_next_event (mpv_handle *h, int *out_end_file_reason)
{
  if (out_end_file_reason)
    *out_end_file_reason = -1;

  /* Timeout 0: return immediately with MPV_EVENT_NONE if nothing is queued. */
  mpv_event *event = mpv_wait_event (h, 0.0);
  if (event == NULL)
    return MPV_EVENT_NONE;

  if (event->event_id == MPV_EVENT_END_FILE && out_end_file_reason) {
    mpv_event_end_file *end_file = (mpv_event_end_file *) event->data;
    if (end_file)
      *out_end_file_reason = (int) end_file->reason;
  }

  return (int) event->event_id;
}
