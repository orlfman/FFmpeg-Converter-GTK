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

private bool spin_main_context_until (owned SourceFunc done, int max_spins = 50) {
    MainContext context = MainContext.default ();

    for (int i = 0; i < max_spins; i++) {
        while (context.pending ()) {
            context.iteration (false);
        }
        if (done ()) {
            return true;
        }

        Timeout.add (1, () => {
            return Source.REMOVE;
        });
        context.iteration (true);

        if (done ()) {
            return true;
        }
    }

    while (context.pending ()) {
        context.iteration (false);
    }

    return done ();
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

private int count_directories_in_path (string path) {
    if (!FileUtils.test (path, FileTest.IS_DIR)) {
        return 0;
    }

    int count = 0;
    try {
        var dir = Dir.open (path);
        string? name;
        while ((name = dir.read_name ()) != null) {
            string child = Path.build_filename (path, name);
            if (FileUtils.test (child, FileTest.IS_DIR)) {
                count++;
            }
        }
    } catch (FileError e) {
        Test.fail_printf ("failed to inspect directory '%s': %s", path, e.message);
    }

    return count;
}

private int run_command_for_test (string[] cmd,
                                  out string stdout_buf,
                                  out string stderr_buf,
                                  string context) {
    stdout_buf = "";
    stderr_buf = "";
    int status = -1;

    try {
        Process.spawn_sync (null, cmd, null, SpawnFlags.SEARCH_PATH,
            null, out stdout_buf, out stderr_buf, out status);
    } catch (Error e) {
        Test.fail_printf ("%s failed to launch command: %s", context, e.message);
    }

    return status;
}

private string make_exec_test_media_file (string dir, string filename) {
    string path = Path.build_filename (dir, filename);
    string[] cmd = {
        AppSettings.get_default ().ffmpeg_path,
        "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "testsrc2=size=16x16:rate=1:d=1.0",
        "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo:d=1.0",
        "-shortest",
        "-c:v", "ffv1",
        "-c:a", "pcm_s16le",
        path
    };

    string stdout_buf, stderr_buf;
    int status = run_command_for_test (cmd, out stdout_buf, out stderr_buf,
        "make exec test media file");
    if (status != 0) {
        Test.fail_printf ("failed to create exec test media file '%s': %s",
            path, stderr_buf.strip ());
    }

    return path;
}

private void cleanup_exec_test_dir (string dir) {
    try {
        var d = Dir.open (dir);
        string? name;
        while ((name = d.read_name ()) != null) {
            FileUtils.unlink (Path.build_filename (dir, name));
        }
    } catch (FileError e) {
        // Best-effort cleanup for test temp files.
    }
    DirUtils.remove (dir);
}

private void assert_filter_complex_executes_with_media_inputs (string[] input_paths,
                                                               string filter_complex,
                                                               bool map_video,
                                                               bool map_audio,
                                                               string context) {
    string[] cmd = {
        AppSettings.get_default ().ffmpeg_path,
        "-hide_banner", "-loglevel", "error", "-y"
    };

    foreach (string input_path in input_paths) {
        cmd += "-i";
        cmd += input_path;
    }

    cmd += "-filter_complex";
    cmd += filter_complex;

    if (map_video) {
        cmd += "-map";
        cmd += "[outv]";
    }
    if (map_audio) {
        cmd += "-map";
        cmd += "[outa]";
    }

    cmd += "-t";
    cmd += "0.5";

    cmd += "-f";
    cmd += "null";
    cmd += "-";

    string stdout_buf, stderr_buf;
    int status = run_command_for_test (cmd, out stdout_buf, out stderr_buf, context);
    if (status != 0) {
        Test.fail_printf ("%s expected ffmpeg to accept filter_complex, stderr: %s",
            context, stderr_buf.strip ());
    }
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
    public string output_folder { get; set; default = "/tmp"; }
    private uint64 next_operation_id = 1;

    public CombineWindowHarness () {
        op_state = new TestOperationStateSource ();
        window = new CombineWindow (
            new SvtAv1Tab (),
            new X265Tab (),
            new X264Tab (),
            new Vp9Tab (),
            new GeneralTab (),
            () => {
                return output_folder;
            },
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

private void test_file_pickers_combine_lock_clears_and_disables_input () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var file_pickers = new FilePickers ();
    file_pickers.input_entry.set_text ("/tmp/source.mkv");

    file_pickers.set_input_locked_for_combine (true);

    assert_true (file_pickers.is_input_locked_for_combine_for_widget_test (),
        "combine lock flag enabled on file pickers");
    assert_string_equal (file_pickers.input_entry.get_text (), "",
        "combine lock clears the main input path");
    assert_false (file_pickers.is_input_row_sensitive_for_widget_test (),
        "combine lock disables the input row");
    assert_false (file_pickers.input_entry.get_sensitive (),
        "combine lock disables the input path widget");
    assert_false (file_pickers.is_input_browse_sensitive_for_widget_test (),
        "combine lock disables the input browse button");

    file_pickers.set_input_locked_for_combine (false);

    assert_false (file_pickers.is_input_locked_for_combine_for_widget_test (),
        "combine lock flag disabled on file pickers");
    assert_true (file_pickers.is_input_row_sensitive_for_widget_test (),
        "unlock restores input row sensitivity");
    assert_true (file_pickers.input_entry.get_sensitive (),
        "unlock restores input path widget sensitivity");
    assert_true (file_pickers.is_input_browse_sensitive_for_widget_test (),
        "unlock restores input browse button sensitivity");
}

private void test_information_tab_clears_stale_input_when_input_removed () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var info_tab = new InformationTab ();
    info_tab.seed_input_values_for_widget_test ("stale-source.mkv");

    info_tab.load_input_info ("");

    assert_string_equal (
        info_tab.get_input_filename_for_widget_test (),
        "—",
        "clearing input resets cached input filename"
    );
    assert_true (
        info_tab.is_input_sections_visible_for_widget_test (),
        "empty input restores the standard input layout"
    );
    assert_false (
        info_tab.is_source_summary_visible_for_widget_test (),
        "empty input does not show combine summary"
    );
}

private void test_information_tab_combine_output_hides_input_and_shows_summary () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var info_tab = new InformationTab ();

    info_tab.apply_output_source_context_for_widget_test (
        OperationOutputSource.COMBINE,
        "Combined 3 files"
    );

    assert_false (
        info_tab.is_input_sections_visible_for_widget_test (),
        "combine output hides single-file input sections"
    );
    assert_true (
        info_tab.is_source_summary_visible_for_widget_test (),
        "combine output shows a source summary"
    );
    assert_string_equal (
        info_tab.get_source_summary_for_widget_test (),
        "Combined 3 files",
        "combine output summary text"
    );

    info_tab.apply_output_source_context_for_widget_test (
        OperationOutputSource.GENERIC,
        ""
    );

    assert_true (
        info_tab.is_input_sections_visible_for_widget_test (),
        "generic output restores input sections"
    );
    assert_false (
        info_tab.is_source_summary_visible_for_widget_test (),
        "generic output hides combine summary"
    );
}

private void test_combine_done_result_marks_source_and_summary () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    var runner = make_capture_runner (files, "/tmp/combined.mkv");
    OperationOutputResult result = runner.build_done_result_for_widget_test ();

    assert_true (
        result.source == OperationOutputSource.COMBINE,
        "combine result marks its output source"
    );
    assert_string_equal (
        result.source_summary,
        "Combined 2 files",
        "combine result summary records input count"
    );
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

private void test_combine_preview_hides_popout_button () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var harness = new CombineWindowHarness ();
    harness.window.create_preview_player_for_widget_test ();

    assert_false (
        harness.window.is_preview_popout_visible_for_widget_test (),
        "combine preview hides the popout button");

    harness.window.close ();
}

private void test_runner_binding_relays_cancelled_signal () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var harness = new CombineWindowHarness ();
    bool fired = false;
    uint64 seen_operation_id = 0;
    string seen_cancel_message = "";

    harness.window.combine_cancelled.connect ((operation_id, cancel_message) => {
        fired = true;
        seen_operation_id = operation_id;
        seen_cancel_message = cancel_message;
    });

    harness.window.simulate_runner_cancelled_for_widget_test (42, "Cancelled for test");

    assert_true (fired, "combine runner binding relays cancelled signal");
    assert_uint64_equal (
        seen_operation_id,
        42,
        "combine runner binding preserves operation id");
    assert_string_equal (
        seen_cancel_message,
        "Cancelled for test",
        "combine runner binding preserves cancel message");
    assert_false (
        harness.window.is_status_label_visible_for_widget_test (),
        "combine cancel keeps dialog-local status hidden");
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

    harness.window.combine_cancelled.connect ((operation_id, cancel_message) => {
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

private void test_pending_overwrite_real_dialog_dismiss_returns_cancel_response () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var settings = AppSettings.get_default ();
    bool previous_overwrite_enabled = settings.overwrite_enabled;
    OutputNameMode previous_output_name_mode = settings.output_name_mode;
    string temp_dir = "";
    var harness = new CombineWindowHarness ();

    try {
        settings.overwrite_enabled = false;
        settings.output_name_mode = OutputNameMode.DEFAULT;

        temp_dir = DirUtils.make_tmp ("combine-overwrite-dialog-XXXXXX");
        harness.output_folder = temp_dir;
        harness.window.present ();

        harness.window.load_files_for_widget_test ({
            "/tmp/first.mkv",
            "/tmp/second.mkv"
        });
        harness.window.reset_pending_overwrite_response_capture_for_widget_test ();

        string existing_output = Path.build_filename (temp_dir, "first-combined.mkv");
        FileUtils.set_contents (existing_output, "existing output");

        harness.window.click_combine_for_widget_test ();

        assert_true (
            harness.window.has_pending_overwrite_dialog_for_widget_test (),
            "real combine launch opens an overwrite dialog when output exists");
        assert_true (
            harness.window.has_pending_overwrite_cancellable_for_widget_test (),
            "real combine launch tracks the overwrite cancellable");

        harness.window.cancel_pending_combine ();

        assert_true (
            spin_main_context_until (() => {
                return harness.window.get_pending_overwrite_response_count_for_widget_test () > 0;
            }),
            "real overwrite dialog callback completes after external dismiss");
        assert_string_equal (
            harness.window.get_last_pending_overwrite_response_for_widget_test (),
            "cancel",
            "external dialog dismiss resolves choose() with the close response");
        assert_false (
            harness.window.has_pending_overwrite_dialog_for_widget_test (),
            "external dismiss clears the live overwrite dialog reference");
        assert_false (
            harness.window.has_pending_overwrite_cancellable_for_widget_test (),
            "external dismiss clears the live overwrite cancellable reference");
        assert_false (
            harness.window.is_operation_reserved_for_widget_test (),
            "external dismiss keeps the combine reservation cleared");
        assert_uint64_equal (
            harness.window.get_active_operation_id_for_widget_test (),
            0,
            "external dismiss keeps the active combine operation cleared");
    } catch (Error e) {
        Test.fail_printf ("real overwrite dialog widget test setup failed: %s", e.message);
    } finally {
        harness.window.close ();
        settings.overwrite_enabled = previous_overwrite_enabled;
        settings.output_name_mode = previous_output_name_mode;
        if (temp_dir != "") {
            cleanup_exec_test_dir (temp_dir);
        }
    }
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
    runner.preserve_metadata = true;
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

private void test_copy_command_omits_metadata_when_preserve_metadata_disabled () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    var runner = make_capture_runner (files);
    runner.preserve_metadata = false;

    int exit_code = runner.run_copy_mode_for_widget_test ();
    assert_true (exit_code == 0, "copy command metadata disabled exit code");

    string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();
    assert_array_not_contains (argv, "-map_metadata",
        "copy mode omits metadata mapping when preserve metadata is disabled");
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
    var profile = new EncodeProfileSnapshot ();
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
        "[0:v:0]scale=768:576:force_original_aspect_ratio=decrease,pad=768:576:-1:-1:color=black,setsar=1,settb=AVTB,setpts=PTS-STARTPTS[v0]",
        "reencode mode rescales anamorphic first input to square pixels");
    assert_contains (filter_complex,
        "[1:v:0]setsar=1,settb=AVTB,setpts=PTS-STARTPTS[v1]",
        "reencode mode normalizes sar even when resolution already matches");
}

