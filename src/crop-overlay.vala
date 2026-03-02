using Gtk;
using Gdk;

// ═══════════════════════════════════════════════════════════════════════════════
//  CropOverlay — Interactive crop rectangle drawn over the video player
//
//  Sits as a transparent layer on top of a Gtk.Picture inside a Gtk.Overlay.
//  The user clicks and drags to create or adjust a crop rectangle, which maps
//  directly to FFmpeg's  crop=W:H:X:Y  filter.
//
//  Features:
//    • Click-drag to create a new selection
//    • Drag inside the selection to move it
//    • Drag corner/edge handles to resize
//    • Semi-transparent dark scrim outside the crop area
//    • Rule-of-thirds grid, dimension badge, corner handles
//    • Emits crop_changed() with video-pixel coordinates
//    • All values snapped to even numbers (FFmpeg requirement)
// ═══════════════════════════════════════════════════════════════════════════════

public class CropOverlay : Gtk.DrawingArea {

    // ── Video source dimensions (set by VideoPlayer) ─────────────────────────
    private int _video_width  = 0;
    private int _video_height = 0;

    // ── Crop rectangle in VIDEO coordinates ──────────────────────────────────
    private double _crop_x = 0;
    private double _crop_y = 0;
    private double _crop_w = 0;
    private double _crop_h = 0;
    private bool   _has_crop = false;

    // ── Interaction state ────────────────────────────────────────────────────
    private const double HANDLE_SIZE   = 10.0;
    private const double EDGE_ZONE     = 8.0;
    private const double MIN_CROP_PX   = 32.0;   // minimum crop in video pixels

    private int   drag_mode = 0;  // 0=NONE, 1=CREATE, 2=MOVE, 3..10=resize handles
    private double drag_start_vx;
    private double drag_start_vy;
    private double drag_orig_x;
    private double drag_orig_y;
    private double drag_orig_w;
    private double drag_orig_h;

    // Resize handle identifiers
    private const int DRAG_NONE      = 0;
    private const int DRAG_CREATE    = 1;
    private const int DRAG_MOVE      = 2;
    private const int DRAG_TL        = 3;
    private const int DRAG_TR        = 4;
    private const int DRAG_BL        = 5;
    private const int DRAG_BR        = 6;
    private const int DRAG_T         = 7;
    private const int DRAG_B         = 8;
    private const int DRAG_L         = 9;
    private const int DRAG_R         = 10;

