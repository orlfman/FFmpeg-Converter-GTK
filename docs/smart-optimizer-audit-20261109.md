# Smart Optimizer audit — 2026-11-09

Audit record: `AUD-20261109-smart-optimizer` in [AUDIT.md](AUDIT.md).
Agent: Claude Code. Base: main at fe740b3 plus the uncommitted folder-conversion
work. Read-only review; no source file was changed.

## Scope and method

- Read in full: `src/optimizer/smart-optimizer.vala`,
  `smart-optimizer-logic.vala`, `smart-optimizer-cache.vala`,
  `src/encoders/smart-codec-resolver.vala`.
- Read in part: the optimizer call sites in `app-controller.vala` and
  `bulk-conversion.vala`, the two-pass arguments in the x264/x265/VP9/SVT-AV1
  builders, the size report in `conversion-runner.vala`, and the optimizer
  plan and VMAF findings documents.
- Four small FFmpeg experiments (below) on `tests/testvideo-raptor.webm`
  (1280x720, 24 fps, read-only), FFmpeg n9.0.2, SVT-AV1 4.2.0, 24 threads.
  Outputs went to a scratch directory and were deleted.
- **Not run:** no build, no test suite, no application run, no 4K or HDR
  source, no multi-file corpus. Findings marked "by reading" were not
  reproduced in the app.

## Findings

Severity reflects user impact, not effort. Line numbers are for fe740b3 plus
the working tree on 2026-11-09.

### SO-F1 — Quality Mode walks to the codec's minimum CRF when the ceiling cannot be reached (High, fixed 2026-11-09; knee stop awaiting real-media verification)

- **Where:** `smart-optimizer-logic.vala` `solve_quality_crf` (second `while`,
  about line 4032); gating in `app-controller.vala:1301` and
  `bulk-conversion.vala:786`.
- **What:** when the fitted curve never reaches the target, every model value
  is at or below the ceiling, so the loop lowers CRF all the way to
  `crf_min` (8 for x264/x265, 10 for SVT-AV1, 12 for VP9). Verification then
  measures a score below the ceiling and accepts it. Auto-convert and folder
  conversion are only withheld for `is_impossible`, which Quality Mode never
  sets for this case.
- **Evidence:** by reading, and the project's own records: the 644 MB and
  1031 MB outputs in `quality-mode-vmaf-measurement-findings.md`, and the note
  above `VMAF_MODEL_4K_PATH` that Ultra on 1080p animation "solves CRF 14 and
  produces an output LARGER than the source, for no visible gain over CRF 18".
  No plateau, flat-curve or sanity check exists anywhere in `src/optimizer`.
- **Why it matters more now:** folder conversion runs this unattended per file.
- **Suggested fix:** (a) stop lowering CRF once the measured or fitted gain
  falls below a threshold (for example under 0.1 VMAF per CRF step) and report
  the knee instead of the floor; (b) treat "lowest probed CRF scores far below
  transparent" or "VMAF range under 1 point across 10+ CRF" as a failed
  measurement; (c) give the recommendation a needs-attention flag that blocks
  auto-convert and folder conversion, as `bit_depth_attention_required` does.

### SO-F2 — libvmaf runs single-threaded in Quality Mode (High for run time, fixed and verified 2026-11-09)

- **Where:** `smart-optimizer.vala:1117` (`threads = encoder_threads_per_job (1)`,
  which returns 0 for "auto") and `:4286` (`n_threads = int.max (1, threads)`).
- **What:** 0 means "let the encoder choose" for the encode, but the same value
  is passed to `measure_vmaf`, where it becomes `n_threads=1`.
- **Evidence (measured):** identical scores, 7x the time.

  | Pair | n_threads=1 | 8 | 24 |
  | --- | --- | --- | --- |
  | 720p, 384 frames | 5.3 s | 0.8 s | 0.7 s |
  | 4K (upscaled), 192 frames | 22.9 s | 4.1 s | 3.2 s |

- **Suggested fix:** pass the processor count (capped at about 16) to libvmaf
  independently of the encoder thread setting.

### SO-F3 — VMAF model is chosen from the source width, and by a hard-coded path (Medium, fixed and verified 2026-11-09)

- **Where:** `smart-optimizer.vala:1168`, `:1426`, `:4376` pass `info.width`;
  `:4232` hard-codes `/usr/share/model/vmaf_4k_v0.6.1.json`.
- **What:** a 4K source downscaled to 1188p is scored with the 4K model, and a
  1080p source upscaled to 4K with the HD model. On systems without that path
  the 4K model is silently never used, so the same file solves to a different
  CRF on another distribution. The model is also not part of the cache key.
- **Evidence (measured):** the same 720p pair scores 97.63 with the default
  model and 98.35 with the 4K model. `model=version=vmaf_4k_v0.6.1` gives the
  same 98.35 with no path. The code comment already records +1.3 CRF (live
  action) and +7.8 CRF (animation) between models.
- **Suggested fix:** take the width from the filtered reference, select with
  `model=version=…`, and add the model name to the cache identity.

