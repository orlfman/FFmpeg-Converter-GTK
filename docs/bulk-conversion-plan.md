# Folder-based Bulk Conversion — implementation plan

Status: implemented; automated synthetic validation complete. Final full-suite result and desktop limits are recorded in AUDIT.md.
Date: 2026-11-02, America/Phoenix.
Task: `TASK-20261102-bulk-conversion-plan`.
Source baseline: `1409c0c` on `main`; implementation changes are uncommitted.
Implementation task: `TASK-20261102-bulk-implementation`.

## Implementation progress — 2026-11-02

- **Done: phase 1a.** Added deep-copy support for nested General/filter/codec/
  keyframe/profile snapshots and `CodecUtils.compose_encode_profile`, which
  composes the complete existing execution profile from captured data without
  changing caller settings. The ordinary UI adapter still reconciles effective
  pixel format before capturing builder arguments, using its own General copy.
- **Verification:** Development application builds; eight new headless profile
  regression cases pass. Corrected, isolated baseline: 20 suites pass and one
  mpv-backend timeout. Modified build: 21 suites pass and the same timeout.
  Display-dependent cases skip without a working display. Independent static
  review found no source/test issues in this slice.
- **Done: phase 1b.** Shared four-codec recommendation resolution and GTK
  adapters match 40 frozen pre-refactor full profiles. Six new pure tests and
  two isolated-display tests pass. Captured General filter-depth variants preserve
  per-job output depth without mutating shared settings.
- **Done: phases 1c–5.** Captured runtime/prepared execution, tracked probes,
  folder selection, sequential queue, full recommendation resolution, atomic
  no-clobber publication, retained results/retries, cancellation and main-window
  actions are implemented. Crop & Trim/Audio/Subtitles are disabled in folder mode.
- **Verification:** Seventeen bulk tests pass on an isolated GTK display, including
  real short conversions in all four codecs for both size and measured quality,
  rotated crop, late collage cancellation, retries, source aliases and collisions.
  Full-suite results and remaining desktop coverage are in `AUDIT.md`.
- **Implementation choices:** Stable bytewise filename ordering; top-level scan;
  private per-run staging with per-item names; atomic hard-link publication on the
  destination filesystem. Unsupported publication filesystems fail safely.
  Ready/unfinished items are conservatively reanalyzed on Convert, using the
  optimizer cache. Completed items are skipped for the same folder/destination;
  Rescan explicitly starts a new queue. Choosing a different input/destination
  establishes a new queue. Queue state is not persisted across app restarts.
- **Post-implementation audit:** Fixed per-sample timed-logo calibration and stale
  Convert sensitivity after detection (`BULK-F4`/`BULK-F5`). Nineteen bulk cases pass,
  including a real frame-hash expectation for moving-logo windows. Historical
  long-range VMAF/frame-alignment findings remain outside these short checks.
- **Privacy:** No supplied private media was accessed, converted or uploaded.
  Generated test media and outputs stayed in isolated disposable directories.

## Agreed behavior

The existing input accepts either a video file or a folder. A folder supplies
the videos for a sequential bulk conversion using the selected codec, full
Smart Optimizer functionality, and General settings.

- **No new hamburger-menu item.** Folder selection belongs in the existing
  input row. The earlier separate Bulk Conversion window/menu proposal is
  superseded by this folder-based design.
- **Crop & Trim, Audio and Subtitles tabs are disabled while a folder is
  selected.** Their source-specific editing and playback are unavailable.
- General and the four codec tabs remain available for configuration before
  starting. Smart Optimizer's audio handling, including No Audio, remains
  available through the codec settings.
- Process one file completely before beginning the next file: probe, optimize,
  encode, validate, optional collage, and cleanup. No analysis of the next file
  while the current file is converting.
- Each video gets its own analysis and recommendation. The first file's CRF,
  bitrate, source size, detected content or audio observations must never become
  the defaults for the rest of the folder.
