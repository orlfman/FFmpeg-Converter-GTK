# Quality Mode — Broken VMAF Measurement Findings

> **Status:** confirmed bug, root cause NOT yet identified. Investigated
> 2026-07-30 against `e3862ad` + uncommitted quality-ceiling work.
>
> **Not caused by the Crop & Trim quality-ceiling fix.** That change only
> routes to `optimize_for_quality`, which is where the defect lives — so the
> codec tab's own Quality Ceiling button is affected identically.
>
> **Prevalence: low.** By the maintainer's estimate roughly 90% of real
> conversions are unaffected, which is why this is parked rather than urgent.
> It is not rare enough to ignore, though — when it fires it is silent and
> writes files several times larger than intended.

## Symptom

Three-segment Crop & Trim export, SVT-AV1, Quality Ceiling = Ultra (VMAF 97),
4K source downscaled to 2112x1188 via `zscale ... 0.55`.

| Segment | Start | Measured curve (CRF → VMAF) | Solved | Output |
| --- | --- | --- | --- | --- |
| 1 | 00:00:00 | 18→98.56, 28→97.58, 38→96.03 | CRF 33 | 76 MB, healthy |
| 2 | 00:02:34 | 18→**63.49**, 28→63.42, 38→63.23 | CRF **10** | **644 MB @ 33.5 Mbps** |
| 3 | 00:05:12 | 18→**80.28**, 28→80.22, 38→79.98 | CRF **10** | **1031 MB @ 35.5 Mbps** |

Source is 17.7 Mbps. Segments 2 and 3 were re-encoded at roughly **twice the
source bitrate** after a 45% downscale.

Two independent tells that the measurement — not the content — is wrong:

1. **The curve is flat.** VMAF moves &lt;0.4 across a 20-point CRF range. A real
   measurement moves several points (segment 1 moves 2.5).
2. **The level is impossible.** CRF 18 on this material does not score 63.

The solver behaved *correctly given its inputs*: unable to reach 97, it walked
CRF to the codec floor of 10 and reported "Codec minimum CRF still measured
VMAF 63.55". The reporting is sound; the number feeding it is garbage.

## Ground truth

Segment 2's content, measured by hand at CRF 18:

- Contiguous 8s clip, FFV1 reference: **99.74**
- 3 × 8s concat-sampled reference (mirrors the optimizer): **98.37**

The app reported **63.49** for the same content.

## Minimal reproduction

Confirmed 2026-07-30: **a single segment reproduces it**, no multi-segment
export needed.

```
Source:  <4K gymnastics webm>, 17.7 Mbps
Segment: 00:02:34.287 → 00:05:11.878   (duration 2:37.591)
Setup:   SVT-AV1, Quality Ceiling = Ultra, downscale 0.55, Export as Separate Files
```

The probe values came back **bit-for-bit identical** to the same range in the
three-segment run — 63.49 / 63.42 / 63.23, then 63.55 after refinement. The
defect is fully deterministic, not a race or a resource-pressure artefact.

Each probe takes ~40s, so the whole failing analysis reproduces in about three
minutes.

**Do not shorten the segment to speed this up.** An 8-second clip taken from
the same start timestamp measures *correctly* (99.74). Whatever is wrong scales
with segment length or sample count, so a trimmed repro will look healthy and
prove nothing.

## The constraint that narrows the search

This is the most useful single observation, and it was not obvious at first:

> At **CRF 10** SVT-AV1 is essentially transparent. That probe must score ~99.
> It scored **63.55**, while CRF 38 scored **63.23** — a 28-point CRF swing
> moving the result by 0.32.

Compression cannot produce that. The only way a near-lossless encode scores 63
against its own source is if **libvmaf is pairing the wrong frames**.

So this is a *frame-alignment* defect, not a quality-measurement tuning
problem. Anything that does not change which frames get compared is not the
fix — which is what makes the ruled-out list below cheap to trust.

## Ruled out by direct reproduction

Each of these was tested and reproduced a healthy ~98, so **do not re-investigate**:

| Hypothesis | Result |
| --- | --- |
| Non-zero start PTS on the stream-copied temp segment | Both seg 1 and seg 2 temp files report `start_time=0.000000`. The `start 0.126000` seen in the log is on the *final* encode, a different command. |
| Concat sampling of 3 × 8s positions misaligning frames | 98.37 |
| Video filter chain applied twice (double downscale) | `build_intermediate_probe_cmd` (`smart-optimizer.vala:4679`) adds no filters — clean |
| SVT-AV1 film grain synthesis penalising VMAF | film-grain=0 → 98.37, =8 → 98.14, =15 → 97.72 |
| `sharpness=2` from `active_tuning` | included in all runs above |
| Intermediate codec: x264 `-qp 0` (8-bit path, per the note at `:237`) vs FFV1 | identical, 98.37 |