private void test_reencode_command_generates_expected_filter_and_flags () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 3.25, 1280, 720,
        "30/1", "yuv420p", "1:1", false));

    var runner = make_capture_runner (files);
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    profile.preserve_metadata = true;
    runner.reencode_profile = profile;
    runner.remove_source_chapters = true;

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

private void test_reencode_codec_subtitle_describes_supported_general_settings () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var harness = new CombineWindowHarness ();
    harness.window.set_copy_mode_switch_active_for_widget_test (false);

    assert_string_equal (
        harness.window.get_reencode_codec_subtitle_for_widget_test (),
        "Uses the selected codec tab and compatible shared General settings",
        "re-encode subtitle describes the supported General settings scope");

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

private void test_combine_uses_live_main_output_folder () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var harness = new CombineWindowHarness ();
    harness.window.load_files_for_widget_test ({
        "/tmp/first.mkv",
        "/tmp/second.mkv"
    });

    harness.output_folder = "/tmp/initial-output";
    harness.output_folder = "/tmp/updated-output";

    harness.window.enable_launch_capture_for_widget_test ();
    harness.window.click_combine_for_widget_test ();

    string launched_output = harness.window.get_last_launched_output_for_widget_test ();
    assert_contains (
        launched_output,
        "/tmp/updated-output/",
        "combine launch uses the current main output folder");
    string basename = Path.get_basename (launched_output);
    assert_true (
        basename.length > ".mkv".length,
        "combine launch generates a non-empty filename");
    assert_true (
        basename.has_suffix ("-combined.mkv"),
        "combine launch keeps the expected combined suffix and container extension");

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

// ═════════════════════════════════════════════════════════════════════════════
//  CHAPTER METADATA TESTS
// ═════════════════════════════════════════════════════════════════════════════

private void test_escape_ffmetadata_value () {
    assert_string_equal (
        CombineRunner.escape_ffmetadata_value ("simple"),
        "simple",
        "plain text passes through unchanged");
    assert_string_equal (
        CombineRunner.escape_ffmetadata_value ("key=value"),
        "key\\=value",
        "equals sign is escaped");
    assert_string_equal (
        CombineRunner.escape_ffmetadata_value ("a;b#c\\d"),
        "a\\;b\\#c\\\\d",
        "semicolons, hashes and backslashes are escaped");
    assert_string_equal (
        CombineRunner.escape_ffmetadata_value ("line1\nline2\rline3"),
        "line1 line2 line3",
        "newlines and carriage returns are replaced with spaces");
}

private void test_chapters_metadata_content_basic () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/intro.mkv", 10.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/main.mkv", 5.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/credits.mkv", 8.0, 1920, 1080));

    var runner = new CombineRunner ();
    runner.generate_chapters = true;
    runner.set_files (files);

    string? content = runner.build_chapters_metadata_content ();
    assert_true (content != null, "chapters metadata not null");
    assert_contains (content, ";FFMETADATA1", "metadata header present");
    assert_contains (content, "START=0", "first chapter starts at 0");
    assert_contains (content, "END=10000", "first chapter ends at 10000ms");
    assert_contains (content, "title=intro", "first chapter title from filename");
    assert_contains (content, "START=10000", "second chapter starts at 10000ms");
    assert_contains (content, "END=15000", "second chapter ends at 15000ms");
    assert_contains (content, "title=main", "second chapter title from filename");
    assert_contains (content, "START=15000", "third chapter starts at 15000ms");
    assert_contains (content, "END=23000", "third chapter ends at 23000ms");
    assert_contains (content, "title=credits", "third chapter title from filename");
}

private void test_chapters_metadata_content_with_crossfade () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/a.mkv", 10.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/b.mkv", 5.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/c.mkv", 8.0, 1920, 1080));

    var runner = new CombineRunner ();
    runner.generate_chapters = true;
    runner.set_files (files);

    string? content = runner.build_chapters_metadata_content (0.5);
    assert_true (content != null, "crossfade chapters metadata not null");
    // Chapter 1: 0 to 10.0 - 0.5 = 9.5s → 9500ms
    assert_contains (content, "START=0", "crossfade ch1 starts at 0");
    assert_contains (content, "END=9500", "crossfade ch1 ends at 9500ms");
    // Chapter 2: 9500 to 9500 + 5.0 - 0.5 = 14000ms
    assert_contains (content, "START=9500", "crossfade ch2 starts at 9500ms");
    assert_contains (content, "END=14000", "crossfade ch2 ends at 14000ms");
    // Chapter 3: 14000 to 14000 + 8.0 = 22000ms (last file, no crossfade subtracted)
    assert_contains (content, "START=14000", "crossfade ch3 starts at 14000ms");
    assert_contains (content, "END=22000", "crossfade ch3 ends at 22000ms");
}

private void test_chapters_copy_mode_args () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    var runner = make_capture_runner (files);
    runner.generate_chapters = true;

    int exit_code = runner.run_copy_mode_for_widget_test ();
    assert_true (exit_code == 0, "chapters copy mode exit code");

    string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();
    assert_array_has_adjacent_pair (argv, "-f", "ffmetadata",
        "chapters copy mode includes ffmetadata format");
    assert_array_has_adjacent_pair (argv, "-map_chapters", "1",
        "chapters copy mode maps chapters to metadata input");
}

private void test_chapters_reencode_mode_args () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    var runner = make_capture_runner (files);
    runner.generate_chapters = true;
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "chapters reencode mode exit code");

    string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();
    assert_array_has_adjacent_pair (argv, "-f", "ffmetadata",
        "chapters reencode mode includes ffmetadata format");
    // Metadata input index = number of video files = 2
    assert_array_has_adjacent_pair (argv, "-map_chapters", "2",
        "chapters reencode mode maps chapters to correct input index");
}

private void test_chapters_disabled_remove_chapters_copy () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    var runner = make_capture_runner (files);
    runner.generate_chapters = false;
    runner.remove_source_chapters = true;

    int exit_code = runner.run_copy_mode_for_widget_test ();
    assert_true (exit_code == 0, "remove chapters copy mode exit code");

    string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();
    assert_array_has_adjacent_pair (argv, "-map_chapters", "-1",
        "remove chapters in copy mode strips source chapters");
    assert_array_not_contains (argv, "ffmetadata",
        "remove chapters without generate does not add ffmetadata input");
}

private void test_chapters_disabled_remove_chapters_reencode () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    var runner = make_capture_runner (files);
    runner.generate_chapters = false;
    runner.remove_source_chapters = true;
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "remove chapters reencode mode exit code");

    string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();
    assert_array_has_adjacent_pair (argv, "-map_chapters", "-1",
        "remove chapters in reencode mode strips source chapters");
}

private void test_chapters_generate_overrides_remove () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    var runner = make_capture_runner (files);
    runner.generate_chapters = true;
    runner.remove_source_chapters = true;
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "generate overrides remove exit code");

    string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();
    // Should map to generated chapters input (index 2), not -1
    assert_array_has_adjacent_pair (argv, "-map_chapters", "2",
        "generate_chapters overrides remove_source_chapters");
    assert_array_has_adjacent_pair (argv, "-f", "ffmetadata",
        "generate_chapters adds ffmetadata input even when remove is also set");
}

private void test_chapters_both_disabled () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    var runner = make_capture_runner (files);
    runner.generate_chapters = false;
    runner.remove_source_chapters = false;

    int exit_code = runner.run_copy_mode_for_widget_test ();
    assert_true (exit_code == 0, "both disabled copy mode exit code");

    string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();
    assert_array_not_contains (argv, "-map_chapters",
        "no -map_chapters when both chapter options disabled");
    assert_array_not_contains (argv, "ffmetadata",
        "no ffmetadata when both chapter options disabled");
}

// ═════════════════════════════════════════════════════════════════════════════
//  CROSSFADE TESTS
// ═════════════════════════════════════════════════════════════════════════════

private void test_crossfade_two_files_filter () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 10.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 8.0, 1920, 1080));

    var runner = make_capture_runner (files);
    runner.crossfade_enabled = true;
    runner.crossfade_duration = 0.5;
    runner.crossfade_type = "fade";
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "crossfade two files exit code");

    string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();
    string filter_complex = "";
    for (int i = 0; i < argv.length - 1; i++) {
        if (argv[i] == "-filter_complex") {
            filter_complex = argv[i + 1];
            break;
        }
    }

    assert_contains (filter_complex,
        "xfade=transition=fade:duration=0.500000:offset=9.500000[outv]",
        "crossfade two files produces correct xfade filter");
    assert_contains (filter_complex,
        "acrossfade=d=0.500000:c1=tri:c2=tri[outa]",
        "crossfade two files produces correct acrossfade filter");
    assert_true (filter_complex.index_of ("concat=") < 0,
        "crossfade mode does not use concat filter");
}

private void test_crossfade_three_files_filter () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 10.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/third.mkv", 8.0, 1920, 1080));

    var runner = make_capture_runner (files);
    runner.crossfade_enabled = true;
    runner.crossfade_duration = 0.5;
    runner.crossfade_type = "fade";
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "crossfade three files exit code");

    string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();
    string filter_complex = "";
    for (int i = 0; i < argv.length - 1; i++) {
        if (argv[i] == "-filter_complex") {
            filter_complex = argv[i + 1];
            break;
        }
    }

    // offset0 = 10.0 - 0.5 = 9.5
    assert_contains (filter_complex,
        "xfade=transition=fade:duration=0.500000:offset=9.500000[xv1]",
        "crossfade three files first xfade offset correct");
    // offset1 = (10.0 + 5.0) - 2 * 0.5 = 14.0
    assert_contains (filter_complex,
        "xfade=transition=fade:duration=0.500000:offset=14.000000[outv]",
        "crossfade three files second xfade offset correct");
    assert_contains (filter_complex,
        "acrossfade=d=0.500000:c1=tri:c2=tri[xa1]",
        "crossfade three files first acrossfade chained");
    assert_contains (filter_complex,
        "acrossfade=d=0.500000:c1=tri:c2=tri[outa]",
        "crossfade three files final acrossfade outputs outa");
}

private void test_crossfade_disabled_uses_concat () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 10.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 8.0, 1920, 1080));

    var runner = make_capture_runner (files);
    runner.crossfade_enabled = false;
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "crossfade disabled exit code");

    string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();
    string filter_complex = "";
    for (int i = 0; i < argv.length - 1; i++) {
        if (argv[i] == "-filter_complex") {
            filter_complex = argv[i + 1];
            break;
        }
    }

    assert_contains (filter_complex, "concat=n=2:v=1:a=1",
        "crossfade disabled still uses concat filter");
    assert_true (filter_complex.index_of ("xfade") < 0,
        "crossfade disabled does not use xfade filter");
}

private void test_crossfade_no_audio () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 10.0, 1920, 1080,
        "30/1", "yuv420p", "1:1", false));
    files.add (make_combine_file ("/tmp/second.mkv", 8.0, 1920, 1080,
        "30/1", "yuv420p", "1:1", false));

    var runner = make_capture_runner (files);
    runner.crossfade_enabled = true;
    runner.crossfade_duration = 0.5;
    runner.crossfade_type = "dissolve";
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "crossfade no audio exit code");

    string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();
    string filter_complex = "";
    for (int i = 0; i < argv.length - 1; i++) {
        if (argv[i] == "-filter_complex") {
            filter_complex = argv[i + 1];
            break;
        }
    }

    assert_contains (filter_complex,
        "xfade=transition=dissolve",
        "crossfade no audio has xfade filter");
    assert_true (filter_complex.index_of ("acrossfade") < 0,
        "crossfade no audio does not have acrossfade filter");
    assert_array_contains (argv, "-an",
        "crossfade no audio disables audio output");
}

