# Smoke Test

Manual smoke test for recent UI, playback, trim, audio, subtitle, and settings changes.

## Suggested Sample File

Use one input file with as many of these as possible:

- 2+ audio tracks
- 2+ subtitle tracks
- chapters

Also keep one external subtitle file handy:

- `.srt`, `.ass`, `.vtt`, `.ssa`, `.sub`, or `.sup`

## Core Pass

### 1. Audio Tab

- Switch between audio streams.
- Confirm the waveform changes when the stream changes.
- Click the waveform to seek.
- Drag across the waveform to scrub.
- Play a non-primary stream.
- Run one segmented audio export.
- If the source audio is Opus and `Copy Streams` is enabled for segments, confirm the output uses `.mka`.

### 2. Video Player / Trim

- Use transport controls:
- play / pause
- seek backward / forward
- frame backward / forward
- Confirm the time readout updates correctly.
- Seek to a chapter.
- Add a segment.
- Edit segment start/end.
- Move a segment.
- Delete a segment.

### 3. Crop & Trim

- Set a crop region.
- Stamp the crop onto one segment.
- Confirm only that segment keeps the crop metadata.

### 4. Subtitles Tab

- Reorder one detected subtitle track.
- Toggle default between two subtitle tracks.
- Add one external subtitle.
- Remove one external subtitle.
- In burn-in mode, confirm an added external subtitle appears in the burn track selector.
- Run one subtitle extract or apply/remux if practical.

### 5. Preferences

- Open `Preferences`.
- Type into the `ffmpeg` path entry and confirm validation updates.
- Type into the `ffprobe` path entry and confirm validation updates.
- Click `Browse` for both entries and confirm the file chooser opens.

### 6. Hamburger Menu

- Open `About`.
- Run `View Input File`.
- After one successful operation, run `Open Output Folder`.

### 7. Success Toast

- Finish one successful operation.
- Click the toast `Open Folder` button.

## Notes

- This checklist is meant to catch regressions in signal wiring, binding lifetime, playback interaction, and state synchronization.
- Automated tests cover logic and some widget wiring, but they do not replace desktop GTK smoke testing.

## Folder conversion

Use disposable synthetic inputs and an output folder outside the repository.
Never overwrite source media or remove existing outputs to make a check pass.

- Choose/drop a folder (including a directory whose name ends in `.mp4`). Confirm
  the queue lists only top-level supported videos, in stable order, without aliases.
- Move from a single file to a folder and back. General manual crop/logo values
  survive; old media previews clear. Crop & Trim, Audio and Subtitles are disabled
  for folders, including programmatic navigation; General Detect actions are disabled.
- Confirm the resolved output destination, per-file Match Source Size description,
  chosen codec and queue results are visible. No new hamburger-menu bulk item exists.
- Try size and quality objectives, all four codecs, content/delivery choices,
  No Audio, multiple audio tracks and General crop/rotation/timing/speed/watermark.
  Confirm unavailable quality capability and impossible per-file targets are clear.
- Convert directly with manual CRF/bitrate/preset and General settings: no optimizer
  analysis occurs, even with Auto-Convert/quality target enabled. Check all four codecs.
- Optimize with Auto-Convert on: each file finishes optimization, encoding and cleanup
  before the next starts. With it off, rows become Ready without output files.
  Convert uses each file's saved settings without another optimization pass.
- Edit a codec/General value after Optimize, including changing it back to its original
  control value: the edit applies to every unfinished file, other per-file settings
  survive, and old estimates clear. Optimizer-only controls do not alter saved profiles.
- Cancel analysis halfway: only prepared files can subsequently convert; other rows
  explain that Optimize is needed. Replace a source/watermark and check stale settings
  are rejected. Switching codec uses the new codec and clears incompatible saved settings.
- Retry skips completed rows; Rescan includes them and clears recommendations.
- Enable Recently Opened in Preferences. Open a file and a bulk folder; check the
  folder is labelled “(Folder)” with its full path in the tooltip. Reopen each
  from the menu and restart the app to check persistence. A folder must restore
  bulk mode with a searchable input-playback list after scanning (never pass the
  folder itself to a player). Clear History and disable history;
  both files and folders must disappear. Deleted folders must be pruned.
- During analysis/encoding, attempt another Optimize, Convert, Combine, recent-file
  or recent-folder selection and input drop. They cannot replace the active input or launch competing work.
- Pre-create output names and sidecars, including source aliases. Verify bytes are
  unchanged and new outputs get suffixes. Verify the default `Converted` folder.
- Cancel during analysis, each encoding pass and optional collage. Check no next file
  starts, subprocesses/passlogs/staging are released, and completed videos remain.
- Close while processing and confirm cancellation waits for cleanup. Check unavailable
  or full destinations stop dispatch while source-specific failures allow later items.

### Bulk playback and large lists

- Use 200 or more synthetic source entries. Open **View Input Video**, search by
  filename, clear search, select with the keyboard, and play without changing the
  folder input. Check Unicode, long filenames, full-path tooltips and narrow layout.
- Scroll before a status update; the list must keep its position and selection.
  **Play Input** on a recycled row must play that row's current source exactly once.
- Before any conversion completes, **View Output Video** and row output buttons
  are disabled. During conversion, completed videos appear live in the output
  dialog without clearing search, focus or an existing selection.
- Exercise both per-row output buttons and the dialog. Confirm the actual published
  filename plays after a collision rename, and a generated collage is not offered
  as the video. An old file at a desired destination is not completion evidence.
- Cancel after one success: that output remains playable and unfinished items do
  not. Playback must leave the queue, settings and disabled editing tabs unchanged.
- Delete a target and attempt playback: show feedback without launching another
  item or cancelling conversion. Close the dialog using its close button/Escape
  while a lookup is pending; no delayed player should appear.
- Rescan, change folder, switch to a single file and close the main window. Old
  dialogs/selections must close and pending file checks must be cancelled.
- Verify ffplay and the desktop-default route, including fallback when ffplay is
  missing or cannot start. Use isolated preferences/default-handler registrations.
- Check accessible names and keyboard/screen-reader navigation on the target
  desktop. Automated signal-driven checks do not replace an assistive-technology pass.

Automated synthetic tests cover these areas partially; this checklist also requires
an actual desktop pass. Timed-logo calibration fixes and remaining long-range VMAF alignment
investigations are tracked in `docs/AUDIT.md`.
