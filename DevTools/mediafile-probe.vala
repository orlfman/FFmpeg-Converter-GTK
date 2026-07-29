// Minimal reproduction for the input-load memory spike.
//
// Does nothing but what VideoPlayer/AudioPlayer do at their core:
// construct a Gtk.MediaFile for a path, optionally attach it to a Gtk.Picture,
// optionally poll is_prepared() the way the app does, and sample its own RSS.
//
// Build:  valac --pkg gtk4 DevTools/mediafile-probe.vala -o mediafile-probe
// Run:    ./mediafile-probe <file> <mode> [seconds]
//
// Modes:
//   bare     construct Gtk.MediaFile, never attach it to any widget
//            (this is what AudioPlayer does for stream 0)
//   picture  attach to a Gtk.Picture in a shown window
//            (this is what VideoPlayer does)
//   poll     picture + the app's 100 ms is_prepared() polling loop
//   play     picture + set_playing(true)

using Gtk;

private int64 rss_kb () {
    string contents;
    try {
        FileUtils.get_contents ("/proc/self/status", out contents);
    } catch (Error e) {
        return -1;
    }
    foreach (unowned string raw in contents.split ("\n")) {
        string line = raw.strip ();
        if (!line.has_prefix ("VmRSS:")) continue;
        string value = line.substring (6).strip ();
        if (value.has_suffix ("kB"))
            value = value.substring (0, value.length - 2).strip ();
        int64 parsed;
        if (int64.try_parse (value, out parsed, null, 10)) return parsed;
        return -1;
    }
    return -1;
}

private string path;
private string mode;
private int run_seconds = 20;

private Gtk.MediaFile? media = null;
private uint prepare_poll = 0;
private int64 baseline = 0;
private int64 peak = 0;
private int elapsed = 0;

private void sample (string tag) {
    int64 now = rss_kb ();
    if (now > peak) peak = now;
    stdout.printf ("  %-14s RSS %8.2f MiB   (+%.2f MiB)\n",
                   tag, now / 1024.0, (now - baseline) / 1024.0);
    stdout.flush ();
}

public static int main (string[] args) {
    if (args.length < 2) {
        stderr.printf ("usage: %s <file> [bare|picture|poll|play] [seconds]\n", args[0]);
        return 2;
    }
    path = args[1];
    mode = (args.length > 2) ? args[2] : "picture";
    if (args.length > 3) run_seconds = int.parse (args[3]);

    var app = new Gtk.Application ("dev.probe.MediaFileProbe",
                                   ApplicationFlags.NON_UNIQUE);

    app.activate.connect (() => {
        baseline = rss_kb ();
        peak = baseline;

        stdout.printf ("file : %s\n", path);
        stdout.printf ("mode : %s\n\n", mode);
        sample ("gtk-ready");

        var win = new Gtk.ApplicationWindow (app);
        win.set_default_size (640, 360);
        var picture = new Gtk.Picture ();
        win.set_child (picture);
        win.present ();

        sample ("window-shown");

        // ── The only thing under test ────────────────────────────────────
        var file = GLib.File.new_for_path (path);
        media = Gtk.MediaFile.for_file (file);

        sample ("mediafile-made");

        if (mode != "bare") {
            picture.set_paintable (media);
            sample ("attached");
        }

        if (mode == "play") {
            media.set_playing (true);
            sample ("playing");
        }

        if (mode == "poll") {
            // Mirrors VideoPlayer.load_file(): poll every 100 ms until prepared.
            prepare_poll = Timeout.add (100, () => {
                if (media != null && media.is_prepared ()) {
                    prepare_poll = 0;
                    return Source.REMOVE;
                }
                return Source.CONTINUE;
            });
        }

        Timeout.add_seconds (1, () => {
            elapsed++;
            sample ("t+%ds".printf (elapsed));
            if (elapsed >= run_seconds) {
                stdout.printf ("\nbaseline %.2f MiB   peak %.2f MiB   growth %.2f MiB\n",
                               baseline / 1024.0, peak / 1024.0,
                               (peak - baseline) / 1024.0);
                stdout.flush ();
                if (prepare_poll != 0) Source.remove (prepare_poll);
                media = null;
                app.quit ();
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });
    });

    return app.run (new string[] { args[0] });
}
