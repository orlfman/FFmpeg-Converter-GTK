#!/usr/bin/env python3
"""
analyze-corpus.py — Smart Optimizer Phase 0 instrumentation.

Runs the Smart Optimizer's content-analysis signals over a folder of source
videos and dumps them as CSV, plus an optional CRF→(size, VMAF) sweep.  The
output is the data that sets every threshold in the quality-solver work:
degradation, grain, temporal complexity, spatial detail, and the intent→VMAF
mapping itself.

Why this exists: the codebase already carries one uncalibrated threshold pair
(GRAIN_SYNTH_LOW/HIGH, commented "PROVISIONAL — calibrated only against
clean/digital sources").  The quality solver adds roughly a dozen more.  Set
them from measurements or the biases are strong in an arbitrary direction.

Design notes
------------
* Sample positions mirror SmartOptimizerLogic.pick_sample_positions so the
  measured values transfer directly to production rather than needing a
  translation step.
* Every file is reduced ONCE to a lossless reference holding the concatenated
  sample segments.  Both the signal passes and the CRF sweep then read that
  small file, so the source is decoded a single time and the signals describe
  exactly the frames the sweep encodes.
* All five new signals ride ONE filter pass alongside the existing signalstats,
  which is the same constraint the production analyzer must honour.

Usage
-----
    ./analyze-corpus.py --corpus /mnt/storage3/testvideos
    ./analyze-corpus.py --corpus DIR --stage signals      # skip the sweep
    ./analyze-corpus.py --corpus DIR --crfs 18,24,30,36 --codec libx265

Output (default ./corpus-out/):
    signals.csv   one row per file
    sweep.csv     one row per (file, crf)

Both are written incrementally and re-runs skip rows already present, so a long
run can be interrupted and resumed.
"""

import argparse
import csv
import json
import math
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

# ── Constants mirrored from SmartOptimizerLogic ──────────────────────────────
SEGMENT_DURATION = 8.0        # seconds per sample segment
MIN_COVERAGE_TARGET = 0.15    # 15% minimum sample coverage
BASE_MAX_SEGMENTS = 6         # < 10 min
LONG_MAX_SEGMENTS = 10        # 10–45 min
VLONG_MAX_SEGMENTS = 14       # > 45 min
LONG_VIDEO_THRESHOLD = 600.0
VLONG_VIDEO_THRESHOLD = 2700.0
SEGMENT_SPREAD = 0.15         # start at 15%, end at 85%
MIN_SEGMENTS = 2

# Lossless-reference budget.  A 4K file at 14×8s would need ~11 GB of lossless
# intermediate; production caps the same intermediate at 4 GiB, so the segment
# count is trimmed to fit rather than blowing up the disk.
DEFAULT_MAX_REF_BYTES = 4 * 1024**3
INTERMEDIATE_LOSSLESS_RATIO = 0.35

# Print stride for metadata.  signalstats still runs on every frame; only the
# printing is decimated.  Denser than production's 15 because the corpus wants
# tighter statistics and the reference clip is small.
PRINT_STRIDE = 5

VMAF_MODEL_HD = "/usr/share/model/vmaf_v0.6.1.json"
VMAF_MODEL_4K = "/usr/share/model/vmaf_4k_v0.6.1.json"
VMAF_4K_MIN_WIDTH = 2560

VIDEO_EXTS = {".mkv", ".mp4", ".webm", ".mov", ".avi", ".m4v", ".ts", ".wmv", ".flv"}


# ── Shell helpers ────────────────────────────────────────────────────────────

def run(cmd, timeout=None):
    """Run a command, returning (returncode, stdout, stderr)."""
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       timeout=timeout)
    return p.returncode, p.stdout.decode("utf-8", "replace"), \
        p.stderr.decode("utf-8", "replace")


def parse_fraction(s):
    """'24000/1001' → 23.976.  Tolerates junk and multi-stream commas."""
    if not s:
        return 0.0
    s = s.split(",")[0].strip()
    try:
        if "/" in s:
            num, den = s.split("/", 1)
            den = float(den)
            return float(num) / den if den else 0.0
        return float(s)
    except (ValueError, ZeroDivisionError):
        return 0.0