## Structural notes gathered

- `calibration_probe_with_vmaf` (`:4255`) encodes **from** `intermediate_path`
  and measures the result **against** that same file, so distorted and
  reference share one origin. Structurally sound.
- `measure_vmaf` (`:4132`) builds `[0:v][1:v]libvmaf=...` with **no
  `setpts=PTS-STARTPTS`** on either input. libvmaf's framesync pairs by
  timestamp. Not proven to be the cause here, but it is real fragility worth
  hardening regardless.
- `ensure_intermediate` (`:2056`) is forced in Quality Mode precisely because
  it must match the distorted input's resolution and frame rate.

## Diagnose before fixing

One datum decides between the candidates below: **do the intermediate and the
probe encode contain the same number of frames?**

That evidence is currently destroyed every run — `cleanup_file (tmp)` and
`cleanup_temp_run_dir` remove both artefacts on the way out. Temporarily retain
them for a failing segment, then compare:

```sh
ffprobe -v error -count_frames -select_streams v:0 \
        -show_entries stream=nb_read_frames -of csv=p=0 <intermediate>
ffprobe -v error -count_frames -select_streams v:0 \
        -show_entries stream=nb_read_frames -of csv=p=0 <probe output>
# plus first/last PTS of each
```

A mismatch confirms the alignment hypothesis outright. Everything below is
guesswork until that number is known, so do this first.

## Candidate fixes, cheapest first

**1. Force CFR when building the intermediate — prime suspect.**
There is **no `-fps_mode`, no `-vsync`, and no explicit `-r` anywhere in
`smart-optimizer.vala`.** The intermediate is a concat of three `-ss` seeks
into a stream-copied AV1 segment, which is exactly the setup that produces
irregular timestamps. Without CFR pinned, ffmpeg can drop or duplicate frames
differently when decoding the reference than when encoding the probe — and one
dropped frame misaligns everything after it.

This also explains the segment-1 exception: it starts at 00:00:00, so its
stream copy begins on a clean keyframe with regular timestamps.

**2. Normalise timestamps on both VMAF inputs.**
`measure_vmaf` builds `[0:v][1:v]libvmaf=...` with no preprocessing, and
libvmaf's framesync pairs by timestamp. The standard hardening:

```
[0:v]setpts=PTS-STARTPTS[dist];[1:v]setpts=PTS-STARTPTS[ref];[dist][ref]libvmaf=...
```

There is in-repo precedent — the collage command already applies
`setpts=PTS-STARTPTS` to every input. Worth doing regardless of root cause.

**3. Verify frame counts before trusting a probe.**
After the probe encode, compare its frame count against the intermediate's. On
mismatch return `vmaf_measured = false` rather than recording the point. Turns
a silently wrong number into a visibly missing one.

**4. Sanity-bound the ladder.**
The lowest CRF probed must score near-transparent. If it does not, the
measurement rig is broken rather than the content — fail the run instead of
solving against nonsense. **This is the check that would have caught it on the
first probe line**, and it is the highest-value item here if only one gets done.

Suggested order: diagnostic → **1** → **2**, with **3** and **4** as the
permanent safety net. Keep 3 and 4 even after the root cause is fixed; they
convert this whole class of failure from *expensive and silent* into
*immediate and obvious*.

## Related: the flat-curve export guard

Console progress (shipped) makes the flat curve visible about two minutes in,
but **does not stop the export** — the 644 MB write still happened. The trim
path drops a segment only when `rec.is_impossible`, and a flat curve is not
flagged impossible: the solver genuinely found the best CRF available given its
inputs, so it reports success.

A guard treating "solved at the codec floor **and** near-zero VMAF variance
across the ladder" as a failed measurement would make this fail safe. It
overlaps candidate 4 above — same detection, applied at the segment-skip level
rather than the run level. Deliberately deferred, 2026-07-30.

## Interim guidance

Quality Ceiling results are not trustworthy on this source. When a curve comes
back flat, or a solve lands on the codec floor with a large predicted size,
treat it as a failed measurement rather than a real answer.
