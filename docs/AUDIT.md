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
| RECENT-F1 | Low / open, test coverage | Unassigned | Keep the main-window recent-folder integration and async/monitor edge checks in a permanent regression target; see TASK-20261109-recent-folders-audit. |
| BASELINE-F1 | Medium / open, pre-existing | Unassigned | Investigate the mpv-backend timeout with appropriate local audio/runtime access. |
| SO-F1 | High / fixed; knee stop awaiting real-media verification | Unassigned | Run Ultra on a source that cannot reach VMAF 97 (1080p animation) and confirm the knee stop. |
| SO-F4 | Medium / open | Unassigned | Loosen the two-pass VBV cap and add a post-encode size correction. |
| SO-F5 | Medium / open, design | Unassigned | Derive effort, preset, ladder and audio share from bitrate density, not megabytes. |
| SO-F6 | Medium (run time) / open | Unassigned | Skip or shorten CRF calibration when two-pass is certain. |
| SO-F7 | Medium / open | Unassigned | Size the VMAF reference budget from output dimensions and free space. |
| SO-F8–SO-F10, SO-F12 | Low / open | Unassigned | See the report. |
| SO-F11 | Medium / partly fixed | Unassigned | Timestamp rebasing is in; re-run the original failing range, then add the frame-count and sanity checks. |
| SO-F13 | Medium / open, design limitation | Unassigned | Fractional targets are feasible; see [feasibility audit](smart-optimizer-fractional-target-audit.md) before implementation. |
| SO-F14 | Medium / open, pre-existing | Unassigned | Align the optimizer’s 80 kbps feasibility floor and post-margin recommendation with the resolver’s 100 kbps minimum; see the fractional-target audit. |

`SO-*` details: [smart-optimizer-audit-20261109.md](smart-optimizer-audit-20261109.md).

Historical quality/frame-alignment findings remain in
`quality-mode-vmaf-measurement-findings.md`. A flat curve of the same kind was
reproduced and fixed in AUD-20261109-vmaf-threads-model; the original
full-length failing range itself has not been re-run. No application-wide audit is implied.

When an issue is found, add its finding ID, severity, status, owner, next action
and a link to its detailed entry below. Keep this index current as findings are
fixed, verified, deferred or reopened; retain the history below.

## Audit history

### TASK-20261109-recent-folders-publish — Publication follow-up

- **Agent/date/base:** Codex; 2026-11-09 18:11 America/Phoenix (UTC-07:00);
  main at 7242896 plus the reviewed changes.
- **Status:** The user subsequently requested publication of the folder-history
  feature and audit. Both are included in the accompanying commit; earlier
  local-only status statements describe the state when those checks ran.
- **Scope/limits:** No new application changes or audit conclusions. RECENT-F1
  remains open. Checked the final diff and remote base; prior runtime results
  remain the validation evidence. See the matching changelog publication entry.

### TASK-20261109-recent-folders-audit — Review of folder history

- **Agent/date/base:** Codex; 2026-11-09 17:38 America/Phoenix (UTC-07:00);
  main at 7242896 plus the uncommitted recent-folder implementation.
- **Scope/result:** Reviewed all implementation/test/documentation changes,
  settings load/save and pruning, stable menu slots and monitors, input admission,
  asynchronous classification, and MainWindow/AppController folder handling.
  No functional regression found within the reviewed and exercised scope.
  Existing file history remains compatible; directory classification happens
  before media-extension checks, and only accepted inputs enter history.
- **Fresh runtime evidence:** A disposable build using the current application
  sources, including the real MainWindow and AppController, passed 29 assertions
  on the local Wayland display. Scratch copies only renamed the entry point and
  exposed inspection helpers; repository application/test sources were unchanged.
  Checked recent-folder activation and completed rescan, visible bulk panel,
  disabled trim/playback, return to file mode, child deletion retaining its parent,
  two rapid selections recording only the latest, a lock applied during resolution
  preventing acceptance/promotion, symlink labels and reopening, automatic pruning
  after rename (including a broken symlink), and a former directory replaced by a
  regular file being reclassified correctly. Disable-history clearing also passed.