- The user authorized a plan audit followed by implementation on 2026-11-02.
  A later request authorized the final audit, fixes, commit and GitHub push; installation remains outside the request. Shared findings
  are recorded in `AUDIT.md`; current work is tracked as
  `TASK-20261102-bulk-implementation` in `CHANGELOG.md`.

## Proposed defaults

These resolve unspecified details for implementation and can be adjusted during
review; they are not additional requirements already confirmed by the user.

| Decision | Proposed behavior |
| --- | --- |
| Folder scope | Videos directly inside the selected folder; no recursive subfolder traversal in the first release. |
| Ordering | Stable bytewise filename order. |
| Candidate selection | Reuse `VideoFileConstants.VIDEO_EXTENSIONS`, case-insensitively; verify an actual video stream when each item is probed. |
| Output | Honor an explicitly selected Output Folder. When blank, use a visible `Converted` subfolder inside the input folder; show this resolved destination before starting. |
| Existing output | Choose a unique filename by default; never overwrite a queued source, even when overwrite is generally enabled. |
| Item failure | Continue after source-specific failures. Stop dispatch on run-wide configuration/output failures (including disk full or an unavailable destination), retaining unstarted items. |
| Cancellation | Stop the current item and further dispatch; retain completed outputs and leave unstarted items queued. |
| Persistence | Queue/results live for the current application session; no crash-resume database or background service. |

Recursive scanning, per-item settings editors, parallel encoding and a separate
bulk window are outside the first implementation. They are not prerequisites
for complete Smart Optimizer support.

## User flow

1. The input row is labeled **Input** and offers **Select File** and
   **Select Folder** through adjacent controls or a split browse control.
   Dragging a local folder into the same input area also works.
2. Accept folder selection only when the application is globally idle, including
   optimizer, pending preflight and auxiliary operations; reject a busy transition
   without changing the current input. Selecting a folder enters folder mode,
   retires the previous file's previews
   and probes, and disables Crop & Trim, Audio and Subtitles. If one of those
   tabs was selected, move to a usable tab such as General before navigation
   side effects run. Guard programmatic tab changes too: disabled pages must not
   clear keep-all-audio choices or apply trim timing locks.
3. Show a compact, scrollable queue below the input controls: folder name,
   candidate count, destination, active codec at Start, and rows for file/status/result.
   The Information tab may show the folder summary; it must not probe the
   directory as a media file. Console remains available for detailed logs.
   When the output is blank, its folder-mode placeholder explains the proposed
   `Converted` subfolder default; restore “Same as input” for single-file mode.
4. Configure General and the chosen codec's Smart Optimizer settings. Show
   “These settings apply to every file; each file is optimized separately.”
5. With a codec selected, **Convert Folder** captures the settings and processes
   the folder sequentially. It always includes Smart Optimization. The batch
   summary identifies the chosen codec; do not silently choose one when no
   encoder has been selected.
6. Preserve the existing **Optimize / Auto-Convert** contract: in folder mode,
   Optimize with Auto-Convert on performs the same sequential optimize-and-encode
   run; with Auto-Convert off it analyzes each item and stores its recommendation
   as **Ready for review**, not Completed. Convert Folder revalidates and conservatively reanalyzes unfinished items,
   reusing optimizer cache measurements when valid. An explicit Convert
   action is a request to convert,
   regardless of the automatic-start toggle.
7. While processing, lock input/output and settings controls for that run and
   keep Cancel available. The backend also uses snapshots and ownership guards;
   widget sensitivity alone must not enforce correctness.
8. Show `File 3 of 12`, current filename, current stage and per-file progress.
   Use item counts for total progress; do not imply equal-duration files or a
   reliable total ETA. Keep completed, failed, skipped and cancelled outcomes
   visible, with output-folder actions and a final summary.
9. A later Convert processes queued/retried and Ready for review items, reusing
   the optimizer cache when valid. Completed items are not automatically re-encoded.
   Re-scan is an explicit idle action for a new run.
   Selecting a single file restores the normal workflow and the disabled tabs.

