/*
 * mpv-render-timing-probe.c — how long does the render call block the caller?
 *
 * MpvBackend renders on the GTK main thread, so whatever the render call waits
 * for is paid there. libmpv's default is to block until the frame's target
 * display time, and the wait is bounded by the frame interval rather than by
 * video-timing-offset, because mpv cannot start the next frame until the
 * previous one is displayed.  Every frame therefore spends its entire
 * inter-frame gap inside the render call — 99% of wall time at every rate
 * measured, i.e. a main loop that does essentially nothing while a preview
 * plays.
 *
 * How bad this is depends on the scheduling around it.  When rendering was
 * driven by a GTK frame-clock tick, a 60 fps source was nearly unaffected,
 * because the tick and the frame rate coincided and the target time had all but
 * arrived by the time the tick caught the frame; only rates below the display
 * rate suffered, which is why the defect survived review.  Now that rendering is
 * driven by mpv's own notification, the render call happens as soon as the frame
 * exists, so the full wait is paid at every rate including 60 fps.
 *
 * MpvBackend fixes this with video-timing-offset=0 (which keeps mpv's
 * audio-relative timing and only removes the lookahead) plus
 * MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME=0 in fcg_mpv_render_sw_draw () (which
 * makes "never block the main thread" an invariant).  --legacy-timing restores
 * both defaults to reproduce the original behaviour.
 *
 * Disabling the render block *without* zeroing the offset is a trap, not a fix:
 * mpv then hands over frames up to a frame interval early and they are
 * presented early.  --legacy-offset reproduces that.  Its timing numbers look
 * exactly like the fix's and mpv's own avsync stays at zero, so the probe
 * measures the presentation lead against mpv's target time directly; dropped
 * frames are a further symptom but an intermittent one, not something to rely
 * on.
 *
 * Only playback is affected.  Paused work — exact seeks and frame stepping — has
 * no target display time to wait for and measures the same either way.
 *
 * This drives the real src/player/mpv-compat.c helpers with MpvBackend's own option set
 * and target-size arithmetic, and mirrors its *current* scheduling: rendering is
 * driven by mpv's render-update callback feeding a coalesced idle on the main
 * loop, not by a GTK frame-clock tick.  That matters for what is being measured
 * — with no frame clock to absorb it, a frame handed over early is presented
 * early — so this must be kept in step with MpvBackend if the scheduling changes
 * again.  Exits non-zero on failure so it can be run over a corpus.
 *
 * Build:
 *   gcc -O1 -o mpv-render-timing-probe DevTools/mpv-render-timing-probe.c \
 *       src/player/mpv-compat.c -Isrc/player $(pkg-config --cflags --libs mpv glib-2.0) -lm
 *
 * Run:  ./mpv-render-timing-probe <file> [options]
 *
 *   --widget=WxH       widget size to size the render target from (default 1600x900)
 *   --hwdec=MODE       hwdec mode (default "no"; the app uses auto-copy-safe)
 *   --secs=N           playback seconds to sample (default 6)
 *   --legacy-timing    mpv's blocking default: reproduces the original defect
 *   --legacy-offset    block disabled but lookahead kept: the trap, not the fix
 *
 * Generate the test corpus (frame rate is what matters, so cover the common
 * cinematic rates and one at the display rate as a control):
 *   for r in 24 30000/1001 60; do \
 *     n=$(echo $r | tr -d '/' ); \
 *     ffmpeg -f lavfi -i testsrc2=s=1920x1080:rate=$r:d=12 \
 *            -f lavfi -i sine=f=440:d=12 \
 *            -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -shortest \
 *            -y timing-$n.mp4; \
 *   done
 *
 * Expected: every clip reports OK and exits 0.  With --legacy-timing every clip
 * reports BLOCKED, and with --legacy-offset every clip reports PRESENTING-EARLY.
 *
 * What this does not measure: the latency between the render call returning and
 * GTK compositing the texture to screen.  That is outside libmpv and unchanged
 * by the fix, but it means "avsync" here is mpv's own estimate rather than
 * end-to-end visual sync.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <locale.h>
#include <math.h>
#include <time.h>

#include <glib.h>

#include "mpv-compat.h"

/* Mirrors MpvBackend's own caps. */
#define MAX_RENDER_WIDTH  1920
#define MAX_RENDER_HEIGHT 1080

