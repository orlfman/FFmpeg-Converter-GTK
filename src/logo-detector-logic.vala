using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  LogoDetectorLogic — Pure analysis behind automatic watermark detection
//
//  Split from LogoDetector (which drives FFmpeg and talks to the UI) so the
//  maths can be unit-tested without GTK, mirroring the smart-optimizer-logic
//  split.
//
//  How detection works:
//
//    A burned-in watermark is the part of the frame that has visible detail
//    (spatial edges) yet barely changes over time.  Picture content moves;
//    a channel bug or a "©" stamp does not.  So we sample frames spread
//    across the video, build a per-pixel temporal mean and standard
//    deviation, and keep pixels that are BOTH edgy in the mean image AND
//    quiet across time.  Those pixels are grouped into blobs, the blobs are
//    scored, and the winner becomes a delogo rectangle.
//
//  This deliberately cannot find moving watermarks, per-frame randomized
//  positions, or full-screen tiled stock-footage overlays — those have no
//  stable pixels to lock onto, and the detector reports that instead of
//  guessing.
// ═══════════════════════════════════════════════════════════════════════════════

/** A rectangle in a video frame, in that frame's own pixel coordinates. */
public class LogoRegion : Object {
    public int x { get; set; default = 0; }
    public int y { get; set; default = 0; }
    public int width { get; set; default = 0; }
    public int height { get; set; default = 0; }
    public double score { get; set; default = 0.0; }

    public LogoRegion (int x, int y, int width, int height, double score = 0.0) {
        this.x = x;
        this.y = y;
        this.width = width;
        this.height = height;
        this.score = score;
    }

    /** Serializes to the "x:y:w:h" form shown in the General tab. */
    public string to_region_string () {
        return "%d:%d:%d:%d".printf (x, y, width, height);
    }
}

/** One stretch of the video to sample frames from. */
public class LogoSampleWindow : Object {
    public double start { get; set; default = 0.0; }
    public double length { get; set; default = 0.0; }
    public double fps { get; set; default = 2.0; }

    public LogoSampleWindow (double start, double length, double fps) {
        this.start = start;
        this.length = length;
        this.fps = fps;
    }
}

/**
 * Running per-pixel mean and standard deviation over a stream of grayscale
 * frames.  Frames arrive one at a time from FFmpeg's rawvideo pipe, so the
 * accumulator keeps only two double arrays regardless of how many frames
 * are sampled.
 */
public class LogoFrameStats : Object {
    public int width { get; private set; default = 0; }
    public int height { get; private set; default = 0; }
    public int frame_count { get; private set; default = 0; }

    private double[] sum;
    private double[] sum_sq;

    public LogoFrameStats (int width, int height) {
        this.width = int.max (0, width);
        this.height = int.max (0, height);
        int n = this.width * this.height;
        sum = new double[n];
        sum_sq = new double[n];
    }

    /** Returns false when the frame is not the expected size. */
    public bool add_frame (uint8[] gray) {
        int n = width * height;
        if (n == 0 || gray.length < n) return false;

        for (int i = 0; i < n; i++) {
            double v = (double) gray[i];
            sum[i] += v;
            sum_sq[i] += v * v;
        }
        frame_count++;
        return true;
    }

    public double[] compute_mean () {
        int n = width * height;
        var result = new double[n];
        if (frame_count == 0) return result;

        double inv = 1.0 / frame_count;
        for (int i = 0; i < n; i++) {
            result[i] = sum[i] * inv;
        }
        return result;
    }

    public double[] compute_stddev () {
        int n = width * height;
        var result = new double[n];
        if (frame_count < 2) return result;

        double inv = 1.0 / frame_count;
        for (int i = 0; i < n; i++) {
            double m = sum[i] * inv;
            double variance = sum_sq[i] * inv - m * m;
            result[i] = variance > 0.0 ? Math.sqrt (variance) : 0.0;
        }
        return result;
    }
}

namespace LogoDetectorLogic {

    // ── Sampling ─────────────────────────────────────────────────────────────
    //    Frames are downscaled before analysis: a watermark is a large,
    //    high-contrast structure, so full resolution buys nothing and costs
    //    a lot of memory bandwidth.
    public const int ANALYSIS_WIDTH = 480;

    /**
     * Width for the second look, taken only when the first finds nothing.
     *
     * Shrinking the frame for analysis is what blurs fine lettering: a caption
     * whose strokes are a pixel or two wide in the source goes sub-pixel at
     * 480 and averages away into its neighbours.  Scanning again at double the
     * width recovers it — measured across the test corpus, the softest real
     * watermark gains about a third of its edge strength while a drifting
     * banner's wake, already soft at any scale, *loses* about a quarter.  The
     * two move apart, so the second look is a genuinely better measurement
     * rather than a more permissive one.
     *
     * It runs second rather than instead because the first pass is the one
     * that has been validated in the field; a retry can only add a detection,
     * never take one away.
     */
    public const int ANALYSIS_WIDTH_RETRY = 960;
    public const int MIN_ANALYSIS_DIM = 16;
    public const int MIN_USABLE_FRAMES = 8;

