# libmpv port review — status and remaining work

Review of the GStreamer → libmpv preview-player port introduced by commits
`500b4b6`, `327a484`, and `bcb5d30`. The review and follow-up implementation
were performed on 2026-07-29 against mpv 0.41 / libmpv 2.5.0.

This document is the current status record:

- **Open work** is authoritative. One numbered finding remains, and it is an
  upstream report rather than a code change.
- **Completed work** records the fixes already present in the working tree and
  the regression coverage added for them.
- Finding numbers are stable. Findings 1-9 have been fixed and moved to
  completed work; 10 keeps its original number rather than being renumbered.
- Source line references were rechecked on 2026-07-29 and will drift as files
  change.

## Status at a glance

| Priority | Findings | Remaining outcome |
| --- | --- | --- |
| External | 10 | Report and track the upstream libmpv rotated-video software-renderer abort. |

The local workaround for finding 10 is already in place and covered by
`DevTools/mpv-render-probe.c`; what remains is filing it, which needs an
upstream account.

## Open work

### Upstream

#### 10. External — report the libmpv rotated-video software-renderer abort

With mpv autorotation active, libmpv's software render API aborts inside
`mpv_render_context_render` for files carrying 90° or 270° container rotation:

```text
mp_image_crop: Assertion `x1 <= img->w && y1 <= img->h' failed
  in mpv_render_context_render()
