# Per-Segment Speed Control — Battle Plan

> **Implementation status:** built and audited. All nine phases landed, plus one
> the plan missed (Phase 10, audio stream-copy). `meson test` is green at 21/21,
> with five new cases in `trim-subtitles-state`.
>
> **Known limitation:** a speed change retimes video and audio but **not
> subtitle streams**. The re-encode path emits no explicit `-map`, so ffmpeg's
> default selection carries a source subtitle track through unscaled, and it
> drifts against the retimed picture. This predates per-segment speed — the
> General tab's speed has always had it — and is not addressed here.
>
> **Scope (locked):** Trim Only and Crop & Trim sub-tabs of the Crop & Trim tab.
> Chapter Split and Crop Only do not get the control — they build their segment
> lists themselves and pass them straight to the runner.
>
> **Line anchors below are as of `ff0eac5`.** They are a starting map, not
> gospel. Every anchor is paired with a content signature — match on the
> signature, not the number.

## Mission Statement

Give each segment its own playback-speed control that moves **video and audio
together**, so a segment set to −50% comes out half-speed in both streams with
no drift and no desync.

```
#1  00:00:10 → 00:00:40  (30s)
#2  00:01:20 → 00:02:45  (1:25 → 2:50)   [speed: 0.50×]      ← slowed
#3  00:04:00 → 00:04:30  (30s → 15s)     [speed: 2.00×]      ← sped up
```

## The Core Mechanism

One number per segment — a percentage in the same `−99…+100` form the General
tab already uses — resolved to a playback-rate multiplier `s = 1 + pct/100`,
driving both streams from the same value:

| Stream | Filter |
| --- | --- |
| video | `setpts=(1/s)*PTS` |
| audio | `atempo` chain to `s` (pitch-preserving, decomposed for values outside 0.5–2.0) |

Both are derived from a single `s`, so the two streams are synchronised *by
construction*: each output stream is exactly `span / s` long. There is no
reconciliation step and no way for the user to desync them, which is the whole
reason this is one control rather than the two independent ones the General tab
exposes.

## Locked Decisions

| Question | Decision | Why |
| --- | --- | --- |
| Segment speed vs. the General tab's speed | **Stack** — effective = global × segment | The global speed is baked into the pre-rendered `video_filters_skip_delogo` / `_skip_crop_and_delogo` strings on `EncodeProfileSnapshot`. Appending a second `setpts`/`atempo` is exact and free; an override needs `_skip_speed` variants of all four strings, and that struct already has a combinatorial problem from crop and delogo. |
| Copy mode when a segment is sped | **Disable copy for the whole export** | Joins the existing `speed_locked` / `watermark_locked` / `logo_removal_locked` family. Mixing copied and re-encoded segments through the demuxer concat only works when the re-encode matches the source codec parameters exactly. |
| Control | **`%` SpinButton**, `−99…+100`, 0 = unchanged | Same idiom, same range, same sanitiser as the General tab. Per-segment ceiling is 2×; stacking with the global speed still reaches 4× when needed. |

## Current State — Verified Facts

| Fact | Anchor |
| --- | --- |
| Segment model, passed to the runner by reference via `set_segments()` | `TrimSegment` — `src/ui/trim-tab.vala:9` |
| Percent → multiplier, with NaN/inf and `≤ 0` guards, `0` short-circuits to "off" | `try_get_speed_multiplier` — `src/encoders/filter-builder.vala:17` (private) |
| `atempo` decomposition for values outside 0.5–2.0 already exists | `build_atempo_chain` — `filter-builder.vala:515` |
| Video chain is reassembled per segment (not taken pre-rendered) so delogo can sit ahead of the segment crop | `build_video_filter_chain_for_segment` — `filter-builder.vala:104` |
| Both export paths funnel their video filters through one function | `build_segment_vf` — `trim-runner.vala:998`, called at `:482` (PATH A) and `:889` (PATH B/C) |
| Both export paths funnel their audio filters through one function | `build_audio_filters_for_segment` — `trim-runner.vala:1143`, called at `:503`, `:647`, `:965` |
| **The segment span is already bound on the input side** — `-t` ahead of `-i` | `extract_segment` — `trim-runner.vala:844-860`. Commit `7f80a98` did this precisely so speed filters could not shift the range. This is the load-bearing prerequisite and it is already done. |
| Per-segment re-encode already has a precedent | `bool seg_reencode = !copy_mode \|\| seg_has_crop;` — `trim-runner.vala:812` |
| Copy-mode lock family | `update_copy_mode_constraints` — `trim-tab.vala:2295`, fed by `update_for_speed` `:2305` |
| Cheap accessor for the General tab's speed state (no full settings snapshot) | `snapshot_speeds_only` — `general-tab.vala:1181` |
| Trim progress is segment-count based, not duration based | `update_progress ((double) i / segments.length …)` — `trim-runner.vala:349` |
| Segments are never serialised | no `segment` key anywhere in `src/app/app-settings.vala` |
| Test harness for real ffmpeg runs against segments already exists | `run_extract_segment_for_widget_test` / `get_last_ffmpeg_argv_for_widget_test` — `trim-runner.vala:1717-1731`, used by `/trim/runner/speed-preserves-segment-range` in `tests/trim-subtitles-state-test.vala:795` |

