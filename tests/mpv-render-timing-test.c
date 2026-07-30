/*
 * mpv-render-timing-test.c — the render call must never block the main thread.
 *
 * MpvBackend renders on the GTK main thread. libmpv's default is to block
 * inside mpv_render_context_render () until the frame's target display time,
 * and that wait is the whole inter-frame interval, so leaving it enabled costs
 * ~99% of wall time at every frame rate: a main loop that does essentially
 * nothing while a preview plays.
 *
 * Two independent things keep that from happening, and this asserts both:
 *
 *   1. fcg_mpv_render_sw_draw () passes MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME
 *      = 0. Checked by playing with mpv's *default* lookahead deliberately left
 *      in place: if the parameter is dropped, every render blocks for a frame
 *      interval and the blocked share goes through the roof.
 *
 *   2. MpvBackend sets video-timing-offset=0, which is what keeps audio-relative
 *      timing correct. Checked by playing with the shipped option set and
 *      asserting frames are not handed over early. Disabling the block without
 *      zeroing the lookahead is a trap that looks identical in the timing
 *      numbers and in mpv's own avsync, so this is measured against mpv's
 *      target time directly.
 *
 * Headless: the software render API needs no display, so unlike the widget
 * tests this runs anywhere. It does need libmpv and an ffmpeg to build the
 * fixture, and reports an explicit skip when ffmpeg is missing.
 *
 * DevTools/mpv-render-timing-probe.c is the exploratory version of this, with
 * percentiles, legacy comparison modes and tunable render targets.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <locale.h>
#include <math.h>
#include <time.h>

#include <glib.h>
#include <glib/gstdio.h>

#include "mpv-compat.h"

/* The fixed path measures 4-6%; the defect measures ~99%. A threshold this
   wide cannot be tripped by a loaded machine, only by the parameter going
   missing. */
#define BLOCKED_FAIL_PERCENT 40.0

/* Correctly timed frames land at or just after their target time. The trap
   hands them over a whole frame interval early — 41 ms on the fixture below. */
#define LEAD_FAIL_MS 10.0

/* Tests are opt-in (`make test`), so this samples generously rather than
   trading accuracy for suite runtime. */
#define MIN_RENDERS 60
#define SAMPLE_SECONDS 4.0

/* 1920x1080 is MAX_RENDER_WIDTH/HEIGHT in MpvBackend, so a fixture at that size
   is rendered at the cap — the largest buffer and slowest render the app can
   ask for, which is the case a threshold most needs to survive. */
#define FIXTURE_SIZE "1920x1080"

typedef struct {
  mpv_handle         *h;
  mpv_render_context *ctx;
  unsigned char      *buf;
  int                 tw, th, stride;
  gint                render_queued;
  gint                event_queued;
  GMainLoop          *loop;

  int                 renders;
  double              blocked;
  double              lead_sum;
  int                 lead_n;
  int                 render_error;
} Fixture;

static double
now_sec (void)
{
  struct timespec ts;
  clock_gettime (CLOCK_MONOTONIC, &ts);
  return (double) ts.tv_sec + (double) ts.tv_nsec / 1e9;
}

/*
 * Mirrors MpvBackend's scheduling: mpv's callbacks run on mpv's threads and
 * only schedule, and the idle does the libmpv work. Worth keeping faithful —
 * how soon the render call happens after the frame exists is exactly what
 * decides how long the block lasts.
 */
static gboolean
render_idle (gpointer data)
{
  Fixture *f = data;
  g_atomic_int_set (&f->render_queued, 0);

  if (!(mpv_render_context_update (f->ctx) & MPV_RENDER_UPDATE_FRAME))
    return G_SOURCE_REMOVE;

  /* target_time is in nanoseconds against mpv_get_time_ns (); render.h still
     documents it as sharing a base with mpv_get_time_us (), which is stale. */
  int64_t target_ns = 0;
  mpv_render_frame_info info = { 0 };
  mpv_render_param info_param = { MPV_RENDER_PARAM_NEXT_FRAME_INFO, &info };
  if (mpv_render_context_get_info (f->ctx, info_param) >= 0
      && (info.flags & MPV_RENDER_FRAME_INFO_PRESENT))
    target_ns = info.target_time;

  double t0 = now_sec ();
  int err = fcg_mpv_render_sw_draw (f->ctx, f->buf, f->tw, f->th, f->stride);
  double t1 = now_sec ();

  if (err < 0) {
    f->render_error = err;
    g_main_loop_quit (f->loop);
    return G_SOURCE_REMOVE;
  }

  f->renders++;
  f->blocked += t1 - t0;

  if (target_ns > 0) {
    f->lead_sum += (double) (target_ns - mpv_get_time_ns (f->h)) / 1e6;
    f->lead_n++;
  }
  return G_SOURCE_REMOVE;
}

static void
on_render_update (void *data)
{
  Fixture *f = data;
  if (g_atomic_int_compare_and_exchange (&f->render_queued, 0, 1))
    g_idle_add_full (G_PRIORITY_HIGH_IDLE, render_idle, f, NULL);
}

