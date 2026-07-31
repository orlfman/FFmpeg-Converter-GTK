using Gtk;

// ═══════════════════════════════════════════════════════════════════════════════
//  PlayerStyles — Shared transport CSS for AudioPlayer and VideoPlayer
//
//  Single source of truth for .transport-bar and .transport-time styling.
//  Both players call ensure_loaded() in their constructors; the static
//  guard makes repeated calls a no-op.
// ═══════════════════════════════════════════════════════════════════════════════

namespace PlayerStyles {

    private static bool loaded = false;

    public static void ensure_loaded () {
        if (loaded) return;
        loaded = true;

        var display = Gdk.Display.get_default ();
        var icon_theme = Gtk.IconTheme.get_for_display (display);
        icon_theme.add_resource_path (
            "/com/github/pieman/FFmpegConverterGTK/icons"
        );

        var css = new CssProvider ();
        css.load_from_string (
            // Transport control bar
            ".transport-bar {\n" +
            "    background: alpha(@window_fg_color, 0.04);\n" +
            "    border-radius: 8px;\n" +
            "    padding: 4px 12px;\n" +
            "}\n" +
            // Time readout box
            ".transport-time {\n" +
            "    background: alpha(@window_fg_color, 0.06);\n" +
            "    border-radius: 6px;\n" +
            "    padding: 2px 8px;\n" +
            "}\n"
        );
        GtkCompat.add_provider_for_display (
            display,
            css,
            STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }
}