```

The failure is independent of render-target size, `profile=sw-fast`, and hwdec
selection. A stream-copy remux that adds only the rotation flag is sufficient to
turn a working file into a reproducer. The 180° case is unaffected, matching the
failure's dependence on swapped dimensions.

`DevTools/mpv-render-probe.c --legacy-rotate` is the standalone reproducer. The
application workaround is already in place, but the upstream defect remains.

**Done when:** an upstream mpv issue contains the reproducer and environment,
its URL is recorded here, and the local workaround remains until a confirmed
fixed libmpv version is available.

## Completed work

### Finding 1 (was High) — the software render no longer blocks GTK's main thread

`mpv_render_context_render` was called without
`MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME`, so libmpv used its blocking default
and waited for each frame's target display time inside the GTK frame-clock tick
callback.

**The original finding understated this in two ways.** Measurement, rather than
reading from the option default, established:

- *The wait is bounded by the frame interval, not by the 50 ms
  `video-timing-offset`.* mpv cannot begin the next frame until the previous one
  is displayed, so the real bound is `min (offset, 1 / fps)` and the whole
  interval is spent inside the render call. Measured p50 render time was
  41.42 ms on a 24 fps source (interval 41.67 ms) and 33.18 ms at 29.97 fps
  (interval 33.37 ms).
- *How bad it is depends on the scheduling around it.* This was originally
  measured against the GTK frame-clock tick the backend used at the time, where
  a 60 fps source was nearly unaffected — the tick and the frame rate coincided,
  so the target time had all but arrived by the time the tick caught the frame.
  That is why the defect survived review. **Finding 7 has since replaced the
  tick with mpv's own render notification, and under that scheduling every rate
  is affected**, because the render call now happens as soon as the frame
  exists rather than at the next display refresh.

Share of wall-clock time the calling thread spent inside
`mpv_render_context_render`, over six seconds of playback at a 1600x900 render
target, measured against the scheduling that now ships:

| source | before | after |
| --- | --- | --- |
| 24 fps | 99.4% | 4.5% |
| 29.97 fps | 99.4% | 4.2% |
| 60 fps | 99.5% | 5.7% |
| 24 fps, no audio track | 99.4% | 4.2% |

In the application that thread is the GTK main thread, so the previous
behaviour was not occasional UI stalls but a main loop that did essentially
nothing while a preview played.

**Only playback was ever affected.** Paused work goes through a different path —
there is no target display time to wait for when the clock is not running — and
this is most of what the preview is actually used for. Exact seeks and frame
stepping measure the same either way, to within noise and with no timeouts:

| operation | before | after |
| --- | --- | --- |
| exact seek to a trim point | 41.4 ms mean | 38.8 ms mean |
| frame step | 43.3 ms mean | 39.6 ms mean |

**The cost was removed, not relocated.** Total process CPU over the same six
seconds of 24 fps playback falls from 2.09 s to 1.63 s of user time; the
blocking wait was itself consuming cycles. A seek/step run shows the same
direction.

**The fix is two changes, and both are required:**

- `src/mpv-backend.vala` — `apply_options ()` sets `video-timing-offset=0` on
  the video path. This is what preserves correctness: mpv keeps timing video
  against audio and only stops preparing frames ahead of their display time, so
  the render call returns immediately instead of waiting.
- `src/mpv-compat.c` — `fcg_mpv_render_sw_draw ()` passes
  `MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME = 0`. This enforces "a render call
  never blocks the main thread" as an invariant that holds even if the option is
  overridden by a profile or its default changes.

**Disabling the render block on its own is the wrong fix**, despite being the
parameter `render.h` names first. With the lookahead still in place, mpv hands
frames over early and they are presented early. `render.h:314-315` describes
this as "A/V sync being slightly off"; measured against mpv's own target time,
frames go out **39.3 ms early on average** at 24 fps — most of a frame interval
— while the timing numbers stay indistinguishable from the fix and mpv's
`avsync` property stays at 0.0 ms. Dropped frames appear too, but
intermittently, so they are not a reliable tell.

That last point matters for the probe: detecting this trap needs the
presentation lead measured explicitly against
`MPV_RENDER_PARAM_NEXT_FRAME_INFO`. Note `target_time` there is in
**nanoseconds**, against `mpv_get_time_ns ()`; `render.h:532-539` still
documents it as sharing a base with `mpv_get_time_us ()`, which is stale and
puts the reading out by a factor of 1000.

A/V sync is preserved, by two independent measures. mpv's own `avsync`
property, sampled after every presented frame, stays at a mean of 0.2 ms and a
maximum of 0.5 ms across the clips above, against a baseline of 0.0 ms. The
presentation lead against mpv's target time is -1.7 ms — frames go out
marginally *late*, never early — with no frames dropped. Both are far below
perceptibility. Both are also internal to libmpv: the latency from the render
call to GTK compositing the texture is outside them, and is unchanged by this
fix.

**Removing mpv's headroom does not cost anything on a loaded machine**, which
was the main risk in setting the offset to zero given that this preview is meant
to stay usable on weak hardware. At the full 1920x1080 render cap under 24-way
CPU contention the fixed path holds at 4.5% blocked, zero dropped frames and a
-2.0 ms lead, while `--legacy-timing` under the same load sits above 99%.
`hwdec=auto-copy-safe` raises mean render time to 2.03 ms and changes nothing
else.

`DevTools/mpv-render-timing-probe.c` is the harness. It mirrors
`apply_options ()`, drives the real `fcg_mpv_render_sw_draw ()`, and reports
render-time percentiles, blocked-time share, `avsync`, drop counts and
presentation lead, exiting non-zero on failure so it can be run over a corpus
like its sibling. `--legacy-timing` reproduces the original defect
(`BLOCKED`) and `--legacy-offset` the trap (`PRESENTING-EARLY`).

**It also mirrors the backend's scheduling**, which is the part that will rot:
it drives rendering from mpv's render-update callback into a coalesced idle,
exactly as `MpvBackend` does since finding 7. It originally simulated the GTK
frame-clock tick the backend used then, and that model silently stopped matching
reality — which is how the "60 fps is unaffected" claim above came to be wrong.
If the backend's scheduling changes again, this probe must change with it.

Unlike `mpv-backend-probe.vala` it depends only on `src/mpv-compat.c`, so the
build command in its header works as written; finding 9 has since given all
three probes Meson targets.
`DevTools/mpv-render-probe.c` cannot cover this, as it renders a single paused
frame.

Verified against the rotation and sizing corpus that `mpv-render-probe.c`
exists for, since the block parameter changes the shared render helper: all six
clips still report FILLS TARGET.

### Finding 2 (was Low) — lifecycle and input hardening

All three items fixed. One of them was not what the finding described.

**`MPV_EVENT_SHUTDOWN` now tears the core down.** `drain_events` used to return
and leave the handle and both timers alive. The original write-up called that an
API-legality issue; it is also a leak, and a self-sustaining one. Vala compiles
the event-poll and settle timers with `g_object_ref (self)` as their user data
(`builddir/ffmpeg-converter-gtk.p/src/mpv-backend.c:1599`, `:1824`), so the
sources hold a strong reference to the backend. Returning without teardown left
the core, render context and demuxer buffers pinned behind a 20 Hz poll that
could never do anything again, and made `~MpvBackend` unreachable. The handler
now closes and reports through the same terminal path as an `END_FILE` error.

**`fcg_mpv_cmd` rejects non-trailing nulls.** It collapsed the non-null
arguments, so a null in the middle promoted the third argument into the second
slot — `("vf", null, "set")` ran as the two-argument command `("vf", "set")`.
That is not a malformed command mpv would reject, it is a different well-formed
one, so the mistake would have produced a wrong result rather than an error. The
list now ends at the first null and a null followed by a non-null returns
`MPV_ERROR_INVALID_PARAMETER`.

**The audio-index finding was wrong about the symptom.** It claimed an
out-of-range index "can silently select no audio". Measured against mpv 0.41,
what actually happens depends on whether there is video to fall back on:

- *Audio-only backend* — the only kind that is ever given an index, from
  `src/audio-player.vala:403`. Every track is deselected, so mpv has nothing to
  decode and fails the load outright with `MPV_ERROR_NOTHING_TO_PLAY`. It never
  reaches `FILE_LOADED`. So the index was already surfaced as an error, just an
  opaque one: "no audio or video data played", which says nothing about the
  selection. Worse, mpv empties its track list before `END_FILE` arrives, so the
  handler cannot report how many streams the file actually had.
- *Backend also decoding video* — mpv resets `aid` to `"no"` and plays on, mute.
  This is the silent case the finding described. No current caller reaches it,
  but `open ()` takes the index as a public parameter, so it is guarded.

Handled at both points accordingly: `drain_events` names the requested stream in
the failure detail when the error is `NOTHING_TO_PLAY`, and
`verify_audio_selection ()` counts the tracks after load and falls back to mpv's
default when there is video to keep playing. Deliberately not a silent recovery
in the first case — an out-of-range index means the caller's stream list
disagrees with mpv's, and reporting it points at that bug instead of hiding it.

### Finding 8 (was Medium) — the deterministic logic has headless coverage

The decisions the backend makes before it touches libmpv or GTK are now pure
static helpers, tested branch by branch in `tests/mpv-backend-state-test.vala`.
That target already ran headless, so no new one was needed; it is now 12 cases,
five driving a live libmpv core and seven pure.

Extracted and covered:

- `crop_space_width` / `crop_space_height` / `is_quarter_turn` — the crop
  coordinate space, including that a half turn does *not* swap axes;
- `aspect_of` — the drawn aspect, including the anamorphic-plus-rotation case
  where the stretch moves between axes, and the divide-by-zero guards;
- `normalize_rotation` — wrapping, negative angles, and angles off the four
  right angles being treated as upright rather than guessed at;
- `rotation_filter` — the clockwise mapping for each angle;
- `rotation_is_settled` — including the square-frame case that would otherwise
  never settle and never get a paintable;
- `fit_render_size` — the no-upscale clamp, the 1920x1080 cap on both axes, the
  two-pixel floor, and the unallocated-widget rejections;
- `frame_geometry_for` — stride alignment swept across 200 widths, asserting the
  stride is always a multiple of 64 and always covers the visible row;
- `aid_option_for_index` and `audio_index_is_out_of_range` — the zero-based to
  one-based mapping, and that a file with no audio is not an out-of-range
  selection.

The instance methods are thin wrappers over these, so the extraction did not
change behaviour: the live-core cases, the rotation and sizing corpus, and the
render-timing tests all still pass.

**The tests were mutation-checked rather than assumed to work.** Making
`is_quarter_turn` treat 180 as a swap, removing the no-upscale clamp from
`fit_render_size`, and dropping the 64-byte stride rounding each fail exactly
the case meant to catch them.

What is deliberately still not covered branch by branch: `count_audio_tracks`
and `verify_audio_selection` need a live core to enumerate tracks, so only the
range decision inside them is pure and tested. Their integration behaviour is
covered by `out-of-range-audio-index-reports-the-stream`.

### Findings 5 and 6 (were Medium, then Low) — the frame buffer is aligned and no longer copied

Fixed together, as the original write-up asked. Each rendered frame now gets its
own 64-byte-aligned allocation from `fcg_frame_buffer_alloc ()`, and ownership of
that allocation is handed to the texture through
`fcg_frame_buffer_to_bytes ()`, which wraps it in a `GBytes` with a matching
free function. `GdkMemoryTexture` references the `GBytes` rather than copying it,
so the frame reaches GTK without the per-frame `memcpy`, and nothing touches the
buffer after it is handed over — which is what made the copy necessary before.

Measured at the 1920x1080 render cap:

| path | per frame | share of one core at 60 fps |
| --- | --- | --- |
| before: reusable scratch + copy out | 0.352 ms | 2.1% |
| after: per-frame owned buffer | ~0.000 ms | ~0% |

**Per-frame allocation is not the cost it looks like.** The obvious objection is
that an 8 MiB `aligned_alloc`/`free` pair per frame would mmap-churn worse than
the copy it replaces. It does not: glibc grows its mmap threshold as it sees the
pattern, so after warm-up the block is reused from the heap and the alloc/free
pair measures at the timer's resolution. That is why no buffer pool was needed —
one was drafted and then dropped as unnecessary complexity.

Two details worth keeping:

- The **pixels** are deliberately not zeroed, because clearing them would
  reintroduce exactly the full-buffer write being removed. That mpv really does
  write every visible byte was verified rather than assumed: rendering the same
  paused frame into two differently-poisoned buffers and diffing them leaves
  zero differing bytes in the visible area across seven clips, including
  anamorphic and rotated sources. A single-poison check is not enough — 0xA5
  collides with real pixel data often enough to look like a defect.
- The **row padding** is cleared. `GdkMemoryTexture` does not read it, but
  handing uninitialised heap to GTK and onward to a graphics driver is not worth
  the saving: at 1080x1920 the padding is 61 KiB against a 7.9 MiB frame and
  clearing it measures 0.003 ms, against the 0.351 ms the removed copy cost.
- `free ()` rather than `g_free ()`, via the `GBytes` free function, because the
  block comes from `aligned_alloc`. Relying on `g_free` to release it would work
  on glibc and is not guaranteed elsewhere.

Finding 5's alignment is now satisfied as a side effect. As recorded when it was
re-measured, it was not costing anything on this zimg-enabled mpv build; it is
fixed here because it came free with finding 6, not because it was hurting.

Verified with 6/6 on the `mpv-render-probe.c` rotation and sizing corpus, and by
playing 144 frames through the real backend with RSS flat at 194 MiB — a leak
would have shown as roughly 1.1 GiB.

### Finding 9 (was Low) — all three DevTools probes build from Meson

`meson compile -C builddir probes` builds `mpv-backend-probe`,
`mpv-render-probe` and `mpv-render-timing-probe`; each is also an individual
target, and all are `build_by_default : false`, so `make build` never compiles
them.

The hand-written `valac` line in `mpv-backend-probe.vala` is replaced by that
target. Chasing its dependency cascade by hand confirmed why it had rotted:
`MpvBackend` needs `AppSettings`, which needs `SmartOptimizerLogic`, which needs
the audio probe types, and onward. The probe therefore supplies the one clamp
`AppSettings` actually uses as a local stub — the same approach, and the same
reason, as `tests/mpv-backend-state-test.vala`. All four documented modes
(`video`, `audio`, `play`, `cycle`) were launched and produce their RSS summary.

The two C probes only ever needed `src/mpv-compat.c`, so their header build
commands already worked; they are declared alongside so all three stay compiling
together.

### Finding 4 (was Low) — stale comments and tooltips corrected

The frame-step tooltips now say "Step back/forward exactly 1 frame" instead of
"~33 ms", both stale mute comments are gone, the audio player's "with an
click-to-seek waveform" reads correctly, and `~MpvBackend`'s comment now says
that it can only run after `close ()` — by construction, since an open backend
is referenced by its own scheduled idles and by mpv's callbacks — rather than
implying its ordering protects a live case.

### Finding 7 (was Medium) — a paused preview is now completely idle

All three periodic sources are gone, replaced by notification.

**The libmpv event poll became `mpv_set_wakeup_callback`.** **The display-rate
GTK tick became `mpv_render_context_set_update_callback`.** Both callbacks run on
mpv's threads and do nothing but set a coalescing flag and schedule an idle; the
idle performs the actual libmpv work on the main thread, so the property the
polling design existed to guarantee is retained. `fcg_mpv_render_sw_create` no
longer installs its no-op update sink, since the backend installs a real one.

**The 100 ms position timers now run only during playback.** A paused preview
was waking ten times a second to re-read a position that could not have moved.
Everything else that moves the position calls a one-shot `sync_position ()`
instead. Seeks are asynchronous, so reading straight after issuing one returns
the old position; the backend therefore emits a new `playback_restarted` signal
from `MPV_EVENT_PLAYBACK_RESTART` and the players read the position when that
fires. That is more accurate than the old timer, which only picked the new
position up on its next tick.

Measured at the libmpv level, after load and settle:

| state | before | after |
| --- | --- | --- |
| paused, 5 s — event wakeups | 100 polls | **0** |
| paused, 5 s — render callbacks | ~300 ticks at 60 Hz | **0** |
| playing, 3 s at 24 fps — renders | ~180 at display rate | 72, one per frame |

Paused is silent, not merely cheaper. Playback also does 2.5x less work, because
rendering is now driven by frames produced rather than by display refreshes.

**Teardown safety.** Both callbacks hold a bare `this` and fire from mpv's
threads, so `close ()` clears them before releasing the handle and render
context. That is safe rather than merely lucky: `mpv_set_wakeup_callback` and
`mpv_render_context_set_update_callback` take the same lock mpv holds while
invoking the callback, so clearing one blocks until any in-flight call has
returned and no further call can begin. Idles capture `this`, which makes Vala
hold a reference, so a queued idle cannot outlive the object; it finds the
nulled handle and context and does nothing. The coalescing flags are
deliberately not reset in `close ()` — each is only ever cleared by the idle
that set it, so clearing one early would allow a duplicate.

One consequence worth noting: events now arrive promptly instead of being
coalesced by a 50 ms poll, so every intermediate `VIDEO_RECONFIG` during the
rotation transpose is seen rather than most being missed. `rotation_settled ()`
already guarded that, and now matters more than it did.

### Finding 3 (was Low) — the asynchronous video FPS probe is removed

`_fps`, its public getter, `start_fps_probe`, `cancel_fps_probe`, both
generation counters, the cancellable, and `FfprobeUtils.probe_input_fps_async`
are gone. Every video load previously spawned an ffprobe subprocess whose result
nothing read. `load_generation` went with it — it existed only to discard stale
probe results.

The synchronous `FfprobeUtils.probe_input_fps` stays, still used by
`src/converter.vala:348` and `src/codec-utils.vala:485`, and its docstring now
records why it is synchronous and that the preview players no longer probe frame
rate at all. `run_ffprobe_async` keeps its eight other callers.

### Latest follow-up: failure handling, unknown duration, and test visibility

- **Load failures now reach a terminal, visible state.** The compatibility shim
  carries `mpv_event_end_file.error` into Vala. `MpvBackend` closes the core,
  event source, render context, render tick, and settle timer before emitting
  `load_failed`. Both players reset their controls, show an inline error, and
  emit `media_failed`.
- **Stale duration state is cleared.** Player reset and failure paths clear old
  duration labels and mappings. Video also resets and disables its scrubber;
  audio disables waveform seeking until a valid mapping duration exists.
- **Playable media with unknown duration now completes readiness.** A successful
  load with duration zero starts normal position updates, emits `media_ready`,
  displays an explicit unavailable-duration message, and leaves only finite-
  duration controls disabled.
- **Audio waveform fallback is stream-specific.** `AudioStreamInfo` retains each
  stream's ffprobe duration, including Matroska `DURATION` tags. Container
  duration is used only when that stream has no usable duration, and switching
  tracks no longer reuses a mutable duration from the previous selection.
- **Trim handles unknown endpoints.** Quick-add creates a bounded ten-second
  segment when no endpoint is known. Crop Only represents “through EOF” directly,
  so FFmpeg omits `-t/-to` instead of producing a zero-length output.
- **Through-EOF audio fade-out is preserved.** Trim probes the first audio
  stream's duration solely as an `afade` placement hint; it does not turn that
  hint into an export limit. If the duration is still unknowable, the console
  explicitly reports that the fade was skipped.
- **Cleanup coverage is visible in the normal test set.** Headless backend tests
  verify failed audio- and video-mode cores close. The separately registered
  `mpv-player-display-state` test verifies the real video render context, event
  source, and GTK render tick are released. It runs when a display exists and
  reports an explicit skip on genuinely headless systems.

Relevant regression coverage:

- `tests/mpv-backend-state-test.vala` — real libmpv failure and core teardown;
- `tests/combine-window-state-test.vala` — player state transitions and
  display-backed render-resource teardown;
- `tests/ffprobe-utils-test.vala` — numeric stream durations, Matroska duration
  tags, and container fallback;
- `tests/audio-reorder-state-test.vala` — selected-stream duration isolation;
- `tests/trim-subtitles-state-test.vala` — unknown-duration ranges and a real
  FFmpeg through-EOF crop that retains audio fade-out while omitting `-t/-to`.

### Earlier rendering and lifecycle fixes

- **`AppSettings.settings_changed` no longer retains every backend.** A named
  instance handler lets Vala use an object-associated signal connection that is
  disconnected automatically when the backend is destroyed.
- **Rotated-video abort is worked around locally.** mpv autorotation is disabled
  with `video-rotate=no`; an explicit transpose filter is chosen from
  `current-tracks/video/demux-rotation` for 90°, 180°, and 270° inputs.
- **Render targets use displayed dimensions.** `dwidth`/`dheight`, rather than
  coded dimensions, size the paintable and render target, avoiding baked-in
  black bars on anamorphic and rotated media.
- **Crop coordinates use the correct space.** `crop_width`/`crop_height` expose
  the post-rotation coded coordinate space used by FFmpeg crop filters, while
  `display_aspect` keeps the overlay aligned with the drawn frame.
- **Decoder corrections propagate after load.** Video readiness waits for
  `VIDEO_RECONFIG`, and `video_size_changed` reports later dimension corrections
  rather than permanently trusting the container's initial claim.

## Verification snapshot

The latest completed work was validated on 2026-07-29 in the project's Wayland
development session:

```text
Application build:                 passed
Meson tests:                       18 passed, 0 failed
mpv-backend-state:                 12 cases passed (was 2)
DevTools probes:                   3/3 build via `meson compile -C builddir probes`
Rotation/sizing corpus:            6/6 FILLS TARGET (shared render helper changed)
mpv-render-timing:                 2 cases passed (new, headless)
mpv-player-display-state:          2 cases passed (executed, not skipped)
Real through-EOF FFmpeg crop/fade: passed
git diff --check:                  passed
```

Findings 2 and 3 added two cases to `tests/mpv-backend-state-test.vala`, both
driving a real libmpv core against an ffmpeg-generated multi-track fixture and
skipping explicitly if ffmpeg is unavailable:

- `out-of-range-audio-index-reports-the-stream` — an index past the end of the
  file fails the load naming the requested stream, and an in-range index still
  selects exactly that track. Confirmed to fail without the fix rather than
  passing either way.
- `shutdown-tears-down-the-core` — `MPV_EVENT_SHUTDOWN` releases the core and
  the event source. The app never sends `quit`, so this needs a test-only hook
  to reach the event at all.

Finding 7 added a third:

- `open-close-cycles-leave-nothing-running` — thirty open/close cycles closing
  at a different point in the load each time, mixing successful and failing
  loads, asserting no signal fires after `close ()` and that the backend still
  loads normally afterwards. This targets the window the notification design
  introduces: an idle already queued for a handle that is about to go away.

The paused-idle numbers in the finding 7 section come from a standalone probe
against a live libmpv core, counting callback invocations directly. No automated
test asserts the wakeup rate.

Finding 1's two halves are now asserted automatically, in the two places each is
reachable. Both were confirmed to fail when their half of the fix is reverted,
rather than passing either way:

- `tests/mpv-render-timing-test.c`, registered as `mpv-render-timing` — C only,
  so it runs headless, unlike the widget tests. `does-not-block-with-default-lookahead`
  plays with mpv's default lookahead deliberately left in place and asserts the
  blocked share stays low; removing `MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME`
  takes it from 2.0% to 99.3%. `frames-are-not-presented-early` asserts frames
  are not handed over ahead of mpv's target time, which is the only signal that
  distinguishes the trap: dropping the offset moves the mean from -1.2 ms to
  +40.4 ms while the timing numbers and `avsync` stay unchanged.
- `/players/video/disables-mpv-timing-lookahead` in the display-gated
  `mpv-player-display-state` test — asserts a real `VideoPlayer` runs its core
  with `video-timing-offset=0`, read back from the live core so a rejected
  option is caught too. The C test cannot reach this half, because the option is
  only applied on the video path and that needs a `Gtk.Picture`. Removing the
  option from `apply_options ()` reads back 0.05 and fails.

Thresholds are deliberately wide — 40% blocked, 10 ms lead — because the gap
between correct and broken is two orders of magnitude, so a loaded machine
cannot trip them.

`fcg_mpv_cmd`'s argument handling was verified separately against a live mpv
handle across all seven null combinations, including that valid one- and
two-argument commands still run.

Commands used:

```sh
meson compile -C builddir ffmpeg-converter-gtk
meson test -C builddir --print-errorlogs
git diff --check
```

Build output still contains the project's existing generated-C and Vala warnings;
the completed changes introduced no build or test failure.

Finding 1 is covered by the two automated tests described below, added after the
fix; the numbers in its section come from the exploratory probe rather than from
those tests. The suite above was re-run after each change with the same result,
and every number in the finding 1 section comes from
`DevTools/mpv-render-timing-probe.c` calling the real `fcg_mpv_render_sw_draw ()`
— the shipped code path, not a simulation of it:

```text
Probe builds from its header command, -Wall -Wextra: clean
video-timing-offset read back after init:            0.000 (option took)
Fixed, 24 / 29.97 / 60 fps:                          4.5% / 4.2% / 5.7% blocked, 0 dropped
Fixed, presentation lead:                            -1.7 ms (late, never early)
--legacy-timing, 24 / 29.97 / 60 fps:                99.4% / 99.4% / 99.5% blocked
--legacy-offset, 24 fps:                             +39.3 ms early (the trap)
Fixed, 1920x1080 under 24-way CPU load:              4.5% blocked, 0 dropped
mpv-render-probe.c rotation/sizing corpus:           6/6 FILLS TARGET
```

Fixture and corpus generation commands are in the two probes' header comments.
The corpus covers the common cinematic rates, one clip at the frame-clock rate
as a control, and one 24 fps clip with no audio track, which confirms the block
is not specific to audio-timed playback.
