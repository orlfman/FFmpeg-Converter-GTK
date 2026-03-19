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

using GLib;
using Json;

// ════════════════════════════════════════════════════════════════════════════
// Public types
// ════════════════════════════════════════════════════════════════════════════

public enum ContentType {
    LIVE_ACTION,
    ANIME,
    SCREENCAST,
    MIXED;

    public string to_label () {
        switch (this) {
            case ANIME:      return "🎌 Anime / Animation";
            case SCREENCAST: return "🖥️ Screencast / Static";
            case MIXED:      return "🎬 Mixed content";
            default:         return "🎥 Live-action";
        }
    }
}

/**
 * Size tier — determines the optimization strategy.
 *
 * As target size increases, the optimizer shifts from aggressive compression
 * toward quality maximization: slower presets matter less (diminishing returns
 * at higher bitrates), audio budget increases, encoder features are pushed
 * toward perceptual quality rather than size reduction, and two-pass is
 * recommended less aggressively.
 */
public enum SizeTier {
    TINY,       // ≤ 25 MB  — imageboard / extreme compression
    SMALL,      // 25–50 MB — size-conscious but more headroom
    MEDIUM,     // 50–100 MB — balanced quality and size
    LARGE,      // 100–200 MB — quality-focused
    XLARGE;     // 200+ MB  — quality-first, generous budget

    public static SizeTier from_mb (int mb) {
        if (mb <= 25)  return TINY;
        if (mb <= 50)  return SMALL;
        if (mb <= 100) return MEDIUM;
        if (mb <= 200) return LARGE;
        return XLARGE;
    }

    public string to_label () {
        switch (this) {
            case TINY:   return "Tiny (≤25 MB)";
            case SMALL:  return "Small (25–50 MB)";
            case MEDIUM: return "Medium (50–100 MB)";
            case LARGE:  return "Large (100–200 MB)";
            case XLARGE: return "XLarge (200+ MB)";
            default:     return "Unknown";
        }
    }
}

public struct OptimizationRecommendation {
    public string codec;
    public int crf;
    public string preset;
    public bool two_pass;
    public int target_bitrate_kbps;    // for two-pass constrained mode
    public int estimated_size_kib;
    public string notes;
    public bool is_impossible;
    public ContentType content_type;
    public double confidence;          // 0.0–1.0, how far we extrapolated
    public SizeTier size_tier;         // optimization strategy tier
    public int recommended_audio_kbps; // audio bitrate the preset should use
    public bool stream_copy_audio;     // true when source audio should be copied, not re-encoded
    public bool strip_metadata;        // true for TINY tier — save every byte
    public string recommended_pix_fmt; // "yuv420p10le", "yuv420p", or "" (codec default)
    public string resolved_container;  // effective container after tier policy (e.g. "webm", "mp4", "mkv")
    public int target_size_kib;        // user-requested target size in KiB
}

// ════════════════════════════════════════════════════════════════════════════
// Internal data carriers
// ════════════════════════════════════════════════════════════════════════════

internal struct SmartOptimizerVideoInfo {
    public double duration;
    public int    width;
    public int    height;
    public double fps;
    public int    audio_bitrate_kbps;
    public bool   audio_bitrate_estimated;   // true when we fell back to a default
    public string audio_codec;               // e.g. "opus", "aac", "vorbis"
    public int64  file_size_bytes;            // source file size from format.size or stat
    public int    source_bit_depth;           // 8, 10, 12… (0 = unknown)
    public string color_transfer;             // "smpte2084", "arib-std-b67", ""
    public string color_primaries;            // "bt2020", "bt709", ""
}

internal struct ContentProfile {
    public double      edge_mean;
    public double      edge_stddev;
    public double      saturation_mean;
    public double      saturation_stddev;
    public double      temporal_diff_mean;   // YDIF average across frames
    public double      temporal_diff_stddev;
    public ContentType content_type;
    public double      type_confidence;
    public double      banding_risk;         // 0.0–1.0 composite score
    public double      low_luma_ratio;       // fraction of frames with high dark pixel count
    public double      dark_scene_ratio;     // fraction of frames where avg luma < 60
}

/**
 * Optional context from the caller (GeneralTab settings, etc.) that affects
 * calibration accuracy. All fields have safe defaults.
 */
public struct OptimizationContext {
    /** FFmpeg video filter chain (e.g. "scale=iw*0.5:-2,crop=...").
     *  Empty string means no filters. Applied to calibration encodes
     *  so size estimates reflect the actual output resolution/processing. */
    public string video_filter_chain;

    /** Trim start in seconds. 0 means start from the beginning. */
    public double trim_start_seconds;

    /** Trim end in seconds. 0 means run until the source duration. */
    public double trim_end_seconds;

    /** Effective encode duration in seconds, accounting for seek/time trim.
     *  0 means use the full probed duration. */
    public double effective_duration;

    /** Override the probed audio bitrate (kbps) with the value that will
     *  actually be used in the encode (e.g. 64 for Opus, 128 for AAC).
     *  0 means probe from the source file. */
    public int audio_bitrate_kbps_override;

    /** When true, no audio track will be muxed — the entire file budget
     *  goes to video. Overrides audio_bitrate_kbps_override. */
    public bool strip_audio;

    /** true when HDR→SDR tonemap filter is in the chain */
    public bool tone_mapping_active;

    /** When true, audio filters (speed change, normalization, concat)
     *  are active — stream-copy is not possible, audio must be re-encoded. */
    public bool audio_requires_reencode;

