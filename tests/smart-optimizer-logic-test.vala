// smart-optimizer-logic-test.vala
// Unit tests for the Smart Optimizer's pure decision logic:
// budget math, curve fitting/solving, trim window resolution, audio
// planning, confidence assessment, and the two-pass policy.

using Gtk;
using GLib;

// ── Stubs for collaborators pulled in by the audio chain ────────────────────
// (same pattern as ffprobe-utils-test.vala)

namespace CodecUtils {
    public StringList build_dropdown_string_list (string[] options) {
        var model = new StringList (null);
        foreach (unowned string option in options) {
            model.append (option);
        }
        return model;
    }
}

public class AppSettings : Object {
    private static AppSettings? instance = null;
    public string ffmpeg_path { get; set; default = "ffmpeg"; }
    public string ffprobe_path { get; set; default = "ffprobe"; }

    public static AppSettings get_default () {
        if (instance == null) {
            instance = new AppSettings ();
        }
        return instance;
    }
}

namespace ConversionUtils {
    public string format_ffmpeg_double (double value, string format = "%g") {
        char[] buffer = new char[64];
        value.format (buffer, format);
        return (string) buffer;
    }

    public string format_command_for_display (string[] argv) {
        return string.joinv (" ", argv);
    }

    public string get_app_temp_root () {
        return GLib.Path.build_filename (
            Environment.get_tmp_dir (), "smartopt-logic-test");
    }
}

public class AudioSegment : Object {
    public double start_time { get; set; }
    public double end_time { get; set; }

    public AudioSegment (double start, double end) {
        start_time = start;
        end_time = end;
    }

    public double get_duration () {
        return (end_time - start_time).clamp (0.0, double.MAX);
    }
}

// ── Test helpers ─────────────────────────────────────────────────────────────

bool close_to (double a, double b, double tol) {
    return Math.fabs (a - b) <= tol;
}

AudioSourceInfo make_audio_source (string codec, int kbps, bool estimated) {
    var s = new AudioSourceInfo ();
    s.presence = MediaStreamPresence.PRESENT;
    s.codec_name = codec;
    s.bitrate_kbps = kbps;
    s.bitrate_estimated = estimated;
    return s;
}

SmartOptimizerVideoInfo make_video_info (AudioSourceInfo[] audio) {
    var info = SmartOptimizerVideoInfo () {
        duration = 120.0,
        width = 1920,
        height = 1080,
        fps = 30.0,
        audio_bitrate_kbps = 0,
        audio_bitrate_estimated = false,
        audio_codec = "",
        total_audio_bitrate_kbps = 0,
        total_audio_bitrate_estimated = false,
        source_audio = new AudioSourceInfo (),
        all_source_audio = {},
        file_size_bytes = 0,
        source_bit_depth = 8,
        color_transfer = "",
        color_primaries = ""
    };
    AudioSourceInfo[] collected = {};
    foreach (var s in audio) {
        if (info.audio_codec.length == 0) {
            info.audio_codec = s.codec_name;
            info.audio_bitrate_kbps = s.bitrate_kbps;
            info.audio_bitrate_estimated = s.bitrate_estimated;
            info.source_audio = s.copy ();
        }
        collected += s.copy ();
        info.total_audio_bitrate_kbps += s.bitrate_kbps;
        if (s.bitrate_estimated) info.total_audio_bitrate_estimated = true;
    }
    info.all_source_audio = collected;
    return info;
}

void test_size_tier_boundaries () {
    assert (SizeTier.from_mb (4) == SizeTier.TINY);
    assert (SizeTier.from_mb (25) == SizeTier.TINY);
    assert (SizeTier.from_mb (26) == SizeTier.SMALL);
    assert (SizeTier.from_mb (50) == SizeTier.SMALL);
    assert (SizeTier.from_mb (51) == SizeTier.MEDIUM);
    assert (SizeTier.from_mb (100) == SizeTier.MEDIUM);
    assert (SizeTier.from_mb (200) == SizeTier.LARGE);
    assert (SizeTier.from_mb (201) == SizeTier.XLARGE);
}

void test_trim_window_no_trim () {
    var ctx = OptimizationContext ();
    var tw = SmartOptimizerLogic.resolve_trim_window (ctx, 100.0, 8.0);
    assert (!tw.trim_active);
    assert (close_to (tw.trim_start, 0.0, 1e-9));
    assert (close_to (tw.trim_end, 100.0, 1e-9));
    assert (close_to (tw.encode_duration, 100.0, 1e-9));
    assert (close_to (tw.sample_segment_duration, 8.0, 1e-9));
}

void test_trim_window_basic_trim () {
    var ctx = OptimizationContext () {
        trim_start_seconds = 10.0,
        trim_end_seconds = 20.0
    };
    var tw = SmartOptimizerLogic.resolve_trim_window (ctx, 100.0, 8.0);
    assert (tw.trim_active);
    assert (close_to (tw.encode_duration, 10.0, 1e-9));
}

void test_trim_window_inverted_falls_back () {
    var ctx = OptimizationContext () {
        trim_start_seconds = 50.0,
        trim_end_seconds = 20.0
    };
    var tw = SmartOptimizerLogic.resolve_trim_window (ctx, 100.0, 8.0);
    assert (!tw.trim_active);
    assert (close_to (tw.encode_duration, 100.0, 1e-9));
}

void test_trim_window_short_source_shrinks_segment () {
    var ctx = OptimizationContext ();
    var tw = SmartOptimizerLogic.resolve_trim_window (ctx, 5.0, 8.0);
    assert (close_to (tw.sample_segment_duration, 5.0, 1e-9));
}

void test_trim_window_effective_duration_caps_end () {
    var ctx = OptimizationContext () {
        trim_start_seconds = 10.0,
        effective_duration = 30.0
    };
    var tw = SmartOptimizerLogic.resolve_trim_window (ctx, 100.0, 8.0);
    assert (tw.trim_active);
    assert (close_to (tw.trim_end, 40.0, 1e-9));
    assert (close_to (tw.encode_duration, 30.0, 1e-9));
}

void test_unit_conversions_round_trip () {
    // 1000 kbps for 60s → KiB → back to kbps
    double kib = SmartOptimizerLogic.kib_from_kbps_for_duration (1000.0, 60.0);
    assert (close_to (kib, 1000.0 * 1000.0 * 60.0 / (8.0 * 1024.0), 1e-6));
    double kbps = SmartOptimizerLogic.kbps_from_kib_for_duration (kib, 60.0);
    assert (close_to (kbps, 1000.0, 1e-6));
    // zero-duration guards
    assert (SmartOptimizerLogic.kib_from_kbps_for_duration (1000.0, 0.0) == 0.0);
    assert (SmartOptimizerLogic.kbps_from_kib_for_duration (100.0, 0.0) == 0.0);
    assert (close_to (SmartOptimizerLogic.mib_from_bytes (1024 * 1024), 1.0, 1e-9));
}

void test_match_source_target_rounding () {
    const int64 MIB = 1024 * 1024;

    // Whole MiB stays put; fractions round to the nearest whole MB.
    assert (SmartOptimizerLogic.match_source_target_mb (9 * MIB) == 9);
    assert (SmartOptimizerLogic.match_source_target_mb ((int64) (9.3 * MIB)) == 9);
    assert (SmartOptimizerLogic.match_source_target_mb ((int64) (9.7 * MIB)) == 10);
    assert (SmartOptimizerLogic.match_source_target_mb ((int64) (9.5 * MIB)) == 10);
    assert (SmartOptimizerLogic.match_source_target_mb ((int64) (264.6 * MIB)) == 265);
    assert (SmartOptimizerLogic.match_source_target_mb ((int64) (377.2 * MIB)) == 377);

    // Sub-MB and unknown sizes clamp to the minimum rather than 0.
    assert (SmartOptimizerLogic.match_source_target_mb (0) == SmartOptimizerLogic.TARGET_MB_MIN);
    assert (SmartOptimizerLogic.match_source_target_mb (-1) == SmartOptimizerLogic.TARGET_MB_MIN);
    assert (SmartOptimizerLogic.match_source_target_mb (1024) == SmartOptimizerLogic.TARGET_MB_MIN);

    // Oversized sources clamp to the ceiling the spin buttons accept.
    assert (SmartOptimizerLogic.match_source_target_mb (64000 * MIB)
            == SmartOptimizerLogic.TARGET_MB_MAX);
}

void test_match_source_target_scaled_to_window () {
    const int64 MIB = 1024 * 1024;

    // Half the duration → half the size.
    assert (SmartOptimizerLogic.match_source_target_mb_for_window (
        400 * MIB, 30.0, 60.0) == 200);
    // A tenth of a 265 MB source, rounded.
    assert (SmartOptimizerLogic.match_source_target_mb_for_window (
        265 * MIB, 6.0, 60.0) == 27);
    // Full window matches the unscaled target.
    assert (SmartOptimizerLogic.match_source_target_mb_for_window (
        265 * MIB, 60.0, 60.0) == 265);
    // A window longer than the source never scales above the source size.
    assert (SmartOptimizerLogic.match_source_target_mb_for_window (
        100 * MIB, 120.0, 60.0) == 100);

    // Unknown durations fall back to the unscaled target.
    assert (SmartOptimizerLogic.match_source_target_mb_for_window (
        100 * MIB, 0.0, 60.0) == 100);
    assert (SmartOptimizerLogic.match_source_target_mb_for_window (
        100 * MIB, 30.0, 0.0) == 100);

    // A very short window still asks for at least the minimum target.
    assert (SmartOptimizerLogic.match_source_target_mb_for_window (
        100 * MIB, 0.01, 3600.0) == SmartOptimizerLogic.TARGET_MB_MIN);
}

void test_container_overhead_scales_with_duration () {
    // 2-hour 30fps MP4 with one AAC track: moov sample tables are MBs,
    // not a fixed 120 KiB.
    double long_mp4 = SmartOptimizerLogic.container_overhead_kib_estimate (
        "mp4", 7200.0, 30.0, {}, false, 1);
    assert (long_mp4 > 3000.0);

    // 30-second WebM stays small.
    double short_webm = SmartOptimizerLogic.container_overhead_kib_estimate (
        "webm", 30.0, 30.0, {}, false, 1);
    assert (short_webm < 100.0);

    // Longer always costs more within a container.
    double short_mp4 = SmartOptimizerLogic.container_overhead_kib_estimate (
        "mp4", 30.0, 30.0, {}, false, 1);
    assert (long_mp4 > short_mp4);
}

