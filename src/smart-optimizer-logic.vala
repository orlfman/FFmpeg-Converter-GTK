// smart-optimizer-logic.vala
// Pure decision logic for the Smart Optimizer: public types, unit
// conversions, budget/audio planning, calibration point selection,
// CRF↔size curve fitting and solving, confidence assessment, and the
// two-pass policy.
//
// This file deliberately has NO subprocess, filesystem, or AppSettings
// dependencies so every function here is unit-testable
// (tests/smart-optimizer-logic-test.vala).  Orchestration, probing, and
// the actual ffmpeg encodes live in smart-optimizer.vala.

using GLib;

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

/**
 * Encoder effort / quality level — the single axis every downstream
 * `CodecPresets.apply_smart_*` function switches on.
 *
 * This is deliberately NOT a size concept.  It expresses how much work the
 * encoder should do and how generously it should spend on perceptual quality:
 * reference frames, motion search, subpel refinement, lookahead, psy-rd,
 * quantization matrices, grain synthesis, and audio budget.
 *
 * Both operating modes produce one:
 *   - Size Mode    derives it from SizeTier (see effort_from_size_tier).
 *   - Quality Mode derives it from the user's quality intent.
 *
 * Downstream feature tables therefore never learn which mode ran, which is
 * what keeps `apply_smart_*` a single code path instead of forking per mode.
 */
public enum EncodeEffort {
    MINIMAL,
    LOW,
    MEDIUM,
    HIGH,
    MAXIMUM;

    public string to_label () {
        switch (this) {
            case MINIMAL: return "Minimal";
            case LOW:     return "Low";
            case MEDIUM:  return "Medium";
            case HIGH:    return "High";
            case MAXIMUM: return "Maximum";
            default:      return "Unknown";
        }
    }
}

/**
 * Which axis the user constrained.  The other one is the readout — both are
 * always reported, so the result can show "50 MB → est. VMAF 93" or
 * "VMAF 95 → est. 78 MB" from the same recommendation.
 */
public enum PinnedAxis {
    SIZE,
    QUALITY;

    public string to_label () {
        return (this == QUALITY) ? "Quality" : "Size";
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
    public int recommended_audio_kbps; // per-stream audio bitrate reserved in the size estimate
    /**
     * Per-stream bitrate the applier must hand the encoder, as a rung of
     * AudioCodecOptions.bitrate_values (0 = stripped or stream-copied).
     *
     * Separate from recommended_audio_kbps because that one is what the
     * output is expected to weigh after VBR measurement, which is routinely a
     * few kbps under the target and is not a selectable rung.  The applier
     * must use THIS field: deriving the bitrate independently is what let the
     * estimate and the encode disagree by 32% at Low intent.
     */
    public int audio_encode_kbps;
    public int total_audio_budget_kbps; // total audio bitrate reserved across all output tracks
    public int audio_track_count;      // number of output audio tracks represented by the budget
    public bool preserve_all_audio_tracks_effective; // tier-aware effective keep-all state
    public bool stream_copy_audio;     // true when source audio should be copied, not re-encoded
    public bool strip_metadata;        // true for TINY tier — save every byte
    public string recommended_pix_fmt; // "yuv420p10le", "yuv420p", or "" (codec default)
    public string resolved_container;  // effective container after tier policy (e.g. "webm", "mp4", "mkv")
    public int target_size_kib;        // user-requested target size in KiB
    public double grain_score;         // measured TOUT (temporal-outlier fraction) — grain/noise proxy
    public double detail_score;        // 0.0–1.0 native-sharpness demand
    /** Exact VP9/SVT-AV1 native sharpness used by calibration; 0 = disabled. */
    public int native_sharpness;
    /** Exact temporal settings applied to every supported video codec. */
    public int keyint_frames;
    public double keyint_seconds;
    public int lookahead_frames;
    public double motion_variability;
    public double static_frame_ratio;
    public double cuts_per_minute;
    public string temporal_reason;

    // ── Mode-agnostic decision axis ──────────────────────────────────────────
    // Every downstream apply_smart_* switches on `effort`, never on size_tier,
    // so the encoder feature tables work identically in both modes.
    public EncodeEffort effort;
    // Force the codec-default container (webm/mp4) for compatibility, ignoring
    // the user's container choice.  A size-target policy (imageboard-tier
    // output), NOT a quality concept — hence its own flag rather than a tier
    // comparison inside the preset appliers.
    public bool force_compat_container;

    // ── Dual-axis reporting ──────────────────────────────────────────────────
    // Both numbers are reported regardless of mode; `pinned_axis` says which
    // one was the constraint and which is the prediction.
    public PinnedAxis pinned_axis;
    public double estimated_vmaf;      // 0.0 when not measured
    public bool   vmaf_measured;       // false until the quality solver lands

    /** Delivery constraint is active — favour cheap decode and compatibility. */
    public bool   fast_decode;
    /**
     * Source bit depth, needed downstream because TOUT (grain_score) is
     * measured at the source's native depth and is not comparable across
     * depths. See grain_warranted.
     */
    public int    source_bit_depth;
}

/**
 * User assertion about what the content actually is.
 *
 * This exists because the classifier provably cannot identify animation.
 * Phase 0 tested edge density, saturation level, saturation variance, motion,
 * repeated-frame ratio and histogram entropy against a 16-file corpus: every
 * one of them puts anime on top of slow, flat live-action.  Auto-detection of
 * that class is not currently possible, so the override is the reliable path
 * rather than a convenience.
 */
public enum ContentOverride {
    AUTO,
    LIVE_ACTION,
    ANIME,
    SCREENCAST;

    public string to_label () {
        switch (this) {
            case LIVE_ACTION: return "Live-action";
            case ANIME:       return "Anime / Animation";
            case SCREENCAST:  return "Screencast / Static";
            default:          return "Auto-detect";
        }
    }
}

/**
 * Optional context from the caller (GeneralTab settings, etc.) that affects
 * calibration accuracy. All fields have safe defaults.
 */
public struct OptimizationContext {
    /** User's content assertion; AUTO leaves the classifier's verdict alone. */
    public ContentOverride content_override;

    /**
     * Delivery constraint: the output is for streaming or playback on modest
     * hardware, so decode cost and compatibility matter more than squeezing
     * the last few percent of efficiency.
     *
     * Deliberately a composable toggle rather than a list entry alongside the
     * quality intents: "Streaming + High" is a coherent request, and a
     * mutually-exclusive list makes it unexpressible.
     */
    public bool optimize_for_delivery;

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

    /** True when the user requested preserving every source audio track. */
    public bool preserve_all_audio_tracks_requested;

    /** Effective output frame rate; 0 means use the probed source rate. */
    public double output_fps;

    /** Playback-rate multiplier applied by the video speed filter.
     *  1.0 is normal speed; 0 means use the safe default of 1.0. */
    public double video_speed_multiplier;

    /** Output container format (e.g. "mkv", "mp4", "webm").
     *  Used for audio stream-copy compatibility checks.
     *  Empty string means infer from codec (conservative fallback). */
    public string output_container;
}

// ════════════════════════════════════════════════════════════════════════════
// Internal data carriers
// ════════════════════════════════════════════════════════════════════════════

public struct SmartOptimizerVideoInfo {
    public double duration;
    public int    width;
    public int    height;
    public double fps;
    public int    audio_bitrate_kbps;       // first audio stream bitrate
    public bool   audio_bitrate_estimated;   // true when first stream fell back to a default
    public string audio_codec;               // first audio stream codec
    public int    total_audio_bitrate_kbps;  // sum across all source audio streams
    public bool   total_audio_bitrate_estimated; // true when any stream used a fallback bitrate
    public AudioSourceInfo source_audio;     // first audio stream
    public AudioSourceInfo[] all_source_audio; // every source audio stream
    public int64  file_size_bytes;            // source file size from format.size or stat
    public int    source_bit_depth;           // 8, 10, 12… (0 = unknown)
    public string color_transfer;             // "smpte2084", "arib-std-b67", ""
    public string color_primaries;            // "bt2020", "bt709", ""
}

public struct ContentProfile {
    public double      edge_mean;
    public double      edge_stddev;
    public double      blur_mean;       // softness input; never an artifact/degradation gate
    public double      blur_stddev;
    public double      saturation_mean;
    public double      saturation_stddev;
    public double      temporal_diff_mean;   // YDIF average across frames
    public double      temporal_diff_stddev;
    public int         temporal_samples;     // decoded-frame samples behind temporal metrics
    public double      static_frame_ratio;   // fraction with near-zero YDIF
    public double      cuts_per_minute;      // decoded scene cuts, excluding sample joins
    public double      noise_mean;           // TOUT (temporal outlier fraction) average — grain/noise proxy
    public double      noise_stddev;
    public ContentType content_type;
    public double      type_confidence;
    /**
     * siti SI — spatial detail; 0 when unmeasured.
     *
     * Deliberately NOT accompanied by siti's TI. SI is a per-frame measure, so
     * it can be sampled on decimated frames for the same mean at a sixth of
     * the cost; TI is frame-to-frame and would measure across the decimation
     * gaps instead. signalstats' YDIF already provides temporal activity on
     * every frame for free, so it is used for that instead.
     */
    public double      spatial_info;
    public double      banding_risk;         // 0.0–1.0 composite score
    public double      low_luma_ratio;       // fraction of frames with high dark pixel count
    public double      dark_scene_ratio;     // fraction of frames where avg luma < 60
}

public struct BitDepthDecision {
    public string pix_fmt;    // "yuv420p10le", "yuv420p", or ""
    public bool   is_10bit;
    public string reason;     // for notes
}

// ════════════════════════════════════════════════════════════════════════════
// SmartOptimizerLogic
// ════════════════════════════════════════════════════════════════════════════

namespace SmartOptimizerLogic {

    // ── Tuning constants ─────────────────────────────────────────────────────

    // Analysis segment config
    public const int    MIN_SEGMENTS       = 2;        // absolute minimum
    public const int    ADAPTIVE_MAX_SEGMENTS = 16;    // cap when content variance is high
    public const int    ADAPTIVE_CALIBRATION_BASE_MAX_POINTS = 6; // 4 base + up to 2 follow-up CRFs

    // Minimum sample coverage target (15%). The segment count is computed
    // from this so that short and medium videos get enough coverage to
    // avoid the "representative samples" problem where 4 fixed segments
    // miss entire complexity regions.
    //   278s video → ceil(278 × 0.15 / 8) = 6 segments (17% coverage)
    //   600s video → ceil(600 × 0.15 / 8) = 12 segments (16% coverage)
    // Hard caps still apply per duration tier to bound encode time.
    public const double MIN_COVERAGE_TARGET = 0.15;
    public const int    BASE_MAX_SEGMENTS   = 6;       // cap for videos < 10 min
    public const int    LONG_MAX_SEGMENTS   = 10;      // cap for videos 10–45 min
    public const int    VLONG_MAX_SEGMENTS  = 14;      // cap for videos > 45 min

    public const double LONG_VIDEO_THRESHOLD  = 600.0; // 10 minutes
    public const double VLONG_VIDEO_THRESHOLD = 2700.0; // 45 minutes
    public const double SEGMENT_SPREAD    = 0.15;      // start at 15%, end at 85%
    // Coefficient of variation threshold for adaptive expansion.
    // If temporal_diff stddev/mean exceeds this, content varies significantly
    // across the video and more samples improve prediction accuracy.
    public const double ADAPTIVE_CV_THRESHOLD = 0.60;
    public const int    ADAPTIVE_CALIBRATION_EDGE_MARGIN = 1;

    // Grain-synthesis gate thresholds on the measured grain signal (TOUT, the
    // signalstats temporal-outlier fraction). Below LOW → source is clean, do
    // NOT synthesize grain (overrides the content-category heuristic — this is
    // what stops clean 4K footage from getting pointless film-grain synthesis).
    // Above HIGH → clearly grainy, synthesize regardless of category. Between
    // the two the signal is ambiguous and we defer to the category heuristic,
    // so the change is regression-safe.
    //
    // PROVISIONAL — calibrated only against clean/digital sources so far
    // (observed 0.0002–0.0014) plus synthetic grain (~0.003). Re-tune against a
    // genuinely grainy film source using the "Grain/noise (TOUT)" value printed
    // in the Smart Optimizer log: set LOW just above your clean maximum and
    // HIGH at/below the grainy reading.
    // ⚠️ 8-BIT ONLY. TOUT is a threshold-derived fraction measured at the
    // source's native depth, and it does NOT rescale linearly with depth: the
    // same 10-bit film reads 0.00194 native and 0.00018 once converted to
    // 8-bit, a 10.8x spread where amplitudes move by exactly 4x. Neither
    // figure can be corrected into the other, so these thresholds are only
    // meaningful for 8-bit sources and a 10-bit source will read as far
    // grainier than it is. grain_warranted() therefore ignores the
    // measurement entirely above 8-bit and defers to the content category.
    public const double GRAIN_SYNTH_LOW  = 0.0015;
    public const double GRAIN_SYNTH_HIGH = 0.0040;

    // If the required video bitrate would fall below this threshold it is
    // physically impossible to produce acceptable-quality output.
    public const int MIN_VIABLE_VIDEO_KBPS = 80;

    public const double BITS_PER_BYTE = 8.0;
    public const double BITS_PER_KILOBIT = 1000.0;
    public const double BYTES_PER_KIB = 1024.0;
    public const double KIB_PER_MIB = 1024.0;

    // Container overhead model: fixed header/metadata base plus per-frame
    // and per-audio-packet index/framing costs.  MP4 keeps per-sample
    // tables in the moov atom (~12 B/frame across stsz/ctts/stco/stss);
    // Matroska/WebM pays block headers plus cue entries (~7 B/frame).
    // Overhead therefore scales with duration and frame count — a 2-hour
    // MP4's moov alone is several MB, which fixed per-tier constants
    // missed entirely.
    public const double CONTAINER_BASE_KIB_MP4 = 30.0;
    public const double CONTAINER_BASE_KIB_MKV = 40.0;
    public const double CONTAINER_VIDEO_BYTES_PER_FRAME_MP4  = 12.0;
    public const double CONTAINER_VIDEO_BYTES_PER_FRAME_MKV  = 7.0;
    public const double CONTAINER_AUDIO_BYTES_PER_PACKET_MP4 = 8.0;
    public const double CONTAINER_AUDIO_BYTES_PER_PACKET_MKV = 6.0;

    // ── Stage result carriers ────────────────────────────────────────────────

    /** Effective encode window after applying trim/effective-duration context. */
    public class TrimWindow {
        public double trim_start;
        public double trim_end;
        public double encode_duration;
        public bool   trim_active;
        public double sample_segment_duration;
    }

    /** Audio strategy and budget; measurement updates the mutable fields. */
    public class AudioPlan {
        public int    tier_audio_kbps;
        public bool   preserve_all_effective;
        public bool   use_stream_copy;
        public string probed_first_codec = "";
        public int    probed_first_kbps;
        public bool   probed_first_estimated;
        public int    actual_source_track_count;
        public int    effective_track_count;
        /**
         * What the encoder is told to target (-b:a), per stream.
         *
         * Distinct from per_stream_kbps, which is what the output is expected
         * to WEIGH.  They start equal and diverge once measurement lands: a
         * VBR encoder handed 192k routinely spends 187, and reserving 192 for
         * it would overstate the file.  Reserving the measurement while
         * encoding at the target is correct; conflating the two is not, and
         * anything that hands a bitrate to ffmpeg must use this field.
         *
         * Always a rung of AudioCodecOptions.bitrate_values (or 0 when audio
         * is stripped or stream-copied), because that is all the UI can
         * express — see snap_audio_kbps_down.
         */
        public int    encode_target_kbps;
        public int    per_stream_kbps;
        public bool   per_stream_estimated;
        public int    total_budget_kbps;
        public AudioSourceInfo[] selected_sources = {};
        public bool   audio_measured;
        public int    measured_kbps;          // effective value after the silence floor
        public int    measured_raw_kbps;      // raw encoder measurement
        public bool   measured_floored;       // true when the silence floor kicked in
        /** Tier budget before the source cap; 0 when the cap did not bind. */
        public int    uncapped_tier_kbps;
        /** Source bitrate the cap was taken from; 0 when it did not bind. */
        public int    cap_source_kbps;
    }

