# Shared audit and findings log

Read this file and `CHANGELOG.md` before starting work. Follow the multi-agent
workflow in `../AGENTS.md`. Record each audit, investigation and re-test, including
explicitly when no findings were identified within its scope. Link detailed
reports here rather than leaving them discoverable only in a chat.

Add entries newest first. Give findings stable IDs and track them as **open**,
**in progress**, **fixed, awaiting verification**, **verified**, or **deferred**
(with reason). Record an owner or explicitly mark the finding unassigned.
Preserve the original evidence; add attributed, dated follow-ups for fixes,
verification, reopening or corrections. A fix is not verified until checks and
their results are recorded. Link back to the corresponding changelog task or
commit so agents can follow the full history.

## Unresolved findings

Folder implementation findings `BULK-F1`–`BULK-F3` are implemented and verified
within the recorded test scope in `AUD-20261102-bulk-final`. Remaining items:

| ID | Severity / status | Owner | Next action |
| --- | --- | --- | --- |
| BASELINE-F1 | Medium / open, pre-existing | Unassigned | Investigate the mpv-backend timeout with appropriate local audio/runtime access. |

Historical quality/frame-alignment findings remain in
`quality-mode-vmaf-measurement-findings.md`; their full-length failing-range
scenario was not revalidated here. No application-wide audit is implied.

When an issue is found, add its finding ID, severity, status, owner, next action
and a link to its detailed entry below. Keep this index current as findings are
fixed, verified, deferred or reopened; retain the history below.

## Audit history

### AUD-20261102-installed-bulk-check — Actual installed development app

- **Task/date/agent:** `TASK-20261102-installed-bulk-check`; 2026-11-02 19:55 America/Phoenix (UTC-07:00); Codex primary.
- **Authorization/base:** User authorized local test media for this check; only
  technical findings are recorded here. Installed development binary matches
  the current local development build; project HEAD is `6426fa2`.
- **Findings:** No functional defects observed in the tested bulk workflow.
  Six actual videos with audio (mixed portrait/landscape, roughly 8–27 seconds)
  completed twice with zero failures. Full decode and FFprobe checks pass on all
  twelve outputs; General half-size scaling and 24 fps are applied, audio remains,
  and durations match their sources within a quarter second.
- **Verified lifecycle:** Sequential work observed; controls locked during the batch
  and restored to idle. Completed-item retry produces no additional outputs. Rescan
  safely suffixes duplicate names. Cancel stops a new run and preserves completed
  outputs. First-run output hashes are unchanged; sources retain original size,
  modification timestamp and device/inode. No staging directories/passlogs remain.
  Disabled page content and guarded navigation were checked on the installed window.
- **Method/limits:** Actual Wayland desktop and installed executable; isolated
  preferences/cache/temp files. Local debugger automation invoked existing GUI
  handlers after desktop accessibility activation proved unreliable; accessible
  labels/states confirmed visible results. This does not establish native mouse/file
  chooser behavior or exhaustive visual coverage. No media/screenshot uploaded or
  copied into the repository. Real-media objective was x264 size mode; prior synthetic
  tests cover all four codecs in size and quality. Normal user settings were isolated.
- **Other evidence:** User independently reported working bulk conversion and video
  playback. That supports the mpv timeout being specific to automated runtime access,
  but its root cause and test status remain unchanged. No player fix was attempted.
- **Disposition:** Test instance exited normally. Twelve converted files are retained
  in the external test output folder. The technical
  [findings report](installed-development-bulk-check.md) accompanies this record;
  detailed local logs are excluded from the commit.

### AUD-20261102-bulk-publish — Pre-publication source audit and fixes

- **Task / agent / date:** `TASK-20261102-bulk-publish`; Codex primary; 2026-11-02 19:07 America/Phoenix (UTC-07:00).
- **Scope / base:** `main` at `1409c0c` plus the uncommitted bulk feature. Reviewed
  typed selection/admission, queue retries/cancellation, source and output ownership,
  frozen execution settings, optimizer sample construction, tests and publication scope.