void test_fit_recovers_exponential () {
    // Perfect exponential: ln(size) = 10 − 0.1·CRF
    int[] crfs = { 16, 21, 26, 30 };
    double[] sizes = new double[4];
    for (int i = 0; i < 4; i++) sizes[i] = Math.exp (10.0 - 0.1 * crfs[i]);

    double qa, qb, qc;
    bool degenerate;
    SmartOptimizerLogic.fit_calibration_curve (crfs, sizes, out qa, out qb, out qc, out degenerate);
    assert (!degenerate);
    assert (close_to (qb + 2.0 * qc * 23.0, -0.1, 1e-6)); // derivative near center
    assert (close_to (qa + qb * 23.0 + qc * 529.0, 10.0 - 2.3, 1e-6));

    // Solve back for the size at CRF 23 → must return ≈23
    double ln_target = 10.0 - 0.1 * 23.0;
    double crf_raw = SmartOptimizerLogic.solve_crf_from_curve (
        qa, qb, qc, ln_target, 23.0, 8, 51);
    assert (close_to (crf_raw, 23.0, 0.01));

    // Residuals of a perfect fit are ~0
    double rmse = SmartOptimizerLogic.fit_rmse_log (crfs, sizes, qa, qb, qc);
    assert (rmse < 1e-6);
}

void test_fit_monotonicity_guard () {
    // Upward-bending tail: a raw quadratic fit would claim
    // "higher CRF → bigger file" past its vertex.
    int[] crfs = { 10, 20, 30, 40 };
    double[] sizes = { 1000.0, 300.0, 200.0, 260.0 };

    double qa, qb, qc;
    bool degenerate;
    SmartOptimizerLogic.fit_calibration_curve (crfs, sizes, out qa, out qb, out qc, out degenerate);
    assert (!degenerate);
    assert (qc == 0.0);            // fell back to the linear fit
    assert (qb < 0.0);             // overall trend is still decreasing
}

void test_fit_rmse_reports_noise () {
    int[] crfs = { 16, 21, 26, 30 };
    double[] sizes = new double[4];
    for (int i = 0; i < 4; i++) sizes[i] = Math.exp (10.0 - 0.1 * crfs[i]);
    sizes[1] *= 1.30;   // +30% outlier

    double qa, qb, qc;
    bool degenerate;
    SmartOptimizerLogic.fit_quadratic_log_curve (crfs, sizes, out qa, out qb, out qc, out degenerate);
    double rmse = SmartOptimizerLogic.fit_rmse_log (crfs, sizes, qa, qb, qc);
    assert (rmse > 0.03);
}

// ── Mode-agnostic effort axis ────────────────────────────────────────────────

void test_effort_from_size_tier_is_monotonic_and_total () {
    // The mapping must be 1:1 and order-preserving: it is the only thing
    // guaranteeing Size Mode behaves identically after the feature tables
    // moved from SizeTier onto EncodeEffort.
    assert (SmartOptimizerLogic.effort_from_size_tier (SizeTier.TINY)
        == EncodeEffort.MINIMAL);
    assert (SmartOptimizerLogic.effort_from_size_tier (SizeTier.SMALL)
        == EncodeEffort.LOW);
    assert (SmartOptimizerLogic.effort_from_size_tier (SizeTier.MEDIUM)
        == EncodeEffort.MEDIUM);
    assert (SmartOptimizerLogic.effort_from_size_tier (SizeTier.LARGE)
        == EncodeEffort.HIGH);
    assert (SmartOptimizerLogic.effort_from_size_tier (SizeTier.XLARGE)
        == EncodeEffort.MAXIMUM);

    // Order preservation matters because two live gates are comparisons, not
    // equality tests: SVT-AV1 grain at >= MEDIUM and x265 grain tune at >= HIGH.
    SizeTier[] ascending = {
        SizeTier.TINY, SizeTier.SMALL, SizeTier.MEDIUM,
        SizeTier.LARGE, SizeTier.XLARGE
    };
    for (int i = 1; i < ascending.length; i++) {
        assert (SmartOptimizerLogic.effort_from_size_tier (ascending[i])
              > SmartOptimizerLogic.effort_from_size_tier (ascending[i - 1]));
    }
}

void test_tier_forces_compat_container_only_for_small_targets () {
    // Container forcing is a size policy, not a quality one — it must stay
    // bound to the tier and never leak onto the effort axis.
    assert (SmartOptimizerLogic.tier_forces_compat_container (SizeTier.TINY));
    assert (SmartOptimizerLogic.tier_forces_compat_container (SizeTier.SMALL));
    assert (!SmartOptimizerLogic.tier_forces_compat_container (SizeTier.MEDIUM));
    assert (!SmartOptimizerLogic.tier_forces_compat_container (SizeTier.LARGE));
    assert (!SmartOptimizerLogic.tier_forces_compat_container (SizeTier.XLARGE));
}

// ── Least-squares core ───────────────────────────────────────────────────────

void test_least_squares_core_recovers_known_quadratic () {
    // y = 3 − 0.5x + 0.02x² sampled exactly; the fit must return the
    // coefficients regardless of what transform produced y.
    double[] xs = { 10.0, 20.0, 30.0, 40.0, 50.0 };
    double[] ys = new double[xs.length];
    for (int i = 0; i < xs.length; i++)
        ys[i] = 3.0 - 0.5 * xs[i] + 0.02 * xs[i] * xs[i];

    double qa, qb, qc;
    bool degenerate;
    SmartOptimizerLogic.fit_quadratic_least_squares (
        xs, ys, out qa, out qb, out qc, out degenerate);

    assert (!degenerate);
    assert (close_to (qa, 3.0, 1e-6));
    assert (close_to (qb, -0.5, 1e-6));
    assert (close_to (qc, 0.02, 1e-6));
}

void test_least_squares_core_handles_logit_transform () {
    // The Phase 2 use case: VMAF is bounded and saturates, so the quality
    // solver fits logit(vmaf/100) rather than the raw score.  Verify the core
    // round-trips a logit-space line back to the VMAF that produced it.
    double[] xs = { 18.0, 24.0, 30.0 };
    double[] vmafs = new double[xs.length];
    double[] ys = new double[xs.length];
    for (int i = 0; i < xs.length; i++) {
        double logit = 4.0 - 0.12 * xs[i];
        vmafs[i] = 100.0 / (1.0 + Math.exp (-logit));
        ys[i] = Math.log ((vmafs[i] / 100.0) / (1.0 - vmafs[i] / 100.0));
    }

    double qa, qb, qc;
    bool degenerate;
    SmartOptimizerLogic.fit_quadratic_least_squares (
        xs, ys, out qa, out qb, out qc, out degenerate);
    assert (!degenerate);

    // Predict at a held-out CRF and convert back out of logit space.
    double x = 27.0;
    double pred_logit = qa + qb * x + qc * x * x;
    double pred_vmaf = 100.0 / (1.0 + Math.exp (-pred_logit));
    double want_vmaf = 100.0 / (1.0 + Math.exp (-(4.0 - 0.12 * x)));
    assert (close_to (pred_vmaf, want_vmaf, 1e-6));
}

void test_least_squares_core_degenerate_falls_back_to_line () {
    // Identical y at every x: the normal-equation system collapses and the
    // fallback must return a flat line rather than inf/nan.
    double[] xs = { 10.0, 10.0, 10.0 };
    double[] ys = { 5.0, 5.0, 5.0 };

    double qa, qb, qc;
    bool degenerate;
    SmartOptimizerLogic.fit_quadratic_least_squares (
        xs, ys, out qa, out qb, out qc, out degenerate);

    assert (degenerate);
    assert (qc == 0.0);
    assert (qa.is_finite () && qb.is_finite ());
    assert (close_to (qb, 0.0, 1e-9));
    assert (close_to (qa, 5.0, 1e-9));
}

void test_log_curve_wrapper_matches_core () {
    // fit_quadratic_log_curve is now a y = ln(size) wrapper; it must agree
    // exactly with feeding the core the same transformed data by hand.
    int[] crfs = { 16, 21, 26, 30 };
    double[] sizes = new double[4];
    for (int i = 0; i < 4; i++) sizes[i] = Math.exp (10.0 - 0.1 * crfs[i]);

    double wa, wb, wc;
    bool w_degenerate;
    SmartOptimizerLogic.fit_quadratic_log_curve (
        crfs, sizes, out wa, out wb, out wc, out w_degenerate);

    double[] xs = new double[4];
    double[] ys = new double[4];
    for (int i = 0; i < 4; i++) {
        xs[i] = (double) crfs[i];
        ys[i] = Math.log (sizes[i]);
    }
    double ca, cb, cc;
    bool c_degenerate;
    SmartOptimizerLogic.fit_quadratic_least_squares (
        xs, ys, out ca, out cb, out cc, out c_degenerate);

    assert (w_degenerate == c_degenerate);
    assert (wa == ca && wb == cb && wc == cc);
}

// ── Quality solver ───────────────────────────────────────────────────────────
//
// Fixtures are MEASURED libx265 sweep points from the Phase 0 corpus
// (/mnt/storage3/testvideos, docs/smart-optimizer-phase0-findings.md).
// Testing the solver against real CRF↔VMAF responses rather than synthetic
// curves is the point: the whole premise is that these curves differ wildly
// per source, and a solver that only works on smooth invented data is useless.

// anime-testvid1.mkv — 43 Mbps BD-tier anime. Steep response.
const int[]    ANIME_CRFS  = { 16, 20, 24, 28, 34 };
const double[] ANIME_VMAFS = { 95.901, 94.319, 92.128, 88.727, 79.376 };
const double[] ANIME_SIZES = { 134961.7, 51508.3, 19027.1, 9371.9, 4245.7 };

// women-1080p-testvid0.mp4 — 13 Mbps live-action master. Flat then cliff.
const int[]    LIVE_CRFS  = { 16, 20, 24, 28, 34 };
const double[] LIVE_VMAFS = { 98.648, 98.198, 96.072, 90.870, 75.838 };

// women-4k-testvid0.mp4 — saturates at CRF 16 (VMAF 99.985).
const int[]    SAT_CRFS  = { 16, 20, 24, 28, 34 };
const double[] SAT_VMAFS = { 99.985, 99.528, 97.321, 93.536, 84.156 };

// Screencast-testvid0.webm — VMAF over-rewards screen content badly.
const int[]    SCREEN_CRFS  = { 16, 20, 24, 28, 34 };
const double[] SCREEN_VMAFS = { 99.985, 99.743, 98.837, 97.229, 92.689 };

void test_quality_intent_targets_ascend () {
    assert (SmartOptimizerLogic.QualityIntent.LOW.target_vmaf () == 88.0);
    assert (SmartOptimizerLogic.QualityIntent.MEDIUM.target_vmaf () == 92.0);
    assert (SmartOptimizerLogic.QualityIntent.HIGH.target_vmaf () == 95.0);
    assert (SmartOptimizerLogic.QualityIntent.ULTRA.target_vmaf () == 97.0);

    // Quality Mode never reaches MINIMAL — that is a size-target concept.
    assert (SmartOptimizerLogic.effort_from_quality_intent (
        SmartOptimizerLogic.QualityIntent.LOW) == EncodeEffort.LOW);
    assert (SmartOptimizerLogic.effort_from_quality_intent (
        SmartOptimizerLogic.QualityIntent.ULTRA) == EncodeEffort.MAXIMUM);
}

