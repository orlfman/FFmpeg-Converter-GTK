// smart-optimizer.vala
// Intelligent video size optimizer with content-aware encoding recommendations.
//
// Designed for 4chan/imageboard targets (≤4 MB, H.264/MP4 or VP9/WebM only).
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
//   - Three-point CRF calibration: encodes samples at three CRF values
//     (lo, mid, hi) instead of two, fitting a quadratic in log-space:
//       ln(size) = a + b·CRF + c·CRF²
//     The quadratic term captures the CRF↔size curve's bend that the
//     two-point exponential model missed, significantly improving accuracy
//     when the predicted CRF falls between or beyond calibration points.
//   - Graceful fallback: if the three-point system is degenerate (e.g. two
//     points produced identical sizes), falls back to two-point exponential
//     automatically.
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
    // SVT-AV1 presets 13→0 mapped to 9 indices (fastest to slowest)
    private const int[] SVT_AV1_PRESETS = { 13, 12, 11, 10, 8, 6, 4, 2, 0 };

    // ── Content-aware preset efficiency tables ───────────────────────────────
    //
    // Each table answers: compared to ultrafast/cpu-used-8, what fraction of
    // that file size does a given preset produce at the same CRF?
    // Index 0 = ultrafast (1.0 by definition), index 8 = veryslow.
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
    private const int    SEGMENT_DURATION = 8;      // seconds per sample
    private const int    MAX_SEGMENTS     = 4;
    private const double SEGMENT_SPREAD   = 0.15;   // start at 15%, end at 85%

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
     * bitrate (size-guaranteed). Caller decides which to use.
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
        double encode_duration = (ctx.effective_duration > 0)
            ? ctx.effective_duration
            : info.duration;

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
        // Sample from the full video even if a trim is set — the content
        // characteristics are representative. The encode_duration is only
        // used for the final size extrapolation.
        double[] positions = pick_sample_positions (info.duration);

        // ── 4. Content detection ────────────────────────────────────────
        ContentProfile profile;
        try {
            cancellable_check (cancellable);
            profile = yield analyze_content (input_file, positions, vf, cancellable);
        } catch (IOError.CANCELLED e) {
            throw e;
        } catch (Error e) {
            warning ("Content analysis failed, assuming live-action: %s", e.message);
            profile = ContentProfile () {
                content_type    = ContentType.LIVE_ACTION,
                type_confidence = 0.0
            };
        }

        // ── 5. Three-point CRF calibration ──────────────────────────────
        // Encode sample segments at three CRFs with the fastest preset,
        // measure sizes, fit a quadratic curve in log-space for THIS video.
        // Three points capture the curvature that a two-point exponential
        // misses, significantly improving accuracy when the predicted CRF
        // falls between or beyond the calibration points.
        // Video filters are included so calibration reflects the actual
        // output resolution and processing.

        int crf_lo, crf_mid, crf_hi;
        pick_calibration_crfs (preferred_codec, tier, out crf_lo, out crf_mid, out crf_hi);

        double size_lo_kb, size_mid_kb, size_hi_kb;
        try {
            cancellable_check (cancellable);
            size_lo_kb = yield calibration_encode (
                input_file, preferred_codec, crf_lo, positions, encode_duration,
                vf, cancellable);
            cancellable_check (cancellable);
            size_mid_kb = yield calibration_encode (
                input_file, preferred_codec, crf_mid, positions, encode_duration,
                vf, cancellable);
            cancellable_check (cancellable);
            size_hi_kb = yield calibration_encode (
                input_file, preferred_codec, crf_hi, positions, encode_duration,
                vf, cancellable);
        } catch (IOError.CANCELLED e) {
            throw e;
        } catch (Error e) {
            warning ("Calibration encode failed: %s", e.message);
            return make_error_rec (preferred_codec,
                "Test encode failed — is ffmpeg installed?\n%s".printf (e.message));
        }

        if (size_lo_kb <= 0 || size_mid_kb <= 0 || size_hi_kb <= 0) {
            warning ("Nonsensical calibration: lo=%.0f mid=%.0f hi=%.0f",
                     size_lo_kb, size_mid_kb, size_hi_kb);
            return make_error_rec (preferred_codec,
                "Calibration produced invalid results (%.0f / %.0f / %.0f KB). File may be corrupt."
                    .printf (size_lo_kb, size_mid_kb, size_hi_kb));
        }

        // Warn if sizes aren't monotonically decreasing (unusual but the
        // quadratic fit handles it — just means unusual content variance)
        if (size_lo_kb <= size_mid_kb || size_mid_kb <= size_hi_kb) {
            warning ("Non-monotonic calibration: CRF %d→%.0fKB, %d→%.0fKB, %d→%.0fKB — "
                + "proceeding with quadratic fit",
                crf_lo, size_lo_kb, crf_mid, size_mid_kb, crf_hi, size_hi_kb);
        }

        // ── 6. Fit CRF↔size curve (quadratic in log-space) ────────────
        // Model:  ln(size) = a + b·crf + c·crf²
        //
        // Three calibration points give a 3×3 linear system:
        //   a + b·x₁ + c·x₁² = ln(size_lo)
        //   a + b·x₂ + c·x₂² = ln(size_mid)
        //   a + b·x₃ + c·x₃² = ln(size_hi)
        //
        // Solved via row subtraction (Gaussian elimination). The quadratic
        // term (c) captures the CRF↔size curve's bend — the key improvement
        // over two-point exponential fitting.

        double x1 = (double) crf_lo;
        double x2 = (double) crf_mid;
        double x3 = (double) crf_hi;
        double y1 = Math.log (size_lo_kb);
        double y2 = Math.log (size_mid_kb);
        double y3 = Math.log (size_hi_kb);

        // Row-subtraction solve for the 3×3 system  [1, x, x²] · [a, b, c]ᵀ = [y]
        // Subtract row 1 from rows 2 and 3 to get a 2×2 system, then solve.
        // The determinant check guards against degenerate inputs (e.g. two
        // calibration points producing identical sizes).
        double det = (x2 - x1) * (x3*x3 - x1*x1) - (x3 - x1) * (x2*x2 - x1*x1);

        double qa, qb, qc;  // quadratic coefficients

        if (Math.fabs (det) < 1e-12) {
            // Degenerate — fall back to two-point exponential (lo + hi)
            warning ("Three-point calibration degenerate, falling back to two-point");
            if (size_lo_kb <= size_hi_kb || Math.fabs (size_lo_kb - size_hi_kb) < 1e-6) {
                // Even two-point is degenerate (sizes are equal or inverted)
                // — use a safe middle CRF
                warning ("Two-point fallback also degenerate — using midpoint CRF");
                qa = y1;
                qb = -0.1;  // small negative slope so the solver picks a reasonable CRF
                qc = 0.0;
            } else {
                double B_fallback = Math.pow (size_hi_kb / size_lo_kb, 1.0 / (crf_hi - crf_lo));
                double A_fallback = size_lo_kb / Math.pow (B_fallback, crf_lo);
                qa = Math.log (A_fallback);
                qb = Math.log (B_fallback);
                qc = 0.0;
            }
        } else {
            // Solve relative to point 1 to reduce numerical error
            double dy2 = y2 - y1;
            double dy3 = y3 - y1;
            double dx2 = x2 - x1;
            double dx3 = x3 - x1;
            double dx2sq = x2*x2 - x1*x1;
            double dx3sq = x3*x3 - x1*x1;

            qc = (dy2 * dx3 - dy3 * dx2) / (dx2sq * dx3 - dx3sq * dx2);
            qb = (dy2 - qc * dx2sq) / dx2;
            qa = y1 - qb * x1 - qc * x1 * x1;
        }

        // ── 7. Content-aware, tier-scaled preset selection ────────────
        // At larger targets, slower presets have diminishing returns because
        // the encoder already has plenty of bits. The "safe" baseline shifts
        // faster, and content-type influence is dampened.
        int ideal_preset_idx = choose_ideal_preset_index (profile);
        int safe_preset_idx  = tier_safe_preset_index (tier);
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
        double crf_raw;

        if (Math.fabs (qc) < 1e-15) {
            // Linear in log-space (pure exponential) — same as two-point
            if (Math.fabs (qb) < 1e-15) {
                // Flat curve — CRF has no effect on size. Use midpoint as best guess.
                crf_raw = (double) crf_mid;
            } else {
                crf_raw = (ln_target - qa) / qb;
            }
        } else {
            // Quadratic formula:  c·x² + b·x + (a − ln_target) = 0
            double disc = qb * qb - 4.0 * qc * (qa - ln_target);
            if (disc < 0) {
                // No real solution — curve doesn't reach the target.
                // Use the vertex (minimum/maximum point) as the best CRF.
                crf_raw = -qb / (2.0 * qc);
            } else {
                double sqrt_disc = Math.sqrt (disc);
                double r1 = (-qb + sqrt_disc) / (2.0 * qc);
                double r2 = (-qb - sqrt_disc) / (2.0 * qc);
                // Pick the root that falls in or nearest the valid CRF range.
                // For typical video, qc > 0 (curve bends up in log-space at
                // very high CRFs), so r2 is usually the correct root.
                if (r1 >= crf_min && r1 <= crf_max && r2 >= crf_min && r2 <= crf_max) {
                    // Both valid — pick the one closest to the midpoint
                    crf_raw = (Math.fabs (r1 - crf_mid) < Math.fabs (r2 - crf_mid)) ? r1 : r2;
                } else if (r1 >= crf_min && r1 <= crf_max) {
                    crf_raw = r1;
                } else if (r2 >= crf_min && r2 <= crf_max) {
                    crf_raw = r2;
                } else {
                    // Neither in range — pick closest to valid range
                    double d1 = double.min (Math.fabs (r1 - crf_min), Math.fabs (r1 - crf_max));
                    double d2 = double.min (Math.fabs (r2 - crf_min), Math.fabs (r2 - crf_max));
                    crf_raw = (d1 < d2) ? r1 : r2;
                }
            }
        }

        int predicted_crf = ((int) Math.round (crf_raw)).clamp (crf_min, crf_max);
        bool crf_at_max = (predicted_crf >= crf_max);

        // ── 8b. Verification encode ─────────────────────────────────────
        // Encode a single segment at the predicted CRF + recommended preset
        // to measure the real preset factor instead of relying on the
        // hardcoded table.  Compare against the quadratic model's ultrafast
        // prediction at the same CRF (no need for a second ultrafast encode).
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

            // Pick the middle sample position for verification
            double[] verify_pos = { positions[positions.length / 2] };
            try {
                cancellable_check (cancellable);

                // Single encode at the recommended preset to measure the real ratio
                verify_preset_kb = yield calibration_encode (
                    input_file, preferred_codec, predicted_crf, verify_pos,
                    encode_duration, vf, cancellable, preset_idx);

                if (verify_model_ultrafast_kb > 0 && verify_preset_kb > 0) {
                    verified_preset_factor = verify_preset_kb / verify_model_ultrafast_kb;
                    // Sanity: clamp to reasonable range (0.2–1.0)
                    verified_preset_factor = verified_preset_factor.clamp (0.20, 1.0);
                    verification_done = true;

                    // Re-solve CRF if the verified factor differs significantly
                    // from the table factor (>5% difference)
                    if (Math.fabs (verified_preset_factor - preset_factor) / preset_factor > 0.05) {
                        double re_target_kb = video_target_kb / verified_preset_factor;
                        double re_ln_target = Math.log (re_target_kb);
                        double re_crf_raw;

                        if (Math.fabs (qc) < 1e-15) {
                            re_crf_raw = (Math.fabs (qb) < 1e-15)
                                ? (double) crf_mid
                                : (re_ln_target - qa) / qb;
                        } else {
                            double re_disc = qb * qb - 4.0 * qc * (qa - re_ln_target);
                            if (re_disc < 0) {
                                re_crf_raw = -qb / (2.0 * qc);
                            } else {
                                double re_sqrt = Math.sqrt (re_disc);
                                double re_r1 = (-qb + re_sqrt) / (2.0 * qc);
                                double re_r2 = (-qb - re_sqrt) / (2.0 * qc);
                                if (re_r1 >= crf_min && re_r1 <= crf_max &&
                                    re_r2 >= crf_min && re_r2 <= crf_max) {
                                    re_crf_raw = (Math.fabs (re_r1 - crf_mid) <
                                                  Math.fabs (re_r2 - crf_mid)) ? re_r1 : re_r2;
                                } else if (re_r1 >= crf_min && re_r1 <= crf_max) {
                                    re_crf_raw = re_r1;
                                } else if (re_r2 >= crf_min && re_r2 <= crf_max) {
                                    re_crf_raw = re_r2;
                                } else {
                                    double d1 = double.min (
                                        Math.fabs (re_r1 - crf_min), Math.fabs (re_r1 - crf_max));
                                    double d2 = double.min (
                                        Math.fabs (re_r2 - crf_min), Math.fabs (re_r2 - crf_max));
                                    re_crf_raw = (d1 < d2) ? re_r1 : re_r2;
                                }
                            }
                        }

                        int re_crf = ((int) Math.round (re_crf_raw)).clamp (crf_min, crf_max);
                        if (re_crf != predicted_crf) {
                            warning ("Smart Optimizer: verification shifted CRF %d → %d "
                                + "(table factor %.2f, measured %.2f)",
                                predicted_crf, re_crf, preset_factor, verified_preset_factor);
                            predicted_crf = re_crf;
                            crf_at_max = (predicted_crf >= crf_max);
                        }
                    }
                }
            } catch (IOError.CANCELLED e) {
                throw e;
            } catch (Error e) {
                // Verification failed — fall back to the table-based factor
                warning ("Verification encode failed, using table preset factor: %s", e.message);
            }
        }

        double final_preset_factor = verification_done ? verified_preset_factor : preset_factor;

        // ── 9. Estimate final size ──────────────────────────────────────
        double raw_estimate_kb = Math.exp (qa + qb * predicted_crf + qc * predicted_crf * predicted_crf);
        int estimated_video_kb = (int) (raw_estimate_kb * final_preset_factor);
        int estimated_total_kb = estimated_video_kb + (int) audio_kb + (int) container_overhead_kb;

        // ── 10. Confidence ──────────────────────────────────────────────
        // Three-point calibration is most accurate within [crf_lo, crf_hi]
        // where the quadratic interpolates rather than extrapolates. Outside
        // that range, confidence degrades proportionally to distance.
        double confidence = 1.0;
        int cal_range = crf_hi - crf_lo;   // e.g. 14 for x264, 15 for vp9
        if (predicted_crf < crf_lo - cal_range || predicted_crf > crf_hi + cal_range) {
            confidence = 0.5;   // far extrapolation (> one full range outside)
            warning ("Smart Optimizer: CRF %d is far outside calibration range [%d, %d, %d] — "
                + "prediction reliability is low", predicted_crf, crf_lo, crf_mid, crf_hi);
        } else if (predicted_crf < crf_lo - 2 || predicted_crf > crf_hi + 2) {
            confidence = 0.75;  // moderate extrapolation
            warning ("Smart Optimizer: CRF %d is outside calibration range [%d, %d, %d] — "
                + "prediction may be inaccurate", predicted_crf, crf_lo, crf_mid, crf_hi);
        } else if (predicted_crf < crf_lo || predicted_crf > crf_hi) {
            confidence = 0.9;   // slight extrapolation (just outside range)
        }
        // Within [crf_lo, crf_hi]: confidence stays at 1.0 — the quadratic
        // model is interpolating between measured points, not extrapolating.

        // ── 10b. Sample coverage factor ─────────────────────────────────
        // When the sampled duration is a small fraction of the total, the
        // linear extrapolation (sample_kb × scale) becomes less reliable.
        // Flag this in the notes and reduce confidence accordingly.
        double sample_duration = double.min (
            (double) positions.length * SEGMENT_DURATION, encode_duration);
        double sample_coverage = sample_duration / encode_duration;
        if (sample_coverage < 0.10) {
            // Less than 10% sampled — meaningful uncertainty
            confidence *= 0.85;
            warning ("Smart Optimizer: sample covers only %.1f%% of video duration — "
                + "size estimate may be less accurate for long videos",
                sample_coverage * 100.0);
        }

        // ── 11. Tier-aware two-pass recommendation ────────────────────
        int target_video_kbps = available_video_kbps;
        bool recommend_two_pass;
        switch (tier) {
            case SizeTier.MEDIUM:
                recommend_two_pass = (confidence < 0.85);
                break;
            case SizeTier.LARGE:
                recommend_two_pass = (confidence < 0.70);
                break;
            case SizeTier.XLARGE:
                // At 200+ MB CRF mode is almost always sufficient
                recommend_two_pass = false;
                break;
            default:
                // TINY and SMALL — always recommend for size guarantee
                recommend_two_pass = true;
                break;
        }

        // ── 12. Feasibility flags ───────────────────────────────────────
        bool is_impossible = crf_at_max && (estimated_total_kb > target_total_kb * 1.1);

        // Force two-pass when CRF alone can't hit the target
        if (crf_at_max && !is_impossible) {
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
            notes.append ("\n── Two-pass mode (size-guaranteed) ──\n");
            notes.append ("  Target bitrate: %d kbps / Preset: %s\n"
                .printf (target_video_kbps, preset_label));
            notes.append ("  This mode guarantees the file fits within the target.\n");
            notes.append ("  Quality is determined by available bitrate, not CRF.\n");
        } else {
            notes.append ("\n── Two-pass: skipped ──\n");
            if (tier >= SizeTier.XLARGE) {
                notes.append ("  Target is generous — CRF mode will comfortably fit.\n");
            } else {
                notes.append ("  CRF confidence is high (%.0f%%) — CRF mode should hit the target.\n"
                    .printf (confidence * 100.0));
            }
        }

        // --- Warnings ---
        if (is_impossible) {
            notes.append ("\n⚠️  Even maximum compression will likely exceed the %d MB target.\n"
                .printf (target_mb));
            notes.append ("    Two-pass will fit the file but expect severe quality loss.\n");
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
        notes.append ("\n── Calibration data (3-point quadratic) ──\n");
        notes.append ("  CRF %d → %.0f KB (full-length estimate)\n"
            .printf (crf_lo, size_lo_kb));
        notes.append ("  CRF %d → %.0f KB (full-length estimate)\n"
            .printf (crf_mid, size_mid_kb));
        notes.append ("  CRF %d → %.0f KB (full-length estimate)\n"
            .printf (crf_hi, size_hi_kb));
        notes.append ("  Model: ln(size) = %.4f + %.4f·CRF + %.6f·CRF²\n"
            .printf (qa, qb, qc));
        if (verification_done) {
            notes.append ("  Preset factor = %.2f (verified: %s vs model, table: %.2f)\n"
                .printf (verified_preset_factor, preset_label, preset_factor));
            notes.append ("  Verification: model ultrafast→%.0f KB, %s→%.0f KB (ratio %.2f)\n"
                .printf (verify_model_ultrafast_kb, preset_label, verify_preset_kb,
                         verified_preset_factor));
        } else {
            notes.append ("  Preset efficiency factor = %.2f (%s vs ultrafast, from table)\n"
                .printf (preset_factor, preset_label));
        }
        notes.append ("  Container overhead: %.0f KB reserved\n"
            .printf (container_overhead_kb));
        if (tier == SizeTier.TINY) {
            notes.append ("  Metadata stripped to save space (tiny target)\n");
        }
        notes.append ("  Sample coverage: %.0f%% (%d × %ds segments)\n"
            .printf (sample_coverage * 100.0, positions.length, SEGMENT_DURATION));
        if (ctx.effective_duration > 0 && ctx.effective_duration != info.duration) {
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
            duration = double.parse (dur_str);
        }

        var info = SmartOptimizerVideoInfo () {
            duration                = duration,
            width                   = 0,
            height                  = 0,
            fps                     = 0.0,
            audio_bitrate_kbps      = 0,
            audio_bitrate_estimated = false,
            audio_codec             = ""
        };

        var streams = root.get_array_member ("streams");
        for (uint i = 0; i < streams.get_length (); i++) {
            var s     = streams.get_object_element (i);
            var ctype = s.get_string_member_with_default ("codec_type", "");

            if (ctype == "video" && info.width == 0) {
                info.width  = (int) s.get_int_member ("width");
                info.height = (int) s.get_int_member ("height");
                var rfr     = s.get_string_member_with_default ("r_frame_rate", "24/1");
                info.fps    = parse_fraction (rfr);

                // ── Duration fallback: video stream level ────────────────
                if (info.duration <= 0) {
                    string stream_dur = s.get_string_member_with_default ("duration", "0");
                    info.duration = double.parse (stream_dur);
                }
            }

            if (ctype == "audio") {
                var bstr = s.get_string_member_with_default ("bit_rate", "0");
                info.audio_bitrate_kbps = (int) (double.parse (bstr) / 1000.0);
                info.audio_codec = s.get_string_member_with_default ("codec_name", "");

                // ── Duration fallback: audio stream level ────────────────
                if (info.duration <= 0) {
                    string stream_dur = s.get_string_member_with_default ("duration", "0");
                    info.duration = double.parse (stream_dur);
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

    private double[] pick_sample_positions (double duration) {
        if (duration <= SEGMENT_DURATION * 2) {
            return { 0 };
        }

        int n = int.min (MAX_SEGMENTS, (int) (duration / SEGMENT_DURATION));
        n = int.max (n, 2);

        double usable = duration - SEGMENT_DURATION;
        double start  = usable * SEGMENT_SPREAD;
        double end    = usable * (1.0 - SEGMENT_SPREAD);
        double step   = (n > 1) ? (end - start) / (n - 1) : 0;

        var positions = new double[n];
        for (int i = 0; i < n; i++) {
            positions[i] = start + step * i;
        }
        return positions;
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
        string        video_filter_chain = "",
        Cancellable?  cancellable = null
    ) throws Error {
        int seg_dur = SEGMENT_DURATION;

        // ── Signal stats (color + motion via YDIF) ──────────────────────
        string[] sig_cmd = build_concat_analysis_cmd (
            path, positions, seg_dur,
            "signalstats=stat=tout+vrep+brng",
            video_filter_chain
        );
        string sig_output = yield run_subprocess_stderr (sig_cmd, cancellable);
        double[] all_satavg = {};
        double[] all_ydif   = {};
        parse_signalstats (sig_output, ref all_satavg, ref all_ydif);

        // ── Edge detection ──────────────────────────────────────────────
        string[] edge_cmd = build_concat_analysis_cmd (
            path, positions, seg_dur,
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
    private int tier_safe_preset_index (SizeTier tier) {
        switch (tier) {
            case SizeTier.TINY:   return 5;   // medium
            case SizeTier.SMALL:  return 5;   // medium
            case SizeTier.MEDIUM: return 4;   // fast
            case SizeTier.LARGE:  return 4;   // fast
            case SizeTier.XLARGE: return 3;   // faster
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

    // ════════════════════════════════════════════════════════════════════════
    // CALIBRATION ENCODING
    // ════════════════════════════════════════════════════════════════════════

    /**
     * Choose three CRF calibration points that bracket the expected
     * answer for the given codec and target size tier.
     *
     * Larger targets need lower CRFs, so the calibration window shifts
     * downward to keep the quadratic model interpolating rather than
     * extrapolating.
     */
    private void pick_calibration_crfs (string codec, SizeTier tier,
                                         out int crf_lo, out int crf_mid, out int crf_hi) {
        if (codec == "vp9") {
            switch (tier) {
                case SizeTier.SMALL:  crf_lo = 22; crf_mid = 30; crf_hi = 38; break;
                case SizeTier.MEDIUM: crf_lo = 18; crf_mid = 26; crf_hi = 34; break;
                case SizeTier.LARGE:  crf_lo = 15; crf_mid = 23; crf_hi = 31; break;
                case SizeTier.XLARGE: crf_lo = 12; crf_mid = 20; crf_hi = 28; break;
                default:              crf_lo = 25; crf_mid = 33; crf_hi = 40; break;
            }
        } else if (codec == "svt-av1") {
            switch (tier) {
                case SizeTier.SMALL:  crf_lo = 18; crf_mid = 28; crf_hi = 38; break;
                case SizeTier.MEDIUM: crf_lo = 15; crf_mid = 24; crf_hi = 33; break;
                case SizeTier.LARGE:  crf_lo = 12; crf_mid = 20; crf_hi = 28; break;
                case SizeTier.XLARGE: crf_lo =  8; crf_mid = 16; crf_hi = 24; break;
                default:              crf_lo = 22; crf_mid = 32; crf_hi = 42; break;
            }
        } else {
            // x264 and x265 share the same CRF scale
            switch (tier) {
                case SizeTier.SMALL:  crf_lo = 16; crf_mid = 23; crf_hi = 30; break;
                case SizeTier.MEDIUM: crf_lo = 14; crf_mid = 21; crf_hi = 28; break;
                case SizeTier.LARGE:  crf_lo = 10; crf_mid = 18; crf_hi = 26; break;
                case SizeTier.XLARGE: crf_lo =  8; crf_mid = 16; crf_hi = 24; break;
                default:              crf_lo = 18; crf_mid = 25; crf_hi = 32; break;
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
        string        video_filter_chain = "",
        Cancellable?  cancellable = null,
        int           preset_idx = -1
    ) throws Error {
        int seg_dur = SEGMENT_DURATION;
        double sample_duration = double.min (
            (double) positions.length * seg_dur, full_duration);

        string tmp = tmp_path ("cal_%d".printf (crf));

        string[] cmd = build_concat_encode_cmd (
            input_file, codec, crf, positions, seg_dur, tmp,
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
        int      seg_dur,
        string   filter,
        string   video_filter_chain = ""
    ) {
        string ffmpeg = AppSettings.get_default ().ffmpeg_path;
        var cmd = new GenericArray<string> ();
        cmd.add (ffmpeg);
        cmd.add ("-v");
        cmd.add ("info");   // info level required for signalstats output

        for (int i = 0; i < positions.length; i++) {
            cmd.add ("-ss");  cmd.add ("%.2f".printf (positions[i]));
            cmd.add ("-t");   cmd.add (seg_dur.to_string ());
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
        int      seg_dur,
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
            cmd.add ("-ss");  cmd.add ("%.2f".printf (positions[i]));
            cmd.add ("-t");   cmd.add (seg_dur.to_string ());
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
                ? SVT_AV1_PRESETS[preset_idx].to_string () : "13");
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
        return extract_number (after);
    }

    /**
     * Extract the first numeric value from a string.
     */
    private double extract_number (string text) {
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
        return (buf.len > 0) ? double.parse (buf.str) : 0.0;
    }

    /**
     * Parse "30000/1001" or "30" into a double.
     */
    private double parse_fraction (string s) {
        if ("/" in s) {
            var parts = s.split ("/");
            double num = double.parse (parts[0]);
            double den = double.parse (parts[1]);
            return (den > 0) ? num / den : 24.0;
        }
        double v = double.parse (s);
        return (v > 0) ? v : 24.0;
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
            SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
        var proc = launcher.spawnv (cmd);
        string stdout_buf;
        string stderr_buf;
        try {
            yield proc.communicate_utf8_async (null, cancellable, out stdout_buf, out stderr_buf);
        } catch (Error e) {
            proc.force_exit ();
            throw e;
        }
        return stdout_buf ?? "";
    }

    /** Run a command, return its stderr as a string (for ffmpeg stats parsing). */
    private async string run_subprocess_stderr (string[] cmd, Cancellable? cancellable = null) throws Error {
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
            string detail = (stderr_buf != null && stderr_buf.length > 0)
                ? stderr_buf.strip ()
                : "no output";
            throw new IOError.FAILED (
                "Command failed: %s\nffmpeg said: %s",
                string.joinv (" ", cmd), detail);
        }
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
        if (FileUtils.unlink (path) != 0) {
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