    /** Output container format (e.g. "mkv", "mp4", "webm").
     *  Used for audio stream-copy compatibility checks.
     *  Empty string means infer from codec (conservative fallback). */
    public string output_container;
}

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

    // Analysis segment config
    private const int    SEGMENT_DURATION   = 8;        // seconds per sample
    private const int    MIN_SEGMENTS       = 2;        // absolute minimum
    private const int    ADAPTIVE_MAX_SEGMENTS = 16;    // cap when content variance is high
    private const int    ADAPTIVE_CALIBRATION_BASE_MAX_POINTS = 6; // 4 base + up to 2 follow-up CRFs

    // Minimum sample coverage target (15%). The segment count is computed
    // from this so that short and medium videos get enough coverage to
    // avoid the "representative samples" problem where 4 fixed segments
    // miss entire complexity regions.
    //   278s video → ceil(278 × 0.15 / 8) = 6 segments (17% coverage)
    //   600s video → ceil(600 × 0.15 / 8) = 12 segments (16% coverage)
    // Hard caps still apply per duration tier to bound encode time.
    private const double MIN_COVERAGE_TARGET = 0.15;
    private const int    BASE_MAX_SEGMENTS   = 6;       // cap for videos < 10 min
    private const int    LONG_MAX_SEGMENTS   = 10;      // cap for videos 10–45 min
    private const int    VLONG_MAX_SEGMENTS  = 14;      // cap for videos > 45 min

    private const double LONG_VIDEO_THRESHOLD  = 600.0; // 10 minutes
    private const double VLONG_VIDEO_THRESHOLD = 2700.0; // 45 minutes
    private const double SEGMENT_SPREAD    = 0.15;      // start at 15%, end at 85%
    // Coefficient of variation threshold for adaptive expansion.
    // If temporal_diff stddev/mean exceeds this, content varies significantly
    // across the video and more samples improve prediction accuracy.
    private const double ADAPTIVE_CV_THRESHOLD = 0.60;
    private const int    ADAPTIVE_CALIBRATION_EDGE_MARGIN = 1;

    // If the required video bitrate would fall below this threshold it is
    // physically impossible to produce acceptable-quality output.
    private const int MIN_VIABLE_VIDEO_KBPS = 80;

    private const double BITS_PER_BYTE = 8.0;
    private const double BITS_PER_KILOBIT = 1000.0;
    private const double BYTES_PER_KIB = 1024.0;
    private const double KIB_PER_MIB = 1024.0;

    // Container overhead (headers, index, seek tables) in KiB per tier.
    // Subtracted from the video budget so the final file actually fits.
    private const double CONTAINER_OVERHEAD_KIB_TINY   = 50.0;
    private const double CONTAINER_OVERHEAD_KIB_SMALL  = 80.0;
    private const double CONTAINER_OVERHEAD_KIB_MEDIUM = 120.0;
    private const double CONTAINER_OVERHEAD_KIB_LARGE  = 200.0;
    private const double CONTAINER_OVERHEAD_KIB_XLARGE = 300.0;

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
        int requested_target_mb = target_mb;
        target_mb = target_mb.clamp (1, 4096);
        if (target_mb != requested_target_mb) {
            warning ("Smart Optimizer: target %d MB out of range, clamped to %d MB",
                requested_target_mb, target_mb);
        }

        // ── 1. Probe ────────────────────────────────────────────────────
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

        // ── 1b. Apply context overrides ─────────────────────────────────
        double trim_start = (ctx.trim_start_seconds > 0)
            ? double.min (ctx.trim_start_seconds, info.duration)
            : 0.0;
        double trim_end = (ctx.trim_end_seconds > 0)
            ? double.min (ctx.trim_end_seconds, info.duration)
            : info.duration;

        if (ctx.effective_duration > 0) {
            trim_end = double.min (trim_end, trim_start + ctx.effective_duration);
        }
        if (trim_end <= trim_start) {
            trim_start = 0.0;
            trim_end = info.duration;
        }

        bool trim_active = trim_start > 0.0 || trim_end < info.duration;
        double encode_duration = trim_end - trim_start;
        if (encode_duration <= 0) {
            encode_duration = (ctx.effective_duration > 0)
                ? ctx.effective_duration
                : info.duration;
            trim_start = 0.0;
            trim_end = double.min (encode_duration, info.duration);
            trim_active = false;
        }
        double sample_segment_duration = double.min ((double) SEGMENT_DURATION, encode_duration);

        // Save probed audio info before any overrides — we need it
        // to decide whether stream-copying audio is viable.
        string probed_audio_codec      = info.audio_codec;
        int    probed_audio_kbps       = info.audio_bitrate_kbps;
        bool   probed_audio_estimated  = info.audio_bitrate_estimated;

        if (ctx.strip_audio) {
            // No audio track — entire budget goes to video
            info.audio_bitrate_kbps      = 0;
            info.audio_bitrate_estimated = false;
        } else if (ctx.audio_bitrate_kbps_override > 0) {
            info.audio_bitrate_kbps      = ctx.audio_bitrate_kbps_override;
            info.audio_bitrate_estimated = false;
        }

        string vf = (ctx.video_filter_chain != null) ? ctx.video_filter_chain : "";

        // ── 1c. Size tier & audio budget ─────────────────────────────────
        SizeTier tier = SizeTier.from_mb (target_mb);
        int tier_audio = tier_audio_kbps (tier);
        bool use_stream_copy_audio = false;

        // Resolve the effective container once:
        //   Tiny/Small → forced to codec default (webm/mp4) for imageboard compat
        //   Medium+    → respect the user's container selection
        string resolved_container = resolve_effective_container (
            preferred_codec, tier, ctx.output_container);

        // Determine the actual audio budget:
        //   1. If the caller stripped audio or set an explicit override, honour that.
        //   2. Otherwise, try to stream-copy the source audio when it is compatible
        //      with the output container and its bitrate fits within the tier budget.
        //      This gives an *exact* audio size rather than a budget estimate.
        //   3. Otherwise, use the tier-based audio budget (re-encode).
        if (!ctx.strip_audio && ctx.audio_bitrate_kbps_override <= 0) {
            bool codec_compatible = audio_codec_compatible_with_container (
                probed_audio_codec, resolved_container);

            if (codec_compatible
                    && !ctx.audio_requires_reencode
                    && probed_audio_kbps > 0
                    && !probed_audio_estimated
                    && probed_audio_kbps <= tier_audio) {
                // Source audio is efficient enough — stream copy for exact size
                use_stream_copy_audio = true;
                info.audio_bitrate_kbps      = probed_audio_kbps;
                info.audio_bitrate_estimated = false;
            } else {
                info.audio_bitrate_kbps      = tier_audio;
                info.audio_bitrate_estimated = false;
            }
        }

        // ── 2. Early feasibility check ──────────────────────────────────
        // Before running any encode, check if the target is even physically
        // plausible. This saves the user waiting through two calibration
        // encodes for a result that was never achievable.
        double target_total_kib = mib_to_kib ((double) target_mb);
        double container_overhead_kib = container_overhead_for_tier (tier);
        double audio_kib = (info.audio_bitrate_kbps > 0)
            ? kib_from_kbps_for_duration ((double) info.audio_bitrate_kbps, encode_duration)
            : 0.0;
        double video_target_kib = target_total_kib - audio_kib - container_overhead_kib;

        if (video_target_kib <= 0) {
            return make_error_rec (preferred_codec,
                "Audio track alone (~%.0f KiB) exceeds the %d MB target."
                    .printf (audio_kib, target_mb));
        }

        int available_video_kbps = (int) kbps_from_kib_for_duration (
            video_target_kib, encode_duration);
        if (available_video_kbps < MIN_VIABLE_VIDEO_KBPS) {
            var msg = new StringBuilder ();
            msg.append ("Target is physically implausible for this video.\n\n");
            msg.append ("Available video bitrate: %d kbps\n".printf (available_video_kbps));
            msg.append ("Minimum for any recognisable quality: %d kbps\n\n"
                .printf (MIN_VIABLE_VIDEO_KBPS));

            // Suggest what duration or scale would be needed
            if (info.width > 0 && info.height > 0) {
                // At MIN_VIABLE_VIDEO_KBPS, how many seconds can we fit?
                double max_duration_s = seconds_for_kib_at_kbps (
                    video_target_kib, MIN_VIABLE_VIDEO_KBPS);
                msg.append ("Options:\n");
                msg.append ("  • Trim to ≤%.0f seconds at current resolution\n"
                    .printf (max_duration_s));

                // What scale factor would make MIN_VIABLE_VIDEO_KBPS feasible
                // at the current duration? Bitrate scales roughly with pixel count.
                double scale_factor = Math.sqrt (
                    (double) available_video_kbps / MIN_VIABLE_VIDEO_KBPS);
                if (scale_factor < 1.0 && scale_factor > 0.1) {
                    int new_w = ((int) (info.width  * scale_factor)) / 2 * 2;
                    int new_h = ((int) (info.height * scale_factor)) / 2 * 2;
                    msg.append ("  • Scale to ~%d×%d (%.0f%% of original)\n"
                        .printf (new_w, new_h, scale_factor * 100.0));
                }
                msg.append ("  • Increase the target size");
            } else {
                msg.append ("Consider:\n");
                msg.append ("  • Trimming the video to a shorter clip\n");
                msg.append ("  • Scaling down the resolution\n");
                msg.append ("  • Increasing the target size");
            }
            return make_error_rec (preferred_codec, msg.str);
        }

        // ── 3. Pick sample positions ────────────────────────────────────
        // Sample within the effective trim window so analysis matches the
        // frames that will actually be encoded.
        double[] positions = pick_sample_positions_in_window (
            trim_start, encode_duration, sample_segment_duration);

        // ── 4. Content detection ────────────────────────────────────────
        ContentProfile profile;
        try {
            cancellable_check (cancellable);
            profile = yield analyze_content (
                input_file, positions, sample_segment_duration, info, vf, cancellable);
        } catch (IOError.CANCELLED e) {
            throw e;
        } catch (Error e) {
            warning ("Content analysis failed, assuming live-action: %s", e.message);
            profile = ContentProfile () {
                content_type    = ContentType.LIVE_ACTION,
                type_confidence = 0.0
            };
        }

        // ── 4b. Adaptive segment expansion ───────────────────────────────
        // If content analysis reveals high variability between segments
        // (e.g. action scenes interspersed with dialogue), expand the
        // sample positions for calibration to improve size prediction.
        // The content classification from step 4 is already done and
        // doesn't need re-running — only calibration benefits from more
        // samples.
        bool adaptive_expanded = false;
        if (profile.temporal_diff_mean > 0) {
            double motion_cv = profile.temporal_diff_stddev / profile.temporal_diff_mean;
            if (motion_cv > ADAPTIVE_CV_THRESHOLD && positions.length < ADAPTIVE_MAX_SEGMENTS) {
                int initial_count = positions.length;
                int expanded_count = int.min (
                    ADAPTIVE_MAX_SEGMENTS,
                    (int) (encode_duration / sample_segment_duration));
                if (expanded_count > initial_count) {
                    positions = pick_sample_positions_n_in_window (
                        trim_start, encode_duration, sample_segment_duration, expanded_count);
                    adaptive_expanded = true;
                    warning ("Smart Optimizer: high content variability (CV=%.2f) — "
                        + "expanded from %d to %d calibration segments",
                        motion_cv, initial_count, positions.length);
                }
            }
        }

        // ── 4c. Bit depth decision ──────────────────────────────────────
        var bit_depth = decide_bit_depth (info, profile, tier, preferred_codec,
            ctx.tone_mapping_active);
        string calibration_pix_fmt = bit_depth.pix_fmt;

        // ── 5. Content-aware, tier-scaled preset selection ────────────
        // Moved before calibration so we can calibrate at the target preset
        // directly, eliminating the need for preset efficiency factor tables
        // and the verification correction loop.
        // At larger targets, slower presets have diminishing returns because
        // the encoder already has plenty of bits. The "safe" baseline shifts
        // faster, and content-type influence is dampened.
        int ideal_preset_idx = choose_ideal_preset_index (profile);
        int safe_preset_idx  = tier_safe_preset_index (tier, preferred_codec);
        double content_factor = tier_content_influence (tier);

        int preset_idx = safe_preset_idx + (int) Math.round (
            (ideal_preset_idx - safe_preset_idx) * profile.type_confidence * content_factor);
        preset_idx = preset_idx.clamp (0, X264_PRESETS.length - 1);

        // ── 6. Base CRF calibration ────────────────────────────────────
        // Encode sample segments at four CRFs with the TARGET preset,
        // measure sizes, then fit a quadratic curve in log-space via least-
        // squares. This base window can be adaptively extended later when
        // the predicted answer falls outside or right at the edge.
        // Video filters are included so calibration reflects the actual
        // output resolution and processing.
        //
        // By calibrating at the target preset, the model directly predicts
        // what the actual encode will produce — no preset efficiency factor
        // correction is needed.

        int[] cal_crfs = new int[4];
        pick_calibration_crfs (preferred_codec, tier,
            out cal_crfs[0], out cal_crfs[1], out cal_crfs[2], out cal_crfs[3]);

        double[] cal_sizes = new double[4];
        try {
            for (int ci = 0; ci < cal_crfs.length; ci++) {
                cancellable_check (cancellable);
                cal_sizes[ci] = yield calibration_encode (
                    input_file, preferred_codec, cal_crfs[ci], positions,
                    encode_duration, sample_segment_duration, vf, cancellable, preset_idx,
                    calibration_pix_fmt);
            }
        } catch (IOError.CANCELLED e) {
            throw e;
        } catch (Error e) {
            warning ("Calibration encode failed: %s", e.message);
            return make_error_rec (preferred_codec,
                "Test encode failed — is ffmpeg installed?\n%s".printf (e.message));
        }

        bool any_invalid = false;
        for (int ci = 0; ci < cal_sizes.length; ci++) {
            if (cal_sizes[ci] <= 0) any_invalid = true;
        }
        if (any_invalid) {
            for (int ci = 0; ci < cal_sizes.length; ci++) {
                if (cal_sizes[ci] <= 0) {
                    warning ("Nonsensical calibration: CRF %d → %.0fKiB",
                        cal_crfs[ci], cal_sizes[ci]);
                    break;
                }
            }
            return make_error_rec (preferred_codec,
                "Calibration produced invalid results. File may be corrupt.");
        }

        // Warn if sizes aren't monotonically decreasing (unusual but the
        // least-squares fit handles it — just means unusual content variance)
        for (int ci = 0; ci < cal_sizes.length - 1; ci++) {
            if (cal_sizes[ci] <= cal_sizes[ci + 1]) {
                warning ("Non-monotonic calibration: CRF %d→%.0fKiB, %d→%.0fKiB — "
                    + "proceeding with least-squares fit",
                    cal_crfs[ci], cal_sizes[ci], cal_crfs[ci + 1], cal_sizes[ci + 1]);
                break;
            }
        }

        // ── 6b. Fit CRF↔size curve (least-squares quadratic in log-space) ─
        double qa = 0, qb = 0, qc = 0;  // quadratic coefficients
        bool degenerate = false;
        fit_quadratic_log_curve (cal_crfs, cal_sizes, out qa, out qb, out qc, out degenerate);

        // ── 7. Solve for CRF ───────────────────────────────────────────
        // Calibration was done at the target preset, so the model directly
        // predicts the output size — no preset factor correction needed.
        // Solve: ln(target) = a + b·crf + c·crf²
        //   → c·crf² + b·crf + (a − ln(target)) = 0

        int crf_min, crf_max;
        if (preferred_codec == "vp9") {
            crf_min = 12; crf_max = 55;
        } else if (preferred_codec == "svt-av1") {
            crf_min = 10; crf_max = 55;
        } else {
            // x264 and x265 share the same 0–51 range
            crf_min = 8; crf_max = 51;
        }

        double ln_target = Math.log (video_target_kib);
        double cal_mid = (double) (cal_crfs[0] + cal_crfs[cal_crfs.length - 1]) / 2.0;
        double crf_raw = solve_crf_from_curve (
            qa, qb, qc, ln_target, cal_mid, crf_min, crf_max);
        int predicted_crf = ((int) Math.round (crf_raw)).clamp (crf_min, crf_max);
        bool crf_at_max = (predicted_crf >= crf_max);
        bool crf_at_min = (predicted_crf <= crf_min);
        bool adaptive_calibration_refined = false;
        int adaptive_points_added = 0;

        // If the initial 4-point window does not bracket the answer well,
        // add follow-up CRFs around the predicted area and refit.
        int[] extra_crfs = pick_adaptive_calibration_crfs (
            predicted_crf, cal_crfs, crf_min, crf_max,
            ADAPTIVE_CALIBRATION_BASE_MAX_POINTS);
        if (extra_crfs.length > 0) {
            try {
                for (int ci = 0; ci < extra_crfs.length; ci++) {
                    try {
                        cancellable_check (cancellable);
                        double extra_size = yield calibration_encode (
                            input_file, preferred_codec, extra_crfs[ci], positions,
                            encode_duration, sample_segment_duration, vf, cancellable, preset_idx,
                            calibration_pix_fmt);
                        if (extra_size <= 0) {
                            warning ("Adaptive calibration produced invalid result: CRF %d → %.0fKiB",
                                extra_crfs[ci], extra_size);
                            continue;
                        }
                        append_calibration_sample (
                            ref cal_crfs, ref cal_sizes, extra_crfs[ci], extra_size);
                        adaptive_points_added++;
                    } catch (IOError.CANCELLED e) {
                        throw e;
                    } catch (Error e) {
                        warning ("Adaptive calibration encode failed at CRF %d: %s",
                            extra_crfs[ci], e.message);
                        continue;
                    }
                }
            } catch (IOError.CANCELLED e) {
                throw e;
            }

            if (adaptive_points_added > 0) {
                adaptive_calibration_refined = true;
                for (int ci = 0; ci < cal_sizes.length - 1; ci++) {
                    if (cal_sizes[ci] <= cal_sizes[ci + 1]) {
                        warning ("Non-monotonic adaptive calibration: CRF %d→%.0fKiB, %d→%.0fKiB — "
                            + "proceeding with least-squares fit",
                            cal_crfs[ci], cal_sizes[ci], cal_crfs[ci + 1], cal_sizes[ci + 1]);
                        break;
                    }
                }

                fit_quadratic_log_curve (cal_crfs, cal_sizes, out qa, out qb, out qc, out degenerate);
                cal_mid = (double) (cal_crfs[0] + cal_crfs[cal_crfs.length - 1]) / 2.0;
                crf_raw = solve_crf_from_curve (
                    qa, qb, qc, ln_target, cal_mid, crf_min, crf_max);
                predicted_crf = ((int) Math.round (crf_raw)).clamp (crf_min, crf_max);
                crf_at_max = (predicted_crf >= crf_max);
                crf_at_min = (predicted_crf <= crf_min);
            }
        }

        // ── 7b. Verification encode ───────────────────────────────────
        // Encode the same sample segments at the solved CRF to check the
        // model's interpolation accuracy.  Since calibration already used
        // the target preset, this is a direct apples-to-apples comparison
        // — no preset factor involved.
        //
        // If the model's prediction is off by >5%, apply the measured
        // error ratio to correct the CRF and estimate.
        bool   verification_done = false;
        int    verified_crf = predicted_crf;
        double verify_model_kib = 0.0;
        double verify_actual_kib = 0.0;
        double model_correction = 1.0;  // ratio: actual / model

        if (!crf_at_max) {
            bool verify_model_valid = try_evaluate_model_size_kib (
                qa, qb, qc, predicted_crf, "verification", out verify_model_kib);

            if (verify_model_valid && verify_model_kib > 0) {
                try {
                    cancellable_check (cancellable);

                    verify_actual_kib = yield calibration_encode (
                        input_file, preferred_codec, predicted_crf, positions,
                        encode_duration, sample_segment_duration, vf, cancellable, preset_idx,
                        calibration_pix_fmt);

                    if (verify_actual_kib > 0) {
                        model_correction = verify_actual_kib / verify_model_kib;
                        verified_crf = predicted_crf;
                        verification_done = true;

                        // If model is off by >5%, re-solve with a corrected target
                        if (Math.fabs (model_correction - 1.0) > 0.05) {
                            // Adjust the target to compensate for the model's bias:
                            // if model underestimates (correction > 1), we need a
                            // smaller model-space target to hit the real target.
                            double corrected_target = video_target_kib / model_correction;
                            double corrected_ln = Math.log (corrected_target);
                            double re_crf_raw = solve_crf_from_curve (
                                qa, qb, qc, corrected_ln, cal_mid, crf_min, crf_max);
                            int re_crf = ((int) Math.round (re_crf_raw)).clamp (crf_min, crf_max);

                            if (re_crf != predicted_crf) {
                                warning ("Smart Optimizer: verification shifted CRF %d → %d "
                                    + "(model error: %+.1f%%)",
                                    predicted_crf, re_crf, (model_correction - 1.0) * 100.0);
                                predicted_crf = re_crf;
                                crf_at_max = (predicted_crf >= crf_max);
                                crf_at_min = (predicted_crf <= crf_min);
                            }
                        }
                    }
                } catch (IOError.CANCELLED e) {
                    throw e;
                } catch (Error e) {
                    warning ("Verification encode failed, using model estimate: %s", e.message);
                }
            }
        }

        // ── 7c. Audio measurement (strict tiers, re-encode only) ────────
        // For TINY/SMALL targets, the audio budget is a large fraction of
        // the total.  When re-encoding audio, measure the actual output
        // bitrate from a quick audio-only encode so the video budget and
        // size estimate use a real number instead of the tier guess.
        int    measured_audio_kbps = 0;
        bool   audio_measured = false;
        if (tier_uses_strict_targeting (tier)
                && !use_stream_copy_audio
                && !ctx.strip_audio
                && ctx.audio_bitrate_kbps_override <= 0
                && info.audio_bitrate_kbps > 0
                && probed_audio_codec.length > 0) {
            try {
                cancellable_check (cancellable);
                measured_audio_kbps = yield measure_audio_bitrate (
                    input_file, resolved_container, positions[0],
                    sample_segment_duration, tier_audio, cancellable);
                if (measured_audio_kbps > 0) {
                    // Sanity check: measured bitrate should not exceed
                    // 2× the tier budget (encoder overhead, container
                    // framing).  If it does, the measurement is suspect.
                    if (measured_audio_kbps <= tier_audio * 2) {
                        double new_audio_kib = kib_from_kbps_for_duration (
                            (double) measured_audio_kbps, encode_duration);
                        double new_video_kib = target_total_kib - new_audio_kib - container_overhead_kib;
                        if (new_video_kib > 0) {
                            audio_measured = true;
                            info.audio_bitrate_kbps = measured_audio_kbps;
                            audio_kib = new_audio_kib;
                            video_target_kib = new_video_kib;
                            available_video_kbps = (int) kbps_from_kib_for_duration (
                                video_target_kib, encode_duration);
                        }
                    } else {
                        warning ("Smart Optimizer: measured audio %d kbps exceeds "
                            + "2× tier budget %d kbps — ignoring measurement",
                            measured_audio_kbps, tier_audio);
                    }
                }
            } catch (IOError.CANCELLED e) {
                throw e;
            } catch (Error e) {
                warning ("Audio measurement failed, using tier budget: %s", e.message);
            }
        }

        // ── 8. Estimate final size ──────────────────────────────────────
        double raw_estimate_kib;
        if (!try_evaluate_model_size_kib (
                qa, qb, qc, predicted_crf, "final estimate", out raw_estimate_kib)) {
            return make_error_rec (preferred_codec,
                "Smart Optimizer's size model became numerically unstable for this file.\n"
                + "Try two-pass mode, a different target size, or trimming the input.");
        }

        // Apply model correction from verification if available.
        // If CRF didn't shift, this effectively uses the verified size.
        // If CRF shifted, it applies the measured error ratio to the new
        // model prediction — a reasonable first-order correction.
        double estimated_video_kib_double = raw_estimate_kib
            * (verification_done ? model_correction : 1.0);
        double estimated_total_kib_double = estimated_video_kib_double + audio_kib + container_overhead_kib;
        int estimated_video_kib = 0;
        int estimated_total_kib = 0;
        if (!try_cast_nonnegative_int (
                estimated_video_kib_double, "estimated video size", out estimated_video_kib)
            || !try_cast_nonnegative_int (
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

        // ── 9. Confidence ──────────────────────────────────────────────
        // Calibration is most accurate within [cal_first, cal_last] where
        // the quadratic interpolates rather than extrapolates. Outside that
        // range, confidence degrades proportionally to distance.
        double confidence = 1.0;
        int cal_first = cal_crfs[0];
        int cal_last = cal_crfs[cal_crfs.length - 1];
        int cal_range = cal_last - cal_first;
        if (predicted_crf < cal_first - cal_range || predicted_crf > cal_last + cal_range) {
            confidence = 0.5;   // far extrapolation (> one full range outside)
            warning ("Smart Optimizer: CRF %d is far outside calibration range [%d, %d] (%d points) — "
                + "prediction reliability is low",
                predicted_crf, cal_first, cal_last, cal_crfs.length);
        } else if (predicted_crf < cal_first - 2 || predicted_crf > cal_last + 2) {
            confidence = 0.75;  // moderate extrapolation
            warning ("Smart Optimizer: CRF %d is outside calibration range [%d, %d] (%d points) — "
                + "prediction may be inaccurate",
                predicted_crf, cal_first, cal_last, cal_crfs.length);
        } else if (predicted_crf < cal_first || predicted_crf > cal_last) {
            confidence = 0.9;   // slight extrapolation (just outside range)
        }
        // Within [cal_first, cal_last]: confidence stays at 1.0 — the quadratic
        // model is interpolating between measured points, not extrapolating.

        // ── 9b. Sample coverage factor ─────────────────────────────────
        // When the sampled duration is a small fraction of the total, the
        // linear extrapolation (sample_kib × scale) becomes less reliable.
        // Scale confidence proportionally so that thin coverage pushes
        // MEDIUM+ tiers toward two-pass instead of trusting the CRF
        // estimate blindly.
        //
        // Coverage ≥ 30%: no penalty (enough content sampled)
        // Coverage 10–30%: linear ramp from 0.65 to 1.0
        // Coverage < 10%: floor at 0.65
        //
        // Examples:
        //   12% → confidence *= 0.69
        //   17% → confidence *= 0.77
        //   20% → confidence *= 0.83
        //   25% → confidence *= 0.91
        //   30% → confidence *= 1.0   (no penalty)
        double sample_duration = double.min (
            (double) positions.length * sample_segment_duration, encode_duration);
        double sample_coverage = sample_duration / encode_duration;
        if (sample_coverage < 0.30) {
            // Linear ramp: 0.65 at ≤10% → 1.0 at 30%
            double coverage_factor = (0.65 + 0.35 * ((sample_coverage - 0.10) / 0.20))
                .clamp (0.65, 1.0);
            confidence *= coverage_factor;
            if (sample_coverage < 0.15) {
                warning ("Smart Optimizer: sample covers only %.1f%% of video duration — "
                    + "size estimate may be less accurate (confidence factor: %.2f)",
                    sample_coverage * 100.0, coverage_factor);
            }
        }

        // ── 9c. Source bitrate sanity check ─────────────────────────
        // Compare the estimated output size against the source file size.
        // If the CRF model predicts a LARGER output while the user wants a
        // SMALLER file, the prediction is unreliable — reduce confidence
        // so the tier logic is more likely to trigger two-pass.
        //
        // We compare total sizes (not video-only) for simplicity — the
        // probed audio bitrate is available (probed_audio_kbps) but
        // total-size comparison avoids needing to decompose the source.
        int source_video_kbps = 0;
        double source_total_kbps = 0.0;
        if (info.file_size_bytes > 0 && info.duration > 0) {
            source_total_kbps = kbps_from_bytes_for_duration (
                info.file_size_bytes, info.duration);
        }
        if (!trim_active && source_total_kbps > 0 && encode_duration > 0) {
            // Rough source video kbps — subtract a conservative audio estimate.
            // 128 kbps covers most common audio codecs without over-subtracting.
            source_video_kbps = int.max (0, (int) source_total_kbps - 128);

            // If the CRF estimate exceeds the source's size while the user
            // asked for a smaller target, the model's prediction is suspect.
            if (source_video_kbps > 0 && available_video_kbps < source_video_kbps) {
                int estimated_output_kbps = (int) kbps_from_kib_for_duration (
                    (double) estimated_total_kib, encode_duration);
                int source_total_kbps_int = (int) source_total_kbps;
                if (estimated_output_kbps > source_total_kbps_int) {
                    confidence *= 0.6;
                    warning ("Smart Optimizer: CRF estimate (%d kbps) exceeds source (%d kbps) "
                        + "— prediction is unreliable",
                        estimated_output_kbps, source_total_kbps_int);
                }
            }
        }

        // ── 9d. Codec-specific confidence adjustment ─────────────────
        // x265's psychovisual rate-distortion optimization (psy-rd)
        // aggressively allocates extra bits to visually complex regions.
        // This makes CRF output inherently less predictable than other
        // codecs: the same CRF produces wildly different bitrates across
        // scenes depending on texture complexity.  Calibration samples
        // capture average complexity but cannot anticipate how psy-rd
        // will inflate specific unsampled scenes.
        //
        // Empirically, x265 CRF encodes overshoot sample-based estimates
        // by 20–40% on variable-content videos, while SVT-AV1, x264,
        // and VP9 land within 5–10% on the same content.
        //
        // A targeted confidence penalty nudges x265 toward two-pass
        // (which gives the rate controller a global complexity map)
        // without affecting codecs that don't need it.
        if (preferred_codec == "x265") {
            confidence *= 0.85;
        }

        // ── 10. Tier-aware two-pass recommendation ────────────────────
        // For strict tiers (TINY/SMALL), shave 3% off the video bitrate
        // to absorb encoder overshoot, audio bitrate variance, and
        // container overhead inaccuracy.  This small headroom is far
        // cheaper than overshooting a hard size ceiling.
        int target_video_kbps = available_video_kbps;
        if (tier_uses_strict_targeting (tier)) {
            target_video_kbps = (int) (target_video_kbps * 0.97);
        }
        bool recommend_two_pass;

        // Track whether the requested output is meaningfully smaller than the
        // source. This feeds user-facing notes and reduction messaging.
        // TINY/SMALL still force two-pass via strict_targeting below; for
        // MEDIUM+ a reduction target alone does not override a confident CRF
        // estimate that lands inside the tier's target band.
        double source_size_mb = mib_from_bytes (info.file_size_bytes);
        double comparison_source_size_mb = source_size_mb;
        double reduction_confidence = 1.0;
        if (trim_active && source_total_kbps > 0) {
            comparison_source_size_mb = mib_from_kbps_for_duration (
                source_total_kbps, encode_duration);
            reduction_confidence = sample_coverage;
            if (profile.temporal_diff_mean > 0) {
                double motion_cv = profile.temporal_diff_stddev / profile.temporal_diff_mean;
                reduction_confidence *= (1.0 - double.min (0.35, motion_cv * 0.20));
            }
            reduction_confidence = reduction_confidence.clamp (0.25, 1.0);
        }
        double reduction_threshold = trim_active
            ? (0.85 + 0.10 * reduction_confidence)
            : 0.98;
        bool target_is_size_reduction = (comparison_source_size_mb > 0)
            && ((double) target_mb < comparison_source_size_mb * reduction_threshold);

        bool strict_targeting = tier_uses_strict_targeting (tier);
        double target_tolerance_kib = strict_targeting
            ? target_total_kib * 0.05
            : tier_target_tolerance_kib (tier, target_total_kib);
        bool within_target_band = Math.fabs (estimated_total_kib - target_total_kib) <= target_tolerance_kib;

        // For TINY/SMALL, even modest overshoot is unacceptable.
        // For MEDIUM+, treat the target as a symmetric landing zone around
        // the requested size, with some leniency above or below target.
        bool crf_overshoots = estimated_total_kib > (target_total_kib + target_tolerance_kib);

        if (strict_targeting) {
            // TINY and SMALL always prefer strict size targeting.
            recommend_two_pass = true;
        } else {
            switch (tier) {
                case SizeTier.MEDIUM:
                    recommend_two_pass = (confidence < 0.85);
                    break;
                case SizeTier.LARGE:
                    recommend_two_pass = (confidence < 0.70);
                    break;
                case SizeTier.XLARGE:
                    recommend_two_pass = (confidence < 0.60);
                    break;
                default:
                    recommend_two_pass = true;
                    break;
            }

            // For MEDIUM+, allow CRF only when the estimate is both
            // confident enough for the tier and lands inside the symmetric
            // target band around the requested size. Reduction targets still
            // go through this same gate unless the tier is strict.
            if (!recommend_two_pass) {
                if (crf_overshoots) {
                    recommend_two_pass = true;
                } else if (!within_target_band) {
                    recommend_two_pass = true;
                }
            }
        }

        // ── 11. Feasibility flags ───────────────────────────────────────
        bool is_impossible = crf_at_max && (estimated_total_kib > target_total_kib * 1.1);

        // Force two-pass when CRF alone cannot comfortably hit the target,
        // including cases where even max CRF still looks too large.
        if (crf_at_max) {
            recommend_two_pass = true;
        }

        // ── 12. Build the recommendation ────────────────────────────────
        string preset_label = format_preset_label (preferred_codec, preset_idx);

        var notes = new StringBuilder ();

        // --- Tier ---
        notes.append ("── Strategy: %s ──\n".printf (tier.to_label ()));
        notes.append ("  Audio budget: %d kbps%s\n".printf (
            info.audio_bitrate_kbps,
            use_stream_copy_audio ? " (stream copy)" :
            audio_measured ? " (measured)" : ""));

        // --- Content ---
        notes.append ("\n── Content ──\n");
        notes.append ("  %s".printf (profile.content_type.to_label ()));
        if (profile.type_confidence > 0)
            notes.append (" (confidence: %s)".printf (
                "%.0f%%".printf (profile.type_confidence * 100)));
        notes.append ("\n");
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
        if (info.audio_bitrate_kbps > 0) {
            if (use_stream_copy_audio) {
                notes.append ("  Audio: stream copy (%s @ %d kbps) → %d KiB exact\n"
                    .printf (probed_audio_codec, probed_audio_kbps, (int) audio_kib));
            } else if (audio_measured) {
                notes.append ("  Audio: %d kbps (measured, tier budget %d kbps) → %d KiB reserved\n"
                    .printf (measured_audio_kbps, tier_audio, (int) audio_kib));
            } else {
                notes.append ("  Audio: ~%d kbps".printf (info.audio_bitrate_kbps));
                if (info.audio_bitrate_estimated)
                    notes.append (" (estimated %s — stream did not report bitrate)".printf (
                        info.audio_codec));
                notes.append (" → %d KiB reserved\n".printf ((int) audio_kib));
            }
        }

        // --- CRF mode ---
        notes.append ("\n── CRF mode (quality-focused) ──\n");
        notes.append ("  CRF %d / Preset: %s\n".printf (predicted_crf, preset_label));

        if (crf_at_max && !is_impossible) {
            notes.append ("  ⚠️  CRF mode is at maximum compression — quality will be poor.\n");
            notes.append ("  ✅  Two-pass mode below is the recommended path.\n");
        } else if (crf_at_min && recommend_two_pass) {
            notes.append ("  CRF floor reached — even maximum quality only produces ~%d KiB.\n"
                .printf (estimated_total_kib));
            notes.append ("  Two-pass VBR below will allocate the full bitrate budget.\n");
        } else if (!is_impossible) {
            notes.append ("  Estimated: ~%d KiB".printf (estimated_total_kib));
            if (confidence < 0.8)
                notes.append (" (extrapolated — confidence %s)"
                    .printf ("%.0f%%".printf (confidence * 100)));
            notes.append ("\n");
        }

        // --- Two-pass mode ---
        if (recommend_two_pass) {
            notes.append ("\n── Two-pass mode (size-targeted) ──\n");
            notes.append ("  Target bitrate: %d kbps / Preset: %s\n"
                .printf (target_video_kbps, preset_label));
            if (target_is_size_reduction) {
                if (!strict_targeting && !within_target_band) {
                    notes.append ("  CRF estimate (~%d KiB) falls outside the ±%.0f MB target band for this tier.\n"
                        .printf (estimated_total_kib, target_tolerance_kib / 1024.0));
                } else if (trim_active && comparison_source_size_mb > 0) {
                    notes.append ("  Trimmed source window is ~%.0f MB (estimated) → target %d MB requires size reduction.\n"
                        .printf (comparison_source_size_mb, target_mb));
                    if (reduction_confidence < 0.95) {
                        notes.append ("  Reduction estimate confidence: %.0f%% (trim-window bitrate inferred from sampled content)\n"
                            .printf (reduction_confidence * 100.0));
                    }
                } else {
                    notes.append ("  Source is ~%.0f MB → target %d MB requires size reduction.\n"
                        .printf (source_size_mb, target_mb));
                }
            } else if (crf_at_min) {
                notes.append ("  CRF mode tops out at ~%d KiB (CRF %d) — maximum quality can't fill the %d MB target.\n"
                    .printf (estimated_total_kib, predicted_crf, target_mb));
                notes.append ("  Two-pass VBR allocates the full bitrate budget to get closer to the requested size.\n");
            } else if (crf_overshoots) {
                if (strict_targeting) {
                    notes.append ("  CRF estimate (~%d KiB) exceeds target (~%.0f KiB).\n"
                        .printf (estimated_total_kib, target_total_kib));
                } else {
                    notes.append ("  CRF estimate (~%d KiB) exceeds the ±%.0f MB target band.\n"
                        .printf (estimated_total_kib, target_tolerance_kib / 1024.0));
                }
            } else if (!strict_targeting && !within_target_band) {
                notes.append ("  CRF estimate (~%d KiB) falls outside the ±%.0f MB target band for this tier.\n"
                    .printf (estimated_total_kib, target_tolerance_kib / 1024.0));
            } else if (confidence < 1.0) {
                notes.append ("  Prediction confidence is %.0f%% — two-pass ensures accuracy.\n"
                    .printf (confidence * 100.0));
            }
            notes.append ("  This mode targets the requested size more directly.\n");
            notes.append ("  Final size can still land above or below target depending on codec, audio, and container behavior.\n");
            notes.append ("  Quality is determined by available bitrate, not CRF.\n");
        } else {
            notes.append ("\n── Two-pass: skipped ──\n");
            if (within_target_band) {
                notes.append ("  CRF confidence is high (%.0f%%) and estimate is within the ±%.0f MB target band.\n"
                    .printf (confidence * 100.0, target_tolerance_kib / 1024.0));
            } else {
                notes.append ("  CRF confidence is high (%.0f%%), but the estimate is outside the target band.\n"
                    .printf (confidence * 100.0));
            }
        }

        // --- Warnings ---
        if (is_impossible) {
            notes.append ("\n⚠️  Even maximum compression will likely exceed the %d MB target.\n"
                .printf (target_mb));
            notes.append ("    Two-pass can push the file closer to the target, but expect severe quality loss.\n");
            notes.append ("    Consider trimming, scaling down, or raising the target.\n");
        } else if (target_video_kbps < 200) {
            notes.append ("\n⚠️  Very low available bitrate (%d kbps) — ".printf (target_video_kbps));
            notes.append ("expect visible quality loss.\n");
        }

        // --- Sample coverage ---
        if (sample_coverage < 0.30) {
            notes.append ("\nℹ️  %.0f%% of the video was sampled for calibration"
                .printf (sample_coverage * 100.0));
            if (sample_coverage < 0.15) {
                notes.append (" (low coverage — estimate may be less accurate).\n");
            } else {
                notes.append (".\n");
            }
        }

        // --- Calibration data ---
        notes.append ("\n── Calibration data (%d-point least-squares quadratic) ──\n"
            .printf (cal_crfs.length));
        for (int ci = 0; ci < cal_crfs.length; ci++) {
            notes.append ("  CRF %d → %.0f KiB (full-length estimate)\n"
                .printf (cal_crfs[ci], cal_sizes[ci]));
        }
        notes.append ("  Model: ln(size) = %.4f + %.4f·CRF + %.6f·CRF²\n"
            .printf (qa, qb, qc));
        if (adaptive_calibration_refined) {
            notes.append ("  Adaptive refinement: +%d follow-up point%s around the solved CRF path\n"
                .printf (adaptive_points_added, adaptive_points_added == 1 ? "" : "s"));
        }
        notes.append ("  Calibrated at preset: %s\n".printf (preset_label));
        if (preferred_codec == "x265") {
            notes.append ("  x265 psy-rd penalty: confidence × 0.85 (psy-rd inflates complex scenes unpredictably)\n");
        }
        if (verification_done) {
            notes.append ("  Verification: model predicted %.0f KiB at CRF %d, measured %.0f KiB (error: %+.1f%%)\n"
                .printf (verify_model_kib, verified_crf, verify_actual_kib,
                         (model_correction - 1.0) * 100.0));
            if (predicted_crf != verified_crf) {
                notes.append ("  CRF adjusted %d → %d to compensate for model error\n"
                    .printf (verified_crf, predicted_crf));
            }
        }
        notes.append ("  Container overhead: %.0f KiB reserved\n"
            .printf (container_overhead_kib));
        if (source_video_kbps > 0) {
            notes.append ("  Source: ~%.0f MB, ~%d kbps (est. video) | Target: %d kbps video\n"
                .printf (source_size_mb, source_video_kbps, target_video_kbps));
        } else if (trim_active && comparison_source_size_mb > 0) {
            notes.append ("  Trim window: %.1fs→%.1fs | Source window estimate: ~%.0f MB\n"
                .printf (trim_start, trim_end, comparison_source_size_mb));
        }
        if (tier == SizeTier.TINY) {
            notes.append ("  Metadata stripped to save space (tiny target)\n");
        }
        notes.append ("  Sample coverage: %.0f%% (%d × %.2fs segments%s)\n"
            .printf (sample_coverage * 100.0, positions.length, sample_segment_duration,
                     adaptive_expanded ? ", adaptively expanded" : ""));
        if (sample_segment_duration != (double) SEGMENT_DURATION) {
            notes.append ("  Sample segments shortened to %.2fs to stay within the trim window\n"
                .printf (sample_segment_duration));
        }
        if (trim_active) {
            notes.append ("  Trimmed duration: %.1fs (window %.1fs→%.1fs, full: %.1fs)\n"
                .printf (encode_duration, trim_start, trim_end, info.duration));
        } else if (ctx.effective_duration > 0 && ctx.effective_duration != info.duration) {
            notes.append ("  Trimmed duration: %.1fs (full: %.1fs)\n"
                .printf (encode_duration, info.duration));
        }
        if (vf.length > 0) {
            notes.append ("  Video filters applied to calibration: yes\n");
        }

        return OptimizationRecommendation () {
            codec                 = preferred_codec,
            crf                   = predicted_crf,
            preset                = preset_label,
            two_pass              = recommend_two_pass,
            target_bitrate_kbps   = target_video_kbps,
            estimated_size_kib    = estimated_total_kib,
            notes                 = notes.str,
            is_impossible         = is_impossible,
            content_type          = profile.content_type,
            confidence            = confidence,
            size_tier             = tier,
            recommended_audio_kbps = info.audio_bitrate_kbps,
            stream_copy_audio     = use_stream_copy_audio,
            strip_metadata        = (tier == SizeTier.TINY),
            recommended_pix_fmt   = bit_depth.pix_fmt,
            resolved_container    = resolved_container,
            target_size_kib       = (int) target_total_kib
        };
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
        sb.append ("Content:        %s\n".printf (rec.content_type.to_label ()));
        sb.append ("Confidence:     %s\n".printf ("%.0f%%".printf (rec.confidence * 100)));
        sb.append ("Size tier:      %s\n".printf (rec.size_tier.to_label ()));
        sb.append ("Audio budget:   %d kbps\n".printf (rec.recommended_audio_kbps));
        if (rec.recommended_pix_fmt != null && rec.recommended_pix_fmt.length > 0)
            sb.append ("Pixel format:   %s\n".printf (rec.recommended_pix_fmt));
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
            file_size_bytes         = source_size_bytes,
            source_bit_depth        = 0,
            color_transfer          = "",
            color_primaries         = ""
        };

        Json.Array? streams = root.has_member ("streams")
            ? root.get_array_member ("streams")
            : null;
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
                        string stream_dur = s.get_string_member_with_default ("duration", "0");
                        double parsed_stream_dur = 0.0;
                        if (try_parse_double (stream_dur, out parsed_stream_dur) && parsed_stream_dur > 0) {
                            info.duration = parsed_stream_dur;
                        }
                    }
                }

                if (ctype == "audio") {
                    var bstr = s.get_string_member_with_default ("bit_rate", "0");
                    double parsed_audio_bps = 0.0;
                    if (try_parse_double (bstr, out parsed_audio_bps) && parsed_audio_bps > 0) {
                        info.audio_bitrate_kbps = (int) (parsed_audio_bps / 1000.0);
                    }
                    info.audio_codec = s.get_string_member_with_default ("codec_name", "");

                    // ── Duration fallback: audio stream level ────────────
                    if (info.duration <= 0) {
                        string stream_dur = s.get_string_member_with_default ("duration", "0");
                        double parsed_stream_dur = 0.0;
                        if (try_parse_double (stream_dur, out parsed_stream_dur) && parsed_stream_dur > 0) {
                            info.duration = parsed_stream_dur;
                        }
                    }
                }
            }
        }

        // ── Duration fallback: separate ffprobe call (most reliable) ─────
        // FfprobeUtils.probe_duration uses format=duration via CSV output,
        // which sometimes succeeds when JSON parsing doesn't (e.g. when
        // the JSON field contains "N/A" or is absent).
        if (info.duration <= 0) {
            info.duration = FfprobeUtils.probe_duration (path);
        }

        // If the audio stream didn't report a bitrate, fall back to a
        // codec-aware default. Opus is efficient at lower bitrates than
        // AAC/Vorbis, so over-estimating eats into the video budget.
        if (info.audio_bitrate_kbps == 0) {
            info.audio_bitrate_estimated = true;
            switch (info.audio_codec) {
                case "opus":
                    info.audio_bitrate_kbps = 96;
                    break;
                case "vorbis":
                    info.audio_bitrate_kbps = 112;
                    break;
                default:
                    // AAC, MP3, or unknown — conservative estimate
                    info.audio_bitrate_kbps = 128;
                    break;
            }
        }

        return info;
    }

    // ════════════════════════════════════════════════════════════════════════
    // SAMPLE POSITION SELECTION
    // ════════════════════════════════════════════════════════════════════════

    private double[] pick_sample_positions (double duration, double segment_duration) {
        if (duration <= segment_duration * 2.0) {
            return { 0 };
        }

        // Compute coverage-based minimum: enough segments to hit the
        // minimum coverage target (e.g. 15%).  This ensures medium-length
        // videos like a 5-minute clip get 6 segments instead of 4,
        // reducing the chance that fixed-position samples miss complex
        // regions entirely.
        int coverage_segs = (int) Math.ceil (
            duration * MIN_COVERAGE_TARGET / segment_duration);

        // Hard cap by duration tier to bound total calibration encode time
        int max_segs;
        if (duration >= VLONG_VIDEO_THRESHOLD) {
            max_segs = VLONG_MAX_SEGMENTS;
        } else if (duration >= LONG_VIDEO_THRESHOLD) {
            max_segs = LONG_MAX_SEGMENTS;
        } else {
            max_segs = BASE_MAX_SEGMENTS;
        }

        // Take the coverage-based count but respect both the tier cap
        // and how many segments physically fit in the duration
        int n = int.min (coverage_segs, max_segs);
        n = int.min (n, (int) (duration / segment_duration));
        n = int.max (n, MIN_SEGMENTS);

        return spread_positions (duration, n, segment_duration);
    }

    private double[] pick_sample_positions_in_window (
        double start,
        double duration,
        double segment_duration
    ) {
        return offset_positions (pick_sample_positions (duration, segment_duration), start);
    }

    /**
     * Pick exactly @requested positions (clamped to what fits in the duration).
     * Used by adaptive expansion when content variability warrants more samples.
     */
    private double[] pick_sample_positions_n (double duration, double segment_duration, int requested) {
        if (duration <= segment_duration * 2.0) {
            return { 0 };
        }
        int n = int.min (requested, (int) (duration / segment_duration));
        n = int.max (n, 2);

        return spread_positions (duration, n, segment_duration);
    }

    private double[] pick_sample_positions_n_in_window (
        double start,
        double duration,
        double segment_duration,
        int    requested
    ) {
        return offset_positions (
            pick_sample_positions_n (duration, segment_duration, requested), start);
    }

    private double[] spread_positions (double duration, int n, double segment_duration) {
        double usable = duration - segment_duration;
        double start  = usable * SEGMENT_SPREAD;
        double end    = usable * (1.0 - SEGMENT_SPREAD);
        double step   = (n > 1) ? (end - start) / (n - 1) : 0;

        var positions = new double[n];
        for (int i = 0; i < n; i++) {
            positions[i] = start + step * i;
        }
        return positions;
    }

    private double[] offset_positions (double[] positions, double start) {
        var shifted = new double[positions.length];
        for (int i = 0; i < positions.length; i++) {
            shifted[i] = positions[i] + start;
        }
        return shifted;
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
        string[] sig_cmd = build_concat_analysis_cmd (
            path, positions, segment_duration,
            "signalstats=stat=tout+vrep+brng",
            video_filter_chain
        );
        string sig_output = yield run_subprocess_stderr (sig_cmd, cancellable);
        double[] all_satavg = {};
        double[] all_ydif   = {};
        double[] all_ylow   = {};
        double[] all_yavg   = {};
        parse_signalstats (sig_output, ref all_satavg, ref all_ydif,
            ref all_ylow, ref all_yavg);

        // ── Edge detection ──────────────────────────────────────────────
        string[] edge_cmd = build_concat_analysis_cmd (
            path, positions, segment_duration,
            "edgedetect=low=0.08:high=0.25,signalstats",
            video_filter_chain
        );
        string edge_output = yield run_subprocess_stderr (edge_cmd, cancellable);
        double[] all_edge = {};
        parse_signalstats_field (edge_output, "YAVG", ref all_edge);

        // ── Compute stats ───────────────────────────────────────────────
        var profile = ContentProfile ();
        compute_stats (all_edge,   out profile.edge_mean,           out profile.edge_stddev);
        compute_stats (all_satavg, out profile.saturation_mean,     out profile.saturation_stddev);
        compute_stats (all_ydif,   out profile.temporal_diff_mean,  out profile.temporal_diff_stddev);

        // ── Banding / dark-scene metrics ────────────────────────────────
        // Dark scene ratio: fraction of frames where avg luma < 60 (of 235 range)
        if (all_yavg.length > 0) {
            int dark_count = 0;
            for (int i = 0; i < all_yavg.length; i++) {
                if (all_yavg[i] < 60.0) dark_count++;
            }
            profile.dark_scene_ratio = (double) dark_count / all_yavg.length;
        }

        // Low luma ratio: fraction of frames with significant dark pixel area.
        // YLOW counts pixels with luma ≤ 16 — normalize by resolution to make
        // the threshold resolution-adaptive.
        if (all_ylow.length > 0) {
            double resolution_scale = (info.width > 0 && info.height > 0)
                ? (double) (info.width * info.height) / 100000.0
                : 1.0;
            int ylow_count = 0;
            for (int i = 0; i < all_ylow.length; i++) {
                double normalized = all_ylow[i] / resolution_scale;
                if (normalized > 5000.0) ylow_count++;
            }
            profile.low_luma_ratio = (double) ylow_count / all_ylow.length;
        }

        // Composite banding risk: weighted combination of dark/luma/smoothness
        double dark_factor = profile.dark_scene_ratio;
        double ylow_factor = profile.low_luma_ratio;
        double smooth_factor = (1.0 - (profile.saturation_stddev / 40.0)).clamp (0.0, 1.0);
        profile.banding_risk = (dark_factor * 0.35 + ylow_factor * 0.30 + smooth_factor * 0.35)
            .clamp (0.0, 1.0);

        classify_content (ref profile);
        return profile;
    }

    // ════════════════════════════════════════════════════════════════════════
    // BIT DEPTH DECISION ENGINE
    // ════════════════════════════════════════════════════════════════════════

    private struct BitDepthDecision {
        public string pix_fmt;    // "yuv420p10le", "yuv420p", or ""
        public bool   is_10bit;
        public string reason;     // for notes
    }

    private BitDepthDecision decide_bit_depth (
        SmartOptimizerVideoInfo info,
        ContentProfile profile,
        SizeTier tier,
        string codec,
        bool tone_mapping_active
    ) {
        bool is_hdr = (info.color_transfer == "smpte2084"
                    || info.color_transfer == "arib-std-b67");
        bool is_wide_gamut = (info.color_primaries == "bt2020");

        // Rule 1: x264 has limited 10-bit support — hard constraint
        // checked before HDR so we don't recommend 10-bit to a codec
        // that can't handle it reliably.
        if (codec == "x264") {
            string reason = (is_hdr || is_wide_gamut) && !tone_mapping_active
                ? "x264 has limited 10-bit support; staying 8-bit (consider enabling tone mapping or switching codec for HDR/wide-gamut content)"
                : "x264 has limited 10-bit support; staying 8-bit";
            return BitDepthDecision () {
                pix_fmt  = PixelFormat.YUV420P,
                is_10bit = false,
                reason   = reason
            };
        }

        // Rule 2: HDR content without tone mapping → must stay 10-bit
        if (is_hdr && !tone_mapping_active) {
            return BitDepthDecision () {
                pix_fmt  = PixelFormat.YUV420P10LE,
                is_10bit = true,
                reason   = "HDR content requires 10-bit to preserve dynamic range"
            };
        }

        // Rule 3: HDR content with tone mapping → 8-bit sufficient
        // Explicit rule so HDR sources with unknown bit depth don't
        // fall through to banding heuristics.
        if (is_hdr && tone_mapping_active) {
            return BitDepthDecision () {
                pix_fmt  = PixelFormat.YUV420P,
                is_10bit = false,
                reason   = "HDR tone-mapped to SDR; 8-bit sufficient"
            };
        }

        // Rule 4: Source ≥ 10-bit without tone mapping → preserve depth
        if (info.source_bit_depth >= 10 && !tone_mapping_active) {
            return BitDepthDecision () {
                pix_fmt  = PixelFormat.YUV420P10LE,
                is_10bit = true,
                reason   = "Source is %d-bit; preserving depth to avoid quantization".printf (
                    info.source_bit_depth)
            };
        }

        // Rule 5: Source ≥ 10-bit with tone mapping → 8-bit sufficient
        if (info.source_bit_depth >= 10 && tone_mapping_active) {
            return BitDepthDecision () {
                pix_fmt  = PixelFormat.YUV420P,
                is_10bit = false,
                reason   = "Tone mapping to SDR; 8-bit sufficient"
            };
        }

        // Rule 6: Small target with low banding risk → 8-bit for speed
        if (tier <= SizeTier.SMALL && profile.banding_risk < 0.5) {
            return BitDepthDecision () {
                pix_fmt  = PixelFormat.YUV420P,
                is_10bit = false,
                reason   = "8-bit for speed at small target size"
            };
        }

        // Rule 7: Wide color gamut (BT.2020) without tone mapping → 10-bit
        // BT.2020 primaries span a much wider color space than BT.709.
        // 10-bit output preserves color precision across that wider gamut,
        // even when the source bit depth is 8 or unknown.
        // Tone mapping converts to BT.709 so 8-bit is fine in that case.
        if (is_wide_gamut && !tone_mapping_active) {
            return BitDepthDecision () {
                pix_fmt  = PixelFormat.YUV420P10LE,
                is_10bit = true,
                reason   = "BT.2020 wide color gamut — 10-bit preserves color precision"
            };
        }

        // Rule 8: Anime with moderate banding risk → 10-bit
        if (profile.content_type == ContentType.ANIME && profile.banding_risk >= 0.3) {
            return BitDepthDecision () {
                pix_fmt  = PixelFormat.YUV420P10LE,
                is_10bit = true,
                reason   = "Anime with banding risk %.0f%% — 10-bit reduces banding".printf (
                    profile.banding_risk * 100.0)
            };
        }

        // Rule 9: High banding risk for any content → 10-bit
        if (profile.banding_risk >= 0.6) {
            return BitDepthDecision () {
                pix_fmt  = PixelFormat.YUV420P10LE,
                is_10bit = true,
                reason   = "High banding risk (%.0f%%) — 10-bit improves gradients".printf (
                    profile.banding_risk * 100.0)
            };
        }

        // Rule 10: Dark content with banding risk → 10-bit
        if (profile.dark_scene_ratio >= 0.5 && profile.banding_risk >= 0.4) {
            return BitDepthDecision () {
                pix_fmt  = PixelFormat.YUV420P10LE,
                is_10bit = true,
                reason   = "Dark content with banding risk — 10-bit reduces artifacts"
            };
        }

        // Rule 11: Default → 8-bit
        return BitDepthDecision () {
            pix_fmt  = PixelFormat.YUV420P,
            is_10bit = false,
            reason   = "Standard 8-bit — no banding risk detected"
        };
    }

    /**
     * Heuristic content classifier.
     *
     * Anime/animation signals:
     *   - High edge density (sharp ink lines on flat fills)
     *   - Low saturation variance (limited palette)
     *   - Low temporal difference with occasional large jumps (held frames)
     *
     * Screencast signals:
     *   - Very high edge density (text, UI borders)
     *   - Very low temporal difference (mostly static)
     *   - Low saturation (grey UI)
     *
     * Live-action: moderate everything, high saturation variance.
     */
    private void classify_content (ref ContentProfile p) {
        double edge_score   = ((p.edge_mean - 5.0) / 30.0).clamp (0.0, 1.0);
        double sat_score    = (1.0 - ((p.saturation_stddev - 5.0) / 35.0)).clamp (0.0, 1.0);
        double motion_score = (1.0 - ((p.temporal_diff_mean - 1.0) / 15.0)).clamp (0.0, 1.0);

        double screen_score = 0.0;
        if (p.temporal_diff_mean < 2.0 && p.edge_mean > 25.0 && p.saturation_mean < 40.0) {
            screen_score = 0.9;
        } else if (p.temporal_diff_mean < 3.0 && p.edge_mean > 20.0) {
            screen_score = 0.5;
        }

        double anime_score = (edge_score * 0.35 + sat_score * 0.35 + motion_score * 0.30);

        if (screen_score > 0.7) {
            p.content_type    = ContentType.SCREENCAST;
            p.type_confidence = screen_score;
        } else if (anime_score > 0.65) {
            p.content_type    = ContentType.ANIME;
            p.type_confidence = anime_score;
        } else if (anime_score > 0.45 && anime_score < 0.65) {
            p.content_type    = ContentType.MIXED;
            p.type_confidence = 1.0 - Math.fabs (anime_score - 0.55) / 0.10;
        } else {
            p.content_type    = ContentType.LIVE_ACTION;
            p.type_confidence = 1.0 - anime_score;
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // CONTENT-AWARE PRESET SELECTION
    // ════════════════════════════════════════════════════════════════════════

    /**
     * Returns the ideal preset index for fully-confident content classification.
     * The caller scales this toward a safe baseline based on type_confidence.
     */
    private int choose_ideal_preset_index (ContentProfile profile) {
        switch (profile.content_type) {
            case ContentType.ANIME:
                // Flat fills + sharp lines compress enormously better with effort.
                return 7;  // "slower" / cpu-used 1

            case ContentType.SCREENCAST:
                // Nearly static; slower presets give very large size wins.
                return 7;  // "slower" / cpu-used 1

            case ContentType.MIXED:
                return 6;  // "slow" / cpu-used 2

            default:
                // Live-action: diminishing returns past medium/slow.
                return 6;  // "slow" / cpu-used 2
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // SIZE-TIER HELPERS
    // ════════════════════════════════════════════════════════════════════════

    /**
     * Recommended audio bitrate for budget calculation.
     * The codec preset functions will configure actual audio to match.
     */
    private int tier_audio_kbps (SizeTier tier) {
        switch (tier) {
            case SizeTier.TINY:   return 64;
            case SizeTier.SMALL:  return 128;
            case SizeTier.MEDIUM: return 192;
            case SizeTier.LARGE:  return 256;
            case SizeTier.XLARGE: return 320;   // Opus 320 kbps — transparent quality
            default:              return 128;
        }
    }

    /**
     * Check if a source audio codec can be stream-copied into the target container.
     *
     * Container support:
     *   webm  → Opus, Vorbis only
     *   mkv   → virtually all codecs (AAC, MP3, Opus, Vorbis, FLAC, AC3, EAC3, DTS)
     *   mp4   → AAC, MP3, AC3, EAC3
     *   other → fall back to AAC, MP3 (safe baseline)
     */
    private static bool audio_codec_compatible_with_container (string audio_codec, string container) {
        if (audio_codec.length == 0) return false;
        string lc = audio_codec.down ();
        string ct = container.down ();

        if (ct == "webm") {
            return (lc == "opus" || lc == "vorbis");
        }

        if (ct == "mkv" || ct == "matroska") {
            // MKV accepts virtually all audio codecs
            return (lc == "aac" || lc == "mp3" || lc == "opus" || lc == "vorbis"
                 || lc == "flac" || lc == "ac3" || lc == "eac3" || lc == "dts");
        }

        if (ct == "mp4") {
            return (lc == "aac" || lc == "mp3" || lc == "ac3" || lc == "eac3");
        }

        // Unknown container — conservative baseline
        return (lc == "aac" || lc == "mp3");
    }

    /**
     * Safe baseline preset index by tier.
     * Larger targets bias toward faster presets because the marginal
     * quality gain from slower presets diminishes with ample bitrate.
     */
    private int tier_safe_preset_index (SizeTier tier, string codec) {
        // SVT-AV1 uses a different mapping because its preset array was
        // compacted from {13..0} to {9..0} — indices shifted relative to
        // x264/x265/vp9 whose arrays didn't change.
        if (codec == "svt-av1") {
            switch (tier) {
                case SizeTier.TINY:   return 4;   // preset 5
                case SizeTier.SMALL:  return 4;   // preset 5
                case SizeTier.MEDIUM: return 3;   // preset 6
                case SizeTier.LARGE:  return 2;   // preset 7
                case SizeTier.XLARGE: return 1;   // preset 8
                default:              return 4;
            }
        }
        // x264, x265, vp9 — unchanged
        switch (tier) {
            case SizeTier.TINY:   return 5;   // x264 medium / vp9 cpu-used 3
            case SizeTier.SMALL:  return 5;   // x264 medium / vp9 cpu-used 3
            case SizeTier.MEDIUM: return 4;   // x264 fast / vp9 cpu-used 4
            case SizeTier.LARGE:  return 4;   // x264 fast / vp9 cpu-used 4
            case SizeTier.XLARGE: return 3;   // x264 faster / vp9 cpu-used 5
            default:              return 5;
        }
    }

    /**
     * Estimated container overhead (headers, index, seek tables) in KiB.
     * Subtracted from the video budget so the final file actually fits.
     */
    private double container_overhead_for_tier (SizeTier tier) {
        switch (tier) {
            case SizeTier.TINY:   return CONTAINER_OVERHEAD_KIB_TINY;
            case SizeTier.SMALL:  return CONTAINER_OVERHEAD_KIB_SMALL;
            case SizeTier.MEDIUM: return CONTAINER_OVERHEAD_KIB_MEDIUM;
            case SizeTier.LARGE:  return CONTAINER_OVERHEAD_KIB_LARGE;
            case SizeTier.XLARGE: return CONTAINER_OVERHEAD_KIB_XLARGE;
            default:              return CONTAINER_OVERHEAD_KIB_SMALL;
        }
    }

    private double mib_to_kib (double mib) {
        return mib * KIB_PER_MIB;
    }

    private double kib_from_bytes (int64 bytes) {
        return (double) bytes / BYTES_PER_KIB;
    }

    private double mib_from_bytes (int64 bytes) {
        return kib_from_bytes (bytes) / KIB_PER_MIB;
    }

    private double kib_from_kbps_for_duration (double kbps, double duration_seconds) {
        if (duration_seconds <= 0.0)
            return 0.0;
        return kbps * BITS_PER_KILOBIT * duration_seconds / (BITS_PER_BYTE * BYTES_PER_KIB);
    }

    private double mib_from_kbps_for_duration (double kbps, double duration_seconds) {
        return kib_from_kbps_for_duration (kbps, duration_seconds) / KIB_PER_MIB;
    }

    private double kbps_from_kib_for_duration (double kib, double duration_seconds) {
        if (duration_seconds <= 0.0)
            return 0.0;
        return kib * BYTES_PER_KIB * BITS_PER_BYTE / (duration_seconds * BITS_PER_KILOBIT);
    }

    private double kbps_from_bytes_for_duration (int64 bytes, double duration_seconds) {
        if (duration_seconds <= 0.0)
            return 0.0;
        return (double) bytes * BITS_PER_BYTE / (duration_seconds * BITS_PER_KILOBIT);
    }

    private double seconds_for_kib_at_kbps (double kib, int kbps) {
        if (kbps <= 0)
            return 0.0;
        return kib * BYTES_PER_KIB * BITS_PER_BYTE / ((double) kbps * BITS_PER_KILOBIT);
    }

    private bool try_evaluate_model_size_kib (
        double      qa,
        double      qb,
        double      qc,
        int         crf,
        string      context,
        out double  size_kib
    ) {
        size_kib = 0.0;

        double crf_double = (double) crf;
        double exponent = qa + qb * crf_double + qc * crf_double * crf_double;
        if (!exponent.is_finite ()) {
            warning ("Smart Optimizer: %s exponent is not finite at CRF %d", context, crf);
            return false;
        }

        size_kib = Math.exp (exponent);
        if (!size_kib.is_finite () || size_kib <= 0.0) {
            warning ("Smart Optimizer: %s size is invalid at CRF %d (exp=%.6f)",
                context, crf, exponent);
            size_kib = 0.0;
            return false;
        }

        return true;
    }

    private bool try_cast_nonnegative_int (double value, string label, out int cast_value) {
        cast_value = 0;
        if (!value.is_finite () || value < 0.0) {
            warning ("Smart Optimizer: %s is invalid (%.6f)", label, value);
            return false;
        }
        if (value > (double) int.MAX) {
            warning ("Smart Optimizer: %s exceeds int range (%.6f)", label, value);
            return false;
        }

        cast_value = (int) value;
        return true;
    }

    /**
     * Content-type influence on preset selection.
     * At larger sizes, content-specific preset adjustments matter less
     * because the encoder has plenty of bits regardless.
     */
    private double tier_content_influence (SizeTier tier) {
        switch (tier) {
            case SizeTier.TINY:   return 1.0;
            case SizeTier.SMALL:  return 0.85;
            case SizeTier.MEDIUM: return 0.65;
            case SizeTier.LARGE:  return 0.45;
            case SizeTier.XLARGE: return 0.25;
            default:              return 1.0;
        }
    }

    /**
     * Tiny and Small are treated as strict size targets.
     * Medium and above treat the target as an approximate landing zone.
     */
    private bool tier_uses_strict_targeting (SizeTier tier) {
        switch (tier) {
            case SizeTier.TINY:
            case SizeTier.SMALL:
                return true;
            default:
                return false;
        }
    }

    /**
     * Acceptable distance from the requested size for quality-focused tiers.
     * Medium+ should land near the target, not necessarily under it.
     */
    private double tier_target_tolerance_kib (SizeTier tier, double target_total_kib) {
        switch (tier) {
            case SizeTier.MEDIUM:
                return double.max (8.0 * 1024.0, target_total_kib * 0.10);
            case SizeTier.LARGE:
                return double.max (10.0 * 1024.0, target_total_kib * 0.10);
            case SizeTier.XLARGE:
                return double.max (16.0 * 1024.0, target_total_kib * 0.12);
            default:
                return 0.0;
        }
    }

    /**
     * Fit ln(size) = a + b*CRF + c*CRF^2 using least squares over an
     * arbitrary number of calibration points. Falls back to a two-point
     * exponential when the quadratic system is degenerate.
     */
    private void fit_quadratic_log_curve (
        int[]    cal_crfs,
        double[] cal_sizes,
        out double qa,
        out double qb,
        out double qc,
        out bool   degenerate
    ) {
        double sx = 0, sx2 = 0, sx3 = 0, sx4 = 0;
        double sy = 0, sxy = 0, sx2y = 0;
        for (int ci = 0; ci < cal_crfs.length; ci++) {
            double x = (double) cal_crfs[ci];
            double y = Math.log (cal_sizes[ci]);
            double x2 = x * x;
            sx   += x;
            sx2  += x2;
            sx3  += x2 * x;
            sx4  += x2 * x2;
            sy   += y;
            sxy  += x * y;
            sx2y += x2 * y;
        }
        double n_pts = (double) cal_crfs.length;

        qa = 0;
        qb = 0;
        qc = 0;
        degenerate = false;

        double[,] m = {
            { n_pts, sx,  sx2, sy   },
            { sx,    sx2, sx3, sxy  },
            { sx2,   sx3, sx4, sx2y }
        };

        for (int col = 0; col < 3; col++) {
            int pivot = col;
            for (int row = col + 1; row < 3; row++) {
                if (Math.fabs (m[row, col]) > Math.fabs (m[pivot, col]))
                    pivot = row;
            }
            if (pivot != col) {
                for (int k = 0; k < 4; k++) {
                    double tmp = m[col, k];
                    m[col, k] = m[pivot, k];
                    m[pivot, k] = tmp;
                }
            }
            if (Math.fabs (m[col, col]) < 1e-12) {
                warning ("Least-squares system degenerate, falling back to two-point");
                double B_fb = Math.pow (
                    cal_sizes[cal_sizes.length - 1] / cal_sizes[0],
                    1.0 / (cal_crfs[cal_crfs.length - 1] - cal_crfs[0]));
                double A_fb = cal_sizes[0] / Math.pow (B_fb, cal_crfs[0]);
                qa = Math.log (A_fb);
                qb = Math.log (B_fb);
                qc = 0.0;
                degenerate = true;
                break;
            }
            for (int row = col + 1; row < 3; row++) {
                double factor = m[row, col] / m[col, col];
                for (int k = col; k < 4; k++)
                    m[row, k] -= factor * m[col, k];
            }
        }

        if (!degenerate) {
            qc = m[2, 3] / m[2, 2];
            qb = (m[1, 3] - m[1, 2] * qc) / m[1, 1];
            qa = (m[0, 3] - m[0, 1] * qb - m[0, 2] * qc) / m[0, 0];
        }
    }

    /**
     * Solve c*x^2 + b*x + (a - ln(target)) = 0 for CRF and select the root
     * that is valid or nearest the valid CRF range.
     */
    private double solve_crf_from_curve (
        double qa,
        double qb,
        double qc,
        double ln_target,
        double cal_mid,
        int    crf_min,
        int    crf_max
    ) {
        if (Math.fabs (qc) < 1e-15) {
            if (Math.fabs (qb) < 1e-15)
                return cal_mid;
            return (ln_target - qa) / qb;
        }

        double disc = qb * qb - 4.0 * qc * (qa - ln_target);
        if (disc < 0)
            return -qb / (2.0 * qc);

        double sqrt_disc = Math.sqrt (disc);
        double r1 = (-qb + sqrt_disc) / (2.0 * qc);
        double r2 = (-qb - sqrt_disc) / (2.0 * qc);

        if (r1 >= crf_min && r1 <= crf_max && r2 >= crf_min && r2 <= crf_max)
            return (Math.fabs (r1 - cal_mid) < Math.fabs (r2 - cal_mid)) ? r1 : r2;
        if (r1 >= crf_min && r1 <= crf_max)
            return r1;
        if (r2 >= crf_min && r2 <= crf_max)
            return r2;

        double d1 = double.min (Math.fabs (r1 - crf_min), Math.fabs (r1 - crf_max));
        double d2 = double.min (Math.fabs (r2 - crf_min), Math.fabs (r2 - crf_max));
        return (d1 < d2) ? r1 : r2;
    }

    private bool calibration_contains_crf (int[] cal_crfs, int crf) {
        for (int i = 0; i < cal_crfs.length; i++) {
            if (cal_crfs[i] == crf)
                return true;
        }
        return false;
    }

    private void append_calibration_sample (
        ref int[]    cal_crfs,
        ref double[] cal_sizes,
        int          crf,
        double       size_kb
    ) {
        int old_len = cal_crfs.length;
        int[] new_crfs = new int[old_len + 1];
        double[] new_sizes = new double[old_len + 1];

        for (int i = 0; i < old_len; i++) {
            new_crfs[i] = cal_crfs[i];
            new_sizes[i] = cal_sizes[i];
        }
        new_crfs[old_len] = crf;
        new_sizes[old_len] = size_kb;

        for (int i = 1; i < new_crfs.length; i++) {
            int cur_crf = new_crfs[i];
            double cur_size = new_sizes[i];
            int j = i - 1;
            while (j >= 0 && new_crfs[j] > cur_crf) {
                new_crfs[j + 1] = new_crfs[j];
                new_sizes[j + 1] = new_sizes[j];
                j--;
            }
            new_crfs[j + 1] = cur_crf;
            new_sizes[j + 1] = cur_size;
        }

        cal_crfs = new_crfs;
        cal_sizes = new_sizes;
    }

    private bool should_refine_calibration_window (int predicted_crf, int[] cal_crfs) {
        int cal_first = cal_crfs[0];
        int cal_last  = cal_crfs[cal_crfs.length - 1];
        return predicted_crf < cal_first
            || predicted_crf > cal_last
            || predicted_crf <= cal_first + ADAPTIVE_CALIBRATION_EDGE_MARGIN
            || predicted_crf >= cal_last - ADAPTIVE_CALIBRATION_EDGE_MARGIN;
    }

    /**
     * Pick up to two extra CRFs near the predicted answer when the initial
     * four-point window does not bracket it well.
     */
    private int[] pick_adaptive_calibration_crfs (
        int   predicted_crf,
        int[] cal_crfs,
        int   crf_min,
        int   crf_max,
        int   max_points
    ) {
        var extra_list = new GenericArray<int?> ();
        int remaining = max_points - cal_crfs.length;
        if (remaining <= 0 || !should_refine_calibration_window (predicted_crf, cal_crfs))
            return {};

        int cal_first = cal_crfs[0];
        int cal_last  = cal_crfs[cal_crfs.length - 1];
        double avg_gap = (cal_crfs.length > 1)
            ? (double) (cal_last - cal_first) / (double) (cal_crfs.length - 1)
            : 4.0;
        int step = int.max (2, (int) Math.round (avg_gap / 2.0));
        int[] offsets = { 0, -step, step, -2 * step, 2 * step, -3 * step, 3 * step };

        for (int i = 0; i < offsets.length && extra_list.length < remaining; i++) {
            int candidate = (predicted_crf + offsets[i]).clamp (crf_min, crf_max);
            if (calibration_contains_crf (cal_crfs, candidate))
                continue;

            bool already_added = false;
            for (int j = 0; j < extra_list.length; j++) {
                if (extra_list[j] == candidate) {
                    already_added = true;
                    break;
                }
            }
            if (!already_added)
                extra_list.add (candidate);
        }

        int[] extra = new int[extra_list.length];
        for (int i = 0; i < extra_list.length; i++)
            extra[i] = extra_list[i];
        return extra;
    }

    // ════════════════════════════════════════════════════════════════════════
    // CALIBRATION ENCODING
    // ════════════════════════════════════════════════════════════════════════

    /**
     * Choose four CRF calibration points that bracket the expected
     * answer for the given codec and target size tier.
     *
     * Four points give an overdetermined system for the quadratic fit,
     * enabling least-squares fitting that averages out noise from
     * individual samples — more robust than an exact 3-point fit.
     *
     * Larger targets need lower CRFs, so the calibration window shifts
     * downward to keep the quadratic model interpolating rather than
     * extrapolating.
     */
    private void pick_calibration_crfs (string codec, SizeTier tier,
                                         out int crf_a, out int crf_b,
                                         out int crf_c, out int crf_d) {
        if (codec == "vp9") {
            switch (tier) {
                case SizeTier.SMALL:  crf_a = 22; crf_b = 27; crf_c = 33; crf_d = 38; break;
                case SizeTier.MEDIUM: crf_a = 18; crf_b = 23; crf_c = 29; crf_d = 34; break;
                case SizeTier.LARGE:  crf_a = 15; crf_b = 20; crf_c = 26; crf_d = 31; break;
                case SizeTier.XLARGE: crf_a = 12; crf_b = 17; crf_c = 23; crf_d = 28; break;
                default:              crf_a = 25; crf_b = 30; crf_c = 35; crf_d = 40; break;
            }
        } else if (codec == "svt-av1") {
            switch (tier) {
                case SizeTier.SMALL:  crf_a = 18; crf_b = 25; crf_c = 32; crf_d = 38; break;
                case SizeTier.MEDIUM: crf_a = 15; crf_b = 21; crf_c = 27; crf_d = 33; break;
                case SizeTier.LARGE:  crf_a = 12; crf_b = 17; crf_c = 23; crf_d = 28; break;
                case SizeTier.XLARGE: crf_a =  8; crf_b = 13; crf_c = 19; crf_d = 24; break;
                default:              crf_a = 22; crf_b = 29; crf_c = 36; crf_d = 42; break;
            }
        } else {
            // x264 and x265 share the same CRF scale
            switch (tier) {
                case SizeTier.SMALL:  crf_a = 16; crf_b = 21; crf_c = 26; crf_d = 30; break;
                case SizeTier.MEDIUM: crf_a = 14; crf_b = 19; crf_c = 24; crf_d = 28; break;
                case SizeTier.LARGE:  crf_a = 10; crf_b = 15; crf_c = 21; crf_d = 26; break;
                case SizeTier.XLARGE: crf_a =  8; crf_b = 13; crf_c = 19; crf_d = 24; break;
                default:              crf_a = 18; crf_b = 23; crf_c = 28; crf_d = 32; break;
            }
        }
    }

    /**
     * Measure the actual audio bitrate by encoding a single segment.
     * Returns the measured audio bitrate in kbps, or 0 on failure.
     */
    private async int measure_audio_bitrate (
        string        input_file,
        string        resolved_container,
        double        seek_pos,
        double        segment_duration,
        int           target_audio_kbps,
        Cancellable?  cancellable = null
    ) throws Error {
        string ffmpeg = AppSettings.get_default ().ffmpeg_path;
        string tmp = tmp_path ("audio_measure");

        // Pick audio codec and raw container based on the resolved output container
        string audio_codec = (resolved_container == "webm") ? "libopus" : "aac";
        string audio_bitrate = "%dk".printf (target_audio_kbps);

        // Use raw container formats to avoid container overhead inflating
        // the measured bitrate.  ADTS is raw AAC frames; OGG is minimal
        // for Opus and much lighter than WebM.
        string container_fmt = (resolved_container == "webm") ? "ogg" : "adts";

        string[] cmd = {
            ffmpeg, "-y", "-v", "warning",
            "-ss", ConversionUtils.format_ffmpeg_double (seek_pos, "%.2f"),
            "-t", ConversionUtils.format_ffmpeg_double (segment_duration, "%.3f"),
            "-i", input_file,
            "-vn",
            "-c:a", audio_codec,
            "-b:a", audio_bitrate,
            "-f", container_fmt,
            tmp
        };

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
        cleanup_file (tmp);

        if (file_size <= 0 || segment_duration <= 0) return 0;

        // Convert file size to kbps: (bytes * 8) / (duration * 1000)
        double kbps = ((double) file_size * BITS_PER_BYTE)
            / (segment_duration * BITS_PER_KILOBIT);
        return (int) Math.round (kbps);
    }

    /**
     * Encode sample segments at a given CRF with the fastest preset.
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
        string        pix_fmt = ""
    ) throws Error {
        double sample_duration = double.min (
            (double) positions.length * segment_duration, full_duration);

        string tmp = tmp_path ("cal_%d".printf (crf));

        string[] cmd = build_concat_encode_cmd (
            input_file, codec, crf, positions, segment_duration, tmp,
            video_filter_chain, preset_idx, pix_fmt);

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

        double sample_kib = kib_from_bytes (file_size);
        double scale     = full_duration / sample_duration;
        return sample_kib * scale;
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

        for (int i = 0; i < positions.length; i++) {
            cmd.add ("-ss");  cmd.add (ConversionUtils.format_ffmpeg_double (positions[i], "%.2f"));
            cmd.add ("-t");   cmd.add (ConversionUtils.format_ffmpeg_double (seg_dur, "%.3f"));
            cmd.add ("-i");   cmd.add (path);
        }

        var fc = new StringBuilder ();
        bool has_vf = (video_filter_chain.length > 0);

        if (has_vf) {
            // Pre-filter each segment, then concat
            for (int i = 0; i < positions.length; i++)
                fc.append ("[%d:v]%s[s%d];".printf (i, video_filter_chain, i));
            for (int i = 0; i < positions.length; i++)
                fc.append ("[s%d]".printf (i));
        } else {
            for (int i = 0; i < positions.length; i++)
                fc.append ("[%d:v]".printf (i));
        }
        fc.append ("concat=n=%d:v=1:a=0[v];[v]%s".printf (positions.length, filter));

        cmd.add ("-filter_complex"); cmd.add (fc.str);
        cmd.add ("-f");              cmd.add ("null");
        cmd.add ("-");

        return cmd.data;
    }

    /**
     * Build a command that encodes concat'd segments to a file at a given CRF.
     *
     * When video_filter_chain is non-empty, each segment is pre-filtered
     * before concat so the calibration output reflects the actual encode size.
     *
     * @param preset_idx  When >= 0, use this preset index instead of the
     *                    fastest preset.
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
        string   pix_fmt = ""
    ) {
        string ffmpeg = AppSettings.get_default ().ffmpeg_path;
        var cmd = new GenericArray<string> ();
        cmd.add (ffmpeg);
        cmd.add ("-y");
        cmd.add ("-v"); cmd.add ("warning");

        for (int i = 0; i < positions.length; i++) {
            cmd.add ("-ss");  cmd.add (ConversionUtils.format_ffmpeg_double (positions[i], "%.2f"));
            cmd.add ("-t");   cmd.add (ConversionUtils.format_ffmpeg_double (seg_dur, "%.3f"));
            cmd.add ("-i");   cmd.add (path);
        }

        var fc = new StringBuilder ();
        bool has_vf = (video_filter_chain.length > 0);

        if (has_vf) {
            for (int i = 0; i < positions.length; i++)
                fc.append ("[%d:v]%s[s%d];".printf (i, video_filter_chain, i));
            for (int i = 0; i < positions.length; i++)
                fc.append ("[s%d]".printf (i));
        } else {
            for (int i = 0; i < positions.length; i++)
                fc.append ("[%d:v]".printf (i));
        }
        fc.append ("concat=n=%d:v=1:a=0[v]".printf (positions.length));

        cmd.add ("-filter_complex"); cmd.add (fc.str);
        cmd.add ("-map");            cmd.add ("[v]");
        cmd.add ("-an");             // no audio for calibration

        if (codec == "vp9") {
            cmd.add ("-c:v");      cmd.add ("libvpx-vp9");
            cmd.add ("-cpu-used"); cmd.add (preset_idx >= 0
                ? VP9_CPU_USED[preset_idx].to_string () : "8");
            cmd.add ("-crf");      cmd.add (crf.to_string ());
            cmd.add ("-b:v");      cmd.add ("0");
            cmd.add ("-row-mt");   cmd.add ("1");
        } else if (codec == "svt-av1") {
            cmd.add ("-c:v");      cmd.add ("libsvtav1");
            cmd.add ("-preset");   cmd.add (preset_idx >= 0
                ? SVT_AV1_PRESETS[preset_idx].to_string ()
                : SVT_AV1_PRESETS[0].to_string ());
            cmd.add ("-crf");      cmd.add (crf.to_string ());
        } else if (codec == "x265") {
            cmd.add ("-c:v");    cmd.add ("libx265");
            cmd.add ("-preset"); cmd.add (preset_idx >= 0
                ? X265_PRESETS[preset_idx] : "ultrafast");
            cmd.add ("-crf");    cmd.add (crf.to_string ());
        } else {
            cmd.add ("-c:v");    cmd.add ("libx264");
            cmd.add ("-preset"); cmd.add (preset_idx >= 0
                ? X264_PRESETS[preset_idx] : "ultrafast");
            cmd.add ("-crf");    cmd.add (crf.to_string ());
        }

        if (pix_fmt.length > 0) {
            cmd.add ("-pix_fmt"); cmd.add (pix_fmt);
        }

        cmd.add ("-f");    cmd.add ("matroska");
        cmd.add (output);

        return cmd.data;
    }

    // ════════════════════════════════════════════════════════════════════════
    // PARSING
    // ════════════════════════════════════════════════════════════════════════

    /**
     * Parse signalstats output for SATAVG and YDIF fields across all frames.
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
        ref double[] yavg_out
    ) {
        var sat_list  = new GenericArray<double?> ();
        var ydif_list = new GenericArray<double?> ();
        var ylow_list = new GenericArray<double?> ();
        var yavg_list = new GenericArray<double?> ();

        foreach (unowned string line in text.split ("\n")) {
            bool is_stats_line = line.contains ("Parsed_signalstats")
                || (line.contains ("SATAVG:") && line.contains ("YDIF:"));
            if (!is_stats_line) continue;

            double? sat  = parse_field_value (line, "SATAVG:");
            double? ydif = parse_field_value (line, "YDIF:");
            double? ylow = parse_field_value (line, "YLOW:");
            double? yavg = parse_field_value (line, "YAVG:");
            if (sat  != null) sat_list.add (sat);
            if (ydif != null) ydif_list.add (ydif);
            if (ylow != null) ylow_list.add (ylow);
            if (yavg != null) yavg_list.add (yavg);
        }

        satavg_out = new double[sat_list.length];
        for (int i = 0; i < sat_list.length; i++) satavg_out[i] = sat_list[i];

        ydif_out = new double[ydif_list.length];
        for (int i = 0; i < ydif_list.length; i++) ydif_out[i] = ydif_list[i];

        ylow_out = new double[ylow_list.length];
        for (int i = 0; i < ylow_list.length; i++) ylow_out[i] = ylow_list[i];

        yavg_out = new double[yavg_list.length];
        for (int i = 0; i < yavg_list.length; i++) yavg_out[i] = yavg_list[i];
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
        string key  = field_name + ":";
        var    list = new GenericArray<double?> ();

        foreach (unowned string line in text.split ("\n")) {
            bool is_stats_line = line.contains ("Parsed_signalstats")
                || line.contains (key);
            if (!is_stats_line) continue;
            double? val = parse_field_value (line, key);
            if (val != null) list.add (val);
        }

        values_out = new double[list.length];
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
     */
    private bool try_extract_number (string text, out double value) {
        value = 0.0;
        var  buf       = new StringBuilder ();
        bool in_number = false;
        for (int i = 0; i < text.length && buf.len < 16; i++) {
            char c = text[i];
            if (!in_number && (c == ' ' || c == '\t')) continue;
            if (c.isdigit () || c == '.' || (c == '-' && !in_number)) {
                buf.append_c (c);
                in_number = true;
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
    // STATISTICS
    // ════════════════════════════════════════════════════════════════════════

    private void compute_stats (double[] values, out double mean, out double stddev) {
        mean   = 0.0;
        stddev = 0.0;
        if (values.length == 0) return;

        double sum = 0.0;
        for (int i = 0; i < values.length; i++) sum += values[i];
        mean = sum / values.length;

        if (values.length < 2) return;
        double sq_sum = 0.0;
        for (int i = 0; i < values.length; i++) {
            double d = values[i] - mean;
            sq_sum += d * d;
        }
        stddev = Math.sqrt (sq_sum / (values.length - 1));
    }

    // ════════════════════════════════════════════════════════════════════════
    // SUBPROCESS HELPERS
    // ════════════════════════════════════════════════════════════════════════

    /** Run a command, return its stdout as a string. */
    private async string run_subprocess_stdout (string[] cmd, Cancellable? cancellable = null) throws Error {
        var launcher = new SubprocessLauncher (
            SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
        var proc = launcher.spawnv (cmd);
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
        var proc = launcher.spawnv (cmd);
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
        var proc = launcher.spawnv (cmd);

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
            string.joinv (" ", cmd), detail);
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

    private string tmp_path (string label) {
        return GLib.Path.build_filename (
            Environment.get_tmp_dir (),
            "smart_opt_%s_%lld.mkv".printf (label, get_real_time ()));
    }

    /**
     * Default container for a codec when the caller doesn't provide one.
     * VP9/SVT-AV1 → webm, x264/x265 → mp4.
     */
    private static string codec_default_container (string codec) {
        if (codec == "vp9" || codec == "svt-av1") return "webm";
        return "mp4";
    }

    /**
     * Resolve the effective output container based on tier policy.
     *
     * Tiny/Small: forced to the codec-default container (webm/mp4)
     *             for imageboard and web compatibility.
     * Medium+:    respect the user's container selection from the UI;
     *             fall back to codec default if unset.
     */
    private static string resolve_effective_container (
        string preferred_codec, SizeTier tier, string? user_container
    ) {
        if (tier <= SizeTier.SMALL) {
            return codec_default_container (preferred_codec);
        }
        if (user_container != null && user_container.length > 0) {
            return user_container;
        }
        return codec_default_container (preferred_codec);
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
            confidence             = 0.0,
            size_tier              = SizeTier.TINY,
            recommended_audio_kbps = 64,
            stream_copy_audio      = false,
            strip_metadata         = false,
            recommended_pix_fmt    = "",
            resolved_container     = codec_default_container (codec),
            target_size_kib        = 0
        };
    }
}
