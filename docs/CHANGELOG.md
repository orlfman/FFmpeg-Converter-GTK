# Agent changelog and handoffs

Shared record of who changed what and why. Read this file and `AUDIT.md` before
starting work; follow the multi-agent workflow in `../AGENTS.md`. Use one task ID
across active work, history and related audit entries. Add history newest first
and preserve earlier entries. Routine log maintenance belongs to its task entry;
it does not require another entry about updating the log.

## Active work

No active implementation tasks. Folder Convert/Optimize behavior and the
2026-11-09 Smart Optimizer fixes are committed and pushed to `origin/main`
(`6d60a87`, `46daaca`); see the publication entry below.

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