def probe(path):
    """Container/stream facts for the first video stream."""
    rc, out, _ = run([
        "ffprobe", "-v", "quiet", "-print_format", "json",
        "-show_format", "-show_streams", "-select_streams", "v:0", str(path)
    ], timeout=120)
    if rc != 0:
        return None
    try:
        d = json.loads(out)
    except json.JSONDecodeError:
        return None
    streams = d.get("streams") or []
    if not streams:
        return None
    s, fmt = streams[0], d.get("format", {})

    pix_fmt = s.get("pix_fmt", "") or ""
    # bits_per_raw_sample is frequently unset on AV1; pix_fmt is authoritative.
    if s.get("bits_per_raw_sample"):
        depth = int(s["bits_per_raw_sample"])
    elif "p10" in pix_fmt:
        depth = 10
    elif "p12" in pix_fmt:
        depth = 12
    else:
        depth = 8

    try:
        size_bytes = int(fmt.get("size", 0) or 0)
    except ValueError:
        size_bytes = 0
    if not size_bytes:
        try:
            size_bytes = os.path.getsize(path)
        except OSError:
            size_bytes = 0

    duration = float(fmt.get("duration", 0) or 0)
    return {
        "codec": s.get("codec_name", "?"),
        "width": int(s.get("width", 0) or 0),
        "height": int(s.get("height", 0) or 0),
        "pix_fmt": pix_fmt,
        "bit_depth": depth,
        "color_transfer": s.get("color_transfer", "") or "",
        "color_primaries": s.get("color_primaries", "") or "",
        "fps": parse_fraction(s.get("r_frame_rate")),
        "duration": duration,
        "size_bytes": size_bytes,
        "source_kbps": (size_bytes * 8 / duration / 1000.0) if duration > 0 else 0.0,
    }


# ── Sample positions (mirrors SmartOptimizerLogic.pick_sample_positions) ─────

def pick_positions(duration, seg=SEGMENT_DURATION, max_override=None,
                   ref_cap=None):
    if duration <= seg * 2.0:
        return [0.0]

    coverage_segs = math.ceil(duration * MIN_COVERAGE_TARGET / seg)
    if duration >= VLONG_VIDEO_THRESHOLD:
        max_segs = VLONG_MAX_SEGMENTS
    elif duration >= LONG_VIDEO_THRESHOLD:
        max_segs = LONG_MAX_SEGMENTS
    else:
        max_segs = BASE_MAX_SEGMENTS

    n = min(coverage_segs, max_segs, int(duration / seg))
    if max_override:
        n = min(n, max_override)
    if ref_cap:
        n = min(n, ref_cap)
    n = max(n, MIN_SEGMENTS)
    n = min(n, int(duration / seg)) or 1

    usable = duration - seg
    start = usable * SEGMENT_SPREAD
    end = usable * (1.0 - SEGMENT_SPREAD)
    step = (end - start) / (n - 1) if n > 1 else 0.0
    return [start + step * i for i in range(n)]


def ref_segment_cap(info, max_ref_bytes):
    """How many 8s segments fit the lossless-reference byte budget."""
    w, h, fps, depth = info["width"], info["height"], info["fps"], info["bit_depth"]
    if not (w and h and fps):
        return None
    bytes_per_frame = w * h * 1.5 * (2 if depth >= 10 else 1)
    per_segment = bytes_per_frame * fps * SEGMENT_DURATION * INTERMEDIATE_LOSSLESS_RATIO
    if per_segment <= 0:
        return None
    return max(1, int(max_ref_bytes / per_segment))


# ── Lossless reference ───────────────────────────────────────────────────────