void test_vmaf_fit_recovers_measured_curve () {
    // The fit must reproduce its own measured points closely. Phase 0 put the
    // corpus mean residual at 0.228 VMAF points; assert comfortably inside 1.0.
    double qa, qb, qc;
    bool degenerate;
    SmartOptimizerLogic.fit_vmaf_curve (
        ANIME_CRFS, ANIME_VMAFS, out qa, out qb, out qc, out degenerate);
    assert (!degenerate);

    double rmse = SmartOptimizerLogic.vmaf_fit_rmse (
        ANIME_CRFS, ANIME_VMAFS, qa, qb, qc);
    assert (rmse < 1.0);

    for (int i = 0; i < ANIME_CRFS.length; i++) {
        double pred = SmartOptimizerLogic.evaluate_vmaf_at_crf (
            qa, qb, qc, ANIME_CRFS[i]);
        assert (Math.fabs (pred - ANIME_VMAFS[i]) < 1.5);
    }
}

void test_vmaf_evaluation_is_clamped_to_metric_range () {
    // An unconstrained quadratic will predict above 100 when extrapolated
    // below the calibration window. VMAF has no such values.
    double qa, qb, qc;
    bool degenerate;
    SmartOptimizerLogic.fit_vmaf_curve (
        LIVE_CRFS, LIVE_VMAFS, out qa, out qb, out qc, out degenerate);
    for (int crf = 0; crf <= 51; crf++) {
        double v = SmartOptimizerLogic.evaluate_vmaf_at_crf (qa, qb, qc, crf);
        assert (v >= 0.0 && v <= 100.0);
    }
}

void test_saturated_points_are_rejected () {
    // women-4k-testvid0 reads VMAF 99.985 at CRF 16 — no gradient. Keeping it
    // cost 3.43 VMAF of prediction error in the Phase 0 held-out test.
    int[] kept_crfs;
    double[] kept_vmafs;
    int kept = SmartOptimizerLogic.filter_saturated_vmaf_points (
        SAT_CRFS, SAT_VMAFS, out kept_crfs, out kept_vmafs);

    // 99.985 (CRF 16) and 99.528 (CRF 20) are both at or above the 99.5
    // threshold, so 3 of the 5 points survive.
    assert (kept == 3);
    assert (kept_crfs[0] == 24);
    // Still enough to fit — exactly the minimum Phase 0 validated.
    assert (kept >= SmartOptimizerLogic.VMAF_MIN_CALIBRATION_POINTS);
    for (int i = 0; i < kept_vmafs.length; i++)
        assert (kept_vmafs[i] < SmartOptimizerLogic.VMAF_SATURATION_THRESHOLD);
}

void test_solve_reproduces_measured_crf_for_target () {
    // The measured anime curve passes through (24, 92.128). Solving for
    // VMAF 92 must therefore land essentially on CRF 24.
    var m = SmartOptimizerLogic.solve_quality_crf (
        ANIME_CRFS, ANIME_VMAFS, 92.0, "x265");
    assert (!m.degenerate);
    assert (m.predicted_crf >= 23 && m.predicted_crf <= 25);

    // And (28, 88.727) → solving for 88 lands just above 28.
    var m2 = SmartOptimizerLogic.solve_quality_crf (
        ANIME_CRFS, ANIME_VMAFS, 88.0, "x265");
    assert (m2.predicted_crf >= 28 && m2.predicted_crf <= 30);
}

void test_solve_separates_content_at_high_intent () {
    // The core justification for solving instead of tabulating: at Ultra the
    // measured spread across content classes was 11.2 CRF. Anime tolerates a
    // far lower CRF than live-action for the same perceptual target, so a
    // single static "Ultra = CRF n" table cannot serve both.
    var anime = SmartOptimizerLogic.solve_quality_crf (
        ANIME_CRFS, ANIME_VMAFS, 97.0, "x265");
    var live = SmartOptimizerLogic.solve_quality_crf (
        LIVE_CRFS, LIVE_VMAFS, 97.0, "x265");

    assert (anime.predicted_crf < live.predicted_crf);
    assert (live.predicted_crf - anime.predicted_crf >= 5);

    // At Low intent the same two converge — which is why the solver earns its
    // cost at High/Ultra specifically.
    var anime_low = SmartOptimizerLogic.solve_quality_crf (
        ANIME_CRFS, ANIME_VMAFS, 88.0, "x265");
    var live_low = SmartOptimizerLogic.solve_quality_crf (
        LIVE_CRFS, LIVE_VMAFS, 88.0, "x265");
    assert (Math.fabs (
        (double) (live_low.predicted_crf - anime_low.predicted_crf)) <= 3.0);
}

void test_solve_refuses_to_fit_when_all_points_saturate () {
    // Every point visually lossless: no gradient anywhere. The solver must
    // report degenerate so the caller probes higher CRFs rather than fitting
    // noise.
    int[] crfs = { 14, 16, 18, 20 };
    double[] vmafs = { 99.99, 99.98, 99.97, 99.95 };
    var m = SmartOptimizerLogic.solve_quality_crf (crfs, vmafs, 95.0, "x265");
    assert (m.degenerate);
    assert (m.saturated_points_dropped == 4);
}

void test_screencast_target_caps_crf_and_keeps_vmaf_as_floor () {
    var p = ContentProfile () { content_type = ContentType.SCREENCAST };
    var t = SmartOptimizerLogic.resolve_quality_target (
        SmartOptimizerLogic.QualityIntent.HIGH, p);
    assert (!t.vmaf_reliable);
    assert (t.crf_cap == 22);

    // The measured screencast curve reaches VMAF 95 only past CRF 30 — a
    // score that would pass the High intent while the text is mangled.
    var m = SmartOptimizerLogic.solve_quality_crf (
        SCREEN_CRFS, SCREEN_VMAFS, 95.0, "x265");
    assert (m.predicted_crf > 28);

    // The cap must pull it back.
    int capped = SmartOptimizerLogic.apply_quality_crf_cap (m.predicted_crf, t);
    assert (capped == 22);

    // VMAF stays a FLOOR: when the solve already asks for better quality than
    // the cap, the solve wins.
    assert (SmartOptimizerLogic.apply_quality_crf_cap (18, t) == 18);
}

void test_non_screencast_target_is_unmodified () {
    var p = ContentProfile () { content_type = ContentType.LIVE_ACTION };
    var t = SmartOptimizerLogic.resolve_quality_target (
        SmartOptimizerLogic.QualityIntent.ULTRA, p);
    assert (t.vmaf_reliable);
    assert (t.crf_cap == 0);
    assert (t.target_vmaf == 97.0);
    assert (SmartOptimizerLogic.apply_quality_crf_cap (12, t) == 12);
}

void test_quality_ceiling_scales_to_trim_window () {
    int64 src = (int64) (1000.0 * 1024.0);          // 1000 KiB source
    double full = SmartOptimizerLogic.quality_ceiling_kib (src, 0, 0);
    assert (close_to (full, 2000.0, 1e-6));          // 2x source

    // Half the file trimmed away → half the ceiling, so a short clip cannot
    // spend the whole file's allowance.
    double half = SmartOptimizerLogic.quality_ceiling_kib (src, 50.0, 100.0);
    assert (close_to (half, 1000.0, 1e-6));

    assert (SmartOptimizerLogic.quality_ceiling_kib (0, 10.0, 100.0) == 0.0);
}

void test_size_ceiling_clamps_and_reports_achieved_quality () {
    // Fit both curves from the same measured anime probes.
    double sa, sb, sc;
    bool sdeg;
    SmartOptimizerLogic.fit_calibration_curve (
        ANIME_CRFS, ANIME_SIZES, out sa, out sb, out sc, out sdeg);
    double va, vb, vc;
    bool vdeg;
    SmartOptimizerLogic.fit_vmaf_curve (
        ANIME_CRFS, ANIME_VMAFS, out va, out vb, out vc, out vdeg);

    // Ultra on this source solves near CRF 16, which the measured curve puts
    // at ~135 MB. A 20 MB ceiling must force the CRF up.
    var o = SmartOptimizerLogic.apply_quality_size_ceiling (
        16, 20000.0, sa, sb, sc, va, vb, vc, 8, 51);
    assert (o.clamped);
    assert (o.final_crf > 16);
    assert (o.estimated_size_kib <= 20000.0);
    // And it must report the quality actually achieved, not the one requested.
    assert (o.achieved_vmaf < 95.0);
    assert (o.achieved_vmaf > 0.0);
}

void test_size_ceiling_is_inert_when_output_already_fits () {
    double sa, sb, sc;
    bool sdeg;
    SmartOptimizerLogic.fit_calibration_curve (
        ANIME_CRFS, ANIME_SIZES, out sa, out sb, out sc, out sdeg);
    double va, vb, vc;
    bool vdeg;
    SmartOptimizerLogic.fit_vmaf_curve (
        ANIME_CRFS, ANIME_VMAFS, out va, out vb, out vc, out vdeg);

    // Generous ceiling → the solved CRF must pass through untouched, byte for
    // byte. This is what makes the multiplier safe to retune later.
    var o = SmartOptimizerLogic.apply_quality_size_ceiling (
        24, 10000000.0, sa, sb, sc, va, vb, vc, 8, 51);
    assert (!o.clamped);
    assert (o.final_crf == 24);

    // Unknown source size (ceiling 0) must also be inert, not treated as zero
    // allowance.
    var o2 = SmartOptimizerLogic.apply_quality_size_ceiling (
        24, 0.0, sa, sb, sc, va, vb, vc, 8, 51);
    assert (!o2.clamped);
    assert (o2.final_crf == 24);
}

void test_quality_calibration_ladders_widen_toward_ultra () {
    foreach (string codec in new string[] { "x265", "x264", "vp9", "svt-av1" }) {
        var low = SmartOptimizerLogic.pick_quality_calibration_crfs (
            codec, SmartOptimizerLogic.QualityIntent.LOW);
        var ultra = SmartOptimizerLogic.pick_quality_calibration_crfs (
            codec, SmartOptimizerLogic.QualityIntent.ULTRA);

        // Three points — Phase 0 showed that is sufficient for a quality solve.
        assert (low.length == SmartOptimizerLogic.VMAF_MIN_CALIBRATION_POINTS);
        assert (ultra.length == SmartOptimizerLogic.VMAF_MIN_CALIBRATION_POINTS);

        // Ascending, and Ultra brackets lower CRFs than Low.
        for (int i = 1; i < low.length; i++) assert (low[i] > low[i - 1]);
        for (int i = 1; i < ultra.length; i++) assert (ultra[i] > ultra[i - 1]);
        assert (ultra[0] < low[0]);

        // Ultra's bracket is wider, because the measured cross-content spread
        // is 11.2 CRF there versus 1.1 at Low.
        assert ((ultra[ultra.length - 1] - ultra[0]) > (low[low.length - 1] - low[0]));

        // Every point must sit inside the codec's own valid range.
        int lo, hi;
        SmartOptimizerLogic.crf_range_for_codec (codec, out lo, out hi);
        foreach (int c in ultra) assert (c >= lo && c <= hi);
        foreach (int c in low) assert (c >= lo && c <= hi);
    }
}

