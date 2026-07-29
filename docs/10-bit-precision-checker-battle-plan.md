# 10-bit Precision Checker — Detailed Battle Plan

> **Implementation status:** planned; no production code has been added.
>
> **Locked product decisions:** the checker is opened from the hamburger menu,
> analyzes the video currently selected in the main window, lives in its own
> reusable window, begins scanning automatically when opened, follows later
> main-window input changes, never modifies the source, and reports evidence and
> confidence rather than pretending source provenance can be proven perfectly.

## Mission Statement

Add a user-facing **10-bit Precision Checker** that answers the practical
question:

> Is this video making meaningful use of its advertised 10-bit pixel format, or
> does it look like 8-bit material that was padded or re-encoded into 10-bit?

The entry point is:

```text
Hamburger menu → 10-bit Precision Checker
```

Selecting it opens a dedicated window and immediately scans the current main
window input file. The finished report must distinguish facts from inference:

```text
Container precision:  10-bit
Measured precision:   Effectively 8-bit
Assessment:           Likely 8-bit source padded to 10-bit
Confidence:           High
```

or, for a file whose lower bits are populated:

```text
Container precision:  10-bit
Measured precision:   Full 10-bit values detected
Assessment:           Consistent with native 10-bit
Confidence:           Medium
```

The checker is a forensic analyzer, not a metadata alias. `pix_fmt` answers only
how the decoded frame is stored. This feature must examine decoded sample values
and their lower-bit structure.

---

## The Non-negotiable Technical Truth

There are three separate questions:

1. **Is the bitstream encoded as 10-bit?** FFprobe and `pix_fmt` can answer this.
2. **Do decoded frames actually use more than eight bits?** Pixel analysis can
   answer this.
3. **Was the original camera/master/source truly greater than 8-bit?** A final
   encode cannot prove this in every case. Dithering, filtering, resizing, color
   conversion, grain synthesis, and lossy codec reconstruction can populate the
   lower bits after an 8-bit source has entered the pipeline.

An experiment on the local corpus demonstrates the trap:

- An 8-bit frame converted directly to `yuv420p10le` still reports
  `signalstats.YBITDEPTH=8`.
- The same 8-bit material encoded with x265 Main10 at CRF 18 reports
  `signalstats.YBITDEPTH=10` because lossy reconstruction creates values in the
  lower two bits.

Therefore:

- `YBITDEPTH <= 8` on a declared 10-bit stream is strong evidence of unused
  precision.
- `YBITDEPTH == 10` proves only that ten decoded bits are populated; it does not
  prove ten-bit ancestry.
- A “native 10-bit” assessment must remain probabilistic and must be gated on a
  calibrated combination of independent signals.
- **Inconclusive is a successful, honest result**, not an analyzer failure.

The UI, data model, tests, and documentation must preserve these distinctions.

---

## Scope

### In scope

- A hamburger-menu item named **10-bit Precision Checker**.
- A non-modal `Adw.Window` owned lazily by `MainWindow`.
- Automatic analysis of the currently selected main-window input.
- Automatic cancellation and restart when that selected input changes.
- FFprobe metadata inspection followed by sampled decoded-pixel analysis.
- Detection of simple 8-to-10-bit padding with high confidence.
- A calibrated probabilistic assessment for more difficult lossy re-encodes.
- Plain-language results, confidence, evidence, limitations, progress, cancel,
  rescan, and failure states.
- Unit tests for the pure classifier and parsers.
- Headless widget/lifecycle tests for the window.
- A repeatable corpus tool for matched-pair calibration and regression data.
- Common planar YUV 10-bit inputs first, with explicit unsupported/inconclusive
  handling for unusual formats.

### Out of scope for the first release

- Claiming cryptographic or forensic proof of original capture bit depth.
- Automatically changing codec-tab pixel-format selections.
- Automatically changing Smart Optimizer recommendations.
- Re-encoding, repairing, or replacing the selected video.
- Uploading samples or consulting online databases.
- Scanning every frame of a full-length video.
- Training or shipping an opaque machine-learning model before interpretable
  signals have been measured and validated.
- Treating HDR metadata, codec profile, encoder tags, or filename text as proof.
- Calling a user’s file “fake.” Report what is measured and what is likely.

---

## Product and Language Contract

### Terminology

Use these terms consistently:

- **Container precision**: the nominal decoded pixel depth inferred from
  `bits_per_raw_sample` and `pix_fmt`. “Stream precision” is also acceptable in
  technical details; do not imply that the container itself creates the depth.
- **Measured precision**: what the sampled decoded pixels demonstrably use.
- **Source assessment**: the most likely history inferred from the evidence.
- **Confidence**: confidence in the assessment, not a percentage of pixels that
  are “real.”
- **8-bit lattice**: the restricted set of 10-bit code values created by a
  straightforward 8-to-10-bit mapping.
- **Lower bit planes**: bits below the most significant eight bits of the
  declared sample format.

Avoid these phrases:

- “Definitely genuine 10-bit”
- “Definitely fake 10-bit”
- “Proven native source”
- “10-bit quality” as a synonym for populated code values

### Verdict taxonomy

Use a closed enum internally, with presentation text kept separate from the
classifier:

| Verdict | User-facing heading | Meaning |
|---|---|---|
| `NOT_APPLICABLE` | Encoded as 8-bit | No deep 10-bit analysis is needed. |
| `EFFECTIVELY_8_BIT` | Likely 8-bit source | A declared high-bit-depth stream overwhelmingly follows an 8-bit lattice or leaves its lower bits unused. |
| `FULL_PRECISION_PRESENT` | Full 10-bit values detected | Lower bits are populated, but origin is not distinguishable with enough confidence. |
| `CONSISTENT_WITH_NATIVE` | Consistent with native 10-bit | Multiple calibrated signals agree with the native-reference population. This remains an assessment, not proof. |
| `INCONCLUSIVE` | Analysis inconclusive | Evidence conflicts, content is unsuitable, coverage is insufficient, or the format lies outside calibrated support. |
| `UNSUPPORTED` | Pixel format not yet supported | The file is valid but cannot be analyzed safely without transforming the evidence. |
| `FAILED` | Analysis could not be completed | FFmpeg/FFprobe failed, the file changed/disappeared, or decoding produced no usable samples. |

`FULL_PRECISION_PRESENT` and `INCONCLUSIVE` are deliberately different. The
former positively establishes populated lower bits; the latter does not have
enough trustworthy measurement even for that statement.

### Confidence taxonomy

Start with categorical confidence rather than fake precision:

- **High**: strong margin beyond a calibrated boundary, adequate temporal and
  spatial coverage, and agreement between relevant planes/regions.
- **Medium**: useful evidence with a smaller margin or one material caveat.
- **Low**: report only with `FULL_PRECISION_PRESENT` or `INCONCLUSIVE`; never use
  Low to make an accusatory 8-bit-derived claim.
- **Not rated**: not applicable, unsupported, cancelled, or failed.

Do not ship numeric confidence percentages until calibration shows that they are
well calibrated probabilities rather than classifier scores wearing a percent
sign.

---

## User Experience

### Hamburger-menu behavior

Add this top-level item near **Combine Videos…**, before Preferences:

```text
Playback                  ›
Recently Opened           ›
Combine Videos…
10-bit Precision Checker…
Preferences
About FFmpeg Converter GTK
Quit
```

The backing application action should be named
`app.ten-bit-precision-checker`.

The action is enabled only when the input breadcrumb contains an existing
regular file. The window still validates that the file has a video stream, so a
race, malformed file, or non-video input results in an explanatory window state
rather than a crash.

Follow the existing file-dependent action pattern in `hamburger-menu.vala`:

- Look up the action registered by `MainWindow`.
- Track `file_pickers.input_entry.changed`.
- Enable or disable the checker action alongside “View Input Video.”
- Keep window ownership and construction out of `HamburgerMenu`; it should only
  expose the menu item and action availability.

### Window ownership and reuse

Follow the lazy `CombineWindow` ownership pattern in `main.vala`:

- `MainWindow` holds `TenBitPrecisionWindow? precision_checker_window`.
- The first action activation constructs it; later activations call `present()`
  on the existing instance.
- The window is transient for the main window but non-modal.
- Closing the checker cancels its active subprocess and clears the
  `MainWindow` reference.
- Closing the main window cannot leave an FFmpeg child behind.
- Reopening the checker uses the current input, never a path retained from a
  previously destroyed window.

### Input-following contract

The checker follows the main input while it exists:

1. Opening the window snapshots the current valid path and starts immediately.
2. When the input breadcrumb changes, `MainWindow` passes the new path to the
   existing checker window.
3. The window cancels the old scan, increments a generation counter, resets its
   display, and starts the new scan automatically when the new path is valid.
4. An empty/invalid new path shows a “Select a video in the main window” state.
5. Results from an older generation are discarded even if cancellation races
   with normal process completion.

The checker must not lock the main input. Changing the file is expected and must
be safe.

### Window layout

Use one `Adw.ToolbarView` with an `Adw.HeaderBar`, a vertically scrolling content
area, and an `Adw.ViewStack` or equivalent state stack.

Suggested content:

```text
┌──────────────────────────────────────────────────────────────┐
│ 10-bit Precision Checker                               [ × ] │
├──────────────────────────────────────────────────────────────┤
│ Source                                                       │
│ movie.mkv                                                    │
│ HEVC Main 10 · yuv420p10le · 3840×2160 · HDR10              │
│                                                              │
│ Analysis                                                     │
│ [██████████████████░░░░░░░]  Examining lower bit planes…    │
│ Sampling region 6 of 8                                      │
│                                                              │
│                                               [ Cancel ]      │
└──────────────────────────────────────────────────────────────┘
```

Finished:

```text
┌──────────────────────────────────────────────────────────────┐
│  Likely 8-bit source                                         │
│  High confidence                                             │
│                                                              │
│  Although encoded as 10-bit, sampled values overwhelmingly  │
│  follow an 8-bit lattice. The extra two bits appear unused.  │
│                                                              │
│  Container precision             10-bit                     │
│  Measured precision              Effectively 8-bit          │
│  Regions sampled                 8 of 8                      │
│  Frames examined                 192                         │
│  Lower-bit activity              Negligible                  │
│  8-bit lattice match             Very strong                 │
│                                                              │
│  ▸ What this result can and cannot prove                     │
│                                                              │
│                      [ Copy Report ] [ Scan Again ]           │
└──────────────────────────────────────────────────────────────┘
```

Do not rely on color alone. Every state needs a heading, icon, and text label.

### Required window states

1. **No input** — instruct the user to select a video in the main window.
2. **Probing** — metadata probe in progress.
3. **Not applicable** — source is 8-bit or lower; show the probed facts.
4. **Scanning** — progress, current phase, Cancel.
5. **Completed** — verdict, confidence, explanation, evidence, limitations,
   Scan Again, and Copy Report.
