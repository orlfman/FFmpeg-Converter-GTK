using GLib;

/** Shared external-player launch; callers validate the selected media first. */
public class PlaybackLauncher : Object {
    public delegate void LaunchFunc (string path) throws Error;
#if BULK_PLAYBACK_TEST_BUILD
    internal static LaunchFunc? test_launch;
#endif
    public static void launch (string path) throws Error {
#if BULK_PLAYBACK_TEST_BUILD
        if (test_launch != null) { test_launch (path); return; }
#endif
        var settings = AppSettings.get_default ();
        string ffplay = settings.ffplay_path;
        string? resolved = ffplay.contains ("/") ? ffplay : Environment.find_program_in_path (ffplay);
        var route = PlaybackLauncherLogic.resolve_route (settings.play_with_ffplay, ffplay, resolved);
        if (settings.play_with_ffplay && route == PlaybackLauncherLogic.Route.DESKTOP_DEFAULT) {
            // ffplay is a separate package from ffmpeg on several distros.
            warning ("ffplay playback requested but '%s' is not on PATH — "
                + "falling back to the default player", ffplay);
        }
        if (route == PlaybackLauncherLogic.Route.FFPLAY) {
            try {
                Pid pid;
                Process.spawn_async (null, PlaybackLauncherLogic.build_ffplay_argv (ffplay, path),
                    null, SpawnFlags.SEARCH_PATH | SpawnFlags.STDOUT_TO_DEV_NULL
                    | SpawnFlags.STDERR_TO_DEV_NULL | SpawnFlags.DO_NOT_REAP_CHILD, null, out pid);
                // DO_NOT_REAP_CHILD without a watch would leave a zombie.
                ChildWatch.add (pid, (child, status) => { Process.close_pid (child); });
                return;
            } catch (SpawnError e) {
                // Preserve the existing desktop fallback when ffplay cannot start.
                warning ("Failed to launch ffplay (%s) — falling back to the "
                    + "default player", e.message);
            }
        }
        AppInfo.launch_default_for_uri (File.new_for_path (path).get_uri (), null);
    }
}