### Two pre-existing defects this feature must fix

**1. Audio fade-out lands on the wrong clock.**
`audio_filter_duration_for_segment` (`trim-runner.vala:1174`) returns the
*source* span. `merge_profile_audio_filter_chain` appends the processing filters
*after* the profile's own, so `afade` sits downstream of `atempo`
(`audio-processing-settings.vala:238-248` computes `st = duration − fade`).
With the General tab's audio speed at 2× on a 60s segment, the fade-out is
placed at `st=57` on a 30s track and never fires.
`conversion-runner.vala:761-773` already solves exactly this
(`audio_output_duration_seconds`) and documents the reasoning; the trim path
never got the same treatment. Per-segment speed multiplies the exposure, so this
is fixed here.

**2. `TrimSegment` cloning drops fields.**
`trim-tab.vala:542` clones with `new TrimSegment (start, end)` and copies only
`label` and `crop_value` — `ends_at_eof` is silently dropped, so stamping a
global crop onto a through-EOF segment turns it into a zero-length export. A
third field would make this worse; a real `copy()` method ends the class of bug.

## Filter Placement — the part that is easy to get wrong

**Video speed goes at the very END of the segment chain.**
`build_video_filter_chain_for_segment` emits delogo first, because delogo
rectangles are source-frame and its timed regions use `enable='between(t,…)'`
on the segment-local clock. A `setpts` ahead of delogo would rewrite the very
timestamps those intervals are matched against. Appending after everything is
both correct and the only position that needs no compensation elsewhere.

The `,setpts=PTS-STARTPTS` that both paths append afterwards
(`trim-runner.vala:494-498`, `:896-900`) stays where it is — subtracting the
first frame's already-scaled timestamp is exactly right.

**Audio speed goes at the HEAD of the chain, next to the global one.**
It is prepended to the profile's own `audio_filters` before the processing
filters are merged in, so every speed change in the audio chain lives in one
place and the fade compensation is a single rule:

> `afade` runs downstream of every speed filter, so it is handed the duration
> measured on the post-speed timeline: `span / (global × segment)`.

## Phases

### Phase 1 — Data model

`src/ui/trim-tab.vala`, `TrimSegment` (`:9`):

- `public double speed_percent { get; set; default = 0.0; }` — `−99…+100`,
  `0` = unchanged.
- `public bool has_speed_change ()` — true when the percent resolves to a
  multiplier other than 1.0 (goes through the FilterBuilder helper so the
  epsilon and finite checks are shared, not re-implemented).
- `public TrimSegment copy ()` — carries `ends_at_eof`, `crop_value`, `label`,
  `speed_percent`. Replaces the hand-rolled clone at `:542`.

### Phase 2 — FilterBuilder helpers (pure, testable)

`src/encoders/filter-builder.vala`:

- `public double resolve_speed_multiplier (double percent)` — thin public
  wrapper over the existing private `try_get_speed_multiplier`, returning `1.0`
  when the percent is 0, non-finite, or produces a non-positive multiplier.
  Named for a bare percentage rather than for segments, because the Trim tab
  resolves the General tab's percentage through it too when computing an
  effective rate.
- `public bool speed_percent_is_active (double percent)` — the epsilon-aware
  "does this change anything" test, so no caller re-implements it.
- `public string build_setpts_speed_filter (double multiplier)` — `""` at 1.0,
  otherwise `setpts=<1/m>*PTS` with the same `%.6f` formatting the snapshot path
  uses at `:293`, so both emitters produce byte-identical fragments.

### Phase 3 — Video, both export paths

`build_segment_vf` (`trim-runner.vala:998`) appends
`build_setpts_speed_filter (segment_speed_multiplier (seg))` to whatever the
chain builder returned. One edit covers PATH A and PATH B/C, and it also covers
the `build_segment_vf_for_test` hook.