void test_fit_residual_is_ignored_on_a_three_point_solve () {
    // A quadratic through exactly 3 points interpolates them exactly, so the
    // residual is zero by construction and proves nothing. Confidence must not
    // read that as a perfect fit.
    int[] crfs = { 17, 23, 29 };
    double[] vmafs = { 98.608, 98.218, 91.544 };   // measured, women-1080p
    var m = SmartOptimizerLogic.solve_quality_crf (crfs, vmafs, 95.0, "x265");
    assert (!m.degenerate);
    assert (m.fit_rmse < 1e-6);              // structurally zero
    assert (m.cal_crfs.length == 3);

    // Solving VMAF 95 on this curve lands between the 23 and 29 samples.
    assert (m.predicted_crf >= 25 && m.predicted_crf <= 28);
}

void test_verification_delta_drives_confidence () {
    int[] crfs = { 17, 23, 29 };
    double[] vmafs = { 98.608, 98.218, 91.544 };
    var m = SmartOptimizerLogic.solve_quality_crf (crfs, vmafs, 95.0, "x265");

    double no_verify = SmartOptimizerLogic.assess_quality_confidence (
        m, 0.5, true, null);

    // A verification that reproduces the prediction leaves confidence alone.
    var good = new SmartOptimizerLogic.VmafVerification ();
    good.done = true;
    good.delta = 0.2;
    double agreed = SmartOptimizerLogic.assess_quality_confidence (
        m, 0.5, true, good);
    assert (close_to (agreed, no_verify, 1e-9));

    // A solve whose own answer does not reproduce must be trusted less,
    // however tidy the curve looked.
    var bad = new SmartOptimizerLogic.VmafVerification ();
    bad.done = true;
    bad.delta = -4.5;
    double disagreed = SmartOptimizerLogic.assess_quality_confidence (
        m, 0.5, true, bad);
    assert (disagreed < agreed);

    // Screencast: VMAF cannot rank the content, so the CRF cap is doing the
    // real work and the metric-derived answer deserves less trust.
    double unreliable = SmartOptimizerLogic.assess_quality_confidence (
        m, 0.5, false, good);
    assert (unreliable < agreed);
}

void test_content_override_beats_the_classifier () {
    // Measured anime readings that the classifier lands on ANIME anyway.
    var p = ContentProfile () {
        edge_mean = 2.67, saturation_mean = 13.74,
        saturation_stddev = 8.59, temporal_diff_mean = 4.55
    };
    SmartOptimizerLogic.classify_content (ref p);
    assert (p.type_confidence <= SmartOptimizerLogic.ANIME_MAX_CONFIDENCE);

    // A user assertion is better evidence than any signal available here, so
    // it replaces the verdict AND lifts confidence to full — which lets
    // choose_preset_index interpolate all the way to the content ideal.
    SmartOptimizerLogic.apply_content_override (ref p, ContentOverride.SCREENCAST);
    assert (p.content_type == ContentType.SCREENCAST);
    assert (p.type_confidence == 1.0);

    // AUTO must leave the measurement untouched.
    var q = ContentProfile () {
        edge_mean = 5.63, saturation_mean = 13.95,
        saturation_stddev = 1.86, temporal_diff_mean = 10.15
    };
    SmartOptimizerLogic.classify_content (ref q);
    var before = q.content_type;
    double conf_before = q.type_confidence;
    SmartOptimizerLogic.apply_content_override (ref q, ContentOverride.AUTO);
    assert (q.content_type == before);
    assert (q.type_confidence == conf_before);
}

void test_delivery_prefers_8bit_but_never_breaks_hdr () {
    var ten = BitDepthDecision () {
        pix_fmt = PixelFormat.YUV420P10LE, is_10bit = true,
        reason = "High banding risk"
    };
    var sdr = SmartOptimizerVideoInfo ();

    // Delivery off: untouched.
    var a = SmartOptimizerLogic.apply_delivery_bit_depth_preference (
        ten, false, sdr, false);
    assert (a.is_10bit);

    // Delivery on, SDR source: drop to 8-bit for compatibility.
    var b = SmartOptimizerLogic.apply_delivery_bit_depth_preference (
        ten, true, sdr, false);
    assert (!b.is_10bit);
    assert (b.pix_fmt == PixelFormat.YUV420P);

    // HDR without tone mapping: 10-bit is NOT optional. Shipping a broken
    // picture is worse than one some devices decode in software.
    var hdr = SmartOptimizerVideoInfo () { color_transfer = "smpte2084" };
    var c = SmartOptimizerLogic.apply_delivery_bit_depth_preference (
        ten, true, hdr, false);
    assert (c.is_10bit);

    // Same source WITH tone mapping is being converted to SDR anyway.
    var d = SmartOptimizerLogic.apply_delivery_bit_depth_preference (
        ten, true, hdr, true);
    assert (!d.is_10bit);

    // BT.2020 wide gamut is the same story as HDR.
    var wide = SmartOptimizerVideoInfo () { color_primaries = "bt2020" };
    var e = SmartOptimizerLogic.apply_delivery_bit_depth_preference (
        ten, true, wide, false);
    assert (e.is_10bit);

    // An already-8-bit decision is never "upgraded".
    var eight = BitDepthDecision () {
        pix_fmt = PixelFormat.YUV420P, is_10bit = false, reason = "Standard"
    };
    var f = SmartOptimizerLogic.apply_delivery_bit_depth_preference (
        eight, true, sdr, false);
    assert (!f.is_10bit);
}

void test_nominal_tier_agrees_with_effort_axis () {
    // The whole point of the nominal tier: it must reach the SAME point on the
    // shared effort axis as the intent does, or Quality Mode and Size Mode
    // would drive the encoder feature tables differently for equal effort.
    SmartOptimizerLogic.QualityIntent[] intents = {
        SmartOptimizerLogic.QualityIntent.LOW,
        SmartOptimizerLogic.QualityIntent.MEDIUM,
        SmartOptimizerLogic.QualityIntent.HIGH,
        SmartOptimizerLogic.QualityIntent.ULTRA
    };
    foreach (var i in intents) {
        assert (SmartOptimizerLogic.effort_from_size_tier (
                    SmartOptimizerLogic.nominal_size_tier_for_intent (i))
                == SmartOptimizerLogic.effort_from_quality_intent (i));
    }

    // Audio planning floors at MEDIUM: Quality Mode has no byte budget, so
    // multi-track preservation must never be refused on size grounds.
    assert (SmartOptimizerLogic.quality_audio_tier (
        SmartOptimizerLogic.QualityIntent.LOW) >= SizeTier.MEDIUM);
    assert (SmartOptimizerLogic.quality_audio_tier (
        SmartOptimizerLogic.QualityIntent.ULTRA) == SizeTier.XLARGE);
}

void test_intermediate_segment_budget () {
    // 4K 10-bit at 60 fps: a single 8s lossless segment is ~2 GiB, so a 4 GiB
    // budget affords very few. Quality Mode must reduce segments rather than
    // abandon the intermediate — it is the VMAF reference.
    int uhd = SmartOptimizerLogic.max_segments_for_intermediate_budget (
        3840, 2160, 60.0, 10, 8.0, SmartOptimizerLogic.INTERMEDIATE_MAX_BYTES);
    assert (uhd >= 1 && uhd <= 3);

    // 1080p 8-bit at 24 fps is far cheaper and should afford many more.
    int hd = SmartOptimizerLogic.max_segments_for_intermediate_budget (
        1920, 1080, 24.0, 8, 8.0, SmartOptimizerLogic.INTERMEDIATE_MAX_BYTES);
    assert (hd > uhd);

    // Unknown geometry yields 0 (caller treats as "cannot size it").
    assert (SmartOptimizerLogic.max_segments_for_intermediate_budget (
        0, 0, 0.0, 8, 8.0, SmartOptimizerLogic.INTERMEDIATE_MAX_BYTES) == 0);
}

void test_limit_positions_preserves_spread () {
    double[] pos = { 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 };

    // No-op when already within budget.
    assert (SmartOptimizerLogic.limit_positions (pos, 20).length == 10);
    assert (SmartOptimizerLogic.limit_positions (pos, 0).length == 10);

    // Trimming must keep the span, not just the first N — otherwise the VMAF
    // reference would only cover the opening of the video.
    double[] three = SmartOptimizerLogic.limit_positions (pos, 3);
    assert (three.length == 3);
    assert (three[0] == 10);
    assert (three[2] == 100);
    for (int i = 1; i < three.length; i++)
        assert (three[i] > three[i - 1]);
}

void test_sum_profile_range_partial_buckets () {
    double[] profile = { 1.0, 2.0, 3.0 };
    double sum = SmartOptimizerLogic.sum_profile_range (profile, 0.5, 1.5);
    assert (close_to (sum, 0.5 * 1.0 + 0.5 * 2.0, 1e-9));
    assert (close_to (SmartOptimizerLogic.sum_profile_range (profile, 0.0, 3.0), 6.0, 1e-9));
}

void test_extrapolation_weight () {
    // Flat profile → representative samples → weight 1.0
    double[] flat = new double[101];
    for (int i = 0; i < flat.length; i++) flat[i] = 10.0;
    double[] positions = { 15.0 };
    double w = SmartOptimizerLogic.compute_extrapolation_weight (flat, positions, 8.0, 0.0, 100.0);
    assert (close_to (w, 1.0, 1e-6));

    // Sample landed in a low-bitrate region → weight must rise
    double[] skewed = new double[101];
    for (int i = 0; i < skewed.length; i++) skewed[i] = 10.0;
    for (int i = 15; i < 23; i++) skewed[i] = 5.0;
    double w2 = SmartOptimizerLogic.compute_extrapolation_weight (skewed, positions, 8.0, 0.0, 100.0);
    assert (w2 > 1.4 && w2 < 1.8);

    // No profile → neutral
    assert (SmartOptimizerLogic.compute_extrapolation_weight ({}, positions, 8.0, 0.0, 100.0) == 1.0);
}

void test_pick_sample_positions_coverage () {
    // 300s video: 15% coverage target → 6 segments (base cap)
    double[] pos = SmartOptimizerLogic.pick_sample_positions (300.0, 8.0);
    assert (pos.length == 6);
    // positions stay inside the 15–85% spread window
    assert (pos[0] >= 0.0);
    assert (pos[pos.length - 1] + 8.0 <= 300.0);
    // ascending
    for (int i = 1; i < pos.length; i++) assert (pos[i] > pos[i - 1]);

    // Very short video → single position at 0
    double[] tiny = SmartOptimizerLogic.pick_sample_positions (12.0, 8.0);
    assert (tiny.length == 1 && tiny[0] == 0.0);
}