6. **Cancelled** — keep source summary; offer Scan Again.
7. **Unsupported** — state the exact pixel format and why conversion would
   contaminate the evidence.
8. **Failed** — concise error and Scan Again; technical details can be expanded.

Opening the window is the user’s consent to begin work, so do not add a redundant
initial Analyze button.

### Progress model

Progress should describe deterministic stages rather than mirror FFmpeg’s noisy
console timestamps:

1. Probing video stream
2. Choosing sample regions
3. Measuring effective bit depth
4. Examining lower bit planes
5. Comparing quantization patterns
6. Building report

When region/frame counts are known, map completed samples into the relevant
stage interval. Never show 100% before classification and report construction
have completed.

---

## Architecture

Keep process execution, measurement, classification, and presentation separate.
The classifier must be runnable without GTK or FFmpeg so thresholds and verdicts
can be tested exhaustively.

### Proposed new files

#### `src/ten-bit-precision-types.vala`

Data-only types:

- `PrecisionVerdict`
- `PrecisionConfidence`
- `PrecisionScanStage`
- `PrecisionSourceInfo`
- `PrecisionRegionMeasurement`
- `PrecisionMeasurementSet`
- `PrecisionAssessment`
- `PrecisionScanResult`

No GTK dependencies and no subprocess execution.

#### `src/ten-bit-precision-logic.vala`

Pure functions for:

- sample-position selection;
- spatial patch selection;
- median/percentile/dispersion calculations;
- per-plane effective-depth aggregation;
- low-bit residue and lattice statistics;
- histogram-comb measurements;
- evidence sufficiency checks;
- classification and confidence;
- generation of structured reason codes, not final UI prose.

Every threshold belongs here with a comment naming the calibration dataset and
date. Do not bury thresholds in the window or FFmpeg parser.

#### `src/ten-bit-precision-analyzer.vala`

Owns FFprobe/FFmpeg orchestration:

- probes source facts;
- validates supported pixel formats;
- constructs safe argv arrays;
- runs metadata and sampled-pixel passes;
- streams and parses bounded raw samples when necessary;
- emits stage/progress updates;
- honors `Cancellable`;
- converts process/parser failures into structured errors;
- returns `PrecisionMeasurementSet` to the pure classifier.

Use `AppSettings.get_default().ffmpeg_path` and `.ffprobe_path`. Never hardcode
binary names.

#### `src/ten-bit-precision-window.vala`

Presentation and lifecycle only:

- state stack and widgets;
- selected-source summary;
- scan generation counter;
- active `Cancellable`;
- progress rendering;
- verdict/evidence rendering;
- Cancel, Scan Again, Copy Report;
- close teardown;
- stale-result suppression.

The window must not parse FFmpeg output or calculate a verdict.

#### `tests/ten-bit-precision-logic-test.vala`

Headless tests of sample selection, statistics, sufficiency, thresholds, verdict
precedence, confidence, and reason codes.

#### `tests/ten-bit-precision-analyzer-test.vala`

Parser and argv-construction tests. Keep external FFmpeg execution optional so
the normal unit suite remains deterministic.

#### `tests/ten-bit-precision-window-state-test.vala`

Headless GTK state/lifecycle tests using injected results or an analyzer
interface/fake.

#### `DevTools/analyze-bit-precision-corpus.py`

Calibration and regression harness. It may call FFmpeg directly, produce CSV or
JSON, generate matched variants, and print confusion matrices. Production
classification must not depend on Python.

### Existing files to modify

#### `src/hamburger-menu.vala`

- Add the menu item.
- Hold/look up the application action for sensitivity updates.
- Enable it only for an existing regular input file.
- Keep all window behavior in `MainWindow`.

#### `src/main.vala`

- Register `ten-bit-precision-checker` once.
- Lazy-create and present `TenBitPrecisionWindow`.
- Pass the current input path on activation.
- Forward input changes while the window exists.
- Clear the window reference on close.
- Ensure application teardown cancels the scan.

#### `meson.build`

- Add new production sources.
- Add the pure-logic test target.
- Add analyzer and headless widget test targets when their files exist.
- Use the existing headless GTK environment for the window-state test.

#### Optional: `src/ffprobe-utils.vala`

Reuse existing helpers when their contracts match. Add narrowly scoped generic
helpers only if they are useful outside the checker. Checker-specific parsing
belongs in its analyzer rather than turning `FfprobeUtils` into a feature class.

### Dependency direction

```text
TenBitPrecisionWindow
          ↓
TenBitPrecisionAnalyzer  →  FFprobe / FFmpeg
          ↓
TenBitPrecisionLogic
          ↓
TenBitPrecisionTypes
```

GTK must not flow downward. FFmpeg output strings must not flow upward beyond
the analyzer.

---

## Source Probe

Start with one FFprobe JSON command against the selected video stream:

```text
ffprobe -v error -print_format json -select_streams v:0 \
  -show_entries \
  stream=codec_name,profile,pix_fmt,bits_per_raw_sample,width,height,\
r_frame_rate,avg_frame_rate,color_range,color_space,color_transfer,\
color_primaries,field_order:format=duration,size \
  INPUT
```

The actual implementation uses an argv array, not a shell command.

Parse into `PrecisionSourceInfo`:

- exact canonical input path or file identity;
- codec/profile;
- pixel format;
- declared bit depth;
- dimensions;
- duration and frame rate;
- chroma subsampling/plane layout when inferable;
- color range/space/transfer/primaries;
- interlacing;
- file size/mtime signature captured at scan start.

