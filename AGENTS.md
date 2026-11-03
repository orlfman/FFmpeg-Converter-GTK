# FFmpeg Converter GTK: agent guide

Shared instructions for AI agents working in this repository. Keep project
knowledge here or in the relevant project documentation, rather than only in an
agent's private memory.

## What this is

A Linux desktop frontend for FFmpeg, written primarily in Vala with GTK4 and
libadwaita, plus small C compatibility bridges. It supports SVT-AV1, x265, x264
and VP9 single-file/folder conversion, audio and subtitle operations, Crop & Trim, combining
videos, collages, watermarking/logo removal, and a measured Smart Optimizer.
In-app audio/video previews use **libmpv**, not GStreamer or Gtk.MediaFile.

This is the application repository itself; there is no nested upstream checkout
or patch-export workflow.

## Read first

- `docs/CHANGELOG.md`: active work, recent changes, decisions and handoffs.
- `docs/AUDIT.md`: open findings, evidence, fixes and verification limits.
- `README.md`: features, dependencies, build/install instructions and profiles.
- `meson.build`, `meson_options.txt` and `Makefile`: authoritative build targets,
  source lists, profiles and test names.
- `DevTools/SMOKE-TEST.md`: manual checks for UI, playback and operation wiring.
- Relevant plans and findings in `docs/` before changing the affected subsystem.
  For optimizer work, start with `smart-optimizer-quality-solver-plan.md`,
  `smart-optimizer-phase0-findings.md` and
  `quality-mode-vmaf-measurement-findings.md`. For playback, consult the mpv
  findings and `mpv-hwdec-vulkan-crash.md`.

Plans and findings may describe proposals, older measurements or pre-reorganization
`src/*.vala` paths. Check their status and the current code; do not treat planned
features as already implemented.

## Layout

- `src/app/`: application entry point, main window, controller, converter and
  persistent settings.
- `src/ui/`: tabs, dialogs, auxiliary windows and shared widgets.
- `src/encoders/`: codec tabs/builders, presets, filter construction, trim
  arguments and logo detection.
- `src/audio/`: audio settings, probing, compatibility rules and argument builders.
- `src/runners/`: subprocess execution, cancellation, progress tracking and
  operation-specific runners.
- `src/player/`: libmpv backend, audio/video players and C compatibility bridge.
  `vapi/mpv.vapi` supplies the in-tree Vala bindings.
- `src/optimizer/`: Smart Optimizer orchestration, pure logic and cache.
- `src/util/`: shared constants/identity, FFprobe utilities, runtime capability
  checks, temporary-file helpers and other common logic.
- `tests/`: GLib/Vala and C regression tests plus media/subtitle fixtures.
- `Resources/`, `Screenshots/`: desktop entries, icons/resources and README images.
- `DevTools/`: interactive build/install helpers, probes, corpus tools and smoke
  checks. These helpers can have side effects; read them before running them.
- `docs/`: design plans, investigations and validation findings, including the
  shared handoff records in `CHANGELOG.md` and `AUDIT.md`.

## Multiple agents and handoffs

Multiple agents may work in parallel on independent tasks. These records are the
shared project memory across agents, chats and sessions:

- **`docs/CHANGELOG.md`** records who changed what, why, current ownership and
  the next steps for whoever takes over.
- **`docs/AUDIT.md`** records what was investigated, findings and evidence,
  unresolved risks, fixes and verification. Detailed reports may stay in other
  `docs/` files, but must be linked from the shared audit record.

### Before starting

1. Read both logs, including active work, recent handoffs and unresolved findings.
   Check the current branch, HEAD and `git status`; distinguish existing changes
   from your own. Logs describe work, but the current files determine what is
   actually present.
2. Choose a unique task ID and identify your agent/session. Add an entry under
   **Active work** in `docs/CHANGELOG.md` before editing. Include timestamp and
   timezone, task/goal, branch/worktree and base revision, owned files or scope,
   status and dependencies. Use the same task ID in both logs and all handoffs.
3. Keep parallel edit scopes separate. Coordinate overlaps before changing the
   same files; agree on one writer for shared integration files such as
   `meson.build`. Read-only reviews may overlap. Another active task does not
   block unrelated work.
4. Use separate build directories for concurrent builds/tests, or coordinate
   access. Do not clean, reconfigure or build in a directory another agent is
   using. When using separate branches/worktrees, include their location and
   base revision in the handoff so another agent can find the work.

### While working

- Keep active-work status and ownership current when scope, dependencies or
  blockers change. Communicate findings that affect another agent promptly and
  record them in the logs; chat messages alone are not a durable handoff.
