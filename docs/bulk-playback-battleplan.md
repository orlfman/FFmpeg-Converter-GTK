# Bulk playback battleplan

Status: implemented locally; automated validation complete with the limits below.  
Author: Codex, 2026-11-09, America/Phoenix (UTC-07:00).  
Source baseline: `e11be84` on `main`.  
Task: `TASK-20261109-bulk-playback-plan`.

## Goal

Let a user processing 200 or more videos find and play a specific source or
completed output without leaving folder mode, disturbing conversion, or navigating
an oversized menu. Reuse the existing ffplay/default-player preference.

The user subsequently requested execution of this plan. Implementation is complete
under `TASK-20261109-bulk-playback-implementation`; installation and publication
have not been performed. This document develops the investigation recorded under
`TASK-20261109-bulk-playback-design` in [AUDIT.md](AUDIT.md).

## User experience

### Existing playback menu

Keep the existing **View Input Video** and **View Output Video** actions.

| Context | View Input Video | View Output Video |
| --- | --- | --- |
| Single-file mode | Preserve current behavior | Preserve current behavior |
| Folder mode, scan finished | Open searchable input dialog | Open searchable completed-output dialog |
| Folder mode, scan pending or failed | Disabled until inputs are available | Disabled unless the current batch still has eligible results |
| Folder mode, no completed videos | Input dialog available | Disabled; bulk panel explains that outputs become playable after completion |

Folder-mode output actions must never fall through to a video left over from a
previous single-file operation. **Open Output Folder** keeps its existing purpose.
No submenu should contain hundreds of filenames.

### Searchable playback dialog

Use one reusable dialog with an input/output mode, titled **Play Input Video** or
**Play Output Video**. Give it a bounded initial size, around 720 × 520 logical
pixels, adapting to smaller windows/screens. List length must not increase its
height. Keep the search and footer visible while the list scrolls.

- Search by case-insensitive filename text, including Unicode. For outputs,
  match both source and final output names, including collision-renamed outputs.
- Show filename, conversion status and enough secondary text to distinguish
  entries. Expose full source/output paths in tooltips or accessible detail.
- Show a count: “200 input videos”, “83 completed videos”, or
  “12 matches · 83 completed videos” when filtered.
- Select one item and enable **Play** when eligible; double-click/Enter may
  activate the same playback action. Do not launch playback on selection alone.
- Focus search on opening; support keyboard navigation, Escape to close,
  accessible button labels and screen-reader selection/count information.
- Keep the dialog open after launching a video, so another can be selected.
- Distinguish “No matching videos” from “No completed videos yet”. Clearing
  search restores the eligible list.
- While the batch runs, add newly completed outputs without stealing focus,
  clearing the query, changing a still-valid selection, or scrolling to the top.
- Reuse an already-open playback dialog when a menu action is invoked again.
  Switching between input/output mode clears selection and updates the title.

### Direct controls in the bulk list

Add **Play Input** and **Play Output** buttons to each visible file row. Compact
icons are acceptable with explicit tooltips and accessible names. They launch the
same validated paths as the dialog, without opening another selector.

Input is available before conversion. Output is available only for a completed
video. Completed videos remain playable while subsequent items run and after
cancellation. No automatic playback of each completed file, playlist, thumbnail
extraction, embedded player, or new playback preference is part of this scope.

## Current code and constraints

| Area | Current behavior | Required change |
| --- | --- | --- |
| `src/ui/hamburger-menu.vala` | Input action accepts FILE only; multi-output results favor folder actions; launcher is private | Delegate folder actions to the batch dialog and share playback launching |
| `src/app/main.vala` | `render_bulk_items()` removes/recreates every row; bulk list is not selectable | Maintain stable model entries and reusable rows; integrate dialog and row controls |
| `src/app/bulk-conversion.vala` | BulkItem stores source, state, desired/final output and result; broad `changed` signal | Expose structural versus item updates without altering scheduling |
| `src/runners/operation-output-result.vala` | Results can contain video plus collage; primary path identifies the main video | Use each item's confirmed primary video, preserving global result semantics |
| `src/player/playback-launcher-logic.vala` | Supplies existing route/argument logic | Reuse it through a shared launch service |
| `meson.build`, `tests/` | Existing component tests omit real MainWindow integration | Register new sources and maintained full-window playback coverage |