/* Baseline is 2-7% across frame rates; the unfixed defect is 92-99%.  Anything
   above this is the main thread being held, not measurement noise. */
#define BLOCKED_FAIL_PERCENT 25.0

/* A correctly timed run drops nothing over a short sample; the trap described
   above drops several per six seconds.  Two absorbs a startup drop and the odd
   one lost to scheduling on a busy machine. */
#define DROP_FAIL_COUNT 2

/* Correctly timed frames are rendered at their target time, so the mean lead
   sits near zero. The trap presents them a whole frame interval early, which is
   16 ms even at 60 fps. */
#define LEAD_FAIL_MS 5.0

#define MAX_SAMPLES 100000

static int imin (int a, int b) { return a < b ? a : b; }
static int imax (int a, int b) { return a > b ? a : b; }

static double
now_sec (void)
{
  struct timespec ts;
  clock_gettime (CLOCK_MONOTONIC, &ts);
  return (double) ts.tv_sec + (double) ts.tv_nsec / 1e9;
}

static void
set_opt (mpv_handle *h, const char *name, const char *value)
{
  int err = mpv_set_option_string (h, name, value);
  if (err < 0)
    fprintf (stderr, "  option %s=%s rejected: %s\n", name, value,
             mpv_error_string (err));
}

static int
cmp_double (const void *a, const void *b)
{
  double x = *(const double *) a, y = *(const double *) b;
  return (x > y) - (x < y);
}

/*
 * fcg_mpv_render_sw_draw () with the block parameter omitted, so libmpv applies
 * its blocking default.  Only used by --legacy-timing; every other path goes
 * through the real helper in src/player/mpv-compat.c.
 */
static int
legacy_render_sw_draw (mpv_render_context *ctx, void *buf,
                       int width, int height, int stride)
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

/* Everything the idles need, standing in for MpvBackend's fields. */
typedef struct {
  mpv_handle         *h;
  mpv_render_context *ctx;
  unsigned char      *buf;
  int                 tw, th, stride;
  int                 legacy_timing;

  /* MpvBackend's coalescing flags, same discipline. */
  gint                render_queued;
  gint                event_queued;

  GMainLoop          *loop;
  double             *samples;
  int                 n;
  double              blocked;
  double              avsync_sum, avsync_max;
  int                 avsync_n;
  double              lead_sum, lead_max;   /* ms early vs mpv's target time */
  int                 lead_n;
  int                 render_failed;
} Probe;

/* ── The scheduling MpvBackend now uses ─────────────────────────────────────
   mpv's callbacks run on mpv's threads and only schedule; the idles do the
   libmpv work on the main thread. */