- **BULK-F4 — fixed and verified:** Confirmed source-timed logo windows were reused
  unchanged for independently seeked optimizer inputs. Each sample now receives a
  locally shifted/clipped delogo chain in analysis, calibration and lossless quality
  references. Static regions and unrelated quoted filters remain unchanged. Removed
  inactive timed filters retain a connected graph. Seek/duration rounding matches
  the actual FFmpeg input arguments. Calibration cache format moves from 2 to 3 so
  old incorrectly timed measurements cannot be reused; application version unchanged.
- **BULK-F5 — medium, fixed and verified; owner Codex:** Switching to a codec tab
  during General detection disabled Convert, but completion never refreshed its
  sensitivity. General now signals detector activity changes, including retired
  worker completion, and MainWindow refreshes admission immediately. The controlled
  detector regression checks start and completion notifications.
- **Verification:** Development application builds. Nineteen bulk cases pass on an
  isolated GTK display with no skips, including new independent graph expectations
  and a real FFmpeg frame-hash comparison against manually specified sample windows.
  Four additional prepared-conversion/codec widget cases pass; the latter includes
  forty frozen codec-profile expectations. Existing four-codec size and measured
  quality conversions, cancellation, aliases and collision checks still pass.
  Full headless suite: 27 OK / 0 failures / the same pre-existing mpv-backend timeout.
  Display-only cases skip in that headless run; full manual desktop coverage remains
  outside these checks. Historical long-range VMAF investigation remains open.
- **Publication controls:** Only source/tests/docs belonging to this work are selected
  for commit. Existing DevTools executable-bit edits and empty docs/README.md remain
  outside the commit. No private source/derived media accessed or included; no
  generated build files are published. User explicitly authorized commit and push.

### AUD-20261102-bulk-final — Prepared runtime and complete folder workflow

- **Task / date / base:** `TASK-20261102-bulk-implementation`; 2026-11-02 18:25 America/Phoenix (UTC-07:00);
  `1409c0c` plus uncommitted folder implementation.
- **Attribution:** `audit_plan_safety` performed independent final read-only review;
  `codec_resolver` reviewed queue/publication/timing and implemented fixes;
  `codec_ui` reviewed typed consumer/cancellation guards; `codec_tests` provided
  regressions. Primary integrated fixes and ran the checks below.
- **BULK-F1, verified within this scope:** Prepared runtime/config/naming copies,
  full shared recommendation resolver and per-source context are integrated. Forty
  frozen old-GTK full-profile references still define resolver parity; helper
  subprocesses use captured paths and tracked cancellation. Earlier concern that
  measured filter chains lacked bit-depth retargeting is corrected: existing
  SmartOptimizer already retargets NLMeans/format chains at source and output depth;
  a regression covers this. No extra retarget rewrite was needed.
- **BULK-F2, verified within this scope:** Typed file/folder resolution, guarded
  detectors/media consumers and MainWindow navigation/admission are implemented.
  Widget tests cover source-mode transitions, manual General preservation, stale
  detector callbacks, busy input rejection, extensionless files and per-file source
  size. MainWindow source review/build completed; exhaustive interactive desktop
  navigation/visual checks remain unperformed.
- **BULK-F3, verified within this scope:** Sequential controller holds whole-batch
  ownership, awaits terminal cleanup, uses its own stop token and publishes with
  atomic no-clobber hard links from exclusively owned staging. Tests prove source
  alias/late-name collision preservation, sequential real conversions, retained
  completed rows, stopping before next dispatch and late optional-collage success.
- **Review fixes verified:** Retry initially rescanned/re-encoded completed rows;
  queue retention plus explicit Rescan fixes it. Late cancelled collage initially
  discarded a valid main video; success now publishes before stopping. Crop bounds
  now account for prior 90° rotation. Root fixed codec audio-off precedence and
  explicit extensionless-file acceptance, plus typed playback/recent input guards.
- **GTK finding (fixed, verified):** Running multiple real queue cases in one GTK
  test process exposed `GtkPopover is not a child of GtkTextView` during ConsoleTab
  disposal. ConsoleTab now unparents its manually attached popover before recursive
  destruction. Rebuilt tests then passed all seventeen cases without that warning.
