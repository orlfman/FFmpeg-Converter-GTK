using GLib;
using Gtk;
using Adw;

private void assert_true (bool value, string context) {
    if (!value) {
        Test.fail_printf ("%s expected true", context);
    }
}

private void assert_false (bool value, string context) {
    if (value) {
        Test.fail_printf ("%s expected false", context);
    }
}

private void assert_uint64_equal (uint64 actual, uint64 expected, string context) {
    if (actual != expected) {
        Test.fail_printf ("%s expected %" + uint64.FORMAT + " but got %" + uint64.FORMAT,
            context, expected, actual);
    }
}

private void assert_string_equal (string actual, string expected, string context) {
    if (actual != expected) {
        Test.fail_printf ("%s expected '%s' but got '%s'", context, expected, actual);
    }
}

private void assert_contains (string actual, string expected_fragment, string context) {
    if (actual.index_of (expected_fragment) < 0) {
        Test.fail_printf ("%s expected '%s' to contain '%s'",
            context, actual, expected_fragment);
    }
}

private void assert_array_contains (string[] values, string expected, string context) {
    foreach (string value in values) {
        if (value == expected) {
            return;
        }
    }

    Test.fail_printf ("%s expected argument '%s'", context, expected);
}

private void assert_array_not_contains (string[] values, string unexpected, string context) {
    foreach (string value in values) {
        if (value == unexpected) {
            Test.fail_printf ("%s did not expect argument '%s'", context, unexpected);
            return;
        }
    }
}

private void assert_array_has_adjacent_pair (string[] values,
                                             string first,
                                             string second,
                                             string context) {
    for (int i = 0; i < values.length - 1; i++) {
        if (values[i] == first && values[i + 1] == second) {
            return;
        }
    }

    Test.fail_printf ("%s expected pair '%s' '%s'", context, first, second);
}

private CombineFile make_combine_file (string path,
                                       double duration,
                                       int width,
                                       int height,
                                       string frame_rate = "30/1",
                                       string pixel_format = "yuv420p",
                                       string sample_aspect_ratio = "1:1",
                                       bool has_audio = true,
                                       string audio_codec = "aac",
                                       int audio_sample_rate = 48000,
                                       string audio_layout = "stereo") {
    var file = new CombineFile ();
    file.path = path;
    file.filename = Path.get_basename (path);
    file.duration = duration;
    file.width = width;
    file.height = height;
    file.video_codec = "h264";
    file.video_profile = "High";
    file.pixel_format = pixel_format;
    file.frame_rate = frame_rate;
    file.sample_aspect_ratio = sample_aspect_ratio;
    file.has_audio = has_audio;
    file.audio_codec = has_audio ? audio_codec : "";
    file.audio_sample_rate = has_audio ? audio_sample_rate : 0;
    file.audio_channel_layout = has_audio ? audio_layout : "";
    file.audio_channels = has_audio ? 2 : 0;
    file.extension = ".mkv";
    return file;
}

private CombineRunner make_capture_runner (GenericArray<CombineFile> files,
                                           string output_path = "/tmp/out.mkv") {
    var runner = new CombineRunner ();
    runner.output_path = output_path;
    runner.set_files (files);
    runner.enable_ffmpeg_capture_for_widget_test ();
    return runner;
}

private bool gtk_widget_tests_ready = false;
private bool gtk_widget_tests_available = false;

private bool ensure_gtk_widget_tests_available () {
    if (!gtk_widget_tests_ready) {
        gtk_widget_tests_available = Gtk.init_check ();
        if (gtk_widget_tests_available) {
            Adw.init ();
        }
        gtk_widget_tests_ready = true;
    }

    if (!gtk_widget_tests_available) {
        Test.message ("Skipping widget test: GTK could not initialize");
        return false;
    }

    return true;
}

private class TestOperationStateSource : Object, IOperationStateSource {
    private bool idle = true;

    public bool is_operation_idle () {
        return idle;
    }
}

private class CombineWindowHarness : Object {
    public TestOperationStateSource op_state { get; private set; }
    public CombineWindow window { get; private set; }
    private uint64 next_operation_id = 1;

