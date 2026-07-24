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

void test_mixed_confidence_floor () {
    // Scores tuned to land just inside the mixed band (anime score 0.46),
    // where the raw confidence formula would report ~10%.
    var p = ContentProfile () {
        edge_mean = 18.8,
        saturation_mean = 60.0,
        saturation_stddev = 23.9,
        temporal_diff_mean = 9.1,
        temporal_diff_stddev = 2.0
    };
    SmartOptimizerLogic.classify_content (ref p);
    assert (p.content_type == ContentType.MIXED);
    assert (p.type_confidence >= 0.25);
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
    Test.add_func ("/smart-optimizer-logic/container-overhead/duration-scaled", test_container_overhead_scales_with_duration);
    Test.add_func ("/smart-optimizer-logic/fit/recovers-exponential", test_fit_recovers_exponential);
    Test.add_func ("/smart-optimizer-logic/fit/monotonicity-guard", test_fit_monotonicity_guard);
    Test.add_func ("/smart-optimizer-logic/fit/rmse-noise", test_fit_rmse_reports_noise);
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
    Test.add_func ("/smart-optimizer-logic/content/mixed-confidence-floor", test_mixed_confidence_floor);
    Test.add_func ("/smart-optimizer-logic/advisory/downscale", test_downscale_advisory);
    Test.add_func ("/smart-optimizer-logic/intermediate/size-estimate", test_intermediate_estimate);
    Test.add_func ("/smart-optimizer-logic/cache/round-trip", test_calibration_cache_round_trip);

    Test.run ();
}
