# Smart Optimizer: fractional-target feasibility audit

**Task:** TASK-20261109-fractional-target-audit

**Author/date:** Codex, 2026-11-09, America/Phoenix

**Reviewed revision:** `031acf6` on `main`

**Status:** Draft assessment; no application changes implemented. Local notes from
TASK-20261109-match-source-rounding were already present and are preserved.

## Assessment

**Fractional targets are feasible. Overall difficulty is moderate.** The curve
solver does not require whole MiB: size budgets, probe measurements and curve
inputs already use doubles. The work is primarily preserving a more precise
request across the application and testing every route that carries it.

A complete change should cover both manually entered targets such as 1.5 MiB
and Match Source's exact file size. A display-only change would be insufficient:
several later interfaces, snapshots and helpers currently convert to integers.

For one developer familiar with this code, budget **roughly 3–5 focused working
days for full fractional input, migration, integration and validation**. This is
an engineering estimate from static review, not a measured implementation time
or delivery commitment. Supporting targets below 1 MiB introduces additional
policy and bitrate-limit work; it should be a separately validated extension.

This improves the precision of the *requested budget*. It does not make the
encoded result byte-exact. Sampling, discrete CRF choices, whole-kbps bitrate
settings, audio variability, muxing overhead and safety margins still apply.

## Why rounding exists

The original Match Source commit, `6d07d59` (2026-07-24), intentionally reused an
existing integer-MB target interface. Its helper comment, README and tests all
explicitly describe rounding to the nearest whole MiB. The manual controls and
saved preference were already integer-based. It is a documented design tradeoff,
tracked as SO-F13 because its relative error is large on small files.

The motivating source is 1,572,679 bytes, or 1.4998235702514648 MiB. Current
rounding selects 1,048,576 bytes, losing 33.3% of the intended budget before
encoding. Exact Match Source would retain 1,572,679 bytes. A manually entered
1.50 MiB would mean 1,572,864 bytes: those two requests should remain distinct
even if the controls display both as approximately 1.50 MiB.

## Current data flow and affected areas

Line references describe `031acf6`; they will move during implementation.

| Area | Current evidence | Required treatment |
| --- | --- | --- |
| Core target helpers and tiers | `src/optimizer/smart-optimizer-logic.vala:50`, `:662`, `:673`, `:680`, `:715` | Replace whole-MiB rounding and integer bounds with precise validated targets. Compare tiers against precise sizes. |
| Budget and policy | Same file `:1213`, `:3560` | Accept a precise target before computing fractional KiB; remove the duplicate integer-MB source-reduction comparison. |
| Optimizer entry and recommendation | `src/optimizer/smart-optimizer.vala:493`, `:938`; recommendation in logic file `:163` | Carry precision from the public size-mode entry through the requested-size result. Update progress, errors and notes. |
| Shared codec UI and interface | `src/encoders/base-codec-tab.vala:375`, `:655`, `:862`, `:925`; `src/encoders/codec-tab.vala:30` | Accept decimals, remove integer casts, preserve exact Match Source separately from display, update preference matching. |
| Preferences and storage | `src/ui/settings-dialog.vala:1686`, `:1944`; `src/app/app-settings.vala:686`, `:896`, `:1053` | Change storage and loading deliberately; decimals currently cannot survive the integer getter/save path. |
| Single-file execution | `src/app/app-controller.vala:14`, `:252`, `:328`, `:1190` | Capture precise settings before async work; compare them accurately when discarding stale recommendations; scale trimmed targets once. |
| Folder execution | `src/app/main.vala:508`; `src/app/bulk-settings.vala:14`, `:41`; `src/app/bulk-conversion.vala:768`, `:872` | Preserve the manual target in frozen settings; resolve exact source sizes per item; retain accurate recommendation/report data. |
| Crop & Trim | `src/ui/trim-tab.vala:871`, `:1033`, `:1236` | Preserve temporary segment byte measurements, duration-based fallback, manual targets and skip messages. |
| Final reporting | `src/app/converter.vala:77`, `:231`, `:255`, `:577`; `src/runners/conversion-runner.vala:186` | Carry the precise request through staged/configured reports; do not turn display rounding into the reported baseline. |
| Tests and documentation | `tests/smart-optimizer-logic-test.vala`, `tests/combine-window-state-test.vala`, `tests/mpv-backend-state-test.vala:6`, `README.md:160` | Replace intentional whole-MiB assertions, add fractional/migration coverage, update the backend test's local clamp stub and user documentation. |