    private const double SHORT_VIDEO_SECONDS = 45.0;
    private const double TARGET_FRAMES_SHORT = 60.0;
    private const double MIN_SAMPLE_FPS = 1.0;
    private const double MAX_SAMPLE_FPS = 6.0;
    private const double WINDOW_SECONDS = 20.0;
    private const double MIN_WINDOW_SECONDS = 2.0;
    private const double WINDOW_FPS = 2.0;
    private const double UNKNOWN_DURATION_WINDOW = 60.0;

    // ── Detection thresholds ─────────────────────────────────────────────────
    //    All pixel values are on the 0–255 grayscale scale.

    /** Minimum |dx|+|dy| in the temporal mean image to count as an edge. */
    private const double GRADIENT_MIN = 14.0;

    /**
     * A pixel counts as static when its temporal deviation falls under the
     * gate, which is a fraction of how much that footage moves anyway (see
     * detect_regions for how the reference is picked) rather than a fixed
     * number — busy footage swings far more than a talking head, and an
     * absolute threshold would only ever suit one of them.
     *
     * The fraction is set by transparency.  Under an overlay of opacity a,
     * the background still bleeds through at (1 - a), so the pixels beneath
     * it deviate by (1 - a) times as much as their surroundings.  Gating at
     * 0.5 therefore catches anything at 50% opacity or above, which covers
     * opaque station logos and the semi-transparent stamps alike.
     */
    private const double STATIC_SD_RELATIVE = 0.5;
    private const double STATIC_SD_FLOOR = 2.0;

    /**
     * How far to look when asking "how much does this part of the frame
     * normally move?".  Wide enough that a watermark is a minority of its own
     * neighbourhood, so it cannot drag its own reference down to meet it.
     */
    private const double LOCAL_REFERENCE_RADIUS_FRACTION = 1.0 / 6.0;

    /**
     * If the frame's detail never moves, the shot is a still image or a frozen
     * clip — there is nothing to tell a watermark apart from the scene, so
     * detection bails out rather than guessing.
     *
     * The measure is how much of the frame the static detail *spans*, on a
     * coarse grid, not what share of the detail it is.  The share is the
     * tempting metric and it is wrong: over footage whose moving parts are
     * soft — haze, sky, shallow depth of field — temporal averaging wipes the
     * scenery out and a crisp watermark ends up supplying nearly every edge in
     * the frame.  That reads as 95% static while being the clearest possible
     * detection.  Spatial spread does not confuse the two: a still image lights
     * up the whole grid, a watermark lights up a corner of it.
     */
    private const double MAX_STATIC_CELL_COVERAGE = 0.6;
    private const int STATIC_GRID_COLUMNS = 16;
    private const int MIN_STATIC_CELL_SIZE = 8;
    /**
     * Below this much detail in the averaged picture there is nothing to work
     * with and the scan gives up early.
     *
     * Kept low on purpose.  Soft footage — haze, sky, shallow depth of field —
     * averages down to almost nothing: a hazy 720p clip measures barely fifty
     * edge pixels once its scenery has blurred away, and even a clear success
     * on such a clip only reaches a few hundred.  Set this near that figure
     * and the guard starts turning findable watermarks away before the real
     * tests get a chance to look at them.
     */
    private const int MIN_EDGE_PIXELS = 60;

    /** Merges the separate strokes of a logo into one blob before labelling. */
    private const int DILATE_RADIUS = 2;

    // ── Blob acceptance ──────────────────────────────────────────────────────
    /**
     * A watermark rarely arrives as one blob.  Lettering breaks into a piece
     * per glyph, and a logo into a piece per stroke, so the pieces are found
     * first and assembled afterwards (see merge_adjacent).
     *
     * That means the size test has to be applied twice, at two different
     * scales.  A *fragment* only has to be big enough not to be noise — the
     * bar has to stay low, because judging a narrow glyph against a fraction
     * of the whole frame throws away the thin letters and keeps the fat ones,
     * which removes a watermark in stencil.  The assembled *region* is what
     * must actually be watermark-sized.
     */
    private const double MIN_FRAGMENT_AREA_FRACTION = 0.0002;
    private const double MIN_AREA_FRACTION = 0.0008;
    private const double MAX_AREA_FRACTION = 0.12;
    private const double MAX_SPAN_FRACTION = 0.75;
    private const int MIN_CORE_PIXELS = 12;
    private const double MIN_FILL_RATIO = 0.04;
    private const int MAX_CANDIDATES = 512;

    /**
     * Blobs running into the frame border have to prove themselves, because
     * letterbox seams, tickers and encoder edge artifacts all live there.
     *
     * What separates those from a watermark is not touching the edge — corner
     * banners routinely run off two edges at once — but being *thin*.  A seam
     * is a couple of pixels deep; a watermark is a solid shape.  So a blob
     * reaching the border is kept only if it is thick both ways, and then
     * carries a scoring penalty: running off the frame is weak evidence of
     * being picture rather than overlay, so where an inset candidate competes
     * with a border one, the border one has to be clearly better to win.
     */
    private const int BORDER_MARGIN = 3;
    private const double BORDER_TOUCH_MIN_THICKNESS = 0.05;
    private const double BORDER_TOUCH_SCORE_PENALTY = 0.35;