    public CombineWindowHarness () {
        op_state = new TestOperationStateSource ();
        window = new CombineWindow (
            new SvtAv1Tab (),
            new X265Tab (),
            new X264Tab (),
            new Vp9Tab (),
            new GeneralTab (),
            "/tmp",
            new StatusArea (),
            new ConsoleTab (),
            (out operation_id) => {
                operation_id = next_operation_id++;
                return true;
            },
            op_state
        );
    }
}

private void test_move_up_button_reorders_files () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var harness = new CombineWindowHarness ();
    harness.window.load_files_for_widget_test ({
        "/tmp/first.mkv",
        "/tmp/second.mkv"
    });

    assert_string_equal (
        harness.window.get_file_name_for_widget_test (0),
        "first.mkv",
        "combine widget initial first file");
    assert_string_equal (
        harness.window.get_file_name_for_widget_test (1),
        "second.mkv",
        "combine widget initial second file");

    harness.window.click_file_move_up_for_widget_test (1);

    assert_string_equal (
        harness.window.get_file_name_for_widget_test (0),
        "second.mkv",
        "combine widget move-up reorders first slot");
    assert_string_equal (
        harness.window.get_file_name_for_widget_test (1),
        "first.mkv",
        "combine widget move-up reorders second slot");

    harness.window.close ();
}

private void test_runner_binding_relays_cancelled_signal () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var harness = new CombineWindowHarness ();
    bool fired = false;
    uint64 seen_operation_id = 0;

    harness.window.combine_cancelled.connect ((operation_id) => {
        fired = true;
        seen_operation_id = operation_id;
    });

    harness.window.simulate_runner_cancelled_for_widget_test (42, "Cancelled for test");

    assert_true (fired, "combine runner binding relays cancelled signal");
    assert_uint64_equal (
        seen_operation_id,
        42,
        "combine runner binding preserves operation id");
    assert_false (
        harness.window.has_active_runner_binding_for_widget_test (),
        "combine runner binding clears stored binding after completion");

    harness.window.close ();
}

private void test_pending_overwrite_cancelled_by_main_window_is_ignored () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var harness = new CombineWindowHarness ();
    bool fired = false;

    harness.window.combine_cancelled.connect ((operation_id) => {
        fired = true;
    });

    harness.window.arm_pending_overwrite_for_widget_test (42);

    assert_true (
        harness.window.has_pending_overwrite_dialog_for_widget_test (),
        "pending overwrite dialog is armed for widget test");
    assert_true (
        harness.window.has_pending_overwrite_cancellable_for_widget_test (),
        "pending overwrite cancellable is armed for widget test");
    assert_true (
        harness.window.is_operation_reserved_for_widget_test (),
        "pending overwrite reserves the operation");
    assert_uint64_equal (
        harness.window.get_active_operation_id_for_widget_test (),
        42,
        "pending overwrite preserves operation id");

    harness.window.cancel_pending_combine ();

    assert_false (
        harness.window.has_pending_overwrite_dialog_for_widget_test (),
        "main-window cancel clears pending overwrite dialog");
    assert_false (
        harness.window.has_pending_overwrite_cancellable_for_widget_test (),
        "main-window cancel clears pending overwrite cancellable");
    assert_false (
        harness.window.is_operation_reserved_for_widget_test (),
        "main-window cancel clears reserved operation");
    assert_uint64_equal (
        harness.window.get_active_operation_id_for_widget_test (),
        0,
        "main-window cancel clears active operation id");

    harness.window.replay_pending_overwrite_cancel_for_widget_test (42);

    assert_false (
        fired,
        "stale overwrite cancel callback is ignored after main-window cancel");

    harness.window.close ();
}