Bit-depth precedence should match existing project behavior:

1. valid `bits_per_raw_sample`;
2. infer from `pix_fmt`;
3. unknown, never silently assume 8-bit for the verdict.

Before accepting results, recheck the file signature. If size or mtime changed
during analysis, discard the result and report that the source changed.

### Fast exits

- No video stream → Failed with a clear explanation.
- Declared depth ≤ 8 → `NOT_APPLICABLE`; no pixel scan.
- Unknown declared depth → Inconclusive or Unsupported; do not force conversion.
- Still image/attached picture only → Not a supported video scan.
- Unsupported packed/RGB/high-depth format → Unsupported unless a verified
  code-preserving unpacking path exists.

---

## Sampling Strategy

The scan must cover the timeline without decoding the entire file and without
transforming away or inventing lower-bit evidence.

### Temporal sampling

Initial calibration candidate, not a forever constant:

- Up to 8 regions distributed across 5–95% of the usable duration.
- Avoid the first and last 5% when duration permits; intros, fades, and credits
  contain too many flat/black frames.
- Decode approximately 24 frames per region for the metadata pass.
- Retain approximately 4–8 activity-qualified frames per region for deeper
  residue analysis.
- For short clips, use fewer non-overlapping regions rather than repeatedly
  sampling the same frames.
- For unknown duration, use a bounded sequential fallback and lower confidence.

Put position selection in pure logic and cover boundary cases: zero/unknown
duration, very short clips, fractional frame rates, and duplicate positions.

Do not concatenate regions before any temporal statistic whose state crosses
frames. A join between unrelated regions is not source motion. Either reset the
analysis chain per region or use only per-frame signals in a concatenated pass.

### Spatial sampling

Deep per-pixel analysis does not need every 4K pixel, but ordinary scaling is
forbidden: interpolation creates lower-bit values and can turn an obvious
8-bit lattice into apparent ten-bit activity.

Preferred strategy:

- Analyze native-value crops from varied spatial positions.
- Choose even crop coordinates/sizes compatible with chroma subsampling.
- Use a bounded patch size, initially 512×512 subject to calibration.
- Rotate through center and quadrant patches across timeline regions.
- Qualify patches by luma activity so black bars, credits, and flat fields do
  not dominate the verdict.
- Preserve original sample values and native range. No scale, colorspace,
  transfer, tonemap, denoise, dither, or pixel-format depth conversion may run
  before measurement.

If a packed format must be unpacked into an equivalent planar format, Phase 0
must prove bit-exact decoded code values with checksums and synthetic ramps
before that path is considered supported.

### Coverage requirements

Classification requires all of:

- a calibrated minimum number of active pixels;
- a calibrated minimum number of active frames;
- multiple separated timeline regions when duration allows;
- enough non-flat code-value diversity;
- no parser truncation or unexpected format negotiation.

Insufficient coverage produces `INCONCLUSIVE`, never a lower-confidence
accusatory verdict.

---

## Measurement Pipeline

Use a staged analyzer so obvious cases are cheap and difficult cases receive
more evidence.

### Stage A — Native decoded-depth metadata

Run FFmpeg at native depth with `signalstats` and metadata printing. Collect per
frame:

- `YBITDEPTH`
- `UBITDEPTH`
- `VBITDEPTH`
- optionally luma range/activity statistics used only to reject flat frames

Aggregate medians, percentiles, frame proportions at each effective depth, and
cross-region consistency. Preserve plane separation; chroma may legitimately
exercise fewer levels than luma.

This stage can identify simple padding:

- declared depth = 10;
- active luma frames consistently report ≤8 used bits;
- chroma is compatible with the same conclusion;
- lower-bit passes do not contradict it.

Do not classify a file from one flat frame.

### Stage B — Lower-bit-plane activity

Use `bitplanenoise` for bit planes 1 and 2 on 10-bit material, retaining its
per-plane metadata. Measure:

- whether each lower plane is ever active;
- per-frame and per-region activity/noise;
- consistency between luma and chroma;
- whether activity appears only in isolated regions.

Zero activity strongly reinforces simple padding. Nonzero activity only proves
that lower bits exist. It does not prove their origin.

For future 12-bit support, generalize the analyzed lower planes relative to the
most significant eight bits; do not duplicate a hardcoded 12-bit classifier.

### Stage C — Exact luma residue analysis

For cases not already resolved, stream bounded native-value luma crops from
FFmpeg and calculate exact statistics in the analyzer/logic layer. Use a binary
stdout pipe and bounded frame buffers; never call `communicate_utf8_async` on
raw video.

For 10-bit sample value `x`, collect at minimum:

- counts for `x mod 4 = 0,1,2,3`;
- dominant residue-class fraction;
- nonzero lower-two-bit fraction;
- round-trip distance to the nearest 8-bit lattice value;
- the 1024-bin luma histogram and occupied-bin count;
- period-4 histogram comb/autocorrelation strength;
- statistics restricted to active, non-clipped pixels;
- per-region versions of all metrics, not just a global average.

Inspect all four lattice phases rather than assuming simple padding always lands
on residue zero. Range remapping and constant offsets can shift the phase.

#### Why residue distribution helps

A direct bit shift normally occupies one residue class. Native ten-bit material
usually occupies all four, subject to content and grading. A lossy 10-bit encode
of 8-bit input often occupies all four as well, but its distribution and spatial
structure can retain quantization or codec fingerprints. This signal is decisive
for simple padding and supporting evidence only for lossy history.