void test_pick_calibration_crfs_shape () {
    foreach (var codec in new string[] { "x264", "x265", "vp9", "svt-av1" }) {
        foreach (var tier in new SizeTier[] { SizeTier.TINY, SizeTier.SMALL,
                                              SizeTier.MEDIUM, SizeTier.LARGE, SizeTier.XLARGE }) {
            int[] crfs = SmartOptimizerLogic.pick_calibration_crfs (codec, tier);
            assert (crfs.length == 4);
            for (int i = 1; i < 4; i++) assert (crfs[i] > crfs[i - 1]);
        }
    }
    assert (SmartOptimizerLogic.pick_calibration_crfs ("svt-av1", SizeTier.XLARGE)[0] == 8);
}

void test_append_calibration_sample_sorted () {
    int[] crfs = { 16, 26 };
    double[] sizes = { 100.0, 50.0 };
    SmartOptimizerLogic.append_calibration_sample (ref crfs, ref sizes, 21, 70.0);
    assert (crfs.length == 3);
    assert (crfs[0] == 16 && crfs[1] == 21 && crfs[2] == 26);
    assert (close_to (sizes[1], 70.0, 1e-9));
}

void test_adaptive_calibration_selection () {
    int[] cal = { 16, 21, 26, 30 };
    // Prediction well inside the window → no refinement
    int[] none = SmartOptimizerLogic.pick_adaptive_calibration_crfs (23, cal, 8, 51, 6);
    assert (none.length == 0);
    // Prediction outside the window → up to 2 new CRFs, none duplicated
    int[] extra = SmartOptimizerLogic.pick_adaptive_calibration_crfs (35, cal, 8, 51, 6);
    assert (extra.length == 2);
    foreach (int c in extra) {
        assert (c >= 8 && c <= 51);
        assert (!SmartOptimizerLogic.calibration_contains_crf (cal, c));
    }
}

void test_resolve_effective_container () {
    // Strict tiers force codec defaults regardless of the user's pick
    assert (SmartOptimizerLogic.resolve_effective_container ("x264", SizeTier.TINY, "mkv") == "mp4");
    assert (SmartOptimizerLogic.resolve_effective_container ("vp9", SizeTier.SMALL, "mkv") == "webm");
    // Medium+ respects the user's choice; falls back to codec default
    assert (SmartOptimizerLogic.resolve_effective_container ("x264", SizeTier.MEDIUM, "mkv") == "mkv");
    assert (SmartOptimizerLogic.resolve_effective_container ("vp9", SizeTier.MEDIUM, "") == "webm");
}

void test_plan_audio_stream_copy_when_within_budget () {
    var info = make_video_info ({ make_audio_source ("opus", 64, false) });
    var ctx = OptimizationContext ();
    var plan = SmartOptimizerLogic.plan_audio (info, ctx, SizeTier.TINY, "webm");
    assert (plan.use_stream_copy);
    assert (plan.per_stream_kbps == 64);
    assert (plan.total_budget_kbps == 64);
    assert (plan.effective_track_count == 1);
}

void test_plan_audio_reencode_when_over_budget () {
    // 96 kbps source exceeds the 64 kbps TINY budget → tier re-encode
    var info = make_video_info ({ make_audio_source ("opus", 96, false) });
    var ctx = OptimizationContext ();
    var plan = SmartOptimizerLogic.plan_audio (info, ctx, SizeTier.TINY, "webm");
    assert (!plan.use_stream_copy);
    assert (plan.per_stream_kbps == 64);
    assert (plan.total_budget_kbps == 64);
}

void test_plan_audio_strip_and_override () {
    var info = make_video_info ({ make_audio_source ("aac", 128, false) });
    var strip_ctx = OptimizationContext () { strip_audio = true };
    var stripped = SmartOptimizerLogic.plan_audio (info, strip_ctx, SizeTier.SMALL, "mp4");
    assert (stripped.effective_track_count == 0);
    assert (stripped.per_stream_kbps == 0);

    var override_ctx = OptimizationContext () { audio_bitrate_kbps_override = 112 };
    var overridden = SmartOptimizerLogic.plan_audio (info, override_ctx, SizeTier.SMALL, "mp4");
    assert (!overridden.use_stream_copy);
    assert (overridden.per_stream_kbps == 112);
    assert (overridden.total_budget_kbps == 112);
}

void test_plan_audio_multitrack_gated_by_tier () {
    var info = make_video_info ({
        make_audio_source ("aac", 128, false),
        make_audio_source ("ac3", 192, false)
    });
    var ctx = OptimizationContext () { preserve_all_audio_tracks_requested = true };

    // Small tier: multi-track request overridden, first track only
    var small = SmartOptimizerLogic.plan_audio (info, ctx, SizeTier.SMALL, "mp4");
    assert (!small.preserve_all_effective);
    assert (small.effective_track_count == 1);

    // Medium tier: honoured
    var medium = SmartOptimizerLogic.plan_audio (info, ctx, SizeTier.MEDIUM, "mkv");
    assert (medium.preserve_all_effective);
    assert (medium.effective_track_count == 2);
}

void test_compute_size_budget () {
    var info = make_video_info ({ make_audio_source ("opus", 64, false) });
    var ctx = OptimizationContext ();
    var plan = SmartOptimizerLogic.plan_audio (info, ctx, SizeTier.TINY, "webm");
    var budget = SmartOptimizerLogic.compute_size_budget (4, "webm", 60.0, 30.0, plan);

    assert (close_to (budget.target_total_kib, 4096.0, 1e-9));
    // 64 kbps × 60 s ≈ 469 KiB of audio
    assert (close_to (budget.audio_kib, 64.0 * 1000.0 * 60.0 / (8.0 * 1024.0), 1.0));
    assert (budget.container_overhead_kib > 0);
    assert (close_to (budget.video_target_kib,
        budget.target_total_kib - budget.audio_kib - budget.container_overhead_kib, 1e-9));
    assert (budget.available_video_kbps > 0);
}

void test_infeasibility_message_suggests_options () {
    string msg = SmartOptimizerLogic.build_infeasibility_message (40, 500.0, 1920, 1080);
    assert ("Trim to" in msg);
    assert ("Scale to" in msg);
}

void test_choose_preset_index () {
    var anime = ContentProfile () {
        content_type = ContentType.ANIME,
        type_confidence = 1.0
    };
    // TINY + fully confident anime → ideal preset 7
    assert (SmartOptimizerLogic.choose_preset_index (anime, SizeTier.TINY, "x264") == 7);

    var unsure = ContentProfile () {
        content_type = ContentType.LIVE_ACTION,
        type_confidence = 0.0
    };
    // Zero confidence → stays at the tier-safe baseline
    assert (SmartOptimizerLogic.choose_preset_index (unsure, SizeTier.TINY, "x264") == 5);
}

void test_adaptive_expansion_count () {
    var variable = ContentProfile () {
        temporal_diff_mean = 10.0,
        temporal_diff_stddev = 8.0    // CV 0.8 > 0.60
    };
    int expanded = SmartOptimizerLogic.adaptive_expansion_count (variable, 6, 200.0, 8.0);
    assert (expanded == 16);

    var steady = ContentProfile () {
        temporal_diff_mean = 10.0,
        temporal_diff_stddev = 2.0    // CV 0.2
    };
    assert (SmartOptimizerLogic.adaptive_expansion_count (steady, 6, 200.0, 8.0) == 0);
}

void test_budget_expanded_count () {
    // n_encodes 7 in batches of 4 → ceil(7/4) = 2 waves.
    // desired 16, base 3, hard cap 16, budget 90s.

    // 720p/preset4-like: cheap, ~1.5s/segment → 2*1.5 = 3s/segment of wall;
    // budget allows 30 → expands to the full desired 16.
    assert (SmartOptimizerLogic.budget_expanded_count (16, 3, 1.5, 7, 4, 90.0, 16) == 16);

    // 4K/preset7-like: expensive, ~27s/segment → 2*27 = 54s/segment;
    // budget allows floor(90/54)=1 → clamps UP to the base floor 3 (no expansion).
    assert (SmartOptimizerLogic.budget_expanded_count (16, 3, 27.0, 7, 4, 90.0, 16) == 3);

    // Mid cost: ~6s/segment → 2*6 = 12s; budget allows floor(90/12)=7 → 7 (< desired 16).
    assert (SmartOptimizerLogic.budget_expanded_count (16, 3, 6.0, 7, 4, 90.0, 16) == 7);

    // Never exceed the desired count even when the machine is very fast.
    assert (SmartOptimizerLogic.budget_expanded_count (8, 3, 0.01, 7, 4, 90.0, 16) == 8);

    // Never exceed the hard cap even if desired somehow did.
    assert (SmartOptimizerLogic.budget_expanded_count (20, 3, 0.01, 7, 4, 90.0, 16) == 16);

    // Degenerate probe (0s) or bad inputs → fall back to base, no expansion.
    assert (SmartOptimizerLogic.budget_expanded_count (16, 3, 0.0, 7, 4, 90.0, 16) == 3);
    assert (SmartOptimizerLogic.budget_expanded_count (16, 3, 6.0, 7, 0, 90.0, 16) == 3);

    // More parallelism → fewer waves → more segments affordable.
    // Same 12s/segment cost, different core budgets:
    //   4-wide: ceil(7/4)=2 waves → 24s/seg → floor(90/24)=3 → base 3.
    //   8-wide: ceil(7/8)=1 wave  → 12s/seg → floor(90/12)=7 → 7.
    assert (SmartOptimizerLogic.budget_expanded_count (16, 3, 12.0, 7, 4, 90.0, 16) == 3);
    assert (SmartOptimizerLogic.budget_expanded_count (16, 3, 12.0, 7, 8, 90.0, 16) == 7);
}

void test_grain_warranted () {
    // Clean sources (below LOW=0.0015) → no grain, EVEN when the category
    // heuristic would say yes. This is the fix: clean 4K/HDR (TOUT ~0.0002)
    // classified as Mixed no longer gets pointless film-grain synthesis.
    assert (!SmartOptimizerLogic.grain_warranted (0.0002, ContentType.MIXED));
    assert (!SmartOptimizerLogic.grain_warranted (0.0002, ContentType.LIVE_ACTION));
    // Boundary: exactly LOW is treated as clean.
    assert (!SmartOptimizerLogic.grain_warranted (0.0015, ContentType.MIXED));

    // Clearly grainy (at/above HIGH=0.004) → grain, overriding category.
    assert (SmartOptimizerLogic.grain_warranted (0.006, ContentType.MIXED));
    assert (SmartOptimizerLogic.grain_warranted (0.004, ContentType.ANIME));

    // Ambiguous middle band → defer to the category heuristic (regression-safe).
    assert (SmartOptimizerLogic.grain_warranted (0.0025, ContentType.MIXED));
    assert (SmartOptimizerLogic.grain_warranted (0.0025, ContentType.LIVE_ACTION));
    assert (!SmartOptimizerLogic.grain_warranted (0.0025, ContentType.ANIME));
    assert (!SmartOptimizerLogic.grain_warranted (0.0025, ContentType.SCREENCAST));

    // No measurement (0.0) → category heuristic exactly as before.
    assert (SmartOptimizerLogic.grain_warranted (0.0, ContentType.MIXED));
    assert (!SmartOptimizerLogic.grain_warranted (0.0, ContentType.SCREENCAST));
}