private void test_probe_completion_updates_reordered_file_row () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var harness = new CombineWindowHarness ();
    harness.window.load_files_for_widget_test ({
        "/tmp/first.mkv",
        "/tmp/second.mkv"
    });

    CombineFile first = harness.window.get_file_for_widget_test (0);

    harness.window.click_file_move_up_for_widget_test (1);

    first.duration = 61.0;
    first.width = 1920;
    first.height = 1080;
    first.video_codec = "h264";
    first.has_audio = true;
    first.audio_codec = "aac";

    harness.window.replay_probe_completion_for_widget_test (first);

    assert_string_equal (
        harness.window.get_file_name_for_widget_test (0),
        "second.mkv",
        "reordered first slot still points at second file");
    assert_string_equal (
        harness.window.get_row_subtitle_for_widget_test (0),
        "Probing...",
        "stale probe callback does not overwrite the wrong row");
    assert_string_equal (
        harness.window.get_file_name_for_widget_test (1),
        "first.mkv",
        "reordered second slot still points at first file");
    assert_contains (
        harness.window.get_row_subtitle_for_widget_test (1),
        "h264 / aac",
        "probe callback updates the moved file row");

    harness.window.close ();
}

private void test_copy_command_maps_primary_video_and_audio () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    var runner = make_capture_runner (files);
    int exit_code = runner.run_copy_mode_for_widget_test ();
    assert_true (exit_code == 0, "copy command test exit code");

    string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();
    assert_array_has_adjacent_pair (argv, "-map", "0:v:0",
        "copy mode maps primary video");
    assert_array_has_adjacent_pair (argv, "-map", "0:a:0",
        "copy mode maps first audio stream");
    assert_array_has_adjacent_pair (argv, "-c", "copy",
        "copy mode uses stream copy");
    assert_array_has_adjacent_pair (argv, "-map_metadata", "0",
        "copy mode preserves metadata from first input");
    assert_array_not_contains (argv, "-an",
        "copy mode keeps audio enabled when any input has audio");
    assert_string_equal (argv[argv.length - 1], "/tmp/out.mkv",
        "copy mode appends output path last");
}

private void test_copy_command_disables_audio_when_inputs_have_no_audio () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080,
        "30/1", "yuv420p", "1:1", false));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080,
        "30/1", "yuv420p", "1:1", false));

    var runner = make_capture_runner (files);
    int exit_code = runner.run_copy_mode_for_widget_test ();
    assert_true (exit_code == 0, "copy no-audio command test exit code");

    string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();
    assert_array_contains (argv, "-an",
        "copy mode disables audio when no input has audio");
    assert_array_not_contains (argv, "0:a:0",
        "copy mode does not map audio when no input has audio");
    assert_string_equal (argv[argv.length - 1], "/tmp/out.mkv",
        "copy no-audio mode appends output path last");
}

private void test_reencode_command_normalizes_sample_aspect_ratio () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 720, 576,
        "25/1", "yuv420p", "16:15"));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 768, 576,
        "25/1", "yuv420p", "1:1"));

    var runner = make_capture_runner (files);
    var profile = new CombineEncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "sar normalization command test exit code");

    string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();
    string filter_complex = "";
    for (int i = 0; i < argv.length - 1; i++) {
        if (argv[i] == "-filter_complex") {
            filter_complex = argv[i + 1];
            break;
        }
    }

    assert_contains (filter_complex,
        "[0:v:0]scale=768:576:force_original_aspect_ratio=decrease,pad=768:576:-1:-1:color=black,setsar=1,setpts=PTS-STARTPTS[v0]",
        "reencode mode rescales anamorphic first input to square pixels");
    assert_contains (filter_complex,
        "[1:v:0]setsar=1,setpts=PTS-STARTPTS[v1]",
        "reencode mode normalizes sar even when resolution already matches");
}