There are about **13 substantive production files** in that path, plus roughly
three existing test files and documentation. Four additional codec-tab files
only call the shared target-reset helper; those may require no edits. A new
shared target type or test target would also need the relevant Meson source
lists updated. This is a scope estimate, not a prescribed diff size.

### What can largely stay in place

- `SizeBudget` already stores total, audio, overhead and video sizes as doubles
  in KiB (`smart-optimizer-logic.vala:559`).
- The size curve solver accepts a double logarithmic target (`:3286`). The fit,
  calibration ladder and verification algorithm need no new mathematical model.
- The encoders receive a bitrate or CRF, not an integer-MiB file-size option.
  Ordinary fractional support does not require a new encoder command format.
- Quality Mode remains governed by its VMAF objective. Shared settings/snapshot
  changes must preserve its existing rule that size controls do not invalidate
  a quality-mode run.
- Probe cache keys describe what was encoded and measured, not the requested
  target (`smart-optimizer-cache.vala:92`). A fractional target change should
  still reuse matching measurements. Derived preset, format and tuning changes
  must continue to affect the key. Do not add the raw target merely to force
  misses; no cache format change is inherently needed for this feature.

## Recommended representation

Use a single validated **`int64 target_bytes`** representation for the requested
size, with shared conversion/formatting helpers. A small value type is optional;
consistent units and a single validation path matter more than a new class.

1. **Manual UI:** accept decimal MiB, suggested 0.01 MiB step and two decimal
   places. Convert to bytes once, rounding to the nearest byte after checking
   that the value is finite and in range.
2. **Match Source:** use the source signature's byte count directly. The source
   file signature remains authoritative, as it is now; the asynchronous size
   label must never become the execution input.
3. **Solver:** convert bytes to double KiB once for existing budget arithmetic.
   Keep CRF and bitrate types unchanged unless addressing a separate limit.
4. **Recommendation and final report:** retain requested bytes. Estimated sizes
   may remain rounded KiB, clearly labelled estimates. Display a convenient MiB
   value while computing differences from the unrounded requested byte count.
5. **Trim fallback:** multiply source bytes by the existing duration fraction in
   floating point, then round once to a byte. Preserve the current upper bound
   on the fraction and invalid-duration fallback. Avoid integer multiplication
   before division, which can overflow or truncate.

Use 64-bit constants and arithmetic for bounds: the existing maximum is
16,384 MiB = **17,179,869,184 bytes**, beyond signed 32-bit range. Reject or
explicitly handle NaN, infinity, negative values, missing source size and
out-of-range requests before casts. Preserve the distinction between an absent
request (current zero sentinels) and a valid size.

**Alternative:** carrying `double target_mib` end to end is also viable and has
less naming churn. Within the current upper limit, binary double precision is
ample to represent byte-derived MiB. It still requires every integer getter,
cast, save/load, comparison and format string to be reviewed. Canonical bytes
are recommended because equality, source identity and reporting are simpler to
reason about; floating point precision itself is not a blocker here.

### Units and UI behavior

The present controls say MB but use powers of 1024. Preserve those numerical
semantics during migration. Prefer labelling the controls **MiB** with a brief
explanation; do not silently switch existing targets to decimal MB.

Displaying an exact Match Source target as 1.50 MiB must not overwrite it with
1.50 on the next snapshot. Show the exact byte count in a tooltip or supporting
text when useful. When Match Source is turned off, explicitly initialize a
manual target at the supported display precision; it is then a new manual
request. Test this transition alongside the global Match Source override,
reset-to-default behavior and the blue stored-preference indicator.

Snapshot equality should compare canonical bytes, rather than a broad tolerance
that could treat two different user requests as equal. Include a test where the
target changes while analysis is running and the older result is rejected.

## Persistence and compatibility