def build_reference(src, info, positions, out_path):
    """Concatenate the sample segments into one lossless clip."""
    cmd = ["ffmpeg", "-hide_banner", "-v", "error", "-y"]
    for pos in positions:
        cmd += ["-ss", f"{pos:.3f}", "-t", f"{SEGMENT_DURATION:.3f}", "-i", str(src)]

    # VP9/AV1 permit odd dimensions with yuv420p; libx264 does not and fails
    # with "Invalid argument".  One corpus file is 3837x2160.  Dropping a
    # single pixel column is irrelevant for signal analysis.
    odd = (info["width"] % 2) or (info["height"] % 2)
    crop = ",crop=trunc(iw/2)*2:trunc(ih/2)*2" if odd else ""

    n = len(positions)
    if n > 1:
        streams = "".join(f"[{i}:v:0]" for i in range(n))
        cmd += ["-filter_complex",
                f"{streams}concat=n={n}:v=1:a=0{crop}[out]", "-map", "[out]"]
    elif crop:
        cmd += ["-filter_complex", f"[0:v:0]{crop[1:]}[out]", "-map", "[out]"]
    else:
        cmd += ["-map", "0:v:0"]

    # FFV1 for >8-bit (universally safe across pixel formats); x264 -qp 0 is
    # faster for the 8-bit majority.  Mirrors the production intermediate.
    if info["bit_depth"] >= 10:
        cmd += ["-c:v", "ffv1", "-level", "3"]
    else:
        cmd += ["-c:v", "libx264", "-qp", "0", "-preset", "ultrafast"]

    cmd += ["-an", "-sn", str(out_path)]
    rc, _, err = run(cmd, timeout=3600)
    if rc != 0 or not out_path.exists():
        return False, err.strip()[-400:]

    # ffmpeg exits 0 even when every input segment yielded zero frames
    # ("Output file is empty, nothing was encoded"), so the exit code alone
    # is not proof of success — verify the reference actually holds frames.
    frames = count_frames(out_path)
    if frames <= 0:
        return False, "reference contains no frames"
    return True, ""


def count_frames(path):
    """Decoded frame count.  Only ever called on short clips."""
    rc, out, _ = run([
        "ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames",
        "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", str(path)
    ], timeout=1800)
    if rc != 0:
        return 0
    try:
        return int(out.strip().split(",")[0])
    except (ValueError, IndexError):
        return 0


def measure_real_duration(path):
    """
    Decode the video stream and report the timestamp actually reached.

    Container headers lie: a file in this corpus advertises 323 s but holds
    ~9 s of decodable video, so every sample position past 9 s produced
    nothing.  This is the authoritative answer, but it costs a full decode —
    only call it when the header-derived positions have already failed, which
    by definition means the file is short or broken and the decode is cheap.
    """
    rc, _, err = run(["ffmpeg", "-v", "error", "-stats", "-i", str(path),
                      "-map", "0:v:0", "-f", "null", "-"], timeout=3600)
    times = re.findall(r"time=(\d+):(\d\d):(\d\d(?:\.\d+)?)", err)
    if not times:
        return 0.0
    h, m, s = times[-1]
    return int(h) * 3600 + int(m) * 60 + float(s)


# ── Signal passes ────────────────────────────────────────────────────────────

METADATA_RE = re.compile(r"lavfi\.([A-Za-z0-9_.]+)=\s*(-?[0-9.eE+]+)")


def parse_metadata(stderr):
    """Collect every lavfi.* metadata value into {key: [values]}."""
    out = {}
    for m in METADATA_RE.finditer(stderr):
        key, raw = m.group(1), m.group(2)
        try:
            out.setdefault(key, []).append(float(raw))
        except ValueError:
            pass
    return out


def run_filter_pass(ref, vf):
    # Measured at native depth; amplitude metrics are normalised afterwards by
    # collect_signals. Converting to 8-bit here would rescale correctly but
    # quantise away the sub-LSB variation fine film grain lives in.
    cmd = ["ffmpeg", "-hide_banner", "-v", "info", "-i", str(ref),
           "-vf", vf, "-an", "-sn", "-f", "null", "-"]
    rc, _, err = run(cmd, timeout=3600)
    if rc != 0:
        return None, err.strip()[-400:]
    return parse_metadata(err), ""


def stats(values):
    """(mean, stddev, p95) for a metric series."""
    if not values:
        return 0.0, 0.0, 0.0
    mean = statistics.fmean(values)
    sd = statistics.stdev(values) if len(values) > 1 else 0.0
    ordered = sorted(values)
    p95 = ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))]
    return mean, sd, p95


