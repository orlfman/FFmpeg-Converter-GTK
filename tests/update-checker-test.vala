using GLib;

private void assert_version_order (
    string left,
    string right,
    int expected
) {
    int comparison;
    assert_true (UpdateChecker.compare_versions (
        left, right, out comparison));
    assert_true (comparison == expected);
}

private void test_version_comparison () {
    assert_version_order ("v1.5.8", "1.5.8", 0);
    assert_version_order ("1.5.8.0", "1.5.8", 0);
    assert_version_order ("1.6.0", "1.5.99", 1);
    assert_version_order ("1.5.7", "v1.5.8", -1);
    assert_version_order ("2.0.0-rc1", "2.0.0", 0);
    assert_version_order ("2.0.0+build.4", "2.0", 0);

    int comparison;
    assert_false (UpdateChecker.compare_versions (
        "release-1.5.8", "1.5.8", out comparison));
    assert_true (comparison == 0);
    assert_false (UpdateChecker.compare_versions (
        "1..8", "1.5.8", out comparison));
    assert_true (comparison == 0);
}

private void test_update_available_response () {
    try {
        var result = UpdateChecker.parse_release_json (
            "1.5.8",
            """{
                "tag_name": "v1.6.0",
                "html_url": "https://github.com/orlfman/FFmpeg-Converter-GTK/releases/tag/v1.6.0"
            }""");

        assert_true (
            result.availability == UpdateAvailability.UPDATE_AVAILABLE);
        assert_true (result.current_version == "1.5.8");
        assert_true (result.latest_version == "v1.6.0");
        assert_true (
            result.release_url ==
            "https://github.com/orlfman/FFmpeg-Converter-GTK/releases/tag/v1.6.0");
    } catch (Error e) {
        Test.fail_printf ("Unexpected parse failure: %s", e.message);
    }
}

private void test_current_and_newer_responses () {
    try {
        var current = UpdateChecker.parse_release_json (
            "1.5.8", """{"tag_name":"1.5.8"}""");
        assert_true (
            current.availability == UpdateAvailability.UP_TO_DATE);

        var newer = UpdateChecker.parse_release_json (
            "1.6.0", """{"tag_name":"1.5.8"}""");
        assert_true (
            newer.availability == UpdateAvailability.NEWER_THAN_LATEST);
    } catch (Error e) {
        Test.fail_printf ("Unexpected parse failure: %s", e.message);
    }
}

private void test_untrusted_release_url_falls_back () {
    try {
        var result = UpdateChecker.parse_release_json (
            "1.5.8",
            """{
                "tag_name": "1.6.0",
                "html_url": "https://example.com/not-the-project"
            }""");

        assert_true (
            result.release_url ==
            "https://github.com/orlfman/FFmpeg-Converter-GTK/releases");
    } catch (Error e) {
        Test.fail_printf ("Unexpected parse failure: %s", e.message);
    }
}

private void test_invalid_response () {
    bool failed = false;
    try {
        UpdateChecker.parse_release_json ("1.5.8", "{} ");
    } catch (UpdateCheckError.INVALID_RESPONSE e) {
        failed = true;
    } catch (Error e) {
        Test.fail_printf ("Unexpected error type: %s", e.message);
    }
    assert_true (failed);
}

void test_pacman_ownership_parsing () {
    const string PKG = "ffmpeg-converter-gtk";

    // The real shape of `pacman -Qo <path>` for an owned file.
    assert_true (InstallDetection.owned_by_package (
        "/usr/bin/ffmpeg-converter-gtk is owned by ffmpeg-converter-gtk 1.5.8-1\n",
        PKG));

    // Nothing to parse.
    assert_true (!InstallDetection.owned_by_package ("", PKG));
    assert_true (!InstallDetection.owned_by_package ("anything", ""));

    // pacman's "no owner" wording must not read as ownership.
    assert_true (!InstallDetection.owned_by_package (
        "error: No package owns /usr/local/bin/ffmpeg-converter-gtk", PKG));

    // A DIFFERENT package owning the binary is not our package. This is the
    // case that matters: a distro repo build, or a fork packaged under
    // another name, must still be sent to the GitHub release.
    assert_true (!InstallDetection.owned_by_package (
        "/usr/bin/ffmpeg-converter-gtk is owned by ffmpeg-converter-gtk-git 1.5.8.r2-1",
        PKG));

    // A path containing the package name must not pass on its own — only the
    // token after "is owned by" counts.
    assert_true (!InstallDetection.owned_by_package (
        "/home/u/ffmpeg-converter-gtk/build/ffmpeg-converter-gtk is owned by other-pkg 1.0",
        PKG));
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/update-checker/pacman-ownership-parsing",
                   test_pacman_ownership_parsing);
    Test.add_func ("/update-checker/version-comparison",
                   test_version_comparison);
    Test.add_func ("/update-checker/update-available-response",
                   test_update_available_response);
    Test.add_func ("/update-checker/current-and-newer-responses",
                   test_current_and_newer_responses);
    Test.add_func ("/update-checker/untrusted-url-fallback",
                   test_untrusted_release_url_falls_back);
    Test.add_func ("/update-checker/invalid-response",
                   test_invalid_response);
    return Test.run ();
}
