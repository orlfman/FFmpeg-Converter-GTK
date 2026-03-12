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
//   - Container overhead: reserves KB for container headers, seek index, and
//     metadata based on size tier. Prevents "just barely over target" results.
//   - Metadata stripping for TINY tier: disables preserve_metadata when
//     targeting ≤25 MB — every byte counts at imageboard sizes.
//
// v7 improvements:
//   - Source-aware two-pass: when target_mb < source file size, two-pass
//     bitrate targeting is forced regardless of tier. CRF mode cannot
//     reliably hold a reduction target on its own, while bitrate targeting
//     gives the encoder a direct size budget to follow.
//   - CRF overshoot detection: if the CRF estimate exceeds the target by
//     >5%, two-pass is forced even when the source size is unknown.
//   - XLARGE tier no longer unconditionally skips two-pass. It now checks
//     confidence (threshold 0.60) and defers to the reduction/overshoot
//     checks above. Prevents 400MB→1.2GB blowups on large targets.
//   - Source file size probed from ffprobe format.size with stat fallback,
//     stored in SmartOptimizerVideoInfo.file_size_bytes.
//   - Duration-scaled sampling: videos >10 min now sample up to 8 segments
//     (64s) instead of 4 (32s), improving prediction accuracy on long or
//     variable-content videos.
//   - Source bitrate sanity check: computes the source's effective video
//     bitrate and compares it against the CRF estimate. If the model
//     predicts a larger output than the source while the target is smaller,
//     confidence is reduced to force two-pass.
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
//   - Three-tier duration scaling: <10 min (4 segments), 10–45 min (8),
//     45+ min (12 base, up to 16 adaptive).

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
    public int estimated_size_kb;
    public string notes;
    public bool is_impossible;
    public ContentType content_type;
    public double confidence;          // 0.0–1.0, how far we extrapolated
    public SizeTier size_tier;         // optimization strategy tier
    public int recommended_audio_kbps; // audio bitrate the preset should use
    public bool strip_metadata;        // true for TINY tier — save every byte
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

    // ── Content-aware preset efficiency tables ───────────────────────────────
    //
    // Each table answers: compared to the fastest preset in the array,
    // what fraction of that file size does a given preset produce at the
    // same CRF?  Index 0 = fastest (1.0 by definition), index 8 = slowest.
    //
    // These are initial estimates — the verification encode (step 8b)
    // measures the real ratio at runtime and corrects if >5% off.
    //
    // Live-action: diminishing returns past medium/slow.
    private const double[] PRESET_FACTORS_LIVE_ACTION = {
        1.00, 0.95, 0.90, 0.85, 0.82,
        0.78, 0.72, 0.65, 0.60
    };
    // Anime: flat fills + sharp ink lines respond strongly to encoder effort.
    // Slower presets can cut file size nearly in half versus ultrafast.
    private const double[] PRESET_FACTORS_ANIME = {
        1.00, 0.92, 0.85, 0.78, 0.73,
        0.66, 0.58, 0.50, 0.45
    };
    // Screencast: highly compressible even at ultrafast; slower presets help
    // more than live-action but the absolute savings are large either way.
    private const double[] PRESET_FACTORS_SCREENCAST = {
        1.00, 0.90, 0.82, 0.74, 0.68,
        0.60, 0.52, 0.44, 0.40
    };
    // Mixed: interpolated roughly between live-action and anime.
    private const double[] PRESET_FACTORS_MIXED = {
        1.00, 0.93, 0.87, 0.81, 0.77,
        0.72, 0.65, 0.57, 0.52
    };

    // Analysis segment config
    private const int    SEGMENT_DURATION   = 8;        // seconds per sample
    private const int    BASE_MAX_SEGMENTS  = 4;        // cap for videos < 10 min
    private const int    LONG_MAX_SEGMENTS  = 8;        // cap for videos 10–45 min
    private const int    VLONG_MAX_SEGMENTS = 12;       // cap for videos > 45 min
    private const int    ADAPTIVE_MAX_SEGMENTS = 16;    // cap when content variance is high
    private const int    ADAPTIVE_CALIBRATION_BASE_MAX_POINTS = 6; // 4 base + up to 2 follow-up CRFs
    private const int    ADAPTIVE_CALIBRATION_HARD_MAX_POINTS = 8; // one bounded second pass after verification
    private const double LONG_VIDEO_THRESHOLD  = 600.0; // 10 minutes
    private const double VLONG_VIDEO_THRESHOLD = 2700.0; // 45 minutes
    private const double SEGMENT_SPREAD    = 0.15;      // start at 15%, end at 85%
    // Coefficient of variation threshold for adaptive expansion.
    // If temporal_diff stddev/mean exceeds this, content varies significantly
    // across the video and more samples improve prediction accuracy.
    private const double ADAPTIVE_CV_THRESHOLD = 0.60;
    private const int    ADAPTIVE_CALIBRATION_EDGE_MARGIN = 1;
    private const int    ADAPTIVE_CALIBRATION_VERIFY_SHIFT_THRESHOLD = 2;

    // If the required video bitrate would fall below this threshold it is
    // physically impossible to produce acceptable-quality output.
    private const int MIN_VIABLE_VIDEO_KBPS = 80;

    // Container overhead (headers, index, seek tables) in KB per tier.
    // Subtracted from the video budget so the final file actually fits.
    private const double CONTAINER_OVERHEAD_KB_TINY   = 50.0;
    private const double CONTAINER_OVERHEAD_KB_SMALL  = 80.0;
    private const double CONTAINER_OVERHEAD_KB_MEDIUM = 120.0;
    private const double CONTAINER_OVERHEAD_KB_LARGE  = 200.0;
    private const double CONTAINER_OVERHEAD_KB_XLARGE = 300.0;

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

        if (ctx.strip_audio) {
            // No audio track — entire budget goes to video
            info.audio_bitrate_kbps      = 0;
            info.audio_bitrate_estimated = false;
        } else if (ctx.audio_bitrate_kbps_override > 0) {
            info.audio_bitrate_kbps      = ctx.audio_bitrate_kbps_override;
            info.audio_bitrate_estimated = false;
        }

        string vf = (ctx.video_filter_chain != null) ? ctx.video_filter_chain : "";

        // ── 1c. Size tier ───────────────────────────────────────────────
        SizeTier tier = SizeTier.from_mb (target_mb);
        int tier_audio = tier_audio_kbps (tier);

        // Use tier-based audio budget when caller hasn't explicitly
        // overridden or stripped audio — the codec preset will configure
        // audio to match.
        if (!ctx.strip_audio && ctx.audio_bitrate_kbps_override <= 0) {
            info.audio_bitrate_kbps      = tier_audio;
            info.audio_bitrate_estimated = false;
        }

        // ── 2. Early feasibility check ──────────────────────────────────
        // Before running any encode, check if the target is even physically
        // plausible. This saves the user waiting through two calibration
        // encodes for a result that was never achievable.
        double target_total_kb = (double) target_mb * 1024.0;
        double container_overhead_kb = container_overhead_for_tier (tier);
        double audio_kb = (info.audio_bitrate_kbps > 0)
            ? info.audio_bitrate_kbps * encode_duration / 8.0
            : 0.0;
        double video_target_kb = target_total_kb - audio_kb - container_overhead_kb;

        if (video_target_kb <= 0) {
            return make_error_rec (preferred_codec,
                "Audio track alone (~%.0f KB) exceeds the %d MB target."
                    .printf (audio_kb, target_mb));
        }

        int available_video_kbps = (int) (video_target_kb * 8.0 / encode_duration);
        if (available_video_kbps < MIN_VIABLE_VIDEO_KBPS) {
            var msg = new StringBuilder ();
            msg.append ("Target is physically implausible for this video.\n\n");
            msg.append ("Available video bitrate: %d kbps\n".printf (available_video_kbps));
            msg.append ("Minimum for any recognisable quality: %d kbps\n\n"
                .printf (MIN_VIABLE_VIDEO_KBPS));

            // Suggest what duration or scale would be needed
            if (info.width > 0 && info.height > 0) {
                // At MIN_VIABLE_VIDEO_KBPS, how many seconds can we fit?
                double max_duration_s = video_target_kb * 8.0 / MIN_VIABLE_VIDEO_KBPS;
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
                input_file, positions, sample_segment_duration, vf, cancellable);
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

        // ── 5. Base CRF calibration ────────────────────────────────────
        // Encode sample segments at four CRFs with the fastest preset,
        // measure sizes, then fit a quadratic curve in log-space via least-
        // squares. This base window can be adaptively extended later when
        // the predicted answer falls outside or right at the edge.
        // Video filters are included so calibration reflects the actual
        // output resolution and processing.

        int[] cal_crfs = new int[4];
        pick_calibration_crfs (preferred_codec, tier,
            out cal_crfs[0], out cal_crfs[1], out cal_crfs[2], out cal_crfs[3]);

        double[] cal_sizes = new double[4];
        try {
            for (int ci = 0; ci < cal_crfs.length; ci++) {
                cancellable_check (cancellable);
                cal_sizes[ci] = yield calibration_encode (
                    input_file, preferred_codec, cal_crfs[ci], positions,
                    encode_duration, sample_segment_duration, vf, cancellable);
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
                    warning ("Nonsensical calibration: CRF %d → %.0fKB",
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
                warning ("Non-monotonic calibration: CRF %d→%.0fKB, %d→%.0fKB — "
                    + "proceeding with least-squares fit",
                    cal_crfs[ci], cal_sizes[ci], cal_crfs[ci + 1], cal_sizes[ci + 1]);
                break;
            }
        }

        // ── 6. Fit CRF↔size curve (least-squares quadratic in log-space) ─
        double qa = 0, qb = 0, qc = 0;  // quadratic coefficients
        bool degenerate = false;
        fit_quadratic_log_curve (cal_crfs, cal_sizes, out qa, out qb, out qc, out degenerate);

        // ── 7. Content-aware, tier-scaled preset selection ────────────
        // At larger targets, slower presets have diminishing returns because
        // the encoder already has plenty of bits. The "safe" baseline shifts
        // faster, and content-type influence is dampened.
        int ideal_preset_idx = choose_ideal_preset_index (profile);
        int safe_preset_idx  = tier_safe_preset_index (tier, preferred_codec);
        double content_factor = tier_content_influence (tier);

        int preset_idx = safe_preset_idx + (int) Math.round (
            (ideal_preset_idx - safe_preset_idx) * profile.type_confidence * content_factor);
        preset_idx = preset_idx.clamp (0, X264_PRESETS.length - 1);

        double[] preset_factors = preset_factors_for_content (profile.content_type);
        double preset_factor = preset_factors[preset_idx];

        // ── 8. Solve for CRF ───────────────────────────────────────────
        // We calibrated at the fastest preset. The recommended (slower) preset
        // produces smaller files at the same CRF, so we inflate the target to
        // compensate:
        //   effective_target = video_target_kb / preset_factor
        // Then solve: ln(effective_target) = a + b·crf + c·crf²
        //   → c·crf² + b·crf + (a − ln(target)) = 0

        double effective_target_kb = video_target_kb / preset_factor;
        int crf_min, crf_max;
        if (preferred_codec == "vp9") {
            crf_min = 12; crf_max = 55;
        } else if (preferred_codec == "svt-av1") {
            crf_min = 10; crf_max = 55;
        } else {
            // x264 and x265 share the same 0–51 range
            crf_min = 8; crf_max = 51;
        }

        double ln_target = Math.log (effective_target_kb);
        double cal_mid = (double) (cal_crfs[0] + cal_crfs[cal_crfs.length - 1]) / 2.0;
        double crf_raw = solve_crf_from_curve (
            qa, qb, qc, ln_target, cal_mid, crf_min, crf_max);
        int predicted_crf = ((int) Math.round (crf_raw)).clamp (crf_min, crf_max);
        bool crf_at_max = (predicted_crf >= crf_max);
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
                            encode_duration, sample_segment_duration, vf, cancellable);
                        if (extra_size <= 0) {
                            warning ("Adaptive calibration produced invalid result: CRF %d → %.0fKB",
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
                        warning ("Non-monotonic adaptive calibration: CRF %d→%.0fKB, %d→%.0fKB — "
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
            }
        }

        // ── 8b. Verification encode ─────────────────────────────────────
        // Encode spread segments at the predicted CRF + recommended preset
        // to measure the real preset factor instead of relying on the
        // hardcoded table.  Compare against the quadratic model's fastest
        // prediction at the same CRF (no need for a second fastest-preset encode).
        //
        // If the verified factor differs significantly, re-solve for CRF
        // using the measured factor so the prediction is self-consistent.
        double verified_preset_factor = preset_factor;  // fallback
        bool   verification_done = false;
        double verify_model_ultrafast_kb = 0.0;
        double verify_preset_kb = 0.0;

        if (!crf_at_max) {
            // Model's prediction at this CRF with ultrafast (already known)
            verify_model_ultrafast_kb = Math.exp (
                qa + qb * predicted_crf + qc * predicted_crf * predicted_crf);

            // Pick spread positions for verification — using multiple segments
            // catches content variability that a single middle segment misses.
            double[] verify_pos;
            if (positions.length >= 4) {
                // Use 3 spread positions: ~25%, ~50%, ~75% through the samples
                int q1 = positions.length / 4;
                int q2 = positions.length / 2;
                int q3 = positions.length * 3 / 4;
                verify_pos = { positions[q1], positions[q2], positions[q3] };
            } else if (positions.length >= 2) {
                // Use first and last
                verify_pos = { positions[0], positions[positions.length - 1] };
            } else {
                verify_pos = { positions[0] };
            }
            try {
                cancellable_check (cancellable);

                // Encode at the recommended preset to measure the real ratio
                verify_preset_kb = yield calibration_encode (
                    input_file, preferred_codec, predicted_crf, verify_pos,
                    encode_duration, sample_segment_duration, vf, cancellable, preset_idx);

                if (verify_model_ultrafast_kb > 0 && verify_preset_kb > 0) {
                    verified_preset_factor = verify_preset_kb / verify_model_ultrafast_kb;
                    // Sanity: clamp to reasonable range (0.2–1.0)
                    verified_preset_factor = verified_preset_factor.clamp (0.20, 1.0);
                    verification_done = true;
                    bool verification_invalidated = false;

                    // Re-solve CRF if the verified factor differs significantly
                    // from the table factor (>5% difference)
                    if (Math.fabs (verified_preset_factor - preset_factor) / preset_factor > 0.05) {
                        int verify_base_crf = predicted_crf;
                        bool verification_curve_refit = false;
                        double re_target_kb = video_target_kb / verified_preset_factor;
                        double re_ln_target = Math.log (re_target_kb);
                        double re_crf_raw = solve_crf_from_curve (
                            qa, qb, qc, re_ln_target, cal_mid, crf_min, crf_max);
                        int re_crf = ((int) Math.round (re_crf_raw)).clamp (crf_min, crf_max);

                        int cal_first_now = cal_crfs[0];
                        int cal_last_now = cal_crfs[cal_crfs.length - 1];
                        bool needs_second_refinement =
                            Math.fabs ((double) (re_crf - verify_base_crf))
                                >= ADAPTIVE_CALIBRATION_VERIFY_SHIFT_THRESHOLD
                            && (re_crf < cal_first_now - ADAPTIVE_CALIBRATION_VERIFY_SHIFT_THRESHOLD
                                || re_crf > cal_last_now + ADAPTIVE_CALIBRATION_VERIFY_SHIFT_THRESHOLD);

                        if (needs_second_refinement) {
                            int[] verify_extra_crfs = pick_adaptive_calibration_crfs (
                                re_crf, cal_crfs, crf_min, crf_max,
                                ADAPTIVE_CALIBRATION_HARD_MAX_POINTS);
                            int second_points_added = 0;
                            for (int ci = 0; ci < verify_extra_crfs.length; ci++) {
                                try {
                                    cancellable_check (cancellable);
                                    double extra_size = yield calibration_encode (
                                        input_file, preferred_codec, verify_extra_crfs[ci], positions,
                                        encode_duration, sample_segment_duration, vf, cancellable);
                                    if (extra_size <= 0) {
                                        warning ("Adaptive verification calibration produced invalid result: CRF %d → %.0fKB",
                                            verify_extra_crfs[ci], extra_size);
                                        continue;
                                    }
                                    append_calibration_sample (
                                        ref cal_crfs, ref cal_sizes, verify_extra_crfs[ci], extra_size);
                                    second_points_added++;
                                } catch (IOError.CANCELLED e) {
                                    throw e;
                                } catch (Error e) {
                                    warning ("Adaptive verification calibration encode failed at CRF %d: %s",
                                        verify_extra_crfs[ci], e.message);
                                    continue;
                                }
                            }

                            if (second_points_added > 0) {
                                adaptive_calibration_refined = true;
                                adaptive_points_added += second_points_added;
                                verification_curve_refit = true;
                                fit_quadratic_log_curve (
                                    cal_crfs, cal_sizes, out qa, out qb, out qc, out degenerate);
                                cal_mid = (double) (cal_crfs[0] + cal_crfs[cal_crfs.length - 1]) / 2.0;
                                verify_model_ultrafast_kb = Math.exp (
                                    qa + qb * verify_base_crf + qc * verify_base_crf * verify_base_crf);
                                if (verify_model_ultrafast_kb > 0 && verify_preset_kb > 0) {
                                    verified_preset_factor = (verify_preset_kb / verify_model_ultrafast_kb)
                                        .clamp (0.20, 1.0);
                                    re_target_kb = video_target_kb / verified_preset_factor;
                                    re_ln_target = Math.log (re_target_kb);
                                } else {
                                    verification_done = false;
                                    verified_preset_factor = preset_factor;
                                }
                                re_crf_raw = solve_crf_from_curve (
                                    qa, qb, qc, re_ln_target, cal_mid, crf_min, crf_max);
                                re_crf = ((int) Math.round (re_crf_raw)).clamp (crf_min, crf_max);
                            }
                        }

                        if (verification_curve_refit && re_crf == verify_base_crf) {
                            verification_done = (verify_model_ultrafast_kb > 0 && verify_preset_kb > 0);
                        }

                        if (re_crf != verify_base_crf) {
                            warning ("Smart Optimizer: verification shifted CRF %d → %d "
                                + "(table factor %.2f, measured %.2f)",
                                verify_base_crf, re_crf, preset_factor, verified_preset_factor);
                            predicted_crf = re_crf;
                            crf_at_max = (predicted_crf >= crf_max);
                            verification_invalidated = true;
                        }
                    }

                    if (verification_invalidated) {
                        verification_done = false;
                        verified_preset_factor = preset_factor;
                    }

                    if (verification_invalidated && !crf_at_max) {
                        verify_model_ultrafast_kb = Math.exp (
                            qa + qb * predicted_crf + qc * predicted_crf * predicted_crf);
                        verify_preset_kb = yield calibration_encode (
                            input_file, preferred_codec, predicted_crf, verify_pos,
                            encode_duration, sample_segment_duration, vf, cancellable, preset_idx);

                        if (verify_model_ultrafast_kb > 0 && verify_preset_kb > 0) {
                            verified_preset_factor = (verify_preset_kb / verify_model_ultrafast_kb)
                                .clamp (0.20, 1.0);
                            verification_done = true;
                        } else {
                            warning ("Final verification at CRF %d produced invalid results; using table preset factor",
                                predicted_crf);
                        }
                    }
                }
            } catch (IOError.CANCELLED e) {
                throw e;
            } catch (Error e) {
                // Verification failed before a usable measured factor was applied.
                warning ("Verification encode failed, using table preset factor: %s", e.message);
            }
        }

        double final_preset_factor = verification_done ? verified_preset_factor : preset_factor;

        // ── 9. Estimate final size ──────────────────────────────────────
        double raw_estimate_kb = Math.exp (qa + qb * predicted_crf + qc * predicted_crf * predicted_crf);
        int estimated_video_kb = (int) (raw_estimate_kb * final_preset_factor);
        int estimated_total_kb = estimated_video_kb + (int) audio_kb + (int) container_overhead_kb;

        // ── 10. Confidence ──────────────────────────────────────────────
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

        // ── 10b. Sample coverage factor ─────────────────────────────────
        // When the sampled duration is a small fraction of the total, the
        // linear extrapolation (sample_kb × scale) becomes less reliable.
        // Flag this in the notes and reduce confidence accordingly.
        double sample_duration = double.min (
            (double) positions.length * sample_segment_duration, encode_duration);
        double sample_coverage = sample_duration / encode_duration;
        if (sample_coverage < 0.10) {
            // Less than 10% sampled — meaningful uncertainty
            confidence *= 0.85;
            warning ("Smart Optimizer: sample covers only %.1f%% of video duration — "
                + "size estimate may be less accurate for long videos",
                sample_coverage * 100.0);
        }

        // ── 10c. Source bitrate sanity check ─────────────────────────
        // Compare the estimated output size against the source file size.
        // If the CRF model predicts a LARGER output while the user wants a
        // SMALLER file, the prediction is unreliable — reduce confidence
        // so the tier logic is more likely to trigger two-pass.
        //
        // We compare total sizes (not video-only) because the probed audio
        // bitrate has already been replaced by the tier-based budget — the
        // original source audio bitrate is no longer available.
        int source_video_kbps = 0;
        double source_total_kbps = 0.0;
        if (info.file_size_bytes > 0 && info.duration > 0) {
            source_total_kbps = (double) info.file_size_bytes * 8.0
                / (info.duration * 1024.0);
        }
        if (!trim_active && source_total_kbps > 0 && encode_duration > 0) {
            // Rough source video kbps — subtract a conservative audio estimate.
            // 128 kbps covers most common audio codecs without over-subtracting.
            source_video_kbps = int.max (0, (int) source_total_kbps - 128);

            // If the CRF estimate exceeds the source's size while the user
            // asked for a smaller target, the model's prediction is suspect.
            if (source_video_kbps > 0 && available_video_kbps < source_video_kbps) {
                int estimated_output_kbps = (int) ((double) estimated_total_kb * 8.0 / encode_duration);
                int source_total_kbps_int = (int) source_total_kbps;
                if (estimated_output_kbps > source_total_kbps_int) {
                    confidence *= 0.6;
                    warning ("Smart Optimizer: CRF estimate (%d kbps) exceeds source (%d kbps) "
                        + "— prediction is unreliable",
                        estimated_output_kbps, source_total_kbps_int);
                }
            }
        }

        // ── 11. Tier-aware two-pass recommendation ────────────────────
        int target_video_kbps = available_video_kbps;
        bool recommend_two_pass;

        // Check whether the user is asking for a file smaller than the
        // source. Tiny/Small still treat that as a hard cap; Medium+
        // allow CRF when the estimate is confident and lands near target.
        double source_size_mb = (double) info.file_size_bytes / (1024.0 * 1024.0);
        double comparison_source_size_mb = source_size_mb;
        double reduction_confidence = 1.0;
        if (trim_active && source_total_kbps > 0) {
            comparison_source_size_mb = source_total_kbps * encode_duration / 8.0 / 1024.0;
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
        bool is_reduction = (comparison_source_size_mb > 0)
            && ((double) target_mb < comparison_source_size_mb * reduction_threshold);

        bool strict_targeting = tier_uses_strict_targeting (tier);
        double target_tolerance_kb = strict_targeting
            ? target_total_kb * 0.05
            : tier_target_tolerance_kb (tier, target_total_kb);
        bool within_target_band = Math.fabs (estimated_total_kb - target_total_kb) <= target_tolerance_kb;

        // For Tiny/Small, even modest overshoot is unacceptable.
        // For Medium+, treat the target as a symmetric landing zone around
        // the requested size, with some leniency above or below target.
        bool crf_overshoots = estimated_total_kb > (target_total_kb + target_tolerance_kb);

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

            // For Medium+, allow CRF only when the estimate is both
            // confident enough for the tier and lands inside the symmetric
            // target band around the requested size.
            if (!recommend_two_pass) {
                if (crf_overshoots) {
                    recommend_two_pass = true;
                } else if (!within_target_band) {
                    recommend_two_pass = true;
                }
            }
        }

        // ── 12. Feasibility flags ───────────────────────────────────────
        bool is_impossible = crf_at_max && (estimated_total_kb > target_total_kb * 1.1);

        // Force two-pass when CRF alone cannot comfortably hit the target,
        // including cases where even max CRF still looks too large.
        if (crf_at_max) {
            recommend_two_pass = true;
        }

        // ── 13. Build the recommendation ────────────────────────────────
        string preset_label = format_preset_label (preferred_codec, preset_idx);

        var notes = new StringBuilder ();

        // --- Tier ---
        notes.append ("── Strategy: %s ──\n".printf (tier.to_label ()));
        notes.append ("  Audio budget: %d kbps\n".printf (tier_audio));

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

        // --- Audio ---
        if (info.audio_bitrate_kbps > 0) {
            notes.append ("  Audio: ~%d kbps".printf (info.audio_bitrate_kbps));
            if (info.audio_bitrate_estimated)
                notes.append (" (estimated %s — stream did not report bitrate)".printf (
                    info.audio_codec));
            notes.append (" → %d KB reserved\n".printf ((int) audio_kb));
        }

        // --- CRF mode ---
        notes.append ("\n── CRF mode (quality-focused) ──\n");
        notes.append ("  CRF %d / Preset: %s\n".printf (predicted_crf, preset_label));

        if (crf_at_max && !is_impossible) {
            notes.append ("  ⚠️  CRF mode is at maximum compression — quality will be poor.\n");
            notes.append ("  ✅  Two-pass mode below is the recommended path.\n");
        } else if (!is_impossible) {
            notes.append ("  Estimated: ~%d KB".printf (estimated_total_kb));
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
            if (is_reduction) {
                if (!strict_targeting && !within_target_band) {
                    notes.append ("  CRF estimate (~%d KB) falls outside the ±%.0f MB target band for this tier.\n"
                        .printf (estimated_total_kb, target_tolerance_kb / 1024.0));
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
            } else if (crf_overshoots) {
                if (strict_targeting) {
                    notes.append ("  CRF estimate (~%d KB) exceeds target (~%.0f KB).\n"
                        .printf (estimated_total_kb, target_total_kb));
                } else {
                    notes.append ("  CRF estimate (~%d KB) exceeds the ±%.0f MB target band.\n"
                        .printf (estimated_total_kb, target_tolerance_kb / 1024.0));
                }
            } else if (!strict_targeting && !within_target_band) {
                notes.append ("  CRF estimate (~%d KB) falls outside the ±%.0f MB target band for this tier.\n"
                    .printf (estimated_total_kb, target_tolerance_kb / 1024.0));
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
                    .printf (confidence * 100.0, target_tolerance_kb / 1024.0));
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
        if (sample_coverage < 0.10) {
            notes.append ("\nℹ️  Only %.0f%% of the video was sampled for calibration.\n"
                .printf (sample_coverage * 100.0));
            notes.append ("    Estimates may be less accurate for long or variable-content videos.\n");
        }

        // --- Calibration data ---
        notes.append ("\n── Calibration data (%d-point least-squares quadratic) ──\n"
            .printf (cal_crfs.length));
        for (int ci = 0; ci < cal_crfs.length; ci++) {
            notes.append ("  CRF %d → %.0f KB (full-length estimate)\n"
                .printf (cal_crfs[ci], cal_sizes[ci]));
        }
        notes.append ("  Model: ln(size) = %.4f + %.4f·CRF + %.6f·CRF²\n"
            .printf (qa, qb, qc));
        if (adaptive_calibration_refined) {
            notes.append ("  Adaptive refinement: +%d follow-up point%s around the solved CRF path\n"
                .printf (adaptive_points_added, adaptive_points_added == 1 ? "" : "s"));
        }
        if (verification_done) {
            notes.append ("  Preset factor = %.2f (verified: %s vs model, table: %.2f)\n"
                .printf (verified_preset_factor, preset_label, preset_factor));
            notes.append ("  Verification: model fastest→%.0f KB, %s→%.0f KB (ratio %.2f)\n"
                .printf (verify_model_ultrafast_kb, preset_label, verify_preset_kb,
                         verified_preset_factor));
        } else {
            notes.append ("  Preset efficiency factor = %.2f (%s vs fastest, from table)\n"
                .printf (preset_factor, preset_label));
        }
        notes.append ("  Container overhead: %.0f KB reserved\n"
            .printf (container_overhead_kb));
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
            estimated_size_kb     = estimated_total_kb,
            notes                 = notes.str,
            is_impossible         = is_impossible,
            content_type          = profile.content_type,
            confidence            = confidence,
            size_tier             = tier,
            recommended_audio_kbps = tier_audio,
            strip_metadata        = (tier == SizeTier.TINY)
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
        if (rec.two_pass)
            sb.append ("  Bitrate cap:  %d kbps\n".printf (rec.target_bitrate_kbps));
        sb.append ("Est. size:      %d KB\n".printf (rec.estimated_size_kb));
        sb.append ("Content:        %s\n".printf (rec.content_type.to_label ()));
        sb.append ("Confidence:     %s\n".printf ("%.0f%%".printf (rec.confidence * 100)));
        sb.append ("Size tier:      %s\n".printf (rec.size_tier.to_label ()));
        sb.append ("Audio budget:   %d kbps\n".printf (rec.recommended_audio_kbps));
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
            file_size_bytes         = source_size_bytes
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

        // Scale segment cap with duration — long videos need more coverage
        // to capture content variability across scenes.
        int max_segs;
        if (duration >= VLONG_VIDEO_THRESHOLD) {
            max_segs = VLONG_MAX_SEGMENTS;
        } else if (duration >= LONG_VIDEO_THRESHOLD) {
            max_segs = LONG_MAX_SEGMENTS;
        } else {
            max_segs = BASE_MAX_SEGMENTS;
        }
        int n = int.min (max_segs, (int) (duration / segment_duration));
        n = int.max (n, 2);

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
        parse_signalstats (sig_output, ref all_satavg, ref all_ydif);

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

        classify_content (ref profile);
        return profile;
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

    /**
     * Return the correct preset-efficiency table for a given content type.
     */
    private unowned double[] preset_factors_for_content (ContentType ct) {
        switch (ct) {
            case ContentType.ANIME:      return PRESET_FACTORS_ANIME;
            case ContentType.SCREENCAST: return PRESET_FACTORS_SCREENCAST;
            case ContentType.MIXED:      return PRESET_FACTORS_MIXED;
            default:                     return PRESET_FACTORS_LIVE_ACTION;
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
     * Estimated container overhead (headers, index, seek tables) in KB.
     * Subtracted from the video budget so the final file actually fits.
     */
    private double container_overhead_for_tier (SizeTier tier) {
        switch (tier) {
            case SizeTier.TINY:   return CONTAINER_OVERHEAD_KB_TINY;
            case SizeTier.SMALL:  return CONTAINER_OVERHEAD_KB_SMALL;
            case SizeTier.MEDIUM: return CONTAINER_OVERHEAD_KB_MEDIUM;
            case SizeTier.LARGE:  return CONTAINER_OVERHEAD_KB_LARGE;
            case SizeTier.XLARGE: return CONTAINER_OVERHEAD_KB_XLARGE;
            default:              return CONTAINER_OVERHEAD_KB_SMALL;
        }
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
    private double tier_target_tolerance_kb (SizeTier tier, double target_total_kb) {
        switch (tier) {
            case SizeTier.MEDIUM:
                return double.max (8.0 * 1024.0, target_total_kb * 0.10);
            case SizeTier.LARGE:
                return double.max (10.0 * 1024.0, target_total_kb * 0.10);
            case SizeTier.XLARGE:
                return double.max (16.0 * 1024.0, target_total_kb * 0.12);
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
     * Encode sample segments at a given CRF with the fastest preset.
     * Returns estimated full-video size in KB (extrapolated from sample).
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
        int           preset_idx = -1
    ) throws Error {
        double sample_duration = double.min (
            (double) positions.length * segment_duration, full_duration);

        string tmp = tmp_path ("cal_%d".printf (crf));

        string[] cmd = build_concat_encode_cmd (
            input_file, codec, crf, positions, segment_duration, tmp,
            video_filter_chain, preset_idx);

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

        double sample_kb = (double) file_size / 1024.0;
        double scale     = full_duration / sample_duration;
        return sample_kb * scale;
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
     * Build a command that encodes concat'd segments to a file at a given CRF
     * using the fastest preset (for calibration speed).
     *
     * When video_filter_chain is non-empty, each segment is pre-filtered
     * before concat so the calibration output reflects the actual encode size.
     */
    /**
     * @param preset_idx  When >= 0, use this preset index instead of the
     *                    fastest preset. Used by verification encodes.
     */
    private string[] build_concat_encode_cmd (
        string   path,
        string   codec,
        int      crf,
        double[] positions,
        double   seg_dur,
        string   output,
        string   video_filter_chain = "",
        int      preset_idx = -1
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
        ref double[] ydif_out
    ) {
        var sat_list  = new GenericArray<double?> ();
        var ydif_list = new GenericArray<double?> ();

        foreach (unowned string line in text.split ("\n")) {
            bool is_stats_line = line.contains ("Parsed_signalstats")
                || (line.contains ("SATAVG:") && line.contains ("YDIF:"));
            if (!is_stats_line) continue;

            double? sat  = parse_field_value (line, "SATAVG:");
            double? ydif = parse_field_value (line, "YDIF:");
            if (sat  != null) sat_list.add (sat);
            if (ydif != null) ydif_list.add (ydif);
        }

        satavg_out = new double[sat_list.length];
        for (int i = 0; i < sat_list.length; i++) satavg_out[i] = sat_list[i];

        ydif_out = new double[ydif_list.length];
        for (int i = 0; i < ydif_list.length; i++) ydif_out[i] = ydif_list[i];
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
            estimated_size_kb      = 0,
            notes                  = "❌ " + message,
            is_impossible          = true,
            content_type           = ContentType.LIVE_ACTION,
            confidence             = 0.0,
            size_tier              = SizeTier.TINY,
            recommended_audio_kbps = 64,
            strip_metadata         = false
        };
    }
}
