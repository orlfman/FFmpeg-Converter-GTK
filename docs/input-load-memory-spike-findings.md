# Input-load memory spike — findings and proposed solution

Date investigated: 2026-07-27

Follow-up investigation: 2026-07-28

Instrumented investigation (glibc `malloc_info`): 2026-07-28

## Summary

Loading a large 4K WebM input causes `ffmpeg-converter-gtk` to grow from about
213 MiB RSS to over 36 GiB, and the memory is not returned when the input is
replaced. A clean launch of the same build settles at about 213 MiB.

Two separate defects combine to produce this:

1. **Peak.** The application eagerly opens the source in two independent
   in-process `Gtk.MediaFile`/GStreamer playback pipelines — one for the Crop &
   Trim preview, one for Audio-tab playback. Each pipeline holds roughly
   **17.8 GiB of live allocations** while the file is loaded. The duplication
   doubles an already-unacceptable per-pipeline cost.
2. **Residual.** When the input is replaced, both pipelines free everything
   correctly, but glibc never returns the freed pages to the kernel. RSS stays
   at 36 GiB with **99.5% of the heap sitting free and unused**. A single
   `malloc_trim(0)` call on the live process recovered 98.9% of it.

There is **no leak**. Teardown is correct. This was confirmed by dumping
`malloc_info` from the live process before and after an input swap.

The file also triggers two eager full-file helper scans, which add substantial
I/O but do not own the retained memory.

## Reproduction

The original 2026-07-27 reproduction file has since been deleted. The pathology
is **not specific to it** — the 2026-07-28 instrumented session reproduced the
full spike on a different file:

```text
/mnt/storage3/library/tmp/input/gallery-dl/nzbget/2025-02-23 - Raw Footage Stationary Camera College Gymnastics 4k Sports Video #gymnastics #4k #gymnast [HVpm_Z6qLzA].webm
```

- Container: WebM/Matroska
- File size: 10,223,491,441 bytes (9.52 GiB)
- Video: AV1, 4K
- Audio: Opus

Any long 4K WebM appears sufficient. A stress fixture can be regenerated rather
than preserved; it should not be committed to the repository.

Toolchain at time of measurement: GTK 4.22.4, GStreamer 1.28.5, glibc 2.44,
24 logical CPUs.

## Measurements

All figures below use binary units (1 GiB = 1024³ bytes). Earlier revisions of
this document divided KiB values by 1000 and overstated every GiB figure by
about 2.4%; those numbers have been recomputed.

### Clean launch, no input

```text
VmRSS        218,008 kB   =   213 MiB
  RssAnon     97,128 kB   =    95 MiB    ← real private heap
  RssFile    120,860 kB   =   118 MiB    ← mapped libraries/fonts, shared+clean
VmSize     2,128,672 kB   =  2.03 GiB    ← mostly reservation, not real memory
VmSwap             0 kB
Threads           14
```

Anonymous mappings at idle: 115 totalling 1.64 GiB reserved but only 87.9 MiB
resident. Of these, one 82,080 kB mapping is the main `brk` heap (79.8 MiB, fully
resident) and 22 are ~64 MiB glibc arena subheaps that are reserved and
essentially untouched.

The 118 MiB of file-backed RSS is dominated by Mesa's shader compiler
(`libLLVM.so.22.1`, ~19 MiB resident, pulled in by the radeonsi/Vulkan stack)
and four SF-Pro font faces at ~4 MiB each. All shared and clean, therefore
reclaimable under pressure. The honest idle cost of the application is the
**95 MiB of private anonymous memory**, not the 213 MiB headline.

### After loading the 9.52 GiB input

```text
VmRSS     37,967,984 kB   = 36.21 GiB
  RssAnon 37,782,244 kB   = 36.02 GiB
  RssFile    185,712 kB   =   177 MiB    ← barely moved
VmSwap             0 kB
Threads           68
```

RSS plateaus at 36.21 GiB and remains stable — it does not climb indefinitely
once loading completes.

Anonymous mapping structure: **587 mappings of ~64 MiB at 98% residency =
35.83 GiB**, which is 99.5% of all anonymous RSS. This is the same structure
visible at idle (22 nearly-empty subheaps), now filled in. `HEAP_MAX_SIZE` is
64 MiB on 64-bit, so these are glibc non-main-arena subheaps.

