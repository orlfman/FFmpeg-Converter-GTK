using GLib;

private void assert_equal_int (int actual, int expected, string context) {
    if (actual != expected) {
        Test.fail_printf ("%s expected %d but got %d", context, expected, actual);
    }
}

private void assert_equal_string (string actual, string expected, string context) {
    if (actual != expected) {
        Test.fail_printf ("%s expected '%s' but got '%s'", context, expected, actual);
    }
}

private void assert_true (bool value, string context) {
    if (!value) {
        Test.fail_printf ("%s expected true", context);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  REGION TEXT
// ═══════════════════════════════════════════════════════════════════════════════

private void test_parse_regions_keeps_valid_entries_and_skips_junk () {
    LogoRegion[] regions = LogoDetectorLogic.parse_regions (
        " 10:20:30:40 , 1:2:3 , a:b:c:d , 50:60:70:80 , -1:2:3:4 , 5:6:0:8 ");

    assert_equal_int (regions.length, 2, "parsed region count");
    assert_equal_string (regions[0].to_region_string (), "10:20:30:40", "first region");
    assert_equal_string (regions[1].to_region_string (), "50:60:70:80", "second region");
}

private void test_parse_regions_tolerates_empty_input () {
    assert_equal_int (LogoDetectorLogic.parse_regions ("").length, 0, "empty text");
    assert_equal_int (LogoDetectorLogic.parse_regions (null).length, 0, "null text");
    assert_equal_int (LogoDetectorLogic.parse_regions (",, ,").length, 0, "separators only");
}

private void test_format_regions_round_trips_through_parse () {
    LogoRegion[] regions = {
        new LogoRegion (1620, 60, 250, 80),
        new LogoRegion (40, 900, 120, 40)
    };

    string text = LogoDetectorLogic.format_regions (regions);
    assert_equal_string (text, "1620:60:250:80,40:900:120:40", "formatted regions");

    LogoRegion[] parsed = LogoDetectorLogic.parse_regions (text);
    assert_equal_int (parsed.length, 2, "round-tripped count");
    assert_equal_int (parsed[0].x, 1620, "round-tripped x");
    assert_equal_int (parsed[1].height, 40, "round-tripped height");
}

private void test_build_delogo_filters_emits_one_instance_per_region () {
    string[] filters = LogoDetectorLogic.build_delogo_filters ("10:20:30:40,50:60:70:80");

    assert_equal_int (filters.length, 2, "delogo filter count");
    assert_equal_string (filters[0], "delogo=x=10:y=20:w=30:h=40", "first delogo filter");
    assert_equal_string (filters[1], "delogo=x=50:y=60:w=70:h=80", "second delogo filter");
}

private void test_build_delogo_filters_ignores_unusable_text () {
    assert_equal_int (LogoDetectorLogic.build_delogo_filters ("").length,
                      0, "empty region text");
    assert_equal_int (LogoDetectorLogic.build_delogo_filters ("not a region").length,
                      0, "garbage region text");
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SAMPLING PLAN
// ═══════════════════════════════════════════════════════════════════════════════

private void test_analysis_size_preserves_aspect_ratio () {
    int w, h;

    LogoDetectorLogic.compute_analysis_size (1920, 1080, out w, out h);
    assert_equal_int (w, 480, "1080p analysis width");
    assert_equal_int (h, 270, "1080p analysis height");

    // Sources narrower than the analysis width are never upscaled.
    LogoDetectorLogic.compute_analysis_size (100, 50, out w, out h);
    assert_equal_int (w, 100, "small source analysis width");
    assert_equal_int (h, 50, "small source analysis height");

    LogoDetectorLogic.compute_analysis_size (0, 0, out w, out h);
    assert_equal_int (w, 0, "invalid source analysis width");
}

private void test_analysis_size_honours_a_wider_retry () {
    int w, h;

    LogoDetectorLogic.compute_analysis_size (1920, 1080, out w, out h,
                                             LogoDetectorLogic.ANALYSIS_WIDTH_RETRY);
    assert_equal_int (w, 960, "retry analysis width");
    assert_equal_int (h, 540, "retry analysis height");

    // A source narrower than the retry width is never blown up to reach it.
    LogoDetectorLogic.compute_analysis_size (604, 1080, out w, out h,
                                             LogoDetectorLogic.ANALYSIS_WIDTH_RETRY);
    assert_equal_int (w, 604, "retry never upscales a narrow source");
}

private void test_detects_a_caption_on_a_wide_analysis_frame () {
    // Same caption as the frame-scale test, drawn at twice the size on twice
    // the frame.  It exercises the thresholds that have to be restated for a
    // wider scan — dilation reach, minimum blob size, and above all the fill
    // ratio, which *falls* as the frame grows because detected pixels trace an
    // outline while the box they sit in grows with area.
    const int W = 960;
    const int H = 540;

    var mean = new double[W * H];
    var stddev = new double[W * H];
    for (int i = 0; i < W * H; i++) {
        mean[i] = 128.0;
        stddev[i] = 18.0;
    }

    for (int stroke = 0; stroke < 6; stroke++) {
        int left = 200 + stroke * 16;
        for (int y = 100; y <= 130; y++) {
            for (int x = left; x < left + 4; x++) {
                int i = y * W + x;
                mean[i] = 230.0;
                stddev[i] = 0.4;
            }
        }
    }

    string reason;
    LogoRegion[] regions = LogoDetectorLogic.detect_regions (
        mean, stddev, W, H, out reason);

    if (regions.length == 0) {
        Test.fail_printf ("expected a wide-frame detection but got: %s", reason);
        return;
    }
    assert_equal_int (regions.length, 1, "wide-frame region count");
    assert_true (regions[0].x <= 200, "wide-frame box reaches the first stroke");
    assert_true (regions[0].x + regions[0].width >= 200 + 5 * 16 + 4,
                 "wide-frame box reaches the last stroke");
}

private void test_detects_a_hollow_outline_on_a_wide_frame () {
    // The shape that exposed the fill-ratio trap: a banner's border, which is
    // a thin outline enclosing a large empty box.  Detected pixels trace the
    // outline and so multiply with the frame's width, while the box grows with
    // its area — fill therefore *falls* on a wider scan.  This one measures
    // about 0.035, which clears the scaled bar but not the unscaled one, so it
    // fails if the ratio is ever treated as resolution-independent again.
    const int W = 960;
    const int H = 540;
    const int X0 = 300, Y0 = 150, X1 = 619, Y1 = 309;

    var mean = new double[W * H];
    var stddev = new double[W * H];
    for (int i = 0; i < W * H; i++) {
        mean[i] = 128.0;
        stddev[i] = 18.0;
    }

    // The border is three pixels thick, as a drawn one would be.  A single-
    // pixel line would carry its contrast on the background pixels beside it,
    // and those move — only a stroke with some body to it is both edged and
    // still, which is what the detector looks for.
    for (int y = Y0; y <= Y1; y++) {
        for (int x = X0; x <= X1; x++) {
            bool border = x < X0 + 3 || x > X1 - 3 || y < Y0 + 3 || y > Y1 - 3;
            if (!border) continue;
            int i = y * W + x;
            mean[i] = 230.0;
            stddev[i] = 0.4;
        }
    }

    string reason;
    LogoRegion[] regions = LogoDetectorLogic.detect_regions (
        mean, stddev, W, H, out reason);

    if (regions.length == 0) {
        Test.fail_printf ("expected a hollow-outline detection but got: %s", reason);
        return;
    }
    assert_true (regions[0].x <= X0, "outline box reaches the left border");
    assert_true (regions[0].x + regions[0].width >= X1, "outline box reaches the right border");
}

private void test_long_videos_are_sampled_in_spread_windows () {
    LogoSampleWindow[] windows = LogoDetectorLogic.plan_sample_windows (3600.0);

    assert_equal_int (windows.length, 3, "long video window count");
    assert_true (windows[0].start < windows[1].start, "windows are ordered");
    assert_true (windows[1].start < windows[2].start, "windows stay ordered");
    assert_true (windows[0].start > 0.0, "first window skips the opening titles");

    foreach (LogoSampleWindow window in windows) {
        assert_true (window.length > 0.0, "window length is positive");
        assert_true (window.start + window.length <= 3600.0, "window stays inside the file");
        assert_true (window.fps > 0.0, "window fps is positive");
    }
}

private void test_short_videos_are_sampled_in_one_pass () {
    LogoSampleWindow[] windows = LogoDetectorLogic.plan_sample_windows (30.0);

    assert_equal_int (windows.length, 1, "short video window count");
    assert_true (windows[0].start == 0.0, "short video starts at zero");
    assert_true (windows[0].length == 30.0, "short video covers the whole file");
    assert_true (windows[0].fps >= 1.0 && windows[0].fps <= 6.0, "short video fps is clamped");
}

private void test_unknown_duration_still_produces_a_window () {
    LogoSampleWindow[] windows = LogoDetectorLogic.plan_sample_windows (0.0);
    assert_equal_int (windows.length, 1, "unknown duration window count");
    assert_true (windows[0].length > 0.0, "unknown duration window has length");

    windows = LogoDetectorLogic.plan_sample_windows (-1.0);
    assert_equal_int (windows.length, 1, "negative duration window count");
}

// ═══════════════════════════════════════════════════════════════════════════════
//  COORDINATE MAPPING
// ═══════════════════════════════════════════════════════════════════════════════

private void test_regions_scale_back_to_source_with_padding () {
    LogoRegion[] analysis = { new LogoRegion (10, 5, 20, 10) };
    LogoRegion[] scaled = LogoDetectorLogic.scale_regions_to_source (
        analysis, 480, 270, 1920, 1080);

    assert_equal_int (scaled.length, 1, "scaled region count");
    // 4× scale, then 8px of padding on every side.
    assert_equal_string (scaled[0].to_region_string (), "32:12:96:56", "scaled region");
}

private void test_scaled_regions_stay_inside_the_frame () {
    LogoRegion[] analysis = { new LogoRegion (0, 0, 480, 270) };
    LogoRegion[] scaled = LogoDetectorLogic.scale_regions_to_source (
        analysis, 480, 270, 1920, 1080);

    assert_equal_int (scaled.length, 1, "clamped region count");
    LogoRegion region = scaled[0];

    // delogo interpolates from the pixels just outside its box, so the box
    // must never touch the frame border.
    assert_true (region.x >= 1, "left edge leaves a border");
    assert_true (region.y >= 1, "top edge leaves a border");
    assert_true (region.x + region.width <= 1919, "right edge leaves a border");
    assert_true (region.y + region.height <= 1079, "bottom edge leaves a border");
    assert_true (region.width > 0 && region.height > 0, "clamped region is not empty");
}

// ═══════════════════════════════════════════════════════════════════════════════
//  DETECTION
//
//  The synthetic frames below stand in for real statistics: a busy background
//  that changes over time, plus (in some cases) a small high-contrast patch
//  that does not.
// ═══════════════════════════════════════════════════════════════════════════════

private const int FRAME_W = 120;
private const int FRAME_H = 80;

private const int LOGO_X0 = 92;
private const int LOGO_Y0 = 10;
private const int LOGO_X1 = 113;   // inclusive
private const int LOGO_Y1 = 24;    // inclusive

/** Blocky pattern with plenty of edges, standing in for picture detail. */
private double background_value (int x, int y) {
    return 30.0 + 60.0 * ((x / 3) % 3) + 20.0 * ((y / 5) % 2);
}

/** High-contrast stripes, standing in for a logo's lettering. */
private double logo_value (int x) {
    return ((x / 2) % 2 == 0) ? 20.0 : 230.0;
}

private bool inside_logo (int x, int y) {
    return x >= LOGO_X0 && x <= LOGO_X1 && y >= LOGO_Y0 && y <= LOGO_Y1;
}

private void build_frame_stats (bool with_logo,
                                double background_sd,
                                double logo_sd,
                                out double[] mean,
                                out double[] stddev) {
    mean = new double[FRAME_W * FRAME_H];
    stddev = new double[FRAME_W * FRAME_H];

    for (int y = 0; y < FRAME_H; y++) {
        for (int x = 0; x < FRAME_W; x++) {
            int i = y * FRAME_W + x;
            if (with_logo && inside_logo (x, y)) {
                mean[i] = logo_value (x);
                stddev[i] = logo_sd;
            } else {
                mean[i] = background_value (x, y);
                stddev[i] = background_sd;
            }
        }
    }
}

private void test_detects_a_static_logo_over_moving_video () {
    double[] mean;
    double[] stddev;
    build_frame_stats (true, 18.0, 0.4, out mean, out stddev);

    string reason;
    LogoRegion[] regions = LogoDetectorLogic.detect_regions (
        mean, stddev, FRAME_W, FRAME_H, out reason);

    if (regions.length == 0) {
        Test.fail_printf ("expected a detection but got: %s", reason);
        return;
    }

    assert_equal_int (regions.length, 1, "detected region count");
    LogoRegion region = regions[0];

    // The blob is dilated before labelling, so the box may be a little larger
    // than the synthetic logo — but it must cover all of it.
    assert_true (region.x <= LOGO_X0, "detected box reaches the logo's left edge");
    assert_true (region.y <= LOGO_Y0, "detected box reaches the logo's top edge");
    assert_true (region.x + region.width - 1 >= LOGO_X1,
                 "detected box reaches the logo's right edge");
    assert_true (region.y + region.height - 1 >= LOGO_Y1,
                 "detected box reaches the logo's bottom edge");

    // ...and it must not have swallowed the picture.
    assert_true (region.width < FRAME_W / 2, "detected box is not the whole frame");
    assert_true (region.height < FRAME_H / 2, "detected box is not the whole frame");
}

/**
 * Builds a frame whose background moves but carries no detail of its own —
 * haze, sky, shallow depth of field — with the logo at an arbitrary corner
 * offset.  Here the logo supplies nearly every edge in the picture.
 */
private void build_featureless_background_stats (int logo_x0, int logo_y0,
                                                 out double[] mean,
                                                 out double[] stddev) {
    mean = new double[FRAME_W * FRAME_H];
    stddev = new double[FRAME_W * FRAME_H];

    int logo_x1 = logo_x0 + (LOGO_X1 - LOGO_X0);
    int logo_y1 = logo_y0 + (LOGO_Y1 - LOGO_Y0);

    for (int y = 0; y < FRAME_H; y++) {
        for (int x = 0; x < FRAME_W; x++) {
            int i = y * FRAME_W + x;
            if (x >= logo_x0 && x <= logo_x1 && y >= logo_y0 && y <= logo_y1) {
                mean[i] = logo_value (x);
                stddev[i] = 0.4;
            } else {
                mean[i] = 128.0;   // flat: averaging has wiped the scenery out
                stddev[i] = 18.0;
            }
        }
    }
}

private void test_detects_a_logo_that_supplies_most_of_the_frames_detail () {
    // Over soft footage the moving picture leaves almost no edges behind, so
    // the watermark accounts for nearly all of them.  That is the clearest
    // possible detection, and must not be mistaken for a frozen shot.
    double[] mean;
    double[] stddev;
    build_featureless_background_stats (LOGO_X0, LOGO_Y0, out mean, out stddev);

    string reason;
    LogoRegion[] regions = LogoDetectorLogic.detect_regions (
        mean, stddev, FRAME_W, FRAME_H, out reason);

    if (regions.length == 0) {
        Test.fail_printf ("expected a detection but got: %s", reason);
        return;
    }
    assert_true (regions[0].x <= LOGO_X0, "detected box reaches the logo");
    assert_true (regions[0].width < FRAME_W / 2, "detected box is not the whole frame");
}

private void test_detects_a_logo_tucked_close_to_the_frame_edge () {
    // A corner logo inset by just the border margin.  Dilation grows its blob
    // past the frame edge, but the margin is judged on the logo itself.
    double[] mean;
    double[] stddev;
    build_featureless_background_stats (3, 3, out mean, out stddev);

    string reason;
    LogoRegion[] regions = LogoDetectorLogic.detect_regions (
        mean, stddev, FRAME_W, FRAME_H, out reason);

    if (regions.length == 0) {
        Test.fail_printf ("expected a corner detection but got: %s", reason);
        return;
    }
    assert_true (regions[0].y < FRAME_H / 2, "detected box is in the top corner");
}

private void test_detects_a_logo_running_off_the_frame_edge () {
    // A corner banner bleeding off the side of the picture.  It is thick, so
    // it is a watermark rather than a letterbox seam, and delogo can still
    // rebuild it from the three sides that remain.
    double[] mean;
    double[] stddev;
    build_featureless_background_stats (FRAME_W - (LOGO_X1 - LOGO_X0) - 1, 20,
                                        out mean, out stddev);

    string reason;
    LogoRegion[] regions = LogoDetectorLogic.detect_regions (
        mean, stddev, FRAME_W, FRAME_H, out reason);

    if (regions.length == 0) {
        Test.fail_printf ("expected an edge detection but got: %s", reason);
        return;
    }
    assert_true (regions[0].x + regions[0].width >= FRAME_W - 2,
                 "detected box reaches the frame edge");
}

private void test_ignores_a_thin_static_sliver_along_the_frame_edge () {
    // Letterbox seams and encoder edge artifacts look perfectly static.  What
    // gives them away is being paper-thin, not being at the edge.
    double[] mean;
    double[] stddev;
    build_featureless_background_stats (20, 20, out mean, out stddev);

    for (int y = 5; y < FRAME_H - 5; y++) {
        for (int x = FRAME_W - 2; x < FRAME_W; x++) {
            int i = y * FRAME_W + x;
            mean[i] = (y % 2 == 0) ? 20.0 : 230.0;
            stddev[i] = 0.4;
        }
    }

    string reason;
    LogoRegion[] regions = LogoDetectorLogic.detect_regions (
        mean, stddev, FRAME_W, FRAME_H, out reason);

    foreach (LogoRegion region in regions) {
        assert_true (region.x + region.width < FRAME_W - 2,
                     "sliver at the frame edge was not reported");
    }
}

/**
 * Draws upright strokes, like the letters of a burned-in caption, over a
 * moving background.  @spacing is the distance between the start of one
 * stroke and the next.
 */
private void build_caption_stats (int stroke_count, int spacing,
                                  out double[] mean, out double[] stddev) {
    mean = new double[FRAME_W * FRAME_H];
    stddev = new double[FRAME_W * FRAME_H];

    for (int y = 0; y < FRAME_H; y++) {
        for (int x = 0; x < FRAME_W; x++) {
            int i = y * FRAME_W + x;
            mean[i] = 128.0;
            stddev[i] = 18.0;
        }
    }

    for (int stroke = 0; stroke < stroke_count; stroke++) {
        int left = 20 + stroke * spacing;
        for (int y = LOGO_Y0; y <= LOGO_Y1; y++) {
            for (int x = left; x < left + 2 && x < FRAME_W; x++) {
                int i = y * FRAME_W + x;
                mean[i] = 230.0;
                stddev[i] = 0.4;
            }
        }
    }
}

private void test_caption_strokes_become_one_region () {
    // Lettering breaks into a fragment per glyph, each far too small to be a
    // watermark on its own.  Removing only the fat ones paints the caption out
    // in stencil, so the pieces have to be assembled first.
    double[] mean;
    double[] stddev;
    build_caption_stats (6, 8, out mean, out stddev);

    string reason;
    LogoRegion[] regions = LogoDetectorLogic.detect_regions (
        mean, stddev, FRAME_W, FRAME_H, out reason);

    if (regions.length == 0) {
        Test.fail_printf ("expected a caption detection but got: %s", reason);
        return;
    }

    assert_equal_int (regions.length, 1, "caption region count");
    assert_true (regions[0].x <= 20, "caption box reaches the first stroke");
    assert_true (regions[0].x + regions[0].width >= 20 + 5 * 8 + 2,
                 "caption box reaches the last stroke");
}

private void test_marks_far_apart_are_not_joined () {
    // Two separate marks must stay separate — merging is for the pieces of one
    // watermark, not for anything that happens to be still.
    double[] mean;
    double[] stddev;
    build_caption_stats (2, 70, out mean, out stddev);

    string reason;
    LogoRegion[] regions = LogoDetectorLogic.detect_regions (
        mean, stddev, FRAME_W, FRAME_H, out reason);

    foreach (LogoRegion region in regions) {
        assert_true (region.width < 60, "distant marks were not merged into one box");
    }
}

private void test_ignores_a_static_region_with_no_sharp_edges () {
    // The wake of a drifting watermark: the patch it covers most of the time
    // reads as perfectly static, because it is under flat overlay in nearly
    // every frame — but averaging has smeared the overlay's edges into a soft
    // mound with no crisp boundary anywhere.  A watermark that truly never
    // moves keeps its edges pixel-sharp however many frames are folded in, so
    // softness here is proof the thing was moving.
    var mean = new double[FRAME_W * FRAME_H];
    var stddev = new double[FRAME_W * FRAME_H];

    double half_w = (LOGO_X1 - LOGO_X0) / 2.0;
    double half_h = (LOGO_Y1 - LOGO_Y0) / 2.0;

    for (int y = 0; y < FRAME_H; y++) {
        for (int x = 0; x < FRAME_W; x++) {
            int i = y * FRAME_W + x;

            // Gentle moving picture: plenty of detail, none of it still, and
            // no edge sharp enough to be mistaken for an overlay.
            mean[i] = 60.0 + 20.0 * ((x / 3) % 3) + 8.0 * ((y / 5) % 2);
            stddev[i] = 18.0;

            if (x < LOGO_X0 || x > LOGO_X1 || y < LOGO_Y0 || y > LOGO_Y1) continue;

            // A smooth mound that blends into the picture at its rim, so the
            // region carries detail but not one hard edge.
            double tx = 1.0 - (((x - LOGO_X0) / half_w) - 1.0).abs ();
            double ty = 1.0 - (((y - LOGO_Y0) / half_h) - 1.0).abs ();
            // Peaks around 70 — the range a real drifting banner's wake
            // measures, and well clear of the threshold either way.
            mean[i] = 100.0 + 60.0 * tx * ty;
            stddev[i] = 0.4;
        }
    }

    string reason;
    LogoRegion[] regions = LogoDetectorLogic.detect_regions (
        mean, stddev, FRAME_W, FRAME_H, out reason);

    assert_equal_int (regions.length, 0, "regions found in a smeared static area");
    assert_true (reason.length > 0, "smeared area reason is set");
}

private void test_reports_when_nothing_in_the_picture_holds_still () {
    double[] mean;
    double[] stddev;
    build_frame_stats (false, 18.0, 18.0, out mean, out stddev);

    string reason;
    LogoRegion[] regions = LogoDetectorLogic.detect_regions (
        mean, stddev, FRAME_W, FRAME_H, out reason);

    assert_equal_int (regions.length, 0, "regions found in fully moving video");
    assert_true (reason.length > 0, "failure reason is set");
}

private void test_reports_when_the_whole_picture_is_static () {
    // A locked-off camera or a still image: everything is static, so a
    // watermark cannot be told apart from the scene.
    double[] mean;
    double[] stddev;
    build_frame_stats (true, 0.5, 0.5, out mean, out stddev);

    string reason;
    LogoRegion[] regions = LogoDetectorLogic.detect_regions (
        mean, stddev, FRAME_W, FRAME_H, out reason);

    assert_equal_int (regions.length, 0, "regions found in a static scene");
    assert_true (reason.contains ("barely moves"), "static scene reason: " + reason);
}

private void test_rejects_frames_that_are_too_small_to_analyze () {
    var mean = new double[4];
    var stddev = new double[4];

    string reason;
    LogoRegion[] regions = LogoDetectorLogic.detect_regions (
        mean, stddev, 2, 2, out reason);

    assert_equal_int (regions.length, 0, "regions found in a tiny frame");
    assert_true (reason.length > 0, "tiny frame reason is set");
}

// ═══════════════════════════════════════════════════════════════════════════════
//  ACCUMULATOR
// ═══════════════════════════════════════════════════════════════════════════════

private void test_frame_stats_average_and_deviation () {
    var stats = new LogoFrameStats (2, 1);

    // Pixel 0 never changes; pixel 1 swings between the two frames.
    stats.add_frame ({ 100, 0 });
    stats.add_frame ({ 100, 200 });

    assert_equal_int (stats.frame_count, 2, "accumulated frame count");

    double[] mean = stats.compute_mean ();
    assert_true (Math.fabs (mean[0] - 100.0) < 0.001, "static pixel mean");
    assert_true (Math.fabs (mean[1] - 100.0) < 0.001, "moving pixel mean");

    double[] stddev = stats.compute_stddev ();
    assert_true (stddev[0] < 0.001, "static pixel deviation");
    assert_true (Math.fabs (stddev[1] - 100.0) < 0.001, "moving pixel deviation");
}

private void test_frame_stats_rejects_wrong_sized_frames () {
    var stats = new LogoFrameStats (4, 4);
    assert_true (!stats.add_frame ({ 1, 2, 3 }), "short frame is rejected");
    assert_equal_int (stats.frame_count, 0, "rejected frame is not counted");
}

// ═══════════════════════════════════════════════════════════════════════════════
//  TIMED REGION TEXT  (moving watermarks)
// ═══════════════════════════════════════════════════════════════════════════════

private void test_timed_regions_round_trip_through_parse () {
    TimedLogoRegion[] regions = {
        new TimedLogoRegion (12.5, 28.0, 1416, 1, 504, 288),
        new TimedLogoRegion (45.25, 61.75, 8, 168, 448, 92)
    };

    string text = LogoDetectorLogic.format_timed_regions (regions);
    assert_equal_string (text, "12.5-28.0:1416:1:504:288,45.2-61.8:8:168:448:92",
        "formatted timed regions");

    TimedLogoRegion[] parsed = LogoDetectorLogic.parse_timed_regions (text);
    assert_equal_int (parsed.length, 2, "round-tripped timed count");
    assert_equal_int (parsed[0].x, 1416, "round-tripped x");
    assert_equal_int (parsed[1].height, 92, "round-tripped height");
    assert_true (parsed[0].start > 12.4 && parsed[0].start < 12.6, "round-tripped start");
    assert_true (parsed[1].end > 61.7 && parsed[1].end < 61.9, "round-tripped end");
}

private void test_parse_timed_regions_skips_junk_and_static_entries () {
    // Static entries are left for parse_regions rather than guessed at, so the
    // two parsers can run over one mixed string and each take only its own.
    TimedLogoRegion[] regions = LogoDetectorLogic.parse_timed_regions (
        " 10:20:30:40 , 1.0-2.0:5:6:7:8 , 3.0-2.0:1:2:3:4 , a-b:1:2:3:4 ,"
        + " 5.0-6.0:1:2:0:4 , 1.2.3-4.0:1:2:3:4 , 9.0-9.0:1:2:3:4 ");

    assert_equal_int (regions.length, 1, "only the one valid timed entry survives");
    assert_equal_string (regions[0].to_region_string (), "1.0-2.0:5:6:7:8",
        "surviving timed entry");
}

private void test_region_text_kind_helpers () {
    assert_true (!LogoDetectorLogic.regions_are_timed ("10:20:30:40"),
        "static text is not timed");
    assert_true (LogoDetectorLogic.regions_are_timed ("1.0-2.0:5:6:7:8"),
        "timed text is timed");
    assert_true (LogoDetectorLogic.has_any_regions ("10:20:30:40"),
        "static text counts as usable");
    assert_true (LogoDetectorLogic.has_any_regions ("1.0-2.0:5:6:7:8"),
        "timed text counts as usable");
    assert_true (!LogoDetectorLogic.has_any_regions (" , junk , "),
        "junk counts as nothing");
    assert_true (!LogoDetectorLogic.has_any_regions (null), "null counts as nothing");
}

private void test_build_delogo_filters_emits_timeline_expressions () {
    string[] filters = LogoDetectorLogic.build_delogo_filters (
        "12.5-28.0:1416:1:504:288,45.0-61.0:8:168:448:92");

    assert_equal_int (filters.length, 2, "timed delogo filter count");
    assert_equal_string (filters[0],
        "delogo=x=1416:y=1:w=504:h=288:enable='between(t,12.500,28.000)'",
        "first timed delogo filter");
    assert_equal_string (filters[1],
        "delogo=x=8:y=168:w=448:h=92:enable='between(t,45.000,61.000)'",
        "second timed delogo filter");
}

private void test_build_delogo_filters_mixes_static_and_timed () {
    string[] filters = LogoDetectorLogic.build_delogo_filters (
        "10:20:30:40,12.5-28.0:1416:1:504:288");

    assert_equal_int (filters.length, 2, "mixed filter count");
    assert_equal_string (filters[0], "delogo=x=10:y=20:w=30:h=40",
        "static entry keeps its unconditional filter");
    assert_true (filters[1].contains ("enable='between(t,12.500,28.000)'"),
        "timed entry keeps its timeline expression");
}

// delogo's enable= is evaluated against the timestamps the filter is handed.
// A trimmed segment is decoded with -ss ahead of -i, so its frames start near
// zero and a source-timeline interval would fire at the wrong moment.
private void test_build_delogo_filters_shifts_timed_regions_by_offset () {
    string text = "12.5-28.0:1416:1:504:288,45.0-61.0:8:168:448:92";

    string[] shifted = LogoDetectorLogic.build_delogo_filters (text, 10.0);
    assert_equal_int (shifted.length, 2, "offset keeps both reachable regions");
    assert_true (shifted[0].contains ("between(t,2.500,18.000)"),
        "first interval shifted back by the offset");
    assert_true (shifted[1].contains ("between(t,35.000,51.000)"),
        "second interval shifted back by the offset");

    // An interval the segment starts in the middle of clamps to zero rather
    // than asking delogo to switch on at a negative timestamp.
    string[] clamped = LogoDetectorLogic.build_delogo_filters (text, 20.0);
    assert_equal_int (clamped.length, 2, "straddling interval is kept");
    assert_true (clamped[0].contains ("between(t,0.000,8.000)"),
        "straddling interval clamps its start to zero");

    // An interval entirely before the segment can only ever be off, so it is
    // dropped instead of emitting a dead filter.
    string[] past = LogoDetectorLogic.build_delogo_filters (text, 40.0);
    assert_equal_int (past.length, 1, "fully elapsed interval is dropped");
    assert_true (past[0].contains ("between(t,5.000,21.000)"),
        "remaining interval is the later one");

    // A span bounds the other end: an interval starting after the encoded
    // stretch would only ever emit a filter that stays off.
    string[] bounded = LogoDetectorLogic.build_delogo_filters (text, 0.0, 20.0);
    assert_equal_int (bounded.length, 1, "interval beyond the span is dropped");
    assert_true (bounded[0].contains ("between(t,12.500,20.000)"),
        "interval overlapping the span is clamped to it");

    // Static entries have no timeline to shift.
    string[] statics = LogoDetectorLogic.build_delogo_filters ("10:20:30:40", 99.0);
    assert_equal_int (statics.length, 1, "static entry survives any offset");
    assert_equal_string (statics[0], "delogo=x=10:y=20:w=30:h=40",
        "static entry is unaffected by the offset");
}

private void test_describe_timed_regions_summarizes_coverage () {
    TimedLogoRegion[] one = { new TimedLogoRegion (10.0, 30.0, 1416, 1, 504, 288) };
    assert_equal_string (LogoDetectorLogic.describe_timed_regions (one),
        "Found a 504×288 watermark at 1416,1 over 20s", "single timed summary");

    TimedLogoRegion[] several = {
        new TimedLogoRegion (0.0, 10.0, 1, 1, 100, 100),
        new TimedLogoRegion (20.0, 35.0, 500, 1, 100, 100)
    };
    assert_equal_string (LogoDetectorLogic.describe_timed_regions (several),
        "Found 2 timed regions covering 25s", "multiple timed summary");

    TimedLogoRegion[] none = {};
    assert_equal_string (LogoDetectorLogic.describe_timed_regions (none),
        "No moving watermark found", "empty timed summary");
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MOVING SCAN — planning, association, verification
// ═══════════════════════════════════════════════════════════════════════════════

private void test_dense_windows_cover_a_long_video_without_unbounded_growth () {
    LogoSampleWindow[] windows = LogoDetectorLogic.plan_dense_sample_windows (292.0);

    // A five-minute file at a four-second stride would be 73 windows; the cap
    // stretches the stride instead so the whole file is still covered.
    assert_equal_int (windows.length, 48, "dense window count is capped");
    assert_true (windows[0].start == 0.0, "dense windows start at the beginning");
    assert_true (windows[windows.length - 1].start > 280.0,
        "dense windows reach the end of the video");

    foreach (LogoSampleWindow window in windows) {
        assert_true (window.length >= 2.0, "every dense window is long enough to analyze");
        assert_true (window.fps > 2.0, "dense windows sample faster than the static scan");
    }
}

private void test_dense_windows_march_at_a_fixed_stride_when_uncapped () {
    LogoSampleWindow[] windows = LogoDetectorLogic.plan_dense_sample_windows (30.0);

    assert_equal_int (windows.length, 8, "short-of-cap window count");
    assert_true (windows[1].start - windows[0].start == 4.0, "uncapped stride");
    assert_true (windows[0].length == 4.0, "uncapped window length");
}

private void test_dense_windows_fall_back_for_tiny_and_unknown_durations () {
    // Too short to carve into windows that could disagree with each other.
    LogoSampleWindow[] tiny = LogoDetectorLogic.plan_dense_sample_windows (5.0);
    assert_equal_int (tiny.length, 1, "a very short video gets one window");
    assert_true (tiny[0].length == 5.0, "the single window covers the whole video");

    LogoSampleWindow[] unknown = LogoDetectorLogic.plan_dense_sample_windows (0.0);
    assert_equal_int (unknown.length, 1, "unknown duration still produces a window");
}

private LogoWindowDetection sighting (double start, double end,
                                     int x, int y, int w, int h) {
    return new LogoWindowDetection (start, end, new LogoRegion (x, y, w, h, 1.0));
}

private void test_association_needs_agreement_between_windows () {
    // Two windows in the same place: a candidate.
    LogoWindowDetection[] agreeing = {
        sighting (0.0, 4.0, 100, 100, 50, 50),
        sighting (4.0, 8.0, 100, 100, 50, 50)
    };
    TimedLogoRegion[] linked = LogoDetectorLogic.associate_timed_regions (agreeing, 4.0);
    assert_equal_int (linked.length, 1, "agreeing windows produce one candidate");
    assert_equal_int (linked[0].window_count, 2, "candidate records both windows");
    assert_equal_int (linked[0].x, 100, "candidate keeps the agreed position");

    // One window on its own: not enough to spend a verification decode on.
    LogoWindowDetection[] lone = { sighting (0.0, 4.0, 100, 100, 50, 50) };
    assert_equal_int (LogoDetectorLogic.associate_timed_regions (lone, 4.0).length, 0,
        "a single sighting is not a candidate");

    // Same place, but far enough apart in time to be two separate sightings.
    LogoWindowDetection[] distant = {
        sighting (0.0, 4.0, 100, 100, 50, 50),
        sighting (60.0, 64.0, 100, 100, 50, 50)
    };
    assert_equal_int (LogoDetectorLogic.associate_timed_regions (distant, 4.0).length, 0,
        "sightings separated by a long gap do not link");

    // Overlapping in time, nowhere near each other in space.
    LogoWindowDetection[] elsewhere = {
        sighting (0.0, 4.0, 100, 100, 50, 50),
        sighting (4.0, 8.0, 900, 600, 50, 50)
    };
    assert_equal_int (LogoDetectorLogic.associate_timed_regions (elsewhere, 4.0).length, 0,
        "sightings in different places do not link");
}

private void test_association_unions_boxes_and_pads_intervals () {
    LogoWindowDetection[] shifting = {
        sighting (10.0, 14.0, 100, 100, 50, 50),
        sighting (14.0, 18.0, 110, 100, 50, 50)
    };

    TimedLogoRegion[] linked = LogoDetectorLogic.associate_timed_regions (
        shifting, 4.0, 100.0);
    assert_equal_int (linked.length, 1, "shifted-but-overlapping windows link");

    // delogo gets one rectangle for the interval, so it has to cover both.
    assert_equal_int (linked[0].x, 100, "union starts at the leftmost sighting");
    assert_equal_int (linked[0].width, 60, "union spans both sightings");

    // A little slack at each end so the logo does not flicker back between the
    // last window that saw it and the first that did not.
    assert_true (linked[0].start < 10.0 && linked[0].start > 9.0,
        "interval start is padded");
    assert_true (linked[0].end > 18.0 && linked[0].end < 19.0,
        "interval end is padded");
}

private void test_association_clamps_padding_to_the_video () {
    LogoWindowDetection[] atEdges = {
        sighting (0.0, 4.0, 100, 100, 50, 50),
        sighting (4.0, 8.0, 100, 100, 50, 50)
    };

    TimedLogoRegion[] linked = LogoDetectorLogic.associate_timed_regions (
        atEdges, 4.0, 8.0);
    assert_equal_int (linked.length, 1, "candidate at the video edges");
    assert_true (linked[0].start == 0.0, "padding cannot run before the video starts");
    assert_true (linked[0].end == 8.0, "padding cannot run past the video end");
}

private void test_verification_window_widens_short_candidates () {
    // A four-second candidate re-checked over four seconds is the measurement
    // that proposed it. Widening is what gives verification something to say.
    LogoSampleWindow middle = LogoDetectorLogic.plan_verification_window (10.0, 14.0, 100.0);
    assert_true (middle.length >= 16.0, "short candidate is widened");
    assert_true (middle.start < 10.0, "widening reaches back before the candidate");
    assert_true (middle.start + middle.length > 14.0, "widening reaches past it");

    // Widening at the very start of the video shifts forward instead of
    // running negative.
    LogoSampleWindow atStart = LogoDetectorLogic.plan_verification_window (0.0, 4.0, 100.0);
    assert_true (atStart.start == 0.0, "widening never starts before zero");
    assert_true (atStart.length >= 16.0, "widening still reaches full length");

    // And at the end it shifts back.
    LogoSampleWindow atEnd = LogoDetectorLogic.plan_verification_window (90.0, 99.0, 100.0);
    assert_true (atEnd.start + atEnd.length <= 100.0, "widening stays inside the video");
    assert_true (atEnd.length >= 16.0, "widening still reaches full length at the end");

    // A candidate already long enough is verified over exactly itself.
    LogoSampleWindow long_enough = LogoDetectorLogic.plan_verification_window (10.0, 40.0, 100.0);
    assert_true (long_enough.start == 10.0, "long candidate keeps its start");
    assert_true (long_enough.length == 30.0, "long candidate keeps its length");

    // A video shorter than the verification length gives up what it has.
    LogoSampleWindow tiny = LogoDetectorLogic.plan_verification_window (0.0, 4.0, 10.0);
    assert_true (tiny.length == 10.0, "verification cannot exceed the video");
}

private void test_verified_regions_are_matched_by_containment () {
    // The corpus's one true positive: verification over a longer stretch
    // returns a much tighter box than the union that proposed it, and that has
    // to count as the same watermark rather than be punished for the difference.
    var proposed = new LogoRegion (1192, 1, 727, 303);
    var verified = new LogoRegion (1424, 188, 495, 100);
    assert_true (LogoDetectorLogic.regions_overlap_enough (proposed, verified),
        "a tighter verified box inside the proposal matches");

    var elsewhere = new LogoRegion (10, 900, 100, 100);
    assert_true (!LogoDetectorLogic.regions_overlap_enough (proposed, elsewhere),
        "a region somewhere else does not match");

    // A fifth of the way in is not the same watermark.
    var straddling = new LogoRegion (1400, 250, 100, 100);
    var mostly_outside = new LogoRegion (1480, 250, 100, 100);
    assert_true (!LogoDetectorLogic.regions_overlap_enough (straddling, mostly_outside),
        "a barely-overlapping region does not match");

    // Exactly half counts — the floor is inclusive.
    var half_in = new LogoRegion (1450, 250, 100, 100);
    assert_true (LogoDetectorLogic.regions_overlap_enough (straddling, half_in),
        "half of the smaller box inside the proposal matches");
}

// A watermark reappearing halfway through the output is the visible cost of
// grouping tightly. These are the real numbers from a 6-minute caption clip,
// where the caption's box shrank and grew with the glyphs that registered and
// split one caption into three verified fragments with a 26-second hole.
private void test_merge_joins_fragments_of_one_watermark () {
    TimedLogoRegion[] fragments = {
        new TimedLogoRegion (7.5, 192.8, 454, 1030, 131, 40, 1.0, 20),
        new TimedLogoRegion (180.2, 216.4, 507, 1030, 78, 39, 1.0, 4),
        new TimedLogoRegion (243.0, 365.5, 454, 1030, 131, 40, 1.0, 16)
    };

    // Stride of a 6-minute file scanned in 48 windows.
    TimedLogoRegion[] merged = LogoDetectorLogic.merge_timed_regions (fragments, 7.85);

    assert_equal_int (merged.length, 1, "three fragments of one caption become one");
    assert_true (merged[0].start < 7.6 && merged[0].start > 7.4, "merged start");
    assert_true (merged[0].end > 365.4 && merged[0].end < 365.6, "merged end");
    assert_equal_int (merged[0].width, 131, "merged box covers every fragment");
    assert_equal_int (merged[0].window_count, 40, "merged evidence is the sum");
}

private void test_merge_refuses_genuine_absences_and_other_places () {
    // Real intervals from a clip where the banner had actually gone away: same
    // corner either side, but 41s and 36s of nothing in between.
    TimedLogoRegion[] apart = {
        new TimedLogoRegion (4.6, 24.5, 1424, 1, 495, 167, 1.0, 4),
        new TimedLogoRegion (65.1, 80.0, 1424, 1, 495, 287, 1.0, 3),
        new TimedLogoRegion (115.5, 150.5, 1424, 188, 495, 100, 1.0, 6)
    };
    assert_equal_int (LogoDetectorLogic.merge_timed_regions (apart, 5.04).length, 3,
        "long gaps are left alone");

    // Adjacent in time, different corners: not the same watermark.
    TimedLogoRegion[] elsewhere = {
        new TimedLogoRegion (0.0, 20.0, 10, 10, 100, 100, 1.0, 4),
        new TimedLogoRegion (22.0, 40.0, 1500, 900, 100, 100, 1.0, 4)
    };
    assert_equal_int (LogoDetectorLogic.merge_timed_regions (elsewhere, 4.0).length, 2,
        "regions in different places are left alone");

    TimedLogoRegion[] none = {};
    assert_equal_int (LogoDetectorLogic.merge_timed_regions (none).length, 0,
        "merging nothing yields nothing");
}

void main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/logo-detector-logic/merge-joins-fragments",
                   test_merge_joins_fragments_of_one_watermark);
    Test.add_func ("/logo-detector-logic/merge-refuses-real-gaps",
                   test_merge_refuses_genuine_absences_and_other_places);

    Test.add_func ("/logo-detector-logic/dense-windows-cover-long-video",
                   test_dense_windows_cover_a_long_video_without_unbounded_growth);
    Test.add_func ("/logo-detector-logic/dense-windows-fixed-stride",
                   test_dense_windows_march_at_a_fixed_stride_when_uncapped);
    Test.add_func ("/logo-detector-logic/dense-windows-fallbacks",
                   test_dense_windows_fall_back_for_tiny_and_unknown_durations);
    Test.add_func ("/logo-detector-logic/association-needs-agreement",
                   test_association_needs_agreement_between_windows);
    Test.add_func ("/logo-detector-logic/association-unions-and-pads",
                   test_association_unions_boxes_and_pads_intervals);
    Test.add_func ("/logo-detector-logic/association-clamps-padding",
                   test_association_clamps_padding_to_the_video);
    Test.add_func ("/logo-detector-logic/verification-window-widens",
                   test_verification_window_widens_short_candidates);
    Test.add_func ("/logo-detector-logic/verified-regions-matched-by-containment",
                   test_verified_regions_are_matched_by_containment);

    Test.add_func ("/logo-detector-logic/timed-regions-round-trip",
                   test_timed_regions_round_trip_through_parse);
    Test.add_func ("/logo-detector-logic/timed-regions-skip-junk",
                   test_parse_timed_regions_skips_junk_and_static_entries);
    Test.add_func ("/logo-detector-logic/region-text-kind-helpers",
                   test_region_text_kind_helpers);
    Test.add_func ("/logo-detector-logic/timed-delogo-filters",
                   test_build_delogo_filters_emits_timeline_expressions);
    Test.add_func ("/logo-detector-logic/mixed-delogo-filters",
                   test_build_delogo_filters_mixes_static_and_timed);
    Test.add_func ("/logo-detector-logic/timed-delogo-filters-offset",
                   test_build_delogo_filters_shifts_timed_regions_by_offset);
    Test.add_func ("/logo-detector-logic/describe-timed-regions",
                   test_describe_timed_regions_summarizes_coverage);

    Test.add_func ("/logo-detector-logic/parse-regions-skips-junk",
                   test_parse_regions_keeps_valid_entries_and_skips_junk);
    Test.add_func ("/logo-detector-logic/parse-regions-tolerates-empty",
                   test_parse_regions_tolerates_empty_input);
    Test.add_func ("/logo-detector-logic/format-regions-round-trips",
                   test_format_regions_round_trips_through_parse);
    Test.add_func ("/logo-detector-logic/build-delogo-filters",
                   test_build_delogo_filters_emits_one_instance_per_region);
    Test.add_func ("/logo-detector-logic/build-delogo-filters-ignores-junk",
                   test_build_delogo_filters_ignores_unusable_text);
    Test.add_func ("/logo-detector-logic/analysis-size-preserves-aspect",
                   test_analysis_size_preserves_aspect_ratio);
    Test.add_func ("/logo-detector-logic/analysis-size-honours-retry-width",
                   test_analysis_size_honours_a_wider_retry);
    Test.add_func ("/logo-detector-logic/detects-hollow-outline-wide-frame",
                   test_detects_a_hollow_outline_on_a_wide_frame);
    Test.add_func ("/logo-detector-logic/detects-caption-on-wide-frame",
                   test_detects_a_caption_on_a_wide_analysis_frame);
    Test.add_func ("/logo-detector-logic/long-videos-sampled-in-windows",
                   test_long_videos_are_sampled_in_spread_windows);
    Test.add_func ("/logo-detector-logic/short-videos-sampled-in-one-pass",
                   test_short_videos_are_sampled_in_one_pass);
    Test.add_func ("/logo-detector-logic/unknown-duration-produces-window",
                   test_unknown_duration_still_produces_a_window);
    Test.add_func ("/logo-detector-logic/regions-scale-back-with-padding",
                   test_regions_scale_back_to_source_with_padding);
    Test.add_func ("/logo-detector-logic/scaled-regions-stay-inside-frame",
                   test_scaled_regions_stay_inside_the_frame);
    Test.add_func ("/logo-detector-logic/detects-static-logo",
                   test_detects_a_static_logo_over_moving_video);
    Test.add_func ("/logo-detector-logic/detects-logo-supplying-most-detail",
                   test_detects_a_logo_that_supplies_most_of_the_frames_detail);
    Test.add_func ("/logo-detector-logic/detects-logo-near-frame-edge",
                   test_detects_a_logo_tucked_close_to_the_frame_edge);
    Test.add_func ("/logo-detector-logic/detects-logo-at-frame-edge",
                   test_detects_a_logo_running_off_the_frame_edge);
    Test.add_func ("/logo-detector-logic/ignores-thin-edge-sliver",
                   test_ignores_a_thin_static_sliver_along_the_frame_edge);
    Test.add_func ("/logo-detector-logic/caption-strokes-become-one-region",
                   test_caption_strokes_become_one_region);
    Test.add_func ("/logo-detector-logic/distant-marks-stay-separate",
                   test_marks_far_apart_are_not_joined);
    Test.add_func ("/logo-detector-logic/ignores-smeared-static-region",
                   test_ignores_a_static_region_with_no_sharp_edges);
    Test.add_func ("/logo-detector-logic/reports-when-nothing-holds-still",
                   test_reports_when_nothing_in_the_picture_holds_still);
    Test.add_func ("/logo-detector-logic/reports-when-scene-is-static",
                   test_reports_when_the_whole_picture_is_static);
    Test.add_func ("/logo-detector-logic/rejects-tiny-frames",
                   test_rejects_frames_that_are_too_small_to_analyze);
    Test.add_func ("/logo-detector-logic/frame-stats-mean-and-deviation",
                   test_frame_stats_average_and_deviation);
    Test.add_func ("/logo-detector-logic/frame-stats-rejects-wrong-size",
                   test_frame_stats_rejects_wrong_sized_frames);

    Test.run ();
}