The preview scan supplies items directly to the UI before the controller owns a
conversion queue. Dialog input entries must therefore come from the currently
accepted displayed batch, not only `bulk_controller.items`. Reconcile preview
and execution entries when conversion begins.

## Playback eligibility and safety

1. Input target is the selected item's actual source path. Playback must never
   call `request_input()` or change the folder input, codec settings, optimizer,
   queue position, output destination or editing-tab sensitivity.
2. Output target requires completed state, a non-null item result and a nonempty
   `result.primary_file_path`. Use the actual published path, including any
   collision suffix. Never guess from the source basename or destination folder.
3. `item.output_path` alone is insufficient: it is assigned before conversion
   finishes and may name an older colliding file. Do not expose staging paths,
   in-progress encodes or collage images as playable outputs.
4. A main video published before optional artifact publication fails is outside
   the initial completed-item rule. Do not infer eligibility from file existence;
   extending partial-result reporting would be a separate explicit change.
5. Check that the selected target is still a regular file immediately before
   launch. Use asynchronous metadata lookup so slow storage does not freeze GTK.
   Follow symlinks consistently with existing input selection. Recheck batch
   generation and item eligibility after the lookup completes.
6. Missing/inaccessible files produce a concise message in the invoking UI;
   suppress stale callbacks after the dialog closes or its batch changes. Do not
   report a playback error as a conversion failure or cancel the batch.
7. Retain configured ffplay routing, desktop fallback, argument-array execution
   and child-process cleanup. The extracted launcher must preserve single-file
   behavior and return errors suitable for UI display.
8. A launch-time filesystem check cannot eliminate every external replacement
   race; the external player opens the path itself. Do not claim stronger identity
   guarantees or add expensive full-media probing to every click.

## Model and performance design

Use a shared batch presentation model, with one stable entry per accepted source
and a generation for the current batch. Key entries by generation plus a stable
source identity/path; never use a filtered row index as file identity.

Use GTK's model-based list approach (`GListStore`, filter/selection models and
`Gtk.ListView` with a reusable row factory) for the dialog and the main bulk list.
Confirm the chosen APIs against the project's installed GTK bindings and supported
minimums before implementation. No dependency/version bump is planned.

- Use observable entry properties or explicit item notifications for status,
  completed result and playback eligibility. Existing plain BulkItem fields do
  not notify views automatically.
- Distinguish queue replacement from an item change. Emit an item update only
  after all fields required by that state are consistent. Preserve existing
  consumers of `changed` until migrated and tested.
- Insert/remove entries on structural changes; update an existing entry on state
  changes. Do not recreate all widgets or replace the entire model for each item.
- Bind and unbind row handlers correctly. A recycled row must launch its current
  item exactly once, with no accumulated signal handlers or captured old paths.
- Keep ordering deterministic and stable while outputs arrive. Preserve selection
  by identity and retain the scroll position when its item is still visible.
- Filtering only reads cached display strings. It must not enumerate folders,
  stat all files, decode media or launch subprocesses on each keystroke.
- Coalesce notification bursts on the GTK main loop. Cache aggregate counts and
  update them with transitions, rather than rescanning every widget for totals.
- Avoid a file monitor per visible playback button. Validate availability on
  activation and update that item's availability after a failed check.

### Lifecycle policy

Folder change, accepted rescan or queue replacement creates a new generation.
Close the old playback dialog and invalidate its pending validations. Clear
selection/results that no longer belong to that generation. Reuse input entries
when preview hands off to execution only when they still belong to the same
accepted batch; transfer completed results only from authoritative controller
state, never by matching a filename alone.

