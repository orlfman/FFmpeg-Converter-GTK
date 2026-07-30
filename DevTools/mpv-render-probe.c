/*
 * mpv-render-probe.c — verify what libmpv's software renderer actually draws.
 *
 * Drives the real src/mpv-compat.c helpers with MpvBackend's own option set and
 * target-size arithmetic, then measures where the video content landed inside
 * the target buffer.  Two defects live here and neither is visible from the
 * Vala side:
 *
 *   1. libmpv's SW renderer ABORTS the process (SIGABRT, "mp_image_crop:
 *      Assertion `x1 <= img->w && y1 <= img->h' failed" inside
 *      mpv_render_context_render) on any file whose container carries a 90 or
 *      270 degree rotation flag, while mpv's own autorotate filter is active.
 *      180 degrees is unaffected — only the angles that swap width and height.
 *      MpvBackend works around this with video-rotate=no plus an explicit vf
 *      transpose; --legacy-rotate re-enables autorotate to reproduce the abort.
 *
 *   2. Sizing the render target from the coded width/height rather than
 *      dwidth/dheight makes mpv letterbox the frame inside the target, because
 *      mpv renders in display space.  Anamorphic sources lose ~30% of the
 *      target to black bars that are baked into the texture.  --legacy-size
 *      reproduces that.
 *
 * Test clips are solid red, so any black pixel in the output is padding mpv
 * added.  A correct render fills the target exactly; the probe exits non-zero
 * when it does not, so it can be run over a corpus.
 *
 * Build:
 *   gcc -O1 -o mpv-render-probe DevTools/mpv-render-probe.c src/mpv-compat.c \
 *       -Isrc $(pkg-config --cflags --libs mpv glib-2.0) -lm
 *
 * Run:  ./mpv-render-probe <file> [widget_w] [widget_h] [--legacy-size] [--legacy-rotate]
 *
 * Generate the test corpus (solid red so padding is measurable):
 *   ffmpeg -f lavfi -i color=c=red:s=640x360:rate=25:d=1 \
 *          -c:v libx264 -pix_fmt yuv420p -y landscape.mp4
 *   ffmpeg -f lavfi -i color=c=red:s=1080x1920:rate=25:d=1 \
 *          -c:v libx264 -pix_fmt yuv420p -y portrait-native.mp4
 *   ffmpeg -f lavfi -i color=c=red:s=720x576:rate=25:d=1 \
 *          -c:v libx264 -pix_fmt yuv420p -aspect 16:9 -y anamorphic.mp4
 *   for a in 90 180 270; do \
 *     ffmpeg -display_rotation $a -i landscape.mp4 -c copy -y rotated-$a.mp4; \
 *   done
 *
 * Expected: every clip reports FILLS TARGET and exits 0.  With --legacy-rotate
 * the three rotated-*.mp4 abort except 180; with --legacy-size the anamorphic
 * and rotated clips report PADDED.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <locale.h>
#include <math.h>

#include "mpv-compat.h"

/* Mirrors MpvBackend's own caps. */
#define MAX_RENDER_WIDTH  1920
#define MAX_RENDER_HEIGHT 1080

static int imin (int a, int b) { return a < b ? a : b; }
static int imax (int a, int b) { return a > b ? a : b; }

static void
set_opt (mpv_handle *h, const char *name, const char *value)
{
  int err = mpv_set_option_string (h, name, value);
  if (err < 0)
    fprintf (stderr, "  option %s=%s rejected: %s\n", name, value,
             mpv_error_string (err));
}

/*
 * The vf that reproduces what ffmpeg's autorotate does, for a given container
 * rotation angle.  mpv's angle is clockwise; verified against ffmpeg's own
 * decode of clips with a marker in the coded frame's top-left corner.
 * Must stay in sync with MpvBackend.rotation_filter ().
 */
static const char *
rotation_filter (int rotate)
{
  switch (rotate) {
    case 90:  return "transpose=clock";
    case 180: return "transpose=clock,transpose=clock";
    case 270: return "transpose=cclock";
    default:  return NULL;
  }
}