- **RECENT-F1 (low, open, test coverage; owner unassigned):** The checked-in
  recent-menu test constructs FilePickers/HamburgerMenu in an application window;
  its Meson target excludes main.vala and app-controller.vala. It therefore cannot
  protect MainWindow's bulk-panel/tab wiring. The extra rapid-selection, late-lock,
  rename/symlink and type-replacement cases above also remain audit-only checks.
  All passed here; this finding concerns future regression protection, not a
  demonstrated product failure. Affected: meson.build:645 and
  tests/combine-window-state-test.vala:7214, at the base plus local changes.
  **Next action:** Add a maintained full-window smoke target and retain the useful
  async/monitor cases as focused regression tests; no urgent application fix needed.
- **Coverage correction (Codex):** The earlier implementation entry's statement
  that the bulk widget suite verifies main-window behavior was too broad. That
  suite covers component/controller behavior, not the actual MainWindow. The
  fresh scratch run above now supplies direct integration evidence for this audit,
  but does not close the permanent-coverage gap. Earlier evidence is preserved.
- **Previous checks distinguished:** The implementation's development build and
  full suite (28 OK, zero failures) were inspected, not rerun for this read-only
  review. The dedicated recent-menu test ran without skips; 108 headless combined
  widget skips remain excluded from desktop coverage.
- **Limits/design choices:** No network/removable filesystem or native chooser/
  mouse validation. Existing synchronous existence checks can wait on slow mounts;
  unavailable paths are pruned like missing files. Symlink aliases remain distinct
  lexical history entries, and older binaries prune folders from the shared key.
  These are existing policies or unmeasured limits, not new reproduced failures.
- **Artifacts/status:** /tmp/ffgtk-recent-audit-v3yuj81_/audit.vala, sources.json,
  compile.log and run.log. The scratch build had three existing application Vala
  warnings plus one unused renamed-entry-point warning; runtime emitted local
  Vulkan-driver notices. Settings/cache/temp and the synthetic video were isolated.
  No user media/preferences changed, no installation, commit or push. Audit complete;
  only shared documentation changed during this review.

### TASK-20261109-recent-folders — Folder history implementation and validation

- **Agent/date/base:** Codex; 2026-11-09 17:28 America/Phoenix (UTC-07:00);
  main at 7242896 plus this task's local changes.
- **Scope:** Optional recent-input storage/validation, stable hamburger slots,
  guarded folder reopening, preference wording, persistence/pruning and tests.
- **Result:** Files and directories share history without a settings migration.
  Folder paths reach FilePickers.request_input and its async filesystem-type
  classifier; existing folder-mode handlers do the rest. Only accepted FILE or
  FOLDER states are recorded. Folder entries cannot enable video playback or
  bypass input locking. No additional unresolved defect identified in this scope.
- **BASELINE-F2 follow-up (verified test fix):** Existing recent-menu assertion
  inspected MRU history immediately after clicked(), before query_info_async
  accepted the new source. Added a bounded wait for FILE acceptance and promotion.
  Both the focused run and full-suite dedicated GTK run now pass; production
  file-history behavior was not changed to make the test synchronous. The original
  failure and investigation entry below are retained for evidence.
- **Checks:** Development build succeeds with three existing Vala warnings;
  focused combine-window-state, bulk-conversion-widgets and
  hamburger-recent-menu-rebuild pass. Full suite: 28 OK, zero failures. Mixed
  history and persistence/disable/clear data cases pass. Dedicated menu and bulk
  GTK tests have no skips; 108 headless combined-suite widget skips are not
  counted as desktop coverage.
- **Desktop evidence:** Actual mapped GTK menu with fatal warnings enabled;
  button signals drive folder reopening, return to file mode, playback gating,
  blocked operation/admission paths and deleted-folder rejection. Folder fixture
  includes spaces, Unicode, a semicolon and a media-looking extension. Existing
  bulk widget suite verifies main-window folder behavior. No native mouse/chooser
  or installed release smoke run is claimed.