Keep completed outputs available for the retained batch after finish/cancellation.
Rescanning intentionally starts a new batch view and does not rediscover historical
outputs from a destination directory. Opening another folder or switching to a
single file ends the old playback context. Closing the main window disconnects
model/dialog signals and cancels pending lookups; already launched external
players may continue normally.

## Implementation sequence

Phases below are implemented and automated checks passed. The validation record
at the end distinguishes completed checks from remaining manual/environment checks.

1. [x] **Shared launcher and eligibility rules.** Extract the existing launcher
   into a reusable service, preserving routing/fallback/cleanup. Add explicit
   per-item input/output resolution and an injectable launch seam for tests.
   Verify single-file playback still requests the same path and route.
2. [x] **Stable presentation model.** Cover preview, queue adoption, item changes,
   completion and reset. Introduce precise controller notifications and generation
   guards. Verify result/path/state updates are coherent before notification.
3. [x] **Efficient bulk rows and direct playback.** Migrate the main list to reusable
   rows, retain its existing information and summary, and add input/output buttons.
   Verify row recycling, keyboard focus and scrolling during live updates.
4. [x] **Searchable dialog.** Add bounded layout, filtering, counts, selection,
   empty states, playback error feedback and live completed-output updates.
5. [x] **Menu and lifecycle integration.** Route folder-mode actions to the dialog;
   preserve single-file actions and Open Output Folder. Handle repeated opening,
   mode changes, cancellation, rescan and window teardown.
6. [x] **Regression and performance validation.** Complete the matrix below,
   document measured results/limits, then update the smoke checklist, README,
   bulk plan, CHANGELOG and AUDIT. Publication/installation require a later request.

Likely new modules: a shared playback launcher under `src/player/`, a batch
presentation model and reusable row/dialog under `src/ui/`, plus focused tests.
Finalize names during implementation. Keep encoding, optimizer mathematics and
output publication policy outside this change.

## Acceptance tests

| Scenario | Required result |
| --- | --- |
| 200 accepted input videos | All discoverable through scrolling/search; dialog stays bounded |
| 1,000 model entries | Stress check remains responsive with reusable visible rows |
| Zero/one/many completed videos | Correct action sensitivity, eligible list and counts |
| Active search while outputs complete | Newly matching results appear; query/focus/valid selection remain |
| Spaces, Unicode, quotes, semicolons, leading hyphens | Literal correct target reaches the launcher; no shell interpretation |
| Similar source/output names and collision suffixes | Selected video's actual published output plays |
| Optimize only or conversion still running for that item | Input may play; unfinished output cannot |
| Cancellation after some successes | Completed outputs remain playable; pending/failed items do not |
| Video plus collage | Only the primary video is offered by output playback |
| Old colliding file exists at desired output | It is never mistaken for the new completed output |
| Delete target before click or during validation | Clear feedback, no stale launch, conversion unaffected |
| Change folder/rescan/close during async validation | Old result is ignored; no detached stale callback |
| Scroll/rebind rows repeatedly | Each button launches its currently displayed item once |
| Batch completes while dialog is open | Counts/actions update without resetting list state |
| Single-file and folder transitions | Correct action routing; no previous batch or unrelated output leaks |
| Keyboard/screen reader, narrow window, long filenames | Controls remain operable and names distinguishable |
| ffplay missing or launch fails | Existing fallback is retained and final failure is surfaced |

Use isolated XDG config/cache/temp directories and synthetic fixtures. Most tests
should capture launch requests rather than opening hundreds of real players.
Run one actual ffplay/default-player smoke check on synthetic media to validate
process handoff. Do not modify user media or preferences.

For the 200/1,000-item cases, instrument row creation/bind counts and update counts:
initial widget creation should scale with the viewport, and a single state change
must not recreate the whole list. Measure search-to-visible-result latency on the
test machine; use under 100 ms at 200 items as an initial target, recording hardware
and conditions rather than claiming an unmeasured guarantee. Exercise repeated
open/close cycles and check for retained handlers/models and stale selection.