void test_decide_bit_depth_rules () {
    var profile = ContentProfile ();
    var hdr = make_video_info ({});
    hdr.color_transfer = "smpte2084";
    hdr.color_primaries = "bt2020";

    // x264 never goes 10-bit, even for HDR
    var x264 = SmartOptimizerLogic.decide_bit_depth (hdr, profile, SizeTier.MEDIUM, "x264", false);
    assert (!x264.is_10bit);

    // Other codecs preserve HDR in 10-bit
    var av1 = SmartOptimizerLogic.decide_bit_depth (hdr, profile, SizeTier.MEDIUM, "svt-av1", false);
    assert (av1.is_10bit);

    // Tone-mapped HDR → 8-bit is enough
    var mapped = SmartOptimizerLogic.decide_bit_depth (hdr, profile, SizeTier.MEDIUM, "svt-av1", true);
    assert (!mapped.is_10bit);
}

void test_banding_metrics_dark_content () {
    var profile = ContentProfile ();
    double[] yavg = { 30.0, 40.0, 50.0, 55.0 };   // all below 60 → dark
    double[] ylow = {};
    SmartOptimizerLogic.compute_banding_metrics (ref profile, yavg, ylow, 1920, 1080);
    assert (close_to (profile.dark_scene_ratio, 1.0, 1e-9));
    assert (profile.banding_risk > 0.0);
}

void test_audio_measurement_floor () {
    // 2 kbps against a 64 kbps tier budget = sampled silence → floor at 25%
    assert (SmartOptimizerLogic.floor_measured_audio_kbps (2, 64) == 16);
    assert (SmartOptimizerLogic.floor_measured_audio_kbps (16, 64) == 16);
    assert (SmartOptimizerLogic.floor_measured_audio_kbps (20, 128) == 32);
    // Plausible measurements pass through untouched
    assert (SmartOptimizerLogic.floor_measured_audio_kbps (50, 64) == 50);
    assert (SmartOptimizerLogic.floor_measured_audio_kbps (90, 64) == 90);
}

// ── Content classification, against real corpus measurements ────────────────
//
// Every row below is a MEASURED reading from the 16-file corpus
// (/mnt/storage3/testvideos, see docs/smart-optimizer-phase0-findings.md).
// These are the regression fixture: the previous thresholds were calibrated
// for an edge scale the measurement never produces, which made SCREENCAST and
// ANIME unreachable and misfiled screencasts as anime.

private ContentProfile corpus_profile (double edge, double sat,
                                       double sat_sd, double ydif) {
    return ContentProfile () {
        edge_mean = edge,
        saturation_mean = sat,
        saturation_stddev = sat_sd,
        temporal_diff_mean = ydif,
        temporal_diff_stddev = 0.0
    };
}

private ContentType classify_corpus (double edge, double sat,
                                     double sat_sd, double ydif) {
    var p = corpus_profile (edge, sat, sat_sd, ydif);
    SmartOptimizerLogic.classify_content (ref p);
    return p.content_type;
}

void test_classify_screencast_prefers_siti_when_available () {
    // Measured corpus values. `si` separates screen content by a far wider
    // margin than edge density, which does not separate it at all.
    var p = corpus_profile (5.28, 14.45, 2.52, 0.85);
    p.spatial_info = 115.4;
    SmartOptimizerLogic.classify_content (ref p);
    assert (p.content_type == ContentType.SCREENCAST);
    assert (p.type_confidence >= 0.9);

    // random-testvid3 has the second-highest si in the corpus (101.8) but the
    // highest motion (18.45) — high spatial detail with heavy motion is live
    // action, not a screen capture. The motion conjunct separates them, and it
    // comes from YDIF rather than siti's TI, which would be measured across
    // the decimation gaps.
    var q = corpus_profile (12.12, 17.54, 9.77, 18.45);
    q.spatial_info = 101.8;
    SmartOptimizerLogic.classify_content (ref q);
    assert (q.content_type != ContentType.SCREENCAST);

    // Highest si among the remaining corpus (74.2) must not trip it either.
    var r = corpus_profile (8.27, 13.78, 6.17, 11.64);
    r.spatial_info = 74.2;
    SmartOptimizerLogic.classify_content (ref r);
    assert (r.content_type != ContentType.SCREENCAST);
}

void test_classify_falls_back_when_siti_missing () {
    // siti unavailable (older ffmpeg, or a failed pass) leaves si at 0. The
    // edge/motion rule must still fire so detection degrades rather than
    // disappearing.
    var p = corpus_profile (5.28, 14.45, 2.52, 0.85);
    assert (p.spatial_info == 0.0);
    SmartOptimizerLogic.classify_content (ref p);
    assert (p.content_type == ContentType.SCREENCAST);

    // And a source that only LOOKS like a screencast on the fallback signals
    // must not be promoted once siti says otherwise: real si, low enough to
    // fail the primary test, routes to the fallback being skipped entirely.
    var q = corpus_profile (5.28, 14.45, 2.52, 0.85);
    q.spatial_info = 30.0;    // measured, but nothing like screen content
    SmartOptimizerLogic.classify_content (ref q);
    assert (q.content_type != ContentType.SCREENCAST);
}

void test_classify_screencast_is_reachable () {
    // Screencast-testvid0.webm — the case the old gate could never reach
    // (it demanded edge > 25.0; nothing in the corpus exceeds 12.96).
    var p = corpus_profile (5.28, 14.45, 2.52, 0.85);
    SmartOptimizerLogic.classify_content (ref p);
    assert (p.content_type == ContentType.SCREENCAST);
    assert (p.type_confidence >= 0.5);

    // short-testvid0.mkv is the nearest confusable on motion (ydif 1.95) but
    // carries almost no edge structure — the edge conjunct must exclude it.
    assert (classify_corpus (1.40, 6.70, 1.38, 1.95) != ContentType.SCREENCAST);
}

void test_classify_screencast_not_labelled_anime () {
    // Direct regression on the old behaviour: the screencast scored 0.653 on
    // the anime heuristic and came back ANIME.
    assert (classify_corpus (5.28, 14.45, 2.52, 0.85) != ContentType.ANIME);
}

void test_classify_anime_is_reachable () {
    // Both real anime sources. Under the old thresholds ANIME was
    // arithmetically unreachable — max achievable score equalled the
    // threshold it had to exceed — so both landed in MIXED.
    assert (classify_corpus (2.67, 13.74, 8.59, 4.55) == ContentType.ANIME);
    assert (classify_corpus (3.15, 7.27, 3.03, 3.13) == ContentType.ANIME);
}

void test_classify_anime_confidence_is_capped () {
    // The corpus shows animation is not reliably separable from slow, flat
    // live-action. Confidence must stay low so choose_preset_index keeps the
    // preset near the tier baseline rather than jumping to the anime ideal.
    var p = corpus_profile (2.67, 13.74, 8.59, 4.55);
    SmartOptimizerLogic.classify_content (ref p);
    assert (p.content_type == ContentType.ANIME);
    assert (p.type_confidence <= SmartOptimizerLogic.ANIME_MAX_CONFIDENCE);
}

void test_classify_live_action_high_motion () {
    // Every corpus file above the motion threshold, lowest first.
    assert (classify_corpus (5.51, 11.46, 4.86,  6.37) == ContentType.LIVE_ACTION);
    assert (classify_corpus (0.21, 34.27, 1.57,  7.54) == ContentType.LIVE_ACTION);
    assert (classify_corpus (2.10, 11.86, 8.63,  9.72) == ContentType.LIVE_ACTION);
    assert (classify_corpus (5.63, 13.95, 1.86, 10.15) == ContentType.LIVE_ACTION);
    assert (classify_corpus (12.96, 19.78, 1.40, 10.46) == ContentType.LIVE_ACTION);
    assert (classify_corpus (8.27, 13.78, 6.17, 11.64) == ContentType.LIVE_ACTION);
    assert (classify_corpus (0.35,  9.38, 2.93, 11.71) == ContentType.LIVE_ACTION);
    assert (classify_corpus (2.37, 33.23, 9.89, 13.83) == ContentType.LIVE_ACTION);
    assert (classify_corpus (12.12, 17.54, 9.77, 18.45) == ContentType.LIVE_ACTION);
}

void test_classify_mixed_is_the_honest_default () {
    // Low motion, no distinguishing structure. MIXED is a legitimate verdict,
    // not a failure — it damps preset interpolation toward the tier baseline.
    // short-testvid0: too little edge content for either screencast or anime.
    assert (classify_corpus (1.40, 6.70, 1.38, 1.95) == ContentType.MIXED);
    // random-testvid1: same, fractionally more motion.
    assert (classify_corpus (1.62, 9.46, 0.49, 2.81) == ContentType.MIXED);
    // random-testvid2: edge above the animation band.
    assert (classify_corpus (4.80, 20.04, 7.27, 2.70) == ContentType.MIXED);
}

void test_classify_no_longer_collapses_to_mixed () {
    // The old classifier put 10 of 16 corpus files in MIXED. Assert the
    // distribution is actually discriminating now.
    double[,] corpus = {
        //  edge,   sat, satSD,  ydif
        {  5.28, 14.45,  2.52,  0.85 },   // screencast
        {  2.67, 13.74,  8.59,  4.55 },   // anime
        {  3.15,  7.27,  3.03,  3.13 },   // anime
        {  1.40,  6.70,  1.38,  1.95 },   // film, slow
        {  5.51, 11.46,  4.86,  6.37 },   // film
        {  0.35,  9.38,  2.93, 11.71 },   // film
        {  2.37, 33.23,  9.89, 13.83 },   // film
        {  2.10, 11.86,  8.63,  9.72 },   // live
        {  0.21, 34.27,  1.57,  7.54 },   // live
        {  8.27, 13.78,  6.17, 11.64 },   // live
        {  5.63, 13.95,  1.86, 10.15 },   // live
        { 12.96, 19.78,  1.40, 10.46 },   // live
        {  2.46,  9.21,  1.65,  3.65 },   // misc
        {  1.62,  9.46,  0.49,  2.81 },   // misc
        { 12.12, 17.54,  9.77, 18.45 },   // misc
        {  4.80, 20.04,  7.27,  2.70 }    // misc
    };
    int mixed = 0;
    for (int i = 0; i < corpus.length[0]; i++) {
        if (classify_corpus (corpus[i, 0], corpus[i, 1],
                             corpus[i, 2], corpus[i, 3]) == ContentType.MIXED)
            mixed++;
    }
    // Was 10/16. Anything approaching that means the classifier has gone
    // degenerate again.
    assert (mixed <= 4);
}

