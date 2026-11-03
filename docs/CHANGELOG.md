# Agent changelog and handoffs

Shared record of who changed what and why. Read this file and `AUDIT.md` before
starting work; follow the multi-agent workflow in `../AGENTS.md`. Use one task ID
across active work, history and related audit entries. Add history newest first
and preserve earlier entries. Routine log maintenance belongs to its task entry;
it does not require another entry about updating the log.

## Active work

No active implementation tasks. The publication audit and fixes are complete;
see TASK-20261102-bulk-publish below and Git history for the resulting commit.

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