- **Actual checks:** App build passes; seventeen bulk cases pass, no skips on the
  isolated Broadway display (4 pure + 13 GTK/integration). Available local FFmpeg
  supports all four encoders and libvmaf; real short outputs for both objectives
  pass FFprobe codec/usability checks. Includes General rotated crop and seek/time,
  output collisions, default destination, retry/reset, stale detectors and late
  collage cancellation. Full headless suite: **27 OK / 0 failures / 1 timeout**,
  same `BASELINE-F1`. Existing unrelated display cases skip. Phase 1c earlier full
  run was 25 OK / same timeout. An isolated full-window startup stayed alive until the eight-second test timer;
  unavailable desktop portal services and a Broadway frame-timing warning were
  logged, so this is not a manual desktop pass. Diff/guarded-copy checks are
  performed at delivery.
- **Limits:** No supplied private fixture or derived content accessed. No manual
  full desktop checklist, long-duration quality validation, forced real disk-full
  device, or exhaustive cancellation point matrix claimed. No installation/upload.

#### BULK-F4 — Timed-logo calibration uses unshifted sample timestamps

- **Severity / status / owner:** Medium; deferred; unassigned; pre-existing shared
  SmartOptimizer behavior, observed by static review rather than a new media repro.
- **Evidence:** Optimizer receives the flat General filter chain; its sampled
  inputs start at independent source seek positions. Timed `delogo` enable ranges
  are not individually shifted to each sample's time origin. Final ConversionRunner
  does retarget logo windows to the encode seek. Static regions are unaffected.
- **Impact:** Timed moving-logo removal can differ between calibration samples and
  the final encode, in both single-file and folder optimization. Folder execution
  still applies the configured final logo-removal windows through the shared runner.
- **Next action:** Add per-input timestamp retargeting in optimizer sample filter
  construction, with independent source-offset expectations and real sampled checks.
  Keep separate from historical VMAF/frame-alignment investigation; do not change
  quality thresholds to disguise a timing mismatch.

### AUD-20261102-phase1b — Complete recommendation-policy extraction

- **Task / date / base:** `TASK-20261102-bulk-implementation`; 2026-11-02 17:43 America/Phoenix (UTC-07:00);
  `1409c0c` plus phases 1a/1b uncommitted changes.
- **Contributors:** `codec_resolver`, `codec_ui`, `codec_tests`; primary integrated
  and executed builds/tests; `audit_plan_safety` independent read-only review.
- **Findings:** No issues in final source/test review. During development fixed
  a Vala borrowed-struct mutation in the adapter and retained hidden CRF defaults
  for two-pass mode. Added independent regressions for both. General snapshots
  now own both depth-dependent filter chains; resolution selects its own variant.
- **Characterization:** Original GTK appliers produced 40 frozen full-profile
  reference hashes (four codecs × five effort levels × two pass modes, cycling
  source/audio/content/delivery/depth/container conditions). Both pure resolver
  and current GTK adapter match these independent references. Temporary legacy
  code was removed after capture, with no private media involved.
- **Checks:** Development app build passed. `encode-profile-snapshot` and
  `smart-codec-resolver` pass (eight phase 1a cases, six new headless cases and
  two display cases skipped in headless mode). Separate isolated Broadway run
  executes both new widget cases successfully, including the 40-profile matrix.
  Full regression: 22 suites OK, one pre-existing `BASELINE-F1` mpv timeout.
  Other display-dependent cases remain unvalidated/skipped. Diff checks passed.
- **Limits / next:** `BULK-F1` remains open for phase 1c runtime/prepared execution
  and calibration filter-depth context. Folder scanner/queue/UI and atomic output
  publication remain pending; no end-to-end bulk conversion claimed. Original
  test videos/outputs were not opened, copied or uploaded.

### AUD-20261102-phase1a — Profile foundation implementation and verification

- **Task / date / base:** `TASK-20261102-bulk-implementation`; 2026-11-02 17:23 America/Phoenix (UTC-07:00);
  `1409c0c` with uncommitted changes in `src/encoders/codec-utils.vala`,
  `tests/combine-window-state-test.vala` and `meson.build`.
- **Contributors:** `audit_plan_core` implemented copies/composition;
  `audit_plan_ui` implemented eight headless contract tests; `audit_plan_safety`
  reviewed callers and final source/tests read-only. Codex primary integrated,
  executed all checks and maintains these records.
