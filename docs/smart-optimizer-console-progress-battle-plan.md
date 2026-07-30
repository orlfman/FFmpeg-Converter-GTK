# Smart Optimizer Console Progress — Battle Plan

> **Implementation status:** planned; no production code has been added.
>
> **Scope decision (locked):** Quality Mode only. `optimize_for_quality` is the
> slow solver — a full VMAF sweep — and is where the current silence hurts most.
> `optimize_for_target_size` stays silent in this pass and becomes a clean
> follow-up.
>
> **Line anchors below are as of `e3862ad`.** They are a starting map, not
> gospel. Every anchor is paired with a content signature — match on the
> signature, not the number.

## Mission Statement

During Smart Optimizer analysis the console window shows **nothing**. The user
gets a single-line status-area update and then, minutes later, a ~30-line dump
all at once. On a multi-segment Quality Mode run this is indistinguishable from
a hang.

Stream the analysis as it happens, choosing content on one principle:

> **Show what the final dump throws away. Skip what it already covers.**

Target output:

```text
[Smart Optimizer] CRF 22 → VMAF 96.8, 5140 KiB  (18s)
[Smart Optimizer] CRF 26 → VMAF 94.1, 3820 KiB  (17s)
[Smart Optimizer] CRF 30 → cached
[Smart Optimizer] All probes cleared VMAF 97 — searching upward to codec limit
[Smart Optimizer] Verified CRF 25: VMAF 94.8 (predicted 95.1, +0.3)
```

## Why This Is Worth Building — The Load-Bearing Finding

**The individual probe measurements never reach the user.** This was verified,
not assumed.

`build_quality_notes` (the end-of-run text) reports probing only in *aggregate*:

- `"%d point(s) reused from a previous run"` — `smart-optimizer.vala:1817`
- `"%d point(s) discarded above VMAF %.1f — no gradient there"` — `:1806`
- `"Fit residual: ±%.2f VMAF"` — `:1822`

The `(CRF → VMAF, size)` table that the entire curve fit and CRF solve are
derived from is **discarded**. Streaming it is therefore *new information*, not
merely *earlier* information.

It also doubles as the progress indicator the feature otherwise lacks: three
lines in at ~18s each tells the user roughly how long the remaining probes take.

## Current State — Verified Facts

| Fact | Anchor |
| --- | --- |
| `SmartOptimizer` has **no** signals, delegates, or log hooks | public surface is only the ctor, the two solvers, and static `format_recommendation` |
| Console sink | `ConsoleTab.add_line (string)` — `src/console-tab.vala:1028` |
| Precedent for streaming to console | `Converter.log_console_if_active()` — `src/converter.vala:751`, used throughout `conversion-runner.vala` |
| Everything runs on the main thread via async/await | `communicate_utf8_async` — no thread marshalling needed for a signal |
| Existing timing instrumentation | `ProbeResult { seconds, peak_rss }` — `src/smart-optimizer.vala:2026` |
| Call site A (codec tabs) | `src/app-controller.vala:1198` — the `quality_mode ? … : …` solver ternary |
| Call site B (Crop & Trim) | `src/trim-tab.vala:968` — same ternary, per segment |

Both call sites already have `console_tab` in scope. Wiring is ~2 lines each.

## Emit Points

All inside `optimize_for_quality`, which begins at `smart-optimizer.vala:865`.

### Tier 1 — the probe stream (the reason this feature exists)

**Main calibration loop — `:1056-1082`.** Signature: `foreach (int crf in crfs)`
immediately after `pick_quality_calibration_crfs`.

Two branches already exist and are the natural emit sites:

- **Cache hit** — the `qcache.lookup_with_vmaf (crf, out c_size, out c_vmaf)`
  branch. Emit `CRF %d → cached`.
- **Fresh measurement** — after `calibration_probe_with_vmaf (…)` returns `m`.
  Emit `CRF %d → VMAF %.1f, %.0f KiB`. Guard on `m.vmaf_measured`, which the
  existing `if (!m.vmaf_measured) continue;` already tests.

**Refinement loops.** The same `ProbeMeasurement` shape recurs at `:1139`,
`:1173`, `:1252` (each already branches on `m.from_cache`) and `:1451` (branches
on `v.from_cache`). Emit the same line format from each so refinement probes are
indistinguishable in form from the initial ladder — the user should see one
continuous measurement stream, not two formats.

`ProbeMeasurement` is `{ size_kib, vmaf, vmaf_measured, from_cache }` at `:4100`.

### Tier 3 — exception paths (nearly free; same code being touched)

- **Saturation / upward search** — phase `── 7b. Recover from an over-saturated
  bracket ──` at `:1090`. This is *why* a run occasionally takes 3× longer;
  today it is indistinguishable from a hang. The condition and messaging already
  exist in note form at `:1795-1805`.
- **Bracket refinement** — phase `── 7c. Refine an off-centre bracket ──` at
  `:1281`. Note-form text at `:1813`.