private void test_crossfade_settb_in_filter () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 10.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 8.0, 1920, 1080));

    var runner = make_capture_runner (files);
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "settb filter exit code");

    string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();
    string filter_complex = "";
    for (int i = 0; i < argv.length - 1; i++) {
        if (argv[i] == "-filter_complex") {
            filter_complex = argv[i + 1];
            break;
        }
    }

    assert_contains (filter_complex, "settb=AVTB",
        "video normalization chain includes settb=AVTB for timebase normalization");
}

private void test_crossfade_with_chapters () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/a.mkv", 10.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/b.mkv", 5.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/c.mkv", 8.0, 1920, 1080));

    var runner = new CombineRunner ();
    runner.generate_chapters = true;
    runner.crossfade_enabled = true;
    runner.crossfade_duration = 0.5;
    runner.set_files (files);

    string? content = runner.build_chapters_metadata_content (0.5);
    assert_true (content != null, "crossfade+chapters metadata not null");

    // Ch1: 0 to 9500ms, Ch2: 9500 to 14000ms, Ch3: 14000 to 22000ms
    assert_contains (content, "END=9500", "crossfade+chapters ch1 end");
    assert_contains (content, "START=9500", "crossfade+chapters ch2 start");
    assert_contains (content, "END=14000", "crossfade+chapters ch2 end");
    assert_contains (content, "START=14000", "crossfade+chapters ch3 start");
    assert_contains (content, "END=22000", "crossfade+chapters ch3 end");
}

// ═════════════════════════════════════════════════════════════════════════════
//  HELPER: Extract filter_complex from argv
// ═════════════════════════════════════════════════════════════════════════════

private string extract_filter_complex (string[] argv) {
    for (int i = 0; i < argv.length - 1; i++) {
        if (argv[i] == "-filter_complex") {
            return argv[i + 1];
        }
    }
    return "";
}

// ═════════════════════════════════════════════════════════════════════════════
//  FULL PROFILE TESTS
// ═════════════════════════════════════════════════════════════════════════════

private void test_combine_reencode_applies_general_video_filters () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    var runner = make_capture_runner (files);
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    profile.combine_video_filters_per_input = "transpose=1";
    profile.combine_video_filters_post_output = "fps=24";
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "video filters apply exit code");

    string fc = extract_filter_complex (runner.get_last_ffmpeg_argv_for_widget_test ());
    assert_contains (fc, "transpose=1,setsar=1,settb=AVTB,setpts=PTS-STARTPTS",
        "clip-local video filters stay in the per-input chain");
    assert_contains (fc, "[outv_pre]fps=24[outv]",
        "output-shaping video filters apply once after combine");
}

private void test_combine_reencode_post_output_scale_is_separate_from_input_normalization () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 640, 480));

    var runner = make_capture_runner (files);
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    profile.combine_video_filters_post_output = "scale=w=1280:h=720:flags=point";
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "post-output scale separation exit code");

    string fc = extract_filter_complex (runner.get_last_ffmpeg_argv_for_widget_test ());
    assert_contains (fc,
        "[1:v:0]scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:-1:-1:color=black,setsar=1,settb=AVTB,setpts=PTS-STARTPTS[v1];",
        "non-first inputs still normalize to file[0] dimensions before combine");
    assert_contains (fc, "[outv_pre]scale=w=1280:h=720:flags=point[outv]",
        "final output scale is applied once after combine");
}

private void test_combine_crossfade_applies_post_output_video_filters () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 10.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 8.0, 1920, 1080));

    var runner = make_capture_runner (files);
    runner.crossfade_enabled = true;
    runner.crossfade_duration = 0.5;
    runner.crossfade_type = "fade";
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    profile.combine_video_filters_post_output = "fps=24";
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "crossfade post-output video filters exit code");

    string fc = extract_filter_complex (runner.get_last_ffmpeg_argv_for_widget_test ());
    assert_contains (fc, "xfade=transition=fade:duration=0.500000:offset=9.500000[outv_pre]",
        "crossfade video output is rewired through outv_pre before final shaping");
    assert_contains (fc, "[outv_pre]fps=24[outv]",
        "crossfade path applies output-shaping filters after combine");
}

private void test_combine_reencode_without_post_output_filters_keeps_direct_outv_label () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    var runner = make_capture_runner (files);
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    profile.combine_video_filters_per_input = "transpose=1";
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "direct outv label exit code");

    string fc = extract_filter_complex (runner.get_last_ffmpeg_argv_for_widget_test ());
    assert_contains (fc, "concat=n=2:v=1:a=1[outv][outa]",
        "combine keeps direct outv output when no post-output video shaping is needed");
    assert_true (fc.index_of ("[outv_pre]") < 0,
        "combine does not introduce outv_pre when no post-output video filters are present");
}

private void test_combine_reencode_strips_speed_setpts_from_video_filters () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    var runner = make_capture_runner (files);
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    // Simulates a speed filter that setpts would produce — should be stripped
    profile.video_filters_skip_crop = "setpts=0.500000*PTS";
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "speed filter strip exit code");

    string fc = extract_filter_complex (runner.get_last_ffmpeg_argv_for_widget_test ());
    // Speed setpts should be stripped; only the timestamp reset remains
    assert_true (fc.index_of ("0.500000*PTS") < 0,
        "speed setpts is stripped from combine video filters");
    assert_contains (fc, "setsar=1,settb=AVTB,setpts=PTS-STARTPTS",
        "timestamp reset still present after speed strip");
}

private void test_combine_reencode_applies_audio_filters () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    var runner = make_capture_runner (files);
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    // Use a non-speed audio filter (speed filters are stripped in combine)
    profile.audio_filters = "aecho=0.8:0.88:60:0.4";
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "audio filters apply exit code");

    string fc = extract_filter_complex (runner.get_last_ffmpeg_argv_for_widget_test ());
    assert_contains (fc, "aecho=0.8:0.88:60:0.4,asetpts=PTS-STARTPTS",
        "general audio filters are applied per input before asetpts");
}

private void test_combine_reencode_applies_audio_processing_chain () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    var runner = make_capture_runner (files);
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    var ap = new AudioProcessingSettingsSnapshot ();
    ap.fade_in_enabled = true;
    ap.fade_in_duration = 1.0;
    profile.audio_processing = ap;
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "audio processing apply exit code");

    string fc = extract_filter_complex (runner.get_last_ffmpeg_argv_for_widget_test ());
    assert_contains (fc, "afade=t=in:d=1.00",
        "audio processing fade-in is applied per input");
}

private void test_combine_reencode_preserves_audio_copy_fallback () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    var runner = make_capture_runner (files);
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    // Simulates the audio-copy fallback already applied by CombineWindow
    profile.audio_args = { "-c:a", "aac", "-b:a", "192k" };
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "audio copy fallback exit code");

    string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();
    assert_array_has_adjacent_pair (argv, "-c:a", "aac",
        "combine always uses audio re-encode, never copy");
}

// ═════════════════════════════════════════════════════════════════════════════
//  AUDIO COPY CONSTRAINT TESTS
// ═════════════════════════════════════════════════════════════════════════════

private void test_combine_reencode_syncs_audio_copy_constraint_across_codec_tabs () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();

    for (uint i = 0; i < 4; i++) {
        assert_true (
            harness.window.is_audio_copy_available_in_codec_tab_for_widget_test (i),
            "Copy starts available in each codec tab before combine re-encode"
        );
        assert_string_equal (
            harness.window.get_codec_tab_selected_audio_codec_for_widget_test (i),
            AudioCodecName.COPY,
            "each codec tab starts on Copy before combine re-encode"
        );
    }

    harness.window.set_copy_mode_switch_active_for_widget_test (false);

    for (uint i = 0; i < 4; i++) {
        assert_false (
            harness.window.is_audio_copy_available_in_codec_tab_for_widget_test (i),
            "combine re-encode removes Copy from each codec tab"
        );
        assert_contains (
            harness.window.get_codec_tab_audio_subtitle_for_widget_test (i),
            "Combine re-encode",
            "combine re-encode subtitle is reflected in each codec tab"
        );
    }

    harness.window.set_copy_mode_switch_active_for_widget_test (true);

    for (uint i = 0; i < 4; i++) {
        assert_true (
            harness.window.is_audio_copy_available_in_codec_tab_for_widget_test (i),
            "returning to copy mode restores Copy in each codec tab"
        );
        assert_string_equal (
            harness.window.get_codec_tab_selected_audio_codec_for_widget_test (i),
            AudioCodecName.COPY,
            "returning to copy mode restores Copy selection in each codec tab"
        );
    }

    harness.window.close ();
}

private void test_closing_combine_window_releases_audio_copy_constraint () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();
    harness.window.set_copy_mode_switch_active_for_widget_test (false);
    harness.window.invoke_close_request_for_widget_test ();

    for (uint i = 0; i < 4; i++) {
        assert_true (
            harness.window.is_audio_copy_available_in_codec_tab_for_widget_test (i),
            "closing combine restores Copy availability in each codec tab"
        );
        assert_string_equal (
            harness.window.get_codec_tab_selected_audio_codec_for_widget_test (i),
            AudioCodecName.COPY,
            "closing combine restores Copy selection in each codec tab"
        );
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//  AUDIO STATUS OVERRIDE TESTS
// ═════════════════════════════════════════════════════════════════════════════

private void test_combine_reencode_sets_audio_badge_override_across_codec_tabs () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();

    // Before re-encode: badge should be the default "Audio status unavailable"
    for (uint i = 0; i < 4; i++) {
        assert_string_equal (
            harness.window.get_codec_tab_audio_badge_text_for_widget_test (i),
            "Audio status unavailable",
            "badge starts as default unavailable before combine re-encode"
        );
    }

    harness.window.set_copy_mode_switch_active_for_widget_test (false);

    for (uint i = 0; i < 4; i++) {
        assert_string_equal (
            harness.window.get_codec_tab_audio_badge_text_for_widget_test (i),
            "Audio re-encoded by Combine",
            "re-encode mode sets override badge in each codec tab"
        );
    }

    harness.window.set_copy_mode_switch_active_for_widget_test (true);

    // Back to copy mode with no probed files — override clears
    for (uint i = 0; i < 4; i++) {
        assert_string_equal (
            harness.window.get_codec_tab_audio_badge_text_for_widget_test (i),
            "Audio status unavailable",
            "returning to copy mode with no probed files clears badge override"
        );
    }

    harness.window.close ();
}

private void test_closing_combine_clears_audio_badge_override () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();
    harness.window.set_copy_mode_switch_active_for_widget_test (false);

    // Verify override is active
    assert_string_equal (
        harness.window.get_codec_tab_audio_badge_text_for_widget_test (0),
        "Audio re-encoded by Combine",
        "override is active before close"
    );

    harness.window.invoke_close_request_for_widget_test ();

    for (uint i = 0; i < 4; i++) {
        assert_string_equal (
            harness.window.get_codec_tab_audio_badge_text_for_widget_test (i),
            "Audio status unavailable",
            "closing combine clears the badge override in each codec tab"
        );
    }
}

private void test_combine_copy_mode_with_audio_shows_copy_badge () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();
    harness.window.load_files_for_widget_test ({
        "/tmp/first.mkv",
        "/tmp/second.mkv"
    });

    // Simulate probed files with audio — pending_probes is already 0
    // from load_files_for_widget_test
    CombineFile first = harness.window.get_file_for_widget_test (0);
    first.has_audio = true;
    first.audio_codec = "aac";
    first.duration = 5.0;
    first.width = 1920;
    first.height = 1080;
    first.video_codec = "h264";

    CombineFile second = harness.window.get_file_for_widget_test (1);
    second.has_audio = true;
    second.audio_codec = "aac";
    second.duration = 3.0;
    second.width = 1920;
    second.height = 1080;
    second.video_codec = "h264";

    harness.window.refresh_combine_state_for_widget_test ();

    // Copy mode (default) with probes done and audio present
    for (uint i = 0; i < 4; i++) {
        assert_string_equal (
            harness.window.get_codec_tab_audio_badge_text_for_widget_test (i),
            "Audio copy via Combine",
            "copy mode with probed audio shows copy badge in each codec tab"
        );
    }

    // Switch to re-encode — badge should change
    harness.window.set_copy_mode_switch_active_for_widget_test (false);

    for (uint i = 0; i < 4; i++) {
        assert_string_equal (
            harness.window.get_codec_tab_audio_badge_text_for_widget_test (i),
            "Audio re-encoded by Combine",
            "switching to re-encode changes badge from copy to re-encode"
        );
    }

    // Switch back to copy — badge should return to copy
    harness.window.set_copy_mode_switch_active_for_widget_test (true);

    for (uint i = 0; i < 4; i++) {
        assert_string_equal (
            harness.window.get_codec_tab_audio_badge_text_for_widget_test (i),
            "Audio copy via Combine",
            "switching back to copy mode restores copy badge"
        );
    }

    harness.window.close ();
}