- **Limits/status:** Local uncommitted implementation. Original settings keys
  retained; older binaries still prune directories according to their old rules.
  Network-filesystem monitoring and symlink alias deduplication were not newly
  tested. Test settings isolated; no external media accessed or preferences changed.
  BASELINE-F1's suite passes here, but its historical root cause was not investigated.

### TASK-20261109-fractional-target-audit — Fractional target feasibility

- **Agent/date/base:** Codex; 2026-11-09 15:55 America/Phoenix (UTC-07:00);
  main at 031acf6, project worktree. Earlier local rounding-investigation
  additions in both shared logs were preserved.
- **Scope/result:** Read-only review of target controls, settings persistence,
  optimizer numeric types, single-file snapshots, folder/trim flows, cache,
  reporting and tests. Fractional targets are feasible with moderate integration
  effort; the fit and budget math already support fractional sizes. Full manual
  and Match Source support is estimated at 3–5 focused working days including
  validation, not a delivery promise.
- **Report:** [smart-optimizer-fractional-target-audit.md](smart-optimizer-fractional-target-audit.md).
  Includes design alternatives, byte-based representation, settings migration,
  bounds/unit decisions, code anchors, phased scope and acceptance criteria.
- **SO-F13:** Remains open as an intentional design precision limitation.
  The draft recommends exact requested bytes with decimal MiB controls, keeping
  the present minimum initially. Final output-size uncertainty still applies.
- **SO-F14 (medium, open, unassigned):** The early optimizer check accepts an
  available video budget of 80 kbps, then Tiny/Small applies a 3% margin;
  all four SmartCodecResolver branches clamp applied bitrate to at least
  100 kbps. Confirmed by source at smart-optimizer-logic.vala:478,
  smart-optimizer.vala:571 and smart-codec-resolver.vala:178/257/301/342.
  A below-100 recommendation may therefore be raised when applied. Relevant
  to smaller budgets but not the user's 543 kbps example. No failing output
  reproduced. Next action: align planning/feasibility with the actually applied
  rate, accounting for the margin, and test the boundary before widening bounds.
- **Checks/limits:** Static source and history review plus arithmetic spot checks;
  report references and whitespace checked. No application edits, build, test
  suite or media access in this audit. The user subsequently requested
  publication of the draft and its supporting audit/changelog records.

### TASK-20261109-match-source-rounding — Small-file Match Source undershoot (SO-F13)

- **Agent/date/base:** Codex; 2026-11-09 15:44 America/Phoenix (UTC-07:00);
  main at 031acf6, clean at start.
- **Severity/status/owner:** Medium; open, pre-existing; unassigned.
- **Evidence:** User-provided SVT-AV1 Size Mode log requests 1024 KiB, plans
  997 KiB and reports 948 KiB actual. A metadata-only stat of the named source
  gives 1,572,679 bytes (1535.819 KiB, 1.499824 MiB), just 185 bytes below the
  1.5 MiB rounding boundary. `match_source_target_mb` rounds to a whole MiB,
  so this input becomes a 1 MiB target, already 33.3% below its source size.
- **Affected code:** `src/optimizer/smart-optimizer-logic.vala:673`, including
  the similarly rounded trimmed-window helper; `AppController` resolves the
  source byte count through this helper before starting the optimizer.
- **Attribution:** The untrimmed helper is identical at fe740b3 and 031acf6.
  The recent VMAF and knee/flat-ladder changes run in Quality Mode, whereas
  this log is Size Mode. The dominant loss is target rounding, not evidence
  that calibration could not characterize this source.
- **Remaining undershoot:** Tiny targeting reduces the available video
  bitrate by 3%. The plan reserves 46 KiB of container overhead; the output
  log implies roughly 7 KiB. The final 948 KiB is 7.4% under the rounded
  request and 4.9% under the 997 KiB plan, within its stated +/-8% range.
  Calibration verification itself differed from the model by only -0.2%.
- **Next action:** Carry precise bytes or fractional KiB through Match Source
  target resolution, budgeting, reporting and trimmed-window scaling. Keep
  rounding only for display. Add boundary coverage around 1.5 MiB, small
  sources and fractional trimmed targets; consider match-source versus hard
  upload-limit safety margins separately.