static gboolean
event_idle (gpointer data)
{
  Fixture *f = data;
  g_atomic_int_set (&f->event_queued, 0);
  for (;;) {
    mpv_event *ev = mpv_wait_event (f->h, 0.0);
    if (!ev || ev->event_id == MPV_EVENT_NONE) break;
    if (ev->event_id == MPV_EVENT_END_FILE)
      g_main_loop_quit (f->loop);
  }
  return G_SOURCE_REMOVE;
}

static void
on_wakeup (void *data)
{
  Fixture *f = data;
  if (g_atomic_int_compare_and_exchange (&f->event_queued, 0, 1))
    g_idle_add (event_idle, f);
}

static gboolean
stop_sampling (gpointer loop)
{
  g_main_loop_quit ((GMainLoop *) loop);
  return G_SOURCE_REMOVE;
}

static void
set_opt (mpv_handle *h, const char *name, const char *value)
{
  int err = mpv_set_option_string (h, name, value);
  g_assert_cmpint (err, >=, 0);
}

/* Clip at @rate with audio, so video is timed against audio exactly as it is
   for a real preview. Returns NULL when ffmpeg is unavailable. */
static char *
make_fixture (const char *dir, const char *rate, const char *name)
{
  char *path = g_build_filename (dir, name, NULL);
  char *video_in = g_strdup_printf ("testsrc2=s=%s:rate=%s:d=8",
                                    FIXTURE_SIZE, rate);
  char *argv[] = {
    "ffmpeg", "-v", "error", "-y",
    "-f", "lavfi", "-i", video_in,
    "-f", "lavfi", "-i", "sine=f=440:d=8",
    "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
    "-c:a", "aac", "-shortest", path, NULL
  };

  int status = 0;
  GError *error = NULL;
  gboolean ok = g_spawn_sync (NULL, argv, NULL,
                              G_SPAWN_SEARCH_PATH
                              | G_SPAWN_STDOUT_TO_DEV_NULL
                              | G_SPAWN_STDERR_TO_DEV_NULL,
                              NULL, NULL, NULL, NULL, &status, &error);
  g_free (video_in);

  if (!ok || status != 0 || !g_file_test (path, G_FILE_TEST_EXISTS)) {
    g_clear_error (&error);
    g_free (path);
    return NULL;
  }
  return path;
}

/*
 * @timing_offset: NULL to leave mpv's default lookahead in place, "0" for the
 *                 shipped option set.
 */
static void
run_playback (const char *path, const char *timing_offset, Fixture *f)
{
  mpv_handle *h = mpv_create ();
  g_assert_nonnull (h);

  /* MpvBackend.apply_options (), with_video path. */
  set_opt (h, "config", "no");
  set_opt (h, "load-scripts", "no");
  set_opt (h, "osc", "no");
  set_opt (h, "terminal", "no");
  set_opt (h, "input-default-bindings", "no");
  set_opt (h, "input-vo-keyboard", "no");
  set_opt (h, "ytdl", "no");
  set_opt (h, "audio-file-auto", "no");
  set_opt (h, "sub-auto", "no");
  set_opt (h, "sid", "no");
  set_opt (h, "idle", "yes");
  set_opt (h, "keep-open", "yes");
  set_opt (h, "pause", "yes");
  set_opt (h, "vo", "libmpv");
  set_opt (h, "video-rotate", "no");
  set_opt (h, "profile", "sw-fast");
  if (timing_offset)
    set_opt (h, "video-timing-offset", timing_offset);
  /* Pinned for determinism; the app's default depends on a preference. */
  set_opt (h, "hwdec", "no");
  set_opt (h, "ao", "null");

  g_assert_cmpint (mpv_initialize (h), >=, 0);

  int err = 0;
  mpv_render_context *ctx = fcg_mpv_render_sw_create (h, &err);
  g_assert_nonnull (ctx);

  const char *load[] = { "loadfile", path, NULL };
  g_assert_cmpint (mpv_command (h, load), >=, 0);

  gboolean loaded = FALSE;
  for (int i = 0; i < 1000 && !loaded; i++) {
    mpv_event *ev = mpv_wait_event (h, 0.01);
    if (ev && ev->event_id == MPV_EVENT_FILE_LOADED) loaded = TRUE;
    if (ev && ev->event_id == MPV_EVENT_END_FILE) break;
  }
  g_assert_true (loaded);
  for (int i = 0; i < 40; i++)
    mpv_wait_event (h, 0.01);

  int64_t dw = 0, dh = 0;
  mpv_get_property (h, "dwidth", MPV_FORMAT_INT64, &dw);
  mpv_get_property (h, "dheight", MPV_FORMAT_INT64, &dh);
  g_assert_cmpint (dw, >, 0);
  g_assert_cmpint (dh, >, 0);

  f->h = h;
  f->ctx = ctx;
  f->tw = (int) dw;
  f->th = (int) dh;
  f->stride = ((f->tw * 4) + 63) & ~63;
  f->buf = g_malloc0 ((size_t) f->stride * f->th);
  f->loop = g_main_loop_new (NULL, FALSE);

  mpv_set_wakeup_callback (h, on_wakeup, f);
  mpv_render_context_set_update_callback (ctx, on_render_update, f);

  int unpause = 0;
  mpv_set_property (h, "pause", MPV_FORMAT_FLAG, &unpause);

  double start = now_sec ();
  g_timeout_add ((guint) (SAMPLE_SECONDS * 1000.0), stop_sampling, f->loop);
  g_main_loop_run (f->loop);
  double wall = now_sec () - start;

  /* As MpvBackend.close () does: clear before releasing. */
  mpv_render_context_set_update_callback (ctx, NULL, NULL);
  mpv_set_wakeup_callback (h, NULL, NULL);

  g_assert_cmpint (f->render_error, ==, 0);
  g_assert_cmpint (f->renders, >=, MIN_RENDERS);

  f->blocked = 100.0 * f->blocked / wall;   /* reuse as a percentage */

  g_main_loop_unref (f->loop);
  g_free (f->buf);
  mpv_render_context_free (ctx);
  mpv_terminate_destroy (h);
}