private void test_combine_copy_mode_without_audio_clears_badge () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();
    harness.window.load_files_for_widget_test ({
        "/tmp/first.mkv",
        "/tmp/second.mkv"
    });

    // Files with no audio (has_audio defaults to false)
    CombineFile first = harness.window.get_file_for_widget_test (0);
    first.duration = 5.0;
    first.width = 1920;
    first.height = 1080;
    first.video_codec = "h264";

    CombineFile second = harness.window.get_file_for_widget_test (1);
    second.duration = 3.0;
    second.width = 1920;
    second.height = 1080;
    second.video_codec = "h264";

    harness.window.refresh_combine_state_for_widget_test ();

    // Copy mode with no audio — override should be cleared
    for (uint i = 0; i < 4; i++) {
        assert_string_equal (
            harness.window.get_codec_tab_audio_badge_text_for_widget_test (i),
            "Audio status unavailable",
            "copy mode with no audio shows default badge"
        );
    }

    harness.window.close ();
}

private void test_combine_copy_badge_follows_pending_probe_lifecycle () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();
    harness.window.load_files_for_widget_test ({
        "/tmp/first.mkv",
        "/tmp/second.mkv"
    });

    CombineFile first = harness.window.get_file_for_widget_test (0);
    CombineFile second = harness.window.get_file_for_widget_test (1);

    // Seed compatible probe data on both files before arming pending probes.
    // This keeps copy mode eligible so the badge assertions isolate the
    // pending_probes lifecycle rather than copy-mode fallback behavior.
    first.has_audio = true;
    first.audio_codec = "aac";
    first.duration = 5.0;
    first.width = 1920;
    first.height = 1080;
    first.video_codec = "h264";

    second.has_audio = true;
    second.audio_codec = "aac";
    second.duration = 3.0;
    second.width = 1920;
    second.height = 1080;
    second.video_codec = "h264";

    Cancellable first_probe = harness.window.arm_pending_probe_for_file_for_widget_test (0);
    Cancellable second_probe = harness.window.arm_pending_probe_for_file_for_widget_test (1);
    harness.window.refresh_combine_state_for_widget_test ();

    assert_uint64_equal (
        (uint64) harness.window.get_pending_probe_count_for_widget_test (),
        2,
        "arming test probes tracks both pending probe slots"
    );

    for (uint i = 0; i < 4; i++) {
        assert_string_equal (
            harness.window.get_codec_tab_audio_badge_text_for_widget_test (i),
            "Audio status unavailable",
            "copy mode keeps the default badge while combine probes are pending"
        );
    }

    harness.window.complete_pending_probe_for_widget_test (first, first_probe);

    assert_uint64_equal (
        (uint64) harness.window.get_pending_probe_count_for_widget_test (),
        1,
        "first completed probe decrements the pending count"
    );

    for (uint i = 0; i < 4; i++) {
        assert_string_equal (
            harness.window.get_codec_tab_audio_badge_text_for_widget_test (i),
            "Audio status unavailable",
            "badge stays unavailable until all combine probes are finished"
        );
    }

    harness.window.complete_pending_probe_for_widget_test (second, second_probe);

    assert_uint64_equal (
        (uint64) harness.window.get_pending_probe_count_for_widget_test (),
        0,
        "second completed probe clears the pending count"
    );

    for (uint i = 0; i < 4; i++) {
        assert_string_equal (
            harness.window.get_codec_tab_audio_badge_text_for_widget_test (i),
            "Audio copy via Combine",
            "badge switches to copy once all combine probes finish with audio"
        );
    }

    harness.window.close ();
}

// ═════════════════════════════════════════════════════════════════════════════
//  GENERAL SPEED CONSTRAINT TESTS
// ═════════════════════════════════════════════════════════════════════════════

private void configure_general_speed_state (GeneralTab general,
                                            bool video_enabled,
                                            double video_percent,
                                            bool audio_enabled,
                                            double audio_percent) {
    general.video_speed.set_value (video_percent);
    general.audio_speed.set_value (audio_percent);
    general.video_speed_check.set_active (video_enabled);
    general.audio_speed_check.set_active (audio_enabled);
}

private void test_reencode_mode_applies_general_speed_constraint () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();
    GeneralTab general = harness.window.get_general_tab_for_widget_test ();

    configure_general_speed_state (general, true, 25.0, true, -15.0);

    harness.window.set_copy_mode_switch_active_for_widget_test (false);

    assert_true (harness.window.get_general_speed_constrained_for_widget_test (),
        "re-encode mode applies general speed constraint");
    assert_false (general.video_speed_check.active,
        "video speed toggle cleared while constrained");
    assert_false (general.audio_speed_check.active,
        "audio speed toggle cleared while constrained");
    assert_false (general.get_video_speed_expander_sensitive_for_widget_test (),
        "video speed expander disabled while constrained");
    assert_false (general.get_audio_speed_expander_sensitive_for_widget_test (),
        "audio speed expander disabled while constrained");
    assert_contains (general.get_video_speed_subtitle_for_widget_test (),
        "Disabled while Combine re-encode is active",
        "video speed subtitle explains constraint");
    assert_contains (general.get_audio_speed_subtitle_for_widget_test (),
        "Disabled while Combine re-encode is active",
        "audio speed subtitle explains constraint");

    harness.window.close ();
}

private void test_copy_mode_releases_general_speed_constraint_and_restores_state () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();
    GeneralTab general = harness.window.get_general_tab_for_widget_test ();

    configure_general_speed_state (general, true, 25.0, true, -15.0);

    harness.window.set_copy_mode_switch_active_for_widget_test (false);
    harness.window.set_copy_mode_switch_active_for_widget_test (true);

    assert_false (harness.window.get_general_speed_constrained_for_widget_test (),
        "copy mode releases general speed constraint");
    assert_true (general.video_speed_check.active,
        "video speed toggle restored after releasing constraint");
    assert_true (general.audio_speed_check.active,
        "audio speed toggle restored after releasing constraint");
    assert_true (Math.fabs (general.video_speed.get_value () - 25.0) < 0.01,
        "video speed value restored after releasing constraint");
    assert_true (Math.fabs (general.audio_speed.get_value () - (-15.0)) < 0.01,
        "audio speed value restored after releasing constraint");
    assert_true (general.get_video_speed_expander_sensitive_for_widget_test (),
        "video speed expander re-enabled after releasing constraint");
    assert_true (general.get_audio_speed_expander_sensitive_for_widget_test (),
        "audio speed expander re-enabled after releasing constraint");
    assert_string_equal (general.get_video_speed_subtitle_for_widget_test (),
        "Adjust playback speed of the video stream",
        "video speed subtitle restored after releasing constraint");
    assert_string_equal (general.get_audio_speed_subtitle_for_widget_test (),
        "Adjust playback speed of the audio stream",
        "audio speed subtitle restored after releasing constraint");

    harness.window.close ();
}

private void test_closing_combine_window_restores_general_speed_state () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();
    GeneralTab general = harness.window.get_general_tab_for_widget_test ();

    configure_general_speed_state (general, true, 25.0, true, -15.0);

    harness.window.set_copy_mode_switch_active_for_widget_test (false);
    harness.window.invoke_close_request_for_widget_test ();

    assert_false (harness.window.get_general_speed_constrained_for_widget_test (),
        "closing combine releases general speed constraint");
    assert_true (general.video_speed_check.active,
        "video speed toggle restored after window close");
    assert_true (general.audio_speed_check.active,
        "audio speed toggle restored after window close");
    assert_true (Math.fabs (general.video_speed.get_value () - 25.0) < 0.01,
        "video speed value restored after window close");
    assert_true (Math.fabs (general.audio_speed.get_value () - (-15.0)) < 0.01,
        "audio speed value restored after window close");

    harness.window.close ();
}

private void test_general_speed_constraint_preserves_unrelated_general_settings () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();
    GeneralTab general = harness.window.get_general_tab_for_widget_test ();

    configure_general_speed_state (general, true, 25.0, true, -15.0);

    // Configure unrelated General settings that should survive the constraint cycle.
    general.scale_mode.set_selected (1);  // Resolution
    general.resolution_preset.set_selected (18);  // 1280x720
    general.rotate_combo.set_selected (1);  // Clockwise 90

    GeneralSettingsSnapshot before = general.snapshot_settings ();

    harness.window.set_copy_mode_switch_active_for_widget_test (false);
    harness.window.set_copy_mode_switch_active_for_widget_test (true);

    GeneralSettingsSnapshot after = general.snapshot_settings ();
    assert_string_equal (after.scale_mode, before.scale_mode,
        "scale mode is preserved across speed constraint");
    assert_string_equal (after.resolution_preset_value, before.resolution_preset_value,
        "resolution preset is preserved across speed constraint");
    assert_string_equal (after.rotate, before.rotate,
        "rotation setting is preserved across speed constraint");

    harness.window.close ();
}

private void test_combine_launch_snapshot_omits_general_speed_filters_when_constrained () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();
    GeneralTab general = harness.window.get_general_tab_for_widget_test ();
    harness.window.load_files_for_widget_test ({
        "/tmp/first.mkv",
        "/tmp/second.mkv"
    });

    configure_general_speed_state (general, true, 25.0, true, -15.0);
    harness.window.set_copy_mode_switch_active_for_widget_test (false);

    harness.window.enable_launch_capture_for_widget_test ();
    harness.window.arm_pending_overwrite_snapshot_for_widget_test (
        77, false, "/tmp/constrained-speed.mkv");
    harness.window.replay_pending_overwrite_launch_for_widget_test (77, "overwrite");

    EncodeProfileSnapshot? profile =
        harness.window.get_last_launched_profile_for_widget_test ();
    assert_true (profile != null, "captured combine launch profile exists");
    assert_true (profile.video_filters.index_of ("*PTS") < 0,
        "captured combine launch profile omits general video speed filter");
    assert_true (profile.video_filters_skip_crop.index_of ("*PTS") < 0,
        "captured combine launch profile omits general video speed filter from skip-crop chain");
    assert_true (profile.audio_filters.index_of ("atempo=") < 0,
        "captured combine launch profile omits general audio speed filter");

    harness.window.close ();
}

// ═════════════════════════════════════════════════════════════════════════════
//  GENERAL CROP CONSTRAINT TESTS
// ═════════════════════════════════════════════════════════════════════════════

private void configure_general_crop_state (GeneralTab general,
                                           bool enabled,
                                           string crop_text) {
    general.crop_value.set_text (crop_text);
    general.crop_check.set_active (enabled);
}

private void test_reencode_mode_applies_general_crop_constraint () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();
    GeneralTab general = harness.window.get_general_tab_for_widget_test ();

    configure_general_crop_state (general, true, "100:100:0:0");

    harness.window.set_copy_mode_switch_active_for_widget_test (false);

    assert_true (harness.window.get_general_crop_constrained_for_widget_test (),
        "re-encode mode applies general crop constraint");
    assert_false (general.crop_check.active,
        "crop toggle cleared while constrained");
    assert_false (general.get_crop_expander_sensitive_for_widget_test (),
        "crop expander disabled while constrained");
    assert_contains (general.get_crop_subtitle_for_widget_test (),
        "Disabled while Combine re-encode is active",
        "crop subtitle explains constraint");

    harness.window.close ();
}