### Stage D — Structural heuristics for lossy 8→10 re-encodes

These features are candidates until Phase 0 validates them:

- lower-bit energy relative to upper-bit local gradients;
- spatial correlation of lower-bit residuals;
- concentration at codec block boundaries;
- temporal stability of lower-bit patterns across nearby frames;
- histogram periodicity after excluding flat/clipped pixels;
- agreement or disagreement between luma and chroma;
- stability of all measurements across scenes;
- low-bit activity that resembles uncorrelated dither versus image-correlated
  detail.

Do not ship a candidate simply because it sounds plausible. Each feature must
show separation on held-out matched pairs and must add value beyond effective
bit depth plus lattice occupancy.

Native film grain can resemble noise. Synthetic dithering can intentionally
resemble legitimate lower-bit activity. Codec reconstruction can resemble both.
Those overlaps are why this stage produces probability-weighted evidence, not a
proof rule.

### Stage E — Structured assessment

The classifier receives only `PrecisionMeasurementSet` plus calibration
constants and returns:

- verdict enum;
- confidence enum;
- measured precision summary;
- ordered reason codes;
- ordered caveat codes;
- coverage summary;
- raw metrics needed by tests/report details.

The window maps reason/caveat codes to user-facing prose. This prevents a future
threshold change from silently changing factual language inside process code.

---

## Classification Policy

Threshold values below are intentionally unspecified until the corpus phase.
The policy and precedence are fixed first; numeric boundaries come from data.

### Precedence

1. Invalid/cancelled/changed source → no assessment.
2. Unsupported evidence path → `UNSUPPORTED`.
3. Declared depth ≤8 → `NOT_APPLICABLE`.
4. Insufficient active coverage → `INCONCLUSIVE`.
5. Strong unused-depth/lattice-lock evidence → `EFFECTIVELY_8_BIT`.
6. Full lower-bit use with native-consistency score beyond its calibrated
   high-confidence boundary → `CONSISTENT_WITH_NATIVE`.
7. Full lower-bit use without enough provenance separation →
   `FULL_PRECISION_PRESENT`.
8. Conflicting evidence → `INCONCLUSIVE`.

### Conservative asymmetric errors

The cost of falsely accusing legitimate ten-bit material is higher than the cost
of returning Inconclusive. Tune accordingly:

- High-confidence `EFFECTIVELY_8_BIT` should target extremely high precision on
  held-out data.
- Ambiguous lossy re-encodes should fall into `FULL_PRECISION_PRESENT` or
  `INCONCLUSIVE` until the corpus justifies stronger language.
- `CONSISTENT_WITH_NATIVE` must not be introduced merely as the inverse of the
  padded detector. It needs positive calibrated evidence.

### Supporting metadata

HDR10/PQ/HLG, BT.2020, Main10 profile, encoder tags, and high bitrate may appear
in the source summary. They must not materially raise confidence unless the
calibration study demonstrates independent predictive value. Metadata can be
copied or forged and often describes delivery requirements rather than ancestry.

---

## Corpus and Calibration Phase

This phase blocks any production `CONSISTENT_WITH_NATIVE` verdict and any
non-obvious `EFFECTIVELY_8_BIT` threshold.

### Ground-truth groups

Collect sources with known lineage, not filenames guessed from the internet:

1. Known native 10-bit camera or lossless/generated ramps and gradients.
2. Known native 10-bit film/video with grain.
3. Known native 10-bit clean digital footage.
4. Known 10-bit animation and flat graphics.
5. Known 8-bit live action, animation, screencasts, and noisy footage.

Existing corpus files are useful for signal exploration but are not automatically
ground truth merely because their `pix_fmt` is 10-bit.

### Matched derivations

For every suitable source, generate controlled variants:

- 10-bit native/reference;
- 10→8 direct quantization;
- 10→8 with ordered and random dithering;
- 8→10 lossless padding;
- 8→10 x265 Main10 over several CRFs/presets;
- 8→10 SVT-AV1 over several CRFs/presets;
- 8→10 VP9 profile 2 where supported;
- 8→10 x264 High10 where supported;
- range-remapped full↔limited variants;
- resized variants using several kernels;
- denoised, sharpened, and grain-added variants;
- HDR-tagged 8-bit-derived variants;
- multiple chroma subsamplings where supported.

The important matched pair is:

```text
same content → true 10-bit path
same content → quantize to 8-bit → encode as 10-bit
```

That holds content constant and tests ancestry rather than genre.

### Data split

Split by source work, not by derived clip. No frames or transformations from the
same original may land in both training/calibration and validation sets. A clip
split would leak content and produce deceptively good thresholds.

Maintain a final untouched holdout set covering:

- live action;
- animation;
- screencast/text;
- clean gradients;
- heavy grain/noise;
- dark footage;
- clipped highlights;
- HDR and SDR;
- 1080p and 4K;
- multiple codecs and quality levels.

### Corpus output

`DevTools/analyze-bit-precision-corpus.py` should emit one row per file and a
manifest linking every derivative to its lineage:

- source ID and transformation lineage;
- expected class;
- codec/pixel format/depth/color metadata;
- sampling coverage;
- every raw measurement;
- classifier verdict/confidence/reasons;
- runtime and bytes decoded;
- tool versions and command configuration.

Generate:

- confusion matrix by verdict;
- precision/recall for `EFFECTIVELY_8_BIT`;
- false positives listed by filename/lineage;
- coverage/inconclusive rates;
- metrics by codec, CRF, content type, and resolution;
- ablation table showing whether each structural heuristic adds value.