def collect_signals(ref):
    """Both analysis passes over the lossless reference."""
    stride = f"select=not(mod(n\\,{PRINT_STRIDE}))"

    # Pass 1 — everything that only *attaches* metadata and leaves frames
    # untouched, so it all shares a single decode.
    vf1 = ("signalstats=stat=tout+vrep+brng,blockdetect,blurdetect,siti,"
           f"scdet=s=0,{stride},metadata=print")
    m1, err = run_filter_pass(ref, vf1)
    if m1 is None:
        return None, f"signal pass: {err}"

    # Pass 2 — edgedetect REWRITES the frame into an edge map, so signalstats
    # after it measures the map, not the source.  It must stay its own pass;
    # YAVG of the edge map is the edge-density proxy production already uses.
    vf2 = f"edgedetect=low=0.08:high=0.25,signalstats,{stride},metadata=print"
    m2, err = run_filter_pass(ref, vf2)
    if m2 is None:
        return None, f"edge pass: {err}"

    def g(src, key):
        return src.get(key, [])

    row = {}
    for label, key in [
        ("tout", "signalstats.TOUT"),      # grain / noise proxy
        ("ydif", "signalstats.YDIF"),      # temporal difference (motion)
        ("yavg", "signalstats.YAVG"),
        ("ylow", "signalstats.YLOW"),
        ("satavg", "signalstats.SATAVG"),
        ("vrep", "signalstats.VREP"),      # repeated-frame fraction
        ("brng", "signalstats.BRNG"),      # out-of-broadcast-range pixels
        ("block", "block"),                # NEW: blockiness → degradation
        ("blur", "blur"),                  # NEW: softness → degradation
        ("si", "siti.si"),                 # NEW: spatial information
        ("ti", "siti.ti"),                 # NEW: temporal information
        ("scd", "scd.score"),              # NEW: scene-change score
        ("mafd", "scd.mafd"),
    ]:
        mean, sd, p95 = stats(g(m1, key))
        row[f"{label}_mean"] = mean
        row[f"{label}_sd"] = sd
        row[f"{label}_p95"] = p95

    edge_mean, edge_sd, edge_p95 = stats(g(m2, "signalstats.YAVG"))
    row["edge_mean"] = edge_mean
    row["edge_sd"] = edge_sd
    row["edge_p95"] = edge_p95

    # Cut density: scdet scores above 10 are conventionally treated as cuts.
    scd = g(m1, "scd.score")
    frames = len(scd)
    cuts = sum(1 for v in scd if v > 10.0)
    row["cut_count"] = cuts
    row["sampled_frames"] = frames
    row["cuts_per_min"] = (cuts / (frames * PRINT_STRIDE / 24.0) * 60.0) \
        if frames else 0.0

    # Bit-depth honesty: signalstats reports the depth actually *used* per
    # plane, which exposes 8-bit content carried in a 10-bit container.
    for label, key in [("ybitdepth", "signalstats.YBITDEPTH"),
                       ("ubitdepth", "signalstats.UBITDEPTH"),
                       ("vbitdepth", "signalstats.VBITDEPTH")]:
        vals = g(m1, key)
        row[label] = statistics.fmean(vals) if vals else 0.0

    return row, ""


# ── CRF sweep with VMAF ──────────────────────────────────────────────────────

def make_degraded(ref, info, workdir, bpp):
    """
    Re-encode the reference into a deliberately starved copy.

    This produces a MATCHED PAIR: identical frames, one clean and one damaged.
    Absolute signal values turn out to be content-confounded — `block` reads
    higher on a clean 43 Mbps anime BD than on a compressed 5 Mbps one — so
    the only way to know whether a signal actually tracks degradation is to
    hold content fixed and vary only the damage.

    Targets a fixed bits-per-pixel rather than a fixed CRF so the severity is
    comparable across resolutions and frame rates.  0.015 bpp sits well under
    every codec threshold in production (bpp_low_threshold is 0.028-0.045).
    """
    w, h, fps = info["width"], info["height"], info["fps"]
    if not (w and h and fps):
        return None
    kbps = max(64, int(w * h * fps * bpp / 1000.0))
    out = workdir / "degraded.mkv"
    rc, _, err = run([
        "ffmpeg", "-hide_banner", "-v", "error", "-y", "-i", str(ref),
        "-c:v", "libx264", "-preset", "veryfast",
        "-b:v", f"{kbps}k", "-maxrate", f"{int(kbps*1.2)}k",
        "-bufsize", f"{kbps*2}k",
        "-an", "-sn", str(out)
    ], timeout=3600)
    if rc != 0 or not out.exists() or count_frames(out) <= 0:
        return None
    return out, kbps


