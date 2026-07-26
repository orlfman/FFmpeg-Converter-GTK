#!/usr/bin/env python3
"""
corpus-report.py — turn Phase 0 measurements into threshold recommendations.

Reads the CSVs produced by analyze-corpus.py and answers the questions the
quality-solver work is blocked on:

  1. Degradation      — where do the `block`/`blur` cut points sit, and does
                        `block` actually separate clean from damaged sources?
  2. Grain            — what should GRAIN_SYNTH_LOW/HIGH be?  The values in
                        smart-optimizer-logic.vala are marked PROVISIONAL
                        because they were only ever calibrated against clean
                        digital sources.
  3. Content classes  — do the classifier's inputs (edge, saturation, motion)
                        actually separate anime / live-action / screencast?
  4. VMAF curve shape — is VMAF-vs-CRF linear, and does a logit transform
                        linearize the saturation near 100?
  5. Fit economy      — the plan asserts "3 base points plus verification
                        should suffice" where size needs 4-6.  With a 5-point
                        ladder we can fit on 3 and predict the other 2, which
                        turns that assertion into a measurement.
  6. Intent mapping   — what CRF does each intent's VMAF target imply, per
                        content class?

Usage:
    ./corpus-report.py --out /mnt/storage3/testvideos/corpus-out
"""

import argparse
import csv
import json
import math
import statistics
from pathlib import Path

# Provisional intent targets from the plan; the report tests them against data.
INTENT_TARGETS = {"Low": 88.0, "Medium": 92.0, "High": 95.0, "Ultra": 97.0}

# Current production constants, for comparison against what the corpus says.
CURRENT_GRAIN_LOW = 0.0015
CURRENT_GRAIN_HIGH = 0.0040


def load(path):
    if not path.exists():
        return []
    with open(path, newline="") as fh:
        return list(csv.DictReader(fh))


def num(row, key, default=0.0):
    try:
        return float(row.get(key, "") or default)
    except (TypeError, ValueError):
        return default


# Files whose true content differs from what the filename suggests. Verified
# by eye, not inferred: random-testvid3 is a fast-cut anime opening that was
# originally filed under the generic "random" prefix.
CONTENT_CORRECTIONS = {
    "random-testvid3.webm": "anime",       # fast-cut opening
    "random-testvid0.webm": "live-action",  # aerial, jet against sky
    "random-testvid1.webm": "live-action",  # poolside phone video
}


def classify(name):
    """Coarse content label from the corpus filename convention."""
    if name in CONTENT_CORRECTIONS:
        return CONTENT_CORRECTIONS[name]
    n = name.lower()
    if "anime" in n:
        return "anime"
    if "screencast" in n:
        return "screencast"
    if "movie" in n or "tvshow" in n or "short" in n:
        return "film/tv"
    if "women" in n or "musicvideo" in n:
        return "live-action"
    return "misc"


def hdr_label(row):
    t = (row.get("color_transfer") or "").lower()
    if t in ("smpte2084", "arib-std-b67"):
        return "HDR"
    return "SDR"


def rule(title):
    print()
    print("=" * 78)
    print(title)
    print("=" * 78)


def logit(v, lo=1e-6):
    """logit(vmaf/100), clamped away from the asymptotes."""
    p = min(max(v / 100.0, lo), 1.0 - lo)
    return math.log(p / (1.0 - p))


def fit_quadratic(xs, ys):
    """Least squares y = a + b*x + c*x^2.  Returns (a,b,c) or None."""
    n = len(xs)
    if n < 3:
        return None
    sx = sum(xs); sx2 = sum(x * x for x in xs)
    sx3 = sum(x ** 3 for x in xs); sx4 = sum(x ** 4 for x in xs)
    sy = sum(ys); sxy = sum(x * y for x, y in zip(xs, ys))
    sx2y = sum(x * x * y for x, y in zip(xs, ys))
    m = [[n, sx, sx2, sy], [sx, sx2, sx3, sxy], [sx2, sx3, sx4, sx2y]]
    for col in range(3):
        piv = max(range(col, 3), key=lambda r: abs(m[r][col]))
        if abs(m[piv][col]) < 1e-12:
            return None
        m[col], m[piv] = m[piv], m[col]
        for r in range(col + 1, 3):
            f = m[r][col] / m[col][col]
            for k in range(col, 4):
                m[r][k] -= f * m[col][k]
    c = m[2][3] / m[2][2]
    b = (m[1][3] - m[1][2] * c) / m[1][1]
    a = (m[0][3] - m[0][1] * b - m[0][2] * c) / m[0][0]
    return a, b, c