static gboolean
render_idle (gpointer data)
{
  Probe *p = data;
  g_atomic_int_set (&p->render_queued, 0);

  if (!(mpv_render_context_update (p->ctx) & MPV_RENDER_UPDATE_FRAME))
    return G_SOURCE_REMOVE;

  /* When mpv wanted this frame shown. Compared against the clock *after* the
     render returns, this is the one metric that separates all three modes:
     the fix and the blocking default both land near zero, while disabling the
     block without zeroing the lookahead presents the frame early by up to a
     frame interval. Neither the timing numbers nor mpv's own avsync show that,
     which is why it is measured directly.

     target_time is in NANOSECONDS, against mpv_get_time_ns (). render.h still
     documents it as sharing a base with mpv_get_time_us (); that is stale, and
     believing it puts the reading out by a factor of 1000. It is 0 for a redraw
     rather than a newly timed frame, which is why zero is skipped below. */
  int64_t target_ns = 0;
  mpv_render_frame_info info = { 0 };
  mpv_render_param info_param = { MPV_RENDER_PARAM_NEXT_FRAME_INFO, &info };
  if (mpv_render_context_get_info (p->ctx, info_param) >= 0
      && (info.flags & MPV_RENDER_FRAME_INFO_PRESENT))
    target_ns = info.target_time;

  double t0 = now_sec ();
  int rerr = p->legacy_timing
    ? legacy_render_sw_draw (p->ctx, p->buf, p->tw, p->th, p->stride)
    : fcg_mpv_render_sw_draw (p->ctx, p->buf, p->tw, p->th, p->stride);
  double t1 = now_sec ();

  if (rerr < 0) {
    fprintf (stderr, "render failed: %s\n", mpv_error_string (rerr));
    p->render_failed = 1;
    g_main_loop_quit (p->loop);
    return G_SOURCE_REMOVE;
  }

  if (p->n < MAX_SAMPLES) {
    p->samples[p->n++] = (t1 - t0) * 1000.0;
    p->blocked += t1 - t0;
  }

  if (target_ns > 0) {
    double lead_ms = (double) (target_ns - mpv_get_time_ns (p->h)) / 1e6;
    p->lead_sum += lead_ms;
    p->lead_max = fmax (p->lead_max, lead_ms);
    p->lead_n++;
  }

  /* mpv's own audio/video desync estimate, which is what the render block
     exists to protect.  Sampled per presented frame. */
  double av = 0.0;
  if (mpv_get_property (p->h, "avsync", MPV_FORMAT_DOUBLE, &av) >= 0) {
    p->avsync_sum += fabs (av);
    p->avsync_max = fmax (p->avsync_max, fabs (av));
    p->avsync_n++;
  }
  return G_SOURCE_REMOVE;
}

static void
on_render_update (void *data)
{
  Probe *p = data;
  if (!g_atomic_int_compare_and_exchange (&p->render_queued, 0, 1))
    return;
  g_idle_add_full (G_PRIORITY_HIGH_IDLE, render_idle, p, NULL);
}

static gboolean
event_idle (gpointer data)
{
  Probe *p = data;
  g_atomic_int_set (&p->event_queued, 0);

  for (;;) {
    mpv_event *ev = mpv_wait_event (p->h, 0.0);
    if (!ev || ev->event_id == MPV_EVENT_NONE) break;
    if (ev->event_id == MPV_EVENT_END_FILE)
      g_main_loop_quit (p->loop);
  }
  return G_SOURCE_REMOVE;
}

static void
on_wakeup (void *data)
{
  Probe *p = data;
  if (!g_atomic_int_compare_and_exchange (&p->event_queued, 0, 1))
    return;
  g_idle_add (event_idle, p);
}

static gboolean
stop_sampling (gpointer data)
{
  g_main_loop_quit ((GMainLoop *) data);
  return G_SOURCE_REMOVE;
}

