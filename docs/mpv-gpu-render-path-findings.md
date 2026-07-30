# Adding a GPU render path to the mpv preview

Feasibility investigation from 2026-07-30. **Nothing has been changed** — this
is a report to pick up from.

## Status

| | |
| --- | --- |
| Current render path | Software (`mpv_render_context` created with the SW API) |
| Is GPU rendering possible? | Yes — libmpv's OpenGL render API, two viable routes |
| Prototype effort | ~1 day |
| Production effort | ~1 week, and the software path can never be deleted |
| Route B verified? | **No** — design proposal, not built or tested |
| Started? | No |

## Why this matters, and for whom

Not for fast machines. The application targets hardware weaker than any
developer box, and that is precisely where the current path costs most: the
software renderer does colour conversion and scaling **on one CPU thread**, on
the GTK main thread, for every frame. A GPU render path moves that work off the
CPU entirely and removes the per-frame VRAM→RAM readback that hardware decoding
currently requires.

The measurement in `src/mpv-backend.vala:551-560` ("264 ms vs 240 ms per exact
seek on a 24-core desktop") is a fast-machine number and should not be read as
"this doesn't matter". It is the *ceiling* of the benefit on a machine that has
CPU to spare. The floor — an old dual-core with an iGPU — is the case that
decides whether the preview is usable at all, and it is unmeasured.

The second reason is correctness rather than speed, and it applies to every
machine: **HDR sources preview with no tone mapping**. Tone mapping lives in
mpv's GPU renderer, so the software path has none and an HDR source previews
flat. For an application whose job is converting video, being unable to judge an
HDR→SDR conversion in its own preview is a functional gap, not a performance
one. No preference can fix it; only a GPU render path can.

## What the current path is

Verified by reading the code, not assumed:

| Piece | Where |
| --- | --- |
| SW render context created | `vapi/mpv.vapi:50` — `fcg_mpv_render_sw_create` |
| SW draw into a CPU buffer | `src/mpv-backend.vala:1214` — `render_sw_draw` |
| Buffer wrapped as a texture | `src/mpv-backend.vala:1223` — `Gdk.MemoryTexture`, `B8G8R8X8` |
| Texture handed to a paintable | `src/mpv-backend.vala:1229` — `FrameSink.set_frame` |
| Paintable drawn by | `Gtk.Picture` (`src/video-player.vala:56`, `attach_picture`) |
| Render driven by | mpv's update callback → `Idle` at `HIGH_IDLE` (`:1171-1182`) |
| Render sizing | `compute_render_size` / `fit_render_size` (`:1244-1266`) |

Two facts about this design are worth preserving through any change:

1. **Rendering is driven by mpv's update callback, not the GTK frame clock**
   (`:1140-1147`). That yields one render per *frame produced* rather than one
   per display refresh, and lets the frame clock idle while paused on a trim
   point — which is this player's normal resting state. On weak hardware this is
   worth more than it sounds.
2. **The render target matches the frame's aspect, not the widget's**
   (`:1234-1243`). mpv pads any mismatch with black, so a widget-shaped target
   bakes letterbox bars into the texture instead of letting `Gtk.Picture`'s
   CONTAIN fit show the themed background.

## Why hardware decoding already works without GPU rendering

Decode and render are separate stages. The application skips the GPU for the
second, not the first. The `-copy` suffix on the hwdec mode is the bridge, and
`src/mpv-backend.vala:551-560` already states the constraint: the software
renderer needs frames in system memory, so the decoder must read them back
rather than hand over a GPU surface.

```text
bitstream → [GPU decode block] → GPU surface
          → readback over PCIe → system memory
          → [sws/zimg: CPU convert + scale] → Gdk.MemoryTexture → GTK
```

Confirmed on an RX 9070 XT with output disabled entirely, so no GPU rendering
was involved at any point:

```console
$ mpv --config=no --hwdec=auto-copy-safe --vo=null --ao=null \
      --frames=60 --msg-level=vd=v tests/vegamonsoon.webm
[vd] Looking at hwdec av1-vulkan...
[vd] Looking at hwdec av1-nvdec...
[vd] Looking at hwdec av1-vaapi...
[vd] Looking at hwdec av1-vulkan-copy...
[vd] Trying hardware decoding via av1-vulkan-copy.
Using hardware decoding (vulkan-copy).
```

mpv rejects each non-copy mode because the output cannot consume a GPU surface,
then falls through to the copy variant. Note that this run also reproduces the
chain in [mpv-hwdec-vulkan-crash.md](mpv-hwdec-vulkan-crash.md): `auto-copy-safe`
resolving to `vulkan-copy` on AV1.

## What the software renderer costs

`apply_options` hardcodes `profile=sw-fast` (`src/mpv-backend.vala:527`). On
mpv 2.5.0 that profile expands to:

```console
$ mpv --show-profile=sw-fast
 sws-scaler=bilinear
 sws-fast=yes
 zimg-scaler=bilinear
 zimg-dither=no
```

Bilinear, no dithering. That is the right trade for a preview on one CPU thread,
but it is also the quality ceiling of the current path — the GPU renderer's
scalers, dithering and tone mapping are simply not reachable from here.

## Two routes

### Route A — swap `Gtk.Picture` for `Gtk.GLArea`

mpv renders directly into the GLArea's framebuffer. This is the conventional
libmpv+GTK approach and the one most examples show.

Costs: `compute_render_size` / `fit_render_size`, the `FrameSink` paintable, and
the aspect-matching design above all become dead or need reimplementing against
GLArea's layout model. Rendering also moves back inside GTK's draw cycle,
weakening preservation point 1.

### Route B — keep the paintable, change only the pixel transport (recommended)

Render mpv into an application-owned GL FBO, then wrap it with
`gdk_gl_texture_new` instead of `Gdk.MemoryTexture` at
`src/mpv-backend.vala:1223`. Everything downstream — paintable, `Gtk.Picture`,
aspect logic, update-callback-driven rendering — stays exactly as it is. The
diff is confined to `poll_and_render` plus the shim.

Both `gdk_gl_texture_new` and `gdk_surface_create_gl_context` are available
(GTK 4.22.4, libadwaita 1.9.2, libmpv 2.5.0 as of this investigation).

**Unverified.** Route B is a design proposal. It has not been built, and the
open risk is texture lifetime: `Gdk.GLTexture` needs a release callback, and the
FBO must not be reused while GTK is still compositing from it. The current code
solves the equivalent problem for CPU buffers by transferring ownership outright
(`:1197-1206`); the GL analogue needs its own solution.

### Shim work, either route

libmpv's GL render API needs `MPV_RENDER_PARAM_API_TYPE` =
`MPV_RENDER_API_TYPE_OPENGL` plus `MPV_RENDER_PARAM_OPENGL_INIT_PARAMS`
carrying a `get_proc_address` callback. That nested-struct-with-callback shape
is exactly what Vala cannot express directly, and exactly why
`src/mpv-compat.c` (254 lines) already exists for the SW helpers. Estimate ~70
lines added there, plus matching entries in `vapi/mpv.vapi`.

## What it buys

| Gain | Who benefits |
| --- | --- |
| CPU colour conversion and scaling leave the main thread | Weak CPUs — the target case |
| hwdec becomes non-copy (`auto-safe`), readback disappears | Everyone; most on low memory bandwidth |
| HDR tone mapping becomes possible | Everyone, and it is a correctness gap today |
| GPU scalers, dithering reachable | Anyone judging fine detail before encoding |

## What makes it a week rather than a day

1. **The software path can never be deleted.** GL initialisation fails on
   llvmpipe, remote sessions, VMs and broken drivers — all of which are more
   common on the weak hardware this change is *for*. Runtime fallback is
   mandatory, so both render paths live in the codebase permanently and this
   surface roughly doubles.
2. **GL context lifecycle.** mpv's GL render context must be created *and freed*
   with a GL context current, and a surface's context only exists once the
   widget is realised. Today the render context is created alongside the mpv
   handle, and `vapi/mpv.vapi:15` already warns it must be freed before the
   handle. That ordering needs restructuring.
3. **The timing tuning is software-specific.** `video-timing-offset=0` carries a
   measured justification (`src/mpv-backend.vala:528-549`) about blocking inside
   `mpv_render_context_render()`. GL blocks differently and the number must be
   re-measured. `DevTools/mpv-render-timing-probe.c` is the existing harness.
4. **Headless tests.** `mpv-backend-state` and `mpv-render-timing` run under
   `headless_gtk_test_env` (`meson.build:145`). A GL path will not, so the
   software path stays the testable one and GL coverage needs a different plan.
5. **The rotation workaround may become unnecessary — conditionally.**
   `video-rotate=no` plus a transpose filter (`:511-523`) exists because mpv's
   autorotate crashes *the software renderer*. GL likely does not need it, but
   it must become conditional rather than removed, and it interacts with the
   `vf set` at `:997` which replaces the whole filter chain.

## What does not block it

Nothing outside the player needs CPU access to preview frames. Colour correction
builds ffmpeg filter strings (`src/color-correction-dialog.vala:818+`) rather
than sampling the preview, and the only consumers of `MpvBackend` are
`VideoPlayer` (`src/video-player.vala:55`) and `AudioPlayer`
(`src/audio-player.vala:123`), the latter with video disabled entirely.

## Effort breakdown

| Task | Estimate |
| --- | --- |
| GL create/render helpers in `mpv-compat.c` + vapi | 0.5 day |
| Route B render into FBO, `Gdk.GLTexture` transport | 1–2 days |
| Context lifecycle restructure (realise/unrealise vs open/close) | 1 day |
| Runtime detection and fallback to the software path | 0.5 day |
| Re-measure `video-timing-offset`, re-validate rotation | 1–2 days |
| Test strategy for a path that cannot run headless | 1 day |

A prototype that puts a GPU-rendered frame on screen is reachable in a day; the
rest is what makes it safe to ship to hardware nobody here can test on.

## Open decisions

1. Is the GPU path opt-in, opt-out, or automatic with silent fallback? Automatic
   is best for users and worst for bug reports — "which renderer were you on?"
   needs to be answerable from the Console log either way.
2. If it lands, does `hwdec` gain a non-copy mode automatically on the GL path,
   or stay copy-only until the crash in
   [mpv-hwdec-vulkan-crash.md](mpv-hwdec-vulkan-crash.md) is understood? Non-copy
   changes which decoders are eligible and is the larger behavioural change of
   the two.
3. Does HDR tone mapping justify the work on its own? If the answer is yes, the
   priority is higher than any performance argument here.

## Reference

Verified during this investigation:

- Render API in use — `vapi/mpv.vapi:40-55`
- `sw-fast` contents — `mpv --show-profile=sw-fast`
- Available hwdec copy modes — `mpv --hwdec=help`: `auto-copy`,
  `auto-copy-safe`, `auto-copy-unsafe`, plus per-API `vaapi-copy`,
  `vulkan-copy`, `nvdec-copy`, `cuda-copy`, `amf-copy`
- Versions — GTK 4.22.4, libadwaita 1.9.2, libmpv 2.5.0
- `gdk_gl_texture_new`, `gdk_surface_create_gl_context` present in GTK 4.22
  headers