### Duplicate pipelines — confirmed two ways

Open descriptors: two, both on the same file, both at offset 10,223,491,441
(end of file).

Thread names in `/proc/<pid>/task/*/comm` show two complete pipelines rather
than one pipeline with extra threads:

```text
2 × GstPlay              2 × matroskademux
2 × multiqueue0:src      2 × multiqueue1:src
2 × multiqueue2:src      2 × multiqueue3:src
2 × vqueue:src           2 × aqueue:src
2 × typefindelement
```

### `malloc_info` before and after input swap

Dumped from the live process via `gdb -p <pid>` calling
`malloc_info(0, fopen(...))`, once with the 9.52 GiB file loaded and once after
switching the main input to a small file. The process survived both dumps with
no change in state.

Raw dumps are archived in
[`data/input-load-memory-spike/`](data/input-load-memory-spike/).

```text
                        loaded (9.52 GiB)     after swap to small file
  heap from OS             36.02 GiB               36.10 GiB
  IN-USE                   35.77 GiB (99.31%)       0.18 GiB ( 0.50%)
  free within heap        253.2 MiB  ( 0.69%)      35.92 GiB (99.50%)
  arena A in-use           17.83 GiB                0.00 GiB
  arena B in-use           17.83 GiB                0.00 GiB
  process RSS              36.21 GiB               36.29 GiB
```

Both large arenas report `system current` of 17.94 GiB with 288 subheaps each —
a near-perfect symmetry that maps one-to-one onto the two `GstPlay` pipelines.
288 × 64 MiB = 18 GiB per arena; 2 × 288 ≈ the 587 subheap mappings counted from
`pmap`.

After the swap, the freed space is **fully coalesced**: in the largest arena,
18,369.2 MiB of free space spans 612 chunks, of which only 0.1 MiB sits in small
bins. The remaining ~18.4 GiB is roughly 463 large consolidated chunks averaging
~40 MiB.

### Confirmed: `malloc_trim(0)` on the live process

With the small file still loaded and 36.29 GiB retained, `malloc_trim(0)` was
called on the running process by the same `gdb` method. It returned `1` (memory
released):

```text
                 before          after          recovered
  VmRSS         36.29 GiB       0.41 GiB        35.88 GiB  (98.9%)
  RssAnon       36.11 GiB       0.23 GiB
  subheaps      585 @ 35.90 GiB resident → 585 @ 0.07 GiB resident
  VmSize        38.5 GiB        38.5 GiB        unchanged
```

Wall time was 4.5 s including `gdb` attach and detach; the trim itself is a small
fraction of that. The application remained fully live — same thread count, media
descriptor still open, RSS stable at 421 MiB ten seconds later with no regrowth.

Two points matter for anyone reproducing this:

- **`VmSize` does not move.** `malloc_trim` uses `madvise(MADV_DONTNEED)`, which
  drops physical pages while keeping the mappings. The subheap *count* stays at
  585; only their residency collapses. Monitor RSS, not VSZ.
- 421 MiB afterwards is roughly double the 213 MiB clean-launch baseline, which
  is consistent with a small file being loaded at the time.

This is the measured basis for item 3 below. It is a real fix for residual RSS,
not a speculative one.

### Why the memory is in subheaps rather than `mmap`

Direct `mmap` allocations totalled only 7.0 MiB (10 blocks) while loaded. A
3840×2160 4:2:0 frame is 12.4 MiB, far above glibc's 128 KiB default `mmap`
threshold, so frame-sized blocks *should* be individually mapped and unmapped on
free. They are not, because glibc raises the threshold dynamically (up to 32 MiB)
once an `mmap`'d block of that size is freed; subsequent frame-sized allocations
then come from arena subheaps, which cannot be released individually.

## Conclusions from the instrumented data

**There is no leak.** In-use memory drops from 35.77 GiB to 0.18 GiB on input
change, with the current code and no modifications. Both pipelines release
everything they allocate.

**Retained RSS is glibc arena retention.** 35.92 GiB is freed but never returned
to the kernel, because non-main arenas only shrink from the top subheap and there
are 288 per arena.

