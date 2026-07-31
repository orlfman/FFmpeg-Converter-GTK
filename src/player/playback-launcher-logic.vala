using GLib;

/** Pure playback decisions kept separate from GTK and process spawning. */
namespace PlaybackLauncherLogic {

    public enum Route {
        DESKTOP_DEFAULT,
        FFPLAY
    }

    /**
     * Resolve the preference to a usable route. Bare executable names require
     * a PATH lookup; explicit paths are handed to spawn, which reports a clean
     * failure and lets the caller fall back if they are invalid.
     */
    public Route resolve_route (
        bool    prefer_ffplay,
        string  configured_ffplay,
        string? resolved_bare_executable
    ) {
        if (!prefer_ffplay || configured_ffplay.length == 0)
            return Route.DESKTOP_DEFAULT;
        if (!configured_ffplay.contains ("/")
                && resolved_bare_executable == null) {
            return Route.DESKTOP_DEFAULT;
        }
        return Route.FFPLAY;
    }

    /** Exact argv used for playback; paths remain one argument even with spaces. */
    public string[] build_ffplay_argv (string ffplay, string video_path) {
        return { ffplay, "-autoexit", video_path };
    }
}