private void test_copy_mode_releases_general_crop_constraint_and_restores_state () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();
    GeneralTab general = harness.window.get_general_tab_for_widget_test ();

    configure_general_crop_state (general, true, "100:100:0:0");

    harness.window.set_copy_mode_switch_active_for_widget_test (false);
    harness.window.set_copy_mode_switch_active_for_widget_test (true);

    assert_false (harness.window.get_general_crop_constrained_for_widget_test (),
        "copy mode releases general crop constraint");
    assert_true (general.crop_check.active,
        "crop toggle restored after releasing constraint");
    assert_string_equal (general.crop_value.text, "100:100:0:0",
        "crop value restored after releasing constraint");
    assert_true (general.get_crop_expander_sensitive_for_widget_test (),
        "crop expander re-enabled after releasing constraint");
    assert_string_equal (general.get_crop_subtitle_for_widget_test (),
        "Remove black bars or unwanted borders",
        "crop subtitle restored after releasing constraint");

    harness.window.close ();
}

private void test_closing_combine_window_restores_general_crop_state () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();
    GeneralTab general = harness.window.get_general_tab_for_widget_test ();

    configure_general_crop_state (general, true, "100:100:0:0");

    harness.window.set_copy_mode_switch_active_for_widget_test (false);
    harness.window.invoke_close_request_for_widget_test ();

    assert_false (harness.window.get_general_crop_constrained_for_widget_test (),
        "closing combine releases general crop constraint");
    assert_true (general.crop_check.active,
        "crop toggle restored after window close");
    assert_string_equal (general.crop_value.text, "100:100:0:0",
        "crop value restored after window close");

    harness.window.close ();
}

private void test_combine_crop_constraint_does_not_override_trim_crop_lock () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();
    GeneralTab general = harness.window.get_general_tab_for_widget_test ();

    configure_general_crop_state (general, true, "100:100:0:0");

    harness.window.set_copy_mode_switch_active_for_widget_test (false);
    general.notify_trim_tab_mode (1);  // Trim crop lock active
    harness.window.set_copy_mode_switch_active_for_widget_test (true);

    assert_false (harness.window.get_general_crop_constrained_for_widget_test (),
        "combine crop constraint released");
    assert_false (general.crop_check.active,
        "crop remains disabled while trim crop lock is active");
    assert_false (general.get_crop_expander_sensitive_for_widget_test (),
        "trim crop lock remains in effect after combine releases");

    general.notify_trim_tab_mode (-1);
    harness.window.close ();
}

private void test_combine_launch_snapshot_omits_general_crop_filter_when_constrained () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();
    GeneralTab general = harness.window.get_general_tab_for_widget_test ();
    harness.window.load_files_for_widget_test ({
        "/tmp/first.mkv",
        "/tmp/second.mkv"
    });

    configure_general_crop_state (general, true, "100:100:0:0");
    harness.window.set_copy_mode_switch_active_for_widget_test (false);

    harness.window.enable_launch_capture_for_widget_test ();
    harness.window.arm_pending_overwrite_snapshot_for_widget_test (
        88, false, "/tmp/constrained-crop.mkv");
    harness.window.replay_pending_overwrite_launch_for_widget_test (88, "overwrite");

    EncodeProfileSnapshot? profile =
        harness.window.get_last_launched_profile_for_widget_test ();
    assert_true (profile != null, "captured combine launch profile exists for crop constraint");
    assert_true (profile.video_filters.index_of ("crop=") < 0,
        "captured combine launch profile omits general crop filter");
    assert_true (profile.video_filters_skip_crop.index_of ("crop=") < 0,
        "captured combine launch profile omits general crop filter from skip-crop chain");

    harness.window.close ();
}

// ═════════════════════════════════════════════════════════════════════════════
//  GENERAL TIMING CONSTRAINT TESTS
// ═════════════════════════════════════════════════════════════════════════════

private void configure_general_timing_state (GeneralTab general,
                                             bool seek_enabled,
                                             int seek_h,
                                             int seek_m,
                                             int seek_s,
                                             bool time_enabled,
                                             int time_h,
                                             int time_m,
                                             int time_s) {
    general.seek_hh.set_value (seek_h);
    general.seek_mm.set_value (seek_m);
    general.seek_ss.set_value (seek_s);
    general.time_hh.set_value (time_h);
    general.time_mm.set_value (time_m);
    general.time_ss.set_value (time_s);
    general.seek_check.set_active (seek_enabled);
    general.time_check.set_active (time_enabled);
}

private void test_combine_open_applies_general_timing_constraint () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();
    GeneralTab general = harness.window.get_general_tab_for_widget_test ();

    assert_true (harness.window.get_general_timing_constrained_for_widget_test (),
        "combine window applies general timing constraint on open");
    assert_false (general.seek_check.active,
        "seek toggle cleared while constrained");
    assert_false (general.time_check.active,
        "duration toggle cleared while constrained");
    assert_false (general.get_seek_expander_sensitive_for_widget_test (),
        "seek expander disabled while constrained");
    assert_false (general.get_time_expander_sensitive_for_widget_test (),
        "duration expander disabled while constrained");
    assert_contains (general.get_seek_subtitle_for_widget_test (),
        "Disabled while Combine is open",
        "seek subtitle explains constraint");
    assert_contains (general.get_time_subtitle_for_widget_test (),
        "Disabled while Combine is open",
        "duration subtitle explains constraint");

    harness.window.close ();
}

private void test_closing_combine_window_restores_general_timing_state () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();
    GeneralTab general = harness.window.get_general_tab_for_widget_test ();

    harness.window.release_general_timing_constraint_for_widget_test ();
    configure_general_timing_state (general, true, 0, 1, 5, true, 0, 0, 30);
    harness.window.sync_general_timing_constraint_for_widget_test ();
    harness.window.invoke_close_request_for_widget_test ();

    assert_false (harness.window.get_general_timing_constrained_for_widget_test (),
        "closing combine releases general timing constraint");
    assert_true (general.seek_check.active,
        "seek toggle restored after window close");
    assert_true (general.time_check.active,
        "duration toggle restored after window close");
    assert_true (general.get_seek_expander_sensitive_for_widget_test (),
        "seek expander re-enabled after window close");
    assert_true (general.get_time_expander_sensitive_for_widget_test (),
        "duration expander re-enabled after window close");
    assert_string_equal (general.get_seek_timestamp (), "00:01:05",
        "seek timestamp restored after window close");
    assert_string_equal (general.get_time_timestamp (), "00:00:30",
        "duration restored after window close");

    harness.window.close ();
}

private void test_combine_timing_constraint_does_not_override_trim_timing_lock () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();
    GeneralTab general = harness.window.get_general_tab_for_widget_test ();

    general.notify_trim_tab_mode (0);  // Trim timing lock active
    harness.window.release_general_timing_constraint_for_widget_test ();

    assert_false (harness.window.get_general_timing_constrained_for_widget_test (),
        "combine timing constraint released");
    assert_false (general.seek_check.active,
        "seek remains disabled while trim timing lock is active");
    assert_false (general.time_check.active,
        "duration remains disabled while trim timing lock is active");
    assert_false (general.get_seek_expander_sensitive_for_widget_test (),
        "trim timing lock remains in effect for seek after combine releases");
    assert_false (general.get_time_expander_sensitive_for_widget_test (),
        "trim timing lock remains in effect for duration after combine releases");

    general.notify_trim_tab_mode (-1);
    harness.window.close ();
}

// ═════════════════════════════════════════════════════════════════════════════
//  FADE / CROSSFADE CONSTRAINT TESTS
// ═════════════════════════════════════════════════════════════════════════════

private void test_crossfade_enabling_clears_and_disables_fades () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();

    // Set up fades on the default codec tab (SVT-AV1, index 0)
    BaseCodecTab? tab = harness.window.get_selected_base_codec_tab_for_widget_test ();
    assert_true (tab != null, "selected base codec tab is not null");
    tab.audio_processing_settings.apply_snapshot (create_fade_snapshot ());

    // Enter re-encode mode
    harness.window.set_copy_mode_switch_active_for_widget_test (false);

    // Enable crossfade
    harness.window.set_crossfade_switch_active_for_widget_test (true);

    // Fades should be cleared and controls disabled
    var snapshot = tab.audio_processing_settings.snapshot_settings ();
    assert_false (snapshot.fade_in_enabled,
        "crossfade enabling clears fade-in");
    assert_false (snapshot.fade_out_enabled,
        "crossfade enabling clears fade-out");
    assert_true (harness.window.get_constrained_codec_tab_for_widget_test () == tab,
        "constrained tab tracks the selected tab");

    harness.window.close ();
}

private void test_crossfade_disabling_reenables_fades () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();

    harness.window.set_copy_mode_switch_active_for_widget_test (false);
    harness.window.set_crossfade_switch_active_for_widget_test (true);
    harness.window.set_crossfade_switch_active_for_widget_test (false);

    assert_true (harness.window.get_constrained_codec_tab_for_widget_test () == null,
        "disabling crossfade releases constraint");

    harness.window.close ();
}

private void test_crossfade_codec_switch_moves_constraint () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();

    harness.window.set_copy_mode_switch_active_for_widget_test (false);
    harness.window.set_crossfade_switch_active_for_widget_test (true);

    BaseCodecTab? tab0 = harness.window.get_selected_base_codec_tab_for_widget_test ();

    // Switch to x265 (index 1)
    harness.window.set_codec_choice_selected_for_widget_test (1);

    BaseCodecTab? tab1 = harness.window.get_selected_base_codec_tab_for_widget_test ();

    // Old tab should be released, new tab should be constrained
    assert_true (harness.window.get_constrained_codec_tab_for_widget_test () == tab1,
        "codec switch moves constraint to new tab");
    assert_true (tab0 != tab1, "tabs are different objects");

    harness.window.close ();
}

private void test_copy_mode_on_releases_crossfade_constraint () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();

    harness.window.set_copy_mode_switch_active_for_widget_test (false);
    harness.window.set_crossfade_switch_active_for_widget_test (true);

    assert_true (harness.window.get_constrained_codec_tab_for_widget_test () != null,
        "constraint is active before copy mode on");

    harness.window.set_copy_mode_switch_active_for_widget_test (true);

    assert_true (harness.window.get_constrained_codec_tab_for_widget_test () == null,
        "copy mode on releases crossfade constraint");

    harness.window.close ();
}

private void test_copy_mode_off_reapplies_crossfade_constraint () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();

    // Enable re-encode + crossfade, then switch to copy, then back
    harness.window.set_copy_mode_switch_active_for_widget_test (false);
    harness.window.set_crossfade_switch_active_for_widget_test (true);
    harness.window.set_copy_mode_switch_active_for_widget_test (true);
    harness.window.set_copy_mode_switch_active_for_widget_test (false);

    // Crossfade was user-preferred, so it should come back along with the constraint
    assert_true (harness.window.get_crossfade_switch_active_for_widget_test (),
        "crossfade restored when returning to re-encode mode");
    assert_true (harness.window.get_constrained_codec_tab_for_widget_test () != null,
        "constraint reapplied when copy mode off");

    harness.window.close ();
}

private void test_crossfade_disabling_restores_fade_state () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();

    BaseCodecTab? tab = harness.window.get_selected_base_codec_tab_for_widget_test ();
    assert_true (tab != null, "tab not null");

    // Set up fades on the codec tab
    tab.audio_processing_settings.apply_snapshot (create_fade_snapshot ());
    var before = tab.audio_processing_settings.snapshot_settings ();
    assert_true (before.fade_in_enabled, "fade-in set before constraint");
    assert_true (before.fade_out_enabled, "fade-out set before constraint");

    // Enable re-encode + crossfade (clears fades)
    harness.window.set_copy_mode_switch_active_for_widget_test (false);
    harness.window.set_crossfade_switch_active_for_widget_test (true);

    var during = tab.audio_processing_settings.snapshot_settings ();
    assert_false (during.fade_in_enabled, "fade-in cleared during constraint");
    assert_false (during.fade_out_enabled, "fade-out cleared during constraint");

    // Disable crossfade — should restore
    harness.window.set_crossfade_switch_active_for_widget_test (false);

    var after = tab.audio_processing_settings.snapshot_settings ();
    assert_true (after.fade_in_enabled,
        "fade-in restored after constraint released");
    assert_true (after.fade_out_enabled,
        "fade-out restored after constraint released");
    assert_true (Math.fabs (after.fade_in_duration - 1.5) < 0.01,
        "fade-in duration restored after constraint released");
    assert_true (Math.fabs (after.fade_out_duration - 2.0) < 0.01,
        "fade-out duration restored after constraint released");

    harness.window.close ();
}