**`malloc_trim(0)` works — measured, not predicted.** Called on the live process
it recovered 35.88 GiB of 36.29 GiB (98.9%) in well under 4.5 s, leaving the
application fully functional.

**Peak memory is the more serious defect.** 17.83 GiB of *live* allocation for a
single playback pipeline is unbounded buffering, not duplication. Removing the
duplicate pipeline halves peak from 36 GiB to 18 GiB — still far beyond what a
16 GiB machine can absorb. Trimming does not affect peak at all; it only cleans
up afterwards.

### Theories ruled out

| Theory | Verdict | Evidence |
|---|---|---|
| Normal startup cost | Ruled out | 213 MiB idle, 95 MiB private |
| Smart Optimizer | Ruled out | Allocation occurs at input selection, before optimization |
| Linux filesystem cache | Ruled out | `RssAnon` 36.02 GiB is private anonymous |
| Captured FFmpeg waveform logs | Ruled out | Repeating the command produced ~6.5 KiB of output |
| Memory leak | **Ruled out** | `malloc_info` in-use falls to 0.18 GiB after swap |
| Heap fragmentation | **Ruled out** | Free space is coalesced into ~40 MiB chunks |
| Arena proliferation | **Ruled out** | 24 arenas against a default cap of 8 × 24 cores = 192; `M_ARENA_MAX` would change nothing |
| Ordinary single-pipeline decode cost | Ruled out as *normal* | A standalone GStreamer AV1 playback test stayed ~289 MiB; 17.83 GiB per pipeline here is pathological |

The waveform helper process was separately measured at 645 MiB RSS with 20
threads while running. Non-trivial, but 1.8% of the parent's footprint, and it
exits.

## Relevant load paths

Every input-path change immediately invokes all of these consumers in
`AppController.wire_file_input_changed()` (`src/app-controller.vala:727-733`):

```vala
info_tab.load_input_info (path);
trim_tab.load_video (path);
audio_tab.load_video (path);
subtitles_tab.load_video (path);
```

The two in-process playback pipelines are:

1. `VideoPlayer.load_file()` (`src/video-player.vala:208-232`) constructs a
   `Gtk.MediaFile` from the complete source and attaches it to the Crop & Trim
   preview picture. Called eagerly from `TrimTab.load_video()`
   (`src/trim-tab.vala:410`).
2. `AudioPlayer.load_file()` (`src/audio-player.vala:311-329`) also constructs a
   `Gtk.MediaFile` from the complete source when audio stream 0 is selected
   (`:322-328`). This makes the Audio tab open a second 4K AV1 playback pipeline
   even though it only needs audio. Called from `AudioTab`
   (`src/audio-tab.vala:2234`) once probing completes.

`SubtitlesTab` and `InformationTab` are ffprobe-only and create no pipeline.

Additional eager full-file work:

- `AudioPlayer.generate_waveform_async()` (`src/audio-player.vala:605-657`) runs
  FFmpeg `showwavespic` over the entire audio stream.
- `InformationTab.count_keyframes()` (`src/information-tab.vala:1343-1374`) runs
  `ffprobe -show_entries packet=flags` over every video packet. Its doc comment
  at `:1340` claims it "reads the container index only", which is wrong — the
  command demuxes the complete video stream.

## Proposed solution

Ordered by impact. Items 1 and 2 address peak memory, which is what makes the
application unusable on lower-end machines. Item 3 addresses residual RSS.

### 1. Bound the playback pipeline's buffering

**Highest-value change, and not previously identified.**

One pipeline holding 17.83 GiB of live allocations is the core defect. Every
other item on this list is a multiplier or a cleanup on top of it.

Investigation needed before a fix can be specified:

- Run `heaptrack` against a fresh launch and load the stress fixture. This names
  the allocation sites directly and is the fastest route to the answer.
- Dump the pipeline topology with `GST_DEBUG_DUMP_DOT_DIR` to see what decodebin
  actually instantiates.
- The doubled `multiqueue0:src` … `multiqueue3:src` threads are the first place
  to look; decodebin's multiqueue can grow substantially when downstream does not
  consume.
