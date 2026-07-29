# Raw `malloc_info` dumps — input-load memory spike

Supporting evidence for [`../../input-load-memory-spike-findings.md`](../../input-load-memory-spike-findings.md).

Captured 2026-07-28 from a single running `ffmpeg-converter-gtk` process
(installed build) via `gdb -p <pid>` calling `malloc_info(0, fopen(...))`. The
process was left running and undisturbed between the two dumps; only the main
window's input file was changed.

| File | State when captured |
|---|---|
| `malloc-info-1-loaded.xml` | 9.52 GiB 4K AV1 WebM loaded; RSS 36.21 GiB |
| `malloc-info-2-after-swap.xml` | main input switched to a small file; RSS 36.29 GiB |

## What they show

```text
                        loaded            after swap
  heap from OS          36.02 GiB         36.10 GiB
  IN-USE                35.77 GiB (99.31%) 0.18 GiB ( 0.50%)
  free within heap     253.2 MiB  ( 0.69%) 35.92 GiB (99.50%)
```

Two arenas of 17.94 GiB each with 288 subheaps each — one per `GstPlay`
pipeline. In-use falls to zero on input change, which is what rules out a leak
and identifies the retained RSS as glibc arena retention.

A subsequent `malloc_trim(0)` on the same process recovered 35.88 GiB of
36.29 GiB (98.9%).

## Reading them

The last block in each file is the process-wide total. Compare
`<system type="current">` (obtained from the OS) against
`<total type="rest">` (free, excluding fastbins); the difference is in-use.
Per-arena blocks appear above it, each ending in `</heap>`.

Note that `<sizes>` bins list **free** chunks only, so the loaded dump shows
almost nothing there while the post-swap dump shows the freed allocations.

Environment: GTK 4.22.4, GStreamer 1.28.5, glibc 2.44, 24 logical CPUs.