private void test_closing_combine_window_restores_fade_state () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();

    BaseCodecTab? tab = harness.window.get_selected_base_codec_tab_for_widget_test ();
    tab.audio_processing_settings.apply_snapshot (create_fade_snapshot ());

    harness.window.set_copy_mode_switch_active_for_widget_test (false);
    harness.window.set_crossfade_switch_active_for_widget_test (true);

    // Close window while crossfade is active
    harness.window.invoke_close_request_for_widget_test ();

    // Fade state should be restored on the shared tab
    var after = tab.audio_processing_settings.snapshot_settings ();
    assert_true (after.fade_in_enabled,
        "fade-in restored after window close");
    assert_true (after.fade_out_enabled,
        "fade-out restored after window close");

    harness.window.close ();
}

private void test_crossfade_release_preserves_non_fade_changes () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();

    BaseCodecTab? tab = harness.window.get_selected_base_codec_tab_for_widget_test ();
    assert_true (tab != null, "tab not null");

    tab.audio_processing_settings.apply_snapshot (create_fade_snapshot ());

    harness.window.set_copy_mode_switch_active_for_widget_test (false);
    harness.window.set_crossfade_switch_active_for_widget_test (true);

    var during = tab.audio_processing_settings.snapshot_settings ();
    during.normalize_enabled = true;
    during.normalize_ebu = false;
    during.channel_downmix = 1;
    tab.audio_processing_settings.apply_snapshot (during);

    harness.window.set_crossfade_switch_active_for_widget_test (false);

    var after = tab.audio_processing_settings.snapshot_settings ();
    assert_true (after.normalize_enabled,
        "normalization change made during constraint is preserved");
    assert_false (after.normalize_ebu,
        "normalization mode change made during constraint is preserved");
    assert_true (after.channel_downmix == 1,
        "channel layout change made during constraint is preserved");
    assert_true (after.fade_in_enabled,
        "fade-in restored after releasing constraint");
    assert_true (after.fade_out_enabled,
        "fade-out restored after releasing constraint");
    assert_true (Math.fabs (after.fade_in_duration - 1.5) < 0.01,
        "fade-in duration restored after releasing constraint");
    assert_true (Math.fabs (after.fade_out_duration - 2.0) < 0.01,
        "fade-out duration restored after releasing constraint");

    harness.window.close ();
}

private void test_closing_combine_window_releases_constraint () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();

    harness.window.set_copy_mode_switch_active_for_widget_test (false);
    harness.window.set_crossfade_switch_active_for_widget_test (true);

    BaseCodecTab? tab = harness.window.get_constrained_codec_tab_for_widget_test ();
    assert_true (tab != null, "constraint exists before close");

    // Simulate close
    harness.window.invoke_close_request_for_widget_test ();

    // The window's constrained_codec_tab should be null after close
    assert_true (harness.window.get_constrained_codec_tab_for_widget_test () == null,
        "closing window releases fade constraint");

    harness.window.close ();
}

// ═════════════════════════════════════════════════════════════════════════════
//  RUNNER FADE BEHAVIOR TESTS
// ═════════════════════════════════════════════════════════════════════════════

private void test_combine_runner_allows_fades_when_crossfade_off () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 10.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 8.0, 1920, 1080));

    var runner = make_capture_runner (files);
    runner.crossfade_enabled = false;
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    var ap = new AudioProcessingSettingsSnapshot ();
    ap.fade_in_enabled = true;
    ap.fade_in_duration = 1.0;
    ap.fade_out_enabled = true;
    ap.fade_out_duration = 2.0;
    profile.audio_processing = ap;
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "fades when crossfade off exit code");

    string fc = extract_filter_complex (runner.get_last_ffmpeg_argv_for_widget_test ());
    assert_contains (fc, "afade=t=in:d=1.00",
        "fade-in allowed when crossfade is off");
    assert_contains (fc, "afade=t=out",
        "fade-out allowed when crossfade is off");
}

private void test_combine_runner_suppresses_afade_when_crossfade_on () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 10.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 8.0, 1920, 1080));

    var runner = make_capture_runner (files);
    runner.crossfade_enabled = true;
    runner.crossfade_duration = 0.5;
    runner.crossfade_type = "fade";
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    var ap = new AudioProcessingSettingsSnapshot ();
    ap.fade_in_enabled = true;
    ap.fade_in_duration = 1.0;
    ap.fade_out_enabled = true;
    ap.fade_out_duration = 2.0;
    profile.audio_processing = ap;
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "suppress fades when crossfade on exit code");

    string fc = extract_filter_complex (runner.get_last_ffmpeg_argv_for_widget_test ());
    assert_true (fc.index_of ("afade") < 0,
        "afade is suppressed when crossfade is enabled");
}

// ═════════════════════════════════════════════════════════════════════════════
//  NORMALIZATION TESTS
// ═════════════════════════════════════════════════════════════════════════════

private void test_combine_peak_normalization_triggers_analysis () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    var runner = make_capture_runner (files);
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    var ap = new AudioProcessingSettingsSnapshot ();
    ap.normalize_enabled = true;
    ap.normalize_ebu = false;  // peak normalization
    profile.audio_processing = ap;
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "peak analysis exit code");

    assert_true (runner.get_peak_analysis_ran_for_widget_test (),
        "peak normalization triggers analysis pass");

    string[] peak_argv = runner.get_last_peak_analysis_argv_for_widget_test ();
    string peak_fc = extract_filter_complex (peak_argv);
    assert_contains (peak_fc, "volumedetect",
        "peak analysis uses volumedetect");
    assert_contains (peak_fc, "concat=",
        "peak analysis uses concat when crossfade off");
}

private void test_combine_peak_normalization_skips_when_audio_disabled () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080,
        "30/1", "yuv420p", "1:1", false));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080,
        "30/1", "yuv420p", "1:1", false));

    var runner = make_capture_runner (files);
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    var ap = new AudioProcessingSettingsSnapshot ();
    ap.normalize_enabled = true;
    ap.normalize_ebu = false;
    profile.audio_processing = ap;
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "peak skip no audio exit code");

    assert_false (runner.get_peak_analysis_ran_for_widget_test (),
        "peak normalization skips when no audio");
}

private void test_combine_peak_normalization_skips_when_profile_audio_disabled () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    var runner = make_capture_runner (files);
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-an" };
    var ap = new AudioProcessingSettingsSnapshot ();
    ap.normalize_enabled = true;
    ap.normalize_ebu = false;
    profile.audio_processing = ap;
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "peak skip -an exit code");

    assert_false (runner.get_peak_analysis_ran_for_widget_test (),
        "peak normalization skips when profile has -an");

    string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();
    string fc = extract_filter_complex (argv);
    assert_array_contains (argv, "-an",
        "profile -an disables audio output");
    assert_array_not_contains (argv, "[outa]",
        "profile -an does not map audio output");
    assert_contains (fc, "concat=n=2:v=1:a=0[outv]",
        "profile -an concat graph disables audio output");
    assert_true (fc.index_of ("[0:a:0]") < 0,
        "profile -an does not build per-input audio chains");
}

private void test_combine_peak_analysis_cleanup_on_cancel_with_chapters () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    string reencode_root = Path.build_filename (
        ConversionUtils.get_app_temp_root (), "combine", "reencode");
    int before_count = count_directories_in_path (reencode_root);

    var runner = make_capture_runner (files);
    runner.generate_chapters = true;
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    var ap = new AudioProcessingSettingsSnapshot ();
    ap.normalize_enabled = true;
    ap.normalize_ebu = false;
    profile.audio_processing = ap;
    runner.reencode_profile = profile;

    runner.cancel ();
    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 1, "cancelled peak-analysis path exit code");

    int after_count = count_directories_in_path (reencode_root);
    if (after_count != before_count) {
        Test.fail_printf (
            "cancelled peak-analysis path leaked temp dirs: before=%d after=%d",
            before_count, after_count);
    }
}

private void test_combine_chapter_write_failure_cleans_temp_dir () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    string reencode_root = Path.build_filename (
        ConversionUtils.get_app_temp_root (), "combine", "reencode");
    int before_count = count_directories_in_path (reencode_root);

    var runner = make_capture_runner (files);
    runner.generate_chapters = true;
    runner.force_write_chapters_file_failure_for_widget_test ();

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == -1, "chapter write failure exit code");

    int after_count = count_directories_in_path (reencode_root);
    if (after_count != before_count) {
        Test.fail_printf (
            "chapter write failure leaked temp dirs: before=%d after=%d",
            before_count, after_count);
    }
}

private void test_combine_peak_normalization_uses_acrossfade_when_crossfade_on () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 10.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 8.0, 1920, 1080));

    var runner = make_capture_runner (files);
    runner.crossfade_enabled = true;
    runner.crossfade_duration = 0.5;
    runner.crossfade_type = "fade";
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    var ap = new AudioProcessingSettingsSnapshot ();
    ap.normalize_enabled = true;
    ap.normalize_ebu = false;
    profile.audio_processing = ap;
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "peak crossfade exit code");

    string[] peak_argv = runner.get_last_peak_analysis_argv_for_widget_test ();
    string peak_fc = extract_filter_complex (peak_argv);
    assert_contains (peak_fc, "acrossfade",
        "peak analysis uses acrossfade when crossfade on");
}

private void test_combine_peak_normalization_includes_output_args () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    var runner = make_capture_runner (files);
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k", "-ac", "2" };
    var ap = new AudioProcessingSettingsSnapshot ();
    ap.normalize_enabled = true;
    ap.normalize_ebu = false;
    profile.audio_processing = ap;
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "peak output args exit code");

    string[] peak_argv = runner.get_last_peak_analysis_argv_for_widget_test ();
    assert_array_has_adjacent_pair (peak_argv, "-ac", "2",
        "peak analysis includes -ac output arg for accurate measurement");
}

private void test_combine_peak_analysis_filter_complex_executes () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    var runner = make_capture_runner (files);
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    var ap = new AudioProcessingSettingsSnapshot ();
    ap.normalize_enabled = true;
    ap.normalize_ebu = false;
    profile.audio_processing = ap;
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "peak exec smoke exit code");

    string[] peak_argv = runner.get_last_peak_analysis_argv_for_widget_test ();
    string peak_fc = extract_filter_complex (peak_argv);

    string? dir = null;
    try {
        dir = DirUtils.make_tmp ("combine-peak-exec-XXXXXX");
    } catch (FileError e) {
        Test.fail_printf ("failed to create peak exec temp dir: %s", e.message);
    }

    string first = make_exec_test_media_file (dir, "first.mkv");
    string second = make_exec_test_media_file (dir, "second.mkv");
    try {
        assert_filter_complex_executes_with_media_inputs (
            { first, second }, peak_fc, false, true,
            "peak analysis filter_complex executes");
    } finally {
        cleanup_exec_test_dir (dir);
    }
}

private void test_combine_ebu_normalization_applies_post_concat () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    var runner = make_capture_runner (files);
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    var ap = new AudioProcessingSettingsSnapshot ();
    ap.normalize_enabled = true;
    ap.normalize_ebu = true;
    profile.audio_processing = ap;
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "ebu post concat exit code");

    string fc = extract_filter_complex (runner.get_last_ffmpeg_argv_for_widget_test ());
    assert_contains (fc, "loudnorm=",
        "EBU normalization present in filter_complex");
    assert_contains (fc, "[outa_pre]",
        "EBU normalization applied post-combine via outa_pre");
}

