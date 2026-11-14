# Agent changelog and handoffs

Shared record of who changed what and why. Read this file and `AUDIT.md` before
starting work; follow the multi-agent workflow in `../AGENTS.md`. Use one task ID
across active work, history and related audit entries. Add history newest first
and preserve earlier entries. Routine log maintenance belongs to its task entry;
it does not require another entry about updating the log.

## Active work

TASK-20261114-release-2.1.1 — Codex (GPT-6), 2026-11-14 America/Phoenix; main at 0195cf5, main checkout. Prepare and publish 2.1.1 to GitHub and AUR, as requested. Owns version constants, release notes, shared logs and AUR package metadata. In progress; build/tests passed, next: publish GitHub tag/release and build/publish AUR package.

When claiming a task, replace the line above with an entry using these fields.
Keep other agents' entries intact; restore the line only when none remain.

```text
Task ID / goal:
Agent / session:
Updated (timestamp and timezone):
Branch / worktree / base revision:
Owned files or scope:
Status: in progress | ready for handoff | blocked | paused
Dependencies / blockers / next action:
```

## History

### TASK-20261114-release-2.1.1 — Version 2.1.1

- **Agent/date/base:** Codex (GPT-6), 2026-11-14 America/Phoenix; main at
  0195cf5. User requested a version bump and release to Git and AUR, with
  simple, human release notes for end users. Selected a patch release.
- **Prepared:** version 2.1.0 → 2.1.1 in `meson.build` and
  `src/util/constants.vala`; user-facing notes in
  [release-notes-2.1.1.md](release-notes-2.1.1.md). Covers all changes since
  v2.1.0: codec settings, startup memory, crash fixes and responsiveness.
- **Validation:** development build succeeds with the same three Vala
  warnings; full suite 30 OK / 0 failures (headless widget skips remain).
  Source archive, with version files overlaid before tagging, builds with
  `arch-meson` and installs to a temporary staging directory, with the
  release binary, desktop entry and icon present. Diff check passes.
- **Publication:** this version commit is intended for tag v2.1.1. GitHub
  release and AUR 2.1.1-1 publication follow; completion recorded below.
  No installation to the user's system or settings changes.

### TASK-20261114-health-publish — Commit and push of the health audit, fixes and reviews

- **Agent/date/base:** Claude Code (Fable 5.2), at the user's request ("Commit
  and push"); 2026-11-14 America/Phoenix (UTC-07:00); `main` at 791ef42.
- **What:** one commit, "Fix a launch-failure crash, cut idle memory and
  unblock the window", then `main` pushed to GitHub. It holds
  TASK-20261114-app-health-audit, -app-health-fix and -health-review-fixes
  (Claude Code) and the log entries of
  TASK-20261114-health-independent-review and -health-fix-recheck (Codex,
  GPT-6).
- **Checks before committing:** read Codex's recheck entry (no new
  findings); `git diff --check` clean. No version bump, no AUR change; the
  installed 2.1.0 keeps HEALTH-F7 until a release.

### TASK-20261114-health-fix-recheck — Verify the cancellation and Combine fixes

- **Agent/date/base:** Codex (GPT-6), 2026-11-14 America/Phoenix; main at
  791ef42 plus Fable’s uncommitted changes, preserved.
- **Result:** no new findings in TASK-20261114-health-review-fixes. Partial
  segment cleanup corrected by source inspection; captured Combine launch
  settings verified by the real GTK race test. See
  AUD-20261114-health-fix-recheck for evidence and limits.
- **Checks:** three focused suites pass, including `combine-launch-snapshot`;
  application build up to date; diff check clean. No automated end-to-end
  cancellation check or full-suite repeat performed.
- **Status:** review complete; shared logs only changed by this reviewer,
  no source edits or commits.

### TASK-20261114-health-review-fixes — Fix the two findings from Codex's review