- **Checks/limits:** Read the supplied log, source and historical helper;
  stat source metadata and recompute arithmetic. No media decoded, no encode,
  build, test run or application-code change. Log does not independently
  expose the Match Source toggle; user reports it was enabled. Documentation
  findings are included with the fractional-target feasibility publication.

- **Historical clarification (2026-11-09 15:47, Codex):** The rounding is intentional
  and documented from the original Match Source feature, commit `6d07d59`
  (2026-07-24). Its helper comment explicitly says the optimizer only accepts
  integer MB targets. Before that commit, the solver already took `int
  target_mb = 4`, the controls advanced in 1 MB steps, and the preference was
  an integer. Match Source reused that existing target path. The original
  README promised roughly the starting size and explicitly described nearest
  whole-MB rounding; regression tests deliberately check both rounding up and
  down. Thus SO-F13 describes a small-file precision limitation of the design,
  not an accidental implementation regression. The supported rationale is
  compatibility with the existing integer target model; no inspected commit
  evidence attributes rounding to an encoder or quality requirement. Source
  and historical diff inspection only; no implementation change.

### AUD-20261109-quality-floor-guard — Fix and verification for SO-F1

- **Task/agent/date/base:** TASK-20261109-quality-floor-guard; Claude Code;
  2026-11-09 15:15 America/Phoenix (UTC-07:00); main at fe740b3 with uncommitted changes.
- **Flat-ladder rejection (verified):** with the timestamp rebase removed by an
  FFmpeg wrapper, the 720p-to-4K run measured 48.07 / 47.97 / 47.60, stopped
  after three probes and returned `is_impossible` with an explanatory message.
  Before this change the same measurement solved CRF 8 at a 358 MiB projection.
- **No regression (verified):** unfiltered 720p Medium still solves CRF 28 at
  91.15; 720p-to-4K Medium still solves CRF 32 at 91.25; a heavy-noise Ultra
  run reached its ceiling normally (CRF 17, 96.58).
- **Knee stop (fixed, awaiting verification):** unit tests only — a plateau of
  95.3 / 95.0 / 93.6 against a 97 target now solves inside CRF 14–20 instead
  of CRF 8, a reachable target on the same curve is unchanged, and a steep
  curve may still go below its window. No real run triggered it.
- **Checks run:** development build; full suite 27 OK, 1 failing (BASELINE-F2);
  the scratch harness from AUD-20261109-vmaf-threads-model, x264, isolated
  directories.
- **Limits:** one fixture, x264, 8-bit, no GUI run, thresholds not
  corpus-calibrated. The low-CRF "must be near-transparent" bound and the
  frame-count check from SO-F11 are still absent.

### AUD-20261109-vmaf-threads-model — Fix and verification for SO-F2, SO-F3, SO-F11

- **Task/agent/date/base:** TASK-20261109-vmaf-threads-model; Claude Code;
  2026-11-09 14:45 America/Phoenix (UTC-07:00); main at fe740b3 with uncommitted changes.
- **SO-F2 (verified):** every libvmaf invocation in three real Quality Mode
  runs carried `n_threads=16` on a 24-thread machine; previously 1.
- **SO-F3 (verified):** a 4K source scaled to 1280 wide was scored with the
  standard model; a 720p source scaled to 3840 wide with
  `model=version=vmaf_4k_v0.6.1`. Unfiltered 720p scores are unchanged
  (96.71 / 92.18 / 84.12 at CRF 21 / 27 / 33 before and after).
- **SO-F11 (partly fixed):** the 720p-to-4K run reproduced a flat curve before
  the change: 48.07 / 47.97 / 47.60 at CRF 21 / 27 / 33, then CRF 8 at 48.19
  and a 358 MiB projection. The retained pair showed stream start times of
  0.167 s (reference) and 0.042 s (probe); libvmaf compared 383 of 384 frames.
  Scoring that same pair by hand gave 48.07 as shipped and 98.95 with
  `setpts=PTS-STARTPTS` on both inputs. After the change the run measured
  98.95 / 95.66 / 90.24 and solved CRF 32 at 91.25 (predicted 91.27).