def vmaf_model_for(info):
    if info["width"] >= VMAF_4K_MIN_WIDTH and os.path.exists(VMAF_MODEL_4K):
        return VMAF_MODEL_4K
    return VMAF_MODEL_HD


def sweep_one(ref, info, crf, codec, workdir, threads):
    """Encode the reference at one CRF, then measure size and VMAF."""
    dist = workdir / f"dist_crf{crf}.mkv"
    enc = ["ffmpeg", "-hide_banner", "-v", "error", "-y", "-i", str(ref),
           "-c:v", codec, "-crf", str(crf)]
    if codec == "libsvtav1":
        enc += ["-preset", "6"]
    elif codec in ("libx264", "libx265"):
        enc += ["-preset", "medium"]
    enc += ["-an", "-sn", str(dist)]

    rc, _, err = run(enc, timeout=7200)
    if rc != 0 or not dist.exists():
        return None, f"encode: {err.strip()[-300:]}"

    size_bytes = dist.stat().st_size
    log = workdir / f"vmaf_crf{crf}.json"
    model = vmaf_model_for(info)
    rc, _, err = run([
        "ffmpeg", "-hide_banner", "-v", "error",
        "-i", str(dist), "-i", str(ref),
        "-lavfi",
        f"[0:v][1:v]libvmaf=model=path={model}:n_threads={threads}"
        f":log_fmt=json:log_path={log}",
        "-f", "null", "-"
    ], timeout=7200)

    result = {"crf": crf, "size_bytes": size_bytes, "vmaf_model": Path(model).name}
    if rc == 0 and log.exists():
        try:
            pooled = json.load(open(log))["pooled_metrics"]["vmaf"]
            result["vmaf_mean"] = pooled["mean"]
            result["vmaf_min"] = pooled["min"]
            result["vmaf_harmonic"] = pooled["harmonic_mean"]
        except (KeyError, json.JSONDecodeError):
            pass
    else:
        return None, f"vmaf: {err.strip()[-300:]}"

    dist.unlink(missing_ok=True)
    return result, ""


# ── CSV plumbing ─────────────────────────────────────────────────────────────

def load_done(path, key_fields):
    if not path.exists():
        return set()
    done = set()
    try:
        with open(path, newline="") as fh:
            for row in csv.DictReader(fh):
                done.add(tuple(row.get(k, "") for k in key_fields))
    except OSError:
        pass
    return done