## Preserve all Smart Optimizer behavior

Full support means using the existing measurement pipeline and applying its
complete recommendation, including details that are not visible as separate
bulk controls:

| Capability | Folder behavior |
| --- | --- |
| Codecs | SVT-AV1, x265, x264 and VP9, using the selected encoder tab. |
| Target Size | Apply the requested target independently to each output, not as a total folder-size budget. |
| Match Source Size | Compute from each video's size; use the existing proportional target calculation for a General seek/duration window. Never use the directory's size. |
| Quality Ceiling | Low/Medium/High/Ultra retain maximum VMAF 88/92/95/97 semantics; quality and size are mutually exclusive objectives. |
| Content Type | Auto-detect, Live-action, Anime/Animation and Screencast/Static overrides apply to each run. |
| Optimize for Streaming | Preserve delivery/fast-decode tuning together with the selected objective. |
| Audio | No Audio, effective track-preservation policy, copy compatibility, exact budgeted bitrate and re-encode requirements are resolved per source. |
| Output profile | Preserve resolved container, pixel format, bit-depth checks, CRF/bitrate, preset, effort, grain/detail/temporal tuning and single/two-pass decisions. |
| Measurement and cache | Preserve calibration, refinement, confidence, source/filter-specific cache identity and progress/report details. |
| Failures and attention | Impossible targets, failed quality measurement or bit-depth attention produce visible per-item outcomes; no silent fallback to an unoptimized encode or lower bit depth. |

Quality mode keeps its current objective-specific container and pass behavior;
do not impose size-mode container forcing or a two-pass size target on it.
Missing libvmaf prevents quality-mode processing, while size mode remains usable.
Resolve batch-wide tool/encoder/filter capability failures before processing all
items rather than repeating the same error for every file.

## General settings and source-specific state

Capture a deep copy of `GeneralSettingsSnapshot` **and**
`GeneralTimingSettingsSnapshot`. The former does not include seek/duration.
Include selected codec/user audio preferences, output naming options,
FFmpeg/FFprobe paths, overwrite policy, and optional collage settings in the run
snapshot. Deep-copy nested objects/arrays before resolving a job's output format.

Apply rotation, scale, crop, frame rate, video/audio speed, video filters,
color correction/HDR, metadata/chapters, text/image watermark and static/timed
logo-removal settings through the existing shared filter builders. Calibration
must use the same effective transformations as the actual encode.

- Validate geometry, effective frame rate, source duration and audio availability
  separately for every input. Clamp an end/duration at the source end using the
  existing timing semantics; a start at/past EOF is an explicit item failure.
- Crop coordinates and logo-removal regions are fixed settings applied to each
  source, not a detection result to recalculate implicitly. Reject invalid
  geometry for that source rather than silently cropping different content.
- General's Detect Crop/Detect Watermark/Detect Moving actions require a single
  source, so disable them in folder mode and guard their handlers. Keep manual
  crop/logo settings configurable. Automatic detection per file is a separate
  future feature, not implied by this plan.
- Selecting a folder must not erase General crop/logo settings. Cancel and
  invalidate outgoing detection callbacks separately from resetting user values;
  show that previously entered geometry will apply to every video.
- Clear the disabled tabs' source-specific state. Do not apply the previous
  video's audio/subtitle edits or Crop & Trim segments to the folder. Normal
  conversion's existing embedded-stream behavior remains the baseline; disabling
  the Audio tab does not disable audio in the output.
- Re-probe each job's audio streams, duration, bit depth, chapters and timed-stream
  topology. User audio preferences can be copied; cached observations about the
  previously selected file cannot.
- **Audio-processing precedence:** Preserve the current Smart Optimizer reset
  behavior: its codec appliers reset codec-local processing controls before
  resolving a recommendation. Bulk must use those effective defaults, not revive
  normalization/fade/downmix settings that the ordinary optimizer discards.
  General audio-speed settings and explicitly retained keep-all-audio choices
  still apply. Changing this reset policy for both workflows is a separate
  product change; extraction must not silently change single-file behavior.
