# Smart Optimizer — Battle Plan v2 (Quality Solver)

> **Implementation status** (see also `smart-optimizer-phase0-findings.md`):
> Phase 0 ✅ · Phase 1 ✅ · Phase 2 ✅ · Phase 3 ✅ (three axes shipped)
> · Phase 4 ⬜ · Phase 5 partial (screencast done; anime offset still lacks
> perceptual data) · Phase 6 ⬜
>
> Corrections the data forced on this plan: the fit is a **plain quadratic on
> raw VMAF**, not logit; the Phase 4a degradation guard is **not implementable
> as specified** and is recommended for removal; the Content axis turned out to
> be **load-bearing**, not a convenience, because the classifier cannot detect
> animation at all.

## Mission Statement

Smart Optimizer already does one thing extremely well: **pin a size, measure this
specific video, solve for the CRF that lands there.** Size reduction, arbitrary
targets, inflation, and match-source are all the same operation with a different
number in `target_mb`.

The goal now is the second half of that idea: **pin a quality, let size float,
solve for the CRF that achieves it on this specific source.**

Not a rule table that says "High = CRF 20." A measurement that says *this grainy
4K master needs CRF 18 to reach VMAF 95, and that clean anime reaches it at CRF
26.* Same solver, same probe encodes, same curve fit, same cache, same confidence
model — the only change is which axis is the constraint and which is the readout.

**Every run reports both numbers.** The user picks which one they're pinning.

> Target: 50 MB → **CRF 24 · est. VMAF 93**
> Target: VMAF 95 → **CRF 21 · est. 78 MB**

The static preset tables are replaced because they cannot be tailored to
anything. Power users who want fixed settings configure the encoder manually.

---

## Core Architectural Principle

There is **one pipeline with a swappable objective function**, not two modes.

```
probe → analyze → sample → calibrate ─┬─ solve for size   → CRF
                                      └─ solve for quality → CRF
                                              ↓
                              verify → recommend (size + quality + why)
```

Everything upstream of the solve is shared. Everything downstream of the solve is
shared. If the implementation ever needs `if (bias_mode)` inside
`apply_smart_x264()`, the abstraction is wrong.

**Prerequisite confirmed:** ffmpeg 8.1.2 on this machine is built
`--enable-libvmaf` with the full model set in `/usr/share/model/`
(`vmaf_v0.6.1`, `vmaf_4k_v0.6.1`, NEG variants), plus `xpsnr` and `ssim` as
cheaper fallbacks.

---

## Phase 0 — Corpus & Instrumentation *(new; must come first)*

The current code already carries the warning sign: `GRAIN_SYNTH_LOW/HIGH` is
commented *"PROVISIONAL — calibrated only against clean/digital sources."* One
uncalibrated threshold already drives a real decision. This plan adds a VMAF
target scale plus several new signals — that's a dozen more magic numbers. Set
them from data or the "strong bias" will be strong in an arbitrary direction,
which is worse than the static presets it replaces.

- Add `DevTools/analyze-corpus.sh` (or a hidden `--analyze-only` mode): run the
  signal pass over a folder, emit one CSV row per file with every metric.
- Add a VMAF-vs-CRF sweep dumper: for each corpus file, encode a few CRFs and
  record `(crf, size, vmaf, xpsnr)`. This is the data that sets the intent→VMAF
  mapping and tells you how linear the curve actually is.
- Collect the matrix now, not in Phase 6: clean masters / heavily compressed /
  anime / live-action / screencast / high motion / static / grainy / clean /
  HDR / SDR.

Deliverable: a CSV you can eyeball. Every threshold in Phases 3–5 cites it.

---

## Phase 1 — Decouple the Pipeline from `SizeTier`

`SizeTier` is currently load-bearing in places that have nothing to do with size.
All four `apply_smart_*` functions in `codec-presets.vala` are 5-arm
`switch (rec.size_tier)` blocks setting ref frames, psy-rd, deblock, lookahead,
qm, arnr. A quality-mode run has no tier, and forking those four functions would
double the most bug-prone file in the project.

