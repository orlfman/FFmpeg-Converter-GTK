// smart-optimizer.vala
// Intelligent video size optimizer with content-aware encoding recommendations.
//
// Supports all target sizes from imageboard (≤4 MB) to large file reductions
// (hundreds of MB), with tier-aware strategies for each range.
//
// Improvements over v1:
//   - Two-point CRF calibration: measures THIS video's CRF↔size curve instead
//     of assuming a universal constant (0.8715). Way more accurate.
//   - Multi-segment sampling: picks segments at 20/40/60/80% through the video
//     instead of just the first 30s. No more fooled by static intros or credits.
//   - Content-aware preset correction: separate calibration tables for
//     live-action, anime, and screencasts — anime gains far more from slower
//     presets than live-action, so the correction factors must reflect that.
//   - Fixed motion detection: uses ffmpeg's YDIF (temporal luma difference) from
//     signalstats instead of the broken SSIM filter (which needs two inputs).
//   - Consolidated ffmpeg calls: multi-input concat reduces subprocess count
//     from 12+ down to ~5.
//   - Content detection includes screencast (text/UI) in addition to anime.
//   - Proper async: actually uses yield + async subprocess, won't block the UI.
//   - Audio bitrate subtracted from target so video gets the right budget.
//   - Early feasibility check before running calibration encodes — saves the
//     user waiting through two slow encodes only to get an impossible result.
//   - Uses AppSettings paths (ffmpeg/ffprobe) instead of bare executable names.
//   - Subprocess errors captured and surfaced in error messages.
//   - Signalstats parsing uses dual strategy (prefix + field fallback) for
//     robustness across ffmpeg builds.
//   - Two-pass bitrate recommendation clearly promoted when CRF mode cannot
//     hit the target.
//   - Audio fallback assumption flagged in output notes.
//   - All errors logged, never silently swallowed.
//
// v3 improvements:
//   - Cancellable support: all async operations accept a GLib.Cancellable so
//     the user can abort mid-calibration without waiting for encodes to finish.
//   - Confidence-scaled preset selection: preset index is interpolated between
//     a safe baseline and the content-specific ideal, weighted by classifier
//     confidence. Uncertain classifications no longer jump to extreme presets.
//   - Codec-aware audio fallback: opus defaults to 96 kbps, vorbis to 112,
//     AAC/unknown to 128 — avoids over-reserving audio budget for WebM files.
//   - Sample coverage tracking: when sampled duration is <10% of total,
//     confidence is reduced and a note is emitted warning of potential
//     inaccuracy on long or variable-content videos.
//   - CRF extrapolation warnings: logged when predicted CRF falls outside
//     the calibration range, with severity proportional to distance.
//   - Fixed FileUtils.unlink error handling (returns int, does not throw).
//   - Portable temp directory via Environment.get_tmp_dir().
//
// v4 improvements:
//   - OptimizationContext: callers can now pass video filter chain, effective
//     duration (for seek/time trim), and audio bitrate override. Calibration
//     encodes include the filter chain so size estimates reflect actual output
//     resolution, crop, framerate, denoise, etc.
//   - Temp file cleanup on cancellation: calibration temp files are now cleaned
//     up even when the encode is cancelled or errors out.
//   - Resolution suggestion: when the target is physically impossible, the
//     error message now calculates what scale factor or trim duration would
//     make it feasible, instead of generic advice.
//   - Duration-aware budget: all size calculations use the effective encode
//     duration (accounting for seek/time trim) rather than the full file.
//
// v5 improvements:
//   - Base + adaptive CRF calibration: starts with four CRF values and fits
//     a quadratic in log-space via least-squares:
//       ln(size) = a + b·CRF + c·CRF²
//     Four points overdetermine the 3-unknown model, so the least-squares
//     fit averages out noise from individual samples — more robust than
//     an exact 3-point solve. When the solved CRF falls outside or right at
//     the edge of that base window, the optimizer can add nearby follow-up
//     CRFs and refit. The quadratic term captures the CRF↔size curve's bend
//     that the two-point exponential model missed.
//   - Graceful fallback: if the least-squares system is degenerate (e.g.
//     two points produced identical sizes), falls back to two-point
//     exponential automatically.
//   - Quadratic root selection: when solving c·x²+b·x+(a-ln(target))=0,
//     picks the root closest to the valid CRF range. Handles edge cases
//     including negative discriminant (target unreachable by the curve).
//
// v6 improvements:
//   - Verification encode: after predicting CRF + preset, a single-segment
//     encode at the recommended preset measures the REAL preset efficiency
//     factor instead of relying on hardcoded tables. Eliminates the single
//     biggest source of estimation error.
//   - Container overhead: reserves KiB for container headers, seek index, and
//     metadata based on size tier. Prevents "just barely over target" results.
//   - Metadata stripping for TINY tier: disables preserve_metadata when
//     targeting ≤25 MB — every byte counts at imageboard sizes.
//
// v7 improvements:
//   - Source-aware targeting policy: TINY/SMALL treat reduction targets as
//     strict size ceilings and force two-pass. MEDIUM+ may still use CRF
//     when the prediction is confident and lands inside the tier's target
//     band, prioritizing quality when the estimate is credible.
//   - Tier-aware overshoot detection: strict tiers force two-pass on even
//     modest CRF overshoot, while MEDIUM+ fall back to two-pass whenever the
//     estimate lands outside the tier's acceptable target band.
//   - XLARGE tier no longer unconditionally skips two-pass. It now checks
//     confidence (threshold 0.60) plus the target-band gates above, which
//     prevents large-target blowups while still allowing confident CRF picks.
//   - Source file size probed from ffprobe format.size with stat fallback,
//     stored in SmartOptimizerVideoInfo.file_size_bytes.
//   - Duration-scaled sampling: videos >10 min now sample up to 8 segments
//     (64s) instead of 4 (32s), improving prediction accuracy on long or
//     variable-content videos.
//   - Source bitrate sanity check: computes the source's effective video
//     bitrate and compares it against the CRF estimate. If the model
//     predicts a larger output than the source while the target is smaller,
//     confidence is reduced so the tier policy is more likely to choose
//     two-pass.
//   - Multi-segment verification: verification encode now uses 2–3 spread
//     positions (quartiles) instead of a single middle segment, catching
//     content variability in the preset factor measurement.
//   - VP9 two-pass uses pure VBR instead of Constrained Quality for hard
//     size targets. CQ's CRF floor can fight the bitrate cap on complex
//     content; VBR gives the encoder a clear target with no quality minimum.
//   - SVT-AV1 presets capped at 9 — presets 10+ are flagged by SVT-AV1 as
//     "automation tooling" with visual artifacts and poor rate control.
//   - Codec-aware tier_safe_preset_index: SVT-AV1 gets its own mapping
//     tuned for the compacted {9..0} array; x264/x265/vp9 unchanged.
//   - Calibration fallback for SVT-AV1 uses preset 9 (array index 0)
//     instead of the old hardcoded preset 13.
//   - Adaptive segment expansion: if content analysis detects high motion
//     variance (CV > 0.60), calibration segments expand up to 16 for
//     better size prediction on variable-content videos.
//   - Coverage-based duration scaling: segment count targets 15% minimum
//     coverage, capped per tier: <10 min (6), 10–45 min (10),
//     45+ min (14 base, up to 16 adaptive).
//
// v8 improvements:
//   - Calibrate at target preset: calibration encodes now use the
//     recommended preset instead of always using the fastest (ultrafast).
//     This eliminates the preset efficiency factor tables and the complex
//     verification correction loop — the model directly predicts what
//     the actual encode will produce.  Fixes a bug where x265's psy-rd
//     at slower presets could produce LARGER files than ultrafast at the
//     same CRF, causing the old factor (clamped to ≤1.0) to severely
//     underestimate output size.
//   - Lightweight model accuracy verification: a single encode at the
//     solved CRF (same preset, same samples) checks the quadratic
//     interpolation accuracy and corrects if off by >5%.
//
// v9 improvements (TINY/SMALL accuracy):
//   - Stream-copy audio when source codec is compatible with the output
//     container and source bitrate ≤ tier budget.  Gives an exact audio
//     size instead of a budget estimate — critical for tiny targets where
//     audio dominates.
//   - Measure actual audio output: when re-encoding audio, run a quick
//     audio-only encode of a calibration segment to measure the real
//     bitrate instead of trusting the tier budget.
//   - Safety margin (v8.1): 3% video bitrate reduction for strict tiers
//     absorbs encoder overshoot.
//   - VBV constraints (v8.1): maxrate/bufsize for two-pass encodes
//     prevents peak bitrate spikes from blowing the size budget.
//
// v10 improvements:
//   - Parallel calibration: independent calibration encodes in a batch
//     run concurrently — one job per 4 logical cores, capped at 4 jobs —
//     with -threads splitting the cores evenly between jobs.  4-core
//     machines keep the sequential behavior; bigger CPUs cut calibration
//     wall time roughly in half or better.  The verification encode uses
//     the same -threads value so its measured size stays consistent with
//     the calibration samples.
//   - Stale-CRF fix: the strict-tier audio bitrate measurement now runs
//     BEFORE CRF calibration instead of after the solve.  Previously a
//     measured audio bitrate that differed from the tier guess updated
//     the budgets but left the already-solved CRF (and the verification
//     encode's corrected target) computed against the stale budget.
//   - Audio measurement fixes: measure_audio_bitrate now maps the first
//     audio stream explicitly (ffmpeg's default selection picks the
//     HIGHEST-channel-count stream — the wrong track when e.g. a 5.1
//     mix follows the stereo default track) and concats up to three
//     spread segments instead of judging a VBR-ish codec from a single
//     window that may be silence or music.
//   - Duration-scaled container overhead: replaces the fixed per-tier
//     KiB constants with a model of base header size plus per-video-
//     frame and per-audio-packet index costs (moov sample tables for
//     MP4, block headers + cues for Matroska/WebM).  A 2-hour MP4 now
//     reserves the several MB its moov actually needs instead of a
//     flat 120–300 KiB.
//   - Complexity-weighted extrapolation: a demux-only ffprobe packet
//     pass builds a per-second source bitrate profile; when samples
//     cover <50% of the encode window, the duration-based
//     extrapolation is corrected by how the sampled regions' source
//     bitrate compares to the whole window (clamped, damped ^0.7) —
//     attacking the "samples missed the action scenes" failure mode.
//   - Residual-based confidence: the least-squares fit's log-space
//     RMSE now scales confidence (no penalty below 3%, floor 0.6 at
//     25%), catching content whose CRF↔size response the quadratic
//     models poorly.  The x265 psy-rd penalty is kept — residuals
//     share the same sample segments, so they cannot see
//     unsampled-scene inflation, which is what that penalty covers.
//   - Monotonicity guard: if the fitted quadratic's slope turns
//     non-negative inside the calibration window (noise bending the
//     parabola upward = "higher CRF → bigger file"), the curve is
//     refitted as a least-squares line in log-space.
//   - Verification reuse: when the solved CRF equals a calibration
//     point, verification reuses that measured size instead of
//     re-encoding identical output.  When verification shifts the CRF
//     by ≥2, one extra measurement at the final CRF replaces the
//     first-order ratio correction with a real size.
//
// v11 improvements:
//   - Split into testable stages: all pure decision logic (types, unit
//     conversions, trim window, audio planning, size budget, curve
//     fitting/solving, confidence assessment, two-pass policy) moved to
//     smart-optimizer-logic.vala with no subprocess/AppSettings
//     dependencies, covered by tests/smart-optimizer-logic-test.vala.
//     This file keeps orchestration, probing, content analysis, and the
//     ffmpeg encodes; optimize_for_target_size is now a readable
//     pipeline over stage methods (measure_and_apply_audio_budget,
//     run_crf_calibration, run_verification, build_notes).
//
// v12 improvements:
//   - Audio measurement silence floor: a measured audio bitrate below
//     25% of the tier budget is treated as sampled silence and floored,
//     so near-silent calibration windows can't starve the audio reserve
//     on files with normal audio elsewhere.
//   - MIXED classification confidence floored at 25% — landing in the
//     mixed band at all is evidence of mixedness; a 0% label read as a
//     classifier failure and zeroed the preset interpolation.
//   - Bits-per-pixel downscale advisory: when the video budget's bpp
//     falls below a codec-specific comfort threshold (0.028 SVT-AV1,
//     0.032 x265/VP9, 0.045 x264), the notes suggest a concrete
//     even-dimension resolution that restores per-pixel quality at the
//     same target size.  Skipped when the filter chain already rescales.
//
// v13 improvements:
//   - Persistent calibration sample cache (smart-optimizer-cache.vala):
//     measured (CRF → size) points are stored in the user cache dir,
//     keyed on file identity (path/size/mtime), codec, preset, pixel
//     format, filter chain, trim window, sample positions, and the
//     extrapolation weight.  Re-running with only a different target
//     size reuses the points and skips the matching calibration encodes;
//     different tiers still get partial reuse where CRF windows overlap.
//   - Lossless intermediate for filtered runs: when a video filter chain
//     is active, the sample segments are decoded and filtered ONCE into
//     a lossless intermediate (x264 -qp 0 for 8-bit, FFV1 for 10-bit);
//     every calibration and verification probe then encodes from it,
//     eliminating the 6-8 redundant decode+filter passes per run.
//     Built lazily (skipped when the cache satisfies every point) and
//     skipped with a warning when the estimated size exceeds 4 GiB.

using GLib;
using Json;

// Public types (ContentType, SizeTier, OptimizationRecommendation,
// OptimizationContext) and the internal data carriers now live in
// smart-optimizer-logic.vala together with all pure decision logic.

// ════════════════════════════════════════════════════════════════════════════
// SmartOptimizer
// ════════════════════════════════════════════════════════════════════════════

public class SmartOptimizer : GLib.Object {

    // ── Preset name tables ───────────────────────────────────────────────────
    private const string[] X264_PRESETS = {
        "ultrafast", "superfast", "veryfast", "faster", "fast",
        "medium", "slow", "slower", "veryslow"
    };
    private const string[] X265_PRESETS = {
        "ultrafast", "superfast", "veryfast", "faster", "fast",
        "medium", "slow", "slower", "veryslow"
    };
    private const int[] VP9_CPU_USED = { 8, 7, 6, 5, 4, 3, 2, 1, 0 };
    // SVT-AV1 presets mapped to 9 indices (fastest to slowest).
    // Preset 1 is skipped — it's barely distinguishable from 0 in quality
    // and rate control but significantly slower.
    // Presets 10+ are excluded — SVT-AV1 flags them as "automation tooling"
    // with visual artifacts, poor rate control, and no film-grain support.
    // Users who want 10+ can disable auto-convert and set it manually.
    private const int[] SVT_AV1_PRESETS = { 9, 8, 7, 6, 5, 4, 3, 2, 0 };

    /**
     * Encoder tuning for the run in progress, so every calibration probe
     * encodes with the settings the recommendation will actually apply.
     *
     * Held per-run rather than threaded through nine command-building
     * signatures. AppController owns a single SmartOptimizer and serialises
     * runs through smart_opt_generation, cancelling any previous one before
     * starting the next, so only one run reads this at a time. Each pipeline
     * sets it before probing; null means "probe with codec/preset/CRF alone",
     * which is the pre-existing behaviour.
     */
    private SmartOptimizerLogic.EncoderTuning? active_tuning = null;
    private FfmpegRuntimeCapabilities? runtime_capabilities;

    public SmartOptimizer (
        FfmpegRuntimeCapabilities? runtime_capabilities = null
    ) {
        this.runtime_capabilities = runtime_capabilities;
    }

    /** Fail before any video probing or temporary-file work when VMAF is absent. */
    private async void require_vmaf (Cancellable? cancellable) throws Error {
        var probe_cancel = cancellable ?? new Cancellable ();
        VmafCapability capability = (runtime_capabilities != null)
            ? yield runtime_capabilities.get_vmaf_capability (
                AppSettings.get_default ().ffmpeg_path, probe_cancel)
            : yield FfmpegRuntimeCapabilities.probe_vmaf (
                AppSettings.get_default ().ffmpeg_path, probe_cancel);

        if (capability.status != VmafCapabilityStatus.SUPPORTED) {
            throw new IOError.NOT_SUPPORTED (
                capability.reason ?? "Quality Target requires FFmpeg with libvmaf support.");
        }
    }

    // Calibration parallelism: encodes within a batch are independent.
    // One concurrent job per this many logical cores, capped below — a
    // single ffmpeg encode already scales across cores, so extra jobs
    // only pay off on CPUs with headroom beyond one encode.
    private const int CORES_PER_CALIBRATION_JOB     = 4;
    private const int MAX_PARALLEL_CALIBRATION_JOBS = 4;

    // Analysis segment config
    private const int    SEGMENT_DURATION   = 8;        // seconds per sample

    // Print only every Nth frame's signalstats metadata. signalstats still
    // runs on every frame (so YDIF/TOUT stay frame-accurate), but printing
    // ~30 metadata keys for every frame at 60fps floods the captured stderr
    // (~15 MB), which starves the GLib pipe drain and backs ffmpeg up — an
    // 8-minute analysis instead of ~1. Decimating the *print* to a few
    // samples/sec keeps the aggregate means stable while keeping the pipe
    // small. At 60fps a stride of 15 samples ~4x/sec; at 24fps ~1.6x/sec.
    private const int    ANALYSIS_PRINT_STRIDE = 15;

    // Adaptive-expansion time budget: the calibration phase may expand to more
    // sample segments when content is variable, but each probe encode's cost
    // scales with resolution/fps/preset — a flat segment cap that's cheap at
    // 720p stalls for minutes at 4K. This is the wall-time (seconds) we're
    // willing to spend on calibration; a live speed-probe measures the real
    // per-segment cost and expansion is sized to fit. It's a policy value
    // (how long is acceptable), NOT a machine-tuned constant — the machine's
    // real speed comes from the probe, so this stays correct on any hardware.
    private const double ANALYSIS_TIME_BUDGET_SECONDS = 90.0;

    // Duration (seconds) of the single speed-probe encode. Kept short so the
    // probe is cheap even at 4K/8K; scaled up to a full segment afterward.
    // Long enough to amortize encoder start-up / first-frame latency.
    private const double SPEED_PROBE_SECONDS = 3.0;

    // Run the probe (for the memory cap) at or above this pixel count even when
    // no segment expansion is wanted — parallel calibration only threatens RAM
    // at high resolution. ~3.1 MP ≈ just above 1080p, so 1440p/4K/8K probe for
    // memory; smaller sources skip it (their parallel jobs are cheap).
    private const long   PROBE_MIN_PIXELS = 3110400;   // 1920x1080 x1.5

    // Fraction of currently-available RAM the parallel calibration encodes may
    // use. Leaves headroom for the encodes to grow and for other apps to
    // allocate during the multi-minute run. The per-job cost comes from the
    // live probe, so this is the only memory policy knob.
    private const double CALIBRATION_MEMORY_FRACTION = 0.7;

    // How often (ms) to sample the probe process's RSS while it encodes.
    private const uint   RSS_POLL_INTERVAL_MS = 150;

    // ════════════════════════════════════════════════════════════════════════
    // PUBLIC API
    // ════════════════════════════════════════════════════════════════════════