def fit_linear(xs, ys):
    n = len(xs)
    if n < 2:
        return None
    sx = sum(xs); sy = sum(ys)
    sxx = sum(x * x for x in xs); sxy = sum(x * y for x, y in zip(xs, ys))
    den = n * sxx - sx * sx
    if abs(den) < 1e-12:
        return None
    b = (n * sxy - sx * sy) / den
    a = (sy - b * sx) / n
    return a, b


def rmse(pred, actual):
    if not pred:
        return 0.0
    return math.sqrt(sum((p - a) ** 2 for p, a in zip(pred, actual)) / len(pred))


# ── Report sections ──────────────────────────────────────────────────────────

def report_signals(rows):
    rule("1. SIGNAL OVERVIEW")
    hdr = (f"{'file':<30}{'class':<12}{'kbps':>7}{'block':>8}{'blur':>7}"
           f"{'tout':>9}{'si':>7}{'ti':>7}{'edge':>7}{'cuts':>6}")
    print(hdr)
    print("-" * len(hdr))
    for r in sorted(rows, key=lambda x: num(x, "source_kbps")):
        print(f"{r['file'][:29]:<30}{classify(r['file']):<12}"
              f"{num(r,'source_kbps'):>7.0f}"
              f"{num(r,'block_mean'):>8.3f}{num(r,'blur_mean'):>7.2f}"
              f"{num(r,'tout_mean'):>9.5f}{num(r,'si_mean'):>7.1f}"
              f"{num(r,'ti_mean'):>7.1f}{num(r,'edge_mean'):>7.2f}"
              f"{int(num(r,'cut_count')):>6}")


