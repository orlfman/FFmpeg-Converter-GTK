# Crash: AV1 hardware decode via Vulkan aborts the process

Investigation of the core dump from 2026-07-29 22:34:33 (pid 409425), taken on
first launch after loading a 4K AV1 WebM. The original report is unchanged below;
see [Update](#update-2026-07-30) for what has since shipped.

## Status

| | |
| --- | --- |
| Cause | Identified with high confidence |
| Reproduced | **No** — 4 attempts, see [Reproduction](#reproduction) |
| Is it a regression from the recent port work? | **No** — see [Not a regression](#not-a-regression) |
| Fix | Not applied as a default; a user-selectable escape hatch shipped instead |

## Update 2026-07-30

Preferences → Player now carries a **Hardware Decoding** mode selector, so this
crash no longer costs a user all hardware decoding — only Vulkan. Relevant to
the decisions left open below:

- **"Automatic, skip Vulkan"** maps to `vaapi-copy,nvdec-copy,cuda-copy,amf-copy,no`.
  mpv accepts a comma-separated priority list and skips entries the machine
  cannot provide, so this stays portable rather than being a one-machine
  workaround — an NVIDIA box still hardware-decodes under it. Verified against
  mpv 2.5.0.
- The default is **unchanged** (`auto-copy-safe`), which on this machine still
  resolves to `vulkan-copy` for AV1. Item 4 below — whether to exclude Vulkan
  outright — is still open and still wants a newer Mesa/RADV before deciding.
- The decoder in use, and the GPU it runs on, are now shown in that same
  Preferences group rather than only in a debug log. On this machine
  "Automatic" reports `vulkan-copy on AMD Radeon RX 9070 XT (RADV GFX1201)` and
  "Automatic, skip Vulkan" reports `vaapi-copy on Intel iHD driver for
  Intel(R) Gen Graphics` — i.e. skipping Vulkan also moves decoding to the
  integrated GPU, which is worth knowing before recommending it as a fix.

## What crashed

The faulting thread is 409793, and none of it is application code:

```text
#0  0x00007fc68256f600 libvulkan_radeon.so + 0x16f600   <- RADV driver
#1  0x00007fc6fca39f40 libavcodec.so.62 + 0xe39f40
#2  0x00007fc6fca3a589 libavcodec.so.62 + 0xe3a589
#3  0x00007fc6fbdf19a1 libavcodec.so.62 + 0x1f19a1
#4  0x00007fc6fbf39ae4 libavcodec.so.62 + 0x339ae4
#5  0x00007fc6fbf3aa35 libavcodec.so.62 + 0x33aa35
#6  0x00007fc6fbf3b3be avcodec_send_packet
#7  0x00007fc6ff13ae7b libmpv.so.2 + 0x13ae7b            <- mpv decoder thread
```

This is the **video decode** path, not the render path: `avcodec_send_packet`
handing a packet to a Vulkan hardware decoder, which faults inside AMD's RADV
driver.

The other 30-odd threads in the dump are all idle or waiting. In particular the
main thread (409425) is sitting in `audio_settings_rebuild_codec_list` →
`gtk_drop_down_set_model`, which is simply where it happened to be when the
process died — not a second fault. Thread 409808 running
`subtitles_runner_probe_sync` under `g_spawn_sync` is likewise unrelated
background work.

## The input

```text
/mnt/storage3/library/tmp/input/gallery-dl/nzbget/
  2025-02-23 - Raw Footage Stationary Camera College Gymnastics 4k Sports Video
  #gymnastics #4k #gymnast [HVpm_Z6qLzA].webm

codec_name=av1   width=3840   height=2026   pix_fmt=yuv420p
r_frame_rate=19001/317 (~59.94)   size=10,223,491,441 bytes
```

Note 3840x**2026** — not a standard 2160-line frame. Odd dimensions are a
recurring source of trouble in hardware video decode blocks, so this is worth
keeping in mind as a possible trigger rather than assuming any 4K AV1 file will
do it.

## The chain

Confirmed by running mpv with the application's own option set:

1. `MpvBackend.wanted_hwdec ()` returns `auto-copy-safe` whenever the
   **Hardware Decoding** preference is on (`src/mpv-backend.vala`).
2. On this machine, for this file, mpv resolves that to **`vulkan-copy`**:

```text
[vd] Looking at hwdec av1-vulkan...
[vd] Looking at hwdec av1-nvdec...
[vd] Looking at hwdec av1-vaapi...
[vd] Looking at hwdec av1-vulkan-copy...
[vd] Trying hardware decoding via av1-vulkan-copy.
Using hardware decoding (vulkan-copy).
```

3. AV1 decode then runs through RADV's Vulkan video decode — the library at the
   top of the stack.

RADV itself prints `radv is not a conformant Vulkan implementation, testing use
only` on this system, which has shown up in unrelated runs during this work too.

The machine has both `libvulkan_radeon.so` and `libvulkan_intel.so` loaded, so
it is a hybrid-GPU setup. Vulkan video decode picking a device on a hybrid
system is another known rough edge, though nothing here proves that is involved.

## Not a regression

None of the recent port work touches decoding:

- `hwdec=auto-copy-safe` was introduced in commit `500b4b6`, which is the
  original GStreamer → libmpv port, well before any of the review fixes.
- The changes made since (timing offset, render block parameter,
  notification-driven scheduling, frame-buffer ownership, audio-index
  validation, `fcg_mpv_cmd` argument handling) all sit on the render and event
  side. The crash is on mpv's decoder thread inside libavcodec.

The one thing worth ruling out properly is the new per-frame frame buffer, since
a heap overflow there could in principle corrupt an unrelated thread's
allocation. It was re-checked and the arithmetic is in bounds:

- allocation is `align64(stride * height)`;
- padding clear ends exactly at `stride * height`;
- slack clear ends exactly at the padded size;
- mpv writes `stride * height`;
- the `GBytes` is created with `stride * height`, and GTK reads at most
  `stride * (height - 1) + width * 4`, which is smaller.

That is reasoning, not proof. A run under valgrind or ASan would settle it and
is cheap to do — see [Next steps](#next-steps).

## Reproduction

**Not reproduced.** Four attempts against the same file on the same machine:

| attempt | configuration | result |
| --- | --- | --- |
| 1 | `--hwdec=auto-copy-safe --frames=40` | clean, exit 0 |
| 2-4 | `--hwdec=vulkan-copy --start=5% --frames=60`, three runs | clean, exit 0 |

So it is intermittent. That matters for judging any fix: a few clean runs after
a change will not be evidence that it worked.

Not yet tried, and worth trying before concluding anything:

- the full application rather than bare mpv, so the render context and the
  software renderer are in play;
- repeated open/close of the same file, which is what actually happened;
- other 4K AV1 sources, to see whether the odd 2026-line height matters;
- a longer soak than 60 frames.

## The fix that was identified

Stop letting mpv choose Vulkan video decode. `auto-copy-safe` sounds
conservative and the existing comment in `apply_options ()` describes it as
restricting selection to "hardware decoders mpv considers reliable" — but mpv's
idea of safe includes Vulkan, which on RADV self-identifies as non-conformant.

Replacing the single value with an explicit priority list was verified to work
on this machine:

```text
hwdec = vaapi-copy,nvdec-copy,d3d11va-copy,videotoolbox-copy,no
```

- Picks `vaapi-copy` here and **never probes Vulkan**:
  `[vd] Looking at hwdec av1-vaapi-copy... Using hardware decoding (vaapi-copy).`
- `vaapi-copy` decodes this exact file fine.
- Falls back to software cleanly when nothing in the list is available —
  tested with a deliberately unavailable list, which logged `Unsupported hwdec:
  d3d11va-copy` and then `Selected decoder: libdav1d`, no error.
- Entries for other platforms are harmless on Linux; the "unsupported" line goes
  to mpv's log, which the application suppresses with `terminal=no`.

Two judgement calls to make before applying it, which is part of why it was left
alone:

1. **It removes Vulkan decode for everyone**, including hardware where Vulkan is
   the only hardware path and works. The fallback is software dav1d, which is
   correct but slower — and this preview explicitly targets weaker machines.
2. **A decoder fault cannot be caught in-process.** It is a SIGSEGV on a library
   thread, so the only defence is not selecting that decoder. That argues for
   excluding it; the counter-argument is that it is intermittent and may be
   specific to this driver version or this file.

A narrower alternative is to keep `auto-copy-safe` but exclude Vulkan
specifically, if mpv grows a way to express that; it currently does not, so the
explicit list is the available mechanism.

## Next steps

1. Try to reproduce properly — full application, repeated loads, other AV1
   sources. Without that, any fix is unfalsifiable.
2. Run the application under valgrind or with `-fsanitize=address` while loading
   this file, to definitively exclude the new frame-buffer path as a source of
   heap corruption.
3. ~~Decide on the hwdec policy above~~ — partly done: the list is available as
   an opt-in mode rather than imposed as the default. See
   [Update](#update-2026-07-30).
4. Check whether a newer Mesa/RADV fixes it, before permanently excluding a
   decode path over one driver.

## Reference

- `src/mpv-backend.vala`, `wanted_hwdec ()` and the `hwdec` block in
  `apply_options ()` — where the policy lives.
- `report_active_decoder ()` reads `hwdec-current` and publishes it to
  `MpvStatus`, so the chosen decoder is visible in Preferences as well as in a
  debug run. It is driven by an observer on that property, because the value is
  empty during the reconfigs that follow a decoder change and only settles
  afterwards.
- `HwdecMode` in `src/constants.vala` — the modes, and the only place the mpv
  spelling of each appears.
- `docs/mpv-port-review-findings.md` — unrelated to this crash, but records the
  rest of the libmpv port review.