Every shipped threshold must cite this output in code comments and in a findings
document added after calibration.

---

## Async Process and Lifecycle Requirements

The checker is read-only but still launches potentially expensive child
processes. Treat cancellation and stale results as correctness requirements.

### Per-scan state

The window owns:

- monotonically increasing `uint64 scan_generation`;
- one active `Cancellable?`;
- exact source path and start signature;
- current stage/progress;
- weak/owned analyzer reference according to implementation shape.

Starting a scan:

1. cancel the previous cancellable;
2. increment generation;
3. create a new cancellable;
4. snapshot path/signature;
5. reset UI to Probing;
6. begin analyzer async call;
7. apply progress/result only when generation, path, signature, and cancellable
   still match.

### Subprocess rules

- Construct argv arrays; never use a shell.
- Capture text output asynchronously for metadata stages.
- Stream binary rawvideo in bounded chunks for residue analysis.
- Drain stderr concurrently with binary stdout to prevent pipe deadlock.
- Cap retained stderr and include only a concise sanitized summary in the UI.
- On cancellation or timeout, terminate the child and await/reap it.
- Treat cancelled scans separately from failed scans.
- Reject a successful exit that produced zero usable frames.
- Put a timeout around every process stage, sized from the bounded sampling job.
- Never leave a worker thread or child process alive after window teardown.

### Concurrency with conversion

The checker does not produce output and should not initially reserve the global
`ActiveOperation` slot. Keep it independent, cancellable, and thread-limited.
Benchmark concurrent conversion before final release. If contention materially
harms conversion or responsiveness, disable starting a checker scan while a
conversion is active or explicitly pause/cancel the checker; do not silently
allow unbounded FFmpeg threading.

### Memory and disk

- Stream analysis; do not retain full videos or all sampled frames.
- Bound each decoded frame buffer to the chosen crop dimensions.
- Aggregate histograms/statistics and release the frame immediately.
- Do not create decoded intermediates.
- If a temporary file is unavoidable for a codec/container edge case, create it
  in a per-run private temporary directory, clean it on every exit path, and do
  not rely on `/tmp` capacity for full-resolution video intermediates.
- Target a small, measured memory ceiling and add a benchmark for 4K input.

---

## Detailed Report Contract

The result model must preserve enough information for UI rendering, tests, and a
Copy Report action without exposing raw FFmpeg logs as the main explanation.

### Always show

- basename and optional full-path tooltip;
- codec/profile;
- pixel format and declared depth;
- resolution;
- HDR/transfer summary when known;
- verdict heading;
- confidence;
- one-paragraph plain-language explanation;
- regions and frames sampled;
- measured precision;
- lower-bit activity summary;
- lattice-match summary;
- limitations expander.

### Evidence wording examples

For `EFFECTIVELY_8_BIT`:

> Although the stream is encoded as 10-bit, sampled decoded values
> overwhelmingly follow an 8-bit value lattice and the lower two bit planes are
> largely unused. This is strong evidence of effectively 8-bit picture data.

For `FULL_PRECISION_PRESENT`:

> The decoded video uses values from all ten bits. Those lower-bit values may
> come from native precision, processing, dithering, or lossy codec
> reconstruction, so the original source depth cannot be determined reliably.

For `CONSISTENT_WITH_NATIVE`:

> Lower-bit values are active across multiple scenes and their measured
> structure is consistent with the calibrated native 10-bit reference set. This
> is an assessment, not proof of the original master or camera format.

For `INCONCLUSIVE`:

> The sampled frames did not contain enough diverse picture information, or the
> measurements disagreed. No reliable source-depth assessment can be made.

### Copy Report

Copy a compact, text-only report containing:

- app/tool version;
- source basename, not full path by default;
- source metadata;
- verdict/confidence;
- coverage;
- human-readable evidence;
- raw aggregate metric values under a Technical Details heading;
- explicit provenance caveat.

Do not copy full filesystem paths unless the UI clearly tells the user it will.

---

## Testing Strategy

### Pure logic tests

Cover at minimum:

- bit-depth inference inputs and unknown handling;
- sample positions for long, short, zero-duration, and unknown-duration media;
- even/aligned patch geometry for 4:2:0, 4:2:2, and 4:4:4;
- modulo residue counts and all four possible dominant phases;
- histogram comb calculation;
- medians/percentiles on empty, single, and mixed inputs;
- coverage gates;
- verdict precedence;
- conservative behavior when signals conflict;
- confidence margin boundaries;
- no `CONSISTENT_WITH_NATIVE` verdict when its calibration gate is disabled;
- stable reason/caveat ordering;
- 12-bit-relative lower-plane math even if 12-bit UI support ships later.

Prefer synthetic `PrecisionMeasurementSet` fixtures so each test states exactly
which fact causes the verdict.

### Parser and command tests

Cover:

- normal FFprobe JSON;
- missing `bits_per_raw_sample` with known `pix_fmt`;
- unknown pixel format;
- no video stream;
- attached picture plus real video stream;
- malformed/truncated JSON;
- `signalstats` metadata for all planes;
- missing chroma metadata;
- bitplanenoise key parsing;
- CRLF/noisy FFmpeg logs;
- zero-frame successful process;
- argv paths containing spaces, quotes, Unicode, and leading dashes;
- commands contain no scaling or color conversion before measurement;
- binary frame-size validation and truncated raw frames.

### Window/lifecycle tests