### SO-F4 — Two-pass x264/x265 is capped to near-constant bitrate (Medium, open)

- **Where:** `smart-codec-resolver.vala:179` and `:258` set `abr_vbv`;
  `x264-builder.vala:247` and `x265-builder.vala:212` emit
  `vbv-maxrate = vbv-bufsize = average bitrate`.
- **What:** a one-second buffer at the average rate stops two-pass from moving
  bits between easy and hard scenes. It does buy size accuracy.
- **Evidence (measured, one 60 s 720p clip, preset medium):**

  | Encode | Actual | VMAF mean | 1%-low | Min |
  | --- | --- | --- | --- | --- |
  | x264 300k, no VBV | 317k | 70.0 | 53.0 | 49.5 |
  | x264 300k, VBV = average (app) | 296k | 68.1 | 38.1 | 32.3 |
  | x264 300k, VBV 2x rate / 4x buffer | 314k | 71.9 | 56.0 | 50.8 |
  | x264 600k, no VBV | 617k | 86.7 | 77.7 | 76.1 |
  | x264 600k, VBV = average (app) | 597k | 85.2 | 67.7 | 64.5 |
  | x265 300k, no VBV | 301k | 86.4 | 76.3 | 73.0 |
  | x265 300k, VBV = average (app) | 296k | 85.3 | 67.9 | 59.1 |

- **Limits:** one clip. The size benefit (about 1% under target against 3–6%
  over for x264 without VBV) is real and matters for strict targets.
- **Suggested fix:** a looser cap (about 2x rate, 4x buffer) plus a
  closed-loop correction: the runner already measures the final size
  (`report_smart_size_result`), so an output over a strict target could rerun
  the second pass at `bitrate × target / actual`. That makes Tiny/Small
  targets strict in fact, which no amount of calibration can.

### SO-F5 — Size tier is keyed on absolute megabytes (Medium, design, open)

- **Where:** `SizeTier.from_mb` (`smart-optimizer-logic.vala:50`),
  `tier_audio_kbps` (`:832`), `tier_safe_preset_index`, `pick_calibration_crfs`.
- **What:** the tier decides audio bitrate, preset, the CRF ladder, encoder
  effort, bit depth and strictness. A megabyte count says nothing about
  bitrate. A two-hour film at 500 MB is "XLarge, quality-first": 320 kbps
  audio is 275 MiB, 55% of the file; the ladder probes CRF 8–24 when the
  answer is near 40; the preset is the fastest in the table.
- **Aggravating:** `cap_audio_kbps_to_source` and stream copy both require a
  probed audio bitrate, and Matroska/WebM streams report `bit_rate=N/A`
  (confirmed on the repository fixture). Nothing reads the `BPS` stream tag.
  For those sources the full tier bitrate is always used.
- **Suggested fix:** keep the megabyte tier only for upload-limit policy
  (strict targeting, forced container, metadata stripping). Derive effort,
  preset, ladder centre and audio share from the video budget's bits per pixel
  (`bpp_low_threshold` already exists) or from the ratio to the source
  bitrate. Cap audio at a share of the total budget. Read `BPS` tags, or
  measure audio packet sizes in a demux pass, when `bit_rate` is absent.

### SO-F6 — Strict tiers discard the CRF calibration (Medium, run time, open)

- **Where:** `decide_two_pass` (`smart-optimizer-logic.vala:3621`) sets
  two-pass unconditionally for Tiny/Small; the resolver then uses a fixed CRF
  and the target bitrate.
- **What:** for targets of 50 MB and under, the four to six probe encodes and
  the verification encode change only the notes, the displayed CRF estimate
  and `is_impossible`. They are most of the analysis time. The same holds for
  any Medium+ run that falls back to two-pass, which low sample coverage
  forces on long videos.
- **Suggested fix:** skip or shorten calibration when two-pass is already
  certain, or spend that one encode on a VMAF readout of the chosen bitrate
  (the plan's "what the target cost perceptually", still unimplemented:
  Size Mode returns `vmaf_measured = false`).

### SO-F7 — Quality Mode samples very little of a 4K source (Medium, open)

- **Where:** `max_segments_for_intermediate_budget`,
  `estimate_intermediate_bytes`, `INTERMEDIATE_MAX_BYTES`
  (`smart-optimizer-logic.vala:2766`).
- **What:** the 4 GiB reference budget is computed from source dimensions and
  a fixed 0.35 ratio. Resulting sample counts, whatever the video's length:

  | Source | Segments | Sampled |
  | --- | --- | --- |
  | 4K 8-bit 30 fps | 4 | 32 s |
  | 4K 8-bit 60 fps, 4K 10-bit 24/30 fps | 2 | 16 s |
  | 4K 10-bit 60 fps | 1 | 8 s |

  A chain that downscales to 1080p still gets the 4K count. The reference is
  written under `Environment.get_tmp_dir ()`, which is RAM-backed tmpfs on
  this machine and many distributions, and the parallel-job memory cap is
  measured before the reference exists.