- **Source findings:** None in the final independent static review. Existing
  callers do not rely on mutating caller General pixel format; the wrapper
  preserves effective-format reconciliation on a private copy.
- **Build:** Development application built successfully in the isolated checkout
  using `meson compile -C builddir-bulk -j 4 ffmpeg-converter-gtk-devel`.
  Removed one new generated-C unused-array-local diagnostic during review;
  final rebuild has no such diagnostic. Existing generated-C/Vala warnings remain.
- **Focused verification:** `meson test -C builddir-bulk --print-errorlogs
  encode-profile-snapshot` passed all eight real cases, with no skips. Checks
  cover nested-copy isolation, caller audio/format/argument preservation,
  filter/audio/metadata/watermark/delogo/speed/keyframe expectations, independent
  job state, private effective-format adapter order and absent-General defaults.
- **Harness correction:** The first dedicated wrapper used GLib `-p`, which
  selected zero nested tests; corrected to recursive `-r /encode-profile` and
  verified TAP `1..8`. The external baseline initially lacked the fixture path
  expected by trim tests, causing a misleading duration failure. Providing the
  original bundled fixture path resolved it without source changes. Final runs
  used isolated XDG configuration/cache and temporary directories for both builds.
- **Full-suite comparison:** Baseline: 20 OK, one timeout. Modified build: 21 OK,
  one identical timeout (the additional suite is the eight-case profile suite).
  Trim/subtitle tests pass in both corrected runs. Display-dependent subtests
  skip because no usable display is available; Meson suite-level OK is not
  equivalent to visual validation.
- **BULK-F1 follow-up:** Data/profile composition completed. Complete Smart
  recommendation extraction, runtime freezing and prepared conversion remain
  unimplemented; leave this finding open and unassigned for the next agent.
- **Limits:** No folder UI/queue or complete four-codec recommendation parity
  claimed. No installed copy changed, no private fixture opened/converted and
  no upload/commit/push performed.

#### BASELINE-F1 — mpv-backend suite timeout in this environment

- **Severity / status / owner:** Medium; open; unassigned.
- **Evidence:** Both unchanged `1409c0c` source and modified source time out
  after 30 seconds in `mpv-backend-state`, following two passing failed-load
  cleanup cases. Stderr includes `pa_write() failed while trying to wake up the
  mainloop: Operation not permitted`. Reproduced with isolated settings.
- **Interpretation / limits:** Predates phase 1a; runtime/environment cause not
  fully diagnosed. No player source changed. Do not claim a fully passing suite
  or modify unrelated playback code just to hide this result.
- **Next action:** Re-run with the appropriate local audio/runtime access and
  investigate the remaining timeout if it persists. Other suites and all eight
  new headless profile tests pass in the corrected comparison.

### AUD-20261102-plan-review — Independent plan audit before implementation

- **Task / date / base:** `TASK-20261102-bulk-implementation`; 2026-11-02 17:13 America/Phoenix (UTC-07:00);
  `1409c0c` plus existing local changes.
- **Agents:** Codex primary; independent read-only reviewers `audit_plan_core`,
  `audit_plan_ui` and `audit_plan_safety`. Primary checked their source evidence
  and corrected the plan; no private test media accessed.
- **Scope / checks:** Static cross-check of the plan against picker/controller,
  navigation, optimizer appliers, converter/runner, cache signatures and output
  helpers. Found the following plan gaps; no new runtime reproduction claimed.
- **PLAN-A1 (high, design corrected; implementation pending):** String/path
  reservations and rechecks do not prevent races while FFmpeg uses `-y`.
  Require exclusively owned same-filesystem staging and atomic no-replace
  publication for video and sidecars. Alias protection needs device/inode or
  equivalent identity, not cache signatures based on path/size/mtime.
- **PLAN-A2 (medium, design corrected; implementation pending):** Require global
  idle admission before entering folder mode, and folder-aware navigation guards
  so disabled Trim cannot clear keep-all-audio or mutate General timing locks.
  Run-wide output failures stop dispatch; only source-specific failures continue.