private void test_reencode_command_generates_expected_filter_and_flags () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 3.25, 1280, 720,
        "30/1", "yuv420p", "1:1", false));

    var runner = make_capture_runner (files);
    var profile = new CombineEncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    profile.preserve_metadata = true;
    profile.remove_chapters = true;
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "reencode command test exit code");

    string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();
    string filter_complex = "";
    for (int i = 0; i < argv.length - 1; i++) {
        if (argv[i] == "-filter_complex") {
            filter_complex = argv[i + 1];
            break;
        }
    }

    assert_array_has_adjacent_pair (argv, "-map", "[outv]",
        "reencode mode maps video output");
    assert_array_has_adjacent_pair (argv, "-map", "[outa]",
        "reencode mode maps audio output");
    assert_array_has_adjacent_pair (argv, "-c:v", "libx264",
        "reencode mode includes codec args");
    assert_array_has_adjacent_pair (argv, "-c:a", "aac",
        "reencode mode includes audio args");
    assert_array_has_adjacent_pair (argv, "-map_metadata", "0",
        "reencode mode preserves metadata when requested");
    assert_array_has_adjacent_pair (argv, "-map_chapters", "-1",
        "reencode mode removes chapters when requested");
    assert_contains (filter_complex,
        "anullsrc=channel_layout=stereo:sample_rate=48000",
        "reencode mode synthesizes silence for files without audio");
    assert_contains (filter_complex,
        "[silence1]atrim=duration=3.250000,asetpts=PTS-STARTPTS[a1]",
        "reencode mode trims synthesized silence to input duration");
    assert_contains (filter_complex,
        "concat=n=2:v=1:a=1[outv][outa]",
        "reencode mode concatenates audio and video outputs");
    assert_string_equal (argv[argv.length - 1], "/tmp/out.mkv",
        "reencode mode appends output path last");
}

private void test_remove_file_cancels_inflight_probe_and_unblocks_combine () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var harness = new CombineWindowHarness ();
    harness.window.load_files_for_widget_test ({
        "/tmp/first.mkv",
        "/tmp/second.mkv",
        "/tmp/third.mkv"
    });

    for (int i = 0; i < 2; i++) {
        CombineFile file = harness.window.get_file_for_widget_test (i);
        file.duration = 60.0 + i;
        file.width = 1920;
        file.height = 1080;
        file.video_codec = "h264";
        file.video_profile = "High";
        file.pixel_format = "yuv420p";
        file.frame_rate = "30/1";
        file.sample_aspect_ratio = "1:1";
        file.has_audio = true;
        file.audio_codec = "aac";
        file.audio_sample_rate = 48000;
        file.audio_channel_layout = "stereo";
        file.audio_channels = 2;
    }

    harness.window.refresh_combine_state_for_widget_test ();

    Cancellable probe_cancellable = harness.window.arm_pending_probe_for_file_for_widget_test (2);
    harness.window.refresh_combine_state_for_widget_test ();

    assert_false (
        harness.window.is_combine_sensitive_for_widget_test (),
        "combine stays blocked while removed file probe is still pending");

    harness.window.remove_file_for_widget_test (2);

    assert_true (
        probe_cancellable.is_cancelled (),
        "removing a file cancels its in-flight probe");
    assert_uint64_equal (
        (uint64) harness.window.get_pending_probe_count_for_widget_test (),
        0,
        "removing a probing file clears pending probe count");
    assert_true (
        harness.window.is_combine_sensitive_for_widget_test (),
        "removing the probing file unblocks combine when remaining files are ready");

    harness.window.close ();
}

private void test_copy_mode_disables_on_sample_aspect_ratio_mismatch () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var harness = new CombineWindowHarness ();
    harness.window.load_files_for_widget_test ({
        "/tmp/first.mkv",
        "/tmp/second.mkv"
    });

    CombineFile first = harness.window.get_file_for_widget_test (0);
    first.duration = 60.0;
    first.width = 720;
    first.height = 576;
    first.video_codec = "h264";
    first.video_profile = "High";
    first.pixel_format = "yuv420p";
    first.frame_rate = "25/1";
    first.sample_aspect_ratio = "16:15";
    first.has_audio = true;
    first.audio_codec = "aac";
    first.audio_sample_rate = 48000;
    first.audio_channel_layout = "stereo";
    first.audio_channels = 2;

    CombineFile second = harness.window.get_file_for_widget_test (1);
    second.duration = 61.0;
    second.width = 720;
    second.height = 576;
    second.video_codec = "h264";
    second.video_profile = "High";
    second.pixel_format = "yuv420p";
    second.frame_rate = "25/1";
    second.sample_aspect_ratio = "1:1";
    second.has_audio = true;
    second.audio_codec = "aac";
    second.audio_sample_rate = 48000;
    second.audio_channel_layout = "stereo";
    second.audio_channels = 2;

    harness.window.refresh_combine_state_for_widget_test ();

    assert_false (
        harness.window.is_copy_mode_sensitive_for_widget_test (),
        "copy mode disables on pixel aspect ratio mismatch");
    assert_contains (
        harness.window.get_copy_mode_subtitle_for_widget_test (),
        "pixel aspect ratios",
        "copy mode explains sar mismatch in subtitle");

    harness.window.close ();
}