- Treat the two logs as shared files. In a coordinated team, have the lead agent
  serialize log updates and attribute each contributor. Otherwise coordinate
  short writing turns. Re-read immediately before editing and apply narrow
  changes; never replace a log with an older whole-file copy or remove someone
  else's entries. The active-work list is a coordination aid, not an atomic lock.
- Preserve historical entries. Add new history entries newest first; change your
  live active-work entry as needed. Correct or supersede earlier conclusions
  explicitly, retaining the original evidence and the reason for the correction.
- Record each audit, investigation and re-test in `docs/AUDIT.md`, even when
  there are no findings. Ordinary build/test results for a change may go in its
  changelog entry; any discovered issue also belongs in the audit log.
- Give each finding a stable ID, severity, status, affected files/revision,
  evidence or reproduction steps, owner (or explicitly unassigned), and next
  action. Link fixes to their changelog task/commit. Distinguish **fixed, awaiting
  verification** from **verified**; close a finding only with recorded evidence.
- State which checks actually ran and their results, skips and limits. Do not
  present another agent's report as your own verification, or a proposed check
  as a completed one. Never include secrets, private media contents or large raw
  logs; link to suitable artifacts instead.

### Before finishing or handing off

Add a dated history entry to `docs/CHANGELOG.md` with:

- Task ID, agent/session and contributors, timestamp with timezone, branch/worktree
  and base revision; resulting commits if any, otherwise explicitly uncommitted.
- What changed and **why**, affected files, important decisions and alternatives
  rejected where that context helps the next agent.
- Checks run, outcomes and limitations; related audit finding/report links.
- Current status, remaining work, blockers and concrete next steps, including
  commands or artifacts needed to resume safely.

Update the active-work entry to match: remove completed tasks from that list,
or mark unfinished work as **ready for handoff**, **blocked** or **paused** with
the last owner and reason. Do not leave abandoned work marked in progress.
An incoming agent must read the handoff, confirm the current files/revision and
claim ownership in the active-work list before continuing. Do not silently take
over a task still marked in progress; coordinate with its owner or the user while
continuing unrelated work. Keep unfinished work and pre-existing user changes
clearly distinguished. Updating the logs does not authorize commits, pushes,
installation or other actions beyond the user's request.

## Working rules

- Check `git status` before editing. Preserve existing user changes; coordinate
  file ownership when agents work in parallel.
- Keep changes focused and follow nearby code: four-space indentation in Vala,
  PascalCase types, snake_case methods/fields, and existing brace/spacing style.
  Match the local C and Meson style when touching those files.
- Edit Vala sources and the maintained C bridges, not generated C/build output.
  Add new files to the appropriate Meson source lists, including test targets
  that explicitly list application sources.
- Keep UI work on the GTK main thread. Snapshot widget settings before worker
  work; preserve cancellation, operation IDs and stale-result guards when inputs
  change or windows close. Release subprocesses, mpv resources, timers and signal
  handlers through the existing lifecycle paths.
- Build subprocess commands as argument arrays. Preserve configured FFmpeg and
  FFprobe paths, locale-independent numeric formatting and proper FFmpeg filter
  escaping; test filenames with spaces and special characters when relevant.
- Reuse shared filter, audio, probe and temporary-file helpers. Preserve stream
  selection/mapping, subtitle defaults, chapters, filter order, pixel format and
  bit depth across conversion, trim and combine paths.
- Smart Optimizer calibration must represent the actual output settings and
  trimmed duration. Keep cache identity consistent with those settings. Quality
  tiers are measured VMAF **ceilings**, not minimums; preserve this distinction
  and the separation between measured results and estimates.
- Detect optional FFmpeg capabilities at runtime. Do not hardcode a developer
  machine's GPU, device path or encoder/filter availability. Preserve software
  decoding and selectable hardware-decoding fallbacks.
- Commit and push only when the user asks. Keep commits small and descriptive;
  include a `Co-Authored-By:` trailer identifying the assisting agent accurately.
  Do not add `Signed-off-by:` or change the repository's Git identity/settings.
- Do not bump versions unless requested. A requested version bump must keep
  `meson.build` and `src/util/constants.vala` in sync.
- Installing dependencies or the application, uninstalling it, and changing
  system configuration require user authorization. Existing authorization for
  that action is sufficient; routine local builds and tests do not install it.

## Build and test

Run commands from the repository root. Required build tools are Meson >= 0.62,
Ninja, Vala, a C compiler and pkg-config. Libraries include GLib/GObject/GIO,
GTK4, libadwaita >= 1.5, JSON-GLib, libsoup 3 and libmpv; the Makefile also checks
Cairo and Pango. Runtime tools are FFmpeg and FFprobe. FFmpeg's `libvmaf` filter
enables quality-target measurements; FFplay is optional. See the README for
distribution package names. Keep `meson_options.txt` compatible with the declared
minimum Meson version.