    /**
     * Two sanity checks against the band of picture just outside a blob.
     *
     * The area a watermark covers is never busier than the picture around it:
     * an overlay can only ever hold pixels still.  A frozen edge inside a
     * moving scene — a hard colour boundary, a lamp post, a window frame —
     * looks just as static pixel by pixel, but the box around it still churns
     * as much as its surroundings, and that is what gives it away.
     *
     * A blob whose surroundings never move at all is rejected outright: with
     * nothing moving nearby there is no evidence it is an overlay rather than
     * scenery.  Real footage always jitters a little from noise and
     * compression, so the bar is set just above zero — it only excludes
     * mathematically frozen picture, which is scenery by definition.
     */
    private const double RING_CONTRAST = 1.25;
    private const double RING_MIN_SD = 1.0;
    private const int RING_MARGIN = 4;

    /**
     * The sharpest edge a region must contain, measured in the temporal mean.
     *
     * This is what separates a watermark from the *wake* of one.  An overlay
     * pinned to the same pixels every frame averages into a pixel-exact copy
     * of itself, so its own borders and lettering stay razor sharp no matter
     * how many frames are folded in.  One that drifts, even slightly, has
     * every edge blurred across the pixels it wandered over — and the region
     * where it happens to sit most of the time still reads as "static",
     * because it is covered by flat overlay in most frames.  Those regions
     * pass every other test here and are worse than useless: delogo paints
     * over picture and leaves the watermark.
     *
     * Sharpness is the one thing averaging destroys and stillness does not,
     * so it tells the two apart.  The measure is the single strongest edge
     * rather than an average — a logo on a plain field has few sharp pixels
     * and a low mean gradient, but the few it has are as crisp as the source.
     *
     * The bar cannot go much higher than this.  Small captions are the hard
     * case: shrinking the frame for analysis softens fine lettering, so a
     * grey 24pt line on 720p measures barely over 100 while a drifting
     * banner's wake measures around 65.  When in doubt this errs low, because
     * missing a watermark only reports nothing, whereas inventing one paints
     * over the picture.
     */
    private const double MIN_MEAN_EDGE_SHARPNESS = 90.0;

    /**
     * How close two fragments must sit to be treated as one watermark.
     *
     * Deliberately tight, and in absolute pixels rather than relative to the
     * fragments: the pieces of a single overlay practically touch — the gaps
     * between the letters of a burned-in caption measure a few pixels at
     * analysis scale — whereas two genuinely separate marks sit far apart.
     * Keeping it small is what stops a chain of merges from wandering across
     * the frame; the area cap below is the backstop.
     */
    private const int MERGE_GAP_MIN = 3;
    private const double MERGE_GAP_FRACTION = 0.015;
    private const double MAX_MERGED_AREA_FRACTION = 0.20;

    /** Weight floor for blobs in the middle of the frame; corners score higher. */
    private const double EDGE_WEIGHT_BASE = 0.55;

    // ── Result selection ─────────────────────────────────────────────────────
    //    Deliberately conservative.  Painting out a stretch of real picture is
    //    a worse outcome than missing a second watermark, so only the strongest
    //    blob is returned unless another is nearly as convincing — the case of
    //    a station logo in one corner and a rating bug in another.
    public const int MAX_REGIONS = 2;
    private const double SECONDARY_SCORE_RATIO = 0.75;
    private const int MAX_PARSED_REGIONS = 8;

    // ── Output geometry ──────────────────────────────────────────────────────
    private const int MIN_PADDING_PX = 2;
    private const double PADDING_FRACTION = 0.004;

    // ═════════════════════════════════════════════════════════════════════════
    //  SAMPLING PLAN
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Picks the analysis frame size: ANALYSIS_WIDTH wide (or the source width
     * if that is smaller), preserving aspect ratio, both dimensions even.
     */
    public void compute_analysis_size (int source_w, int source_h,
                                       out int analysis_w, out int analysis_h,
                                       int target_width = ANALYSIS_WIDTH) {
        analysis_w = 0;
        analysis_h = 0;
        if (source_w <= 0 || source_h <= 0) return;

        int w = int.min (target_width, source_w);
        if (w < 2) w = 2;
        w &= ~1;

        int h = (int) Math.round ((double) w * source_h / source_w);
        if (h < 2) h = 2;
        h &= ~1;

        analysis_w = w;
        analysis_h = h;
    }