private void test_combine_ebu_filter_complex_executes () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    var runner = make_capture_runner (files);
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    var ap = new AudioProcessingSettingsSnapshot ();
    ap.normalize_enabled = true;
    ap.normalize_ebu = true;
    profile.audio_processing = ap;
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "ebu exec smoke exit code");

    string fc = extract_filter_complex (runner.get_last_ffmpeg_argv_for_widget_test ());

    string? dir = null;
    try {
        dir = DirUtils.make_tmp ("combine-ebu-exec-XXXXXX");
    } catch (FileError e) {
        Test.fail_printf ("failed to create ebu exec temp dir: %s", e.message);
    }

    string first = make_exec_test_media_file (dir, "first.mkv");
    string second = make_exec_test_media_file (dir, "second.mkv");
    try {
        assert_filter_complex_executes_with_media_inputs (
            { first, second }, fc, true, true,
            "EBU filter_complex executes");
    } finally {
        cleanup_exec_test_dir (dir);
    }
}

private void test_combine_ebu_normalization_applies_post_acrossfade () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 10.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 8.0, 1920, 1080));

    var runner = make_capture_runner (files);
    runner.crossfade_enabled = true;
    runner.crossfade_duration = 0.5;
    runner.crossfade_type = "fade";
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    var ap = new AudioProcessingSettingsSnapshot ();
    ap.normalize_enabled = true;
    ap.normalize_ebu = true;
    profile.audio_processing = ap;
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "ebu post acrossfade exit code");

    string fc = extract_filter_complex (runner.get_last_ffmpeg_argv_for_widget_test ());
    assert_contains (fc, "acrossfade",
        "crossfade is present");
    assert_contains (fc, "loudnorm=",
        "EBU normalization present post-acrossfade");
    assert_contains (fc, "[outa_pre]",
        "EBU normalization applied post-acrossfade via outa_pre");
}

// ═════════════════════════════════════════════════════════════════════════════
//  SILENCE INPUT TESTS
// ═════════════════════════════════════════════════════════════════════════════

private void test_combine_reencode_silence_input_excludes_normalization () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 3.0, 1920, 1080,
        "30/1", "yuv420p", "1:1", false));

    var runner = make_capture_runner (files);
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    var ap = new AudioProcessingSettingsSnapshot ();
    ap.normalize_enabled = true;
    ap.normalize_ebu = true;
    profile.audio_processing = ap;
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "silence excludes normalization exit code");

    string fc = extract_filter_complex (runner.get_last_ffmpeg_argv_for_widget_test ());
    // Silence input should use anullsrc, not normalization
    assert_contains (fc, "anullsrc=channel_layout=stereo:sample_rate=48000[silence1]",
        "silence input still uses anullsrc");
    assert_contains (fc, "[silence1]atrim=duration=3.000000,asetpts=PTS-STARTPTS[a1]",
        "silence input keeps simple atrim chain without normalization");
}

// ═════════════════════════════════════════════════════════════════════════════
//  CROSSFADE WITH FULL PROFILE TESTS
// ═════════════════════════════════════════════════════════════════════════════

private void test_combine_reencode_strips_video_speed_filter () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 10.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 8.0, 1920, 1080));

    var runner = make_capture_runner (files);
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    // Simulates General tab with hflip + speed filter
    profile.video_filters_skip_crop = "hflip,setpts=0.500000*PTS";
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "strip video speed exit code");

    string fc = extract_filter_complex (runner.get_last_ffmpeg_argv_for_widget_test ());
    // hflip should be kept, speed setpts should be stripped
    assert_contains (fc, "hflip,setsar=1",
        "non-speed video filters are kept");
    assert_true (fc.index_of ("0.500000*PTS") < 0,
        "video speed setpts filter is stripped from combine");
}

private void test_combine_reencode_strips_audio_speed_filter () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 10.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 8.0, 1920, 1080));

    var runner = make_capture_runner (files);
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    profile.audio_filters = "atempo=1.500000";
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "strip audio speed exit code");

    string fc = extract_filter_complex (runner.get_last_ffmpeg_argv_for_widget_test ());
    assert_true (fc.index_of ("atempo") < 0,
        "audio speed atempo filter is stripped from combine");
}

private void test_strip_video_speed_filters_unit () {
    assert_string_equal (
        CombineRunner.strip_video_speed_filters ("hflip,setpts=0.500000*PTS,format=yuv420p"),
        "hflip,format=yuv420p",
        "strips setpts speed and keeps other filters");
    assert_string_equal (
        CombineRunner.strip_video_speed_filters ("setpts=0.500000*PTS"),
        "",
        "strips lone speed filter to empty");
    assert_string_equal (
        CombineRunner.strip_video_speed_filters ("hflip"),
        "hflip",
        "preserves non-speed filter unchanged");
    assert_string_equal (
        CombineRunner.strip_video_speed_filters (""),
        "",
        "handles empty string");
}

private void test_strip_audio_speed_filters_unit () {
    assert_string_equal (
        CombineRunner.strip_audio_speed_filters ("atempo=1.500000"),
        "",
        "strips lone atempo to empty");
    assert_string_equal (
        CombineRunner.strip_audio_speed_filters ("atempo=2.0,atempo=1.250000"),
        "",
        "strips chained atempo filters");
    assert_string_equal (
        CombineRunner.strip_audio_speed_filters (""),
        "",
        "handles empty string");
}

private void test_combine_crossfade_with_full_profile_video_filters () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 10.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 8.0, 1920, 1080));

    var runner = make_capture_runner (files);
    runner.crossfade_enabled = true;
    runner.crossfade_duration = 0.5;
    runner.crossfade_type = "fade";
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    profile.video_filters_skip_crop = "hflip";
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "crossfade video filters exit code");

    string fc = extract_filter_complex (runner.get_last_ffmpeg_argv_for_widget_test ());
    assert_contains (fc, "hflip,setsar=1",
        "video filters applied in crossfade mode");
    assert_contains (fc, "xfade=",
        "crossfade still works with video filters");
}

private void test_combine_crossfade_with_full_profile_audio_filters () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 10.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 8.0, 1920, 1080));

    var runner = make_capture_runner (files);
    runner.crossfade_enabled = true;
    runner.crossfade_duration = 0.5;
    runner.crossfade_type = "fade";
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    // Use a non-speed audio filter (speed filters are stripped in combine)
    profile.audio_filters = "aecho=0.8:0.88:60:0.4";
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "crossfade audio filters exit code");

    string fc = extract_filter_complex (runner.get_last_ffmpeg_argv_for_widget_test ());
    assert_contains (fc, "aecho=0.8:0.88:60:0.4",
        "non-speed audio filters applied in crossfade mode");
    assert_contains (fc, "acrossfade",
        "acrossfade still works with audio filters");
}

// ═════════════════════════════════════════════════════════════════════════════
//  HELPER: Create a fade snapshot for constraint tests
// ═════════════════════════════════════════════════════════════════════════════

private AudioProcessingSettingsSnapshot create_fade_snapshot () {
    var snapshot = new AudioProcessingSettingsSnapshot ();
    snapshot.fade_in_enabled = true;
    snapshot.fade_in_duration = 1.5;
    snapshot.fade_out_enabled = true;
    snapshot.fade_out_duration = 2.0;
    return snapshot;
}

private void assert_codec_tab_container_defaults (ContainerDefaultMode mode,
                                                  string expected_svt,
                                                  string expected_vp9,
                                                  string expected_x264,
                                                  string expected_x265,
                                                  string context) {
    if (!ensure_gtk_widget_tests_available ()) {
        return;
    }

    var settings = AppSettings.get_default ();
    ContainerDefaultMode previous_mode = settings.container_default_mode;

    try {
        settings.container_default_mode = mode;

        var svt = new SvtAv1Tab ();
        var vp9 = new Vp9Tab ();
        var x264 = new X264Tab ();
        var x265 = new X265Tab ();

        assert_string_equal (svt.get_container (), expected_svt,
            @"$context initial svt-av1 container");
        assert_string_equal (vp9.get_container (), expected_vp9,
            @"$context initial vp9 container");
        assert_string_equal (x264.get_container (), expected_x264,
            @"$context initial x264 container");
        assert_string_equal (x265.get_container (), expected_x265,
            @"$context initial x265 container");

        svt.container_combo.set_selected (0);
        vp9.container_combo.set_selected (1);
        x264.container_combo.set_selected (0);
        x265.container_combo.set_selected (0);

        svt.reset_defaults ();
        vp9.reset_defaults ();
        x264.reset_defaults ();
        x265.reset_defaults ();

        assert_string_equal (svt.get_container (), expected_svt,
            @"$context reset svt-av1 container");
        assert_string_equal (vp9.get_container (), expected_vp9,
            @"$context reset vp9 container");
        assert_string_equal (x264.get_container (), expected_x264,
            @"$context reset x264 container");
        assert_string_equal (x265.get_container (), expected_x265,
            @"$context reset x265 container");
    } finally {
        settings.container_default_mode = previous_mode;
    }
}

private void test_codec_tab_container_preference_applies_on_construction_and_reset () {
    assert_codec_tab_container_defaults (
        ContainerDefaultMode.DEFAULT,
        ContainerExt.MKV,
        ContainerExt.WEBM,
        ContainerExt.MKV,
        ContainerExt.MKV,
        "default mode"
    );

    assert_codec_tab_container_defaults (
        ContainerDefaultMode.MKV,
        ContainerExt.MKV,
        ContainerExt.MKV,
        ContainerExt.MKV,
        ContainerExt.MKV,
        "mkv mode"
    );

    assert_codec_tab_container_defaults (
        ContainerDefaultMode.CODEC_SPECIFIC,
        ContainerExt.WEBM,
        ContainerExt.WEBM,
        ContainerExt.MP4,
        ContainerExt.MP4,
        "codec-specific mode"
    );
}

private void test_codec_tab_container_preference_updates_live_on_settings_change () {
    if (!ensure_gtk_widget_tests_available ()) {
        return;
    }

    var settings = AppSettings.get_default ();
    ContainerDefaultMode previous_mode = settings.container_default_mode;

    try {
        settings.container_default_mode = ContainerDefaultMode.DEFAULT;

        var svt = new SvtAv1Tab ();
        var vp9 = new Vp9Tab ();
        var x264 = new X264Tab ();
        var x265 = new X265Tab ();

        assert_string_equal (svt.get_container (), ContainerExt.MKV,
            "live update initial svt-av1 container");
        assert_string_equal (vp9.get_container (), ContainerExt.WEBM,
            "live update initial vp9 container");
        assert_string_equal (x264.get_container (), ContainerExt.MKV,
            "live update initial x264 container");
        assert_string_equal (x265.get_container (), ContainerExt.MKV,
            "live update initial x265 container");

        settings.container_default_mode = ContainerDefaultMode.CODEC_SPECIFIC;
        settings.settings_changed ();

        assert_string_equal (svt.get_container (), ContainerExt.WEBM,
            "live update svt-av1 container");
        assert_string_equal (vp9.get_container (), ContainerExt.WEBM,
            "live update vp9 container");
        assert_string_equal (x264.get_container (), ContainerExt.MP4,
            "live update x264 container");
        assert_string_equal (x265.get_container (), ContainerExt.MP4,
            "live update x265 container");

        settings.container_default_mode = ContainerDefaultMode.MKV;
        settings.settings_changed ();

        assert_string_equal (svt.get_container (), ContainerExt.MKV,
            "live update mkv svt-av1 container");
        assert_string_equal (vp9.get_container (), ContainerExt.MKV,
            "live update mkv vp9 container");
        assert_string_equal (x264.get_container (), ContainerExt.MKV,
            "live update mkv x264 container");
        assert_string_equal (x265.get_container (), ContainerExt.MKV,
            "live update mkv x265 container");
    } finally {
        settings.container_default_mode = previous_mode;
        settings.settings_changed ();
    }
}