void test_downscale_advisory () {
    // Real-world case: SVT-AV1 at 450 kbps for 1280×608 @ 25 fps
    // → bpp ≈ 0.023, below the 0.028 threshold.
    var adv = SmartOptimizerLogic.assess_downscale ("svt-av1", 450, 1280, 608, 25.0, false);
    assert (adv != null);
    assert (close_to (adv.bpp, 450000.0 / (1280.0 * 608.0 * 25.0), 1e-9));
    assert (adv.new_width % 2 == 0 && adv.new_height % 2 == 0);
    assert (adv.new_width < 1280 && adv.new_height < 608);
    assert (adv.new_width >= 320 && adv.new_height >= 240);
    assert (adv.scale_factor <= 0.9);

    // Plenty of bitrate → no advisory
    assert (SmartOptimizerLogic.assess_downscale ("svt-av1", 4000, 1280, 608, 25.0, false) == null);
    // Filter chain already rescales → no advisory
    assert (SmartOptimizerLogic.assess_downscale ("svt-av1", 450, 1280, 608, 25.0, true) == null);
    // Suggestion would fall below 320×240 → no advisory
    assert (SmartOptimizerLogic.assess_downscale ("svt-av1", 100, 640, 360, 30.0, false) == null);
    // x264 needs more bits per pixel than AV1 — its threshold is higher
    assert (SmartOptimizerLogic.bpp_low_threshold ("x264")
        > SmartOptimizerLogic.bpp_low_threshold ("svt-av1"));
}

void test_intermediate_estimate () {
    double est = SmartOptimizerLogic.estimate_intermediate_bytes (1920, 1080, 30.0, 8, 48.0);
    assert (est > 0);
    assert (close_to (est,
        1920.0 * 1080.0 * 1.5 * 30.0 * 48.0 * SmartOptimizerLogic.INTERMEDIATE_LOSSLESS_RATIO,
        1.0));
    // 10-bit doubles the raw frame size
    double est10 = SmartOptimizerLogic.estimate_intermediate_bytes (1920, 1080, 30.0, 10, 48.0);
    assert (close_to (est10, est * 2.0, 1.0));
    // Unknown dimensions → 0 (callers skip the intermediate)
    assert (SmartOptimizerLogic.estimate_intermediate_bytes (0, 1080, 30.0, 8, 48.0) == 0.0);
    // Long 4K 10-bit sample sets blow past the guard
    assert (SmartOptimizerLogic.estimate_intermediate_bytes (3840, 2160, 30.0, 10, 128.0)
        > SmartOptimizerLogic.INTERMEDIATE_MAX_BYTES);
}

void test_cache_stores_vmaf_and_stays_compatible () {
    string input = "";
    string store = "";
    try {
        Posix.close (FileUtils.open_tmp ("smartopt-vcache-input-XXXXXX.dat", out input));
        FileUtils.set_contents (input, "dummy quality cache input");
        Posix.close (FileUtils.open_tmp ("smartopt-vcache-store-XXXXXX.json", out store));
        FileUtils.unlink (store);
    } catch (Error e) {
        assert_not_reached ();
    }
    SmartOptimizerCache.cache_file_override = store;

    double[] positions = { 10.0, 50.0, 90.0 };
    var c1 = SmartOptimizerCache.try_create (
        input, "x265", 5, "yuv420p", "", 0.0, 100.0, 8.0, positions, 1.0);
    assert (c1 != null);

    // A size-only sample (what Size Mode writes) and a quality sample.
    c1.record (30, 1000.0);
    c1.record_with_vmaf (23, 2000.0, 96.88);
    c1.save ();

    var c2 = SmartOptimizerCache.try_create (
        input, "x265", 5, "yuv420p", "", 0.0, 100.0, 8.0, positions, 1.0);
    assert (c2 != null);

    double size, vmaf;
    // The quality sample round-trips with its score.
    assert (c2.lookup_with_vmaf (23, out size, out vmaf));
    assert (close_to (size, 2000.0, 1e-6));
    assert (close_to (vmaf, 96.88, 1e-6));

    // The size-only sample must MISS the quality lookup: without a score the
    // quality solver would still have to encode it, so there is nothing saved.
    assert (!c2.lookup_with_vmaf (30, out size, out vmaf));
    // …but it is still a perfectly good size hit.
    assert (c2.lookup (30, out size) && close_to (size, 1000.0, 1e-6));

    // Both remain visible to the plain size lookup.
    assert (c2.lookup (23, out size) && close_to (size, 2000.0, 1e-6));
    assert (c2.sample_count == 2);

    // A later size-only write must not silently discard a measured score.
    c2.record (23, 2100.0);
    c2.save ();
    var c3 = SmartOptimizerCache.try_create (
        input, "x265", 5, "yuv420p", "", 0.0, 100.0, 8.0, positions, 1.0);
    assert (c3 != null);
    assert (c3.lookup_with_vmaf (23, out size, out vmaf));
    assert (close_to (size, 2100.0, 1e-6));
    assert (close_to (vmaf, 96.88, 1e-6));

    SmartOptimizerCache.cache_file_override = null;
    FileUtils.unlink (input);
    FileUtils.unlink (store);
}

void test_cache_reads_legacy_two_element_samples () {
    // Entries written before quality mode existed are [crf, size] pairs with
    // no third element. They must still load, as size-only samples.
    string input = "";
    string store = "";
    try {
        Posix.close (FileUtils.open_tmp ("smartopt-legacy-input-XXXXXX.dat", out input));
        FileUtils.set_contents (input, "legacy cache input");
        Posix.close (FileUtils.open_tmp ("smartopt-legacy-store-XXXXXX.json", out store));
    } catch (Error e) {
        assert_not_reached ();
    }
    SmartOptimizerCache.cache_file_override = store;

    double[] positions = { 10.0, 50.0, 90.0 };
    // Write a legacy-shaped store through the old API, then confirm the new
    // reader treats it as size-only rather than choking or inventing a score.
    var writer = SmartOptimizerCache.try_create (
        input, "x265", 5, "yuv420p", "", 0.0, 100.0, 8.0, positions, 1.0);
    assert (writer != null);
    writer.record (28, 4321.0);
    writer.save ();

    var reader = SmartOptimizerCache.try_create (
        input, "x265", 5, "yuv420p", "", 0.0, 100.0, 8.0, positions, 1.0);
    assert (reader != null);
    double size, vmaf;
    assert (reader.lookup (28, out size) && close_to (size, 4321.0, 1e-6));
    assert (!reader.lookup_with_vmaf (28, out size, out vmaf));

    SmartOptimizerCache.cache_file_override = null;
    FileUtils.unlink (input);
    FileUtils.unlink (store);
}

void test_calibration_cache_round_trip () {
    string input = "";
    string store = "";
    try {
        Posix.close (FileUtils.open_tmp ("smartopt-cache-input-XXXXXX.dat", out input));
        FileUtils.set_contents (input, "dummy calibration cache input");
        Posix.close (FileUtils.open_tmp ("smartopt-cache-store-XXXXXX.json", out store));
        FileUtils.unlink (store);   // start with no store on disk
    } catch (Error e) {
        assert_not_reached ();
    }
    SmartOptimizerCache.cache_file_override = store;

    double[] positions = { 10.0, 50.0, 90.0 };
    var c1 = SmartOptimizerCache.try_create (
        input, "svt-av1", 4, "yuv420p", "", 0.0, 100.0, 8.0, positions, 1.0);
    assert (c1 != null);
    double v;
    assert (!c1.lookup (30, out v));
    c1.record (30, 1234.5);
    c1.record (40, 600.25);
    c1.save ();

    // Same parameters → same key → both samples come back
    var c2 = SmartOptimizerCache.try_create (
        input, "svt-av1", 4, "yuv420p", "", 0.0, 100.0, 8.0, positions, 1.0);
    assert (c2 != null);
    assert (c2.lookup (30, out v) && close_to (v, 1234.5, 1e-6));
    assert (c2.lookup (40, out v) && close_to (v, 600.25, 1e-6));
    assert (c2.sample_count == 2);

    // Any keyed parameter changing → different key → miss
    var other_codec = SmartOptimizerCache.try_create (
        input, "x264", 4, "yuv420p", "", 0.0, 100.0, 8.0, positions, 1.0);
    assert (other_codec != null && !other_codec.lookup (30, out v));
    var other_weight = SmartOptimizerCache.try_create (
        input, "svt-av1", 4, "yuv420p", "", 0.0, 100.0, 8.0, positions, 1.1);
    assert (other_weight != null && !other_weight.lookup (30, out v));
    var other_filters = SmartOptimizerCache.try_create (
        input, "svt-av1", 4, "yuv420p", "scale=640:-2", 0.0, 100.0, 8.0, positions, 1.0);
    assert (other_filters != null && !other_filters.lookup (30, out v));

    // Missing input file → no cache handle
    assert (SmartOptimizerCache.try_create (
        "/nonexistent/path.mkv", "svt-av1", 4, "yuv420p", "",
        0.0, 100.0, 8.0, positions, 1.0) == null);

    SmartOptimizerCache.cache_file_override = null;
    FileUtils.unlink (input);
    FileUtils.unlink (store);
}

SmartOptimizerLogic.CalibrationModel make_model (int predicted_crf) {
    var model = new SmartOptimizerLogic.CalibrationModel ();
    model.cal_crfs = { 16, 21, 26, 30 };
    model.cal_sizes = new double[4];
    for (int i = 0; i < 4; i++)
        model.cal_sizes[i] = Math.exp (10.0 - 0.1 * model.cal_crfs[i]);
    double qa, qb, qc;
    bool degenerate;
    SmartOptimizerLogic.fit_calibration_curve (
        model.cal_crfs, model.cal_sizes, out qa, out qb, out qc, out degenerate);
    model.qa = qa; model.qb = qb; model.qc = qc;
    model.crf_min = 8; model.crf_max = 51;
    model.cal_mid = 23.0;
    model.predicted_crf = predicted_crf;
    return model;
}

void test_assess_confidence_interpolation_vs_extrapolation () {
    // Interpolating, full coverage, clean fit → full confidence
    var inside = SmartOptimizerLogic.assess_confidence (
        make_model (23), 4000, 6, 8.0, 48.0, false, 0, 0.0, 1000, "vp9");
    assert (close_to (inside.confidence, 1.0, 1e-9));

    // Far extrapolation → 0.5
    var far = SmartOptimizerLogic.assess_confidence (
        make_model (48), 4000, 6, 8.0, 48.0, false, 0, 0.0, 1000, "vp9");
    assert (close_to (far.confidence, 0.5, 1e-9));

    // x265 psy-rd penalty applies on top
    var x265 = SmartOptimizerLogic.assess_confidence (
        make_model (23), 4000, 6, 8.0, 48.0, false, 0, 0.0, 1000, "x265");
    assert (close_to (x265.confidence, 0.85, 1e-9));
}

void test_assess_confidence_coverage_penalty () {
    // 2 × 8s of a 400s encode = 4% coverage → 0.65 floor
    var thin = SmartOptimizerLogic.assess_confidence (
        make_model (23), 4000, 2, 8.0, 400.0, false, 0, 0.0, 1000, "vp9");
    assert (close_to (thin.confidence, 0.65, 1e-9));
    assert (thin.sample_coverage < 0.05);
}

