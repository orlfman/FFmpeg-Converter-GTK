# Folder conversion using the existing Convert and Optimize actions

Status: implemented in the working tree; verification results are recorded in AUDIT.md.
Implementation task: TASK-20261102-bulk-actions-implementation.
Date: 2026-11-02, America/Phoenix. Agent: Codex primary.
Task: TASK-20261102-bulk-actions-plan. Source baseline: main at fe740b3.
Supersedes the method-selector proposal in TASK-20261102-manual-bulk-plan.

## Agreed behavior

Folder input extends the normal application workflow. Do not add a Manual/Smart
mode selector, hamburger entry, or separate conversion workflow.

| User action | Folder behavior |
| --- | --- |
| Convert, without prior optimization | Convert each file using the current codec and General settings. Do not run Smart Optimizer. |
| Optimize, Auto-Convert on | Optimize a file, convert it using its optimized settings, finish cleanup, then process the next file. |
| Optimize, Auto-Convert off | Optimize files sequentially and retain each file's settings in the queue. Produce no converted outputs. |
| Convert after optimization | Convert using each file's retained optimized settings, including any subsequent explicit user edits. Do not optimize again. |

Keep General settings, all four codecs, existing supported manual encoder options,
sequential processing, output protection and cancellation. Keep Crop & Trim, Audio
and Subtitles pages disabled for folder input; codec-local audio controls remain
applicable. Smart Optimizer controls and Auto-Convert retain their normal roles.
Auto-Convert affects Optimize, not a direct Convert click.

Each file can have different optimized settings. Retain them per queue item; never
apply the last file's recommendation to the entire folder. The queue should identify
which files have optimized settings ready, with a concise settings summary. Shared
codec controls represent common settings/edits, not a claim that every optimized
file has identical settings. Single-file behavior remains unchanged.

## Implementation plan

### 1. Capture the complete settings and distinguish actions internally

Route Convert, Optimize only, and Optimize then Convert explicitly through the
existing controller. This is internal action routing, not a user-facing mode.

Capture full codec-builder settings/arguments, common codec settings, General,
timing, runtime and naming before async work begins. Reuse the same pixel-format
reconciliation and profile composition as single-file conversion. The common codec
snapshot alone omits encoder-specific settings. Deep-copy snapshots and inspect
all four builders for source-dependent values that need per-file resolution.

### 2. Support direct conversion through the existing queue

Retain scanning, fresh source/audio probes, identity checks, geometry/timing
validation, naming, prepared execution, staging, collision protection and cleanup.
Compose a manual profile using captured builder arguments and the individual
file's metadata through CodecUtils.compose_encode_profile. Do not invoke optimizer,
recommendation resolution or calibration for direct manual conversion.

Validate the requested pixel format and supported encoder/two-pass capabilities,
including SVT-AV1 restrictions. Direct conversion must not require libvmaf just
because the saved optimizer quality target is enabled. Preserve codec-local audio
processing, all-tracks intent and existing audio-copy/container fallback; refresh
source metadata for each file, including silent files. Do not apply optimizer-only
audio overrides to a direct manual conversion. Report required audio fallbacks.

Move common output-FPS/timing calculation out of optimizer-context-dependent code.
Only genuine optimized profiles may carry valid optimizer size reports. A manual
bitrate or CRF does not promise a particular output size.

### 3. Retain usable per-file settings after Optimize

For each successful analysis, store the complete resolved settings/profile,
two-pass decision, recommendation/report data, source identity/revision and the
settings/dependency snapshot that produced it. Store enough structured codec and
General data to support later edits without reconstructing settings from labels
or parsing FFmpeg arguments. Keep this state in memory with the existing queue.

Optimize with Auto-Convert on uses those settings immediately and finishes that
file before dispatching the next. With Auto-Convert off, save them as Ready and
stop after analysis. A later Convert uses them without repeating optimization.
Recheck source/dependency identity and runtime compatibility before execution.
If a source or required asset changed, mark the result stale and explain that
Optimize must be run again; never silently reanalyze on Convert.