- **PLAN-A3 (medium, design corrected; implementation pending):** Normal optimizer
  appliers reset codec-local audio-processing controls. Preserve that behavior
  for parity rather than promise those discarded settings survive in bulk.
  General audio speed and retained user audio choices still apply.
- **PLAN-A4 (medium, design corrected; implementation pending):** Cancellation
  must also cover initial duration/FPS probes, output verification and collage
  probes; current initial synchronous probes are outside tracked encoder execution.
- **Sequencing correction:** Split phase 1 into 1a deep-copy/pure profile
  composition, 1b complete four-codec recommendation resolution and 1c frozen
  runtime/request preparation. Completing 1a does not enable folder conversion.
- **Result / limits:** Plan corrected and suitable for beginning slice 1a.
  Existing `BULK-F1`–`BULK-F3` remain open implementation constraints. No build,
  application tests or media conversion were part of this static plan audit;
  subsequent implementation validation will be recorded separately.

### AUD-20261102-bulk-test-fixture — Local fixture location check

- **Task / agent / date:** `TASK-20261102-bulk-test-fixture`; Codex, primary
  chat; 2026-11-02 17:08 America/Phoenix (UTC-07:00).
- **Revision / scope:** `1409c0c` with existing local changes; local directory
  existence and documentation only. No application build produced.
- **Evidence / checks:** Confirmed `/mnt/storage1/local/projects/testvideofolder/`
  exists and has the immediate subdirectory `output/`. Did not open video
  contents, enumerate private filenames, copy fixtures or run conversions.
- **Findings:** None within the directory/documentation check. No conclusions
  about media compatibility or bulk implementation correctness.
- **Recorded constraint:** Original and derived media stay external to the
  repository and must not be committed or uploaded. Future testing should use
  the supplied output directory and sanitized text-only reports.
- **Limits / handoff:** No builds or application tests. Use synthetic fixtures
  for portable automated coverage; the existing bulk design findings remain open.

### AUD-20261102-bulk-plan — Bulk Conversion architecture investigation

- **Task / plan:** `TASK-20261102-bulk-conversion-plan` in `CHANGELOG.md`;
  `bulk-conversion-plan.md`.
- **Agent/session:** Codex primary chat with attributed read-only review from
  `bulk_optimizer`, `bulk_ui` and `bulk_pipeline`.
- **Date:** 2026-11-02 17:00 America/Phoenix (UTC-07:00).
- **Revision / scope:** `1409c0c` on `main` with existing local changes;
  static review of folder input, full optimizer reuse, conversion, output and
  operation lifecycle. No application build was produced.
- **Checks / evidence:** Inspected `file-pickers.vala`, `path-breadcrumb.vala`,
  `app-controller.vala`, `main.vala`, `general-tab.vala`, codec tabs/presets/utils,
  optimizer APIs/cache, converter/runner, naming helpers and relevant docs.
  Reviewed the plan for consistency with the user's latest folder/no-menu and
  disabled-tab instructions; checked documented existing files and symbols.
- **Findings:** The following open design constraints must be addressed before
  claiming the new folder feature works. They are not reproduced runtime bugs.

#### BULK-F1 — Full optimizer parity requires shared prepared data

- **Severity / status / owner:** Medium; open; unassigned implementation owner.
- **Evidence:** `CodecPresets.apply_smart_*` configures more codec settings than
  the trim-specific `CodecUtils.build_smart_codec_args`. `Converter.start_conversion`
  and `snapshot_config` still require live codec/General widgets. General timing
  is a separate snapshot; optimizer and runner helpers also read global runtime
  preferences. Source review was corroborated by `bulk_optimizer` and `bulk_pipeline`.
- **Impact on proposed feature:** Reusing the reduced helper or copying one
  main-window source state could omit optimizer tuning, timing or per-file audio
  and could change settings midway through a batch.
- **Next action:** Extract complete shared profile/request resolution, capture
  timing/runtime preferences, deep-copy job settings and probe each source.
  Verify normal-path parity across all four codecs before integrating bulk.
- **Verification:** Not implemented or runtime-tested; see plan phases 1 and 3.

#### BULK-F2 — Directory input must bypass single-file consumers