- **Suggested fix:** size the budget from the filtered output dimensions and
  the free space of the temporary filesystem; prefer more, shorter segments
  (scene diversity is worth more than segment length); count a tmpfs
  reference against the memory budget.

### SO-F8 — Quality Mode inherits Size Mode's preset mapping (Low, design, open)

- **What:** intents map to nominal tiers, and larger tiers choose faster
  presets. Worked through the tables for live action: Ultra gives x265
  `faster`/`fast` and SVT-AV1 preset 7; Low gives x265 `medium`/`slow` and
  SVT-AV1 preset 4. With VMAF pinned, the preset no longer buys quality, it
  buys file size, so the archival intent gets the least efficient encode.
  Preset and tuning varying with intent is also why no probe can be reused
  across intents (open question 2 in the solver plan).
- **Suggested fix:** make speed its own choice in Quality Mode (a preference,
  or the slowest preset that fits a time budget using the existing speed
  probe).

### SO-F9 — Quality verification corrects one way, one CRF at a time (Low, open)

- **Where:** `smart-optimizer.vala:1527–1607`.
- **What:** an overshoot raises CRF by one and repeats a full encode plus VMAF
  each time. An undershoot of any size is accepted, so the result is "at or
  below the ceiling" but not necessarily the closest one.
- **Suggested fix:** add each verified point to the model and re-solve, or
  bisect between the nearest measured points above and below the ceiling.

### SO-F10 — Probes use hand-built encoder arguments (Low, open)

- **Where:** `append_video_codec_args` (`smart-optimizer.vala:4674`) against
  `SmartCodecResolver`.
- **What:** the probe carries preset, tune, psy-rd, grain, sharpness,
  lookahead and keyframe interval. The applied encode adds x264 motion
  search, sub-pixel refinement, B-frame count, trellis and deblock offsets;
  VP9 `aq-mode`, `tune-content screen` and ARNR; SVT-AV1 quantisation
  matrices. The ±2% figure in the code comment covers x265 and SVT-AV1 only.
- **Suggested fix:** build probe arguments through `SmartCodecResolver` and
  the real builders with the candidate CRF, so parity is structural.

### SO-F11 — VMAF frame-alignment hardening is still absent (Medium, partly fixed 2026-11-09, pre-existing)

- **Follow-up 2026-11-09:** a flat curve was reproduced on a 720p-to-4K run
  and removed by rebasing both libvmaf inputs; see
  AUD-20261109-vmaf-threads-model in [AUDIT.md](AUDIT.md). The checks below
  other than `setpts` are still missing.

- `measure_vmaf` still has no `setpts=PTS-STARTPTS`, no frame-count check and
  no sanity bound; these are candidates 2–4 of
  `quality-mode-vmaf-measurement-findings.md`. The historical failing range
  was not re-run here.
- **New ruled-out datum for that document:** `film-grain-denoise=1` (which the
  probes use and the earlier hand tests did not list). At strength 15 it cost
  0.5–1.3 VMAF on clean and on noise-added 720p material and did not flatten
  the curve (clean: 99.11 at CRF 18, 93.94 at CRF 38).

### SO-F12 — Frame rate comes from `r_frame_rate` (Low, by reading, not reproduced)

- `probe_video` (`smart-optimizer.vala:3305`) never reads `avg_frame_rate`.
  Where a variable-frame-rate file reports its timebase there, the keyframe
  interval, container overhead, bits-per-pixel advice and the reference
  budget in SO-F7 would all be wrong. A synthetic attempt to reproduce this
  reported 30/1 for both fields, so this stays unconfirmed.

## Smaller observations

- Content analysis decodes and filters the samples three times (signalstats,
  edgedetect, banding) and is not cached; the plan already names it as the
  floor of a cached run. One process with `split`, plus caching the profile,
  would remove most of it.
- The Quality Mode ladder probes run one after another; Size Mode's parallel
  batch is not reused.
- The FFV1 reference is written without slices or threading, and every probe
  and every VMAF pass decodes it.
- Quality Mode never builds the source bitrate profile, so its size readout
  has no complexity weighting and its samples are evenly spaced regardless of
  content. The profile could choose representative segments in both modes
  instead of correcting afterwards.
- The cache key has no FFmpeg path or version; the store is per-boot under
  `/tmp`, so the exposure is small.
- Per-stream audio bitrate ignores channel count.
- The two public pipelines share about a hundred lines of prologue, and
  methods take 16 to 27 parameters. A per-run context object would remove
  both and the `active_tuning` instance field.
- Routine telemetry is logged with `warning ()`.
- The orchestrator has no tests; only the pure logic does.

## Follow-up

SO-F2 and SO-F3 were fixed under TASK-20261109-vmaf-threads-model and SO-F1
under TASK-20261109-quality-floor-guard; the section text above is the
original finding. SO-F1 reuses `is_impossible` for a flat ladder instead of
the separate needs-attention flag suggested there.

## Suggested order

1. SO-F2 and SO-F3: small, contained, measured.
2. SO-F1: the guard and the needs-attention flag.
3. SO-F4 with the closed-loop size correction.
4. SO-F5 and SO-F6 together, since both redefine what the tier controls.