- Test whether a pipeline whose widget is never mapped (the Audio tab case, and
  any hidden-tab case after item 4) fails to apply back-pressure, allowing
  decoded frames to accumulate in the paintable sink. For scale: 17.83 GiB at
  12.4 MiB per 4K frame is roughly 1,430 frames.

Likely mitigations, to be confirmed by the above: explicit `max-size-bytes` /
`max-size-time` limits on the queues, capping decoder threads, or not running a
video decode path at all for the audio-only use case (see item 2).

### 2. Never load the full video into the Audio player

Eliminates one of the two pipelines outright, halving peak.

`AudioPlayer.load_file()` already extracts non-primary audio streams into a
temporary audio-only file before constructing `Gtk.MediaFile`. Use that same path
for stream 0:

```vala
// Current behavior (src/audio-player.vala:322-328)
if (stream_index > 0)
    extract_and_load_playback.begin (path, stream_index);
else
    load_media_from_path (path);

// Proposed behavior
extract_and_load_playback.begin (path, stream_index);
```

The existing extraction command (`src/audio-player.vala:364-372`) uses
`-map 0:a:<index> -vn -sn -c:a copy` into a `.mka` temporary
(`:471-478`), so the primary stream can be copied without decoding or
re-encoding. The Audio tab's `Gtk.MediaFile` would then never instantiate a
second video pipeline.

The extraction should remain cancellable and generation-guarded, as it is now.
Its temporary file should continue to use the managed audio-player temp directory
and be removed when the input changes or the player is disposed.

#### Cost to account for

Stream copy does not decode, but it still **demuxes the entire source**. For a
9.52 GiB input that is a full-file read before the Audio tab can play anything.
Combined with item 4 (lazy waveform), that read lands the moment the user opens
the Audio tab, producing a visible stall that needs progress indication.

Extraction and waveform generation currently each read the whole file. A single
FFmpeg invocation with two outputs — the `-c:a copy` remux and the
`showwavespic` render — halves that I/O.

#### Multiple audio streams and behavior compatibility

Multiple audio streams do not require loading the original video into the Audio
player. The existing extraction path already selects one stream at a time. A
useful policy:

- Probe all audio streams from the original source and preserve the existing
  track-selection UI.
- Extract only the selected track into an audio-only playback proxy.
- Cache proxies by input file signature and audio-stream index so switching back
  to an already-used track is immediate.
- Delete every proxy associated with the previous input when no longer needed.

Stream copy preserves encoded audio without quality loss, but is not
automatically behavior-identical in every edge case. Potential differences:
initial extraction latency, temporary disk usage, remux compatibility, seek/index
behavior, duration rounding, and timestamp normalization for sources whose audio
starts at a nonzero timestamp or contains gaps.

To preserve the existing feature set, the proxy must be playback-only:

- Probing, waveform generation, conversion, extraction, and export must keep
  using the original source and selected source-stream index.
- Trim and audio-segment values must stay in the original source timeline.
- Any timestamp offset introduced by the proxy must be measured and compensated
  rather than changing stored segment times.
- Failed or unsupported stream-copy remuxes need a controlled fallback.
  `fallback_to_primary_stream()` (`src/audio-player.vala:421-426`) currently
  reopens the original source, which reintroduces the full pipeline and therefore
  the memory risk. A bounded audio transcode is a safer option if its behavior is
  clearly defined.

The current implementation already accepts proxy behavior for non-primary tracks,
which reduces the scope of extending it to stream 0, but the timestamp and
fallback cases still need explicit tests before claiming full equivalence.

### 3. Return freed heap pages to the kernel after large-media teardown

This addresses residual RSS only. It does nothing for peak.

The instrumented data shows teardown already works: in-use falls to 0.18 GiB
without any code change. **`Gtk.MediaFile.clear()` is therefore not required for
reclamation** and should be treated as teardown hygiene rather than as the fix.
It is still worth adding for deterministic timing, particularly in `VideoPlayer`,
where `picture.set_paintable (media)` (`src/video-player.vala:214`) holds a
second reference that outlives `reset_player_state()`.

Current cleanup paths are inconsistent:

- `VideoPlayer.reset_player_state()` (`:414-432`) pauses its `Gtk.MediaFile` but
  does not call `clear()` or null `media` before the next load.
- `AudioPlayer.reset_player_state()` (`src/audio-player.vala:937-940`) nulls
  `media` but does not first call `clear()`.

