// Counterpart to mediafile-probe.vala, for the libmpv backend.
//
// Samples RSS the same way and prints the same summary, so the two can be run
// against the same file and compared directly.  Where mediafile-probe exercises
// Gtk.MediaFile, this drives MpvBackend exactly as VideoPlayer and AudioPlayer
// do: open a path, wait for file_loaded, optionally play.
//
// Build:  meson compile -C builddir mpv-backend-probe
//
// Deliberately not a hand-written valac line. MpvBackend depends on AppSettings,
// which depends on SmartOptimizerLogic, which depends on the audio probe types,
// and so on; every such edge used to have to be chased by hand and the
// documented command silently rotted. The Meson target tracks the real source
// list instead. `meson compile -C builddir probes` builds this and the two C
// probes together.
//
// Run:  ./builddir/mpv-backend-probe <file> [video|audio|play|cycle] [seconds]
//
// Modes:
//   video   video preview attached to a Gtk.Picture (what VideoPlayer does)
//   audio   audio-only, no video decoding at all (what AudioPlayer does)
//   play    video + start playback
//   cycle   open/close once per second, to check teardown returns memory

using Gtk;

// AppSettings shares one clamp with the otherwise unrelated optimizer. Pulling
// in the real implementation drags most of the application behind it, so the
// probe supplies the same bounds itself — as tests/mpv-backend-state-test.vala
// does, for the same reason.
namespace SmartOptimizerLogic {
    public int clamp_target_mb (int value) {
        return value.clamp (1, 16384);
    }
}

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

private MpvBackend? backend = null;
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
        stderr.printf ("usage: %s <file> [video|audio|play] [seconds]\n", args[0]);
        return 2;
    }
    path = args[1];
    mode = (args.length > 2) ? args[2] : "video";
    if (args.length > 3) run_seconds = int.parse (args[3]);

    var app = new Gtk.Application ("dev.probe.MpvBackendProbe",
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
        picture.set_content_fit (ContentFit.CONTAIN);
        win.set_child (picture);
        win.present ();

        sample ("window-shown");

        // ── The only thing under test ────────────────────────────────────
        bool with_video = (mode != "audio");
        backend = new MpvBackend (with_video);
        if (with_video) {
            backend.attach_picture (picture);
        }

        backend.file_loaded.connect (() => {
            stdout.printf ("  loaded         %.3f s, %d x %d\n",
                           backend.duration, backend.video_width, backend.video_height);
            stdout.flush ();
            sample ("file-loaded");

            if (mode == "play") {
                backend.set_playing (true);
                sample ("playing");
            }
        });

        backend.load_failed.connect ((detail) => {
            stdout.printf ("  LOAD FAILED    %s\n", detail);
            stdout.flush ();
        });

        backend.open (path, mode == "audio" ? 0 : -1);
        sample ("opened");

        Timeout.add_seconds (1, () => {
            elapsed++;

            if (mode == "cycle") {
                // Tear the whole mpv core down and stand a new one up, the way
                // an input change does. RSS must not ratchet upwards.
                backend.close ();
                backend.open (path, -1);
            }

            sample ("t+%ds".printf (elapsed));
            if (elapsed >= run_seconds) {
                stdout.printf ("\nbaseline %.2f MiB   peak %.2f MiB   growth %.2f MiB\n",
                               baseline / 1024.0, peak / 1024.0,
                               (peak - baseline) / 1024.0);
                stdout.flush ();
                backend.close ();
                backend = null;
                app.quit ();
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });
    });

    return app.run (new string[] { args[0] });
}
