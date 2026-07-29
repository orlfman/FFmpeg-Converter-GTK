# Upstream report: playbin3 buffers entire AV1-in-Matroska files into memory

> Draft for filing at https://gitlab.freedesktop.org/gstreamer/gstreamer/-/issues
>
> Suggested title: **playbin3 retains the entire file in memory for AV1 in
> Matroska (not MP4, not playbin2, not HEVC)**

## Summary

When playing **AV1 in a Matroska/WebM container** with `playbin3`, resident
memory grows continuously until the whole file has been read into memory. It
never plateaus below that point.

The growth requires all of:

- **AV1** — the identical Matroska container with HEVC does not grow
- **Matroska** — the identical AV1 elementary stream remuxed to MP4 does not grow
- **playbin3** — `playbin` (playbin2) on the same file does not grow

A 2-hour 8.5 GB AV1 Blu-ray remux climbs at ~28 MiB/s of wall clock and is still
climbing, linearly, 90 seconds in. In a GTK4 application this drove the process
to 36 GiB RSS on a 9.5 GB input.

This reaches every GTK4 application through `Gtk.MediaFile`, which is built on
`GstPlay` and therefore playbin3. Simply constructing a `Gtk.MediaFile` — without
attaching it to a widget and without starting playback — is enough.

## Environment

```text
GStreamer   1.28.5
GTK         4.22.4
glibc       2.44
OS          CachyOS (Arch-based), kernel 7.1.5
CPU         24 logical cores
```

## Minimal reproduction

Generate a test file and a control, entirely synthetically:

```sh
ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=24 -t 300 \
       -c:v libsvtav1 -preset 10 -crf 28 -pix_fmt yuv420p10le av1.mkv
ffmpeg -i av1.mkv -c copy av1.mp4
```

Play each and sample `VmRSS` from `/proc/<pid>/status`. `fakesink sync=true` is
used so the sinks apply normal real-time back-pressure; behaviour is identical
with real sinks.

```sh
gst-launch-1.0 -q playbin3 uri=file://$PWD/av1.mkv \
  video-sink="fakesink sync=true" audio-sink="fakesink sync=true"
```

### Result — same AV1 stream, 317 MB file

| pipeline | container | peak RSS |
|---|---|---:|
| playbin3 | Matroska | **459.79 MiB** |
| playbin3 | MP4 | 102.67 MiB |
| playbin2 | Matroska | 146.27 MiB |

The excess over baseline is ~357 MiB for a 317 MB file — i.e. the entire file
is resident.

## Scaling

The effect is proportional to how much of the file has been read, so it is only
conspicuous on large files. Using stream-copied clips of one source (identical
codec, resolution and bitrate; only length differs):

| clip length | playbin3 + Matroska | playbin3 + MP4 |
|---:|---:|---:|
| 30 s | 316 MiB | 144 MiB |
| 120 s | 860 MiB | 144 MiB |
| 600 s | **3471 MiB** | 111 MiB |

MP4 is flat across a 20× change in duration. Matroska fits a straight line:

```text
peak RSS ≈ 136 MiB + 6.03 MiB per second of content

   30 s → predicted  317 MiB, measured  316 MiB
  120 s → predicted  860 MiB, measured  860 MiB
  600 s → predicted 3754 MiB, measured 3753 MiB
```

The ~136 MiB intercept matches the MP4 figure and is presumably the legitimate
decode working set. The 6.03 MiB/s slope is the unbounded component.

## Real-world controlled comparison

Two commercial Blu-ray remuxes, both Matroska, both 10-bit HDR, both 23.976 fps,
near-identical size and duration. The meaningful difference is the codec:

| | AV1, 3840×1608, 8.5 GB, 2h00 | HEVC, 1920×802, 8.4 GB, 2h20 |
|---|---:|---:|
| t+5 s | 234.62 MiB | 159.30 MiB |
| t+45 s | 1217.89 MiB | 159.32 MiB |
| t+90 s | **2608.68 MiB** | 162.14 MiB |
| trend | +27.9 MiB/s, no plateau | flat (2.8 MiB drift) |

The AV1 file was still climbing linearly when sampling stopped. The HEVC file is
flat. Both were played with playbin3 and identical sink configuration.

This rules out container, file size, duration, bit depth, frame rate, HDR, and
the presence of multiple audio/subtitle tracks as explanations.

## Where the memory goes

`heaptrack` on a GTK application loading a 120 s AV1 Matroska clip (peak heap
1.63 GB; the file is 361 MB on disk):

| bytes | calls | stack |
|---:|---:|---|
| 741 MB | 16402 | `g_memdup2` ← `gst_buffer_new_memdup` ← `libgstvideoparsersbad.so` ← `gst_pad_push` ← `libgstmatroska.so` |
| 573 MB | 10184 | `gst_allocator_alloc` ← `gst_buffer_map_range` ← `libgstmatroska.so` |
| 108 MB | 8146 | `gst_allocator_alloc` ← `libgstgio.so` ← `gst_pad_pull_range` chain ← `libgstmatroska.so` |

1.42 GB of the 1.63 GB peak, for a 361 MB file — resident roughly four times
over: once as read by `gstgio`, once as mapped/merged by `matroskademux`, and
again as `av1parse` copies each frame through `gst_buffer_new_memdup`.

16402 `gst_buffer_new_memdup` calls for a 120 s clip at 59.94 fps is
approximately one copy per frame for the entire file, which suggests the whole
stream is parsed and retained up front rather than streamed.

This is not a leak — the memory is released correctly on pipeline teardown. It
is retained for as long as the media is loaded.

## Timing

Growth is not gradual during playback. On a small cached file the full
allocation completes within one to three seconds of the pipeline being set up
and then stays flat. On large files it is limited by read throughput. Setting
the pipeline to PLAYING versus leaving it PAUSED makes no measurable difference
(872 MiB vs 860 MiB on the 120 s file).

## Impact on GTK applications

`Gtk.MediaFile` is playbin3-based via `GstPlay` and exposes no handle on the
pipeline, so applications cannot set queue limits or otherwise bound this.

A 40-line GTK4 program that only calls `Gtk.MediaFile.for_file()` reproduces it
fully. Attaching the media to a `Gtk.Picture`, polling `is_prepared()`, and
calling `set_playing(true)` all make no measurable difference:

| what the program does | growth |
|---|---:|
| construct `Gtk.MediaFile`, never attach it to anything | 859.80 MiB |
| attach to a `Gtk.Picture` in a shown window | 859.98 MiB |
| attach + poll `is_prepared()` every 100 ms | 859.92 MiB |
| attach + `set_playing(true)` | 872.21 MiB |

In our case — a GTK4 video converter that previews the selected input — choosing
a 9.5 GB 4K AV1 file drove the process to 36 GiB RSS and made the application
unusable on machines with less than roughly 40 GiB of RAM. Two independent
preview pipelines meant paying the cost twice.

Matroska/WebM is what yt-dlp, gallery-dl and most AV1 encoders produce, so
affected inputs are common and getting more so as AV1 adoption grows.

Full reproducer source: `DevTools/mediafile-probe.vala` in this project.

```vala
// valac --pkg gtk4 mediafile-probe.vala -o mediafile-probe
// ./mediafile-probe /path/to/av1.mkv bare 20
var media = Gtk.MediaFile.for_file (GLib.File.new_for_path (path));
// nothing else — RSS climbs until the file is resident
```