1. Introduce a **derived effort/quality level** on `OptimizationRecommendation` —
   the single axis `apply_smart_*` switches on. Size Mode computes it from
   `SizeTier`; Quality Mode computes it from intent. Neither downstream function
   learns which mode ran.
2. Split `OptimizationRecommendation` reporting fields so both numbers are always
   present: `estimated_size_kib` *and* `estimated_vmaf` (+ `vmaf_measured` flag),
   plus which axis was pinned.
3. Audit every `size_tier` read outside the solver. `configure_smart_audio` is
   the notable one — it picks audio purely by tier, so Quality Mode needs an
   explicit intent→audio mapping or Ultra silently inherits a guess.
4. Extract the least-squares core out of `fit_quadratic_log_curve` so it can be
   fed a different y-transform. Phase 2 needs the identical 3×3 solve against a
   non-log y.

**Exit criteria:** Size Mode behaves *bit-identically* to today, with the tier
switch replaced by the new level. This phase ships no user-visible change.
Existing `smart-optimizer-logic-test.vala` coverage must pass untouched.

---

## Phase 2 — The Quality Solver

The core of the work.

**Measurement.** During calibration, every probe encode already produces a file.
Run libvmaf against it and record `(crf → size, vmaf)` as a tuple. Size Mode gets
its quality readout nearly free from the same pass.

**Reference source.** This is where v13 pays off unexpectedly: the lossless
filtered intermediate built for filtered runs is *exactly* the right VMAF
reference. libvmaf requires matching resolution and frame rate, so when a
scale/crop chain is active you must compare against the filtered source, not the
original. Extend intermediate construction to cover the quality path, and be
explicit in the notes that VMAF then measures **encode fidelity, not downscale
loss**.

**The fit.** VMAF is bounded [0,100] and saturates near the top, so a raw linear
fit will badly overshoot at high targets. Fit `logit(vmaf/100)` against CRF
(clamp inputs to ≤99.5), reusing the extracted least-squares core. VMAF-vs-CRF is
far better behaved than size-vs-CRF — less curvature, less content dependence —
so **3 base points plus verification should suffice** where size needs 4–6.
Confirm against the Phase 0 sweep.

**The solve.** `solve_crf_from_curve` against a target VMAF instead of a target
size. Reuse extrapolation-distance and RMSE-based confidence unchanged.

**Cost control** (in priority order): reuse existing probe encodes rather than
adding passes; `n_threads` on libvmaf; skip VMAF on probes far from the predicted
answer; keep `xpsnr` wired as a fallback if 4K proves too slow.

**Cache.** ✅ *Implemented.* `smart-optimizer-cache.vala` entries now hold VMAF
alongside size, serialised as a third array element only when measured — so
size-only runs still write the old 2-element shape and old stores still load.
`lookup_with_vmaf` deliberately MISSES on a size-only sample: without a score
the quality solver would still have to encode the probe, so there is nothing to
save. A later size-only write preserves any score already measured.

Measured on a 1080p source (x265, High):

| run | elapsed | note |
|---|---|---|
| cold | 199.9 s | 3 probes + verification |
| warm, base points only | 75.2 s | verification still re-probed |
| warm, verification reused | 34.2 s | **5.8× faster**, identical answer |
| warm, reference built lazily | 33.1 s | reference never built |

**Preset stays in the key and that is correct** — changing intent changes the
preset, and a different preset genuinely produces different sizes *and*
different scores, so reuse across intents would be wrong. Confirmed live:
switching High→Ultra correctly missed and re-measured.

The reference is now built **lazily, on the first cache miss**, since a fully
cached re-run needs no encoding at all. That mattered less than expected here
(~1 s) but is the single most expensive step at 4K.

The remaining ~33 s floor on a cached run is **content analysis**, not the
solver — two filter passes over the sample segments, shared with Size Mode.
That is the next thing to attack if quality-mode latency matters.

**No two-pass in Quality Mode.** Two-pass exists to hit a byte count.
CRF-with-a-measured-target is the entire point.

**Safety ceiling: 2× source size.** A pathological-case net, not a routine
constraint — the solver isn't blindly picking CRF 5, so this should rarely fire.
Design accordingly:

- It is a **post-solve clamp, not a second objective.** Solve for VMAF; if the
  estimated size exceeds the ceiling, raise CRF until it fits and report the
  quality actually achieved: *"couldn't reach VMAF 97 within 2× source; landed at
  94."* Never let the ceiling participate in the solve, or it becomes a competing
  target that fights the quality axis.
- **Use the windowed source size.** `match_source_target_mb_for_window` already
  solves this for Match Source Size — scale by duration fraction, or a 30-second
  trim of a 1 GB file gets a 2 GB ceiling that can never fire.
- **Composes with the 4a degradation guard, in order.** Degradation lowers the
  effective target *before* the solve; the ceiling clamps whatever is left
  *after*. Both fire on the same input (degraded source + high intent), so the
  notes must attribute the outcome to one cause, not blame both.

Realistic trigger cases for testing: heavily-compressed source at Ultra, and
codec downgrades (AV1 source → x264 at Ultra, where x264 needs far more bits for
the same VMAF).

**The multiplier is tunable and 2.0 is a placeholder.** Keep it as a named
constant (`QUALITY_MODE_MAX_SOURCE_MULTIPLIER`) in `smart-optimizer-logic.vala`
next to `GRAIN_SYNTH_LOW/HIGH` and `BPP_COMFORT_MULTIPLIER`, with the clamp
itself as a pure function covered by `smart-optimizer-logic-test.vala`. Because
it is a post-solve clamp, changing it cannot perturb any run that was already
landing under the ceiling — every result below the line stays byte-identical.
**Phase 0 sets the final value:** the corpus sweep already records
`(crf, size, vmaf)` per file, which shows directly how far Ultra pushes size
relative to source on real material. Pick a multiplier above the legitimate cases
and below the pathological ones.

Start with a single global number. Per-intent or per-degradation multipliers are
plausible later, but adding them before data shows they're needed is exactly the
magic-number proliferation Phase 0 exists to prevent. Likewise, leave it
hardcoded rather than exposing a Preferences knob until Phase 6 shows users
actually hit it — promoting a constant to an `AppSettings` value later is
mechanical, but every preference added is permanent.

---

## Phase 3 — Intent Axes & UI

The old list crams three orthogonal concepts into one dropdown. Split it:

**Quality intent** — the size-axis replacement, mutually exclusive, maps to VMAF
targets:

| Intent | Target | Meaning |
|---|---|---|
| Low | ~88 | Acceptable, size-conscious |
| Medium | ~92 | Good — default |
| High | ~95 | Visually near-transparent |
| Ultra | ~97 | Archival; beyond this is heavy diminishing returns |

Numbers provisional until Phase 0 data lands.

**Content** — `Auto / Live-action / Anime / Screencast`. Overrides
`profile.content_type`. This is what "Anime" always actually was: a content
assertion, not a quality tier. As an override it is correct by construction on
non-anime content.

**Delivery** — a composable toggle, not a list entry: fast-decode / low-latency /
compatibility. "Streaming + High" is a coherent request that a mutually-exclusive
list makes unexpressible.

**Imageboards** is a size target (≤4 MB) wearing a preset costume — it belongs in
Size Mode presets, not here.

**UI:** pinning quality disables the target-size controls and vice versa; the
result card always shows both numbers with the pinned one marked.

✅ **The static preset tables are gone.** They were initially kept as an instant
zero-analysis path, on the argument that Quality Mode costs minutes on a long
file where a table was instant. That was overridden: having two controls with
"Quality" in the name — a static `Quality Profile` dropdown directly above the
new `Quality Target` — was actively misleading, and produced exactly the
confusion you would predict (a user set the profile to Medium and got a 4 MB
size-targeted run, because the profile has nothing to do with the optimizer).

`apply_svt_av1`, `apply_x265`, `apply_x264` and `apply_vp9` are removed along
with the dropdown, taking `codec-presets.vala` from 1152 lines to 610. Users
wanting fixed settings configure the encoder directly, which is what the
mission statement said from the start.

---

## Phase 4 — Where the Content Signals Land

VMAF anchors the CRF. **Content analysis drives everything VMAF is blind to.**
The Phase-3-of-the-old-plan signals aren't redundant; they're the other half of
the decision.

