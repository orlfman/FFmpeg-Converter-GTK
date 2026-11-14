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
| REV-F3 | Low / open, design | Unassigned | Smart Optimizer's `VP9_CPU_USED` still has four steps (8–5) that libvpx 1.17 encodes identically in Good. (The notes now match the arguments, since REV-F2 removed the clamp.) See AUD-20261110-pre-push-review. |
| REV-F4 | Low / open | Unassigned | An x265 Level too low for the picture now fails the conversion with FFmpeg's generic encoder-open error; High tier cannot be chosen. |
| REV-F5 | Low / open | Unassigned | VP9 alt-ref/lookahead dimming follows the tab's Two-Pass switch, not per-file two-pass decisions in folder mode. |
| REV-F6 | Low / open, design | Unassigned | x265 psy-rd and deblock widgets show 2.0 and 0, 0 while a tune applies other values (documented trade-off of X265-F2). |
| REV-F7 | Low / open, test coverage | Unassigned | No test reads the real X265Tab defaults (Reference Frames Auto, psy-rd/deblock); tests mirror them by hand. |
| X265-F4 | Low / deferred, documented trade-off kept by the user | Unassigned | None unless calibration gets cheaper; max effort measured +2.7% size / +0.57 VMAF for ×1.5 probe time. See AUD-20261110-x265-settings. |
| X264-F4 | Medium / fixed; residual drift measured on one clip | Unassigned | Re-measure on real anime and screen content; calibration now carries psy-trellis, deblock offset and subme 10/11. See AUD-20261114-x264-settings. |
| X264-F7, X264-F8 | Low / addressed by subtitles only | Unassigned | None unless the app should block a level the picture exceeds or lossless with an 8-bit profile; both still reach x264 as before. |
| BASELINE-F2 | Low / open, pre-existing | Unassigned | `preview-fullscreen-state` fails `/combine/widgets/preview-fullscreen-window-state` ("leaving fullscreen restores a compact picture allocation") on this desktop at 4760b73 as well; see the X264 fix follow-up. |
| HEALTH-F1 | Medium / fixed, not exercised on screen | Unassigned | Run a multi-segment Crop & Trim Smart export on a large source and confirm the window stays responsive and Cancel stops the segment copy. See AUD-20261114-app-health. |
| HEALTH-F2 | Medium / partly fixed | Unassigned | Tabs now join the window on first visit (idle private memory 136 → 103 MB). The remaining lever is building the four codec tabs on first use (about 8.6 MB each); it needs every reader of their widgets to cope with an unbuilt tab. |
| HEALTH-F6 | Low / fixed, effect unmeasured | Unassigned | Measure RSS after closing a combine preview and after a Smart Optimizer run on a large source. |
| SVT-F2 | Low / open, pre-existing | Unassigned | Decide whether SVT-AV1 AQ Mode "Complexity" should still send `aq-mode=2` in QP mode, where it turns QP into CRF; see AUD-20261110-svt-variance-boost. |

`SO-*` details: [smart-optimizer-audit-20261109.md](smart-optimizer-audit-20261109.md).

Historical quality/frame-alignment findings remain in
`quality-mode-vmaf-measurement-findings.md`. A flat curve of the same kind was
reproduced and fixed in AUD-20261109-vmaf-threads-model; the original
full-length failing range itself has not been re-run. No application-wide audit is implied.

When an issue is found, add its finding ID, severity, status, owner, next action
and a link to its detailed entry below. Keep this index current as findings are
fixed, verified, deferred or reopened; retain the history below.

## Audit history

### AUD-20261114-health-fix-recheck — Independent review of the two follow-up fixes

- **Task/agent/date/base:** TASK-20261114-health-fix-recheck; Codex (GPT-6),
  2026-11-14 America/Phoenix; main at 791ef42 plus the uncommitted health
  changes. Scope: Fable’s TASK-20261114-health-review-fixes. Review only.
- **Result:** no new findings in this follow-up. HEALTH-REV-F1 is corrected
  by source inspection: the segment is unlinked in the exception path before
  either cancellation breaks or another error continues, and in the nonzero
  copy-exit path. The helper kills/reaps the copy before returning an error;
  the final directory removal can now succeed after those early exits.
  End-to-end cancellation remains untested in this recheck.
- **HEALTH-REV-F2 independently verified:** launch request capture now
  precedes the first async yield, including files, codec arguments and
  crossfade settings. Naming gets a separate fixed container holder; its
  builder’s codec name is constant. The continuation updates only the output
  path and preserves the captured request. Existing operation-ID guards and
  overwrite handling remain in place.
- **Checks:** `combine-launch-snapshot`, `combine-window-state` and
  `trim-subtitles-state`: 3 OK / 0 failures. Confirmed the dedicated
  `/combine/widgets/metadata-naming-launches-request-captured-at-click` test
  actually ran with GTK rather than skipping. It changes the codec after
  clicking and checks the captured codec, suffix and container. Broad
  headless suites still have their expected widget skips. Application build
  succeeds (up to date); `git diff --check` passes.
- **Limits/status:** no full-suite repeat, performance remeasurement or
  manual app walkthrough for this focused follow-up. No implementation
  changes or commits. Retain the cancellation integration-test gap already
  documented by Fable; no additional corrective code identified.

### AUD-20261114-health-independent-review — Review of Fable’s stability fixes

- **Task/agent/date/base:** TASK-20261114-health-independent-review; Codex
  (GPT-6), 2026-11-14 America/Phoenix; main at 791ef42 plus Fable’s
  uncommitted TASK-20261114-app-health-fix changes. Review only; source and
  tests preserved. Two Medium findings, both open and unassigned.
- **HEALTH-REV-F1:** cancelling a Smart Crop & Trim export during the new
  asynchronous segment copy leaves the partial `seg_N.mkv` behind.
  `src/ui/trim-tab.vala:1041–1045` breaks out of the segment loop before
  `FileUtils.unlink (tmp_seg)` at line 1184. The subsequent
  `DirUtils.remove (tmp_dir)` cannot remove a nonempty directory and its
  failure is ignored. This new cancellation route therefore retains the
  copied bytes (potentially gigabytes) and its `smart-opt-*` directory.
  Contrast the existing optimizer cancellation handler, which explicitly
  unlinks the segment before breaking. Fix with per-segment finally cleanup
  or unlink before breaking, after the child has exited; also cover failing
  copy exits, which already bypassed cleanup before this patch. Reproduction
  scenario: cancel while FFmpeg is copying a long segment after it has
  created the output, then inspect the temporary directory. Established by
  control-flow inspection; not driven through the app in this review.
- **HEALTH-REV-F2:** Metadata naming now yields before Combine captures its
  launch request (`src/ui/combine-window.vala:1267–1288`). Naming uses the
  initially selected codec/tab, but `build_launch_request` later rereads
  `codec_choice`, codec settings and crossfade settings. The reservation
  blocks file-list edits and the Combine button, but does not disable these
  controls. Start a VP9/WebM combine with a slow metadata probe and select
  x264 before it returns: the pending name still ends in `.webm` while the
  launch profile uses libx264, which the WebM muxer rejects. Crossfade can
  likewise be changed after its initial validation. Capture one immutable
  request/profile before yielding and use it for both naming and launch,
  or lock all relevant settings throughout the pending operation. The
  operation-ID guard only rejects cancelled/replaced reservations; it cannot
  detect changes to settings within the same reservation. Established from
  the naming, sensitivity and launch paths; no GUI race reproduction run.
- **Independent checks:** full `meson test -C builddir-dev --print-errorlogs`
  run: 29 OK / 0 failures, including the new capture success, missing-program
  and timeout tests. Display-dependent tests in headless suites retain their
  expected skips. `meson compile -C builddir-dev` succeeds (up to date);
  `git diff --check` passes. Reviewed all changed source hunks (ignoring
  whitespace for the large subtitle thread indentation change), operation
  reservation/cancellation, profile naming, temporary-file cleanup, and the
  three-argument subprocess C bridge. The binding correction is consistent
  with the C signature and covered by the missing-program regression test.
- **Limits:** the passing suite does not exercise these two newly identified
  paths. Memory/startup measurements and first-visit tab rendering remain
  Fable’s evidence; no independent performance measurements or manual UI
  walkthrough were done. No implementation fixes or commits made.
- **Follow-up, 2026-11-14 16:40–16:49 America/Phoenix (Claude Code, Fable
  5.2, TASK-20261114-health-review-fixes): HEALTH-REV-F1 and HEALTH-REV-F2
  confirmed by reading the code and fixed. Uncommitted.**
  - **HEALTH-REV-F1:** confirmed. `run_segment_copy_async` waits for the
    killed child before it throws, so the partial file is safe to remove.
    `trim-tab.vala` now unlinks `tmp_seg` on all three early exits of the
    copy step: cancellation, a spawn or wait error, and a non-zero exit. The
    last two skipped cleanup before today's change as well, as the reviewer
    noted. No automated test: the Smart export loop needs the trim tab, a
    real source and the optimizer; not driven through the app either.
  - **HEALTH-REV-F2:** confirmed. `on_combine_clicked` now builds the launch
    request before anything can yield, and names the output from a frozen
    `CombineCodecTab` holding the container read at the click, so the name
    and the launch come from one snapshot. `continue_combine_with_output`
    only fills in the output path. The synchronous naming modes use the same
    order, with no behaviour change.
  - **Test:** `/combine/widgets/metadata-naming-launches-request-captured-at-click`
    selects VP9, clicks Combine with Metadata naming, switches to x264 while
    the title probe runs and checks the launched profile and name. Against a
    temporary variant that rebuilt the request after the probe it failed
    ("…/first-vp9.webm" with an x264 launch profile); with the fix it passes.
    The headless `combine-window-state` suite skips it, so `meson.build`
    gains a display suite, `combine-launch-snapshot`, that runs only this
    test.
  - **Verification:** development build exit 0, same 3 pre-existing Vala
    warnings; full suite 30 OK, 0 failing; `git diff --check` clean.