Current settings read `target_mb` with `KeyFile.get_integer` and save with
`set_integer`. Simply writing `target_mb=1.5` would make older integer readers
reject it and use their fallback. The migration needs an explicit policy.

Recommended plan for the byte representation:

- Add a `target_bytes` integer-64 key and prefer it when valid.
- If it is absent or invalid, read the existing integer `target_mb`, validate it,
  and multiply by 1,048,576. Thus an old value of 4 keeps exactly the same budget.
- Save the precise key. If retaining a rounded legacy `target_mb` mirror for
  older binaries, give the new key precedence and document that old binaries
  can represent only the approximation. Test what an older save does to both
  keys before claiming downgrade compatibility.
- Preserve default, bounds and the settings mutex/snapshot pattern. Isolate
  migration tests in disposable configuration directories.

Using the same `target_mb` key with a double reader/writer is a smaller alternative:
new readers can support old integer values, but older versions cannot reliably
read new fractional values. That is a compatibility tradeoff, not a reason to
avoid fractional targets altogether.

## Scope boundaries and behavior decisions

### Fractions above 1 MiB versus targets below 1 MiB

Supporting 1.25 or 1.5 MiB does not require lowering the current minimum of
1 MiB. The recommended first release keeps that minimum and the existing
16,384 MiB maximum. A source outside these bounds must be labelled as adjusted,
not described as an exact match. Exact Match Source applies within the supported
range. Extending that range below 1 MiB is a separate decision.

Sub-1-MiB support is possible, but audio and container costs quickly dominate.
The current base overhead reserve is 30 KiB for MP4 and 40 KiB for MKV/WebM,
before per-frame/per-packet costs. Preserve early infeasibility checks and
useful explanations instead of silently increasing the requested budget.

### Existing bitrate-floor mismatch — SO-F14

Static review found a pre-existing limitation relevant to small targets:

- The optimizer's minimum viable video budget is **80 kbps**
  (`smart-optimizer-logic.vala:478`; checked in `smart-optimizer.vala:571`).
- Tiny/Small policy then applies its 3% margin (`decide_two_pass`).
- All four smart codec resolutions clamp two-pass video bitrate to at least
  **100 kbps** (`smart-codec-resolver.vala:178`, `:257`, `:301`, `:342`).

A recommendation below 100 kbps can therefore be raised when settings are
applied. This risk already exists at integer targets and is independent of the
reported 543 kbps example. It becomes more relevant when admitting smaller
budgets. The mismatch is confirmed in code; a failing output was not reproduced
in this audit.

Align validation and planning with the bitrate that will actually be applied,
including the safety margin, or deliberately support lower rates across the
resolver, controls and builders after validation. Merely changing the early
constant to 100 is insufficient if the later margin can reduce it below 100.
Treat this as a separate fix, and a prerequisite for confidently expanding
small-target support. Review the existing 50,000 kbps upper clamp as a boundary
case too; changing it is not required just to represent fractions.

### Tier thresholds and conservative sizing

Compare exact sizes against 25, 50, 100 and 200 MiB. For example, 25.01 MiB
belongs above the Tiny threshold; truncating it to 25 first would select the
wrong policy. Whole-number targets should preserve their existing tier behavior.
More accurate source targets can legitimately move some files across a tier,
changing audio, preset or container policy. Document and test those transitions.

Keep the 3% margin and overhead policy unchanged for the initial precision
migration. Changing them simultaneously would make it difficult to attribute
output differences. A future distinction between “match this size” and “stay
under an upload limit” is useful but separate product work.

Whole-kbps bitrate steps remain: one kbps over the example's 12.772 seconds is
about 1,596.5 bytes. CRF and rate-control variation also limit practical output
precision. Do not promise that a 1.50 MiB request produces exactly 1.50 MiB.

## Delivery choices and effort

Estimates assume one developer familiar with Vala/GTK and working media tools.
They include relevant testing; they exclude redesigning rate control or repeated
full-output retries to hit an exact byte count.