**4a. Source degradation *(highest value)*.** `blockdetect` + `blurdetect` chain
directly into the existing `signalstats,…,metadata=print` pass — no extra decode,
no new infrastructure.

The failure mode this fixes is specific and non-obvious: **VMAF is measured
against the source, so on a damaged source the encoder spends real bits
faithfully reproducing blocking and mosquito noise to keep the score up.** The
guard is counterintuitive — on degraded sources, *lower* the effective VMAF
target, because some of the measured "loss" is you cleaning up artifacts, which
is an improvement the metric scores as damage.

**4b. Temporal complexity / cut density *(cheapest win — do it first).*** The
demux-only ffprobe packet pass already runs; keyframe positions and packet-size
variance fall out of it essentially free. `scdet` if more precision is needed.
Feeds lookahead/refs decisions, Streaming behaviour, sampling strategy, and Size
Mode confidence.

**4c. Spatial detail.** `siti` gives ITU-T P.910 spatial *and* temporal
information from one filter — two signals, one pass.

**4d. Noise character *(demote to last).*** TOUT alone cannot separate film grain
from sensor noise from mosquito noise. Doing it honestly needs
flat-region-vs-edge high-frequency comparison or a denoised-diff pass — a second
decode for the weakest payoff on the list.

**Hard constraint for this phase: new signals ride existing passes.** Analysis
already does two filter passes over N×8s segments plus a packet probe, then 4–6
probe encodes plus verification. Anything demanding its own pass justifies itself
against wall-clock.

**Decisions that stay rule-driven** (VMAF cannot see them): bit depth / banding →
10-bit; grain policy and synthesis strength; psy-rd and AQ strength; deblock;
delivery-constraint features.

---

## Phase 5 — Content-Aware Targets & Honest Limits

VMAF is trained on live-action. Ignoring that produces confidently wrong results
on exactly the content this app is used for.

- **Anime:** VMAF under-penalizes flat animation — expect a positive offset on
  the target. Size from Phase 0 data.
- **Screencast:** VMAF is close to meaningless on text and UI. Fall back to
  rule-based CRF with VMAF as a sanity *floor* only, and say so in the notes.
- **≥1080p:** evaluate `vmaf_4k_v0.6.1`; decide on NEG variants (they resist
  sharpening/enhancement gaming, generally the right choice for encoder
  decisions).
- **Two confidences, kept separate.** `assess_confidence` measures confidence in
  the *prediction* (extrapolation, coverage, RMSE). `profile.type_confidence`
  measures confidence in the *classification*. Only the second should make bias
  application more conservative. Conflating them will produce misleading notes.
- **Notes must explain the chain:** intent → target → measured curve → CRF, plus
  every guard that fired and why.

---

## Phase 6 — Validation

- Corpus from Phase 0, now used as a regression suite: does each intent hit its
  VMAF target within tolerance across all content classes?
- **Cross-mode sanity:** solve for size, then verify the reported VMAF matches an
  independent measurement of the real output. Same in reverse. The two solvers
  must agree about the same video.
- Blind A/B against what a knowledgeable user would pick manually for the same
  intent.
- Wall-clock regression: Quality Mode should be *faster* than Size Mode, not
  slower — fewer calibration points and no two-pass.

---

## What This Buys Size Mode

Not a side effect worth burying: **every size-targeted run can now report what
the target cost perceptually.** "You asked for 50 MB; that's VMAF 89." And the
match-source case finally answers the question it was always really asking —
*was the re-encode worth it?* "Same size in AV1, VMAF 97, visually identical"
versus "same size, VMAF 88, you lost something."

---

## Open Questions

1. Is VMAF fast enough on 4K probes, or does `xpsnr` become the default with VMAF
   as an opt-in? Phase 0 answers this.
2. Should preset stay in the cache key? Decoupling would make intent-switching
   much cheaper.
3. Screencast + Quality Mode has no good metric. Is rule-based-with-a-floor
   acceptable, or does that content type simply not offer Quality Mode?

## Resolved Decisions

- **Quality Mode size ceiling: 2× source** (windowed for trims), as a post-solve
  clamp that reports the quality actually achieved. See Phase 2.
