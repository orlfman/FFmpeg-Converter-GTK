# Input-load memory spike — findings and proposed solution

Date investigated: 2026-07-27

## Summary

Loading one particular WebM input causes `ffmpeg-converter-gtk` to retain about
32 GiB of resident memory. This is not normal application startup usage and is
not caused by Smart Optimizer. A clean launch of the same build settles at about
225 MiB RSS.

The evidence points to the application eagerly opening the large AV1 source in
two independent in-process `Gtk.MediaFile`/GStreamer playback pipelines: one for
the Crop & Trim video preview and another for Audio-tab playback. The file also
triggers two eager full-file helper scans, which add substantial I/O but do not
own the retained 32 GiB.

## Reproduction file

```text
/mnt/storage3/library/tmp/input/gallery-dl/nzbget/2026-05-29 - Highlights 2 Days College Track Championship NE10 Connecticut #championship #college #sports [G2_l_7y4rYo].webm
```

Observed media properties:

- Container: WebM/Matroska
- File size: 9,801,369,895 bytes (about 9.13 GiB)
- Duration: 3,724.421 seconds (1:02:04.421)
- Video: AV1 Main, 3840×2160, approximately 59.94 fps, 8-bit 4:2:0
- Audio: Opus stereo, 48 kHz
- Overall bitrate: approximately 21.05 Mbit/s
- GStreamer reports the file as seekable and discovers it successfully.
- A scan found approximately 2,862 Matroska Cluster signatures; the file does
  not appear to be a single malformed giant cluster.

## Measurements

### Clean application launch

The locally built application was sampled for several seconds without an input
file:

```text
RSS: approximately 224,604 KiB
VSZ: approximately 2,223,844 KiB
```

### After loading the reproduction file

The installed application process was inspected after its helper processes had
finished:

```text
VmRSS:        32,829,304 KiB
RssAnon:      32,634,492 KiB
RssFile:         194,776 KiB
RssShmem:             36 KiB
VmSwap:                0 KiB
Threads:                  66
```

Nearly all of the allocation is private anonymous resident memory. It is
therefore real process memory, not merely Linux filesystem page cache and not a
large virtual-address reservation being mistaken for RSS.

`pmap` showed hundreds of fully resident anonymous allocations near 64 MiB
each. The application retained these allocations after `ffprobe` and the
waveform-generating FFmpeg process had exited.

The live process contained two `GstPlay` threads, two Matroska demuxer threads,
and two open descriptors for the reproduction file. Both descriptors were at
offset 9,801,369,895, the end of the source. This matches the two eager media
loads described below.

## Relevant load paths

Every input-path change immediately invokes all of these consumers in
`AppController.wire_file_input_changed()`:

```vala
info_tab.load_input_info (path);
trim_tab.load_video (path);
audio_tab.load_video (path);
subtitles_tab.load_video (path);
```

The two in-process playback pipelines are:

1. `VideoPlayer.load_file()` constructs a `Gtk.MediaFile` from the complete
   source and attaches it to the Crop & Trim preview picture.
2. `AudioPlayer.load_file()` also constructs a `Gtk.MediaFile` from the
   complete source when audio stream 0 is selected. This makes the Audio tab
   open a second 4K AV1 playback pipeline even though it only needs audio.

Additional eager full-file work includes:

- `AudioPlayer.generate_waveform_async()` runs FFmpeg `showwavespic` over the
  entire audio stream.
- `InformationTab.count_keyframes()` runs `ffprobe` over every video packet.
  Its comment currently says it reads only the container index, but the command
  actually demuxes the complete video stream.

## Causes ruled out

### Normal application startup

Ruled out. Startup without this input uses about 225 MiB RSS.

### Smart Optimizer

Ruled out for this incident. The allocation happens when the input is selected,
before optimization. Smart Optimizer has its own memory-budgeted calibration
behavior, but it is not responsible for this input-load spike.

### Linux filesystem cache

Ruled out as the main 32 GiB figure. `/proc/<pid>/status` and `smaps` attribute
about 32.6 GiB directly to private anonymous memory in the application.

### Captured FFmpeg waveform logs

Ruled out. Repeating the waveform command generated only about 6.5 KiB of
combined console output. The completed helper process cannot account for the
memory retained by the parent.