Preserve failures/attention states. Convert after an optimization pass processes
eligible ready files; it must not silently convert failed or never-analyzed files
with unrelated manual settings. A partially cancelled analysis retains completed
recommendations; a subsequent Optimize can prepare the remaining files. Rescan
clears retained optimization state and establishes a fresh queue.

### 4. Preserve normal editing and operation behavior

After Optimize, explicit user changes to codec or General fields override those
fields across unfinished items while retaining each file's other optimized values.
Track explicit user edits separately from programmatic widget updates so unrelated
shared defaults never overwrite a recommendation. Recompose and validate each
profile before conversion. Changes that invalidate optimizer size/quality estimates
clear those estimates; Convert still does not run analysis. Changing optimizer
controls alone takes effect on the next Optimize, not retroactively on prepared
encoder settings. Toggling Auto-Convert alone does not start a job.

A codec change cannot reuse another codec's optimized profile: clear incompatible
prepared settings, show that current settings will apply, and use the newly selected
codec on Convert. Input/destination changes follow existing queue-reset behavior.
Retain completed rows for a continuing queue: Convert skips them; Rescan explicitly
starts a new queue and safely generates new output names. No implicit reprocessing.

Keep whole-batch operation ownership, settings locks, close/cancel handling and stale
callback guards for all three actions. Update existing summary/help text that
incorrectly says every Convert uses Smart Optimizer. Do not introduce new controls
for choosing between manual and optimized conversion.

### 5. Verify the behavior and document it

- Compare direct folder profiles with single-file conversion for all four codecs,
  supported rate-control/two-pass choices, advanced settings, bit depth, keyframes,
  General filters and audio processing. Include independent expected arguments.
- Test all four rows of the action table, with Auto-Convert both on and off. Prove
  Convert never starts optimizer analysis and works without libvmaf when otherwise
  supported. Optimize-only must create no converted output.
- Optimize two distinct inputs to different settings, then Convert and prove each
  uses its own retained profile without additional analysis. Test explicit edits,
  cleared estimates, codec changes, failed/partial analysis, stale sources/assets,
  retries, rescans, cancellation and settings locks.
- Run short synthetic real conversions for all available encoders; verify metadata
  and full decoding. Cover mixed dimensions/durations, no/multiple audio streams,
  incompatible audio copy, General timing/geometry errors, collisions and cleanup.
  Report capability skips; output metadata alone cannot establish preset/CRF parity.
- Build and run relevant bulk, prepared-conversion, profile, codec and audio tests,
  then the full suite. Record any pre-existing mpv timeout separately; historical
  long-range VMAF findings are outside this feature's completion claims.
- Check the actual development window with isolated preferences: direct Convert,
  both Optimize paths, edit after Optimize, cancel/retry/rescan, and return to a
  single file. Record any native UI interaction limits honestly.
- Update README, DevTools/SMOKE-TEST.md, the original bulk plan's behavior section
  and shared audit/changelog records with actual results and remaining limits.

Use synthetic media by default. Authorized external test media may be used locally
if needed; keep media, identifying filenames and raw local logs out of the repo
and publication artifacts.

## Evidence and handoff

Likely changes: src/app/main.vala, src/app/bulk-conversion.vala, codec snapshot/edit
tracking helpers and existing tests. Reuse the shared codec builders, profile
composition and prepared Converter API; extend Meson test lists only as needed.

Static review confirms current folder Convert always runs Smart Optimizer; the
analysis-only branch retains a recommendation but discards the resolved local
profile. Current execution also depends on optimizer-specific context and resolution.
Therefore adding direct manual execution alone is insufficient: Optimize then
Convert must also retain usable per-item settings and avoid reoptimization.

The existing single-file flow applies a recommendation to the codec controls, stages
its size report and optionally requests conversion. Folder processing must preserve
that action sequence while retaining distinct settings for different files.

Initial planning validation: source/document review and documentation consistency
checks, without builds or runtime tests. Implementation and later tests are recorded
separately in the shared logs. Existing unrelated DevTools edits and docs/README.md
remain untouched. Implementation is complete with validation limits in AUDIT.md / CHANGELOG.md.
Code and documentation are uncommitted; no push requested.