- Shared image-watermark assets participate in signatures and cache validation.
  A changed/missing asset invalidates prepared work that depends on it.

## Current code and required refactoring

This is simpler in interface scope than a new bulk window. It still requires a
queue and careful separation of file-specific state from widgets.

| Existing code | Implication |
| --- | --- |
| `src/ui/file-pickers.vala`: `on_input_browse_clicked`, drop handlers | Browse currently opens files only; drops accept video extensions only. Add a folder picker and filesystem-type classification before extension checks. |
| `src/ui/path-breadcrumb.vala`: `changed`, async path state | Display metadata is private and becomes ready after `changed`; it cannot be assumed to be authoritative input classification. |
| `src/app/app-controller.vala`: `wire_file_input_changed` | Currently sends every path to media consumers and resets crop/logo values. Branch by resolved source mode first. |
| `src/encoders/base-codec-tab.vala`: `update_source_file_size` | Avoid treating directory metadata size as the Match Source Size target; display “Matched separately for each file.” |
| `src/optimizer/smart-optimizer.vala`: `optimize_for_target_size`, `optimize_for_quality` | Existing async engine can operate on each file. Give the queue its own instance; mutable tuning state makes concurrent reuse unsafe. |
| `src/app/app-controller.vala`: `SmartOptimizerRunSnapshot`, `run_smart_optimizer` | Extract reusable immutable request/context preparation from main-window state. Do not drive a batch through the main input entry. |
| `src/encoders/codec-presets.vala`: `apply_smart_*` | Contains full codec-specific recommendation application. Extract shared data-based resolution and preserve these settings. |
| `src/encoders/codec-utils.vala`: `build_smart_codec_args` | This reduced helper serves trim; it is not full parity with the normal appliers. Using it alone would drop some effort/grain/psy/ref/B-frame settings. |
| `src/app/converter.vala`: `ConversionConfig`, `start_conversion`, `snapshot_config` | Existing start still requires live codec widgets. Add a prepared-request entry point; retain the current single-file wrapper. |
| `src/runners/conversion-runner.vala`: `run` | Reuse encoding, normalization, two-pass, validation, optional collage and cleanup. Route runtime/output options through captured data instead of changing global settings. |
| `src/app/main.vala`: operation reservation, preflight, cancel/close | Own the complete batch as one operation; preserve admission and pending-dialog guards across item transitions. |
| `src/util/conversion-utils.vala`: naming and `find_unique_path_with_reserved` | Reuse naming policy, with batch-wide reservations and protection for all queued source identities. |

### Proposed data and service boundaries

Names below are proposed, not existing APIs:

- `InputSelection`: source kind (`NONE`, `RESOLVING`, `FILE`, `FOLDER`, `INVALID`),
  path, generation and cancellable. All input entry points use it.
- `FolderBatchSettings`: immutable selected codec, optimizer options, General
  settings/timing, user audio preferences and runtime/output options.
- `BulkItem`: stable ID, input path/signature, state, per-file probes,
  recommendation, resolved output, result/error and prepared-settings identity.
- `SmartOptimizationRequest` / request factory: per-file context, effective trim,
  audio policy, target/quality objective and captured runtime paths.
- Shared recommendation resolver: produces complete codec-builder snapshots and
  `EncodeProfileSnapshot`, reused by ordinary optimizer application and bulk.
- Prepared conversion request: input/output, `ConversionConfig`, runtime options,
  two-pass information and job identity; no live widgets required.
- `BulkConversionController`: sequential scheduler owning queue state, optimizer,
  conversion service, cancellation and terminal completion. Use small injectable
  service boundaries/delegates for meaningful state-machine tests.

Avoid a third independent implementation of encoder presets. Retain the existing
runner behind a request-based entry point rather than building another FFmpeg
runner. Existing single-file entry points become adapters to the same resolved
data/execution path, with parity verified before changing their behavior.