Prefer a development profile for local checks without installation:

```sh
# First setup only:
meson setup builddir-dev -Dprofile=development
# For an existing build directory, inspect its profile; reconfigure if needed:
# meson setup builddir-dev --reconfigure -Dprofile=development
meson compile -C builddir-dev
meson test -C builddir-dev --print-errorlogs
```

The development binary is `builddir-dev/ffmpeg-converter-gtk-devel`. It has its
own application ID and settings directory, so it can run beside the release app.
With the default profile, `make` builds `builddir/ffmpeg-converter-gtk` and
`make test` builds and runs the tests. Tests and diagnostic probes are excluded
from the default application build; a successful build alone is not a test pass.

For a focused run, use the **test name**, for example:

```sh
meson test -C builddir-dev --print-errorlogs smart-optimizer-logic
```

Relevant suites include:

| Area | Meson test names |
| --- | --- |
| Audio arguments, settings and track state | `audio-builder`, `audio-add-builder`, `audio-extract-logic`, `audio-settings`, `audio-reorder`, `audio-reorder-state` |
| Probing and subtitle language | `ffprobe-utils`, `subtitle-language-guesser` |
| Trim, subtitles and combine state | `trim-subtitles-state`, `combine-window-state` |
| Preview backend and timing | `mpv-backend-state`, `mpv-render-timing`, `mpv-player-display-state` |
| Player controls and window lifetime | `player-speed-selection`, `preview-fullscreen-state` |
| Optimizer and logo detection | `smart-optimizer-logic`, `logo-detector-logic` |
| Folder processing and prepared profiles | `bulk-conversion`, `bulk-conversion-widgets`, `prepared-conversion`, `prepared-conversion-widgets`, `encode-profile-snapshot`, `smart-codec-resolver`, `smart-codec-widgets` |
| Other utilities and menus | `playback-launcher-logic`, `update-checker`, `heap-trim-policy`, `hamburger-recent-menu-rebuild` |

After code changes, build with no new warnings and run the relevant regression
tests; run the full suite for shared pipeline or cross-cutting changes. Add
meaningful regression coverage for changed behavior, especially state changes
within one running instance, cancellation and stale callbacks. Documentation-only
changes need reference/command checks, not a full rebuild.

Display-dependent GTK tests can skip without a working display. Report skips,
missing dependencies, hardware limits and checks not run explicitly. For playback,
widget or signal changes, also exercise the relevant smoke checklist on a desktop;
headless tests do not establish visual correctness. For argument/filter changes,
use a small real FFmpeg operation and FFprobe output checks where practical.

## Protect media, preferences and installed copies

- Use disposable outputs and small synthetic/copied media for testing. Never
  overwrite source media or delete existing outputs to make a test pass.
- Release settings normally live in
  `~/.config/FFmpeg-Converter-GTK/settings.ini`; development settings live in
  `~/.config/FFmpeg-Converter-GTK-Devel/settings.ini`. Do not edit or reset the
  user's preferences unless asked; back them up before an authorized edit.
- Isolate manual test runs, including the managed FFmpeg temporary root:

  ```sh
  test_root="$(mktemp -d)"
  mkdir -p "$test_root/config" "$test_root/cache" "$test_root/tmp"
  XDG_CONFIG_HOME="$test_root/config" XDG_CACHE_HOME="$test_root/cache" \
    TMPDIR="$test_root/tmp" ./builddir-dev/ffmpeg-converter-gtk-devel
  ```

  A development app already running with the same application ID may receive
  the launch instead. Ensure the window belongs to the build being tested.
  Inspect and remove only your own test directory after all test processes stop.
- `DevTools/build.sh` is an interactive **build-and-install** helper, not a
  compile check: `--dev` still installs to `~/.local`; release mode cleans its
  build directory and offers a version bump. Use direct Meson commands above
  for routine validation. `DevTools/build-debug.sh` also cleans its debug build
  directory and launches a debugger.
- `make install` changes the installed application. `make uninstall` also
  deletes the release settings directory. Do not run either, or uninstall
  helpers, as routine checks; preserve package-managed installations.

## Leaving useful records

Summarize what changed, checks performed, results and remaining limitations when
finishing. Always update `docs/CHANGELOG.md` for completed or handed-off work and
`docs/AUDIT.md` for audits, investigations, re-tests and discovered issues, using
the workflow above. Link detailed `docs/*-findings.md` reports from those shared
records so the next agent can find them. Update related plans when their
implementation status changes. Do not invent results or rewrite another agent's
history.