### AUD-20261114-app-health — Application stability, memory use and performance

- **Task/agent/date/base:** TASK-20261114-app-health-audit; Claude Code
  (Fable 5.2), at the user's request ("audit to see a way to improve
  application overall stability, ram consumption, and performance");
  2026-11-14 16:10–16:18 America/Phoenix (UTC-07:00); main at 791ef42.
  Investigation only; no code changed.
- **Method:** ran the existing `builddir-dev/ffmpeg-converter-gtk-devel` with
  isolated `XDG_CONFIG_HOME`, `XDG_CACHE_HOME` and `TMPDIR`, no input loaded,
  and read `/proc/<pid>/smaps`, `status`, `stat` and per-thread CPU. Compared
  against a bare `Adw.ApplicationWindow` and against test windows holding 300
  rows, 150 dropdowns or 110 spin buttons (PyGObject, same GTK 4.24 /
  libadwaita). Then searched `src/` for blocking process calls, thread
  creation, timers, nested main loops, synchronous file access, signal
  connections to the settings singleton, per-use windows and large buffers,
  and read each hit's caller to see which thread it runs on. Earlier memory
  work (`input-load-memory-spike-findings.md`, the mpv findings) was read
  first and not repeated.
- **Measured, idle with no input (GTK's default Vulkan renderer, radv):**

  | | App | Bare libadwaita window |
  | --- | --- | --- |
  | RSS | 332 MB | 152 MB |
  | PSS | 214 MB | 79 MB |
  | Heap (`[heap]`) | 131 MB | 18 MB |
  | Threads | 15 | 13 |

  CPU while idle: 0 ticks and 1 voluntary context switch in 20 s. Startup:
  0.85–0.98 s from launch to the last CPU activity, 0.75–0.95 s of CPU, one
  `ffmpeg` capability probe. `GSK_RENDERER=ngl` gave PSS 243 MB and 28
  threads; `cairo` gave PSS 155 MB and 13 threads (heap still about 120 MB),
  so the renderer is not where the app's own memory is.
- **Healthy, no finding:** no idle wakeups or polling timers; no libmpv
  threads until a player is used; the console batches output and caps its
  buffer at 200 000 characters; the main window asks before closing during
  an operation and cancels it; `GSubprocess` and `spawn_sync` give FFmpeg
  `/dev/null` as stdin, so a terminal cannot stall it; progress comes from
  `-progress pipe:2`, so stderr lines stay short; folder scans, stale
  temp-directory cleanup and the Information tab's probes are asynchronous or
  on worker threads; `CombineCodecTab` is a plain object, not a widget; the
  optimizer cache is capped.
- **HEALTH-F1 (Medium, open):** `TrimTab.run_smart_then_export`
  (`trim-tab.vala:828`) is an async method on the main thread, and for every
  segment it runs `Process.spawn_sync` on an FFmpeg stream copy
  (`trim-tab.vala:1015`). The window cannot repaint or take input until each
  copy finishes, and Cancel cannot interrupt it. A long segment of a large
  source on a slow disk freezes the window for the whole copy. Read from the
  code; not reproduced on screen.
- **HEALTH-F2 (Medium, open, design):** the app's own heap at idle is about
  113 MB above an empty window. `create_components` (`main.vala:630`) builds
  all ten tabs, including four codec tabs with their own audio and filter
  groups, before the window appears. In the test windows a `Gtk.DropDown`
  cost about 200 kB of heap, a `Gtk.SpinButton` about 115 kB and an
  `Adw.ActionRow` about 8 kB; the source has 90 `DropDown` and 110
  `SpinButton` construction sites, several inside groups that are created
  once per codec tab. `malloc_trim` on the idle process returned about 25 MB,
  so roughly 105 MB is live. Which tab costs what was not measured.
- **HEALTH-F3 (Low, open):** the synchronous probes
  (`FfprobeUtils.run_ffprobe_sync`, `SubtitlesRunner.probe_sync` and
  `probe_duration`) have no timeout and take no cancellable. They run on
  worker threads, so the window stays responsive, but a source on a stalled
  network mount leaves the thread and the operation waiting with no way to
  cancel; the pre-encode probes in `converter.vala:448–468` are the common
  path.
- **HEALTH-F4 (Low, open):** starting a combine calls the synchronous
  `ConversionUtils.compute_output_path` on the main thread
  (`combine-window.vala:1255` and `1262`); with the Metadata naming mode that
  runs `ffprobe` synchronously. The single-file path already uses
  `compute_output_path_async`.
- **HEALTH-F5 (Low, open):** eight worker threads are created with
  `new Thread<void> (...)` (crop detect, logo detect, subtitle probe, four
  subtitle operations, heap trim), which aborts the process if the thread
  cannot be created. The other eleven sites use `new Thread<void>.try` and
  report the error.
- **HEALTH-F6 (Low, open, unmeasured):** `HeapTrim.request` is only called
  when an input is replaced (`app-controller.vala:786`) and only acts above
  1 GiB RSS. Closing the combine preview, the pop-out player or bulk
  playback, and finishing a Smart Optimizer run, never ask for a trim.
  Whether memory stays high after those was not measured.
- **Limits:** memory was measured only at idle with no input. Loading a
  file, playback, an encode in progress and long sessions were not measured,
  because they need the window to be driven by hand. Nothing was profiled
  with heaptrack, valgrind or perf (not installed). The review searched for
  specific patterns; it is not a line-by-line read of 73 000 lines.
- **Follow-up, 2026-11-14 16:22–16:36 America/Phoenix (Claude Code, Fable
  5.2, TASK-20261114-app-health-fix): HEALTH-F1 to HEALTH-F6 fixed or partly
  fixed, at the user's request ("do f1, f2, f3, f4, f5, and f6. all of
  them"), plus a new crash found on the way (HEALTH-F7). Uncommitted.**
  - **Two corrections to the entry above.** (1) The idle table was taken with
    an empty shader cache, which inflates the heap. With a warm cache the same
    build measured RSS 305 MB, PSS 188 MB, private memory 136 MB and heap
    96 MB; those are the "before" figures used below. (2) HEALTH-F3 named the
    pre-encode probes in `converter.vala:448–468` as the common unprotected
    path. That was wrong: they pass `runner.execute_capture`, which is
    cancellable. The unprotected callers were the ones that pass no capture
    runner (logo detection, collage, the trim runner's probes, the subtitle
    probes).
  - **HEALTH-F7 (High, new, fixed):** every failed launch through
    `SubprocessCompat.spawnv` crashed the app. The Vala binding
    (`constants.vala:720`) marked `argv` null-terminated but not
    `array_length = false`, so Vala also passed the array length; the
    three-parameter C bridge received that integer as its `GError**`, and
    GLib dereferenced it when a spawn failed. Evidence: the new test
    `/ffprobe-utils/sync-capture-returns-output-and-status` segfaulted in
    `g_set_error` under `ffcg_subprocess_launcher_spawnv_compat` before the
    fix; the installed 2.1.0 (`/usr/bin/ffmpeg-converter-gtk`) exits with
    SIGSEGV at startup when `[paths] ffmpeg` points to a file that does not
    exist (isolated config). After adding `array_length = false`, no generated
    call passes a length, the test passes and the development build stays up
    with the same settings. Successful launches were never affected.
  - **HEALTH-F1:** the per-segment stream copy runs through a new
    `TrimTab.run_segment_copy_async` (`GSubprocess.wait_async` with the Smart
    export's cancellable, output silenced). Cancelling kills the copy and ends
    the export as cancelled. Not run on screen.
  - **HEALTH-F2 (partly fixed):** measured per tab first (private memory at
    construction): codec tabs about 8.6 MB each, Audio 5.4 MB, Crop & Trim
    4.1 MB, Information 2.0 MB, General 1.6 MB, Subtitles 1.3 MB. About
    50 MB more appeared when the window was laid out and mapped. Two changes
    in `main.vala`: the `Adw.ViewStack` is no longer homogeneous, so hidden
    pages are not measured, and each tab is put into its page the first time
    the page is shown (`attach_deferred_page_content`). All tabs are still
    constructed at startup, so every cross-tab reference works as before.

    | Idle, warm cache | Before | After |
    | --- | --- | --- |
    | RSS | 305 MB | 255 MB |
    | PSS | 188 MB | 154 MB |
    | Private memory | 136 MB | 103 MB |
    | Heap | 96 MB | 78 MB |
    | Launch to last CPU activity | 0.85–0.98 s | 0.72–0.75 s |

    The first visit to a tab took 27–41 ms for the codec tabs and 12–22 ms
    for the others, against 10–11 ms for a revisit; visiting all ten brought
    private memory to 134 MB, the old idle level. No GTK warning was logged
    while every page was visited. Not done: building the codec tabs
    themselves on first use.
  - **HEALTH-F3:** new `FfprobeUtils.run_capture_with_timeout` runs the child
    on a private main context with a 120 s limit, kills it on timeout and
    gives it 2 s to be reaped. `run_ffprobe_sync` and the subtitle runner's
    `probe_sync` and `probe_duration` use it. Callers that pass a capture
    runner are unchanged.
  - **HEALTH-F4:** with the Metadata naming mode the combine window resolves
    the output path through `compute_output_path_async` and continues in
    `continue_combine_with_output` if the reservation is still current; other
    modes stay synchronous, as they never run `ffprobe`.
  - **HEALTH-F5:** the eight sites use `new Thread<void>.try` and undo their
    busy state or report the failure. `subtitles-runner.vala` shows a large
    diff because the thread bodies moved one level in.
  - **HEALTH-F6:** `HeapTrim.request (true)` is also called when the combine
    preview closes, when an operation ends and when the Smart Optimizer
    stops. It still only acts above 1 GiB RSS. The effect was not measured.
  - **Verification:** development build exit 0, the same 3 pre-existing Vala
    warnings. Full suite 29 OK, 0 failing, twice. New tests
    `/ffprobe-utils/sync-capture-returns-output-and-status` and
    `/ffprobe-utils/sync-capture-gives-up-after-timeout` pass (a `sleep 30`
    with a 200 ms limit returns −1 in under 5 s). `preview-fullscreen-state`
    passed in both runs here, although it failed at 4760b73 earlier today
    (BASELINE-F2 stays open as intermittent).
  - **Not covered:** nothing was clicked by hand. HEALTH-F1, F4, F5 and F6
    have no automated test: they need the main window or a thread-creation
    failure, and no test target compiles `main.vala`. The late tab attachment
    was checked by a temporary hook that visited every page, since removed.

### AUD-20261114-x264-crf0-recheck — Review of Fable’s lossless subtitle correction

- **Task/agent/date/base:** TASK-20261114-x264-crf0-recheck; Codex (GPT-6),
  2026-11-14 America/Phoenix; main at 4760b73 plus the uncommitted x264
  changes. Scope: TASK-20261114-x264-crf0-subtitle, the follow-up to
  X264-REV-F1. Review only.
- **Result:** no new findings. X264-REV-F1 independently verified fixed.
  The CRF subtitle now limits the lossless claim to 8-bit output and directs
  10-bit users to QP 0. The QP subtitle correctly covers both depths and
  states the Auto/High444 profile requirement. The audit follow-up explicitly
  corrects the earlier inaccurate claim while preserving its history.
- **Fresh verification:** seven 12-frame synthetic encodes, decoded sample
  hashes compared with the source converted to the same pixel format:
  8-bit Auto CRF 0 matches; 8-bit High CRF 0 is rejected; 10-bit High10
  CRF 0 differs; 10-bit Auto QP 0 matches; High10 QP 0 is rejected;
  High444 with 10-bit 4:4:4 QP 0 matches and CRF 0 differs. Artifacts:
  `/tmp/x264-crf0-recheck-f5sktm7l`. `git diff --check` passes.
- **Limits:** this follow-up changes wording only. Build and regression
  suites were not repeated for this recheck; prior results remain separately
  attributed. The subtitle layout was not inspected in a running app.
  No implementation changes or commits made.

### AUD-20261114-x264-independent-review — Independent review of Fable 5.2’s changes

- **Task/agent/date/base:** TASK-20261114-x264-independent-review; Codex
  (GPT-6), 2026-11-14 America/Phoenix; main at 4760b73 plus Fable’s ten
  uncommitted changed files. Review requested by the user. Documentation-only
  additions by this reviewer; implementation left intact.
- **X264-REV-F1 — Medium / open, owner unassigned:** the new CRF subtitle
  (`src/encoders/x264-tab.vala:190`) incorrectly promises that CRF 0 is
  lossless regardless of bit depth. With 10-bit 4:2:0, FFmpeg 9.0.2 / x264
  core 165 r3222 reports `rc=crf crf=0.0`, profile High 10, and decoded
  samples differ from the input. QP 0 on the same 10-bit source reports
  `rc=cqp qp=0`, High 4:4:4 Predictive, and identical decoded samples.
  Both CRF 0 and QP 0 are lossless in the 8-bit control. A user selecting
  Auto plus 10-bit can therefore follow the new guidance and unknowingly
  create a lossy archival copy. Qualify the CRF guidance by bit depth and
  direct users to QP 0 for 10-bit lossless. The original X264-F8 statement
  and its claimed subtitle fix are superseded by this evidence; the QP
  subtitle itself passed these checks.
- **Reproduction:** encode 12 frames of `testsrc2=s=320x240:r=24` using
  `-pix_fmt yuv420p10le -c:v libx264 -crf 0`, decode to yuv420p10le and
  compare FFmpeg `-f hash` output with the synthetic source converted to
  that same format. Repeat with `-qp 0` and with yuv420p for controls.
  Disposable artifacts: `/tmp/x264-review-9qohap51`.
- **Independently verified:** `meson compile -C builddir-dev` succeeds
  (up to date). Focused suites `smart-codec-resolver`, `smart-codec-widgets`,
  `smart-optimizer-logic`, `combine-window-state`: 4 OK, 0 failures. The
  dedicated widget suite executes the new x264 defaults test; headless
  suites still skip display-dependent tests. Fresh synthetic encodes confirm
  CABAC/MB-Tree off, Baseline, fastdecode with Threads 4, subme 11 with
  trellis 2, and the unmodified veryslow/animation/zerolatency settings.
  `git diff --check` passes. Read the changed builder, tab, resolver,
  calibration, trim, cache and test code and their relevant callers.
- **Assessment/limits:** no additional actionable regression found in this
  scope. The inability to force values reused as Auto sentinels is explicitly
  documented by Fable and not counted as an undisclosed defect. The stated
  calibration size/VMAF results remain Fable’s measurements on one clip;
  this review did not remeasure them or certify broader content coverage.
  The full 29-suite run, baseline fullscreen comparison and manual visual
  inspection were not repeated. No fixes or commits made by this review.
- **Follow-up, 2026-11-14 America/Phoenix (Claude Code, Fable 5.2,
  TASK-20261114-x264-crf0-subtitle): X264-REV-F1 reproduced and fixed.
  Uncommitted.**
  - **Reproduced** with the reviewer's method (12 frames of
    `testsrc2=s=320x240:r=24`, decoded-frame SHA-256 against the source):
    8-bit CRF 0 and QP 0 are both `rc=cqp qp=0`, High 4:4:4 Predictive, and
    match the source. 10-bit CRF 0 is `rc=crf crf=0.0`, High 10, and does not
    match, with Profile Auto, High10 and High444 alike. 10-bit QP 0 is
    `rc=cqp qp=0`, High 4:4:4 Predictive, and matches with Auto and High444;
    with High10 x264 refuses ("high10 profile doesn't support lossless").
    The mistake was mine: the X264-F8 run showed `rc=crf` for High10 CRF 0
    and I did not carry that into the subtitle.
  - **Fix:** `src/encoders/x264-tab.vala` CRF subtitle now says 0 is lossless
    for 8-bit output only and points to QP 0 for 10-bit lossless; the QP
    subtitle says 0 is lossless at 8 and 10 bit. Text only; no argument
    changed. X264-F8's statement that CRF 0 is lossless holds for 8-bit only.
  - **Verification:** development build exit 0, same 3 pre-existing Vala
    warnings; `combine-window-state`, `smart-codec-widgets` and
    `smart-codec-resolver` pass. No test reads the subtitle text, and the
    tab was not looked at on screen.

### AUD-20261114-x264-settings — Do the x264 tab's settings reach the encoder and do what the tab says?

- **Task/agent/date/base:** TASK-20261114-x264-settings-check; Claude Code
  (Fable 5.2), at the user's request ("audit x264 tab settings like how av1,
  x265, and vp9 was done"); 2026-11-14 15:01–15:06 America/Phoenix (UTC-07:00)
  by the system clock; main at 4760b73. Investigation only; no code changed.
- **Method:** read `src/encoders/x264-builder.vala`, `x264-tab.vala`,
  `resolve_x264`, `apply_smart_x264`, the trim tab's direct Smart arguments
  (`CodecUtils.build_smart_codec_args`) and x264 calibration
  (`smart-optimizer.vala:4925`). Ran FFmpeg 9.0.2 / x264 core 165 r3222 with
  the argument strings the builder produces on a 2 s 640x360 `testsrc2` clip,
  and read back the option line x264 writes into the stream (its own record of
  what it applied) plus FFprobe's profile, level and pixel format. Presets and
  tunes were run alone and with the tab's defaults. The Smart Codec comparison
  used 20 s from 10 s of `tests/testvideo-raptor.webm` (720p) with libvmaf.
- **Working as labelled:** preset name; profiles Main, High, High10, High422
  and High444 in 8 and 10 bit with their pixel formats (FFprobe profile
  matches); Baseline's profile itself (Constrained Baseline); CRF 0–51; QP
  0–69; ABR; CBR (`rc=cbr`, `nal_hrd=cbr`, also in MP4, 1968 kbps for a 2000
  target); two-pass ABR (`rc=2pass`); all 16 levels as stream labels (10 to
  52); keyframe interval (`-g 60` → `keyint=60`) and the fixed-time custom
  mode; reference frames 1–16; B-frames 0–16; B-frame adaptation 0–2; weighted
  prediction off; deblock off and custom offsets; psy-rd strength, psy-trellis
  and psy off; lookahead 0–250; AQ modes 1–3 with strength; AQ Disabled;
  all five ME algorithms; search range with umh; subpixel refinement 0–9;
  Open GOP; threads.
- **X264-F1 (High, open):** turning CABAC or MB-Tree off breaks the encode.
  The builder sends them as `no-cabac` and `no-mbtree` with no value
  (`x264-builder.vala:217–221`), and FFmpeg's `-x264-params` needs
  `key=value`. When the flag is the last parameter FFmpeg refuses to start
  ("Error setting option x264-params", exit 234). When something follows it,
  FFmpeg joins the two into one bad key, logs "Error parsing option
  'no-cabac:rc-lookahead = 60'" and carries on, so the flag **and the next
  parameter** are both lost: CABAC stayed on (`cabac=1`), MB-Tree stayed on,
  and the lookahead, `aq-mode`, `open-gop`, `threads` or `vbv-maxrate` after
  it was dropped. Four routes reach this: the CABAC switch, the MB-Tree
  switch, Profile Baseline and Tune fastdecode (the last two add `no-cabac`
  themselves). Baseline with otherwise default settings fails to start;
  Baseline with Threads 4 encoded but ignored the thread count. Smart
  Optimizer's delivery option (`optimize_for_delivery`) picks fastdecode for
  x264, so it is affected too. Baseline and fastdecode still get CAVLC from
  the profile and tune. `cabac=0` and `mbtree=0` were tested and work.
- **X264-F2 (Medium, open, design):** the preset is partly undone. The builder
  always sends `ref=3`, `bframes=3`, `b-adapt=1`, `deblock=0,0` and `me=hex`
  (the tab's defaults), and `-x264-params` is applied after the preset.

  | Preset | Preset alone | With the tab's defaults | Size |
  | --- | --- | --- | --- |
  | ultrafast | ref 1, no B-frames, no deblock, dia | ref 3, 3 B-frames, deblock, hex | −10.2% |
  | superfast | ref 1, dia | ref 3, hex | −4.6% |
  | veryfast | ref 1 | ref 3 | −3.8% |
  | faster, fast | ref 2 | ref 3 | −1.3% |
  | slow | ref 5 | ref 3 | +1.2% |
  | slower | ref 8, umh, b-adapt 2 | ref 3, hex, b-adapt 1 | +4.2% |
  | veryslow | ref 16, 8 B-frames, umh, range 24, b-adapt 2 | ref 3, 3 B-frames, hex, range 16, b-adapt 1 | +7.2% |
  | placebo | ref 16, 16 B-frames, tesa, range 24 | as veryslow's row | +7.4% |

  Subpixel refinement and search range are only sent when they differ from 7
  and 16, so those two follow the preset while the other five do not. Smart
  Codec sets these per effort on purpose and is not affected.
- **X264-F3 (Medium, open, design):** Tune is partly undone, for the same
  reason plus the always-sent `psy-rd=1.0,0.00`. film loses its deblock
  −1,−1 and psy-trellis 0.15; animation loses deblock 1,1, psy-rd 0.4, 6
  references and 5 B-frames (its AQ strength 0.6 survives); grain loses
  deblock −2,−2 and psy-trellis 0.25; stillimage loses deblock −3,−3 and
  psy-rd 2.0:0.7. zerolatency gets its B-frames back (`bframes=3`), which
  defeats the tune; its lookahead and MB-Tree changes survive. psnr and ssim
  are unaffected (psy stays off, AQ stays as the tune set it).
- **X264-F4 (Medium, open):** because of X264-F3 and the per-effort settings,
  Smart Codec's final x264 arguments are not what calibration measured.
  Calibration and the trim tab's direct Smart arguments send only preset, CRF,
  tune and lookahead. Final against calibration, preset medium, CRF 23, one
  live-action clip:

  | Tune | Minimal effort | Medium effort | Maximum effort |
  | --- | --- | --- | --- |
  | none | −1.5% / VMAF +0.03 | +3.0% / +0.34 | +4.8% / +0.46 |
  | animation | +4.3% / +0.20 | +8.5% / +0.49 | +10.0% / +0.60 |
  | stillimage (screencasts) | −18.0% / −0.77 | −14.1% / −0.47 | −12.4% / −0.33 |

  The `EncoderTuning` comment records ±2% as the accepted drift; only the
  untuned minimal case is inside it. The tune was added to calibration because
  animation moved size by a third, but the builder then undoes most of that
  tune in the final encode. Not measured on real anime or screen content.
- **X264-F5 (Low, open):** Subpixel Refinement 10 and 11 encode as 9 unless
  trellis is 2 and AQ is on. The tab has no trellis control, and only presets
  slow and beyond set trellis 2, so with medium or faster the two top entries
  are silently reduced (`subme=11` → `subme=9` on medium; kept on slow). Smart
  Codec sets 10 and 11 at high and maximum effort.
- **X264-F6 (Low, open):** Search Range above 16 does nothing with the default
  hex algorithm (or dia): `merange=64` gave `me_range=16` and a byte-identical
  file. It applies with umh, esa and tesa. The subtitle says 4–64.
- **X264-F7 (Low, open):** Level does not constrain anything by itself. x264
  writes the level into the stream and prints warnings, but still encodes:
  Level 1 at 640x360 produced a file labelled level 1.0 that is far outside
  it. The subtitle says it "constrains resolution, bitrate, and buffers". The
  list also stops at 5.2; x264 accepts 6, 6.1 and 6.2.
- **X264-F8 (Low, open):** CRF 0 or QP 0 is lossless, which x264 only allows
  in High 4:4:4 Predictive. With Profile High the encode fails ("high profile
  doesn't support lossless"); with Auto the output silently becomes High 4:4:4
  Predictive, which most hardware players cannot decode. The CRF and QP
  subtitles do not mention it.
- **Notes, not findings:** ABR with "Enable VBV" sets max rate and buffer equal
  to the bitrate, which x264 itself reports as `rc=cbr`; it differs from the
  CBR mode only by `nal-hrd` (491 869 against 492 103 bytes). Smart Codec's
  two-pass uses this (see SO-F4). AQ Disabled shows as `aq=1:0.00`, x264's
  form of no AQ while MB-Tree is on. Lookahead 0 also turns MB-Tree off.
  Two-pass first passes use x264's fast first-pass settings. With no tune and
  preset medium the tab's default arguments are byte-identical to sending
  none.
- **Limits:** builder output was reproduced by reading the code, not captured
  from the running app; the UI was not run. Synthetic clip for per-setting
  checks; one real clip for X264-F4. The fps-based custom keyframe modes were
  not exercised.
- **Follow-up, 2026-11-14 15:21–15:30 America/Phoenix (Claude Code, Fable
  5.2, TASK-20261114-x264-settings-fix): X264-F1 to X264-F8 fixed or
  addressed, at the user's request ("Fix all 8"). Uncommitted.**
  - **X264-F1:** the builder sends `cabac=0` and `mbtree=0`. Verified with
    x264: CABAC and MB-Tree off with a lookahead after them, Baseline with
    default settings, and fastdecode with Threads 4 all encode, and x264
    reports `cabac=0`, `mbtree=0` and `threads=4`.
  - **X264-F2, X264-F3:** `ref`, `bframes`, `b-adapt`, `deblock`, `me` and
    `psy-rd` are sent only when they differ from x264's defaults (3, 1, 0,0,
    hex, 1.0/0.0) or are turned off; Reference Frames gains "Auto" (first,
    default on build and reset). An untouched tab now sends no
    `-x264-params`. Verified: veryslow reports 16 references, 8 B-frames, umh
    and b-adapt 2 (171 194 bytes, identical to the preset alone); ultrafast,
    animation and zerolatency are byte-identical to the preset or tune alone,
    and zerolatency has no B-frames. Trade-off, as for x265: exactly 3
    B-frames, Fast adaptation, hex, deblock 0,0 or psy 1.0/0.0 cannot be
    forced on top of a preset or tune that changes them; the subtitles say so.
  - **X264-F4:** `EncoderTuning` gains `x264_psy_trellis`,
    `x264_deblock_offset` and `x264_subme`. `decide_encoder_tuning` leaves
    psy and deblock to the animation and stillimage tunes and otherwise sets
    psy-trellis by effort and deblock −1,−1 at high and maximum effort;
    `resolve_x264` reads those values instead of its own copies. Calibration
    and the trim tab's direct arguments write them through
    `X264Builder.smart_tuning_params`. `SmartOptimizerCache` format version
    5 → 6 and the tuning key gained the three fields. Final against
    calibration after the fix, CRF 23, same clip:

    | Case | Minimal | Low | Medium | High | Maximum |
    | --- | --- | --- | --- | --- | --- |
    | no tune, medium | −1.5% / +0.03 | +0.1% / +0.08 | +0.2% / +0.08 | −1.5% / +0.03 | −2.5% / −0.00 |
    | no tune, faster | −1.1% / +0.11 | −0.5% / +0.42 | −0.4% / +0.45 | −1.0% / +0.06 | −1.6% / +0.05 |
    | animation, medium | +1.1% / +0.11 | not run | −0.3% / +0.15 | not run | −0.6% / +0.08 |
    | stillimage, medium | −1.3% / +0.05 | not run | +2.4% / +0.05 | not run | −2.2% / −0.01 |

    Cost: carrying subme 10/11 with trellis 2 makes a probe encode about
    ×1.9 (high) to ×2.4 (maximum) slower at those two efforts (1.3 s → 2.5 s
    and 3.1 s on the 20 s clip). Leaving it out kept probes fast but drifted
    −7.3% (high) and −7.1% (maximum). Smart Codec output changes: anime and
    screencast encodes keep the tune's psy and deblock at every effort, and
    high and maximum effort really use subme 10/11 (see X264-F5).
  - **X264-F5:** the builder adds `trellis=2` beside subme 10 and 11.
    Verified on preset medium: `subme=11 trellis=2` (was `subme=9`). AQ off
    still lowers it to 9; the subtitle says both.
  - **X264-F6, X264-F7, X264-F8:** subtitles only. Search Range says above 16
    needs umh, esa or tesa; Level says it is written into the stream and that
    x264 warns but still encodes; CRF and QP say 0 is lossless, needs Profile
    Auto or High444 and is written as High 4:4:4 Predictive. Level gains 6,
    6.1 and 6.2. The encoder behaviour itself is unchanged.
  - **Smart Codec golden digests:** x264 cases 0–9 changed. For each, putting
    the legacy `-x264-params` string back into the dumped profile reproduced
    the digest it replaces; cases 10–39 were byte-identical. The table comment
    records this third exception.
  - **Verification:** new tests `/combine/x264/cabac-and-mbtree-off-are-key-value`,
    `/combine/x264/defaults-leave-preset-and-tune-alone`,
    `/combine/x264/subme-10-and-11-send-trellis-2`,
    `/combine/x264/smart-tuning-matches-final-arguments` and
    `/smart-codec/widgets/x264-tab-defaults-follow-preset` pass; the widget
    test ran with real GTK widgets in `smart-codec-widgets`. Full suite: 27
    OK, 2 failing on the first run, 28 OK and 1 failing on re-running those
    two. `bulk-playback` (`/bulk-playback/launcher/real-player-and-fallback`)
    failed once and passed on the re-run. `preview-fullscreen-state` fails
    the same assertion in an untouched worktree at 4760b73, so it is
    pre-existing here; recorded as BASELINE-F2.
  - **Not covered:** the app window was not opened; the new subtitles were
    not looked at on screen. X264-F4 was measured on one live-action clip.

### AUD-20261110-pre-push-review — Review of the unpushed x265 and VP9 fixes

- **Task/agent/date/base:** TASK-20261110-pre-push-review; Claude Code (Opus
  5.5), at the user's request ("audit your fixes, and if everything looks good,
  push"); 2026-11-10 10:36 America/Phoenix (UTC-07:00); range
  `origin/main..main` = 123cb61, cec0a59, f149e7d. Review only; no code changed.
- **Method:** line-by-line read of every changed hunk and its enclosing
  function; callers of each changed function (bulk merge and copy, Smart
  Codec appliers, trim tab's direct args, two-pass runner, calibration);
  removed behaviour (always-present `-x265-params`, `-level:v`,
  `frame_parallel=false`).
- **Checked and fine:** x265 two-pass uses FFmpeg's `-pass`/`-passlogfile`,
  not `-x265-params`, so an empty or absent `-x265-params` is safe. Folder
  copy and merge (`merge_builder`) carry every changed field (`ref_frames`,
  `level`, `frame_parallel`, `speed`, `quality_deadline`). The folder summary
  reports the clamped VP9 speed. Every target that compiles the optimizer
  also compiles `x265-builder.vala`. No bug was found in the shipped
  configuration (libvpx 1.17, x265 4.3).
- **Findings (all Low, open, unassigned):** REV-F1 to REV-F7, as in the index
  above. REV-F1 and REV-F2 make two VP9 fixes depend on libvpx 1.17's
  behaviour; REV-F3 and REV-F6 are design follow-ups to accepted trade-offs;
  REV-F4 and REV-F5 are UX edges; REV-F7 is test coverage.
- **Outcome:** none blocks publishing; pushed with these recorded.
- **Follow-up, 2026-11-10 10:45 America/Phoenix (Claude Code,
  TASK-20261110-vp9-libvpx-independence): REV-F1 and REV-F2 fixed.** The
  installed libvpx is 1.17.0, the version Arch's `extra` repository ships.
  The user chose to let libvpx decide the speed limit instead of probing it at
  startup.
  - **REV-F1:** Frame Parallel is always explicit: `-frame-parallel 1` or `0`
    from the builder, `-frame-parallel 1` in the trim tab's direct Smart
    arguments (`CodecUtils.build_smart_codec_args`) and in VP9 calibration, so
    calibration and final still match on a libvpx whose default differs.
    `SmartOptimizerCache` format version 4 → 5. On libvpx 1.17 the output is
    unchanged (the audit run showed `-frame-parallel 1` byte-identical to the
    default). All ten VP9 Smart Codec golden digests (cases 20–29) changed;
    removing exactly that argument pair from each dumped profile reproduced
    the digest it replaces, and no other codec changed. The table comment
    records this second exception.
  - **REV-F2:** removed `Vp9Builder.max_speed_for_deadline`, the builder
    clamp, and the tab's deadline-dependent Speed range. Speed 0–8 is passed
    through, and the installed libvpx applies its own limit. The subtitle now
    says libvpx 1.17 encodes 6–8 as 5 with Good/Best. `apply_smart_vp9` is
    back to its original order. This undoes the range part of the VP9-F3 fix;
    VP9-F3 is now addressed by the subtitle only.
  - **Verification:** `/combine/vp9/speed-passes-through-to-libvpx`,
    `/combine/vp9/frame-parallel-is-explicit` and the reworked
    `/smart-codec/widgets/vp9-tab-follows-two-pass` pass (the widget test ran,
    not skipped); `/smart-codec/policy/full-effort-features` now expects
    `-frame-parallel 1`. Real encode with the new default arguments and Speed 8
    on Good: libvpx logged `VP8E_SET_CPUUSED: 8` and
    `VP9E_SET_FRAME_PARALLEL_DECODING:1`, no errors.

### AUD-20261110-vp9-settings — Do the VP9 tab's settings reach the encoder and change it?

- **Task/agent/date/base:** TASK-20261110-vp9-settings-check; Claude Code
  (Opus 5.5), at the user's request; 2026-11-10 10:25 America/Phoenix
  (UTC-07:00); main at cec0a59. Investigation only; no code changed.
- **Method:** read `src/encoders/vp9-builder.vala`, `vp9-tab.vala`, the VP9
  profile helpers in `codec-utils.vala` and `resolve_vp9`. Ran FFmpeg 9.0.2 /
  libvpx 1.17.0 with the builder's argument strings at `-loglevel debug`,
  which prints libvpx's final `vpx_codec_enc_cfg` and every `vpx_codec_control`
  call. Settings that looked inert on a 1 s synthetic clip were re-run on 5 s
  of `tests/testvideo-raptor.webm` (720p), comparing file size and
  decoded-frame MD5, in single-pass and two-pass.
- **Working as labelled:** CRF (`rc_end_usage 3` with `-b:v 0`), Constrained
  Quality (2, with CQ level), VBR (0), CBR (1 via equal min/max rate); Rate
  Tolerance (`rc_undershoot_pct`/`rc_overshoot_pct`; libvpx's default really is
  25/25 as the subtitle says); deadlines good/best/realtime; Speed 0–5;
  Content Type Film; AQ modes 1–4 (each changes output); sharpness; row-mt
  on/off; tile columns/rows (libvpx clamps columns by width); threads;
  keyframe interval (`kf_max_dist`); Profiles 0–3 with their pixel formats
  (`g_profile`/`g_bit_depth`); alt-ref in two-pass. No libvpx errors.
- **VP9-F1 (Medium, open):** in single-pass encodes, Alt-Ref Frames, ARNR
  Filter Frames/Strength and Lookahead do nothing. On the 720p clip, CRF 31
  with alt-ref off, ARNR 15/6, lag 0 and lag 10 were all byte-identical to the
  default (1 366 339 bytes); single-pass VBR likewise. In two-pass, turning
  alt-ref off changed the file (935 400 → 899 539 bytes). FFmpeg's own help
  marks `-auto-alt-ref` "2-pass only". The app defaults to single-pass CRF, and
  Smart Codec's per-effort ARNR values (7/5 to 15/6) only matter when it picks
  two-pass. The tab's subtitles do not say this.
- **VP9-F2 (Low, open):** Frame Parallel Decoding cannot be turned off. Off
  sends nothing (`vp9-builder.vala:205`), and libvpx 1.17 already enables it:
  the default output was byte-identical to `-frame-parallel 1`, while
  `-frame-parallel 0` differed (1 366 339 → 1 360 467 bytes, −0.4%). The
  subtitle promises a compression gain from leaving it off that never happens.
- **VP9-F3 (Low, open):** with the Good deadline, Speed 6, 7 and 8 produce the
  same encode as 5 (synthetic and real clips). The tab allows 0–8. Smart
  Optimizer's `VP9_CPU_USED` table maps its four fastest steps to 8, 7, 6 and
  5, so those are one encode; calibration uses the same values, so it is not a
  calibration mismatch, only no speed gain. Realtime does use 6–8.
- **VP9-F4 (Low, open):** Content Type "Screen" sends
  `VP9E_SET_TUNE_CONTENT 1` but has no effect with the Good deadline: identical
  output on the film clip, in two-pass, and on a synthetic screen-like source
  with sharp text. With realtime it does change the encode (1 955 329 →
  1 847 644 bytes). Smart Codec sets "Screen" for screencasts with Good, so
  that choice is inert.
- **Notes, not findings:** AQ "Automatic" sends nothing, which in libvpx is
  no AQ (all four modes differ from it); the builder's "Disabled" branch is
  unreachable from the tab, which has no such entry. `Vp9BuilderSnapshot`
  class defaults (alt-ref off, tolerance 100/100, AQ "Disabled") differ from
  the tab's, but `resolve_vp9` sets these fields explicitly.
- **Limits:** one real clip and synthetic sources; two-pass covered only for
  alt-ref, lookahead and Screen. CQ mode was not re-run for VP9-F1. The UI was
  not run; arguments were reproduced from the builder code.
- **Follow-up, 2026-11-10, committed 10:33 America/Phoenix (Claude Code,
  TASK-20261110-vp9-settings-fix): VP9-F1 to VP9-F4 fixed.**
  - **Extra evidence first:** on 3 s of the same clip, single-pass CQ and CBR
    were also byte-identical with alt-ref off and with lag 0, and VBR with lag
    0. So VP9-F1 holds for every single-pass mode. With the Best deadline,
    Speed 8 was byte-identical to 5, so VP9-F3 covers Best too.
  - **VP9-F1:** the Alt-Ref and Lookahead rows are dimmed (insensitive)
    whenever Two-Pass is off, which includes CRF, where the tab hides and
    clears Two-Pass. Their subtitles say "two-pass only". The builder still
    sends their values; they are inert in single pass, so Smart Codec's output
    is unchanged.
  - **VP9-F2:** the switch now starts on (build and reset), matching libvpx.
    Only off is sent, as `-frame-parallel 0`. `Vp9BuilderSnapshot.frame_parallel`
    defaults to true, and `resolve_vp9` sets true, so Smart Codec still sends
    nothing and its output is unchanged. The
    `/smart-codec/policy/full-effort-features` assertion that expected
    `!frame_parallel` now expects true plus no `-frame-parallel` argument.
  - **VP9-F3:** `Vp9Builder.max_speed_for_deadline` (5 for Good, Best or unset;
    8 for Realtime) clamps `-cpu-used`, and the tab's Speed range follows the
    deadline. `apply_smart_vp9` now sets the deadline before Speed so the
    widget value and the resolver's arguments agree. Smart Optimizer's
    `VP9_CPU_USED` table is unchanged: calibration still sends 8–6 for its
    fastest steps, which libvpx encodes as 5, the same as the clamped final
    argument.
  - **VP9-F4:** the Content Type subtitle says Screen only takes effect with
    Realtime. Smart Codec still picks Screen for screencasts; it is inert with
    Good but harmless, and changing it would alter Smart Codec goldens for no
    output difference.
  - **Verification:** new tests `/combine/vp9/speed-follows-deadline`,
    `/combine/vp9/frame-parallel-off-is-sent` and
    `/smart-codec/widgets/vp9-tab-follows-two-pass-and-deadline` (real GTK
    widgets: dimming follows Two-Pass, Speed range follows the deadline, a
    cpu-used 8 Smart Codec recommendation lands as 5). The widget test ran,
    not skipped, in this session. The argument effects were measured in the
    audit runs above.

### AUD-20261110-x265-settings — Do the x265 tab's settings reach the encoder?

- **Task/agent/date/base:** TASK-20261110-x265-settings-check; Claude Code
  (Opus 5.5), at the user's request; 2026-11-10 09:50 America/Phoenix
  (UTC-07:00); main at 5cc5052. Investigation only; no code changed.
- **Method:** read `src/encoders/x265-builder.vala` and `x265-tab.vala`, then
  ran FFmpeg 9.0.2 / x265 4.3 on a 1 s synthetic `testsrc2` clip with the
  argument strings the builder produces, reading x265's startup summary for
  each setting. Some cases were also run with no app arguments for comparison.
- **Working as labelled:** preset; profile Main / Main10 (with matching
  `-pix_fmt`); CRF; QP (`CQP-30`); ABR with VBV (buffer = max-rate = bitrate);
  CBR (VBV plus `strict-cbr=1`, accepted; the summary does not print it);
  keyframe interval (`-g 60` → max 60); SAO off; weighted prediction off;
  deblock off and custom offsets (`deblock(tC=-1:B=-1)`); psy-rd strength and
  off; cutree off; lookahead up to 250; AQ modes 1–4 with strength; AQ
  "Disabled" (shown as mode 1, strength 0.0, x265's form of no AQ while
  cutree is on); threads (`pools`) and frame threads. No x265 errors.
- **X265-F1 (Medium, open):** Level never applies. The builder sends
  `-level:v N` (`x265-builder.vala:142`), but libx265 has no level option
  and does not read FFmpeg's generic one. All 13 choices from 1 to 6.2 gave the
  automatic `Level-2.1` on the test clip. `-x265-params level-idc=4.1` works
  but can select High tier (`Level-4.1 (High tier)`), which many players do
  not support. `level-idc=4.1:high-tier=0` gave `Level-4.1 (Main tier)` and
  capped VBV at the Main-tier limit (20000 kbps; 40000 for 5.1). x265 warns
  that a level under CRF turns on VBV; that is expected.
- **X265-F2 (Medium, open, design):** Tune is partly undone. The builder always
  sends `psy-rd` (2.0 by default, or 0) and `deblock=0,0` / `no-deblock=1`
  (`x265-builder.vala:166–182`), and `-x265-params` is applied after the tune.
  Tune alone versus with the app's defaults: psnr and ssim turn psy-rd off →
  app restores 2.00; grain sets psy-rd 4.00 → 2.00; animation sets psy-rd 0.40
  and `deblock(tC=1:B=1)` → 2.00 and plain deblock; fastdecode turns deblock
  off → app turns it back on. zerolatency is unaffected.
- **X265-F3 (Low, open, design):** Reference Frames has no Auto, so `ref=3` (the
  default) is always sent (`x265-builder.vala:161`) and overrides the preset.
  Presets alone use 1 (ultrafast), 2 (veryfast), 4 (slow) and 5 (veryslow)
  references. Smart Codec sets references per effort on purpose, so it is not
  affected.
- **Notes, not findings:** PMode still works in x265 4.3 (`+ pmode`), but
  x265's help marks it "Deprecated from release 4.1". `X265BuilderSnapshot`
  field defaults differ from the tab's (deblock and psy-rd off, `ref` empty,
  lookahead 20). No path was found where an unedited default snapshot reaches
  an encode: `main.vala:549` snapshots the tab, and Smart Codec sets these
  fields explicitly.
- **Limits:** builder output was reproduced by reading the code, not captured
  from the running app; two-pass x265 and `Custom` keyframe modes were not
  exercised. The existing `bulk-conversion` x265 tests cover two-pass runs.
- **Follow-up, 2026-11-10, committed 10:09 America/Phoenix (Claude Code,
  TASK-20261110-x265-settings-fix): X265-F1, X265-F2 and X265-F3 fixed and
  verified at the builder and encoder level.**
  - **X265-F1:** Level is now sent as `-x265-params level-idc=N:high-tier=0`,
    and `-level:v` is gone. A level too low for the picture now stops the
    encode with x265's own error ("picture dimensions are out of range for
    specified level"; Level 1 and 2 at 640x360). Before, it was silently
    ignored. x264 was checked as well: libx264 does apply `-level:v` (3.1, 4.1
    and 5.1 gave stream levels 31, 41 and 51), so it is unchanged.
  - **X265-F2:** deblock and psy-rd are sent only when they differ from x265's
    defaults (deblock 0,0; psy-rd 2.0) or are turned off. At the defaults the
    tune and preset decide. Trade-off: exactly 2.0 / 0,0 cannot be forced on top
    of a tune that changes them. The Psy-RD and Deblock subtitles say so. Smart
    Optimizer calibration (`smart-optimizer.vala`) now uses the same rule
    through `X265Builder.psy_rd_differs_from_default`, so it still measures the
    final arguments. This changes Smart Codec output only where an x265 tune
    sets its own values while effort is low: anime at MINIMAL/LOW effort now
    gets animation's psy-rd 0.4, and anime or fastdecode at MINIMAL–MEDIUM
    gets the tune's deblock. `SmartOptimizerCache` format version 3 → 4, so
    cached samples measured with the old arguments are not reused.
  - **X265-F3:** Reference Frames gains "Auto" (first, and the default on build
    and reset), which sends no `ref`. Presets restore this dropdown by label,
    so the new first entry does not shift saved choices. Smart Codec still
    sets references per effort.
  - **Verification:** new tests `/combine/x265/level-reaches-encoder-in-main-tier`,
    `/combine/x265/default-psy-rd-and-deblock-leave-tune-alone` and
    `/combine/x265/reference-frames-auto-follows-preset` pass. They need the new
    `psy_rd_differs_from_default` helper, so they were not run against the old
    builder. Real x265 4.3 encode with the new defaults (`-preset slow -crf 28
    -tune animation -x265-params level-idc=4.1:high-tier=0`) reported
    `Level-4.1 (Main tier)`, 4 references, `psy-rd=0.40` and
    `deblock(tC=1:B=1)`.
  - **Smart Codec golden digests:** the first full run failed
    `smart-codec-resolver`, `smart-codec-widgets` and `combine-window-state` on
    `/smart-codec/golden/all-four-codecs` (case 15 reported). Dumping all 40
    serialized profiles showed exactly six changed: x265 cases 10–15 (efforts
    0–2), whose `-x265-params` no longer carry `deblock=0,0` and, where it was
    2.0, `psy-rd=2.0`. Putting those values back reproduced each stored legacy
    digest exactly, so no other field changed. Those six digests were updated
    with a comment recording the exception to the "must not be regenerated"
    rule. Cases 16–19 (psy-rd 3.0/3.5, deblock −1,−1) and the other codecs did
    not change.
  - **Not covered:** the UI was not run.
- **X265-F4 (Low, open, pre-existing; found during the fix):** x265 calibration
  in `append_video_codec_args` sends only preset, CRF, tune, psy-rd and
  lookahead. Smart Codec's final x265 arguments also set references (3–5 by
  effort), PMode at MEDIUM and above, and deblock `-1,-1` at HIGH and above, so
  calibration samples are not encoded with the final settings. Not changed
  here; needs a decision on whether calibration should mirror them, given
  their encode-time cost. Unassigned.
  - **Correction and re-measurement, 2026-11-10 10:15 America/Phoenix (Claude
    Code, TASK-20261110-x265-calibration-tools):** the finding above missed that
    the `EncoderTuning` doc comment (`smart-optimizer-logic.vala`) already
    records leaving reference count out of calibration as a measured decision
    (x265 psy-rd 2.5 + ref 4: size +1.7%, VMAF +0.05). This is a documented
    trade-off, not an oversight. Re-measured on `tests/testvideo-raptor.webm`
    (20 s from 10 s, 720p, CRF 24, one clip), calibration args against Smart
    Codec's final args at each effort's base preset:

    | Effort (preset) | Final adds | Size | VMAF | Probe encode time |
    | --- | --- | --- | --- | --- |
    | Medium (fast) | ref 4, PMode | −1.8% | −0.00 | ×1.11 |
    | High (fast) | ref 5, PMode, deblock −1,−1 | −0.7% | −0.05 | ×1.22 |
    | Max (faster, preset ref 2) | ref 5, PMode, deblock −1,−1 | +2.7% | +0.57 | ×1.50 |

    Medium and high stay inside the documented ±2%. Max is slightly outside,
    because the `faster` preset's 2 references differ most from Smart Codec's 5.
    **Decision (user, 2026-11-10):** keep the trade-off; the accuracy gain at max
    effort is not worth the extra calibration time. Status → deferred. The doc
    comment now records this re-measurement. No behaviour changed.

### AUD-20261110-svt-variance-boost — SVT-AV1 "Variance" AQ never enabled Variance Boost

- **Task/agent/date/base:** TASK-20261110-svt-variance-boost; Claude Code
  (Opus 5.5); 2026-11-10 09:10 America/Phoenix (UTC-07:00); main at e278ace.
  Found while advising the user on settings for a real conversion.
- **SVT-F1 (Medium, verified):** AQ Mode "Variance" sent `aq-mode=1` together
  with `enable-variance-boost=1` and the AQ Strength
  (`src/encoders/svt-av1-builder.vala`). SVT-AV1 4.2.0 warns that segment-based
  `aq-mode=1` is for "demos, experimentation", logs "Variance AQ based on
  segmentation with Variance Boost not supported, disabling Variance Boost", and
  reports `AQ mode / Variance Boost : 1 / 0`. So the choice selected an
  experimental mode, dropped the boost, and ignored AQ Strength. On an 8 s
  1080p clip, output with and without the boost under `aq-mode=1` was
  byte-identical.
  - **Fix:** "Variance" now sends only `enable-variance-boost=1` and
    `variance-boost-strength=N`, leaving `aq-mode` at the rate-control default.
    "Disabled" (`aq-mode=0`), "Complexity" (`aq-mode=2`) and "Automatic"
    (nothing) are unchanged. The UI label stays "Variance" because the tab,
    builder and Smart Codec resolver compare these strings.
  - **Why no `aq-mode=2`:** on a synthetic clip, Variance Boost changed the
    output under CRF, QP (where FFmpeg selects `aq-mode=0`) and VBR without any
    `aq-mode`. Forcing `aq-mode=2` under `-qp 30` produced output byte-identical
    to `-crf 30`, so QP would silently become CRF.
  - **Verification:** new test
    `/combine/svt-av1/aq-variance-enables-variance-boost` fails on the old
    builder ("did not expect 'aq-mode=1'") and passes on the fix. A real
    encode of `tests/testvideo-raptor.webm` (first 3 s, preset 10, CRF 30) with
    the new arguments reports `AQ mode / Variance Boost strength / octile /
    curve : 2 / 2 / 5 / 0` with no warning; the old arguments report `1 / 0`.
- **SVT-F2 (Low, open, pre-existing, not changed):** "Complexity" sends
  `aq-mode=2` in every rate-control mode. Under QP that is SVT-AV1's CRF, as the
  identical-output result above shows, so QP + Complexity does not encode at a
  constant QP. Unassigned; needs a product decision rather than a mechanical fix.
- **Limits:** The UI was not run; the builder was tested through its snapshot
  path. Checked against SVT-AV1 4.2.0 and FFmpeg 9.0.2 only.
- **Follow-up, 2026-11-10 09:38 America/Phoenix (Claude Code, from the user's
  pasted conversion log):** the user rebuilt the app and ran one SVT-AV1
  conversion from its window with AQ Mode "Variance". The clip was a 1.4 s
  720x1280 H.264 file from their own library; paths are omitted. The logged
  command carried
  `-svtav1-params enable-variance-boost=1:variance-boost-strength=2` with no
  `aq-mode`. SVT-AV1 4.2.0 reported `AQ mode / Variance Boost strength / octile /
  curve : 2 / 2 / 5 / 0`, printed no segmentation or "disabling Variance Boost"
  warning, and the conversion completed. This covers the UI-to-encoder path
  for "Variance" under CRF (preset 8, CRF 28). User-run; the agent checked the
  log, not the output file. QP and VBR were not run from the UI.

### AUD-20261109-user-bulk-testing — User-reported manual desktop testing

- **Task/agent/date/base:** TASK-20261109-user-bulk-testing; recorded by Claude
  Code from the user's statement; 2026-11-09 20:40 America/Phoenix (UTC-07:00);
  main at a4bcaaa (v2.1.0).
- **Report:** Heavy manual folder-conversion testing by the user on their own
  desktop "worked great", including bulk input/output playback and folders in
  Recently Opened.
- **What it addresses:** the "no manual desktop pass" limit recorded in
  TASK-20261109-bulk-playback-implementation, AUD-20261109-bulk-playback-review
  and AUD-20261109-bulk-playback-fixes, and the same limit for folder history.
  Treat hands-on use of these features as done by the user.
- **What it does not close:** RECENT-F1 (a request for permanent regression
  tests, not for manual use); screen-reader, network-storage and installed-
  release checks; SO-F1's knee stop, unless a tested video could not reach its
  quality ceiling, which the report does not say.
- **Evidence standing:** User-reported. No agent observed the runs; no logs,
  counts or build identity were supplied.

### AUD-20261109-bulk-playback-fixes — Fix and verification for BPLAY-F2 to BPLAY-F5

- **Task/agent/date/base:** TASK-20261109-bulk-playback-fixes; Claude Code;
  2026-11-09 19:35 America/Phoenix (UTC-07:00); main at e11be84 with uncommitted changes.
- **BPLAY-F2 (verified):** the tree without `tests/`, `DevTools/` and
  `Screenshots/` now configures (3 targets) and compiles the application.
  Before the fix the same tree stopped at configure.
- **BPLAY-F3 (verified):** the scratch program from the review, unchanged,
  now reports 2 completed, 2 outputs, row status "Completed" and View Output
  Video enabled after the edit-and-restore sequence; before the fix it
  reported 0 / 0 / "Waiting" / disabled. The same sequence is now part of
  `/bulk-playback/window/real-conversion-cancellation`.
- **BPLAY-F4 (verified by test):** a removed output stays unavailable after a
  recheck, and becomes eligible and counted again once the file is restored.
  The window-focus and dialog-open triggers are wiring only and were not
  exercised.
- **BPLAY-F5 (verified by test or inspection):** the two fallback warnings are
  asserted with `Test.expect_message`; Enter-to-play is asserted for one match
  and for none; labelled row buttons were inspected in a rendered
  `main-1000.png`; the `AGENTS.md` table lists the suite. Wrapped status text
  was not seen rendered with a long message.
- **Checks run:** development build; full suite 29 OK, 0 failing; the six
  `bulk-playback` cases with no skips on Wayland; archive simulation;
  scratch program with two real x264 runs.
- **Limits:** No manual desktop pass, screen reader or installed build.

### AUD-20261109-bulk-playback-review — Independent review of the bulk playback implementation

- **Task/agent/date/base:** TASK-20261109-bulk-playback-review; Claude Code;
  2026-11-09 19:16 America/Phoenix (UTC-07:00); main at e11be84 plus Codex's
  uncommitted TASK-20261109-bulk-playback-implementation. Read-only for source.
- **Scope:** `playback-launcher.vala`, `bulk-playback-model.vala`,
  `bulk-playback-view.vala`, the diffs to `main.vala`, `bulk-conversion.vala`,
  `hamburger-menu.vala` and `meson.build`, and `tests/bulk-playback-test.vala`.
  Commits 7242896 and e11be84 were not reviewed.
- **Reproduced from the implementation's record:** development build succeeds;
  full suite 29 OK, 0 failing; all six `bulk-playback` cases pass on Wayland
  without skips. The dialog lifecycle, generation/cancellation guards in
  `BulkPlaybackModel.play` and the row recycling read as described.
- **Checks run:** build and full suite; a configure of a simulated release
  archive and of `git archive HEAD`; a scratch program built from the
  `bulk-playback-test` source list driving the real MainWindow through two
  real x264 folder runs. Isolated XDG and temporary directories.
- **Limits:** No manual desktop pass, no screen reader, no installed build.
  Codex's three screenshots were inspected; `dialog-200.png` was captured
  mid-animation and shows little. BPLAY-F4 and BPLAY-F5 are by reading only.
  The test's default-handler registration was checked not to touch the user's
  `~/.config/mimeapps.list` in this run.

#### BPLAY-F2 — Release archives fail to configure

- **Severity/status/owner:** High; open; unassigned.
- **Where:** `meson.build`, the `bulk_playback_test` target at the end of the file.
- **Evidence:** `.gitattributes` marks `tests/` as `export-ignore`, and every
  other test target is wrapped in `if fs.exists(...)`. This one is not. With
  `tests/` removed, `meson setup` stops with "meson.build:951:21: ERROR: File
  tests/bulk-playback-test.vala does not exist." The same configure on
  `git archive HEAD` succeeds (3 targets). A GitHub release tarball, and
  therefore the AUR package built from it, would not build.
- **Next action:** Wrap the target and its `test()` in the same guard.

#### BPLAY-F3 — Folder list stops following the queue after the output field is edited and restored

- **Severity/status/owner:** Medium; open; unassigned. Regression from this change.
- **Where:** `main.vala`: `output_entry.changed` starts `preview_bulk_folder`
  without resetting the controller's queue, and the list is now rebuilt only on
  `queue_replaced`. `BulkConversionController.run` reuses its queue when the
  folder and output keys are unchanged, so no `queue_replaced` follows and
  `BulkPlaybackModel.update` ignores items it does not hold.
- **Evidence (measured):** two real files; run 1 cancelled after the first
  completes (model: 1 completed). Output field set to "x" and back to empty:
  the list now holds preview items. Run 2 converts the second file
  (controller: completed / completed) while the model reports 0 completed,
  0 outputs, row status "Waiting", and View Output Video stays disabled.
  Previously every `changed` re-rendered from the controller's items, which
  corrected the list on the first update; that is by reading the old code,
  not a run of it.
- **Impact:** display only. Files are converted and published correctly; the
  list, counts and output playback are wrong for that run.
- **Next action:** Re-render from `bulk_controller.items` when a run starts on
  an existing queue (or emit `queue_replaced` there), and add this sequence to
  the playback suite.

#### BPLAY-F4 — A failed file check disables a row until Rescan

- **Severity/status/owner:** Low; open; unassigned. By reading.
- **Where:** `BulkPlaybackModel.play` sets `input_available`/`output_available`
  to false on any non-cancellation error; `BulkPlaybackEntry.refresh` only
  re-enables the output flag when the video path changes, and never the input.
- **Impact:** a transient failure (network or removable storage, a file moved
  back) leaves Play Input greyed for that row, and can disable the menu action
  when it was the last one, until Rescan or a folder change.

#### BPLAY-F5 — Small items

- **Severity/status/owner:** Low; open; unassigned. By reading.
- `PlaybackLauncher` drops the two `warning ()` messages the menu code logged
  when ffplay was requested but missing or failed to start; the fallback is
  now silent.
- Row status text changed from wrapped to middle-ellipsised; long failure
  reasons are now only readable in the tooltip.
- In the dialog, Enter in the search field does nothing until a row is
  selected, even with a single match.
- The two row buttons are icon-only (a play triangle and a camera); which is
  input and which is output is only in the tooltip.
- `AGENTS.md`'s test table does not list `bulk-playback`.

### TASK-20261109-bulk-playback-implementation — Playback implementation and final review

- **Agent/date/base:** Codex; 2026-11-09 19:04 America/Phoenix (UTC-07:00);
  main at e11be84 plus local implementation. Scope: shared player launcher,
  bulk presentation model, row/dialog lifecycle, MainWindow/menu/controller wiring,
  source lists, permanent tests and user documentation.
- **Result:** No unresolved functional defect identified in this scope. Playback
  resolves a selected source or confirmed completed primary video, validates file
  type asynchronously and rejects stale generation/request results. Existing
  desired destinations, in-progress outputs and collage artifacts cannot be
  selected as completed videos. Folder/queue state is unchanged by playback.
- **BPLAY-F1 (verified, introduced and fixed during implementation; owner Codex):**
  The custom filter closure retained its dialog. stop() now clears the filter's
  model/function and disconnects subscriptions; close/Escape cancel before closing
  animation. MainWindow's error callback uses a tracked weak reference. The
  repeated-close test uses GLib.WeakRef and proves dialog destruction over four
  cycles; pending-close and reset cases prove no late launch. No follow-up needed.
  A minimum-height overflow exposed by the real-conversion desktop test was also
  corrected by allowing the bulk scroll area to shrink; final fatal-warning tests
  and 420-pixel dialog render succeed.
- **Permanent coverage:** Six bulk-playback cases exercise eligibility/missing
  files/cancellation, Unicode filtering/live results/scale/selection/scroll,
  recycled-row targets, actual MainWindow actions/reset/file-folder transitions,
  a real x264 batch cancelled after one success, and real ffplay/desktop handoff.
  The real batch's completed video remains playable while the next item is stopped.
  Failed/missing ffplay executables fall back to a temporary desktop handler.
  Final close/Escape paths and displayed status tooltips are included.
- **Results:** Full suite 29 OK, zero failures. Final development build plus
  playback-launcher-logic, hamburger-recent-menu-rebuild and bulk-playback pass
  after the last tooltip/close refinements. New suite executes all six cases with
  no skips on Wayland. Headless GTK skips in other suites are not counted as
  display coverage. Build retains the three existing application Vala warnings;
  generated C has compiler diagnostics typical of the existing Vala build.
- **Scale evidence:** Core Ultra 7 270K Plus, GTK 4.24.1, libadwaita 1.10.0.
  Dialog and main list create 205 reusable row widgets for 1,000 entries; a single
  item update creates none. Search-to-filtered-list processing at 200 entries
  measured 57–115 ms including the 50 ms search delay. The initial under-100-ms
  target is not consistently achieved under load; treat it as future tuning,
  not an asserted performance guarantee. No full 200-video encoding benchmark.
- **Limits:** Rendered desktop images inspected, including narrow dialog and
  1,000-item main list. No physical keyboard/mouse or screen-reader pass, network/
  removable filesystem check or installed-release run. Partial artifact-publication
  failures remain conservatively unavailable for output playback. Source/model
  tests do not eliminate the ordinary race between final stat and external open.
  RECENT-F1 remains open: the new full-window playback tests do not replace its
  requested recent-folder reopening/rename/late-lock cases.
- **Evidence/status:** [Battleplan](bulk-playback-battleplan.md); logs under
  /tmp/ffgtk-bulk-playback-{full-suite,final-build,final-tests}.log and screenshots
  under /tmp/ffgtk-bulk-playback-visuals/. The first full-suite launch was not
  executed because automatic approval review reached a usage limit; after the
  user's continuation, the normal approval path succeeded and the suite ran.
  No bypass, user-media access, preference changes, installation or publication.
  Application, tests and documentation remain uncommitted.

### TASK-20261109-bulk-playback-plan — Large-batch playback design review

- **Agent/date/base:** Codex; 2026-11-09 18:22 America/Phoenix (UTC-07:00);
  main at e11be84; existing design notes preserved.
- **Scope/result:** [Battleplan](bulk-playback-battleplan.md) captures the requested
  scalable playback UX and source-informed integration steps. No new functional
  defect asserted. MainWindow currently rebuilds bulk rows on controller updates;
  the plan replaces that pattern with stable model entries and reusable views.
- **Design checks:** Explicitly covers preview items before queue ownership,
  completed primary videos versus desired paths/collage artifacts, batch generation
  guards, async existence checks, recycled-row callbacks and selection during live
  filtering. Partial artifact-publication failures are conservatively excluded
  from output playback unless future result reporting explicitly supports them.
- **Verification/status:** Local source/reference review and documentation checks
  only. No runtime or performance measurements, application changes or publication.
  RECENT-F1 remains open; planned full-window tests are not completed evidence.
  Document is ready for implementation planning; no implementation started.

### TASK-20261109-bulk-playback-design — Playback in folder mode

- **Agent/date/base:** Codex; 2026-11-09 18:19 America/Phoenix (UTC-07:00);
  main at e11be84; application read-only.
- **Result:** Feasible using existing playback launch logic; no new defect alleged.
  HamburgerMenu permits input playback only for FILE. Multi-output results favor
  opening a folder, and the bulk list has no selected row or playback controls.
  A specific video must be chosen before either action has an unambiguous target.
- **Available data:** BulkItem.path identifies each source; completed items have
  result.primary_file_path identifying the video even when result.output_paths
  also contains a collage. output_path is assigned a desired destination before
  conversion finishes, so existence of that path alone is not proof of success
  and could identify an older conflicting output. Use completed state plus result
  and recheck the final regular file at activation.
- **Proposed UX:** Add Play Input/Play Output controls on each bulk row; optionally
  route existing menu actions to a batch-scoped choice of playable inputs or
  completed videos. Reuse the ffplay/default-player preference. Keep folder input
  and editing-tab restrictions unchanged, and retain Open Output Folder. Input
  playback can be available before conversion; completed videos can be played
  while later items run or after cancellation. Never launch staging files or
  collage artifacts as output videos.
- **Implementation/tests:** Share the existing private playback helper; pass a
  chosen path without request_input or controller state changes. Reset any menu
  selection on folder/queue replacement and keep it stable across row rebuilds.
  Test before/after completion, partial cancellation, deleted files, collision
  renaming, collateral image outputs and folder/file transitions. Existing bulk
  rows are rebuilt on updates, so menu/dialog snapshots need activation-time
  validation. Full-window coverage would also address relevant parts of RECENT-F1.
- **Limits/status:** Source inspection only, no runtime verification or estimate
  benchmark. No application changes. Shared documentation remains uncommitted.

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