    /**
     * Analyze a video and recommend encoding settings to hit a target file size.
     *
     * Returns both a CRF recommendation (quality-focused) and a two-pass
     * bitrate target (more size-directed, but not exact-size guaranteed).
     * Caller decides which to use.
     *
     * @param ctx  Optional context — video filters, effective duration, audio
     *             bitrate override. Pass a default-initialized struct to use
     *             probed values for everything.
     */
    public async OptimizationRecommendation optimize_for_target_size (
        string                input_file,
        int                   target_mb       = 4,
        string                preferred_codec = "vp9",
        OptimizationContext   ctx             = OptimizationContext (),
        Cancellable?          cancellable     = null
    ) throws Error {
        string? temp_run_dir = ConversionUtils.create_managed_temp_run_dir (
            "smart-optimizer",
            "analysis"
        );
        var intermediate = new IntermediateHolder ();

        try {
            int requested_target_mb = target_mb;
            target_mb = SmartOptimizerLogic.clamp_target_mb (target_mb);
            if (target_mb != requested_target_mb) {
                warning ("Smart Optimizer: target %d MB out of range, clamped to %d MB",
                    requested_target_mb, target_mb);
            }

            // ── 1. Probe ────────────────────────────────────────────────
            SmartOptimizerVideoInfo info;
            try {
                info = yield probe_video (input_file, cancellable);
            } catch (Error e) {
                if (e is IOError.CANCELLED) throw e;
                warning ("Probe failed: %s", e.message);
                return make_error_rec (preferred_codec,
                    "Could not read video file: %s".printf (e.message));
            }
            if (info.duration <= 0) {
                return make_error_rec (preferred_codec,
                    "Video has zero duration — ffprobe could not determine the length.\n"
                    + "The file may be corrupt, truncated, or in an unsupported container format.");
            }
            info.duration = yield verify_probed_duration (
                input_file, info.duration, cancellable);

            // ── 1b. Trim window, tier, container, audio plan ────────────
            var tw = SmartOptimizerLogic.resolve_trim_window (
                ctx, info.duration, (double) SEGMENT_DURATION);
            SizeTier tier = SizeTier.from_mb (target_mb);
            // Tiny/Small → forced to codec default (webm/mp4) for
            // imageboard compat; Medium+ → respect the user's selection.
            string resolved_container = SmartOptimizerLogic.resolve_effective_container (
                preferred_codec, tier, ctx.output_container);
            var plan = SmartOptimizerLogic.plan_audio (info, ctx, tier, resolved_container);
            string vf = (ctx.video_filter_chain != null) ? ctx.video_filter_chain : "";

            // ── 2. Early feasibility check ──────────────────────────────
            // Before running any encode, check if the target is even
            // physically plausible.  This saves the user waiting through
            // calibration encodes for a result that was never achievable.
            var budget = SmartOptimizerLogic.compute_size_budget (
                target_mb, resolved_container, tw.encode_duration, info.fps, plan);

            if (budget.video_target_kib <= 0) {
                return make_error_rec (preferred_codec,
                    "%s alone (~%.0f KiB) exceeds the %d MB target."
                        .printf (plan.effective_track_count == 1 ? "Audio track" : "Audio tracks",
                            budget.audio_kib, target_mb));
            }
            if (budget.available_video_kbps < SmartOptimizerLogic.MIN_VIABLE_VIDEO_KBPS) {
                return make_error_rec (preferred_codec,
                    SmartOptimizerLogic.build_infeasibility_message (
                        budget.available_video_kbps, budget.video_target_kib,
                        info.width, info.height));
            }

            // ── 3. Pick sample positions ────────────────────────────────
            // Sample within the effective trim window so analysis matches
            // the frames that will actually be encoded.
            double[] positions = SmartOptimizerLogic.pick_sample_positions_in_window (
                tw.trim_start, tw.encode_duration, tw.sample_segment_duration);

            // ── 3b. Audio measurement (strict tiers, re-encode only) ────
            // Must run before CRF calibration: the solved CRF, the
            // verification encode's corrected target, and the final
            // estimate all derive from budget.video_target_kib.
            yield measure_and_apply_audio_budget (
                input_file, resolved_container, tier, ctx, plan, budget,
                positions, tw.sample_segment_duration, tw.encode_duration,
                temp_run_dir, cancellable);

            // ── 3c. Source complexity profile ───────────────────────────
            // One demux-only ffprobe pass builds a per-second source
            // bitrate profile; only worth it when samples cover a
            // minority of the encode window.
            double[] source_bitrate_profile = {};
            double prospective_coverage = double.min (1.0,
                (double) positions.length * tw.sample_segment_duration
                    / double.max (tw.encode_duration, 0.001));
            if (prospective_coverage < 0.5) {
                source_bitrate_profile = yield probe_source_bitrate_profile (
                    input_file, info.duration, cancellable);
            }

            // ── 4. Content detection ────────────────────────────────────
            ContentProfile profile;
            try {
                cancellable_check (cancellable);
                profile = yield analyze_content (
                    input_file, positions, tw.sample_segment_duration, info, vf, cancellable);
            } catch (IOError.CANCELLED e) {
                throw e;
            } catch (Error e) {
                warning ("Content analysis failed, assuming live-action: %s", e.message);
                profile = ContentProfile () {
                    content_type    = ContentType.LIVE_ACTION,
                    type_confidence = 0.0
                };
            }
            // The user's assertion beats the measurement — see
            // SmartOptimizerLogic.ContentOverride for why that is not just a
            // convenience for animation.
            SmartOptimizerLogic.apply_content_override (
                ref profile, ctx.content_override);
            double detail_score = SmartOptimizerLogic.detail_preservation_score (
                profile, info.source_bit_depth);

            // ── 4b. Bit depth & content-aware, tier-scaled preset ───────
            // Decided before expansion so the speed-probe below encodes at the
            // real target preset/pix_fmt. Neither depends on sample positions.
            var bit_depth = SmartOptimizerLogic.decide_bit_depth (
                info, profile, tier, preferred_codec, ctx.tone_mapping_active);
            bit_depth = SmartOptimizerLogic.apply_delivery_bit_depth_preference (
                bit_depth, ctx.optimize_for_delivery, info, ctx.tone_mapping_active);
            int preset_idx = SmartOptimizerLogic.choose_preset_index (
                profile, tier, preferred_codec);

            // Probe with the settings that will actually be applied. Content
            // type, grain and effort are all settled by this point, so there
            // is no ordering obstacle — the probe simply used to ignore them.
            var encoder_tuning = SmartOptimizerLogic.decide_encoder_tuning (
                preferred_codec,
                SmartOptimizerLogic.effort_from_size_tier (tier),
                profile.content_type, profile.noise_mean, detail_score,
                info.source_bit_depth, ctx.optimize_for_delivery);
            active_tuning = encoder_tuning;

            // ── 4c. Live probe: time-budgeted expansion + RAM-safe jobs ──
            // One short probe encode at the real preset/res/bit-depth measures
            // BOTH per-segment encode time AND peak RSS. Time sizes how far the
            // calibration can expand within the wall-time budget (a flat
            // segment cap that's cheap at 720p is an 8-min stall at 4K); RSS
            // caps how many calibration jobs run in parallel (4× 4K/10-bit
            // encodes ≈ 58 GiB otherwise → swap thrash). Nothing is tuned to
            // this machine — both limits come from the measurement.
            bool adaptive_expanded = false;
            int  base_segments = positions.length;
            int  desired_segments = SmartOptimizerLogic.adaptive_expansion_count (
                profile, base_segments, tw.encode_duration, tw.sample_segment_duration);

            // Probe when expansion is wanted (needs a time estimate) or the
            // source is large enough that parallel calibration could exhaust
            // RAM (needs a memory estimate).
            long source_pixels = (long) info.width * (long) info.height;
            bool run_probe = (desired_segments > 0) || (source_pixels >= PROBE_MIN_PIXELS);

            int    calibration_job_cap   = calibration_parallel_jobs ();
            double secs_per_segment      = -1.0;
            int64  probe_peak_rss_bytes  = 0;
            if (run_probe) {
                try {
                    ProbeResult probe = yield run_speed_memory_probe (
                        input_file, preferred_codec, preset_idx, bit_depth.pix_fmt,
                        vf, tw.sample_segment_duration, tw.trim_start,
                        tw.encode_duration, temp_run_dir, cancellable);
                    secs_per_segment = probe.seconds;
                    probe_peak_rss_bytes = probe.peak_rss;
                    calibration_job_cap = memory_capped_calibration_jobs (probe.peak_rss);
                    warning ("Smart Optimizer: probe %.2fs/segment, peak %.1f GiB/job → "
                        + "calibration parallelism %d (uncapped %d)",
                        secs_per_segment, probe.peak_rss / (1024.0 * 1024.0 * 1024.0),
                        calibration_job_cap, calibration_parallel_jobs ());
                } catch (IOError.CANCELLED e) {
                    throw e;
                } catch (Error e) {
                    warning ("Smart Optimizer: speed/memory probe failed (%s) — "
                        + "no expansion, default parallelism", e.message);
                    secs_per_segment    = -1.0;
                    calibration_job_cap = calibration_parallel_jobs ();
                }
            }

            // Expand only if wanted AND we have a usable time measurement.
            // The budget uses the memory-capped parallelism so the time
            // estimate reflects the calibration that will actually run.
            if (desired_segments > 0 && secs_per_segment > 0.0) {
                int final_segments = SmartOptimizerLogic.budget_expanded_count (
                    desired_segments, base_segments, secs_per_segment,
                    SmartOptimizerLogic.ADAPTIVE_CALIBRATION_BASE_MAX_POINTS + 1,
                    calibration_job_cap,
                    ANALYSIS_TIME_BUDGET_SECONDS,
                    SmartOptimizerLogic.ADAPTIVE_MAX_SEGMENTS);
                warning ("Smart Optimizer: variability wants %d segments → budgeted to "
                    + "%d (base %d)", desired_segments, final_segments, base_segments);
                if (final_segments > base_segments) {
                    positions = SmartOptimizerLogic.pick_sample_positions_n_in_window (
                        tw.trim_start, tw.encode_duration, tw.sample_segment_duration,
                        final_segments);
                    adaptive_expanded = true;
                }
            }

            // ── 4b2. Complexity-weighted extrapolation ──────────────────
            // Correct the linear duration scaling by how the sampled
            // regions' source bitrate compares to the full encode window.
            double extrapolation_weight = SmartOptimizerLogic.compute_extrapolation_weight (
                source_bitrate_profile, positions, tw.sample_segment_duration,
                tw.trim_start, tw.trim_end);

            // ── 5b. Persistent calibration sample cache ────────────────
            // Keyed on everything that shapes a measurement (file
            // identity, codec, preset, pix_fmt, filters, trim window,
            // positions, extrapolation weight) — a re-run that changes
            // only the target size reuses the measured points.
            var cache = SmartOptimizerCache.try_create (
                input_file, preferred_codec, preset_idx, bit_depth.pix_fmt,
                vf, tw.trim_start, tw.encode_duration,
                tw.sample_segment_duration, positions, extrapolation_weight,
                SmartOptimizerLogic.encoder_tuning_key (encoder_tuning));

            // ── 6/7. Calibration, fit, solve, adaptive refinement ───────
            SmartOptimizerLogic.CalibrationModel model;
            try {
                model = yield run_crf_calibration (
                    input_file, preferred_codec, tier, positions,
                    tw.encode_duration, tw.sample_segment_duration, vf,
                    preset_idx, bit_depth.pix_fmt, budget.video_target_kib,
                    extrapolation_weight, cache, intermediate, info,
                    calibration_job_cap, temp_run_dir, cancellable);
            } catch (IOError.CANCELLED e) {
                throw e;
            } catch (Error e) {
                return make_error_rec (preferred_codec, e.message);
            }

            // ── 7b. Verification encode ─────────────────────────────────
            var verification = yield run_verification (
                input_file, preferred_codec, model, positions,
                tw.encode_duration, tw.sample_segment_duration, vf,
                preset_idx, bit_depth.pix_fmt, budget.video_target_kib,
                extrapolation_weight, cache, intermediate,
                temp_run_dir, cancellable);

            // Persist this run's fresh measurements for future runs.
            if (cache != null)
                cache.save ();

            // ── 8. Estimate final size ──────────────────────────────────
            double raw_estimate_kib;
            if (!SmartOptimizerLogic.try_evaluate_model_size_kib (
                    model.qa, model.qb, model.qc, model.predicted_crf,
                    "final estimate", out raw_estimate_kib)) {
                return make_error_rec (preferred_codec,
                    "Smart Optimizer's size model became numerically unstable for this file.\n"
                    + "Try two-pass mode, a different target size, or trimming the input.");
            }

            // Apply model correction from verification if available.
            // If CRF didn't shift, this effectively uses the verified size.
            // If CRF shifted, it applies the measured error ratio to the new
            // model prediction — a reasonable first-order correction.
            double estimated_video_kib_double = raw_estimate_kib
                * (verification.done ? verification.correction : 1.0);
            double estimated_total_kib_double = estimated_video_kib_double
                + budget.audio_kib + budget.container_overhead_kib;
            int estimated_video_kib = 0;
            int estimated_total_kib = 0;
            if (!SmartOptimizerLogic.try_cast_nonnegative_int (
                    estimated_video_kib_double, "estimated video size", out estimated_video_kib)
                || !SmartOptimizerLogic.try_cast_nonnegative_int (
                    estimated_total_kib_double, "estimated total size", out estimated_total_kib)) {
                return make_error_rec (preferred_codec,
                    "Smart Optimizer produced an out-of-range size estimate for this file.\n"
                    + "Try two-pass mode or a less aggressive target.");
            }
            if (estimated_total_kib < estimated_video_kib) {
                warning ("Smart Optimizer: total estimate %d KiB smaller than video estimate %d KiB",
                    estimated_total_kib, estimated_video_kib);
                return make_error_rec (preferred_codec,
                    "Smart Optimizer produced an inconsistent size estimate for this file.\n"
                    + "Try two-pass mode or a less aggressive target.");
            }

            // ── 9. Confidence ───────────────────────────────────────────
            var conf = SmartOptimizerLogic.assess_confidence (
                model, estimated_total_kib, positions.length,
                tw.sample_segment_duration, tw.encode_duration, tw.trim_active,
                info.file_size_bytes, info.duration,
                budget.available_video_kbps, preferred_codec);

            // ── 10/11. Two-pass policy & feasibility flags ──────────────
            var policy = SmartOptimizerLogic.decide_two_pass (
                tier, target_mb, budget.target_total_kib,
                budget.available_video_kbps, estimated_total_kib,
                conf.confidence, model.crf_at_max, tw.trim_active,
                conf.source_total_kbps, tw.encode_duration,
                info.file_size_bytes, conf.sample_coverage, profile);

            // ── 11b. Downscale advisory ─────────────────────────────────
            // Purely informational: when bits-per-pixel is low for the
            // codec, suggest a concrete resolution in the notes.
            var downscale = SmartOptimizerLogic.assess_downscale (
                preferred_codec, policy.target_video_kbps,
                info.width, info.height, info.fps,
                vf.contains ("scale") || vf.contains ("crop"));

            // ── 12. Build the recommendation ────────────────────────────
            string preset_label = format_preset_label (preferred_codec, preset_idx);
            string notes = build_notes (
                preferred_codec, target_mb, tier, ctx, vf, info, tw, plan,
                budget, profile, bit_depth,
                SmartOptimizerLogic.tier_content_influence (tier),
                preset_label, model, verification, conf, policy, downscale,
                estimated_total_kib, extrapolation_weight,
                positions.length, adaptive_expanded,
                intermediate.path != null,
                secs_per_segment, probe_peak_rss_bytes, calibration_job_cap);

            return OptimizationRecommendation () {
                codec                 = preferred_codec,
                crf                   = model.predicted_crf,
                preset                = preset_label,
                two_pass              = policy.recommend_two_pass,
                target_bitrate_kbps   = policy.target_video_kbps,
                estimated_size_kib    = estimated_total_kib,
                notes                 = notes,
                is_impossible         = policy.is_impossible,
                content_type          = profile.content_type,
                grain_score           = profile.noise_mean,
                detail_score          = detail_score,
                native_sharpness      = encoder_tuning.native_sharpness,
                confidence            = conf.confidence,
                size_tier             = tier,
                recommended_audio_kbps = plan.per_stream_kbps,
                audio_encode_kbps     = plan.encode_target_kbps,
                total_audio_budget_kbps = plan.total_budget_kbps,
                audio_track_count     = plan.effective_track_count,
                preserve_all_audio_tracks_effective = plan.preserve_all_effective,
                stream_copy_audio     = plan.use_stream_copy,
                strip_metadata        = (tier == SizeTier.TINY),
                recommended_pix_fmt   = bit_depth.pix_fmt,
                resolved_container    = resolved_container,
                target_size_kib       = (int) budget.target_total_kib,
                // Shared decision axis — see SmartOptimizerLogic.EncodeEffort.
                effort                = SmartOptimizerLogic.effort_from_size_tier (tier),
                force_compat_container =
                    SmartOptimizerLogic.tier_forces_compat_container (tier),
                // This is the size solver: size was pinned, quality is the
                // readout.  VMAF stays unmeasured until the quality solver.
                pinned_axis           = PinnedAxis.SIZE,
                estimated_vmaf        = 0.0,
                vmaf_measured         = false,
                fast_decode           = ctx.optimize_for_delivery,
                source_bit_depth      = info.source_bit_depth
            };
        } finally {
            active_tuning = null;
            if (intermediate.path != null)
                cleanup_file (intermediate.path);
            cleanup_temp_run_dir (temp_run_dir);
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // QUALITY MODE PIPELINE
    // ════════════════════════════════════════════════════════════════════════

    /**
     * The second solver: pin a perceptual target, let size float, solve for the
     * CRF that achieves it ON THIS SOURCE.
     *
     * Shares the analysis prologue with optimize_for_target_size — probe, trim
     * window, sampling, content analysis, bit depth, preset — and diverges only
     * at the objective. Where the size solver fits ln(size) against CRF and
     * solves for a byte count, this fits VMAF against CRF and solves for a
     * score. Same probes, same least-squares core, same sample segments.
     *
     * Differences from Size Mode, all deliberate:
     *   - The lossless intermediate is mandatory (it is the VMAF reference),
     *     and the segment count is reduced to fit its budget rather than
     *     abandoning it.
     *   - No two-pass. Two-pass exists to hit a byte count.
     *   - No container forcing. That is imageboard-size policy.
     *   - The calibration cache is not used: it stores sizes only, and a
     *     cached size still leaves the VMAF unmeasured, so there is nothing to
     *     save. Extending it to hold VMAF is a worthwhile follow-up.
     */
    public async OptimizationRecommendation optimize_for_quality (
        string                            input_file,
        SmartOptimizerLogic.QualityIntent intent          = SmartOptimizerLogic.QualityIntent.MEDIUM,
        string                            preferred_codec = "x265",
        OptimizationContext               ctx             = OptimizationContext (),
        Cancellable?                      cancellable     = null
    ) throws Error {
        yield require_vmaf (cancellable);

        string? temp_run_dir = ConversionUtils.create_managed_temp_run_dir (
            "smart-optimizer", "quality");
        var intermediate = new IntermediateHolder ();

        try {
            // ── 1. Probe ────────────────────────────────────────────────
            SmartOptimizerVideoInfo info;
            try {
                info = yield probe_video (input_file, cancellable);
            } catch (Error e) {
                if (e is IOError.CANCELLED) throw e;
                warning ("Probe failed: %s", e.message);
                return make_error_rec (preferred_codec,
                    "Could not read video file: %s".printf (e.message));
            }
            if (info.duration <= 0) {
                return make_error_rec (preferred_codec,
                    "Video has zero duration — ffprobe could not determine the length.");
            }
            info.duration = yield verify_probed_duration (
                input_file, info.duration, cancellable);

            // ── 2. Trim window, audio, container ────────────────────────
            var tw = SmartOptimizerLogic.resolve_trim_window (
                ctx, info.duration, (double) SEGMENT_DURATION);

            // Nominal tier feeds the still-tier-typed helpers; it maps to the
            // same point on the shared effort axis as the intent does.
            SizeTier nominal_tier =
                SmartOptimizerLogic.nominal_size_tier_for_intent (intent);

            // Container: respect the user's choice. Quality Mode has no size
            // constraint, so the imageboard compatibility forcing must not
            // apply — hence NOT resolve_effective_container(nominal_tier).
            string resolved_container =
                (ctx.output_container != null && ctx.output_container.length > 0)
                    ? ctx.output_container
                    : SmartOptimizerLogic.codec_default_container (preferred_codec);

            // Audio planned at the floored tier: with no byte budget there is
            // no reason to refuse multi-track preservation.
            var plan = SmartOptimizerLogic.plan_audio (
                info, ctx, SmartOptimizerLogic.quality_audio_tier (intent),
                resolved_container);
            string vf = (ctx.video_filter_chain != null) ? ctx.video_filter_chain : "";

            // ── 3. Sample positions ─────────────────────────────────────
            double[] positions = SmartOptimizerLogic.pick_sample_positions_in_window (
                tw.trim_start, tw.encode_duration, tw.sample_segment_duration);

            // ── 4. Content analysis ─────────────────────────────────────
            ContentProfile profile;
            try {
                cancellable_check (cancellable);
                profile = yield analyze_content (
                    input_file, positions, tw.sample_segment_duration,
                    info, vf, cancellable);
            } catch (IOError.CANCELLED e) {
                throw e;
            } catch (Error e) {
                warning ("Content analysis failed, assuming live-action: %s", e.message);
                profile = ContentProfile () {
                    content_type    = ContentType.LIVE_ACTION,
                    type_confidence = 0.0
                };
            }
            // The user's assertion beats the measurement — see
            // SmartOptimizerLogic.ContentOverride for why that is not just a
            // convenience for animation.
            SmartOptimizerLogic.apply_content_override (
                ref profile, ctx.content_override);
            double detail_score = SmartOptimizerLogic.detail_preservation_score (
                profile, info.source_bit_depth);

            // ── 5. Bit depth, preset, effective target ──────────────────
            var bit_depth = SmartOptimizerLogic.decide_bit_depth (
                info, profile, nominal_tier, preferred_codec, ctx.tone_mapping_active);
            bit_depth = SmartOptimizerLogic.apply_delivery_bit_depth_preference (
                bit_depth, ctx.optimize_for_delivery, info, ctx.tone_mapping_active);
            int preset_idx = SmartOptimizerLogic.choose_preset_index (
                profile, nominal_tier, preferred_codec);

            // Same reasoning as Size Mode: probe what will be applied.
            var encoder_tuning = SmartOptimizerLogic.decide_encoder_tuning (
                preferred_codec,
                SmartOptimizerLogic.effort_from_quality_intent (intent),
                profile.content_type, profile.noise_mean, detail_score,
                info.source_bit_depth, ctx.optimize_for_delivery);
            active_tuning = encoder_tuning;
            var target = SmartOptimizerLogic.resolve_quality_target (intent, profile);

            // ── 6. Constrain samples to the VMAF reference budget ───────
            // The intermediate is the reference, so it must be built. When it
            // would be too large, reduce segments instead of skipping it.
            int max_segments = SmartOptimizerLogic.max_segments_for_intermediate_budget (
                info.width, info.height, info.fps, info.source_bit_depth,
                tw.sample_segment_duration, SmartOptimizerLogic.INTERMEDIATE_MAX_BYTES);
            int positions_before = positions.length;
            if (max_segments > 0)
                positions = SmartOptimizerLogic.limit_positions (positions, max_segments);
            bool positions_trimmed = (positions.length < positions_before);
            if (positions_trimmed) {
                warning ("Smart Optimizer: reduced sampling from %d to %d segments "
                    + "to keep the VMAF reference under %.1f GiB",
                    positions_before, positions.length,
                    SmartOptimizerLogic.INTERMEDIATE_MAX_BYTES / (1024.0 * 1024.0 * 1024.0));
            }

            // Replace the assumed audio budget with a measurement before
            // anything reserves against it: the reservation is part of the
            // reported size.
            yield measure_quality_audio_budget (
                input_file, resolved_container, ctx, plan, positions,
                tw.sample_segment_duration, tw.encode_duration, tw.trim_start,
                temp_run_dir, cancellable);

            // The reference is built lazily, on the first probe that actually
            // misses the cache. A fully-cached re-run needs no encoding at all,
            // so building it up front would be pure waste — and for 4K it is
            // the single most expensive step in the pipeline.

            // ── 7. Probe the CRF↔VMAF (and CRF↔size) response ───────────
            double sample_duration = double.min (
                (double) positions.length * tw.sample_segment_duration,
                tw.encode_duration);
            int threads = encoder_threads_per_job (1);

            // Cache keyed on everything that shapes a measurement. Preset is
            // part of that key and preset varies with intent, so switching
            // intent correctly misses — a different preset genuinely produces
            // different sizes AND different scores. The win is re-running the
            // SAME intent after changing something the key does not cover
            // (container, audio, delivery toggle), which currently costs a
            // full 3-5 probe re-measure.
            var qcache = SmartOptimizerCache.try_create (
                input_file, preferred_codec, preset_idx, bit_depth.pix_fmt,
                vf, tw.trim_start, tw.encode_duration,
                tw.sample_segment_duration, positions, 1.0,
                SmartOptimizerLogic.encoder_tuning_key (encoder_tuning));

            int[] crfs = SmartOptimizerLogic.pick_quality_calibration_crfs (
                preferred_codec, intent);
            double[] vmafs = {};
            double[] sizes = {};
            int[] measured_crfs = {};
            int cached_points = 0;

            try {
                foreach (int crf in crfs) {
                    double c_size = 0.0, c_vmaf = 0.0;
                    if (qcache != null
                            && qcache.lookup_with_vmaf (crf, out c_size, out c_vmaf)) {
                        measured_crfs += crf;
                        vmafs += c_vmaf;
                        sizes += c_size;
                        cached_points++;
                        continue;
                    }
                    yield ensure_quality_reference (
                        intermediate, input_file, positions,
                        tw.sample_segment_duration, vf, bit_depth.pix_fmt,
                        info, temp_run_dir, cancellable);
                    var m = yield calibration_probe_with_vmaf (
                        preferred_codec, crf, preset_idx, bit_depth.pix_fmt,
                        intermediate.path, tw.encode_duration, sample_duration,
                        1.0, info.width, threads, temp_run_dir, cancellable);
                    if (!m.vmaf_measured)
                        continue;
                    measured_crfs += crf;
                    vmafs += m.vmaf;
                    sizes += m.size_kib;
                    if (qcache != null)
                        qcache.record_with_vmaf (crf, m.size_kib, m.vmaf);
                }
            } catch (IOError.CANCELLED e) {
                throw e;
            } catch (Error e) {
                return make_error_rec (preferred_codec,
                    "Quality calibration failed: %s".printf (e.message));
            }

            // ── 7b. Recover from an over-saturated bracket ──────────────
            // A fitted answer is only a starting point. If saturation leaves
            // too little gradient to fit (including an all-saturated ladder),
            // search upward until an actual encode crosses the selected
            // ceiling, then narrow that bracket to adjacent integral CRFs.
            // Stop only at the codec limit. High/Ultra screencasts are the
            // explicit exception: their rule-based cap protects text.
            var m0 = SmartOptimizerLogic.solve_quality_crf (
                measured_crfs, vmafs, target.target_vmaf, preferred_codec);
            bool refined = false;          // extra probes after saturation
            bool bracket_refined = false;  // extra probes to bracket the answer
            bool saturation_direct_solution = false;
            bool saturation_codec_limit = false;

            if (m0.degenerate && m0.saturated_points_dropped > 0
                    && target.enforce_vmaf_ceiling) {
                int crf_min, crf_max;
                SmartOptimizerLogic.crf_range_for_codec (
                    preferred_codec, out crf_min, out crf_max);
                int above_crf = -1;
                int below_crf = -1;
                for (int i = 0; i < measured_crfs.length; i++) {
                    if (vmafs[i] > target.target_vmaf) {
                        above_crf = measured_crfs[i];
                    } else if (above_crf >= 0) {
                        below_crf = measured_crfs[i];
                        break;
                    }
                }
                int next_crf = (below_crf >= 0) ? -1
                    : SmartOptimizerLogic.next_saturation_search_crf (
                        above_crf, crf_max);
                try {
                    while (below_crf < 0 && above_crf < crf_max) {
                        var m = yield quality_measurement_at_crf (
                            next_crf, qcache, intermediate, input_file, positions,
                            tw.sample_segment_duration, vf, info, preferred_codec,
                            preset_idx, bit_depth.pix_fmt, tw.encode_duration,
                            sample_duration, threads, temp_run_dir, cancellable);
                        if (!m.vmaf_measured) {
                            return make_error_rec (preferred_codec,
                                "Could not verify the quality ceiling at CRF %d.\n"
                                .printf (next_crf)
                                + "Auto-convert was not started because the "
                                + "selected quality ceiling could not be guaranteed.");
                        }
                        SmartOptimizerLogic.append_quality_calibration_sample (
                            ref measured_crfs, ref vmafs, ref sizes,
                            next_crf, m.vmaf, m.size_kib);
                        if (m.from_cache)
                            cached_points++;
                        refined = true;
                        if (m.vmaf <= target.target_vmaf) {
                            below_crf = next_crf;
                            break;
                        }
                        above_crf = next_crf;
                        if (next_crf >= crf_max)
                            break;
                        next_crf = SmartOptimizerLogic.next_saturation_search_crf (
                            next_crf, crf_max);
                    }

                    // Coarse probing found the crossing. Narrow it so the
                    // chosen integer is the closest one at or below the ceiling.
                    int midpoint = SmartOptimizerLogic.next_quality_bracket_crf (
                        above_crf, below_crf);
                    while (midpoint >= 0) {
                        var m = yield quality_measurement_at_crf (
                            midpoint, qcache, intermediate, input_file, positions,
                            tw.sample_segment_duration, vf, info, preferred_codec,
                            preset_idx, bit_depth.pix_fmt, tw.encode_duration,
                            sample_duration, threads, temp_run_dir, cancellable);
                        if (!m.vmaf_measured) {
                            return make_error_rec (preferred_codec,
                                "Could not verify the quality ceiling at CRF %d.\n"
                                .printf (midpoint)
                                + "Auto-convert was not started because the "
                                + "selected quality ceiling could not be guaranteed.");
                        }
                        SmartOptimizerLogic.append_quality_calibration_sample (
                            ref measured_crfs, ref vmafs, ref sizes,
                            midpoint, m.vmaf, m.size_kib);
                        if (m.from_cache)
                            cached_points++;
                        if (m.vmaf <= target.target_vmaf)
                            below_crf = midpoint;
                        else
                            above_crf = midpoint;
                        midpoint = SmartOptimizerLogic.next_quality_bracket_crf (
                            above_crf, below_crf);
                    }
                } catch (IOError.CANCELLED e) {
                    throw e;
                } catch (Error e) {
                    return make_error_rec (preferred_codec,
                        "Quality ceiling search failed: %s\n".printf (e.message)
                        + "Auto-convert was not started because the selected "
                        + "quality ceiling could not be guaranteed.");
                }

                int direct_crf = (below_crf > 0) ? below_crf : crf_max;
                saturation_codec_limit = (below_crf <= 0);
                saturation_direct_solution = true;

                // Preserve a real fitted model when enough gradient was found,
                // but make the measured bracket answer authoritative.
                m0 = SmartOptimizerLogic.solve_quality_crf (
                    measured_crfs, vmafs, target.target_vmaf, preferred_codec);
                if (m0.degenerate) {
                    m0.degenerate = false;
                    m0.cal_crfs = measured_crfs;
                    m0.cal_vmafs = vmafs;
                    m0.qa = vmafs[vmafs.length - 1];
                    m0.qb = 0.0;
                    m0.qc = 0.0;
                }
                m0.predicted_crf = direct_crf;
                for (int i = 0; i < measured_crfs.length; i++) {
                    if (measured_crfs[i] == direct_crf) {
                        m0.predicted_vmaf = vmafs[i];
                        break;
                    }
                }
                m0.crf_at_max = (direct_crf >= crf_max);
            } else if (m0.degenerate && !target.enforce_vmaf_ceiling
                    && target.crf_cap > 0 && measured_crfs.length > 0) {
                // High/Ultra screen content does not need a VMAF gradient to
                // choose its answer: the explicit CRF cap is authoritative and
                // the final candidate is still measured for honest reporting.
                m0.degenerate = false;
                m0.cal_crfs = measured_crfs;
                m0.cal_vmafs = vmafs;
                m0.qa = vmafs[vmafs.length - 1];
                m0.qb = 0.0;
                m0.qc = 0.0;
                m0.predicted_crf = measured_crfs[measured_crfs.length - 1];
                m0.predicted_vmaf = m0.qa;
                saturation_direct_solution = true;
            } else if (m0.degenerate && target.enforce_vmaf_ceiling
                    && measured_crfs.length > 0) {
                // A partially saturated ladder can leave only one or two usable
                // points. Keep extending it until the curve is fit-capable or
                // the codec has nowhere left to go.
                int crf_min, crf_max;
                SmartOptimizerLogic.crf_range_for_codec (
                    preferred_codec, out crf_min, out crf_max);
                int next_crf = SmartOptimizerLogic.next_saturation_search_crf (
                    measured_crfs[measured_crfs.length - 1], crf_max);
                try {
                    while (m0.degenerate && next_crf >= 0
                            && !SmartOptimizerLogic.calibration_contains_crf (
                                measured_crfs, next_crf)) {
                        var m = yield quality_measurement_at_crf (
                            next_crf, qcache, intermediate, input_file, positions,
                            tw.sample_segment_duration, vf, info, preferred_codec,
                            preset_idx, bit_depth.pix_fmt, tw.encode_duration,
                            sample_duration, threads, temp_run_dir, cancellable);
                        if (m.vmaf_measured) {
                            SmartOptimizerLogic.append_quality_calibration_sample (
                                ref measured_crfs, ref vmafs, ref sizes,
                                next_crf, m.vmaf, m.size_kib);
                            if (m.from_cache)
                                cached_points++;
                            refined = true;
                            m0 = SmartOptimizerLogic.solve_quality_crf (
                                measured_crfs, vmafs, target.target_vmaf,
                                preferred_codec);
                        }
                        if (next_crf >= crf_max)
                            break;
                        next_crf = SmartOptimizerLogic.next_saturation_search_crf (
                            next_crf, crf_max);
                    }
                } catch (IOError.CANCELLED e) {
                    throw e;
                } catch (Error e) {
                    warning ("Smart Optimizer: saturation refinement failed: %s", e.message);
                }
            }

            bool all_saturated = (measured_crfs.length > 0
                && m0.saturated_points_dropped == measured_crfs.length);

            if (m0.degenerate && !all_saturated && !saturation_direct_solution) {
                return make_error_rec (preferred_codec,
                    "Could not measure a usable quality curve for this video.\n"
                    + "Too few probes produced a score — the source may be "
                    + "corrupt or too short to sample.");
            }

            // ── 7c. Refine an off-centre bracket ───────────────────────
            // A solve landing outside the probed window is extrapolation, and
            // confidence is docked for it. One more probe near the answer
            // usually converts that into interpolation. Size Mode has done
            // this since v5 (pick_adaptive_calibration_crfs); Quality Mode was
            // only refining on saturation, so it accepted a low-confidence
            // answer rather than spending a probe to earn a better one.
            //
            // Observed: an SVT-AV1 Medium run probed {26,32,38} and solved 41,
            // reporting 58% confidence (0.75 extrapolation x 0.77 coverage)
            // despite verifying to within 0.11 VMAF. The ladders for SVT-AV1
            // and VP9 were derived by analogy from the measured x265 ones, so
            // being off-centre is expected until they get a sweep of their own.
            if (!m0.degenerate && !saturation_direct_solution
                    && measured_crfs.length > 0
                    && SmartOptimizerLogic.should_refine_calibration_window (
                        m0.predicted_crf, measured_crfs)) {
                int crf_min_r, crf_max_r;
                SmartOptimizerLogic.crf_range_for_codec (
                    preferred_codec, out crf_min_r, out crf_max_r);
                int[] extra_crfs = SmartOptimizerLogic.pick_adaptive_calibration_crfs (
                    m0.predicted_crf, measured_crfs, crf_min_r, crf_max_r,
                    measured_crfs.length + 1);      // one follow-up probe
                try {
                    foreach (int crf in extra_crfs) {
                        double rc_size = 0.0, rc_vmaf = 0.0;
                        if (qcache != null
                                && qcache.lookup_with_vmaf (crf, out rc_size, out rc_vmaf)) {
                            measured_crfs += crf;
                            vmafs += rc_vmaf;
                            sizes += rc_size;
                            cached_points++;
                            bracket_refined = true;
                            continue;
                        }
                        yield ensure_quality_reference (
                            intermediate, input_file, positions,
                            tw.sample_segment_duration, vf, bit_depth.pix_fmt,
                            info, temp_run_dir, cancellable);
                        var rm = yield calibration_probe_with_vmaf (
                            preferred_codec, crf, preset_idx, bit_depth.pix_fmt,
                            intermediate.path, tw.encode_duration, sample_duration,
                            1.0, info.width, threads, temp_run_dir, cancellable);
                        if (!rm.vmaf_measured)
                            continue;
                        measured_crfs += crf;
                        vmafs += rm.vmaf;
                        sizes += rm.size_kib;
                        if (qcache != null)
                            qcache.record_with_vmaf (crf, rm.size_kib, rm.vmaf);
                        bracket_refined = true;
                    }
                } catch (IOError.CANCELLED e) {
                    throw e;
                } catch (Error e) {
                    warning ("Smart Optimizer: bracket refinement failed: %s", e.message);
                }
                if (bracket_refined) {
                    m0 = SmartOptimizerLogic.solve_quality_crf (
                        measured_crfs, vmafs, target.target_vmaf, preferred_codec);
                }
            }

            if (all_saturated && !saturation_direct_solution) {
                // Model the response as flat at the measured value: within the
                // probed range that is precisely what saturation means. This
                // branch is the High/Ultra screen-text exception; strict
                // ceilings took the measured search path above.
                m0.degenerate = false;
                m0.cal_crfs = measured_crfs;
                m0.cal_vmafs = vmafs;
                m0.qa = vmafs[vmafs.length - 1];
                m0.qb = 0.0;
                m0.qc = 0.0;
                m0.predicted_crf = measured_crfs[measured_crfs.length - 1];
                m0.predicted_vmaf = m0.qa;
                warning ("Smart Optimizer: every probe cleared VMAF %.1f — "
                    + "recommending the highest probed CRF (%d, VMAF %.2f)",
                    SmartOptimizerLogic.VMAF_SATURATION_THRESHOLD,
                    m0.predicted_crf, m0.predicted_vmaf);
            }

            // ── 8. Size curve from the same probes ──────────────────────
            double sa = 0.0, sb = 0.0, sc = 0.0;
            bool size_degenerate = true;
            if (measured_crfs.length >= 2) {
                SmartOptimizerLogic.fit_calibration_curve (
                    measured_crfs, sizes, out sa, out sb, out sc, out size_degenerate);
            }

            // ── 9. Content CRF cap ──────────────────────────────────────
            // The intent's VMAF IS the ceiling. Once the encode measures the
            // score that was asked for, further bytes buy quality the user
            // explicitly said they did not want, so the solve itself is the
            // stopping rule and nothing else needs to bound it.
            //
            // There used to be a second guard here capping output at 100% of
            // the SOURCE's byte count. It was removed because a byte
            // comparison only means "wasted bits" when the pipeline preserves
            // resolution, frame rate, duration, bit depth and codec
            // efficiency. Break any one and it clamps honest encodes: an
            // upscale to 4K needs ~2.2x the bytes at identical CRF, frame
            // interpolation doubles the frames, and re-encoding to a less
            // efficient codec legitimately costs more for equal quality (a
            // case the old comment already conceded as a "known trade-off").
            // Every one of those degraded quality below the requested target
            // for a reason that was never about quality.
            int capped_crf = SmartOptimizerLogic.apply_quality_crf_cap (
                m0.predicted_crf, target);
            bool crf_capped = (capped_crf != m0.predicted_crf);

            // Audio and container overhead still have to be reserved — not to
            // bound anything now, but because the reported size is the whole
            // file and the curve models video alone.
            double audio_kib = SmartOptimizerLogic.compute_reserved_audio_kib (
                plan.selected_sources, plan.use_stream_copy, plan.per_stream_kbps,
                plan.total_budget_kbps, tw.encode_duration);
            double overhead_kib = SmartOptimizerLogic.container_overhead_kib_estimate (
                resolved_container, tw.encode_duration, info.fps,
                plan.selected_sources, plan.use_stream_copy,
                plan.effective_track_count);

            int final_crf = capped_crf;
            double achieved_vmaf = SmartOptimizerLogic.evaluate_vmaf_at_crf (
                m0.qa, m0.qb, m0.qc, final_crf);
            double estimated_video_kib = 0.0;
            if (!size_degenerate) {
                SmartOptimizerLogic.try_evaluate_model_size_kib (
                    sa, sb, sc, final_crf, "quality size estimate",
                    out estimated_video_kib);
            }

            // ── 9b. Verification and ceiling correction ────────────────
            // The model chooses only a starting CRF. Measure the actual answer;
            // whenever it is above a hard ceiling, raise CRF one step and
            // measure again. Auto-convert cannot begin until this loop accepts
            // the result or proves that the codec's maximum CRF cannot reach it.
            var verification = new SmartOptimizerLogic.VmafVerification ();
            verification.initial_crf = final_crf;
            int verify_crf_min, verify_crf_max;
            SmartOptimizerLogic.crf_range_for_codec (
                preferred_codec, out verify_crf_min, out verify_crf_max);

            while (true) {
                verification.done = false;
                verification.verified_crf = final_crf;
                verification.predicted_vmaf =
                    SmartOptimizerLogic.evaluate_vmaf_at_crf (
                        m0.qa, m0.qb, m0.qc, final_crf);

                for (int i = 0; i < measured_crfs.length; i++) {
                    if (measured_crfs[i] == final_crf) {
                        verification.done = true;
                        verification.measured_vmaf = vmafs[i];
                        estimated_video_kib = sizes[i];
                        break;
                    }
                }

                if (!verification.done) {
                    try {
                        var v = yield quality_measurement_at_crf (
                            final_crf, qcache, intermediate, input_file, positions,
                            tw.sample_segment_duration, vf, info, preferred_codec,
                            preset_idx, bit_depth.pix_fmt, tw.encode_duration,
                            sample_duration, threads, temp_run_dir, cancellable);
                        if (v.vmaf_measured) {
                            verification.done = true;
                            verification.measured_vmaf = v.vmaf;
                            estimated_video_kib = v.size_kib;
                            if (v.from_cache)
                                cached_points++;
                        }
                    } catch (IOError.CANCELLED e) {
                        throw e;
                    } catch (Error e) {
                        warning ("Smart Optimizer: quality verification failed: %s",
                            e.message);
                    }
                }

                if (!verification.done) {
                    if (target.enforce_vmaf_ceiling) {
                        return make_error_rec (preferred_codec,
                            "Could not verify VMAF at CRF %d.\n".printf (final_crf)
                            + "Auto-convert was not started because the selected "
                            + "quality ceiling could not be guaranteed.");
                    }
                    break;
                }

                verification.delta =
                    verification.measured_vmaf - verification.predicted_vmaf;
                achieved_vmaf = verification.measured_vmaf;

                var ceiling_decision = SmartOptimizerLogic.decide_quality_ceiling (
                    target, verification.measured_vmaf, final_crf, verify_crf_max);
                if (ceiling_decision
                        == SmartOptimizerLogic.QualityCeilingDecision.RAISE_CRF) {
                    final_crf++;
                    verification.ceiling_corrections++;
                    continue;
                }
                if (ceiling_decision
                        == SmartOptimizerLogic.QualityCeilingDecision.CODEC_LIMIT) {
                    verification.ceiling_unreachable = true;
                } else if (ceiling_decision == SmartOptimizerLogic
                        .QualityCeilingDecision.TEXT_PROTECTION_EXCEPTION) {
                    verification.text_protection_exception = true;
                }
                break;
            }

            // The saturation search can know this before final verification;
            // retain the fact even if the maximum-CRF sample was reused.
            if (saturation_codec_limit)
                verification.ceiling_unreachable = true;

            // ── 10. Confidence ─────────────────────────────────────────
            double coverage = (tw.encode_duration > 0.0)
                ? double.min (1.0, sample_duration / tw.encode_duration) : 0.0;
            double confidence = SmartOptimizerLogic.assess_quality_confidence (
                m0, coverage, target.vmaf_reliable, verification);
            if (all_saturated) {
                // A saturated model carries no gradient, regardless of whether
                // the result came from a codec limit or the text exception.
                confidence *= 0.6;
            }

            // ── 11. Estimated size ─────────────────────────────────────
            int estimated_total_kib = 0;
            SmartOptimizerLogic.try_cast_nonnegative_int (
                estimated_video_kib + audio_kib + overhead_kib,
                "quality estimated size", out estimated_total_kib);

            if (qcache != null)
                qcache.save ();

            string preset_label = format_preset_label (preferred_codec, preset_idx);
            string notes = build_quality_notes (
                preferred_codec, intent, target, info, tw, plan, profile,
                bit_depth, preset_label, m0, measured_crfs, vmafs, sizes,
                final_crf, achieved_vmaf, estimated_total_kib,
                confidence, coverage, positions.length, positions_trimmed,
                crf_capped, refined, verification, all_saturated,
                cached_points, bracket_refined);

            return OptimizationRecommendation () {
                codec                 = preferred_codec,
                crf                   = final_crf,
                preset                = preset_label,
                // Two-pass exists to hit a byte count; there is no byte count.
                two_pass              = false,
                target_bitrate_kbps   = 0,
                estimated_size_kib    = estimated_total_kib,
                notes                 = notes,
                is_impossible         = false,
                content_type          = profile.content_type,
                grain_score           = profile.noise_mean,
                detail_score          = detail_score,
                native_sharpness      = encoder_tuning.native_sharpness,
                confidence            = confidence,
                // Size Mode's reporting field; unused when quality is pinned.
                size_tier             = nominal_tier,
                recommended_audio_kbps = plan.per_stream_kbps,
                audio_encode_kbps     = plan.encode_target_kbps,
                total_audio_budget_kbps = plan.total_budget_kbps,
                audio_track_count     = plan.effective_track_count,
                preserve_all_audio_tracks_effective = plan.preserve_all_effective,
                stream_copy_audio     = plan.use_stream_copy,
                strip_metadata        = false,
                recommended_pix_fmt   = bit_depth.pix_fmt,
                resolved_container    = resolved_container,
                target_size_kib       = 0,
                effort                = SmartOptimizerLogic.effort_from_quality_intent (intent),
                // Imageboard compatibility forcing is a size policy.
                force_compat_container = false,
                pinned_axis           = PinnedAxis.QUALITY,
                estimated_vmaf        = achieved_vmaf,
                vmaf_measured         = true,
                fast_decode           = ctx.optimize_for_delivery,
                source_bit_depth      = info.source_bit_depth
            };
        } finally {
            active_tuning = null;
            if (intermediate.path != null)
                cleanup_file (intermediate.path);
            cleanup_temp_run_dir (temp_run_dir);
        }
    }

    // Above this duration, measuring the whole audio track costs enough that
    // sampling is preferable. Opus runs far faster than realtime, so a
    // half-hour track measures in seconds against a Quality Mode run already
    // measured in minutes.
    private const double QUALITY_AUDIO_FULL_MEASURE_MAX_SECONDS = 1800.0;

    /**
     * Replace Quality Mode's assumed audio budget with a measurement.
     *
     * The effort level supplies a NOMINAL bitrate (192 kbps at Medium), but
     * what the encoder actually emits depends on the content: Opus VBR
     * collapses quiet material to a fraction of its nominal rate. Measured on
     * a real source whose audio averages −38.2 dB, a 192 kbps reservation
     * produced 7.9 kbps of output — a 3.1 MiB over-estimate on a 10 MiB file,
     * which accounted for that run's ENTIRE size prediction error (the video
     * model was accurate to 0.9%).
     *
     * Over-reserving is purely a reporting error in Quality Mode now that
     * nothing bounds the output by byte count — but it is still the largest
     * single source of size-prediction error, so it is worth measuring.
     *
     * Where affordable this measures the WHOLE track rather than sampling.
     * Size Mode samples three windows and floors the result at a fraction of
     * the budget, because a silent sample from an otherwise-loud track would
     * under-reserve and blow a hard size target. That floor would have been
     * wrong here — this track is quiet end to end, so the measurement was
     * right and the floor would have inflated it sixfold. Measuring the whole
     * track removes the sampling risk the floor exists to cover, so the floor
     * is only applied when sampling is actually used.
     */
    private async void measure_quality_audio_budget (
        string        input_file,
        string        resolved_container,
        OptimizationContext ctx,
        SmartOptimizerLogic.AudioPlan plan,
        double[]      positions,
        double        sample_segment_duration,
        double        encode_duration,
        double        trim_start,
        string?       temp_run_dir,
        Cancellable?  cancellable
    ) throws Error {
        if (plan.use_stream_copy
                || ctx.strip_audio
                || ctx.audio_bitrate_kbps_override > 0
                || plan.effective_track_count < 1
                || plan.encode_target_kbps <= 0
                || plan.probed_first_codec.length == 0) {
            return;
        }

        bool full_track = (encode_duration > 0.0
            && encode_duration <= QUALITY_AUDIO_FULL_MEASURE_MAX_SECONDS);
        double[] measure_positions = full_track
            ? new double[] { trim_start }
            : positions;
        double measure_duration = full_track
            ? encode_duration
            : sample_segment_duration;

        // Measure at the rate the encode will use.  The measurement refines
        // what the output will WEIGH; it must never move the encoder target,
        // which has to stay on a rung the applier can select.
        int target_kbps = plan.encode_target_kbps;

        int measured_kbps;
        try {
            cancellable_check (cancellable);
            measured_kbps = yield measure_audio_bitrate (
                input_file, resolved_container, measure_positions,
                measure_duration, target_kbps, cancellable, temp_run_dir);
        } catch (IOError.CANCELLED e) {
            throw e;
        } catch (Error e) {
            warning ("Smart Optimizer: audio measurement failed (%s) — keeping "
                + "the %d kbps budget", e.message, target_kbps);
            return;
        }
        if (measured_kbps <= 0)
            return;

        int raw_kbps = measured_kbps;
        bool floored = false;
        if (!full_track) {
            measured_kbps = SmartOptimizerLogic.floor_measured_audio_kbps (
                measured_kbps, target_kbps);
            floored = (measured_kbps != raw_kbps);
        }

        // A measurement far above the nominal rate means the probe is wrong,
        // not the assumption.
        if (measured_kbps > target_kbps * 2) {
            warning ("Smart Optimizer: measured audio %d kbps exceeds twice the "
                + "%d kbps budget — ignoring", measured_kbps, target_kbps);
            return;
        }

        warning ("Smart Optimizer: audio measured at %d kbps (%s), replacing the "
            + "%d kbps reserve", measured_kbps,
            full_track ? "whole track" : "sampled", plan.per_stream_kbps);

        plan.audio_measured    = true;
        plan.measured_raw_kbps = raw_kbps;
        plan.measured_kbps     = measured_kbps;
        plan.measured_floored  = floored;
        plan.per_stream_kbps   = measured_kbps;
        plan.total_budget_kbps = measured_kbps * int.max (1, plan.effective_track_count);
    }

    /**
     * Build the VMAF reference on first need, and fail loudly if it cannot be
     * built — Quality Mode has no fallback, since without a reference there is
     * nothing to measure against.
     */
    private async void ensure_quality_reference (
        IntermediateHolder holder,
        string        input_file,
        double[]      positions,
        double        segment_duration,
        string        vf,
        string        pix_fmt,
        SmartOptimizerVideoInfo info,
        string?       temp_run_dir,
        Cancellable?  cancellable
    ) throws Error {
        if (holder.path != null)
            return;
        yield ensure_intermediate (
            holder, input_file, positions, segment_duration, vf, pix_fmt,
            info, temp_run_dir, cancellable, true);
        if (holder.path != null)
            return;

        // Almost always a lying container duration: every sample position sat
        // past the last decodable frame. Measure what the file really holds
        // and try once more against that.
        double real = yield measure_real_duration (input_file, cancellable);
        if (real > 0.0 && real < info.duration) {
            warning ("Smart Optimizer: header claims %.1fs, only %.1fs decodable "
                + "— resampling", info.duration, real);
            double seg = double.min (segment_duration, real);
            double[] retry = SmartOptimizerLogic.pick_sample_positions (seg > 0 ? real : 0.0, seg);
            holder.build_failed = false;
            yield ensure_intermediate (
                holder, input_file, retry, seg, vf, pix_fmt,
                info, temp_run_dir, cancellable, true);
        }

        if (holder.path == null) {
            throw new IOError.FAILED (
                "Could not build a lossless reference for quality measurement.\n"
                + "Quality Mode needs one to compare against; try a size target instead.");
        }
    }

    /** Human-readable explanation of a quality solve. */
    private string build_quality_notes (
        string                              codec,
        SmartOptimizerLogic.QualityIntent   intent,
        SmartOptimizerLogic.QualityTarget   target,
        SmartOptimizerVideoInfo             info,
        SmartOptimizerLogic.TrimWindow      tw,
        SmartOptimizerLogic.AudioPlan       plan,
        ContentProfile                      profile,
        BitDepthDecision                    bit_depth,
        string                              preset_label,
        SmartOptimizerLogic.VmafModel       model,
        int[]                               crfs,
        double[]                            vmafs,
        double[]                            sizes,
        int                                 final_crf,
        double                              achieved_vmaf,
        int                                 estimated_total_kib,
        double                              confidence,
        double                              coverage,
        int                                 segment_count,
        bool                                positions_trimmed,
        bool                                crf_capped,
        bool                                refined,
        SmartOptimizerLogic.VmafVerification verification,
        bool                                all_saturated,
        int                                 cached_points,
        bool                                bracket_refined
    ) {
        var n = new StringBuilder ();

        n.append ("── Intent: %s (VMAF ceiling %.0f) ──\n".printf (
            intent.to_label (), target.target_vmaf));
        n.append ("  %s\n".printf (target.reason));
        n.append ("  Quality ceiling pinned; size is the prediction.\n");

        n.append ("\n── Content ──\n");
        n.append ("  %s".printf (profile.content_type.to_label ()));
        if (profile.type_confidence > 0)
            n.append (" (confidence: %.0f%%)".printf (profile.type_confidence * 100));
        n.append ("\n");
        n.append ("  Grain/noise (TOUT): %.4f\n".printf (profile.noise_mean));

        n.append ("\n── Measured quality curve ──\n");
        for (int i = 0; i < crfs.length; i++) {
            n.append ("  CRF %2d → VMAF %6.2f  (%.1f MiB projected)\n".printf (
                crfs[i], vmafs[i], sizes[i] / 1024.0));
        }
        if (all_saturated) {
            n.append (("  ⚠ Every probe cleared VMAF %.1f — the metric cannot "
                 + "separate these encodes.\n").printf (
                    SmartOptimizerLogic.VMAF_SATURATION_THRESHOLD));
            if (target.enforce_vmaf_ceiling) {
                n.append ("  Probed through the codec limit while looking for "
                    + "an encode at or below the ceiling.\n");
            } else {
                n.append ("  The High/Ultra screen-text exception uses its "
                    + "text-protection CRF instead of chasing this score.\n");
            }
        } else if (model.saturated_points_dropped > 0) {
            n.append ("  %d point(s) discarded above VMAF %.1f — no gradient there\n"
                .printf (model.saturated_points_dropped,
                         SmartOptimizerLogic.VMAF_SATURATION_THRESHOLD));
        }
        if (refined)
            n.append ("  Re-probed at higher CRFs after saturation\n");
        if (bracket_refined) {
            n.append ("  Re-probed near the answer — the first bracket did not "
                + "contain it\n");
        }
        if (cached_points > 0) {
            n.append ("  %d point(s) reused from a previous run\n".printf (
                cached_points));
        }
        if (SmartOptimizerLogic.fit_residual_is_informative (
                model.cal_crfs.length, model.qc)) {
            n.append ("  Fit residual: ±%.2f VMAF\n".printf (model.fit_rmse));
        } else {
            n.append (("  Fit residual: n/a — %d points define the curve "
                + "exactly, so there is no residual to measure\n")
                .printf (model.cal_crfs.length));
        }

        n.append ("\n── Decision ──\n");
        n.append ("  Fitted starting CRF %d for VMAF ceiling %.1f\n".printf (
            model.predicted_crf, target.target_vmaf));
        if (crf_capped) {
            n.append ("  Text protection capped CRF at %d — %s\n".printf (
                SmartOptimizerLogic.apply_quality_crf_cap (model.predicted_crf, target),
                "High/Ultra screencasts may exceed the numeric VMAF ceiling"));
        }
        // preset_label already reads "preset 6" / "cpu-used 2" / "slow"
        // depending on codec, so it must not be prefixed again.
        n.append ("  Final: %s CRF %d, %s, %s\n".printf (
            codec, final_crf, preset_label,
            bit_depth.is_10bit ? "10-bit" : "8-bit"));
        n.append ("  %s\n".printf (bit_depth.reason));

        if (verification.done) {
            n.append ("  Verified at CRF %d: measured VMAF %.2f "
                .printf (verification.verified_crf, verification.measured_vmaf));
            n.append ("(predicted %.2f, %+.2f)\n".printf (
                verification.predicted_vmaf, verification.delta));
            if (verification.ceiling_corrections > 0) {
                n.append (("  Raised CRF %d step(s), from %d to %d, until the "
                    + "measured result was at or below the ceiling.\n").printf (
                        verification.ceiling_corrections,
                        verification.initial_crf, verification.verified_crf));
            }
            if (verification.text_protection_exception) {
                n.append (("  ⚠ Measured VMAF %.2f exceeds the %.0f ceiling "
                    + "to protect screen-text legibility at this tier.\n").printf (
                        verification.measured_vmaf, target.target_vmaf));
            }
            if (verification.ceiling_unreachable) {
                n.append (("  ⚠ Codec maximum CRF %d still measured VMAF %.2f; "
                    + "the %.0f ceiling is unreachable for this source.\n").printf (
                        verification.verified_crf, verification.measured_vmaf,
                        target.target_vmaf));
            } else if (target.enforce_vmaf_ceiling && model.crf_at_min
                    && verification.measured_vmaf < target.target_vmaf) {
                n.append (("  Codec minimum CRF still measured VMAF %.2f; this "
                    + "is the closest result the source and codec can produce "
                    + "below the %.0f ceiling.\n").printf (
                        verification.measured_vmaf, target.target_vmaf));
            }
            if (Math.fabs (verification.delta)
                    > SmartOptimizerLogic.VMAF_VERIFY_TOLERANCE) {
                n.append ("  ⚠ The curve did not generalise to its own answer — "
                    + "confidence reduced\n");
            }
        }

        n.append ("\n── Prediction ──\n");
        n.append ("  Estimated size: %.1f MiB\n".printf (estimated_total_kib / 1024.0));
        n.append ("  %s VMAF: %.1f\n".printf (
            verification.done ? "Measured" : "Estimated", achieved_vmaf));
        n.append ("  Confidence: %.0f%%\n".printf (confidence * 100.0));
        n.append ("  Sampled %.0f%% of the encode window (%d × %.1fs segments%s)\n"
            .printf (coverage * 100.0, segment_count, tw.sample_segment_duration,
                     positions_trimmed ? ", reduced to fit the reference budget" : ""));
        if (plan.use_stream_copy) {
            n.append ("  Audio: stream copy, %d kbps/stream × %d\n".printf (
                plan.per_stream_kbps, plan.effective_track_count));
        } else {
            n.append ("  Audio: encode %d kbps/stream × %d".printf (
                plan.encode_target_kbps, plan.effective_track_count));
            if (plan.per_stream_kbps > 0
                    && plan.per_stream_kbps != plan.encode_target_kbps) {
                n.append (", reserving %d kbps".printf (plan.per_stream_kbps));
            }
            n.append ("\n");
            append_audio_cap_note (n, plan);
        }
        n.append ("  Single-pass CRF — two-pass targets a byte count, "
            + "which quality mode does not have.\n");

        return n.str;
    }

    /**
     * Report the source-bitrate cap when it lowered the tier's audio budget.
     *
     * Worth a line because it is the one place the optimizer spends fewer
     * bits than the tier allows, and a user comparing two intents will
     * otherwise see the audio rate refuse to rise with no explanation.
     */
    private static void append_audio_cap_note (
        StringBuilder n, SmartOptimizerLogic.AudioPlan plan
    ) {
        if (plan.uncapped_tier_kbps <= 0 || plan.cap_source_kbps <= 0)
            return;

        n.append (("  Capped from the %d kbps tier budget: source audio is "
            + "%d kbps, so bits above that refine the previous encoder's "
            + "output rather than recover anything.\n")
            .printf (plan.uncapped_tier_kbps, plan.cap_source_kbps));
    }

    // ════════════════════════════════════════════════════════════════════════
    // PIPELINE STAGES
    // ════════════════════════════════════════════════════════════════════════

    /**
     * For TINY/SMALL targets with re-encoded audio, measure the actual
     * audio bitrate from a quick audio-only encode and update the plan
     * and budget so every later stage — including the CRF solve — uses
     * the real number instead of the tier guess.
     */
    private async void measure_and_apply_audio_budget (
        string        input_file,
        string        resolved_container,
        SizeTier      tier,
        OptimizationContext ctx,
        SmartOptimizerLogic.AudioPlan plan,
        SmartOptimizerLogic.SizeBudget budget,
        double[]      positions,
        double        sample_segment_duration,
        double        encode_duration,
        string?       temp_run_dir,
        Cancellable?  cancellable
    ) throws Error {
        if (!SmartOptimizerLogic.tier_uses_strict_targeting (tier)
                || plan.use_stream_copy
                || ctx.strip_audio
                || plan.effective_track_count != 1
                || ctx.audio_bitrate_kbps_override > 0
                || plan.encode_target_kbps <= 0
                || plan.probed_first_codec.length == 0) {
            return;
        }
        try {
            cancellable_check (cancellable);
            // Measure at the rate the encode will actually use, not the tier
            // rung it started from — the source cap may have lowered it, and
            // measuring a rate we will not encode at re-introduces exactly
            // the estimate/encode split this measurement exists to close.
            int target_kbps = plan.encode_target_kbps;
            int measured_audio_kbps = yield measure_audio_bitrate (
                input_file, resolved_container, positions,
                sample_segment_duration, target_kbps, cancellable, temp_run_dir);
            if (measured_audio_kbps > 0) {
                // Silence guard: VBR audio collapses near-silent sampled
                // segments to a few kbps, but a full-length track rarely
                // stays that low.  Floor the measurement at a fraction of
                // the encode target instead of under-reserving audio.
                int raw_measured_kbps = measured_audio_kbps;
                measured_audio_kbps = SmartOptimizerLogic.floor_measured_audio_kbps (
                    measured_audio_kbps, target_kbps);
                if (measured_audio_kbps != raw_measured_kbps) {
                    warning ("Smart Optimizer: measured audio %d kbps looks like sampled "
                        + "silence — floored to %d kbps",
                        raw_measured_kbps, measured_audio_kbps);
                }

                // Sanity check: measured bitrate should not exceed 2× the
                // encode target (encoder overhead, container framing).  If
                // it does, the measurement is suspect.
                if (measured_audio_kbps <= target_kbps * 2) {
                    double new_audio_kib = SmartOptimizerLogic.compute_reserved_audio_kib (
                        plan.selected_sources,
                        false,
                        measured_audio_kbps,
                        measured_audio_kbps,
                        encode_duration);
                    double new_video_kib = budget.target_total_kib - new_audio_kib
                        - budget.container_overhead_kib;
                    if (new_video_kib > 0) {
                        plan.audio_measured    = true;
                        plan.measured_kbps     = measured_audio_kbps;
                        plan.measured_raw_kbps = raw_measured_kbps;
                        plan.measured_floored  = (measured_audio_kbps != raw_measured_kbps);
                        plan.per_stream_kbps   = measured_audio_kbps;
                        plan.total_budget_kbps = measured_audio_kbps;
                        budget.audio_kib        = new_audio_kib;
                        budget.video_target_kib = new_video_kib;
                        budget.available_video_kbps =
                            (int) SmartOptimizerLogic.kbps_from_kib_for_duration (
                                budget.video_target_kib, encode_duration);
                    }
                } else {
                    warning ("Smart Optimizer: measured audio %d kbps exceeds "
                        + "2× encode target %d kbps — ignoring measurement",
                        measured_audio_kbps, target_kbps);
                }
            }
        } catch (IOError.CANCELLED e) {
            throw e;
        } catch (Error e) {
            warning ("Audio measurement failed, using tier budget: %s", e.message);
        }
    }

    /** Lazily-built pre-filtered lossless intermediate for one run. */
    // Result of the live speed/memory probe: encode time and peak resident RAM.
    private class ProbeResult {
        public double seconds  = 0.0;
        public int64  peak_rss = 0;
    }

    private class IntermediateHolder {
        public string? path = null;
        public bool build_failed = false;
    }

    /**
     * Build the lossless intermediate on first need: one decode+filter
     * pass over the sample segments that every subsequent probe reads
     * instead of re-running the filter chain.  No-op when no filter
     * chain is active, when a previous attempt failed, or when the
     * estimated intermediate size exceeds the guard — the probes then
     * simply keep the (slower, equally correct) source+filters path.
     */
    private async void ensure_intermediate (
        IntermediateHolder holder,
        string        input_file,
        double[]      positions,
        double        segment_duration,
        string        vf,
        string        pix_fmt,
        SmartOptimizerVideoInfo info,
        string?       temp_run_dir,
        Cancellable?  cancellable,
        bool          force = false
    ) throws Error {
        // @force is Quality Mode: the intermediate is not an optimisation
        // there, it is the VMAF reference. libvmaf needs a reference matching
        // the distorted input's resolution and frame rate exactly, and the
        // filtered sample concat is the only thing that does. Size Mode leaves
        // force=false and keeps the "skip it and re-filter" fallback.
        if (holder.path != null || holder.build_failed)
            return;
        if (vf.length == 0 && !force)
            return;

        double sample_duration = (double) positions.length * segment_duration;
        double estimated_bytes = SmartOptimizerLogic.estimate_intermediate_bytes (
            info.width, info.height, info.fps, info.source_bit_depth, sample_duration);
        if (estimated_bytes <= 0
                || estimated_bytes > SmartOptimizerLogic.INTERMEDIATE_MAX_BYTES) {
            holder.build_failed = true;
            if (estimated_bytes > 0) {
                warning ("Smart Optimizer: skipping lossless intermediate (~%.1f GiB estimated) — "
                    + "probes will re-run the filter chain",
                    estimated_bytes / (1024.0 * 1024.0 * 1024.0));
            }
            return;
        }

        cancellable_check (cancellable);
        string tmp = tmp_path ("intermediate", temp_run_dir);
        string[] cmd = build_filtered_intermediate_cmd (
            input_file, positions, segment_duration, vf, pix_fmt, tmp);
        try {
            yield run_subprocess_wait (cmd, cancellable);
        } catch (IOError.CANCELLED e) {
            cleanup_file (tmp);
            throw e;
        } catch (Error e) {
            cleanup_file (tmp);
            holder.build_failed = true;
            // Size Mode falls back to re-filtering per probe; Quality Mode has
            // no fallback because this file IS the VMAF reference.
            warning ("Smart Optimizer: intermediate build failed (%s) — %s",
                e.message,
                force ? "quality measurement cannot proceed"
                      : "probes will re-run the filter chain");
            return;
        }

        // ffmpeg exits 0 on "Output file is empty, nothing was encoded" (it
        // does exactly that for odd-dimension sources under x264, and for
        // sample positions that all land past the last decodable frame), so
        // neither the exit code nor the file's existence proves the build
        // worked. Nor does its SIZE: a header-only Matroska file is ~5 KB, so
        // a size check passes and the truncated file then gets used as a probe
        // source or a VMAF reference. Decode a frame instead — that is the
        // only thing that actually answers the question.
        bool usable = FileUtils.test (tmp, FileTest.EXISTS)
            && yield can_decode_a_frame (tmp, cancellable);
        if (!usable) {
            cleanup_file (tmp);
            holder.build_failed = true;
            warning ("Smart Optimizer: intermediate build produced no data — %s",
                force ? "quality measurement cannot proceed"
                      : "probes will re-run the filter chain");
            return;
        }
        holder.path = tmp;
    }

    /**
     * Correct a container duration that the file cannot back up.
     *
     * Headers lie: one corpus file advertises 323 s and holds 9.4 s of
     * decodable video. Every duration-derived figure in the pipeline inherits
     * that — sample positions land past the end, the size projection scales an
     * 8 s probe by 40x instead of 1.2x, and the audio reservation over the
     * phantom 313 s exceeds the entire source, which silently zeroes the size
     * ceiling and disables it.
     *
     * The detection is O(1): seek near the claimed end and try to decode one
     * frame. Only when that fails do we pay for a real measurement, and a file
     * that fails is short by definition, so the decode is cheap.
     *
     * Returns the corrected duration, or the original when it holds up.
     */
    private async double verify_probed_duration (
        string path, double claimed, Cancellable? cancellable
    ) {
        if (claimed <= 1.0)
            return claimed;

        // Seek near the claimed end and look at WHICH timestamp comes back.
        //
        // Two cheaper-looking checks do not work, both for the same reason
        // this codebase keeps tripping over: seeking past the end and decoding
        // exits 0 having produced nothing, and `-count_frames` over a
        // read_interval past the end still reports 1 because the seek clamps
        // to the last available packet. The clamp is the tell — ask for a
        // timestamp near the end and see how far short the answer lands.
        //
        //   lying file:  seek 322.491s -> pts   9.386   (313s short)
        //   honest file: seek  83.288s -> pts  80.113   (3.2s, keyframe spacing)
        if (claimed <= TAIL_SEEK_TOLERANCE_SECONDS)
            return claimed;                     // too short to discriminate

        string ffprobe = AppSettings.get_default ().ffprobe_path;
        double probe_at = double.max (0.0, claimed - 1.0);
        string[] cmd = {
            ffprobe, "-v", "error", "-select_streams", "v:0",
            "-read_intervals",
            "%s%%+#1".printf (ConversionUtils.format_ffmpeg_double (probe_at, "%.3f")),
            "-show_entries", "packet=pts_time", "-of", "csv=p=0", path
        };
        string tail_out;
        try {
            tail_out = yield run_subprocess_stdout (cmd, cancellable);
        } catch (IOError.CANCELLED e) {
            return claimed;
        } catch (Error e) {
            return claimed;                     // cannot tell — trust the header
        }

        double tail_pts = 0.0;
        foreach (unowned string line in tail_out.split ("\n")) {
            string t = line.strip ();
            if (t.length == 0) continue;
            if (try_parse_double (t, out tail_pts)) break;
        }
        // Landing within a GOP of the request means the tail really is there.
        if (tail_pts <= 0.0 || (probe_at - tail_pts) <= TAIL_SEEK_TOLERANCE_SECONDS)
            return claimed;

        double real = yield measure_real_duration (path, cancellable);
        if (real <= 0.0 || real >= claimed)
            return claimed;
        warning ("Smart Optimizer: container claims %.1fs but only %.1fs is "
            + "decodable — using the measured duration", claimed, real);
        return real;
    }

    /** True when at least one video frame decodes out of @path. */
    private async bool can_decode_a_frame (string path, Cancellable? cancellable) {
        string ffmpeg = AppSettings.get_default ().ffmpeg_path;
        string[] cmd = {
            ffmpeg, "-hide_banner", "-v", "error", "-nostdin",
            "-i", path, "-frames:v", "1", "-f", "null", "-"
        };
        try {
            yield run_subprocess_wait (cmd, cancellable);
            return true;
        } catch (IOError.CANCELLED e) {
            return false;
        } catch (Error e) {
            return false;
        }
    }

    /**
     * Decode the video stream and report the timestamp actually reached.
     *
     * Container headers lie. One corpus file advertises 323 s and holds 9.4 s
     * of decodable video, so every sample position past 9.4 s yields nothing
     * and the reference comes out as a 5 KB stub. This is the authoritative
     * answer, but it costs a full decode — call it only after a build has
     * already failed, which by definition means the file is short or broken
     * and the decode is cheap.
     */
    private async double measure_real_duration (string path, Cancellable? cancellable) {
        string ffmpeg = AppSettings.get_default ().ffmpeg_path;
        string[] cmd = {
            ffmpeg, "-hide_banner", "-v", "error", "-stats", "-nostdin",
            "-i", path, "-map", "0:v:0", "-f", "null", "-"
        };
        string err;
        try {
            err = yield run_subprocess_stderr (cmd, cancellable);
        } catch (Error e) {
            return 0.0;
        }
        double best = 0.0;
        try {
            var re = new Regex ("time=(\\d+):(\\d\\d):(\\d\\d(?:\\.\\d+)?)");
            MatchInfo mi;
            if (re.match (err, 0, out mi)) {
                do {
                    double h = double.parse (mi.fetch (1));
                    double m = double.parse (mi.fetch (2));
                    double sec = double.parse (mi.fetch (3));
                    best = double.max (best, h * 3600.0 + m * 60.0 + sec);
                } while (mi.next ());
            }
        } catch (RegexError e) {
            return 0.0;
        }
        return best;
    }

    /**
     * Base 4-point CRF calibration at the target preset, least-squares
     * curve fit, CRF solve, and adaptive window refinement.
     *
     * By calibrating at the target preset, the model directly predicts
     * what the actual encode will produce — no preset efficiency factor
     * correction is needed.
     *
     * Points already measured by a previous run (persistent sample cache)
     * are reused without encoding; fresh measurements are recorded back.
     *
     * Throws IOError.FAILED with a user-facing message when the encodes
     * fail or produce invalid sizes; the orchestrator surfaces it via
     * make_error_rec.
     */
    private async SmartOptimizerLogic.CalibrationModel run_crf_calibration (
        string        input_file,
        string        codec,
        SizeTier      tier,
        double[]      positions,
        double        encode_duration,
        double        sample_segment_duration,
        string        vf,
        int           preset_idx,
        string        pix_fmt,
        double        video_target_kib,
        double        extrapolation_weight,
        SmartOptimizerCache? cache,
        IntermediateHolder intermediate,
        SmartOptimizerVideoInfo info,
        int           max_calibration_jobs,
        string?       temp_run_dir,
        Cancellable?  cancellable
    ) throws Error {
        var model = new SmartOptimizerLogic.CalibrationModel ();
        int[] base_crfs = SmartOptimizerLogic.pick_calibration_crfs (codec, tier);
        double[] base_sizes = new double[base_crfs.length];

        // Parallelism is the smaller of the CPU-based count and the RAM-based
        // cap the live probe derived (each 4K/10-bit job can hold ~14 GiB).
        int calibration_jobs = int.max (1,
            int.min (calibration_parallel_jobs (), max_calibration_jobs));
        int calibration_encoder_threads = encoder_threads_per_job (calibration_jobs);

        // Reuse points a previous run already measured; only the missing
        // CRFs get encoded.
        int[] missing_crfs = {};
        for (int ci = 0; ci < base_crfs.length; ci++) {
            double cached_size = 0.0;
            if (cache != null && cache.lookup (base_crfs[ci], out cached_size)
                    && cached_size > 0) {
                base_sizes[ci] = cached_size;
                model.cached_points++;
            } else {
                missing_crfs += base_crfs[ci];
            }
        }

        if (missing_crfs.length > 0) {
            yield ensure_intermediate (intermediate, input_file, positions,
                sample_segment_duration, vf, pix_fmt, info, temp_run_dir, cancellable);

            double[] fresh_sizes;
            try {
                fresh_sizes = yield run_calibration_batch (
                    input_file, codec, missing_crfs, positions,
                    encode_duration, sample_segment_duration, vf, cancellable,
                    preset_idx, pix_fmt, temp_run_dir,
                    calibration_jobs, calibration_encoder_threads,
                    extrapolation_weight, intermediate.path, true);
            } catch (IOError.CANCELLED e) {
                throw e;
            } catch (Error e) {
                warning ("Calibration encode failed: %s", e.message);
                throw new IOError.FAILED (
                    "Test encode failed — is ffmpeg installed?\n%s", e.message);
            }

            int mi = 0;
            for (int ci = 0; ci < base_crfs.length && mi < missing_crfs.length; ci++) {
                if (base_crfs[ci] == missing_crfs[mi]) {
                    base_sizes[ci] = fresh_sizes[mi];
                    if (cache != null && fresh_sizes[mi] > 0)
                        cache.record (base_crfs[ci], fresh_sizes[mi]);
                    mi++;
                }
            }
        }
        model.cal_crfs = base_crfs;
        model.cal_sizes = base_sizes;

        bool any_invalid = false;
        for (int ci = 0; ci < model.cal_sizes.length; ci++) {
            if (model.cal_sizes[ci] <= 0) any_invalid = true;
        }
        if (any_invalid) {
            for (int ci = 0; ci < model.cal_sizes.length; ci++) {
                if (model.cal_sizes[ci] <= 0) {
                    warning ("Nonsensical calibration: CRF %d → %.0fKiB",
                        model.cal_crfs[ci], model.cal_sizes[ci]);
                    break;
                }
            }
            throw new IOError.FAILED (
                "Calibration produced invalid results. File may be corrupt.");
        }

        // Warn if sizes aren't monotonically decreasing (unusual but the
        // least-squares fit handles it — just means unusual content variance)
        for (int ci = 0; ci < model.cal_sizes.length - 1; ci++) {
            if (model.cal_sizes[ci] <= model.cal_sizes[ci + 1]) {
                warning ("Non-monotonic calibration: CRF %d→%.0fKiB, %d→%.0fKiB — "
                    + "proceeding with least-squares fit",
                    model.cal_crfs[ci], model.cal_sizes[ci],
                    model.cal_crfs[ci + 1], model.cal_sizes[ci + 1]);
                break;
            }
        }

        // Fit the CRF↔size curve (least-squares quadratic in log-space,
        // with the monotonicity guard), then solve for the target size:
        //   ln(target) = a + b·crf + c·crf² → c·crf² + b·crf + (a − ln t) = 0
        double qa = 0, qb = 0, qc = 0;
        bool degenerate = false;
        SmartOptimizerLogic.fit_calibration_curve (
            model.cal_crfs, model.cal_sizes, out qa, out qb, out qc, out degenerate);
        model.qa = qa; model.qb = qb; model.qc = qc;
        model.degenerate = degenerate;

        int crf_min, crf_max;
        SmartOptimizerLogic.crf_range_for_codec (codec, out crf_min, out crf_max);
        model.crf_min = crf_min;
        model.crf_max = crf_max;

        double ln_target = Math.log (video_target_kib);
        model.cal_mid = (double) (model.cal_crfs[0]
            + model.cal_crfs[model.cal_crfs.length - 1]) / 2.0;
        double crf_raw = SmartOptimizerLogic.solve_crf_from_curve (
            model.qa, model.qb, model.qc, ln_target, model.cal_mid,
            model.crf_min, model.crf_max);
        model.predicted_crf = ((int) Math.round (crf_raw)).clamp (model.crf_min, model.crf_max);
        model.crf_at_max = (model.predicted_crf >= model.crf_max);
        model.crf_at_min = (model.predicted_crf <= model.crf_min);

        // If the initial 4-point window does not bracket the answer well,
        // add follow-up CRFs around the predicted area and refit.
        int[] extra_crfs = SmartOptimizerLogic.pick_adaptive_calibration_crfs (
            model.predicted_crf, model.cal_crfs, model.crf_min, model.crf_max,
            SmartOptimizerLogic.ADAPTIVE_CALIBRATION_BASE_MAX_POINTS);
        if (extra_crfs.length > 0) {
            int[] cal_crfs = model.cal_crfs;
            double[] cal_sizes = model.cal_sizes;

            // Cached follow-up points join the fit for free.
            int[] fresh_extra_crfs = {};
            for (int ci = 0; ci < extra_crfs.length; ci++) {
                double cached_size = 0.0;
                if (cache != null && cache.lookup (extra_crfs[ci], out cached_size)
                        && cached_size > 0) {
                    SmartOptimizerLogic.append_calibration_sample (
                        ref cal_crfs, ref cal_sizes, extra_crfs[ci], cached_size);
                    model.cached_points++;
                    model.adaptive_points_added++;
                } else {
                    fresh_extra_crfs += extra_crfs[ci];
                }
            }

            if (fresh_extra_crfs.length > 0) {
                yield ensure_intermediate (intermediate, input_file, positions,
                    sample_segment_duration, vf, pix_fmt, info, temp_run_dir, cancellable);

                // Tolerant batch: individual encode failures are logged and
                // skipped (their slot reports 0); only cancellation aborts.
                double[] extra_sizes = yield run_calibration_batch (
                    input_file, codec, fresh_extra_crfs, positions,
                    encode_duration, sample_segment_duration, vf, cancellable,
                    preset_idx, pix_fmt, temp_run_dir,
                    calibration_jobs, calibration_encoder_threads,
                    extrapolation_weight, intermediate.path, false);

                for (int ci = 0; ci < fresh_extra_crfs.length; ci++) {
                    if (extra_sizes[ci] <= 0) {
                        warning ("Adaptive calibration produced invalid result: CRF %d → %.0fKiB",
                            fresh_extra_crfs[ci], extra_sizes[ci]);
                        continue;
                    }
                    SmartOptimizerLogic.append_calibration_sample (
                        ref cal_crfs, ref cal_sizes, fresh_extra_crfs[ci], extra_sizes[ci]);
                    if (cache != null)
                        cache.record (fresh_extra_crfs[ci], extra_sizes[ci]);
                    model.adaptive_points_added++;
                }
            }
            model.cal_crfs = cal_crfs;
            model.cal_sizes = cal_sizes;

            if (model.adaptive_points_added > 0) {
                model.adaptive_refined = true;
                for (int ci = 0; ci < model.cal_sizes.length - 1; ci++) {
                    if (model.cal_sizes[ci] <= model.cal_sizes[ci + 1]) {
                        warning ("Non-monotonic adaptive calibration: CRF %d→%.0fKiB, %d→%.0fKiB — "
                            + "proceeding with least-squares fit",
                            model.cal_crfs[ci], model.cal_sizes[ci],
                            model.cal_crfs[ci + 1], model.cal_sizes[ci + 1]);
                        break;
                    }
                }

                SmartOptimizerLogic.fit_calibration_curve (
                    model.cal_crfs, model.cal_sizes, out qa, out qb, out qc, out degenerate);
                model.qa = qa; model.qb = qb; model.qc = qc;
                model.degenerate = degenerate;
                model.cal_mid = (double) (model.cal_crfs[0]
                    + model.cal_crfs[model.cal_crfs.length - 1]) / 2.0;
                crf_raw = SmartOptimizerLogic.solve_crf_from_curve (
                    model.qa, model.qb, model.qc, ln_target, model.cal_mid,
                    model.crf_min, model.crf_max);
                model.predicted_crf = ((int) Math.round (crf_raw)).clamp (model.crf_min, model.crf_max);
                model.crf_at_max = (model.predicted_crf >= model.crf_max);
                model.crf_at_min = (model.predicted_crf <= model.crf_min);
            }
        }

        return model;
    }

    /**
     * Verification encode at the solved CRF to check the model's
     * interpolation accuracy — a direct apples-to-apples comparison since
     * calibration already used the target preset.  When the measured
     * error is >5%, the CRF is re-solved against a corrected target; a
     * shift of ≥2 CRF triggers one re-measurement at the final CRF.
     * Updates model.predicted_crf (and the at-min/at-max flags) in place.
     */
    private async SmartOptimizerLogic.VerificationOutcome run_verification (
        string        input_file,
        string        codec,
        SmartOptimizerLogic.CalibrationModel model,
        double[]      positions,
        double        encode_duration,
        double        sample_segment_duration,
        string        vf,
        int           preset_idx,
        string        pix_fmt,
        double        video_target_kib,
        double        extrapolation_weight,
        SmartOptimizerCache? cache,
        IntermediateHolder intermediate,
        string?       temp_run_dir,
        Cancellable?  cancellable
    ) throws Error {
        var outcome = new SmartOptimizerLogic.VerificationOutcome ();
        outcome.verified_crf = model.predicted_crf;

        if (model.crf_at_max)
            return outcome;

        double verify_model_kib = 0.0;
        if (!SmartOptimizerLogic.try_evaluate_model_size_kib (
                model.qa, model.qb, model.qc, model.predicted_crf,
                "verification", out verify_model_kib)
            || verify_model_kib <= 0) {
            return outcome;
        }
        outcome.model_kib = verify_model_kib;

        int encoder_threads = encoder_threads_per_job (calibration_parallel_jobs ());

        try {
            // When the solved CRF matches a calibration point, the stored
            // sample is reused — the encode would reproduce a file already
            // measured.  The correction then captures the fit's residual
            // at that point.
            for (int vi = 0; vi < model.cal_crfs.length; vi++) {
                if (model.cal_crfs[vi] == model.predicted_crf && model.cal_sizes[vi] > 0) {
                    outcome.reused = true;
                    break;
                }
            }
            outcome.actual_kib = yield sample_size_at_crf (
                input_file, codec, model.predicted_crf, model.cal_crfs, model.cal_sizes,
                positions, encode_duration, sample_segment_duration, vf,
                cancellable, preset_idx, pix_fmt, temp_run_dir,
                encoder_threads, extrapolation_weight, cache, intermediate.path);

            if (outcome.actual_kib > 0) {
                outcome.correction = outcome.actual_kib / verify_model_kib;
                outcome.verified_crf = model.predicted_crf;
                outcome.done = true;

                // If model is off by >5%, re-solve with a corrected target:
                // if the model underestimates (correction > 1), we need a
                // smaller model-space target to hit the real target.
                if (Math.fabs (outcome.correction - 1.0) > 0.05) {
                    double corrected_target = video_target_kib / outcome.correction;
                    double corrected_ln = Math.log (corrected_target);
                    double re_crf_raw = SmartOptimizerLogic.solve_crf_from_curve (
                        model.qa, model.qb, model.qc, corrected_ln,
                        model.cal_mid, model.crf_min, model.crf_max);
                    int re_crf = ((int) Math.round (re_crf_raw)).clamp (model.crf_min, model.crf_max);

                    if (re_crf != model.predicted_crf) {
                        warning ("Smart Optimizer: verification shifted CRF %d → %d "
                            + "(model error: %+.1f%%)",
                            model.predicted_crf, re_crf, (outcome.correction - 1.0) * 100.0);
                        model.predicted_crf = re_crf;
                        model.crf_at_max = (model.predicted_crf >= model.crf_max);
                        model.crf_at_min = (model.predicted_crf <= model.crf_min);

                        // A shift of ≥2 CRF outruns the first-order ratio
                        // correction — measure once at the final CRF so the
                        // estimate is real, not projected.
                        double reverify_model_kib = 0.0;
                        if ((model.predicted_crf - outcome.verified_crf).abs () >= 2
                            && SmartOptimizerLogic.try_evaluate_model_size_kib (
                                model.qa, model.qb, model.qc, model.predicted_crf,
                                "re-verification", out reverify_model_kib)
                            && reverify_model_kib > 0) {
                            double re_actual = yield sample_size_at_crf (
                                input_file, codec, model.predicted_crf,
                                model.cal_crfs, model.cal_sizes,
                                positions, encode_duration, sample_segment_duration, vf,
                                cancellable, preset_idx, pix_fmt, temp_run_dir,
                                encoder_threads, extrapolation_weight, cache, intermediate.path);
                            if (re_actual > 0) {
                                outcome.reverify_actual_kib = re_actual;
                                outcome.correction = re_actual / reverify_model_kib;
                                outcome.reverified = true;
                            }
                        }
                    }
                }
            }
        } catch (IOError.CANCELLED e) {
            throw e;
        } catch (Error e) {
            warning ("Verification encode failed, using model estimate: %s", e.message);
        }
        return outcome;
    }

    /**
     * Format the user-facing notes block from the stage results.
     * Pure formatting — every decision was already made upstream.
     */
    private string build_notes (
        string codec,
        int target_mb,
        SizeTier tier,
        OptimizationContext ctx,
        string vf,
        SmartOptimizerVideoInfo info,
        SmartOptimizerLogic.TrimWindow tw,
        SmartOptimizerLogic.AudioPlan plan,
        SmartOptimizerLogic.SizeBudget budget,
        ContentProfile profile,
        BitDepthDecision bit_depth,
        double content_factor,
        string preset_label,
        SmartOptimizerLogic.CalibrationModel model,
        SmartOptimizerLogic.VerificationOutcome verification,
        SmartOptimizerLogic.ConfidenceAssessment conf,
        SmartOptimizerLogic.TwoPassPolicy policy,
        SmartOptimizerLogic.DownscaleAdvisory? downscale,
        int estimated_total_kib,
        double extrapolation_weight,
        int positions_count,
        bool adaptive_expanded,
        bool used_intermediate,
        double probe_secs_per_segment,
        int64 probe_peak_rss_bytes,
        int calibration_job_cap
    ) {
        var notes = new StringBuilder ();

        // --- Tier ---
        notes.append ("── Strategy: %s ──\n".printf (tier.to_label ()));
        notes.append ("  Audio budget: %d kbps/stream".printf (
            plan.use_stream_copy ? plan.per_stream_kbps : plan.encode_target_kbps));
        if (plan.effective_track_count > 1) {
            notes.append (" (%d tracks, %d kbps total)".printf (
                plan.effective_track_count, plan.total_budget_kbps));
        }
        notes.append ("%s\n".printf (
            plan.use_stream_copy ? " (stream copy)" :
            plan.audio_measured
                ? " (reserving %d kbps measured)".printf (plan.per_stream_kbps)
                : ""));

        // --- Content ---
        notes.append ("\n── Content ──\n");
        notes.append ("  %s".printf (profile.content_type.to_label ()));
        if (profile.type_confidence > 0)
            notes.append (" (confidence: %s)".printf (
                "%.0f%%".printf (profile.type_confidence * 100)));
        notes.append ("\n");
        // Calibration instrument for grain detection: raw TOUT (temporal
        // outlier fraction) from signalstats. Log-only for now — no decision
        // is gated on it yet.
        notes.append ("  Grain/noise (TOUT): %.4f (±%.4f)\n".printf (
            profile.noise_mean, profile.noise_stddev));
        if (tier >= SizeTier.MEDIUM) {
            notes.append ("  Content influence dampened to %.0f%% (ample bitrate)\n"
                .printf (content_factor * 100.0));
        }

        // --- Bit Depth ---
        bool is_hdr_source = (info.color_transfer == "smpte2084"
                           || info.color_transfer == "arib-std-b67");
        bool is_wide_gamut_source = (info.color_primaries == "bt2020");

        notes.append ("\n── Bit Depth ──\n");
        notes.append ("  Source: %s\n".printf (
            info.source_bit_depth > 0 ? "%d-bit".printf (info.source_bit_depth) : "unknown"));

        // Color space info
        if (is_hdr_source && is_wide_gamut_source) {
            notes.append ("  Color: HDR (%s) + BT.2020 wide gamut — confirmed HDR\n"
                .printf (info.color_transfer));
        } else if (is_hdr_source && !is_wide_gamut_source) {
            string primaries_label = (info.color_primaries.length > 0)
                ? info.color_primaries : "unknown";
            notes.append ("  Color: HDR (%s) but primaries are %s (unusual — expected BT.2020)\n"
                .printf (info.color_transfer, primaries_label));
        } else if (!is_hdr_source && is_wide_gamut_source) {
            notes.append ("  Color: BT.2020 wide gamut without HDR transfer — SDR wide-gamut content\n");
        }

        // Tone mapping validation
        if (ctx.tone_mapping_active && !is_hdr_source && !is_wide_gamut_source) {
            notes.append ("  Note: Tone mapping is enabled but source is not HDR or wide-gamut — it may be unnecessary\n");
        }

        notes.append ("  Banding risk: %.0f%%\n".printf (profile.banding_risk * 100.0));
        notes.append ("  Dark scenes: %.0f%% of frames\n".printf (profile.dark_scene_ratio * 100.0));
        notes.append ("  Decision: %s (%s)\n".printf (
            bit_depth.is_10bit ? "10-bit" : "8-bit", bit_depth.reason));
        notes.append ("  Output pixel format: %s\n".printf (bit_depth.pix_fmt));

        // --- Audio ---
        notes.append ("\n── Audio ──\n");
        if (ctx.preserve_all_audio_tracks_requested
                && !plan.preserve_all_effective
                && plan.actual_source_track_count > 1) {
            notes.append ("  Multi-track audio overridden: Tiny/Small targets keep only the first audio track\n");
        }
        if (plan.per_stream_kbps > 0) {
            if (plan.use_stream_copy) {
                if (plan.effective_track_count > 1) {
                    notes.append ("  Audio: stream copy (%d tracks, %d kbps total) → %d KiB exact\n"
                        .printf (plan.effective_track_count, plan.total_budget_kbps,
                                 (int) budget.audio_kib));
                } else {
                    notes.append ("  Audio: stream copy (%s @ %d kbps) → %d KiB exact\n"
                        .printf (plan.probed_first_codec, plan.probed_first_kbps,
                                 (int) budget.audio_kib));
                }
            } else if (plan.audio_measured) {
                if (plan.measured_floored) {
                    notes.append ("  Audio: encode %d kbps, reserving %d kbps (measured %d kbps — sampled segments look near-silent, floored) → %d KiB\n"
                        .printf (plan.encode_target_kbps, plan.measured_kbps,
                                 plan.measured_raw_kbps, (int) budget.audio_kib));
                } else {
                    notes.append ("  Audio: encode %d kbps, reserving %d kbps (measured) → %d KiB\n"
                        .printf (plan.encode_target_kbps, plan.measured_kbps,
                                 (int) budget.audio_kib));
                }
                append_audio_cap_note (notes, plan);
            } else {
                notes.append ("  Audio: ~%d kbps/stream".printf (plan.per_stream_kbps));
                if (plan.per_stream_estimated)
                    notes.append (" (estimated %s — first stream did not report bitrate)".printf (
                        plan.probed_first_codec));
                if (plan.effective_track_count > 1) {
                    notes.append (" across %d tracks (%d kbps total)".printf (
                        plan.effective_track_count, plan.total_budget_kbps));
                }
                notes.append (" → %d KiB reserved\n".printf ((int) budget.audio_kib));
                append_audio_cap_note (notes, plan);
            }
        }

        // --- CRF mode ---
        notes.append ("\n── CRF mode (quality-focused) ──\n");
        notes.append ("  CRF %d / Preset: %s\n".printf (model.predicted_crf, preset_label));

        if (model.crf_at_max && !policy.is_impossible) {
            notes.append ("  ⚠️  CRF mode is at maximum compression — quality will be poor.\n");
            notes.append ("  ✅  Two-pass mode below is the recommended path.\n");
        } else if (model.crf_at_min && policy.recommend_two_pass) {
            notes.append ("  CRF floor reached — even maximum quality only produces ~%d KiB.\n"
                .printf (estimated_total_kib));
            notes.append ("  Two-pass VBR below will allocate the full bitrate budget.\n");
        } else if (!policy.is_impossible) {
            notes.append ("  Estimated: ~%d KiB".printf (estimated_total_kib));
            if (conf.confidence < 0.8)
                notes.append (" (extrapolated — confidence %s)"
                    .printf ("%.0f%%".printf (conf.confidence * 100)));
            notes.append ("\n");
        }

        // --- Two-pass mode ---
        if (policy.recommend_two_pass) {
            notes.append ("\n── Two-pass mode (size-targeted) ──\n");
            notes.append ("  Target bitrate: %d kbps / Preset: %s\n"
                .printf (policy.target_video_kbps, preset_label));
            if (policy.target_is_size_reduction) {
                if (!policy.strict_targeting && !policy.within_target_band) {
                    notes.append ("  CRF estimate (~%d KiB) falls outside the ±%.0f MB target band for this tier.\n"
                        .printf (estimated_total_kib, policy.target_tolerance_kib / 1024.0));
                } else if (tw.trim_active && policy.comparison_source_size_mb > 0) {
                    notes.append ("  Trimmed source window is ~%.0f MB (estimated) → target %d MB requires size reduction.\n"
                        .printf (policy.comparison_source_size_mb, target_mb));
                    if (policy.reduction_confidence < 0.95) {
                        notes.append ("  Reduction estimate confidence: %.0f%% (trim-window bitrate inferred from sampled content)\n"
                            .printf (policy.reduction_confidence * 100.0));
                    }
                } else {
                    notes.append ("  Source is ~%.0f MB → target %d MB requires size reduction.\n"
                        .printf (policy.source_size_mb, target_mb));
                }
            } else if (model.crf_at_min) {
                notes.append ("  CRF mode tops out at ~%d KiB (CRF %d) — maximum quality can't fill the %d MB target.\n"
                    .printf (estimated_total_kib, model.predicted_crf, target_mb));
                notes.append ("  Two-pass VBR allocates the full bitrate budget to get closer to the requested size.\n");
            } else if (policy.crf_overshoots) {
                if (policy.strict_targeting) {
                    notes.append ("  CRF estimate (~%d KiB) exceeds target (~%.0f KiB).\n"
                        .printf (estimated_total_kib, budget.target_total_kib));
                } else {
                    notes.append ("  CRF estimate (~%d KiB) exceeds the ±%.0f MB target band.\n"
                        .printf (estimated_total_kib, policy.target_tolerance_kib / 1024.0));
                }
            } else if (!policy.strict_targeting && !policy.within_target_band) {
                notes.append ("  CRF estimate (~%d KiB) falls outside the ±%.0f MB target band for this tier.\n"
                    .printf (estimated_total_kib, policy.target_tolerance_kib / 1024.0));
            } else if (conf.confidence < 1.0) {
                notes.append ("  Prediction confidence is %.0f%% — two-pass ensures accuracy.\n"
                    .printf (conf.confidence * 100.0));
            }
            notes.append ("  This mode targets the requested size more directly.\n");
            notes.append ("  Final size can still land above or below target depending on codec, audio, and container behavior.\n");
            notes.append ("  Quality is determined by available bitrate, not CRF.\n");
        } else {
            notes.append ("\n── Two-pass: skipped ──\n");
            if (policy.within_target_band) {
                notes.append ("  CRF confidence is high (%.0f%%) and estimate is within the ±%.0f MB target band.\n"
                    .printf (conf.confidence * 100.0, policy.target_tolerance_kib / 1024.0));
            } else {
                notes.append ("  CRF confidence is high (%.0f%%), but the estimate is outside the target band.\n"
                    .printf (conf.confidence * 100.0));
            }
        }

        // --- Warnings ---
        if (policy.is_impossible) {
            notes.append ("\n⚠️  Even maximum compression will likely exceed the %d MB target.\n"
                .printf (target_mb));
            notes.append ("    Two-pass can push the file closer to the target, but expect severe quality loss.\n");
            notes.append ("    Consider trimming, scaling down, or raising the target.\n");
        } else if (policy.target_video_kbps < 200) {
            notes.append ("\n⚠️  Very low available bitrate (%d kbps) — ".printf (policy.target_video_kbps));
            notes.append ("expect visible quality loss.\n");
        }

        // --- Downscale advisory ---
        if (downscale != null) {
            notes.append ("\n💡 Bits per pixel: %.3f at %d kbps (%d×%d @ %.4g fps) — below the %.3f comfort threshold for %s.\n"
                .printf (downscale.bpp, policy.target_video_kbps, info.width, info.height,
                         info.fps, downscale.threshold, codec));
            notes.append ("   Scaling to ~%d×%d (%.0f%%) would give each pixel more bits at this target size.\n"
                .printf (downscale.new_width, downscale.new_height,
                         downscale.scale_factor * 100.0));
        }

        // --- Sample coverage ---
        if (conf.sample_coverage < 0.30) {
            notes.append ("\nℹ️  %.0f%% of the video was sampled for calibration"
                .printf (conf.sample_coverage * 100.0));
            if (conf.sample_coverage < 0.15) {
                notes.append (" (low coverage — estimate may be less accurate).\n");
            } else {
                notes.append (".\n");
            }
        }

        // --- Calibration data ---
        notes.append ("\n── Calibration data (%d-point least-squares quadratic) ──\n"
            .printf (model.cal_crfs.length));
        for (int ci = 0; ci < model.cal_crfs.length; ci++) {
            notes.append ("  CRF %d → %.0f KiB (full-length estimate)\n"
                .printf (model.cal_crfs[ci], model.cal_sizes[ci]));
        }
        notes.append ("  Model: ln(size) = %.4f + %.4f·CRF + %.6f·CRF²\n"
            .printf (model.qa, model.qb, model.qc));
        if (SmartOptimizerLogic.fit_residual_is_informative (
                model.cal_crfs.length, model.qc)) {
            notes.append ("  Fit residual: ±%.1f%% RMSE%s\n"
                .printf (conf.fit_rmse * 100.0,
                         conf.fit_quality_factor < 1.0
                             ? " (confidence ×%.2f)".printf (conf.fit_quality_factor)
                             : ""));
        } else {
            notes.append (("  Fit residual: n/a — %d points define the curve "
                + "exactly, so there is no residual to measure\n")
                .printf (model.cal_crfs.length));
        }
        if (Math.fabs (extrapolation_weight - 1.0) > 0.005) {
            notes.append ("  Complexity weight: ×%.2f (source bitrate, sampled regions vs full window)\n"
                .printf (extrapolation_weight));
        }
        if (model.adaptive_refined) {
            notes.append ("  Adaptive refinement: +%d follow-up point%s around the solved CRF path\n"
                .printf (model.adaptive_points_added,
                         model.adaptive_points_added == 1 ? "" : "s"));
        }
        notes.append ("  Calibrated at preset: %s\n".printf (preset_label));
        if (model.cached_points > 0) {
            notes.append ("  Calibration cache: %d of %d point%s reused from a previous run\n"
                .printf (model.cached_points, model.cal_crfs.length,
                         model.cached_points == 1 ? "" : "s"));
        }
        if (used_intermediate) {
            notes.append ("  Filters pre-rendered once to a lossless intermediate for calibration\n");
        }
        if (codec == "x265") {
            notes.append ("  x265 psy-rd penalty: confidence × 0.85 (psy-rd inflates complex scenes unpredictably)\n");
        }
        if (verification.done) {
            double first_verify_error = (verification.actual_kib / verification.model_kib - 1.0) * 100.0;
            notes.append ("  Verification: model predicted %.0f KiB at CRF %d, measured %.0f KiB (error: %+.1f%%)%s\n"
                .printf (verification.model_kib, verification.verified_crf, verification.actual_kib,
                         first_verify_error,
                         verification.reused ? " [reused calibration sample]" : ""));
            if (model.predicted_crf != verification.verified_crf) {
                notes.append ("  CRF adjusted %d → %d to compensate for model error\n"
                    .printf (verification.verified_crf, model.predicted_crf));
                if (verification.reverified) {
                    notes.append ("  Re-measured at CRF %d: %.0f KiB — estimate uses the measurement\n"
                        .printf (model.predicted_crf, verification.reverify_actual_kib));
                }
            }
        }
        notes.append ("  Container overhead: %.0f KiB reserved\n"
            .printf (budget.container_overhead_kib));
        if (conf.source_video_kbps > 0) {
            notes.append ("  Source: ~%.0f MB, ~%d kbps (est. video) | Target: %d kbps video\n"
                .printf (policy.source_size_mb, conf.source_video_kbps, policy.target_video_kbps));
        } else if (tw.trim_active && policy.comparison_source_size_mb > 0) {
            notes.append ("  Trim window: %.1fs→%.1fs | Source window estimate: ~%.0f MB\n"
                .printf (tw.trim_start, tw.trim_end, policy.comparison_source_size_mb));
        }
        if (tier == SizeTier.TINY) {
            notes.append ("  Metadata stripped to save space (tiny target)\n");
        }
        notes.append ("  Sample coverage: %.0f%% (%d × %.2fs segments%s)\n"
            .printf (conf.sample_coverage * 100.0, positions_count, tw.sample_segment_duration,
                     adaptive_expanded ? ", adaptively expanded" : ""));
        // Live probe telemetry: what the one speed/memory probe measured and how
        // it sized the calibration. Only present when the probe actually ran.
        if (probe_secs_per_segment > 0.0) {
            int uncapped_jobs = calibration_parallel_jobs ();
            notes.append ("  Probe: %.2fs/segment, peak %.1f GiB/job → parallelism %d%s\n"
                .printf (probe_secs_per_segment,
                         probe_peak_rss_bytes / (1024.0 * 1024.0 * 1024.0),
                         calibration_job_cap,
                         calibration_job_cap < uncapped_jobs
                             ? " (RAM-capped from %d)".printf (uncapped_jobs) : ""));
        }
        if (tw.sample_segment_duration != (double) SEGMENT_DURATION) {
            notes.append ("  Sample segments shortened to %.2fs to stay within the trim window\n"
                .printf (tw.sample_segment_duration));
        }
        if (tw.trim_active) {
            notes.append ("  Trimmed duration: %.1fs (window %.1fs→%.1fs, full: %.1fs)\n"
                .printf (tw.encode_duration, tw.trim_start, tw.trim_end, info.duration));
        } else if (ctx.effective_duration > 0 && ctx.effective_duration != info.duration) {
            notes.append ("  Trimmed duration: %.1fs (full: %.1fs)\n"
                .printf (tw.encode_duration, info.duration));
        }
        if (vf.length > 0) {
            notes.append ("  Video filters applied to calibration: yes\n");
        }

        return notes.str;
    }

    /**
     * Format a recommendation for display.
     */
    public static string format_recommendation (OptimizationRecommendation rec) {
        var sb = new StringBuilder ();

        if (rec.is_impossible) {
            sb.append ("⚠️  Target is likely unreachable.\n\n");
        } else {
            sb.append ("✅ Smart Optimizer Recommendation\n\n");
        }

        sb.append ("Codec:          %s\n".printf (rec.codec.up ()));
        sb.append ("CRF:            %d\n".printf (rec.crf));
        sb.append ("Preset:         %s\n".printf (rec.preset));
        sb.append ("Two-pass:       %s\n".printf (rec.two_pass ? "enabled" : "disabled"));
        if (rec.two_pass) {
            sb.append ("  Bitrate cap:  %d kbps\n".printf (rec.target_bitrate_kbps));
            sb.append ("Est. size:      ~%d KiB (via two-pass @ %d kbps)\n"
                .printf (rec.target_size_kib, rec.target_bitrate_kbps));
            if (rec.estimated_size_kib < rec.target_size_kib) {
                sb.append ("CRF ceiling:    %d KiB (CRF %d — max quality undershoots target)\n"
                    .printf (rec.estimated_size_kib, rec.crf));
            } else {
                sb.append ("CRF estimate:   %d KiB (CRF %d — exceeds target band)\n"
                    .printf (rec.estimated_size_kib, rec.crf));
            }
        } else {
            sb.append ("Est. size:      %d KiB\n".printf (rec.estimated_size_kib));
        }
        if (rec.vmaf_measured) {
            sb.append ("Est. VMAF:      %.1f\n".printf (rec.estimated_vmaf));
        }
        sb.append ("Pinned axis:    %s\n".printf (rec.pinned_axis.to_label ()));
        sb.append ("Content:        %s\n".printf (rec.content_type.to_label ()));
        sb.append ("Confidence:     %s\n".printf ("%.0f%%".printf (rec.confidence * 100)));
        sb.append ("Effort:         %s\n".printf (rec.effort.to_label ()));
        if (rec.pinned_axis == PinnedAxis.SIZE) {
            sb.append ("Size tier:      %s\n".printf (rec.size_tier.to_label ()));
        }
        sb.append ("Audio tracks:   %d (%s)\n".printf (
            rec.audio_track_count,
            rec.audio_track_count == 0
                ? "none"
                : (rec.preserve_all_audio_tracks_effective ? "all preserved" : "first track only")));
        if (rec.stream_copy_audio) {
            sb.append ("Audio budget:   %d kbps/stream (copied)".printf (
                rec.recommended_audio_kbps));
        } else {
            sb.append ("Audio budget:   %d kbps/stream".printf (rec.audio_encode_kbps));
            // The reserve is what the VBR encoder is expected to actually
            // spend.  Showing only one number is how a 192 kbps reserve and a
            // 128 kbps encode went unnoticed.
            if (rec.recommended_audio_kbps > 0
                    && rec.recommended_audio_kbps != rec.audio_encode_kbps) {
                sb.append (" (reserving %d kbps measured)".printf (
                    rec.recommended_audio_kbps));
            }
        }
        if (rec.audio_track_count > 1) {
            sb.append (" (%d kbps total)".printf (rec.total_audio_budget_kbps));
        }
        sb.append ("\n");
        if (rec.recommended_pix_fmt != null && rec.recommended_pix_fmt.length > 0)
            sb.append ("Pixel format:   %s\n".printf (rec.recommended_pix_fmt));
        string normalized_codec = rec.codec.down ();
        if (!rec.is_impossible
                && (normalized_codec == "vp9" || normalized_codec == "svt-av1")) {
            double detail_percent = rec.detail_score.clamp (0.0, 1.0) * 100.0;
            if (rec.native_sharpness > 0) {
                sb.append ("Sharpness:      level %d (detail score %.0f%%)\n".printf (
                    rec.native_sharpness, detail_percent));
            } else if (rec.effort == EncodeEffort.MINIMAL
                    && rec.detail_score >= 0.25) {
                sb.append ("Sharpness:      disabled (detail score %.0f%%; Minimal effort cap)\n"
                    .printf (detail_percent));
            } else {
                sb.append ("Sharpness:      disabled (detail score %.0f%% — below threshold)\n"
                    .printf (detail_percent));
            }
        }
        if (rec.strip_metadata)
            sb.append ("Metadata:       stripped (tiny target)\n");
        sb.append ("\n");
        sb.append (rec.notes);

        return sb.str;
    }

    // ════════════════════════════════════════════════════════════════════════
    // PROBING
    // ════════════════════════════════════════════════════════════════════════

    private async SmartOptimizerVideoInfo probe_video (string path, Cancellable? cancellable = null) throws Error {
        string ffprobe = AppSettings.get_default ().ffprobe_path;
        string[] cmd = {
            ffprobe, "-v", "quiet", "-print_format", "json",
            "-show_format", "-show_streams", path
        };
        string stdout_text = yield run_subprocess_stdout (cmd, cancellable);

        var parser = new Json.Parser ();
        parser.load_from_data (stdout_text);
        var root   = parser.get_root ().get_object ();
        var format = root.has_member ("format") ? root.get_object_member ("format") : null;

        // ── Duration: try format-level first ─────────────────────────────
        double duration = 0.0;
        if (format != null) {
            string dur_str = format.get_string_member_with_default ("duration", "0");
            double parsed_duration = 0.0;
            if (try_parse_double (dur_str, out parsed_duration) && parsed_duration > 0) {
                duration = parsed_duration;
            }
        }

        // ── Source file size ──────────────────────────────────────────────
        int64 source_size_bytes = 0;
        if (format != null) {
            string sz_str = format.get_string_member_with_default ("size", "0");
            int64 parsed_size = 0;
            if (try_parse_int64 (sz_str, out parsed_size) && parsed_size > 0) {
                source_size_bytes = parsed_size;
            }
        }
        if (source_size_bytes <= 0) {
            // Fallback: stat the file directly
            try {
                var finfo = File.new_for_path (path)
                    .query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                source_size_bytes = finfo.get_size ();
            } catch (Error e) {
                warning ("Could not stat source file: %s", e.message);
            }
        }

        var info = SmartOptimizerVideoInfo () {
            duration                = duration,
            width                   = 0,
            height                  = 0,
            fps                     = 0.0,
            audio_bitrate_kbps      = 0,
            audio_bitrate_estimated = false,
            audio_codec             = "",
            total_audio_bitrate_kbps = 0,
            total_audio_bitrate_estimated = false,
            source_audio            = new AudioSourceInfo (),
            all_source_audio        = {},
            file_size_bytes         = source_size_bytes,
            source_bit_depth        = 0,
            color_transfer          = "",
            color_primaries         = ""
        };

        Json.Array? streams = root.has_member ("streams")
            ? root.get_array_member ("streams")
            : null;
        AudioSourceInfo[] collected_audio = {};
        if (streams != null) {
            for (uint i = 0; i < streams.get_length (); i++) {
                var s     = streams.get_object_element (i);
                var ctype = s.get_string_member_with_default ("codec_type", "");

                if (ctype == "video" && info.width == 0) {
                    info.width  = (int) s.get_int_member ("width");
                    info.height = (int) s.get_int_member ("height");
                    var rfr     = s.get_string_member_with_default ("r_frame_rate", "24/1");
                    info.fps    = parse_fraction (rfr);

                    // ── Bit depth & HDR metadata ──────────────────────────
                    string bits_raw = s.get_string_member_with_default ("bits_per_raw_sample", "");
                    if (bits_raw != null && bits_raw.strip ().length > 0) {
                        int64 parsed_bits = 0;
                        if (try_parse_int64 (bits_raw, out parsed_bits) && parsed_bits > 0) {
                            info.source_bit_depth = (int) parsed_bits;
                        }
                    }
                    if (info.source_bit_depth <= 0) {
                        string pix_fmt = s.get_string_member_with_default ("pix_fmt", "");
                        if (pix_fmt.length > 0) {
                            info.source_bit_depth = FfprobeUtils.infer_bit_depth_from_pix_fmt (pix_fmt);
                        }
                    }
                    info.color_transfer = s.get_string_member_with_default ("color_transfer", "");
                    info.color_primaries = s.get_string_member_with_default ("color_primaries", "");

                    // ── Duration fallback: video stream level ────────────
                    if (info.duration <= 0) {
                        double parsed_stream_dur = get_stream_duration_seconds (s);
                        if (parsed_stream_dur > 0) {
                            info.duration = parsed_stream_dur;
                        }
                    }
                }

                if (ctype == "audio") {
                    var source = new AudioSourceInfo ();
                    source.presence = MediaStreamPresence.PRESENT;
                    source.stream_index = (int) i;
                    source.codec_name = s.get_string_member_with_default ("codec_name", "");
                    source.channels = (int) s.get_int_member_with_default ("channels", 0);
                    source.sample_rate = (int) s.get_int_member_with_default ("sample_rate", 0);
                    source.sample_fmt = s.get_string_member_with_default ("sample_fmt", "");
                    string bits_raw = s.get_string_member_with_default ("bits_per_raw_sample", "");
                    int64 parsed_bits = 0;
                    if (bits_raw != null && bits_raw.strip ().length > 0
                        && try_parse_int64 (bits_raw, out parsed_bits) && parsed_bits > 0) {
                        source.bits_per_raw_sample = (int) parsed_bits;
                    }
                    double parsed_stream_dur = get_stream_duration_seconds (s);
                    if (parsed_stream_dur > 0) {
                        source.duration = parsed_stream_dur;
                    }

                    int stream_bitrate_kbps = 0;
                    bool stream_bitrate_estimated = false;
                    var bstr = s.get_string_member_with_default ("bit_rate", "0");
                    double parsed_audio_bps = 0.0;
                    if (try_parse_double (bstr, out parsed_audio_bps) && parsed_audio_bps > 0) {
                        stream_bitrate_kbps = (int) (parsed_audio_bps / 1000.0);
                    } else {
                        stream_bitrate_estimated = true;
                        stream_bitrate_kbps = SmartOptimizerLogic.default_audio_bitrate_kbps_for_codec (source.codec_name);
                    }
                    source.bitrate_kbps = stream_bitrate_kbps;
                    source.bitrate_estimated = stream_bitrate_estimated;

                    if (info.audio_codec.length == 0) {
                        info.audio_bitrate_kbps = stream_bitrate_kbps;
                        info.audio_bitrate_estimated = stream_bitrate_estimated;
                        info.audio_codec = source.codec_name;
                        info.source_audio = source.copy ();
                    }

                    collected_audio += source.copy ();
                    info.total_audio_bitrate_kbps += stream_bitrate_kbps;
                    if (stream_bitrate_estimated) {
                        info.total_audio_bitrate_estimated = true;
                    }

                    // ── Duration fallback: audio stream level ────────────
                    if (info.duration <= 0) {
                        if (parsed_stream_dur > 0) {
                            info.duration = parsed_stream_dur;
                        }
                    }
                }
            }
        }

        info.all_source_audio = collected_audio;

        // ── Duration fallback: separate ffprobe call (most reliable) ─────
        // FfprobeUtils.probe_duration uses format=duration via CSV output,
        // which sometimes succeeds when JSON parsing doesn't (e.g. when
        // the JSON field contains "N/A" or is absent).
        if (info.duration <= 0) {
            info.duration = FfprobeUtils.probe_duration (path);
        }

        return info;
    }

    /**
     * Build a per-second source video bitrate profile (KiB per 1-second
     * bucket) from packet sizes.  Demux-only — no decoding — so this is
     * disk-bound and cheap relative to a calibration encode.
     * Returns an empty array when unavailable; only cancellation
     * propagates as an error.
     */
    private async double[] probe_source_bitrate_profile (
        string       path,
        double       duration,
        Cancellable? cancellable
    ) throws Error {
        if (duration <= 0)
            return {};
        double bucket_count = Math.ceil (duration) + 1.0;
        if (bucket_count > 1000000.0)
            return {};
        int n_buckets = (int) bucket_count;

        string output;
        try {
            string ffprobe = AppSettings.get_default ().ffprobe_path;
            string[] cmd = {
                ffprobe, "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "packet=pts_time,size",
                "-of", "csv=p=0",
                path
            };
            output = yield run_subprocess_stdout (cmd, cancellable);
        } catch (IOError.CANCELLED e) {
            throw e;
        } catch (Error e) {
            warning ("Source bitrate profile unavailable: %s", e.message);
            return {};
        }

        double[] buckets = new double[n_buckets];
        int parsed = 0;
        foreach (unowned string line in output.split ("\n")) {
            string trimmed = line.strip ();
            if (trimmed.length == 0) continue;
            string[] parts = trimmed.split (",");
            if (parts.length < 2) continue;
            double pts = 0.0;
            double pkt_size = 0.0;
            if (!try_parse_double (parts[0], out pts)) continue;
            if (!try_parse_double (parts[1], out pkt_size) || pkt_size <= 0) continue;
            int bucket = (int) pts;
            if (bucket < 0 || bucket >= n_buckets) continue;
            buckets[bucket] += pkt_size / SmartOptimizerLogic.BYTES_PER_KIB;
            parsed++;
        }
        // Too few packets to characterize anything.
        if (parsed < 10)
            return {};
        return buckets;
    }

    // ════════════════════════════════════════════════════════════════════════
    // CONTENT ANALYSIS
    // ════════════════════════════════════════════════════════════════════════

    /**
     * Run signalstats + edgedetect over sample segments and classify content.
     * Uses two ffmpeg calls total (one for signal stats, one for edge stats),
     * each processing all segments via multi-input concat.
     */
    private async ContentProfile analyze_content (
        string        path,
        double[]      positions,
        double        segment_duration,
        SmartOptimizerVideoInfo info,
        string        video_filter_chain = "",
        Cancellable?  cancellable = null
    ) throws Error {
        // ── Signal stats (color + motion via YDIF) ──────────────────────
        // signalstats attaches per-frame metadata; metadata=print surfaces it
        // on stderr (as lavfi.signalstats.KEY=value lines). `select` decimates
        // the *printed* frames AFTER signalstats — the stats themselves are
        // still computed frame-to-frame, so YDIF/TOUT stay accurate; we just
        // sample fewer of them (see ANALYSIS_PRINT_STRIDE for why).
        string decimate = "select=not(mod(n\\,%d))".printf (ANALYSIS_PRINT_STRIDE);
        string[] sig_cmd = build_concat_analysis_cmd (
            path, positions, segment_duration,
            // siti shares this decode rather than needing a pass of its own —
            // unlike edgedetect below, which rewrites the frame into an edge
            // map and cannot be chained here.
            //
            // It sits AFTER the decimation deliberately. siti is expensive
            // (per-frame Sobel): measured on this chain, running it on every
            // frame costs 45.6s against 4.5s for signalstats alone, while
            // running it on the decimated 1/15 costs 7.3s — for an IDENTICAL
            // mean SI, since SI is a per-frame measure. Only SI is taken;
            // siti's TI would be meaningless across the decimation gaps, and
            // signalstats' YDIF already covers temporal activity for free.
            "signalstats=stat=tout+vrep+brng,%s,blurdetect,siti,metadata=print".printf (decimate),
            video_filter_chain
        );
        string sig_output = yield run_subprocess_stderr (sig_cmd, cancellable);
        double[] all_satavg = {};
        double[] all_ydif   = {};
        double[] all_ylow   = {};
        double[] all_yavg   = {};
        double[] all_tout   = {};
        parse_signalstats (sig_output, ref all_satavg, ref all_ydif,
            ref all_ylow, ref all_yavg, ref all_tout);
        double[] all_si = {};
        parse_metadata_field (sig_output, "lavfi.siti.si", ref all_si);
        double[] all_blur = {};
        parse_metadata_field (sig_output, "lavfi.blur", ref all_blur);

        // Put the amplitude metrics on one scale before any statistic is
        // computed from them. signalstats reports in the source's native
        // range, so without this every threshold downstream sees a 10-bit
        // source as four times whatever it actually is. TOUT is deliberately
        // excluded — it does not rescale linearly; see
        // SmartOptimizerLogic.normalise_amplitude_for_depth.
        for (int i = 0; i < all_satavg.length; i++)
            all_satavg[i] = SmartOptimizerLogic.normalise_amplitude_for_depth (
                all_satavg[i], info.source_bit_depth);
        for (int i = 0; i < all_ydif.length; i++)
            all_ydif[i] = SmartOptimizerLogic.normalise_amplitude_for_depth (
                all_ydif[i], info.source_bit_depth);
        for (int i = 0; i < all_ylow.length; i++)
            all_ylow[i] = SmartOptimizerLogic.normalise_amplitude_for_depth (
                all_ylow[i], info.source_bit_depth);
        for (int i = 0; i < all_yavg.length; i++)
            all_yavg[i] = SmartOptimizerLogic.normalise_amplitude_for_depth (
                all_yavg[i], info.source_bit_depth);

        // ── Edge detection ──────────────────────────────────────────────
        string[] edge_cmd = build_concat_analysis_cmd (
            path, positions, segment_duration,
            "edgedetect=low=0.08:high=0.25,signalstats,%s,metadata=print".printf (decimate),
            video_filter_chain
        );
        string edge_output = yield run_subprocess_stderr (edge_cmd, cancellable);
        double[] all_edge = {};
        parse_signalstats_field (edge_output, "YAVG", ref all_edge);

        // ── Compute stats ───────────────────────────────────────────────
        var profile = ContentProfile ();
        SmartOptimizerLogic.compute_stats (
            all_edge,   out profile.edge_mean,          out profile.edge_stddev);
        SmartOptimizerLogic.compute_stats (
            all_blur,   out profile.blur_mean,          out profile.blur_stddev);
        SmartOptimizerLogic.compute_stats (
            all_satavg, out profile.saturation_mean,    out profile.saturation_stddev);
        SmartOptimizerLogic.compute_stats (
            all_ydif,   out profile.temporal_diff_mean, out profile.temporal_diff_stddev);
        SmartOptimizerLogic.compute_stats (
            all_tout,   out profile.noise_mean,         out profile.noise_stddev);

        double si_sd;
        SmartOptimizerLogic.compute_stats (
            all_si, out profile.spatial_info, out si_sd);

        SmartOptimizerLogic.compute_banding_metrics (
            ref profile, all_yavg, all_ylow, info.width, info.height);
        SmartOptimizerLogic.classify_content (ref profile);
        return profile;
    }

    // ════════════════════════════════════════════════════════════════════════
    // PROBE PARSING HELPERS
    // ════════════════════════════════════════════════════════════════════════

    private double get_stream_duration_seconds (Json.Object stream) {
        string stream_dur = stream.get_string_member_with_default ("duration", "0");
        double parsed_stream_dur = 0.0;
        if (try_parse_double (stream_dur, out parsed_stream_dur) && parsed_stream_dur > 0.0)
            return parsed_stream_dur;

        if (stream.has_member ("tags")) {
            var tags = stream.get_object_member ("tags");
            if (tags != null) {
                string tagged_duration = "";
                if (tags.has_member ("DURATION")) {
                    tagged_duration = tags.get_string_member_with_default ("DURATION", "");
                } else if (tags.has_member ("duration")) {
                    tagged_duration = tags.get_string_member_with_default ("duration", "");
                }

                double tagged_seconds = 0.0;
                if (try_parse_duration_seconds (tagged_duration, out tagged_seconds) && tagged_seconds > 0.0)
                    return tagged_seconds;
            }
        }

        return 0.0;
    }

    private bool try_parse_duration_seconds (string text, out double seconds) {
        seconds = 0.0;
        string t = text.strip ();
        if (t.length == 0)
            return false;

        if (try_parse_double (t, out seconds) && seconds > 0.0)
            return true;

        string[] parts = t.split (":");
        if (parts.length != 3)
            return false;

        if (!Regex.match_simple ("^[0-9]+$", parts[0])
                || !Regex.match_simple ("^[0-9]{1,2}$", parts[1])
                || !Regex.match_simple ("^[0-9]{1,2}(\\.[0-9]+)?$", parts[2])) {
            return false;
        }

        double hours = 0.0;
        double minutes = 0.0;
        double secs = 0.0;
        if (!try_parse_double (parts[0], out hours)
                || !try_parse_double (parts[1], out minutes)
                || !try_parse_double (parts[2], out secs)) {
            return false;
        }
        if (minutes >= 60.0 || secs >= 60.0)
            return false;

        seconds = hours * 3600.0 + minutes * 60.0 + secs;
        return true;
    }

    // ════════════════════════════════════════════════════════════════════════
    // CALIBRATION ENCODING
    // ════════════════════════════════════════════════════════════════════════

    /**
     * Measure the actual audio bitrate by encoding sample segments.
     * Concats up to three spread positions so VBR-ish codecs aren't
     * judged from a single window that happens to be silence or music.
     * The first audio stream is mapped explicitly — ffmpeg's default
     * selection picks the HIGHEST-channel-count stream, which is not
     * the track the strict-tier budget keeps.
     * Returns the measured audio bitrate in kbps, or 0 on failure.
     */
    private async int measure_audio_bitrate (
        string        input_file,
        string        resolved_container,
        double[]      positions,
        double        segment_duration,
        int           target_audio_kbps,
        Cancellable?  cancellable = null,
        string?       temp_run_dir = null
    ) throws Error {
        string ffmpeg = AppSettings.get_default ().ffmpeg_path;
        string tmp = tmp_path ("audio_measure", temp_run_dir);

        // Up to three spread sample positions: first / middle / last.
        double[] sample_positions;
        if (positions.length <= 3) {
            sample_positions = positions;
        } else {
            sample_positions = {
                positions[0],
                positions[positions.length / 2],
                positions[positions.length - 1]
            };
        }

        // Pick audio codec and raw container based on the resolved output container
        string audio_codec = (resolved_container == "webm") ? "libopus" : "aac";
        string audio_bitrate = "%dk".printf (target_audio_kbps);

        // Use raw container formats to avoid container overhead inflating
        // the measured bitrate.  ADTS is raw AAC frames; OGG is minimal
        // for Opus and much lighter than WebM.
        string container_fmt = (resolved_container == "webm") ? "ogg" : "adts";

        var cmd = new GenericArray<string> ();
        cmd.add (ffmpeg);
        cmd.add ("-y");
        cmd.add ("-v"); cmd.add ("warning");

        for (int i = 0; i < sample_positions.length; i++) {
            cmd.add ("-ss"); cmd.add (ConversionUtils.format_ffmpeg_double (sample_positions[i], "%.2f"));
            cmd.add ("-t");  cmd.add (ConversionUtils.format_ffmpeg_double (segment_duration, "%.3f"));
            cmd.add ("-i");  cmd.add (input_file);
        }

        // Concat the FIRST audio stream of each segment input ([N:a:0]).
        var fc = new StringBuilder ();
        for (int i = 0; i < sample_positions.length; i++)
            fc.append ("[%d:a:0]".printf (i));
        fc.append ("concat=n=%d:v=0:a=1[a]".printf (sample_positions.length));

        cmd.add ("-filter_complex"); cmd.add (fc.str);
        cmd.add ("-map"); cmd.add ("[a]");
        cmd.add ("-c:a"); cmd.add (audio_codec);
        cmd.add ("-b:a"); cmd.add (audio_bitrate);
        cmd.add ("-f");   cmd.add (container_fmt);
        cmd.add (tmp);

        try {
            yield run_subprocess_wait (StringArrayUtils.copy_generic_array (cmd), cancellable);
        } catch (Error e) {
            cleanup_file (tmp);
            throw e;
        }

        int64 file_size = 0;
        var file = File.new_for_path (tmp);
        if (file.query_exists ()) {
            var finfo = file.query_info (
                FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
            file_size = finfo.get_size ();
        }
        cleanup_file (tmp);

        double measured_duration = segment_duration * sample_positions.length;
        if (file_size <= 0 || measured_duration <= 0) return 0;

        // Convert file size to kbps: (bytes * 8) / (duration * 1000)
        double kbps = ((double) file_size * SmartOptimizerLogic.BITS_PER_BYTE)
            / (measured_duration * SmartOptimizerLogic.BITS_PER_KILOBIT);
        return (int) Math.round (kbps);
    }

    /**
     * Number of calibration encodes to run concurrently on this machine:
     * one job per CORES_PER_CALIBRATION_JOB logical cores, capped at
     * MAX_PARALLEL_CALIBRATION_JOBS (4 cores → 1 job, 8 → 2, 16+ → 4).
     */
    private static int calibration_parallel_jobs () {
        int cores = (int) GLib.get_num_processors ();
        return (cores / CORES_PER_CALIBRATION_JOB)
            .clamp (1, MAX_PARALLEL_CALIBRATION_JOBS);
    }

    /**
     * Encoder threads per concurrent job — an even share of the logical
     * cores so parallel jobs don't oversubscribe the CPU.  Returns 0
     * (ffmpeg default: auto) when running a single job.
     */
    private static int encoder_threads_per_job (int parallel_jobs) {
        if (parallel_jobs <= 1)
            return 0;
        int cores = (int) GLib.get_num_processors ();
        return int.max (2, cores / parallel_jobs);
    }

    /**
     * Run calibration encodes for a set of CRFs, up to @max_parallel
     * concurrently.  Returns measured sizes in the same order as @crfs.
     *
     * With @fail_fast, the first failure aborts the batch once the
     * in-flight encodes drain.  Without it, failed CRFs report 0.0 and
     * the batch continues; only cancellation aborts.
     */
    private async double[] run_calibration_batch (
        string        input_file,
        string        codec,
        int[]         crfs,
        double[]      positions,
        double        full_duration,
        double        segment_duration,
        string        video_filter_chain,
        Cancellable?  cancellable,
        int           preset_idx,
        string        pix_fmt,
        string?       temp_run_dir,
        int           max_parallel,
        int           encoder_threads,
        double        extrapolation_weight,
        string?       intermediate_path,
        bool          fail_fast
    ) throws Error {
        double[] results = new double[crfs.length];

        int start = 0;
        while (start < crfs.length) {
            cancellable_check (cancellable);
            int batch = int.min (int.max (max_parallel, 1), crfs.length - start);

            int pending = batch;
            Error? failure = null;
            SourceFunc resume = run_calibration_batch.callback;

            for (int i = 0; i < batch; i++) {
                int slot = start + i;
                int crf = crfs[slot];
                calibration_encode.begin (
                    input_file, codec, crf, positions, full_duration,
                    segment_duration, video_filter_chain, cancellable,
                    preset_idx, pix_fmt, temp_run_dir, encoder_threads,
                    extrapolation_weight, intermediate_path,
                    (obj, res) => {
                        try {
                            results[slot] = calibration_encode.end (res);
                        } catch (Error e) {
                            results[slot] = 0.0;
                            // Keep the first failure, but cancellation
                            // always takes precedence for propagation.
                            if (failure == null
                                || (e is IOError.CANCELLED
                                    && !(failure is IOError.CANCELLED))) {
                                failure = e;
                            }
                            if (!(e is IOError.CANCELLED)) {
                                warning ("Calibration encode failed at CRF %d: %s",
                                    crf, e.message);
                            }
                        }
                        pending--;
                        if (pending == 0) {
                            Idle.add ((owned) resume);
                        }
                    });
            }
            yield;

            if (failure != null && (fail_fast || failure is IOError.CANCELLED)) {
                throw failure;
            }
            start += batch;
        }
        return results;
    }

    /**
     * Measured full-length size estimate at @crf: reuses the calibration
     * sample when one was encoded at exactly that CRF (the encode would
     * reproduce a file already measured), then the persistent cache,
     * otherwise runs one sample encode (recorded into the cache).
     */
    private async double sample_size_at_crf (
        string        input_file,
        string        codec,
        int           crf,
        int[]         cal_crfs,
        double[]      cal_sizes,
        double[]      positions,
        double        full_duration,
        double        segment_duration,
        string        video_filter_chain,
        Cancellable?  cancellable,
        int           preset_idx,
        string        pix_fmt,
        string?       temp_run_dir,
        int           encoder_threads,
        double        extrapolation_weight,
        SmartOptimizerCache? cache,
        string?       intermediate_path
    ) throws Error {
        for (int i = 0; i < cal_crfs.length; i++) {
            if (cal_crfs[i] == crf && cal_sizes[i] > 0)
                return cal_sizes[i];
        }
        double cached_size = 0.0;
        if (cache != null && cache.lookup (crf, out cached_size) && cached_size > 0)
            return cached_size;

        cancellable_check (cancellable);
        double fresh = yield calibration_encode (
            input_file, codec, crf, positions, full_duration,
            segment_duration, video_filter_chain, cancellable,
            preset_idx, pix_fmt, temp_run_dir, encoder_threads,
            extrapolation_weight, intermediate_path);
        if (cache != null && fresh > 0)
            cache.record (crf, fresh);
        return fresh;
    }

    /**
     * Live probe for both adaptive-expansion budgeting and memory-safe
     * parallelism: encode one short slice at the real target
     * codec/preset/pix_fmt and measure both wall-time and peak RSS. Uses the
     * same per-job thread count a calibration encode gets, so both figures are
     * representative of one calibration job. Encodes from source (the lossless
     * intermediate isn't built yet at this point), which includes decode cost
     * — a conservative bias, the safe direction for both time and memory.
     *
     * Returns a ProbeResult: .seconds is the estimated time to encode one
     * full-length sample segment; .peak_rss is one job's peak resident memory.
     */
    private async ProbeResult run_speed_memory_probe (
        string        input_file,
        string        codec,
        int           preset_idx,
        string        pix_fmt,
        string        video_filter_chain,
        double        segment_duration,
        double        trim_start,
        double        encode_duration,
        string?       temp_run_dir,
        Cancellable?  cancellable = null
    ) throws Error {
        double probe_secs = double.min (SPEED_PROBE_SECONDS, segment_duration);
        if (probe_secs <= 0.0)
            throw new IOError.FAILED ("Speed-probe duration is non-positive");

        // Sample from the middle of the encode window — representative footage.
        double[] one_position = { trim_start + encode_duration / 2.0 };
        int threads = encoder_threads_per_job (calibration_parallel_jobs ());
        string tmp = tmp_path ("speedprobe", temp_run_dir);

        // CRF value is irrelevant to timing (preset dominates speed); use a
        // representative mid value.
        string[] cmd = build_concat_encode_cmd (
            input_file, codec, 30, one_position, probe_secs, tmp,
            video_filter_chain, preset_idx, pix_fmt, threads);

        ProbeResult raw;
        try {
            raw = yield run_encode_measure_peak_rss (cmd, cancellable);
        } catch (Error e) {
            cleanup_file (tmp);
            throw e;
        }
        cleanup_file (tmp);

        var result = new ProbeResult ();
        result.peak_rss = raw.peak_rss;
        // Scale the short probe up to a full segment (encode time ~ duration).
        result.seconds = raw.seconds * (segment_duration / probe_secs);
        return result;
    }

    /**
     * Run an encode to completion while sampling the process's resident memory,
     * returning a ProbeResult with the wall-time (.seconds) and peak RSS in
     * bytes (.peak_rss). The whole encode — dav1d decode threads and the SVT
     * encoder — runs in the single ffmpeg process, so one PID's VmRSS captures
     * the full job.
     */
    private async ProbeResult run_encode_measure_peak_rss (
        string[]      cmd,
        Cancellable?  cancellable = null
    ) throws Error {
        var launcher = new SubprocessLauncher (
            SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
        var proc = SubprocessCompat.spawnv (launcher, cmd);
        string? pid = proc.get_identifier ();

        var result = new ProbeResult ();
        var timer = new Timer ();

        uint poll_id = 0;
        if (pid != null) {
            poll_id = Timeout.add (RSS_POLL_INTERVAL_MS, () => {
                int64 rss = read_process_rss_bytes (pid);
                if (rss > result.peak_rss)
                    result.peak_rss = rss;
                return Source.CONTINUE;
            });
        }

        try {
            yield proc.wait_check_async (cancellable);
        } catch (Error e) {
            if (poll_id != 0)
                Source.remove (poll_id);
            proc.force_exit ();
            throw e;
        }
        if (poll_id != 0)
            Source.remove (poll_id);
        timer.stop ();
        // One last sample in case the peak landed between polls.
        if (pid != null) {
            int64 rss = read_process_rss_bytes (pid);
            if (rss > result.peak_rss)
                result.peak_rss = rss;
        }
        result.seconds = timer.elapsed ();
        return result;
    }

    /** Read a process's resident memory (bytes) from /proc; 0 if unavailable. */
    private int64 read_process_rss_bytes (string pid) {
        string contents;
        try {
            if (!FileUtils.get_contents ("/proc/" + pid + "/status", out contents))
                return 0;
        } catch (Error e) {
            return 0;   // process already exited, or /proc unreadable
        }
        foreach (unowned string line in contents.split ("\n")) {
            if (line.has_prefix ("VmRSS:")) {
                string rest = line.substring (6).strip ();   // "12345 kB"
                int sp = rest.index_of (" ");
                string num = (sp > 0) ? rest.substring (0, sp) : rest;
                return int64.parse (num) * 1024;             // /proc kB is KiB
            }
        }
        return 0;
    }

    /**
     * Currently-allocatable RAM in bytes (MemAvailable from /proc/meminfo);
     * 0 if unavailable. MemAvailable — not MemTotal — is the right base: it
     * already excludes what the desktop, browser, and everything else are
     * using, so budgeting against it keeps calibration from spilling into swap.
     */
    private int64 read_mem_available_bytes () {
        string contents;
        try {
            if (!FileUtils.get_contents ("/proc/meminfo", out contents))
                return 0;
        } catch (Error e) {
            return 0;
        }
        foreach (unowned string line in contents.split ("\n")) {
            if (line.has_prefix ("MemAvailable:")) {
                string rest = line.substring (13).strip ();
                int sp = rest.index_of (" ");
                string num = (sp > 0) ? rest.substring (0, sp) : rest;
                return int64.parse (num) * 1024;
            }
        }
        return 0;
    }

    /**
     * Cap the CPU-based calibration parallelism so the parallel encodes fit in
     * CALIBRATION_MEMORY_FRACTION of currently-available RAM, using the probe's
     * measured per-job RSS. Falls back to the CPU-based count when the
     * measurement or meminfo is unavailable (no worse than the prior behavior).
     */
    private int memory_capped_calibration_jobs (int64 per_job_rss_bytes) {
        int cpu_jobs = calibration_parallel_jobs ();
        if (per_job_rss_bytes <= 0)
            return cpu_jobs;
        int64 mem_available = read_mem_available_bytes ();
        if (mem_available <= 0)
            return cpu_jobs;
        int64 budget = (int64) (mem_available * CALIBRATION_MEMORY_FRACTION);
        int mem_jobs = (int) (budget / per_job_rss_bytes);
        return mem_jobs.clamp (1, cpu_jobs);
    }

    /**
     * Encode sample segments at a given CRF with the target preset.
     * Returns estimated full-video size in KiB (extrapolated from sample).
     */
    private async double calibration_encode (
        string        input_file,
        string        codec,
        int           crf,
        double[]      positions,
        double        full_duration,
        double        segment_duration,
        string        video_filter_chain = "",
        Cancellable?  cancellable = null,
        int           preset_idx = -1,
        string        pix_fmt = "",
        string?       temp_run_dir = null,
        int           encoder_threads = 0,
        double        extrapolation_weight = 1.0,
        string?       intermediate_path = null
    ) throws Error {
        double sample_duration = double.min (
            (double) positions.length * segment_duration, full_duration);

        string tmp = tmp_path ("cal_%d".printf (crf), temp_run_dir);

        // When a pre-filtered lossless intermediate exists, probe from it —
        // same frames, none of the decode+filter cost.
        string[] cmd = (intermediate_path != null)
            ? build_intermediate_probe_cmd (
                intermediate_path, codec, crf, preset_idx, pix_fmt,
                encoder_threads, tmp)
            : build_concat_encode_cmd (
                input_file, codec, crf, positions, segment_duration, tmp,
                video_filter_chain, preset_idx, pix_fmt, encoder_threads);

        try {
            yield run_subprocess_wait (cmd, cancellable);
        } catch (Error e) {
            // Clean up temp file on ANY failure (including cancellation)
            cleanup_file (tmp);
            throw e;
        }

        int64 file_size = 0;
        var file = File.new_for_path (tmp);
        if (file.query_exists ()) {
            var finfo = file.query_info (
                FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
            file_size = finfo.get_size ();
        }
        cleanup_file (tmp);

        if (file_size <= 0) {
            throw new IOError.FAILED (
                "Calibration encode produced empty file at CRF %d", crf);
        }

        double sample_kib = SmartOptimizerLogic.kib_from_bytes (file_size);
        double scale     = full_duration / sample_duration;
        return sample_kib * scale * extrapolation_weight;
    }

    // ════════════════════════════════════════════════════════════════════════
    // VMAF MEASUREMENT  (Quality Mode)
    // ════════════════════════════════════════════════════════════════════════

    // libvmaf ships a built-in default model, so a missing file on disk is not
    // fatal — we simply omit the model= parameter and let it choose. The 4K
    // model is trained for a 4K viewing distance and is the right choice for
    // large frames; below that the HD model applies.
    //
    // ⚠️ This choice is NOT free, and it matters far more on animation than on
    // photographic content. Scoring identical x265 encodes under each model:
    //
    //             live action (1080p)      animation (1080p)
    //   HD→4K        +1.3 CRF                 +7.8 CRF
    //   HD→HD-neg    −1.3 CRF                 −2.4 CRF
    //
    // The HD model cannot score 1080p animation above ~95 even at CRF 17,
    // where the picture is visually near-perfect; the same encoder setting
    // scores 98.6 on live action. The intent→VMAF scale (88/92/95/97) comes
    // from VMAF literature built almost entirely on photographic content, so
    // applying it to animation through a model that under-scores animation
    // demands a higher real quality than the intent name implies.
    //
    // Consequence, measured end to end: Ultra on a 1080p anime source solves
    // CRF 14 and produces an output LARGER than the source, for no visible
    // gain over CRF 18. See docs/smart-optimizer-phase0-findings.md.
    //
    // Not "fixed" by switching models: the 4K model scores animation more
    // plausibly, but it is trained for a 4K viewing distance and using it on
    // 1080p is wrong by libvmaf's own design. The correct remedy is a
    // content-aware target offset, which needs subjective comparison to size —
    // a measurement this corpus cannot provide.
    // How far a seek may land short of the request before the container's
    // duration is treated as a lie. Generous: long-GOP encodes place keyframes
    // up to ~10s apart, and a seek resolves to the keyframe at or before the
    // target, so a few seconds of undershoot is normal.
    private const double TAIL_SEEK_TOLERANCE_SECONDS = 30.0;

    private const string VMAF_MODEL_4K_PATH  = "/usr/share/model/vmaf_4k_v0.6.1.json";
    private const int    VMAF_4K_MIN_WIDTH   = 2560;

    /** One probe's measurements: extrapolated size plus perceptual score. */
    private class ProbeMeasurement {
        public double size_kib;
        public double vmaf;
        public bool   vmaf_measured;
        public bool   from_cache;
    }

    /**
     * Model path for this frame size, or null to use libvmaf's built-in
     * default. Only returns a path that actually exists.
     */
    private string? vmaf_model_path (int width) {
        if (width >= VMAF_4K_MIN_WIDTH
                && FileUtils.test (VMAF_MODEL_4K_PATH, FileTest.EXISTS)) {
            return VMAF_MODEL_4K_PATH;
        }
        return null;
    }

    /**
     * Measure VMAF of @distorted against @reference.
     *
     * libvmaf takes the DISTORTED stream first and the reference second, and
     * requires both to match in resolution and frame rate — which is exactly
     * why Quality Mode forces the lossless intermediate: it is the only thing
     * guaranteed to match the probe's frames.
     *
     * Returns the pooled mean. Phase 0 calibrated the intent targets against
     * the mean, so the harmonic mean (which punishes bad frames harder) would
     * need its own target scale before it could be substituted.
     *
     * Returns 0.0 on any failure — the caller treats an unmeasured probe as a
     * missing point rather than aborting the whole run.
     */
    private async double measure_vmaf (
        string        distorted,
        string        reference,
        int           width,
        int           threads,
        string?       temp_run_dir,
        Cancellable?  cancellable
    ) throws Error {
        cancellable_check (cancellable);
        string log = tmp_path ("vmaf", temp_run_dir) + ".json";

        var filter = new StringBuilder ();
        filter.append ("[0:v][1:v]libvmaf=");
        string? model = vmaf_model_path (width);
        if (model != null)
            filter.append ("model=path=%s:".printf (model));
        filter.append ("n_threads=%d:log_fmt=json:log_path=%s".printf (
            int.max (1, threads), log));

        string ffmpeg = AppSettings.get_default ().ffmpeg_path;
        string[] cmd = {
            ffmpeg, "-hide_banner", "-v", "error", "-nostdin",
            "-i", distorted, "-i", reference,
            "-lavfi", filter.str,
            "-f", "null", "-"
        };

        try {
            yield run_subprocess_wait (cmd, cancellable);
        } catch (IOError.CANCELLED e) {
            cleanup_file (log);
            throw e;
        } catch (Error e) {
            cleanup_file (log);
            warning ("Smart Optimizer: VMAF measurement failed: %s", e.message);
            return 0.0;
        }

        double score = 0.0;
        try {
            string contents;
            if (FileUtils.get_contents (log, out contents)) {
                var parser = new Json.Parser ();
                parser.load_from_data (contents);
                var root = parser.get_root ().get_object ();
                if (root != null && root.has_member ("pooled_metrics")) {
                    var pooled = root.get_object_member ("pooled_metrics");
                    if (pooled != null && pooled.has_member ("vmaf")) {
                        var v = pooled.get_object_member ("vmaf");
                        if (v != null && v.has_member ("mean"))
                            score = v.get_double_member ("mean");
                    }
                }
            }
        } catch (Error e) {
            warning ("Smart Optimizer: could not parse VMAF log: %s", e.message);
        }
        cleanup_file (log);

        if (!score.is_finite () || score < 0.0 || score > 100.0) {
            warning ("Smart Optimizer: implausible VMAF %.3f — discarding", score);
            return 0.0;
        }
        return score;
    }

    /**
     * Return one quality measurement, preferring this run's persistent cache.
     * A miss builds the shared reference lazily, encodes the requested CRF,
     * measures it, and records both axes for later correction steps.
     */
    private async ProbeMeasurement quality_measurement_at_crf (
        int                     crf,
        SmartOptimizerCache?    qcache,
        IntermediateHolder      intermediate,
        string                  input_file,
        double[]                positions,
        double                  segment_duration,
        string                  vf,
        SmartOptimizerVideoInfo info,
        string                  codec,
        int                     preset_idx,
        string                  pix_fmt,
        double                  full_duration,
        double                  sample_duration,
        int                     encoder_threads,
        string?                 temp_run_dir,
        Cancellable?            cancellable
    ) throws Error {
        double cached_size = 0.0, cached_vmaf = 0.0;
        if (qcache != null
                && qcache.lookup_with_vmaf (crf, out cached_size, out cached_vmaf)) {
            return new ProbeMeasurement () {
                size_kib = cached_size,
                vmaf = cached_vmaf,
                vmaf_measured = true,
                from_cache = true
            };
        }

        yield ensure_quality_reference (
            intermediate, input_file, positions, segment_duration, vf, pix_fmt,
            info, temp_run_dir, cancellable);
        var measured = yield calibration_probe_with_vmaf (
            codec, crf, preset_idx, pix_fmt, intermediate.path,
            full_duration, sample_duration, 1.0, info.width,
            encoder_threads, temp_run_dir, cancellable);
        if (measured.vmaf_measured && qcache != null)
            qcache.record_with_vmaf (crf, measured.size_kib, measured.vmaf);
        return measured;
    }

    /**
     * Encode one calibration probe and measure BOTH axes from it.
     *
     * Size Mode's calibration_encode deletes the probe as soon as it has the
     * byte count; Quality Mode needs the file alive a moment longer to run
     * libvmaf against it. Same encode, same frames, two numbers — which is
     * what lets every run report both a size and a quality figure regardless
     * of which one the user pinned.
     */
    private async ProbeMeasurement calibration_probe_with_vmaf (
        string        codec,
        int           crf,
        int           preset_idx,
        string        pix_fmt,
        string        intermediate_path,
        double        full_duration,
        double        sample_duration,
        double        extrapolation_weight,
        int           width,
        int           encoder_threads,
        string?       temp_run_dir,
        Cancellable?  cancellable
    ) throws Error {
        var m = new ProbeMeasurement ();
        string tmp = tmp_path ("qcal_%d".printf (crf), temp_run_dir);

        string[] cmd = build_intermediate_probe_cmd (
            intermediate_path, codec, crf, preset_idx, pix_fmt,
            encoder_threads, tmp);

        try {
            yield run_subprocess_wait (cmd, cancellable);
        } catch (Error e) {
            cleanup_file (tmp);
            throw e;
        }

        int64 file_size = 0;
        var file = File.new_for_path (tmp);
        if (file.query_exists ()) {
            var finfo = file.query_info (
                FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
            file_size = finfo.get_size ();
        }
        if (file_size <= 0) {
            cleanup_file (tmp);
            throw new IOError.FAILED (
                "Quality calibration encode produced empty file at CRF %d", crf);
        }

        double sample_kib = SmartOptimizerLogic.kib_from_bytes (file_size);
        double scale = (sample_duration > 0.0)
            ? full_duration / sample_duration : 1.0;
        m.size_kib = sample_kib * scale * extrapolation_weight;

        try {
            m.vmaf = yield measure_vmaf (
                tmp, intermediate_path, width, encoder_threads,
                temp_run_dir, cancellable);
            m.vmaf_measured = (m.vmaf > 0.0);
        } catch (IOError.CANCELLED e) {
            cleanup_file (tmp);
            throw e;
        }

        cleanup_file (tmp);
        return m;
    }

    // ════════════════════════════════════════════════════════════════════════
    // FFMPEG COMMAND BUILDERS
    // ════════════════════════════════════════════════════════════════════════

    /**
     * Build a command that seeks to multiple positions in the input, concats
     * the segments, and runs a filter for analysis (signalstats, edgedetect).
     * Output goes to null; we parse stderr for stats.
     *
     * When video_filter_chain is non-empty, each segment is pre-filtered
     * (e.g. scaled/cropped) before concat so analysis reflects the actual
     * output dimensions and processing.
     */
    private string[] build_concat_analysis_cmd (
        string   path,
        double[] positions,
        double   seg_dur,
        string   filter,
        string   video_filter_chain = ""
    ) {
        string ffmpeg = AppSettings.get_default ().ffmpeg_path;
        var cmd = new GenericArray<string> ();
        cmd.add (ffmpeg);
        cmd.add ("-v");
        cmd.add ("info");   // info level required for signalstats output

        add_segment_inputs (cmd, path, positions, seg_dur);

        // Measured at the source's NATIVE bit depth, deliberately.
        //
        // signalstats reports in the native range, so a 10-bit source yields
        // ~4x the values of the same content at 8-bit. Every threshold in the
        // classifier, the grain gate and the banding metrics compares these
        // across sources, so that scale difference has to be removed — but it
        // is removed in the parser (normalise_amplitude_for_depth), NOT with a
        // format filter here.
        //
        // Converting to 8-bit before measuring does not merely rescale: it
        // quantises away the sub-LSB variation that fine film grain lives in.
        // Measured on a 10-bit film with grain visible at 3x magnification:
        //
        //     YDIF  13.83 native -> 3.46 forced-8-bit   (4.00x — pure scale)
        //     TOUT   0.00194     -> 0.00018             (10.8x — grain LOST)
        //
        // Dividing afterwards reproduces the conversion's answer for motion
        // and saturation while leaving the grain measurement intact.
        cmd.add ("-filter_complex");
        cmd.add (concat_filter_spec (positions.length, video_filter_chain)
            + ";[v]%s".printf (filter));
        cmd.add ("-f");              cmd.add ("null");
        cmd.add ("-");

        return StringArrayUtils.copy_generic_array (cmd);
    }

    /** Append the per-segment seek inputs shared by all sampling commands. */
    private void add_segment_inputs (
        GenericArray<string> cmd,
        string   path,
        double[] positions,
        double   seg_dur
    ) {
        for (int i = 0; i < positions.length; i++) {
            cmd.add ("-ss");  cmd.add (ConversionUtils.format_ffmpeg_double (positions[i], "%.2f"));
            cmd.add ("-t");   cmd.add (ConversionUtils.format_ffmpeg_double (seg_dur, "%.3f"));
            cmd.add ("-i");   cmd.add (path);
        }
    }

    /**
     * Filter-complex spec that optionally pre-filters each segment, then
     * concats them into [v].
     */
    private string concat_filter_spec (int n, string video_filter_chain) {
        var fc = new StringBuilder ();
        bool has_vf = (video_filter_chain.length > 0);

        if (has_vf) {
            // Pre-filter each segment, then concat
            for (int i = 0; i < n; i++)
                fc.append ("[%d:v]%s[s%d];".printf (i, video_filter_chain, i));
            for (int i = 0; i < n; i++)
                fc.append ("[s%d]".printf (i));
        } else {
            for (int i = 0; i < n; i++)
                fc.append ("[%d:v]".printf (i));
        }
        fc.append ("concat=n=%d:v=1:a=0[v]".printf (n));
        return fc.str;
    }

    /** Append the encoder arguments for a calibration probe at @crf. */
    /**
     * Encoder arguments for a calibration probe.
     *
     * @tuning carries the settings the recommendation will actually apply.
     * Without it the probe measures a stripped-down encode and the model
     * describes something the user never receives — on animation that was a
     * 34% size error. See SmartOptimizerLogic.decide_encoder_tuning.
     */
    private void append_video_codec_args (
        GenericArray<string> cmd,
        string codec,
        int    crf,
        int    preset_idx,
        SmartOptimizerLogic.EncoderTuning? tuning = null
    ) {
        if (codec == "vp9") {
            cmd.add ("-c:v");      cmd.add ("libvpx-vp9");
            cmd.add ("-cpu-used"); cmd.add (preset_idx >= 0
                ? VP9_CPU_USED[preset_idx].to_string () : "8");
            cmd.add ("-crf");      cmd.add (crf.to_string ());
            cmd.add ("-b:v");      cmd.add ("0");
            cmd.add ("-row-mt");   cmd.add ("1");
            if (tuning != null && tuning.native_sharpness > 0) {
                cmd.add ("-sharpness");
                cmd.add (tuning.native_sharpness.to_string ());
            }
        } else if (codec == "svt-av1") {
            cmd.add ("-c:v");      cmd.add ("libsvtav1");
            cmd.add ("-preset");   cmd.add (preset_idx >= 0
                ? SVT_AV1_PRESETS[preset_idx].to_string ()
                : SVT_AV1_PRESETS[0].to_string ());
            cmd.add ("-crf");      cmd.add (crf.to_string ());
            if (tuning != null) {
                var p = new GenericArray<string> ();
                if (tuning.film_grain) {
                    p.add ("film-grain=%d".printf (tuning.film_grain_strength));
                    p.add ("film-grain-denoise=1");
                }
                if (tuning.fast_decode_level > 0)
                    p.add ("fast-decode=%d".printf (tuning.fast_decode_level));
                if (tuning.native_sharpness > 0)
                    p.add ("sharpness=%d".printf (tuning.native_sharpness));
                if (p.length > 0) {
                    var joined = new StringBuilder ();
                    for (int i = 0; i < p.length; i++) {
                        if (i > 0) joined.append (":");
                        joined.append (p[i]);
                    }
                    cmd.add ("-svtav1-params"); cmd.add (joined.str);
                }
            }
        } else if (codec == "x265") {
            cmd.add ("-c:v");    cmd.add ("libx265");
            cmd.add ("-preset"); cmd.add (preset_idx >= 0
                ? X265_PRESETS[preset_idx] : "ultrafast");
            cmd.add ("-crf");    cmd.add (crf.to_string ());
            if (tuning != null) {
                if (tuning.tune.length > 0) {
                    cmd.add ("-tune"); cmd.add (tuning.tune);
                }
                if (tuning.psy_rd > 0.0) {
                    cmd.add ("-x265-params");
                    cmd.add ("psy-rd=%s".printf (
                        ConversionUtils.format_ffmpeg_double (tuning.psy_rd, "%.2f")));
                }
            }
        } else {
            cmd.add ("-c:v");    cmd.add ("libx264");
            cmd.add ("-preset"); cmd.add (preset_idx >= 0
                ? X264_PRESETS[preset_idx] : "ultrafast");
            cmd.add ("-crf");    cmd.add (crf.to_string ());
            if (tuning != null && tuning.tune.length > 0) {
                cmd.add ("-tune"); cmd.add (tuning.tune);
            }
        }
    }

    /**
     * Build the one-time command that decodes and filters the sample
     * segments into a lossless intermediate: mathematically identical
     * frames, so probes measure the same sizes — just without paying the
     * decode+filter cost 6-8 times.
     */
    private string[] build_filtered_intermediate_cmd (
        string   path,
        double[] positions,
        double   seg_dur,
        string   video_filter_chain,
        string   pix_fmt,
        string   output
    ) {
        string ffmpeg = AppSettings.get_default ().ffmpeg_path;
        var cmd = new GenericArray<string> ();
        cmd.add (ffmpeg);
        cmd.add ("-y");
        cmd.add ("-v"); cmd.add ("warning");

        add_segment_inputs (cmd, path, positions, seg_dur);

        // Force even dimensions. The intermediate is always encoded with
        // libx264 -qp 0 (8-bit) or FFV1 (10-bit) regardless of the OUTPUT
        // codec, and x264 refuses odd dimensions with yuv420p — "width not
        // divisible by 2" — while VP9 and AV1 sources happily carry them.
        // Screen captures land on odd sizes routinely, so without this the
        // intermediate fails for every codec, taking Quality Mode with it
        // (the intermediate is its VMAF reference).
        //
        // The expression is self-neutralising: trunc(iw/2)*2 == iw when iw is
        // already even, so this is a no-op for the overwhelming majority of
        // sources. Crop rather than scale — dropping one pixel column is
        // lossless for the pixels that remain, where rescaling would resample
        // the whole frame and stop the intermediate being a faithful
        // reference.
        string even_chain = (video_filter_chain.length > 0)
            ? video_filter_chain + ",crop=trunc(iw/2)*2:trunc(ih/2)*2"
            : "crop=trunc(iw/2)*2:trunc(ih/2)*2";

        cmd.add ("-filter_complex");
        cmd.add (concat_filter_spec (positions.length, even_chain));
        cmd.add ("-map");            cmd.add ("[v]");
        cmd.add ("-an");

        if (pix_fmt.contains ("10")) {
            // 10-bit: FFV1 is lossless and always available.
            cmd.add ("-c:v"); cmd.add ("ffv1");
        } else {
            // 8-bit: lossless x264 decodes much faster than FFV1.
            cmd.add ("-c:v");    cmd.add ("libx264");
            cmd.add ("-preset"); cmd.add ("ultrafast");
            cmd.add ("-qp");     cmd.add ("0");
        }
        if (pix_fmt.length > 0) {
            cmd.add ("-pix_fmt"); cmd.add (pix_fmt);
        }

        cmd.add ("-f");    cmd.add ("matroska");
        cmd.add (output);

        return StringArrayUtils.copy_generic_array (cmd);
    }

    /**
     * Calibration probe reading the pre-filtered lossless intermediate:
     * no seeks, no filters — just decode and encode at the probe CRF.
     */
    private string[] build_intermediate_probe_cmd (
        string intermediate_path,
        string codec,
        int    crf,
        int    preset_idx,
        string pix_fmt,
        int    encoder_threads,
        string output
    ) {
        string ffmpeg = AppSettings.get_default ().ffmpeg_path;
        var cmd = new GenericArray<string> ();
        cmd.add (ffmpeg);
        cmd.add ("-y");
        cmd.add ("-v"); cmd.add ("warning");
        cmd.add ("-i"); cmd.add (intermediate_path);
        cmd.add ("-an");

        append_video_codec_args (cmd, codec, crf, preset_idx, active_tuning);

        if (pix_fmt.length > 0) {
            cmd.add ("-pix_fmt"); cmd.add (pix_fmt);
        }
        if (encoder_threads > 0) {
            cmd.add ("-threads"); cmd.add (encoder_threads.to_string ());
        }

        cmd.add ("-f");    cmd.add ("matroska");
        cmd.add (output);

        return StringArrayUtils.copy_generic_array (cmd);
    }

    /**
     * Build a command that encodes concat'd segments to a file at a given CRF.
     *
     * When video_filter_chain is non-empty, each segment is pre-filtered
     * before concat so the calibration output reflects the actual encode size.
     *
     * @param preset_idx  When >= 0, use this preset index instead of the
     *                    fastest preset.
     * @param encoder_threads  When > 0, cap encoder threads (used when
     *                         several calibration encodes run in parallel).
     */
    private string[] build_concat_encode_cmd (
        string   path,
        string   codec,
        int      crf,
        double[] positions,
        double   seg_dur,
        string   output,
        string   video_filter_chain = "",
        int      preset_idx = -1,
        string   pix_fmt = "",
        int      encoder_threads = 0
    ) {
        string ffmpeg = AppSettings.get_default ().ffmpeg_path;
        var cmd = new GenericArray<string> ();
        cmd.add (ffmpeg);
        cmd.add ("-y");
        cmd.add ("-v"); cmd.add ("warning");

        add_segment_inputs (cmd, path, positions, seg_dur);

        cmd.add ("-filter_complex");
        cmd.add (concat_filter_spec (positions.length, video_filter_chain));
        cmd.add ("-map");            cmd.add ("[v]");
        cmd.add ("-an");             // no audio for calibration

        append_video_codec_args (cmd, codec, crf, preset_idx, active_tuning);

        if (pix_fmt.length > 0) {
            cmd.add ("-pix_fmt"); cmd.add (pix_fmt);
        }

        if (encoder_threads > 0) {
            cmd.add ("-threads"); cmd.add (encoder_threads.to_string ());
        }

        cmd.add ("-f");    cmd.add ("matroska");
        cmd.add (output);

        return StringArrayUtils.copy_generic_array (cmd);
    }

    // ════════════════════════════════════════════════════════════════════════
    // PARSING
    // ════════════════════════════════════════════════════════════════════════

    /**
     * Parse signalstats output for SATAVG, YDIF, YLOW, YAVG, and TOUT
     * fields across all frames.
     *
     * Uses a dual-strategy approach for robustness across ffmpeg builds:
     *   Primary:   lines prefixed with "Parsed_signalstats" (standard format)
     *   Fallback:  any line containing both "SATAVG:" and "YDIF:" fields
     *              (handles builds that omit the filter-name prefix)
     */
    private void parse_signalstats (
        string      text,
        ref double[] satavg_out,
        ref double[] ydif_out,
        ref double[] ylow_out,
        ref double[] yavg_out,
        ref double[] tout_out
    ) {
        var sat_list  = new GenericArray<double?> ();
        var ydif_list = new GenericArray<double?> ();
        var ylow_list = new GenericArray<double?> ();
        var yavg_list = new GenericArray<double?> ();
        var tout_list = new GenericArray<double?> ();

        foreach (unowned string line in text.split ("\n")) {
            // Primary: metadata=print output — one "lavfi.signalstats.KEY=value"
            // per line. Fallback: legacy colon-delimited multi-field lines.
            bool is_metadata_line = line.contains ("lavfi.signalstats.");
            bool is_legacy_line   = line.contains ("Parsed_signalstats")
                || (line.contains ("SATAVG:") && line.contains ("YDIF:"));
            if (!is_metadata_line && !is_legacy_line) continue;

            double? sat  = parse_field_value (line, "lavfi.signalstats.SATAVG=")
                        ?? parse_field_value (line, "SATAVG:");
            double? ydif = parse_field_value (line, "lavfi.signalstats.YDIF=")
                        ?? parse_field_value (line, "YDIF:");
            double? ylow = parse_field_value (line, "lavfi.signalstats.YLOW=")
                        ?? parse_field_value (line, "YLOW:");
            double? yavg = parse_field_value (line, "lavfi.signalstats.YAVG=")
                        ?? parse_field_value (line, "YAVG:");
            double? tout = parse_field_value (line, "lavfi.signalstats.TOUT=")
                        ?? parse_field_value (line, "TOUT:");
            if (sat  != null) sat_list.add (sat);
            if (ydif != null) ydif_list.add (ydif);
            if (ylow != null) ylow_list.add (ylow);
            if (yavg != null) yavg_list.add (yavg);
            if (tout != null) tout_list.add (tout);
        }

        if (sat_list.length > int.MAX) {
            satavg_out = {};
            ydif_out = {};
            ylow_out = {};
            yavg_out = {};
            tout_out = {};
            return;
        }

        satavg_out = new double[(int) sat_list.length];
        for (int i = 0; i < sat_list.length; i++) satavg_out[i] = sat_list[i];

        if (ydif_list.length > int.MAX) {
            satavg_out = {};
            ydif_out = {};
            ylow_out = {};
            yavg_out = {};
            tout_out = {};
            return;
        }

        ydif_out = new double[(int) ydif_list.length];
        for (int i = 0; i < ydif_list.length; i++) ydif_out[i] = ydif_list[i];

        if (ylow_list.length > int.MAX) {
            satavg_out = {};
            ydif_out = {};
            ylow_out = {};
            yavg_out = {};
            tout_out = {};
            return;
        }

        ylow_out = new double[(int) ylow_list.length];
        for (int i = 0; i < ylow_list.length; i++) ylow_out[i] = ylow_list[i];

        if (yavg_list.length > int.MAX) {
            satavg_out = {};
            ydif_out = {};
            ylow_out = {};
            yavg_out = {};
            tout_out = {};
            return;
        }

        yavg_out = new double[(int) yavg_list.length];
        for (int i = 0; i < yavg_list.length; i++) yavg_out[i] = yavg_list[i];

        if (tout_list.length > int.MAX) {
            satavg_out = {};
            ydif_out = {};
            ylow_out = {};
            yavg_out = {};
            tout_out = {};
            return;
        }

        tout_out = new double[(int) tout_list.length];
        for (int i = 0; i < tout_list.length; i++) tout_out[i] = tout_list[i];
    }

    /**
     * Parse any `lavfi.<key>=<value>` metadata line, for filters outside the
     * signalstats namespace (siti, blockdetect, blurdetect, scdet).
     */
    private void parse_metadata_field (
        string        output,
        string        key,
        ref double[]  values
    ) {
        string needle = key + "=";
        var list = new GenericArray<double?> ();
        foreach (unowned string line in output.split ("\n")) {
            int idx = line.index_of (needle);
            if (idx < 0)
                continue;
            string raw = line.substring (idx + needle.length).strip ();
            double v;
            if (try_parse_double (raw, out v) && v.is_finite ())
                list.add (v);
        }
        var parsed = new double[list.length];
        for (int i = 0; i < list.length; i++)
            parsed[i] = list[i];
        values = parsed;
    }

    /**
     * Parse a single named field (like YAVG) from signalstats output.
     * Dual-strategy: prefer the Parsed_signalstats prefix, fall back to any
     * line that contains the requested field name.
     */
    private void parse_signalstats_field (
        string      text,
        string      field_name,
        ref double[] values_out
    ) {
        string key_metadata = "lavfi.signalstats." + field_name + "=";
        string key_legacy   = field_name + ":";
        var    list = new GenericArray<double?> ();

        foreach (unowned string line in text.split ("\n")) {
            bool is_stats_line = line.contains (key_metadata)
                || line.contains ("Parsed_signalstats")
                || line.contains (key_legacy);
            if (!is_stats_line) continue;
            double? val = parse_field_value (line, key_metadata)
                       ?? parse_field_value (line, key_legacy);
            if (val != null) list.add (val);
        }

        if (list.length > int.MAX) {
            values_out = {};
            return;
        }

        values_out = new double[(int) list.length];
        for (int i = 0; i < list.length; i++) values_out[i] = list[i];
    }

    /**
     * Find "KEY:value" in a line and parse the numeric value.
     * Returns null if not found.
     */
    private double? parse_field_value (string line, string key) {
        int idx = line.index_of (key);
        if (idx < 0) return null;

        string after = line.substring (idx + key.length);
        double val = 0.0;
        if (try_extract_number (after, out val))
            return val;
        return null;
    }

    /**
     * Extract the first numeric value from a string.
     * Returns false if no digits were found (distinguishes parse failure
     * from a legitimately parsed 0.0). Uses g_ascii_strtod via
     * double.try_parse for locale independence.
     *
     * Handles scientific notation (e.g. "5.20833e-05") — signalstats reports
     * small fractions like TOUT in exponential form, and stopping at the 'e'
     * would truncate "5.2e-05" to "5.2", a ~100000x error.
     */
    private bool try_extract_number (string text, out double value) {
        value = 0.0;
        var  buf       = new StringBuilder ();
        bool in_number = false;
        bool exp_seen  = false;
        for (int i = 0; i < text.length && buf.len < 24; i++) {
            char c = text[i];
            if (!in_number && (c == ' ' || c == '\t')) continue;
            if (c.isdigit () || c == '.' || (c == '-' && !in_number)) {
                buf.append_c (c);
                in_number = true;
            } else if (in_number && !exp_seen && (c == 'e' || c == 'E')
                       && i + 1 < text.length
                       && (text[i + 1].isdigit ()
                           || ((text[i + 1] == '-' || text[i + 1] == '+')
                               && i + 2 < text.length && text[i + 2].isdigit ()))) {
                // exponent marker, only when a valid exponent digit follows
                buf.append_c (c);
                exp_seen = true;
                if (text[i + 1] == '-' || text[i + 1] == '+') {
                    buf.append_c (text[i + 1]);
                    i++;
                }
            } else if (in_number) {
                break;
            }
        }
        if (buf.len == 0) return false;
        unowned string unparsed = null;
        if (!double.try_parse (buf.str, out value, out unparsed))
            return false;
        return true;
    }

    /**
     * Parse "30000/1001" or "30" into a double.
     */
    private double parse_fraction (string s) {
        double parsed = 0.0;
        if (try_parse_fraction_value (s, out parsed) && parsed > 0) {
            return parsed;
        }
        return 24.0;
    }

    private bool try_parse_double (string? text, out double value) {
        value = 0.0;
        if (text == null) return false;

        string raw = text.strip ();
        if (raw.length == 0) return false;
        if (raw == "N/A" || raw == "nan" || raw == "NaN") return false;

        unowned string unparsed = null;
        if (!double.try_parse (raw, out value, out unparsed)) return false;
        return unparsed == null || unparsed.strip ().length == 0;
    }

    private bool try_parse_int64 (string? text, out int64 value) {
        value = 0;
        if (text == null) return false;

        string raw = text.strip ();
        if (raw.length == 0) return false;
        if (raw == "N/A") return false;

        unowned string unparsed = null;
        if (!int64.try_parse (raw, out value, out unparsed, 10)) return false;
        return unparsed == null || unparsed.strip ().length == 0;
    }

    private bool try_parse_fraction_value (string? text, out double value) {
        value = 0.0;
        if (text == null) return false;

        string raw = text.strip ();
        if (raw.length == 0 || raw == "N/A") return false;

        if ("/" in raw) {
            var parts = raw.split ("/");
            if (parts.length < 2) return false;

            double num = 0.0;
            double den = 0.0;
            if (!try_parse_double (parts[0], out num)
                || !try_parse_double (parts[1], out den)
                || den <= 0.0) {
                return false;
            }

            value = num / den;
            return value > 0.0;
        }

        return try_parse_double (raw, out value) && value > 0.0;
    }

    // ════════════════════════════════════════════════════════════════════════
    // SUBPROCESS HELPERS
    // ════════════════════════════════════════════════════════════════════════

    /** Run a command, return its stdout as a string. */
    private async string run_subprocess_stdout (string[] cmd, Cancellable? cancellable = null) throws Error {
        var launcher = new SubprocessLauncher (
            SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
        var proc = SubprocessCompat.spawnv (launcher, cmd);
        string stdout_buf;
        string stderr_buf;
        try {
            yield proc.communicate_utf8_async (null, cancellable, out stdout_buf, out stderr_buf);
        } catch (Error e) {
            proc.force_exit ();
            throw e;
        }
        ensure_subprocess_success (proc, cmd, stdout_buf, stderr_buf);
        return stdout_buf ?? "";
    }

    /** Run a command, return its stderr as a string (for ffmpeg stats parsing). */
    private async string run_subprocess_stderr (string[] cmd, Cancellable? cancellable = null) throws Error {
        var launcher = new SubprocessLauncher (
            SubprocessFlags.STDERR_PIPE | SubprocessFlags.STDOUT_PIPE);
        var proc = SubprocessCompat.spawnv (launcher, cmd);
        string stdout_buf;
        string stderr_buf;
        try {
            yield proc.communicate_utf8_async (null, cancellable, out stdout_buf, out stderr_buf);
        } catch (Error e) {
            proc.force_exit ();
            throw e;
        }
        ensure_subprocess_success (proc, cmd, stdout_buf, stderr_buf);
        return stderr_buf ?? "";
    }

    /**
     * Run a command, wait for it to finish.
     * Captures stderr so that failure messages are included in thrown errors.
     */
    private async void run_subprocess_wait (string[] cmd, Cancellable? cancellable = null) throws Error {
        var launcher = new SubprocessLauncher (
            SubprocessFlags.STDERR_PIPE | SubprocessFlags.STDOUT_SILENCE);
        var proc = SubprocessCompat.spawnv (launcher, cmd);

        string stdout_buf;
        string stderr_buf;
        try {
            yield proc.communicate_utf8_async (null, cancellable, out stdout_buf, out stderr_buf);
        } catch (Error e) {
            proc.force_exit ();
            throw e;
        }

        if (!proc.get_successful ()) {
            ensure_subprocess_success (proc, cmd, stdout_buf, stderr_buf);
        }
    }

    private void ensure_subprocess_success (
        Subprocess proc,
        string[]   cmd,
        string?    stdout_buf,
        string?    stderr_buf
    ) throws Error {
        if (proc.get_successful ()) return;

        string detail = (stderr_buf != null && stderr_buf.strip ().length > 0)
            ? stderr_buf.strip ()
            : ((stdout_buf != null && stdout_buf.strip ().length > 0)
                ? stdout_buf.strip ()
                : "no output");
        throw new IOError.FAILED (
            "Command failed: %s\nTool said: %s",
            ConversionUtils.format_command_for_display (cmd), detail);
    }

    // ════════════════════════════════════════════════════════════════════════
    // UTILITIES
    // ════════════════════════════════════════════════════════════════════════

    /**
     * Check if the operation has been cancelled and throw if so.
     * Convenience wrapper around Cancellable.set_error_if_cancelled().
     */
    private void cancellable_check (Cancellable? cancellable) throws IOError {
        if (cancellable != null && cancellable.is_cancelled ()) {
            throw new IOError.CANCELLED ("Operation cancelled by user");
        }
    }

    private string format_preset_label (string codec, int preset_idx) {
        if (codec == "vp9") {
            return "cpu-used %d".printf (VP9_CPU_USED[preset_idx]);
        } else if (codec == "svt-av1") {
            return "preset %d".printf (SVT_AV1_PRESETS[preset_idx]);
        } else if (codec == "x265") {
            return X265_PRESETS[preset_idx];
        }
        return X264_PRESETS[preset_idx];
    }

    private string tmp_path (string label, string? temp_run_dir = null) {
        if (temp_run_dir != null) {
            string? managed_path = ConversionUtils.create_managed_temp_file (
                temp_run_dir,
                "smart-opt-" + label,
                ".mkv"
            );
            if (managed_path != null) {
                return managed_path;
            }
        }

        return GLib.Path.build_filename (
            Environment.get_tmp_dir (),
            "smart_opt_%s_%s.mkv".printf (label, get_real_time ().to_string ()));
    }

    private void cleanup_temp_run_dir (string? run_dir) {
        if (run_dir == null)
            return;

        ConversionUtils.try_remove_empty_dir_chain (
            run_dir,
            ConversionUtils.get_app_temp_root ()
        );
    }

    private void cleanup_file (string path) {
        if (FileUtils.test (path, FileTest.EXISTS) && FileUtils.unlink (path) != 0) {
            warning ("Failed to clean up temp file %s: %s", path, strerror (errno));
        }
    }

    private OptimizationRecommendation make_error_rec (string codec, string message) {
        return OptimizationRecommendation () {
            codec                  = codec,
            crf                    = 0,
            preset                 = "",
            two_pass               = false,
            target_bitrate_kbps    = 0,
            estimated_size_kib     = 0,
            notes                  = "❌ " + message,
            is_impossible          = true,
            content_type           = ContentType.LIVE_ACTION,
            detail_score           = 0.0,
            native_sharpness       = 0,
            confidence             = 0.0,
            size_tier              = SizeTier.TINY,
            recommended_audio_kbps = 64,
            total_audio_budget_kbps = 0,
            audio_track_count      = 0,
            preserve_all_audio_tracks_effective = false,
            stream_copy_audio      = false,
            strip_metadata         = false,
            recommended_pix_fmt    = "",
            resolved_container     = SmartOptimizerLogic.codec_default_container (codec),
            target_size_kib        = 0,
            // Inert — callers bail on is_impossible before applying a
            // recommendation.  Kept consistent with the TINY tier above so a
            // future path that does read these gets no surprises.
            effort                 = EncodeEffort.MINIMAL,
            force_compat_container = true,
            pinned_axis            = PinnedAxis.SIZE,
            estimated_vmaf         = 0.0,
            vmaf_measured          = false,
            fast_decode            = false,
            source_bit_depth       = 8
        };
    }
}