- **Agent/date/base:** Claude Code (Fable 5.2), at the user's request
  (pointing to Codex's review); 2026-11-14 16:40–16:49 America/Phoenix
  (UTC-07:00); `main` at 791ef42 plus the uncommitted health fixes.
  Uncommitted.
- **Why:** HEALTH-REV-F1 (cancelled or failed segment copies left their
  partial file and temp directory behind) and HEALTH-REV-F2 (Metadata naming
  yielded before the combine launch request was captured) from
  AUD-20261114-health-independent-review. Both were introduced or exposed by
  TASK-20261114-app-health-fix.
- **Changed:** `src/ui/trim-tab.vala` (unlink the segment on every early exit
  of the copy step); `src/ui/combine-window.vala` (request captured at the
  click, naming from a frozen container); `tests/combine-window-state-test.vala`
  (one widget test); `meson.build` (display suite `combine-launch-snapshot`).
- **Checks:** the new test fails against a pre-fix variant and passes with
  the fix; full suite 30 OK / 0 failing; build with the same 3 warnings.
- **Not done:** HEALTH-REV-F1 has no automated test and was not driven
  through the app. Nothing committed.

### TASK-20261114-health-independent-review — Audit the stability and memory fixes

- **Agent/date/base:** Codex (GPT-6), 2026-11-14 America/Phoenix; main at
  791ef42 with Fable’s uncommitted health fixes preserved.
- **Result:** two Medium findings, HEALTH-REV-F1 (cancelled segment copy
  leaves partial media behind) and HEALTH-REV-F2 (Combine captures mutable
  settings after asynchronous metadata naming). Evidence and next actions
  in AUD-20261114-health-independent-review. These are source-level findings;
  the affected UI sequences were not exercised manually.
- **Checks:** full suite 29 OK / 0 failures; application build up to date;
  diff whitespace check passes. No independent performance measurements.
- **Status:** review complete; only shared logs changed by this reviewer,
  uncommitted. Next: fix cleanup on every segment-copy exit and snapshot
  Combine settings before naming yields, with targeted regression coverage.

### TASK-20261114-app-health-fix — Stability, memory and start-up fixes

- **Agent/date/base:** Claude Code (Fable 5.2), at the user's request ("do
  f1, f2, f3, f4, f5, and f6. all of them"); 2026-11-14 16:22–16:36
  America/Phoenix (UTC-07:00); `main` at 791ef42. Uncommitted, together with
  TASK-20261114-app-health-audit.
- **Why:** AUD-20261114-app-health, HEALTH-F1 to HEALTH-F6, and HEALTH-F7
  found while testing the fix for F3.
- **Changed:**
  - `src/util/constants.vala`: `SubprocessCompat.spawnv` binding gains
    `array_length = false` (HEALTH-F7: failed launches segfaulted).
  - `src/app/main.vala`: non-homogeneous view stack; tabs join their page on
    first visit; heap trim requested when an operation or the Smart Optimizer
    ends.
  - `src/ui/trim-tab.vala`: asynchronous, cancellable segment copy.
  - `src/util/ffprobe-utils.vala`: `run_capture_with_timeout`;
    `run_ffprobe_sync` uses it. `src/runners/subtitles-runner.vala`: both
    probes use it; four thread starts report failure.
  - `src/ui/combine-window.vala`: Metadata naming resolves asynchronously;
    heap trim after the preview closes.
  - `src/ui/general-tab.vala`, `src/ui/subtitles-tab.vala`,
    `src/util/heap-trim.vala`: thread starts report failure.
  - `meson.build`: `heap-trim.vala` added to the combine-window test target.
  - `tests/ffprobe-utils-test.vala`: two capture tests.
- **Results:** idle private memory 136 → 103 MB and RSS 305 → 255 MB with a
  warm shader cache; start-up about 0.9 → 0.73 s. A nonexistent FFmpeg path
  no longer crashes the app.
- **Rejected:** building the codec tabs on first use (would save about
  8.6 MB each, but every builder, preset, folder and trim path that reads
  their widgets would have to cope with an unbuilt tab); a watchdog thread
  per probe (the private main context needs no extra thread).
- **Checks:** development build, same 3 Vala warnings; full suite 29 OK / 0
  failing, twice; real launches with isolated settings for memory, start-up
  and the bad-path case. Details and limits in the audit follow-up.
- **Not done:** nothing exercised by hand in the window; not committed. The
  installed 2.1.0 still has HEALTH-F7 until a release is cut.

### TASK-20261114-app-health-audit — Stability, memory and performance audit

- **Agent/date/base:** Claude Code (Fable 5.2), at the user's request;
  2026-11-14 16:10–16:18 America/Phoenix (UTC-07:00); `main` at 791ef42.
  Investigation only; no code changed. Uncommitted: this entry and
  AUD-20261114-app-health in `docs/AUDIT.md`.
- **Result:** the app is idle-quiet (no CPU while idle, about 0.9 s to start)
  and most process, console and shutdown handling is sound. Six findings,
  HEALTH-F1 to HEALTH-F6: a main-thread blocking FFmpeg copy in Crop & Trim's
  Smart export (Medium); 131 MB of idle heap from building every tab at
  startup (Medium, design); four Low items.
- **Checks:** the existing development binary was run with isolated XDG and
  temp directories and closed again; no build, no tests. No detailed report
  file was written; everything is in the audit entry.
- **Next steps:** HEALTH-F1 is a contained change (run the copy through an
  asynchronous subprocess with the export's cancellable). HEALTH-F2 needs a
  per-tab measurement before choosing between building tabs on first visit
  and building only the dropdown-heavy groups late. Loaded-file, playback and
  encode-time memory still need measuring by hand.

### TASK-20261114-x264-publish — Commit and push of the x264 audit, fixes and reviews

- **Agent/date/base:** Claude Code (Fable 5.2), at the user's request ("commit
  and push"); 2026-11-14 America/Phoenix (UTC-07:00); `main` at 4760b73.
- **What:** one commit, "Make the x264 tab's settings apply as labelled", then
  `main` pushed to GitHub. It holds TASK-20261114-x264-settings-check,
  -settings-fix and -crf0-subtitle (Claude Code) and the log entries of
  TASK-20261114-x264-independent-review and -crf0-recheck (Codex, GPT-6).
- **Checks before committing:** read Codex's recheck entry (no new findings);
  `git diff --check` clean. No version bump, no AUR change.

### TASK-20261114-x264-crf0-recheck — Verify the corrected lossless guidance

- **Agent/date/base:** Codex (GPT-6), 2026-11-14 America/Phoenix; main at
  4760b73 with the existing uncommitted changes preserved.
- **Result:** reviewed Fable’s TASK-20261114-x264-crf0-subtitle; no new
  findings. X264-REV-F1 independently verified fixed through seven synthetic
  bit-depth/profile checks and decoded sample hashes. Details in
  AUD-20261114-x264-crf0-recheck.
- **Scope/status:** completed; shared review logs only, no implementation
  edits or commits. Diff check passes. No repeat build/suite run for the
  wording-only correction, and no manual visual inspection.

### TASK-20261114-x264-crf0-subtitle — CRF 0 is lossless at 8 bit only

- **Agent/date/base:** Claude Code (Fable 5.2), at the user's request
  (pointing to Codex's review); 2026-11-14 America/Phoenix (UTC-07:00);
  `main` at 4760b73 plus the uncommitted x264 changes. Uncommitted.
- **Why:** X264-REV-F1 from AUD-20261114-x264-independent-review. Reproduced:
  10-bit CRF 0 stays ordinary CRF and is lossy; 10-bit QP 0 is lossless.
- **Changed:** `src/encoders/x264-tab.vala`, CRF and QP subtitles only.
  `docs/AUDIT.md`: follow-up under the review entry; X264-REV-F1 removed from
  the unresolved index.
- **Checks:** development build exit 0, same 3 Vala warnings; three focused
  suites pass. Subtitle not viewed in the running app.
- **Status:** done. Nothing committed.

### TASK-20261114-x264-independent-review — Review of Fable 5.2’s x264 work

- **Agent/date/base:** Codex (GPT-6), 2026-11-14 America/Phoenix; main at
  4760b73, main checkout with Fable’s uncommitted changes preserved.
- **Result:** one Medium finding, X264-REV-F1: CRF 0 is lossy at 10 bit,
  contrary to the new subtitle. Four synthetic control encodes and decoded
  sample hashes establish the distinction from QP 0. Details and correction
  to the prior audit claim are in AUD-20261114-x264-independent-review.
- **Checks:** focused suites 4 OK / 0 failures, including real GTK execution
  of the x264 defaults test; application build up to date; seven additional
  synthetic encoder checks passed; diff whitespace check passed. Full suite,
  VMAF measurements and manual visual checks not repeated.
- **Changes/status:** only review entries in the two shared logs; no source
  edits or commits. Review complete; next action is correcting the CRF
  guidance and its audit documentation, then checking the resulting text.

### TASK-20261114-x264-settings-fix — x264 settings apply as labelled

- **Agent/date/base:** Claude Code (Fable 5.2), at the user's request ("Fix
  all 8"); 2026-11-14 15:21–15:30 America/Phoenix (UTC-07:00) by the system
  clock; `main` at 4760b73. Uncommitted, together with
  TASK-20261114-x264-settings-check.
- **Why:** AUD-20261114-x264-settings, X264-F1 to X264-F8.
- **Changed:**
  - `src/encoders/x264-builder.vala`: `cabac=0` / `mbtree=0` replace the
    valueless flags; `ref`, `bframes`, `b-adapt`, `deblock`, `me` and `psy-rd`
    are sent only when changed from x264's defaults or turned off; subme 10
    and 11 add `trellis=2`; new `psy_differs_from_default` and
    `smart_tuning_params`.
  - `src/encoders/x264-tab.vala`: Reference Frames "Auto" (default on build
    and reset); Level 6, 6.1, 6.2; subtitles for CRF, QP, Tune, Level, ME
    algorithm, Search Range, Subpixel Refinement, Reference Frames, B-Frames,
    B-Frame Adaptation, Deblock and Psy.
  - `src/optimizer/smart-optimizer-logic.vala`: `EncoderTuning` carries x264
    psy-trellis, deblock offset and subme 10/11; `x264_psy_trellis_for_effort`;
    tuning key and doc comment updated.
  - `src/encoders/smart-codec-resolver.vala`: `resolve_x264` takes psy-trellis
    and deblock from the tuning. `src/encoders/codec-utils.vala` (trim direct
    args) and `src/optimizer/smart-optimizer.vala` (calibration) send the
    same tuning parameters. `smart-optimizer-cache.vala`: version 5 → 6.
  - `tests/combine-window-state-test.vala`: five x264 tests; x264 golden
    digests 0–9 updated and each checked against its legacy digest; the
    effort-policy assertion expects `trellis=2` beside `subme=11`.
- **Behaviour changes to know:** an untouched x264 tab now follows the preset
  and tune exactly. Smart Codec anime and screencast encodes keep the tune's
  psy and deblock. High and maximum effort calibration probes for x264 take
  about twice as long, in exchange for about 1.5–2.5% size drift instead of
  about 7%. Cached optimizer samples from v5 are not reused.
- **Rejected:** Auto entries for B-frames, adaptation and ME (more UI; the
  x265 fix set the same precedent); subtitle-only for subme 10/11 (Smart
  Codec's top two efforts would stay identical to subme 9); blocking lossless
  or out-of-level encodes in the app (x264 already reports both).
- **Checks:** development build exit 0, the same 3 pre-existing Vala
  warnings; full suite 27 OK / 2 failing, then 28 / 1 on re-running the two:
  `bulk-playback` passed the second time, `preview-fullscreen-state` also
  fails at 4760b73 in a clean worktree (BASELINE-F2). The new widget test ran,
  not skipped. Real x264 encodes confirmed each new argument string.
- **Not done:** app window not opened; not committed or pushed. A release
  would need the AUR package only after a version bump, which was not asked
  for.

### TASK-20261114-x264-settings-check — Check that x264 settings reach the encoder

- **Agent/date/base:** Claude Code (Fable 5.2), at the user's request ("audit
  x264 tab settings like how av1, x265, and vp9 was done"); 2026-11-14
  15:01–15:06 America/Phoenix (UTC-07:00) by the system clock; `main` at
  4760b73. Investigation only; no code changed. Uncommitted: this entry and
  AUD-20261114-x264-settings in `docs/AUDIT.md`.
- **Result:** most settings apply as labelled. Eight findings are recorded as
  open and unassigned in AUD-20261114-x264-settings:
  - X264-F1 (High): CABAC off, MB-Tree off, Profile Baseline and Tune
    fastdecode send a valueless `no-cabac` / `no-mbtree`, which either stops
    FFmpeg from starting or silently drops that flag and the next parameter.
  - X264-F2, X264-F3 (Medium): the always-sent tab defaults undo most of what
    presets and tunes change; zerolatency gets B-frames back.
  - X264-F4 (Medium): Smart Codec's final x264 arguments differ from what
    calibration measured (−18% to +10% size on one clip).
  - X264-F5 to X264-F8 (Low): subme 10/11, search range above 16, Level and
    lossless do less than, or something other than, the tab says.
- **Checks:** FFmpeg 9.0.2 / x264 core 165 runs only, reading x264's applied
  option line. No build and no tests were run (no code changed). The app was
  not opened.
- **Next steps:** X264-F1 has a tested replacement (`cabac=0`, `mbtree=0`) and
  needs a builder test. X264-F2 and X264-F3 need the same decision x265 got in
  TASK-20261110-x265-settings-fix (send a value only when it differs from the
  encoder default, or add Auto entries); that changes Smart Codec x264 golden
  digests and needs an optimizer cache version bump. Re-measure X264-F4 after
  that. X264-F5 to X264-F8 are subtitle or range changes.

### TASK-20261110-vp9-libvpx-independence — VP9 settings no longer assume libvpx 1.17

- **Agent/date/base:** Claude Code (Opus 5.5), at the user's request ("Yes,
  fix both", then "Let libvpx decide"); 2026-11-10 10:42–10:46
  America/Phoenix (UTC-07:00); `main` at 6bc1554 (pushed). Committed on its
  own as "Stop VP9 settings depending on libvpx 1.17 defaults" and pushed.
- **Why:** REV-F1 and REV-F2 from AUD-20261110-pre-push-review: Frame
  Parallel "on" relied on libvpx's default, and the Speed cap hardcoded libvpx
  1.17's Good/Best behaviour.
- **Changed:**
  - `src/encoders/vp9-builder.vala`: always sends `-frame-parallel 1` or `0`;
    removed `max_speed_for_deadline` and the `-cpu-used` clamp.
  - `src/encoders/vp9-tab.vala`: Speed range back to a fixed 0–8 with a
    subtitle noting libvpx 1.17's behaviour; removed the deadline-dependent
    range.
  - `src/encoders/codec-presets.vala`: `apply_smart_vp9` back to its original
    order (now identical to before TASK-20261110-vp9-settings-fix).
  - `src/encoders/codec-utils.vala` (trim tab's direct Smart args) and
    `src/optimizer/smart-optimizer.vala` (VP9 calibration): send
    `-frame-parallel 1`. `smart-optimizer-cache.vala`: format version 4 → 5.
  - `tests/combine-window-state-test.vala`: VP9 builder tests rewritten for
    pass-through speed and explicit frame parallel; widget test renamed
    `/smart-codec/widgets/vp9-tab-follows-two-pass`; policy assertion expects
    `-frame-parallel 1`; VP9 golden digests 20–29 updated, each checked by
    removing that argument pair to reproduce the digest it replaces.
- **Rejected:** a startup probe of libvpx's speed behaviour (the user chose
  simplicity; every current Arch user is on 1.17.0).
- **Checks:** development build, same 3 pre-existing Vala warnings; full
  suite 29 OK, 0 failing, 740 subtests, 137 headless skips ("GTK could not
  initialize"); the widget tests, including golden parity, ran in the display
  suites. Real encode logged `CPUUSED 8` and `FRAME_PARALLEL_DECODING 1`.
- **Not done:** app window not opened by hand.

### TASK-20261110-pre-push-review — Review before pushing the x265 and VP9 fixes

- **Agent/date/base:** Claude Code (Opus 5.5), at the user's request;
  2026-11-10 10:36 America/Phoenix (UTC-07:00); `main` at f149e7d, reviewing
  `origin/main..main`. Committed on its own as "Record the pre-push review of
  the x265 and VP9 fixes", then `main` pushed to GitHub.
- **Result:** no bug in the shipped configuration; seven low-severity
  findings, REV-F1 to REV-F7, recorded in AUD-20261110-pre-push-review.
- **Also corrected:** the TASK-20261110-vp9-settings-fix time range and its
  audit follow-up timestamp, which were written ahead of the real clock; they
  now match the 10:33 commit.
- **Next steps:** REV-F1 (explicit `-frame-parallel 1`) and REV-F2 (speed cap
  tied to libvpx version) are the most worthwhile if the app must support
  other libvpx builds.

### TASK-20261110-vp9-settings-fix — VP9 tab shows what libvpx actually does

- **Agent/date/base:** Claude Code (Opus 5.5), at the user's request ("Yes,
  fix all 4"); 2026-11-10 10:28–10:33 America/Phoenix (UTC-07:00); `main` at
  cec0a59. Committed together with TASK-20261110-vp9-settings-check as "Make
  the VP9 tab match what libvpx applies"; not pushed.
- **Why:** AUD-20261110-vp9-settings found four settings that do less than the
  tab says (VP9-F1 to VP9-F4). No encoder argument was wrong.
- **Changed:**
  - `src/encoders/vp9-tab.vala`: Alt-Ref and Lookahead dim while Two-Pass is
    off; Speed's range follows the deadline (0–5 Good/Best, 0–8 Realtime);
    Frame Parallel starts on (build and reset); subtitles for Speed, Content
    Type, Lookahead, Alt-Ref and Frame Parallel say what applies.
  - `src/encoders/vp9-builder.vala`: `max_speed_for_deadline` clamps
    `-cpu-used`; Frame Parallel sends only `-frame-parallel 0` when off;
    snapshot `frame_parallel` defaults to true.
  - `src/encoders/smart-codec-resolver.vala`: `resolve_vp9` keeps frame
    parallel on (libvpx's default, what it always encoded with).
  - `src/encoders/codec-presets.vala`: `apply_smart_vp9` sets the deadline
    before Speed, so the clamped widget value matches the resolver.
  - `tests/combine-window-state-test.vala`: `/combine/vp9/speed-follows-deadline`,
    `/combine/vp9/frame-parallel-off-is-sent`,
    `/smart-codec/widgets/vp9-tab-follows-two-pass-and-deadline`; the
    full-effort policy assertion now expects frame parallel on and no argument.
- **Rejected:** not sending alt-ref/ARNR/lag in single pass (no output
  difference, but it would change Smart Codec goldens); changing Smart
  Optimizer's `VP9_CPU_USED` table (calibration and final already encode
  identically); dropping Smart Codec's Screen choice (inert, harmless).
- **Checks:** development build, same 3 pre-existing Vala warnings; new tests
  pass; full suite 29 OK, 0 failing, 740 subtests, 137 skipped in headless
  suites ("GTK could not initialize"; the new widget test ran in
  `smart-codec-widgets`). Smart Codec golden digests unchanged.
- **Not done:** the app window was not opened by hand; not pushed.

### TASK-20261110-vp9-settings-check — Check that VP9 settings reach the encoder

- **Agent/date/base:** Claude Code (Opus 5.5), at the user's request ("check
  vp9 now like you did for av1 and x265"); 2026-11-10 10:25 America/Phoenix
  (UTC-07:00); `main` at cec0a59. Investigation only; no code changed.
  Committed with TASK-20261110-vp9-settings-fix.
- **Result:** every VP9 option reaches libvpx as labelled, but four settings
  do less than the UI says. Recorded as open, unassigned findings in
  AUD-20261110-vp9-settings: alt-ref, ARNR and lookahead are inert in
  single-pass (VP9-F1); Frame Parallel Decoding cannot be turned off (VP9-F2);
  Speed 6–8 equal 5 with Good (VP9-F3); Content Type Screen is inert with Good
  (VP9-F4).
- **Next steps:** VP9-F2 is a one-line builder fix (send `-frame-parallel 0`
  when off), but it changes default output and Smart Codec goldens, so it
  needs a decision on the default. VP9-F1, F3 and F4 are UI and labelling
  decisions; no encoder argument is wrong.

### TASK-20261110-x265-calibration-tools — X265-F4 kept as a documented trade-off

- **Agent/date/base:** Claude Code (Opus 5.5), at the user's request ("fix
  that now"), then the user's decision ("keep the trade off"); 2026-11-10
  10:00–10:15 America/Phoenix (UTC-07:00); `main` at 123cb61. Committed on
  its own as "Keep x265 calibration trade-off and record re-measurement";
  not pushed.
- **What happened:** before implementing, the `EncoderTuning` doc comment
  turned out to record leaving reference count out of calibration as a
  measured decision, which X265-F4 had missed. A re-measurement (one clip,
  details in AUD-20261110-x265-settings) put medium and high effort inside the
  documented ±2%, and max effort at +2.7% size / +0.57 VMAF for ×1.5 probe
  encode time. The user chose to keep the trade-off.
- **Changed:** comment only, in `src/optimizer/smart-optimizer-logic.vala`
  (re-measurement and decision). `docs/AUDIT.md`: X265-F4 corrected and set
  to deferred. No behaviour change.
- **Also corrected:** the TASK-20261110-x265-settings-fix time range and
  its audit follow-up timestamp, which had been written ahead of the real
  clock; they now match the 10:09 commit.
- **Checks:** development build after the comment edit: exit 0, the same 3
  pre-existing Vala warnings, no errors. Tests not re-run (comment-only code
  change).
- **Status:** done; nothing remains for X265-F4 unless calibration cost changes.

### TASK-20261110-x265-settings-fix — x265 Level, Tune and Reference Frames apply as labelled

- **Agent/date/base:** Claude Code (Opus 5.5), at the user's request ("fix all
  3"); 2026-11-10 09:55–10:09 America/Phoenix (UTC-07:00); `main` at 5cc5052.
  Committed together with TASK-20261110-x265-settings-check as "Fix x265
  Level, Tune and Reference Frames settings"; not pushed.
- **Why:** AUD-20261110-x265-settings found that Level was ignored (X265-F1),
  Tune was partly undone by always-sent psy-rd and deblock (X265-F2), and
  Reference Frames always overrode the preset (X265-F3).
- **Changed:**
  - `src/encoders/x265-builder.vala`: Level is sent as `level-idc=N:high-tier=0`
    and `-level:v` is gone. Deblock and psy-rd are sent only when changed from
    x265's defaults or turned off (new `psy_rd_differs_from_default`).
    Reference Frames "Auto" or unset sends no `ref`.
  - `src/encoders/x265-tab.vala`: "Auto" is first in Reference Frames and is the
    default on build and reset; the Reference Frames, Deblock and Psy-RD
    subtitles explain the defaults.
  - `src/optimizer/smart-optimizer.vala`: x265 calibration uses the same psy-rd
    rule, so it measures the final arguments.
    `src/optimizer/smart-optimizer-cache.vala`: format version 3 → 4.
  - `tests/combine-window-state-test.vala`: three `/combine/x265/` tests; the
    SVT helper renamed to `assert_codec_param_key_absent`; Smart Codec golden
    digests for x265 cases 10–15 updated, with the check that explains them
    recorded beside the table.
- **Behaviour changes to know:** a level too low for the picture now fails the
  encode with x265's own error instead of being ignored. Smart Codec anime at
  low effort now gets the animation tune's psy-rd and deblock, and fastdecode
  gets its deblock-off. Cached optimizer samples from v3 are not reused.
- **Rejected:** a three-state Auto control for psy-rd and deblock (more UI for
  little gain), and changing `X265BuilderSnapshot` field defaults (an existing
  folder test relies on them, and no live path uses them unedited).
- **Checks:** development build, same 3 pre-existing Vala warnings in the app;
  new tests pass; full suite 29 OK, 0 failing, 735 subtests, 136 skipped in
  headless suites ("GTK could not initialize"); real x265 4.3 encode with the
  new defaults confirmed level, tier, preset references and the tune's
  psy-rd/deblock. x264 `-level:v` confirmed working, left unchanged.
- **Not done:** UI not run; not pushed. X265-F4 (calibration lacks Smart
  Codec's references, PMode and deblock offsets) recorded, unassigned.

### TASK-20261110-x265-settings-check — Check that x265 settings reach the encoder

- **Agent/date/base:** Claude Code (Opus 5.5), at the user's request ("do a
  check of x265 to make sure its settings work"); 2026-11-10 09:50
  America/Phoenix (UTC-07:00); `main` at 5cc5052. Investigation only; no code
  changed. Committed with TASK-20261110-x265-settings-fix.
- **Result:** most settings apply as labelled. Three issues are recorded as
  open, unassigned findings in AUD-20261110-x265-settings: Level is ignored
  (X265-F1), Tune is partly overridden by the always-sent psy-rd and deblock
  values (X265-F2), and Reference Frames always overrides the preset (X265-F3).
- **Next steps:** X265-F1 has a tested replacement (`level-idc=N:high-tier=0`).
  X265-F2 and X265-F3 need a decision on when the app should send these values
  before changing the builder.

### TASK-20261110-svt-variance-boost — SVT-AV1 "Variance" AQ now enables Variance Boost

- **Agent/date/base:** Claude Code (Opus 5.5), at the user's request ("make the
  change / fix"); 2026-11-10 09:10 America/Phoenix (UTC-07:00); `main` at
  e278ace, on the checked-out branch as the user chose. Committed on its own
  as "Make SVT-AV1 "Variance" AQ enable Variance Boost"; not pushed.
- **Why:** AQ Mode "Variance" sent `aq-mode=1` plus Variance Boost. SVT-AV1 4.2
  turns the boost off in that combination and treats `aq-mode=1` as
  experimental, so the option gave neither what it promised nor a working AQ
  Strength. Details and evidence: AUD-20261110-svt-variance-boost (SVT-F1).
- **Changed:** `src/encoders/svt-av1-builder.vala`: "Variance" sends only
  `enable-variance-boost=1:variance-boost-strength=N`; other AQ choices
  unchanged. `tests/combine-window-state-test.vala`: new test
  `/combine/svt-av1/aq-variance-enables-variance-boost` covering all four
  choices.
- **Rejected:** sending `aq-mode=2` with the boost. It turns QP mode into CRF
  (byte-identical output in testing). Also kept the "Variance" label, which
  other code compares by text.
- **Checks:** development build with no new Vala warnings; the new test fails
  on the old builder and passes on the fix; full suite 29 OK, 0 failing (136
  widget subtests skipped in headless suites with "GTK could not initialize";
  the display suites ran). Real FFmpeg/SVT-AV1 encodes confirmed the boost is
  active with the new arguments.
- **In-app check (follow-up):** the user's own conversion from the rebuilt app
  with "Variance" (CRF) showed the boost active and no warnings; see the
  follow-up in AUD-20261110-svt-variance-boost.
- **Not done:** QP and VBR not run from the UI; not pushed. SVT-F2 (QP + "Complexity" behaves
  as CRF) recorded, unassigned, not changed.

### TASK-20261109-user-bulk-testing — User-reported manual testing of folder features

- **Agent/date/base:** Recorded by Claude Code from the user's statement;
  2026-11-09 20:40 America/Phoenix (UTC-07:00); `main` at a4bcaaa (v2.1.0).
- **Status:** Record only; documentation, committed and pushed on its own. No code change.
- **Report:** The user has done heavy manual testing of folder (bulk)
  conversion on their desktop and reports that it worked well, including the
  new input and output playback and folders in Recently Opened.
- **Standing:** User-reported, not agent-verified. No counts, media details,
  build identity or steps were given, and none are inferred here. See
  AUD-20261109-user-bulk-testing for what this does and does not close.

### TASK-20261109-release-2.1.0 — Version 2.1.0 release

- **Agent/date/base:** Claude Code, at the user's request ("if you deem it in a
  good state for a release, bump version number, push release to git / aur");
  2026-11-09 20:30 America/Phoenix (UTC-07:00); `main`, base baa9504.
- **Status:** Version bumped 2.0.1 → 2.1.0 in `meson.build` and
  `src/util/constants.vala` (kept in sync). This commit is tagged `v2.1.0`;
  the GitHub release and the AUR update follow from the tag.
- **Readiness checks (before the bump, at baa9504):** development build with
  no Vala errors; full suite 29 OK, 0 failing; `git archive HEAD` configured
  with `arch-meson`, compiled and installed to a scratch destination
  (binary, desktop file, icon).
- **Known limits carried into the release:** open findings in AUDIT.md, none
  blocking: SO-F1's knee stop is unit-tested only; SO-F11 is partly fixed and
  its original failing range was not re-run; bulk playback has had no manual
  desktop or screen-reader pass; SO-F4 to SO-F14 are design or tuning items.
- **Contents since v2.0.1:** folder conversion, per-file Smart Optimizer
  settings, folder history, bulk playback, and the Quality Mode measurement
  fixes.

### TASK-20261109-resources-screenshot-history — Consolidate the screenshot commits

- **Agent/date/base:** Codex, 2026-11-09 20:00 America/Phoenix (UTC-07:00), main at 500388d.
- **Change:** With the user's approval, combined the two screenshot commits
  into one gallery addition containing the newer capture. The original
  screenshot blob is absent from the replacement commit's ancestry.
- **Validation:** Checked the replacement tree and its parent, confirmed the
  gallery image matches the supplied replacement, and checked whitespace.
  The entries below preserve the record of the initial addition and swap.

### TASK-20261109-resources-screenshot-swap — Replace the conversion resource screenshot

- **Agent/date/base:** Codex, 2026-11-09 19:56 America/Phoenix (UTC-07:00), main at 91caa5c.
- **Change:** Replaced the gallery image with the newer capture supplied by the
  user. The gallery continues to use the same asset path and caption.
- **Validation:** Inspected the PNG, compared the replacement byte for byte,
  and verified the README reference. Documentation change packaged in the
  accompanying commit for origin/main.

### TASK-20261109-resources-screenshot — Conversion resource-usage screenshot

- **Agent/date/base:** Codex; 2026-11-09 19:53 America/Phoenix (UTC-07:00);
  main, project worktree, f073661; clean at start.
- **Scope/status:** User requested adding the supplied screenshot to GitHub's
  screenshot section. Added Screenshots/Screenshot-System-Resources-Conversion.png
  and a labelled README gallery cell with descriptive alt text, caption and
  full-size image link. Included in this documentation commit for origin/main.
- **Validation:** Inspected the supplied image; copied it byte-for-byte without
  alteration. Verified README paths, whitespace and remote-base alignment.
  No application changes or build/tests needed for this documentation-only update.
- **Handoff:** No outstanding implementation work; final response records the
  commit and push verification. Original screenshot remains unchanged.

### TASK-20261109-bulk-playback-publish — Commit and push of bulk playback with its review fixes

- **Agent/date/base:** Claude Code, at the user's request; 2026-11-09 19:40
  America/Phoenix (UTC-07:00); `main`, base e11be84.
- **Status:** Complete. One commit on `origin/main`, "Add searchable playback
  for bulk inputs and outputs", which also adds this entry.
- **Contents:** TASK-20261109-bulk-playback-design, -plan and -implementation
  (Codex) together with TASK-20261109-bulk-playback-review and -fixes (Claude
  Code). The fixes edit the same new files as the implementation, so the two
  were not split; the commit carries both co-author trailers.
- **Notes:** Codex's three entries below still read "uncommitted" and are left
  as written; this entry supersedes that. Author identity was passed per
  commit, as before, without changing Git settings.
- **Validation:** The committed tree is the one validated in
  AUD-20261109-bulk-playback-fixes (full suite 29 OK, archive simulation,
  scratch run). Nothing was re-run after staging.

### TASK-20261109-bulk-playback-fixes — Fixes for the bulk playback review findings

- **Agent/date/base:** Claude Code, at the user's request; 2026-11-09 19:35
  America/Phoenix (UTC-07:00); main at e11be84 plus Codex's uncommitted
  TASK-20261109-bulk-playback-implementation.
- **Status:** Complete; committed and pushed with the implementation (see
  TASK-20261109-bulk-playback-publish). No installation or version bump.
- **Changes/why (BPLAY-F2 to BPLAY-F5):**
  - `meson.build`: the `bulk-playback-test` target is guarded with `fs.exists`
    so archives without `tests/` configure again.
  - `bulk-conversion.vala`: a run that reuses its queue emits `queue_replaced`,
    so the window's list holds the controller's items again after a preview
    replaced them.
  - `bulk-playback-model.vala`: new `recheck_unavailable ()` re-examines only
    rows that failed a file check. `main.vala` calls it when the window becomes
    active in folder mode and when a playback dialog is opened.
  - `playback-launcher.vala`: the two fallback warnings are back.
  - `bulk-playback-view.vala`: status text wraps again; row buttons are
    labelled "Input" and "Output"; Enter in the search field plays the top
    match when nothing is selected.
  - `AGENTS.md`: `bulk-playback` added to the test table.
  - `tests/bulk-playback-test.vala`: regression steps for the reused queue,
    the recheck, Enter-to-play and the fallback warnings.
- **Decision:** unavailable rows are still removed from the lists on a failed
  check, as Codex designed; they are rechecked rather than left playable.
- **Validation:** Development build; full suite 29 OK, 0 failing; details in
  AUD-20261109-bulk-playback-fixes.
- **Limits/handoff:** No manual desktop pass. Wrapped status text was not seen
  rendered with a long message. The implementation and these fixes are both
  uncommitted and belong in one commit or two adjacent ones.

### TASK-20261109-bulk-playback-review — Independent review of bulk playback

- **Agent/date/base:** Claude Code, at the user's request; 2026-11-09 19:16
  America/Phoenix (UTC-07:00); main at e11be84 plus Codex's uncommitted
  TASK-20261109-bulk-playback-implementation.
- **Status:** Review complete; only AUDIT.md and this entry changed. Committed
  and pushed with TASK-20261109-bulk-playback-publish. No source, test or
  build-file change in this task.
- **Result:** Build and the 29-suite run reproduce. Four findings recorded as
  BPLAY-F2 to BPLAY-F5 in AUD-20261109-bulk-playback-review. BPLAY-F2 (release
  archives fail to configure because the new test target is unguarded) and
  BPLAY-F3 (list goes stale after the output field is edited and restored)
  should be fixed before this work is committed or released.
- **Handoff:** Findings unassigned. The implementation task's own entry below
  is unchanged and still reads "no unresolved functional defect"; this entry
  and the audit entry supersede that for the two items above.

### TASK-20261109-bulk-playback-implementation — Searchable playback for bulk inputs and outputs

- **Agent/date/base:** Codex; 2026-11-09 19:04 America/Phoenix (UTC-07:00);
  main, project worktree, e11be84. Preserved the existing uncommitted plan/design notes.
- **Status:** Implementation and automated validation complete; local/uncommitted.
  No installation, version bump, commit or push. Native assistive-technology and
  network-storage checks remain manual limits, recorded in the plan and AUDIT.md.
- **Behavior:** Existing input/output playback actions open a bounded searchable
  dialog in folder mode. Each bulk row offers direct input/output playback;
  completed primary videos appear live and remain playable after cancellation.
  Existing ffplay/default-player preference and fallback are shared with single-file
  playback. No input switch or queue/settings mutation occurs when a video plays.
- **Implementation:** New shared launcher, batch presentation model and reusable
  row/dialog modules. MainWindow consumes explicit queue/item signals and uses
  Gtk.ListView instead of rebuilding every row. Counts and notifications are
  coalesced; async file checks are cancelled by batch changes and close/Escape.
  Updated Meson sources/target, README, smoke checklist and both bulk plans.
- **Validation:** Development build succeeds (same three existing Vala warnings).
  Full suite 29 OK, zero failures. Final tooltip/close refinements then passed the
  development build and three relevant suites again. New six-case bulk-playback
  suite has real MainWindow, synthetic x264 cancellation/output retention and
  actual ffplay/desktop fallback coverage, all running on Wayland without skips.
- **Scale/layout:** 1,000 entries use 205 reusable rows in both lists; a single
  update creates no rows. Selection/scroll persistence and narrow dialog rendering
  pass. Search at 200 entries measured 57–115 ms including 50 ms typing delay;
  sub-100-ms latency is a tuning target, not a consistent guarantee under load.
- **Handoff/evidence:** See [battleplan](bulk-playback-battleplan.md) and the matching
  audit entry for scope and limits. Logs: /tmp/ffgtk-bulk-playback-full-suite.log,
  /tmp/ffgtk-bulk-playback-final-build.log, /tmp/ffgtk-bulk-playback-final-tests.log.
  Rendered layout evidence: /tmp/ffgtk-bulk-playback-visuals/. All media/settings/
  cache/temp/desktop-handler fixtures isolated. RECENT-F1 remains open for its
  recent-folder-specific cases; new playback coverage does not close those.

### TASK-20261109-bulk-playback-plan — Scalable bulk playback battleplan

- **Agent/date/base:** Codex; 2026-11-09 18:22 America/Phoenix (UTC-07:00);
  main, project worktree, e11be84.
- **Status/scope:** Requested Markdown plan complete; documentation only,
  uncommitted. Preserved the preceding uncommitted playback-design records.
- **Deliverable:** [Bulk playback battleplan](bulk-playback-battleplan.md) specifies
  the searchable input/output dialog, direct row playback, stable model updates,
  reusable rows, lifecycle/eligibility rules, six implementation phases and
  acceptance tests for 200-video batches plus a 1,000-entry stress check.
- **Checks/limits:** Compared integration points with current sources; checked
  local document links and whitespace. No application changes, build, tests,
  installation or publication. Performance targets are proposed, not measured.
- **Handoff:** Implementation has not started. See the plan's checklists and
  matching AUDIT.md entry; preserve the existing launcher behavior and queue state.

### TASK-20261109-bulk-playback-design — Bulk input/output playback feasibility

- **Agent/date/base:** Codex; 2026-11-09 18:19 America/Phoenix (UTC-07:00);
  main, project worktree, e11be84.
- **Status/scope:** Design investigation complete; shared notes only, uncommitted.
  No playback implementation or publication requested/performed in this task.
- **Recommendation:** Let users play an individual bulk item's input or completed
  video through the existing ffplay/default-player launcher. Per-row controls are
  the simplest mapping; existing View Input/Output menu actions could open a file
  chooser list scoped to the batch. Preserve folder selection and conversion state.
- **Evidence/limits:** Source review only; no new build/runtime tests. See the
  matching AUDIT.md entry for readiness checks, output-artifact distinctions and
  follow-up test cases. Modest UI/state integration, with no encoder redesign.

### TASK-20261109-recent-folders-publish — Publish folder history and its audit

- **Agent/date/base:** Codex; 2026-11-09 18:11 America/Phoenix (UTC-07:00);
  main, project worktree, base 7242896.
- **Scope/status:** User requested commit and push of the completed folder-history
  implementation, tests, documentation and audit. All nine reviewed files are
  included in the accompanying feature commit. This publication follow-up
  supersedes the earlier entries' local-only status; their original evidence stays.
- **Checks:** Refreshed origin/main; it matched the base with no divergence.
  Whitespace and change-scope checks passed, with no file-mode changes. Application
  sources have not changed since the recorded 28-suite pass and 29-assertion audit;
  those checks were not rerun solely for publication.
- **Handoff:** RECENT-F1 remains a low-priority permanent-test improvement, not a
  reproduced functional defect. No installation or version bump. The requested
  destination is origin/main; the final publication response records the commit
  and the result of the push/remote-head verification.

### TASK-20261109-recent-folders-audit — Review recent-folder support

- **Agent/date/base:** Codex; 2026-11-09 17:38 America/Phoenix (UTC-07:00);
  main, project worktree, 7242896 plus existing recent-folder changes.
- **Status/scope:** Audit complete, documentation only and uncommitted. Preserved
  the application and permanent tests exactly as found. No installation/publication.
- **Result:** No functional regression found. Recorded RECENT-F1 (low, permanent
  test coverage) in AUDIT.md and explicitly corrected the earlier overstatement
  about main-window coverage from component tests, preserving historical evidence.
- **Checks:** Static review plus a disposable full-application harness on Wayland:
  29 assertions passed for bulk-panel/tab/playback state, reopening, rapid input
  changes, locking during resolution, child deletion, renamed folders, symlink
  reopening/pruning, type replacement and disabled history. Synthetic media and
  isolated settings/cache/temp only. Reviewed the previous 28-suite pass; did not
  rerun the whole suite without source changes. Whitespace check passed.
- **Limits/handoff:** No new network-mount or native chooser/mouse check. Retain
  the full-window and asynchronous edge checks in a maintained test target when
  addressing RECENT-F1. Evidence and detailed limitations are in AUDIT.md and
  /tmp/ffgtk-recent-audit-v3yuj81_/. Feature implementation remains uncommitted.

### TASK-20261109-recent-folders — Recently Opened supports bulk folders

- **Agent/date/base:** Codex; 2026-11-09 17:28 America/Phoenix (UTC-07:00);
  main at 7242896, project worktree, clean at start.
- **Status:** Complete, local and uncommitted. No installation or publication.
- **Behavior:** Files and folders share the existing optional 20-entry history.
  Folders appear as `basename (Folder)` with full-path tooltips and reopen through
  FilePickers' normal asynchronous selection into folder mode. Playback remains
  file-only. Accepted selections promote history; operation/admission locks
  block reopening without promoting the rejected item. Missing folders are
  pruned. Clear/disable history removes both types; history remains off by default.
- **Implementation:** app-settings.vala accepts regular files and directories;
  legacy API names and persisted recent_files/input_files key remain compatible.
  hamburger-menu.vala records accepted folders and routes recent entries through
  guarded request_input. settings-dialog.vala explains mixed history. README,
  smoke checklist and bulk plan updated.
- **Tests:** Mixed history bounds/deduplication/pruning; folder persistence,
  disabled recording and clearing; actual GTK menu activation, folder/file mode,
  playback gating, literal paths, blocked selection and stale-folder cleanup.
  Corrected BASELINE-F2: the existing menu test now waits for asynchronous input
  acceptance before asserting promotion, matching production semantics.
- **Validation:** Development build succeeds with the same three application
  Vala warnings. Focused suites pass; full suite 28 OK, zero failures. The
  dedicated fatal-warning menu test and bulk widget suite execute on Wayland
  without skips. Headless combine-window-state has 108 intentional widget skips;
  its two recent-history data cases pass, and the dedicated menu run supplies
  the relevant display coverage. No native chooser/mouse or installed-app check.
- **Evidence/handoff:** TASK-20261109-recent-folders in AUDIT.md. Local logs:
  /tmp/ffgtk-recent-folders-build.log, /tmp/ffgtk-recent-folders-tests.log,
  /tmp/ffgtk-recent-folders-full-suite.log. Settings/cache/temp roots isolated;
  no user preferences or media changed.

### TASK-20261109-fractional-target-audit — Fractional target support assessment

- **Agent/date/base:** Codex; 2026-11-09 15:55 America/Phoenix (UTC-07:00);
  main at 031acf6, project worktree.
- **Status/scope:** Requested draft complete, documentation only. Included in
  the user-requested fractional-target audit publication with the rounding notes.
  Added [feasibility audit](smart-optimizer-fractional-target-audit.md) and linked
  findings in AUDIT.md; preserved the pre-existing local rounding notes.
- **Conclusion:** Feasible, moderate effort. Existing floating-point budget and
  curve math can stay; target precision must cross settings, controls, snapshots,
  folder/trim and reports. Recommends exact bytes internally and decimal MiB
  entry, with current minimum retained initially. Full scope estimate: 3–5
  focused working days including validation; smaller Match Source-only option
  and sub-1-MiB extension are assessed separately.
- **Finding:** SO-F14 records an existing 80 kbps feasibility versus 100 kbps
  application-floor mismatch; post-margin validation matters for small budgets.
  Source-confirmed only, no runtime reproduction.
- **Checks/limits:** Static review, arithmetic examples, reference and whitespace
  checks. No application changes, build/test run or media access. Publication
  was subsequently requested by the user; this commit includes the report and
  both supporting investigation records.
- **Handoff:** The report provides the implementation sequence and acceptance
  tests. SO-F13/SO-F14 remain open; implementation has not started.

### TASK-20261109-match-source-rounding — Explain a Match Source size undershoot

- **Agent/date/base:** Codex; 2026-11-09 15:44 America/Phoenix (UTC-07:00);
  main, project worktree, 031acf6.
- **Status/scope:** Investigation complete; documentation only. Included in the
  fractional-target audit publication. See SO-F13 in AUDIT.md; application
  fix remains open.
- **Finding:** The user's 1,572,679-byte source is 1.499824 MiB. Existing
  whole-MiB rounding converts Match Source to a 1 MiB target. The supplied
  log's 948 KiB final size reflects that smaller request plus conservative
  budgeting and normal variance. This rounding predates the recent fixes.
- **Validation:** Supplied log, metadata-only source stat, source inspection,
  arithmetic and comparison with fe740b3. No media decoded or conversion,
  build or test suite performed. Publication followed with the feasibility audit.
- **Handoff:** Preserve source-size precision throughout target calculations;
  test small-file and trimmed-window boundaries when implementing the fix.

- **Historical follow-up (2026-11-09 15:47, Codex):** Traced rounding to the original
  Match Source commit `6d07d59` (2026-07-24). Its code comment, README and
  tests deliberately specify nearest whole-MB targets, reusing the existing
  integer target API, preference and 1 MB UI steps. SO-F13 is a design
  precision limitation for small files; no unintended regression was found.
  See the attributed clarification in AUDIT.md. Documentation only; included
  with the feasibility audit publication.

### TASK-20261109-publish — Commit and push of folder-conversion and optimizer work

- **Agent/date/base:** Claude Code, at the user's request; 2026-11-09 15:10
  America/Phoenix (UTC-07:00); `main`, base fe740b3.
- **Status:** Complete. `origin/main` moved fe740b3 → 46daaca; working tree clean.
- **Commits:**
  - `6d60a87` "Use existing Convert and Optimize actions for folder conversion":
    the work of TASK-20261102-bulk-actions-implementation, -bulk-actions-plan and
    -manual-bulk-plan (Codex), with the log entries as they stood before
    2026-11-09, plus the empty `docs/README.md` at the user's request.
    Co-authored trailer: Codex.
  - `46daaca` "Fix Quality Mode VMAF measurement and stop solving to the codec
    floor": TASK-20261109-smart-optimizer-audit, -vmaf-threads-model and
    -quality-floor-guard, plus a v14 block in the `smart-optimizer.vala` header.
    Co-authored trailer: Claude.
- **Notes:** The earlier Codex entries below still read "uncommitted"; they are
  left as written and superseded by this entry. The four DevTools scripts that
  had lost their executable bit locally (`analyze-corpus.py`, `build-debug.sh`,
  `corpus-report.py`, `fake-ffmpeg-hang.sh`) were restored with `chmod +x`;
  they match the repository again, so nothing was committed for them. This
  checkout has no Git `user.name`/`user.email`; the usual author identity was
  passed per commit without changing Git settings.
- **Validation:** None beyond the task entries below; no build or test was run
  on the split commits individually. `6d60a87` was not built on its own.
- **Handoff:** Open findings are indexed in AUDIT.md (SO-F4 onward, SO-F11
  partly fixed, SO-F1 knee stop awaiting real-media verification, BASELINE-F1,
  BASELINE-F2). This entry was committed separately, after the two above.

### TASK-20261109-quality-floor-guard — Quality Mode knee stop and flat-ladder rejection

- **Agent/date/base:** Claude Code; 2026-11-09 15:15 America/Phoenix (UTC-07:00);
  main at fe740b3 plus uncommitted work, project worktree.
- **Status:** Complete; committed and pushed as `46daaca` (2026-11-09). No
  installation or version bump.
- **Changes/why:** Fixes SO-F1. `smart-optimizer-logic.vala`:
  `solve_quality_crf` no longer lowers CRF when the fitted gain is under
  `VMAF_MIN_GAIN_PER_CRF` (0.1) and, when the ceiling is out of reach, settles
  on the knee and sets `VmafModel.gain_limited`; new
  `quality_ladder_is_implausible` (span of 10+ CRF, range under 1 VMAF, below
  target and below saturation). `smart-optimizer.vala`: an implausible ladder
  returns an error recommendation (`is_impossible`), which the existing
  single-file, trim and folder gates already refuse to apply or convert; the
  notes explain a knee stop. Two new logic tests; one existing test now skips
  gain-limited solves.
- **Decision:** the flat-ladder case reuses `is_impossible` rather than a new
  flag, so no caller changed. A knee stop is still applied and auto-converted:
  it is a valid answer, only a smaller one.
- **Validation:** Development build, no new Vala warnings. Full suite 27 OK,
  1 failing (BASELINE-F2, unchanged). Real runs in AUD-20261109-quality-floor-guard.
- **Limits/handoff:** The knee stop is covered by unit tests only; no real
  source that cannot reach its ceiling was available. Not run in the GUI.
  The 0.1 and 1.0 thresholds are reasoned, not corpus-calibrated.

### TASK-20261109-vmaf-threads-model — VMAF threads, model choice and frame pairing

- **Agent/date/base:** Claude Code; 2026-11-09 14:45 America/Phoenix (UTC-07:00);
  main at fe740b3 plus the uncommitted folder-conversion work, project worktree.
- **Status:** Complete; committed and pushed as `46daaca` (2026-11-09). No
  installation or version bump.
- **Changes/why:** Fixes SO-F2, SO-F3 and the timestamp half of SO-F11.
  `smart-optimizer.vala`: libvmaf gets its own thread count instead of the
  encoder's "0 = auto" (which became one thread); the VMAF model follows the
  filtered frame width, measured with a one-frame `showinfo` probe, and is
  requested as `model=version=vmaf_4k_v0.6.1` after a synthetic check, with the
  old file path only as a fallback; the model is part of the Quality cache
  identity; both libvmaf inputs are rebased with `setpts=PTS-STARTPTS`.
  `smart-optimizer-logic.vala`: `vmaf_thread_count`, `vmaf_wants_4k_model`,
  `parse_showinfo_frame_size`. Three new cases in the logic test.
- **Unplanned addition:** the `setpts` change was not in the request. The
  end-to-end check of the 4K model path reproduced the historical flat curve
  (VMAF 48 at every CRF, solved CRF 8), so the model fix could not be verified
  without it. See AUD-20261109-vmaf-threads-model.
- **Validation:** Development build passes with no new Vala warnings. Full
  suite: 27 OK, 1 failing — `hamburger-recent-menu-rebuild` (recent-file slot
  order, three of three runs); it does not exercise the optimizer and was not
  checked against the base revision. Real FFmpeg runs through
  `optimize_for_quality` are recorded in the audit entry.
- **Limits/handoff:** Not run in the GUI. The original failing range in
  `quality-mode-vmaf-measurement-findings.md` was not re-run. Existing Quality
  cache entries are not reused because the cache identity changed. SO-F1 and
  SO-F4 onward remain open.

### TASK-20261109-smart-optimizer-audit — Smart Optimizer audit

- **Agent/date/base:** Claude Code; 2026-11-09 14:12 America/Phoenix (UTC-07:00);
  main at fe740b3, /home/pieman/Files/Archive/projects/FFmpeg-Converter-GTK.
- **Status:** Complete; documentation only, committed and pushed in `46daaca`
  (2026-11-09). No source change, build,
  test run, commit or installation.
- **Changes/why:** The user asked for an audit of the Smart Optimizer. Added
  [smart-optimizer-audit-20261109.md](smart-optimizer-audit-20261109.md) and
  indexed findings `SO-F1`–`SO-F12` in AUDIT.md (AUD-20261109-smart-optimizer).
- **Validation:** Four standalone FFmpeg experiments on the repository fixture;
  results and limits are in the report. Scratch outputs were deleted.
- **Handoff:** All findings unassigned. Suggested order is at the end of the
  report: SO-F2 and SO-F3 first (small and measured), then SO-F1.

### TASK-20261102-bulk-actions-implementation — Existing actions for folder conversion

- **Agent/date/base:** Codex primary; 2026-11-02 21:18 America/Phoenix (UTC-07:00); main at fe740b3.
  Project worktree: /home/pieman/Files/Archive/projects/FFmpeg-Converter-GTK.
  Build/test copy: Codex workspace work/bulk-implementation/builddir-bulk.
- **Status:** Complete, uncommitted. No commit, push, installation or version bump.
- **Behavior/why:** Convert uses manual settings or retained per-file optimized
  settings; only Optimize runs analysis. Auto-Convert controls immediate sequential
  conversion after Optimize. This follows the user's existing-button workflow.
- **Changes:** Added src/app/bulk-settings.vala for captured builder/common settings,
  typed per-field merges and explicit edit tracking. Updated bulk-conversion.vala,
  main.vala, all four Meson source lists, regression tests, README, smoke checklist
  and both bulk plans. Ready rows show per-file settings. Rate-control fields and
  two-pass intent are edited together; unrelated optimized choices survive edits.
  Partial analysis, stale sources/assets, codec changes, retries and Rescan have
  explicit handling. Existing staging/publication/cancellation paths are reused.
- **Additional fix:** x264/x265 builders now emit valid psy=0 / psy-rd=0 parameters
  when those features are disabled. See MANUAL-BULK-F1 in AUDIT.md.
- **Validation:** Development build passes with the same three Vala warnings.
  Full suite: 27 passing suites, no assertion failures, one existing mpv timeout.
  Focused bulk runs: 7 data cases, 20 GTK cases and 4 added manual two-pass cases
  pass; shared codec/prepared GTK cases: 4 pass. All four codecs perform real manual
  CRF and bitrate two-pass conversions with full decode checks. No capability skips
  in the display runs. Headless display-dependent skips are not counted as coverage.
- **Desktop:** Actual rebuilt Wayland window, isolated preferences, synthetic inputs,
  local debugger driving existing handlers: direct Convert, Optimize-only followed
  by Convert with a CRF edit, Optimize with Auto-Convert, and return to single-file
  mode pass. Per-file keyframes remain distinct. Eight outputs decode cleanly.
  A fresh instance closes normally via the GTK event loop; direct debugger close
  had a Wayland/Vulkan teardown stall. No native mouse/chooser or active-close claim.
- **Evidence/limits:** [Findings](manual-bulk-conversion-findings.md),
  AUD-20261102-bulk-actions-implementation. Local build logs: manual-full-suite-final.log,
  manual-widgets-verified.log, manual-two-pass.log. Historical VMAF/mpv limitations
  remain. No external test media accessed, user preferences changed or media uploaded.
- **Preservation/handoff:** Four pre-existing DevTools mode changes and empty
  docs/README.md preserved. Source tree matches the isolated tested copy; no required
  implementation work remains. User may build/install normally when desired.

### TASK-20261102-bulk-actions-plan — Preserve normal Convert and Optimize behavior

- **Agent/date/base:** Codex primary; 2026-11-02 20:50 America/Phoenix (UTC-07:00); main at fe740b3,
  /home/pieman/Files/Archive/projects/FFmpeg-Converter-GTK.
- **Status:** Planning complete; uncommitted documentation only. No implementation.
- **User correction:** No mode selector. Convert uses current settings; Optimize
  with Auto-Convert performs sequential optimization/conversion; without it,
  retain per-file settings for a later Convert, without repeated optimization.
- **Changes:** Rewrote [manual-bulk-conversion-plan.md](manual-bulk-conversion-plan.md).
  Supersedes the selector/disabled-Optimize proposal in the older entry below.
  Added retained per-item profiles, explicit edit handling and action-sequence tests.
- **Validation:** Static review of single-file recommendation application and bulk
  analysis-only/profile execution, documentation consistency and whitespace checks.
  No builds, runtime tests or media access. See AUD-20261102-bulk-actions-plan.
- **Handoff:** Implementation unassigned. Follow the revised plan; earlier selector
  decisions are historical. Preserve existing unrelated edits. No commit or push.

### TASK-20261102-manual-bulk-plan — Manual folder settings plan

- **Agent/date/base:** Codex primary; 2026-11-02 20:18 America/Phoenix (UTC-07:00); main at fe740b3,
  /home/pieman/Files/Archive/projects/FFmpeg-Converter-GTK.
- **Status:** Planning complete; documentation uncommitted. No implementation,
  commit, push or installation performed.
- **Changes/why:** Added [manual-bulk-conversion-plan.md](manual-bulk-conversion-plan.md)
  for the requested manual folder-conversion option. Proposed folder-only method
  selector defaults to Smart Optimizer; manual mode uses full codec-builder settings
  and General settings through the existing sequential prepared-conversion pipeline.
- **Decisions:** Per-file audio/compatibility checks remain necessary. Manual mode
  bypasses optimizer/VMAF requirements. Method switching invalidates unfinished
  recommendations and preserves completed rows; Rescan explicitly reprocesses them.
- **Validation:** Static source and documentation review, referenced paths and
  whitespace checks only; no builds, runtime tests or media access.
  See AUD-20261102-manual-bulk-plan in AUDIT.md.
- **Preservation/handoff:** Existing four DevTools edits and untracked docs/README.md
  unchanged. Implementation unassigned; next owner should claim work, implement the
  plan's capture/preparation/UI phases and complete its regression/desktop checks.

### TASK-20261102-findings-report — Technical findings report

- **Agent/date/base:** Codex primary; 2026-11-02 19:57 America/Phoenix (UTC-07:00); main at `6426fa2`.
- **Status:** Complete; user authorized this documentation commit.
- **Changes:** Added [installed-development-bulk-check.md](installed-development-bulk-check.md)
  and linked the installed-app audit/handoff records. Report contains test setup,
  results and validation limits, with no media content descriptions, media files,
  screenshots or input/output filenames.
- **Validation:** Documentation content review, links and whitespace checks.
  Existing technical results are unchanged; no additional conversion or code tests needed.
- **Scope:** Documentation only. Existing DevTools mode edits and empty docs/README.md
  remain excluded. Commit revision is available in Git history; no source changes.

### TASK-20261102-installed-bulk-check — Installed app with authorized local media

- **Agent/date/base:** Codex primary; 2026-11-02 19:55 America/Phoenix (UTC-07:00); main at `6426fa2`.
- **Status:** Completed. Source/binary unchanged; technical findings are recorded in
  [installed-development-bulk-check.md](installed-development-bulk-check.md). User reported successful bulk conversion and normal playback,
  then authorized testing with local test inputs.
- **Method:** Launched `~/.local/bin/ffmpeg-converter-gtk-devel` on the actual
  Wayland desktop with isolated XDG/TMPDIR preferences. SHA-256 matches the local
  development build. Desktop accessibility supplied anonymous UI state checks;
  unreliable accessibility click activation required a local debugger driver of
  the installed app's existing GTK/MainWindow handlers. No replacement binary or
  separate conversion pipeline was used. Native chooser interaction is not covered.
- **Results:** Two full runs of six real local videos completed: twelve outputs,
  zero item failures. x264 size target 4 MB, General half-size scaling and 24 fps.
  All twelve have expected H.264 video/AAC audio, source-matching duration and
  selected General transformations; full FFmpeg audio/video decode reports no errors.
- **Lifecycle/safety:** Convert again skipped completed rows without new files.
  Explicit rescan created distinct names; all six first-run SHA-256 checksums
  remained unchanged. A subsequent run was stopped through the Cancel control;
  no additional outputs, active jobs, staging directories or passlogs remained.
  Input/settings/Rescan were locked during processing and restored afterward;
  Crop & Trim/Audio/Subtitles page content was insensitive and programmatic
  navigation to those pages redirected to General.
- **Preservation:** All six originals retain size, timestamp, device/inode.
  Twelve outputs remain in the user's external output directory for review.
  Temporary preferences isolated the normal installed configuration. No
  images, audio, video, screenshots or filenames were included in project records
  or uploaded. Detailed local command logs stay outside the repository.
- **Handoff:** No functional defects found in the tested bulk workflow. Other
  codecs/objectives retain prior synthetic coverage; this real-media run used x264
  size mode. The independent mpv automated timeout and historical VMAF investigation
  are not resolved by this check. The test instance exited normally.

### TASK-20261102-bulk-publish — Audit, fixes and authorized GitHub publication

- **Agent / date / base:** Codex primary; 2026-11-02 19:07 America/Phoenix (UTC-07:00); `main` above `1409c0c`.
- **Changes / why:** Fixed timed-logo calibration sample offsets across analysis,
  calibration and quality references, with cache invalidation. Fixed Convert staying
  disabled after a detector finishes. See `AUD-20261102-bulk-publish`, `BULK-F4` and
  `BULK-F5` for evidence and regression coverage. Earlier implementation history is
  preserved below; its deferred timed-logo finding is superseded by this fix.
- **Validation:** App builds; 19 bulk cases and 4 codec/prepared GTK cases pass on
  an isolated display. Full headless suite: 27 OK, 0 failures, 1 known mpv timeout.
  New real FFmpeg frame hashes match an independent timing expectation. All four
  codecs pass both size and measured-quality output checks. No private media used.
- **Publication:** User authorized commit/push. This entry accompanies the feature
  commit; its resulting hash and publication are verified against GitHub at delivery.
  GitHub remote was fetched and matched the local base. Existing unrelated DevTools
  mode edits and empty docs/README.md are excluded. No installation or app version bump.
- **Handoff:** Implementation/audit complete. Preserve the remaining mpv environment
  timeout and historical long-range VMAF investigation; do not report a fully passing
  suite or complete manual desktop validation. Test logs remain in the isolated
  working copy's builddir-bulk/audit-*.log. Commit history is the revision reference.

### TASK-20261102-bulk-implementation — Folder conversion delivered

- **Date / branch / base:** 2026-11-02 18:25 America/Phoenix (UTC-07:00); `main`, `1409c0c`, all changes uncommitted.
- **Agents / ownership:** Primary integrated `main.vala`, controller, source lists,
  documentation and final checks. `codec_resolver` implemented the sequential
  backend, publication and geometry checks; `codec_ui` implemented typed selection,
  folder controls, detector retirement and capability cancellation; `codec_tests`
  implemented regressions. `audit_plan_safety` independently reviewed final
  integration. Primary serialized logs and all builds. Working copy remains
  `/home/pieman/Documents/Codex/2026-11-02/home-pieman-files-archive-projects-ffmpeg-2/work/bulk-implementation`.
- **Status / behavior:** Completed folder-input implementation, no new hamburger
  action. General/full Smart Optimizer settings are captured once and resolved per
  file. Crop & Trim/Audio/Subtitles and source detectors are guarded in folder mode.
  Whole-batch ownership covers analysis, sequential encoding and cleanup; controls,
  recent/programmatic input changes and competing actions cannot replace a run.
- **Prepared pipeline (1c):** Captured runtime/naming/config snapshots, data-only
  prepared Converter entry, tracked duration/FPS/topology/verification/collage
  helpers, private passlogs and child reaping. Existing single-file entry remains.
  Optimizer/capability cancellation now waits for helper exit before returning.
- **Queue/output decisions:** Top-level, bytewise-sorted, identity-deduplicated queue.
  Blank output uses `Converted`; explicit output is honored. Fresh source/audio/
  duration/geometry checks per item, strict crop/logo bounds, complete four-codec
  recommendation resolver. Private same-filesystem staging and atomic hard links
  preserve existing outputs/source aliases; unsupported publication fails safely.
  Retry skips completed rows; Ready/unfinished rows reanalyze conservatively using
  the optimizer cache. Rescan (or different input/destination) starts a new queue.
  Source failures continue; destination/tool failures stop. Late collage cancellation
  preserves the verified video and stops further dispatch.
- **Audited fixes:** Completed-row retry, late successful-video cancellation,
  rotated crop dimensions, codec audio-disabled precedence, extensionless explicit
  file selection and typed playback/recent-input guards. Tests also exposed a
  ConsoleTab popover disposal warning; explicitly unparenting its manually attached
  popover before TextView disposal fixes it. See `AUD-20261102-bulk-final`.
- **Verification:** Final development app build passes. Seventeen bulk cases pass
  on the isolated GTK display (four pure, thirteen widget/integration), including
  real FFmpeg size AND measured-quality outputs for x264/x265/VP9/SVT-AV1, crop/
  timing, collisions, retained completed items and deterministic late collage stop.
  Full suite: **27 OK, zero failures, one pre-existing mpv-backend timeout**.
  Other display-dependent cases skip in the headless full run. Earlier prepared
  widget cases and frozen forty-profile codec parity checks passed separately.
  Diff checks pass. An isolated app startup stayed running for eight seconds
  until the test timer stopped it; portal/Broadway warnings prevent treating that
  as visual validation. Full visual/interactive desktop checklist is still manual.
- **Documents:** README and `DevTools/SMOKE-TEST.md` explain folder scope, settings,
  defaults, queue retries, cancellation and safe filesystem behavior. Plan updated
  to actual implementation choices. No version change, installation, commit, push
  or upload. Six existing DevTools modifications and empty docs/README.md preserved.
- **Limits / future handoff:** Existing timed-logo calibration sample-offset issue
  remains `BULK-F4`; historical long-range VMAF alignment finding is not closed by
  short synthetic tests. `BASELINE-F1` mpv runtime timeout persists. The supplied
  private inputs and output directory were not opened or modified. Generated media
  stayed in isolated disposable directories. Future agents should start with these
  audit limits and the manual smoke checklist, not redo completed foundations.
- **Reproduce checks:** In the working copy use `meson compile -C builddir-bulk`
  and `meson test -C builddir-bulk --print-errorlogs`; isolate XDG/TMPDIR as in
  AGENTS.md. Focused suite: `bulk-conversion`; real GTK suite:
  `combine-window-state-test -r /bulk-conversion` on a working display. Logs are
  `builddir-bulk/bulk-final-widget-tests.log`, `bulk-full-tests.log`,
  `bulk-app-final-build.log` and `bulk-window-startup.log` (not tracked).

### TASK-20261102-bulk-implementation — Phase 1b shared four-codec resolver

- **Date / agents:** 2026-11-02 17:43 America/Phoenix (UTC-07:00); Codex primary integrated/ran tests,
  `codec_resolver` implemented data policy/builders, `codec_ui` implemented GTK
  adapters, `codec_tests` wrote frozen-reference regressions; `audit_plan_safety`
  independently reviewed source/tests read-only with no findings.
- **Status / base:** Phase 1b completed, uncommitted on `main` above `1409c0c`.
- **Changes / why:** Added `SmartCodecResolver` and `SmartCodecResolution` for
  complete four-codec recommendation application. Replaced duplicated GTK policy
  tables with adapters; reused existing builder execution. Preserved reset
  defaults, effort/tuning, audio choices, container forcing, bit depth and
  single/two-pass behavior. Captured both depth-specific General filter variants
  so post-analysis depth changes do not reuse an incompatible NLMeans chain.
- **Evidence:** Captured 40 full-profile goldens from the original GTK appliers
  using an isolated local Broadway display. New pure resolution and new GTK
  adapters both match all 40 frozen profiles. Eight new tests cover those
  matrices plus audio constraints, inactive CRF defaults, independent ownership,
  filter variants and borrowed recommendation preservation.
- **Validation:** App builds; profile and resolver suites pass. Six new pure
  cases pass headlessly; two widget cases pass with the isolated display.
  Full suite: 22 OK, the same pre-existing mpv-backend timeout. Existing eight
  phase 1a tests still pass; whitespace checks clean. No private media accessed.
- **Corrections during development:** Fixed borrowed-struct codec mutation and
  retained inactive two-pass CRF defaults. Corrected one test expectation from
  unsupported 96k to the existing next selectable 128k audio rung. Temporary
  legacy source/generator removed; only frozen synthetic profile references ship.
- **Handoff:** Continuing phase 1c immediately. Calibration context still needs
  correct per-file depth variant before measurement; prepared execution must
  capture runtime options and track every helper process. No installation,
  commit, push or upload. Existing DevTools changes preserved.

### TASK-20261102-bulk-implementation — Audited plan and completed foundation slice 1a

- **Agent/session / date:** Codex primary; 2026-11-02 17:23 America/Phoenix (UTC-07:00). `audit_plan_core`
  implemented profile data/composition; `audit_plan_ui` wrote tests;
  `audit_plan_safety` independently reviewed. Primary integrated and ran checks.
- **Branch / worktree / base:** `main`,
  `/home/pieman/Files/Archive/projects/FFmpeg-Converter-GTK`, `1409c0c`.
- **Status:** Requested plan audit and first implementation milestone completed;
  all changes uncommitted. Full feature ready for continuation, not shipped.
- **Plan corrections / why:** Added atomic no-clobber staging/publication,
  source-alias identity, global-idle folder admission, programmatic disabled-tab
  guards, explicit audio-processing reset precedence, tracked probe cancellation
  and run-wide output failure handling. Split phase 1 into reviewable 1a/1b/1c.
- **Code changed:** `src/encoders/codec-utils.vala` adds deep copies and
  data-only `compose_encode_profile`; existing UI adapter now uses a private
  General snapshot while preserving effective pixel format. This prevents one
  future job from mutating another job's reusable settings. No codec preset
  policy or encoder runner behavior changed in this slice.
- **Tests/integration:** Eight `/encode-profile/...` cases added in
  `tests/combine-window-state-test.vala`; `meson.build` registers headless
  `encode-profile-snapshot` with recursive test selection.
- **Validation:** App builds; eight new tests pass with no skips. Corrected,
  isolated full-suite baseline: 20 OK/one timeout; modified: 21 OK/same timeout.
  Trim suite passes; display-dependent cases skip. `git diff --check` passes.
  Detailed evidence/harness corrections: `AUD-20261102-phase1a`, `BASELINE-F1`.
- **Preserved:** All six existing DevTools modifications, `AGENTS.md`, earlier
  history, empty `docs/README.md`, original private videos and existing outputs.
  Nothing installed, committed, pushed or uploaded.
- **Next:** Claim the ready-for-handoff entry above. Implement phase 1b's full
  recommendation resolver and independent four-codec parity coverage, then 1c
  and the remaining folder/queue phases. `BULK-F1`–`BULK-F3` remain open.

### TASK-20261102-bulk-test-fixture — Private local test input and output

- **Agent/session / date:** Codex, primary chat; 2026-11-02 17:08 America/Phoenix (UTC-07:00).
- **Branch / worktree / base:** `main`,
  `/home/pieman/Files/Archive/projects/FFmpeg-Converter-GTK`, `1409c0c`.
- **Status:** Completed; documentation is uncommitted. No implementation started.
- **Changed / why:** Added a local-only test-media section to
  `bulk-conversion-plan.md` with the user's input folder and its existing
  `output/` destination. Recorded that original and derived media must remain
  outside the repository and must never be committed or uploaded.
- **Validation:** Confirmed the input and output directories exist, without
  opening media or listing private filenames. Checked plan/log consistency;
  no builds, conversions or application tests. See `AUD-20261102-bulk-test-fixture`.
- **Handoff:** Use the explicit local output folder during future manual bulk
  tests; exclude it from input discovery, preserve existing files and use unique
  output names. Synthetic media remains the basis for committed automated tests.
  Existing code/DevTools changes and prior records were preserved.

### TASK-20261102-bulk-conversion-plan — Folder-based Bulk Conversion plan

- **Agent/session:** Codex, primary chat; read-only Codex subagents
  `bulk_optimizer`, `bulk_ui` and `bulk_pipeline` reviewed optimizer parity,
  input/lifecycle behavior and conversion/output safety. The primary agent is
  the sole documentation/log writer.
- **Date:** 2026-11-02 17:00 America/Phoenix (UTC-07:00).
- **Branch / worktree / base:** `main`,
  `/home/pieman/Files/Archive/projects/FFmpeg-Converter-GTK`, `1409c0c`.
- **Status:** Planning completed; documentation is uncommitted. Application
  implementation has not started.
- **Changed:** Added `docs/bulk-conversion-plan.md`; recorded the static review
  and implementation constraints in `docs/AUDIT.md`.
- **Why / user decisions:** The initial hamburger-menu/window request was
  superseded during planning by folder input in the existing workflow with no
  new hamburger item. The user explicitly confirmed that Crop & Trim, Audio
  and Subtitles should be disabled when a folder is selected. Full Smart
  Optimizer and General settings apply, processing one video at a time.
- **Plan decisions:** Separate confirmed requirements from proposed defaults;
  preserve every optimizer control and complete recommendation application;
  snapshot settings/timing and runtime options; add explicit input modes and
  whole-batch ownership; probe each file independently; protect all queued sources.
  The reviewers identified a prepared-item eligibility ambiguity, which was
  corrected so analysis-only items remain Ready for review and can be converted.
- **Validation:** Read-only source/document review and documentation/reference
  checks. No builds, automated tests, media conversions or desktop checks.
  See `AUD-20261102-bulk-plan` and implementation findings `BULK-F1`–`BULK-F3`.
- **Existing changes preserved:** Existing `AGENTS.md`, earlier log history,
  empty `docs/README.md` and all six pre-existing modified DevTools scripts.
- **Next actions / handoff:** Await a request to implement. Start with phase 1's
  shared request/profile extraction and parity coverage. Folder scan scope,
  output defaults and failure policy are proposed choices for review, not
  additional user-confirmed requirements. No active implementation owner.

### TASK-20261102-agent-handoffs — Shared multi-agent workflow

- **Agent:** Codex, primary chat; a Codex review subagent reviewed coordination
  pitfalls and recommended separate build directories and serialized log writes.
- **Date:** 2026-11-02 16:04 America/Phoenix (UTC-07:00).
- **Branch / worktree / base:** `main`,
  `/home/pieman/Files/Archive/projects/FFmpeg-Converter-GTK`, `1409c0c`.
- **Status:** Completed; changes are uncommitted.
- **Changed:** Expanded `AGENTS.md` with parallel-work ownership, shared-file and
  build-directory coordination, audit attribution, finding lifecycle and handoff
  requirements. Initialized the existing empty `docs/CHANGELOG.md` and
  `docs/AUDIT.md` with guidance, entry formats and this documentation record.
- **Why:** The user requested durable shared records so agents can understand
  what other agents did, why they did it, and how to continue their work.
- **Validation:** Documentation consistency and cross-reference checks only;
  no application build, automated tests or desktop checks were run for this
  documentation-only change. See `AUDIT.md`, `AUD-20261102-agent-handoffs`.
- **Existing changes preserved:** Modified `DevTools/analyze-corpus.py`,
  `DevTools/build-debug.sh`, `DevTools/build.sh`, `DevTools/corpus-report.py`,
  `DevTools/fake-ffmpeg-hang.sh` and `DevTools/uninstall.sh`. `AGENTS.md` was
  already untracked; `docs/AUDIT.md`, `docs/CHANGELOG.md` and `docs/README.md`
  were existing untracked empty files. `docs/README.md` was left untouched.
- **Next steps / blockers:** None for this task. Future agents should read both
  shared logs and register their own active work before editing. Earlier project
  changes have not been retroactively audited or reconstructed here.

### History entry format

```text
Task ID / short title:
Agent / session / contributors:
Timestamp and timezone:
Branch / worktree / base revision / resulting commits or uncommitted state:
Status:
Changes and affected files:
Why / important decisions:
Validation actually performed / results / skips / limits:
Related audit finding IDs / report or artifact links:
Unfinished and uncommitted work / pre-existing changes:
Next actions / blockers / handoff owner:
```