int
main (int argc, char **argv)
{
  if (argc < 2) {
    fprintf (stderr,
             "usage: %s <file> [--widget=WxH] [--hwdec=MODE] [--secs=N] "
             "[--legacy-timing] [--legacy-offset]\n", argv[0]);
    return 2;
  }

  const char *path = argv[1];
  const char *hwdec = "no";
  int widget_w = 1600, widget_h = 900;
  int legacy_timing = 0, legacy_offset = 0;
  double secs = 6.0;

  for (int i = 2; i < argc; i++) {
    if (!strncmp (argv[i], "--widget=", 9))
      sscanf (argv[i] + 9, "%dx%d", &widget_w, &widget_h);
    else if (!strncmp (argv[i], "--hwdec=", 8))      hwdec = argv[i] + 8;
    else if (!strncmp (argv[i], "--secs=", 7))       secs = atof (argv[i] + 7);
    else if (!strcmp (argv[i], "--legacy-timing"))   legacy_timing = 1;
    else if (!strcmp (argv[i], "--legacy-offset"))   legacy_offset = 1;
  }

  /* MpvBackend.ensure_c_numeric_locale (). */
  setlocale (LC_NUMERIC, "C");

  mpv_handle *h = mpv_create ();
  if (!h) { fprintf (stderr, "mpv_create failed\n"); return 1; }

  /* Mirrors MpvBackend.apply_options () for the with_video path. */
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
  set_opt (h, "demuxer-max-bytes", "32MiB");
  set_opt (h, "demuxer-max-back-bytes", "16MiB");
  set_opt (h, "vo", "libmpv");
  set_opt (h, "video-rotate", "no");
  set_opt (h, "profile", "sw-fast");
  /* The fix under test.  Must come after "profile", as MpvBackend's does.
     Both legacy modes want mpv's lookahead back: --legacy-timing pairs it with
     the blocking render (the original defect), --legacy-offset with the
     non-blocking one (the trap). */
  if (!legacy_timing && !legacy_offset)
    set_opt (h, "video-timing-offset", "0");
  set_opt (h, "hwdec", hwdec);
  /* Keep audio decoded, and so video timed against it, without needing a sink
     the probe can rely on being present. */
  set_opt (h, "ao", "null");

  if (mpv_initialize (h) < 0) { fprintf (stderr, "mpv_initialize failed\n"); return 1; }

  int err = 0;
  mpv_render_context *ctx = fcg_mpv_render_sw_create (h, &err);
  if (!ctx) {
    fprintf (stderr, "render context failed: %s\n", mpv_error_string (err));
    return 1;
  }

  const char *load[] = { "loadfile", path, NULL };
  if (mpv_command (h, load) < 0) { fprintf (stderr, "loadfile failed\n"); return 1; }

  /* Open and settle synchronously, before the callback-driven phase starts. */
  int loaded = 0;
  for (int i = 0; i < 1000 && !loaded; i++) {
    mpv_event *ev = mpv_wait_event (h, 0.01);
    if (ev && ev->event_id == MPV_EVENT_FILE_LOADED) loaded = 1;
    if (ev && ev->event_id == MPV_EVENT_END_FILE) {
      fprintf (stderr, "%s: mpv could not open the file\n", path);
      return 1;
    }
  }
  if (!loaded) { fprintf (stderr, "%s: never reached file-loaded\n", path); return 1; }
  for (int i = 0; i < 40; i++)
    mpv_wait_event (h, 0.01);

  int64_t dw = 0, dh = 0;
  mpv_get_property (h, "dwidth",  MPV_FORMAT_INT64, &dw);
  mpv_get_property (h, "dheight", MPV_FORMAT_INT64, &dh);
  if (dw <= 0 || dh <= 0) {
    fprintf (stderr, "%s: no usable video dimensions\n", path);
    return 1;
  }

  double container_fps = 0.0;
  mpv_get_property (h, "container-fps", MPV_FORMAT_DOUBLE, &container_fps);

  /* Confirm the option actually took, rather than trusting that it was
     accepted — mpv validates lazily and a rejected option is easy to miss. */
  double effective_offset = -1.0;
  mpv_get_property (h, "video-timing-offset", MPV_FORMAT_DOUBLE, &effective_offset);

  /* MpvBackend.compute_render_size (). */
  int avail_w = imin (imin (widget_w, MAX_RENDER_WIDTH), (int) dw);
  int avail_h = imin (imin (widget_h, MAX_RENDER_HEIGHT), (int) dh);
  double sf = fmin ((double) avail_w / (double) dw, (double) avail_h / (double) dh);
  int tw = imax (2, (int) lround ((double) dw * sf));
  int th = imax (2, (int) lround ((double) dh * sf));

  /* MpvBackend.ensure_frame_buffer (). */
  int stride = ((tw * 4) + 63) & ~63;

  Probe p = { 0 };
  p.h = h;
  p.ctx = ctx;
  p.tw = tw; p.th = th; p.stride = stride;
  p.legacy_timing = legacy_timing;
  p.buf = calloc (1, (size_t) stride * th);
  p.samples = malloc (sizeof (double) * MAX_SAMPLES);
  p.loop = g_main_loop_new (NULL, FALSE);
  if (!p.buf || !p.samples) { fprintf (stderr, "out of memory\n"); return 1; }

  int64_t drops_before = 0;
  mpv_get_property (h, "frame-drop-count", MPV_FORMAT_INT64, &drops_before);

  mpv_set_wakeup_callback (h, on_wakeup, &p);
  mpv_render_context_set_update_callback (ctx, on_render_update, &p);

  int unpause = 0;
  mpv_set_property (h, "pause", MPV_FORMAT_FLAG, &unpause);

  double start = now_sec ();
  g_timeout_add ((guint) (secs * 1000.0), stop_sampling, p.loop);
  g_main_loop_run (p.loop);
  double wall = now_sec () - start;

  /* Clear the callbacks before anything they reference goes away, exactly as
     MpvBackend.close () does. */
  mpv_render_context_set_update_callback (ctx, NULL, NULL);
  mpv_set_wakeup_callback (h, NULL, NULL);

  int64_t drops_after = 0;
  mpv_get_property (h, "frame-drop-count", MPV_FORMAT_INT64, &drops_after);

  const char *mode = legacy_timing ? "legacy-timing"
                   : legacy_offset ? "legacy-offset" : "fixed";

  printf ("%-22s %-14s fps=%-7.3f target=%dx%-9d offset=%.3f  ",
          path, mode, container_fps, tw, th, effective_offset);

  int ok = 0;
  if (p.n == 0) {
    printf ("no frames rendered\n");
  } else {
    qsort (p.samples, p.n, sizeof (double), cmp_double);
    double sum = 0.0;
    for (int i = 0; i < p.n; i++) sum += p.samples[i];
    double pct = 100.0 * p.blocked / wall;
    int64_t dropped = drops_after - drops_before;

    /* Two distinct failures.  Holding the main thread is the defect this probe
       exists for; dropping frames is what removing the render block without
       zeroing the lookahead does instead, and it would otherwise pass, because
       the trap's timing looks exactly like the fix's. */
    double lead = p.lead_n ? p.lead_sum / p.lead_n : 0.0;

    /* Three distinct failures. Holding the main thread is the defect this probe
       exists for. Presenting early is what removing the render block without
       zeroing the lookahead does instead, and it is invisible in the timing
       numbers and in mpv's avsync, so it needs its own check. Dropped frames
       are a further symptom of the same trap, but an intermittent one. */
    const char *verdict = p.render_failed              ? "RENDER-FAILED"
                        : pct >= BLOCKED_FAIL_PERCENT  ? "BLOCKED"
                        : lead >= LEAD_FAIL_MS         ? "PRESENTING-EARLY"
                        : dropped > DROP_FAIL_COUNT    ? "DROPPING"
                                                       : "OK";
    ok = !strcmp (verdict, "OK");

    printf ("blocked=%.1f%% %s\n", pct, verdict);
    printf ("    renders=%-5d mean=%6.2f ms  p50=%6.2f  p95=%6.2f  max=%6.2f\n",
            p.n, sum / p.n, p.samples[p.n / 2],
            p.samples[(int) (p.n * 0.95)], p.samples[p.n - 1]);
    printf ("    |avsync| mean=%.1f ms  max=%.1f ms   dropped=%lld"
            "   presented early: mean=%.1f ms max=%.1f ms\n",
            p.avsync_n ? 1000.0 * p.avsync_sum / p.avsync_n : 0.0,
            1000.0 * p.avsync_max, (long long) dropped, lead, p.lead_max);
  }

  free (p.buf);
  free (p.samples);
  g_main_loop_unref (p.loop);
  mpv_render_context_free (ctx);
  mpv_terminate_destroy (h);
  return ok ? 0 : 1;
}