## Scanning, outputs and queue lifecycle

### Folder scanning

Enumerate asynchronously and classify actual filesystem type before applying
video-extension filters. Freeze a finite candidate list at Start; do not watch
for new videos or discover the outputs created by the running batch. Do not
follow directory symlinks or recurse. Deduplicate file aliases by file identity
where available. Cache signatures (path/size/mtime) are not alias identity:
use canonical paths plus device/inode or equivalent file IDs to protect hardlink
and symlink aliases. Check identity again before optimization and conversion.

An empty, unreadable, removed or invalid folder gets a clear status and cannot
start. A candidate with no decodable video stream fails individually. Cancelled
scans and late metadata callbacks cannot replace a newer input selection.

### Output safety

Resolve names from each source using existing naming modes and the recommendation's
effective container. Allocate random/date names once per job. Reserve output and
collage paths against existing files, other jobs and **every queued input**,
including resolved symlink/hardlink aliases. Reservations are planning state,
not atomic filesystem ownership. The current runner and collage builder use
FFmpeg `-y`, so a final existence recheck alone is insufficient.

For bulk, encode and generate sidecars inside an exclusively created per-run
staging directory with distinct per-item paths on the destination filesystem. Publish each completed artifact
using atomic no-replace semantics (for example Linux `renameat2` with
`RENAME_NOREPLACE`), allocating another final name on collision. Fail safely if
that guarantee cannot be provided. Never use check-then-rename or `-y` on a final
bulk destination. Keep the current single-file overwrite policy unchanged.
A successful video may be retained if its optional sidecar fails; report the
sidecar outcome separately. Test collisions introduced after initial reservation.

Never pass an input path as an overwrite destination. Stop/reject destructive
conflicts even if the ordinary overwrite preference is enabled. Only clean up
partial files and temporary directories that the current job demonstrably owns;
never delete pre-existing media. Report unusable/header-only outputs as failures
even when FFmpeg exits zero. Do not declare success before runner validation.

### State and exclusivity

Normal item flow:

```text
Queued → Probing → Optimizing → Preparing → Converting → Finalizing → Completed
                        └─ Ready for review (analysis-only run)
Ready for review → Preparing if still valid, otherwise → Probing → Optimizing
Any active stage → Failed / Needs attention / Cancelled
```

Add a folder-batch operation to main-window tracking and reserve it once for the
whole run, including preflight, optimizer, dialogs and item transitions. Check
ownership in action handlers and optimizer entry points as well as sensitivity.
Block competing conversion/trim/audio/subtitle/Combine/optimizer starts. Do not
drain an unrelated pending Auto-Convert request between items.

Coordinate Combine's existing locks: it modifies shared General controls and
clears/locks input when opened. Require it to close/release its constraints before
folder input is selected, and reject opening it while the batch owns the input.
Do not capture temporarily constrained General values as an intended batch profile.
Recent-item selection and other programmatic input changes must respect the
same ownership guard; disabling only the input widget is insufficient.

Use batch generation, item ID and per-run cancellables for callbacks. On Cancel,
set the queue's stop flag immediately, cancel the active probe/optimizer/encoder,
dismiss owned preflight dialogs, and wait for cleanup/terminal delivery before
releasing ownership. Never dispatch the next item after a stop request. Route
initial duration/FPS probes, output validation and collage-related probes through
the captured runtime paths and tracked cancellable execution too; the current
converter's initial synchronous probes are not covered by its encoder runner.

Late cancellation during collage/finalization can legitimately leave a successful
video: the existing runner may report success after consuming optional-phase
cancellation. Preserve that success, record the cancelled optional work, and
still stop the queue. App-close confirmation must use the same cancellation path
and wait for the owned work to finish. Completed outputs remain available.

## Implementation phases and exit criteria

### 1. Establish shared request/profile foundations

Split this work into independently verified slices:

1. **1a — Data/profile composition (first implementation milestone):** Add deep
   copies for nested General/filter/codec/profile snapshots. Extract a pure
   `CodecUtils.compose_encode_profile` accepting data and codec arguments. Keep
   `snapshot_encode_profile` as the ordinary UI adapter; stop modifying the
   caller's General settings. Characterize effective output with independent
   expectations, mutation-isolation tests and the existing regression suite.
2. **1b — Complete recommendation resolution:** Extract codec-specific snapshot
   resolution from all four `CodecPresets.apply_smart_*` appliers, including
   effort/grain/ref/B-frame/psy/audio/container decisions. Capture parity fixtures
   before replacing either path so tests do not compare the resolver with itself.
3. **1c — Runtime/request preparation:** Freeze timing, per-source audio, bit
   depth and metadata policy plus executable/output options. Pass captured
   options through optimizer/probe/naming/runner helpers that currently read
   `AppSettings` dynamically; cover all probes with tracked cancellation.

Completing slice 1a does not complete phase 1 or expose working folder conversion.

**Exit:** For representative recommendations across all four codecs, the new
resolver produces equivalent effective settings/arguments to the current normal
Smart Optimizer path, including effort and audio/container decisions. Existing
single-file regression tests pass. No folder UI is needed to prove this phase.

### 2. Add explicit input modes and folder scanning

Introduce the input-selection model, folder browse/drop, asynchronous scanner and
folder summary. Branch the controller before single-file probes. Disable and
clear Crop & Trim/Audio/Subtitles, preserve General values, and invalidate old
detectors. Guard single-file playback, recent-file history and source-size displays.

**Exit:** File → folder → file works without sending directories to media tools,
losing General settings, retaining old previews or leaking stale source state.
Folder selection starts no encoding until an explicit action.

### 3. Expose prepared conversion execution

Add the request-based converter start alongside the existing single-file wrapper.
Extract result-based audio-copy/bit-depth/capability preflight needed by bulk;
do not update the main codec widgets with another file's probe results. Keep
operation IDs, two-pass/passlog ownership, normalization, validation, collage and
cleanup behavior intact.

**Exit:** A prepared one-file job runs through the same conversion machinery as
the ordinary path, without reading or mutating live input/codec widgets.

### 4. Implement the sequential controller

Add per-file preparation, optimizer execution, full profile resolution, naming,
conversion, results and next-item dispatch. Support the existing Auto-Convert
and analysis-only behavior; prepared recommendations require matching source,
settings, runtime and asset identity before use. Implement failure policy,
retry/unstarted-item handling and stop-before-next dispatch.

**Exit:** Controlled fake services prove no overlap, correct per-file context,
no advancement before cleanup, and cancellation at every yield/terminal boundary.

### 5. Integrate main-window actions and reporting

Connect folder-mode Optimize/Convert Folder/Cancel, queue rows, count/stage
progress, final summary and successful output actions. Wire whole-batch ownership,
direct-handler guards, preference/control locking and app-close behavior. Keep
all controls inside the existing workflow; add no hamburger bulk action.

**Exit:** All agreed behavior is reachable through the ordinary input row and
codec tabs, and single-file behavior remains intact.

### 6. Validate and document

Register new sources and opt-in test targets in `meson.build`, including test
targets that enumerate application files explicitly. Extend `DevTools/SMOKE-TEST.md`
and README with folder scope, disabled tabs, optimizer behavior, output defaults,
cancellation and limits. Record implementation checks/findings in the shared logs.

**Exit:** Relevant and full regression suites pass, desktop smoke checks pass,
and real short conversions cover all four codecs where capabilities are present.
Report any missing encoder/libvmaf/display coverage explicitly. Do not replace
the existing installed application as part of validation.

## Local-only test media supplied by the user

Use these existing locations for manual bulk-processing tests once implemented:

- Input: `/mnt/storage1/local/projects/testvideofolder/`
- Explicit output: `/mnt/storage1/local/projects/testvideofolder/output/`