An ordered teardown when an input is replaced:

1. Stop update and preparation timers and disconnect media callbacks.
2. Set playback to false.
3. Detach the media from any `Gtk.Picture` holding a reference.
4. Call `Gtk.MediaFile.clear()` to close the backend pipeline.
5. Null the media reference.
6. Let the GLib main context run so GStreamer teardown and finalizers complete
   before requesting a trim.

**Then call `malloc_trim(0)`** from a delayed idle or timeout callback. glibc 2.44
exposes it (`/usr/include/malloc.h:148`). This has been **measured on the live
process**: 35.88 GiB of 36.29 GiB recovered (98.9%), application unaffected. Bind
it directly rather than adding a C file:

```vala
[CCode (cheader_filename = "malloc.h", cname = "malloc_trim")]
private extern int malloc_trim (size_t pad);
```

(`src/subprocess-compat.c` is already in the build if a C shim is preferred.)

Caveats: it cannot release still-referenced allocations, cannot prove GStreamer
teardown completed, and may cost performance as later allocations fault pages
back in. Run it after exceptional large-media teardown, not on routine UI
operations.

#### Optional: pin `M_MMAP_THRESHOLD`

Because glibc's dynamic threshold pushes frame-sized allocations out of `mmap`
and into arena subheaps (see Measurements), pinning the threshold explicitly at
startup would route them back to `mmap`, where each free unmaps immediately and
returns memory to the kernel with no trim call. This is continuous rather than
post-hoc and would prevent the buildup instead of cleaning it up.

Tradeoff: `mmap`/`munmap` churn at frame rate. Choose a threshold that keeps
ordinary allocations on the heap and only routes frame-sized blocks to `mmap`,
and benchmark playback smoothness before adopting.

Unsafe alternatives — dropping the kernel filesystem cache, or applying
`madvise()` directly to allocator-owned mappings — must not be used.

### 4. Lazily create playback pipelines

Selecting an input while working on a codec tab should not immediately prepare
players on hidden pages.

- Store the selected path in Crop & Trim and Audio state.
- Construct the `Gtk.MediaFile` only when the corresponding tab becomes visible,
  or immediately if that tab is already visible.
- Stop and release the pipeline when leaving a heavy preview tab if preserving
  exact playback position is not required.
- Ensure at most one full-video preview pipeline is active at a time.

**Unlisted dependency that will otherwise break trim defaults.** `TrimTab` reads
values populated only by `VideoPlayer.on_media_prepared()`:

- `player.intrinsic_width` / `intrinsic_height` (`src/trim-tab.vala:561-562`)
- `player.get_duration_seconds()` (`src/trim-tab.vala:481`, `:765`, `:1302`,
  `:2200`)

Defer the pipeline and these return 0 for any consumer running before the tab is
shown. `VideoPlayer` already demonstrates the fix: `start_fps_probe()`
(`src/video-player.vala:434`) sources fps from `FfprobeUtils` independently of
the media pipeline. Duration and dimensions should come from the ffprobe path
too — `InformationTab` already probes the file.

### 5. Make waveform generation lazy

Generate the waveform when the Audio tab is first shown rather than on every
global input selection. Keep the existing file-signature cache so revisiting the
tab remains fast.

For very long sources, consider a bounded representative waveform. The helper
process was measured at 645 MiB and is not the owner of the retained memory, so
this is an I/O and latency change, not a memory fix.

### 6. Remove eager full-file keyframe counting

`InformationTab.count_keyframes()` should not scan a multi-gigabyte video just
because it was selected.

Preferred options, in order:

1. Defer exact keyframe counting until the Information tab is visible.
2. Present the value as unavailable unless explicitly requested.
3. If exact counting remains automatic, stream and count `ffprobe` output
   incrementally.

Note that the dominant cost is the full demux (I/O and time), not the captured
string: a 4K60 hour-long source yields on the order of 220,000 packets, roughly
1 MB of CSV.

The doc comment at `src/information-tab.vala:1340` must also be corrected —
`-show_entries packet=flags` demuxes packets across the file and does not read a
container index.

### 7. Add cancellation and stale-load protection across all consumers

