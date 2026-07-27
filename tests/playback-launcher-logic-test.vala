using GLib;

private void test_preference_off_uses_desktop_player () {
    assert (PlaybackLauncherLogic.resolve_route (
        false, "ffplay", "/usr/bin/ffplay")
        == PlaybackLauncherLogic.Route.DESKTOP_DEFAULT);
}

private void test_preference_on_uses_available_ffplay () {
    assert (PlaybackLauncherLogic.resolve_route (
        true, "ffplay", "/usr/bin/ffplay")
        == PlaybackLauncherLogic.Route.FFPLAY);
    assert (PlaybackLauncherLogic.resolve_route (
        true, "/opt/ffmpeg/bin/ffplay", null)
        == PlaybackLauncherLogic.Route.FFPLAY);
}

private void test_missing_bare_ffplay_falls_back_to_desktop () {
    assert (PlaybackLauncherLogic.resolve_route (true, "ffplay", null)
        == PlaybackLauncherLogic.Route.DESKTOP_DEFAULT);
    assert (PlaybackLauncherLogic.resolve_route (true, "", null)
        == PlaybackLauncherLogic.Route.DESKTOP_DEFAULT);
}

private void test_ffplay_command_preserves_video_path_as_one_argument () {
    string[] argv = PlaybackLauncherLogic.build_ffplay_argv (
        "/opt/custom ffmpeg/ffplay", "/videos/a file [final].mkv");
    assert (argv.length == 3);
    assert (argv[0] == "/opt/custom ffmpeg/ffplay");
    assert (argv[1] == "-autoexit");
    assert (argv[2] == "/videos/a file [final].mkv");
}

void main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/playback/preference/off-uses-desktop",
        test_preference_off_uses_desktop_player);
    Test.add_func ("/playback/preference/on-uses-ffplay",
        test_preference_on_uses_available_ffplay);
    Test.add_func ("/playback/preference/missing-falls-back",
        test_missing_bare_ffplay_falls_back_to_desktop);
    Test.add_func ("/playback/command/path-is-one-argument",
        test_ffplay_command_preserves_video_path_as_one_argument);
    Test.run ();
}