The input folder and its `output` subdirectory were confirmed to exist. Video
contents were not opened or inspected, and no conversion was run when recording
these locations. The explicit output folder takes precedence over the proposed
blank-output `Converted` default; do not create a replacement test destination.

The user's videos are private local test fixtures. Keep the originals and all
converted outputs, extracted frames/audio, collages, thumbnails and other derived
media outside the repository. Do not copy them into `tests/`, release archives or
other tracked locations, and do not commit or upload them to GitHub or another
external service. Keep test reports text-only and omit private filenames and
content; use anonymous item labels when sharing diagnostic output.

Exclude the `output` subdirectory from input discovery, including any future
recursive scanning. Do not modify source videos or clean existing output files;
new test runs must allocate unique output names. Reusable automated tests should
use synthetic fixtures rather than require access to these private videos.
These paths are local testing configuration, not hardcoded application defaults.

## Required verification matrix

- Input: file/folder chooser and drops, a folder named `example.mp4`, empty/missing/
  unreadable folder, mixed extensions, duplicate aliases, deterministic ordering,
  cancellation during scanning and stale results after switching input.
- UI: exact disabled-tab behavior and restoration; no directory probing/preview/
  recent-video entry; reject folder selection while other work is active;
  guarded programmatic tab navigation preserves audio choices and General locks;
  General values retained; Match Source uses per-item sizes;
  programmatic/recent selection cannot replace an active batch.
- Parity: one-file folder compared with ordinary Smart Optimize + Convert across
  codecs, size/quality, content/delivery, effort/grain, containers, pixel formats,
  No Audio and multi-track audio. Compare effective settings/commands rather than
  requiring byte-identical nondeterministic encodes.
- Settings: crop/scale/rotation/HDR/color/watermark/delogo, seek/duration on short
  files, separate audio/video speed, metadata/chapters, normalization and mutated
  global preferences after Start. Prove calibration and output agree.
- Isolation: no-audio then multi-audio inputs, different resolutions/durations/
  bit depths, changed source or watermark, cache hit and invalidation; no leakage
  of earlier recommendations, budgets or stream observations.
- Queue: no concurrent item work, explicit next dispatch, failure then success,
  retry without duplicating completed outputs, analysis-only then valid/stale
  prepared conversion, impossible recommendations and attention states.
- Outputs: same stems/custom/date/metadata names, existing destination/sidecar,
  path matching a later queued input, symlink/hardlink aliases, collisions created
  after preflight but before publication, source changes,
  unwritable output/disk-full failure stops further dispatch, owned staging cleanup
  and exit-zero but
  unusable output.
- Lifecycle: cancel during probe, optimization, pass 1/pass 2, preflight wait and
  collage/finalization; no next item after late success; close during work;
  conflicting manual Optimize/Convert/Combine actions; no leaked children or
  passlogs after terminal cleanup.

## Known investigation limits and handoff

`docs/quality-mode-vmaf-measurement-findings.md` records a historical unresolved
quality-measurement/frame-alignment problem. This planning pass did not reproduce
it or establish whether it persists at the current revision. Revalidate its
full-length failing-range scenario before claiming bulk quality parity; ordinary
short fixtures alone cannot close that report. Record any reproduced defect and
its fix separately instead of changing solver thresholds as part of queue work.

Initial planning was based on static source review, with read-only Codex reviewers
for optimizer behavior, input/UI ownership and conversion/output safety. No build,
test, media conversion or desktop check was run during that initial planning
pass. Subsequent implementation/validation is recorded above and in the
shared logs. The initial implementation
constraints are recorded as `BULK-F1`–`BULK-F3` in `AUDIT.md`.

Parallel work can split shared profile/request extraction, input-mode/scanner
work and queue tests once their interfaces are agreed. Assign one owner for
integration changes in `main.vala`, `app-controller.vala`, `meson.build` and the
shared logs. Each phase must leave an attributed handoff with validation and
remaining work. The implementation is complete with validation limits explicitly recorded in the shared audit and changelog. The folder UI and disabled-tab requirements above are confirmed.