- **Checks run:** development build; full suite 27 OK, 1 failing
  (`hamburger-recent-menu-rebuild`, see BASELINE-F2); a scratch harness built
  from the application sources calling `optimize_for_quality` (x264, Medium,
  audio stripped) on `tests/testvideo-raptor.webm` and a 4K upscale of it,
  with isolated XDG and temporary directories and an FFmpeg wrapper that
  logged arguments.
- **Limits:** one fixture, x264 only, 8-bit, no GUI run. Why the two stream
  start times differ was not established, only that rebasing removes the
  effect. The original gymnastics range was not available and not re-run, so
  SO-F11 is not closed. Frame-count and sanity-bound checks are still absent.

#### BASELINE-F2 — hamburger-recent-menu-rebuild fails on this desktop

- **Severity/status/owner:** Low; open; unassigned.
- **Evidence:** `/hamburger/recent-inputs/repeated-refresh-is-stable` aborts
  with "clicking a recent-file slot promotes it in history expected
  '…/recent-18.mkv' but got '…/recent-19.mkv'", three of three runs, on a live
  Wayland session at fe740b3 plus working-tree changes.
- **Next action:** Check against the base revision. It was not established
  whether this predates TASK-20261109-vmaf-threads-model; the case does not
  touch optimizer code.

### AUD-20261109-smart-optimizer — Smart Optimizer design and code audit

- **Task/agent/date/base:** TASK-20261109-smart-optimizer-audit; Claude Code;
  2026-11-09 14:12 America/Phoenix (UTC-07:00); main at fe740b3 with the
  uncommitted folder-conversion changes.
- **Scope:** `src/optimizer/` in full, `smart-codec-resolver.vala`, the optimizer
  call sites and two-pass builder arguments. Read-only; no source changed.
- **Results:** Twelve findings, `SO-F1`–`SO-F12`, all open and unassigned. Report:
  [smart-optimizer-audit-20261109.md](smart-optimizer-audit-20261109.md).
- **Checks run:** Four FFmpeg experiments on `tests/testvideo-raptor.webm`
  (FFmpeg n9.0.2, SVT-AV1 4.2.0): libvmaf thread scaling (SO-F2), VMAF model
  comparison (SO-F3), two-pass with and without the VBV cap (SO-F4), and
  `film-grain-denoise=1` as a cause of the flat VMAF curve (ruled out, SO-F11).
- **Limits:** No build, test suite or application run. No 4K, HDR or
  multi-file corpus. SO-F1 and SO-F5–SO-F10 rest on reading the code and the
  project's own records; SO-F12 was not reproduced. The historical failing
  range in `quality-mode-vmaf-measurement-findings.md` was not re-run.

### AUD-20261102-bulk-actions-implementation — Implementation and verification

- **Task/agent/date/base:** TASK-20261102-bulk-actions-implementation; Codex primary;
  2026-11-02 21:18 America/Phoenix (UTC-07:00); main at fe740b3 with uncommitted changes.
- **Scope:** Existing Convert/Optimize actions for folders, per-file retained settings,
  explicit edits, manual profiles and related lifecycle/audio/output behavior.
- **Results:** Build passes; full suite has 27 OK, no assertion failures, and the
  pre-existing mpv-backend timeout (30 seconds, audio/runtime permission message).
  Bulk coverage across focused runs: 31 cases pass, including all four codecs in
  manual CRF and manual bitrate two-pass, real output decoding, no optimizer/VMAF
  dependency for Convert, profile parity, edits back to original values, mixed audio,
  partial analysis/stale sources, retries and cancellation. Four shared GTK cases pass.
- **Desktop evidence:** Actual rebuilt app on Wayland with isolated XDG preferences
  and synthetic inputs, driven by its MainWindow/AppController handlers. Direct
  Convert, both Auto-Convert states and later Convert with edited CRF work; two
  files keep different optimized GOP values. Eight outputs fully decode. Input
  returning to FILE restores Convert and all source-page sensitivities. No staging
  remains. Native chooser/mouse coverage is not established.