    /** Suggestion to downscale when bits-per-pixel is too low for quality. */
    public class DownscaleAdvisory {
        public double bpp;
        public double threshold;
        public int    new_width;
        public int    new_height;
        public double scale_factor;
    }

    /** Size budget breakdown; audio measurement updates the fields. */
    public class SizeBudget {
        public double target_total_kib;
        public double container_overhead_kib;
        public double audio_kib;
        public double video_target_kib;
        public int    available_video_kbps;
    }

    /** Fitted CRF↔size model and the solved CRF. */
    public class CalibrationModel {
        public int[]    cal_crfs = {};
        public double[] cal_sizes = {};
        public double   qa;
        public double   qb;
        public double   qc;
        public bool     degenerate;
        public double   cal_mid;
        public int      crf_min;
        public int      crf_max;
        public int      predicted_crf;
        public bool     crf_at_max;
        public bool     crf_at_min;
        public bool     adaptive_refined;
        public int      adaptive_points_added;
        public int      cached_points;    // samples reused from the persistent cache
    }

    /** Result of the verification encode(s) against the model. */
    public class VerificationOutcome {
        public bool   done;
        public bool   reused;
        public bool   reverified;
        public int    verified_crf;
        public double model_kib;
        public double actual_kib;
        public double reverify_actual_kib;
        public double correction = 1.0;   // ratio: actual / model
    }

    /** Confidence in the CRF size estimate, with its component factors. */
    public class ConfidenceAssessment {
        public double confidence = 1.0;
        public double sample_coverage;
        public double fit_rmse;
        public double fit_quality_factor = 1.0;
        public int    source_video_kbps;
        public double source_total_kbps;
    }

    /** Two-pass recommendation and the target-band bookkeeping behind it. */
    public class TwoPassPolicy {
        public bool   recommend_two_pass;
        public int    target_video_kbps;
        public bool   strict_targeting;
        public double target_tolerance_kib;
        public bool   within_target_band;
        public bool   crf_overshoots;
        public bool   target_is_size_reduction;
        public double source_size_mb;
        public double comparison_source_size_mb;
        public double reduction_confidence = 1.0;
        public bool   is_impossible;
    }

    // ── Unit conversions ─────────────────────────────────────────────────────

    public double mib_to_kib (double mib) {
        return mib * KIB_PER_MIB;
    }

    public double kib_from_bytes (int64 bytes) {
        return (double) bytes / BYTES_PER_KIB;
    }

    public double mib_from_bytes (int64 bytes) {
        return kib_from_bytes (bytes) / KIB_PER_MIB;
    }

    // ── Target size bounds and match-source targeting ────────────────────────

    // Bounds shared by every Target Size control — the per-tab spin buttons,
    // the stored preference, and the Preferences dialog.  The ceiling is high
    // enough that "Match Source Size" can still reach multi-gigabyte sources.
    public const int TARGET_MB_MIN = 1;
    public const int TARGET_MB_MAX = 16384;

    public int clamp_target_mb (int value) {
        return value.clamp (TARGET_MB_MIN, TARGET_MB_MAX);
    }

    /**
     * Whole-MiB target that matches a source file's size.
     *
     * The optimizer only accepts integer MB targets, so the source size is
     * rounded to the nearest whole MiB (9.3 MB → 9, 9.7 MB → 10) and clamped
     * into the range the Target Size controls accept.
     */
    public int match_source_target_mb (int64 file_size_bytes) {
        if (file_size_bytes <= 0)
            return TARGET_MB_MIN;
        return clamp_target_mb ((int) Math.round (mib_from_bytes (file_size_bytes)));
    }

    /**
     * Match-source target scaled to a trimmed window.
     *
     * A trimmed segment carries only part of the source, so matching the full
     * source size would effectively remove the size constraint.  Scaling by
     * duration preserves the source's bytes-per-second density.  Falls back to
     * the unscaled target when either duration is unknown.
     */
    public int match_source_target_mb_for_window (int64 file_size_bytes,
                                                  double window_duration,
                                                  double total_duration) {
        if (file_size_bytes <= 0)
            return TARGET_MB_MIN;
        if (window_duration <= 0.0 || total_duration <= 0.0)
            return match_source_target_mb (file_size_bytes);

        double fraction = double.min (1.0, window_duration / total_duration);
        return clamp_target_mb (
            (int) Math.round (mib_from_bytes (file_size_bytes) * fraction));
    }

    public double kib_from_kbps_for_duration (double kbps, double duration_seconds) {
        if (duration_seconds <= 0.0)
            return 0.0;
        return kbps * BITS_PER_KILOBIT * duration_seconds / (BITS_PER_BYTE * BYTES_PER_KIB);
    }

    public double mib_from_kbps_for_duration (double kbps, double duration_seconds) {
        return kib_from_kbps_for_duration (kbps, duration_seconds) / KIB_PER_MIB;
    }

    public double kbps_from_kib_for_duration (double kib, double duration_seconds) {
        if (duration_seconds <= 0.0)
            return 0.0;
        return kib * BYTES_PER_KIB * BITS_PER_BYTE / (duration_seconds * BITS_PER_KILOBIT);
    }

    public double kbps_from_bytes_for_duration (int64 bytes, double duration_seconds) {
        if (duration_seconds <= 0.0)
            return 0.0;
        return (double) bytes * BITS_PER_BYTE / (duration_seconds * BITS_PER_KILOBIT);
    }

    public double seconds_for_kib_at_kbps (double kib, int kbps) {
        if (kbps <= 0)
            return 0.0;
        return kib * BYTES_PER_KIB * BITS_PER_BYTE / ((double) kbps * BITS_PER_KILOBIT);
    }

    // ── Trim window ──────────────────────────────────────────────────────────

    /**
     * Resolve the effective encode window from the caller's trim context.
     * Invalid or inverted windows fall back to the full probed duration.
     */
    public TrimWindow resolve_trim_window (
        OptimizationContext ctx,
        double              probed_duration,
        double              default_segment_duration
    ) {
        var tw = new TrimWindow ();
        tw.trim_start = (ctx.trim_start_seconds > 0)
            ? double.min (ctx.trim_start_seconds, probed_duration)
            : 0.0;
        tw.trim_end = (ctx.trim_end_seconds > 0)
            ? double.min (ctx.trim_end_seconds, probed_duration)
            : probed_duration;

        if (ctx.effective_duration > 0) {
            tw.trim_end = double.min (tw.trim_end, tw.trim_start + ctx.effective_duration);
        }
        if (tw.trim_end <= tw.trim_start) {
            tw.trim_start = 0.0;
            tw.trim_end = probed_duration;
        }

        tw.trim_active = tw.trim_start > 0.0 || tw.trim_end < probed_duration;
        tw.encode_duration = tw.trim_end - tw.trim_start;
        if (tw.encode_duration <= 0) {
            tw.encode_duration = (ctx.effective_duration > 0)
                ? ctx.effective_duration
                : probed_duration;
            tw.trim_start = 0.0;
            tw.trim_end = double.min (tw.encode_duration, probed_duration);
            tw.trim_active = false;
        }
        tw.sample_segment_duration = double.min (default_segment_duration, tw.encode_duration);
        return tw;
    }

    // ── Container & audio planning ───────────────────────────────────────────