/*
 * The render helper must not block even when mpv is preparing frames ahead.
 * This is the assertion that fails if MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME
 * is dropped from fcg_mpv_render_sw_draw ().
 */
static void
test_render_does_not_block_with_default_lookahead (const void *fixture_path)
{
  const char *path = fixture_path;
  if (path == NULL) {
    g_test_skip ("ffmpeg unavailable, cannot build a fixture");
    return;
  }

  Fixture f = { 0 };
  run_playback (path, NULL, &f);

  g_test_message ("blocked %.1f%% of wall time over %d renders",
                  f.blocked, f.renders);
  g_assert_cmpfloat (f.blocked, <, BLOCKED_FAIL_PERCENT);
}

/*
 * With the shipped option set, frames must not be presented ahead of the time
 * mpv scheduled them for. This is the assertion that fails if
 * video-timing-offset=0 is dropped from MpvBackend.apply_options () — the case
 * that neither the timing numbers nor mpv's avsync would reveal.
 */
static void
test_frames_are_not_presented_early (const void *fixture_path)
{
  const char *path = fixture_path;
  if (path == NULL) {
    g_test_skip ("ffmpeg unavailable, cannot build a fixture");
    return;
  }

  Fixture f = { 0 };
  run_playback (path, "0", &f);

  g_assert_cmpint (f.lead_n, >, 0);
  double lead = f.lead_sum / f.lead_n;

  g_test_message ("presented %.1f ms before target on average over %d frames",
                  lead, f.lead_n);
  g_assert_cmpfloat (lead, <, LEAD_FAIL_MS);
  g_assert_cmpfloat (f.blocked, <, BLOCKED_FAIL_PERCENT);
}

/*
 * Frame rates worth covering separately.
 *
 * 23.976 and 29.97 are what most real footage carries, and the block costs a
 * whole frame interval there. 60 is the interesting one: under the GTK
 * frame-clock tick this backend used to render from, a 60 fps source was almost
 * unaffected because the tick and the frame rate coincided, and that is why the
 * defect went unnoticed for as long as it did. It is only covered now because
 * rendering moved to mpv's notification. Keeping it in the matrix means a
 * future scheduling change that reintroduces the asymmetry shows up as one rate
 * failing rather than as a silent gap.
 */
static const struct { const char *rate; const char *file; const char *label; } RATES[] = {
  { "24000/1001", "timing-23976.mkv", "23.976fps" },
  { "30000/1001", "timing-2997.mkv",  "29.97fps"  },
  { "60",         "timing-60.mkv",    "60fps"     },
};

int
main (int argc, char **argv)
{
  /* MpvBackend.ensure_c_numeric_locale (): mpv_create () refuses to run unless
     LC_NUMERIC is "C". */
  setlocale (LC_NUMERIC, "C");

  g_test_init (&argc, &argv, NULL);

  char *dir = g_dir_make_tmp ("mpv-render-timing-XXXXXX", NULL);
  g_assert_nonnull (dir);

  char *paths[G_N_ELEMENTS (RATES)] = { NULL };
  char *names[G_N_ELEMENTS (RATES) * 2] = { NULL };

  for (guint i = 0; i < G_N_ELEMENTS (RATES); i++) {
    paths[i] = make_fixture (dir, RATES[i].rate, RATES[i].file);

    names[i * 2] = g_strdup_printf (
      "/mpv-render/%s/does-not-block-with-default-lookahead", RATES[i].label);
    names[i * 2 + 1] = g_strdup_printf (
      "/mpv-render/%s/frames-are-not-presented-early", RATES[i].label);

    g_test_add_data_func (names[i * 2], paths[i],
                          test_render_does_not_block_with_default_lookahead);
    g_test_add_data_func (names[i * 2 + 1], paths[i],
                          test_frames_are_not_presented_early);
  }

  int result = g_test_run ();

  for (guint i = 0; i < G_N_ELEMENTS (RATES); i++) {
    if (paths[i]) {
      g_unlink (paths[i]);
      g_free (paths[i]);
    }
    g_free (names[i * 2]);
    g_free (names[i * 2 + 1]);
  }
  g_rmdir (dir);
  g_free (dir);
  return result;
}