int
main (int argc, char **argv)
{
  if (argc < 2) {
    fprintf (stderr,
             "usage: %s <file> [widget_w] [widget_h] "
             "[--legacy-size] [--legacy-rotate]\n", argv[0]);
    return 2;
  }

  const char *path = argv[1];
  int widget_w = 900, widget_h = 340;
  int legacy_size = 0, legacy_rotate = 0;

  for (int i = 2; i < argc; i++) {
    if (!strcmp (argv[i], "--legacy-size"))        legacy_size = 1;
    else if (!strcmp (argv[i], "--legacy-rotate")) legacy_rotate = 1;
    else if (argv[i][0] != '-') {
      if (widget_w == 900 && i == 2) widget_w = atoi (argv[i]);
      else                           widget_h = atoi (argv[i]);
    }
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
  set_opt (h, "profile", "sw-fast");
  set_opt (h, "hwdec", "no");   /* pinned for determinism */
  if (!legacy_rotate)
    set_opt (h, "video-rotate", "no");

  if (mpv_initialize (h) < 0) { fprintf (stderr, "mpv_initialize failed\n"); return 1; }

  int err = 0;
  mpv_render_context *ctx = fcg_mpv_render_sw_create (h, &err);
  if (!ctx) {
    fprintf (stderr, "render context failed: %s\n", mpv_error_string (err));
    return 1;
  }

  const char *load[] = { "loadfile", path, NULL };
  if (mpv_command (h, load) < 0) { fprintf (stderr, "loadfile failed\n"); return 1; }

  /* Wait for the file to open, then apply rotation the way MpvBackend does. */
  int64_t rotate = 0;
  int loaded = 0;
  for (int i = 0; i < 500 && !loaded; i++) {
    mpv_event *ev = mpv_wait_event (h, 0.01);
    if (ev && ev->event_id == MPV_EVENT_FILE_LOADED) loaded = 1;
    if (ev && ev->event_id == MPV_EVENT_END_FILE) {
      fprintf (stderr, "%s: mpv could not open the file\n", path);
      return 1;
    }
  }
  if (!loaded) { fprintf (stderr, "%s: never reached file-loaded\n", path); return 1; }

  /* "current-tracks/video/demux-rotation" is the only rotation property
     populated this early — video-dec-params/rotate does not exist until the
     first VIDEO_RECONFIG, which is already too late to avoid rendering one
     sideways frame.  It is simply absent (not 0) when there is no rotation. */
  if (mpv_get_property (h, "current-tracks/video/demux-rotation",
                        MPV_FORMAT_INT64, &rotate) < 0)
    rotate = 0;

  if (!legacy_rotate) {
    const char *vf = rotation_filter ((int) rotate);
    if (vf) {
      const char *cmd[] = { "vf", "set", vf, NULL };
      mpv_command (h, cmd);
    }
  }

  /* Wait for a frame that reflects the filter chain above. */
  int have_frame = 0;
  for (int i = 0; i < 500 && !have_frame; i++) {
    mpv_wait_event (h, 0.01);
    if (mpv_render_context_update (ctx) & MPV_RENDER_UPDATE_FRAME)
      have_frame = 1;
  }
  if (!have_frame) { fprintf (stderr, "%s: no frame arrived\n", path); return 1; }

  int64_t cw = 0, ch = 0, dw = 0, dh = 0;
  mpv_get_property (h, "width",   MPV_FORMAT_INT64, &cw);
  mpv_get_property (h, "height",  MPV_FORMAT_INT64, &ch);
  mpv_get_property (h, "dwidth",  MPV_FORMAT_INT64, &dw);
  mpv_get_property (h, "dheight", MPV_FORMAT_INT64, &dh);

  /* MpvBackend.compute_render_size (): from dwidth/dheight, which is the space
     mpv actually draws in.  --legacy-size uses the coded dims to show the
     letterboxing that caused. */
  int64_t base_w = legacy_size ? cw : dw;
  int64_t base_h = legacy_size ? ch : dh;
  if (base_w <= 0 || base_h <= 0) {
    fprintf (stderr, "%s: no usable video dimensions\n", path);
    return 1;
  }

  int avail_w = imin (imin (widget_w, MAX_RENDER_WIDTH), (int) base_w);
  int avail_h = imin (imin (widget_h, MAX_RENDER_HEIGHT), (int) base_h);
  double sf = fmin ((double) avail_w / (double) base_w,
                    (double) avail_h / (double) base_h);
  int tw = imax (2, (int) lround ((double) base_w * sf));
  int th = imax (2, (int) lround ((double) base_h * sf));

  /* MpvBackend.ensure_frame_buffer (). */
  int stride = ((tw * 4) + 63) & ~63;
  unsigned char *buf = calloc (1, (size_t) stride * th);
  if (!buf) { fprintf (stderr, "out of memory\n"); return 1; }

  int rerr = fcg_mpv_render_sw_draw (ctx, buf, tw, th, stride);
  if (rerr < 0) {
    fprintf (stderr, "%s: render failed: %s\n", path, mpv_error_string (rerr));
    return 1;
  }

  /* Bounding box of non-black pixels.  Clips are solid colour, so anything
     black is padding mpv added. */
  int minx = tw, miny = th, maxx = -1, maxy = -1;
  for (int y = 0; y < th; y++) {
    const unsigned char *row = buf + (size_t) y * stride;
    for (int x = 0; x < tw; x++) {
      if (row[x * 4 + 0] > 24 || row[x * 4 + 1] > 24 || row[x * 4 + 2] > 24) {
        if (x < minx) minx = x;
        if (x > maxx) maxx = x;
        if (y < miny) miny = y;
        if (y > maxy) maxy = y;
      }
    }
  }

  printf ("%-22s coded=%lldx%-9lld display=%lldx%-9lld rotate=%-4lld target=%dx%d  ",
          path, (long long) cw, (long long) ch, (long long) dw, (long long) dh,
          (long long) rotate, tw, th);

  int ok = 0;
  if (maxx < 0) {
    printf ("content=NONE (all black)\n");
  } else {
    int bw = maxx - minx + 1, bh = maxy - miny + 1;
    ok = (bw == tw && bh == th);
    printf ("content=%dx%d at (%d,%d) fill=%.1f%% %s\n",
            bw, bh, minx, miny,
            100.0 * (double) (bw * bh) / (double) (tw * th),
            ok ? "FILLS TARGET" : "PADDED");
  }

  free (buf);
  mpv_render_context_free (ctx);
  mpv_terminate_destroy (h);
  return ok ? 0 : 1;
}