### Ordinary single GStreamer decoding cost

A standalone GStreamer AV1 playback pipeline stayed around 289 MiB RSS during a
short decode test. The pathological result therefore appears specific to the
application's eager `Gtk.MediaFile` setup, its duplicated playback pipelines,
and this long 4K60 AV1 source. The precise allocator or GStreamer/graphics
component responsible for retaining every anonymous arena has not yet been
isolated.

## Proposed solution

### 1. Never load the full video into the Audio player

This is the highest-value change.

`AudioPlayer.load_file()` already extracts non-primary audio streams into a
temporary audio-only file before constructing `Gtk.MediaFile`. Use that same
path for stream 0 as well:

```vala
// Current behavior
if (stream_index > 0)
    extract_and_load_playback.begin (path, stream_index);
else
    load_media_from_path (path);

// Proposed behavior
extract_and_load_playback.begin (path, stream_index);
```

The existing extraction command uses `-map 0:a:<index> -vn -sn -c:a copy`, so
the primary Opus stream can be copied quickly into a comparatively small
audio-only temporary file without decoding or re-encoding it. The Audio tab's
`Gtk.MediaFile` would then never instantiate a second AV1 video pipeline.

The extraction should remain cancellable and generation-guarded, as it is now.
Its temporary file should continue to use the managed audio-player temp
directory and be removed when the input changes or the player is disposed.

### 2. Lazily create playback pipelines

Selecting an input while working on a codec tab should not immediately prepare
players on hidden pages.

- Store the selected path in Crop & Trim and Audio state.
- Construct their `Gtk.MediaFile` only when the corresponding tab becomes
  visible, or immediately when that tab is already visible.
- Stop and release the pipeline when leaving a heavy preview tab if preserving
  its exact playback position is not required.
- Ensure at most one full-video preview pipeline is active at a time.

This avoids paying the decoder/demuxer cost for features the user may never
open.

### 3. Make waveform generation lazy

Generate the waveform when the Audio tab is first shown rather than on every
global input selection. Keep the existing file-signature cache so revisiting
the tab remains fast.

For very long sources, consider generating a bounded representative waveform
or using an FFmpeg filter path designed to aggregate audio without retaining
duration-proportional state. This should be measured separately; the current
helper process was not the owner of the retained 32 GiB in this reproduction.

### 4. Remove eager full-file keyframe counting

`InformationTab.count_keyframes()` should not scan a multi-gigabyte video just
because it was selected.

Preferred options, in order:

1. Defer exact keyframe counting until the Information tab is visible.
2. Present the value as unavailable unless explicitly requested.
3. If exact counting remains automatic, stream and count `ffprobe` output
   incrementally rather than capturing and splitting the complete output.

The method comment should also be corrected: `-show_entries packet=flags`
demuxes packets across the file; it does not merely read a container index.

### 5. Add cancellation and stale-load protection across all consumers

Rapidly selecting another file should cancel every probe, waveform job, audio
extraction, and pending media preparation associated with the previous path.
Generation checks already exist in several components; the remaining load paths
should follow the same pattern.

## Verification plan

After implementing the changes:

1. Launch without an input and record baseline RSS.
2. Select the reproduction file while remaining on a codec tab.
   - No full-video `GstPlay` pipeline should be created.
   - No waveform or exact-keyframe scan should start until its tab is opened.
3. Open the Audio tab.
   - Confirm the player opens an audio-only temporary file.
   - Confirm no second descriptor for the original AV1 source remains open for
     playback.
4. Open Crop & Trim.
   - Confirm only one full-video `Gtk.MediaFile` pipeline is active.
5. Verify RSS remains close to the normal GTK/GStreamer range and does not grow
   into multiple GiB.
6. Repeat with ordinary short H.264, HEVC, VP9, and AV1 inputs.
7. Change inputs rapidly and close the window during preparation to verify
   cancellation and temporary-file cleanup.

Automated tests should cover the load policy as pure state logic: hidden tabs
must not request media preparation, Audio must request audio-only extraction for
stream 0 as well as later streams, and stale generations must not publish their
results. The 9.8 GB reproduction file should remain a manual stress fixture
rather than being added to the repository.