Guard: `build_segment_vf` has an early return for `reencode_profile == null`
(`:999`) — the speed append has to happen on that branch too, since a segment
speed alone can force a re-encode with no other filters set.

### Phase 4 — Audio, both export paths, plus the fade fix

`build_audio_filters_for_segment` (`trim-runner.vala:1143`):

- Prepend the segment's `atempo` chain to `reencode_profile.audio_filters`
  before handing it to `merge_profile_audio_filter_chain`.
- `audio_filter_duration_for_segment` (`:1174`) divides by the **effective**
  audio multiplier (`profile.audio_speed_multiplier × segment multiplier`) on
  both the finite-span branch and the probed through-EOF branch, with the
  reasoning documented the way `conversion-runner.vala:761` documents it.

This automatically corrects the peak-analysis commands too, since
`build_peak_detect_cmd_for_segment` (`:698`) and
`prepare_peak_normalization_for_concat` (`:619`) both build their filters
through the same function — the analysis and the encode stay on one clock.

### Phase 5 — Copy mode and forced re-encode

- Runner: `seg_reencode = !copy_mode || seg_has_crop || seg.has_speed_change ()`
  (`trim-runner.vala:812`). Defensive, and it is what makes separate-file export
  re-encode only the sped segments (`launch_runner` deliberately skips the
  global force in that mode — `trim-tab.vala:582`).
- Launch: the `any_crop` scan at `trim-tab.vala:551-555` also scans for speed,
  so `force_reencode` is true and the re-encode profile gets built (`:624`).
- UI: new `segment_speed_locked` field recomputed from the segment list on every
  rebuild, joining `forced_reencode` in `update_copy_mode_constraints ()`
  (`:2296`).

### Phase 6 — PATH A with mixed speeds

`run_concat_filter_encode` normalises resolution across branches when segments
disagree (`trim-runner.vala:450-471`, `needs_scale_normalize`). Speed introduces
the same hazard on the time axis: `setpts` changes each branch's effective frame
rate, and the concat filter takes its parameters from the first input.

Mirror the existing pattern — when the effective speeds are not all equal, pin
every branch to one frame rate with an `fps=` filter inserted after the speed
`setpts` and before the `setpts=PTS-STARTPTS` reset. The target rate is the
configured output rate when the General tab set one, otherwise the probed source
rate. Log it the way the resolution normalisation is logged at `:470`.

### Phase 7 — UI

`build_segment_row` (`trim-tab.vala:2506`), gated to
`Mode.TRIM_ONLY || Mode.TRIM_AND_CROP`:

- A `%` SpinButton after the end-time entry, before the crop button. Built by a
  helper that mirrors `create_speed_spin` (`general-tab.vala:312`): range
  `−99…+100`, step 1, `digits = 0`, numeric, snap to ticks.
- `SegmentRowBinding` gains `speed_spin` and `on_speed_changed`, following the
  existing binding-object pattern (no closures capturing the index).
- Row subtitle grows a speed indicator alongside the existing crop one, and
  shows the output duration when it differs from the source span:
  `(1:25 → 2:50)  [speed: 0.50×]`, or
  `[speed: 0.50× → 1.00× effective]` when the General tab's speed is also on.
- Segment list total (`:2486-2498`) reports source and output durations when
  they differ.

Both use `general_tab.snapshot_speeds_only ()` — null-guarded, since
`general_tab` is wired by MainWindow after construction.

A speed change refreshes its row in place rather than through
`rebuild_segment_rows ()`, which would destroy the spin button the user is
still holding.

**Staleness.** The effective figure folds in the General tab's speed, and that
tab emits nothing when a percentage changes while staying enabled — its
`video_speed_toggled` / `audio_speed_toggled` signals only fire on effective
on/off transitions. So the summaries are re-rendered from two places:
`update_for_speed` (the toggle) and `sync_general_tab_locks` in
`app-controller.vala` (every switch into the trim tab), through a public
`refresh_segment_speed_display ()`.

### Phase 8 — Smart Optimizer

`trim-tab.vala:978` sets `ctx.video_speed_multiplier` from the General snapshot
alone. Multiply in the segment's multiplier — the optimizer's size and VMAF
estimates are computed against output length, and a 2× segment produces half of
what the estimate assumes.

The temp extract the optimizer analyses is a stream copy at source speed, which
stays correct: only the multiplier needs to reach `OptimizationContext`.

### Phase 9 — Tests