| Scope | Difficulty | Rough effort | Result |
| --- | --- | --- | --- |
| Exact Match Source within current bounds; manual targets remain whole MiB | Moderate, smaller scope | 1–2 working days | Shared core/callers/reports gain precision; preference/manual-input migration can wait. |
| Full fractional manual targets plus exact Match Source | Moderate, recommended | 3–5 working days total | Consistent precision across preferences, codec tabs, single files, folder jobs and trim. |
| Also admit targets below 1 MiB | Moderate with extra validation | Add roughly 1–2 days initially | Requires bounds decisions, bitrate-floor alignment and short/long/audio-heavy cases; calibration issues may increase this. |

A demo with a decimal input can be produced much faster. Production readiness
is dominated by migration, all-route parity and validation. No additional
analysis passes are inherently needed, so fractional representation itself
should not materially increase encoding time.

Suggested implementation order:

1. Introduce precise target helpers and numeric/boundary tests; preserve current
   limits and whole-value results.
2. Thread the precise request through the optimizer, single-file snapshots,
   folder captures, segment targets and final reports.
3. Add decimal controls, settings migration, unit labels and consistent display.
4. Update tests and docs, build all affected targets, then validate representative
   actual conversions and interactive flows. Address SO-F14 separately where
   needed before expanding the supported small-budget range.

## Validation and acceptance criteria

- **Numeric:** test 1.25, 1.5 and 1.75 MiB; exact Match Source at 1,572,679 bytes;
  185-byte rounding-boundary regression; current min/max; invalid, non-finite and
  overflowing inputs; each side of every size-tier boundary. Preserve existing
  whole-number target behavior.
- **Trim:** preserve a measured temporary segment's bytes; test fallback scaling,
  unknown durations, an overlong window and a fraction that becomes sub-minimum.
  General seek/time uses duration scaling; Crop & Trim prefers measured segment
  bytes. Preserve that distinction and existing speed/duration semantics.
- **Persistence:** legacy integer loads, decimal/manual round-trip through the new
  representation, malformed keys, precedence, default/reset, and any claimed
  older-version compatibility. Test locale-aware entry separately from the
  stable on-disk numeric representation.
- **State:** a fractional edit invalidates an active size solve; size edits remain
  irrelevant in Quality Mode. Test Match Source on/off, global override,
  source switches during asynchronous size probing and frozen folder settings.
- **Conversion:** all four codecs with a fractional manual target and exact Match
  Source; single file, folder and trim routes; audio on/off and representative
  durations. Inspect actual target, resulting bitrate, muxed size and decoded
  output. Exercise a rate near the resolver floor and a whole-number control.
- **Reporting/cache:** the requested target remains exact through staging and
  final difference calculation; rounding is display-only. Verify cache reuse
  when only the target changes within otherwise identical encode settings, and
  invalidation when derived settings change.

Relevant existing suites include `smart-optimizer-logic`, `smart-codec-resolver`,
`smart-codec-widgets`, `bulk-conversion`, `bulk-conversion-widgets`,
`prepared-conversion`, `prepared-conversion-widgets`, `combine-window-state`,
`trim-subtitles-state` and `mpv-backend-state` (its local clamp stub shares the
settings dependency). Extend focused tests where current suites do not cover
this flow. Run the full suite after the cross-cutting type change; display skips
are not GUI coverage. Known historical failures in AUDIT.md require separate
attribution and must not mask new regressions.

Acceptance means the correct budget reaches every route, not zero final-size
error. The supplied source should enter Match Source with 1,572,679 bytes and
retain that requested value in its report. No new expected output size or
quality claim can be made until the modified implementation is tested.

## Evidence and limits of this audit

Reviewed current source, callers, settings serialization, test assertions and
Meson test wiring, together with the original rounding commit and the prior
user-log investigation. Arithmetic spot checks confirmed lossless byte-to-double
MiB round-trips for the motivating size, adjacent 1.5 MiB boundary values,
minimum/default and current maximum. These are arithmetic examples, not tests
of an implemented feature.

No application code was edited, no build or test suite was run, and no media was
opened or encoded during this feasibility audit. All implementation proposals
and effort estimates above remain unverified. SO-F13 remains an open design
limitation; SO-F14 is an existing code-level mismatch, awaiting runtime testing.
