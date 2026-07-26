# Smart Optimizer — Phase 0 Findings

Measurements from `DevTools/analyze-corpus.py` over the corpus at
`/mnt/storage3/testvideos` (16 files), analysed by `DevTools/corpus-report.py`.

Phase 0 exists because the codebase already carries one uncalibrated threshold
pair (`GRAIN_SYNTH_LOW/HIGH`, commented *"PROVISIONAL — calibrated only against
clean/digital sources"*) and the quality solver would add roughly a dozen more.
This document records what the corpus actually says.

**Status: complete.** 16 files, 16 signal rows (with matched degraded pairs),
80 CRF/VMAF sweep points, 16 matched compressibility pairs.

### Summary of what changed in the plan

| Plan said | Data says |
|---|---|
| Fit `logit(vmaf/100)` | **Plain quadratic on raw VMAF** — 4.7× lower residual; logit explodes at VMAF 100 |
| "3 points should suffice" | **Confirmed** — 0.318 VMAF mean prediction error |
| Phase 4a: gate on `blockdetect`/`blurdetect` | **Not possible.** No pixel-domain signal detects degradation without a reference. Consider dropping the guard |
| Phase 4d (noise character) demoted to last | **Un-demote** — TOUT cannot separate grain from compression noise, so the existing grain gate is untrustworthy without it |
| Phase 4b (temporal complexity) "cheapest win, do first" | **Not implementable** — keyframe density and bitrate variance measure the source encoder's GOP and rate control, not content (Part 7) |
| Phase 4d (noise character) | **Not implementable** — the candidate signal was measuring bit depth (Part 8) |
| Content override axis is a nice-to-have | **Essential** — the classifier cannot detect anime or screencast at all (Part 4) |

### Highest-priority outcome

Part 4 was an **active production defect** unrelated to the quality solver:
`classify_content` could not assign ANIME or SCREENCAST to any real source, and
misfiled screencasts as anime. **Fixed** — see Part 4.

---

## Part 1 — Production bugs found

Three genuine defects surfaced while building the tooling. None are caused by
the Phase 1 refactor; all pre-date it. They share one root cause worth stating
on its own:

> **`ffmpeg` exits 0 while producing nothing** — in one specific case. When a
> filter chain yields no frames (a trim or concat covering a range with no
> decodable content), ffmpeg prints "Output file is empty, nothing was encoded"
> and **exits 0**, leaving a header-only container: 262 bytes for MP4, 581 for
> Matroska. Any code treating a zero exit as proof of success consumes that
> file happily.
>
> ⚠️ **Correction.** An earlier revision of this document claimed the
> odd-dimension failure below also exits 0. It does not — x264 exits 187 and
> x265 exits 183. That claim came from a shell pipeline where `&&` read the
> exit status of `tail` rather than of ffmpeg. Encoder-open failures are
> already caught by the exit code; the empty-output case is the one that slips
> through, and it is the one worth guarding.

Production checks exit status in several places where it needs to check output.

### 1.1 — Odd source dimensions silently produce empty output ⚠️ user-facing

**Severity: high.** Affects normal conversion, not just Smart Optimizer.

VP9 and AV1 permit odd dimensions with `yuv420p`; x264 and x265 do not.
`Screencast-testvid0.webm` in the corpus is **3837×2160** — window captures
routinely land on odd dimensions because they record whatever size the window
happened to be.

Measured, 2 seconds of that source, no scaling:

| Encoder | Output | Frames | ffmpeg exit |
|---|---|---|---|
| libx264 | **0 bytes** | **0** | **187** |
| libx265 | **0 bytes** | **0** | **183** |
| libsvtav1 | 1244903 bytes | 78 | 0 |
| libvpx-vp9 | 1141675 bytes | 78 | 0 |

So converting an odd-dimension source to x264/x265 produces nothing — but it
does so *loudly*, with a non-zero exit that callers already treat as failure.
The user still cannot convert the file, which is the real defect; they are just
not lied to about it.

`filter-builder.vala:187-190` already rounds to even — but only inside the
**scale** path, so it only helps when the user happens to be scaling. With no
scale filter the odd dimensions pass straight through.

Also hits `build_filtered_intermediate_cmd` (`smart-optimizer.vala:2537`), which
uses `libx264 -qp 0` for 8-bit lossless intermediates.

**Proposed fix:** guarantee even dimensions in the filter chain for any
x264/x265 output regardless of whether the user is scaling — append
`crop=trunc(iw/2)*2:trunc(ih/2)*2`. Crop rather than scale: dropping one pixel
column is lossless for the remaining pixels, whereas rescaling resamples the
whole frame. The expression is self-neutralising (`trunc(iw/2)*2 == iw` when
`iw` is even), so it needs no source-dimension knowledge to be *correct*.

⚠️ **But it must not be appended unconditionally.** Adding any `-vf` forces a
filter graph, which disables video stream-copy. A user doing a remux would
silently start re-encoding. The guard therefore needs all three of:

1. output codec is x264 or x265 (SVT-AV1 and VP9 handle odd dimensions fine),
2. video is actually being re-encoded, not stream-copied, and
3. the source has an odd dimension — which means the fix *does* need probed
   source dimensions, despite the expression being self-neutralising.

Note `ScaleMode.PERCENTAGE` already emits `trunc(iw*N/2)*2`, but
`ScaleMode.RESOLUTION` and `ScaleMode.CUSTOM` pass their dimensions through
verbatim, so a user typing an odd custom width hits the same failure even when
the source is even.

**Partially fixed.** The *lossless intermediate* now forces even dimensions
(`smart-optimizer.vala`, `build_filtered_intermediate_cmd`). That path is safe
to fix unilaterally: the intermediate is internal and always re-encoded, so the
stream-copy hazard does not apply.

This mattered more than first assessed — the intermediate uses `libx264 -qp 0`
regardless of the OUTPUT codec, so an odd-dimension source broke it for **every
codec**, taking Quality Mode with it (the intermediate is its VMAF reference).
Confirmed by a live run: a 3837×2160 screen capture failed under SVT-AV1 before
the fix and completes after it.

**The user-facing conversion path is still unfixed** — that is where the
stream-copy interaction needs a decision. `ensure_intermediate` also now
validates output size rather than mere existence, since ffmpeg had been leaving
a 581-byte truncated file that passed the existence check.

### 1.2 — Lying container durations produce empty calibration ⚠️

**Severity: medium.** Smart Optimizer only.

`random-testvid3.webm` advertises **323.5 s** in its container header but holds
**150 decodable frames (~9.4 s)**. `pick_sample_positions` trusts the probed
duration, so all six sample windows land past the last frame. Every calibration
encode returns nothing, and because ffmpeg exits 0 throughout, the optimizer
would fit its CRF↔size model to empty measurements.

**Proposed fix:** validate that the intermediate/probe output contains frames,
not merely that the command exited 0. On failure, measure the real duration
(decode to null and read the final timestamp) and re-pick positions once. The
fallback is cheap by construction — it only fires after an empty result, which
means the file is short or broken.

`analyze-corpus.py` implements exactly this; it recovers the file to 1 segment
from the real 9.4 s.

**Knock-on: the file's bitrate was also being mis-derived.** `size ÷ header
duration` made `random-testvid3.webm` look like a 0.1 Mbps wreck — an apparently
ideal degraded sample. Against its real 9.4 s duration it is **4.6 Mbps at
640×360 (bpp 1.26)**, one of the *least* starved files in the corpus. Any
production logic deriving source bitrate from the probed duration inherits the
same error, which matters because bitrate feeds the confidence assessment and
the reduction-target check.

**Corpus gap created by this correction:** with `random-testvid3` reclassified,
the corpus now has **no genuinely degraded real-world source**. The matched-pair
probe manufactures damaged copies, which covers the calibration need, but a real
over-compressed download (a re-encoded rip, a low-quality stream capture) would
be worth adding.

### 1.3 — Exit-status-only success checks ✅ FIXED

**Severity: medium.** The general form of 1.2.

`ConversionRunner` declared success purely on `execute_ffmpeg(...) == 0` and
never checked that the output existed, so an encode that produced nothing
reported *"Conversion completed successfully!"* over an unplayable file.
`TrimRunner` and `CombineRunner` had the same shape — and trimming is the
likeliest operation to hit it, since a range starting past the end of the real
content produces exactly the empty output described above.

Fixed with `FfprobeUtils.output_file_is_usable`, applied at all three
completion points. Size alone cannot decide it: a header-only file is small but
not zero, and a legitimately tiny clip is also small. Asking ffprobe for a
duration is what separates them — it fails outright on the stubs.

Verified against real artifacts rather than in theory:

| file | verdict |
|---|---|
| 581-byte Matroska stub (exit 0) | rejected |
| 262-byte MP4 stub (exit 0) | rejected |
| valid 1.28 MB encode | accepted |
| zero-byte file | rejected |
| missing file | rejected |

---

## Part 2 — Degradation signal (`blockdetect` / `blurdetect`)

**Verdict: neither `block` nor `blur` is usable as a degradation threshold, and
`block` is not even directionally reliable. Phase 4a needs redesigning.**

⚠️ This reverses an earlier reading taken from four cross-content data points.
Nine matched pairs say the opposite. The matched pairs are authoritative — they
hold content fixed and vary only damage.

### Matched pairs (n=9, degraded to 0.015 bpp)

| Source | block | →deg | Δblock | Δblur |
|---|---|---|---|---|
| anime-testvid0 | 1.305 | 3.210 | +1.905 | +0.67 |
| anime-testvid1 | 1.426 | 3.084 | +1.658 | +0.51 |
| **movie-1080p** | **3.792** | **1.695** | **−2.096** | +1.00 |
| movie-UHD | 1.019 | 1.157 | +0.138 | +1.53 |
| musicvideo | 1.344 | 2.465 | +1.121 | +0.49 |
| random-testvid0 | 1.489 | 2.407 | +0.918 | +1.22 |
| random-testvid1 | 1.514 | 2.154 | +0.640 | +0.92 |
| random-testvid2 | 1.500 | 2.037 | +0.537 | +0.30 |
| random-testvid3 | 1.947 | 3.290 | +1.343 | +2.34 |

- **Δblock: mean +0.685, range −2.096 … +1.905 — SIGN FLIPS.**
- **Δblur: mean +0.998, range +0.303 … +2.338 — always positive.**

### Why `block` flips sign

Blockiness is **not monotonic with damage**. Mild compression adds block edges;
severe compression smooths them away, because the deblocking filter and
aggressive quantisation flatten detail into mush. `movie-1080p` degrades from
3.792 to 1.695 — it got *less* blocky by being wrecked harder.

`block` also has (at least) two content confounds:

1. **Synthetic rectangles.** A pristine screencast reads 2.345 — higher than
   most *deliberately damaged* files. UI chrome is literally rectangles on a
   grid, which is what the detector looks for.
2. **Film grain.** `movie-1080p` reads 3.792 clean, the corpus maximum, and it
   also has the second-highest TOUT (0.00194) — consistent with AV1 film-grain
   synthesis. Degrading it destroys the grain, which is exactly why its block
   score collapses.

### `blur` is directionally reliable but still not absolute

Δblur is positive in all 9 pairs, which makes it the better *relative* signal —
the reverse of my earlier claim. But its absolute range still overlaps
completely across content (optical shallow-depth-of-field reads the same as
compression softness), and **production has no clean reference to diff
against**, so directional reliability alone doesn't help.

### Absolute separability: fails

```
clean    block: 1.019 … 3.792
degraded block: 1.157 … 3.290     → overlap 2.634
```

Normalisation does not rescue it:

```
block/si    clean 0.0191…0.1047   deg 0.0507…0.1035   overlap 0.0540
block/edge  clean 0.1606…2.9035   deg 0.4702…5.1062   overlap 2.4333
```

### bits-per-pixel is also confounded

The obvious fallback has its own problem — bpp is not comparable across codecs.
`anime-testvid1` (AV1, 0.694 bpp) and `movie-UHD` (AV1, 0.064 bpp) differ by
10× while both being high-quality sources, because AV1 needs far fewer bits than
h264 for equal quality. Any bpp rule needs a per-codec efficiency multiplier.

### Recommended redesign: measure compressibility, don't detect artifacts

The most promising option uses machinery the solver **already runs**.

An already-compressed source has had its high-frequency content removed. So if
you encode it at near-lossless quality, it compresses to far fewer bits than a
clean master of the same resolution would. That ratio —

> bits needed at near-lossless ÷ (width × height × fps)

— is a direct measure of *remaining information content*, and it is:

- **content-adaptive by construction** (it measures this source, not a
  population),
- **codec-independent** on the source side (you're measuring with *your*
  encoder, not inferring from theirs),
- **free** — the calibration sweep already encodes the sample segments at
  several CRFs, and the lowest CRF point is exactly this measurement.

This reframes degradation from *"detect artifacts in the pixels"* (which the
data says doesn't work) to *"measure how much real information is left"* (which
the existing probe pipeline answers directly).

### Tested — and it also fails as an absolute threshold

Matched pairs at CRF 16 (identical frames, clean vs starved copy, 16 files):

```
clean bits-per-pixel: 0.0133 … 0.4757
degraded            : 0.0114 … 0.2790     → OVERLAP 0.2657
```

Directionally correct for most content (14/16 ratios below 1.0, mean 0.668),
but **two files went the wrong way**:

- **Screencast: ratio 1.147.** Degrading text *adds* ringing and mosquito noise
  around glyph edges, and reproducing that mess at near-lossless costs more bits
  than the clean flat text did.
- musicvideo: 1.019, essentially unchanged.

So the compressibility idea joins the others. My proposal above was wrong.

### The real conclusion: absolute degradation detection is not possible

Every signal tried — `block`, `blur`, `si`, source bpp, and compressibility at
near-lossless — is directionally informative against a reference and
content-confounded without one. That is not a run of bad luck in signal
selection; it is what the problem is. **"Is this source damaged?" is not
answerable from the source alone**, because damage is defined relative to what
the content should have looked like, and a single file does not carry that.

Any future attempt should start from this, not rediscover it.

### The one surviving candidate: codec-corrected quality ratio

Production knows the source bitrate, codec, resolution and fps, and the
calibration already produces a near-lossless size. Correcting source bpp by a
rough per-codec efficiency factor and dividing by the measured CRF-16 bpp gives:

| file | codec | q_ratio |
|---|---|---|
| women-4k-testvid0 | h264 | 0.28 |
| random-testvid2 | h264 | 0.45 |
| tvshow-720p | h264 | 0.63 |
| musicvideo | av1 | 0.65 |
| … | | |
| **anime-testvid0** (5 Mbps rip) | h264 | **1.24** |
| … | | |
| movie-UHD | av1 | 2.34 |
| **anime-testvid1** (43 Mbps BD) | h264 | **3.12** |
| women-4k-testvid1 | av1 | 7.57 |

27× dynamic range, and it ranks the one near-matched pair correctly — the
compressed anime rip (1.24) below the BD-tier source (3.12).

**But this is a plausibility check, not a validation.** There is no ground-truth
quality label in the corpus, and the codec-efficiency multipliers are themselves
uncalibrated constants. It should not be trusted without that work.

### Recommendation for Phase 4a

**Consider dropping the degradation guard entirely.** Its purpose was to stop
VMAF chasing artifacts on damaged sources and overspending. But:

1. No measurable signal identifies degradation from a single source (above).
2. The **2× source-size ceiling already catches the pathological case**, which
   was the concrete harm the guard existed to prevent.
3. Nothing in the intent→CRF mapping (Part 6) shows degraded sources demanding
   pathological CRFs.

Dropping it removes two filters, a pile of uncalibrated thresholds, and a
signal that the data says cannot work — at the cost of a guard that the size
ceiling largely subsumes. If it is kept, the codec-corrected quality ratio is
the only candidate worth pursuing, and it needs ground-truth validation first.

---

## Part 3 — Grain thresholds (TOUT)

Current production: `GRAIN_SYNTH_LOW = 0.0015`, `GRAIN_SYNTH_HIGH = 0.0040`.

**Not one file in the corpus reaches `GRAIN_SYNTH_HIGH`.** Full range across 16
files: **0.00004 – 0.00279**.

| band | count | meaning |
|---|---|---|
| ≤ 0.0015 (clean) | 13 | measurement decides: no grain |
| 0.0015 – 0.0040 (ambiguous) | 3 | falls through to category heuristic |
| ≥ 0.0040 (grainy) | **0** | never fires |

So the "clearly grainy → synthesise regardless of category" branch is dead on
this material, and the grain decision is effectively still the category
heuristic — which Part 4 shows is itself broken.

### The mean is the wrong statistic

`tout_p95` tells a different story from `tout_mean`:

| file | mean | p95 |
|---|---|---|
| random-testvid3 | 0.00279 | **0.00743** |
| movie-1080p | 0.00194 | **0.00436** |
| anime-testvid1 | 0.00107 | 0.00389 |
| tvshow-720p | 0.00125 | 0.00387 |

Two files cross 0.0040 at p95 while no file crosses it at the mean. Grain is
scene-dependent — heavy in dark or flat scenes, invisible in bright detailed
ones — so averaging across all sampled frames dilutes exactly the evidence the
threshold is looking for. **Production averages (`noise_mean`).**

Recommendation: gate grain on a high percentile rather than the mean, or lower
`GRAIN_SYNTH_HIGH` substantially. The percentile change is preferable — it
targets the actual physical behaviour instead of just moving a number.

### TOUT does not separate grain from compression noise

The highest TOUT in the corpus (`random-testvid3`, 0.00279) is **anime** — flat
cel content, which has no grain at all; its TOUT is compression noise and
dithering on flat fills. The second highest (`movie-1080p`, 0.00194) is a film
whose grain is visible on inspection at 3× magnification: uniform fine speckle
across flat fabric. TOUT ranks them adjacently.

That the corpus **maximum** TOUT belongs to grain-free animation is a stronger
statement of the confound than the original one, which was based on a
mis-derived bitrate for that file.

This is exactly the confound the plan's "noise character" signal (Phase 4d) was
meant to resolve, and it confirms that keeping grain synthesis gated on TOUT
alone will mis-fire on compressed sources. It also strengthens the case for
demoting 4d less far than I suggested: it is not merely a refinement, it is what
makes the existing grain gate trustworthy.

### Corpus gap

No source reads as genuinely grainy. Either the corpus has no real film grain
(all modern digital or already-denoised encodes), or TOUT under-reports it. A
real 35 mm/16 mm scan remains the outstanding item to settle this.

---

## Part 4 — Content classification is miscalibrated ⚠️

**Severity: high. This is an active production defect, not a future design
concern.** `classify_content` cannot identify the content types it exists to
identify.

Replaying `classify_content` exactly as written (`smart-optimizer-logic.vala`)
against the corpus measurements:

| file | edge | satSD | ydif | edgeS | satS | motS | anime | verdict |
|---|---|---|---|---|---|---|---|---|
| Screencast-testvid0 | 5.28 | 2.52 | 0.85 | 0.009 | 1.000 | 1.000 | 0.653 | **ANIME** ❌ |
| anime-testvid0 | 2.67 | 8.59 | 4.55 | 0.000 | 0.897 | 0.763 | 0.543 | **MIXED** ❌ |
| anime-testvid1 | 3.15 | 3.03 | 3.13 | 0.000 | 1.000 | 0.858 | 0.607 | **MIXED** ❌ |
| movie-1080p | 2.37 | 9.89 | 13.83 | 0.000 | 0.860 | 0.145 | 0.344 | LIVE_ACTION |
| movie-UHD | 0.35 | 2.93 | 11.71 | 0.000 | 1.000 | 0.286 | 0.436 | LIVE_ACTION |
| musicvideo | 2.10 | 8.63 | 9.72 | 0.000 | 0.896 | 0.419 | 0.439 | LIVE_ACTION |
| random-testvid0 | 2.46 | 1.65 | 3.65 | 0.000 | 1.000 | 0.823 | 0.597 | MIXED |
| random-testvid1 | 1.62 | 0.49 | 2.81 | 0.000 | 1.000 | 0.879 | 0.614 | MIXED |
| random-testvid2 | 4.80 | 7.27 | 2.70 | 0.000 | 0.935 | 0.886 | 0.593 | MIXED |
| random-testvid3 | 12.12 | 9.77 | 18.45 | 0.237 | 0.864 | 0.000 | 0.385 | LIVE_ACTION |
| short-testvid0 | 1.40 | 1.38 | 1.95 | 0.000 | 1.000 | 0.937 | 0.631 | MIXED |
| tvshow-720p | 5.51 | 4.86 | 6.37 | 0.017 | 1.000 | 0.642 | 0.549 | MIXED |
| women-1080p | 5.63 | 1.86 | 10.15 | 0.021 | 1.000 | 0.390 | 0.474 | MIXED |
| women-4k-testvid0 | 12.96 | 1.40 | 10.46 | 0.265 | 1.000 | 0.369 | 0.554 | MIXED |
| women-4k-testvid1 | 0.21 | 1.57 | 7.54 | 0.000 | 1.000 | 0.564 | 0.519 | MIXED |
| women-phonevid | 8.27 | 6.17 | 11.64 | 0.109 | 0.967 | 0.291 | 0.464 | MIXED |

### Three concrete defects

**1. The edge term is dead.**
`edge_score = ((edge_mean − 5.0) / 30.0).clamp(0,1)` is written for edge values
spanning 5–35. The corpus spans **0.21 – 12.96**. Result: `edge_score` is
exactly 0.000 for 10/16 files and below 0.27 for every other one. The heaviest
single input to the anime heuristic contributes nothing.

**2. The screencast gate is unreachable.**
Requires `edge_mean > 25.0` (or `> 20.0` for the weak branch). Nothing in the
corpus exceeds **12.96**, and that is a *live-action 4K* file. `SCREENCAST` can
never be assigned, so screencasts never get `tune stillimage` (x264) or VP9's
Screen content mode.

**3. Anime is unreachable; screencast is misfiled as anime.**
With `edge_score ≈ 0`, the maximum achievable `anime_score` is
`0.35·1 + 0.30·1 = 0.65`, and the test is `> 0.65` — so **ANIME is arithmetically
unreachable for any source whose edge_mean is below 5.0**, which includes both
real anime files. Meanwhile the screencast reaches 0.653 purely on low motion
(ydif 0.85) and flat saturation (satSD 2.52), and is labelled ANIME.

### Downstream impact

`content_type` drives preset selection (`choose_ideal_preset_index`), encoder
tune (`animation` / `stillimage` / `grain`), bit-depth Rule 8, and the
`grain_warranted` category fallback. Today:

- Anime never receives `tune animation`.
- Screencasts never receive `tune stillimage` or VP9 Screen mode.
- 10/16 sources are treated as MIXED, and MIXED confidence feeds the preset
  interpolation, so preset choice is being damped toward the tier baseline
  across most content.

### `si` is a dramatically better screencast discriminator

`siti`'s spatial-information output separates screencast from everything else by
more than 2×, where `edge_mean` does not separate it at all:

```
Screencast     si = 115.4      (edge 5.28 — indistinguishable from live-action)
next highest   si =  52.3
corpus median  si ≈  40
```

Combined with `ti = 4.6` (lowest motion in the corpus bar none), screencast is
trivially separable on `si`/`ti` — the two signals added for the quality solver
turn out to fix a classifier bug that predates it.

### ✅ FIXED

`classify_content` rewritten against the measured ranges, with the corpus as a
regression fixture (7 new tests in `smart-optimizer-logic-test.vala`).

The new classifier is ordered most-confident-rule-first, because the classes
differ enormously in how well the available signals identify them:

| rule | condition | corpus margin |
|---|---|---|
| SCREENCAST | `ydif < 2.0 && edge > 3.0` | screencast 0.85/5.28; nearest confusable `short-testvid0` 1.95/**1.40** — excluded on edge |
| LIVE_ACTION | `ydif > 6.0` | lowest live/film 6.37; highest anime 4.55 |
| ANIME | `ydif < 5.0 && 2.0 ≤ edge ≤ 4.5` | weak — see below |
| MIXED | everything else | the honest default |

### Before / after on the corpus

| | OLD | NEW |
|---|---|---|
| SCREENCAST | 0 | **1** |
| ANIME | 1 *(the screencast!)* | **3** |
| LIVE_ACTION | 4 | **9** |
| MIXED | **11** | 3 |

Both real anime files now classify as ANIME (were MIXED). The screencast
classifies as SCREENCAST (was ANIME). The MIXED sink drops from 11 to 3.

### Known false positive, accepted deliberately

`random-testvid0.webm` classifies as ANIME. Visual check: it is **live-action
aerial footage — a fighter jet against open sky.** Slow subject, smooth sky,
almost no texture, so it reads exactly like animation on these signals.

Not fixable by tightening: its edge is 2.46 against anime's 2.67/3.15: a
0.2 margin. Moving the boundary there would be fitting noise on a two-sample
class.

Mitigated instead by **capping ANIME confidence at 0.5**
(`ANIME_MAX_CONFIDENCE`). `choose_preset_index` interpolates from the tier
baseline toward the content ideal *scaled by confidence*, so a capped-confidence
ANIME moves the preset only halfway. The residual cost of the false positive is
`tune animation` on flat live-action, which is mild.

### Corpus correction: there is a THIRD anime file, and it is misdetected

`random-testvid3.webm` is a fast-cut **anime opening**, verified by looking at
frames rather than inferred from the filename. It had been filed under the
generic "random" prefix and treated as `misc` throughout the earlier analysis.

This matters because it is the only **high-motion** animation in the corpus:

| file | motion (ydif) | classified as |
|---|---|---|
| anime-testvid0 | 4.55 | ANIME ✓ |
| anime-testvid1 | 3.13 | ANIME ✓ |
| **random-testvid3** | **18.45** (corpus max) | **LIVE_ACTION ✗** |

The `ydif > 6.0` live-action rule claims it long before the animation rule is
reached, and the animation rule was calibrated on two low-motion samples that
never exercised this case. A regression test now asserts the misclassification
explicitly (`content/high-motion-anime-limitation`) so it cannot change
silently — an earlier version of that test asserted this file as *correctly*
live-action, which was encoding the bug as expected behaviour.

**The spatial-information hypothesis died once more anime was measured.** With
one sample, si 101.8 against a 74.2 ceiling looked like a clean animation
signal. Three more anime sources put the other five at **22.3–46.9**, straddling
live action. SI was never measuring animation, only graphics-heavy content —
which is exactly why it was not implemented on n=1.

### With six anime samples, the animation rule improves — but only in its band

Three further animation sources (dark TV, bright TV, cinematic film) brought the
corpus to six verified anime. Within the band the animation rule can actually
reach (motion at or below the live-action threshold):

```
anime   edge 1.36–2.67   satSD 3.03–8.59
live    edge 1.40–4.80   satSD 0.49–7.27
```

Edge alone cannot separate them: lowering the floor to 1.3 to catch the darkest
anime also admits an aerial shot of a jet, a poolside phone video and a muted
live-action film — all three verified by eye, and two of them previously
sitting unexamined in the corpus as "misc".

**Saturation variance separates them.** Animation cuts between strongly and
differently coloured scenes; the naturalistic footage landing in this band holds
a consistent overall saturation.

| rule | anime found | false positives |
|---|---|---|
| original (edge 2.0–4.5) | 3/6 | 1 |
| widened edge only (1.3–4.5) | 4/6 | 3 |
| widened + `blur < 7.5` | 4/6 | 2 |
| **widened + `satSD ≥ 2.5`** | **4/6** | **0** |
| widened + satSD + blur | 4/6 | 0 |

Strictly better than the original on both axes. `blur` also separates —
animation has no optical defocus, which is a better physical story than the
saturation one — but it adds nothing once satSD is applied, so it was left out
rather than carried as redundant decoration.

**Two of six are still missed, both high-motion** (ydif 8.73 and 18.45). The
live-action rule claims them before the animation rule is reached, and nothing
measurable here separates fast animation from fast live action.

### Animation detection remains weak, by design

Every available signal was tested for anime separability and all overlap with
slow, flat live-action:

- `edge_mean` — anime 2.67/3.15 vs `random-testvid0` 2.46, `short-testvid0` 1.40
- `saturation_mean` — anime 13.74/7.27, scattered across the corpus mid-range
- `saturation_stddev` — anime 8.59/3.03, no coherent band
- `temporal_diff_mean` — anime 3.13/4.55 overlaps four non-anime files
- `VREP` (repeated frames — the "animated on 2s" hypothesis) — anime 0.07/0.08,
  **identical to film/tv 0.08**. Ruled out.
- histogram `entropy` (limited-palette hypothesis) — anime UV 3.42/4.17 sits
  directly on top of film 4.02–4.08 and live-action 3.98. Ruled out.

With two anime samples and this much overlap, no honest threshold exists. This
makes the plan's **Content override axis (Auto / Live-action / Anime /
Screencast) load-bearing rather than a convenience** — it is the only reliable
path to correct animation handling.

If auto-detection is wanted later, the missing measurement is *flat-region
ratio* (fraction of pixels whose local gradient is exactly zero — cel fills),
which `signalstats` does not expose. More anime samples would also be needed
before trusting any new threshold.

---

## Part 5 — VMAF curve shape: use a plain quadratic, NOT logit

**The plan specified `logit(vmaf/100)`. The data says a plain quadratic on raw
VMAF is 4.7× better.** 16 files, 5 CRF points each (`16,20,24,28,34`, libx265):

| model | mean RMSE (VMAF points) |
|---|---|
| raw linear | 1.925 |
| logit-linear | 1.075 |
| **quadratic on raw VMAF** | **0.228** |

Logit does beat raw-linear on mid-range files (0.098 on `movie-1080p`, 0.054 on
`random-testvid1`) — the saturation correction is real. But it **explodes** on
files that touch VMAF 100:

```
Screencast-testvid0   logit RMSE 2.726   (VMAF 99.99 at CRF 16)
women-4k-testvid0     logit RMSE 6.777   (VMAF 100.0 at CRF 16)
```

As VMAF → 100, `logit` → ∞, so a single saturated sample wrecks the fit. The
quadratic is robust across the whole corpus (worst case 0.380).

**Consequence for Phase 2:** feed `fit_quadratic_least_squares` the raw VMAF
values with **no transform at all**. This is simpler than the plan assumed — the
extracted least-squares core is used directly. Two guards are needed:

1. **Clamp predictions to ≤100** — an unconstrained quadratic will happily
   predict 101.
2. **Reject saturated calibration points.** If the lowest-CRF probe returns
   ≥99.5, it carries no gradient information; discard it and probe higher. This
   is what damaged both the logit fit and the 3-point test below.

## Part 5b — Fit economy: 3 points IS sufficient

Fitting on 3 points (lowest, middle, highest) and predicting the 2 held-out
points across all 16 files:

- **mean |error| = 0.318 VMAF points**
- max error 3.429

The plan's assertion is confirmed: the quality solve needs **3 base points plus
verification**, where the size solve needs 4–6. VMAF-vs-CRF really is a
better-behaved response than size-vs-CRF.

The single bad case is instructive — `women-4k-testvid0` errs by 3.43 because
its CRF-16 anchor is saturated at VMAF 100.0. With the saturation guard above,
3 points is comfortably sufficient.

---

## Part 6 — Intent → CRF mapping: the solver's justification, quantified

CRF required to reach each intent's VMAF target, per content class:

| class | Low (88) | Medium (92) | High (95) | Ultra (97) |
|---|---|---|---|---|
| anime | 29.8 | 25.6 | **20.1** | **12.3** |
| film/tv | 30.6 | 27.4 | 23.7 | 19.5 |
| misc | 30.3 | 27.1 | 23.2 | 18.0 |
| live-action | 30.9 | 28.5 | **26.0** | **23.5** |
| **spread** | **1.1** | **2.9** | **5.9** | **11.2** |

**The required CRF spread widens sharply as quality intent rises.** At Ultra,
anime needs CRF 12.3 while live-action needs 23.5 — an 11-point gap, and the
per-file extremes are wider still (`anime-testvid1` 11.1 vs `musicvideo` 26.6, a
**15.5-point** range).

⚠️ **Partly corrected by Part 9.** The anime figures here are inflated by the HD
VMAF model under-scoring animation by the equivalent of 6–8 CRF. The spread
between live-action and film classes is real; the anime column is not a clean
measure of content difference and should not be quoted as one.

This is the quantified case for the solver:

- A static "Ultra = CRF 18" table would leave anime visibly short of its target
  while spending far more than live-action needs.
- **At Low intent the spread is only 1.1 CRF** — a static table would be nearly
  fine. The solver's value is concentrated at High/Ultra, exactly the intents
  users reach for when they care.

### Screencast breaks the intent scale entirely

| intent | Low | Medium | High | Ultra |
|---|---|---|---|---|
| Screencast | — | — | 29.8 | 27.2 |

Low and Medium are unreachable: **even CRF 34 scores VMAF 92.69**, above the
Medium target. And "Ultra" resolves to CRF 27, which on text and UI would look
poor to any user.

This is direct confirmation of the plan's Phase 5 concern. VMAF is trained on
natural video and massively over-rewards synthetic screen content. Screencast
must use rule-based CRF with VMAF as a floor only — the intent→VMAF scale is
meaningless there.

---

## Part 7 — Temporal complexity (Phase 4b) does not work either

**Verdict: neither keyframe density nor whole-file bitrate variance measures
content. Both measure the encoder that produced the source. Recommend dropping
Phase 4b as specified, like Phase 4a.**

Phase 4b was billed as the cheapest win — keyframe positions and packet-size
variance fall out of the demux-only `probe_source_bitrate_profile` pass that
already runs, so the signals are genuinely free. They were measured across all
16 corpus files before being wired into anything.

### Keyframe density tracks GOP configuration, not cuts

| file | motion (ydif) | keyframes/min | source codec |
|---|---|---|---|
| random-testvid3 | **18.45** (highest) | **63.9** | vp8 |
| movie-1080p | 13.83 | **6.1** (lowest) | av1 |
| movie-UHD | 11.71 | 6.0 | av1 |
| women-4k-testvid0 | 10.46 | 60.1 | h264 |
| **anime-testvid1** | **3.13** (lowest) | **66.2** (highest) | h264 |

The two highest-motion files sit at opposite extremes of keyframe density, and
the **lowest-motion file has the highest density of all**. What the column
actually separates is source encoder configuration: the AV1 streaming encodes
use a ~10 s GOP (6/min), the h264 captures use ~1 s (60/min).

Correlations confirm it: `kf/min` vs source bits-per-pixel is **+0.630**,
stronger than its +0.536 with motion — and motion and bitrate are themselves
correlated, so most of that second figure is likely mediated by the first.

### Whole-file bitrate variance is worse

Per-second bucket CV against the things it would need to track:

```
bucketCV vs motion (ti)          −0.219   ← negative; should be positive
bucketCV vs sampled ydif CV      −0.138   ← uncorrelated with what it would replace
bucketCV vs source bpp           −0.292
```

It does not track content variability at all. `adaptive_expansion_count`'s
existing sampled-motion CV — computed from decoded pixels rather than container
metadata — is the better measure despite being noisier, and should stay.

### Postscript: `siti` (Phase 4c) is usable, but not where it was aimed

Spatial information was planned as an input to detail-retention decisions (AQ,
psy-rd strength per intent). There is no ground truth for that, so it would
have been another invented threshold. It IS used for something measured: `si`
separates screen content from everything else by a much wider margin than edge
density, which does not separate it at all.

```
Screencast   si 115.4   motion  0.85
next-highest si 101.8   motion 18.45   (heavy motion — live action)
rest          si ≤ 74.2
```

**Cost correction.** The claim earlier in this document that the new signals
"ride the existing pass for free" was right about the decode and wrong about
the filter. Measured on the production chain:

| chain | time |
|---|---|
| signalstats alone | 4.5 s |
| signalstats + siti (every frame) | **45.6 s** |
| signalstats + siti (after decimation) | **7.3 s** |

`siti` does per-frame Sobel work and is expensive. Placing it *after* the
existing frame decimation cuts it 6× for an **identical mean SI**, because SI
is a per-frame measure and sampling it is unbiased.

That is only true for SI. TI is frame-to-frame and would measure across the
decimation gaps, so it is not used — `signalstats`' YDIF already provides
temporal activity on every frame at no cost, and the screencast rule pairs
`si` with that instead.

Net effect on a real run: analysis went 33 s → 74 s when siti ran on every
frame, and back to 36 s once decimated.

### The general principle, now confirmed twice

> **Properties of an already-encoded source describe the encoder that made it at
> least as much as the content inside it.**

Degradation (Part 2) and temporal complexity (Part 7) both died on this. Two of
the four Phase 4 signals are gone, killed by measurement rather than opinion,
and the surviving two (spatial detail via `siti`, noise character) should be
held to the same standard before implementation: measure first, wire in second.

Signals derived from **decoded pixels** (`signalstats`, `edgedetect`, `siti`)
remain sound. Signals derived from **container/bitstream metadata** (packet
sizes, keyframe flags, source bitrate) are suspect by default.

---

## Part 8 — signalstats is measured in the source's native bit depth ⚠️

**Severity: high, and it invalidated part of this document's own analysis.**

`signalstats` reports in the source's native range, so a 10-bit source yields
~4× the values of identical content at 8-bit. Every threshold in
`classify_content`, the grain gate and the banding metrics compares those
figures **across** sources.

Measured on one 10-bit film, native versus the same content converted to 8-bit:

| metric | native | at 8-bit | ratio |
|---|---|---|---|
| YDIF | 13.83 | 3.46 | 4.00× |
| YLOW | 147.9 | 37.0 | 4.00× |
| SATAVG stddev | 9.89 | 2.47 | 4.02× |
| **TOUT** | **0.00194** | **0.00018** | **10.8×** |
| edgedetect YAVG | 3.199 | 3.206 | 1.00× |

`edgedetect` normalises its own output and is unaffected. Everything else is not.

### What it broke

`YDIF` is `temporal_diff_mean`, which gates every branch of the classifier. The
two 10-bit films in this corpus measured 13.83 and 11.71 and were filed as
high-motion live action. **Their true motion is 3.46 and 2.93** — both inside
the animation rule's band. Several conclusions earlier in this document were
drawn from those inflated figures.

### The fix, and why not the obvious one

Amplitudes are divided by `2^(depth−8)` in the parser. The one-line alternative
— `format=yuv420p` before measuring — rescales correctly but **quantises away
the sub-LSB variation fine film grain lives in**: note TOUT moving 10.8× where
amplitudes move exactly 4×. That difference is grain destroyed, not rescaled,
and it would have made a film with grain visible at 3× magnification read as
clean.

### TOUT cannot be fixed at all

Its depth response is not linear and neither figure converts into the other.
`GRAIN_SYNTH_LOW/HIGH` are therefore **8-bit only**, and `grain_warranted` now
ignores the measurement above 8-bit and defers to the content category rather
than acting on a number known to be wrong.

Restricted to the 8-bit corpus, where TOUT *is* comparable, the earlier finding
survives intact: the maximum reading (0.00279) belongs to grain-free cel
animation, and **nothing reaches `GRAIN_SYNTH_HIGH` (0.0040)**.

### Threshold consequence

Recentring the animation rule's saturation floor. Within the band that rule
reaches, the highest non-animation satSD is now 2.47 (a live-action film,
previously mis-scaled to 9.89) and the lowest animation satSD is 3.03. The
shipped 2.50 cleared the film by **0.03** — luck, not calibration. It is now
2.75, the midpoint, 0.28 from each side.

### How it was found

Testing a Phase 4d candidate. Denoise-residual amplitude looked like a clean
separator — a 3.4× gap, correctly ranking grain-free animation last despite that
file holding the corpus-maximum TOUT, which was the stated test. The top three
files turned out to be exactly the three 10-bit files in the corpus. Normalised,
the visibly grainy film sits **10th of 19**. Phase 4d is dead; the bug it
exposed was worth more than the signal.

---

## Part 9 — The VMAF model choice is not free, and it distorts animation

**Phase 5 item, measured.** The plan flagged the 4K model and the NEG variants
as decisions to make; they were made by convention and never tested.

Scoring **identical** x265 encodes under each model (only the scoring differs,
so any difference is attributable to the model alone):

| | live action 1080p | animation 1080p | live action 4K |
|---|---|---|---|
| HD → 4K model | +1.3 CRF | **+7.8 CRF** | +1.8 CRF |
| HD → HD-neg | −1.3 CRF | −2.4 CRF | −1.4 CRF |

On photographic content the choice moves the answer 1–2 CRF. On animation it
moves it **6–8**.

### The HD model under-scores animation

```
same encodes, 1080p anime
  default(HD)   CRF17 → 94.87   CRF23 → 92.05    Ultra (97): UNREACHABLE
  4K model      CRF17 → 97.76   CRF23 → 95.67    Ultra: CRF 19.7
```

The HD model cannot score 1080p animation above ~95 even at CRF 17, where the
picture is visually near-perfect. Live action at the same CRF scores 98.58.

The intent→VMAF scale (88/92/95/97) comes from VMAF literature built almost
entirely on photographic content. Pushing animation through a model that
under-scores it therefore demands a **higher real quality than the intent name
implies**.

### Measured consequence

Ultra on a 1080p anime source, end to end:

```
CRF 11 → VMAF 97.28   (1605 MiB projected)
CRF 18 → VMAF 95.97   ( 517 MiB projected)
CRF 25 → VMAF 92.70   ( 197 MiB projected)
→ solved CRF 14, verified 96.86 (delta −0.10), output 1027 MiB
```

The solver is working correctly — the verification delta is 0.10 — but the
**output is larger than the 881 MiB source**, for no visible gain over CRF 18.
The 2× size ceiling does not fire because 1027 < 1762.

### This corrects an earlier conclusion in this document

Part 6 reported the intent→CRF spread widening to 11.2 CRF at Ultra (anime 12.3
vs live-action 23.5) and presented that as the core justification for solving
rather than tabulating. **A substantial part of that spread is metric artifact,
not content difference.** The solver argument still stands on the live-action
and film numbers, but the anime figure should not be quoted as evidence of
content variation.

### Not fixed, and why

Switching animation to the 4K model would score it more plausibly, but that
model is trained for a 4K viewing distance and using it on 1080p is wrong by
libvmaf's own design. The correct remedy is a **content-aware target offset** —
the Phase 5 item that has been open throughout — and its magnitude needs
subjective comparison, which no metric sweep can supply.

What the measurement DOES settle is the **direction**, which is the opposite of
the plan's assumption. The plan expected VMAF to *under-penalise* flat animation
and called for raising the anime target. The HD model over-penalises it, so the
target should if anything be **lowered**.

### NEG variants

NEG scores 1–2.4 CRF lower across the board, i.e. more conservative. It resists
enhancement gaming, which is a real argument for encoder decisions where nothing
is being enhanced. Left unchanged for now: it shifts every intent's effective
quality upward, which would silently re-scale the entire 88/92/95/97 mapping
that Phase 0 calibrated against the non-NEG models.

---

## Part 10 — The SVT-AV1 calibration ladders were 8–16 CRF off

Phase 0 measured the CRF ladders for x264/x265 only. The SVT-AV1 and VP9 ones
were scaled from those by analogy, and a live run exposed the consequence: an
SVT-AV1 Medium solve landed on CRF 41 from a `{26,32,38}` bracket, reporting
58% confidence despite verifying to within 0.11 VMAF.

A dedicated sweep (19 files, CRF 24–48, libsvtav1) shows every ladder centred
too low:

| intent | old bracket | measured mean | measured range |
|---|---|---|---|
| Low | 30–42 | **50.1** | 41.9–53.8 |
| Medium | 26–38 | **43.8** | 33.9–53.6 |
| High | 20–34 | **34.1** | 22.5–43.6 |
| Ultra | 14–30 | 30.6* | 17.1–38.7 |

The Low bracket **topped out at 42 while the mean answer is 50.1**, so the
solve fell outside the window on nearly every source.

\* Ultra's figure is biased upward: animation cannot reach VMAF 97 under the HD
model at all (Part 9), so those files contribute no Ultra value and only the
easier content is averaged. This is why Ultra's mean sits *below* High's.

New ladders, centred on the measured means and deliberately wide — the spread
is ~20 CRF at every intent above Low, far wider than x265's:

```
Low     { 42, 48, 54 }
Medium  { 34, 44, 54 }
High    { 24, 34, 44 }
Ultra   { 18, 28, 38 }
```

### x264 shares x265's ladder, and that is correct

Phase 0 swept `libx265` only — 80 rows, zero x264 — yet both codecs share a
ladder, so x264's centring was an assumption of exactly the kind that proved
8–16 CRF wrong for SVT-AV1.

Checked directly, scoring identical content at identical CRF under both
encoders (3 sources × CRF 20/26/32):

```
mean delta   −0.07 VMAF      worst case   −1.45
```

They track each other almost exactly, so sharing the ladder is right.

This contradicts the familiar *"x265 CRF 28 ≈ x264 CRF 23"* guidance — but that
guidance is about **file size at equal quality**, and x265 reaches the same
quality with fewer bits. CRF is a quality parameter in both encoders, so the
CRF achieving a given VMAF is nearly identical; the codec difference lands on
the size axis, which the solver measures separately.

### VP9 remains unmeasured

Its ladder is still derived by analogy and has never been checked. SVT-AV1's
was a guess of exactly the same kind and turned out to be 8–16 CRF out, which
is the error to expect from VP9's. The code says so rather than lumping both
codecs under one "unvalidated" note now that SVT-AV1 is measured.

Adaptive refinement makes a mis-centred ladder recoverable — it probes near the
first solve and refits — but it pays that extra probe on nearly every run when
the ladder is this far out, which is the real cost of leaving VP9 unmeasured.

---

## Part 11 — The probe measured different encoder settings from those applied

**Severity: high on the size axis, negligible on the quality axis.** Reported
by Codex; confirmed and quantified here.

Calibration probes encoded with codec, preset, CRF and pixel format only, while
`apply_smart_*` went on to add tunes, film-grain synthesis, psy-rd, lookahead,
quantisation matrices, AQ and fast-decode. The model was therefore fitted to
one encoder configuration and the result produced by another. The verification
probe used the same simplified command, so it confirmed the mismatch rather
than catching it.

Measured at identical CRF, probe settings versus applied:

| setting | size Δ | VMAF Δ |
|---|---|---|
| **x264 `tune animation`** | **−34.3%** | +0.14 |
| SVT-AV1 `film-grain=12` | −7.1% | −0.95 |
| x265 psy-rd 2.5 + ref 4 | +1.7% | +0.05 |
| SVT-AV1 qm + lookahead | −0.3% | +0.03 |

### The quality axis survived; the size axis did not

Every VMAF delta is under a point, so solved CRFs and verified scores were
fine. Size was not: on animation the probe produced files ~34% larger than the
real encode, so **a Size Mode target landed about a third under what was
asked for** — quality paid for and not received.

This also explains why a live SVT-AV1 run predicted within 1%: it was
live-action at Medium effort, where the only extras were quantisation matrices
and lookahead at −0.3%. It happened to land in the benign case.

**The classifier fix made this worse.** Before Part 4, `ANIME` was
arithmetically unreachable, so `tune animation` almost never fired and the
34% path stayed hidden. Correcting the classifier activated it.

### Fix

One decision, two consumers: `decide_encoder_tuning` takes
`(codec, effort, content_type, grain_score, source_bit_depth, fast_decode)` and
returns the tune, grain settings, psy-rd and fast-decode level. The probe
builds its ffmpeg arguments from it and `apply_smart_*` sets its widgets from
it, so they cannot drift apart again — patching the probe setting-by-setting
would have recreated exactly the divergence that caused this.

Verified at the source. A live probe command now reads:

```
-preset medium -crf 21 -tune animation -x265-params psy-rd=2.50
```

where it previously read `-preset medium -crf 21`.

Only parameters measured as material are carried. Quantisation matrices,
lookahead, reference count and CDEF stayed within ±2% and are left to
`apply_smart_*` alone — a measured judgement rather than an oversight.

### Knock-on: the calibration cache key

Tuning changes what a probe measures, so a cached sample taken under different
tuning is a different measurement. The cache key now includes the tuning
identity; without it, changing content type or toggling Streaming would have
served stale sizes from a differently-tuned probe.

---

## Tooling notes

- `analyze-corpus.py --degrade-probe` produces the matched pairs. Without it the
  degradation columns are absent and Part 2 cannot be evaluated.
- Reference material totals **616 s across all 16 files** (10.3 min) — a
  120-minute film contributes 24 s. Segment counts are capped by a 4 GiB
  lossless-reference budget, so 4K files get 2–3 segments where 1080p gets 10.
- All five new signals ride **one** filter pass alongside the existing
  `signalstats`, confirming the plan's "signals must ride existing passes"
  constraint is achievable. `edgedetect` must stay separate because it rewrites
  frames into an edge map rather than attaching metadata.