Inject an analyzer interface or fake so headless GTK tests can deterministically
exercise:

- action disabled with no input and enabled with a regular file;
- first activation constructs and presents one window;
- second activation reuses it;
- opening starts automatically;
- 8-bit fast exit;
- progress stage updates;
- Cancel state and Scan Again;
- input change cancels/restarts;
- stale result from generation N cannot overwrite generation N+1;
- close cancels active work and clears `MainWindow` ownership;
- unsupported, failed, inconclusive, and completed rendering;
- Copy Report content and path privacy;
- controls have text labels and do not rely on color.

### Live integration tests

Keep small synthetic fixtures or generate them in a temporary directory:

1. 8-bit source declared 8-bit → Not Applicable.
2. Lossless/direct 8→10 padding → Effectively 8-bit.
3. Native/generated 10-bit ramp → Full precision present or native-consistent
   after calibration.
4. 8→10 lossy x265 encode → must not be declared proven native merely because
   `YBITDEPTH=10`.
5. Completely black 10-bit clip → Inconclusive, not Effectively 8-bit based on
   flat frames alone.
6. Short clip → bounded valid sampling.
7. Corrupt/truncated input → Failed without hanging.
8. Cancellation during probe and during raw streaming → child reaped.

Do not make ordinary unit tests depend on the user’s corpus or mount layout.

### Regression commands

The implementation phase should finish with at least:

```text
meson setup builddir --reconfigure
meson compile -C builddir
meson test -C builddir --print-errorlogs
```

Also run the corpus analyzer and record its command, tool versions, dataset
manifest hash, and report artifact in the calibration findings document.

---

## Performance Targets

Set final budgets from measurement, but design toward:

- 8-bit/not-applicable result after one quick FFprobe call.
- Progressive feedback within 250 ms of opening.
- Bounded, distributed analysis rather than full decode.
- No UI-main-thread blocking.
- No unbounded stdout/stderr accumulation.
- No more than one active checker scan per window/application.
- Responsiveness preserved while scanning 4K on the target machine.

Benchmark at minimum:

- 1080p H.264 8-bit;
- 1080p HEVC Main10;
- 4K HEVC Main10 HDR;
- 4K AV1 10-bit;
- slow-seeking long-GOP media;
- a file on slower storage;
- checker running alone and concurrently with conversion.

Record wall time, time to first visible progress, CPU utilization, peak RSS,
bytes read, cancellation latency, and remaining child processes after cancel.

Optimization order:

1. Fast metadata exit.
2. Early termination only after multiple active regions agree strongly.
3. Fewer decoded frames without reducing timeline coverage.
4. Smaller native crops without scaling.
5. Controlled FFmpeg thread count.
6. Cache only if repeat scans prove common and cache invalidation uses exact file
   signature plus analyzer-version/calibration-version keys.

Do not add a cache in the first implementation unless measurement justifies its
complexity.

---

## Implementation Phases

### Phase 0 — Establish the Evidence

1. Add `DevTools/analyze-bit-precision-corpus.py`.
2. Reproduce and record the direct-padding versus lossy-reconstruction
   `YBITDEPTH` experiment.
3. Generate the matched-pair matrix.
4. Verify which pixel-format unpacking paths are bit-exact.
5. Measure candidate Stage D signals and discard non-separating ones.
6. Define coverage gates and conservative classifier thresholds.
7. Write `docs/10-bit-precision-checker-phase0-findings.md` with results,
   failures, and final thresholds.

**Exit criteria:** every proposed shipped metric has a definition, measured
distribution, held-out result, and known failure cases. Existing corpus files
without known lineage are not mislabeled as truth.

### Phase 1 — Pure Types and Classifier

1. Add data types and enums.
2. Add sample/patch selection logic.
3. Add aggregate/residue/histogram calculations.
4. Add sufficiency and verdict precedence.
5. Add reason/caveat codes.
6. Add comprehensive pure unit tests.
7. Keep the calibrated native verdict behind an explicit constant/versioned
   policy gate until Phase 0 supports it.

**Exit criteria:** synthetic measurement sets produce stable, fully tested
verdicts without GTK, FFmpeg, filesystem, or environment dependencies.

### Phase 2 — Analyzer Vertical Slice

1. Implement FFprobe source facts and fast exits.
2. Implement Stage A `signalstats` parsing.
3. Implement Stage B bit-plane parsing.
4. Implement distributed positions and per-region process construction.
5. Implement cancellation, timeouts, zero-frame checks, and file-signature
   validation.
6. Return structured results through the pure classifier.
7. Add parser/argv tests and small optional live fixtures.

At the end of this phase, simple padded 10-bit files can be detected, while
lossy ambiguous files honestly report full precision/inconclusive.

**Exit criteria:** no shell invocation, no source writes, no orphaned children,
and the direct-padding/lossy-reconstruction regression behaves correctly.

### Phase 3 — Dedicated Window and Hamburger Integration

1. Add the application action in `MainWindow`.
2. Add the hamburger item and sensitivity tracking.
3. Add lazy single-window ownership.
4. Build all required window states.
5. Auto-start on open.
6. Forward main input changes and restart safely.
7. Add Cancel, Scan Again, and Copy Report.
8. Add headless window-state/lifecycle tests.

**Exit criteria:** the complete user journey works with the conservative Stage
A/B classifier and remains safe under rapid input changes, repeated menu
activation, cancellation, and window close.

### Phase 4 — Deep Residue and Calibrated Lossy Heuristics