Extend `tests/trim-subtitles-state-test.vala`, next to the existing
`/trim/runner/speed-preserves-segment-range` (`:795`) and using the same
`run_extract_segment_for_widget_test` + `probe_media_duration_seconds` harness:

1. `/trim/runner/segment-speed-scales-both-streams` — a 2s segment at −50% and
   at +100% produces 4s and 1s outputs. Asserted **per stream**, not on the
   container duration: one number covering both streams is exactly what would
   hide a drift between them. Also asserts the run re-encodes (`-c:v libx264`)
   despite `copy_mode = true`, and bounds the input (no `-to`).
2. `/trim/runner/segment-speed-stacks-with-general-tab` — a 0.5× segment under a
   2× global profile comes out at the source span (1.0× effective).
3. `/trim/runner/segment-speed-follows-logo-removal` — the `setpts` fragment
   appears after the `delogo` fragment in `build_segment_vf_for_test`, and
   survives a null re-encode profile.
4. `/trim/segments/copy-preserves-all-fields` — `TrimSegment.copy ()` carries
   `ends_at_eof`, crop, label and speed.

5. `/trim/runner/segment-fade-out-follows-output-timeline` — the regression test
   for the fade fix above. Asserts `st=9.00` unsped, `st=4.00` under a 2× global
   (the case that was silently broken), and `st=1.50` with a 2× segment stacked
   on top. Built from `build_peak_detect_command_for_widget_test`, so it reads
   the real chain without running ffmpeg.

Matroska reports per-stream duration as a `DURATION` tag rather than a stream
field, so `probe_stream_duration_seconds` accepts both forms.

The 0%-still-copies case is asserted on the decision rather than on an export:
stream-copying `test_dvd.vob` into Matroska fails on that asset's unset
timestamps, for reasons unrelated to speed.

### Phase 10 — Audio stream-copy (not in the original plan)

Found while implementing, and load-bearing: `FilterBuilder.merge_audio_filters`
(`filter-builder.vala:603`) **silently drops** the filter chain when the audio
codec is `copy` — the comment there says the UI is responsible for preventing
that pairing. For the General tab's speed the UI does:
`wire_audio_speed_constraint` (`app-controller.vala:812`) takes "Copy" out of
every codec tab's audio list via `AudioSettings.update_for_audio_speed`.

Nothing did that for a segment speed, so a user with audio set to Copy would
have got retimed video against untouched, original-length audio — exactly the
desync this feature exists to prevent, and silent.

`AudioSettings` gains a `segment_speed_active` flag with its own
`update_for_segment_speed (bool)` and a `SEGMENT_SPEED` blocker reason. Separate
from `speed_active` rather than shared, because the two are set by different
controls and either can be on while the other is off — one flag would let one
clear the other's lock. `TrimTab.refresh_segment_speed_lock` drives it across
the four codec tabs, exactly as `update_concat_audio_constraint` does.

## Risk Register

| Risk | Mitigation |
| --- | --- |
| Speed `setpts` landing ahead of delogo breaks timed logo regions | Appended at the tail of `build_segment_vf`; covered by test 3 |
| `atempo` outside 0.5–2.0 | `build_atempo_chain` already decomposes; percent range caps at 0.01×–2× anyway |
| Mixed-speed concat producing judder or A/V drift | Phase 6 fps normalisation |
| Fade-out silently not firing | Phase 4, covered by the existing peak/fade call sites sharing one duration function |
| Audio stream-copy silently dropping the atempo, leaving audio at source length against retimed video | Phase 10 |
| `r_frame_rate` is a timebase, not a display rate — VFR sources report values like 1000/1, and pinning branches to that would encode 1000 fps | `is_plausible_display_fps` bounds it to 1–240 and skips normalization outside that |
| `OptimizationContext` is a struct whose `video_speed_multiplier` starts at 0, its "unset" sentinel — multiplying the segment speed into it keeps it 0 | folded in against an explicit 1.0 |
| A segment speed left in the list holding the audio-copy lock in Crop Only / Chapter Split, which export their own segments | `refresh_segment_speed_lock` is mode-aware and re-runs from `apply_mode` |
| Subtitle streams not retimed by a speed change | Not addressed — see the limitation note at the top |
| Segment speed leaking into Chapter Split / Crop Only | Those modes build their own `segs` at `trim-tab.vala:475` and `:509`; the control is never built for them |
| A through-EOF segment with speed | No `-t` is emitted, `setpts`/`atempo` still apply; the fade branch probes the remaining source duration and divides it like the finite branch |