def report_degradation(rows):
    rule("2. DEGRADATION SIGNAL  (block / blur vs source bitrate)")
    print("Hypothesis: `block` rises as sources get more compressed.")
    print("`blur` is expected to be content-confounded (optical softness reads")
    print("the same as compression softness), so it is reported but not trusted.\n")

    # Bitrate is only meaningful per-pixel; normalise so 4K and 360p compare.
    enriched = []
    for r in rows:
        w, h, fps = num(r, "width"), num(r, "height"), num(r, "fps")
        kbps = num(r, "source_kbps")
        bpp = (kbps * 1000.0) / (w * h * fps) if w and h and fps else 0.0
        enriched.append((bpp, r))
    enriched.sort()

    print(f"{'file':<30}{'bpp':>9}{'block':>8}{'blur':>7}{'verdict':>14}")
    print("-" * 68)
    for bpp, r in enriched:
        # bpp under ~0.02 is squarely in "starved" territory for any codec.
        verdict = "degraded" if bpp < 0.02 else ("marginal" if bpp < 0.05 else "clean")
        print(f"{r['file'][:29]:<30}{bpp:>9.4f}{num(r,'block_mean'):>8.3f}"
              f"{num(r,'blur_mean'):>7.2f}{verdict:>14}")

    # ── Matched pairs: same frames, only damage varies ──────────────────────
    paired = [r for r in rows if r.get("deg_block_mean")]
    if not paired:
        print("\n  (no matched-pair data — re-run with --degrade-probe)")
        return

    print()
    print("MATCHED PAIRS — identical frames, only compression varies.")
    print("This is the only content-independent read on each signal.\n")
    print(f"{'file':<30}{'block':>8}{'→deg':>8}{'Δ':>8}"
          f"{'blur':>8}{'Δblur':>8}{'Δtout':>10}")
    print("-" * 80)
    d_block, d_blur = [], []
    for r in sorted(paired, key=lambda x: x["file"]):
        db = num(r, "delta_block_mean")
        dl = num(r, "delta_blur_mean")
        d_block.append(db); d_blur.append(dl)
        print(f"{r['file'][:29]:<30}{num(r,'block_mean'):>8.3f}"
              f"{num(r,'deg_block_mean'):>8.3f}{db:>+8.3f}"
              f"{num(r,'blur_mean'):>8.2f}{dl:>+8.2f}"
              f"{num(r,'delta_tout_mean'):>+10.5f}")
    print("-" * 80)
    print(f"  Δblock: mean={statistics.fmean(d_block):+.3f}  "
          f"min={min(d_block):+.3f}  max={max(d_block):+.3f}  "
          f"consistent={'YES' if min(d_block) > 0 else 'NO'}")
    print(f"  Δblur : mean={statistics.fmean(d_blur):+.3f}  "
          f"min={min(d_blur):+.3f}  max={max(d_blur):+.3f}  "
          f"consistent={'YES' if min(d_blur) > 0 else 'NO'}")

    # The production question: can an ABSOLUTE threshold work?  Production sees
    # one source with no clean reference, so a relative signal is only usable
    # if clean and damaged populations happen not to overlap.
    print()
    print("ABSOLUTE SEPARABILITY (what production can actually use):")
    clean_vals = [num(r, "block_mean") for r in paired]
    deg_vals = [num(r, "deg_block_mean") for r in paired]
    print(f"  clean    block: {min(clean_vals):.3f} … {max(clean_vals):.3f}")
    print(f"  degraded block: {min(deg_vals):.3f} … {max(deg_vals):.3f}")
    gap = min(deg_vals) - max(clean_vals)
    if gap > 0:
        print(f"  → SEPARABLE by an absolute cut point ≈ "
              f"{(min(deg_vals)+max(clean_vals))/2:.3f} (gap {gap:.3f})")
        print("    Production can threshold `block` directly.")
    else:
        print(f"  → POPULATIONS OVERLAP by {-gap:.3f}.")
        print("    An absolute `block` threshold WILL misclassify.  Production")
        print("    has no clean reference to diff against, so `block` must be")
        print("    normalised by a content proxy (edge/si) or combined with")
        print("    source bpp rather than thresholded raw.")
        # Test the normalisation idea directly.
        print()
        print("  Normalisation candidates (clean vs degraded ranges):")
        for label, key in (("block/si", "si_mean"), ("block/edge", "edge_mean")):
            cn, dg = [], []
            for r in paired:
                base = num(r, key)
                dbase = num(r, f"deg_{key}") or base
                if base > 0:
                    cn.append(num(r, "block_mean") / base)
                if dbase > 0:
                    dg.append(num(r, "deg_block_mean") / dbase)
            if cn and dg:
                g = min(dg) - max(cn)
                verdict = f"SEPARABLE (gap {g:+.4f})" if g > 0 \
                    else f"overlap {-g:.4f}"
                print(f"    {label:<12} clean {min(cn):.4f}…{max(cn):.4f}   "
                      f"deg {min(dg):.4f}…{max(dg):.4f}   {verdict}")


def report_grain(rows):
    rule("3. GRAIN THRESHOLDS  (TOUT)")
    print(f"Current production: LOW={CURRENT_GRAIN_LOW}  HIGH={CURRENT_GRAIN_HIGH}")
    print("(marked PROVISIONAL — only ever seen clean digital + synthetic grain)\n")
    ordered = sorted(rows, key=lambda r: num(r, "tout_mean"))
    print(f"{'file':<30}{'class':<12}{'tout':>10}{'tout_p95':>10}{'vs current':>14}")
    print("-" * 76)
    for r in ordered:
        t = num(r, "tout_mean")
        band = ("clean" if t <= CURRENT_GRAIN_LOW else
                "grainy" if t >= CURRENT_GRAIN_HIGH else "ambiguous")
        print(f"{r['file'][:29]:<30}{classify(r['file']):<12}{t:>10.5f}"
              f"{num(r,'tout_p95'):>10.5f}{band:>14}")

    vals = [num(r, "tout_mean") for r in rows]
    amb = [v for v in vals if CURRENT_GRAIN_LOW < v < CURRENT_GRAIN_HIGH]
    print()
    print(f"  {len(amb)}/{len(vals)} files land in the ambiguous band, where the")
    print("  decision falls through to the content-category heuristic.")
    if len(amb) > len(vals) * 0.4:
        print("  → Band is TOO WIDE: most of the corpus is undecided, so the")
        print("    measurement rarely overrides the category guess.")