    /**
     * Default container for a codec when the caller doesn't provide one.
     * VP9/SVT-AV1 → webm, x264/x265 → mp4.
     */
    public string codec_default_container (string codec) {
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
    public string resolve_effective_container (
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

    /**
     * Recommended audio bitrate for budget calculation.
     * The codec preset functions will configure actual audio to match.
     */
    public int tier_audio_kbps (SizeTier tier) {
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
     * Snap a bitrate down onto the UI's bitrate ladder.
     *
     * The optimizer's budget is arithmetic and lands anywhere; the audio
     * bitrate dropdown only offers fixed rungs.  Anything the optimizer
     * reserves in its size estimate has to be a value the applier can
     * actually select, or the estimate describes an encode that never runs.
     * Rounds DOWN so snapping can never push the encode over a budget that
     * was computed to fit; below the lowest rung it returns that rung, since
     * there is nothing cheaper to pick.
     */
    public int snap_audio_kbps_down (int kbps) {
        int[] rungs = AudioCodecOptions.bitrate_values ();
        if (rungs.length == 0 || kbps <= 0)
            return 0;

        int chosen = rungs[0];
        foreach (int rung in rungs) {
            if (rung <= kbps)
                chosen = rung;
        }
        return chosen;
    }

    /** Snap a bitrate up onto the ladder, clamped to the highest rung. */
    public int snap_audio_kbps_up (int kbps) {
        int[] rungs = AudioCodecOptions.bitrate_values ();
        if (rungs.length == 0 || kbps <= 0)
            return 0;

        foreach (int rung in rungs) {
            if (rung >= kbps)
                return rung;
        }
        return rungs[rungs.length - 1];
    }

    /**
     * Cap a tier's re-encode budget at what the source audio actually carries.
     *
     * The tier ladder assumes the budget is the binding constraint, which is
     * true of video and much weaker for audio: bits spent above the source
     * rate go to reproducing the FIRST encoder's output more exactly, not to
     * recovering anything it discarded.  Measured on a 96 kbps AAC track
     * (25 s, stereo, 48 kHz), transcoded to Opus and differenced against the
     * decoded source:
     *
     *     Opus 128k   residual -53.0 dBFS    395 KB
     *     Opus 192k   residual -55.4 dBFS    592 KB
     *     Opus 256k   residual -57.0 dBFS    793 KB
     *     Opus 320k   residual -58.1 dBFS    991 KB
     *
     * So the returns are real but steeply diminishing — 2.5x the bytes for
     * 5 dB of waveform convergence, on a signal the AAC stage had already
     * lowpassed to about 14 kHz (energy above it sits 38 dB under full band).
     * Waveform residual also flatters high bitrates: Opus discards phase and
     * fine waveform detail deliberately, so this metric understates how close
     * 128k already is perceptually.
     *
     * Against that, the cost is not marginal.  On the clip above the XLARGE
     * rung spent 963 KiB on audio inside a 2461 KiB ceiling — 39% of the
     * file — and the video solver gave up its VMAF 97 target to fit around
     * it, landing at 96.  Trading a measured 5 dB of audio waveform accuracy
     * for a visible quality target is the wrong side of that bargain.
     *
     * The cap is the lowest rung at or above the source rate, not the source
     * rate itself: lossy-to-lossy transcoding needs some headroom to avoid
     * compounding generational loss, and the ladder is what the applier can
     * select anyway.  So a 96 kbps source caps at 128, and a 256 kbps source
     * caps at 256.  Lossless and high-bitrate sources sit above every rung
     * the tier would have chosen, so the cap simply never binds.
     *
     * Only ever lowers the budget — a source below the tier does not entitle
     * it to more.  Skipped when the source bitrate was guessed rather than
     * probed (ffprobe reported no bit_rate), since capping on a guess can
     * silently degrade audio the guess was wrong about.
     *
     * With multiple tracks the cap follows the LOUDEST demand — the highest
     * source bitrate in the set — because one budget is applied to every
     * output track, and sizing it to the quietest would under-serve the rest.
     */
    public int cap_audio_kbps_to_source (int tier_kbps, AudioSourceInfo[] sources) {
        if (tier_kbps <= 0 || sources.length == 0)
            return tier_kbps;

        int highest_source_kbps = 0;
        foreach (unowned AudioSourceInfo source in sources) {
            // One estimated stream poisons the whole set: the cap is applied
            // per-stream, so a guess anywhere can under-serve a real track.
            if (source.bitrate_estimated || source.bitrate_kbps <= 0)
                return tier_kbps;
            highest_source_kbps = int.max (highest_source_kbps, source.bitrate_kbps);
        }

        if (highest_source_kbps <= 0)
            return tier_kbps;

        return int.min (tier_kbps, snap_audio_kbps_up (highest_source_kbps));
    }

    public int default_audio_bitrate_kbps_for_codec (string codec_name) {
        switch (codec_name.down ()) {
            case "opus":
                return 96;
            case "vorbis":
                return 112;
            default:
                // AAC, MP3, AC3, or unknown — conservative estimate
                return 128;
        }
    }

    public AudioSourceInfo[] select_budget_audio_sources (
        SmartOptimizerVideoInfo info,
        bool preserve_all_audio_tracks_effective
    ) {
        if (preserve_all_audio_tracks_effective && info.all_source_audio.length > 0)
            return info.all_source_audio;

        if (info.source_audio.codec_name.length > 0)
            return { info.source_audio };

        if (info.all_source_audio.length > 0)
            return { info.all_source_audio[0] };

        return {};
    }

    public double effective_audio_stream_duration (
        AudioSourceInfo source,
        double encode_duration
    ) {
        if (encode_duration <= 0.0)
            return 0.0;

        double stream_duration = source.duration > 0.0 ? source.duration : encode_duration;
        return double.min (stream_duration, encode_duration);
    }

    public double compute_reserved_audio_kib (
        AudioSourceInfo[] selected_audio_sources,
        bool use_source_stream_bitrates,
        int per_stream_bitrate_kbps,
        int fallback_total_audio_budget_kbps,
        double encode_duration
    ) {
        if (encode_duration <= 0.0)
            return 0.0;

        if (selected_audio_sources.length == 0) {
            return (fallback_total_audio_budget_kbps > 0)
                ? kib_from_kbps_for_duration ((double) fallback_total_audio_budget_kbps, encode_duration)
                : 0.0;
        }

        double total_kib = 0.0;
        foreach (unowned AudioSourceInfo source in selected_audio_sources) {
            int stream_bitrate_kbps = use_source_stream_bitrates
                ? source.bitrate_kbps
                : per_stream_bitrate_kbps;
            if (stream_bitrate_kbps <= 0)
                continue;

            total_kib += kib_from_kbps_for_duration (
                (double) stream_bitrate_kbps,
                effective_audio_stream_duration (source, encode_duration));
        }

        return total_kib;
    }

    /**
     * Decide the audio strategy for the encode: strip / explicit override /
     * stream copy (when container-compatible and within budget) / tier
     * re-encode budget.  Pure — never mutates @info.
     */
    public AudioPlan plan_audio (
        SmartOptimizerVideoInfo info,
        OptimizationContext     ctx,
        SizeTier                tier,
        string                  resolved_container
    ) {
        var plan = new AudioPlan ();
        plan.tier_audio_kbps = tier_audio_kbps (tier);
        plan.preserve_all_effective =
            ctx.preserve_all_audio_tracks_requested && tier >= SizeTier.MEDIUM;
        plan.use_stream_copy = false;

        // Probed audio, first-stream and aggregate views — needed to decide
        // whether multi-track preservation is viable and its budget cost.
        plan.probed_first_codec     = info.audio_codec;
        plan.probed_first_kbps      = info.audio_bitrate_kbps;
        plan.probed_first_estimated = info.audio_bitrate_estimated;
        int probed_total_audio_kbps = plan.preserve_all_effective
            ? info.total_audio_bitrate_kbps
            : plan.probed_first_kbps;
        bool probed_total_audio_estimated = plan.preserve_all_effective
            ? info.total_audio_bitrate_estimated
            : plan.probed_first_estimated;
        plan.actual_source_track_count = (info.all_source_audio.length > 0)
            ? info.all_source_audio.length
            : (info.audio_codec.length > 0 ? 1 : 0);
        plan.effective_track_count = plan.preserve_all_effective
            ? plan.actual_source_track_count
            : (plan.actual_source_track_count > 0 ? 1 : 0);
        plan.total_budget_kbps = 0;
        plan.selected_sources = select_budget_audio_sources (
            info, plan.preserve_all_effective);
        plan.per_stream_kbps      = info.audio_bitrate_kbps;
        plan.per_stream_estimated = info.audio_bitrate_estimated;

        string incompatible_audio_codec = "";
        bool audio_copy_compatible = AudioCompatibilityLogic.container_supports_audio_copy_for_selection (
            resolved_container,
            info.source_audio,
            info.all_source_audio,
            plan.preserve_all_effective,
            out incompatible_audio_codec
        );

        if (ctx.strip_audio) {
            // No audio track — entire budget goes to video
            plan.per_stream_kbps       = 0;
            plan.per_stream_estimated  = false;
            plan.effective_track_count = 0;
            plan.encode_target_kbps    = 0;
        } else if (ctx.audio_bitrate_kbps_override > 0) {
            // Overrides are per-stream FFmpeg rates; multiply by track count
            // when preserving multiple tracks.
            plan.per_stream_kbps       = ctx.audio_bitrate_kbps_override;
            plan.per_stream_estimated  = false;
            plan.effective_track_count = int.max (plan.effective_track_count, 1);
            plan.total_budget_kbps     = ctx.audio_bitrate_kbps_override * plan.effective_track_count;
            // An explicit override is the caller's number, not a budget to
            // negotiate — but it still has to be selectable in the dropdown.
            plan.encode_target_kbps    = snap_audio_kbps_down (
                ctx.audio_bitrate_kbps_override);
        }

        // Determine the actual audio budget:
        //   1. If the caller stripped audio or set an explicit override, honour that.
        //   2. Otherwise, try to stream-copy the selected audio set when it is
        //      container-compatible. For Tiny/Small this remains first-track-only
        //      and must fit the tier budget; for Medium+ keep-all mode we reserve
        //      the exact combined source bitrate and let feasibility checks decide.
        //   3. Otherwise, use the tier-based per-stream re-encode budget.
        if (!ctx.strip_audio && ctx.audio_bitrate_kbps_override <= 0
                && plan.effective_track_count > 0) {
            bool can_stream_copy_single = audio_copy_compatible
                && !ctx.audio_requires_reencode
                && plan.probed_first_kbps > 0
                && !plan.probed_first_estimated
                && plan.probed_first_kbps <= plan.tier_audio_kbps;
            bool can_stream_copy_multi = plan.preserve_all_effective
                && audio_copy_compatible
                && !ctx.audio_requires_reencode
                && probed_total_audio_kbps > 0
                && !probed_total_audio_estimated;

            if (can_stream_copy_multi || can_stream_copy_single) {
                plan.use_stream_copy      = true;
                plan.per_stream_kbps      = plan.probed_first_kbps;
                plan.per_stream_estimated = plan.probed_first_estimated;
                plan.total_budget_kbps    = plan.preserve_all_effective
                    ? probed_total_audio_kbps
                    : plan.probed_first_kbps;
                // Copying re-uses the source bitstream; there is no target.
                plan.encode_target_kbps   = 0;
            } else {
                // Re-encoding. The tier says what we can afford; the source
                // says what is worth spending. Take the lower.
                int budget_kbps = cap_audio_kbps_to_source (
                    plan.tier_audio_kbps, plan.selected_sources);
                if (budget_kbps != plan.tier_audio_kbps) {
                    plan.uncapped_tier_kbps = plan.tier_audio_kbps;
                    foreach (unowned AudioSourceInfo source in plan.selected_sources) {
                        plan.cap_source_kbps = int.max (
                            plan.cap_source_kbps, source.bitrate_kbps);
                    }
                }
                plan.encode_target_kbps   = budget_kbps;
                plan.per_stream_kbps      = budget_kbps;
                plan.per_stream_estimated = false;
                plan.total_budget_kbps    = budget_kbps * plan.effective_track_count;
            }
        }

        return plan;
    }

    // A measured audio bitrate below this fraction of the tier budget is
    // treated as sampled silence: Opus/AAC VBR collapse quiet segments to
    // a few kbps, but a full-length track rarely stays that low.
    public const double AUDIO_MEASUREMENT_FLOOR_FRACTION = 0.25;

    /**
     * Guard against silence-skewed audio measurements: floors the measured
     * bitrate at AUDIO_MEASUREMENT_FLOOR_FRACTION of the tier budget so
     * near-silent calibration windows can't starve the audio reserve on
     * files with normal audio elsewhere.
     */
    public int floor_measured_audio_kbps (int measured_kbps, int tier_audio_kbps) {
        int floor_kbps = (int) Math.round (
            tier_audio_kbps * AUDIO_MEASUREMENT_FLOOR_FRACTION);
        return int.max (measured_kbps, floor_kbps);
    }

    /**
     * Typical audio packets (container blocks/samples) per second by codec,
     * derived from each codec's frame size at common sample rates.
     */
    public double audio_packets_per_second (string codec_name) {
        switch (codec_name.down ()) {
            case "opus":   return 50.0;   // 20 ms frames
            case "aac":    return 47.0;   // 1024 samples @ 48 kHz
            case "vorbis": return 45.0;
            case "mp3":    return 38.0;   // 1152 samples @ 44.1 kHz
            case "ac3":
            case "eac3":   return 31.0;   // 1536 samples @ 48 kHz
            case "flac":   return 10.0;   // 4096-sample blocks
            default:       return 45.0;
        }
    }

    /**
     * Estimated container overhead (headers, index, seek tables) in KiB,
     * scaled by encode duration, frame rate, and audio packet count.
     * Subtracted from the video budget so the final file actually fits.
     */
    public double container_overhead_kib_estimate (
        string            resolved_container,
        double            encode_duration,
        double            fps,
        AudioSourceInfo[] selected_audio_sources,
        bool              use_stream_copy_audio,
        int               audio_track_count
    ) {
        bool is_mp4 = (resolved_container == "mp4"
                    || resolved_container == "mov"
                    || resolved_container == "m4v");
        double base_kib  = is_mp4 ? CONTAINER_BASE_KIB_MP4
                                  : CONTAINER_BASE_KIB_MKV;
        double video_bpf = is_mp4 ? CONTAINER_VIDEO_BYTES_PER_FRAME_MP4
                                  : CONTAINER_VIDEO_BYTES_PER_FRAME_MKV;
        double audio_bpp = is_mp4 ? CONTAINER_AUDIO_BYTES_PER_PACKET_MP4
                                  : CONTAINER_AUDIO_BYTES_PER_PACKET_MKV;

        double effective_fps = (fps > 0) ? fps : 30.0;
        double overhead_bytes = effective_fps * encode_duration * video_bpf;

        if (use_stream_copy_audio && selected_audio_sources.length > 0) {
            foreach (unowned AudioSourceInfo source in selected_audio_sources) {
                overhead_bytes += audio_packets_per_second (source.codec_name)
                    * effective_audio_stream_duration (source, encode_duration)
                    * audio_bpp;
            }
        } else if (audio_track_count > 0) {
            string target_codec = (resolved_container == "webm") ? "opus" : "aac";
            overhead_bytes += audio_packets_per_second (target_codec)
                * encode_duration * audio_bpp * audio_track_count;
        }

        return base_kib + overhead_bytes / BYTES_PER_KIB;
    }

    /**
     * Compute the full size budget: total target, container overhead,
     * reserved audio, and the video budget that remains.
     */
    public SizeBudget compute_size_budget (
        int       target_mb,
        string    resolved_container,
        double    encode_duration,
        double    fps,
        AudioPlan plan
    ) {
        var budget = new SizeBudget ();
        budget.target_total_kib = mib_to_kib ((double) target_mb);
        budget.container_overhead_kib = container_overhead_kib_estimate (
            resolved_container, encode_duration, fps,
            plan.selected_sources, plan.use_stream_copy,
            plan.effective_track_count);
        budget.audio_kib = compute_reserved_audio_kib (
            plan.selected_sources,
            plan.use_stream_copy,
            plan.per_stream_kbps,
            plan.total_budget_kbps,
            encode_duration);
        budget.video_target_kib = budget.target_total_kib
            - budget.audio_kib - budget.container_overhead_kib;
        budget.available_video_kbps = (int) kbps_from_kib_for_duration (
            budget.video_target_kib, encode_duration);
        return budget;
    }

    /**
     * User-facing message for a target below the minimum viable video
     * bitrate, with concrete trim/scale suggestions when the resolution
     * is known.
     */
    public string build_infeasibility_message (
        int    available_video_kbps,
        double video_target_kib,
        int    width,
        int    height
    ) {
        var msg = new StringBuilder ();
        msg.append ("Target is physically implausible for this video.\n\n");
        msg.append ("Available video bitrate: %d kbps\n".printf (available_video_kbps));
        msg.append ("Minimum for any recognisable quality: %d kbps\n\n"
            .printf (MIN_VIABLE_VIDEO_KBPS));

        // Suggest what duration or scale would be needed
        if (width > 0 && height > 0) {
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
                int new_w = ((int) (width  * scale_factor)) / 2 * 2;
                int new_h = ((int) (height * scale_factor)) / 2 * 2;
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
        return msg.str;
    }

    // ── Sample position selection ────────────────────────────────────────────

    public double[] pick_sample_positions (double duration, double segment_duration) {
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

    public double[] pick_sample_positions_in_window (
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
    public double[] pick_sample_positions_n (double duration, double segment_duration, int requested) {
        if (duration <= segment_duration * 2.0) {
            return { 0 };
        }
        int n = int.min (requested, (int) (duration / segment_duration));
        n = int.max (n, 2);

        return spread_positions (duration, n, segment_duration);
    }

    public double[] pick_sample_positions_n_in_window (
        double start,
        double duration,
        double segment_duration,
        int    requested
    ) {
        return offset_positions (
            pick_sample_positions_n (duration, segment_duration, requested), start);
    }

    public double[] spread_positions (double duration, int n, double segment_duration) {
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

    public double[] offset_positions (double[] positions, double start) {
        var shifted = new double[positions.length];
        for (int i = 0; i < positions.length; i++) {
            shifted[i] = positions[i] + start;
        }
        return shifted;
    }

    /**
     * Adaptive segment expansion: when motion variability (CV of YDIF)
     * is high, more calibration samples improve size prediction.
     * Returns the expanded segment count, or 0 when no expansion applies.
     */
    public int adaptive_expansion_count (
        ContentProfile profile,
        int            current_count,
        double         encode_duration,
        double         segment_duration
    ) {
        if (profile.temporal_diff_mean <= 0)
            return 0;
        double motion_cv = profile.temporal_diff_stddev / profile.temporal_diff_mean;
        if (motion_cv <= ADAPTIVE_CV_THRESHOLD || current_count >= ADAPTIVE_MAX_SEGMENTS)
            return 0;
        int expanded_count = int.min (
            ADAPTIVE_MAX_SEGMENTS,
            (int) (encode_duration / segment_duration));
        if (expanded_count <= current_count)
            return 0;
        // This is the DESIRED count driven by content variability alone;
        // budget_expanded_count() then trims it to what a live speed-probe
        // says the time budget can afford. The caller logs the final count.
        return expanded_count;
    }

    /**
     * Trim a desired expansion count to what the calibration time budget can
     * afford, using a live per-segment encode time measured by a speed-probe.
     *
     * Calibration runs @n_encodes probe encodes in parallel batches of
     * @parallelism, each batch encoding all segments; so the wall-time for a
     * given segment count is roughly:
     *
     *     ceil(n_encodes / parallelism)  ×  segments  ×  secs_per_segment
     *
     * We invert that to find the largest segment count whose estimated
     * wall-time stays under @budget_seconds, then clamp into
     * [base_count, hard_cap]. base_count is the floor — the base samples are
     * always encoded — and hard_cap is the absolute ceiling regardless of how
     * fast the machine is.
     *
     * Degenerate inputs (non-positive probe time or budget, parallelism < 1)
     * fall back to base_count: if we can't trust the measurement, don't expand.
     */
    public int budget_expanded_count (
        int    desired,
        int    base_count,
        double secs_per_segment,
        int    n_encodes,
        int    parallelism,
        double budget_seconds,
        int    hard_cap
    ) {
        if (secs_per_segment <= 0.0 || budget_seconds <= 0.0
            || parallelism < 1 || n_encodes < 1)
            return base_count.clamp (0, hard_cap);

        int waves = (n_encodes + parallelism - 1) / parallelism;  // ceil
        double wall_per_segment = (double) waves * secs_per_segment;
        int budget_segments = (int) Math.floor (budget_seconds / wall_per_segment);

        int allowed = int.min (desired, budget_segments);
        return allowed.clamp (base_count, hard_cap);
    }

    // ── Complexity-weighted extrapolation ────────────────────────────────────

    /**
     * Correction to the duration-based extrapolation: mean source bitrate
     * over the encode window divided by mean source bitrate over the
     * sampled ranges.  1.0 when the samples are representative.  Clamped
     * and damped (^0.7) because source bitrate correlates with output
     * complexity but not 1:1 — the source may be rate-capped or tuned
     * differently than our target encode.
     */
    public double compute_extrapolation_weight (
        double[] profile_kib_per_s,
        double[] positions,
        double   segment_duration,
        double   trim_start,
        double   trim_end
    ) {
        if (profile_kib_per_s.length == 0 || positions.length == 0)
            return 1.0;

        double window_kib = sum_profile_range (profile_kib_per_s, trim_start, trim_end);
        double window_dur = trim_end - trim_start;
        double sampled_kib = 0.0;
        double sampled_dur = 0.0;
        for (int i = 0; i < positions.length; i++) {
            double seg_start = positions[i];
            double seg_end = double.min (seg_start + segment_duration, trim_end);
            if (seg_end <= seg_start) continue;
            sampled_kib += sum_profile_range (profile_kib_per_s, seg_start, seg_end);
            sampled_dur += (seg_end - seg_start);
        }
        if (window_kib <= 0 || sampled_kib <= 0 || window_dur <= 0 || sampled_dur <= 0)
            return 1.0;

        double ratio = ((window_kib / window_dur) / (sampled_kib / sampled_dur))
            .clamp (0.4, 2.5);
        return Math.pow (ratio, 0.7);
    }

    /**
     * Sum profile KiB over [start, end), scaling partially covered
     * 1-second buckets by their overlap fraction.
     */
    public double sum_profile_range (double[] profile, double start, double end) {
        double total = 0.0;
        int first = int.max (0, (int) Math.floor (start));
        int last  = int.min (profile.length, (int) Math.ceil (end));
        for (int b = first; b < last; b++) {
            double overlap = double.min (end, (double) b + 1.0)
                - double.max (start, (double) b);
            if (overlap > 0)
                total += profile[b] * overlap;
        }
        return total;
    }

    // ── Content classification & banding ─────────────────────────────────────

    // ── Content classification thresholds ────────────────────────────────────
    //
    // CALIBRATED against a 16-file corpus (see docs/smart-optimizer-phase0-
    // findings.md).  The previous thresholds were written for an edge scale
    // spanning 5–35; the actual `edgedetect`→YAVG measurement spans 0.21–12.96,
    // which made the edge term contribute exactly 0.000 on 10 of 16 files,
    // rendered SCREENCAST unreachable (it required edge > 25.0), and made
    // ANIME arithmetically unreachable (its maximum achievable score equalled
    // the threshold it had to exceed).  Screencasts were consequently
    // misfiled as anime and 10/16 files collapsed to MIXED.
    //
    // Every value below is quoted against measured corpus readings so the next
    // person can see the margin they are working with.

    // Screencast: near-static frames carrying substantial UI/text edge content.
    //   corpus: screencast ydif 0.85 / edge 5.28
    //           next-lowest ydif is short-testvid0 at 1.95, but its edge is
    //           1.40 — the edge conjunct is what separates them, since the
    //           motion margin alone is thin.
    public const double SCREENCAST_MAX_MOTION = 2.0;
    public const double SCREENCAST_MIN_EDGE   = 3.0;

    // Preferred screencast test, used whenever `siti` produced a reading.
    //   corpus: screencast si 115.4, motion 0.85
    //           next-highest si is 101.8 (random-testvid3) but its motion is
    //           18.45, the corpus maximum — synthetic screen content is the
    //           only thing combining very high spatial detail with almost no
    //           motion.
    //           highest si among everything else: 74.2 (motion 11.64).
    // The si margin (115.4 vs 74.2) is far wider than the edge margin, where
    // the nearest confusable sits 0.05 from the motion threshold.
    public const double SCREENCAST_MIN_SI = 80.0;

    // Live-action: sustained real-world motion.
    //   corpus: lowest live/film ydif is 6.37 (tvshow); highest anime is 4.55.
    public const double LIVE_ACTION_MIN_MOTION = 6.0;

    // Animation: held frames, visible line work, and colour that swings
    // between shots.
    //
    // Calibrated against six verified animation sources spanning dark TV,
    // bright TV, cinematic film and a fast-cut opening. Within the band this
    // rule can actually reach (motion at or below LIVE_ACTION_MIN_MOTION):
    //
    //   anime      edge 1.36–2.67   satSD 3.03–8.59
    //   live       edge 1.40–4.80   satSD 0.49–7.27
    //
    // Edge alone does not separate them — widening the edge floor to catch the
    // darkest anime also admits a hazy aerial shot, a poolside phone video and
    // a muted live-action film. Saturation VARIANCE does: animation cuts
    // between strongly and differently coloured scenes, while the naturalistic
    // footage that lands in this band holds a consistent overall saturation.
    //
    // Measured over the corpus, adding the satSD floor takes recall from 3/6
    // to 4/6 while removing the one false positive, so it is strictly better
    // on both axes. (`blur` also separates — animation has no optical
    // defocus — but adds nothing once satSD is applied, so it is left out
    // rather than carried as redundant decoration.)
    //
    // The floor is the MIDPOINT of the measured gap, not a round number:
    // within the band this rule reaches, the highest non-animation satSD is
    // 2.47 (a live-action film) and the lowest animation satSD is 3.03. 2.75
    // sits 0.28 from each. The first version of this used 2.50, which cleared
    // the film by 0.03 — that was luck rather than calibration, and it only
    // became visible once the bit-depth normalisation put that 10-bit film on
    // the right scale.
    //
    // ⚠️ STILL INCOMPLETE. Two of six anime are missed, both high-motion: the
    // live-action rule claims them before this one is reached, and nothing
    // measurable here separates fast animation from fast live action. The
    // confidence cap stays for that reason, and the user content override
    // remains the reliable path.
    public const double ANIME_MAX_MOTION = 5.0;
    public const double ANIME_MIN_EDGE   = 1.3;
    public const double ANIME_MAX_EDGE   = 4.5;
    /** Colour must actually move between shots; see the note above. */
    public const double ANIME_MIN_SAT_STDDEV = 2.75;
    public const double ANIME_MAX_CONFIDENCE = 0.5;

    /**
     * Heuristic content classifier.
     *
     * Ordered most-confident rule first, because the classes differ wildly in
     * how well the available signals identify them:
     *
     *   SCREENCAST  — cleanly separable (near-zero motion + real edge content).
     *   LIVE_ACTION — cleanly separable at the high-motion end.
     *   ANIME       — weakly separable; see ANIME_* constants above.
     *   MIXED       — the honest answer for low-motion content we cannot place.
     *
     * MIXED is a legitimate verdict, not a failure. It damps preset
     * interpolation toward the tier baseline, which is the correct behaviour
     * when the content is genuinely ambiguous.
     */
    public void classify_content (ref ContentProfile p) {
        // 1. Screencast — static frames with UI/text structure.
        //
        // Prefer the siti test when a reading exists: `si` separates screen
        // content from everything else by a much wider margin than edge
        // density does, which does not separate it at all. Fall back to the
        // edge/motion pair when siti is unavailable (older ffmpeg, or a failed
        // analysis pass), so detection degrades rather than disappearing.
        bool siti_available = (p.spatial_info > 0.0);
        if (siti_available
                && p.spatial_info >= SCREENCAST_MIN_SI
                && p.temporal_diff_mean < SCREENCAST_MAX_MOTION) {
            p.content_type = ContentType.SCREENCAST;
            p.type_confidence = 0.9;
            return;
        }
        if (!siti_available
                && p.temporal_diff_mean < SCREENCAST_MAX_MOTION
                && p.edge_mean > SCREENCAST_MIN_EDGE) {
            p.content_type = ContentType.SCREENCAST;
            // Confidence grows as motion approaches zero; a perfectly static
            // capture is unmistakable, one near the boundary less so.
            p.type_confidence = (1.0 - p.temporal_diff_mean / SCREENCAST_MAX_MOTION)
                .clamp (0.5, 1.0);
            return;
        }

        // 2. Live-action — sustained real-world motion. Confidence ramps up
        //    over the band above the threshold and saturates well clear of it.
        if (p.temporal_diff_mean > LIVE_ACTION_MIN_MOTION) {
            p.content_type = ContentType.LIVE_ACTION;
            p.type_confidence =
                (0.6 + 0.4 * ((p.temporal_diff_mean - LIVE_ACTION_MIN_MOTION) / 6.0))
                .clamp (0.6, 1.0);
            return;
        }

        // 3. Animation — low motion with line-art-like edge density.
        //    Deliberately low confidence: see ANIME_* above.
        if (p.temporal_diff_mean < ANIME_MAX_MOTION
                && p.edge_mean >= ANIME_MIN_EDGE
                && p.edge_mean <= ANIME_MAX_EDGE
                && p.saturation_stddev >= ANIME_MIN_SAT_STDDEV) {
            p.content_type = ContentType.ANIME;
            p.type_confidence = ANIME_MAX_CONFIDENCE;
            return;
        }

        // 4. Everything else — low motion, no distinguishing structure.
        p.content_type = ContentType.MIXED;
        p.type_confidence = 0.5;
    }

    /**
     * Replace the classifier's verdict with the user's assertion.
     *
     * Confidence goes to 1.0 because the user told us — that is strictly
     * better evidence than any measurement available here, and it lets
     * choose_preset_index interpolate all the way to the content ideal instead
     * of hedging toward the tier baseline.
     */
    public void apply_content_override (
        ref ContentProfile p,
        ContentOverride    ov
    ) {
        switch (ov) {
            case ContentOverride.LIVE_ACTION:
                p.content_type = ContentType.LIVE_ACTION;
                p.type_confidence = 1.0;
                break;
            case ContentOverride.ANIME:
                p.content_type = ContentType.ANIME;
                p.type_confidence = 1.0;
                break;
            case ContentOverride.SCREENCAST:
                p.content_type = ContentType.SCREENCAST;
                p.type_confidence = 1.0;
                break;
            default:
                break;   // AUTO — leave the measurement alone
        }
    }

    /**
     * Banding / dark-scene metrics from per-frame YAVG and YLOW samples.
     */
    public void compute_banding_metrics (
        ref ContentProfile profile,
        double[] all_yavg,
        double[] all_ylow,
        int      width,
        int      height
    ) {
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
            double resolution_scale = (width > 0 && height > 0)
                ? (double) (width * height) / 100000.0
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
    }

    /**
     * Whether the measured grain signal warrants grain handling (AV1 film-grain
     * synthesis, or x265/x264 `--tune grain`). Decides on the *measurement*
     * when it's confident, and falls back to the content-category heuristic
     * (live-action / mixed) only in the ambiguous middle band — so a clean
     * source is never grain-synthesized just because it classified as mixed,
     * and a grainy source gets grain even if the category was uncertain.
     *
     * This is only the grain-signal decision; callers apply their own tier
     * gate (e.g. SVT-AV1 at MEDIUM+, x265 at LARGE+).
     */
    public bool grain_warranted (double grain_score, ContentType content_type,
                                 int source_bit_depth = 8) {
        bool category_says_grain = (content_type == ContentType.LIVE_ACTION
            || content_type == ContentType.MIXED);

        // Above 8-bit the measurement is on a scale these thresholds were never
        // calibrated for, and it cannot be converted onto one. Trusting it
        // would call every 10-bit source grainy. Defer to the category instead
        // of acting on a number known to be wrong.
        if (source_bit_depth > 8)
            return category_says_grain;

        if (grain_score <= 0.0)                 // no measurement → category heuristic
            return category_says_grain;
        if (grain_score >= GRAIN_SYNTH_HIGH)    // clearly grainy
            return true;
        if (grain_score <= GRAIN_SYNTH_LOW)     // clearly clean
            return false;
        return category_says_grain;             // ambiguous → category heuristic
    }

    /**
     * Rescale a signalstats amplitude to its 8-bit equivalent.
     *
     * signalstats reports in the source's native range, so a 10-bit source
     * yields ~4x the values of identical content at 8-bit. Every threshold in
     * the classifier, the grain gate and the banding metrics compares these
     * figures ACROSS sources, so without this a 10-bit input reads as four
     * times the motion it actually has — which is exactly what happened: two
     * corpus films measured YDIF 13.83 and 11.71 and were classified as
     * high-motion live action, when their true motion is 3.46 and 2.93.
     *
     * Applies to amplitude-like metrics only: YDIF, YLOW, SATAVG and the
     * spread derived from it. NOT to:
     *   - edgedetect's YAVG, which normalises its own output (measured
     *     identical at both depths), and
     *   - TOUT, which is a threshold-derived fraction whose depth response is
     *     10.8x rather than 4x — it does not rescale linearly, and is left
     *     native. See GRAIN_SYNTH_LOW/HIGH for what that means for grain.
     */
    public double normalise_amplitude_for_depth (double value, int source_bit_depth) {
        if (source_bit_depth <= 8)
            return value;
        return value / Math.pow (2.0, (double) (source_bit_depth - 8));
    }

    public void compute_stats (double[] values, out double mean, out double stddev) {
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

    // ── Bit depth decision engine ────────────────────────────────────────────

    public BitDepthDecision decide_bit_depth (
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
     * Delivery override on the bit-depth decision.
     *
     * 8-bit decodes on far more hardware than 10-bit, so a stream aimed at
     * unknown devices should prefer it — but NOT when the source genuinely
     * requires 10-bit. HDR without tone mapping and BT.2020 without tone
     * mapping both lose real information at 8-bit, and shipping a broken
     * picture is worse than shipping one some devices decode in software.
     */
    public BitDepthDecision apply_delivery_bit_depth_preference (
        BitDepthDecision        decision,
        bool                    delivery,
        SmartOptimizerVideoInfo info,
        bool                    tone_mapping_active
    ) {
        if (!delivery || !decision.is_10bit)
            return decision;

        bool is_hdr = (info.color_transfer == "smpte2084"
                    || info.color_transfer == "arib-std-b67");
        bool is_wide_gamut = (info.color_primaries == "bt2020");
        if ((is_hdr || is_wide_gamut) && !tone_mapping_active)
            return decision;   // 10-bit is not optional here

        return BitDepthDecision () {
            pix_fmt  = PixelFormat.YUV420P,
            is_10bit = false,
            reason   = "8-bit for playback compatibility (delivery mode) — "
                     + "overriding: " + decision.reason
        };
    }

    // ── Preset selection ─────────────────────────────────────────────────────

    /**
     * Returns the ideal preset index for fully-confident content classification.
     * The caller scales this toward a safe baseline based on type_confidence.
     */
    public int choose_ideal_preset_index (ContentProfile profile) {
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
     * Safe baseline preset index by tier.
     * Larger targets bias toward faster presets because the marginal
     * quality gain from slower presets diminishes with ample bitrate.
     */
    public int tier_safe_preset_index (SizeTier tier, string codec) {
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
     * Content-type influence on preset selection.
     * At larger sizes, content-specific preset adjustments matter less
     * because the encoder has plenty of bits regardless.
     */
    public double tier_content_influence (SizeTier tier) {
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
     * Confidence-scaled preset selection: interpolate from the tier's safe
     * baseline toward the content-type ideal, weighted by classifier
     * confidence and the tier's content influence.
     */
    public int choose_preset_index (ContentProfile profile, SizeTier tier, string codec) {
        int ideal_preset_idx = choose_ideal_preset_index (profile);
        int safe_preset_idx  = tier_safe_preset_index (tier, codec);
        double content_factor = tier_content_influence (tier);

        int preset_idx = safe_preset_idx + (int) Math.round (
            (ideal_preset_idx - safe_preset_idx) * profile.type_confidence * content_factor);
        // All preset tables have 9 entries (indices 0–8).
        return preset_idx.clamp (0, 8);
    }

    // ── Encoder tuning: one decision, two consumers ──────────────────────────

    /**
     * Encoder parameters that materially change what an encode produces.
     *
     * This exists so the CALIBRATION PROBE and the APPLIED RECOMMENDATION
     * cannot disagree. They used to: the probe encoded with codec, preset, CRF
     * and pixel format only, while apply_smart_* went on to add tunes, grain
     * synthesis, psy-rd and fast-decode. The model was therefore fitted to one
     * encoder configuration and the result produced by another.
     *
     * Measured divergence at identical CRF, probe settings vs applied:
     *
     *     x264 tune=animation            size −34.3%   VMAF +0.14
     *     SVT-AV1 film-grain=12          size  −7.1%   VMAF −0.95
     *     x265 psy-rd 2.5 + ref 4        size  +1.7%   VMAF +0.05
     *     SVT-AV1 qm + lookahead         size  −0.3%   VMAF +0.03
     *
     * The quality axis survived the mismatch — every VMAF delta is under a
     * point — but the size axis did not. On animation the predicted size was
     * half again what the encode actually produced, so a Size Mode target
     * landed about a third under what the user asked for: quality they paid
     * for and did not receive.
     *
     * Only parameters that moved the result meaningfully are carried here.
     * Quantisation matrices, reference count, CDEF and the rest stayed within
     * ±2% and are deliberately left to apply_smart_* alone. Lookahead and
     * keyframe interval are carried separately by TemporalTuning because they
     * now depend on decoded-pixel signals. The remaining probe complexity is
     * not repaid. That is a measured
     * judgement, not an oversight; re-measure before assuming it still holds
     * if those settings change substantially.
     */
    public struct EncoderTuning {
        /** x264/x265 -tune value; "" for none. Only ONE tune is possible. */
        public string tune;
        /** SVT-AV1 film grain synthesis. */
        public bool   film_grain;
        public int    film_grain_strength;
        /** x265 psy-rd; 0 leaves the encoder default. */
        public double psy_rd;
        /** SVT-AV1 fast-decode level; 0 = disabled. */
        public int    fast_decode_level;
        /** VP9/SVT-AV1 native sharpness; 0 = disabled. */
        public int    native_sharpness;
    }

    /** Stable identity for a tuning, for use in the calibration cache key. */
    public string encoder_tuning_key (EncoderTuning t) {
        return "%s|%d|%d|%.2f|%d|%d".printf (
            t.tune, t.film_grain ? 1 : 0, t.film_grain_strength,
            t.psy_rd, t.fast_decode_level, t.native_sharpness);
    }

    // ── Temporal tuning: decoded-pixel signals, never source GOP metadata ───

    public const double STATIC_FRAME_YDIF_MAX = 0.05;

    public struct TemporalTuning {
        /** Maximum GOP length. Encoders may still insert scene-cut keyframes. */
        public int keyint_frames;
        public double keyint_seconds;
        public int lookahead_frames;
        public double motion_variability;
        public string reason;
    }

    /** Fraction of decoded samples that are effectively unchanged frames. */
    public double static_frame_ratio_from_ydif (double[] normalized_ydif) {
        if (normalized_ydif.length == 0)
            return 0.0;

        int static_count = 0;
        foreach (double value in normalized_ydif) {
            if (value.is_finite () && value <= STATIC_FRAME_YDIF_MAX)
                static_count++;
        }
        return (double) static_count / normalized_ydif.length;
    }

    /**
     * Convert cuts measured in independently filtered sample segments into a
     * rate on the final output timeline. Each segment has its own filter state,
     * so equal local timestamps in different segments are distinct real cuts.
     */
    public double scene_cuts_per_minute (
        double[] cut_times,
        int      segment_count,
        double   segment_duration,
        double   video_speed_multiplier = 1.0
    ) {
        if (cut_times.length == 0 || segment_count <= 0 || segment_duration <= 0.0)
            return 0.0;

        int real_cuts = 0;
        foreach (double cut_time in cut_times) {
            if (cut_time.is_finite () && cut_time >= 0.0)
                real_cuts++;
        }

        double speed = (video_speed_multiplier.is_finite ()
                && video_speed_multiplier > 0.0)
            ? video_speed_multiplier : 1.0;
        double sampled_minutes = segment_count * segment_duration / speed / 60.0;
        return sampled_minutes > 0.0 ? real_cuts / sampled_minutes : 0.0;
    }

    /** Pure filter graph used to keep temporal state local to each sample. */
    public string independent_analysis_filter_spec (
        int    segment_count,
        string video_filter_chain,
        string analysis_filter
    ) {
        var fc = new StringBuilder ();
        for (int i = 0; i < segment_count; i++) {
            if (i > 0)
                fc.append (";");
            fc.append ("[%d:v]".printf (i));
            if (video_filter_chain.length > 0)
                fc.append (video_filter_chain + ",");
            fc.append (analysis_filter);
            fc.append ("[analysis%d]".printf (i));
        }
        return fc.str;
    }

    private int temporal_lookahead_cap (string codec, EncodeEffort effort) {
        if (codec == "vp9") {
            switch (effort) {
                case EncodeEffort.MINIMAL: return 12;
                case EncodeEffort.LOW:     return 16;
                case EncodeEffort.MEDIUM:  return 20;
                default:                   return 25;
            }
        }
        if (codec == "svt-av1") {
            switch (effort) {
                case EncodeEffort.MINIMAL: return 60;
                case EncodeEffort.LOW:     return 80;
                case EncodeEffort.MEDIUM:  return 100;
                default:                   return 120;
            }
        }
        switch (effort) {
            case EncodeEffort.MINIMAL: return 40;
            case EncodeEffort.LOW:     return 50;
            case EncodeEffort.MEDIUM:  return 60;
            case EncodeEffort.HIGH:    return 80;
            default:                   return 120;
        }
    }

    /** Shared signal decision translated into each encoder's supported range. */
    public TemporalTuning decide_temporal_tuning (
        string         codec,
        EncodeEffort   effort,
        ContentProfile profile,
        double         output_fps,
        bool           optimize_for_delivery,
        bool           svt_two_pass_compatible
    ) {
        double fps = (output_fps.is_finite () && output_fps > 0.0)
            ? output_fps : 30.0;
        bool signals_available = profile.temporal_samples > 0;
        double motion_cv = (profile.temporal_diff_mean > 0.05)
            ? profile.temporal_diff_stddev / profile.temporal_diff_mean
            : 0.0;

        double keyint_seconds = 5.0;
        string reason = "moderate temporal activity";
        if (optimize_for_delivery) {
            keyint_seconds = 2.0;
            reason = "delivery mode favours seeking and stream recovery";
        } else if (signals_available
                && (profile.cuts_per_minute >= 12.0 || motion_cv >= 1.0)) {
            keyint_seconds = 2.0;
            reason = "frequent cuts or highly variable motion";
        } else if (signals_available
                && (profile.cuts_per_minute >= 6.0 || motion_cv >= 0.60)) {
            keyint_seconds = 4.0;
            reason = "variable motion or regular scene changes";
        } else if (signals_available
                && (profile.content_type == ContentType.SCREENCAST
                    || (profile.temporal_diff_mean <= 2.0
                        && profile.static_frame_ratio >= 0.35
                        && profile.cuts_per_minute <= 2.0))) {
            keyint_seconds = 8.0;
            reason = "mostly static frames with few scene changes";
        } else if (!signals_available) {
            reason = "temporal signals unavailable; using the neutral policy";
        }

        double requested_frames = Math.round (keyint_seconds * fps);
        int keyint_frames;
        if (!requested_frames.is_finite () || requested_frames >= 1920.0)
            keyint_frames = 1920;
        else if (requested_frames <= 1.0)
            keyint_frames = 1;
        else
            keyint_frames = (int) requested_frames;
        keyint_seconds = keyint_frames / fps;

        double demand = 0.5;
        if (signals_available) {
            double motion = ((profile.temporal_diff_mean - 1.0) / 10.0)
                .clamp (0.0, 1.0);
            double variability = (motion_cv / 1.0).clamp (0.0, 1.0);
            double cuts = (profile.cuts_per_minute / 12.0).clamp (0.0, 1.0);
            demand = (0.35 * motion + 0.40 * variability + 0.25 * cuts
                - 0.30 * profile.static_frame_ratio.clamp (0.0, 1.0))
                .clamp (0.0, 1.0);
            if (profile.content_type == ContentType.SCREENCAST)
                demand *= 0.60;
        }

        int cap = temporal_lookahead_cap (codec, effort);
        int floor = (codec == "vp9") ? 8 : ((codec == "svt-av1") ? 24 : 20);
        if (codec == "svt-av1" && svt_two_pass_compatible) {
            cap = int.min (cap, 42);
            floor = int.min (floor, cap);
            reason += "; SVT-AV1 lookahead capped at 42 for two-pass compatibility";
        }
        if (optimize_for_delivery) {
            int delivery_cap = (codec == "vp9") ? 12
                : ((codec == "svt-av1") ? 32 : 40);
            cap = int.min (cap, delivery_cap);
            floor = int.min (floor, cap);
        }

        int lookahead = (int) Math.round (floor + (cap - floor) * demand);
        if (codec == "x264" || codec == "x265")
            lookahead = (int) Math.round (lookahead / 5.0) * 5;
        lookahead = lookahead.clamp (0, cap);

        return TemporalTuning () {
            keyint_frames = keyint_frames,
            keyint_seconds = keyint_seconds,
            lookahead_frames = lookahead,
            motion_variability = motion_cv,
            reason = reason
        };
    }

    public string temporal_tuning_key (TemporalTuning t) {
        return "%d|%d".printf (t.keyint_frames, t.lookahead_frames);
    }

    /**
     * Estimate how much the source benefits from native edge preservation.
     *
     * The anchors are the measured 19-file Phase-0 corpus ranges. Spatial
     * information is the primary signal, edge density confirms real structure,
     * and blur is only a small softness term: absolute blur cannot distinguish
     * optical defocus from compression damage, so it must never act as a gate.
     * TOUT reduces sharpening on noisy 8-bit sources; above 8-bit that metric
     * is not comparable and is deliberately ignored.
     */
    public double detail_preservation_score (
        ContentProfile profile,
        int            source_bit_depth
    ) {
        double spatial = ((profile.spatial_info - 15.0) / 85.0).clamp (0.0, 1.0);
        double edges = ((profile.edge_mean - 1.0) / 9.0).clamp (0.0, 1.0);
        double clarity = (profile.blur_mean > 0.0)
            ? ((10.0 - profile.blur_mean) / 6.0).clamp (0.0, 1.0)
            : 0.0;
        double noise_penalty = 0.0;
        if (source_bit_depth > 0 && source_bit_depth <= 8) {
            noise_penalty = ((profile.noise_mean - 0.0005) / 0.0020)
                .clamp (0.0, 1.0);
        }
        return (0.50 * spatial + 0.30 * edges + 0.20 * clarity
            - 0.15 * noise_penalty).clamp (0.0, 1.0);
    }

    /**
     * Turn measured detail demand into a conservative native sharpness.
     * Effort is a maximum-strength cap, not the on/off decision: Low and
     * Medium may preserve detail, while High/Maximum permit stronger levels
     * only when the source signal calls for them.
     */
    public int native_sharpness_for_detail (
        EncodeEffort effort,
        double       detail_score
    ) {
        int requested = 0;
        if (detail_score >= 0.75)       requested = 3;
        else if (detail_score >= 0.55) requested = 2;
        else if (detail_score >= 0.25) requested = 1;

        int cap = 0;
        switch (effort) {
            case EncodeEffort.LOW:
            case EncodeEffort.MEDIUM:  cap = 1; break;
            case EncodeEffort.HIGH:    cap = 2; break;
            case EncodeEffort.MAXIMUM: cap = 3; break;
            default:                   cap = 0; break;
        }
        return int.min (requested, cap);
    }

    /** x265 psy-rd by effort, mirroring apply_smart_x265. */
    public double psy_rd_for_effort (EncodeEffort effort) {
        switch (effort) {
            case EncodeEffort.MINIMAL: return 2.0;
            case EncodeEffort.LOW:     return 2.0;
            case EncodeEffort.MEDIUM:  return 2.5;
            case EncodeEffort.HIGH:    return 3.0;
            case EncodeEffort.MAXIMUM: return 3.5;
            default:                   return 2.0;
        }
    }

    /** SVT-AV1 film grain strength by effort, mirroring apply_smart_svt_av1. */
    public int film_grain_strength_for_effort (EncodeEffort effort) {
        switch (effort) {
            case EncodeEffort.LOW:     return 8;
            case EncodeEffort.MEDIUM:  return 10;
            case EncodeEffort.HIGH:    return 12;
            case EncodeEffort.MAXIMUM: return 15;
            default:                   return 8;
        }
    }

    /**
     * Decide the encoder tuning for a recommendation.
     *
     * Every input is known before calibration runs — content classification,
     * grain/detail measurements and effort are all settled by then — so the
     * probe can use the real settings rather than a stripped-down approximation.
     */
    public EncoderTuning decide_encoder_tuning (
        string       codec,
        EncodeEffort effort,
        ContentType  content_type,
        double       grain_score,
        double       detail_score,
        int          source_bit_depth,
        bool         fast_decode
    ) {
        var t = EncoderTuning () {
            tune = "", film_grain = false, film_grain_strength = 0,
            psy_rd = 0.0, fast_decode_level = 0, native_sharpness = 0
        };
        bool grain = grain_warranted (grain_score, content_type, source_bit_depth);

        if (codec == "x264") {
            // Only one tune is possible, and an explicit delivery request wins
            // over the content-derived choice.
            if (fast_decode)                                 t.tune = "fastdecode";
            else if (content_type == ContentType.ANIME)      t.tune = "animation";
            else if (content_type == ContentType.SCREENCAST) t.tune = "stillimage";
        } else if (codec == "x265") {
            if (fast_decode)                            t.tune = "fastdecode";
            else if (content_type == ContentType.ANIME) t.tune = "animation";
            else if (effort >= EncodeEffort.HIGH && grain) t.tune = "grain";
            t.psy_rd = psy_rd_for_effort (effort);
        } else if (codec == "vp9") {
            t.native_sharpness = native_sharpness_for_detail (effort, detail_score);
        } else if (codec == "svt-av1") {
            // AV1 exposes fast-decode separately from tuning, so unlike
            // x264/x265 it composes rather than displacing anything.
            t.fast_decode_level = fast_decode ? 1 : 0;
            t.native_sharpness = native_sharpness_for_detail (effort, detail_score);
            if (effort >= EncodeEffort.MEDIUM && grain) {
                t.film_grain = true;
                t.film_grain_strength = film_grain_strength_for_effort (effort);
            }
        }
        return t;
    }

    // ── Mode-agnostic effort mapping ─────────────────────────────────────────

    /**
     * Size Mode's bridge onto the shared effort axis.
     *
     * Deliberately 1:1 with SizeTier so this refactor is behaviour-preserving:
     * every feature table that used to switch on the tier now switches on the
     * effort level it maps to, and produces byte-identical settings.  Quality
     * Mode reaches the same axis from user intent instead.
     *
     * The mapping is one-way on purpose.  Effort has no inverse — several
     * intents can land on the same effort level, and in Quality Mode there is
     * no size tier to recover.
     */
    public EncodeEffort effort_from_size_tier (SizeTier tier) {
        switch (tier) {
            case SizeTier.TINY:   return EncodeEffort.MINIMAL;
            case SizeTier.SMALL:  return EncodeEffort.LOW;
            case SizeTier.MEDIUM: return EncodeEffort.MEDIUM;
            case SizeTier.LARGE:  return EncodeEffort.HIGH;
            case SizeTier.XLARGE: return EncodeEffort.MAXIMUM;
            default:              return EncodeEffort.LOW;
        }
    }

    /**
     * Tiny/Small targets force the codec-default container (webm/mp4) for
     * imageboard and web compatibility, overriding the user's choice.
     *
     * Size-target policy, not quality policy — Quality Mode always leaves this
     * false and respects the user's container selection.
     */
    public bool tier_forces_compat_container (SizeTier tier) {
        return tier <= SizeTier.SMALL;
    }

    // ── Tier policy helpers ──────────────────────────────────────────────────

    /**
     * Tiny and Small are treated as strict size targets.
     * Medium and above treat the target as an approximate landing zone.
     */
    public bool tier_uses_strict_targeting (SizeTier tier) {
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
    public double tier_target_tolerance_kib (SizeTier tier, double target_total_kib) {
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

    // ── Lossless intermediate sizing ─────────────────────────────────────────

    // Lossless intra-ish compression typically lands well under this
    // fraction of raw video size; used only as a disk-usage guard.
    public const double INTERMEDIATE_LOSSLESS_RATIO = 0.35;
    // Skip the intermediate when its estimated size exceeds this — the
    // slow path (re-running filters per probe) is safe, just slower.
    public const double INTERMEDIATE_MAX_BYTES = 4.0 * 1024.0 * 1024.0 * 1024.0;

    /**
     * Rough size estimate for a lossless intermediate holding the filtered
     * sample segments.  Uses SOURCE dimensions — an upper bound whenever
     * the filter chain downscales.  Returns 0 when inputs are unknown
     * (callers treat that as "don't build").
     */
    public double estimate_intermediate_bytes (
        int    width,
        int    height,
        double fps,
        int    source_bit_depth,
        double sample_duration
    ) {
        if (width <= 0 || height <= 0 || fps <= 0 || sample_duration <= 0)
            return 0.0;
        double bytes_per_frame = (double) width * (double) height * 1.5
            * (source_bit_depth >= 10 ? 2.0 : 1.0);
        return bytes_per_frame * fps * sample_duration * INTERMEDIATE_LOSSLESS_RATIO;
    }

    // ── Downscale advisory ───────────────────────────────────────────────────

    // Comfort multiplier: the suggested resolution targets this many times
    // the low-bpp threshold, so the advice restores clear headroom rather
    // than landing right back on the edge.
    public const double BPP_COMFORT_MULTIPLIER = 1.6;

    /**
     * Codec-specific bits-per-pixel threshold below which per-pixel
     * quality visibly suffers.  More efficient codecs tolerate lower bpp.
     */
    public double bpp_low_threshold (string codec) {
        if (codec == "svt-av1") return 0.028;
        if (codec == "x265" || codec == "vp9") return 0.032;
        return 0.045;   // x264
    }

    /**
     * Suggest a downscale resolution when the video budget's bits-per-pixel
     * is below the codec's comfort threshold.  Returns null when no
     * suggestion applies: enough bitrate, unknown dimensions, the filter
     * chain already rescales, the reduction would be marginal (<10%), or
     * the suggested size would drop below 320×240.
     */
    public DownscaleAdvisory? assess_downscale (
        string codec,
        int    target_video_kbps,
        int    width,
        int    height,
        double fps,
        bool   filter_chain_rescales
    ) {
        if (filter_chain_rescales || width <= 0 || height <= 0
                || fps <= 0 || target_video_kbps <= 0)
            return null;

        double bpp = (double) target_video_kbps * 1000.0
            / ((double) width * (double) height * fps);
        double threshold = bpp_low_threshold (codec);
        if (bpp >= threshold)
            return null;

        // Scale factor that lifts bpp to the comfort target; bitrate per
        // pixel scales with the inverse of the pixel count (factor²).
        double target_bpp = threshold * BPP_COMFORT_MULTIPLIER;
        double scale = Math.sqrt (bpp / target_bpp);
        if (scale > 0.9)
            return null;   // not a meaningful reduction
        scale = double.max (scale, 0.4);

        int new_w = ((int) (width  * scale)) / 2 * 2;
        int new_h = ((int) (height * scale)) / 2 * 2;
        if (new_w < 320 || new_h < 240)
            return null;

        var adv = new DownscaleAdvisory ();
        adv.bpp = bpp;
        adv.threshold = threshold;
        adv.new_width = new_w;
        adv.new_height = new_h;
        adv.scale_factor = scale;
        return adv;
    }

    // ── Calibration point selection ──────────────────────────────────────────

    /** Valid CRF solve range per codec. */
    public void crf_range_for_codec (string codec, out int crf_min, out int crf_max) {
        if (codec == "vp9") {
            crf_min = 12; crf_max = 55;
        } else if (codec == "svt-av1") {
            crf_min = 10; crf_max = 55;
        } else {
            // x264 and x265 share the same 0–51 range
            crf_min = 8; crf_max = 51;
        }
    }

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
    public int[] pick_calibration_crfs (string codec, SizeTier tier) {
        int[] crfs = new int[4];
        if (codec == "vp9") {
            switch (tier) {
                case SizeTier.SMALL:  crfs = { 22, 27, 33, 38 }; break;
                case SizeTier.MEDIUM: crfs = { 18, 23, 29, 34 }; break;
                case SizeTier.LARGE:  crfs = { 15, 20, 26, 31 }; break;
                case SizeTier.XLARGE: crfs = { 12, 17, 23, 28 }; break;
                default:              crfs = { 25, 30, 35, 40 }; break;
            }
        } else if (codec == "svt-av1") {
            switch (tier) {
                case SizeTier.SMALL:  crfs = { 18, 25, 32, 38 }; break;
                case SizeTier.MEDIUM: crfs = { 15, 21, 27, 33 }; break;
                case SizeTier.LARGE:  crfs = { 12, 17, 23, 28 }; break;
                case SizeTier.XLARGE: crfs = {  8, 13, 19, 24 }; break;
                default:              crfs = { 22, 29, 36, 42 }; break;
            }
        } else {
            // x264 and x265 share the same CRF scale
            switch (tier) {
                case SizeTier.SMALL:  crfs = { 16, 21, 26, 30 }; break;
                case SizeTier.MEDIUM: crfs = { 14, 19, 24, 28 }; break;
                case SizeTier.LARGE:  crfs = { 10, 15, 21, 26 }; break;
                case SizeTier.XLARGE: crfs = {  8, 13, 19, 24 }; break;
                default:              crfs = { 18, 23, 28, 32 }; break;
            }
        }
        return crfs;
    }

    public bool calibration_contains_crf (int[] cal_crfs, int crf) {
        for (int i = 0; i < cal_crfs.length; i++) {
            if (cal_crfs[i] == crf)
                return true;
        }
        return false;
    }

    public void append_calibration_sample (
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

    /** Insert one quality sample while keeping CRF, VMAF, and size aligned. */
    public void append_quality_calibration_sample (
        ref int[]    cal_crfs,
        ref double[] cal_vmafs,
        ref double[] cal_sizes,
        int          crf,
        double       vmaf,
        double       size_kib
    ) {
        if (calibration_contains_crf (cal_crfs, crf))
            return;

        int old_len = cal_crfs.length;
        int[] new_crfs = new int[old_len + 1];
        double[] new_vmafs = new double[old_len + 1];
        double[] new_sizes = new double[old_len + 1];

        for (int i = 0; i < old_len; i++) {
            new_crfs[i] = cal_crfs[i];
            new_vmafs[i] = cal_vmafs[i];
            new_sizes[i] = cal_sizes[i];
        }
        new_crfs[old_len] = crf;
        new_vmafs[old_len] = vmaf;
        new_sizes[old_len] = size_kib;

        for (int i = 1; i < new_crfs.length; i++) {
            int cur_crf = new_crfs[i];
            double cur_vmaf = new_vmafs[i];
            double cur_size = new_sizes[i];
            int j = i - 1;
            while (j >= 0 && new_crfs[j] > cur_crf) {
                new_crfs[j + 1] = new_crfs[j];
                new_vmafs[j + 1] = new_vmafs[j];
                new_sizes[j + 1] = new_sizes[j];
                j--;
            }
            new_crfs[j + 1] = cur_crf;
            new_vmafs[j + 1] = cur_vmaf;
            new_sizes[j + 1] = cur_size;
        }

        cal_crfs = new_crfs;
        cal_vmafs = new_vmafs;
        cal_sizes = new_sizes;
    }

    public bool should_refine_calibration_window (int predicted_crf, int[] cal_crfs) {
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
    public int[] pick_adaptive_calibration_crfs (
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

        int[] extra = new int[(int) extra_list.length];
        for (int i = 0; i < extra_list.length; i++)
            extra[i] = extra_list[i];
        return extra;
    }

    // ── Curve fitting & solving ──────────────────────────────────────────────

    /**
     * Fit the CRF↔size curve, then guard against a non-monotonic
     * quadratic: noise can bend the fitted parabola upward inside the
     * calibration window, which would claim "higher CRF → bigger file".
     * The derivative b + 2c·x is linear, so checking both window ends
     * covers the whole window; if either is non-negative, refit as a
     * least-squares line in log-space instead.
     */
    public void fit_calibration_curve (
        int[]    cal_crfs,
        double[] cal_sizes,
        out double qa,
        out double qb,
        out double qc,
        out bool   degenerate
    ) {
        fit_quadratic_log_curve (cal_crfs, cal_sizes, out qa, out qb, out qc, out degenerate);
        if (degenerate)
            return;

        double first = (double) cal_crfs[0];
        double last  = (double) cal_crfs[cal_crfs.length - 1];
        if (qb + 2.0 * qc * first >= 0.0 || qb + 2.0 * qc * last >= 0.0) {
            warning ("Smart Optimizer: quadratic fit non-monotonic over CRF [%d, %d] — refitting linear",
                cal_crfs[0], cal_crfs[cal_crfs.length - 1]);
            fit_linear_log_curve (cal_crfs, cal_sizes, out qa, out qb);
            qc = 0.0;
        }
    }

    /**
     * Least-squares line ln(size) = a + b*CRF over all calibration points.
     */
    public void fit_linear_log_curve (
        int[]    cal_crfs,
        double[] cal_sizes,
        out double qa,
        out double qb
    ) {
        double sx = 0, sy = 0, sxx = 0, sxy = 0;
        int n = cal_crfs.length;
        for (int i = 0; i < n; i++) {
            double x = (double) cal_crfs[i];
            double y = Math.log (cal_sizes[i]);
            sx += x; sy += y; sxx += x * x; sxy += x * y;
        }
        double denom = (double) n * sxx - sx * sx;
        if (Math.fabs (denom) < 1e-12) {
            qb = 0.0;
            qa = (n > 0) ? sy / n : 0.0;
            return;
        }
        qb = ((double) n * sxy - sx * sy) / denom;
        qa = (sy - qb * sx) / n;
    }

    /**
     * Root-mean-square residual of the fitted curve in log-space —
     * approximately the relative size error (0.05 ≈ ±5%).  Uses
     * degrees-of-freedom-adjusted variance so the 4-point base fit
     * doesn't report artificially tiny residuals.
     */
    /**
     * Whether a fitted residual carries any information.
     *
     * A quadratic has three coefficients, so three points determine it
     * exactly and every residual is zero — not because the curve agrees with
     * the data, but because it had no freedom to disagree.  Both RMSE
     * helpers below floor their degrees of freedom at 1 to avoid dividing by
     * zero, which turns that structural zero into a printable "±0.00".
     *
     * Reporting it alongside runs that probed more points inverts the
     * meaning: a 3-point fit shows ±0.00 while a 5-point fit of the same
     * content shows ±0.17, so the less-constrained model looks like the
     * better one.  Callers should ask this before printing a residual.
     *
     * Mirrors the model_params choice in fit_rmse_log and vmaf_fit_rmse —
     * keep the three in step.
     */
    public bool fit_residual_is_informative (int point_count, double qc) {
        int model_params = (qc == 0.0) ? 2 : 3;
        return point_count > model_params;
    }

    public double fit_rmse_log (
        int[]    cal_crfs,
        double[] cal_sizes,
        double   qa,
        double   qb,
        double   qc
    ) {
        if (cal_crfs.length == 0)
            return 0.0;
        double ss = 0.0;
        for (int i = 0; i < cal_crfs.length; i++) {
            double x = (double) cal_crfs[i];
            double resid = Math.log (cal_sizes[i]) - (qa + qb * x + qc * x * x);
            ss += resid * resid;
        }
        int model_params = (qc == 0.0) ? 2 : 3;
        int dof = int.max (1, cal_crfs.length - model_params);
        return Math.sqrt (ss / dof);
    }

    /**
     * Least-squares quadratic fit y = a + b·x + c·x² over pre-transformed data.
     *
     * The objective-function-agnostic core of the calibration solver.  Callers
     * supply whatever y-transform linearizes their response:
     *
     *   - Size:    y = ln(size)          — exponential CRF↔size response.
     *   - Quality: y = logit(vmaf/100)   — VMAF is bounded [0,100] and
     *                                      saturates near the top, so a raw
     *                                      fit overshoots badly at high
     *                                      targets.
     *
     * Falls back to a straight line through the first and last points when the
     * 3×3 normal-equation system is degenerate (e.g. every sample produced an
     * identical value, or fewer than three distinct x values).
     */
    public void fit_quadratic_least_squares (
        double[] xs,
        double[] ys,
        out double qa,
        out double qb,
        out double qc,
        out bool   degenerate
    ) {
        double sx = 0, sx2 = 0, sx3 = 0, sx4 = 0;
        double sy = 0, sxy = 0, sx2y = 0;
        for (int i = 0; i < xs.length; i++) {
            double x = xs[i];
            double y = ys[i];
            double x2 = x * x;
            sx   += x;
            sx2  += x2;
            sx3  += x2 * x;
            sx4  += x2 * x2;
            sy   += y;
            sxy  += x * y;
            sx2y += x2 * y;
        }
        double n_pts = (double) xs.length;

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
                // Straight line through the endpoints in transformed space.
                // Algebraically identical to the old raw-size two-point
                // exponential (qb = ln(B), qa = ln(A)) but computed directly in
                // log space, so it skips a pow/exp round-trip.
                double x0 = xs[0];
                double x1 = xs[xs.length - 1];
                double dx = x1 - x0;
                if (Math.fabs (dx) < 1e-12) {
                    // Every x identical — no slope is recoverable; hold the
                    // mean.  The old code divided by zero here and produced
                    // inf/nan.  Upstream dedupes CRFs, so this is defensive.
                    qb = 0.0;
                    qa = (xs.length > 0) ? sy / n_pts : 0.0;
                } else {
                    qb = (ys[ys.length - 1] - ys[0]) / dx;
                    qa = ys[0] - qb * x0;
                }
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
     * Fit ln(size) = a + b*CRF + c*CRF^2 using least squares over an
     * arbitrary number of calibration points.  Thin y = ln(size) wrapper over
     * fit_quadratic_least_squares.
     */
    public void fit_quadratic_log_curve (
        int[]    cal_crfs,
        double[] cal_sizes,
        out double qa,
        out double qb,
        out double qc,
        out bool   degenerate
    ) {
        var xs = new double[cal_crfs.length];
        var ys = new double[cal_crfs.length];
        for (int i = 0; i < cal_crfs.length; i++) {
            xs[i] = (double) cal_crfs[i];
            ys[i] = Math.log (cal_sizes[i]);
        }
        fit_quadratic_least_squares (xs, ys, out qa, out qb, out qc, out degenerate);
    }

    /**
     * Solve c*x^2 + b*x + (a - ln(target)) = 0 for CRF and select the root
     * that is valid or nearest the valid CRF range.
     */
    public double solve_crf_from_curve (
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

    public bool try_evaluate_model_size_kib (
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

    public bool try_cast_nonnegative_int (double value, string label, out int cast_value) {
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

    // ── Confidence assessment ────────────────────────────────────────────────

    /**
     * Confidence in the CRF size estimate: extrapolation distance from the
     * calibration window, sample coverage, source-bitrate sanity, the x265
     * psy-rd penalty, and the fit's residual quality.
     */
    public ConfidenceAssessment assess_confidence (
        CalibrationModel model,
        int    estimated_total_kib,
        int    positions_count,
        double sample_segment_duration,
        double encode_duration,
        bool   trim_active,
        int64  file_size_bytes,
        double probed_duration,
        int    available_video_kbps,
        string codec
    ) {
        var conf = new ConfidenceAssessment ();

        // Calibration is most accurate within [cal_first, cal_last] where
        // the quadratic interpolates rather than extrapolates. Outside that
        // range, confidence degrades proportionally to distance.
        conf.confidence = 1.0;
        int cal_first = model.cal_crfs[0];
        int cal_last = model.cal_crfs[model.cal_crfs.length - 1];
        int cal_range = cal_last - cal_first;
        int predicted_crf = model.predicted_crf;
        if (predicted_crf < cal_first - cal_range || predicted_crf > cal_last + cal_range) {
            conf.confidence = 0.5;   // far extrapolation (> one full range outside)
            warning ("Smart Optimizer: CRF %d is far outside calibration range [%d, %d] (%d points) — "
                + "prediction reliability is low",
                predicted_crf, cal_first, cal_last, model.cal_crfs.length);
        } else if (predicted_crf < cal_first - 2 || predicted_crf > cal_last + 2) {
            conf.confidence = 0.75;  // moderate extrapolation
            warning ("Smart Optimizer: CRF %d is outside calibration range [%d, %d] (%d points) — "
                + "prediction may be inaccurate",
                predicted_crf, cal_first, cal_last, model.cal_crfs.length);
        } else if (predicted_crf < cal_first || predicted_crf > cal_last) {
            conf.confidence = 0.9;   // slight extrapolation (just outside range)
        }
        // Within [cal_first, cal_last]: confidence stays at 1.0 — the quadratic
        // model is interpolating between measured points, not extrapolating.

        // Sample coverage factor: when the sampled duration is a small
        // fraction of the total, the linear extrapolation becomes less
        // reliable.  Coverage ≥ 30%: no penalty; 10–30%: linear ramp from
        // 0.65 to 1.0; < 10%: floor at 0.65.
        double sample_duration = double.min (
            (double) positions_count * sample_segment_duration, encode_duration);
        conf.sample_coverage = sample_duration / encode_duration;
        if (conf.sample_coverage < 0.30) {
            // Linear ramp: 0.65 at ≤10% → 1.0 at 30%
            double coverage_factor = (0.65 + 0.35 * ((conf.sample_coverage - 0.10) / 0.20))
                .clamp (0.65, 1.0);
            conf.confidence *= coverage_factor;
            if (conf.sample_coverage < 0.15) {
                warning ("Smart Optimizer: sample covers only %.1f%% of video duration — "
                    + "size estimate may be less accurate (confidence factor: %.2f)",
                    conf.sample_coverage * 100.0, coverage_factor);
            }
        }

        // Source bitrate sanity check: if the CRF model predicts a LARGER
        // output while the user wants a SMALLER file, the prediction is
        // unreliable — reduce confidence so the tier logic is more likely
        // to trigger two-pass.
        if (file_size_bytes > 0 && probed_duration > 0) {
            conf.source_total_kbps = kbps_from_bytes_for_duration (
                file_size_bytes, probed_duration);
        }
        if (!trim_active && conf.source_total_kbps > 0 && encode_duration > 0) {
            // Rough source video kbps — subtract a conservative audio estimate.
            // 128 kbps covers most common audio codecs without over-subtracting.
            conf.source_video_kbps = int.max (0, (int) conf.source_total_kbps - 128);

            if (conf.source_video_kbps > 0 && available_video_kbps < conf.source_video_kbps) {
                int estimated_output_kbps = (int) kbps_from_kib_for_duration (
                    (double) estimated_total_kib, encode_duration);
                int source_total_kbps_int = (int) conf.source_total_kbps;
                if (estimated_output_kbps > source_total_kbps_int) {
                    conf.confidence *= 0.6;
                    warning ("Smart Optimizer: CRF estimate (%d kbps) exceeds source (%d kbps) "
                        + "— prediction is unreliable",
                        estimated_output_kbps, source_total_kbps_int);
                }
            }
        }

        // x265's psy-rd aggressively allocates extra bits to visually
        // complex regions, making CRF output inherently less predictable
        // than other codecs.  Calibration samples capture average
        // complexity but cannot anticipate how psy-rd inflates specific
        // unsampled scenes — a residual check on the same samples cannot
        // see it either, hence a codec-targeted penalty.
        if (codec == "x265") {
            conf.confidence *= 0.85;
        }

        // Fit residual quality: high scatter means the interpolation is
        // unreliable even inside the calibration range.  No penalty below
        // 3% RMSE; linear ramp to a 0.6 floor at 25%.
        conf.fit_rmse = fit_rmse_log (
            model.cal_crfs, model.cal_sizes, model.qa, model.qb, model.qc);
        conf.fit_quality_factor = 1.0;
        if (conf.fit_rmse > 0.03) {
            conf.fit_quality_factor = (1.0 - 0.4 * (conf.fit_rmse - 0.03) / 0.22)
                .clamp (0.6, 1.0);
            conf.confidence *= conf.fit_quality_factor;
            if (conf.fit_quality_factor < 0.9) {
                warning ("Smart Optimizer: calibration fit RMSE ±%.1f%% — confidence factor %.2f",
                    conf.fit_rmse * 100.0, conf.fit_quality_factor);
            }
        }

        return conf;
    }

    // ── Two-pass policy ──────────────────────────────────────────────────────

    /**
     * Tier-aware two-pass recommendation: strict tiers always use two-pass
     * (with a 3% bitrate safety margin); MEDIUM+ allow CRF only when the
     * estimate is confident enough for the tier and lands inside the
     * symmetric target band around the requested size.
     */
    public TwoPassPolicy decide_two_pass (
        SizeTier       tier,
        int            target_mb,
        double         target_total_kib,
        int            available_video_kbps,
        int            estimated_total_kib,
        double         confidence,
        bool           crf_at_max,
        bool           trim_active,
        double         source_total_kbps,
        double         encode_duration,
        int64          file_size_bytes,
        double         sample_coverage,
        ContentProfile profile
    ) {
        var policy = new TwoPassPolicy ();

        // For strict tiers (TINY/SMALL), shave 3% off the video bitrate
        // to absorb encoder overshoot, audio bitrate variance, and
        // container overhead inaccuracy.  This small headroom is far
        // cheaper than overshooting a hard size ceiling.
        policy.target_video_kbps = available_video_kbps;
        if (tier_uses_strict_targeting (tier)) {
            policy.target_video_kbps = (int) (policy.target_video_kbps * 0.97);
        }

        // Track whether the requested output is meaningfully smaller than the
        // source. This feeds user-facing notes and reduction messaging.
        // TINY/SMALL still force two-pass via strict_targeting below; for
        // MEDIUM+ a reduction target alone does not override a confident CRF
        // estimate that lands inside the tier's target band.
        policy.source_size_mb = mib_from_bytes (file_size_bytes);
        policy.comparison_source_size_mb = policy.source_size_mb;
        policy.reduction_confidence = 1.0;
        if (trim_active && source_total_kbps > 0) {
            policy.comparison_source_size_mb = mib_from_kbps_for_duration (
                source_total_kbps, encode_duration);
            policy.reduction_confidence = sample_coverage;
            if (profile.temporal_diff_mean > 0) {
                double motion_cv = profile.temporal_diff_stddev / profile.temporal_diff_mean;
                policy.reduction_confidence *= (1.0 - double.min (0.35, motion_cv * 0.20));
            }
            policy.reduction_confidence = policy.reduction_confidence.clamp (0.25, 1.0);
        }
        double reduction_threshold = trim_active
            ? (0.85 + 0.10 * policy.reduction_confidence)
            : 0.98;
        policy.target_is_size_reduction = (policy.comparison_source_size_mb > 0)
            && ((double) target_mb < policy.comparison_source_size_mb * reduction_threshold);

        policy.strict_targeting = tier_uses_strict_targeting (tier);
        policy.target_tolerance_kib = policy.strict_targeting
            ? target_total_kib * 0.05
            : tier_target_tolerance_kib (tier, target_total_kib);
        policy.within_target_band =
            Math.fabs (estimated_total_kib - target_total_kib) <= policy.target_tolerance_kib;

        // For TINY/SMALL, even modest overshoot is unacceptable.
        // For MEDIUM+, treat the target as a symmetric landing zone around
        // the requested size, with some leniency above or below target.
        policy.crf_overshoots =
            estimated_total_kib > (target_total_kib + policy.target_tolerance_kib);

        if (policy.strict_targeting) {
            // TINY and SMALL always prefer strict size targeting.
            policy.recommend_two_pass = true;
        } else {
            switch (tier) {
                case SizeTier.MEDIUM:
                    policy.recommend_two_pass = (confidence < 0.85);
                    break;
                case SizeTier.LARGE:
                    policy.recommend_two_pass = (confidence < 0.70);
                    break;
                case SizeTier.XLARGE:
                    policy.recommend_two_pass = (confidence < 0.60);
                    break;
                default:
                    policy.recommend_two_pass = true;
                    break;
            }

            // For MEDIUM+, allow CRF only when the estimate is both
            // confident enough for the tier and lands inside the symmetric
            // target band around the requested size. Reduction targets still
            // go through this same gate unless the tier is strict.
            if (!policy.recommend_two_pass) {
                if (policy.crf_overshoots) {
                    policy.recommend_two_pass = true;
                } else if (!policy.within_target_band) {
                    policy.recommend_two_pass = true;
                }
            }
        }

        // Feasibility flags: force two-pass when CRF alone cannot
        // comfortably hit the target, including cases where even max CRF
        // still looks too large.
        policy.is_impossible = crf_at_max
            && (estimated_total_kib > target_total_kib * 1.1);
        if (crf_at_max) {
            policy.recommend_two_pass = true;
        }

        return policy;
    }

    // ════════════════════════════════════════════════════════════════════════
    // QUALITY SOLVER
    //
    // The second objective function.  Size Mode pins a byte count and lets
    // quality float; Quality Mode pins a perceptual score and lets size float.
    // Both run the same pipeline, the same probe encodes, the same
    // least-squares core and the same confidence model — only the target
    // differs.
    //
    // Every constant below is quoted against the Phase 0 corpus measurements
    // (16 files x 5 CRF points, libx265; docs/smart-optimizer-phase0-findings.md).
    // ════════════════════════════════════════════════════════════════════════

    // VMAF at or above this carries no gradient — the metric has saturated and
    // the encoder is already past visually lossless.  Calibration points up
    // here must be discarded: they anchor the fit on a clipped value.  Measured
    // consequence of NOT doing this: women-4k-testvid0 (VMAF 100.0 at CRF 16)
    // mispredicted its held-out point by 3.43 VMAF, against a corpus mean of
    // 0.318.
    public const double VMAF_SATURATION_THRESHOLD = 99.5;

    // A quality solve needs at least this many usable (non-saturated) points
    // to fit.  Phase 0 measured 3-point fits at 0.318 VMAF mean prediction
    // error, so three is genuinely enough — where the size solve needs 4-6.
    public const int VMAF_MIN_CALIBRATION_POINTS = 3;

    /**
     * What the user asked for, as a perceptual target rather than a byte count.
     *
     * The VMAF values are Phase 0 defaults: 88/92/95/97 spans "acceptable" to
     * "archival", and the measured CRF spread across content classes at each
     * target is what justifies solving instead of tabulating —
     * 1.1 CRF of spread at Low, but 11.2 at Ultra.
     */
    public enum QualityIntent {
        LOW,
        MEDIUM,
        HIGH,
        ULTRA;

        public double target_vmaf () {
            switch (this) {
                case LOW:    return 88.0;
                case MEDIUM: return 92.0;
                case HIGH:   return 95.0;
                case ULTRA:  return 97.0;
                default:     return 92.0;
            }
        }

        public string to_label () {
            switch (this) {
                case LOW:    return "Low";
                case MEDIUM: return "Medium";
                case HIGH:   return "High";
                case ULTRA:  return "Ultra";
                default:     return "Medium";
            }
        }
    }

    /**
     * Quality Mode's bridge onto the shared effort axis, mirroring
     * effort_from_size_tier.  MINIMAL is deliberately unreachable here — it
     * exists for imageboard-scale size targets, not for any quality intent.
     */
    public EncodeEffort effort_from_quality_intent (QualityIntent intent) {
        switch (intent) {
            case QualityIntent.LOW:    return EncodeEffort.LOW;
            case QualityIntent.MEDIUM: return EncodeEffort.MEDIUM;
            case QualityIntent.HIGH:   return EncodeEffort.HIGH;
            case QualityIntent.ULTRA:  return EncodeEffort.MAXIMUM;
            default:                   return EncodeEffort.MEDIUM;
        }
    }

    /**
     * The effective target for this intent on this content.
     *
     * VMAF is trained on natural video and does not transfer uniformly, so the
     * intent's nominal target is not always the right one to solve for.
     */
    public struct QualityTarget {
        public double target_vmaf;
        /** False when VMAF cannot be trusted to rank this content. */
        public bool   vmaf_reliable;
        /** True when measured VMAF must not exceed target_vmaf. */
        public bool   enforce_vmaf_ceiling;
        /** CRF ceiling used by the High/Ultra screen-text exception; 0 = none. */
        public int    crf_cap;
        public string reason;
    }

    // Screencast CRF caps. Phase 0 measured a 3837x2160 screen capture at
    // VMAF 92.69 at CRF 34 and 97.23 at CRF 28 — scores that would satisfy the
    // Medium and High intents while the text is visibly mangled.  VMAF
    // massively over-rewards synthetic screen content. High and Ultra preserve
    // the rule-based text-legibility guard. Low and Medium deliberately accept
    // the text-quality trade-off and enforce their numeric VMAF ceilings like
    // every other content type.
    //
    // PROVISIONAL: these are defensible values for text legibility, not
    // perceptually validated ones.  Settling them needs subjective comparison,
    // which Phase 0 could not provide.
    public int screencast_crf_cap (QualityIntent intent) {
        switch (intent) {
            case QualityIntent.LOW:    return 0;
            case QualityIntent.MEDIUM: return 0;
            case QualityIntent.HIGH:   return 22;
            case QualityIntent.ULTRA:  return 18;
            default:                   return 0;
        }
    }

    public QualityTarget resolve_quality_target (
        QualityIntent  intent,
        ContentProfile profile
    ) {
        double nominal = intent.target_vmaf ();

        if (profile.content_type == ContentType.SCREENCAST) {
            int cap = screencast_crf_cap (intent);
            if (cap <= 0) {
                return QualityTarget () {
                    target_vmaf         = nominal,
                    vmaf_reliable       = false,
                    enforce_vmaf_ceiling = true,
                    crf_cap             = 0,
                    reason              = ("VMAF over-rates screen content, but "
                        + "%s deliberately keeps VMAF %.0f as a hard ceiling; "
                        + "reduced text clarity is part of this tier's trade-off")
                        .printf (intent.to_label (), nominal)
                };
            }
            return QualityTarget () {
                target_vmaf          = nominal,
                vmaf_reliable        = false,
                enforce_vmaf_ceiling = false,
                crf_cap              = cap,
                reason               = ("VMAF over-rates screen content; %s may "
                    + "exceed VMAF %.0f to protect text, with CRF capped at %d")
                    .printf (intent.to_label (), nominal, cap)
            };
        }

        // Animation: VMAF is widely held to under-penalise flat cel-shaded
        // content, which would argue for a raised target.  Phase 0 could not
        // measure the offset — that needs subjective comparison, not a metric
        // sweep — so no adjustment is applied rather than inventing one.
        // Revisit with perceptual data.
        return QualityTarget () {
            target_vmaf          = nominal,
            vmaf_reliable        = true,
            enforce_vmaf_ceiling = true,
            crf_cap              = 0,
            reason               = "VMAF %.0f hard ceiling".printf (nominal)
        };
    }

    /** The action required after measuring one candidate encode. */
    public enum QualityCeilingDecision {
        ACCEPT,
        RAISE_CRF,
        CODEC_LIMIT,
        TEXT_PROTECTION_EXCEPTION
    }

    /**
     * Decide what verification must do with an actual VMAF measurement.
     * There is intentionally no allowance: a score above the selected tier's
     * number is over its ceiling. The only exception is the explicit
     * High/Ultra screencast text-protection policy.
     */
    public QualityCeilingDecision decide_quality_ceiling (
        QualityTarget target,
        double        measured_vmaf,
        int           crf,
        int           codec_max_crf
    ) {
        if (measured_vmaf <= target.target_vmaf)
            return QualityCeilingDecision.ACCEPT;
        if (!target.enforce_vmaf_ceiling)
            return QualityCeilingDecision.TEXT_PROTECTION_EXCEPTION;
        if (crf >= codec_max_crf)
            return QualityCeilingDecision.CODEC_LIMIT;
        return QualityCeilingDecision.RAISE_CRF;
    }

    /** Next coarse CRF for saturation recovery, or -1 at the codec limit. */
    public int next_saturation_search_crf (int current_crf, int codec_max_crf) {
        if (current_crf >= codec_max_crf)
            return -1;
        return int.min (current_crf + 6, codec_max_crf);
    }

    /** Midpoint for narrowing a measured over/under bracket, or -1 if adjacent. */
    public int next_quality_bracket_crf (int above_crf, int below_crf) {
        if (below_crf - above_crf <= 1)
            return -1;
        return above_crf + (below_crf - above_crf) / 2;
    }

    /**
     * Drop calibration points whose VMAF has saturated.
     *
     * Above VMAF_SATURATION_THRESHOLD the response is flat, so those samples
     * contribute no gradient and drag the fit.  Points are kept in ascending
     * CRF order.  Returns the number kept; when fewer than
     * VMAF_MIN_CALIBRATION_POINTS survive the caller must probe higher CRFs
     * rather than fit what is left.
     */
    public int filter_saturated_vmaf_points (
        int[]      crfs,
        double[]   vmafs,
        out int[]  kept_crfs,
        out double[] kept_vmafs
    ) {
        var kc = new GenericArray<int> ();
        var kv = new GenericArray<double?> ();
        for (int i = 0; i < crfs.length && i < vmafs.length; i++) {
            if (vmafs[i] > 0.0 && vmafs[i] < VMAF_SATURATION_THRESHOLD) {
                kc.add (crfs[i]);
                kv.add (vmafs[i]);
            }
        }
        kept_crfs = new int[kc.length];
        kept_vmafs = new double[kv.length];
        for (int i = 0; i < kc.length; i++) {
            kept_crfs[i] = kc[i];
            kept_vmafs[i] = kv[i];
        }
        return kept_crfs.length;
    }

    /** Fitted CRF↔VMAF model and the CRF solved for the target. */
    public class VmafModel {
        public int[]    cal_crfs = {};
        public double[] cal_vmafs = {};
        public double   qa;
        public double   qb;
        public double   qc;
        public bool     degenerate;
        public int      predicted_crf;
        public double   predicted_vmaf;
        public bool     crf_at_min;
        public bool     crf_at_max;
        public int      saturated_points_dropped;
        public double   fit_rmse;          // in VMAF points
    }

    /**
     * Fit CRF↔VMAF with a plain quadratic on the RAW score.
     *
     * Phase 0 tested this against the transform the plan originally specified.
     * Over 16 files:  raw-linear 1.925, logit-linear 1.075, quadratic 0.228
     * VMAF points of mean residual.  Logit's saturation correction is real for
     * mid-range files but diverges as VMAF approaches 100 (logit -> infinity),
     * so a single near-100 sample wrecks it — 6.777 on women-4k-testvid0.  The
     * raw quadratic is the most robust across the corpus (worst case 0.380).
     */
    public void fit_vmaf_curve (
        int[]    cal_crfs,
        double[] cal_vmafs,
        out double qa,
        out double qb,
        out double qc,
        out bool   degenerate
    ) {
        var xs = new double[cal_crfs.length];
        var ys = new double[cal_crfs.length];
        for (int i = 0; i < cal_crfs.length; i++) {
            xs[i] = (double) cal_crfs[i];
            ys[i] = cal_vmafs[i];
        }
        fit_quadratic_least_squares (xs, ys, out qa, out qb, out qc, out degenerate);
    }

    /**
     * Evaluate the fitted VMAF curve, clamped to the metric's real range.
     * An unconstrained quadratic will happily predict 101.
     */
    public double evaluate_vmaf_at_crf (double qa, double qb, double qc, double crf) {
        double v = qa + qb * crf + qc * crf * crf;
        if (!v.is_finite ())
            return 0.0;
        return v.clamp (0.0, 100.0);
    }

    /**
     * Root-mean-square residual of the VMAF fit, in VMAF points.
     *
     * ⚠️ With exactly VMAF_MIN_CALIBRATION_POINTS (3) points a quadratic is
     * fully determined, so every residual is zero by construction and this
     * carries NO information about fit quality.  A 0.00 residual on a 3-point
     * solve means "3 points" and nothing more.  The real generalisation check
     * is the verification probe (see VmafVerification): encode once at the
     * solved CRF and compare measured VMAF against the prediction.
     */
    public double vmaf_fit_rmse (
        int[] cal_crfs, double[] cal_vmafs, double qa, double qb, double qc
    ) {
        if (cal_crfs.length == 0)
            return 0.0;
        double ss = 0.0;
        for (int i = 0; i < cal_crfs.length; i++) {
            double resid = cal_vmafs[i]
                - (qa + qb * cal_crfs[i] + qc * cal_crfs[i] * cal_crfs[i]);
            ss += resid * resid;
        }
        int model_params = (qc == 0.0) ? 2 : 3;
        int dof = int.max (1, cal_crfs.length - model_params);
        return Math.sqrt (ss / dof);
    }

    /**
     * Solve the fitted curve for the CRF that achieves @target_vmaf.
     *
     * Reuses solve_crf_from_curve — the root selection there (prefer a root
     * inside the valid range, else the nearest) is objective-agnostic; only
     * the y value being solved for changes.  Size Mode passes ln(target
     * bytes); Quality Mode passes the target VMAF directly.
     */
    public VmafModel solve_quality_crf (
        int[]         cal_crfs,
        double[]      cal_vmafs,
        double        target_vmaf,
        string        codec
    ) {
        var m = new VmafModel ();

        int[] kept_crfs;
        double[] kept_vmafs;
        int kept = filter_saturated_vmaf_points (
            cal_crfs, cal_vmafs, out kept_crfs, out kept_vmafs);
        m.saturated_points_dropped = cal_crfs.length - kept;
        m.cal_crfs = kept_crfs;
        m.cal_vmafs = kept_vmafs;

        int crf_min, crf_max;
        crf_range_for_codec (codec, out crf_min, out crf_max);

        if (kept < VMAF_MIN_CALIBRATION_POINTS) {
            // Not enough gradient to fit.  Caller must probe higher CRFs.
            m.degenerate = true;
            m.predicted_crf = (crf_min + crf_max) / 2;
            m.predicted_vmaf = 0.0;
            return m;
        }

        fit_vmaf_curve (kept_crfs, kept_vmafs,
            out m.qa, out m.qb, out m.qc, out m.degenerate);
        m.fit_rmse = vmaf_fit_rmse (kept_crfs, kept_vmafs, m.qa, m.qb, m.qc);

        double cal_mid = (double) (kept_crfs[0] + kept_crfs[kept_crfs.length - 1]) / 2.0;
        double raw = solve_crf_from_curve (
            m.qa, m.qb, m.qc, target_vmaf, cal_mid, crf_min, crf_max);

        // The intent's VMAF is a ceiling, not a bullseye: Ultra means "up to
        // 97". CRF is integral, so select the best-quality integer whose MODEL
        // prediction is not above the ceiling. Verification below is still
        // authoritative and raises CRF again if the measured result overshoots.
        int nearest = (int) Math.round (raw);
        int solved = nearest.clamp (crf_min, crf_max);
        while (solved < crf_max
                && evaluate_vmaf_at_crf (m.qa, m.qb, m.qc, solved) > target_vmaf) {
            solved++;
        }
        while (solved > crf_min
                && evaluate_vmaf_at_crf (m.qa, m.qb, m.qc, solved - 1) <= target_vmaf) {
            solved--;
        }

        m.crf_at_min = solved <= crf_min;
        m.crf_at_max = solved >= crf_max;
        m.predicted_crf = solved.clamp (crf_min, crf_max);
        m.predicted_vmaf = evaluate_vmaf_at_crf (m.qa, m.qb, m.qc, m.predicted_crf);
        return m;
    }

    /** Apply the High/Ultra screencast text-protection CRF cap, when present. */
    public int apply_quality_crf_cap (int solved_crf, QualityTarget target) {
        if (target.crf_cap <= 0)
            return solved_crf;
        return int.min (solved_crf, target.crf_cap);
    }


    /**
     * Nominal SizeTier for a quality intent.
     *
     * Several helpers are still tier-typed (decide_bit_depth,
     * choose_preset_index, tier_content_influence, plan_audio).  Rather than
     * fork them, Quality Mode hands them the tier that maps to the SAME point
     * on the shared effort axis, so both modes drive identical downstream
     * behaviour:
     *
     *     effort_from_size_tier (nominal_size_tier_for_intent (i))
     *         == effort_from_quality_intent (i)          for every intent
     *
     * (asserted by the unit tests).
     *
     * ⚠️ Two call sites must NOT use this tier:
     *   - resolve_effective_container — LOW maps to SMALL, which would force
     *     the imageboard compatibility container.  Quality Mode has no size
     *     constraint and must respect the user's container choice.
     *   - the keep-all-audio gate in plan_audio, which requires tier >= MEDIUM.
     *     Use quality_audio_tier() instead: with no size budget there is no
     *     reason to drop audio tracks.
     */
    public SizeTier nominal_size_tier_for_intent (QualityIntent intent) {
        switch (intent) {
            case QualityIntent.LOW:    return SizeTier.SMALL;
            case QualityIntent.MEDIUM: return SizeTier.MEDIUM;
            case QualityIntent.HIGH:   return SizeTier.LARGE;
            case QualityIntent.ULTRA:  return SizeTier.XLARGE;
            default:                   return SizeTier.MEDIUM;
        }
    }

    /**
     * Tier used only for audio planning in Quality Mode — the nominal tier
     * floored at MEDIUM.  Quality Mode has no byte budget to protect, so
     * multi-track preservation should never be refused on size grounds.
     */
    public SizeTier quality_audio_tier (QualityIntent intent) {
        SizeTier t = nominal_size_tier_for_intent (intent);
        return (t < SizeTier.MEDIUM) ? SizeTier.MEDIUM : t;
    }

    /**
     * How many sample segments fit inside the lossless-intermediate budget.
     *
     * Quality Mode REQUIRES the intermediate: it is the VMAF reference, and
     * libvmaf needs a reference with identical resolution and frame rate to
     * the distorted input.  Size Mode can skip it and pay the re-filter cost
     * instead, but Quality Mode has no such fallback — without a reference
     * there is nothing to measure against.
     *
     * So instead of abandoning the intermediate when it would be too large
     * (what Size Mode does), Quality Mode reduces the segment count until it
     * fits.  Returns 0 when the inputs are unknown.
     */
    public int max_segments_for_intermediate_budget (
        int    width,
        int    height,
        double fps,
        int    source_bit_depth,
        double segment_duration,
        double max_bytes
    ) {
        double per_segment = estimate_intermediate_bytes (
            width, height, fps, source_bit_depth, segment_duration);
        if (per_segment <= 0.0 || max_bytes <= 0.0)
            return 0;
        return int.max (1, (int) Math.floor (max_bytes / per_segment));
    }

    /** Truncate @positions to at most @max_count entries, preserving spread. */
    public double[] limit_positions (double[] positions, int max_count) {
        if (max_count <= 0 || positions.length <= max_count)
            return positions;
        // Keep an evenly spaced subset rather than the first N, so the samples
        // still span the whole encode window.
        var kept = new double[max_count];
        double step = (double) (positions.length - 1) / (double) (max_count - 1);
        for (int i = 0; i < max_count; i++) {
            int idx = (int) Math.round (step * i);
            kept[i] = positions[idx.clamp (0, positions.length - 1)];
        }
        return kept;
    }

    /**
     * Confidence in a quality solve.
     *
     * Deliberately a SEPARATE number from assess_confidence, which scores the
     * SIZE prediction (extrapolation distance, coverage, fit residual, the
     * x265 psy-rd penalty).  Conflating the two would report size-model
     * uncertainty as quality uncertainty and vice versa — they answer
     * different questions and can disagree sharply on the same run.
     *
     * Note this is still confidence in the PREDICTION, not in the content
     * classification; profile.type_confidence remains the right input for
     * damping content-driven decisions.
     */
    /**
     * Outcome of the verification probe: one encode at the solved CRF, scored
     * against the same reference.
     *
     * This is the quality solver's real accuracy check.  The fit residual
     * cannot serve — with a 3-point ladder the quadratic interpolates its own
     * points exactly — so the only honest measure of whether the answer is
     * right is to encode at that answer and score it.
     */
    public class VmafVerification {
        public bool   done;
        public int    initial_crf;
        public int    verified_crf;
        public double predicted_vmaf;
        public double measured_vmaf;
        /** measured − predicted; negative means the solve was optimistic. */
        public double delta;
        /** Number of one-step CRF increases made after measured overshoots. */
        public int    ceiling_corrections;
        /** True when the codec's maximum CRF still measures above the ceiling. */
        public bool   ceiling_unreachable;
        /** True when High/Ultra preserved screen text above the numeric ceiling. */
        public bool   text_protection_exception;
    }

    // Verification deltas beyond this many VMAF points mean the curve did not
    // generalise to the answer it produced.  Phase 0's held-out prediction
    // error averaged 0.318 VMAF, so a point-and-a-half is well outside normal.
    public const double VMAF_VERIFY_TOLERANCE = 1.5;

    public double assess_quality_confidence (
        VmafModel          model,
        double             sample_coverage,
        bool               vmaf_reliable_for_content,
        VmafVerification?  verification = null
    ) {
        if (model.degenerate)
            return 0.3;

        double confidence = 1.0;

        // Extrapolation beyond the measured bracket, mirroring the size
        // solver's treatment.
        if (model.cal_crfs.length >= 2) {
            int first = model.cal_crfs[0];
            int last  = model.cal_crfs[model.cal_crfs.length - 1];
            int range = int.max (1, last - first);
            if (model.predicted_crf < first - range
                    || model.predicted_crf > last + range) {
                confidence *= 0.5;
            } else if (model.predicted_crf < first - 2
                    || model.predicted_crf > last + 2) {
                confidence *= 0.75;
            } else if (model.predicted_crf < first || model.predicted_crf > last) {
                confidence *= 0.9;
            }
        }

        // Fit residual, in VMAF points.  Only meaningful when the fit is
        // overdetermined — at exactly 3 points the quadratic interpolates its
        // own samples and the residual is zero by construction, so applying
        // this term there would silently reward having too little data.
        if (model.cal_crfs.length > 3 && model.fit_rmse > 1.0) {
            confidence *= (1.0 - 0.4 * ((model.fit_rmse - 1.0) / 4.0)).clamp (0.6, 1.0);
        }

        // Verification: the real generalisation check.  A solve whose own
        // answer does not reproduce when encoded is not trustworthy however
        // tidy the curve looked.
        if (verification != null && verification.done) {
            double err = Math.fabs (verification.delta);
            if (err > VMAF_VERIFY_TOLERANCE) {
                confidence *= (1.0 - 0.5 * ((err - VMAF_VERIFY_TOLERANCE) / 5.0))
                    .clamp (0.4, 1.0);
            }
        }

        // Sample coverage — same ramp the size solver uses.
        if (sample_coverage > 0.0 && sample_coverage < 0.30) {
            confidence *= (0.65 + 0.35 * ((sample_coverage - 0.10) / 0.20))
                .clamp (0.65, 1.0);
        }

        // Content the metric cannot rank (screencast): the CRF cap is doing
        // the real work, so the VMAF-derived answer deserves little trust.
        if (!vmaf_reliable_for_content)
            confidence *= 0.5;

        return confidence.clamp (0.0, 1.0);
    }

    // ── Quality-mode calibration ladder ──────────────────────────────────────

    /**
     * Three CRF points bracketing the expected answer for this intent.
     *
     * Phase 0 measured 3-point fits at 0.318 VMAF mean prediction error, so
     * three suffices where the size solve needs 4-6 — the CRF↔VMAF response is
     * far better behaved than CRF↔size.  Brackets widen toward Ultra because
     * the measured spread across content classes does: 1.1 CRF at Low, 11.2 at
     * Ultra (anime 12.3 vs live-action 23.5).
     *
     * The x264/x265 and SVT-AV1 ladders are corpus-calibrated. **VP9's is
     * not** — it still follows pick_calibration_crfs by analogy and has never
     * been measured, so treat its centring as a guess. SVT-AV1's was also a
     * guess until measured, and turned out to be 8–16 CRF off, which is the
     * scale of error to expect from VP9's.
     *
     * Adaptive refinement (pick_adaptive_calibration_crfs) corrects a
     * mis-centred bracket by probing near the first solve, so an imperfect
     * starting ladder costs an extra probe rather than a bad answer — but it
     * costs that probe on nearly every run when the ladder is as far out as
     * SVT-AV1's was.
     */
    public int[] pick_quality_calibration_crfs (string codec, QualityIntent intent) {
        if (codec == "vp9") {
            switch (intent) {
                case QualityIntent.LOW:    return { 28, 34, 40 };
                case QualityIntent.MEDIUM: return { 24, 30, 36 };
                case QualityIntent.HIGH:   return { 19, 26, 32 };
                case QualityIntent.ULTRA:  return { 13, 21, 28 };
                default:                   return { 24, 30, 36 };
            }
        }
        if (codec == "svt-av1") {
            // CORPUS-MEASURED (19 files, CRF 24–48). The original values here
            // were scaled from the x265 ladder by analogy and were centred
            // 8–16 CRF too low — the LOW bracket topped out at 42 while the
            // measured answer averages 50.1, so the solve fell outside the
            // window on nearly every source:
            //
            //   intent   old bracket   measured mean   measured range
            //   Low      30–42         50.1            41.9–53.8
            //   Medium   26–38         43.8            33.9–53.6
            //   High     20–34         34.1            22.5–43.6
            //   Ultra    14–30         30.6*           17.1–38.7
            //
            // * Ultra's mean is biased upward because animation cannot reach
            //   VMAF 97 at all under the HD model (see vmaf_model_path), so
            //   only the easier content contributes a figure.
            //
            // Brackets are deliberately wide — the measured spread is ~20 CRF
            // at every intent above Low, far wider than x265's.
            switch (intent) {
                case QualityIntent.LOW:    return { 42, 48, 54 };
                case QualityIntent.MEDIUM: return { 34, 44, 54 };
                case QualityIntent.HIGH:   return { 24, 34, 44 };
                case QualityIntent.ULTRA:  return { 18, 28, 38 };
                default:                   return { 34, 44, 54 };
            }
        }
        // x264 / x265 share one ladder. Phase 0 swept libx265 only, so this
        // was measured on x265 and merely assumed for x264 — the same kind of
        // assumption that proved 8–16 CRF wrong for SVT-AV1.
        //
        // Checked rather than assumed: scoring identical content at identical
        // CRF under both encoders (3 sources x CRF 20/26/32) puts x264 within
        // −0.07 VMAF of x265 on average, worst case −1.45. Sharing the ladder
        // is correct.
        //
        // This runs against the familiar "x265 CRF 28 ≈ x264 CRF 23" guidance,
        // which is about FILE SIZE at equal quality — x265 reaches the same
        // quality with fewer bits. CRF is a quality parameter in both, so the
        // CRF that hits a given VMAF is nearly the same either way, and the
        // codec difference lands on the size axis, which the solver measures
        // separately.
        switch (intent) {
            case QualityIntent.LOW:    return { 24, 30, 36 };
            case QualityIntent.MEDIUM: return { 21, 27, 33 };
            case QualityIntent.HIGH:   return { 17, 23, 29 };
            case QualityIntent.ULTRA:  return { 11, 18, 25 };
            default:                   return { 21, 27, 33 };
        }
    }
}