Run relevant playback, bulk and menu tests, then the full suite because model and
menu changes cross shared UI paths. Include a maintained real-MainWindow test for
folder playback without switching input, completed-output activation, and reset
while validation is pending. Component-only tests or headless skips do not count
as that coverage. RECENT-F1 can be narrowed only for scenarios actually added;
its unrelated recent-folder cases remain open until separately covered.

## Completion criteria and handoff

The work is ready when a 200-video batch can be searched and played through both
menu and per-row controls, only eligible videos launch, playback leaves conversion
state untouched, live updates preserve interaction state, and the test matrix has
recorded results and explicit limitations. Update
[DevTools/SMOKE-TEST.md](../DevTools/SMOKE-TEST.md),
[bulk-conversion-plan.md](bulk-conversion-plan.md), [CHANGELOG.md](CHANGELOG.md) and
[AUDIT.md](AUDIT.md) before handoff.

Original estimated difficulty: moderate. Implementation reused existing playback
routing and added model/update integration, lifecycle handling and tests. Future
changes must recheck the current files, active-work claims and base revision.

## Implementation and validation record — 2026-11-09

- New modules: `src/player/playback-launcher.vala`,
  `src/ui/bulk-playback-model.vala`, and `src/ui/bulk-playback-view.vala`.
  `MainWindow` now consumes queue-replacement and per-item signals. Existing
  broad controller notifications remain available to other consumers.
- Shared playback validates regular-file type asynchronously, checks batch
  generation after the lookup, and cancels on reset/close/Escape. Output
  eligibility requires completed state and an item's confirmed primary result.
  Row callbacks read their current bound entry. Missing-file errors appear in
  the dialog or a toast; deleted targets are unavailable until a fresh batch view.
- Development build succeeds with the same three existing Vala warnings.
  Full suite: **29 OK, zero failures**. After the final tooltip and immediate
  close/Escape refinements, the development build plus `bulk-playback`,
  `hamburger-recent-menu-rebuild` and `playback-launcher-logic` passed again.
- The new `bulk-playback` suite runs six cases, including the real MainWindow:
  eligibility/cancellation, search/live updates/scale, recycled rows, full-window
  actions/reset, real x264 conversion with cancellation, and real external-player
  handoff/fallback. All six ran on Wayland without skips. Existing headless widget
  skips elsewhere do not count as desktop verification.
- The real batch test converted one synthetic video, cancelled before the next,
  and played the retained primary output through the full-window dialog. A real
  ffplay process completed synthetic media; isolated desktop-handler tests covered
  preference-off, missing ffplay and failed-executable fallback paths.
- On this Core Ultra 7 270K Plus / GTK 4.24.1 / libadwaita 1.10.0 desktop, 1,000
  entries created **205 row widgets** in both dialog and main list (GTK's reusable
  overscan pool). A single item update created no replacement rows. Search at
  200 entries measured **57–115 ms**, including the 50 ms typing delay and main-loop
  processing. The initial sub-100-ms target was not consistent under test load;
  it remains a tuning target, not a guaranteed latency. No per-keystroke filesystem
  checks or full media probing are performed.
- Selection and scroll persistence, Unicode search, 420-pixel-wide dialog layout,
  repeated close/release, deleted targets, late lookup cancellation, collision
  paths and collateral-image exclusion were exercised. Rendered screenshots were
  inspected at `/tmp/ffgtk-bulk-playback-visuals/`.
- Limits: no native mouse/physical-keyboard or screen-reader pass; keyboard actions
  were exercised through GTK signals and standard GTK navigation is retained.
  No network/removable-storage test, installed-release test, or 200-video encode
  marathon. Large-list tests use model fixtures; actual encoding uses tiny synthetic
  media. Partial artifact-publication failures remain conservatively excluded.
- Evidence: `/tmp/ffgtk-bulk-playback-full-suite.log`,
  `/tmp/ffgtk-bulk-playback-final-build.log`,
  `/tmp/ffgtk-bulk-playback-final-tests.log`, and the current Meson test log.
  Settings/cache/temp/default-player registrations were isolated. No user media or
  preferences changed. Application changes, tests and this document are uncommitted.

