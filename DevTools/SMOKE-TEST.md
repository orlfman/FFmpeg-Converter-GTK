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