private void test_pending_overwrite_freezes_launch_file_list () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var harness = new CombineWindowHarness ();
    harness.window.load_files_for_widget_test ({
        "/tmp/first.mkv",
        "/tmp/second.mkv"
    });

    harness.window.enable_launch_capture_for_widget_test ();
    harness.window.arm_pending_overwrite_snapshot_for_widget_test (
        42, true, "/tmp/frozen-output.mkv");

    harness.window.click_file_move_up_for_widget_test (1);
    harness.window.replay_pending_overwrite_launch_for_widget_test (42, "overwrite");

    string[] launched_paths = harness.window.get_last_launched_paths_for_widget_test ();
    assert_true (
        launched_paths.length == 2,
        "overwrite launch captures the frozen file list");
    assert_string_equal (
        launched_paths[0],
        "/tmp/first.mkv",
        "overwrite launch preserves original first file");
    assert_string_equal (
        launched_paths[1],
        "/tmp/second.mkv",
        "overwrite launch preserves original second file");
    assert_string_equal (
        harness.window.get_last_launched_output_for_widget_test (),
        "/tmp/frozen-output.mkv",
        "overwrite launch preserves frozen output path");
    assert_true (
        harness.window.get_last_launched_copy_mode_for_widget_test (),
        "overwrite launch preserves frozen copy mode");

    harness.window.close ();
}

private void test_idle_close_request_cancels_pending_probes () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var harness = new CombineWindowHarness ();
    Cancellable probe_cancellable = harness.window.arm_pending_probe_for_widget_test ();

    bool blocked = harness.window.invoke_close_request_for_widget_test ();

    assert_false (blocked, "idle close request allows the window to close");
    assert_true (probe_cancellable.is_cancelled (),
        "idle close request cancels pending probes");
    assert_uint64_equal (
        (uint64) harness.window.get_pending_probe_count_for_widget_test (),
        0,
        "idle close request clears pending probe count");
}

void main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/combine/widgets/move-up-button",
        test_move_up_button_reorders_files);
    Test.add_func ("/combine/runner/cancelled-relay",
        test_runner_binding_relays_cancelled_signal);
    Test.add_func ("/combine/overwrite/main-window-cancel-ignores-stale-callback",
        test_pending_overwrite_cancelled_by_main_window_is_ignored);
    Test.add_func ("/combine/probe/reordered-row-identity",
        test_probe_completion_updates_reordered_file_row);
    Test.add_func ("/combine/runner/copy-command-maps-primary-streams",
        test_copy_command_maps_primary_video_and_audio);
    Test.add_func ("/combine/runner/copy-command-no-audio",
        test_copy_command_disables_audio_when_inputs_have_no_audio);
    Test.add_func ("/combine/runner/reencode-command-sar-normalization",
        test_reencode_command_normalizes_sample_aspect_ratio);
    Test.add_func ("/combine/runner/reencode-command-filter-and-flags",
        test_reencode_command_generates_expected_filter_and_flags);
    Test.add_func ("/combine/window/remove-file-cancels-pending-probe",
        test_remove_file_cancels_inflight_probe_and_unblocks_combine);
    Test.add_func ("/combine/window/copy-mode-sar-mismatch",
        test_copy_mode_disables_on_sample_aspect_ratio_mismatch);
    Test.add_func ("/combine/overwrite/freezes-launch-file-list",
        test_pending_overwrite_freezes_launch_file_list);
    Test.add_func ("/combine/window/idle-close-cancels-pending-probes",
        test_idle_close_request_cancels_pending_probes);

    Test.run ();
}