    /**
     * Spreads sampling across the video instead of decoding all of it.
     * Long files get three short windows at 12%, 45% and 78% — enough to
     * catch a persistent overlay while keeping the scan to a few seconds.
     */
    public LogoSampleWindow[] plan_sample_windows (double duration) {
        LogoSampleWindow[] windows = {};

        if (!duration.is_finite () || duration <= 0.0) {
            // Duration unknown (some raw streams) — scan from the start.
            windows += new LogoSampleWindow (0.0, UNKNOWN_DURATION_WINDOW, WINDOW_FPS);
            return windows;
        }

        if (duration <= SHORT_VIDEO_SECONDS) {
            double fps = (TARGET_FRAMES_SHORT / duration).clamp (MIN_SAMPLE_FPS, MAX_SAMPLE_FPS);
            windows += new LogoSampleWindow (0.0, duration, fps);
            return windows;
        }

        double window_len = double.min (WINDOW_SECONDS, duration * 0.15);
        double[] offsets = { 0.12, 0.45, 0.78 };
        foreach (double fraction in offsets) {
            double start = duration * fraction;
            double len = double.min (window_len, duration - start);
            if (len < MIN_WINDOW_SECONDS) continue;
            windows += new LogoSampleWindow (start, len, WINDOW_FPS);
        }

        if (windows.length == 0) {
            windows += new LogoSampleWindow (0.0, duration, WINDOW_FPS);
        }
        return windows;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  DETECTION
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Finds watermark-shaped regions in analysis-resolution statistics.
     *
     * Returns an empty array and fills @reason with a user-facing explanation
     * whenever nothing convincing is found — the caller shows that text
     * rather than inventing a rectangle.
     */
    public LogoRegion[] detect_regions (double[] mean, double[] stddev,
                                        int w, int h, out string reason) {
        reason = "";
        LogoRegion[] none = {};

        int n = w * h;
        if (w < MIN_ANALYSIS_DIM || h < MIN_ANALYSIS_DIM
            || mean.length < n || stddev.length < n) {
            reason = "The sampled frames were too small to analyze";
            return none;
        }

        double[] gradient = compute_gradient (mean, w, h);
        // Two references, and the more permissive one wins.
        //
        // The global median is the median over the whole frame, not over edge
        // pixels only: a large watermark supplies most of the frame's static
        // edges, so an edge-only median would be dragged down by the very
        // thing being looked for.
        //
        // The local mean covers the case the global median handles badly — a
        // frame that is half frozen and half busy, like a locked-off shot of a
        // moving subject.  There the global median describes neither half, and
        // a watermark sitting over the still half would never look still
        // enough to notice.
        double global_reference = histogram_percentile (stddev, 0.5);
        int radius = int.max (4, (int) (w * LOCAL_REFERENCE_RADIUS_FRACTION));
        double[] local_reference = box_mean (stddev, w, h, radius);

        var core = new bool[n];
        int edge_pixels = 0;
        int static_edge_pixels = 0;
        for (int i = 0; i < n; i++) {
            if (gradient[i] < GRADIENT_MIN) continue;
            edge_pixels++;

            double reference = double.max (global_reference, local_reference[i]);
            double gate = double.max (STATIC_SD_FLOOR, reference * STATIC_SD_RELATIVE);
            if (stddev[i] <= gate) {
                core[i] = true;
                static_edge_pixels++;
            }
        }

        if (edge_pixels < scaled_count (MIN_EDGE_PIXELS, w)) {
            reason = "The picture is too soft to scan — averaging the frames left almost no detail behind";
            return none;
        }
        if (static_edge_pixels == 0) {
            reason = "No static overlay found — every detailed part of the picture moves";
            return none;
        }
        if (static_cell_coverage (core, w, h) > MAX_STATIC_CELL_COVERAGE) {
            reason = "The picture barely moves, so a watermark cannot be told apart from the scene";
            return none;
        }

        bool[] grown = dilate (core, w, h, scaled_distance (DILATE_RADIUS, w));
        LogoRegion[] fragments = find_candidates (grown, core, gradient, stddev, w, h);
        // Assemble the pieces before judging them: the glyphs of a caption are
        // each too small to be a watermark, but together they are one.
        LogoRegion[] candidates = watermark_sized (
            merge_adjacent (fragments, w, h), w, h);
        if (candidates.length == 0) {
            reason = "No watermark-shaped region stood out from the picture";
            return none;
        }

        sort_by_score_desc (candidates);

        // The best region, plus any close runner-up.
        double best = candidates[0].score;
        LogoRegion[] selected = {};
        for (int i = 0; i < candidates.length && selected.length < MAX_REGIONS; i++) {
            if (i > 0 && candidates[i].score < best * SECONDARY_SCORE_RATIO) break;
            selected += candidates[i];
        }
        return selected;
    }

    /**
     * Maps regions from analysis resolution back to source resolution and pads
     * them slightly — delogo interpolates from the pixels just outside its box,
     * so a rectangle that clips the logo's own edge smears the leftovers.
     */
    public LogoRegion[] scale_regions_to_source (LogoRegion[] regions,
                                                 int analysis_w, int analysis_h,
                                                 int source_w, int source_h) {
        LogoRegion[] result = {};
        if (analysis_w <= 0 || analysis_h <= 0 || source_w <= 4 || source_h <= 4) {
            return result;
        }

        double sx = (double) source_w / analysis_w;
        double sy = (double) source_h / analysis_h;
        int pad = int.max (MIN_PADDING_PX,
                           (int) Math.round (source_w * PADDING_FRACTION));

        foreach (LogoRegion region in regions) {
            int x0 = (int) Math.floor (region.x * sx) - pad;
            int y0 = (int) Math.floor (region.y * sy) - pad;
            int x1 = (int) Math.ceil ((region.x + region.width) * sx) + pad;
            int y1 = (int) Math.ceil ((region.y + region.height) * sy) + pad;

            // delogo needs at least one pixel of real frame on every side.
            x0 = x0.clamp (1, source_w - 2);
            y0 = y0.clamp (1, source_h - 2);
            x1 = x1.clamp (x0 + 1, source_w - 1);
            y1 = y1.clamp (y0 + 1, source_h - 1);

            result += new LogoRegion (x0, y0, x1 - x0, y1 - y0, region.score);
        }
        return result;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  REGION TEXT  ↔  FILTER ARGUMENTS
    // ═════════════════════════════════════════════════════════════════════════

    public string format_regions (LogoRegion[] regions) {
        string[] parts = {};
        foreach (LogoRegion region in regions) {
            parts += region.to_region_string ();
        }
        return string.joinv (",", parts);
    }

    /** Tolerant parser for the Region entry — invalid entries are skipped. */
    public LogoRegion[] parse_regions (string? text) {
        LogoRegion[] result = {};
        if (text == null) return result;

        foreach (string chunk in text.split (",")) {
            string entry = chunk.strip ();
            if (entry.length == 0) continue;

            string[] parts = entry.split (":");
            if (parts.length != 4) continue;

            int x, y, w, h;
            if (!parse_bounded_int (parts[0], 0, out x)) continue;
            if (!parse_bounded_int (parts[1], 0, out y)) continue;
            if (!parse_bounded_int (parts[2], 1, out w)) continue;
            if (!parse_bounded_int (parts[3], 1, out h)) continue;

            result += new LogoRegion (x, y, w, h);
            if (result.length >= MAX_PARSED_REGIONS) break;
        }
        return result;
    }

    /** One delogo instance per region; chained, they remove several logos. */
    public string[] build_delogo_filters (string? regions_text) {
        string[] filters = {};
        foreach (LogoRegion region in parse_regions (regions_text)) {
            filters += "delogo=x=%d:y=%d:w=%d:h=%d".printf (
                region.x, region.y, region.width, region.height);
        }
        return filters;
    }

    public string describe_regions (LogoRegion[] regions) {
        if (regions.length == 0) {
            return "No watermark detected";
        }
        if (regions.length == 1) {
            LogoRegion region = regions[0];
            return "Found a %d×%d watermark at %d,%d".printf (
                region.width, region.height, region.x, region.y);
        }
        return "Found %d watermark areas".printf (regions.length);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNALS
    // ═════════════════════════════════════════════════════════════════════════

    private bool parse_bounded_int (string token, int minimum, out int value) {
        value = 0;
        string text = token.strip ();
        if (text.length == 0 || text.length > 9) return false;

        for (int i = 0; i < text.length; i++) {
            if (!text[i].isdigit ()) return false;
        }

        int parsed = int.parse (text);
        if (parsed < minimum) return false;

        value = parsed;
        return true;
    }

    /**
     * Fraction of coarse grid cells holding at least one static edge pixel.
     *
     * Deliberately insensitive to how *many* static pixels there are — one is
     * as good as a thousand for lighting a cell.  A watermark is compact no
     * matter how detailed it is; frozen picture is everywhere no matter how
     * sparse.  Counting pixels would conflate the two, counting cells does not.
     */
    private double static_cell_coverage (bool[] core, int w, int h) {
        int cell = int.max (scaled_distance (MIN_STATIC_CELL_SIZE, w),
                            w / STATIC_GRID_COLUMNS);
        int columns = (w + cell - 1) / cell;
        int rows = (h + cell - 1) / cell;
        if (columns <= 0 || rows <= 0) return 0.0;

        var lit = new bool[columns * rows];
        for (int y = 0; y < h; y++) {
            int row = y * w;
            int cell_row = (y / cell) * columns;
            for (int x = 0; x < w; x++) {
                if (core[row + x]) lit[cell_row + x / cell] = true;
            }
        }

        int count = 0;
        foreach (bool value in lit) {
            if (value) count++;
        }
        return (double) count / (columns * rows);
    }

    /**
     * How far the frame being analyzed is above the width the thresholds below
     * were measured at.  Never less than 1: the numbers are calibrated for 480
     * and a source too small to reach it keeps them exactly as they are.
     */
    private double analysis_scale (int w) {
        return double.max (1.0, (double) w / ANALYSIS_WIDTH);
    }

    /**
     * A distance in pixels, restated for the frame actually being analyzed.
     * Gaps between letters, dilation reach, how far in from the border a logo
     * must sit — all are distances on the picture, so they grow with it.
     */
    private int scaled_distance (int baseline, int w) {
        return int.max (1, (int) Math.round (baseline * analysis_scale (w)));
    }

    /** A pixel count, restated for the frame being analyzed: area, so scale². */
    private int scaled_count (int baseline, int w) {
        double s = analysis_scale (w);
        return int.max (1, (int) Math.round (baseline * s * s));
    }

    /**
     * The fill-ratio bar, restated for the frame being analyzed — and it falls
     * as the frame grows, which is the opposite of the obvious guess.
     *
     * Fill is detected pixels over box area.  The detected pixels are *edges*,
     * so they trace the outline of the lettering and multiply roughly with the
     * frame's width, while the box they sit in grows with its area.  Measured
     * on a real banner: doubling the width took the edge count from 157 to 380
     * but the box from 2790 to 11284, so fill fell from 0.056 to 0.034 and a
     * perfectly good watermark dropped out of a fixed 0.04 bar.
     */
    private double scaled_fill_ratio (int w) {
        return MIN_FILL_RATIO / analysis_scale (w);
    }

    /** Cheap central-difference gradient — enough to find lettering and logos. */
    private double[] compute_gradient (double[] mean, int w, int h) {
        var gradient = new double[w * h];
        for (int y = 1; y < h - 1; y++) {
            int row = y * w;
            for (int x = 1; x < w - 1; x++) {
                int i = row + x;
                double dx = mean[i + 1] - mean[i - 1];
                double dy = mean[i + w] - mean[i - w];
                gradient[i] = Math.fabs (dx) + Math.fabs (dy);
            }
        }
        return gradient;
    }

    /** Percentile via a 256-bucket histogram — O(n) and outlier-proof. */
    private double histogram_percentile (double[] values, double fraction) {
        var bins = new int[256];
        int total = 0;

        foreach (double value in values) {
            int bucket = (int) Math.round (value);
            bins[bucket.clamp (0, 255)]++;
            total++;
        }
        if (total == 0) return 0.0;

        int target = (int) (total * fraction);
        int running = 0;
        for (int bucket = 0; bucket < 256; bucket++) {
            running += bins[bucket];
            if (running > target) return (double) bucket;
        }
        return 255.0;
    }

    /**
     * Separable box mean over a square window, via per-row and per-column
     * prefix sums so the cost does not grow with the radius.
     */
    private double[] box_mean (double[] values, int w, int h, int radius) {
        var horizontal = new double[w * h];
        var prefix = new double[w + 1];

        for (int y = 0; y < h; y++) {
            int row = y * w;
            for (int x = 0; x < w; x++) {
                prefix[x + 1] = prefix[x] + values[row + x];
            }
            for (int x = 0; x < w; x++) {
                int from = int.max (0, x - radius);
                int to = int.min (w - 1, x + radius);
                horizontal[row + x] = (prefix[to + 1] - prefix[from]) / (to - from + 1);
            }
        }

        var result = new double[w * h];
        var column = new double[h + 1];

        for (int x = 0; x < w; x++) {
            for (int y = 0; y < h; y++) {
                column[y + 1] = column[y] + horizontal[y * w + x];
            }
            for (int y = 0; y < h; y++) {
                int from = int.max (0, y - radius);
                int to = int.min (h - 1, y + radius);
                result[y * w + x] = (column[to + 1] - column[from]) / (to - from + 1);
            }
        }
        return result;
    }

    /** Separable box dilation, so a logo's separate strokes become one blob. */
    private bool[] dilate (bool[] mask, int w, int h, int radius) {
        var horizontal = new bool[w * h];
        for (int y = 0; y < h; y++) {
            int row = y * w;
            for (int x = 0; x < w; x++) {
                bool on = false;
                int from = int.max (0, x - radius);
                int to = int.min (w - 1, x + radius);
                for (int k = from; k <= to && !on; k++) {
                    on = mask[row + k];
                }
                horizontal[row + x] = on;
            }
        }

        var result = new bool[w * h];
        for (int y = 0; y < h; y++) {
            int from = int.max (0, y - radius);
            int to = int.min (h - 1, y + radius);
            for (int x = 0; x < w; x++) {
                bool on = false;
                for (int k = from; k <= to && !on; k++) {
                    on = horizontal[k * w + x];
                }
                result[y * w + x] = on;
            }
        }
        return result;
    }

    /**
     * Flood-fills the dilated mask into blobs and keeps the ones shaped like
     * a watermark.  The stack is explicit — a recursive fill blows the C stack
     * on large connected areas.
     */
    private LogoRegion[] find_candidates (bool[] grown, bool[] core,
                                          double[] gradient, double[] stddev,
                                          int w, int h) {
        LogoRegion[] candidates = {};
        int n = w * h;
        var visited = new bool[n];
        var stack = new int[n];

        double frame_area = (double) n;
        // Fragments are held to the low bar; watermark_sized judges the whole.
        double min_area = frame_area * MIN_FRAGMENT_AREA_FRACTION;
        double max_area = frame_area * MAX_AREA_FRACTION;
        int max_span_w = (int) (w * MAX_SPAN_FRACTION);
        int max_span_h = (int) (h * MAX_SPAN_FRACTION);
        int min_border_thickness = int.max (
            4, (int) (int.min (w, h) * BORDER_TOUCH_MIN_THICKNESS));
        int min_core_pixels = scaled_count (MIN_CORE_PIXELS, w);
        int border_margin = scaled_distance (BORDER_MARGIN, w);
        double min_fill = scaled_fill_ratio (w);

        for (int seed = 0; seed < n; seed++) {
            if (!grown[seed] || visited[seed]) continue;

            int top = 0;
            stack[top++] = seed;
            visited[seed] = true;

            int min_x = w, min_y = h, max_x = -1, max_y = -1;
            // The core extent is tracked apart from the dilated one: dilation
            // is a grouping device, and letting its halo decide how close the
            // blob sits to the frame edge would disqualify any watermark inset
            // by less than DILATE_RADIUS + BORDER_MARGIN — which at analysis
            // scale is a corner logo only ten source pixels in, a perfectly
            // ordinary place to put one.
            int core_min_x = w, core_min_y = h, core_max_x = -1, core_max_y = -1;
            int core_pixels = 0;
            double gradient_sum = 0.0;

            while (top > 0) {
                int index = stack[--top];
                int px = index % w;
                int py = index / w;

                if (px < min_x) min_x = px;
                if (px > max_x) max_x = px;
                if (py < min_y) min_y = py;
                if (py > max_y) max_y = py;

                if (core[index]) {
                    core_pixels++;
                    gradient_sum += gradient[index];
                    if (px < core_min_x) core_min_x = px;
                    if (px > core_max_x) core_max_x = px;
                    if (py < core_min_y) core_min_y = py;
                    if (py > core_max_y) core_max_y = py;
                }

                for (int dy = -1; dy <= 1; dy++) {
                    int ny = py + dy;
                    if (ny < 0 || ny >= h) continue;
                    for (int dx = -1; dx <= 1; dx++) {
                        int nx = px + dx;
                        if (nx < 0 || nx >= w) continue;
                        int neighbour = ny * w + nx;
                        if (visited[neighbour] || !grown[neighbour]) continue;
                        visited[neighbour] = true;
                        stack[top++] = neighbour;
                    }
                }
            }

            if (core_pixels < min_core_pixels) continue;

            // Judged on the core rather than the dilated blob, so a logo inset
            // by less than the dilation radius is not pushed under the margin
            // by its own halo.
            bool touches_border =
                core_min_x < border_margin || core_min_y < border_margin
                || core_max_x >= w - border_margin
                || core_max_y >= h - border_margin;

            if (touches_border
                && (core_max_x - core_min_x + 1 < min_border_thickness
                    || core_max_y - core_min_y + 1 < min_border_thickness)) continue;

            if (!box_is_plausible (min_x, min_y, max_x, max_y, core_pixels,
                                   min_area, max_area,
                                   max_span_w, max_span_h, min_fill)) continue;

            if (peak_gradient (gradient, w, min_x, min_y, max_x, max_y)
                < MIN_MEAN_EDGE_SHARPNESS) continue;

            int box_w = max_x - min_x + 1;
            int box_h = max_y - min_y + 1;

            double box_sd, ring_sd;
            measure_box_and_ring (stddev, w, h, min_x, min_y, max_x, max_y,
                                  out box_sd, out ring_sd);
            if (ring_sd <= RING_MIN_SD) continue;
            if (box_sd > RING_CONTRAST * ring_sd) continue;

            double score = score_candidate (box_w, box_h, core_pixels, gradient_sum,
                                            min_x + box_w / 2, min_y + box_h / 2, w, h);
            if (touches_border) score *= BORDER_TOUCH_SCORE_PENALTY;
            candidates += new LogoRegion (min_x, min_y, box_w, box_h, score);
            if (candidates.length >= MAX_CANDIDATES) break;
        }

        return candidates;
    }

    /**
     * Unions fragments that sit close enough to be parts of one watermark.
     *
     * Scores add up as pieces combine, so a caption assembled from six glyphs
     * outranks whatever single blob happened to score highest on its own.
     */
    private LogoRegion[] merge_adjacent (LogoRegion[] fragments, int w, int h) {
        if (fragments.length < 2) return fragments;

        int gap = int.max (scaled_distance (MERGE_GAP_MIN, w),
                           (int) (w * MERGE_GAP_FRACTION));
        double area_limit = (double) w * h * MAX_MERGED_AREA_FRACTION;

        LogoRegion[] merged = {};
        foreach (LogoRegion fragment in fragments) {
            merged += new LogoRegion (fragment.x, fragment.y, fragment.width,
                                      fragment.height, fragment.score);
        }

        bool changed = true;
        while (changed) {
            changed = false;
            for (int a = 0; a < merged.length && !changed; a++) {
                for (int b = a + 1; b < merged.length && !changed; b++) {
                    if (gap_between (merged[a], merged[b], true) > gap) continue;
                    if (gap_between (merged[a], merged[b], false) > gap) continue;

                    int x0 = int.min (merged[a].x, merged[b].x);
                    int y0 = int.min (merged[a].y, merged[b].y);
                    int x1 = int.max (merged[a].x + merged[a].width,
                                      merged[b].x + merged[b].width);
                    int y1 = int.max (merged[a].y + merged[a].height,
                                      merged[b].y + merged[b].height);
                    if ((double) (x1 - x0) * (y1 - y0) > area_limit) continue;

                    var union = new LogoRegion (x0, y0, x1 - x0, y1 - y0,
                                                merged[a].score + merged[b].score);
                    LogoRegion[] rebuilt = {};
                    for (int i = 0; i < merged.length; i++) {
                        if (i != a && i != b) rebuilt += merged[i];
                    }
                    rebuilt += union;
                    merged = rebuilt;
                    changed = true;
                }
            }
        }
        return merged;
    }

    /** Separation between two boxes on one axis; negative means they overlap. */
    private int gap_between (LogoRegion a, LogoRegion b, bool horizontal) {
        if (horizontal) {
            return int.max (a.x, b.x) - int.min (a.x + a.width, b.x + b.width);
        }
        return int.max (a.y, b.y) - int.min (a.y + a.height, b.y + b.height);
    }

    /** Keeps only assembled regions that are plausibly a whole watermark. */
    private LogoRegion[] watermark_sized (LogoRegion[] regions, int w, int h) {
        double frame_area = (double) w * h;
        double min_area = frame_area * MIN_AREA_FRACTION;
        double max_area = frame_area * MAX_AREA_FRACTION;
        int max_span_w = (int) (w * MAX_SPAN_FRACTION);
        int max_span_h = (int) (h * MAX_SPAN_FRACTION);

        LogoRegion[] kept = {};
        foreach (LogoRegion region in regions) {
            double area = (double) region.width * region.height;
            if (area < min_area || area > max_area) continue;
            if (region.width > max_span_w || region.height > max_span_h) continue;
            kept += region;
        }
        return kept;
    }

    /** Strongest edge anywhere in a bounding box of the temporal mean. */
    private double peak_gradient (double[] gradient, int w,
                                  int min_x, int min_y, int max_x, int max_y) {
        double peak = 0.0;
        for (int y = min_y; y <= max_y; y++) {
            int row = y * w;
            for (int x = min_x; x <= max_x; x++) {
                if (gradient[row + x] > peak) peak = gradient[row + x];
            }
        }
        return peak;
    }

    /** Whether a bounding box is the right size and shape to be a watermark. */
    private bool box_is_plausible (int min_x, int min_y, int max_x, int max_y,
                                   int core_pixels,
                                   double min_area, double max_area,
                                   int max_span_w, int max_span_h,
                                   double min_fill_ratio) {
        if (max_x < min_x || max_y < min_y) return false;

        int box_w = max_x - min_x + 1;
        int box_h = max_y - min_y + 1;
        double box_area = (double) box_w * box_h;

        if (box_area < min_area || box_area > max_area) return false;
        if (box_w > max_span_w || box_h > max_span_h) return false;
        return core_pixels / box_area >= min_fill_ratio;
    }

    /**
     * Mean temporal deviation inside a bounding box and in the band of picture
     * just outside it.
     */
    private void measure_box_and_ring (double[] stddev, int w, int h,
                                       int min_x, int min_y, int max_x, int max_y,
                                       out double box_mean, out double ring_mean) {
        int margin = scaled_distance (RING_MARGIN, w);
        int x0 = int.max (0, min_x - margin);
        int y0 = int.max (0, min_y - margin);
        int x1 = int.min (w - 1, max_x + margin);
        int y1 = int.min (h - 1, max_y + margin);

        double box_sum = 0.0;
        double ring_sum = 0.0;
        int box_count = 0;
        int ring_count = 0;

        for (int y = y0; y <= y1; y++) {
            bool inside_rows = y >= min_y && y <= max_y;
            for (int x = x0; x <= x1; x++) {
                double value = stddev[y * w + x];
                if (inside_rows && x >= min_x && x <= max_x) {
                    box_sum += value;
                    box_count++;
                } else {
                    ring_sum += value;
                    ring_count++;
                }
            }
        }

        box_mean = box_count > 0 ? box_sum / box_count : 0.0;
        ring_mean = ring_count > 0 ? ring_sum / ring_count : 0.0;
    }

    /**
     * Bigger, denser, sharper and closer to a frame edge all make a blob more
     * watermark-like.  Size enters as a square root: confidence really does
     * grow with how much static structure there is — a stray sliver of frozen
     * scenery is small, a logo is not — but not so fast that a large blob wins
     * on pixel count alone.
     */
    private double score_candidate (int box_w, int box_h, int core_pixels,
                                    double gradient_sum, int centre_x, int centre_y,
                                    int w, int h) {
        double box_area = (double) box_w * box_h;
        if (box_area <= 0.0 || core_pixels <= 0) return 0.0;

        double average_gradient = gradient_sum / core_pixels;
        double density = core_pixels / box_area;
        double edge_proximity = compute_edge_proximity (centre_x, centre_y, w, h);

        return Math.sqrt ((double) core_pixels)
             * average_gradient
             * (0.3 + 0.7 * density)
             * (EDGE_WEIGHT_BASE + (1.0 - EDGE_WEIGHT_BASE) * edge_proximity);
    }

    /** 1.0 hugging a frame edge, 0.0 dead centre. */
    private double compute_edge_proximity (int centre_x, int centre_y, int w, int h) {
        double dx = (double) int.min (centre_x, w - 1 - centre_x) / (w * 0.5);
        double dy = (double) int.min (centre_y, h - 1 - centre_y) / (h * 0.5);
        return 1.0 - double.min (dx, dy).clamp (0.0, 1.0);
    }

    /** Insertion sort — candidate counts are small and capped. */
    private void sort_by_score_desc (LogoRegion[] regions) {
        for (int i = 1; i < regions.length; i++) {
            LogoRegion key = regions[i];
            int j = i - 1;
            while (j >= 0 && regions[j].score < key.score) {
                regions[j + 1] = regions[j];
                j--;
            }
            regions[j + 1] = key;
        }
    }
}