- **Severity / status / owner:** Medium; open; unassigned implementation owner.
- **Evidence:** `FilePickers.on_input_browse_clicked` opens files only; drop
  handlers check video extensions. `AppController.wire_file_input_changed`
  unconditionally loads file consumers and resets crop/logo state.
  `BaseCodecTab.update_source_file_size` queries size without a folder-mode
  policy. `bulk_ui` independently reviewed these paths.
- **Impact on proposed feature:** Simply placing a folder path in the current
  input would invoke file-oriented probes/previews, could lose General values
  and could use directory metadata as a source-size target.
- **Next action:** Add explicit source classification, folder picker/drop,
  asynchronous enumeration, disabled-tab handling, non-destructive detector
  invalidation and per-file size/audio resolution.
- **Verification:** Not implemented or runtime-tested; see plan phase 2.

#### BULK-F3 — Per-item completion cannot release or restart a stopped batch

- **Severity / status / owner:** Medium; open; unassigned implementation owner.
- **Evidence:** Main operation reset can drain queued Auto-Convert work;
  `AppController.run_smart_optimizer` needs a shared bulk-admission guard.
  `ConversionRunner.run` can consume optional collage/finalization cancellation
  and still report conversion success. Output uniqueness must include other
  queue items and all source aliases, extending single-file naming concerns.
  `bulk_ui` and `bulk_pipeline` supplied independent lifecycle/output reviews.
- **Impact on proposed feature:** Naive per-file dispatch could overlap other
  operations, launch the next file after cancellation, or collide with another
  queued input/output.
- **Next action:** Reserve the whole queue as one operation, use independent
  queue stop/generation identity, wait for terminal cleanup, enforce handler
  admission, and reserve safe paths for all inputs, outputs and sidecars.
- **Verification:** Not implemented or runtime-tested; see plan phases 4 and 5.

**Historical issue requiring revalidation:**
`quality-mode-vmaf-measurement-findings.md` documents an earlier unresolved VMAF
alignment/measurement issue. This pass did not reproduce it or determine its
current status. Do not claim it fixed or close it based on this plan; include
its full-length failing-range scenario when validating quality-mode parity.

**Limits / handoff:** No builds, automated tests, live conversions or desktop
checks. The plan was reviewed statically; two reviewers identified the same
Ready-for-review eligibility ambiguity, which the primary agent corrected.
Existing DevTools changes were neither modified nor audited. Findings remain
open design actions for the eventual implementing agent; planning is complete.

### AUD-20261102-agent-handoffs — Documentation consistency review

- **Task:** `TASK-20261102-agent-handoffs` in `CHANGELOG.md`.
- **Agent:** Codex, primary chat. A Codex review subagent separately recommended
  coordination rules; that review was advisory, not application verification.
- **Date:** 2026-11-02 16:04 America/Phoenix (UTC-07:00).
- **Revision / build:** Base `1409c0c` on `main`, with uncommitted documentation
  changes; no application build was produced.
- **Scope:** The multi-agent additions to `AGENTS.md` and initialization of
  `docs/CHANGELOG.md` and `docs/AUDIT.md`.
- **Checks / evidence:** Read the current guide and repository status; confirmed
  both logs existed and were empty. Checked the drafted workflow for ownership,
  attribution, shared-log/build coordination, finding status, validation limits
  and handoff details. Checked the final documents for consistent log paths and
  task IDs and preservation of unrelated files.
- **Findings:** None within this documentation-only scope; no application
  correctness, security, performance or visual audit was performed.
- **Limits:** No build, automated tests or manual desktop tests. No claims about
  earlier changes or existing `DevTools` modifications.
- **Next actions / owner:** None; documentation task completed by Codex.

### Audit entry format

```text
Audit ID / related changelog task:
Agent / session / timestamp and timezone:
Scope / affected revision, build, branch or worktree:
Checks actually run / evidence / results:
Findings: explicit none within scope, or for each issue:
  Finding ID / severity / status / owner (or unassigned):
  Affected files / impact:
  Evidence / reproduction steps:
  Recommended or completed action / related change or commit:
  Verification results / remaining limits:
Skips / unverified assumptions / testing limits:
Next actions / handoff owner:
```