    // ── Signal ───────────────────────────────────────────────────────────────
    public signal void crop_changed (int crop_w, int crop_h, int crop_x, int crop_y);

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public CropOverlay () {
        set_can_target (true);
        set_hexpand (true);
        set_vexpand (true);

        // Drawing
        set_draw_func (on_draw);

        // ── Drag gesture for creating / moving / resizing ────────────────────
        var drag = new Gtk.GestureDrag ();
        drag.set_button (1);
        drag.drag_begin.connect (on_drag_begin);
        drag.drag_update.connect (on_drag_update);
        drag.drag_end.connect (on_drag_end);
        add_controller (drag);

        // ── Motion controller for cursor changes ─────────────────────────────
        var motion = new Gtk.EventControllerMotion ();
        motion.motion.connect (on_motion);
        motion.leave.connect (() => {
            set_cursor_from_name ("default");
        });
        add_controller (motion);

        // ── Key controller for Escape to clear ───────────────────────────────
        var key = new Gtk.EventControllerKey ();
        key.key_pressed.connect ((keyval, keycode, state) => {
            if (keyval == Gdk.Key.Escape) {
                clear_crop ();
                return true;
            }
            return false;
        });
        add_controller (key);
        set_focusable (true);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PUBLIC API
    // ═════════════════════════════════════════════════════════════════════════

    public void set_video_size (int w, int h) {
        _video_width  = w;
        _video_height = h;
        queue_draw ();
    }

    public bool has_crop () {
        return _has_crop && _crop_w > 0 && _crop_h > 0;
    }

    /**
     * Returns the crop in FFmpeg "W:H:X:Y" format, or "" if none.
     */
    public string get_crop_string () {
        if (!has_crop ()) return "";
        int w = snap_even ((int) _crop_w);
        int h = snap_even ((int) _crop_h);
        int x = snap_even ((int) _crop_x);
        int y = snap_even ((int) _crop_y);
        return "%d:%d:%d:%d".printf (w, h, x, y);
    }

    /**
     * Set crop from an FFmpeg "W:H:X:Y" string.
     */
    public void set_crop_string (string val) {
        if (val.strip () == "" || val == "w:h:x:y") {
            clear_crop ();
            return;
        }

        string clean = val.strip ();
        if (clean.has_prefix ("crop=")) clean = clean.substring (5);

        string[] parts = clean.split (":");
        if (parts.length == 4) {
            _crop_w = double.parse (parts[0]);
            _crop_h = double.parse (parts[1]);
            _crop_x = double.parse (parts[2]);
            _crop_y = double.parse (parts[3]);
            _has_crop = (_crop_w > 0 && _crop_h > 0);
            queue_draw ();
            if (_has_crop)
                crop_changed ((int) _crop_w, (int) _crop_h, (int) _crop_x, (int) _crop_y);
        }
    }

    public void clear_crop () {
        _has_crop = false;
        _crop_x = 0; _crop_y = 0;
        _crop_w = 0; _crop_h = 0;
        queue_draw ();
        crop_changed (0, 0, 0, 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  COORDINATE MAPPING — Widget ↔ Video
    // ═════════════════════════════════════════════════════════════════════════

    private struct DisplayRect {
        double x;
        double y;
        double w;
        double h;
    }

    /**
     * Compute the rectangle where the video is actually painted inside this
     * widget, accounting for the Picture's CONTAIN fit mode.
     */
    private DisplayRect get_display_rect () {
        int widget_w = get_width ();
        int widget_h = get_height ();
        DisplayRect r = { 0, 0, widget_w, widget_h };

        if (_video_width <= 0 || _video_height <= 0 || widget_w <= 0 || widget_h <= 0)
            return r;

        double video_aspect  = (double) _video_width  / _video_height;
        double widget_aspect = (double) widget_w / widget_h;

        if (widget_aspect > video_aspect) {
            // Pillarboxing — bars on left/right
            r.h = widget_h;
            r.w = r.h * video_aspect;
            r.x = (widget_w - r.w) / 2.0;
            r.y = 0;
        } else {
            // Letterboxing — bars on top/bottom
            r.w = widget_w;
            r.h = r.w / video_aspect;
            r.x = 0;
            r.y = (widget_h - r.h) / 2.0;
        }

        return r;
    }

    /** Widget pixel → Video pixel */
    private void widget_to_video (double wx, double wy, out double vx, out double vy) {
        var r = get_display_rect ();
        if (r.w <= 0 || r.h <= 0 || _video_width <= 0 || _video_height <= 0) {
            vx = 0; vy = 0; return;
        }
        vx = ((wx - r.x) / r.w) * _video_width;
        vy = ((wy - r.y) / r.h) * _video_height;
    }

    /** Video pixel → Widget pixel */
    private void video_to_widget (double vx, double vy, out double wx, out double wy) {
        var r = get_display_rect ();
        if (_video_width <= 0 || _video_height <= 0) {
            wx = 0; wy = 0; return;
        }
        wx = r.x + (vx / _video_width)  * r.w;
        wy = r.y + (vy / _video_height) * r.h;
    }

    /** Video distance → Widget distance (for sizes) */
    private double video_w_to_widget (double vw) {
        if (_video_width <= 0) return 0;
        var r = get_display_rect ();
        return (vw / _video_width) * r.w;
    }
    private double video_h_to_widget (double vh) {
        if (_video_height <= 0) return 0;
        var r = get_display_rect ();
        return (vh / _video_height) * r.h;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  DRAWING
    // ═════════════════════════════════════════════════════════════════════════

    private void on_draw (Gtk.DrawingArea area, Cairo.Context cr, int width, int height) {
        if (_video_width <= 0 || _video_height <= 0) return;

        var dr = get_display_rect ();

        if (!_has_crop) {
            // No crop defined — draw a subtle hint overlay
            draw_empty_hint (cr, dr, width, height);
            return;
        }

        // Map crop rect to widget coords
        double rx, ry;
        video_to_widget (_crop_x, _crop_y, out rx, out ry);
        double rw = video_w_to_widget (_crop_w);
        double rh = video_h_to_widget (_crop_h);

        // ── 1. Dark scrim outside crop area ──────────────────────────────────
        cr.set_source_rgba (0, 0, 0, 0.55);
        // Top bar
        cr.rectangle (dr.x, dr.y, dr.w, ry - dr.y);
        cr.fill ();
        // Bottom bar
        cr.rectangle (dr.x, ry + rh, dr.w, (dr.y + dr.h) - (ry + rh));
        cr.fill ();
        // Left bar
        cr.rectangle (dr.x, ry, rx - dr.x, rh);
        cr.fill ();
        // Right bar
        cr.rectangle (rx + rw, ry, (dr.x + dr.w) - (rx + rw), rh);
        cr.fill ();

        // ── 2. Crop border ───────────────────────────────────────────────────
        cr.set_source_rgba (1.0, 1.0, 1.0, 0.9);
        cr.set_line_width (2.0);
        cr.rectangle (rx, ry, rw, rh);
        cr.stroke ();

        // ── 3. Rule-of-thirds grid ───────────────────────────────────────────
        cr.set_source_rgba (1.0, 1.0, 1.0, 0.25);
        cr.set_line_width (0.8);
        double[] thirds = { 1.0/3.0, 2.0/3.0 };
        foreach (double t in thirds) {
            // Vertical
            double gx = rx + rw * t;
            cr.move_to (gx, ry);
            cr.line_to (gx, ry + rh);
            cr.stroke ();
            // Horizontal
            double gy = ry + rh * t;
            cr.move_to (rx, gy);
            cr.line_to (rx + rw, gy);
            cr.stroke ();
        }

        // ── 4. Corner handles ────────────────────────────────────────────────
        draw_handles (cr, rx, ry, rw, rh);

        // ── 5. Dimension badge ───────────────────────────────────────────────
        draw_dimension_badge (cr, rx, ry, rw, rh);
    }

    private void draw_empty_hint (Cairo.Context cr, DisplayRect dr, int width, int height) {
        // Subtle crosshair in the center
        double cx = dr.x + dr.w / 2.0;
        double cy = dr.y + dr.h / 2.0;

        cr.set_source_rgba (1, 1, 1, 0.15);
        cr.set_line_width (1.0);

        double arm = 24.0;
        cr.move_to (cx - arm, cy);
        cr.line_to (cx + arm, cy);
        cr.stroke ();
        cr.move_to (cx, cy - arm);
        cr.line_to (cx, cy + arm);
        cr.stroke ();

        // Hint text
        cr.set_source_rgba (1, 1, 1, 0.35);
        cr.select_font_face ("sans-serif", Cairo.FontSlant.NORMAL, Cairo.FontWeight.NORMAL);
        cr.set_font_size (13);
        Cairo.TextExtents te;
        string hint = "Click and drag to define crop area";
        cr.text_extents (hint, out te);
        cr.move_to (cx - te.width / 2.0, cy + arm + 20);
        cr.show_text (hint);
    }

    private void draw_handles (Cairo.Context cr, double rx, double ry, double rw, double rh) {
        double hs = HANDLE_SIZE;
        double hh = hs / 2.0;

        // Handle positions: corners + edge midpoints
        double[,] pts = {
            { rx,          ry },            // TL
            { rx + rw,     ry },            // TR
            { rx,          ry + rh },       // BL
            { rx + rw,     ry + rh },       // BR
            { rx + rw/2,   ry },            // T
            { rx + rw/2,   ry + rh },       // B
            { rx,          ry + rh/2 },     // L
            { rx + rw,     ry + rh/2 }      // R
        };

        for (int i = 0; i < 8; i++) {
            double px = pts[i, 0];
            double py = pts[i, 1];

            // White fill
            cr.set_source_rgba (1, 1, 1, 0.95);
            cr.rectangle (px - hh, py - hh, hs, hs);
            cr.fill ();

            // Dark border
            cr.set_source_rgba (0.15, 0.15, 0.15, 0.8);
            cr.set_line_width (1.2);
            cr.rectangle (px - hh, py - hh, hs, hs);
            cr.stroke ();
        }
    }

    private void draw_dimension_badge (Cairo.Context cr, double rx, double ry, double rw, double rh) {
        int w = snap_even ((int) _crop_w);
        int h = snap_even ((int) _crop_h);
        string text = "%d × %d".printf (w, h);

        cr.select_font_face ("sans-serif", Cairo.FontSlant.NORMAL, Cairo.FontWeight.BOLD);
        cr.set_font_size (12);
        Cairo.TextExtents te;
        cr.text_extents (text, out te);

        double pad = 6.0;
        double bw = te.width + pad * 2;
        double bh = te.height + pad * 2;

        // Position badge below the crop rect (or above if near bottom)
        double bx = rx + (rw - bw) / 2.0;
        double by = ry + rh + 8.0;

        int widget_h = get_height ();
        if (by + bh > widget_h - 4) {
            by = ry - bh - 8.0;
        }

        // Badge background
        cr.set_source_rgba (0.1, 0.1, 0.1, 0.85);
        draw_rounded_rect (cr, bx, by, bw, bh, 4.0);
        cr.fill ();

        // Badge text
        cr.set_source_rgba (1, 1, 1, 0.95);
        cr.move_to (bx + pad, by + pad + te.height);
        cr.show_text (text);
    }

    private static void draw_rounded_rect (Cairo.Context cr, double x, double y,
                                            double w, double h, double r) {
        cr.new_sub_path ();
        cr.arc (x + w - r, y + r,     r, -Math.PI / 2, 0);
        cr.arc (x + w - r, y + h - r, r, 0,             Math.PI / 2);
        cr.arc (x + r,     y + h - r, r, Math.PI / 2,   Math.PI);
        cr.arc (x + r,     y + r,     r, Math.PI,       3 * Math.PI / 2);
        cr.close_path ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  HIT TESTING — Which part of the crop rect did we click?
    // ═════════════════════════════════════════════════════════════════════════

    private int hit_test (double wx, double wy) {
        if (!_has_crop) return DRAG_CREATE;

        double rx, ry;
        video_to_widget (_crop_x, _crop_y, out rx, out ry);
        double rw = video_w_to_widget (_crop_w);
        double rh = video_h_to_widget (_crop_h);

        double ez = EDGE_ZONE;

        // Check corners first (they overlap edges)
        if (near (wx, wy, rx, ry, ez))             return DRAG_TL;
        if (near (wx, wy, rx + rw, ry, ez))        return DRAG_TR;
        if (near (wx, wy, rx, ry + rh, ez))        return DRAG_BL;
        if (near (wx, wy, rx + rw, ry + rh, ez))   return DRAG_BR;

        // Check edge midpoints
        if (near (wx, wy, rx + rw/2, ry, ez))      return DRAG_T;
        if (near (wx, wy, rx + rw/2, ry + rh, ez)) return DRAG_B;
        if (near (wx, wy, rx, ry + rh/2, ez))      return DRAG_L;
        if (near (wx, wy, rx + rw, ry + rh/2, ez)) return DRAG_R;

        // Check edges (entire edge, not just midpoint)
        if (wy >= ry - ez && wy <= ry + ez && wx >= rx && wx <= rx + rw) return DRAG_T;
        if (wy >= ry + rh - ez && wy <= ry + rh + ez && wx >= rx && wx <= rx + rw) return DRAG_B;
        if (wx >= rx - ez && wx <= rx + ez && wy >= ry && wy <= ry + rh) return DRAG_L;
        if (wx >= rx + rw - ez && wx <= rx + rw + ez && wy >= ry && wy <= ry + rh) return DRAG_R;

        // Inside the rectangle → move
        if (wx >= rx && wx <= rx + rw && wy >= ry && wy <= ry + rh)
            return DRAG_MOVE;

        // Outside → create new
        return DRAG_CREATE;
    }

    private static bool near (double x1, double y1, double x2, double y2, double threshold) {
        double dx = x1 - x2;
        double dy = y1 - y2;
        if (dx < 0) dx = -dx;
        if (dy < 0) dy = -dy;
        return dx < threshold && dy < threshold;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  GESTURE HANDLERS
    // ═════════════════════════════════════════════════════════════════════════

    private void on_drag_begin (Gtk.GestureDrag gesture, double start_x, double start_y) {
        grab_focus ();

        drag_mode = hit_test (start_x, start_y);

        double vx, vy;
        widget_to_video (start_x, start_y, out vx, out vy);
        vx = vx.clamp (0, _video_width);
        vy = vy.clamp (0, _video_height);

        drag_start_vx = vx;
        drag_start_vy = vy;
        drag_orig_x = _crop_x;
        drag_orig_y = _crop_y;
        drag_orig_w = _crop_w;
        drag_orig_h = _crop_h;

        if (drag_mode == DRAG_CREATE) {
            _crop_x = vx;
            _crop_y = vy;
            _crop_w = 0;
            _crop_h = 0;
            _has_crop = true;
        }
    }

    private void on_drag_update (Gtk.GestureDrag gesture, double offset_x, double offset_y) {
        double start_wx, start_wy;
        gesture.get_start_point (out start_wx, out start_wy);

        double cur_wx = start_wx + offset_x;
        double cur_wy = start_wy + offset_y;

        double cur_vx, cur_vy;
        widget_to_video (cur_wx, cur_wy, out cur_vx, out cur_vy);
        cur_vx = cur_vx.clamp (0, _video_width);
        cur_vy = cur_vy.clamp (0, _video_height);

        double dvx = cur_vx - drag_start_vx;
        double dvy = cur_vy - drag_start_vy;

        switch (drag_mode) {
        case DRAG_CREATE:
            // Anchor is drag_start_v, current point defines opposite corner
            double x1 = double.min (drag_start_vx, cur_vx);
            double y1 = double.min (drag_start_vy, cur_vy);
            double x2 = double.max (drag_start_vx, cur_vx);
            double y2 = double.max (drag_start_vy, cur_vy);
            _crop_x = x1;
            _crop_y = y1;
            _crop_w = x2 - x1;
            _crop_h = y2 - y1;
            break;

        case DRAG_MOVE:
            _crop_x = (drag_orig_x + dvx).clamp (0, _video_width  - drag_orig_w);
            _crop_y = (drag_orig_y + dvy).clamp (0, _video_height - drag_orig_h);
            _crop_w = drag_orig_w;
            _crop_h = drag_orig_h;
            break;

        case DRAG_TL:
            apply_resize (dvx, dvy, true, true, false, false);
            break;
        case DRAG_TR:
            apply_resize (dvx, dvy, false, true, true, false);
            break;
        case DRAG_BL:
            apply_resize (dvx, dvy, true, false, false, true);
            break;
        case DRAG_BR:
            apply_resize (dvx, dvy, false, false, true, true);
            break;
        case DRAG_T:
            apply_resize (0, dvy, false, true, false, false);
            break;
        case DRAG_B:
            apply_resize (0, dvy, false, false, false, true);
            break;
        case DRAG_L:
            apply_resize (dvx, 0, true, false, false, false);
            break;
        case DRAG_R:
            apply_resize (dvx, 0, false, false, true, false);
            break;
        }

        queue_draw ();
        emit_crop ();
    }

    private void on_drag_end (Gtk.GestureDrag gesture, double offset_x, double offset_y) {
        // Snap final values to even and clamp
        if (_has_crop) {
            _crop_x = snap_even (((int) _crop_x).clamp (0, _video_width));
            _crop_y = snap_even (((int) _crop_y).clamp (0, _video_height));
            _crop_w = snap_even (((int) _crop_w).clamp (0, _video_width  - (int) _crop_x));
            _crop_h = snap_even (((int) _crop_h).clamp (0, _video_height - (int) _crop_y));

            // Discard tiny accidental clicks
            if (_crop_w < MIN_CROP_PX || _crop_h < MIN_CROP_PX) {
                clear_crop ();
            }
        }

        drag_mode = DRAG_NONE;
        queue_draw ();
        emit_crop ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  RESIZE HELPER
    // ═════════════════════════════════════════════════════════════════════════

    private void apply_resize (double dvx, double dvy,
                               bool move_left, bool move_top,
                               bool move_right, bool move_bottom) {
        double nx = drag_orig_x;
        double ny = drag_orig_y;
        double nw = drag_orig_w;
        double nh = drag_orig_h;

        if (move_left) {
            nx = drag_orig_x + dvx;
            nw = drag_orig_w - dvx;
        }
        if (move_top) {
            ny = drag_orig_y + dvy;
            nh = drag_orig_h - dvy;
        }
        if (move_right) {
            nw = drag_orig_w + dvx;
        }
        if (move_bottom) {
            nh = drag_orig_h + dvy;
        }

        // Prevent negative size (handle flip)
        if (nw < MIN_CROP_PX) { nw = MIN_CROP_PX; }
        if (nh < MIN_CROP_PX) { nh = MIN_CROP_PX; }

        // Clamp to video bounds
        if (nx < 0) { nw += nx; nx = 0; }
        if (ny < 0) { nh += ny; ny = 0; }
        if (nx + nw > _video_width)  nw = _video_width  - nx;
        if (ny + nh > _video_height) nh = _video_height - ny;

        _crop_x = nx;
        _crop_y = ny;
        _crop_w = nw;
        _crop_h = nh;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CURSOR — change based on hover position
    // ═════════════════════════════════════════════════════════════════════════

    private void on_motion (Gtk.EventControllerMotion ctrl, double x, double y) {
        if (drag_mode != DRAG_NONE) return;  // don't change cursor while dragging

        int hit = hit_test (x, y);
        switch (hit) {
        case DRAG_TL: case DRAG_BR:
            set_cursor_from_name ("nwse-resize");
            break;
        case DRAG_TR: case DRAG_BL:
            set_cursor_from_name ("nesw-resize");
            break;
        case DRAG_T: case DRAG_B:
            set_cursor_from_name ("ns-resize");
            break;
        case DRAG_L: case DRAG_R:
            set_cursor_from_name ("ew-resize");
            break;
        case DRAG_MOVE:
            set_cursor_from_name ("grab");
            break;
        default:
            set_cursor_from_name ("crosshair");
            break;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    private void emit_crop () {
        if (_has_crop) {
            crop_changed (
                snap_even ((int) _crop_w),
                snap_even ((int) _crop_h),
                snap_even ((int) _crop_x),
                snap_even ((int) _crop_y)
            );
        }
    }

    private static int snap_even (int val) {
        return (val / 2) * 2;
    }
}