1. Add the bounded binary luma sample stream.
2. Add exact residue/lattice/histogram metrics.
3. Add only the Stage D signals that survived corpus ablation.
4. Re-run held-out validation.
5. Enable `CONSISTENT_WITH_NATIVE` only if validation meets the predeclared
   false-positive target.
6. Version the classifier/calibration constants for report reproducibility.

**Exit criteria:** deeper analysis materially reduces ambiguity without turning
known lossy 8→10 variants into confident native claims.

### Phase 5 — Hardening, Performance, and Release Polish

1. Benchmark the full matrix.
2. Tune sample counts/crops from accuracy-versus-runtime curves.
3. Test packed formats and explicitly expand or retain unsupported cases.
4. Verify accessibility and narrow-window behavior.
5. Verify paths with Unicode/spaces and files changing mid-scan.
6. Stress cancel/reopen/input-switch loops and inspect for remaining children.
7. Update README/user help with the provenance caveat.
8. Capture representative screenshots only after wording is final.

**Exit criteria:** all tests pass, budgets are documented, cancellation is
prompt, memory is bounded, supported formats are explicit, and no report makes a
claim stronger than its evidence.

---

## Acceptance Criteria

The feature is complete only when all of the following are true:

### Entry and lifecycle

- The hamburger menu contains **10-bit Precision Checker…**.
- It is disabled without an existing selected input file.
- It opens one reusable non-modal window.
- Opening begins scanning automatically.
- Changing main input cancels and starts the new file.
- Cancel, close, and application shutdown leave no FFmpeg/FFprobe children.
- Stale results can never overwrite the active source.

### Analysis correctness

- Declared 8-bit input exits without deep decoding.
- Simple padded 8→10 material is detected on held-out fixtures.
- A lossy 8→10 encode is not called native solely because all ten decoded bits
  are populated.
- Flat/black/insufficient content returns Inconclusive rather than a confident
  ancestry verdict.
- No scale/color/transfer transform contaminates measured samples.
- Unsupported formats are named and handled explicitly.
- Thresholds and confidence levels trace to calibration evidence.

### Report quality

- Container precision and measured precision are separate.
- Assessment and confidence are separate.
- The explanation states what was measured.
- The limitations text states that original source depth cannot always be
  recovered from the final encode.
- No “fake” or “proven genuine” language appears.
- Copy Report is useful without leaking the full path by default.

### Engineering quality

- Process, classifier, and UI layers remain separate.
- Pure logic has deterministic unit coverage.
- Process parsers and argv construction have regression coverage.
- Window generation/cancellation behavior has headless coverage.
- Main-thread responsiveness, peak memory, and cancellation latency are
  measured on 1080p and 4K files.
- The entire existing test suite remains green.

---

## Known Risks and Mitigations

| Risk | Consequence | Mitigation |
|---|---|---|
| Lossy 10-bit reconstruction populates low bits from 8-bit input | False “native” result | Never use populated depth alone; calibrate matched lossy pairs; prefer ambiguous verdicts. |
| Dithering deliberately fills lower bits | 8-bit-derived material resembles native precision | Detect only when supported by data; otherwise Full Precision Present/Inconclusive. |
| Native grain resembles lower-bit noise | Legitimate footage looks synthetic | Keep content-matched native grain in corpus; do not equate noise with fakery. |
| Animation/flat frames use few levels | False effectively-8-bit result | Activity/diversity gates and distributed sampling; Inconclusive on insufficient evidence. |
| Scaling/color conversion invents code values | Analyzer contaminates its own evidence | Native-value crops only; verify any unpacking bit-exactly. |
| Black bars dominate samples | Artificial lattice lock | Spatial diversity and active-pixel qualification. |
| Long GOP seeks are slow | Poor UX | Bounded regions, visible progress, timeouts, prompt cancel. |
| Binary pipe blocks on stderr | Hang | Drain both streams concurrently and cap stderr. |
| Main input changes during scan | Wrong-file result shown | Cancellable + generation + path/signature guard. |
| File changes in place | Measurements mix versions | Recheck size/mtime signature before publishing. |
| Checker competes with an encode | Conversion slowdown | Bound threads; benchmark concurrency; gate/pause if necessary. |
| Thresholds overfit current corpus | Confident mistakes in new content | Source-level holdout, codec/content matrix, asymmetric false-positive target, versioned calibration. |

---

## Deferred Decisions Requiring Phase 0 Data

These must not be guessed during UI implementation:

1. Exact region/frame/patch counts.
2. Minimum active-pixel and code-diversity coverage.
3. Effective-depth agreement required across Y/U/V.
4. Lattice-lock and histogram-comb thresholds.
5. Whether bitplanenoise adds independent predictive value.
6. Which structural heuristics survive held-out validation.
7. Whether `CONSISTENT_WITH_NATIVE` can meet an acceptable false-positive rate.
8. Which packed/RGB/12-bit formats have verified code-preserving analysis paths.
9. Final thread and timeout budgets.
10. Whether repeat scans justify a signature-keyed cache.

The product shape, honesty contract, architecture, lifecycle, and verdict
precedence do not depend on those numbers and can proceed while calibration is
underway.

---

## Final Principle

The most valuable result this checker can produce is not always “native” or
“8-bit-derived.” It is a trustworthy boundary between what the decoded video
proves and what its patterns merely suggest.

Catch simple padded conversions decisively. Analyze difficult lossy conversions
carefully. Say “inconclusive” whenever the evidence cannot support more. That is
what will make the 10-bit Precision Checker credible rather than decorative.