- **Verification and ceiling correction** — phase `── 9b ──` at `:1413`. Emit
  the measured-vs-predicted delta and any CRF correction. Note-form text at
  `:1849-1857` shows exactly the values available (`verification.verified_crf`,
  `.measured_vmaf`, `.predicted_vmaf`, `.delta`, `.ceiling_corrections`).

### Deliberately NOT emitted

- **Anything already in `format_recommendation`** (`:2989`) — it is already a
  thorough ~30-line dump (codec, CRF, preset, sizes, confidence, audio budget,
  pixel format, sharpness). Echoing it live doubles console volume for no gain.
- **Raw ffmpeg/libvmaf stderr.** Already captured for error messages by
  `run_subprocess_stderr` (`:5112`). See the note at `:354` — ~30 metadata keys
  per frame at 60fps floods it. It would bury every useful line above.
- **Per-frame or per-sample-position detail.**
- **The instant phases.** Of the 14 numbered phases in this solver, most (trim
  window resolution, tier selection, confidence math) complete immediately.
  Emitting all of them is noise; only the probe/refine/verify phases are slow.

## Implementation Steps

1. **Add the signal.** On `SmartOptimizer` (`:254`), near the ctor at `:289`:

   ```vala
   /** One human-readable analysis line, emitted as the run progresses. */
   public signal void progress (string line);
   ```

   A plain string keeps the call sites trivial and lets each emit site own its
   own formatting. Resist a struct until a second consumer needs one.

2. **Emit Tier 1** at the five `ProbeMeasurement` sites listed above. Use one
   shared private helper (e.g. `emit_probe_line`) so the format cannot drift
   between the initial ladder and the refinement loops.

3. **Add elapsed time per probe.** During a four-minute wait, "how many left ×
   how long each" is the single most useful fact. `ProbeResult.seconds`
   (`:2026`) already proves the measurement plumbing exists for the live
   speed/RAM probe; a `get_monotonic_time()` delta around
   `calibration_probe_with_vmaf` is sufficient here.

4. **Emit Tier 3** at the saturation, bracket-refinement, and verification
   phases. Reuse the wording already written in `build_quality_notes` so the
   live stream and the final notes agree.

5. **Wire call site A** — `app-controller.vala:1198`. Connect `progress` to
   `console_tab.add_line ("[Smart Optimizer] " + line)`.

   **Connect once, not per run.** `AppController` owns a single long-lived
   `SmartOptimizer` (constructed at `:137`); connecting inside the run function
   would stack a new handler on every invocation and duplicate every line N
   times on the Nth run. Connect where the optimizer is constructed.

6. **Wire call site B** — `trim-tab.vala:968`. `TrimTab` lazily constructs its
   own `SmartOptimizer` at `:748-752` (guarded by `if (smart_optimizer == null)`,
   so it is created exactly once) — connect there, inside the same guard.

   **Volume control matters here.** This path runs the whole solver *per
   segment*; ten segments multiplies the stream by ten, on top of the
   `format_recommendation` dump it already emits per segment. Prefix each line
   with the segment name to match the existing convention at `:983` / `:1002`,
   and emit **Tier 1 only** on this path. The existing per-segment lines to
   match are at `:988` (skip) and `:1009` (success).

## Verification

```bash
cd /home/pieman/Files/Archive/projects/FFmpeg-Converter-GTK
ninja -C builddir 2>&1 | grep -iE "error|Linking target"
meson test -C builddir 2>&1 | tail -5     # expect 19/19 OK
```

Then exercise it for real — a build alone proves nothing about output content:

1. Codec tab (x265 or SVT-AV1) → set **Quality Ceiling** to High or Ultra →
   **Optimize**. Console should stream 3-5 probe lines with rising CRF and
   falling VMAF, then a verification line.
2. Run it a **second time** on the same file with identical settings. Most
   points should now report `cached`, and the run should finish in seconds —
   this simultaneously proves the cache-hit branch emits and that handlers are
   not double-connected (no duplicated lines).
3. Crop & Trim → two or three short segments → Smart Optimizer on, Export as
   Separate Files on. Each segment's lines should carry its own name prefix.
4. A screencast source at Ultra is the cheapest way to exercise the saturation
   path, since flat screen content saturates VMAF readily.

## Risk Notes

- The repo is clean and pushed at `e3862ad`. A partial or unsatisfactory attempt
  is fully recoverable with `git checkout -- src/`.
- `smart-optimizer.vala` is ~5300 lines. Only the Quality Mode solver
  (`:865-1580`) and the signal declaration need touching. Straying into the size
  solver is out of scope for this pass.
- The double-connect trap in steps 5 and 6 is the most likely real bug in this
  change. Both owners construct their `SmartOptimizer` exactly once — connect
  there, never in the per-run or per-segment path.

## Follow-Up (explicitly out of scope)

- The same treatment for `optimize_for_target_size`. Its calibration/fit section
  is phases 4c–7b; unlike Quality Mode, its emit points have **not** been mapped
  yet and require reading roughly 300 lines first.
- A verbosity preference, if the trim path proves too noisy in practice.