Rapidly selecting another file should cancel every probe, waveform job, audio
extraction, and pending media preparation associated with the previous path.

`InformationTab` is the worst offender and needs more than "follow the existing
pattern" — it has **no cancellation and no generation guards at all**
(`grep -n 'generation\|Cancellable\|cancel' src/information-tab.vala` returns
nothing):

- `load_input_info()` (`:397-415`) spawns a raw detached `Thread` per input
  change.
- That thread runs two blocking `Process.spawn_sync` ffprobe calls (`:1355` and
  the `-show_format -show_streams` probe), one of which is a full-file demux.
- The result is delivered via `Idle.add()` with **no staleness check**, so a slow
  probe of a large file overwrites a newer, faster probe. Last-to-finish wins
  rather than last-requested.
- Nothing bounds thread creation under rapid input switching, and
  `Process.spawn_sync` cannot be cancelled at all — it must be converted to an
  async subprocess before cancellation is even possible.

## Verification plan

After implementing the changes:

1. Launch without an input and record baseline RSS (expect ~213 MiB / ~95 MiB
   private).
2. Select the stress fixture while remaining on a codec tab.
   - No full-video `GstPlay` pipeline should be created.
   - No waveform or exact-keyframe scan should start until its tab is opened.
3. Open the Audio tab.
   - Confirm the player opens an audio-only temporary file.
   - Confirm no second descriptor for the original source remains open for
     playback.
4. Open Crop & Trim.
   - Confirm only one full-video `Gtk.MediaFile` pipeline is active.
   - **Record peak RSS for that single pipeline.** This is the acceptance
     criterion for item 1; the pre-fix value is 17.83 GiB.
5. Verify RSS stays within the normal GTK/GStreamer range and does not reach
   multiple GiB.
6. Repeat with ordinary short H.264, HEVC, VP9, and AV1 inputs.
7. Change inputs rapidly and close the window during preparation to verify
   cancellation and temporary-file cleanup.
8. After preparing the stress input, replace it with a small file.
   - Confirm old descriptors and old GStreamer threads disappear.
   - Dump `malloc_info` and confirm in-use collapses (it already does today).
   - Compare RSS before and after the delayed `malloc_trim(0)`. The manual
     baseline to match is 36.29 GiB → 0.41 GiB. Check RSS, not VSZ — `VmSize`
     stays flat because `madvise(MADV_DONTNEED)` retains the mappings.
9. Test sources with zero, one, and multiple audio streams.
   - Switch repeatedly among primary and non-primary tracks.
   - Verify waveform selection, seeking, duration, segment playback, and export
     still refer to the correct original stream.
   - Include nonzero audio start times, discontinuities/gaps, and common PCM,
     AAC, Opus, AC-3, and DTS inputs.
   - Exercise remux failure and fallback behavior.

### Measurement recipe

Peak and residual memory:

```sh
grep -E 'VmRSS|RssAnon|Threads' /proc/<pid>/status
pmap -x <pid> | awk '$2+0>=65000 && $2+0<=65600 {n++} END {print n" subheaps"}'
```

In-use versus free (requires root because `ptrace_scope` is 1):

```sh
pkexec gdb -p <pid> -batch \
  -ex 'set $f = (void *) fopen("/tmp/mi.xml", "w")' \
  -ex 'call (int) malloc_info(0, $f)' \
  -ex 'call (int) fclose($f)' \
  -ex detach
```

Then compare the final `<system type="current">` against `<total type="rest">`.

Manual trim, to reproduce the 98.9% reclamation on a running process:

```sh
pkexec gdb -p <pid> -batch -ex 'call (int) malloc_trim(0)' -ex detach
```

A return value of `1` means pages were released. All three operations tolerated
attachment with no observable disruption, but each stops every thread briefly and
can deadlock if a thread is stopped holding an arena lock; prefer sampling when
the pipeline is idle.

### Automated coverage

Cover the load policy as pure state logic: hidden tabs must not request media
preparation, Audio must request audio-only extraction for stream 0 as well as
later streams, and stale generations must not publish their results. Also cover
playback-proxy cache keys, proxy cleanup, timestamp-offset conversion, and
fallback policy without depending on GTK media playback.

The stress fixture should remain a manual, regenerable test input rather than
being added to the repository.