void main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/combine/widgets/move-up-button",
        test_move_up_button_reorders_files);
    Test.add_func ("/combine/widgets/preview-hides-popout-button",
        test_combine_preview_hides_popout_button);
    Test.add_func ("/combine/file-pickers/combine-lock-clears-and-disables-input",
        test_file_pickers_combine_lock_clears_and_disables_input);
    Test.add_func ("/combine/information/clears-stale-input-when-removed",
        test_information_tab_clears_stale_input_when_input_removed);
    Test.add_func ("/combine/information/output-hides-input-and-shows-summary",
        test_information_tab_combine_output_hides_input_and_shows_summary);
    Test.add_func ("/combine/runner/done-result-marks-source-and-summary",
        test_combine_done_result_marks_source_and_summary);
    Test.add_func ("/combine/runner/cancelled-relay",
        test_runner_binding_relays_cancelled_signal);
    Test.add_func ("/combine/overwrite/main-window-cancel-ignores-stale-callback",
        test_pending_overwrite_cancelled_by_main_window_is_ignored);
    Test.add_func ("/combine/overwrite/real-dialog-dismiss-returns-cancel-response",
        test_pending_overwrite_real_dialog_dismiss_returns_cancel_response);
    Test.add_func ("/combine/probe/reordered-row-identity",
        test_probe_completion_updates_reordered_file_row);
    Test.add_func ("/combine/runner/copy-command-maps-primary-streams",
        test_copy_command_maps_primary_video_and_audio);
    Test.add_func ("/combine/runner/copy-command-omits-metadata-when-disabled",
        test_copy_command_omits_metadata_when_preserve_metadata_disabled);
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
    Test.add_func ("/combine/window/reencode-subtitle-describes-compatible-general-settings",
        test_reencode_codec_subtitle_describes_supported_general_settings);
    Test.add_func ("/combine/overwrite/freezes-launch-file-list",
        test_pending_overwrite_freezes_launch_file_list);
    Test.add_func ("/combine/window/uses-live-main-output-folder",
        test_combine_uses_live_main_output_folder);
    Test.add_func ("/combine/window/idle-close-cancels-pending-probes",
        test_idle_close_request_cancels_pending_probes);
    Test.add_func ("/combine/codec-tabs/container-preference-defaults",
        test_codec_tab_container_preference_applies_on_construction_and_reset);
    Test.add_func ("/combine/codec-tabs/container-preference-live-update",
        test_codec_tab_container_preference_updates_live_on_settings_change);

    // Chapter metadata tests
    Test.add_func ("/combine/chapters/escape-ffmetadata-value",
        test_escape_ffmetadata_value);
    Test.add_func ("/combine/chapters/metadata-content-basic",
        test_chapters_metadata_content_basic);
    Test.add_func ("/combine/chapters/metadata-content-with-crossfade",
        test_chapters_metadata_content_with_crossfade);
    Test.add_func ("/combine/chapters/copy-mode-args",
        test_chapters_copy_mode_args);
    Test.add_func ("/combine/chapters/reencode-mode-args",
        test_chapters_reencode_mode_args);
    Test.add_func ("/combine/chapters/disabled-remove-chapters-copy",
        test_chapters_disabled_remove_chapters_copy);
    Test.add_func ("/combine/chapters/disabled-remove-chapters-reencode",
        test_chapters_disabled_remove_chapters_reencode);
    Test.add_func ("/combine/chapters/generate-overrides-remove",
        test_chapters_generate_overrides_remove);
    Test.add_func ("/combine/chapters/both-disabled",
        test_chapters_both_disabled);

    // Crossfade tests
    Test.add_func ("/combine/crossfade/two-files-filter",
        test_crossfade_two_files_filter);
    Test.add_func ("/combine/crossfade/three-files-filter",
        test_crossfade_three_files_filter);
    Test.add_func ("/combine/crossfade/disabled-uses-concat",
        test_crossfade_disabled_uses_concat);
    Test.add_func ("/combine/crossfade/no-audio",
        test_crossfade_no_audio);
    Test.add_func ("/combine/crossfade/settb-in-filter",
        test_crossfade_settb_in_filter);
    Test.add_func ("/combine/crossfade/with-chapters",
        test_crossfade_with_chapters);

    // Full profile tests
    Test.add_func ("/combine/profile/video-filters",
        test_combine_reencode_applies_general_video_filters);
    Test.add_func ("/combine/profile/post-output-scale-separation",
        test_combine_reencode_post_output_scale_is_separate_from_input_normalization);
    Test.add_func ("/combine/profile/crossfade-post-output-video-filters",
        test_combine_crossfade_applies_post_output_video_filters);
    Test.add_func ("/combine/profile/direct-outv-without-post-output-filters",
        test_combine_reencode_without_post_output_filters_keeps_direct_outv_label);
    Test.add_func ("/combine/profile/strips-speed-setpts",
        test_combine_reencode_strips_speed_setpts_from_video_filters);
    Test.add_func ("/combine/profile/audio-filters",
        test_combine_reencode_applies_audio_filters);
    Test.add_func ("/combine/profile/audio-processing-chain",
        test_combine_reencode_applies_audio_processing_chain);
    Test.add_func ("/combine/profile/audio-copy-fallback",
        test_combine_reencode_preserves_audio_copy_fallback);

    // Audio copy constraint tests
    Test.add_func ("/combine/audio-copy/reencode-syncs-all-codec-tabs",
        test_combine_reencode_syncs_audio_copy_constraint_across_codec_tabs);
    Test.add_func ("/combine/audio-copy/close-releases-constraint",
        test_closing_combine_window_releases_audio_copy_constraint);

    // Audio status override tests
    Test.add_func ("/combine/audio-badge/reencode-sets-override",
        test_combine_reencode_sets_audio_badge_override_across_codec_tabs);
    Test.add_func ("/combine/audio-badge/close-clears-override",
        test_closing_combine_clears_audio_badge_override);
    Test.add_func ("/combine/audio-badge/copy-mode-with-audio-shows-copy-badge",
        test_combine_copy_mode_with_audio_shows_copy_badge);
    Test.add_func ("/combine/audio-badge/copy-mode-without-audio-clears-badge",
        test_combine_copy_mode_without_audio_clears_badge);
    Test.add_func ("/combine/audio-badge/pending-probe-lifecycle",
        test_combine_copy_badge_follows_pending_probe_lifecycle);

    // General speed constraint tests
    Test.add_func ("/combine/general-speed/reencode-applies-constraint",
        test_reencode_mode_applies_general_speed_constraint);
    Test.add_func ("/combine/general-speed/copy-releases-and-restores",
        test_copy_mode_releases_general_speed_constraint_and_restores_state);
    Test.add_func ("/combine/general-speed/close-restores-state",
        test_closing_combine_window_restores_general_speed_state);
    Test.add_func ("/combine/general-speed/preserves-unrelated-general-settings",
        test_general_speed_constraint_preserves_unrelated_general_settings);
    Test.add_func ("/combine/general-speed/launch-omits-speed-filters",
        test_combine_launch_snapshot_omits_general_speed_filters_when_constrained);

    // General crop constraint tests
    Test.add_func ("/combine/general-crop/reencode-applies-constraint",
        test_reencode_mode_applies_general_crop_constraint);
    Test.add_func ("/combine/general-crop/copy-releases-and-restores",
        test_copy_mode_releases_general_crop_constraint_and_restores_state);
    Test.add_func ("/combine/general-crop/close-restores-state",
        test_closing_combine_window_restores_general_crop_state);
    Test.add_func ("/combine/general-crop/trim-lock-survives-release",
        test_combine_crop_constraint_does_not_override_trim_crop_lock);
    Test.add_func ("/combine/general-crop/launch-omits-crop-filter",
        test_combine_launch_snapshot_omits_general_crop_filter_when_constrained);

    // General timing constraint tests
    Test.add_func ("/combine/general-timing/open-applies-constraint",
        test_combine_open_applies_general_timing_constraint);
    Test.add_func ("/combine/general-timing/close-restores-state",
        test_closing_combine_window_restores_general_timing_state);
    Test.add_func ("/combine/general-timing/trim-lock-survives-release",
        test_combine_timing_constraint_does_not_override_trim_timing_lock);

    // Fade/crossfade UI constraint tests
    Test.add_func ("/combine/constraint/crossfade-clears-and-disables-fades",
        test_crossfade_enabling_clears_and_disables_fades);
    Test.add_func ("/combine/constraint/crossfade-disabling-reenables",
        test_crossfade_disabling_reenables_fades);
    Test.add_func ("/combine/constraint/codec-switch-moves-constraint",
        test_crossfade_codec_switch_moves_constraint);
    Test.add_func ("/combine/constraint/copy-mode-on-releases",
        test_copy_mode_on_releases_crossfade_constraint);
    Test.add_func ("/combine/constraint/copy-mode-off-reapplies",
        test_copy_mode_off_reapplies_crossfade_constraint);
    Test.add_func ("/combine/constraint/disabling-restores-fade-state",
        test_crossfade_disabling_restores_fade_state);
    Test.add_func ("/combine/constraint/close-restores-fade-state",
        test_closing_combine_window_restores_fade_state);
    Test.add_func ("/combine/constraint/release-preserves-non-fade-changes",
        test_crossfade_release_preserves_non_fade_changes);
    Test.add_func ("/combine/constraint/close-releases",
        test_closing_combine_window_releases_constraint);

    // Runner fade behavior
    Test.add_func ("/combine/runner/allows-fades-when-crossfade-off",
        test_combine_runner_allows_fades_when_crossfade_off);
    Test.add_func ("/combine/runner/suppresses-afade-when-crossfade-on",
        test_combine_runner_suppresses_afade_when_crossfade_on);

    // Normalization tests
    Test.add_func ("/combine/normalization/peak-triggers-analysis",
        test_combine_peak_normalization_triggers_analysis);
    Test.add_func ("/combine/normalization/peak-skips-no-audio",
        test_combine_peak_normalization_skips_when_audio_disabled);
    Test.add_func ("/combine/normalization/peak-skips-profile-audio-disabled",
        test_combine_peak_normalization_skips_when_profile_audio_disabled);
    Test.add_func ("/combine/normalization/peak-cleanup-on-cancel-with-chapters",
        test_combine_peak_analysis_cleanup_on_cancel_with_chapters);
    Test.add_func ("/combine/chapters/write-failure-cleans-temp-dir",
        test_combine_chapter_write_failure_cleans_temp_dir);
    Test.add_func ("/combine/normalization/peak-uses-acrossfade",
        test_combine_peak_normalization_uses_acrossfade_when_crossfade_on);
    Test.add_func ("/combine/normalization/peak-includes-output-args",
        test_combine_peak_normalization_includes_output_args);
    Test.add_func ("/combine/normalization/peak-filter-complex-executes",
        test_combine_peak_analysis_filter_complex_executes);
    Test.add_func ("/combine/normalization/ebu-post-concat",
        test_combine_ebu_normalization_applies_post_concat);
    Test.add_func ("/combine/normalization/ebu-filter-complex-executes",
        test_combine_ebu_filter_complex_executes);
    Test.add_func ("/combine/normalization/ebu-post-acrossfade",
        test_combine_ebu_normalization_applies_post_acrossfade);

    // Silence input tests
    Test.add_func ("/combine/silence/excludes-normalization",
        test_combine_reencode_silence_input_excludes_normalization);

    // Speed filter stripping
    Test.add_func ("/combine/speed/strip-video-speed-filter",
        test_combine_reencode_strips_video_speed_filter);
    Test.add_func ("/combine/speed/strip-audio-speed-filter",
        test_combine_reencode_strips_audio_speed_filter);
    Test.add_func ("/combine/speed/strip-video-speed-unit",
        test_strip_video_speed_filters_unit);
    Test.add_func ("/combine/speed/strip-audio-speed-unit",
        test_strip_audio_speed_filters_unit);

    // Crossfade with full profile
    Test.add_func ("/combine/crossfade/with-video-filters",
        test_combine_crossfade_with_full_profile_video_filters);
    Test.add_func ("/combine/crossfade/with-audio-filters",
        test_combine_crossfade_with_full_profile_audio_filters);

    Test.run ();
}