- **Shutdown/runtime limits:** A direct debugger gtk_window_close call stalled in
  Wayland roundtrip / GTK Vulkan renderer teardown while stopped in the event loop.
  That idle test process was terminated. A fresh instance closed and exited normally
  when the close action was scheduled through GTK's event loop. This is a driver
  limitation in this check, not proof of a production close defect. The private
  test bus also reported an accessibility registry warning. Active desktop close,
  historical VMAF ranges and mpv timeout root cause remain outside this validation.
- **Report/artifacts:** [manual-bulk-conversion-findings.md](manual-bulk-conversion-findings.md).
  Isolated build logs: manual-full-suite-final.log, manual-widgets-verified.log,
  manual-two-pass.log, manual-build-release.log. No supplied external media accessed.

#### MANUAL-BULK-F1 — Disabled psycho-visual options rejected by FFmpeg

- **Severity/status/owner:** Medium; verified fixed; Codex primary.
- **Affected revision/files:** fe740b3, x264-builder.vala and x265-builder.vala.
- **Evidence:** Real manual encodes rejected x264-params containing bare no-psy and
  x265-params containing bare no-psy-rd with an invalid argument error. Independent
  short FFmpeg invocations reproduced both failures before the correction.
- **Fix:** Emit psy=0 and psy-rd=0 respectively, retaining the intended disabled
  setting in FFmpeg-compatible key/value syntax. Included in the implementation task.
- **Verification:** Real manual CRF and two-pass encodes pass for x264 and x265,
  command assertions verify the corrected values, and full output decoding passes.
  Shared four-codec resolver's 40 frozen-profile expectations remain passing.

### AUD-20261102-bulk-actions-plan — Revised action-sequence planning review

- **Task/agent/date/base:** TASK-20261102-bulk-actions-plan; Codex primary;
  2026-11-02 20:50 America/Phoenix (UTC-07:00); main at fe740b3.
- **Scope/evidence:** Reviewed AppController's single-file recommendation application
  and Auto-Convert routing, and bulk-conversion.vala's ready branch and execution.
  Bulk analysis currently discards its resolved local profile on the ready branch;
  subsequent Convert repeats analysis. Matching the requested normal workflow
  therefore needs retained per-file executable settings, not only manual conversion.
- **Disposition:** Revised [plan](manual-bulk-conversion-plan.md) includes distinct
  existing actions, retained settings, explicit user-edit overrides, stale-result
  checks and tests that assert no analysis on Convert. Supersedes the previous
  plan's mode selector and disabled optimizer controls. No new runtime defect
  established; these are requirements for the requested behavior extension.
- **Limits/handoff:** Static review and documentation checks only; no code changes,
  builds or tests. Implementation/runtime validation unassigned. Existing baseline
  mpv and historical VMAF findings unchanged.

### AUD-20261102-manual-bulk-plan — Manual mode planning review

- **Task/agent/date/base:** TASK-20261102-manual-bulk-plan; Codex primary;
  2026-11-02 20:18 America/Phoenix (UTC-07:00); main at fe740b3.
- **Scope:** Source-informed [manual bulk plan](manual-bulk-conversion-plan.md).
  Read main.vala request capture/routing, bulk-conversion.vala preparation/preflight,
  codec-builder.vala, base-codec-tab.vala, codec-utils.vala profile composition,
  Converter snapshot configuration and audio compatibility helpers.
- **Evidence/design constraints:** Generic codec snapshots omit full encoder-builder
  arguments; these must be captured for manual mode. Current per-item preparation
  always runs optimization and config/status paths depend on its context/results.
  Manual preflight must check the requested pixel format and bypass quality-mode
  libvmaf checks. Shared profile composition already provides audio-container
  fallback; each source still needs fresh audio metadata and processing checks.
- **Findings:** No new runtime defect established. These are planned extension
  requirements, recorded in phases 1–4 rather than claims of implemented fixes.
  Plan includes mode-switch stale-state guards, completed-item retry semantics,
  supported two-pass validation, parity tests and real conversion/desktop checks.
- **Checks/limits:** Static review and documentation path/whitespace checks only.
  No build, tests, media access or UI execution. Existing mpv and historical VMAF
  limitations remain unchanged. Implementation and runtime validation unassigned.

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
