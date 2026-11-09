# Folder Convert and Optimize implementation

Completed 2026-11-02 by Codex primary, task TASK-20261102-bulk-actions-implementation.
Base: main at fe740b3. Changes remain uncommitted.

The existing controls now support folder input:

- Convert uses the current manual codec and General settings.
- Optimize with Auto-Convert on optimizes and converts each file sequentially.
- Optimize with Auto-Convert off retains separate settings for each file. Convert
  subsequently uses them without another optimization pass.
- Later codec/General edits override the edited settings while retaining other
  per-file choices. Rate control and its values/two-pass choice are treated together.
  Changes back to original control values are tracked too. Old estimates clear.
- Unfinished/failed analysis does not silently fall back to manual conversion.
  Source changes invalidate prepared results. Changing codec clears incompatible
  prepared settings; Rescan starts a fresh queue. Completed outputs remain protected.

The plain request and edit-merging code is in src/app/bulk-settings.vala. The
existing bulk controller still owns sequential execution, cancellation, staging,
publication and cleanup. MainWindow routes the existing actions and tracks edits.
No mode selector was added. Source-specific pages remain disabled for folders.

Real manual encodes exposed invalid bare disabled-psy parameters in the existing
x264/x265 builders. They now use FFmpeg-compatible psy=0 and psy-rd=0 key/value
arguments. Synthetic full-decode checks cover both corrections.

Validation:

| Check | Result |
| --- | --- |
| Development build | Passed; existing Vala warnings remain, no new Vala warnings |
| Full suite | 27 passing suites, no assertion failures; one pre-existing mpv-backend timeout |
| Bulk cases across focused runs | 31 passed: 7 data/scanner/calibration cases, 20 display cases, 4 additional manual two-pass cases |
| Shared codec/prepared GTK cases | 4 passed, no skips |
| Four codecs | Real manual CRF and manual bitrate two-pass encodes, General crop, complete decode checks |
| Lifecycle/audio | Mixed silent/two-audio-track sources, processing/copy fallback, interrupted analysis, stale source, retries and cancellation |
| Actual desktop window | Direct Convert, both Optimize paths, edit after optimization, and return to single-file mode passed |

Desktop checks used the rebuilt development executable on Wayland with isolated
preferences and synthetic inputs, driven through its actual MainWindow/AppController
handlers with a local debugger. Two optimized inputs retained different keyframe
settings after a shared CRF edit. Eight synthetic outputs from the desktop runs
fully decoded; no queue staging remained. Single-file input restored Convert and
all three source-specific pages. No installed copy or normal preferences changed.

Limits: this does not establish native mouse/chooser interaction or exhaustive
visual coverage. A temporary private desktop bus emitted an accessibility registry
registration warning; the application window and its actions remained usable.
A direct debugger close while stopped inside the Wayland event loop stalled in
GTK/Vulkan teardown; that instance was terminated after conversion was idle.
A fresh instance closed normally when the close action was scheduled through
the GTK event loop. Close during active processing was not retested on the desktop.
The mpv timeout again reported audio/runtime permission errors; its root cause is
still unresolved. Historical long-range VMAF investigations remain outside this work.
No supplied external media was accessed during this implementation.

README, smoke checks, plans and shared audit/changelog records are updated.
No commit, push, installation or version bump was performed.