def report_content(rows):
    rule("4. CONTENT-CLASS SEPARATION  (classifier inputs)")
    print("classify_content() keys off edge density, saturation spread, and motion.\n")
    by_class = {}
    for r in rows:
        by_class.setdefault(classify(r["file"]), []).append(r)
    print(f"{'class':<14}{'n':>3}{'edge':>9}{'satavg':>9}{'ydif':>8}"
          f"{'si':>8}{'ti':>8}{'tout':>10}")
    print("-" * 70)
    for cls, rs in sorted(by_class.items()):
        def avg(k):
            return statistics.fmean([num(r, k) for r in rs]) if rs else 0.0
        print(f"{cls:<14}{len(rs):>3}{avg('edge_mean'):>9.2f}"
              f"{avg('satavg_mean'):>9.2f}{avg('ydif_mean'):>8.2f}"
              f"{avg('si_mean'):>8.1f}{avg('ti_mean'):>8.1f}"
              f"{avg('tout_mean'):>10.5f}")


def report_sweep(sweep_rows, signal_rows):
    if not sweep_rows:
        rule("5-7. VMAF SWEEP")
        print("No sweep.csv rows yet — run --stage sweep.")
        return

    sig_by_file = {r["file"]: r for r in signal_rows}
    by_file = {}
    for r in sweep_rows:
        by_file.setdefault(r["file"], []).append(r)
    for pts in by_file.values():
        pts.sort(key=lambda r: num(r, "crf"))

    rule("5. VMAF-vs-CRF CURVE SHAPE  (raw vs logit)")
    print("If logit linearizes VMAF's saturation near 100, the logit fit should")
    print("show a materially lower residual than the raw-linear fit.\n")
    print(f"{'file':<30}{'pts':>4}{'vmaf range':>16}{'lin RMSE':>10}"
          f"{'logit RMSE*':>12}{'quad RMSE':>11}")
    print("-" * 84)
    lin_tot, logit_tot, quad_tot = [], [], []
    for f, pts in sorted(by_file.items()):
        xs = [num(p, "crf") for p in pts]
        vs = [num(p, "vmaf_mean") for p in pts]
        if len(xs) < 3 or not all(vs):
            continue
        lin = fit_linear(xs, vs)
        lin_r = rmse([lin[0] + lin[1] * x for x in xs], vs) if lin else float("nan")

        ls = [logit(v) for v in vs]
        lg = fit_linear(xs, ls)
        # Report the logit residual back in VMAF points so it is comparable.
        if lg:
            pred_v = [100.0 / (1.0 + math.exp(-(lg[0] + lg[1] * x))) for x in xs]
            logit_r = rmse(pred_v, vs)
        else:
            logit_r = float("nan")

        q = fit_quadratic(xs, vs)
        quad_r = rmse([q[0] + q[1] * x + q[2] * x * x for x in xs], vs) \
            if q else float("nan")

        lin_tot.append(lin_r); logit_tot.append(logit_r); quad_tot.append(quad_r)
        print(f"{f[:29]:<30}{len(xs):>4}{min(vs):>7.1f}-{max(vs):<8.1f}"
              f"{lin_r:>10.3f}{logit_r:>12.3f}{quad_r:>11.3f}")
    if lin_tot:
        print("-" * 84)
        print(f"{'MEAN':<30}{'':>4}{'':>16}{statistics.fmean(lin_tot):>10.3f}"
              f"{statistics.fmean(logit_tot):>12.3f}"
              f"{statistics.fmean(quad_tot):>11.3f}")
        print("\n  * logit RMSE is converted back to VMAF points for comparison.")
        best = min([("linear", statistics.fmean(lin_tot)),
                    ("logit-linear", statistics.fmean(logit_tot)),
                    ("quadratic", statistics.fmean(quad_tot))], key=lambda t: t[1])
        print(f"  → lowest mean residual: {best[0]} ({best[1]:.3f} VMAF points)")

    rule("6. FIT ECONOMY  (does a 3-point ladder suffice?)")
    print("Fit on 3 points, predict the held-out points, measure the error.")
    print("The plan asserts 3 + verification is enough where size needs 4-6.\n")
    print(f"{'file':<30}{'held out':>10}{'predicted':>11}{'actual':>9}{'err':>8}")
    print("-" * 70)
    errs = []
    for f, pts in sorted(by_file.items()):
        xs = [num(p, "crf") for p in pts]
        vs = [num(p, "vmaf_mean") for p in pts]
        if len(xs) < 5 or not all(vs):
            continue
        # Fit on first, middle, last; hold out index 1 and 3.
        idx_fit = [0, len(xs) // 2, len(xs) - 1]
        idx_out = [i for i in range(len(xs)) if i not in idx_fit]
        fx = [xs[i] for i in idx_fit]
        fy = [logit(vs[i]) for i in idx_fit]
        q = fit_quadratic(fx, fy)
        if not q:
            continue
        for i in idx_out:
            lv = q[0] + q[1] * xs[i] + q[2] * xs[i] ** 2
            pred = 100.0 / (1.0 + math.exp(-lv))
            err = pred - vs[i]
            errs.append(abs(err))
            print(f"{f[:29]:<30}{('crf %d' % xs[i]):>10}{pred:>11.2f}"
                  f"{vs[i]:>9.2f}{err:>+8.2f}")
    if errs:
        print("-" * 70)
        print(f"  mean |error| = {statistics.fmean(errs):.3f} VMAF points, "
              f"max = {max(errs):.3f}")
        if statistics.fmean(errs) < 0.5:
            print("  → 3 points is SUFFICIENT (sub-0.5 VMAF prediction error).")
        elif statistics.fmean(errs) < 1.0:
            print("  → 3 points is marginal; 4 recommended for High/Ultra.")
        else:
            print("  → 3 points is NOT enough; use 4-5.")

    rule("7. INTENT → CRF MAPPING  (per file, per intent)")
    print("CRF required to hit each intent's VMAF target on this source.")
    print("Spread across content classes is what the bias must adapt to.\n")
    names = list(INTENT_TARGETS)
    print(f"{'file':<30}{'class':<12}" + "".join(f"{n:>9}" for n in names))
    print("-" * (42 + 9 * len(names)))
    per_class = {}
    for f, pts in sorted(by_file.items()):
        xs = [num(p, "crf") for p in pts]
        vs = [num(p, "vmaf_mean") for p in pts]
        if len(xs) < 3 or not all(vs):
            continue
        q = fit_quadratic(xs, [logit(v) for v in vs])
        if not q:
            continue
        cls = classify(f)
        cells = []
        for n in names:
            tgt = logit(INTENT_TARGETS[n])
            a, b, c = q[0] - tgt, q[1], q[2]
            crf = None
            if abs(c) < 1e-12:
                if abs(b) > 1e-12:
                    crf = -a / b
            else:
                disc = b * b - 4 * c * a
                if disc >= 0:
                    r1 = (-b + math.sqrt(disc)) / (2 * c)
                    r2 = (-b - math.sqrt(disc)) / (2 * c)
                    cands = [r for r in (r1, r2) if min(xs) - 8 <= r <= max(xs) + 8]
                    crf = min(cands, key=lambda r: abs(r - statistics.fmean(xs))) \
                        if cands else None
            if crf is None:
                cells.append(f"{'--':>9}")
            else:
                cells.append(f"{crf:>9.1f}")
                per_class.setdefault((cls, n), []).append(crf)
        print(f"{f[:29]:<30}{cls:<12}" + "".join(cells))

    if per_class:
        print()
        print("Per-class mean CRF for each intent:")
        print(f"{'class':<14}" + "".join(f"{n:>9}" for n in names))
        print("-" * (14 + 9 * len(names)))
        classes = sorted({c for c, _ in per_class})
        for cls in classes:
            row = ""
            for n in names:
                vals = per_class.get((cls, n), [])
                row += f"{statistics.fmean(vals):>9.1f}" if vals else f"{'--':>9}"
            print(f"{cls:<14}{row}")
        print()
        print("  A wide spread ACROSS classes at the same intent is the whole")
        print("  argument for the solver: a fixed 'High = CRF 20' table cannot")
        print("  serve content whose required CRF differs by several points.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="corpus-out folder")
    args = ap.parse_args()
    out = Path(args.out).expanduser().resolve()

    signals = load(out / "signals.csv")
    sweep = load(out / "sweep.csv")
    if not signals:
        raise SystemExit(f"no signals.csv in {out}")

    print(f"Phase 0 corpus report — {len(signals)} files, {len(sweep)} sweep points")
    report_signals(signals)
    report_degradation(signals)
    report_grain(signals)
    report_content(signals)
    report_sweep(sweep, signals)
    print()


if __name__ == "__main__":
    main()