void test_decide_two_pass_policies () {
    var profile = ContentProfile ();

    // TINY: always two-pass, with the 3% bitrate safety margin
    var tiny = SmartOptimizerLogic.decide_two_pass (
        SizeTier.TINY, 4, 4096.0, 1000, 4000, 1.0, false,
        false, 0.0, 60.0, 0, 1.0, profile);
    assert (tiny.recommend_two_pass);
    assert (tiny.strict_targeting);
    assert (tiny.target_video_kbps == 970);

    // XLARGE, confident, estimate on target → CRF mode allowed
    var xl = SmartOptimizerLogic.decide_two_pass (
        SizeTier.XLARGE, 300, 307200.0, 8000, 307200, 0.9, false,
        false, 0.0, 300.0, 0, 1.0, profile);
    assert (!xl.recommend_two_pass);
    assert (xl.within_target_band);

    // MEDIUM with low confidence → two-pass
    var medium = SmartOptimizerLogic.decide_two_pass (
        SizeTier.MEDIUM, 80, 81920.0, 4000, 81920, 0.5, false,
        false, 0.0, 300.0, 0, 1.0, profile);
    assert (medium.recommend_two_pass);

    // CRF pinned at max and still 2× over target → impossible + two-pass
    var maxed = SmartOptimizerLogic.decide_two_pass (
        SizeTier.MEDIUM, 80, 81920.0, 4000, 163840, 1.0, true,
        false, 0.0, 300.0, 0, 1.0, profile);
    assert (maxed.recommend_two_pass);
    assert (maxed.is_impossible);
}

void main (string[] args) {
    Test.init (ref args);
    // The logic under test emits warning() diagnostics by design (monotonicity
    // guard, extrapolation/coverage penalties) — don't let the harness treat
    // them as fatal.
    GLib.Log.set_always_fatal (LogLevelFlags.LEVEL_ERROR);

    Test.add_func ("/smart-optimizer-logic/size-tier-boundaries", test_size_tier_boundaries);
    Test.add_func ("/smart-optimizer-logic/trim-window/no-trim", test_trim_window_no_trim);
    Test.add_func ("/smart-optimizer-logic/trim-window/basic", test_trim_window_basic_trim);
    Test.add_func ("/smart-optimizer-logic/trim-window/inverted", test_trim_window_inverted_falls_back);
    Test.add_func ("/smart-optimizer-logic/trim-window/short-source", test_trim_window_short_source_shrinks_segment);
    Test.add_func ("/smart-optimizer-logic/trim-window/effective-duration", test_trim_window_effective_duration_caps_end);
    Test.add_func ("/smart-optimizer-logic/units/round-trip", test_unit_conversions_round_trip);
    Test.add_func ("/smart-optimizer-logic/match-source/rounding", test_match_source_target_rounding);
    Test.add_func ("/smart-optimizer-logic/match-source/window-scaled", test_match_source_target_scaled_to_window);
    Test.add_func ("/smart-optimizer-logic/container-overhead/duration-scaled", test_container_overhead_scales_with_duration);
    Test.add_func ("/smart-optimizer-logic/fit/recovers-exponential", test_fit_recovers_exponential);
    Test.add_func ("/smart-optimizer-logic/fit/monotonicity-guard", test_fit_monotonicity_guard);
    Test.add_func ("/smart-optimizer-logic/fit/rmse-noise", test_fit_rmse_reports_noise);
    Test.add_func ("/smart-optimizer-logic/effort/from-size-tier", test_effort_from_size_tier_is_monotonic_and_total);
    Test.add_func ("/smart-optimizer-logic/effort/compat-container", test_tier_forces_compat_container_only_for_small_targets);
    Test.add_func ("/smart-optimizer-logic/fit/core-quadratic", test_least_squares_core_recovers_known_quadratic);
    Test.add_func ("/smart-optimizer-logic/fit/core-logit", test_least_squares_core_handles_logit_transform);
    Test.add_func ("/smart-optimizer-logic/fit/core-degenerate", test_least_squares_core_degenerate_falls_back_to_line);
    Test.add_func ("/smart-optimizer-logic/fit/log-wrapper-matches-core", test_log_curve_wrapper_matches_core);
    Test.add_func ("/smart-optimizer-logic/profile/sum-range", test_sum_profile_range_partial_buckets);
    Test.add_func ("/smart-optimizer-logic/profile/extrapolation-weight", test_extrapolation_weight);
    Test.add_func ("/smart-optimizer-logic/positions/coverage", test_pick_sample_positions_coverage);
    Test.add_func ("/smart-optimizer-logic/calibration/crf-tables", test_pick_calibration_crfs_shape);
    Test.add_func ("/smart-optimizer-logic/calibration/append-sorted", test_append_calibration_sample_sorted);
    Test.add_func ("/smart-optimizer-logic/calibration/adaptive-selection", test_adaptive_calibration_selection);
    Test.add_func ("/smart-optimizer-logic/container/resolve", test_resolve_effective_container);
    Test.add_func ("/smart-optimizer-logic/audio/stream-copy", test_plan_audio_stream_copy_when_within_budget);
    Test.add_func ("/smart-optimizer-logic/audio/reencode-over-budget", test_plan_audio_reencode_when_over_budget);
    Test.add_func ("/smart-optimizer-logic/audio/strip-and-override", test_plan_audio_strip_and_override);
    Test.add_func ("/smart-optimizer-logic/audio/multitrack-tier-gate", test_plan_audio_multitrack_gated_by_tier);
    Test.add_func ("/smart-optimizer-logic/budget/compute", test_compute_size_budget);
    Test.add_func ("/smart-optimizer-logic/budget/infeasibility-message", test_infeasibility_message_suggests_options);
    Test.add_func ("/smart-optimizer-logic/preset/choose-index", test_choose_preset_index);
    Test.add_func ("/smart-optimizer-logic/segments/adaptive-expansion", test_adaptive_expansion_count);
    Test.add_func ("/smart-optimizer-logic/segments/budget-expanded", test_budget_expanded_count);
    Test.add_func ("/smart-optimizer-logic/grain/warranted", test_grain_warranted);
    Test.add_func ("/smart-optimizer-logic/bit-depth/rules", test_decide_bit_depth_rules);
    Test.add_func ("/smart-optimizer-logic/banding/dark-content", test_banding_metrics_dark_content);
    Test.add_func ("/smart-optimizer-logic/confidence/extrapolation", test_assess_confidence_interpolation_vs_extrapolation);
    Test.add_func ("/smart-optimizer-logic/confidence/coverage", test_assess_confidence_coverage_penalty);
    Test.add_func ("/smart-optimizer-logic/policy/two-pass", test_decide_two_pass_policies);
    Test.add_func ("/smart-optimizer-logic/audio/measurement-floor", test_audio_measurement_floor);
    Test.add_func ("/smart-optimizer-logic/content/screencast-siti", test_classify_screencast_prefers_siti_when_available);
    Test.add_func ("/smart-optimizer-logic/content/siti-fallback", test_classify_falls_back_when_siti_missing);
    Test.add_func ("/smart-optimizer-logic/content/screencast-reachable", test_classify_screencast_is_reachable);
    Test.add_func ("/smart-optimizer-logic/content/screencast-not-anime", test_classify_screencast_not_labelled_anime);
    Test.add_func ("/smart-optimizer-logic/content/anime-reachable", test_classify_anime_is_reachable);
    Test.add_func ("/smart-optimizer-logic/content/anime-confidence-capped", test_classify_anime_confidence_is_capped);
    Test.add_func ("/smart-optimizer-logic/content/live-action-motion", test_classify_live_action_high_motion);
    Test.add_func ("/smart-optimizer-logic/content/mixed-default", test_classify_mixed_is_the_honest_default);
    Test.add_func ("/smart-optimizer-logic/content/not-degenerate", test_classify_no_longer_collapses_to_mixed);
    Test.add_func ("/smart-optimizer-logic/quality/intent-targets", test_quality_intent_targets_ascend);
    Test.add_func ("/smart-optimizer-logic/quality/fit-measured-curve", test_vmaf_fit_recovers_measured_curve);
    Test.add_func ("/smart-optimizer-logic/quality/evaluation-clamped", test_vmaf_evaluation_is_clamped_to_metric_range);
    Test.add_func ("/smart-optimizer-logic/quality/reject-saturated", test_saturated_points_are_rejected);
    Test.add_func ("/smart-optimizer-logic/quality/solve-measured-crf", test_solve_reproduces_measured_crf_for_target);
    Test.add_func ("/smart-optimizer-logic/quality/content-separation", test_solve_separates_content_at_high_intent);
    Test.add_func ("/smart-optimizer-logic/quality/all-saturated-degenerate", test_solve_refuses_to_fit_when_all_points_saturate);
    Test.add_func ("/smart-optimizer-logic/quality/screencast-cap", test_screencast_target_caps_crf_and_keeps_vmaf_as_floor);
    Test.add_func ("/smart-optimizer-logic/quality/target-unmodified", test_non_screencast_target_is_unmodified);
    Test.add_func ("/smart-optimizer-logic/quality/ceiling-window", test_quality_ceiling_scales_to_trim_window);
    Test.add_func ("/smart-optimizer-logic/quality/ceiling-clamps", test_size_ceiling_clamps_and_reports_achieved_quality);
    Test.add_func ("/smart-optimizer-logic/quality/ceiling-inert", test_size_ceiling_is_inert_when_output_already_fits);
    Test.add_func ("/smart-optimizer-logic/quality/calibration-ladders", test_quality_calibration_ladders_widen_toward_ultra);
    Test.add_func ("/smart-optimizer-logic/quality/three-point-residual", test_fit_residual_is_ignored_on_a_three_point_solve);
    Test.add_func ("/smart-optimizer-logic/quality/verification-confidence", test_verification_delta_drives_confidence);
    Test.add_func ("/smart-optimizer-logic/content/override", test_content_override_beats_the_classifier);
    Test.add_func ("/smart-optimizer-logic/delivery/bit-depth", test_delivery_prefers_8bit_but_never_breaks_hdr);
    Test.add_func ("/smart-optimizer-logic/quality/nominal-tier-agrees", test_nominal_tier_agrees_with_effort_axis);
    Test.add_func ("/smart-optimizer-logic/quality/intermediate-budget", test_intermediate_segment_budget);
    Test.add_func ("/smart-optimizer-logic/quality/limit-positions", test_limit_positions_preserves_spread);
    Test.add_func ("/smart-optimizer-logic/advisory/downscale", test_downscale_advisory);
    Test.add_func ("/smart-optimizer-logic/intermediate/size-estimate", test_intermediate_estimate);
    Test.add_func ("/smart-optimizer-logic/cache/round-trip", test_calibration_cache_round_trip);
    Test.add_func ("/smart-optimizer-logic/cache/vmaf-samples", test_cache_stores_vmaf_and_stays_compatible);
    Test.add_func ("/smart-optimizer-logic/cache/legacy-samples", test_cache_reads_legacy_two_element_samples);

    Test.run ();
}