def append_row(path, row, fieldnames):
    exists = path.exists()
    with open(path, "a", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fieldnames, extrasaction="ignore")
        if not exists:
            w.writeheader()
        w.writerow(row)


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(
        description="Smart Optimizer Phase 0 corpus analyzer.")
    ap.add_argument("--corpus", required=True, help="folder of source videos")
    ap.add_argument("--out", default=None,
                    help="output folder (default: ./corpus-out)")
    ap.add_argument("--stage",
                    choices=["signals", "sweep", "degsweep", "all"],
                    default="all",
                    help="degsweep: encode BOTH the clean reference and a "
                         "starved copy at the same CRFs, giving matched "
                         "compressibility pairs — the test for whether "
                         "'bits needed at near-lossless' measures degradation")
    ap.add_argument("--codec", default="libx265",
                    help="sweep encoder (default libx265)")
    ap.add_argument("--crfs", default="18,24,30,36",
                    help="comma-separated CRF sweep points")
    ap.add_argument("--max-segments", type=int, default=None,
                    help="cap sample segments per file")
    ap.add_argument("--max-ref-bytes", type=int, default=DEFAULT_MAX_REF_BYTES,
                    help="lossless reference byte budget per file")
    ap.add_argument("--threads", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--keep-refs", action="store_true",
                    help="keep lossless references instead of deleting them")
    ap.add_argument("--degrade-probe", action="store_true",
                    help="also measure a deliberately starved copy of each "
                         "reference, giving matched clean/damaged pairs")
    ap.add_argument("--degrade-bpp", type=float, default=0.015,
                    help="bits-per-pixel target for the degraded copy "
                         "(default 0.015 — well under any codec's comfort "
                         "threshold)")
    args = ap.parse_args()

    for tool in ("ffmpeg", "ffprobe"):
        if not shutil.which(tool):
            sys.exit(f"error: {tool} not found in PATH")

    corpus = Path(args.corpus).expanduser().resolve()
    if not corpus.is_dir():
        sys.exit(f"error: {corpus} is not a directory")

    out_dir = Path(args.out).expanduser().resolve() if args.out \
        else Path.cwd() / "corpus-out"
    out_dir.mkdir(parents=True, exist_ok=True)
    signals_csv = out_dir / "signals.csv"
    sweep_csv = out_dir / "sweep.csv"

    crfs = [int(c) for c in args.crfs.split(",") if c.strip()]
    files = sorted(p for p in corpus.iterdir()
                   if p.is_file() and p.suffix.lower() in VIDEO_EXTS)
    if not files:
        sys.exit(f"error: no video files found in {corpus}")

    degsweep_csv = out_dir / "degsweep.csv"
    signals_done = load_done(signals_csv, ["file"])
    sweep_done = load_done(sweep_csv, ["file", "crf"])
    degsweep_done = load_done(degsweep_csv, ["file"])

    print(f"corpus : {corpus}  ({len(files)} files)")
    print(f"output : {out_dir}")
    print(f"stage  : {args.stage}   codec: {args.codec}   crfs: {crfs}")
    print()

    signal_fields = None

    for idx, src in enumerate(files, 1):
        name = src.name
        print(f"[{idx}/{len(files)}] {name}")

        info = probe(src)
        if not info:
            print("    ! probe failed — skipping")
            continue

        need_signals = args.stage in ("signals", "all") and \
            (name,) not in signals_done
        pending_crfs = [c for c in crfs
                        if (name, str(c)) not in sweep_done] \
            if args.stage in ("sweep", "all") else []
        need_degsweep = args.stage == "degsweep" and \
            (name,) not in degsweep_done

        if not need_signals and not pending_crfs and not need_degsweep:
            print("    · already done")
            continue

        cap = ref_segment_cap(info, args.max_ref_bytes)
        positions = pick_positions(info["duration"], SEGMENT_DURATION,
                                   args.max_segments, cap)
        print(f"    {info['width']}x{info['height']} {info['codec']} "
              f"{info['bit_depth']}-bit  {info['duration']:.0f}s  "
              f"→ {len(positions)} segments")

        workdir = Path(tempfile.mkdtemp(prefix="corpus-", dir=out_dir))
        ref = workdir / "ref.mkv"
        duration_source = "header"
        try:
            ok, err = build_reference(src, info, positions, ref)
            if not ok:
                # Almost always a lying container duration: the sample
                # positions sit past the last decodable frame.  Measure the
                # real duration and retry once before giving up.
                print(f"    ! reference build failed ({err}) — measuring "
                      f"real duration")
                real = measure_real_duration(src)
                if real > 0 and real < info["duration"]:
                    print(f"    header claims {info['duration']:.1f}s, "
                          f"actually {real:.1f}s decodable")
                    info["duration"] = real
                    info["source_kbps"] = (info["size_bytes"] * 8 / real / 1000.0)
                    duration_source = "measured"
                    positions = pick_positions(real, SEGMENT_DURATION,
                                               args.max_segments, cap)
                    print(f"    retrying with {len(positions)} segments")
                    ok, err = build_reference(src, info, positions, ref)
                if not ok:
                    print(f"    ! giving up: {err}")
                    continue
            print(f"    reference: {ref.stat().st_size / 1024**2:.1f} MiB"
                  f"  ({duration_source} duration)")

            if need_signals:
                sig, err = collect_signals(ref)
                if sig is None:
                    print(f"    ! {err}")
                else:
                    row = {"file": name}
                    row.update({k: info[k] for k in (
                        "codec", "width", "height", "pix_fmt", "bit_depth",
                        "color_transfer", "color_primaries", "fps", "duration",
                        "size_bytes", "source_kbps")})
                    row["segments"] = len(positions)
                    row["duration_source"] = duration_source
                    row.update(sig)

                    # Matched-pair probe: same frames, deliberately damaged.
                    # Emits deg_* columns plus the delta, which is the only
                    # content-independent read on each degradation signal.
                    if args.degrade_probe:
                        made = make_degraded(ref, info, workdir, args.degrade_bpp)
                        if made:
                            deg_path, deg_kbps = made
                            deg, derr = collect_signals(deg_path)
                            if deg:
                                row["deg_kbps"] = deg_kbps
                                for k in ("block_mean", "blur_mean", "tout_mean",
                                          "si_mean", "ti_mean", "edge_mean"):
                                    row[f"deg_{k}"] = deg[k]
                                    row[f"delta_{k}"] = deg[k] - sig[k]
                                print(f"    degraded @ {deg_kbps} kbps: "
                                      f"block {sig['block_mean']:.3f}"
                                      f"→{deg['block_mean']:.3f} "
                                      f"(Δ{deg['block_mean']-sig['block_mean']:+.3f})  "
                                      f"blur Δ{deg['blur_mean']-sig['blur_mean']:+.2f}")
                            deg_path.unlink(missing_ok=True)
                        else:
                            print("    ! degraded probe failed")
                    if signal_fields is None:
                        signal_fields = list(row.keys())
                    append_row(signals_csv, row, signal_fields)
                    print(f"    signals: tout={sig['tout_mean']:.5f} "
                          f"block={sig['block_mean']:.3f} "
                          f"blur={sig['blur_mean']:.3f} "
                          f"si={sig['si_mean']:.1f} ti={sig['ti_mean']:.1f} "
                          f"cuts={sig['cut_count']}")

            if need_degsweep:
                # Compressibility at near-lossless, measured on identical
                # frames clean and damaged.  If "bits needed at low CRF"
                # tracks degradation, the damaged copy must compress to
                # markedly fewer bits than the clean one.
                made = make_degraded(ref, info, workdir, args.degrade_bpp)
                if not made:
                    print("    ! degraded build failed")
                else:
                    deg_path, deg_kbps = made
                    crf = crfs[0]
                    clean_res, e1 = sweep_one(ref, info, crf, args.codec,
                                              workdir, args.threads)
                    deg_res, e2 = sweep_one(deg_path, info, crf, args.codec,
                                            workdir, args.threads)
                    deg_path.unlink(missing_ok=True)
                    if clean_res and deg_res:
                        w, h, fps = info["width"], info["height"], info["fps"]
                        frames = fps * len(positions) * SEGMENT_DURATION
                        px = w * h * frames
                        cb = clean_res["size_bytes"] * 8.0 / px if px else 0.0
                        db = deg_res["size_bytes"] * 8.0 / px if px else 0.0
                        append_row(degsweep_csv, {
                            "file": name, "crf": crf,
                            "width": w, "height": h, "fps": fps,
                            "segments": len(positions),
                            "clean_bytes": clean_res["size_bytes"],
                            "deg_bytes": deg_res["size_bytes"],
                            "clean_bpp": f"{cb:.6f}", "deg_bpp": f"{db:.6f}",
                            "ratio": f"{(db/cb if cb else 0):.4f}",
                            "deg_kbps": deg_kbps,
                        }, ["file", "crf", "width", "height", "fps", "segments",
                            "clean_bytes", "deg_bytes", "clean_bpp", "deg_bpp",
                            "ratio", "deg_kbps"])
                        print(f"    crf {crf} bpp: clean {cb:.4f} → "
                              f"deg {db:.4f}  (ratio {db/cb if cb else 0:.3f})")
                    else:
                        print(f"    ! degsweep: {e1 or e2}")

            for crf in pending_crfs:
                res, err = sweep_one(ref, info, crf, args.codec, workdir,
                                     args.threads)
                if res is None:
                    print(f"    ! crf {crf}: {err}")
                    continue
                row = {"file": name, "codec": args.codec,
                       "width": info["width"], "height": info["height"],
                       "segments": len(positions),
                       "ref_bytes": ref.stat().st_size}
                row.update(res)
                append_row(sweep_csv, row, [
                    "file", "codec", "width", "height", "segments",
                    "ref_bytes", "crf", "size_bytes", "vmaf_mean", "vmaf_min",
                    "vmaf_harmonic", "vmaf_model"])
                print(f"    crf {crf:>2}: {res['size_bytes'] / 1024**2:7.2f} MiB  "
                      f"vmaf {res.get('vmaf_mean', float('nan')):.2f}")
        finally:
            if args.keep_refs:
                print(f"    kept reference: {ref}")
            else:
                shutil.rmtree(workdir, ignore_errors=True)

    print()
    print(f"done. signals → {signals_csv}")
    print(f"      sweep   → {sweep_csv}")


if __name__ == "__main__":
    main()
