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

// Compositor transitions are wall-clock operations. The broad state-test
// helper above deliberately counts main-loop turns, which can complete much
// faster than its numeric argument when a frame clock is active.
private bool spin_main_context_until_deadline (owned SourceFunc done,
                                               int timeout_ms) {
    MainContext context = MainContext.default ();
    int64 deadline = get_monotonic_time () + (timeout_ms * TimeSpan.MILLISECOND);

    while (get_monotonic_time () < deadline) {
        while (context.pending ()) {
            context.iteration (false);
        }
        if (done ()) {
            return true;
        }
        Thread.usleep (1000);
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

/**
 * Assert that @earlier appears before the first @later.
 *
 * FFmpeg reads its command line positionally, so for some options the
 * difference between input and output semantics is nothing but which side of
 * -i they land on.
 */
private void assert_array_option_precedes (string[] values,
                                           string earlier,
                                           string later,
                                           string context) {
    int earlier_index = -1;
    int later_index = -1;

    for (int i = 0; i < values.length; i++) {
        if (earlier_index < 0 && values[i] == earlier) earlier_index = i;
        if (later_index < 0 && values[i] == later) later_index = i;
    }

    if (earlier_index < 0) {
        Test.fail_printf ("%s expected '%s' to be present", context, earlier);
        return;
    }
    if (later_index < 0) {
        Test.fail_printf ("%s expected '%s' to be present", context, later);
        return;
    }
    if (earlier_index > later_index) {
        Test.fail_printf ("%s expected '%s' before '%s'",
            context, earlier, later);
    }
}

/** The argument following @option, or "" when the option is absent. */
private string get_argv_value_after (string[] values,
                                     string option,
                                     string context) {
    for (int i = 0; i < values.length - 1; i++) {
        if (values[i] == option) {
            return values[i + 1];
        }
    }

    Test.fail_printf ("%s expected '%s' to carry a value", context, option);
    return "";
}

private void assert_array_occurrence_count (string[] values,
                                            string expected,
                                            int expected_count,
                                            string context) {
    int actual_count = 0;
    foreach (string value in values) {
        if (value == expected) {
            actual_count++;
        }
    }

    if (actual_count != expected_count) {
        Test.fail_printf ("%s expected '%s' %d time(s) but found %d",
            context, expected, expected_count, actual_count);
    }
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

private ConversionRunner make_conversion_runner_for_test (EncodeProfileSnapshot profile,
                                                          double source_span_seconds = 1.0,
                                                          bool topology_known = true,
                                                          bool has_subtitles = false,
                                                          bool has_chapters = false) {
    var config = new ConversionConfig ();
    config.profile = profile;
    config.source_span_seconds = source_span_seconds;
    config.timed_stream_topology_known = topology_known;
    config.input_has_subtitle_stream = has_subtitles;
    config.input_has_chapters = has_chapters;
    return new ConversionRunner.for_command_test (config);
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

private string run_compute_output_path_async_for_test (string input_file,
                                                       string output_folder,
                                                       ICodecBuilder builder,
                                                       ICodecTab codec_tab,
                                                       string context) {
    var loop = new MainLoop (null, false);
    string? output_path = null;
    Error? async_error = null;

    Converter.compute_output_path_async.begin (
        input_file,
        output_folder,
        builder,
        codec_tab,
        null,
        (obj, res) => {
            try {
                output_path = Converter.compute_output_path_async.end (res);
            } catch (Error e) {
                async_error = e;
            }
            loop.quit ();
        }
    );

    loop.run ();

    if (async_error != null) {
        Test.fail_printf ("%s async output-path computation failed: %s",
            context, async_error.message);
    }
    if (output_path == null) {
        Test.fail_printf ("%s async output-path computation returned no result", context);
    }

    return output_path;
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

private string make_fake_svt_probe_ffmpeg (string dir,
                                           string filename,
                                           bool supports_crf_two_pass) {
    string path = Path.build_filename (dir, filename);
    string pass2_body = supports_crf_two_pass
        ? "    exit 0\n"
        : "    echo 'Svt[info]: probe started' >&2\n"
          + "    echo 'Svt[error]: CRF does not support multi-pass. Use single pass.' >&2\n"
          + "    exit 1\n";
    string script =
        "#!/bin/sh\n"
        + "pass=''\n"
        + "passlog=''\n"
        + "while [ \"$#\" -gt 0 ]; do\n"
        + "  case \"$1\" in\n"
        + "    -pass)\n"
        + "      shift\n"
        + "      pass=\"$1\"\n"
        + "      ;;\n"
        + "    -passlogfile)\n"
        + "      shift\n"
        + "      passlog=\"$1\"\n"
        + "      ;;\n"
        + "  esac\n"
        + "  shift\n"
        + "done\n"
        + "case \"$pass\" in\n"
        + "  1)\n"
        + "    if [ -n \"$passlog\" ]; then\n"
        + "      : > \"${passlog}-0.log\"\n"
        + "    fi\n"
        + "    exit 0\n"
        + "    ;;\n"
        + "  2)\n"
        + pass2_body
        + "    ;;\n"
        + "esac\n"
        + "echo 'missing -pass argument' >&2\n"
        + "exit 1\n";

    try {
        FileUtils.set_contents (path, script);
    } catch (FileError e) {
        Test.fail_printf ("failed to write fake ffmpeg probe script '%s': %s",
            path, e.message);
    }

    if (Posix.chmod (path, 0755) != 0) {
        Test.fail_printf ("failed to chmod fake ffmpeg probe script '%s'", path);
    }

    return path;
}

private string make_fake_svt_probe_ffmpeg_with_generic_error (string dir,
                                                              string filename) {
    string path = Path.build_filename (dir, filename);
    string script =
        "#!/bin/sh\n"
        + "pass=''\n"
        + "while [ \"$#\" -gt 0 ]; do\n"
        + "  case \"$1\" in\n"
        + "    -pass)\n"
        + "      shift\n"
        + "      pass=\"$1\"\n"
        + "      ;;\n"
        + "  esac\n"
        + "  shift\n"
        + "done\n"
        + "case \"$pass\" in\n"
        + "  1)\n"
        + "    exit 0\n"
        + "    ;;\n"
        + "  2)\n"
        + "    echo 'Svt[info]: probe started' >&2\n"
        + "    echo 'Error opening output files: Invalid argument' >&2\n"
        + "    exit 1\n"
        + "    ;;\n"
        + "esac\n"
        + "echo 'missing -pass argument' >&2\n"
        + "exit 1\n";

    try {
        FileUtils.set_contents (path, script);
    } catch (FileError e) {
        Test.fail_printf ("failed to write fake ffmpeg generic-error script '%s': %s",
            path, e.message);
    }

    if (Posix.chmod (path, 0755) != 0) {
        Test.fail_printf ("failed to chmod fake ffmpeg generic-error script '%s'", path);
    }

    return path;
}

private SvtAv1CrfTwoPassCapability run_svt_crf_two_pass_probe_for_test (string binary_path,
                                                                        string context) {
    var loop = new MainLoop (null, false);
    var cancellable = new Cancellable ();
    SvtAv1CrfTwoPassCapability? capability = null;
    Error? async_error = null;

    FfmpegRuntimeCapabilities.probe_svt_av1_crf_two_pass.begin (
        binary_path,
        cancellable,
        (obj, res) => {
            try {
                capability = FfmpegRuntimeCapabilities.probe_svt_av1_crf_two_pass.end (res);
            } catch (Error e) {
                async_error = e;
            }
            loop.quit ();
        }
    );

    loop.run ();

    if (async_error != null) {
        Test.fail_printf ("%s probe failed: %s", context, async_error.message);
    }
    if (capability == null) {
        Test.fail_printf ("%s probe returned no result", context);
    }

    return capability;
}

private string make_fake_vmaf_probe_ffmpeg (string dir,
                                             string filename,
                                             bool supports_vmaf,
                                             bool exits_successfully = true) {
    string path = Path.build_filename (dir, filename);
    string listing = supports_vmaf
        ? " .. libvmaf           VV->V      Calculate VMAF\n"
          + " .. vmafmotion        V->V       Calculate VMAF Motion\n"
        : " .. vmafmotion        V->V       Calculate VMAF Motion\n";
    string script = "#!/bin/sh\n"
        + (exits_successfully
            ? "printf '%s' '" + listing + "'\nexit 0\n"
            : "echo 'configured ffmpeg failed' >&2\nexit 1\n");

    try {
        FileUtils.set_contents (path, script);
    } catch (FileError e) {
        Test.fail_printf ("failed to write fake VMAF probe script '%s': %s",
            path, e.message);
    }

    if (Posix.chmod (path, 0755) != 0)
        Test.fail_printf ("failed to chmod fake VMAF probe script '%s'", path);
    return path;
}

private VmafCapability run_vmaf_probe_for_test (string binary_path,
                                                 string context) {
    var loop = new MainLoop (null, false);
    var cancellable = new Cancellable ();
    VmafCapability? capability = null;
    Error? async_error = null;

    FfmpegRuntimeCapabilities.probe_vmaf.begin (
        binary_path,
        cancellable,
        (obj, res) => {
            try {
                capability = FfmpegRuntimeCapabilities.probe_vmaf.end (res);
            } catch (Error e) {
                async_error = e;
            }
            loop.quit ();
        }
    );
    loop.run ();

    if (async_error != null)
        Test.fail_printf ("%s probe failed: %s", context, async_error.message);
    if (capability == null)
        Test.fail_printf ("%s probe returned no result", context);
    return capability;
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
        Test.skip ("GTK could not initialize");
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

private class OutputPathCodecBuilder : Object, ICodecBuilder {
    private string codec_name;

    public OutputPathCodecBuilder (string codec_name) {
        this.codec_name = codec_name;
    }

    public string get_codec_name () {
        return codec_name;
    }

    public Object? snapshot_settings (GeneralSettingsSnapshot? general_settings = null) {
        return null;
    }

    public string[] build_codec_args_from_snapshot (Object? snapshot) {
        return {};
    }

    public string[] get_codec_args () {
        return {};
    }
}

private class OutputPathCodecTab : Object, ICodecTab {
    private string container;
    private ICodecBuilder builder;

    public OutputPathCodecTab (string codec_name, string container) {
        this.container = container;
        this.builder = new OutputPathCodecBuilder (codec_name);
    }

    public ICodecBuilder get_codec_builder () {
        return builder;
    }

    public bool get_two_pass () {
        return false;
    }

    public string get_container () {
        return container;
    }

    public CodecTabSettingsSnapshot snapshot_settings (
        GeneralSettingsSnapshot? general_settings = null) {
        var snapshot = new CodecTabSettingsSnapshot ();
        snapshot.container = container;
        return snapshot;
    }

    public KeyframeSettingsSnapshot snapshot_keyframe_settings (
        GeneralSettingsSnapshot? general_settings) {
        return new KeyframeSettingsSnapshot ();
    }

    public string[] get_audio_args () {
        return {};
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

private void test_information_tab_png_output_hides_frame_rate_and_uses_image_codec_label () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var info_tab = new InformationTab ();
    var info = new VideoInfo ();
    info.filename = "sample-collage.png";
    info.container = "PNG";
    info.duration = "N/A";
    info.video_codec = "png";
    info.resolution = "1920 x 810";
    info.frame_rate = "25 fps";
    info.pix_fmt = "rgb24";
    info.file_size = "1.88 MB";

    info_tab.populate_output_for_widget_test (info);

    assert_false (
        info_tab.is_output_frame_rate_visible_for_widget_test (),
        "still-image outputs hide the frame rate row"
    );
    assert_string_equal (
        info_tab.get_output_codec_title_for_widget_test (),
        "Image Codec",
        "still-image outputs relabel codec as image codec"
    );
    assert_false (
        info_tab.build_output_summary_for_widget_test (info).contains ("fps"),
        "still-image summaries omit frame rate text"
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
    assert_true (
        harness.window.is_preview_fullscreen_visible_for_widget_test (),
        "combine preview keeps the independent fullscreen button visible");

    harness.window.close ();
}

private void test_video_player_fullscreen_control_state () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var player = new VideoPlayer ();
    int request_count = 0;
    player.fullscreen_requested.connect (() => {
        request_count++;
    });

    var icon_theme = Gtk.IconTheme.get_for_display (Gdk.Display.get_default ());
    assert_true (icon_theme.has_icon ("video-fullscreen-symbolic"),
        "custom fullscreen enter icon is registered");
    assert_true (icon_theme.has_icon ("video-unfullscreen-symbolic"),
        "custom fullscreen exit icon is registered");

    assert_true (player.is_fullscreen_visible_for_widget_test (),
        "video player exposes a dedicated fullscreen control");
    assert_string_equal (player.fullscreen_icon_for_widget_test (),
        "video-fullscreen-symbolic", "fullscreen starts with the custom enter icon");
    assert_string_equal (player.fullscreen_tooltip_for_widget_test (),
        "Enter fullscreen", "fullscreen starts with its enter tooltip");
    assert_false (player.picture_expands_for_widget_test (),
        "embedded video keeps its compact layout");
    assert_string_equal (player.popout_icon_for_widget_test (),
        "view-fullscreen-symbolic", "fullscreen does not replace the popout icon");
    assert_string_equal (player.fullscreen_shortcut_trigger_for_widget_test (),
        "F11", "fullscreen exposes the expected keyboard shortcut");
    assert_true (player.fullscreen_shortcut_is_global_for_widget_test (),
        "fullscreen shortcut works throughout the player window");

    player.click_fullscreen_for_widget_test ();
    assert_cmpint (request_count, CompareOperator.EQ, 1);
    assert_true (player.activate_fullscreen_shortcut_for_widget_test (),
        "fullscreen shortcut action activates");
    assert_cmpint (request_count, CompareOperator.EQ, 2);

    player.set_fullscreen_state (true);
    assert_string_equal (player.fullscreen_icon_for_widget_test (),
        "video-unfullscreen-symbolic", "fullscreen uses the custom exit icon");
    assert_string_equal (player.fullscreen_tooltip_for_widget_test (),
        "Exit fullscreen", "fullscreen exposes its exit action");
    assert_true (player.picture_expands_for_widget_test (),
        "fullscreen video expands into the available height");
    assert_string_equal (player.popout_icon_for_widget_test (),
        "view-fullscreen-symbolic", "fullscreen leaves the popout control unchanged");

    player.set_fullscreen_state (false);
    assert_string_equal (player.fullscreen_icon_for_widget_test (),
        "video-fullscreen-symbolic", "leaving fullscreen restores the enter icon");
    assert_false (player.picture_expands_for_widget_test (),
        "leaving fullscreen restores the compact layout");

    player.cleanup ();
}

private void test_video_player_fullscreen_shortcut_releases_player () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    VideoPlayer? player = new VideoPlayer ();
    var player_ref = WeakRef (player);
    player = null;

    assert_true (spin_main_context_until_deadline (() => {
        return player_ref.get () == null;
    }, 1000), "fullscreen shortcut does not retain its VideoPlayer");
}

private void test_combine_preview_player_releases_on_close () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var harness = new CombineWindowHarness ();
    for (int cycle = 0; cycle < 8; cycle++) {
        harness.window.create_preview_player_for_widget_test ();
        harness.window.present_preview_for_widget_test ();
        assert_true (spin_main_context_until_deadline (() => {
            return harness.window.preview_picture_height_for_widget_test () > 0;
        }, 2000), "combine preview maps before lifecycle close");

        var player_ref = WeakRef (
            harness.window.preview_player_for_widget_test ());
        harness.window.close_preview_for_widget_test ();
        assert_true (spin_main_context_until_deadline (() => {
            return !harness.window.has_preview_window_for_widget_test ()
                && player_ref.get () == null;
        }, 2000), "closed combine preview releases its VideoPlayer");
    }

    harness.window.close ();
}

private void test_combine_preview_fullscreen_window_state () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var harness = new CombineWindowHarness ();
    harness.window.create_preview_player_for_widget_test ();
    harness.window.present_preview_for_widget_test ();
    assert_true (spin_main_context_until_deadline (() => {
        return harness.window.preview_picture_height_for_widget_test () > 0;
    }, 2000), "combine preview receives an initial allocation");
    int normal_height = harness.window.preview_picture_height_for_widget_test ();

    harness.window.click_preview_fullscreen_for_widget_test ();
    assert_true (harness.window.is_preview_fullscreen_requested_for_widget_test (),
        "combine preview forwards the fullscreen request to its controller");
    if (!spin_main_context_until_deadline (() => {
        return harness.window.is_preview_window_fullscreen_for_widget_test ();
    }, 2000)) {
        Test.skip ("Compositor did not acknowledge the fullscreen request");
        harness.window.close ();
        return;
    }
    assert_false (harness.window.is_preview_header_visible_for_widget_test (),
        "combine preview hides window chrome in fullscreen");
    assert_true (harness.window.preview_picture_expands_for_widget_test (),
        "combine preview expands the picture after fullscreen is acknowledged");
    assert_true (spin_main_context_until_deadline (() => {
        return harness.window.preview_picture_height_for_widget_test () > normal_height;
    }, 2000), "fullscreen allocates more than the normal picture height");
    int fullscreen_height = harness.window.preview_picture_height_for_widget_test ();

    assert_true (harness.window.preview_escape_uses_capture_for_widget_test (),
        "combine Escape handler runs before crop-overlay key handling");
    assert_true (harness.window.request_preview_escape_for_widget_test (),
        "Escape is handled while the combine preview is fullscreen");
    assert_true (spin_main_context_until_deadline (() => {
        return !harness.window.is_preview_window_fullscreen_for_widget_test ()
            && !harness.window.is_preview_fullscreen_transition_pending_for_widget_test ();
    }, 2000), "combine preview leaves compositor fullscreen state");
    assert_true (harness.window.is_preview_header_visible_for_widget_test (),
        "combine preview restores window chrome after fullscreen");
    assert_false (harness.window.preview_picture_expands_for_widget_test (),
        "combine preview restores the compact picture layout");
    assert_true (spin_main_context_until_deadline (() => {
        int height = harness.window.preview_picture_height_for_widget_test ();
        return height > 0 && height < fullscreen_height;
    }, 2000), "leaving fullscreen restores a compact picture allocation");

    // Exercise the pending-state path: a second request made before the first
    // compositor response must target the desired state, not stale window state.
    harness.window.click_preview_fullscreen_for_widget_test ();
    harness.window.click_preview_fullscreen_for_widget_test ();
    assert_false (harness.window.is_preview_fullscreen_requested_for_widget_test (),
        "two rapid fullscreen requests cancel each other");
    bool rapid_toggle_settled = spin_main_context_until_deadline (() => {
        return !harness.window.is_preview_fullscreen_transition_pending_for_widget_test ()
            && !harness.window.is_preview_window_fullscreen_for_widget_test ();
    }, 2500);
    assert_true (rapid_toggle_settled,
        "rapid fullscreen toggles settle in normal window state");

    harness.window.close ();
}

private void test_trim_preview_fullscreen_window_state () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var host = new Adw.Window ();
    var tab = new TrimTab ();
    host.set_content (tab);
    host.present ();
    assert_true (spin_main_context_until_deadline (() => {
        return tab.popout_picture_height_for_widget_test () > 0;
    }, 2000), "embedded Crop & Trim player receives an initial allocation");
    int normal_height = tab.popout_picture_height_for_widget_test ();

    assert_true (tab.activate_player_fullscreen_shortcut_for_widget_test (),
        "F11 activates from the embedded Crop & Trim player");
    assert_true (tab.has_popout_window_for_widget_test (),
        "embedded F11 opens the existing Crop & Trim pop-out");
    assert_true (tab.is_popout_fullscreen_requested_for_widget_test (),
        "Crop & Trim forwards F11 to the pop-out fullscreen controller");

    if (!spin_main_context_until_deadline (() => {
        return tab.is_popout_window_fullscreen_for_widget_test ();
    }, 2000)) {
        Test.skip ("Compositor did not acknowledge the Crop & Trim fullscreen request");
        tab.close_popout ();
        host.close ();
        return;
    }

    assert_false (tab.is_popout_header_visible_for_widget_test (),
        "Crop & Trim hides pop-out chrome in fullscreen");
    assert_true (tab.popout_picture_expands_for_widget_test (),
        "Crop & Trim expands the fullscreen picture");
    assert_true (spin_main_context_until_deadline (() => {
        return tab.popout_picture_height_for_widget_test () > normal_height;
    }, 2000), "Crop & Trim fullscreen increases the picture allocation");
    int fullscreen_height = tab.popout_picture_height_for_widget_test ();

    assert_true (tab.popout_escape_uses_capture_for_widget_test (),
        "Crop & Trim Escape handler runs before crop-overlay key handling");
    assert_true (tab.request_popout_escape_for_widget_test (),
        "Escape is handled while Crop & Trim is fullscreen");
    assert_true (spin_main_context_until_deadline (() => {
        return !tab.is_popout_window_fullscreen_for_widget_test ()
            && !tab.is_popout_fullscreen_transition_pending_for_widget_test ();
    }, 2000), "Escape leaves Crop & Trim fullscreen");
    assert_true (tab.is_popout_header_visible_for_widget_test (),
        "Crop & Trim restores pop-out chrome after Escape");
    assert_false (tab.popout_picture_expands_for_widget_test (),
        "Crop & Trim restores the compact picture layout");
    assert_true (spin_main_context_until_deadline (() => {
        int height = tab.popout_picture_height_for_widget_test ();
        return height > 0 && height < fullscreen_height;
    }, 2000), "Crop & Trim restores a compact picture allocation");

    tab.click_player_popout_for_widget_test ();
    assert_false (tab.has_popout_window_for_widget_test (),
        "the original pop-out control still reattaches the player");

    host.close ();
}

private void test_video_player_duration_state_transitions () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var player = new VideoPlayer ();
    int ready_count = 0;
    double ready_duration = -1.0;
    string failure_message = "";
    player.media_ready.connect ((duration) => {
        ready_count++;
        ready_duration = duration;
    });
    player.media_failed.connect ((message) => {
        failure_message = message;
    });

    player.prepare_duration_for_widget_test (42.0);
    assert_true (ready_count == 1 && ready_duration == 42.0,
        "video known duration reaches ready state");
    assert_string_equal (player.get_duration_text_for_widget_test (),
        "00:00:42.000", "video known duration is displayed");
    assert_true (player.get_scrubber_upper_for_widget_test () == 42.0,
        "video known duration configures scrubber range");
    assert_true (player.is_scrubber_sensitive_for_widget_test (),
        "video known duration enables timeline seeking");

    player.clear ();
    assert_string_equal (player.get_duration_text_for_widget_test (),
        "00:00:00.000", "video reset clears stale duration text");
    assert_true (player.get_scrubber_upper_for_widget_test () == 1.0,
        "video reset clears stale scrubber range");
    assert_false (player.is_scrubber_sensitive_for_widget_test (),
        "video reset disables the empty scrubber");

    player.prepare_duration_for_widget_test (0.0);
    assert_true (ready_count == 2 && ready_duration == 0.0,
        "video unknown duration still reaches ready state");
    assert_string_equal (player.get_duration_text_for_widget_test (),
        "--:--:--.---", "video unknown duration is explicit");
    assert_false (player.is_scrubber_sensitive_for_widget_test (),
        "video unknown duration keeps timeline seeking disabled");
    assert_true (player.is_media_status_visible_for_widget_test (),
        "video unknown duration shows an explanation");
    assert_contains (player.get_media_status_for_widget_test (),
        "Duration unavailable", "video unknown-duration explanation");

    player.fail_for_widget_test ("Preview failed for test");
    assert_string_equal (failure_message, "Preview failed for test",
        "video failure is propagated to its owner");
    assert_string_equal (player.get_duration_text_for_widget_test (),
        "00:00:00.000", "video failure clears duration state");
    assert_contains (player.get_media_status_for_widget_test (),
        "Preview failed", "video failure is user-visible");
    player.cleanup ();
}

private void test_audio_player_duration_state_transitions () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var player = new AudioPlayer ();
    int ready_count = 0;
    double ready_duration = -1.0;
    string failure_message = "";
    player.media_ready.connect ((duration) => {
        ready_count++;
        ready_duration = duration;
    });
    player.media_failed.connect ((message) => {
        failure_message = message;
    });

    player.prepare_duration_for_widget_test (18.5);
    assert_true (ready_count == 1 && ready_duration == 18.5,
        "audio known duration reaches ready state");
    assert_true (player.get_duration_for_widget_test () == 18.5,
        "audio known duration is retained for waveform mapping");
    assert_true (player.is_waveform_seek_sensitive_for_widget_test (),
        "audio known duration enables waveform seeking");

    player.clear ();
    assert_true (player.get_duration_for_widget_test () == 0.0,
        "audio reset clears stale mapping duration");
    assert_string_equal (player.get_duration_text_for_widget_test (),
        "00:00:00.000", "audio reset clears stale duration text");
    assert_false (player.is_waveform_seek_sensitive_for_widget_test (),
        "audio reset disables waveform seeking");

    player.prepare_duration_for_widget_test (0.0);
    assert_true (ready_count == 2 && ready_duration == 0.0,
        "audio unknown duration still reaches ready state");
    assert_string_equal (player.get_duration_text_for_widget_test (),
        "--:--:--.---", "audio unknown duration is explicit");
    assert_false (player.is_waveform_seek_sensitive_for_widget_test (),
        "audio unknown duration keeps waveform seeking disabled");
    assert_true (player.is_media_status_visible_for_widget_test (),
        "audio unknown duration shows an explanation");
    assert_contains (player.get_media_status_for_widget_test (),
        "Duration unavailable", "audio unknown-duration explanation");

    player.clear ();
    player.prepare_duration_with_fallback_for_widget_test (0.0, 73.25);
    assert_true (ready_count == 3 && ready_duration == 73.25,
        "audio ffprobe fallback reaches ready state with a finite duration");
    assert_true (player.get_duration_for_widget_test () == 73.25,
        "audio ffprobe fallback is retained for waveform mapping");
    assert_string_equal (player.get_duration_text_for_widget_test (),
        "00:01:13.250", "audio ffprobe fallback is displayed");
    assert_true (player.is_waveform_seek_sensitive_for_widget_test (),
        "audio ffprobe fallback enables waveform seeking");

    player.fail_for_widget_test ("Audio preview failed for test");
    assert_string_equal (failure_message, "Audio preview failed for test",
        "audio failure is propagated to its owner");
    assert_true (player.get_duration_for_widget_test () == 0.0,
        "audio failure clears mapping duration");
    assert_contains (player.get_media_status_for_widget_test (),
        "Audio preview failed", "audio failure is user-visible");
    player.cleanup ();
}

/**
 * Playback rate is per-preview and must not survive a reset.
 *
 * The reset path closes the mpv core, so a rate carried over from the previous
 * file would sit on the transport with nothing applying it — and then be
 * silently applied to the next load. Reset also has to stay quiet: reporting a
 * change at a player mid-teardown would push a rate at a null handle.
 */
private void assert_speed_selector_resets (SpeedMenuButton speed,
                                           owned Func<void*> reset_player,
                                           string label) {
    int change_count = 0;
    double last_reported = -1.0;
    speed.speed_changed.connect ((rate) => {
        change_count++;
        last_reported = rate;
    });

    assert_true (speed.speed == 1.0,
        "%s speed starts at 1x".printf (label));
    assert_string_equal (speed.get_face_text_for_widget_test (), "1×",
        "%s speed face starts at 1x".printf (label));

    speed.select_rate_for_widget_test (2.0);
    assert_true (speed.speed == 2.0,
        "%s speed selection is retained".printf (label));
    assert_string_equal (speed.get_face_text_for_widget_test (), "2×",
        "%s speed selection reaches the button face".printf (label));
    assert_true (change_count == 1 && last_reported == 2.0,
        "%s speed selection reports exactly one change".printf (label));

    reset_player (null);
    assert_true (speed.speed == 1.0,
        "%s reset returns the rate to 1x".printf (label));
    assert_string_equal (speed.get_face_text_for_widget_test (), "1×",
        "%s reset returns the button face to 1x".printf (label));
    assert_true (change_count == 1,
        "%s reset does not report a rate change".printf (label));
}

private void test_video_player_speed_resets_per_preview () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var player = new VideoPlayer ();
    var speed = player.speed_button_for_widget_test ();

    assert_false (speed.get_sensitive (),
        "video speed selection is disabled before a file loads");
    player.prepare_duration_for_widget_test (42.0);
    assert_true (speed.get_sensitive (),
        "video ready state enables speed selection");

    assert_speed_selector_resets (speed, (unused) => player.clear (), "video");

    assert_false (speed.get_sensitive (),
        "video reset disables speed selection again");

    // Duration is what gates the scrubber, not the rate selector: an unknown
    // duration still leaves speed adjustable.
    player.prepare_duration_for_widget_test (0.0);
    assert_false (player.is_scrubber_sensitive_for_widget_test (),
        "video unknown duration keeps timeline seeking disabled");
    assert_true (speed.get_sensitive (),
        "video unknown duration still allows speed selection");
    player.cleanup ();
}

private void test_audio_player_speed_resets_per_preview () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var player = new AudioPlayer ();
    var speed = player.speed_button_for_widget_test ();

    assert_false (speed.get_sensitive (),
        "audio speed selection is disabled before a stream loads");
    player.prepare_duration_for_widget_test (18.5);
    assert_true (speed.get_sensitive (),
        "audio ready state enables speed selection");

    assert_speed_selector_resets (speed, (unused) => player.clear (), "audio");

    assert_false (speed.get_sensitive (),
        "audio reset disables speed selection again");

    player.prepare_duration_for_widget_test (0.0);
    assert_false (player.is_waveform_seek_sensitive_for_widget_test (),
        "audio unknown duration keeps waveform seeking disabled");
    assert_true (speed.get_sensitive (),
        "audio unknown duration still allows speed selection");
    player.cleanup ();
}

/**
 * A selected rate must actually reach the mpv core, and must not move the
 * media clock once it is there.
 *
 * The widget-state tests above stop at the signal boundary. This one goes the
 * rest of the way: it reads "speed" back off a live core, which is the only
 * thing that catches mpv rejecting the property — libmpv reports that as a
 * debug line and set_property otherwise looks like it worked.
 *
 * The seek assertion is the half that matters for correctness rather than
 * comfort. Trim points are taken from get_position_seconds (), so if rate ever
 * scaled the reported time, previewing at 2x would silently halve every cut
 * coordinate the user picked.
 */
private void test_video_player_speed_reaches_mpv_without_scaling_time () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    string? temp_dir = null;
    try {
        temp_dir = DirUtils.make_tmp ("video-player-speed-XXXXXX");
        string path = Path.build_filename (temp_dir, "speed.mkv");

        string[] argv = {
            "ffmpeg", "-v", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=s=320x180:rate=24:d=4",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
            path
        };
        int status = 0;
        Process.spawn_sync (null, argv, null,
                            SpawnFlags.SEARCH_PATH
                            | SpawnFlags.STDOUT_TO_DEV_NULL
                            | SpawnFlags.STDERR_TO_DEV_NULL,
                            null, null, null, out status);
        if (status != 0 || !FileUtils.test (path, FileTest.EXISTS)) {
            Test.skip ("ffmpeg unavailable, cannot build a video fixture");
            return;
        }

        var player = new VideoPlayer ();
        bool ready = false;
        player.media_ready.connect (() => ready = true);

        player.load_file (path);
        assert_true (spin_main_context_until (() => ready, 5000),
            "video speed fixture reaches readiness");
        assert_cmpfloat (player.backend_speed_for_widget_test (),
            CompareOperator.EQ, 1.0);

        var speed = player.speed_button_for_widget_test ();
        speed.select_rate_for_widget_test (2.0);
        assert_cmpfloat (player.backend_speed_for_widget_test (),
            CompareOperator.EQ, 2.0);

        // An exact seek must still land on the source time it was given while a
        // non-1x rate is active.
        player.seek_to (2.0);
        assert_true (spin_main_context_until (
            () => player.get_position_seconds () > 1.9, 5000),
            "exact seek lands while playing back at 2x");
        assert_cmpfloat (player.get_position_seconds (),
            CompareOperator.LT, 2.1);

        speed.select_rate_for_widget_test (0.25);
        assert_cmpfloat (player.backend_speed_for_widget_test (),
            CompareOperator.EQ, 0.25);
        assert_cmpfloat (player.get_position_seconds (),
            CompareOperator.GT, 1.9);
        assert_cmpfloat (player.get_position_seconds (),
            CompareOperator.LT, 2.1);

        // A fresh load starts back at 1x on the core, not just on the button.
        ready = false;
        player.load_file (path);
        assert_true (spin_main_context_until (() => ready, 5000),
            "video speed fixture reloads");
        assert_cmpfloat (player.backend_speed_for_widget_test (),
            CompareOperator.EQ, 1.0);

        player.cleanup ();
        FileUtils.remove (path);
    } catch (FileError e) {
        Test.fail_printf ("failed to create video speed test directory: %s",
            e.message);
    } catch (SpawnError e) {
        Test.skip ("ffmpeg unavailable, cannot build a video fixture");
    } finally {
        if (temp_dir != null)
            DirUtils.remove (temp_dir);
    }
}

/**
 * A video preview must run with video-timing-offset=0.
 *
 * That option is what keeps mpv's software render call from blocking the GTK
 * main thread for a whole frame interval — see the finding 1 section of
 * docs/mpv-port-review-findings.md. It is only applied on the video path, so it
 * needs a real Gtk.Picture and therefore a display; the headless
 * mpv-render-timing test covers the render parameter that pairs with it, but
 * cannot reach this half.
 *
 * Reading it back from the live core also catches the option being rejected,
 * which mpv reports only as a debug line.
 */
private void test_video_player_disables_mpv_timing_lookahead () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    string? temp_dir = null;
    try {
        temp_dir = DirUtils.make_tmp ("video-player-timing-XXXXXX");
        string path = Path.build_filename (temp_dir, "timing.mkv");

        string[] argv = {
            "ffmpeg", "-v", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=s=320x180:rate=24:d=1",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
            path
        };
        int status = 0;
        Process.spawn_sync (null, argv, null,
                            SpawnFlags.SEARCH_PATH
                            | SpawnFlags.STDOUT_TO_DEV_NULL
                            | SpawnFlags.STDERR_TO_DEV_NULL,
                            null, null, null, out status);
        if (status != 0 || !FileUtils.test (path, FileTest.EXISTS)) {
            Test.skip ("ffmpeg unavailable, cannot build a video fixture");
            return;
        }

        var player = new VideoPlayer ();
        bool ready = false;
        player.media_ready.connect (() => ready = true);

        player.load_file (path);
        assert_true (spin_main_context_until (() => ready, 5000),
            "video fixture reaches readiness");

        // Zero exactly: any lookahead at all is paid on the main thread.
        assert_cmpfloat (player.backend_timing_offset_for_widget_test (),
            CompareOperator.EQ, 0.0);

        player.cleanup ();
        FileUtils.remove (path);
    } catch (FileError e) {
        Test.fail_printf ("failed to create video timing test directory: %s",
            e.message);
    } catch (SpawnError e) {
        Test.skip ("ffmpeg unavailable, cannot build a video fixture");
    } finally {
        if (temp_dir != null)
            DirUtils.remove (temp_dir);
    }
}

private void test_video_player_failed_load_releases_backend_resources () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    string? temp_dir = null;
    try {
        temp_dir = DirUtils.make_tmp ("video-player-failure-XXXXXX");
        string missing_path = Path.build_filename (temp_dir, "missing-video.mkv");

        var player = new VideoPlayer ();
        bool failed = false;
        player.media_failed.connect ((message) => {
            failed = true;
        });

        player.load_file (missing_path);
        assert_true (player.is_backend_core_active_for_widget_test (),
            "video load creates an mpv core before asynchronous failure");
        assert_true (player.is_backend_render_context_active_for_widget_test (),
            "video load creates a software render context");
        assert_true (player.is_backend_event_source_active_for_widget_test (),
            "video load starts the mpv event source");
        assert_true (player.is_backend_render_tick_active_for_widget_test (),
            "video load starts the GTK render tick");

        assert_true (spin_main_context_until (() => failed, 3000),
            "video missing-file failure reaches the owning player");
        assert_false (player.is_backend_core_active_for_widget_test (),
            "video failure releases the mpv core");
        assert_false (player.is_backend_render_context_active_for_widget_test (),
            "video failure releases the software render context");
        assert_false (player.is_backend_event_source_active_for_widget_test (),
            "video failure removes the mpv event source");
        assert_false (player.is_backend_render_tick_active_for_widget_test (),
            "video failure removes the GTK render tick");
        player.cleanup ();
    } catch (FileError e) {
        Test.fail_printf ("failed to create video failure test directory: %s",
            e.message);
    } finally {
        if (temp_dir != null)
            DirUtils.remove (temp_dir);
    }
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

private void test_copy_command_strips_metadata_when_preserve_metadata_disabled () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 5.0, 1920, 1080));

    var runner = make_capture_runner (files);
    runner.preserve_metadata = false;

    int exit_code = runner.run_copy_mode_for_widget_test ();
    assert_true (exit_code == 0, "copy command metadata disabled exit code");

    // FFmpeg copies global metadata by default, so preserve-off must
    // strip explicitly with -map_metadata -1.
    string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();
    assert_array_has_adjacent_pair (argv, "-map_metadata", "-1",
        "copy mode strips metadata when preserve metadata is disabled");
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

private void test_reencode_command_image_watermark_topology () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 3.0, 1920, 1080));

    var runner = make_capture_runner (files);
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    profile.watermark_enabled = true;
    profile.watermark_mode = "image";
    profile.watermark_image_path = "/tmp/logo.png";
    profile.watermark_image_width = 200;
    profile.watermark_position = "Bottom Right";
    profile.watermark_opacity = 0.7;
    profile.watermark_margin = 15;
    profile.overlay_format = "yuv420p10";
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "image watermark reencode exit code");

    string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();

    // Watermark image must appear as a third -i input (after the two video files)
    assert_array_has_adjacent_pair (argv, "-i", "/tmp/logo.png",
        "image watermark adds watermark as input");

    // filter_complex must contain the overlay chain
    string filter_complex = "";
    for (int i = 0; i < argv.length - 1; i++) {
        if (argv[i] == "-filter_complex") {
            filter_complex = argv[i + 1];
            break;
        }
    }

    assert_contains (filter_complex, "overlay=",
        "filter_complex contains overlay filter for image watermark");
    assert_contains (filter_complex, "scale=200:-1",
        "filter_complex scales watermark to requested width");
    assert_contains (filter_complex, "main_w-overlay_w-15",
        "filter_complex positions watermark at Bottom Right with margin");
    assert_contains (filter_complex, ":format=yuv420p10[outv]",
        "combine runner preserves the selected 10-bit overlay format");
    assert_contains (filter_complex, "[outv_pre_wm]",
        "filter_complex renames [outv] to [outv_pre_wm] before overlay");
    assert_contains (filter_complex, "[outv]",
        "filter_complex produces final [outv] from overlay");

    // Standard output mapping must still work
    assert_array_has_adjacent_pair (argv, "-map", "[outv]",
        "image watermark maps video output");
    assert_array_has_adjacent_pair (argv, "-map", "[outa]",
        "image watermark maps audio output");
}

private void test_reencode_command_text_watermark_no_extra_input () {
    var files = new GenericArray<CombineFile> ();
    files.add (make_combine_file ("/tmp/first.mkv", 4.0, 1920, 1080));
    files.add (make_combine_file ("/tmp/second.mkv", 3.0, 1920, 1080));

    var runner = make_capture_runner (files);
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    // Text mode watermark — should NOT add an extra -i input
    profile.watermark_enabled = true;
    profile.watermark_mode = "text";
    runner.reencode_profile = profile;

    int exit_code = runner.run_reencode_mode_for_widget_test ();
    assert_true (exit_code == 0, "text watermark reencode exit code");

    string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();

    // Text mode watermark should only have the two video inputs, no extra
    int input_count = 0;
    for (int i = 0; i < argv.length; i++) {
        if (argv[i] == "-i") input_count++;
    }
    assert_true (input_count == 2,
        "text mode watermark does not add extra inputs (got %d)".printf (input_count));

    // filter_complex must NOT contain overlay
    string filter_complex = "";
    for (int i = 0; i < argv.length - 1; i++) {
        if (argv[i] == "-filter_complex") {
            filter_complex = argv[i + 1];
            break;
        }
    }

    if (filter_complex.contains ("overlay=")) {
        Test.fail_printf ("text mode should not use overlay filter, got: %s", filter_complex);
    }
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

private void test_converter_output_path_is_sanitized_before_overwrite_check () {
    var settings = AppSettings.get_default ();
    OutputNameMode previous_mode = settings.output_name_mode;
    string previous_custom_name = settings.output_custom_name;

    try {
        settings.output_name_mode = OutputNameMode.DEFAULT;
        settings.output_custom_name = "";

        var codec_tab = new OutputPathCodecTab ("svt-av1", ContainerExt.WEBM);
        var builder = codec_tab.get_codec_builder ();

        string input_file = "/tmp/Episode:01?.mkv";
        string output_folder = "/tmp/output";
        string expected = "/tmp/output/Episode_01_-av1.webm";

        string sync_path = Converter.compute_output_path (
            input_file,
            output_folder,
            builder,
            codec_tab
        );
        assert_string_equal (
            sync_path,
            expected,
            "sync conversion output path is sanitized before overwrite checks"
        );

        string async_path = run_compute_output_path_async_for_test (
            input_file,
            output_folder,
            builder,
            codec_tab,
            "sanitized conversion output path"
        );
        assert_string_equal (
            async_path,
            expected,
            "async conversion output path is sanitized before overwrite checks"
        );
    } finally {
        settings.output_name_mode = previous_mode;
        settings.output_custom_name = previous_custom_name;
    }
}

private EncodeProfileSnapshot make_basic_conversion_profile_for_test () {
    var profile = new EncodeProfileSnapshot ();
    profile.codec_name = "x264";
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "20" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "160k" };
    return profile;
}

private void enable_image_watermark_for_conversion_test (EncodeProfileSnapshot profile) {
    profile.watermark_enabled = true;
    profile.watermark_mode = "image";
    profile.watermark_image_path = "/tmp/logo.png";
}

private void test_conversion_runner_non_watermark_off_keeps_existing_mapping_behavior () {
    var profile = make_basic_conversion_profile_for_test ();
    var runner = make_conversion_runner_for_test (profile);

    string[] argv = runner.build_single_pass_argv_for_test (
        "/tmp/input.mkv",
        "/tmp/output.mkv"
    );

    assert_array_not_contains (argv, "0:v:0",
        "off path should not explicitly map the primary video stream");
    assert_array_not_contains (argv, "0:a?",
        "off path should not explicitly map all audio streams");
}

private void test_conversion_runner_non_watermark_on_maps_primary_video_and_all_audio () {
    var profile = make_basic_conversion_profile_for_test ();
    profile.preserve_all_audio_tracks = true;
    var runner = make_conversion_runner_for_test (profile);

    string[] argv = runner.build_single_pass_argv_for_test (
        "/tmp/input.mkv",
        "/tmp/output.mkv"
    );

    assert_array_has_adjacent_pair (argv, "-map", "0:v:0",
        "on path maps the primary video stream");
    assert_array_has_adjacent_pair (argv, "-map", "0:a?",
        "on path maps all audio streams");
}

/**
 * The General tab's Duration selects a stretch of the source, so it has to
 * bound the input.
 *
 * As an output option it was measured after the filter chain, where a speed
 * filter has already rewritten the timestamps — which put it on a different
 * clock from the rest of the app. SmartOptimizer samples the source between
 * trim_start_seconds and trim_end_seconds (app-controller), and timed logo
 * removal clamps its enable windows to the same span (logo-detector-logic);
 * both read it as source time. At 2x the encode ran on past the requested
 * span, and logo removal stopped covering the tail of the output.
 *
 * Without a speed filter both placements produce identical output, so the
 * position is the only thing worth asserting here.
 */
private void test_conversion_runner_duration_bounds_the_input () {
    var profile = make_basic_conversion_profile_for_test ();
    profile.video_filters = "setpts=0.500000*PTS";
    profile.video_filters_skip_delogo = profile.video_filters;
    profile.video_filters_skip_crop_and_delogo = profile.video_filters;

    var config = new ConversionConfig ();
    config.profile = profile;
    config.source_span_seconds = 30.0;
    config.timed_stream_topology_known = true;
    config.seek_enabled = true;
    config.seek_timestamp = "00:00:05";
    config.time_enabled = true;
    config.time_timestamp = "00:00:30";

    var runner = new ConversionRunner.for_command_test (config);

    string[] single_pass = runner.build_single_pass_argv_for_test (
        "/tmp/input.mkv", "/tmp/output.mkv");
    string[] pass1 = runner.build_pass1_argv_for_test ("/tmp/input.mkv");
    string[] pass2 = runner.build_pass2_argv_for_test (
        "/tmp/input.mkv", "/tmp/output.mkv");

    assert_array_option_precedes (single_pass, "-t", "-i",
        "single-pass duration bounds the input");
    assert_array_option_precedes (pass1, "-t", "-i",
        "pass 1 duration bounds the input");
    assert_array_option_precedes (pass2, "-t", "-i",
        "pass 2 duration bounds the input");

    // Start and length must stay on the same side of -i, or they describe two
    // different ranges.
    assert_array_option_precedes (single_pass, "-ss", "-i",
        "single-pass start time bounds the input");

    // One limit only — a leftover output-side copy would re-truncate the
    // already-correct span.
    assert_array_occurrence_count (single_pass, "-t", 1,
        "single-pass emits exactly one duration limit");

    // Progress reporting stays where it was.
    assert_array_has_adjacent_pair (single_pass, "-progress", "pipe:2",
        "single-pass keeps the progress pipe");
}

private void test_conversion_runner_video_only_resets_output_timestamps () {
    var profile = make_basic_conversion_profile_for_test ();
    profile.audio_args = { "-an" };
    profile.video_filters = "scale=1280:720";
    profile.video_filters_skip_delogo = profile.video_filters;
    profile.video_filters_skip_crop_and_delogo = profile.video_filters;
    var runner = make_conversion_runner_for_test (profile);

    string[] single_pass = runner.build_single_pass_argv_for_test (
        "/tmp/input.mkv",
        "/tmp/output.mkv"
    );
    string[] pass1 = runner.build_pass1_argv_for_test ("/tmp/input.mkv");
    string[] pass2 = runner.build_pass2_argv_for_test (
        "/tmp/input.mkv",
        "/tmp/output.mkv"
    );

    string expected = "scale=1280:720,setpts=PTS-STARTPTS";
    assert_array_has_adjacent_pair (single_pass, "-vf", expected,
        "video-only single-pass conversion resets the final timeline");
    assert_array_has_adjacent_pair (pass1, "-vf", expected,
        "video-only pass 1 uses the normalized timeline");
    assert_array_has_adjacent_pair (pass2, "-vf", expected,
        "video-only pass 2 uses the same normalized timeline");
}

private void test_conversion_runner_video_only_adds_timestamp_filter_to_empty_chain () {
    var profile = make_basic_conversion_profile_for_test ();
    profile.audio_args = { "-an" };
    var runner = make_conversion_runner_for_test (profile);

    string[] argv = runner.build_single_pass_argv_for_test (
        "/tmp/input.mkv",
        "/tmp/output.mkv"
    );

    assert_array_has_adjacent_pair (argv, "-vf", "setpts=PTS-STARTPTS",
        "video-only conversion normalizes timestamps even without other filters");
}

private void test_conversion_runner_retained_audio_does_not_reset_video_independently () {
    var profile = make_basic_conversion_profile_for_test ();
    profile.video_filters = "scale=1280:720";
    profile.video_filters_skip_delogo = profile.video_filters;
    profile.video_filters_skip_crop_and_delogo = profile.video_filters;
    var runner = make_conversion_runner_for_test (profile);

    string[] argv = runner.build_single_pass_argv_for_test (
        "/tmp/input.mkv",
        "/tmp/output.mkv"
    );

    assert_array_has_adjacent_pair (argv, "-vf", "scale=1280:720",
        "audio-bearing conversion preserves its original A/V timestamp relationship");
    assert_array_not_contains (argv, "scale=1280:720,setpts=PTS-STARTPTS",
        "audio-bearing conversion does not reset only the video timeline");
}

private void test_conversion_runner_subtitles_block_independent_video_reset () {
    var profile = make_basic_conversion_profile_for_test ();
    profile.audio_args = { "-an" };
    profile.video_filters = "scale=1280:720";
    profile.video_filters_skip_delogo = profile.video_filters;
    profile.video_filters_skip_crop_and_delogo = profile.video_filters;
    var runner = make_conversion_runner_for_test (
        profile, 1.0, true, true, false);

    string[] argv = runner.build_single_pass_argv_for_test (
        "/tmp/input-with-subtitles.mkv",
        "/tmp/output.mkv"
    );

    assert_array_has_adjacent_pair (argv, "-vf", "scale=1280:720",
        "automatically mapped subtitles keep their original relation to video");
}

private void test_conversion_runner_retained_chapters_block_video_reset () {
    var profile = make_basic_conversion_profile_for_test ();
    profile.audio_args = { "-an" };
    profile.video_filters = "scale=1280:720";
    profile.video_filters_skip_delogo = profile.video_filters;
    profile.video_filters_skip_crop_and_delogo = profile.video_filters;
    var runner = make_conversion_runner_for_test (
        profile, 1.0, true, false, true);

    string[] argv = runner.build_single_pass_argv_for_test (
        "/tmp/input-with-chapters.mkv",
        "/tmp/output.mkv"
    );

    assert_array_has_adjacent_pair (argv, "-vf", "scale=1280:720",
        "retained chapter timestamps block an independent video reset");
}

private void test_conversion_runner_removed_chapters_allow_video_reset () {
    var profile = make_basic_conversion_profile_for_test ();
    profile.audio_args = { "-an" };
    profile.remove_chapters = true;
    var runner = make_conversion_runner_for_test (
        profile, 1.0, true, false, true);

    string[] argv = runner.build_single_pass_argv_for_test (
        "/tmp/input-with-removed-chapters.mkv",
        "/tmp/output.mkv"
    );

    assert_array_has_adjacent_pair (argv, "-vf", "setpts=PTS-STARTPTS",
        "removed chapters no longer constrain the output timeline");
}

private void test_conversion_runner_unknown_topology_fails_closed () {
    var profile = make_basic_conversion_profile_for_test ();
    profile.audio_args = { "-an" };
    profile.video_filters = "scale=1280:720";
    profile.video_filters_skip_delogo = profile.video_filters;
    profile.video_filters_skip_crop_and_delogo = profile.video_filters;
    var runner = make_conversion_runner_for_test (
        profile, 1.0, false, false, false);

    string[] argv = runner.build_single_pass_argv_for_test (
        "/tmp/unprobeable-input.mkv",
        "/tmp/output.mkv"
    );

    assert_array_has_adjacent_pair (argv, "-vf", "scale=1280:720",
        "unknown topology does not risk shifting one stream independently");
}

private void test_conversion_runner_video_only_watermark_excludes_input_subtitles () {
    var profile = make_basic_conversion_profile_for_test ();
    profile.audio_args = { "-an" };
    enable_image_watermark_for_conversion_test (profile);
    var runner = make_conversion_runner_for_test (
        profile, 1.0, true, true, false);

    string[] argv = runner.build_single_pass_argv_for_test (
        "/tmp/input-with-subtitles.mkv",
        "/tmp/output.mkv"
    );

    string filter_complex = extract_filter_complex (argv);
    assert_contains (filter_complex, "[0:v]setpts=PTS-STARTPTS[vf_out]",
        "explicit video-only watermark mapping can safely reset timestamps");
}

private void test_conversion_runner_image_watermark_toggle_off_maps_first_audio_only () {
    var profile = make_basic_conversion_profile_for_test ();
    enable_image_watermark_for_conversion_test (profile);
    var runner = make_conversion_runner_for_test (profile);

    string[] argv = runner.build_single_pass_argv_for_test (
        "/tmp/input.mkv",
        "/tmp/output.mkv"
    );

    assert_array_has_adjacent_pair (argv, "-map", "[outv]",
        "image watermark path maps the filtered video output");
    assert_array_has_adjacent_pair (argv, "-map", "0:a:0?",
        "image watermark path maps only the first audio stream when toggle is off");
    assert_array_not_contains (argv, "0:a?",
        "image watermark path should not map all audio streams when toggle is off");
    assert_array_not_contains (argv, "0:v:0",
        "image watermark path should not add a redundant direct video map");
}

private void test_conversion_runner_image_watermark_toggle_on_maps_all_audio () {
    var profile = make_basic_conversion_profile_for_test ();
    profile.preserve_all_audio_tracks = true;
    enable_image_watermark_for_conversion_test (profile);
    var runner = make_conversion_runner_for_test (profile);

    string[] argv = runner.build_single_pass_argv_for_test (
        "/tmp/input.mkv",
        "/tmp/output.mkv"
    );

    assert_array_has_adjacent_pair (argv, "-map", "[outv]",
        "image watermark path maps the filtered video output");
    assert_array_has_adjacent_pair (argv, "-map", "0:a?",
        "image watermark path maps all audio streams when toggle is on");
    assert_array_not_contains (argv, "0:a:0?",
        "image watermark path should not map only the first audio stream when toggle is on");
    assert_array_not_contains (argv, "0:v:0",
        "image watermark path should not add a redundant direct video map");
}

private void test_conversion_runner_image_watermark_preserves_selected_10bit () {
    var profile = make_basic_conversion_profile_for_test ();
    enable_image_watermark_for_conversion_test (profile);
    profile.video_filters = "format=" + PixelFormat.YUV420P10LE;
    profile.video_filters_skip_delogo = profile.video_filters;
    profile.video_filters_skip_crop_and_delogo = profile.video_filters;
    profile.overlay_format = "yuv420p10";
    var runner = make_conversion_runner_for_test (profile);

    string[] argv = runner.build_single_pass_argv_for_test (
        "/tmp/input.mkv",
        "/tmp/output.mkv"
    );

    string filter_complex = extract_filter_complex (argv);
    assert_contains (filter_complex, "[0:v]format=yuv420p10le[vf_out]",
        "conversion runner normalizes the main video to selected 10-bit");
    assert_contains (filter_complex, ":format=yuv420p10[outv]",
        "conversion runner preserves selected 10-bit through image overlay");
}

private void test_conversion_runner_pass1_image_watermark_keeps_audio_mapping_disabled () {
    var profile = make_basic_conversion_profile_for_test ();
    profile.preserve_all_audio_tracks = true;
    enable_image_watermark_for_conversion_test (profile);
    var runner = make_conversion_runner_for_test (profile);

    string[] argv = runner.build_pass1_argv_for_test ("/tmp/input.mkv");

    assert_array_has_adjacent_pair (argv, "-map", "[outv]",
        "pass1 watermark path still maps the filtered video output");
    assert_array_contains (argv, "-an",
        "pass1 disables audio");
    assert_array_not_contains (argv, "0:v:0",
        "pass1 should not add explicit primary video mapping for keep-all-audio");
    assert_array_not_contains (argv, "0:a?",
        "pass1 should not add explicit all-audio mapping before -an");
    assert_array_not_contains (argv, "0:a:0?",
        "pass1 should not add explicit first-audio mapping before -an");
}

private void test_conversion_runner_pass2_maps_primary_video_and_all_audio_when_toggle_on () {
    var profile = make_basic_conversion_profile_for_test ();
    profile.preserve_all_audio_tracks = true;
    var runner = make_conversion_runner_for_test (profile);

    string[] argv = runner.build_pass2_argv_for_test (
        "/tmp/input.mkv",
        "/tmp/output.mkv"
    );

    assert_array_has_adjacent_pair (argv, "-map", "0:v:0",
        "pass2 maps the primary video stream");
    assert_array_has_adjacent_pair (argv, "-map", "0:a?",
        "pass2 maps all audio streams");
}

private void test_conversion_runner_pass2_image_watermark_toggle_off_maps_first_audio_only () {
    var profile = make_basic_conversion_profile_for_test ();
    enable_image_watermark_for_conversion_test (profile);
    var runner = make_conversion_runner_for_test (profile);

    string[] argv = runner.build_pass2_argv_for_test (
        "/tmp/input.mkv",
        "/tmp/output.mkv"
    );

    assert_array_has_adjacent_pair (argv, "-map", "[outv]",
        "pass2 watermark path maps the filtered video output");
    assert_array_has_adjacent_pair (argv, "-map", "0:a:0?",
        "pass2 watermark path maps only the first audio stream when toggle is off");
    assert_array_not_contains (argv, "0:a?",
        "pass2 watermark path should not map all audio streams when toggle is off");
}

private void test_conversion_runner_pass2_image_watermark_toggle_on_maps_all_audio () {
    var profile = make_basic_conversion_profile_for_test ();
    profile.preserve_all_audio_tracks = true;
    enable_image_watermark_for_conversion_test (profile);
    var runner = make_conversion_runner_for_test (profile);

    string[] argv = runner.build_pass2_argv_for_test (
        "/tmp/input.mkv",
        "/tmp/output.mkv"
    );

    assert_array_has_adjacent_pair (argv, "-map", "[outv]",
        "pass2 watermark path maps the filtered video output");
    assert_array_has_adjacent_pair (argv, "-map", "0:a?",
        "pass2 watermark path maps all audio streams when toggle is on");
    assert_array_not_contains (argv, "0:a:0?",
        "pass2 watermark path should not map only the first audio stream when toggle is on");
}

private void test_conversion_runner_peak_detect_toggle_off_maps_first_audio_only () {
    var profile = make_basic_conversion_profile_for_test ();
    var runner = make_conversion_runner_for_test (profile);

    string[] argv = runner.build_peak_detect_argv_for_test ("/tmp/input.mkv");

    assert_array_has_adjacent_pair (argv, "-map", "0:a:0?",
        "peak detect path maps only the first audio stream when toggle is off");
    assert_array_not_contains (argv, "0:a?",
        "peak detect path should not map all audio streams when toggle is off");
}

private void test_conversion_runner_peak_detect_toggle_on_maps_all_audio () {
    var profile = make_basic_conversion_profile_for_test ();
    profile.preserve_all_audio_tracks = true;
    var runner = make_conversion_runner_for_test (profile);

    string[] argv = runner.build_peak_detect_argv_for_test ("/tmp/input.mkv");

    assert_array_has_adjacent_pair (argv, "-map", "0:a?",
        "peak detect path maps all audio streams when toggle is on");
    assert_array_not_contains (argv, "0:a:0?",
        "peak detect path should not map only the first audio stream when toggle is on");
}

private void test_conversion_runner_collage_output_path_uses_png_sidecar_name () {
    var profile = make_basic_conversion_profile_for_test ();
    var runner = make_conversion_runner_for_test (profile);

    string collage_path = runner.build_collage_output_path_for_test (
        "/tmp/final-video-x265.mkv"
    );

    assert_string_equal (
        collage_path,
        "/tmp/final-video-x265-collage.png",
        "collage output path appends -collage.png next to the video"
    );
}

private void test_conversion_runner_collage_command_uses_percentage_timestamps () {
    var profile = make_basic_conversion_profile_for_test ();
    var runner = make_conversion_runner_for_test (profile);

    string[] argv = runner.build_collage_argv_for_test (
        "/tmp/output.mkv",
        "/tmp/output-collage.png",
        100.0,
        10.0
    );

    assert_array_occurrence_count (argv, "-ss", 12,
        "collage command seeks to twelve normalized timeline positions");
    assert_array_occurrence_count (argv, "-seek_timestamp", 12,
        "collage command treats every capture position as an absolute timestamp");
    assert_array_has_adjacent_pair (argv, "-ss", "18.000000",
        "collage command captures the 8 percent frame");
    assert_array_has_adjacent_pair (argv, "-ss", "26.000000",
        "collage command captures the 16 percent frame");
    assert_array_has_adjacent_pair (argv, "-ss", "34.000000",
        "collage command captures the 24 percent frame");
    assert_array_has_adjacent_pair (argv, "-ss", "42.000000",
        "collage command captures the 32 percent frame");
    assert_array_has_adjacent_pair (argv, "-ss", "50.000000",
        "collage command captures the 40 percent frame");
    assert_array_has_adjacent_pair (argv, "-ss", "58.000000",
        "collage command captures the 48 percent frame");
    assert_array_has_adjacent_pair (argv, "-ss", "66.000000",
        "collage command captures the 56 percent frame");
    assert_array_has_adjacent_pair (argv, "-ss", "74.000000",
        "collage command captures the 64 percent frame");
    assert_array_has_adjacent_pair (argv, "-ss", "82.000000",
        "collage command captures the 72 percent frame");
    assert_array_has_adjacent_pair (argv, "-ss", "90.000000",
        "collage command captures the 80 percent frame");
    assert_array_has_adjacent_pair (argv, "-ss", "98.000000",
        "collage command captures the 88 percent frame");
    assert_array_has_adjacent_pair (argv, "-ss", "106.000000",
        "collage command captures the 96 percent frame");
    assert_array_has_adjacent_pair (argv, "-frames:v", "1",
        "collage command writes a single PNG frame");
    assert_array_has_adjacent_pair (argv, "-update", "1",
        "collage command tells image2 it is writing one image, not a sequence");
    assert_string_equal (
        argv[argv.length - 1],
        "/tmp/output-collage.png",
        "collage command writes to the expected PNG path"
    );

    string filter_complex = "";
    for (int i = 0; i < argv.length - 1; i++) {
        if (argv[i] == "-filter_complex") {
            filter_complex = argv[i + 1];
            break;
        }
    }

    assert_contains (filter_complex, "xstack=inputs=12",
        "collage command combines twelve captured frames");
    assert_contains (filter_complex, "[0:v]setpts=PTS-STARTPTS,scale=",
        "collage resets each captured tile before framesync");
    assert_contains (
        filter_complex,
        "layout=0_0|480_0|960_0|1440_0|0_270|480_270|960_270|1440_270|0_540|480_540|960_540|1440_540",
        "collage command arranges frames in a 4-by-3 grid"
    );
}

private void test_conversion_runner_nonzero_pts_media_and_collage_integration () {
    string temp_dir;
    try {
        temp_dir = DirUtils.make_tmp ("conversion-timestamp-collage-XXXXXX");
    } catch (Error e) {
        Test.fail_printf ("failed to create timestamp integration directory: %s",
            e.message);
        return;
    }

    try {
        string input_path = Path.build_filename (temp_dir, "nonzero-input.mkv");
        string output_path = Path.build_filename (temp_dir, "normalized-output.mkv");
        string collage_path = Path.build_filename (temp_dir, "input-collage.png");
        string stdout_buf, stderr_buf;

        string[] make_input = {
            AppSettings.get_default ().ffmpeg_path,
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=10:d=4",
            "-vf", "setpts=PTS+1.5/TB",
            "-c:v", "ffv1",
            "-an",
            input_path
        };
        int make_status = run_command_for_test (
            make_input, out stdout_buf, out stderr_buf,
            "create nonzero-PTS integration input");
        assert_true (make_status == 0,
            "nonzero-PTS integration input is created");

        VideoTimelineProbeResult input_timeline =
            FfprobeUtils.probe_video_timeline (input_path);
        assert_true (input_timeline.success,
            "nonzero-PTS input video timeline is readable");
        assert_true (Math.fabs (input_timeline.start_time - 1.5) < 0.01,
            "integration input keeps its nonzero video start");

        var profile = make_basic_conversion_profile_for_test ();
        profile.codec_args = { "-c:v", "ffv1" };
        profile.audio_args = { "-an" };
        var runner = make_conversion_runner_for_test (
            profile, input_timeline.get_duration (), true, false, false);

        string[] conversion_argv = runner.build_single_pass_argv_for_test (
            input_path, output_path);
        int conversion_status = run_command_for_test (
            conversion_argv, out stdout_buf, out stderr_buf,
            "normalize nonzero-PTS integration input");
        assert_true (conversion_status == 0,
            "nonzero-PTS integration conversion succeeds");

        VideoTimelineProbeResult output_timeline =
            FfprobeUtils.probe_video_timeline (output_path);
        assert_true (output_timeline.success,
            "normalized integration output video timeline is readable");
        assert_true (Math.fabs (output_timeline.start_time) < 0.001,
            "normalized integration output starts at zero");
        assert_true (Math.fabs (
                output_timeline.get_duration () - input_timeline.get_duration ()) < 0.02,
            "timestamp normalization preserves the video duration");

        string[] collage_argv = runner.build_collage_argv_for_test (
            input_path,
            collage_path,
            input_timeline.get_duration (),
            input_timeline.start_time
        );
        int collage_status = run_command_for_test (
            collage_argv, out stdout_buf, out stderr_buf,
            "generate collage from nonzero-PTS integration input");
        assert_true (collage_status == 0,
            "absolute video-timeline collage generation succeeds");
        assert_true (FileUtils.test (collage_path, FileTest.EXISTS),
            "absolute video-timeline collage creates its PNG");
    } finally {
        cleanup_exec_test_dir (temp_dir);
    }
}

// The standalone collage window drives real ffmpeg over a file the user picked
// rather than one the app just wrote, so the interesting part is the glue:
// probe the source, place the twelve captures, and land the PNG beside it.
private void test_collage_runner_writes_png_beside_source () {
    string temp_dir;
    try {
        temp_dir = DirUtils.make_tmp ("collage-runner-XXXXXX");
    } catch (Error e) {
        Test.fail_printf ("failed to create collage runner directory: %s",
            e.message);
        return;
    }

    try {
        string source_path = Path.build_filename (temp_dir, "clip.mkv");
        string expected_collage = Path.build_filename (temp_dir, "clip-collage.png");
        string stdout_buf, stderr_buf;

        string[] make_source = {
            AppSettings.get_default ().ffmpeg_path,
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=10:d=6",
            "-c:v", "ffv1",
            "-an",
            source_path
        };
        assert_true (
            run_command_for_test (make_source, out stdout_buf, out stderr_buf,
                "create collage runner source") == 0,
            "collage runner source clip is created");

        var runner = new CollageRunner ();
        string finished_path = "";
        string failure = "";
        runner.collage_done.connect ((result) => {
            finished_path = result.primary_file_path;
        });
        runner.collage_failed.connect ((message) => {
            failure = message;
        });
        runner.collage_cancelled.connect ((message) => {
            failure = "cancelled: " + message;
        });

        runner.run (source_path);
        spin_main_context_until_deadline (() => {
            return finished_path.length > 0 || failure.length > 0;
        }, 30000);

        if (failure.length > 0) {
            Test.fail_printf ("collage runner failed: %s", failure);
            return;
        }

        assert_string_equal (finished_path, expected_collage,
            "collage lands beside the source file");
        assert_true (FileUtils.test (expected_collage, FileTest.EXISTS),
            "collage runner writes its PNG");

        // 4 columns × 480 by 3 rows × 270 — proves the tiles were composed
        // rather than a single frame being written straight out.
        string[] probe_size = {
            AppSettings.get_default ().ffprobe_path,
            "-v", "error",
            "-show_entries", "stream=width,height",
            "-of", "csv=p=0",
            expected_collage
        };
        assert_true (
            run_command_for_test (probe_size, out stdout_buf, out stderr_buf,
                "probe generated collage") == 0,
            "generated collage is a readable image");
        assert_string_equal (stdout_buf.strip (), "1920,810",
            "generated collage is a 4-by-3 grid of 480x270 tiles");
    } finally {
        cleanup_exec_test_dir (temp_dir);
    }
}

// The size row is only meaningful while the sidecar is on, so it follows the
// switch. Never presented or closed: SettingsDialog writes the real settings
// file from its "closed" handler.
private void test_collage_size_row_follows_the_switch () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var dialog = new SettingsDialog ();

    // Driven from a known state rather than asserting the initial one, which
    // reflects whatever the running user's config says.
    dialog.set_collage_enabled_for_widget_test (true);
    assert_true (dialog.is_collage_size_visible_for_widget_test (),
        "collage size appears once the sidecar is enabled");

    dialog.set_collage_enabled_for_widget_test (false);
    assert_false (dialog.is_collage_size_visible_for_widget_test (),
        "collage size hides again when the sidecar is switched off");

    dialog.set_collage_enabled_for_widget_test (true);
    assert_true (dialog.is_collage_size_visible_for_widget_test (),
        "collage size comes back when the sidecar is re-enabled");

    // The subtitle carries the real pixel dimensions, since a 4x3 grid of 16:9
    // tiles is 64:27 and "4K" alone would imply a height of 2160.
    dialog.select_collage_size_for_widget_test (CollageSize.UHD_4K);
    assert_contains (dialog.get_collage_size_subtitle_for_widget_test (),
        "3840 × 1620", "the size row spells out the resulting dimensions");
}

// Runs a collage and reports either the finished image's dimensions or the
// message the user would see. Used to pin down how odd inputs are handled.
private string run_collage_for_test (string path, out string failure) {
    string o, er;
    var runner = new CollageRunner ();
    string done = ""; string fail = "";
    runner.collage_done.connect ((r) => { done = r.primary_file_path; });
    runner.collage_failed.connect ((m) => { fail = m; });
    runner.collage_cancelled.connect ((m) => { fail = "cancelled: " + m; });
    runner.run (path);
    spin_main_context_until_deadline (() => {
        return done.length > 0 || fail.length > 0;
    }, 30000);

    failure = fail;
    if (done.length == 0) return "";

    run_command_for_test ({ AppSettings.get_default ().ffprobe_path, "-v", "error",
        "-show_entries", "stream=width,height", "-of", "csv=p=0", done },
        out o, out er, "probe generated collage");
    return o.strip ();
}

// Unlike the post-encode sidecar, which only ever sees a file this app just
// wrote, the standalone window takes whatever the user points it at. Twelve
// capture points spread across a clip with fewer than twelve frames must still
// come out as a whole image, and a file with no video has to be refused with
// something a person can act on rather than an ffmpeg error.
private void test_collage_handles_degenerate_sources () {
    string temp_dir;
    try {
        temp_dir = DirUtils.make_tmp ("collage-degenerate-XXXXXX");
    } catch (Error e) {
        Test.fail_printf ("failed to create degenerate source directory: %s",
            e.message);
        return;
    }

    try {
        string o, er, failure;
        string ff = AppSettings.get_default ().ffmpeg_path;
        CollageSize configured = AppSettings.get_default ().collage_size;
        string expected = "%d,%d".printf (
            configured.image_width (), configured.image_height ());

        string[] names = { "one-frame.mkv", "three-frame.mkv", "half-second.mkv" };
        string[] specs = {
            "testsrc2=size=320x180:rate=10:d=0.1",
            "testsrc2=size=320x180:rate=10:d=0.3",
            "testsrc2=size=320x180:rate=30:d=0.5"
        };
        for (int i = 0; i < names.length; i++) {
            string path = Path.build_filename (temp_dir, names[i]);
            assert_true (
                run_command_for_test ({ ff, "-hide_banner", "-loglevel", "error", "-y",
                    "-f", "lavfi", "-i", specs[i], "-c:v", "ffv1", "-an", path },
                    out o, out er, "create " + names[i]) == 0,
                @"$(names[i]) fixture is created");

            assert_string_equal (run_collage_for_test (path, out failure), expected,
                @"$(names[i]) still produces a full collage");
        }

        // No video stream at all.
        string audio = Path.build_filename (temp_dir, "audio-only.mka");
        assert_true (
            run_command_for_test ({ ff, "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                "-c:a", "flac", audio }, out o, out er, "create audio-only") == 0,
            "audio-only fixture is created");
        assert_string_equal (run_collage_for_test (audio, out failure), "",
            "an audio-only file produces no collage");
        assert_contains (failure, "no video stream",
            "an audio-only file is refused in the user's terms");

        // A video extension over content that is not media at all.
        string junk = Path.build_filename (temp_dir, "not-a-video.mkv");
        FileUtils.set_contents (junk, "this is not a video file at all");
        assert_string_equal (run_collage_for_test (junk, out failure), "",
            "a non-media file produces no collage");
        assert_true (failure.length > 0,
            "a non-media file is refused with a message rather than silence");
    } catch (FileError e) {
        Test.fail_printf ("failed to write degenerate fixture: %s", e.message);
    } finally {
        cleanup_exec_test_dir (temp_dir);
    }
}

// Every size has to divide evenly by the 4x3 grid, or ffmpeg's xstack gets
// tiles whose scaled size does not match the layout offsets it was given.
private void test_collage_sizes_tile_the_grid_exactly () {
    foreach (CollageSize size in CollageSize.all ()) {
        string label = size.get_label ();

        assert_true (size.tile_width () * 9 == size.tile_height () * 16,
            @"$label tile stays 16:9");
        assert_true (size.image_width () == size.tile_width () * 4,
            @"$label image spans four columns");
        assert_true (size.image_height () == size.tile_height () * 3,
            @"$label image spans three rows");
        assert_string_equal (CollageSize.from_string (size.to_string ()).get_label (),
            label, @"$label survives a settings round trip");
    }

    // The size this feature shipped with, before it was configurable. An
    // upgrade must not silently change anyone's collage.
    assert_true (CollageSize.FHD_1080.image_width () == 1920
            && CollageSize.FHD_1080.image_height () == 810,
        "1080p still produces the original 1920x810 collage");
    assert_string_equal (CollageSize.from_string ("nonsense").get_label (), "1080p",
        "an unreadable stored size falls back to the shipped default");
}

private void test_collage_size_reaches_the_ffmpeg_command () {
    var runner = make_conversion_runner_for_test (
        make_basic_conversion_profile_for_test (), 60.0, true, false, false);

    foreach (CollageSize size in CollageSize.all ()) {
        string[] argv = runner.build_collage_argv_for_test (
            "/tmp/in.mkv", "/tmp/out-collage.png", 60.0, 0.0, false, size);

        string filter_complex = "";
        for (int i = 0; i < argv.length - 1; i++) {
            if (argv[i] == "-filter_complex") {
                filter_complex = argv[i + 1];
                break;
            }
        }

        string expected_scale = "scale=%d:%d".printf (
            size.tile_width (), size.tile_height ());
        assert_contains (filter_complex, expected_scale,
            @"$(size.get_label ()) scales tiles to its own size");

        // The layout offsets are pixel positions, so they move with the tile
        // size. A mismatch here is the failure that produces a black collage.
        string expected_last_offset = "%d_%d".printf (
            size.tile_width () * 3, size.tile_height () * 2);
        assert_contains (filter_complex, expected_last_offset,
            @"$(size.get_label ()) places the final tile at its own offset");
        assert_contains (filter_complex, "xstack=inputs=12",
            @"$(size.get_label ()) still stacks twelve frames");
    }
}

// A per-run runner strands itself if the ProcessRunner keeps holding the event
// logger, because that callback owns a reference straight back to the runner.
private void test_collage_runner_does_not_strand_itself () {
    string temp_dir;
    try {
        temp_dir = DirUtils.make_tmp ("collage-lifetime-XXXXXX");
    } catch (Error e) {
        Test.fail_printf ("failed to create collage lifetime directory: %s",
            e.message);
        return;
    }

    try {
        string source_path = Path.build_filename (temp_dir, "clip.mkv");
        string stdout_buf, stderr_buf;

        string[] make_source = {
            AppSettings.get_default ().ffmpeg_path,
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=10:d=3",
            "-c:v", "ffv1", "-an",
            source_path
        };
        assert_true (
            run_command_for_test (make_source, out stdout_buf, out stderr_buf,
                "create collage lifetime source") == 0,
            "collage lifetime source clip is created");

        bool finished = false;
        bool finalized = false;

        // Scoped so the only strong reference is dropped before the assert.
        {
            var runner = new CollageRunner ();
            runner.collage_done.connect (() => { finished = true; });
            runner.collage_failed.connect (() => { finished = true; });
            runner.collage_cancelled.connect (() => { finished = true; });
            runner.weak_ref (() => { finalized = true; });

            runner.run (source_path);
            spin_main_context_until_deadline (() => {
                return finished;
            }, 30000);
        }

        assert_true (finished, "collage lifetime run reaches a terminal signal");
        spin_main_context_until_deadline (() => {
            return finalized;
        }, 2000);
        assert_true (finalized,
            "collage runner is released once its run is over");
    } finally {
        cleanup_exec_test_dir (temp_dir);
    }
}

// The source picker has to be locked while a run is in flight: the run holds
// its own copy of the path, so a change mid-run leaves the window describing
// one file while the result names another.
private void test_collage_window_locks_the_source_while_running () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var window = new CollageWindow (null);

    assert_true (window.is_browse_enabled_for_widget_test (),
        "the source picker is available while idle");

    window.set_generating_for_widget_test (true);
    assert_false (window.is_browse_enabled_for_widget_test (),
        "the source picker is locked while a collage runs");
    assert_false (window.is_generate_enabled_for_widget_test (),
        "Generate cannot be re-triggered while a collage runs");

    window.set_generating_for_widget_test (false);
    assert_true (window.is_browse_enabled_for_widget_test (),
        "the source picker unlocks once the run is over");
}

private void test_collage_window_gates_generate_on_a_real_source () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    string temp_dir;
    try {
        temp_dir = DirUtils.make_tmp ("collage-window-XXXXXX");
    } catch (Error e) {
        Test.fail_printf ("failed to create collage window directory: %s",
            e.message);
        return;
    }

    try {
        var window = new CollageWindow (null);

        assert_false (window.is_generate_enabled_for_widget_test (),
            "collage window starts with Generate disabled");

        string missing_path = Path.build_filename (temp_dir, "absent.mkv");
        window.set_source_path_for_widget_test (missing_path);
        assert_false (window.is_generate_enabled_for_widget_test (),
            "collage window keeps Generate disabled for a missing source");

        string present_path = Path.build_filename (temp_dir, "present.mkv");
        FileUtils.set_contents (present_path, "not really a video");
        window.set_source_path_for_widget_test (present_path);
        assert_true (window.is_generate_enabled_for_widget_test (),
            "collage window enables Generate once the source exists");
        assert_string_equal (
            window.get_output_preview_for_widget_test (),
            Path.build_filename (temp_dir, "present-collage.png"),
            "collage window previews the sidecar path beside the source");

        window.close ();
    } catch (FileError e) {
        Test.fail_printf ("failed to write collage window source: %s", e.message);
    } finally {
        cleanup_exec_test_dir (temp_dir);
    }
}

private void test_process_runner_capture_is_cancellable () {
    var runner = new ProcessRunner ();
    runner.prepare_for_new_execution ();

    int exit_status = 0;
    string captured_stdout = "";
    string captured_stderr = "";
    int64 started_us = GLib.get_monotonic_time ();

    var worker = new Thread<void> ("capture-cancel-test", () => {
        exit_status = runner.execute_capture (
            { "/usr/bin/sleep", "30" },
            out captured_stdout,
            out captured_stderr
        );
    });

    Thread.usleep (150000);
    runner.cancel ();
    worker.join ();

    double elapsed_seconds =
        (GLib.get_monotonic_time () - started_us) / 1000000.0;
    assert_true (exit_status != 0,
        "cancelled capture returns a nonzero status");
    assert_true (runner.is_cancelled (),
        "capture cancellation remains visible to its owner");
    assert_true (elapsed_seconds < 5.0,
        "capture cancellation stops the helper promptly");
}

private void test_converter_progress_prefers_real_video_duration () {
    var config = new ConversionConfig ();
    config.source_span_seconds = 17.766;
    config.video_source_span_seconds = 16.2;

    assert_uint64_equal (
        (uint64) Converter.compute_expected_frame_count_for_test (config, 30.0),
        486,
        "frame progress excludes a container leading timestamp gap"
    );

    config.video_source_span_seconds = 0.0;
    assert_uint64_equal (
        (uint64) Converter.compute_expected_frame_count_for_test (config, 30.0),
        533,
        "frame progress retains container-duration fallback when video timing is unavailable"
    );
}

/**
 * Progress counts output frames, so a speed filter has to be divided out.
 *
 * The span it starts from is source time. FFmpeg re-times to the output frame
 * rate rather than carrying every source frame across, so at 2x roughly half
 * the counted frames are ever written and the bar stalls near the middle;
 * at 0.5x it fills long before the encode ends.
 */
private void test_conversion_frame_count_accounts_for_video_speed () {
    var config = new ConversionConfig ();
    config.source_span_seconds = 20.0;
    config.video_source_span_seconds = 20.0;

    assert_uint64_equal (
        (uint64) Converter.compute_expected_frame_count_for_test (config, 30.0),
        600, "unmodified speed counts one frame per source frame");

    config.profile.video_speed_multiplier = 2.0;
    assert_uint64_equal (
        (uint64) Converter.compute_expected_frame_count_for_test (config, 30.0),
        300, "2x writes half as many frames as the source span suggests");

    config.profile.video_speed_multiplier = 0.5;
    assert_uint64_equal (
        (uint64) Converter.compute_expected_frame_count_for_test (config, 30.0),
        1200, "0.5x writes twice as many");

    // Audio rate is a separate setting and must not move the frame count.
    config.profile.video_speed_multiplier = 1.0;
    config.profile.audio_speed_multiplier = 2.0;
    assert_uint64_equal (
        (uint64) Converter.compute_expected_frame_count_for_test (config, 30.0),
        600, "audio speed leaves the video frame count alone");

    // A nonsense multiplier must not produce an infinite or negative count.
    config.profile.video_speed_multiplier = 0.0;
    assert_uint64_equal (
        (uint64) Converter.compute_expected_frame_count_for_test (config, 30.0),
        600, "an unusable multiplier falls back to unmodified speed");
}

/**
 * The audio fade-out is placed on the post-atempo timeline.
 *
 * merge_profile_audio_filter_chain appends the processing filters after the
 * profile's own, so afade runs downstream of atempo. Offsetting it from the
 * source span puts the fade past the end of a shortened track, where it never
 * fires — the export just stops at full volume.
 */
private void test_conversion_audio_fade_follows_audio_speed () {
    var profile = make_basic_conversion_profile_for_test ();
    profile.audio_filters = "atempo=2.000000";
    profile.audio_speed_multiplier = 2.0;
    profile.audio_processing.fade_out_enabled = true;
    profile.audio_processing.fade_out_duration = 2.0;

    var config = new ConversionConfig ();
    config.profile = profile;
    config.source_span_seconds = 20.0;
    config.timed_stream_topology_known = true;

    var runner = new ConversionRunner.for_command_test (config);
    string[] argv = runner.build_single_pass_argv_for_test (
        "/tmp/input.mkv", "/tmp/output.mkv");

    // 20s of source at 2x is 10s of audio, so the 2s fade starts at 8s —
    // not at 18s, which is past the end of the track entirely.
    string af = get_argv_value_after (argv, "-af", "audio filter chain");
    assert_contains (af, "afade=t=out:st=8",
        "fade-out is offset from the sped-up audio length");
    assert_false (af.contains ("afade=t=out:st=18"),
        "fade-out is not offset from the source span");
}

private void test_conversion_runner_single_frame_collage_integration () {
    string temp_dir;
    try {
        temp_dir = DirUtils.make_tmp ("conversion-single-frame-collage-XXXXXX");
    } catch (Error e) {
        Test.fail_printf ("failed to create single-frame collage directory: %s",
            e.message);
        return;
    }

    try {
        string input_path = Path.build_filename (temp_dir, "single-frame.mkv");
        string collage_path = Path.build_filename (temp_dir, "single-frame-collage.png");
        string stdout_buf, stderr_buf;
        string[] make_input = {
            AppSettings.get_default ().ffmpeg_path,
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=blue:size=320x180:rate=1",
            "-frames:v", "1", "-c:v", "ffv1", "-an",
            input_path
        };
        assert_true (run_command_for_test (
                make_input, out stdout_buf, out stderr_buf,
                "create single-frame collage input") == 0,
            "single-frame collage input is created");

        VideoTimelineProbeResult timeline =
            FfprobeUtils.probe_video_timeline (input_path);
        assert_true (timeline.success, "single-frame timeline is readable");
        assert_uint64_equal ((uint64) timeline.packet_count, 1,
            "single-frame timeline reports one packet");
        assert_true (timeline.packet_count_complete,
            "single-frame classification is based on a complete packet count");

        var profile = make_basic_conversion_profile_for_test ();
        var runner = make_conversion_runner_for_test (profile);
        string[] collage_argv = runner.build_collage_argv_for_test (
            input_path,
            collage_path,
            timeline.get_duration (),
            timeline.start_time,
            true
        );
        assert_array_occurrence_count (collage_argv, "0.000000", 12,
            "single-frame collage samples the sole frame for every tile");

        assert_true (run_command_for_test (
                collage_argv, out stdout_buf, out stderr_buf,
                "generate single-frame collage") == 0,
            "single-frame collage command succeeds");
        assert_true (FileUtils.test (collage_path, FileTest.EXISTS),
            "single-frame collage creates its PNG");
    } finally {
        cleanup_exec_test_dir (temp_dir);
    }
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

private void test_combine_disables_keep_all_audio_at_construction () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();

    // Constraint is applied immediately at construction, even in copy mode.
    // Set the toggle on while constrained to verify state preservation.
    for (uint i = 0; i < 4; i++) {
        harness.window.set_codec_choice_selected_for_widget_test (i);
        BaseCodecTab? tab = harness.window.get_selected_base_codec_tab_for_widget_test ();
        assert_true (tab != null, "selected codec tab exists after construction");
        assert_false (tab.audio_settings.get_keep_all_audio_sensitive_for_test (),
            "combine window disables keep-all at construction in each codec tab");
        assert_contains (
            tab.audio_settings.get_keep_all_audio_subtitle_for_test (),
            "Combine does not support multiple audio tracks",
            "keep-all subtitle explains combine constraint at construction"
        );
        tab.audio_settings.set_keep_all_audio_active_for_test (true);
    }

    // Stays disabled and preserves toggle after switching to reencode
    harness.window.set_copy_mode_switch_active_for_widget_test (false);

    for (uint i = 0; i < 4; i++) {
        harness.window.set_codec_choice_selected_for_widget_test (i);
        BaseCodecTab? tab = harness.window.get_selected_base_codec_tab_for_widget_test ();
        assert_true (tab != null, "selected codec tab exists after reencode switch");
        assert_false (tab.audio_settings.get_keep_all_audio_sensitive_for_test (),
            "keep-all stays disabled after switching to reencode");
        assert_true (tab.audio_settings.get_keep_all_audio_active_for_test (),
            "keep-all toggle state preserved after switching to reencode");
    }

    // Stays disabled and preserves toggle after switching back to copy
    harness.window.set_copy_mode_switch_active_for_widget_test (true);

    for (uint i = 0; i < 4; i++) {
        harness.window.set_codec_choice_selected_for_widget_test (i);
        BaseCodecTab? tab = harness.window.get_selected_base_codec_tab_for_widget_test ();
        assert_true (tab != null, "selected codec tab exists after copy switch");
        assert_false (tab.audio_settings.get_keep_all_audio_sensitive_for_test (),
            "keep-all stays disabled after switching back to copy");
        assert_true (tab.audio_settings.get_keep_all_audio_active_for_test (),
            "keep-all toggle state preserved after switching back to copy");
    }

    harness.window.close ();
}

private void test_closing_combine_window_releases_keep_all_audio_constraint () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();

    // Set toggle on while constrained — state should survive
    for (uint i = 0; i < 4; i++) {
        harness.window.set_codec_choice_selected_for_widget_test (i);
        BaseCodecTab? tab = harness.window.get_selected_base_codec_tab_for_widget_test ();
        assert_true (tab != null, "selected codec tab exists before keep-all close release");
        tab.audio_settings.set_keep_all_audio_active_for_test (true);
    }

    harness.window.invoke_close_request_for_widget_test ();

    for (uint i = 0; i < 4; i++) {
        harness.window.set_codec_choice_selected_for_widget_test (i);
        BaseCodecTab? tab = harness.window.get_selected_base_codec_tab_for_widget_test ();
        assert_true (tab != null, "selected codec tab exists after keep-all close release");
        assert_true (tab.audio_settings.get_keep_all_audio_sensitive_for_test (),
            "closing combine re-enables keep-all in each codec tab");
        assert_true (tab.audio_settings.get_keep_all_audio_active_for_test (),
            "closing combine preserves keep-all toggle state in each codec tab");
        assert_string_equal (
            tab.audio_settings.get_keep_all_audio_subtitle_for_test (),
            "Preserve all source audio tracks in the output",
            "closing combine restores keep-all subtitle in each codec tab"
        );
    }
}

private void test_trim_style_clear_does_not_clear_keep_all_audio_while_combine_is_open () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();

    for (uint i = 0; i < 4; i++) {
        harness.window.set_codec_choice_selected_for_widget_test (i);
        BaseCodecTab? tab = harness.window.get_selected_base_codec_tab_for_widget_test ();
        assert_true (tab != null, "selected codec tab exists for trim-style keep-all clear");
        assert_false (tab.audio_settings.get_keep_all_audio_sensitive_for_test (),
            "combine constrains keep-all before trim-style clear");

        tab.audio_settings.set_keep_all_audio_active_for_test (true);
        tab.audio_settings.clear_keep_all_audio ();

        assert_true (tab.audio_settings.get_keep_all_audio_active_for_test (),
            "trim-style clear does not wipe preserved keep-all state while combine is open");
        assert_false (tab.audio_settings.get_keep_all_audio_sensitive_for_test (),
            "combine constraint remains active after trim-style clear");
    }

    harness.window.invoke_close_request_for_widget_test ();

    for (uint i = 0; i < 4; i++) {
        harness.window.set_codec_choice_selected_for_widget_test (i);
        BaseCodecTab? tab = harness.window.get_selected_base_codec_tab_for_widget_test ();
        assert_true (tab != null, "selected codec tab exists after trim-style clear release");
        assert_true (tab.audio_settings.get_keep_all_audio_sensitive_for_test (),
            "closing combine restores keep-all sensitivity after trim-style clear");
        assert_true (tab.audio_settings.get_keep_all_audio_active_for_test (),
            "closing combine still preserves keep-all state after trim-style clear");
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

// ═════════════════════════════════════════════════════════════════════════════
//  WATERMARK CONSTRAINT TESTS
// ═════════════════════════════════════════════════════════════════════════════

private void configure_watermark_state (GeneralTab general,
                                        bool enabled,
                                        string text) {
    general.watermark_text.set_text (text);
    general.watermark_check.set_active (enabled);
}

private void test_active_watermark_forces_reencode () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();
    GeneralTab general = harness.window.get_general_tab_for_widget_test ();

    configure_watermark_state (general, true, "Test Watermark");

    // Switch to re-encode to trigger constraint sync
    harness.window.set_copy_mode_switch_active_for_widget_test (false);

    assert_true (harness.window.get_watermark_forces_reencode_for_widget_test (),
        "watermark forces re-encode when active");
    assert_false (harness.window.is_copy_mode_sensitive_for_widget_test (),
        "copy mode switch disabled when watermark active");

    harness.window.close ();
}

private void test_clearing_watermark_text_releases_constraint () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();
    GeneralTab general = harness.window.get_general_tab_for_widget_test ();

    configure_watermark_state (general, true, "Test Watermark");
    harness.window.set_copy_mode_switch_active_for_widget_test (false);

    // Clear the text — watermark becomes effectively inactive
    general.watermark_text.set_text ("");
    spin_main_context_until (() => {
        return !harness.window.get_watermark_forces_reencode_for_widget_test ();
    });

    assert_false (harness.window.get_watermark_forces_reencode_for_widget_test (),
        "watermark constraint released after clearing text");

    harness.window.close ();
}

private void test_watermark_effective_state_requires_text () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var harness = new CombineWindowHarness ();
    GeneralTab general = harness.window.get_general_tab_for_widget_test ();

    // Switch on but no text — should not be effectively enabled
    general.watermark_check.set_active (true);
    assert_false (general.is_watermark_effectively_enabled (),
        "watermark not effective with empty text");

    // Add text — now effective
    general.watermark_text.set_text ("Hello");
    assert_true (general.is_watermark_effectively_enabled (),
        "watermark effective with switch on and text present");

    // Switch off — not effective
    general.watermark_check.set_active (false);
    assert_false (general.is_watermark_effectively_enabled (),
        "watermark not effective when switch is off");

    harness.window.close ();
}

private void test_drawtext_unavailable_disables_watermark_ui () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var general = new GeneralTab ();
    general.watermark_text.set_text ("Sample");
    general.watermark_check.set_active (true);

    general.set_drawtext_available (false, "Unavailable — missing drawtext");

    // Expander stays sensitive because overlay is still available —
    // user can switch to Image mode.
    assert_true (general.get_watermark_expander_sensitive_for_widget_test (),
        "watermark expander stays sensitive when overlay is available");
    assert_false (general.is_watermark_effectively_enabled (),
        "text watermark is not effective when drawtext is unavailable");
    assert_contains (general.get_watermark_subtitle_for_widget_test (),
        "missing drawtext",
        "watermark subtitle explains drawtext unavailability");

    // Fully disable both filters — now the whole expander should lock out
    general.set_overlay_available (false, "Unavailable — missing overlay");
    assert_false (general.get_watermark_expander_sensitive_for_widget_test (),
        "watermark UI fully disabled when neither filter is available");
}

private void test_svt_av1_crf_two_pass_probe_reports_supported () {
    string? dir = null;

    try {
        dir = DirUtils.make_tmp ("svt-probe-supported-XXXXXX");
        string fake_ffmpeg = make_fake_svt_probe_ffmpeg (dir, "fake-ffmpeg", true);

        SvtAv1CrfTwoPassCapability capability =
            run_svt_crf_two_pass_probe_for_test (fake_ffmpeg, "supported probe");

        assert_true (
            capability.status == SvtAv1CrfTwoPassCapabilityStatus.SUPPORTED,
            "supported probe status"
        );
        assert_contains (
            capability.reason ?? "",
            "supported",
            "supported probe reason"
        );
    } catch (FileError e) {
        Test.fail_printf ("failed to create supported probe temp dir: %s", e.message);
    } finally {
        if (dir != null) {
            cleanup_exec_test_dir (dir);
        }
    }
}

private void test_svt_av1_crf_two_pass_probe_reports_unsupported () {
    string? dir = null;

    try {
        dir = DirUtils.make_tmp ("svt-probe-unsupported-XXXXXX");
        string fake_ffmpeg = make_fake_svt_probe_ffmpeg (dir, "fake-ffmpeg", false);

        SvtAv1CrfTwoPassCapability capability =
            run_svt_crf_two_pass_probe_for_test (fake_ffmpeg, "unsupported probe");

        assert_true (
            capability.status == SvtAv1CrfTwoPassCapabilityStatus.UNSUPPORTED,
            "unsupported probe status"
        );
        assert_contains (
            capability.reason ?? "",
            "unsupported",
            "unsupported probe reason"
        );
    } catch (FileError e) {
        Test.fail_printf ("failed to create unsupported probe temp dir: %s", e.message);
    } finally {
        if (dir != null) {
            cleanup_exec_test_dir (dir);
        }
    }
}

private void test_svt_av1_crf_two_pass_probe_prefers_error_over_info () {
    string? dir = null;

    try {
        dir = DirUtils.make_tmp ("svt-probe-error-detail-XXXXXX");
        string fake_ffmpeg = make_fake_svt_probe_ffmpeg_with_generic_error (
            dir,
            "fake-ffmpeg"
        );

        SvtAv1CrfTwoPassCapability capability =
            run_svt_crf_two_pass_probe_for_test (fake_ffmpeg, "generic error probe");

        assert_true (
            capability.status == SvtAv1CrfTwoPassCapabilityStatus.ERROR,
            "generic error probe status"
        );
        assert_contains (
            capability.reason ?? "",
            "Error opening output files",
            "generic error probe reason prefers error line"
        );
    } catch (FileError e) {
        Test.fail_printf ("failed to create generic error probe temp dir: %s", e.message);
    } finally {
        if (dir != null) {
            cleanup_exec_test_dir (dir);
        }
    }
}

private void test_vmaf_filter_parser_requires_exact_libvmaf_name () {
    assert_false (
        FfmpegRuntimeCapabilities.filter_listing_has_libvmaf (
            " .. vmafmotion        V->V       Calculate VMAF Motion\n"),
        "vmafmotion alone must not satisfy the Quality Target guard");
    assert_true (
        FfmpegRuntimeCapabilities.filter_listing_has_libvmaf (
            " ..\tlibvmaf\tVV->V\tCalculate VMAF\n"),
        "exact libvmaf filter is accepted with tab-separated fields");
}

private void test_encoder_pixel_format_parser_requires_exact_token () {
    string listing =
        "Encoder libx264 [libx264 H.264]:\n"
        + "    Supported pixel formats: yuv420p yuv422p yuv420p10le yuv422p10le\n";
    assert_true (
        FfmpegRuntimeCapabilities.encoder_listing_supports_pixel_format (
            listing, "yuv420p10le"),
        "libx264 High10 format is detected");
    assert_false (
        FfmpegRuntimeCapabilities.encoder_listing_supports_pixel_format (
            listing, "yuv420p10"),
        "partial pixel-format names must not match");
    assert_false (
        FfmpegRuntimeCapabilities.encoder_listing_supports_pixel_format (
            "Option help mentions yuv420p10le but no supported-format line\n",
            "yuv420p10le"),
        "unrelated help text must not satisfy the capability guard");
}

private void test_vmaf_probe_reports_supported_and_unsupported () {
    string? dir = null;
    try {
        dir = DirUtils.make_tmp ("vmaf-probe-XXXXXX");
        string supported_ffmpeg = make_fake_vmaf_probe_ffmpeg (
            dir, "ffmpeg-with-vmaf", true);
        string unsupported_ffmpeg = make_fake_vmaf_probe_ffmpeg (
            dir, "ffmpeg-without-vmaf", false);

        VmafCapability supported = run_vmaf_probe_for_test (
            supported_ffmpeg, "supported VMAF");
        VmafCapability unsupported = run_vmaf_probe_for_test (
            unsupported_ffmpeg, "unsupported VMAF");

        assert_true (supported.status == VmafCapabilityStatus.SUPPORTED,
            "libvmaf filter reports supported");
        assert_true (unsupported.status == VmafCapabilityStatus.UNSUPPORTED,
            "missing libvmaf filter reports unsupported");
        assert_contains (unsupported.reason ?? "", "Target Size remains available",
            "unsupported message preserves the size solver");
    } catch (FileError e) {
        Test.fail_printf ("failed to create VMAF probe temp dir: %s", e.message);
    } finally {
        if (dir != null)
            cleanup_exec_test_dir (dir);
    }
}

private void test_vmaf_probe_reports_binary_errors_separately () {
    string? dir = null;
    try {
        dir = DirUtils.make_tmp ("vmaf-probe-error-XXXXXX");
        string broken_ffmpeg = make_fake_vmaf_probe_ffmpeg (
            dir, "broken-ffmpeg", false, false);
        VmafCapability capability = run_vmaf_probe_for_test (
            broken_ffmpeg, "VMAF binary error");

        assert_true (capability.status == VmafCapabilityStatus.ERROR,
            "failed FFmpeg invocation is an error, not an unsupported build");
        assert_contains (capability.reason ?? "", "configured ffmpeg failed",
            "binary error keeps the useful diagnostic");
    } catch (FileError e) {
        Test.fail_printf ("failed to create VMAF error temp dir: %s", e.message);
    } finally {
        if (dir != null)
            cleanup_exec_test_dir (dir);
    }
}

private void test_smart_optimizer_report_includes_native_sharpness_decision () {
    var rec = OptimizationRecommendation () {
        codec = "svt-av1",
        crf = 21,
        preset = "preset 7",
        estimated_size_kib = 16212,
        notes = "",
        content_type = ContentType.MIXED,
        confidence = 0.87,
        recommended_pix_fmt = "yuv420p",
        detail_score = 0.63,
        native_sharpness = 2,
        effort = EncodeEffort.MAXIMUM,
        pinned_axis = PinnedAxis.QUALITY,
        keyint_frames = 120,
        keyint_seconds = 5.0,
        lookahead_frames = 61,
        motion_variability = 0.57,
        cuts_per_minute = 4.5,
        static_frame_ratio = 0.18,
        temporal_reason = "variable motion"
    };

    string enabled = SmartOptimizer.format_recommendation (rec);
    assert_contains (enabled, "Quality-model confidence: 87%",
        "quality report identifies confidence as belonging to its model");
    assert_contains (enabled, "Sharpness:      level 2 (detail score 63%)",
        "SVT-AV1 report states the applied sharpness level and signal");
    assert_contains (enabled,
        "Keyframes:      ≤ 120 frames (5.0s maximum; scene cuts enabled)",
        "report states the signal-selected maximum GOP");
    assert_contains (enabled, "Lookahead:      61 frames",
        "report states the applied lookahead");
    assert_contains (enabled,
        "Temporal signal: motion CV 0.57, cuts 4.5/min, static frames 18%",
        "report exposes the temporal signals behind the decision");

    rec.pinned_axis = PinnedAxis.SIZE;
    rec.two_pass = true;
    rec.target_size_kib = 3072;
    rec.target_bitrate_kbps = 283;
    rec.confidence = 1.0;
    rec.expected_size_error_fraction = 0.066;
    rec.expected_final_size_kib = 2988;
    rec.final_size_basis = "video ±6%, audio ±3%, container reserve ±50%";
    rec.calibration_fit_rmse = 0.017;
    rec.calibration_fit_informative = true;
    rec.notes = "SVT-AV1 two-pass quirk: the encoder may reduce the requested lookahead to a compatible value.";
    string size_target = SmartOptimizer.format_recommendation (rec);
    assert_contains (size_target,
        "Calibration confidence: 100% (CRF size model; residual ±1.7%)",
        "size report distinguishes CRF calibration confidence");
    assert_contains (size_target,
        "Planning uncertainty: approximately ±7% (bitrate/audio/container estimate)",
        "size report describes modeled final-size error as planning uncertainty");
    assert_contains (size_target, "Requested size: 3072 KiB",
        "two-pass header identifies the requested size as a target");
    assert_contains (size_target,
        "Est. size:      ~2988 KiB (via two-pass @ 283 kbps)",
        "two-pass header uses the independently budgeted estimate");
    assert_contains (size_target,
        "Expected final size: ~2988 KiB (approximately ±7%)",
        "size report gives the final-size planning range");
    assert_contains (size_target,
        "Final-size basis: video ±6%, audio ±3%, container reserve ±50%; may vary above or below target",
        "size report explains both uncertainty directions and inputs");
    assert_contains (size_target,
        "SVT-AV1 two-pass quirk: the encoder may reduce the requested lookahead to a compatible value.",
        "size report documents SVT's automatic two-pass lookahead adjustment");

    rec.codec = "vp9";
    rec.pinned_axis = PinnedAxis.QUALITY;
    rec.two_pass = false;
    rec.detail_score = 0.12;
    rec.native_sharpness = 0;
    string disabled = SmartOptimizer.format_recommendation (rec);
    assert_contains (disabled,
        "Sharpness:      disabled (detail score 12% — below threshold)",
        "VP9 report explains a disabled sharpness decision");

    rec.codec = "x265";
    string deferred_codec = SmartOptimizer.format_recommendation (rec);
    assert_false (deferred_codec.contains ("Sharpness:"),
        "x264/x265 do not claim a native sharpness decision");
}

private void test_conversion_report_compares_smart_target_with_actual_bytes () {
    string report = ConversionRunner.format_smart_size_comparison (
        3072, 2989, 0.07, 2922516);
    assert_contains (report, "Requested:  3072 KiB",
        "completion report preserves the optimizer's exact requested size");
    assert_contains (report, "Planned:    2989 KiB (approximately ±7%)",
        "completion report preserves the independently planned size");
    assert_contains (report, "Actual:     2854 KiB",
        "completion report derives actual KiB from filesystem bytes");
    assert_contains (report, "Requested difference: -218 KiB (-7.1%)",
        "completion report compares actual size with the requested maximum");
    assert_contains (report,
        "Planned difference:   -135 KiB (-4.5%; within ±7% uncertainty)",
        "completion report evaluates the planning model against its uncertainty");
    assert_true (ConversionRunner.format_smart_size_comparison (
        0, 0, 0.0, 2922516) == "",
        "ordinary conversions do not receive a Smart Optimizer size report");
}

private void test_smart_optimizer_direct_args_include_temporal_tuning () {
    var rec = OptimizationRecommendation () {
        codec = "x264",
        crf = 23,
        preset = "slow",
        recommended_pix_fmt = "yuv420p",
        keyint_frames = 120,
        lookahead_frames = 60,
        native_sharpness = 1
    };

    string[] x264 = CodecUtils.build_smart_codec_args (rec);
    assert_array_has_adjacent_pair (x264, "-g", "120",
        "x264 direct args apply the temporal keyframe interval");
    assert_array_has_adjacent_pair (x264, "-x264-params", "rc-lookahead=60",
        "x264 direct args apply the selected lookahead");

    rec.codec = "x265";
    string[] x265 = CodecUtils.build_smart_codec_args (rec);
    assert_array_has_adjacent_pair (x265, "-g", "120",
        "x265 direct args apply the temporal keyframe interval");
    assert_array_has_adjacent_pair (x265, "-x265-params", "rc-lookahead=60",
        "x265 direct args apply the selected lookahead");

    rec.codec = "vp9";
    rec.preset = "cpu-used 5";
    rec.lookahead_frames = 25;
    string[] vp9 = CodecUtils.build_smart_codec_args (rec);
    assert_array_has_adjacent_pair (vp9, "-g", "120",
        "VP9 direct args apply the temporal keyframe interval");
    assert_array_has_adjacent_pair (vp9, "-lag-in-frames", "25",
        "VP9 direct args apply the selected lookahead");
    assert_array_has_adjacent_pair (vp9, "-sharpness", "1",
        "VP9 direct args retain the native sharpness decision");

    rec.codec = "svt-av1";
    rec.preset = "preset 4";
    rec.lookahead_frames = 42;
    string[] svt = CodecUtils.build_smart_codec_args (rec);
    assert_array_has_adjacent_pair (svt, "-g", "120",
        "SVT-AV1 direct args apply the temporal keyframe interval");
    assert_array_has_adjacent_pair (svt, "-svtav1-params",
        "lookahead=42:sharpness=1",
        "SVT-AV1 direct args combine lookahead and sharpness");
}

private void test_smart_optimizer_applies_temporal_tuning_to_codec_tabs () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var rec = OptimizationRecommendation () {
        crf = 24,
        effort = EncodeEffort.MEDIUM,
        content_type = ContentType.LIVE_ACTION,
        source_bit_depth = 10,
        recommended_pix_fmt = "yuv420p10le",
        resolved_container = "mkv",
        keyint_frames = 173,
        lookahead_frames = 40,
        audio_encode_kbps = 192
    };

    rec.codec = "x264";
    rec.preset = "medium";
    var x264 = new X264Tab ();
    CodecPresets.apply_smart_x264 (x264, rec);
    assert_true (CodecUtils.get_dropdown_text (x264.keyint_combo) == "173",
        "x264 tab receives an exact signal-selected GOP");
    assert_true ((int) x264.lookahead_spin.get_value () == 40,
        "x264 tab receives signal-selected lookahead");
    PixelFormatSettingsSnapshot x264_format =
        x264.snapshot_pixel_format_settings ();
    assert_true (x264_format.ten_bit_selected,
        "x264 tab receives Smart Optimizer's 10-bit recommendation");
    assert_true (CodecUtils.get_dropdown_text (x264.profile_combo) == "High10",
        "x264 Smart Optimizer profile matches its 10-bit output");

    rec.codec = "x265";
    rec.preset = "medium";
    var x265 = new X265Tab ();
    CodecPresets.apply_smart_x265 (x265, rec);
    assert_true (CodecUtils.get_dropdown_text (x265.keyint_combo) == "173",
        "x265 tab receives an exact signal-selected GOP");
    assert_true ((int) x265.lookahead_spin.get_value () == 40,
        "x265 tab receives signal-selected lookahead");
    PixelFormatSettingsSnapshot x265_format =
        x265.snapshot_pixel_format_settings ();
    assert_true (x265_format.ten_bit_selected,
        "x265 tab receives Smart Optimizer's 10-bit recommendation");
    assert_true (CodecUtils.get_dropdown_text (x265.profile_combo) == "Main10",
        "x265 Smart Optimizer profile matches its 10-bit output");
    var x265_general = new GeneralSettingsSnapshot ();
    x265_general.pixel_format = x265_format.copy ();
    EncodeProfileSnapshot x265_profile = CodecUtils.snapshot_encode_profile (
        x265.get_codec_builder (), x265, x265_general);
    assert_string_equal (x265_profile.overlay_format, "yuv420p10",
        "Smart x265 profile carries 10-bit into overlay filters");
    assert_contains (x265_profile.video_filters, "format=yuv420p10le",
        "Smart x265 profile carries 10-bit into the video filter chain");
    assert_array_has_adjacent_pair (x265_profile.codec_args,
        "-pix_fmt", PixelFormat.YUV420P10LE,
        "Smart x265 profile carries 10-bit into encoder arguments");

    rec.codec = "vp9";
    rec.preset = "cpu-used 5";
    rec.resolved_container = "webm";
    rec.lookahead_frames = 25;
    var vp9 = new Vp9Tab ();
    CodecPresets.apply_smart_vp9 (vp9, rec);
    assert_true (CodecUtils.get_dropdown_text (vp9.keyint_combo) == "173",
        "VP9 tab receives an exact signal-selected GOP");
    assert_true ((int) vp9.lag_in_frames_spin.get_value () == 25,
        "VP9 tab receives signal-selected lookahead");
    PixelFormatSettingsSnapshot vp9_format =
        vp9.snapshot_pixel_format_settings ();
    assert_true (vp9_format.ten_bit_selected,
        "VP9 tab receives Smart Optimizer's 10-bit recommendation");
    assert_true (CodecUtils.get_dropdown_text (vp9.profile_combo)
            == "Profile 2 (10-bit 4:2:0)",
        "VP9 Smart Optimizer profile matches its 10-bit output");

    rec.codec = "svt-av1";
    rec.preset = "preset 7";
    rec.lookahead_frames = 42;
    var svt = new SvtAv1Tab ();
    CodecPresets.apply_smart_svt_av1 (svt, rec);
    assert_true (CodecUtils.get_dropdown_text (svt.keyint_combo) == "173",
        "SVT-AV1 tab receives an exact signal-selected GOP");
    assert_true ((int) svt.lookahead_spin.get_value () == 42,
        "SVT-AV1 tab receives the two-pass-compatible lookahead");
    PixelFormatSettingsSnapshot svt_format =
        svt.snapshot_pixel_format_settings ();
    assert_true (svt_format.ten_bit_selected,
        "SVT-AV1 tab receives Smart Optimizer's 10-bit recommendation");

    rec.source_bit_depth = 8;
    rec.recommended_pix_fmt = PixelFormat.YUV420P;

    rec.codec = "x264";
    rec.preset = "medium";
    CodecPresets.apply_smart_x264 (x264, rec);
    assert_true (x264.snapshot_pixel_format_settings ().eight_bit_selected,
        "x264 tab can transition to Smart Optimizer's 8-bit recommendation");
    assert_true (CodecUtils.get_dropdown_text (x264.profile_combo) == "High",
        "x264 Smart Optimizer selects the matching 8-bit profile");

    rec.codec = "x265";
    CodecPresets.apply_smart_x265 (x265, rec);
    assert_true (x265.snapshot_pixel_format_settings ().eight_bit_selected,
        "x265 tab can transition to Smart Optimizer's 8-bit recommendation");
    assert_true (CodecUtils.get_dropdown_text (x265.profile_combo) == "Main",
        "x265 Smart Optimizer selects the matching 8-bit profile");

    rec.codec = "vp9";
    rec.preset = "cpu-used 5";
    rec.resolved_container = "webm";
    CodecPresets.apply_smart_vp9 (vp9, rec);
    assert_true (vp9.snapshot_pixel_format_settings ().eight_bit_selected,
        "VP9 tab can transition to Smart Optimizer's 8-bit recommendation");
    assert_true (CodecUtils.get_dropdown_text (vp9.profile_combo)
            == "Profile 0 (8-bit 4:2:0)",
        "VP9 Smart Optimizer selects the matching 8-bit profile");

    rec.codec = "svt-av1";
    rec.preset = "preset 7";
    CodecPresets.apply_smart_svt_av1 (svt, rec);
    assert_true (svt.snapshot_pixel_format_settings ().eight_bit_selected,
        "SVT-AV1 tab can transition to Smart Optimizer's 8-bit recommendation");
}

private void test_svt_av1_crf_two_pass_capability_updates_visibility () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var svt = new SvtAv1Tab ();
    svt.rc_mode_combo.set_selected (0);

    var unsupported = new SvtAv1CrfTwoPassCapability ();
    unsupported.status = SvtAv1CrfTwoPassCapabilityStatus.UNSUPPORTED;
    unsupported.reason = "Unsupported by current ffmpeg build";
    svt.set_crf_two_pass_capability (unsupported);

    assert_false (
        svt.get_two_pass_row_visible_for_widget_test (),
        "svt two-pass hidden when crf two-pass is unsupported"
    );

    svt.rc_mode_combo.set_selected (1);
    assert_false (
        svt.get_two_pass_row_visible_for_widget_test (),
        "svt two-pass hidden when qp two-pass is unsupported"
    );

    svt.rc_mode_combo.set_selected (2);
    assert_true (
        svt.get_two_pass_row_visible_for_widget_test (),
        "svt two-pass visible in vbr regardless of crf capability"
    );
    assert_contains (
        svt.get_two_pass_subtitle_for_widget_test (),
        "Slower but better quality distribution",
        "svt vbr two-pass keeps default subtitle"
    );

    var supported = new SvtAv1CrfTwoPassCapability ();
    supported.status = SvtAv1CrfTwoPassCapabilityStatus.SUPPORTED;
    supported.reason = "Supported by current ffmpeg build";
    svt.set_crf_two_pass_capability (supported);

    assert_true (
        svt.get_two_pass_row_visible_for_widget_test (),
        "svt two-pass remains visible for vbr when crf two-pass is supported"
    );

    svt.rc_mode_combo.set_selected (0);
    assert_true (
        svt.get_two_pass_row_visible_for_widget_test (),
        "svt two-pass visible when crf two-pass is supported"
    );
    assert_contains (
        svt.get_two_pass_subtitle_for_widget_test (),
        "verified for the current FFmpeg build",
        "svt two-pass subtitle explains supported state"
    );

    svt.rc_mode_combo.set_selected (1);
    assert_true (
        svt.get_two_pass_row_visible_for_widget_test (),
        "svt two-pass visible when qp two-pass is supported"
    );
}

private void test_svt_av1_crf_two_pass_backstop_fails_fast () {
    if (!ensure_gtk_widget_tests_available ()) return;

    string? dir = null;

    try {
        dir = DirUtils.make_tmp ("svt-backstop-XXXXXX");
        string input = make_exec_test_media_file (dir, "input.mkv");
        string output = Path.build_filename (dir, "output.webm");

        var status_area = new StatusArea ();
        var console_tab = new ConsoleTab ();
        var general_tab = new GeneralTab ();
        var converter = new Converter (status_area, console_tab, general_tab);
        var svt_tab = new SvtAv1Tab ();
        var builder = new SvtAv1Builder (svt_tab);

        var unsupported = new SvtAv1CrfTwoPassCapability ();
        unsupported.status = SvtAv1CrfTwoPassCapabilityStatus.UNSUPPORTED;
        unsupported.reason = "Unsupported by current ffmpeg build";
        converter.set_svt_crf_two_pass_capability (unsupported);
        svt_tab.rc_mode_combo.set_selected (1);
        svt_tab.two_pass_switch.set_active (true);

        bool failed = false;
        converter.conversion_failed.connect ((operation_id) => {
            failed = true;
        });

        assert_true (
            converter.start_conversion (input, output, svt_tab, builder, 77),
            "svt backstop conversion starts"
        );
        assert_true (
            spin_main_context_until (() => { return failed; }, 500),
            "svt backstop conversion fails"
        );

        string status_text;
        string status_icon;
        string status_css;
        status_area.get_full_status_snapshot (out status_text, out status_icon, out status_css);
        assert_contains (
            status_text,
            "Unsupported by current ffmpeg build",
            "svt backstop status explains unsupported state"
        );
    } catch (FileError e) {
        Test.fail_printf ("failed to create svt backstop temp dir: %s", e.message);
    } finally {
        if (dir != null) {
            cleanup_exec_test_dir (dir);
        }
    }
}

/** The SVT-AV1 parameter list for one AQ Mode choice, split on ':'. */
private string[] svt_av1_params_for_aq_mode (string aq_mode, int strength) {
    var snapshot = new SvtAv1BuilderSnapshot ();
    snapshot.aq_mode = aq_mode;
    snapshot.aq_strength = strength;
    // A thread count keeps -svtav1-params present for every AQ choice.
    snapshot.threads = "2";
    string[] args = SvtAv1Builder.build_args_from_snapshot (snapshot);
    return get_argv_value_after (args, "-svtav1-params",
        "SVT-AV1 AQ " + aq_mode).split (":");
}

private void assert_codec_param_key_absent (string[] codec_params,
                                            string key,
                                            string context) {
    foreach (string param in codec_params) {
        if (param.has_prefix (key + "=")) {
            Test.fail_printf ("%s did not expect '%s'", context, param);
            return;
        }
    }
}

private void test_svt_av1_aq_variance_enables_variance_boost () {
    // SVT-AV1 4.2 logs "Variance AQ based on segmentation with Variance
    // Boost not supported, disabling Variance Boost" for aq-mode=1, so the
    // Variance choice must add the boost without selecting aq-mode=1.
    string[] variance = svt_av1_params_for_aq_mode ("Variance", 3);
    assert_array_contains (variance, "enable-variance-boost=1",
        "Variance enables Variance Boost");
    assert_array_contains (variance, "variance-boost-strength=3",
        "Variance carries the AQ Strength");
    assert_codec_param_key_absent (variance, "aq-mode",
        "Variance keeps the rate-control aq-mode");

    string[] automatic = svt_av1_params_for_aq_mode ("Automatic", 3);
    assert_codec_param_key_absent (automatic, "aq-mode",
        "Automatic leaves aq-mode to the encoder");
    assert_codec_param_key_absent (automatic, "enable-variance-boost",
        "Automatic leaves Variance Boost off");
    assert_codec_param_key_absent (automatic, "variance-boost-strength",
        "Automatic sends no boost strength");

    string[] disabled = svt_av1_params_for_aq_mode ("Disabled", 3);
    assert_array_contains (disabled, "aq-mode=0",
        "Disabled turns adaptive quantization off");
    assert_codec_param_key_absent (disabled, "enable-variance-boost",
        "Disabled leaves Variance Boost off");

    string[] complexity = svt_av1_params_for_aq_mode ("Complexity", 3);
    assert_array_contains (complexity, "aq-mode=2",
        "Complexity selects delta-q AQ");
    assert_codec_param_key_absent (complexity, "enable-variance-boost",
        "Complexity leaves Variance Boost off");
}

/** An x265 snapshot holding the tab's defaults, not the class defaults. */
private X265BuilderSnapshot x265_tab_default_snapshot () {
    var snapshot = new X265BuilderSnapshot ();
    snapshot.ref_frames = "Auto";
    snapshot.deblock_enabled = true;
    snapshot.psy_rd_enabled = true;
    snapshot.psy_rd = 2.0;
    // A thread count keeps -x265-params present for every case.
    snapshot.threads = "2";
    return snapshot;
}

/** The x265-params list the builder produces for @snapshot, split on ':'. */
private string[] x265_params_for (X265BuilderSnapshot snapshot, string context) {
    return get_argv_value_after (X265Builder.build_args_from_snapshot (snapshot),
        "-x265-params", context).split (":");
}

private void test_x265_level_reaches_encoder_in_main_tier () {
    // libx265 ignores FFmpeg's generic -level; x265 4.3 kept the automatic
    // level for every choice until it was sent as level-idc.
    var snapshot = x265_tab_default_snapshot ();
    snapshot.level = "4.1";
    assert_array_not_contains (X265Builder.build_args_from_snapshot (snapshot),
        "-level:v", "x265 Level does not use FFmpeg's ignored -level");
    string[] level = x265_params_for (snapshot, "x265 Level 4.1");
    assert_array_contains (level, "level-idc=4.1", "x265 Level reaches x265");
    assert_array_contains (level, "high-tier=0",
        "x265 Level stays in the widely decodable Main tier");

    snapshot.level = "Auto";
    string[] automatic = x265_params_for (snapshot, "x265 Level Auto");
    assert_codec_param_key_absent (automatic, "level-idc",
        "x265 Level Auto leaves the level to the encoder");
    assert_codec_param_key_absent (automatic, "high-tier",
        "x265 Level Auto leaves the tier to the encoder");
}

private void test_x265_default_psy_rd_and_deblock_leave_tune_alone () {
    // -x265-params is applied after -tune, so sending x265's defaults undid
    // what psnr, ssim, grain, animation and fastdecode set.
    var snapshot = x265_tab_default_snapshot ();
    snapshot.tune = "animation";
    string[] defaults = x265_params_for (snapshot, "x265 tab defaults");
    assert_codec_param_key_absent (defaults, "psy-rd",
        "default psy-rd leaves the tune's value");
    assert_codec_param_key_absent (defaults, "deblock",
        "default deblock leaves the tune's offsets");
    assert_codec_param_key_absent (defaults, "no-deblock",
        "default deblock stays enabled");

    snapshot.psy_rd = 3.0;
    snapshot.deblock_alpha = -1;
    snapshot.deblock_beta = -1;
    string[] chosen = x265_params_for (snapshot, "x265 chosen values");
    assert_array_contains (chosen, "psy-rd=3.0", "a chosen psy-rd still applies");
    assert_array_contains (chosen, "deblock=-1,-1", "chosen deblock offsets still apply");

    snapshot.psy_rd_enabled = false;
    snapshot.deblock_enabled = false;
    string[] disabled = x265_params_for (snapshot, "x265 disabled filters");
    assert_array_contains (disabled, "psy-rd=0", "disabled psy-rd turns it off");
    assert_array_contains (disabled, "no-deblock=1", "disabled deblock turns it off");

    // Calibration shares this rule, so it measures what the encode sends.
    assert_false (X265Builder.psy_rd_differs_from_default (2.0),
        "psy-rd 2.0 is x265's default");
    assert_true (X265Builder.psy_rd_differs_from_default (2.5),
        "psy-rd 2.5 must be sent");
    assert_true (X265Builder.psy_rd_differs_from_default (3.5),
        "Smart Codec's high-effort psy-rd must be sent");
}

private void test_vp9_speed_follows_deadline () {
    // libvpx 1.17 encodes Speed 6–8 exactly as 5 with Good and Best.
    var snapshot = new Vp9BuilderSnapshot ();
    snapshot.speed = 8;
    snapshot.quality_deadline = "good";
    assert_array_has_adjacent_pair (Vp9Builder.build_args_from_snapshot (snapshot),
        "-cpu-used", "5", "Good sends Speed 8 as the 5 it encodes at");
    snapshot.quality_deadline = "best";
    assert_array_has_adjacent_pair (Vp9Builder.build_args_from_snapshot (snapshot),
        "-cpu-used", "5", "Best sends Speed 8 as 5");
    snapshot.quality_deadline = "realtime";
    assert_array_has_adjacent_pair (Vp9Builder.build_args_from_snapshot (snapshot),
        "-cpu-used", "8", "Realtime keeps Speed 8");
    snapshot.speed = 3;
    snapshot.quality_deadline = "good";
    assert_array_has_adjacent_pair (Vp9Builder.build_args_from_snapshot (snapshot),
        "-cpu-used", "3", "Speeds within the range are unchanged");
    assert_true (Vp9Builder.max_speed_for_deadline ("") == 5,
        "an unset deadline is FFmpeg's default, good");
}

private void test_vp9_frame_parallel_off_is_sent () {
    // libvpx 1.17 already enables frame parallel decoding.
    var snapshot = new Vp9BuilderSnapshot ();
    assert_array_not_contains (Vp9Builder.build_args_from_snapshot (snapshot),
        "-frame-parallel", "the default leaves libvpx's frame parallel decoding on");
    snapshot.frame_parallel = false;
    assert_array_has_adjacent_pair (Vp9Builder.build_args_from_snapshot (snapshot),
        "-frame-parallel", "0", "turning it off reaches libvpx");
}

private void test_smart_codec_widgets_vp9_tab_follows_two_pass_and_deadline () {
    if (!ensure_gtk_widget_tests_available ()) return;
    var tab = new Vp9Tab ();
    assert_true (tab.frame_parallel_switch.active,
        "Frame Parallel starts on, as libvpx does");
    // CRF is single pass, where libvpx ignores alt-ref and lag-in-frames.
    assert_false (tab.altref_expander.sensitive, "alt-ref is dimmed in single-pass CRF");
    assert_false (tab.lookahead_expander.sensitive, "lookahead is dimmed in single-pass CRF");
    CodecPresets.set_dropdown_by_label (tab.rc_mode_combo, RateControl.VBR);
    tab.two_pass_switch.set_active (true);
    assert_true (tab.altref_expander.sensitive, "alt-ref applies in two-pass");
    assert_true (tab.lookahead_expander.sensitive, "lookahead applies in two-pass");
    tab.two_pass_switch.set_active (false);
    assert_false (tab.altref_expander.sensitive, "alt-ref dims again in single-pass VBR");

    tab.speed_spin.set_value (8);
    assert_true ((int) tab.speed_spin.get_value () == 5, "Good caps Speed at 5");
    CodecPresets.set_dropdown_by_label (tab.quality_combo, "realtime");
    tab.speed_spin.set_value (8);
    assert_true ((int) tab.speed_spin.get_value () == 8, "Realtime allows Speed 8");
    CodecPresets.set_dropdown_by_label (tab.quality_combo, "good");
    assert_true ((int) tab.speed_spin.get_value () == 5,
        "returning to Good clamps Speed to 5");

    // Smart Codec applies the deadline before Speed, so its fastest step
    // shows as the 5 that Good encodes, matching the resolver's arguments.
    var rec = make_smart_codec_case_recommendation (21);
    rec.preset = "cpu-used 8";
    var applied = new Vp9Tab ();
    applied.apply_smart_recommendation (rec);
    assert_true ((int) applied.speed_spin.get_value () == 5,
        "a cpu-used 8 recommendation applies as Speed 5 with Good");
    assert_true (applied.altref_expander.sensitive == applied.two_pass_switch.active,
        "alt-ref sensitivity follows the applied two-pass choice");
}

private void test_x265_reference_frames_auto_follows_preset () {
    var snapshot = x265_tab_default_snapshot ();
    assert_codec_param_key_absent (x265_params_for (snapshot, "x265 refs Auto"),
        "ref", "Auto references follow the preset");

    snapshot.ref_frames = "";
    assert_codec_param_key_absent (x265_params_for (snapshot, "x265 refs unset"),
        "ref", "unset references follow the preset");

    snapshot.ref_frames = "5";
    assert_array_contains (x265_params_for (snapshot, "x265 refs 5"),
        "ref=5", "a chosen reference count still applies");
}

// ═════════════════════════════════════════════════════════════════════════════
//  FILTERBUILDER DRAWTEXT TESTS
// ═════════════════════════════════════════════════════════════════════════════

private void test_shared_output_timing_resolution () {
    double fps = 0.0;
    assert_true (CodecUtils.try_resolve_output_fps (
        FrameRateLabel.CUSTOM, "1", out fps),
        "positive low custom FPS is accepted consistently");
    assert_true (Math.fabs (fps - 1.0) < 1e-9,
        "low custom FPS is preserved exactly");
    assert_true (CodecUtils.try_resolve_output_fps (
        FrameRateLabel.CUSTOM, "1000", out fps),
        "positive high custom FPS is accepted consistently");
    assert_true (Math.fabs (fps - 1000.0) < 1e-9,
        "high custom FPS is preserved exactly");
    assert_false (CodecUtils.try_resolve_output_fps (
        FrameRateLabel.ORIGINAL, "60", out fps),
        "Original delegates to the probed source FPS");
    assert_false (CodecUtils.try_resolve_output_fps (
        FrameRateLabel.CUSTOM, "0", out fps),
        "non-positive custom FPS remains invalid");

    var keyframes = new KeyframeSettingsSnapshot ();
    keyframes.keyint_text = "Custom";
    keyframes.custom_mode = 1; // two seconds, expressed in output frames
    keyframes.frame_rate_text = FrameRateLabel.CUSTOM;
    keyframes.custom_frame_rate_text = "1";
    string[] low_fps_gop = CodecUtils.resolve_custom_keyframe_args_from_snapshot (
        keyframes, "/path/not-probed-when-fps-is-configured");
    assert_array_has_adjacent_pair (low_fps_gop, "-g", "2",
        "custom keyframe resolution uses the shared low output FPS");
    keyframes.custom_frame_rate_text = "1000";
    string[] high_fps_gop = CodecUtils.resolve_custom_keyframe_args_from_snapshot (
        keyframes, "/path/not-probed-when-fps-is-configured");
    assert_array_has_adjacent_pair (high_fps_gop, "-g", "2000",
        "custom keyframe resolution uses the shared high output FPS");

    var snap = new GeneralSettingsSnapshot ();
    snap.video_speed_enabled = true;
    snap.video_speed_percent = 100.0;
    assert_true (Math.fabs (
        FilterBuilder.get_video_speed_multiplier (snap) - 2.0) < 1e-9,
        "optimizer timing sees the same 2x multiplier as setpts");
    assert_contains (FilterBuilder.build_video_filter_chain_from_snapshot (snap),
        "setpts=0.500000*PTS", "filter chain uses the matching 2x timeline");
}

private GeneralSettingsSnapshot make_watermark_snapshot (
    string text,
    string position = "Bottom Right",
    double opacity = 0.5,
    int margin = 10,
    int font_size = 24,
    string color = "ffffff") {
    var snap = new GeneralSettingsSnapshot ();
    snap.watermark_enabled = true;
    snap.watermark_text = text;
    snap.watermark_position = position;
    snap.watermark_color = color;
    snap.watermark_opacity = opacity;
    snap.watermark_margin = margin;
    snap.watermark_font_size = font_size;
    return snap;
}

private void test_drawtext_basic_output () {
    var snap = make_watermark_snapshot ("Hello World");
    string chain = FilterBuilder.build_video_filter_chain_from_snapshot (snap);

    assert_contains (chain, "drawtext=", "chain contains drawtext filter");
    assert_contains (chain, "text='Hello World'", "drawtext includes text");
    assert_contains (chain, "fontsize=24", "drawtext includes font size");
    assert_contains (chain, "fontcolor=0xffffff@0.50", "drawtext includes fontcolor with opacity");
    assert_contains (chain, "shadowcolor=black@0.5", "drawtext includes dark shadow for bright text");
    assert_contains (chain, "expansion=none", "drawtext sets expansion=none");
}

private void test_drawtext_position_presets () {
    // Bottom Right (default)
    var snap = make_watermark_snapshot ("X", "Bottom Right", 0.5, 10, 24);
    string chain = FilterBuilder.build_video_filter_chain_from_snapshot (snap);
    assert_contains (chain, "x=w-text_w-10", "bottom right x");
    assert_contains (chain, "y=h-text_h-10", "bottom right y");

    // Top Left
    snap = make_watermark_snapshot ("X", "Top Left", 0.5, 15, 24);
    chain = FilterBuilder.build_video_filter_chain_from_snapshot (snap);
    assert_contains (chain, "x=15", "top left x");
    assert_contains (chain, "y=15", "top left y");

    // Center
    snap = make_watermark_snapshot ("X", "Center", 0.5, 10, 24);
    chain = FilterBuilder.build_video_filter_chain_from_snapshot (snap);
    assert_contains (chain, "x=(w-text_w)/2", "center x");
    assert_contains (chain, "y=(h-text_h)/2", "center y");
}

private void test_drawtext_escaping () {
    var snap = make_watermark_snapshot ("test:colon\\slash'quote[bracket]");
    string chain = FilterBuilder.build_video_filter_chain_from_snapshot (snap);
    assert_contains (chain, "test\\:colon\\\\slash\\'quote\\[bracket\\]",
        "special characters are escaped");
}

private void test_drawtext_disabled_produces_nothing () {
    var snap = new GeneralSettingsSnapshot ();
    snap.watermark_enabled = false;
    snap.watermark_text = "Should not appear";
    string chain = FilterBuilder.build_video_filter_chain_from_snapshot (snap);

    // Should not contain drawtext at all
    if (chain.contains ("drawtext")) {
        Test.fail_printf ("disabled watermark should not produce drawtext filter, got: %s", chain);
    }

    // Also test empty text with enabled flag
    snap.watermark_enabled = true;
    snap.watermark_text = "";
    chain = FilterBuilder.build_video_filter_chain_from_snapshot (snap);
    if (chain.contains ("drawtext")) {
        Test.fail_printf ("empty watermark text should not produce drawtext filter, got: %s", chain);
    }
}

private void test_combine_post_output_includes_watermark () {
    var snap = make_watermark_snapshot ("Combined Video");
    string chain = FilterBuilder.build_combine_post_output_video_filters_from_snapshot (snap);
    assert_contains (chain, "drawtext=", "combine post-output includes drawtext");
    assert_contains (chain, "text='Combined Video'", "combine post-output includes watermark text");
}

private void test_drawtext_utf8_text_preserved () {
    var snap = make_watermark_snapshot ("\u00a9 My Video \u2014 \u00e9l\u00e8ve");
    string chain = FilterBuilder.build_video_filter_chain_from_snapshot (snap);
    assert_contains (chain, "\u00a9 My Video \u2014 \u00e9l\u00e8ve",
        "UTF-8 text preserved through escaping");
}

private void test_drawtext_custom_color () {
    // Yellow text — luminance ~0.886, bright, should get dark shadow
    var snap = make_watermark_snapshot ("Yellow Text", "Center", 0.8, 10, 24, "ffff00");
    string chain = FilterBuilder.build_video_filter_chain_from_snapshot (snap);
    assert_contains (chain, "fontcolor=0xffff00@0.80", "custom yellow color in drawtext");
    assert_contains (chain, "shadowcolor=black@0.5", "bright yellow gets dark shadow");
}

private void test_drawtext_dark_color_gets_light_shadow () {
    // Dark blue — below luminance threshold, should get light shadow
    var snap = make_watermark_snapshot ("Dark", "Center", 0.5, 10, 24, "000033");
    string chain = FilterBuilder.build_video_filter_chain_from_snapshot (snap);
    assert_contains (chain, "fontcolor=0x000033@0.50", "dark color in drawtext");
    assert_contains (chain, "shadowcolor=white@0.5", "dark color gets light shadow");
}

// ═════════════════════════════════════════════════════════════════════════════
//  IMAGE WATERMARK TESTS
// ═════════════════════════════════════════════════════════════════════════════

private void test_image_mode_skips_drawtext () {
    var snap = new GeneralSettingsSnapshot ();
    snap.watermark_enabled = true;
    snap.watermark_mode = "image";
    snap.watermark_text = "Should not appear";
    snap.watermark_image_path = "/tmp/logo.png";
    string chain = FilterBuilder.build_video_filter_chain_from_snapshot (snap);

    if (chain.contains ("drawtext")) {
        Test.fail_printf ("image mode should not produce drawtext filter, got: %s", chain);
    }
}

private void test_image_overlay_fragment_basic () {
    string frag = FilterBuilder.build_image_overlay_fragment (
        "[1:v]", "[0:v]", "[outv]",
        "Bottom Right", 10, 0.5, 150);

    assert_contains (frag, "scale=150:-1", "overlay fragment scales to width");
    assert_contains (frag, "format=rgba", "overlay fragment converts to rgba");
    assert_contains (frag, "colorchannelmixer=aa=0.50", "overlay fragment applies opacity");
    assert_contains (frag, "overlay=x=main_w-overlay_w-10", "overlay x position");
    assert_contains (frag, "y=main_h-overlay_h-10", "overlay y position");
    assert_contains (frag, "[1:v]", "overlay fragment references watermark input");
    assert_contains (frag, "[0:v]", "overlay fragment references video input");
    assert_contains (frag, "[outv]", "overlay fragment produces output label");
}

private void test_image_overlay_fragment_full_opacity () {
    string frag = FilterBuilder.build_image_overlay_fragment (
        "[1:v]", "[0:v]", "[outv]",
        "Center", 0, 1.0, 200);

    // Full opacity should not include colorchannelmixer
    if (frag.contains ("colorchannelmixer")) {
        Test.fail_printf ("full opacity should not add colorchannelmixer, got: %s", frag);
    }

    assert_contains (frag, "x=(main_w-overlay_w)/2", "center x");
    assert_contains (frag, "y=(main_h-overlay_h)/2", "center y");
}

private void test_image_overlay_fragment_original_size () {
    string frag = FilterBuilder.build_image_overlay_fragment (
        "[1:v]", "[0:v]", "[outv]",
        "Top Left", 5, 0.8, -1);

    // -1 means original size — no scale filter
    if (frag.contains ("scale=")) {
        Test.fail_printf ("original size (-1) should not include scale, got: %s", frag);
    }

    assert_contains (frag, "x=5", "top left x");
    assert_contains (frag, "y=5", "top left y");
}

private void test_overlay_output_format_mapping () {
    var pixel_format = new PixelFormatSettingsSnapshot ();

    pixel_format.eight_bit_selected = true;
    pixel_format.eight_bit_format_text = "8-bit 4:2:2";
    assert_string_equal (
        FilterBuilder.get_overlay_output_format (pixel_format),
        "yuv422", "8-bit 4:2:2 overlay format");

    pixel_format.eight_bit_selected = false;
    pixel_format.ten_bit_selected = true;
    pixel_format.ten_bit_format_text = "10-bit 4:4:4";
    assert_string_equal (
        FilterBuilder.get_overlay_output_format (pixel_format),
        "yuv444p10", "10-bit 4:4:4 overlay format");

    pixel_format.ten_bit_selected = false;
    assert_string_equal (
        FilterBuilder.get_overlay_output_format (pixel_format),
        "", "unset overlay format");

    assert_string_equal (
        FilterBuilder.get_overlay_output_format_from_pix_fmt (
            PixelFormat.YUV420P),
        "yuv420", "8-bit 4:2:0 FFmpeg format mapping");
    assert_string_equal (
        FilterBuilder.get_overlay_output_format_from_pix_fmt (
            PixelFormat.YUV422P10LE),
        "yuv422p10", "10-bit 4:2:2 FFmpeg format mapping");
    assert_string_equal (
        FilterBuilder.get_overlay_output_format_from_pix_fmt ("unknown"),
        "", "unknown FFmpeg format remains unset");

    assert_string_equal (
        FilterBuilder.retarget_yuv_pixel_format_filters (
            "scale=1280:720,format=yuv420p,eq=contrast=1.1",
            PixelFormat.YUV420P10LE),
        "scale=1280:720,format=yuv420p10le,eq=contrast=1.1",
        "Smart format replaces a stale explicit output depth in place");
    assert_string_equal (
        FilterBuilder.retarget_yuv_pixel_format_filters (
            "scale=1280:720", PixelFormat.YUV420P10LE),
        "scale=1280:720,format=yuv420p10le",
        "Smart format is appended when the chain has no format filter");
    assert_string_equal (
        FilterBuilder.retarget_yuv_pixel_format_filters (
            "format=rgba", PixelFormat.YUV420P10LE),
        "format=rgba,format=yuv420p10le",
        "unrelated format filters are preserved");
    assert_string_equal (
        FilterBuilder.retarget_yuv_pixel_format_filters (
            "drawtext=text=hello\\,world,format=yuv420p",
            PixelFormat.YUV420P10LE),
        "drawtext=text=hello\\,world,format=yuv420p10le",
        "escaped commas inside filter arguments survive Smart retargeting");
    assert_string_equal (
        FilterBuilder.retarget_yuv_pixel_format_filters (
            "drawtext=text='hello,world',format=yuv420p",
            PixelFormat.YUV420P10LE),
        "drawtext=text='hello,world',format=yuv420p10le",
        "quoted commas inside filter arguments survive Smart retargeting");

    PixelFormatSettingsSnapshot from_ffmpeg =
        CodecUtils.pixel_format_settings_from_ffmpeg_pix_fmt (
            PixelFormat.YUV444P10LE);
    assert_true (from_ffmpeg.ten_bit_selected,
        "FFmpeg 10-bit format selects the codec tab's 10-bit control");
    assert_false (from_ffmpeg.eight_bit_selected,
        "FFmpeg 10-bit format leaves the 8-bit control off");
    assert_string_equal (from_ffmpeg.ten_bit_format_text,
        "10-bit 4:4:4", "FFmpeg chroma maps to the codec tab label");
}

private void test_image_overlay_fragment_preserves_10bit () {
    string frag = FilterBuilder.build_image_overlay_fragment (
        "[1:v]", "[0:v]", "[outv]",
        "Bottom Right", 10, 0.5, 150, "yuv420p10");

    assert_contains (
        frag, "overlay=x=main_w-overlay_w-10:y=main_h-overlay_h-10:format=yuv420p10[outv]",
        "overlay fragment preserves selected 10-bit format");
}

private void test_image_overlay_position_presets () {
    // Top Right
    string x_expr, y_expr;
    FilterBuilder.get_overlay_position_exprs ("Top Right", 15, out x_expr, out y_expr);
    assert_string_equal (x_expr, "main_w-overlay_w-15", "top right x");
    assert_string_equal (y_expr, "15", "top right y");

    // Bottom Left
    FilterBuilder.get_overlay_position_exprs ("Bottom Left", 20, out x_expr, out y_expr);
    assert_string_equal (x_expr, "20", "bottom left x");
    assert_string_equal (y_expr, "main_h-overlay_h-20", "bottom left y");
}

private void test_image_watermark_effective_state () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var general = new GeneralTab ();

    // Image mode with switch on but no file — should not be effective
    general.watermark_mode.set_selected (1);  // Image mode
    general.watermark_check.set_active (true);
    assert_false (general.is_watermark_effectively_enabled (),
        "image watermark not effective with no file selected");

    // Switch off — not effective regardless
    general.watermark_check.set_active (false);
    assert_false (general.is_watermark_effectively_enabled (),
        "image watermark not effective when switch is off");
}

private void test_overlay_unavailable_disables_image_watermark () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var general = new GeneralTab ();
    general.watermark_mode.set_selected (1);  // Image mode
    general.watermark_check.set_active (true);

    general.set_overlay_available (false, "Unavailable — missing overlay");

    // Expander stays sensitive because drawtext is still available —
    // user can switch to Text mode.
    assert_true (general.get_watermark_expander_sensitive_for_widget_test (),
        "watermark expander stays sensitive when drawtext is available");
    assert_false (general.is_watermark_effectively_enabled (),
        "image watermark is not effective when overlay is unavailable");
    assert_contains (general.get_watermark_subtitle_for_widget_test (),
        "missing overlay",
        "watermark subtitle explains overlay unavailability");
}

private void test_mode_switch_unlocks_when_other_filter_available () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var general = new GeneralTab ();

    // Simulate FFmpeg that has overlay but not drawtext
    general.set_drawtext_available (false, "Unavailable — no drawtext");
    general.set_overlay_available (true);

    // Expander must remain sensitive so the user can reach the mode dropdown
    assert_true (general.get_watermark_expander_sensitive_for_widget_test (),
        "expander sensitive when overlay available but drawtext missing");

    // Default text mode shows the unavailability hint
    assert_contains (general.get_watermark_subtitle_for_widget_test (),
        "no drawtext",
        "subtitle shows drawtext hint in text mode");

    // Switch to image mode — subtitle should clear
    general.watermark_mode.set_selected (1);
    assert_string_equal (general.get_watermark_subtitle_for_widget_test (),
        "Overlay text or an image on the video",
        "subtitle resets to default after switching to available image mode");

    // Switch back to text mode — hint should return
    general.watermark_mode.set_selected (0);
    assert_contains (general.get_watermark_subtitle_for_widget_test (),
        "no drawtext",
        "subtitle shows drawtext hint again after switching back to text mode");
}

private void test_image_watermark_snapshot_fields () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var general = new GeneralTab ();
    general.watermark_mode.set_selected (1);  // Image mode
    general.watermark_check.set_active (true);
    general.watermark_image_width.set_value (200);

    var snap = general.snapshot_settings ();

    assert_string_equal (snap.watermark_mode, "image", "snapshot captures image mode");
    assert_true ((int) snap.watermark_image_width == 200, "snapshot captures image width");
}

private void test_encode_profile_carries_watermark_fields () {
    var snap = new GeneralSettingsSnapshot ();
    snap.watermark_enabled = true;
    snap.watermark_mode = "image";
    snap.watermark_image_path = "/tmp/logo.png";
    snap.watermark_image_width = 200;
    snap.watermark_position = "Top Left";
    snap.watermark_opacity = 0.8;
    snap.watermark_margin = 15;

    // Verify fields roundtrip through EncodeProfileSnapshot
    var profile = new EncodeProfileSnapshot ();
    profile.watermark_enabled = snap.watermark_enabled;
    profile.watermark_mode = snap.watermark_mode;
    profile.watermark_image_path = snap.watermark_image_path;
    profile.watermark_image_width = snap.watermark_image_width;
    profile.watermark_position = snap.watermark_position;
    profile.watermark_opacity = snap.watermark_opacity;
    profile.watermark_margin = snap.watermark_margin;

    assert_true (profile.watermark_enabled, "profile watermark_enabled");
    assert_string_equal (profile.watermark_mode, "image", "profile watermark_mode");
    assert_string_equal (profile.watermark_image_path, "/tmp/logo.png", "profile watermark_image_path");
    assert_true ((int) profile.watermark_image_width == 200, "profile watermark_image_width");
    assert_string_equal (profile.watermark_position, "Top Left", "profile watermark_position");
    assert_true ((int) profile.watermark_margin == 15, "profile watermark_margin");
}

// The moving scan writes timed entries into the same Region field the static
// scan uses, so everything downstream that asked "is there a region?" has to
// recognise both forms — otherwise the whole feature silently does nothing.
private void test_timed_regions_enable_logo_removal () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var general = new GeneralTab ();
    general.delogo_check.set_active (true);

    general.delogo_value.set_text ("");
    assert_false (general.is_logo_removal_effectively_enabled (),
        "an empty region field leaves logo removal inactive");

    general.delogo_value.set_text ("10:20:30:40");
    assert_true (general.is_logo_removal_effectively_enabled (),
        "a static region activates logo removal");

    general.delogo_value.set_text ("12.5-28.0:1416:1:504:288");
    assert_true (general.is_logo_removal_effectively_enabled (),
        "a timed region activates logo removal");

    general.delogo_value.set_text ("not a region");
    assert_false (general.is_logo_removal_effectively_enabled (),
        "unparseable text leaves logo removal inactive");

    // And the timed text reaches the conversion path intact.
    general.delogo_value.set_text ("12.5-28.0:1416:1:504:288");
    var snapshot = general.snapshot_settings ();
    assert_true (snapshot.delogo_enabled, "snapshot carries the enabled flag");
    assert_string_equal (snapshot.delogo_regions, "12.5-28.0:1416:1:504:288",
        "snapshot carries the timed region text verbatim");
}

private void test_both_logo_detect_buttons_reset_together () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var general = new GeneralTab ();
    assert_string_equal (general.detect_logo_button.get_label (), "Detect Watermark",
        "static detect button label");
    assert_string_equal (general.detect_moving_logo_button.get_label (), "Detect Moving",
        "moving detect button label");

    // Either scan locks both buttons, since both write the same field.
    general.detect_logo_button.sensitive = false;
    general.detect_moving_logo_button.sensitive = false;
    general.delogo_value.set_text ("12.5-28.0:1416:1:504:288");
    general.delogo_check.set_active (true);

    general.reset_logo_removal ();

    assert_true (general.detect_logo_button.sensitive,
        "reset re-enables the static detect button");
    assert_true (general.detect_moving_logo_button.sensitive,
        "reset re-enables the moving detect button");
    assert_string_equal (general.delogo_value.get_text (), "",
        "reset clears the region field");
    assert_false (general.is_logo_removal_effectively_enabled (),
        "reset leaves logo removal inactive");
}

private void test_recent_input_history_is_bounded_deduplicated_and_pruned () {
    string temp_dir = "";
    string[] files = {};

    try {
        temp_dir = DirUtils.make_tmp ("recent-input-history-XXXXXX");
        for (int i = 0; i < 22; i++) {
            string path = Path.build_filename (
                temp_dir, "video-%02d.mkv".printf (i));
            if (i % 2 == 0)
                FileUtils.set_contents (path, "test");
            else
                assert_true (DirUtils.create (path, 0700) == 0,
                    "create a folder with a media-looking name");
            files += path;
        }

        string[] candidates = { files[0], files[1], files[0] };
        for (int i = 2; i < files.length; i++)
            candidates += files[i];

        string[] clean = AppSettings.sanitize_recent_input_files (candidates);
        assert_true (clean.length == AppSettings.MAX_RECENT_INPUT_FILES,
            "recent history retains at most 20 files and folders");
        assert_string_equal (clean[0], files[0],
            "recent history preserves newest-first order");
        assert_string_equal (clean[1], files[1],
            "duplicate entries do not displace the next unique file");
        assert_string_equal (clean[19], files[19],
            "the 20-item boundary is deterministic");

        DirUtils.remove (files[5]);
        string[] pruned = AppSettings.sanitize_recent_input_files (clean);
        assert_true (pruned.length == 19,
            "a deleted recent input is removed during refresh");
        foreach (unowned string path in pruned) {
            assert_true (path != files[5],
                "deleted input does not remain in the recent menu model");
        }
    } catch (Error e) {
        error ("Recent input history test setup failed: %s", e.message);
    } finally {
        foreach (unowned string path in files) {
            if (FileUtils.test (path, FileTest.IS_DIR)) DirUtils.remove (path);
            else FileUtils.remove (path);
        }
        if (temp_dir.length > 0)
            DirUtils.remove (temp_dir);
    }
}

private void test_recent_input_folders_persist_and_obey_history_preference () {
    string? root = null;
    try {
        root = DirUtils.make_tmp ("recent-folders-setting-XXXXXX");
        string folder = Path.build_filename (root, "Batch café; videos.mp4");
        string video = Path.build_filename (root, "single.mkv");
        string missing = Path.build_filename (root, "missing");
        assert_true (DirUtils.create (folder, 0700) == 0, "create bulk folder");
        FileUtils.set_contents (video, "test");
        var settings = AppSettings.create_for_test (root);
        settings.record_recent_input_file (folder);
        assert_true (settings.recent_input_files.length == 0,
            "history remains off by default for folders too");
        settings.recently_opened_enabled = true;
        settings.record_recent_input_file (folder);
        settings.record_recent_input_file (video);
        settings.record_recent_input_file (missing);
        settings.record_recent_input_file (Path.build_filename (folder, "."));
        assert_true (settings.recent_input_files.length == 2,
            "mixed history canonicalizes duplicates and excludes missing paths");
        assert_string_equal (settings.recent_input_files[0], folder,
            "reopening a folder promotes it without duplication");
        var loaded = AppSettings.create_for_test (root);
        assert_true (loaded.recent_input_files.length == 2,
            "both file and folder survive persisted settings reload");
        assert_string_equal (loaded.recent_input_files[0], folder, "folder keeps its order");
        assert_string_equal (loaded.recent_input_files[1], video, "file remains in history");

        DirUtils.remove (folder);
        var pruned = AppSettings.create_for_test (root);
        assert_true (pruned.recent_input_files.length == 1,
            "loading settings prunes a deleted bulk folder");
        assert_true (DirUtils.create (folder, 0700) == 0, "recreate bulk folder");
        pruned.record_recent_input_file (folder);
        pruned.recently_opened_enabled = false;
        pruned.save ();
        pruned.record_recent_input_file (folder);
        var disabled = AppSettings.create_for_test (root);
        assert_true (!disabled.recently_opened_enabled && disabled.recent_input_files.length == 0,
            "disabling history removes both types from disk and stops recording");
        disabled.recently_opened_enabled = true;
        disabled.record_recent_input_file (folder);
        disabled.record_recent_input_file (video);
        disabled.clear_recent_input_files ();
        var cleared = AppSettings.create_for_test (root);
        assert_true (cleared.recent_input_files.length == 0,
            "Clear History persists removal of files and folders");
    } catch (Error e) {
        Test.fail_printf ("recent folder history setup failed: %s", e.message);
    } finally {
        if (root != null) cleanup_exec_test_dir (root);
    }
}

private void test_collage_size_preference_persists () {
    string? config_root = null;
    try {
        config_root = DirUtils.make_tmp ("collage-size-setting-XXXXXX");

        var settings = AppSettings.create_for_test (config_root);
        assert_string_equal (settings.collage_size.get_label (), "1080p",
            "collage size defaults to the size this feature shipped with");

        settings.collage_size = CollageSize.UHD_4K;
        settings.save ();

        var reloaded = AppSettings.create_for_test (config_root);
        assert_string_equal (reloaded.collage_size.get_label (), "4K",
            "a chosen collage size survives reload");

        reloaded.reset_to_defaults ();
        var reset = AppSettings.create_for_test (config_root);
        assert_string_equal (reset.collage_size.get_label (), "1080p",
            "reset restores the collage size default");
    } catch (FileError e) {
        Test.fail_printf ("failed to create collage size test directory: %s",
            e.message);
    } finally {
        if (config_root != null) {
            cleanup_exec_test_dir (Path.build_filename (
                config_root, "FFmpeg-Converter-GTK"));
            DirUtils.remove (config_root);
        }
    }
}

private void test_quality_ceiling_preference_persists () {
    string? config_root = null;
    try {
        config_root = DirUtils.make_tmp ("quality-ceiling-setting-XXXXXX");

        var settings = AppSettings.create_for_test (config_root);
        assert_true (settings.smart_optimizer_quality_ceiling == 0,
            "quality ceiling defaults to Off");

        // 3 == High. Stored by name, so the on-disk value is "high".
        settings.smart_optimizer_quality_ceiling = 3;
        settings.save ();

        var reloaded = AppSettings.create_for_test (config_root);
        assert_true (reloaded.smart_optimizer_quality_ceiling == 3,
            "a chosen quality ceiling survives reload");

        // Out-of-range assignments clamp rather than corrupting the config,
        // which would otherwise index past the dropdown model.
        reloaded.smart_optimizer_quality_ceiling = 99;
        assert_true (reloaded.smart_optimizer_quality_ceiling == 4,
            "an out-of-range quality ceiling clamps to Ultra");
        reloaded.smart_optimizer_quality_ceiling = -7;
        assert_true (reloaded.smart_optimizer_quality_ceiling == 0,
            "a negative quality ceiling clamps to Off");

        reloaded.reset_to_defaults ();
        var reset = AppSettings.create_for_test (config_root);
        assert_true (reset.smart_optimizer_quality_ceiling == 0,
            "reset restores the quality ceiling default");
    } catch (FileError e) {
        Test.fail_printf ("failed to create settings test directory: %s", e.message);
    } finally {
        if (config_root != null) {
            cleanup_exec_test_dir (Path.build_filename (
                config_root, "FFmpeg-Converter-GTK"));
            DirUtils.remove (config_root);
        }
    }
}

private void test_bit_depth_warning_dialog_preference_persists () {
    string? config_root = null;
    try {
        config_root = DirUtils.make_tmp ("bit-depth-warning-setting-XXXXXX");

        var settings = AppSettings.create_for_test (config_root);
        assert_true (settings.show_bit_depth_warning_dialog,
            "bit-depth dialog preference defaults to enabled");

        settings.show_bit_depth_warning_dialog = false;
        settings.save ();

        var reloaded = AppSettings.create_for_test (config_root);
        assert_false (reloaded.show_bit_depth_warning_dialog,
            "disabled bit-depth dialog preference survives reload");

        reloaded.reset_to_defaults ();
        var reset = AppSettings.create_for_test (config_root);
        assert_true (reset.show_bit_depth_warning_dialog,
            "reset restores the bit-depth dialog preference default");
    } catch (FileError e) {
        Test.fail_printf ("failed to create settings test directory: %s", e.message);
    } finally {
        if (config_root != null) {
            cleanup_exec_test_dir (Path.build_filename (
                config_root, "FFmpeg-Converter-GTK"));
            DirUtils.remove (config_root);
        }
    }
}

private void test_recent_input_menu_item_exposes_full_path_tooltip () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    string path = "/videos/archive/shared-name.mkv";
    var button = HamburgerMenu.create_recent_input_button (path);
    assert_string_equal (button.get_label (), "shared-name.mkv",
        "recent item keeps a compact basename label");
    assert_string_equal (button.get_tooltip_text () ?? "", path,
        "recent item tooltip exposes its complete path");
}

private void test_recent_input_menu_repeated_refresh_is_stable () {
    if (Environment.get_variable ("HAMBURGER_REBUILD_TEST") != "1") {
        Test.skip ("runs in the dedicated fatal-warning GTK test");
        return;
    }

    string? temp_root = null;
    string[] files = {};
    AppSettings? settings = null;
    Adw.ApplicationWindow? window = null;

    try {
        temp_root = DirUtils.make_tmp ("hamburger-rebuild-XXXXXX");
        Environment.set_variable ("XDG_CONFIG_HOME", temp_root, true);
        if (!ensure_gtk_widget_tests_available ())
            return;

        settings = AppSettings.get_default ();
        settings.recently_opened_enabled = true;
        for (int i = 0; i < AppSettings.MAX_RECENT_INPUT_FILES; i++) {
            string path = Path.build_filename (
                temp_root, "recent-%02d.mkv".printf (i));
            FileUtils.set_contents (path, "test");
            files += path;
            settings.record_recent_input_file (path);
        }

        var app = new Adw.Application (
            "com.github.pieman.FFmpegConverterGTK.HamburgerRebuildTest",
            ApplicationFlags.NON_UNIQUE
        );
        app.register (null);

        window = new Adw.ApplicationWindow (app);
        var file_pickers = new FilePickers ();
        var hamburger = new HamburgerMenu (window, file_pickers);
        var menu_button = hamburger.get_button ();
        window.set_content (menu_button);
        window.present ();

        assert_true (spin_main_context_until (() => {
            return window.get_mapped ();
        }), "hamburger rebuild test window maps");

        menu_button.set_active (true);
        spin_main_context_until (() => { return true; }, 2);
        menu_button.set_active (false);
        spin_main_context_until (() => { return true; }, 2);

        var second_recent =
            hamburger.get_recent_input_button_for_widget_test (1);
        assert_true (second_recent != null,
            "recent-file custom buttons bind to the popover");
        if (second_recent != null) {
            assert_true (second_recent.get_parent () != null,
                "recent-file button is parented into its custom GTK slot");
            assert_string_equal (second_recent.get_label (),
                Path.get_basename (
                    files[AppSettings.MAX_RECENT_INPUT_FILES - 2]),
                "recent-file button shows its current basename");
            assert_string_equal (second_recent.get_tooltip_text () ?? "",
                files[AppSettings.MAX_RECENT_INPUT_FILES - 2],
                "recent-file button retains its current complete path");
            second_recent.clicked ();
            assert_true (spin_main_context_until_deadline (() => {
                return file_pickers.kind == InputSourceKind.FILE
                    && settings.recent_input_files[0] == files[AppSettings.MAX_RECENT_INPUT_FILES - 2];
            }, 3000), "recent file resolves before promotion is inspected");
            assert_string_equal (file_pickers.input_entry.get_text (),
                files[AppSettings.MAX_RECENT_INPUT_FILES - 2],
                "clicking a recent-file slot selects its current path");
            assert_string_equal (settings.recent_input_files[0],
                files[AppSettings.MAX_RECENT_INPUT_FILES - 2],
                "clicking a recent-file slot promotes it in history");
        }

        var last_recent = hamburger.get_recent_input_button_for_widget_test (
            AppSettings.MAX_RECENT_INPUT_FILES - 1);
        assert_true (last_recent != null,
            "all recent-file custom slots bind to the popover");
        if (last_recent != null) {
            assert_true (last_recent.get_parent () != null,
                "last recent-file button is parented into its GTK slot");
            assert_string_equal (last_recent.get_label (),
                Path.get_basename (files[0]),
                "the final history entry reaches the final custom slot");
        }

        for (int i = 0; i < 6; i++) {
            menu_button.set_active (true);
            spin_main_context_until (() => { return true; }, 2);
            menu_button.set_active (false);
            spin_main_context_until (() => { return true; }, 2);
        }

        // Select a folder normally, then reopen it through the actual menu
        // slot. Files and directories share history but only files can play.
        string folder = Path.build_filename (temp_root, "Batch café; videos.mp4");
        assert_true (DirUtils.create (folder, 0700) == 0, "create recent bulk folder");
        file_pickers.request_input (folder);
        assert_true (spin_main_context_until_deadline (() => {
            return file_pickers.kind == InputSourceKind.FOLDER;
        }, 3000), "accepted folder selection resolves into bulk input mode");
        assert_string_equal (settings.recent_input_files[0], folder,
            "folder selection automatically records its location");
        var folder_button = hamburger.get_recent_input_button_for_widget_test (0);
        assert_true (folder_button != null, "folder appears in a stable recent slot");
        if (folder_button != null) {
            assert_string_equal (folder_button.get_label (), "Batch café; videos.mp4 (Folder)",
                "folder marker distinguishes a directory with a media extension");
            assert_string_equal (folder_button.get_tooltip_text () ?? "", folder,
                "folder tooltip preserves the literal complete path");
        }
        var playback = app.lookup_action ("view-input") as GLib.SimpleAction;
        assert_true (playback != null && !playback.get_enabled (),
            "a folder is never offered to the video player");
        file_pickers.request_input (files[0]);
        assert_true (spin_main_context_until_deadline (() => {
            return file_pickers.kind == InputSourceKind.FILE;
        }, 3000), "can return from folder to file mode");
        folder_button = hamburger.get_recent_input_button_for_widget_test (1);
        assert_true (folder_button != null, "folder remains available after opening a file");
        if (folder_button != null) {
            file_pickers.set_operation_locked (true);
            folder_button.clicked ();
            assert_string_equal (file_pickers.source_path, files[0],
                "recent folder cannot replace an input during conversion");
            assert_string_equal (settings.recent_input_files[0], files[0],
                "blocked folder selection is not promoted");
            file_pickers.set_operation_locked (false);
            file_pickers.set_input_admission (() => { return false; });
            folder_button.clicked ();
            assert_string_equal (file_pickers.source_path, files[0],
                "recent folder respects controller admission for other operations");
            file_pickers.set_input_admission (() => { return true; });
            folder_button.clicked ();
            assert_true (spin_main_context_until_deadline (() => {
                return file_pickers.kind == InputSourceKind.FOLDER;
            }, 3000), "clicking recent folder reenters bulk input mode");
            assert_string_equal (file_pickers.source_path, folder,
                "recent folder reopens the exact location");
            assert_string_equal (settings.recent_input_files[0], folder,
                "accepted recent folder moves to the front");
        }
        assert_true (playback != null && !playback.get_enabled (),
            "reopened folder keeps playback disabled");
        file_pickers.request_input (files[0]);
        assert_true (spin_main_context_until_deadline (() => {
            return file_pickers.kind == InputSourceKind.FILE;
        }, 3000), "file mode returns after a recent folder");
        assert_true (playback != null && playback.get_enabled (),
            "file playback becomes available again");
        folder_button = hamburger.get_recent_input_button_for_widget_test (1);
        DirUtils.remove (folder);
        if (folder_button != null) folder_button.clicked ();
        assert_string_equal (file_pickers.source_path, files[0],
            "stale folder slot does not replace the selected file");
        assert_array_not_contains (settings.recent_input_files, folder,
            "deleted folder is pruned when its stale menu slot is clicked");

        var clear_action =
            app.lookup_action ("clear-recent-inputs") as GLib.SimpleAction;
        assert_true (clear_action != null,
            "hamburger registers its clear-history action");
        if (clear_action != null) {
            clear_action.activate (null);
            assert_true (settings.recent_input_files.length == 0,
                "clear-history action empties persisted recent files");
            var cleared_first =
                hamburger.get_recent_input_button_for_widget_test (0);
            assert_true (cleared_first != null,
                "clear-history keeps the first custom slot bound");
            if (cleared_first != null) {
                assert_string_equal (cleared_first.get_label (),
                    "No Recent Files or Folders",
                    "settings signal refreshes the cleared menu once");
                assert_false (cleared_first.get_sensitive (),
                    "cleared-history placeholder is disabled");
            }
        }

        foreach (unowned string path in files)
            settings.record_recent_input_file (path);

        // Exercise the same settings_changed route as the third recorded
        // coredump, then replace the entire popover by hiding and restoring
        // the recent submenu.
        settings.save ();
        menu_button.set_active (true);
        spin_main_context_until (() => { return true; }, 2);
        settings.recently_opened_enabled = false;
        settings.save ();
        assert_false (menu_button.get_active (),
            "rebuilding the model closes an active hamburger popover");
        settings.recently_opened_enabled = true;
        settings.save ();

        var empty_recent =
            hamburger.get_recent_input_button_for_widget_test (0);
        assert_true (empty_recent != null,
            "empty-history slot binds after popover replacement");
        if (empty_recent != null) {
            assert_string_equal (empty_recent.get_label (), "No Recent Files or Folders",
                "rebuilt empty history exposes its placeholder");
            assert_false (empty_recent.get_sensitive (),
                "rebuilt empty-history placeholder is disabled");
        }

        // Disabling history intentionally clears it. Refill every slot so the
        // replacement popover is also tested with a full, changing history.
        foreach (unowned string path in files)
            settings.record_recent_input_file (path);
        settings.save ();

        var rebuilt_first =
            hamburger.get_recent_input_button_for_widget_test (0);
        assert_true (rebuilt_first != null,
            "populated slot binds after popover replacement");
        if (rebuilt_first != null) {
            assert_true (rebuilt_first.get_parent () != null,
                "rebuilt recent-file button is parented into its GTK slot");
            assert_string_equal (rebuilt_first.get_tooltip_text () ?? "",
                files[AppSettings.MAX_RECENT_INPUT_FILES - 1],
                "rebuilt recent-file slot carries its refreshed path");
        }

        for (int i = 0; i < 4; i++) {
            menu_button.set_active (true);
            spin_main_context_until (() => { return true; }, 2);
            menu_button.set_active (false);
            spin_main_context_until (() => { return true; }, 2);
        }

        assert_true (menu_button.get_menu_model () != null,
            "hamburger retains a live menu model after repeated refreshes");

        // Cancel recent-file monitors before removing their temporary files.
        settings.recently_opened_enabled = false;
        settings.save ();
        window.close ();
        spin_main_context_until (() => { return true; }, 2);
    } catch (Error e) {
        Test.fail_printf ("hamburger rebuild test setup failed: %s", e.message);
    } finally {
        foreach (unowned string path in files)
            FileUtils.remove (path);
        if (temp_root != null) {
            cleanup_exec_test_dir (Path.build_filename (
                temp_root, "FFmpeg-Converter-GTK"));
            DirUtils.remove (temp_root);
        }
    }
}

// The profile boundary is deliberately testable without constructing GTK
// widgets: later jobs must not mutate settings already captured for an encode.
private class ProfileAdapterTrace : Object {
    public int stage = 0;
    public int tab_snapshots = 0;
    public int builder_snapshots = 0;
}

private class ProfileAdapterBuilder : Object, ICodecBuilder {
    private ProfileAdapterTrace trace;
    public GeneralSettingsSnapshot? captured_general = null;

    public ProfileAdapterBuilder (ProfileAdapterTrace trace) {
        this.trace = trace;
    }

    public string get_codec_name () {
        return "x265";
    }

    public Object? snapshot_settings (GeneralSettingsSnapshot? general_settings = null) {
        assert_true (trace.stage == 1, "adapter captures effective tab format before builder");
        trace.stage = 2;
        trace.builder_snapshots++;
        captured_general = general_settings;
        return general_settings != null ? general_settings.copy () : null;
    }

    public string[] build_codec_args_from_snapshot (Object? snapshot) {
        var general = snapshot as GeneralSettingsSnapshot;
        string pix_fmt = general != null && general.pixel_format.ten_bit_selected
            ? PixelFormat.YUV422P10LE : PixelFormat.YUV420P;
        return { "-c:v", "libx265", "-pix_fmt", pix_fmt };
    }

    public string[] get_codec_args () {
        return {};
    }
}

private class ProfileAdapterTab : Object, ICodecTab {
    private ProfileAdapterTrace trace;
    private ICodecBuilder builder;
    public CodecTabSettingsSnapshot settings = new CodecTabSettingsSnapshot ();

    public ProfileAdapterTab (ProfileAdapterTrace trace, ICodecBuilder builder) {
        this.trace = trace;
        this.builder = builder;
    }

    public ICodecBuilder get_codec_builder () {
        return builder;
    }

    public bool get_two_pass () {
        return false;
    }

    public string get_container () {
        return settings.container;
    }

    public CodecTabSettingsSnapshot snapshot_settings (
        GeneralSettingsSnapshot? general_settings = null) {
        assert_true (trace.stage == 0, "adapter snapshots the tab once before builder state");
        trace.stage = 1;
        trace.tab_snapshots++;
        return settings.copy ();
    }

    public KeyframeSettingsSnapshot snapshot_keyframe_settings (
        GeneralSettingsSnapshot? general_settings) {
        return settings.keyframe_settings.copy ();
    }

    public string[] get_audio_args () {
        return {};
    }
}

private void test_encode_profile_composition_does_not_mutate_callers () {
    var general = new GeneralSettingsSnapshot ();
    general.pixel_format.ten_bit_selected = true;
    general.pixel_format.ten_bit_format_text = "10-bit 4:4:4";
    var codec = new CodecTabSettingsSnapshot ();
    codec.container = ContainerExt.WEBM;
    codec.pixel_format.eight_bit_selected = true;
    codec.audio_settings.codec = AudioCodecName.COPY;
    codec.audio_settings.source.presence = MediaStreamPresence.PRESENT;
    codec.audio_settings.source.codec_name = "aac";
    codec.audio_settings.source.channels = 2;
    codec.audio_settings.bitrate_kbps = 160;
    codec.audio_settings.preserve_all_audio_tracks = true;
    codec.audio_settings.all_sources = { codec.audio_settings.source.copy () };
    string[] video_args = { "-c:v", "libvpx-vp9", "-crf", "31" };

    var profile = CodecUtils.compose_encode_profile ("vp9", video_args, codec, general);

    assert_array_has_adjacent_pair (profile.audio_args, "-c:a", "libopus",
        "WebM job transcodes incompatible AAC rather than copying it");
    assert_array_has_adjacent_pair (profile.audio_args, "-b:a", "160k",
        "container coercion retains the requested audio budget");
    assert_true (profile.preserve_all_audio_tracks, "job preserves the track policy");
    assert_string_equal (codec.audio_settings.codec, AudioCodecName.COPY,
        "coercion does not replace the user's reusable Copy selection");
    assert_string_equal (codec.audio_settings.source.codec_name, "aac",
        "coercion does not rewrite source observations");
    assert_true (general.pixel_format.ten_bit_selected,
        "effective job format does not change caller bit-depth selection");
    assert_false (general.pixel_format.eight_bit_selected,
        "caller does not acquire codec-local depth selection");
    assert_string_equal (profile.video_filters, "format=yuv420p",
        "job filters use the effective codec-local output format");
    assert_string_equal (profile.overlay_format, "yuv420",
        "overlay format agrees with the effective job format");

    video_args[1] = "changed-after-capture";
    assert_array_has_adjacent_pair (profile.codec_args, "-c:v", "libvpx-vp9",
        "captured codec arguments are independent from the caller array");
}

private void test_general_settings_copy_isolates_nested_state () {
    var requested = new GeneralSettingsSnapshot ();
    requested.pixel_format.ten_bit_selected = true;
    requested.pixel_format.ten_bit_format_text = "10-bit 4:2:2";
    requested.video_filters.processing_filters = { "hqdn3d=1:1:1:1", "deband" };
    requested.video_filters.hdr_filter = "tonemap=tonemap=hable";
    requested.crop_enabled = true;
    requested.crop_value = "160:90:4:6";
    requested.watermark_enabled = true;
    requested.watermark_text = "shared settings";
    requested.delogo_enabled = true;
    requested.delogo_regions = "8:10:20:24";

    var first_job = requested.copy ();
    first_job.pixel_format.ten_bit_format_text = "10-bit 4:4:4";
    first_job.video_filters.processing_filters[0] = "null";
    first_job.video_filters.hdr_filter = "";
    first_job.crop_value = "80:44:0:0";
    first_job.watermark_text = "job-specific";
    first_job.delogo_regions = "1:1:4:4";

    assert_string_equal (requested.pixel_format.ten_bit_format_text, "10-bit 4:2:2",
        "resolving one job cannot retarget shared pixel settings");
    assert_string_equal (requested.video_filters.processing_filters[0], "hqdn3d=1:1:1:1",
        "processing-filter array is not shared across jobs");
    assert_string_equal (requested.video_filters.hdr_filter, "tonemap=tonemap=hable",
        "video-filter snapshot object is not shared across jobs");
    assert_string_equal (requested.crop_value, "160:90:4:6", "shared crop survives job resolution");
    assert_string_equal (requested.watermark_text, "shared settings", "shared watermark survives");
    assert_string_equal (requested.delogo_regions, "8:10:20:24", "shared logo regions survive");
    assert_true (first_job.crop_enabled && first_job.watermark_enabled && first_job.delogo_enabled,
        "copy retains enabled processing before job-specific changes");
}

private void test_codec_settings_copy_isolates_source_observations () {
    var requested = new CodecTabSettingsSnapshot ();
    requested.container = ContainerExt.WEBM;
    requested.keyframe_settings.keyint_text = "Custom";
    requested.keyframe_settings.custom_mode = 3;
    requested.audio_settings.codec = AudioCodecName.COPY;
    requested.audio_settings.source.codec_name = "opus";
    requested.audio_settings.source.channels = 6;
    requested.audio_settings.all_sources = { requested.audio_settings.source.copy () };
    requested.audio_processing.normalize_enabled = true;
    requested.audio_processing.peak_normalize_gain_db = -3.0;
    requested.pixel_format.ten_bit_selected = true;

    var first_job = requested.copy ();
    first_job.keyframe_settings.custom_mode = 0;
    first_job.audio_settings.source.codec_name = "aac";
    first_job.audio_settings.all_sources[0].channels = 2;
    first_job.audio_settings.codec = AudioCodecName.AAC;
    first_job.audio_processing.peak_normalize_gain_db = -9.0;
    first_job.pixel_format.ten_bit_selected = false;

    assert_true (requested.keyframe_settings.custom_mode == 3, "job keyframe settings are isolated");
    assert_string_equal (requested.audio_settings.source.codec_name, "opus",
        "job primary audio observation is isolated");
    assert_true (requested.audio_settings.all_sources[0].channels == 6,
        "job audio track observations are deep-copied");
    assert_string_equal (requested.audio_settings.codec, AudioCodecName.COPY,
        "job codec decision cannot replace reusable user policy");
    assert_true (Math.fabs (requested.audio_processing.peak_normalize_gain_db + 3.0) < 1e-9,
        "per-file normalization result cannot leak to another job");
    assert_true (requested.pixel_format.ten_bit_selected, "job pixel settings are isolated");
    assert_string_equal (first_job.container, ContainerExt.WEBM, "copy retains requested container");
}

private void test_encode_profile_composition_preserves_processing_contract () {
    var general = new GeneralSettingsSnapshot ();
    general.delogo_enabled = true;
    general.delogo_regions = "8:10:20:24";
    general.rotate = Rotation.HORIZONTAL_FLIP;
    general.crop_enabled = true;
    general.crop_value = "160:90:4:6";
    general.video_filters.processing_filters = { "hqdn3d=1:1:1:1" };
    general.video_filters.hdr_filter = "tonemap=tonemap=hable";
    general.scale_mode = ScaleMode.CUSTOM;
    general.custom_resolution_value = "128:72";
    general.scale_algorithm = ScaleAlgorithm.POINT;
    general.scale_range = "full";
    general.frame_rate_text = FrameRateLabel.CUSTOM;
    general.custom_frame_rate_text = "24";
    general.video_speed_enabled = true;
    general.video_speed_percent = 50.0;
    general.audio_speed_enabled = true;
    general.audio_speed_percent = -50.0;
    general.color_filter = "eq=brightness=0.02";
    general.preserve_metadata = true;
    general.remove_chapters = true;
    general.watermark_enabled = true;
    general.watermark_mode = "image";
    general.watermark_image_path = "/synthetic/overlay.png";
    general.watermark_image_width = 96;
    general.watermark_position = "Top Left";
    general.watermark_opacity = 0.75;
    general.watermark_margin = 7;
    var codec = new CodecTabSettingsSnapshot ();
    codec.pixel_format.ten_bit_selected = true;
    codec.pixel_format.ten_bit_format_text = "10-bit 4:4:4";
    codec.audio_settings.codec = AudioCodecName.AAC;
    codec.audio_settings.bitrate_kbps = 192;
    codec.audio_settings.preserve_all_audio_tracks = true;
    codec.audio_processing.channel_downmix = 1;
    codec.audio_processing.normalize_enabled = true;
    codec.audio_processing.fade_in_enabled = true;
    codec.audio_processing.fade_in_duration = 0.8;
    codec.keyframe_settings.keyint_text = "Custom";
    codec.keyframe_settings.custom_mode = 1;
    codec.keyframe_settings.frame_rate_text = "24";

    var profile = CodecUtils.compose_encode_profile ("x265",
        { "-c:v", "libx265", "-crf", "23" }, codec, general);
    string before_crop = "delogo=x=8:y=10:w=20:h=24,hflip,";
    string after_crop = "hqdn3d=1:1:1:1,tonemap=tonemap=hable,";
    string output_filters = "scale=w=128:h=72:flags=point,zscale=range=full,fps=24,";
    string after_speed = "format=yuv444p10le,eq=brightness=0.02";
    assert_string_equal (profile.video_filters,
        before_crop + "crop=160:90:4:6," + after_crop + output_filters
            + "setpts=0.666667*PTS," + after_speed,
        "profile retains source-coordinate delogo and complete filter ordering");
    assert_string_equal (profile.video_filters_skip_crop,
        before_crop + after_crop + output_filters + "setpts=0.666667*PTS," + after_speed,
        "crop-free chain preserves all other transformations");
    assert_false (profile.video_filters_skip_delogo.contains ("delogo="),
        "deferred-logo chain excludes pre-rendering logo removal");
    assert_contains (profile.video_filters_skip_delogo, "hflip,crop=160:90:4:6,",
        "deferred-logo chain retains crop and rotation");
    assert_false (profile.video_filters_skip_crop_and_delogo.contains ("crop="),
        "segment-crop chain excludes shared crop");
    assert_false (profile.video_filters_skip_crop_and_delogo.contains ("delogo="),
        "segment-crop chain excludes shared delogo");
    assert_string_equal (profile.combine_video_filters_per_input,
        before_crop + after_crop + "eq=brightness=0.02",
        "combine per-input chain excludes shared output geometry and speed");
    assert_string_equal (profile.combine_video_filters_post_output,
        output_filters + "format=yuv444p10le",
        "combine output chain retains scale, frame rate and effective pixel format");
    assert_string_equal (profile.audio_filters, "atempo=0.500000", "independent audio speed survives");
    assert_true (Math.fabs (profile.video_speed_multiplier - 1.5) < 1e-9,
        "video duration policy retains speed multiplier");
    assert_true (Math.fabs (profile.audio_speed_multiplier - 0.5) < 1e-9,
        "audio duration policy retains independent speed multiplier");
    assert_array_has_adjacent_pair (profile.audio_args, "-c:a", "aac", "profile keeps audio encoder");
    assert_array_has_adjacent_pair (profile.audio_args, "-b:a", "192k", "profile keeps audio budget");
    assert_array_has_adjacent_pair (profile.audio_args, "-ac", "2", "profile keeps channel downmix");
    assert_true (profile.preserve_all_audio_tracks && profile.preserve_metadata && profile.remove_chapters,
        "profile keeps track, metadata and chapter policies");
    assert_true (profile.audio_processing.normalize_enabled && profile.audio_processing.fade_in_enabled,
        "profile carries deferred normalization and fade processing");
    assert_true (Math.fabs (profile.audio_processing.fade_in_duration - 0.8) < 1e-9,
        "profile retains fade duration");
    assert_true (profile.delogo_enabled, "profile carries deferred delogo enabled state");
    assert_string_equal (profile.delogo_regions, "8:10:20:24", "profile carries deferred logo regions");
    assert_true (profile.watermark_enabled, "profile carries image watermark enabled state");
    assert_string_equal (profile.watermark_mode, "image", "profile carries image watermark mode");
    assert_string_equal (profile.watermark_image_path, "/synthetic/overlay.png", "profile carries image identity");
    assert_true (profile.watermark_image_width == 96 && profile.watermark_margin == 7,
        "profile carries overlay geometry");
    assert_true (Math.fabs (profile.watermark_opacity - 0.75) < 1e-9, "profile carries overlay opacity");
    assert_string_equal (profile.watermark_position, "Top Left", "profile carries overlay position");
    assert_string_equal (profile.overlay_format, "yuv444p10", "overlay preserves effective output chroma/depth");
    assert_array_has_adjacent_pair (CodecUtils.build_codec_args_from_snapshot (profile, ""),
        "-g", "48", "captured 24 fps custom keyframes resolve without probing an input");
}

private void test_encode_profile_copy_freezes_execution_state () {
    var profile = new EncodeProfileSnapshot ();
    profile.codec_name = "x265";
    profile.codec_args = { "-c:v", "libx265", "-crf", "23" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "192k" };
    profile.keyframe_settings = new KeyframeSettingsSnapshot ();
    profile.keyframe_settings.keyint_text = "Custom";
    profile.keyframe_settings.custom_mode = 1;
    profile.keyframe_settings.frame_rate_text = "24";
    profile.audio_processing.normalize_enabled = true;
    profile.audio_processing.peak_normalize_gain_db = -2.0;
    profile.video_filters = "crop=160:90:4:6,format=yuv420p10le";
    profile.watermark_image_path = "/synthetic/first.png";
    profile.overlay_format = "yuv420p10";

    var running_job = profile.copy ();
    profile.codec_args[3] = "40";
    profile.audio_args[3] = "64k";
    profile.keyframe_settings.frame_rate_text = "60";
    profile.audio_processing.peak_normalize_gain_db = -15.0;
    profile.video_filters = "null";
    profile.watermark_image_path = "/synthetic/second.png";
    profile.overlay_format = "yuv420";

    assert_array_has_adjacent_pair (running_job.codec_args, "-crf", "23", "running video args are frozen");
    assert_array_has_adjacent_pair (running_job.audio_args, "-b:a", "192k", "running audio args are frozen");
    assert_array_has_adjacent_pair (CodecUtils.build_codec_args_from_snapshot (running_job, ""),
        "-g", "48", "running keyframe snapshot is deep-copied");
    assert_true (Math.fabs (running_job.audio_processing.peak_normalize_gain_db + 2.0) < 1e-9,
        "running audio processing is deep-copied");
    assert_string_equal (running_job.video_filters, "crop=160:90:4:6,format=yuv420p10le",
        "running filter chain is frozen");
    assert_string_equal (running_job.watermark_image_path, "/synthetic/first.png", "running overlay identity is frozen");
    assert_string_equal (running_job.overlay_format, "yuv420p10", "running overlay format is frozen");
    var defaults_copy = new EncodeProfileSnapshot ().copy ();
    assert_true (defaults_copy.keyframe_settings == null, "copy preserves absent keyframe policy");
}

private void test_encode_profile_jobs_do_not_leak_audio_or_format () {
    var general = new GeneralSettingsSnapshot ();
    general.crop_enabled = true;
    general.crop_value = "160:90:0:0";
    var codec = new CodecTabSettingsSnapshot ();
    codec.audio_settings.enabled = false;
    codec.pixel_format.ten_bit_selected = true;
    var first = CodecUtils.compose_encode_profile ("x265", { "-c:v", "libx265" }, codec, general);

    codec.audio_settings.enabled = true;
    codec.audio_settings.codec = AudioCodecName.AAC;
    codec.audio_settings.bitrate_kbps = 160;
    codec.pixel_format.ten_bit_selected = false;
    codec.pixel_format.eight_bit_selected = true;
    general.crop_value = "80:44:2:2";
    var second = CodecUtils.compose_encode_profile ("x264", { "-c:v", "libx264" }, codec, general);

    assert_array_contains (first.audio_args, "-an", "no-audio job remains silent");
    assert_array_not_contains (second.audio_args, "-an", "next audio-enabled job is not contaminated");
    assert_array_has_adjacent_pair (second.audio_args, "-c:a", "aac", "next job retains independent audio");
    assert_string_equal (first.video_filters, "crop=160:90:0:0,format=yuv420p10le", "first job retains its geometry and depth");
    assert_string_equal (second.video_filters, "crop=80:44:2:2,format=yuv420p", "second job uses its geometry and depth");
    assert_string_equal (first.overlay_format, "yuv420p10", "first job retains overlay depth");
    assert_string_equal (second.overlay_format, "yuv420", "second job has independent overlay depth");
    assert_false (general.pixel_format.eight_bit_selected || general.pixel_format.ten_bit_selected,
        "neither job resolved output format into shared General settings");
}

private void test_encode_profile_adapter_reconciles_effective_format_privately () {
    var trace = new ProfileAdapterTrace ();
    var builder = new ProfileAdapterBuilder (trace);
    var tab = new ProfileAdapterTab (trace, builder);
    tab.settings.pixel_format.ten_bit_selected = true;
    tab.settings.pixel_format.ten_bit_format_text = "10-bit 4:2:2";
    var general = new GeneralSettingsSnapshot ();
    general.pixel_format.eight_bit_selected = true;
    general.crop_enabled = true;
    general.crop_value = "160:90:0:0";

    var profile = CodecUtils.snapshot_encode_profile (builder, tab, general);

    assert_true (trace.tab_snapshots == 1 && trace.builder_snapshots == 1,
        "adapter captures tab and builder exactly once");
    assert_true (builder.captured_general != null && builder.captured_general != general,
        "builder receives private General state rather than the caller object");
    assert_array_has_adjacent_pair (profile.codec_args, "-pix_fmt", "yuv422p10le",
        "builder receives the codec's effective format before capturing arguments");
    assert_string_equal (profile.video_filters, "crop=160:90:0:0,format=yuv422p10le",
        "filters and builder agree on effective chroma/depth");
    assert_string_equal (profile.overlay_format, "yuv422p10", "overlay agrees with builder format");
    assert_true (general.pixel_format.eight_bit_selected, "adapter retains caller's 8-bit selection");
    assert_false (general.pixel_format.ten_bit_selected, "adapter does not write effective depth into caller");
}

private void test_encode_profile_composition_without_general_uses_defaults () {
    var codec = new CodecTabSettingsSnapshot ();
    codec.audio_settings.enabled = false;
    codec.container = "";
    var profile = CodecUtils.compose_encode_profile ("x264", { "-c:v", "libx264" }, codec, null);

    assert_string_equal (profile.container, ContainerExt.MKV, "empty container retains profile fallback");
    assert_array_contains (profile.audio_args, "-an", "audio disable works without General state");
    assert_string_equal (profile.video_filters, "", "absent General state adds no filters");
    assert_string_equal (profile.audio_filters, "", "absent General state adds no speed filters");
    assert_false (profile.watermark_enabled || profile.delogo_enabled, "absent General state adds no overlays");
    assert_true (profile.video_speed_multiplier == 1.0 && profile.audio_speed_multiplier == 1.0,
        "absent General state retains neutral duration multipliers");
}

// Captured from LegacyCodecPresets (pre-extraction implementation) using
// actual GTK widgets on 2026-11-02. Case order: codec x effort x pass.
// These values must not be regenerated from the resolver under test.
//
// Deliberate exception (TASK-20261110-x265-settings-fix, X265-F2): x265
// cases 10–15 (efforts 0–2) no longer send x265's default deblock=0,0 and,
// where it was 2.0, psy-rd=2.0, so a tune keeps its own values. Each new
// digest was checked by putting exactly those values back into its
// -x265-params and reproducing the legacy digest it replaces; no other
// field differed. Cases 16–19 and the other codecs are unchanged.
private const string[] SMART_CODEC_GOLDEN_DIGESTS = {
    // x264
    "e35e995894090fc338f6dd3ae0da0e715c5986f3f000c82f5330ede974c56bed",
    "ea6e97466f45ccb612046fb47fcdefec8ec1027ee675996d79d508f3777df2b8",
    "7ef6cec52b87c69c831bf2c83aa93e3f6746a445b0fce83e9a457df23b1f11db",
    "3275d8f304b6bd551008595181241134728d29971813dd17c2ddc63592563753",
    "90317aba6c8681ff0acef52ab53e88001a3d2a8dcc2b67970f353ac1e6913c2e",
    "c8c617cfa48d9f58bb4e8d4478ee94a9b5ea26c95116d32e50b22dd214ee3c4c",
    "804569cf4d8f3d7cdeee5002674b94e7a425271baea4bed90dd3be2d51a81fd9",
    "d2977e7d3742aa5c2b15c197a2035e28b744fd20145a5b4a4bb1e0ef46d6f2f8",
    "5bc50196dbbf58a078ba0f789f09661ea6ba2637eecdc5e5896dd29d0f8d8ba6",
    "9954489d4fd18565131c2e2f9543ea1260e5b4473c4806dcdb06c8ac97b698a2",
    // x265
    "4f4c4cad70273d94cb5ad7bcc7704c29f3e2b1f0f954da9ae737a95d2ee948b6",
    "a6aa5f30150c544ae12b34846044bbd8aeaa3ddd89cb9b57eefe2730ec723465",
    "3a10ef8e1df3caa6ab8bf477e21ad961d3e26f9feb878cf460585535304c2a02",
    "880ffa6333ac90e7a081bc300d4679fb63251b31f398613b45fcabd486da06db",
    "e6fae69bb489e19d63347cfe54a68b1ef87c03a075d11b36d68b5a3fe143572d",
    "3993adb84ac0bb377c98e5a7a9697b8e1139cdcdc1593302cb18e35afeac6d5f",
    "310da3878c190ac1c74f311c294052dc7666e06622b6a3eda4e19023cfc7a82e",
    "e02c417be205ec7485e77304cf993be7a1ed9c5c18ac186889f2b23011e30d94",
    "796ceed22cae4223cd45fc29273be906a8c7cb250be9b74d3db2bd138c5a2404",
    "e4fbee7bcf2c5aded6f557c4264aed07afe4d52f51a38195b0c9e378af6eb943",
    // VP9
    "f78cb8456b4951f89f8684c5d1d5ad2e3783446a3e28a64888feb9f8a70782f5",
    "445b0ba6a1404d0a09813476e45deb7814c4e3f78b5015771c45fe97da9400f3",
    "056ef2c9800038797cd2e38d4cad20618cefcf0e86f1f9c79b8e272cbe72ff8b",
    "d04d03ada317b4b897278c694b6858614a1193e7dfad492aea90944c99a538b9",
    "93358514b3cf4cd30e0349b199cbcaf399f26afeeffa0ee25d4c896be42c8a49",
    "6b55a1ed1b6d78f95ef73fc1f5e625931f44702a36307efafad309ee0942b1c7",
    "859f620fbeaf23922a2bcae32f7eb43277dc8d954518499bfb0d029fd0286d33",
    "d6ee7b88e8e92734ded957e67c40cb2ba1667de832561f96d21235a7ea468198",
    "a6528bc4d205e4831c574a807a56f184cba9f5dc9e145db1043b52d9dc02c863",
    "375906a09401d866801ad9ead3652255aa9ff5dc819f88a8e3a54a3161ccaabb",
    // SVT-AV1
    "605d1685ba990aa77118fc81970351f98743177da6d0701b8f30a09bafdff7af",
    "679d97fb99da56df3df4f73b328388fec22ffdcc9f47d845b67284747b78cef2",
    "5272202085a227e7ee211ad950785651486711c9b1841a2b889f81e09b57ee2a",
    "ff379af935ea933a0627352dd1b189c5b90920cf330c69753d1f4f87ecedb8af",
    "190c9f9c5b1f55b1a68933b5c1bc28330843214f9536a72319e77aedaffbc4de",
    "b2970f6d03c7bc3a4b6613283aaf9bc8ddf382ec9744725bcc6baaf3276f5cbf",
    "8e14025adaeccf3bd1403950bad05481f12e2b09daf5a359411719ec5358965c",
    "891ef1e966600e1e42e05ed2ebfe8b02b69b14d73e50577d27236adb9bfe12de",
    "2f984a6b8f795405abef0d2587657b46a33b8254bc1c1c552e5297b185a29d7e",
    "cadad9457933fb1d9ec8d7bcf3ad83f8e6620968f5102a5af565b36bd161b07b",
};

// Full-profile goldens are captured from the pre-extraction widget appliers,
// not from SmartCodecResolver. This keeps policy parity independently checked
// after the ordinary widget path also starts using the shared resolver.
private string smart_codec_case_name (int codec_index) {
    switch (codec_index) {
        case 0: return "x264";
        case 1: return "x265";
        case 2: return "vp9";
        default: return "svt-av1";
    }
}

private OptimizationRecommendation make_smart_codec_case_recommendation (int index) {
    int codec_index = index / 10;
    int effort_index = (index % 10) / 2;
    bool two_pass = (index % 2) != 0;
    string codec = smart_codec_case_name (codec_index);
    bool ten_bit = (effort_index % 2) != 0;
    return OptimizationRecommendation () {
        codec = codec,
        crf = 20 + effort_index * 3,
        preset = codec_index == 2 ? "cpu-used 4"
            : codec_index == 3 ? "preset 6" : "slow",
        two_pass = two_pass,
        target_bitrate_kbps = two_pass ? 1700 + effort_index * 100 : 0,
        content_type = (ContentType) (effort_index % 4),
        effort = (EncodeEffort) effort_index,
        size_tier = (SizeTier) effort_index,
        pinned_axis = two_pass ? PinnedAxis.SIZE : PinnedAxis.QUALITY,
        recommended_pix_fmt = ten_bit ? PixelFormat.YUV420P10LE : PixelFormat.YUV420P,
        source_bit_depth = ten_bit ? 10 : 8,
        grain_score = effort_index == 4 ? 0.008 : 0.0,
        detail_score = 0.7,
        fast_decode = effort_index == 3,
        native_sharpness = effort_index >= 3 ? 2 : 0,
        keyint_frames = 173,
        lookahead_frames = effort_index == 0 ? 0
            : codec_index == 2 ? 10 + effort_index * 3 : 24 + effort_index * 4,
        force_compat_container = effort_index == 0 && two_pass,
        resolved_container = effort_index == 0 && two_pass
            ? ((codec_index < 2) ? ContainerExt.MP4 : ContainerExt.WEBM)
            : ContainerExt.MKV,
        stream_copy_audio = effort_index == 2,
        audio_encode_kbps = effort_index == 1 || effort_index == 2 ? 0
            : effort_index == 3 ? 256 : 192,
        recommended_audio_kbps = effort_index == 2 ? 96 : 192,
        preserve_all_audio_tracks_effective = effort_index >= 3,
        strip_metadata = effort_index == 0,
        notes = "synthetic recommendation for parity coverage"
    };
}

private bool smart_codec_case_copy_allowed (int index) {
    return !(((index % 10) / 2) == 2 && (index % 2) != 0);
}

private bool smart_codec_case_strip_audio (int index) {
    return ((index % 10) / 2) == 4 && (index % 2) != 0;
}

private GeneralSettingsSnapshot make_smart_codec_case_general (int index) {
    var general = new GeneralSettingsSnapshot ();
    general.crop_enabled = true;
    general.crop_value = "320:180:4:6";
    general.frame_rate_text = FrameRateLabel.CUSTOM;
    general.custom_frame_rate_text = "24";
    general.video_filters.processing_filters = { "hqdn3d=1:1:1:1" };
    general.color_filter = "eq=brightness=0.02";
    general.preserve_metadata = true;
    general.remove_chapters = (index % 2) != 0;
    general.watermark_enabled = true;
    general.watermark_mode = "image";
    general.watermark_image_path = "/synthetic/watermark.png";
    general.watermark_image_width = 64;
    general.watermark_position = "Top Left";
    general.watermark_margin = 8;
    general.watermark_opacity = 0.75;
    general.delogo_enabled = true;
    general.delogo_regions = "8:10:20:24";
    general.audio_speed_enabled = !smart_codec_case_copy_allowed (index);
    general.audio_speed_percent = general.audio_speed_enabled ? 25.0 : 0.0;
    general.video_speed_enabled = ((index % 10) / 2) == 4;
    general.video_speed_percent = general.video_speed_enabled ? 25.0 : 0.0;
    return general;
}

private CodecTabSettingsSnapshot make_smart_codec_case_requested (int index) {
    int codec_index = index / 10;
    bool absent = (index % 10) == 0;
    var requested = new CodecTabSettingsSnapshot ();
    requested.container = ContainerExt.MKV;
    requested.audio_settings.preserve_all_audio_tracks = true;
    requested.audio_settings.enabled = !absent;
    requested.audio_settings.source.presence = absent
        ? MediaStreamPresence.ABSENT : MediaStreamPresence.PRESENT;
    requested.audio_settings.source.codec_name = absent ? "" : codec_index < 2 ? "aac" : "opus";
    requested.audio_settings.source.channels = absent ? 0 : 2;
    requested.audio_settings.source.sample_fmt = absent ? "" : "fltp";
    if (!absent) {
        requested.audio_settings.all_sources = {
            requested.audio_settings.source.copy (), requested.audio_settings.source.copy ()
        };
        requested.audio_settings.all_sources[1].stream_index = 1;
    }
    requested.audio_processing.normalize_enabled = true;
    requested.audio_processing.fade_in_enabled = true;
    requested.audio_processing.channel_downmix = 2;
    return requested;
}

private void append_smart_profile_token (StringBuilder text, string name, string value) {
    text.append_printf ("%s:%d:%s\n", name, value.length, value);
}

private void append_smart_profile_array (StringBuilder text, string name, string[] values) {
    append_smart_profile_token (text, name + ".length", values.length.to_string ());
    for (int i = 0; i < values.length; i++) {
        append_smart_profile_token (text, name + "." + i.to_string (), values[i]);
    }
}

private string serialize_smart_codec_profile (EncodeProfileSnapshot profile, bool two_pass) {
    var text = new StringBuilder ();
    append_smart_profile_token (text, "codec", profile.codec_name);
    append_smart_profile_token (text, "container", profile.container);
    append_smart_profile_token (text, "two_pass", two_pass.to_string ());
    append_smart_profile_array (text, "codec_args", profile.codec_args);
    append_smart_profile_array (text, "audio_args", profile.audio_args);
    append_smart_profile_token (text, "all_audio", profile.preserve_all_audio_tracks.to_string ());
    KeyframeSettingsSnapshot? keyframes = profile.keyframe_settings;
    append_smart_profile_token (text, "keyframes.present", (keyframes != null).to_string ());
    if (keyframes != null) {
        append_smart_profile_token (text, "keyframes.interval", keyframes.keyint_text);
        append_smart_profile_token (text, "keyframes.mode", keyframes.custom_mode.to_string ());
        append_smart_profile_token (text, "keyframes.fps", keyframes.frame_rate_text);
        append_smart_profile_token (text, "keyframes.custom_fps", keyframes.custom_frame_rate_text);
    }
    append_smart_profile_token (text, "video", profile.video_filters);
    append_smart_profile_token (text, "video.skip_crop", profile.video_filters_skip_crop);
    append_smart_profile_token (text, "video.skip_delogo", profile.video_filters_skip_delogo);
    append_smart_profile_token (text, "video.skip_crop_delogo", profile.video_filters_skip_crop_and_delogo);
    append_smart_profile_token (text, "combine.input", profile.combine_video_filters_per_input);
    append_smart_profile_token (text, "combine.output", profile.combine_video_filters_post_output);
    append_smart_profile_token (text, "audio.filters", profile.audio_filters);
    append_smart_profile_token (text, "video.speed", ConversionUtils.format_ffmpeg_double (profile.video_speed_multiplier, "%.6f"));
    append_smart_profile_token (text, "audio.speed", ConversionUtils.format_ffmpeg_double (profile.audio_speed_multiplier, "%.6f"));
    append_smart_profile_token (text, "audio.normalize", profile.audio_processing.normalize_enabled.to_string ());
    append_smart_profile_token (text, "audio.ebu", profile.audio_processing.normalize_ebu.to_string ());
    append_smart_profile_token (text, "audio.peak", ConversionUtils.format_ffmpeg_double (profile.audio_processing.peak_normalize_gain_db, "%.6f"));
    append_smart_profile_token (text, "audio.fade_in", profile.audio_processing.fade_in_enabled.to_string ());
    append_smart_profile_token (text, "audio.fade_in_duration", ConversionUtils.format_ffmpeg_double (profile.audio_processing.fade_in_duration, "%.6f"));
    append_smart_profile_token (text, "audio.fade_out", profile.audio_processing.fade_out_enabled.to_string ());
    append_smart_profile_token (text, "audio.fade_out_duration", ConversionUtils.format_ffmpeg_double (profile.audio_processing.fade_out_duration, "%.6f"));
    append_smart_profile_token (text, "audio.downmix", profile.audio_processing.channel_downmix.to_string ());
    append_smart_profile_token (text, "metadata", profile.preserve_metadata.to_string ());
    append_smart_profile_token (text, "chapters.remove", profile.remove_chapters.to_string ());
    append_smart_profile_token (text, "delogo", profile.delogo_enabled.to_string ());
    append_smart_profile_token (text, "delogo.regions", profile.delogo_regions);
    append_smart_profile_token (text, "watermark", profile.watermark_enabled.to_string ());
    append_smart_profile_token (text, "watermark.mode", profile.watermark_mode);
    append_smart_profile_token (text, "watermark.image", profile.watermark_image_path);
    append_smart_profile_token (text, "watermark.width", profile.watermark_image_width.to_string ());
    append_smart_profile_token (text, "watermark.position", profile.watermark_position);
    append_smart_profile_token (text, "watermark.opacity", ConversionUtils.format_ffmpeg_double (profile.watermark_opacity, "%.6f"));
    append_smart_profile_token (text, "watermark.margin", profile.watermark_margin.to_string ());
    append_smart_profile_token (text, "watermark.format", profile.overlay_format);
    return text.str;
}

private BaseCodecTab make_smart_codec_case_tab (int index) {
    switch (index / 10) {
        case 0: return new X264Tab ();
        case 1: return new X265Tab ();
        case 2: return new Vp9Tab ();
        default: return new SvtAv1Tab ();
    }
}

private EncodeProfileSnapshot capture_smart_codec_widget_case (
    int index, out bool two_pass) {
    var rec = make_smart_codec_case_recommendation (index);
    var requested = make_smart_codec_case_requested (index);
    var general = make_smart_codec_case_general (index);
    BaseCodecTab tab = make_smart_codec_case_tab (index);
    CodecPresets.set_dropdown_by_label (tab.container_combo, requested.container);
    var probe = new AudioStreamProbeResult () {
        presence = requested.audio_settings.source.presence,
        codec_name = requested.audio_settings.source.codec_name,
        channels = requested.audio_settings.source.channels,
        sample_fmt = requested.audio_settings.source.sample_fmt,
        all_sources = requested.audio_settings.all_sources
    };
    tab.audio_settings.apply_source_audio_probe_result (probe);
    tab.audio_settings.set_keep_all_audio_requested (true);
    tab.audio_settings.update_for_audio_speed (general.audio_speed_enabled);
    tab.audio_processing_settings.apply_snapshot (requested.audio_processing);

    tab.apply_smart_recommendation (rec);
    // These effects belonged to AppController, outside the codec appliers.
    if (rec.strip_metadata)
        general.preserve_metadata = false;
    if (smart_codec_case_strip_audio (index))
        tab.audio_settings.set_audio_enabled (false);
    two_pass = tab.get_two_pass ();
    return CodecUtils.snapshot_encode_profile (tab.get_codec_builder (), tab, general);
}




private void assert_smart_codec_case_digest (int index, EncodeProfileSnapshot profile, bool two_pass) {
    string serialized = serialize_smart_codec_profile (profile, two_pass);
    string actual = Checksum.compute_for_string (ChecksumType.SHA256, serialized);
    string expected = SMART_CODEC_GOLDEN_DIGESTS[index];
    if (actual != expected) {
        Test.fail_printf ("smart codec case %d (%s, effort %d, pass %d) expected legacy digest %s but got %s; profile: %s",
            index, smart_codec_case_name (index / 10), (index % 10) / 2, index % 2,
            expected, actual, serialized);
    }
}

private void test_smart_codec_resolver_matches_legacy_goldens () {
    for (int index = 0; index < 40; index++) {
        var requested = make_smart_codec_case_requested (index);
        var general = make_smart_codec_case_general (index);
        var rec = make_smart_codec_case_recommendation (index);
        var result = SmartCodecResolver.resolve (rec, requested, general,
            smart_codec_case_copy_allowed (index), smart_codec_case_strip_audio (index));
        assert_true (result != null, "known codec recommendation resolves");
        if (result == null) return;
        assert_smart_codec_case_digest (index, result.to_profile (), result.two_pass);
    }
}

private void test_smart_codec_widgets_match_legacy_goldens () {
    if (!ensure_gtk_widget_tests_available ()) return;
    for (int index = 0; index < 40; index++) {
        bool two_pass;
        var profile = capture_smart_codec_widget_case (index, out two_pass);
        assert_smart_codec_case_digest (index, profile, two_pass);
    }
}

private void test_smart_codec_resolver_retains_complete_effort_policy () {
    var x264 = SmartCodecResolver.resolve (make_smart_codec_case_recommendation (8),
        make_smart_codec_case_requested (8), make_smart_codec_case_general (8));
    assert_true (x264 != null && x264.builder_settings is X264BuilderSnapshot,
        "x264 has a typed complete builder snapshot");
    if (x264 == null) return;
    var x264_settings = (X264BuilderSnapshot) x264.builder_settings;
    assert_string_equal (x264_settings.ref_frames, "8", "maximum x264 effort uses eight references");
    assert_true (x264_settings.bframes == 8 && x264_settings.b_adapt == 2
            && x264_settings.subme == 11 && x264_settings.me_range == 32,
        "maximum x264 effort preserves B frames, adaptation and motion search");
    assert_true (Math.fabs (x264_settings.psy_trellis - 0.25) < 1e-9
            && x264_settings.open_gop && x264_settings.cabac && x264_settings.mbtree,
        "maximum x264 effort preserves psy, open GOP and entropy decisions");
    string[] x264_args = x264.to_profile ().codec_args;
    assert_contains (get_argv_value_after (x264_args, "-x264-params", "x264 complete parameters"),
        "ref=8:bframes=8:b-adapt=2:deblock=-1,-1:me=umh:merange=32:subme=11:psy-rd=1.0,0.25",
        "complete x264 command includes effort policy omitted by the trim shortcut");

    var x265 = SmartCodecResolver.resolve (make_smart_codec_case_recommendation (18),
        make_smart_codec_case_requested (18), make_smart_codec_case_general (18));
    assert_true (x265 != null && x265.builder_settings is X265BuilderSnapshot,
        "x265 has a typed complete builder snapshot");
    if (x265 == null) return;
    var x265_settings = (X265BuilderSnapshot) x265.builder_settings;
    assert_string_equal (x265_settings.ref_frames, "5", "maximum x265 effort uses five references");
    assert_true (x265_settings.pmode && x265_settings.sao && x265_settings.cutree
            && x265_settings.deblock_alpha == -1 && x265_settings.deblock_beta == -1,
        "maximum x265 effort preserves parallel, perceptual and deblock settings");
    assert_contains (get_argv_value_after (x265.to_profile ().codec_args, "-x265-params", "x265 complete parameters"),
        "ref=5:deblock=-1,-1:pmode=1:psy-rd=",
        "complete x265 command includes effort policy");

    var vp9 = SmartCodecResolver.resolve (make_smart_codec_case_recommendation (28),
        make_smart_codec_case_requested (28), make_smart_codec_case_general (28));
    assert_true (vp9 != null && vp9.builder_settings is Vp9BuilderSnapshot,
        "VP9 has a typed complete builder snapshot");
    if (vp9 == null) return;
    var vp9_settings = (Vp9BuilderSnapshot) vp9.builder_settings;
    assert_true (vp9_settings.altref_enabled && vp9_settings.arnr_maxframes == 15
            && vp9_settings.arnr_strength == 6 && vp9_settings.row_mt && vp9_settings.frame_parallel,
        "maximum VP9 effort preserves denoising and threading policy");
    assert_array_not_contains (vp9.to_profile ().codec_args, "-frame-parallel",
        "Smart Codec keeps libvpx's default frame parallel decoding");
    assert_string_equal (vp9_settings.aq_mode, "Complexity", "VP9 adaptive quantization is retained");
    assert_array_has_adjacent_pair (vp9.to_profile ().codec_args, "-arnr-maxframes", "15",
        "complete VP9 command retains alt-ref effort");

    var svt = SmartCodecResolver.resolve (make_smart_codec_case_recommendation (38),
        make_smart_codec_case_requested (38), make_smart_codec_case_general (38));
    assert_true (svt != null && svt.builder_settings is SvtAv1BuilderSnapshot,
        "SVT has a typed complete builder snapshot");
    if (svt == null) return;
    var svt_settings = (SvtAv1BuilderSnapshot) svt.builder_settings;
    assert_true (svt_settings.grain_enabled && svt_settings.grain_denoise_selected == 1
            && svt_settings.qm_enabled && svt_settings.qm_min == 8 && svt_settings.qm_max == 15,
        "grainy maximum-effort SVT retains film grain and quantization matrices");
    string svt_params = get_argv_value_after (svt.to_profile ().codec_args, "-svtav1-params", "SVT complete parameters");
    assert_contains (svt_params, "film-grain=", "complete SVT command retains measured grain policy");
    assert_contains (svt_params, "film-grain-denoise=1", "complete SVT command retains grain denoise mode");
    assert_contains (svt_params, "qm-min=8:qm-max=15", "complete SVT command retains effort-specific QM range");
}

private void test_smart_codec_resolver_audio_policy_and_processing_reset () {
    var requested = make_smart_codec_case_requested (4);
    var general = make_smart_codec_case_general (4);
    var rec = make_smart_codec_case_recommendation (4);
    rec.preserve_all_audio_tracks_effective = false;
    rec.recommended_audio_kbps = 96;
    general.audio_speed_enabled = true;
    general.audio_speed_percent = 25.0;
    // No UI-derived copy_allowed argument: General speed must itself forbid Copy.
    var result = SmartCodecResolver.resolve (rec, requested, general);
    assert_true (result != null, "copy-constrained recommendation resolves");
    if (result == null) return;
    var profile = result.to_profile ();
    assert_array_has_adjacent_pair (profile.audio_args, "-c:a", "aac",
        "General audio speed forces re-encode even when copy_allowed defaults true");
    assert_array_has_adjacent_pair (profile.audio_args, "-b:a", "128k",
        "copy fallback rounds the 96 kbps source budget up to the next supported rung");
    assert_false (profile.audio_processing.normalize_enabled
            || profile.audio_processing.fade_in_enabled || profile.audio_processing.fade_out_enabled,
        "normal Smart Optimizer reset semantics discard codec-local processing");
    assert_true (profile.audio_processing.channel_downmix == 0,
        "normal Smart Optimizer reset semantics discard codec-local downmix");
    assert_false (profile.preserve_all_audio_tracks, "effective recommendation track policy wins");
    assert_true (requested.audio_settings.preserve_all_audio_tracks
            && requested.audio_processing.normalize_enabled && requested.audio_processing.channel_downmix == 2,
        "resolving does not erase reusable requested policy or processing values");

    var stripped = SmartCodecResolver.resolve (rec, requested, general, true, true);
    assert_true (stripped != null, "explicit No Audio recommendation resolves");
    if (stripped != null)
        assert_array_contains (stripped.to_profile ().audio_args, "-an", "explicit No Audio is carried to output");

    var absent = SmartCodecResolver.resolve (make_smart_codec_case_recommendation (0),
        make_smart_codec_case_requested (0), make_smart_codec_case_general (0));
    assert_true (absent != null, "silent source recommendation resolves");
    if (absent != null)
        assert_array_contains (absent.to_profile ().audio_args, "-an",
            "source with no audio stays silent after default audio reset");
}

private void test_smart_codec_resolver_owns_inputs_and_profiles () {
    var requested = make_smart_codec_case_requested (19);
    var general = make_smart_codec_case_general (19);
    var rec = make_smart_codec_case_recommendation (19);
    var result = SmartCodecResolver.resolve (rec, requested, general);
    assert_true (result != null, "independent recommendation resolves");
    if (result == null) return;
    var first = result.to_profile ();
    string frozen = serialize_smart_codec_profile (first, result.two_pass);
    requested.audio_settings.source.codec_name = "changed";
    requested.audio_settings.all_sources[0].channels = 8;
    requested.audio_processing.normalize_enabled = false;
    general.crop_value = "16:16:0:0";
    general.video_filters.processing_filters[0] = "null";
    general.watermark_image_path = "/synthetic/replaced.png";
    assert_string_equal (serialize_smart_codec_profile (result.to_profile (), result.two_pass), frozen,
        "caller changes cannot rewrite an existing resolved job");
    result.codec_settings.audio_settings.codec = AudioCodecName.FLAC;
    if (result.general_settings != null)
        result.general_settings.watermark_image_path = "/synthetic/another.png";
    assert_string_equal (serialize_smart_codec_profile (first, result.two_pass), frozen,
        "later changes to resolution data cannot rewrite an already captured execution profile");

    var tiny = make_smart_codec_case_recommendation (1);
    var tiny_general = make_smart_codec_case_general (1);
    var tiny_result = SmartCodecResolver.resolve (tiny, make_smart_codec_case_requested (1), tiny_general);
    assert_true (tiny_result != null, "metadata-stripping recommendation resolves");
    if (tiny_result != null) {
        assert_false (tiny_result.to_profile ().preserve_metadata,
            "recommendation metadata stripping reaches the resolved profile");
    }
    assert_true (tiny_general.preserve_metadata,
        "recommendation metadata policy does not change the caller's General preferences");
    rec.codec = "unknown";
    assert_true (SmartCodecResolver.resolve (rec, requested, general) == null,
        "unknown codecs cannot silently become a different encoder");
}

private void test_smart_codec_resolver_preserves_inactive_crf_defaults () {
    for (int codec_index = 0; codec_index < 4; codec_index++) {
        int index = codec_index * 10 + 9;
        var result = SmartCodecResolver.resolve (make_smart_codec_case_recommendation (index),
            make_smart_codec_case_requested (index), make_smart_codec_case_general (index));
        assert_true (result != null && result.two_pass, "bitrate recommendation resolves as two-pass");
        if (result == null) return;
        int inactive_crf = -1;
        int expected = 28;
        if (result.builder_settings is X264BuilderSnapshot) {
            inactive_crf = ((X264BuilderSnapshot) result.builder_settings).crf;
            expected = 23;
        } else if (result.builder_settings is X265BuilderSnapshot) {
            inactive_crf = ((X265BuilderSnapshot) result.builder_settings).crf;
        } else if (result.builder_settings is Vp9BuilderSnapshot) {
            inactive_crf = ((Vp9BuilderSnapshot) result.builder_settings).crf;
            expected = 31;
        } else if (result.builder_settings is SvtAv1BuilderSnapshot) {
            inactive_crf = ((SvtAv1BuilderSnapshot) result.builder_settings).crf;
        }
        assert_true (inactive_crf == expected,
            "inactive CRF retains the legacy reset default while two-pass bitrate is selected");
    }
}

private void test_smart_codec_resolver_selects_owned_filter_depth_variants () {
    const string EIGHT_BIT_FILTER = "nlmeans=s=3.000:p=7:r=15";
    const string TEN_BIT_FILTER = "nlmeans=s=0.1875:p=7:r=15";
    var general = make_smart_codec_case_general (12);
    general.pixel_format.eight_bit_selected = true;
    general.video_filters.has_depth_variants = true;
    general.video_filters.processing_filters_eight_bit = { EIGHT_BIT_FILTER };
    general.video_filters.processing_filters_ten_bit = { TEN_BIT_FILTER };
    general.video_filters.processing_filters = { EIGHT_BIT_FILTER };
    var requested = make_smart_codec_case_requested (12);
    var rec = make_smart_codec_case_recommendation (12);
    rec.recommended_pix_fmt = PixelFormat.YUV420P10LE;
    rec.source_bit_depth = 10;

    var ten_bit_job = SmartCodecResolver.resolve (rec, requested, general);
    assert_true (ten_bit_job != null, "10-bit recommendation resolves with captured filter variants");
    if (ten_bit_job == null) return;
    string ten_bit_chain = ten_bit_job.to_profile ().video_filters;
    assert_contains (ten_bit_chain, TEN_BIT_FILTER,
        "resolved output depth selects the matching captured filter variant");
    assert_false (ten_bit_chain.contains (EIGHT_BIT_FILTER),
        "10-bit profile does not retain the previously active 8-bit filter strength");
    assert_string_equal (general.video_filters.processing_filters[0], EIGHT_BIT_FILTER,
        "resolving output depth does not overwrite the caller's active filters");
    assert_true (general.pixel_format.eight_bit_selected && !general.pixel_format.ten_bit_selected,
        "resolving output depth leaves the caller's bit-depth selection unchanged");

    var copied = general.copy ();
    copied.video_filters.processing_filters_eight_bit[0] = "null";
    copied.video_filters.processing_filters_ten_bit[0] = "negate";
    copied.video_filters.select_bit_depth (true);
    assert_string_equal (general.video_filters.processing_filters_eight_bit[0], EIGHT_BIT_FILTER,
        "copied 8-bit variant array is independently owned");
    assert_string_equal (general.video_filters.processing_filters_ten_bit[0], TEN_BIT_FILTER,
        "copied 10-bit variant array is independently owned");
    assert_contains (ten_bit_job.to_profile ().video_filters, TEN_BIT_FILTER,
        "mutating a later settings copy does not change the already resolved job");

    rec.recommended_pix_fmt = PixelFormat.YUV420P;
    rec.source_bit_depth = 8;
    var eight_bit_job = SmartCodecResolver.resolve (rec, requested, general);
    assert_true (eight_bit_job != null, "subsequent 8-bit recommendation resolves separately");
    if (eight_bit_job != null) {
        assert_contains (eight_bit_job.to_profile ().video_filters, EIGHT_BIT_FILTER,
            "subsequent 8-bit job selects the 8-bit filter variant");
        assert_false (eight_bit_job.to_profile ().video_filters.contains (TEN_BIT_FILTER),
            "prior 10-bit resolution does not contaminate subsequent jobs");
    }

    // Existing manually constructed snapshots carry only processing_filters.
    // They must keep working without populating the new optional variants.
    general.video_filters.has_depth_variants = false;
    general.video_filters.processing_filters = { "unsharp=5:5:0.5:5:5:0" };
    rec.recommended_pix_fmt = PixelFormat.YUV420P10LE;
    var legacy_snapshot_job = SmartCodecResolver.resolve (rec, requested, general);
    assert_true (legacy_snapshot_job != null, "legacy single-filter snapshot still resolves");
    if (legacy_snapshot_job != null) {
        assert_contains (legacy_snapshot_job.to_profile ().video_filters,
            "unsharp=5:5:0.5:5:5:0", "single-filter snapshots keep their supplied processing chain");
    }
}

private void test_smart_codec_target_adapter_does_not_mutate_recommendation () {
    if (!ensure_gtk_widget_tests_available ()) return;
    var rec = make_smart_codec_case_recommendation (6);
    rec.codec = "not-the-target";
    rec.preset = "slow";
    var x264 = new X264Tab ();
    var x265 = new X265Tab ();
    for (int i = 0; i < 3; i++) {
        CodecPresets.apply_smart_x264 (x264, rec);
        assert_string_equal (rec.codec, "not-the-target",
            "target adapter does not overwrite/free the caller's codec string");
        assert_array_has_adjacent_pair (x264.get_codec_builder ().get_codec_args (),
            "-c:v", "libx264", "target-specific x264 method keeps its historical target contract");
        CodecPresets.apply_smart_x265 (x265, rec);
        assert_string_equal (rec.codec, "not-the-target",
            "another adapter can reuse the same borrowed recommendation");
        assert_array_has_adjacent_pair (x265.get_codec_builder ().get_codec_args (),
            "-c:v", "libx265", "target-specific x265 method keeps its historical target contract");
    }
}

private class PreparedProbeCapture : Object {
    public string expected_executable = "/synthetic/captured-ffprobe";
    public int calls = 0;
    public int wrong_executable = 0;
    public bool fail = false;

    public int capture (string[] argv, out string stdout_text, out string stderr_text) {
        calls++;
        if (argv.length == 0 || argv[0] != expected_executable)
            wrong_executable++;
        stdout_text = "";
        stderr_text = "";
        if (fail) return 1;
        string command = string.joinv (" ", argv);
        if (command.contains ("stream=r_frame_rate"))
            stdout_text = "24/1\n";
        else if (command.contains ("stream=codec_type"))
            stdout_text = "{\"streams\":[{\"codec_type\":\"video\"}],\"chapters\":[]}";
        else if (command.contains ("packet=pts_time,duration_time"))
            stdout_text = command.contains ("%+#1") ? "0.000000,0.040000\n"
                : "0.000000,0.040000\n1.960000,0.040000\n";
        else if (command.contains ("stream_tags=DURATION"))
            stdout_text = "{\"streams\":[{\"codec_name\":\"aac\",\"duration\":\"2.0\"}],\"format\":{\"duration\":\"2.0\"}}";
        else if (command.contains ("format_tags=title"))
            stdout_text = "{\"format\":{\"tags\":{\"title\":\"Synthetic title\"}}}";
        else if (command.contains ("format=duration"))
            stdout_text = "2.0\n";
        else if (command.contains ("stream=index"))
            stdout_text = "0\n";
        else
            return 1;
        return 0;
    }
}

private string prepared_fixture_dir () {
    try {
        return DirUtils.make_tmp ("ffmpeg-prepared-runtime-XXXXXX");
    } catch (Error e) {
        Test.fail_printf ("could not create prepared conversion fixture: %s", e.message);
        return "";
    }
}

private bool write_prepared_test_file (string path, string text, bool executable = false) {
    try {
        FileUtils.set_contents (path, text);
    } catch (Error e) {
        Test.fail_printf ("could not write prepared fixture: %s", e.message);
        return false;
    }
    if (executable && Posix.chmod (path, 0755) != 0) {
        Test.fail_printf ("could not make prepared fixture executable");
        return false;
    }
    return true;
}

private string read_prepared_test_file (string path) {
    string text = "";
    try {
        FileUtils.get_contents (path, out text);
    } catch (Error e) {
        Test.fail_printf ("could not read prepared fixture: %s", e.message);
    }
    return text;
}

private void restore_prepared_runtime_preferences (ConversionRuntimeOptions saved) {
    var settings = AppSettings.get_default ();
    settings.ffmpeg_path = saved.ffmpeg_path;
    settings.ffprobe_path = saved.ffprobe_path;
    settings.generate_collage_thumbnail = saved.generate_collage_thumbnail;
    settings.collage_size = saved.collage_size;
    settings.overwrite_enabled = saved.overwrite_enabled;
}

private void test_prepared_config_and_runtime_are_deep_copies () {
    var settings = AppSettings.get_default ();
    var saved = ConversionRuntimeOptions.capture_current ();
    try {
        settings.ffmpeg_path = "/synthetic/captured-ffmpeg";
        settings.ffprobe_path = "/synthetic/captured-ffprobe";
        settings.generate_collage_thumbnail = true;
        settings.collage_size = CollageSize.HD_720;
        settings.overwrite_enabled = true;
        var config = new ConversionConfig ();
        config.runtime_options = ConversionRuntimeOptions.capture_current ();
        config.profile.codec_name = "x264";
        config.profile.codec_args = { "-c:v", "libx264", "-crf", "23" };
        config.profile.audio_args = { "-an" };
        config.profile.keyframe_settings = new KeyframeSettingsSnapshot ();
        config.profile.keyframe_settings.keyint_text = "173";
        config.seek_enabled = true;
        config.seek_timestamp = "00:00:01.250";
        config.time_enabled = true;
        config.time_timestamp = "00:00:02.000";
        config.source_span_seconds = 2.0;
        config.video_source_span_seconds = 1.5;
        config.output_fps = 24.0;
        config.timed_stream_topology_known = true;
        config.input_has_chapters = true;
        config.smart_requested_size_kib = 2048;
        config.smart_planned_size_kib = 1980;
        config.smart_planning_uncertainty = 0.1;
        config.passlog_base = "/synthetic/foreign-passlog";
        var captured = config.copy ();
        ConversionRuntimeOptions? runtime = captured.runtime_options;
        assert_true (runtime != null, "config copy retains explicit runtime snapshot");
        if (runtime == null) return;
        config.runtime_options.ffmpeg_path = "/synthetic/mutated-original";
        config.profile.codec_args[1] = "mutated-original";
        config.profile.keyframe_settings.keyint_text = "240";
        config.profile.audio_processing.peak_normalize_gain_db = -9.0;
        settings.ffmpeg_path = "/synthetic/later-global-ffmpeg";
        settings.ffprobe_path = "/synthetic/later-global-ffprobe";
        settings.generate_collage_thumbnail = false;
        settings.collage_size = CollageSize.UHD_4K;
        settings.overwrite_enabled = false;
        var runner = new ConversionRunner.for_command_test (captured);
        string[] argv = runner.build_single_pass_argv_for_test ("/synthetic/input.mkv", "/synthetic/output.mkv");
        assert_string_equal (argv[0], "/synthetic/captured-ffmpeg", "runner uses captured executable after preferences change");
        assert_array_has_adjacent_pair (argv, "-c:v", "libx264", "config owns copied codec arguments");
        assert_array_has_adjacent_pair (argv, "-ss", "00:00:01.250", "copied seek remains effective");
        assert_array_has_adjacent_pair (argv, "-t", "00:00:02.000", "copied duration remains effective");
        assert_string_equal (runtime.ffprobe_path, "/synthetic/captured-ffprobe", "probe executable is captured too");
        assert_true (runtime.generate_collage_thumbnail && runtime.collage_size == CollageSize.HD_720
                && runtime.overwrite_enabled, "collage and overwrite preferences are frozen together");
        assert_true (captured.profile.keyframe_settings.keyint_text == "173"
                && captured.profile.audio_processing.peak_normalize_gain_db == 0.0,
            "config copy owns nested execution settings");
        assert_true (captured.source_span_seconds == 2.0 && captured.video_source_span_seconds == 1.5
                && captured.output_fps == 24.0 && captured.timed_stream_topology_known && captured.input_has_chapters,
            "copy retains effective timeline, progress and topology");
        assert_true (captured.smart_requested_size_kib == 2048 && captured.smart_planned_size_kib == 1980
                && Math.fabs (captured.smart_planning_uncertainty - 0.1) < 1e-9,
            "copy retains optimizer size reporting");
        string[] collage = runner.build_collage_argv_for_test ("/synthetic/output.mkv", "/synthetic/collage.png", 2.0);
        assert_string_equal (collage[0], "/synthetic/captured-ffmpeg", "collage command also uses captured executable");
        var legacy = new ConversionConfig ();
        assert_true (legacy.copy ().runtime_options == null, "manual configs retain legacy capture-at-execution semantics");
    } finally {
        restore_prepared_runtime_preferences (saved);
    }
}

private void test_prepared_probes_use_explicit_path_and_controlled_capture () {
    var capture = new PreparedProbeCapture ();
    const string INPUT = "/synthetic/input.mkv";
    const string TOOL = "/synthetic/captured-ffprobe";
    assert_true (FfprobeUtils.probe_duration (INPUT, capture.capture, TOOL) == 2.0, "controlled duration parses result");
    assert_true (FfprobeUtils.probe_input_fps (INPUT, capture.capture, TOOL) == 24.0, "controlled FPS parses result");
    assert_true (FfprobeUtils.has_video_stream (INPUT, capture.capture, TOOL), "controlled video-presence probe parses result");
    var topology = FfprobeUtils.probe_timed_stream_topology (INPUT, capture.capture, TOOL);
    assert_true (topology.success && !topology.has_subtitle_stream && !topology.has_chapters,
        "controlled topology parses captured JSON");
    var timeline = FfprobeUtils.probe_video_timeline (INPUT, capture.capture, TOOL);
    assert_true (timeline.success && Math.fabs (timeline.get_duration () - 2.0) < 1e-9,
        "all stages of packet timeline probing use controlled capture");
    assert_string_equal (FfprobeUtils.probe_title (INPUT, capture.capture, TOOL) ?? "", "Synthetic title",
        "metadata naming can use captured probe executable");
    assert_true (FfprobeUtils.probe_primary_audio_duration (INPUT, capture.capture, TOOL) == 2.0,
        "audio-duration fallback can use captured probe executable");
    string dir = prepared_fixture_dir ();
    if (dir.length == 0) return;
    try {
        string path = Path.build_filename (dir, "synthetic-output.mkv");
        if (!write_prepared_test_file (path, "synthetic output bytes")) return;
        string reason;
        assert_true (FfprobeUtils.output_file_is_usable (path, out reason, capture.capture, TOOL),
            "final output validation uses controlled captured probe");
        assert_true (capture.calls >= 10 && capture.wrong_executable == 0,
            "every probe, including timeline subcalls, uses the explicit executable");
        capture.fail = true;
        assert_false (FfprobeUtils.output_file_is_usable (path, out reason, capture.capture, TOOL),
            "failed controlled validation does not declare output usable");
        assert_contains (reason, "no media", "failed duration verification remains explicit");
    } finally {
        cleanup_exec_test_dir (dir);
    }
}

private string make_prepared_probe_script (string dir, string name, bool block_duration = false) {
    string path = Path.build_filename (dir, name);
    string trace = Shell.quote (Path.build_filename (dir, "probe.trace"));
    string marker = Shell.quote (Path.build_filename (dir, "probe.started"));
    string blocking = block_duration
        ? "case \"$*\" in *format=duration*) : > " + marker
            + "; trap 'exit 143' TERM INT; while :; do sleep 0.02; done ;; esac\n"
        : "";
    string script = "#!/bin/sh\n"
        + "printf 'PROBE\\n' >> " + trace + "\n"
        + "printf '<%s>\\n' \"$@\" >> " + trace + "\n"
        + blocking
        + "case \"$*\" in\n"
        + "  *stream=r_frame_rate*) printf '24/1\\n' ;;\n"
        + "  *stream=codec_type*) printf '%s\\n' '{\"streams\":[{\"codec_type\":\"video\"}],\"chapters\":[]}' ;;\n"
        + "  *packet=pts_time,duration_time*) printf '0.000000,0.040000\\n1.960000,0.040000\\n' ;;\n"
        + "  *format=duration*) printf '2.0\\n' ;;\n"
        + "  *stream=index*) printf '0\\n' ;;\n"
        + "  *) printf '0\\n' ;;\n"
        + "esac\n";
    write_prepared_test_file (path, script, true);
    return path;
}

private string make_prepared_encoder_script (string dir) {
    string path = Path.build_filename (dir, "captured-ffmpeg.sh");
    string trace = Shell.quote (Path.build_filename (dir, "encoder.trace"));
    string script = "#!/bin/sh\n"
        + "printf 'ENCODE\\n' >> " + trace + "\n"
        + "printf '<%s>\\n' \"$@\" >> " + trace + "\n"
        + "last=''; passlog=''; next=''\n"
        + "for arg in \"$@\"; do\n"
        + "  if [ \"$next\" = passlog ]; then passlog=\"$arg\"; next=''; fi\n"
        + "  if [ \"$arg\" = -passlogfile ]; then next=passlog; fi\n"
        + "  last=\"$arg\"\n"
        + "done\n"
        + "if [ -n \"$passlog\" ]; then printf 'owned log' > \"${passlog}-0.log\"; fi\n"
        + "if [ \"$last\" != /dev/null ]; then printf 'synthetic encoded output' > \"$last\"; fi\n"
        + "printf 'frame=48\\nprogress=end\\n' >&2\n";
    write_prepared_test_file (path, script, true);
    return path;
}

private class PreparedTerminalCapture : Object {
    public int succeeded = 0;
    public int failed = 0;
    public int cancelled = 0;
    public uint64 last_id = 0;

    public int count () { return succeeded + failed + cancelled; }

    // Keep cleanup waits free of closures: Vala 0.56 can emit duplicate
    // closure helpers when a captured lambda is generated from a finally block.
    public bool wait_for_count (int expected, int timeout_ms) {
        MainContext context = MainContext.default ();
        int64 deadline = get_monotonic_time () + (timeout_ms * TimeSpan.MILLISECOND);
        while (get_monotonic_time () < deadline) {
            while (context.pending ())
                context.iteration (false);
            if (count () >= expected)
                return true;
            Thread.usleep (1000);
        }
        return count () >= expected;
    }

    public void bind (Converter converter) {
        converter.conversion_succeeded.connect ((id, result) => { succeeded++; last_id = id; });
        converter.conversion_failed.connect ((id) => { failed++; last_id = id; });
        converter.conversion_cancelled.connect ((id, reason) => { cancelled++; last_id = id; });
    }
}

private ConversionConfig make_prepared_execution_config (string ffmpeg, string ffprobe) {
    var config = new ConversionConfig ();
    config.profile.codec_name = "x264";
    config.profile.codec_args = { "-c:v", "libx264", "-b:v", "100k" };
    config.profile.audio_args = { "-an" };
    config.profile.container = ContainerExt.MKV;
    config.runtime_options = new ConversionRuntimeOptions ();
    config.runtime_options.ffmpeg_path = ffmpeg;
    config.runtime_options.ffprobe_path = ffprobe;
    config.runtime_options.generate_collage_thumbnail = false;
    return config;
}

private void test_prepared_worker_owns_passlog_and_captured_request () {
    if (!ensure_gtk_widget_tests_available ()) return;
    string dir = prepared_fixture_dir ();
    if (dir.length == 0) return;
    var saved = ConversionRuntimeOptions.capture_current ();
    var converter = new Converter (new StatusArea (), new ConsoleTab (), new GeneralTab ());
    var terminal = new PreparedTerminalCapture ();
    terminal.bind (converter);
    try {
        string input = Path.build_filename (dir, "synthetic-input.mkv");
        string output = Path.build_filename (dir, "synthetic-output.mkv");
        string foreign = Path.build_filename (dir, "foreign-passlog");
        if (!write_prepared_test_file (input, "synthetic input bytes")
                || !write_prepared_test_file (foreign + "-0.log", "foreign sentinel")) return;
        var config = make_prepared_execution_config (make_prepared_encoder_script (dir),
            make_prepared_probe_script (dir, "captured-ffprobe.sh"));
        config.passlog_base = foreign;
        var settings = AppSettings.get_default ();
        settings.ffmpeg_path = "/synthetic/incorrect-live-ffmpeg";
        settings.ffprobe_path = "/synthetic/incorrect-live-ffprobe";
        settings.generate_collage_thumbnail = true;
        assert_true (converter.start_prepared_conversion (input, output, config, true, 701),
            "prepared two-pass conversion starts from data without a codec tab");
        string? owned = converter.passlog_base;
        assert_true (owned != null && owned != foreign,
            "prepared execution allocates its own passlog rather than trusting caller path");
        assert_string_equal (config.passlog_base, foreign, "prepared start does not rewrite caller config");
        config.profile.codec_args[1] = "mutated-after-start";
        config.runtime_options.ffmpeg_path = "/synthetic/mutated-after-start";
        assert_true (spin_main_context_until_deadline (() => { return terminal.count () == 1; }, 6000),
            "prepared worker reaches a terminal signal");
        assert_true (terminal.succeeded == 1 && terminal.failed == 0 && terminal.cancelled == 0
                && terminal.last_id == 701, "prepared worker reports success once for its operation");
        string trace = read_prepared_test_file (Path.build_filename (dir, "encoder.trace"));
        assert_true (trace.split ("ENCODE\n").length - 1 == 2,
            "captured collage=false stays false despite live preference changes");
        assert_contains (trace, "<libx264>", "worker retains captured codec arguments");
        assert_false (trace.contains ("mutated-after-start"), "worker does not read changed caller config");
        assert_string_equal (read_prepared_test_file (foreign + "-0.log"), "foreign sentinel",
            "cleanup never touches the supplied foreign passlog");
        assert_true (converter.passlog_base == null, "owned passlog state is cleared before terminal delivery");
        if (owned != null) {
            assert_false (FileUtils.test (owned + "-0.log", FileTest.EXISTS),
                "owned two-pass artifacts are cleaned before terminal delivery");
        }
        assert_true (FileUtils.test (output, FileTest.IS_REGULAR), "fake execution produced its local test output");
    } finally {
        converter.cancel ();
        if (terminal.count () == 0)
            terminal.wait_for_count (1, 6000);
        restore_prepared_runtime_preferences (saved);
        cleanup_exec_test_dir (dir);
    }
}

private void test_prepared_worker_cancels_initial_probe_and_can_retry () {
    if (!ensure_gtk_widget_tests_available ()) return;
    string dir = prepared_fixture_dir ();
    if (dir.length == 0) return;
    var converter = new Converter (new StatusArea (), new ConsoleTab (), new GeneralTab ());
    var terminal = new PreparedTerminalCapture ();
    terminal.bind (converter);
    bool retry_started = false;
    try {
        string input = Path.build_filename (dir, "synthetic-input.mkv");
        string output = Path.build_filename (dir, "synthetic-output.mkv");
        if (!write_prepared_test_file (input, "synthetic input bytes")) return;
        var config = make_prepared_execution_config (make_prepared_encoder_script (dir),
            make_prepared_probe_script (dir, "blocking-ffprobe.sh", true));
        assert_true (converter.start_prepared_conversion (input, output, config, true, 702),
            "prepared worker starts before controlled initial probe");
        assert_true (spin_main_context_until_deadline (() => {
            return FileUtils.test (Path.build_filename (dir, "probe.started"), FileTest.EXISTS);
        }, 3000), "initial duration probe has actually started before cancellation");
        assert_false (converter.start_prepared_conversion (input, output, config, true, 703),
            "a busy prepared conversion cannot be replaced by another start");
        converter.cancel ();
        assert_true (spin_main_context_until_deadline (() => { return terminal.count () == 1; }, 6000),
            "cancellation waits for initial probe termination and cleanup");
        assert_true (terminal.cancelled == 1 && terminal.succeeded == 0 && terminal.failed == 0
                && terminal.last_id == 702, "initial probe cancellation reports exactly one terminal result");
        string probe_trace = read_prepared_test_file (Path.build_filename (dir, "probe.trace"));
        assert_true (probe_trace.split ("PROBE\n").length - 1 == 1,
            "cancelled first probe does not launch FPS/topology/timeline helpers");
        assert_false (FileUtils.test (Path.build_filename (dir, "encoder.trace"), FileTest.EXISTS),
            "cancelled initial probe never launches an encoder");
        assert_true (converter.passlog_base == null, "cancelled start cleans its owned passlog state");
        config.runtime_options.ffprobe_path = make_prepared_probe_script (dir, "retry-ffprobe.sh");
        retry_started = converter.start_prepared_conversion (input, output, config, false, 704);
        assert_true (retry_started,
            "same converter can accept a new prepared job after cancelled cleanup");
        assert_true (spin_main_context_until_deadline (() => { return terminal.count () == 2; }, 6000),
            "retry finishes without a stale old completion interfering");
        assert_true (terminal.cancelled == 1 && terminal.succeeded == 1 && terminal.failed == 0
                && terminal.last_id == 704, "retry receives its own single successful terminal result");
    } finally {
        converter.cancel ();
        int expected_terminals = retry_started ? 2 : 1;
        if (terminal.count () < expected_terminals)
            terminal.wait_for_count (expected_terminals, 6000);
        cleanup_exec_test_dir (dir);
    }
}

private void test_prepared_optimizer_captures_runtime_and_precancel_skips_spawn () {
    string dir = prepared_fixture_dir ();
    if (dir.length == 0) return;
    var saved = ConversionRuntimeOptions.capture_current ();
    try {
        string executable = Path.build_filename (dir, "no-vmaf-ffmpeg.sh");
        string marker = Path.build_filename (dir, "optimizer.started");
        string script = "#!/bin/sh\nprintf 'called\\n' >> " + Shell.quote (marker)
            + "\nprintf 'Filters:\\n ... scale V->V Scale video\\n'\n";
        if (!write_prepared_test_file (executable, script, true)) return;
        var options = new ConversionRuntimeOptions ();
        options.ffmpeg_path = executable;
        options.ffprobe_path = "/synthetic/probe-must-not-start";
        var optimizer = new SmartOptimizer (null, options);
        options.ffmpeg_path = "/synthetic/mutated-options";
        AppSettings.get_default ().ffmpeg_path = "/synthetic/mutated-global";
        bool done = false;
        bool unsupported = false;
        optimizer.optimize_for_quality.begin ("/synthetic/not-a-media-file",
            SmartOptimizerLogic.QualityIntent.HIGH, "x264", OptimizationContext (), null, (obj, res) => {
                try {
                    optimizer.optimize_for_quality.end (res);
                } catch (IOError.NOT_SUPPORTED e) {
                    unsupported = true;
                } catch (Error e) {
                    Test.fail_printf ("unexpected captured optimizer failure: %s", e.message);
                }
                done = true;
            });
        assert_true (spin_main_context_until_deadline (() => { return done; }, 3000),
            "quality capability preflight completes without inspecting a source");
        assert_true (unsupported && FileUtils.test (marker, FileTest.EXISTS),
            "optimizer uses its captured executable, not mutated options or global paths");
        FileUtils.unlink (marker);
        var cancelled = new Cancellable ();
        cancelled.cancel ();
        bool probe_done = false;
        double duration = -1.0;
        FfprobeUtils.probe_duration_async.begin ("/synthetic/not-a-media-file", cancelled,
            executable, (obj, res) => {
                duration = FfprobeUtils.probe_duration_async.end (res);
                probe_done = true;
            });
        assert_true (spin_main_context_until_deadline (() => { return probe_done; }, 3000),
            "pre-cancelled probe completes promptly");
        assert_true (duration == 0.0 && !FileUtils.test (marker, FileTest.EXISTS),
            "pre-cancelled async probe does not spawn a child");
    } finally {
        restore_prepared_runtime_preferences (saved);
        cleanup_exec_test_dir (dir);
    }
}

private void test_prepared_naming_and_calibration_filter_contracts () {
    const string OPENCL_CHAIN = "format=yuv420p,hwupload,nlmeans_opencl=s=2,hwdownload,format=yuv420p";
    assert_string_equal (FilterBuilder.retarget_yuv_pixel_format_filters (OPENCL_CHAIN, PixelFormat.YUV420P10LE),
        "format=yuv420p10le,hwupload,nlmeans_opencl=s=2,hwdownload,format=yuv420p10le",
        "existing calibration retargeting updates both explicit OpenCL wrapper formats");
    string dir = prepared_fixture_dir ();
    if (dir.length == 0) return;
    string output_directory = Path.build_filename (dir, "not-created-output");
    var settings = AppSettings.get_default ();
    OutputNameMode saved_mode = settings.output_name_mode;
    string saved_custom = settings.output_custom_name;
    try {
        settings.output_name_mode = OutputNameMode.CUSTOM;
        settings.output_custom_name = "captured-name";
        var naming = OutputNamingSettingsSnapshot.capture_current ();
        settings.output_name_mode = OutputNameMode.DEFAULT;
        settings.output_custom_name = "later-name";
        var profile = new EncodeProfileSnapshot ();
        profile.codec_name = "SVT-AV1";
        profile.container = ContainerExt.WEBM;
        bool done = false;
        string result = "";
        ConversionUtils.compute_output_path_from_profile_async.begin ("/synthetic/source.mkv",
            output_directory, profile, naming, null, "/synthetic/probe", (obj, res) => {
                try {
                    result = ConversionUtils.compute_output_path_from_profile_async.end (res);
                } catch (Error e) {
                    Test.fail_printf ("captured output naming failed: %s", e.message);
                }
                done = true;
            });
        naming.custom_name = "changed-after-call";
        assert_true (spin_main_context_until_deadline (() => { return done; }, 3000),
            "captured custom naming completes");
        assert_string_equal (result, Path.build_filename (output_directory, "captured-name-av1.webm"),
            "profile-based naming uses captured mode/name and the resolved container");
        assert_false (FileUtils.test (output_directory, FileTest.EXISTS),
            "resolving a planned output path does not create destination directories");
    } finally {
        settings.output_name_mode = saved_mode;
        settings.output_custom_name = saved_custom;
        cleanup_exec_test_dir (dir);
    }
}


// Folder-mode fixtures contain text bytes and fake helpers only. They must not
// depend on the user's external media directory or any installed preferences.
private void cleanup_bulk_fixture_tree (string path) {
    if (FileUtils.test (path, FileTest.IS_SYMLINK)
            || !FileUtils.test (path, FileTest.IS_DIR)) {
        FileUtils.unlink (path);
        return;
    }
    try {
        var directory = Dir.open (path);
        string? name;
        while ((name = directory.read_name ()) != null)
            cleanup_bulk_fixture_tree (Path.build_filename (path, name));
    } catch (FileError e) {
        // Best-effort cleanup is confined to the directory created by this test.
    }
    DirUtils.remove (path);
}

private class BulkScanCapture : Object {
    public bool done = false;
    public GenericArray<BulkItem>? result = null;
    public Error? error = null;

    public void start (string folder, string output, Cancellable? token = null) {
        done = false;
        result = null;
        error = null;
        BulkConversionController.scan_folder.begin (folder, output, token, (obj, res) => {
            try {
                result = BulkConversionController.scan_folder.end (res);
            } catch (Error e) {
                error = e;
            }
            done = true;
        });
    }

    public bool wait (int timeout_ms = 3000) {
        MainContext context = MainContext.default ();
        int64 deadline = get_monotonic_time () + timeout_ms * TimeSpan.MILLISECOND;
        while (!done && get_monotonic_time () < deadline) {
            while (context.pending ()) context.iteration (false);
            Thread.usleep (1000);
        }
        return done;
    }
}

private void test_bulk_scan_sorts_top_level_videos_and_deduplicates_aliases () {
    string dir = prepared_fixture_dir ();
    if (dir.length == 0) return;
    try {
        string first = Path.build_filename (dir, "a.mkv");
        string last = Path.build_filename (dir, "z.MP4");
        string nested = Path.build_filename (dir, "nested");
        string output = Path.build_filename (dir, "rendered.mp4");
        assert_true (DirUtils.create (nested, 0700) == 0 && DirUtils.create (output, 0700) == 0,
            "scanner test creates its own nested and output directories");
        if (!write_prepared_test_file (last, "last synthetic video")
                || !write_prepared_test_file (first, "first synthetic video")
                || !write_prepared_test_file (Path.build_filename (dir, "ignore.txt"), "not a video candidate")
                || !write_prepared_test_file (Path.build_filename (nested, "nested.mkv"), "nested video")
                || !write_prepared_test_file (Path.build_filename (output, "old-output.mkv"), "existing output")) return;
        assert_true (Posix.link (first, Path.build_filename (dir, "m-hardlink.mkv")) == 0,
            "scanner test creates a regular hardlink alias");
        assert_true (Posix.symlink (first, Path.build_filename (dir, "n-symlink.mkv")) == 0,
            "scanner test creates a regular-file symbolic alias");
        assert_true (Posix.symlink (Path.build_filename (output, "old-output.mkv"),
                Path.build_filename (dir, "p-output-alias.mkv")) == 0,
            "scanner test creates a candidate alias into the excluded output directory");
        assert_true (Posix.symlink (Path.build_filename (dir, "missing.mkv"),
                Path.build_filename (dir, "dangling.mkv")) == 0,
            "scanner test creates a dangling alias");
        var capture = new BulkScanCapture ();
        capture.start (dir, output);
        assert_true (capture.wait (), "folder scanner completes asynchronously");
        assert_true (capture.error == null && capture.result != null, "folder scanner returns candidates without error");
        if (capture.result == null) return;
        assert_true (capture.result.length == 2,
            "only top-level regular videos survive extension, directory and identity filtering");
        if (capture.result.length != 2) return;
        assert_string_equal (capture.result[0].path, first,
            "sorted-first path wins when symbolic and hardlink aliases identify the same source");
        assert_string_equal (capture.result[1].path, last,
            "candidate order is stable and accepts an uppercase video extension");
        assert_string_equal (read_prepared_test_file (Path.build_filename (output, "old-output.mkv")),
            "existing output", "scanning preserves the excluded output directory's contents");
    } finally {
        cleanup_bulk_fixture_tree (dir);
    }
}

private void test_bulk_scan_precancel_does_not_return_partial_queue () {
    string dir = prepared_fixture_dir ();
    if (dir.length == 0) return;
    try {
        if (!write_prepared_test_file (Path.build_filename (dir, "source.mkv"), "synthetic")) return;
        var token = new Cancellable ();
        token.cancel ();
        var capture = new BulkScanCapture ();
        capture.start (dir, Path.build_filename (dir, "output"), token);
        assert_true (capture.wait (), "pre-cancelled folder scan completes promptly");
        assert_true (capture.error is IOError.CANCELLED && capture.result == null,
            "pre-cancelled scan reports cancellation rather than an executable partial queue");
    } finally {
        cleanup_bulk_fixture_tree (dir);
    }
}

private void test_bulk_publish_preserves_late_collisions_and_protected_source_aliases () {
    string dir = prepared_fixture_dir ();
    if (dir.length == 0) return;
    try {
        string source = Path.build_filename (dir, "source.mkv");
        string stage_directory = BulkConversionController.create_staging_directory (dir);
        string other_stage_directory = BulkConversionController.create_staging_directory (dir);
        Posix.Stat stage_info;
        assert_true (stage_directory != other_stage_directory,
            "each bulk staging directory has an exclusively allocated unique path");
        assert_true (Posix.stat (stage_directory, out stage_info) == 0
                && (stage_info.st_mode & 0777) == 0700,
            "bulk staging directory is private to its owner");
        string stage = Path.build_filename (stage_directory, "staged-result.mkv");
        string desired = Path.build_filename (dir, "planned-output.mkv");
        if (!write_prepared_test_file (source, "source sentinel")
                || !write_prepared_test_file (stage, "completed conversion")
                || !write_prepared_test_file (desired, "late collision sentinel")) return;
        var protected_inputs = new GenericArray<BulkItem> ();
        protected_inputs.add (new BulkItem (source));
        string published = BulkConversionController.publish_staged_file (stage, desired, protected_inputs);
        assert_true (published != desired && FileUtils.test (published, FileTest.IS_REGULAR),
            "a destination created after planning gets a unique published name");
        assert_string_equal (read_prepared_test_file (desired), "late collision sentinel",
            "atomic publication never replaces an existing destination");
        assert_string_equal (read_prepared_test_file (published), "completed conversion",
            "the complete staged file is published under the alternate name");
        assert_false (FileUtils.test (stage, FileTest.EXISTS), "successful publication consumes its stage link");

        string alias_destination = Path.build_filename (dir, "source-hardlink.mkv");
        assert_true (Posix.link (source, alias_destination) == 0, "publish fixture creates a protected source alias");
        if (!write_prepared_test_file (stage, "second completed conversion")) return;
        string second = BulkConversionController.publish_staged_file (stage, alias_destination, protected_inputs);
        assert_true (second != alias_destination, "a hardlink to a queued source is also a protected collision");
        assert_string_equal (read_prepared_test_file (source), "source sentinel", "publication preserves original source bytes");
        assert_string_equal (read_prepared_test_file (alias_destination), "source sentinel", "publication preserves source alias bytes");

        string unsafe_stage = Path.build_filename (dir, "unsafe-source-stage.mkv");
        assert_true (Posix.link (source, unsafe_stage) == 0, "publish fixture creates an unsafe source-backed stage");
        bool rejected = false;
        try {
            BulkConversionController.publish_staged_file (unsafe_stage,
                Path.build_filename (dir, "must-not-publish.mkv"), protected_inputs);
        } catch (Error e) {
            rejected = true;
        }
        assert_true (rejected, "a stage whose identity aliases a queued source is rejected");
        assert_true (FileUtils.test (unsafe_stage, FileTest.IS_REGULAR), "rejected publication retains the caller's stage");
        assert_false (FileUtils.test (Path.build_filename (dir, "must-not-publish.mkv"), FileTest.EXISTS),
            "source-backed stage never becomes a converted output");
        assert_string_equal (read_prepared_test_file (source), "source sentinel", "rejected publication leaves source unchanged");
    } catch (Error e) {
        Test.fail_printf ("bulk atomic publication failed: %s", e.message);
    } finally {
        cleanup_bulk_fixture_tree (dir);
    }
}

private void test_bulk_settings_copy_owns_every_per_job_input () {
    var settings = new BulkConversionSettings ();
    settings.codec = "vp9";
    settings.codec_settings.container = ContainerExt.WEBM;
    settings.codec_settings.audio_settings.all_sources = { new AudioSourceInfo () };
    settings.codec_settings.audio_settings.all_sources[0].codec_name = "opus";
    settings.general_settings.crop_enabled = true;
    settings.general_settings.crop_value = "320:180:4:6";
    settings.general_settings.video_filters.processing_filters = { "hqdn3d=1:1:3:3" };
    settings.timing.seek_enabled = true;
    settings.timing.seek_minutes = 1.0;
    settings.timing.time_enabled = true;
    settings.timing.time_seconds = 7.0;
    settings.runtime_options.ffmpeg_path = "/synthetic/captured-ffmpeg";
    settings.runtime_options.ffprobe_path = "/synthetic/captured-ffprobe";
    settings.runtime_options.overwrite_enabled = true;
    settings.naming.mode = OutputNameMode.CUSTOM;
    settings.naming.custom_name = "captured-name";
    settings.target_mb = 17;
    settings.match_source_size = true;
    settings.quality_mode = true;
    settings.quality_intent = SmartOptimizerLogic.QualityIntent.HIGH;
    settings.content_override = ContentOverride.ANIME;
    settings.optimize_for_delivery = true;
    settings.strip_audio = true;
    var captured = settings.copy ();
    settings.codec = "x264";
    settings.codec_settings.container = ContainerExt.MP4;
    settings.codec_settings.audio_settings.all_sources[0].codec_name = "aac";
    settings.general_settings.crop_value = "640:360:0:0";
    settings.general_settings.video_filters.processing_filters[0] = "negate";
    settings.timing.seek_minutes = 2.0;
    settings.timing.time_seconds = 9.0;
    settings.runtime_options.ffmpeg_path = "/synthetic/mutated-ffmpeg";
    settings.runtime_options.ffprobe_path = "/synthetic/mutated-ffprobe";
    settings.naming.custom_name = "mutated-name";
    settings.target_mb = 1;
    settings.match_source_size = false;
    settings.quality_mode = false;
    settings.optimize_for_delivery = false;
    settings.strip_audio = false;
    assert_true (captured.codec == "vp9" && captured.codec_settings.container == ContainerExt.WEBM,
        "bulk copy freezes selected codec and requested container");
    assert_string_equal (captured.codec_settings.audio_settings.all_sources[0].codec_name, "opus",
        "bulk copy owns nested audio-source observations");
    assert_true (captured.general_settings.crop_enabled && captured.general_settings.crop_value == "320:180:4:6"
            && captured.general_settings.video_filters.processing_filters[0] == "hqdn3d=1:1:3:3",
        "bulk copy owns General values and nested filter arrays");
    assert_true (captured.timing.seek_enabled && captured.timing.seek_minutes == 1.0
            && captured.timing.time_enabled && captured.timing.time_seconds == 7.0,
        "bulk copy freezes each file's timing request");
    assert_true (captured.runtime_options.ffmpeg_path == "/synthetic/captured-ffmpeg"
            && captured.runtime_options.ffprobe_path == "/synthetic/captured-ffprobe"
            && captured.runtime_options.overwrite_enabled,
        "bulk copy independently owns runtime tool and output preferences");
    assert_true (captured.naming.mode == OutputNameMode.CUSTOM && captured.naming.custom_name == "captured-name",
        "bulk copy independently owns captured naming settings");
    assert_true (captured.target_mb == 17 && captured.match_source_size && captured.quality_mode
            && captured.quality_intent == SmartOptimizerLogic.QualityIntent.HIGH
            && captured.content_override == ContentOverride.ANIME && captured.optimize_for_delivery && captured.strip_audio,
        "bulk copy retains every optimizer intent, source-size and audio policy");
}

private void test_bulk_saved_settings_merge_preserves_per_file_choices () {
    var baseline = new BulkConversionSettings ();
    baseline.codec = "x264";
    baseline.builder_settings = new X264BuilderSnapshot ();
    baseline.general_settings.preserve_metadata = true;
    var current = baseline.copy ();
    ((X264BuilderSnapshot) current.builder_settings).crf = 31;
    current.general_settings.scale_mode = ScaleMode.PERCENTAGE;
    current.general_settings.scale_width_multiplier = 0.5;
    current.general_settings.scale_height_multiplier = 0.5;
    var rec = make_smart_codec_case_recommendation (1);
    SmartCodecResolution? first = SmartCodecResolver.resolve (rec, baseline.codec_settings, baseline.general_settings);
    rec.preset = "fast";
    rec.keyint_frames = 81;
    SmartCodecResolution? second = SmartCodecResolver.resolve (rec, baseline.codec_settings, baseline.general_settings);
    assert_true (first != null && second != null, "prepare independent optimized settings");
    if (first == null || second == null) return;
    var a = BulkSettingsEdits.apply (first, baseline, current);
    var b = BulkSettingsEdits.apply (second, baseline, current);
    assert_true (((X264BuilderSnapshot) a.builder_settings).crf == 31
            && ((X264BuilderSnapshot) b.builder_settings).crf == 31,
        "manual CRF edit overrides both prepared profiles");
    assert_array_has_adjacent_pair (a.to_profile ().codec_args, "-crf", "31",
        "editing CRF uses the visible manual rate-control choice instead of retained ABR");
    assert_false (a.two_pass, "manual rate-control edit also honors the visible two-pass setting");
    assert_string_equal (((X264BuilderSnapshot) a.builder_settings).preset, "slow", "first file keeps its optimized preset");
    assert_string_equal (((X264BuilderSnapshot) b.builder_settings).preset, "fast", "second file keeps its optimized preset");
    assert_string_equal (b.codec_settings.keyframe_settings.keyint_text, "81", "unrelated per-file keyframes survive edits");
    assert_true (!a.general_settings.preserve_metadata && a.general_settings.scale_width_multiplier == 0.5,
        "optimizer metadata decision survives an unrelated General edit");
    assert_true (BulkSettingsEdits.changed (baseline, current), "edits invalidate old estimates");
    var optimizer_only = baseline.copy ();
    optimizer_only.target_mb = 78;
    optimizer_only.quality_mode = true;
    assert_false (BulkSettingsEdits.changed (baseline, optimizer_only), "optimizer control changes do not change prepared encoder settings");
    a.codec_settings.audio_settings.bitrate_kbps = 12;
    a.general_settings.video_filters.processing_filters = { "changed" };
    assert_true (first.codec_settings.audio_settings.bitrate_kbps != 12
            && first.general_settings.video_filters.processing_filters.length == 0,
        "edited profiles own their mutable nested data");
    var returned = baseline.copy ();
    BulkSettingsEdits.record_changes (baseline, current, returned.edited_fields);
    var restored = BulkSettingsEdits.apply (first, baseline, returned);
    assert_true (((X264BuilderSnapshot) restored.builder_settings).crf == 23,
        "returning a user-edited CRF to its original control value overrides optimization too");
    current = baseline.copy ();
    current.codec_settings.audio_processing.fade_in_enabled = true;
    assert_true (BulkSettingsEdits.changed (baseline, current), "audio processing edits clear optimizer estimates");
}

private void run_bulk_manual_codec_case (int index, bool two_pass = false) {
    if (!ensure_gtk_widget_tests_available ()) return;
    string? ffmpeg = Environment.find_program_in_path ("ffmpeg");
    string? ffprobe = Environment.find_program_in_path ("ffprobe");
    if (ffmpeg == null || ffprobe == null) { Test.skip ("FFmpeg tools unavailable"); return; }
    string dir = prepared_fixture_dir ();
    if (dir.length == 0) return;
    var capture = new BulkQueueCapture ();
    int runs = 0;
    try {
        string input = Path.build_filename (dir, "manual source.mkv");
        if (!make_bulk_synthetic_source (ffmpeg, input)) return;
        var settings = new BulkConversionSettings ();
        settings.codec = smart_codec_case_name (index);
        settings.two_pass = two_pass;
        settings.quality_mode = true; // Must not require libvmaf or run quality analysis.
        settings.target_mb = 0;       // Not a meaningful optimizer target.
        settings.runtime_options.ffprobe_path = ffprobe;
        settings.runtime_options.generate_collage_thumbnail = false;
        string calls = Path.build_filename (dir, "calls.txt");
        string wrapper = Path.build_filename (dir, "ffmpeg-wrapper");
        string script = "#!/bin/sh\nprintf '%s\\n' \"$*\" >> " + Shell.quote (calls)
            + "\ncase \" $* \" in *' -filters '*) exit 99;; esac\nexec " + Shell.quote (ffmpeg) + " \"$@\"\n";
        if (!write_prepared_test_file (wrapper, script)) return;
        FileUtils.chmod (wrapper, 0700);
        settings.runtime_options.ffmpeg_path = wrapper;
        if (index == 0) {
            var builder = new X264BuilderSnapshot ();
            builder.preset = "ultrafast"; builder.crf = 31;
            if (two_pass) { builder.rc_mode = RateControl.ABR; builder.abr_bitrate_kbps = 300; }
            settings.builder_settings = builder;
        } else if (index == 1) {
            var builder = new X265BuilderSnapshot ();
            builder.preset = "ultrafast"; builder.crf = 31;
            if (two_pass) { builder.rc_mode = RateControl.ABR; builder.abr_bitrate_kbps = 300; }
            settings.builder_settings = builder;
        } else if (index == 2) {
            var builder = new Vp9BuilderSnapshot ();
            builder.crf = 31;
            if (two_pass) { builder.rc_mode = RateControl.VBR; builder.vbr_bitrate_kbps = 300; }
            settings.builder_settings = builder;
        } else {
            var builder = new SvtAv1BuilderSnapshot ();
            builder.preset = 12; builder.crf = 31; builder.threads = "2";
            if (two_pass) { builder.rc_mode = RateControl.VBR; builder.vbr_bitrate_kbps = 300; }
            settings.builder_settings = builder;
        }
        settings.codec_settings.audio_settings.enabled = false;
        settings.general_settings.crop_enabled = true;
        settings.general_settings.crop_value = "160:90:0:0";
        capture.start (dir, Path.build_filename (dir, "output"), settings, true, (uint64) (980 + index), false);
        runs++;
        assert_true (capture.wait_for_callbacks (runs), "manual conversion finishes");
        assert_true (capture.analysis_dispatches == 0 && capture.conversion_dispatches == 1,
            "Convert performs no optimizer analysis");
        if (capture.controller.items.length != 1) { Test.fail (); return; }
        BulkItem item = capture.controller.items[0];
        assert_string_equal (item.state, "completed", "manual file completes: " + item.status);
        assert_true (item.recommendation == null, "manual conversion creates no recommendation");
        if (item.state != "completed") return;
        string stdout_text, stderr_text;
        assert_true (run_command_for_test ({ ffprobe, "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height", "-of", "csv=p=0", item.output_path },
            out stdout_text, out stderr_text, "check manual General crop") == 0 && stdout_text.strip () == "160,90",
            "General settings apply to manual conversion");
        assert_true (run_command_for_test ({ ffmpeg, "-v", "error", "-i", item.output_path,
            "-f", "null", "-" }, out stdout_text, out stderr_text, "decode manual output") == 0,
            "manual output fully decodes: " + stderr_text);
        string logged = read_prepared_test_file (calls);
        if (index == 0) {
            assert_true (logged.contains ("psy=0"), "disabled x264 psy uses a valid key=value parameter");
        } else if (index == 1) {
            assert_true (logged.contains ("psy-rd=0"), "disabled x265 psy uses a valid key=value parameter");
        }
        assert_true (logged.contains (two_pass ? "-b:v 300k" : "-crf 31"),
            "manual rate-control value reaches the real encoder command");
        if (two_pass)
            assert_true (logged.contains ("-pass 1") && logged.contains ("-pass 2"),
                "manual bitrate conversion executes both passes");
        assert_false (logged.contains ("-filters") || logged.contains ("libvmaf")
            || logged.contains ("smart-optimizer"), "manual conversion neither probes VMAF nor calibrates");
    } catch (Error e) {
        Test.fail_printf ("manual codec case failed: %s", e.message);
    } finally {
        capture.controller.cancel (); capture.wait_for_callbacks (runs, 15000);
        cleanup_bulk_fixture_tree (dir);
    }
}

private void test_bulk_manual_x264 () { run_bulk_manual_codec_case (0); }
private void test_bulk_manual_x265 () { run_bulk_manual_codec_case (1); }
private void test_bulk_manual_vp9 () { run_bulk_manual_codec_case (2); }
private void test_bulk_manual_svt () { run_bulk_manual_codec_case (3); }

private void test_bulk_manual_two_pass_x264 () { run_bulk_manual_codec_case (0, true); }
private void test_bulk_manual_two_pass_x265 () { run_bulk_manual_codec_case (1, true); }
private void test_bulk_manual_two_pass_vp9 () { run_bulk_manual_codec_case (2, true); }
private void test_bulk_manual_two_pass_svt () { run_bulk_manual_codec_case (3, true); }

private void test_bulk_manual_adapter_matches_single_file () {
    if (!ensure_gtk_widget_tests_available ()) return;
    BaseCodecTab[] tabs = { new X264Tab (), new X265Tab (), new Vp9Tab (), new SvtAv1Tab () };
    for (int i = 0; i < tabs.length; i++) {
        var general = new GeneralTab ();
        general.crop_check.active = true;
        general.crop_value.text = "160:90:0:0";
        var settings = new BulkConversionSettings ();
        settings.codec = smart_codec_case_name (i);
        settings.general_settings = general.snapshot_settings (tabs[i].snapshot_pixel_format_settings ());
        settings.codec_settings = tabs[i].snapshot_settings (settings.general_settings);
        settings.builder_settings = tabs[i].get_codec_builder ().snapshot_settings (settings.general_settings);
        settings.two_pass = tabs[i].get_two_pass ();
        var frozen = settings.copy ();
        var manual = new SmartCodecResolution ();
        manual.codec_name = tabs[i].get_codec_builder ().get_codec_name ();
        manual.builder_settings = frozen.builder_settings;
        manual.codec_settings = frozen.codec_settings;
        manual.general_settings = frozen.general_settings;
        EncodeProfileSnapshot ordinary = CodecUtils.snapshot_encode_profile (
            tabs[i].get_codec_builder (), tabs[i], settings.general_settings);
        assert_string_equal (serialize_smart_codec_profile (manual.to_profile (), frozen.two_pass),
            serialize_smart_codec_profile (ordinary, settings.two_pass), "manual profile matches normal single-file capture");
    }
}

private void test_bulk_partial_optimization_and_stale_sources () {
    if (!ensure_gtk_widget_tests_available ()) return;
    string? ffmpeg = Environment.find_program_in_path ("ffmpeg");
    string? ffprobe = Environment.find_program_in_path ("ffprobe");
    if (ffmpeg == null || ffprobe == null) { Test.skip ("FFmpeg tools unavailable"); return; }
    string dir = prepared_fixture_dir ();
    if (dir.length == 0) return;
    var capture = new BulkQueueCapture ();
    int runs = 0;
    bool cancel_after_ready = true;
    ulong changed = capture.controller.changed.connect (() => {
        if (cancel_after_ready && capture.controller.items.length > 0
                && capture.controller.items[0].state == "ready") {
            cancel_after_ready = false;
            capture.controller.cancel ();
        }
    });
    try {
        string input = Path.build_filename (dir, "a-first.mkv");
        string second = Path.build_filename (dir, "b-second.mkv");
        string output = Path.build_filename (dir, "output");
        if (!make_bulk_synthetic_source (ffmpeg, input)) return;
        File.new_for_path (input).copy (File.new_for_path (second), FileCopyFlags.NONE);
        var settings = new BulkConversionSettings ();
        settings.codec = "x264";
        settings.builder_settings = new X264BuilderSnapshot ();
        settings.strip_audio = true;
        settings.runtime_options.ffmpeg_path = ffmpeg;
        settings.runtime_options.ffprobe_path = ffprobe;
        settings.runtime_options.generate_collage_thumbnail = false;
        settings.target_mb = 4;
        capture.start (dir, output, settings, false, 991); runs++;
        assert_true (capture.wait_for_callbacks (runs), "interrupted analysis finishes cleanup");
        assert_true (capture.controller.items[0].state == "ready"
            && capture.controller.items[1].prepared == null, "cancelled analysis retains only completed recommendations");
        capture.start (dir, output, settings, true, 992, false); runs++;
        assert_true (capture.wait_for_callbacks (runs), "Convert after partial analysis finishes");
        assert_true (capture.analysis_dispatches == 0 && capture.conversion_dispatches == 1
            && capture.controller.items[0].state == "completed" && capture.controller.items[1].state == "failed",
            "only the prepared file converts; unfinished analysis does not fall back to manual settings");
        capture.controller.reset_queue ();
        capture.start (dir, output, settings, false, 993); runs++;
        assert_true (capture.wait_for_callbacks (runs), "fresh analysis completes");
        FileUtils.remove (input);
        if (!write_prepared_test_file (input, "source was replaced after Optimize")) return;
        capture.start (dir, output, settings, true, 994, false); runs++;
        assert_true (capture.wait_for_callbacks (runs), "changed-source conversion finishes");
        assert_true (capture.analysis_dispatches == 0 && capture.controller.items[0].state == "failed"
            && capture.controller.items[1].state == "completed", "stale source is rejected without reanalysis while valid file converts");
    } catch (Error e) {
        Test.fail_printf ("partial analysis regression: %s", e.message);
    } finally {
        capture.controller.disconnect (changed);
        capture.controller.cancel (); capture.wait_for_callbacks (runs, 15000);
        cleanup_bulk_fixture_tree (dir);
    }
}

private void test_bulk_manual_audio_and_cancel () {
    if (!ensure_gtk_widget_tests_available ()) return;
    string? ffmpeg = Environment.find_program_in_path ("ffmpeg");
    string? ffprobe = Environment.find_program_in_path ("ffprobe");
    if (ffmpeg == null || ffprobe == null) { Test.skip ("FFmpeg tools unavailable"); return; }
    string dir = prepared_fixture_dir ();
    if (dir.length == 0) return;
    var capture = new BulkQueueCapture ();
    int runs = 0;
    try {
        string input = Path.build_filename (dir, "a-audio.mkv");
        string silent = Path.build_filename (dir, "b-silent.mkv");
        string output = Path.build_filename (dir, "output");
        string stdout_text, stderr_text;
        int generated = run_command_for_test ({ ffmpeg, "-v", "error", "-f", "lavfi", "-i",
            "testsrc2=size=160x90:rate=12:duration=1", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
            "-f", "lavfi", "-i", "sine=frequency=880:duration=1", "-map", "0:v", "-map", "1:a", "-map", "2:a",
            "-c:v", "ffv1", "-c:a", "flac", input }, out stdout_text, out stderr_text, "create two-track audio fixture");
        assert_true (generated == 0, "audio fixture generated: " + stderr_text);
        if (generated != 0 || !make_bulk_synthetic_source (ffmpeg, silent)) return;
        var settings = new BulkConversionSettings ();
        settings.codec = "x264";
        var builder = new X264BuilderSnapshot (); builder.preset = "ultrafast";
        settings.builder_settings = builder;
        settings.codec_settings.container = ContainerExt.MP4;
        settings.codec_settings.audio_settings.codec = AudioCodecName.COPY;
        settings.codec_settings.audio_settings.preserve_all_audio_tracks = true;
        settings.codec_settings.audio_processing.fade_in_enabled = true;
        settings.codec_settings.audio_processing.channel_downmix = 1;
        settings.runtime_options.ffmpeg_path = ffmpeg;
        settings.runtime_options.ffprobe_path = ffprobe;
        settings.runtime_options.generate_collage_thumbnail = false;
        capture.start (dir, output, settings, true, 995, false); runs++;
        assert_true (capture.wait_for_callbacks (runs), "mixed-audio manual queue finishes");
        for (int i = 0; i < capture.controller.items.length; i++) {
            BulkItem item = capture.controller.items[i];
            assert_string_equal (item.state, "completed", "mixed-audio file completes: " + item.status);
            if (item.state != "completed") continue;
            int code = run_command_for_test ({ ffprobe, "-v", "error", "-select_streams", "a",
                "-show_entries", "stream=codec_name", "-of", "csv=p=0", item.output_path },
                out stdout_text, out stderr_text, "check manual audio streams");
            assert_true (code == 0 && stdout_text.strip () == (i == 0 ? "aac\naac" : ""),
                "per-file probing preserves both processed tracks and silent input stays silent");
            assert_true (run_command_for_test ({ ffmpeg, "-v", "error", "-i", item.output_path,
                "-f", "null", "-" }, out stdout_text, out stderr_text, "decode processed manual audio") == 0,
                "audio/video output fully decodes: " + stderr_text);
        }
        capture.controller.reset_queue ();
        capture.cancel_first_conversion = true;
        capture.start (dir, output, settings, true, 996, false); runs++;
        assert_true (capture.wait_for_callbacks (runs), "manual cancel waits for cleanup");
        assert_true (capture.analysis_dispatches == 0 && capture.conversion_dispatches == 1
            && capture.controller.items[0].state == "cancelled" && capture.controller.items[1].state == "pending",
            "manual cancel prevents the next file from starting");
    } catch (Error e) {
        Test.fail_printf ("manual audio regression: %s", e.message);
    } finally {
        capture.controller.cancel (); capture.wait_for_callbacks (runs, 15000);
        cleanup_bulk_fixture_tree (dir);
    }
}

private class BulkQueueCapture : Object {
    public BulkConversionController controller;
    public int callbacks = 0;
    public int finished_signals = 0;
    public uint64 last_finished_id = 0;
    public int output_signals = 0;
    public int published_count = 0;
    public bool finished_after_release = true;
    public bool overlapping_items = false;
    public bool out_of_order = false;
    public int analysis_dispatches = 0;
    public int conversion_dispatches = 0;
    public bool cancel_first_conversion = false;
    public bool expect_conversion = false;
    private HashTable<string, bool> analyzed = new HashTable<string, bool> (str_hash, str_equal);
    private HashTable<string, bool> converted = new HashTable<string, bool> (str_hash, str_equal);

    public BulkQueueCapture () {
        controller = new BulkConversionController (new StatusArea (), new ConsoleTab (), new GeneralTab ());
        controller.changed.connect (on_changed);
        controller.finished.connect ((id) => {
            finished_signals++;
            last_finished_id = id;
            finished_after_release = finished_after_release && !controller.is_running;
        });
        controller.output_ready.connect ((result) => {
            output_signals++;
            published_count += result.output_paths.length;
        });
    }

    private void on_changed () {
        int active = 0;
        bool request_stop = false;
        for (int i = 0; i < controller.items.length; i++) {
            BulkItem item = controller.items[i];
            if (item.state == "analyzing" || item.state == "converting") {
                active++;
                if (i > 0) {
                    string previous = controller.items[i - 1].state;
                    if (previous != (expect_conversion ? "completed" : "ready"))
                        out_of_order = true;
                }
            }
            if (item.state == "analyzing" && !analyzed.contains (item.path)) {
                analyzed.insert (item.path, true);
                analysis_dispatches++;
            }
            if (item.state == "converting" && !converted.contains (item.path)) {
                converted.insert (item.path, true);
                conversion_dispatches++;
                if (cancel_first_conversion && conversion_dispatches == 1)
                    request_stop = true;
            }
        }
        overlapping_items = overlapping_items || active > 1;
        if (request_stop)
            controller.cancel ();
    }

    public void start (string folder, string output, BulkConversionSettings settings,
                       bool convert, uint64 operation_id, bool optimize = true) {
        analyzed.remove_all ();
        converted.remove_all ();
        analysis_dispatches = 0;
        conversion_dispatches = 0;
        expect_conversion = convert;
        controller.run.begin (folder, output, settings, convert, operation_id, optimize, (obj, res) => {
            controller.run.end (res);
            callbacks++;
        });
    }

    public bool wait_for_callbacks (int expected, int timeout_ms = 90000) {
        MainContext context = MainContext.default ();
        int64 deadline = get_monotonic_time () + timeout_ms * TimeSpan.MILLISECOND;
        while (get_monotonic_time () < deadline) {
            while (context.pending ()) context.iteration (false);
            if (callbacks >= expected) return true;
            Thread.usleep (1000);
        }
        return callbacks >= expected;
    }
}

private void test_bulk_queue_analyzes_converts_and_stops_sequentially () {
    if (!ensure_gtk_widget_tests_available ()) return;
    string? ffmpeg = Environment.find_program_in_path ("ffmpeg");
    string? ffprobe = Environment.find_program_in_path ("ffprobe");
    if (ffmpeg == null || ffprobe == null) {
        Test.skip ("FFmpeg and FFprobe are required for the synthetic queue integration");
        return;
    }
    string dir = prepared_fixture_dir ();
    if (dir.length == 0) return;
    var capture = new BulkQueueCapture ();
    int requested_runs = 0;
    try {
        string first = Path.build_filename (dir, "a-synthetic.mkv");
        string second = Path.build_filename (dir, "b-synthetic.mkv");
        string output = Path.build_filename (dir, "output");
        assert_true (DirUtils.create (output, 0700) == 0, "synthetic queue creates an external-to-source output child");
        string stdout_text, stderr_text;
        string[] generate = { ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin",
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24:duration=2",
            "-c:v", "libx264", "-preset", "ultrafast", "-crf", "28",
            "-pix_fmt", "yuv420p", "-an", first };
        int generated = run_command_for_test (generate, out stdout_text, out stderr_text,
            "generate two-second synthetic bulk source");
        assert_true (generated == 0, "real FFmpeg generates the synthetic queue source: " + stderr_text);
        if (generated != 0) return;
        File.new_for_path (first).copy (File.new_for_path (second), FileCopyFlags.NONE);
        var settings = new BulkConversionSettings ();
        settings.codec = "x264";
        settings.codec_settings.container = ContainerExt.MKV;
        settings.runtime_options.ffmpeg_path = ffmpeg;
        settings.runtime_options.ffprobe_path = ffprobe;
        settings.runtime_options.generate_collage_thumbnail = false;
        settings.target_mb = 4;
        settings.strip_audio = true;
        settings.naming.mode = OutputNameMode.CUSTOM;
        settings.naming.custom_name = "shared-result";
        settings.general_settings.crop_enabled = true;
        settings.general_settings.crop_value = "160:90:0:0";
        settings.timing.seek_enabled = true;
        settings.timing.seek_seconds = 0.5;
        settings.timing.time_enabled = true;
        settings.timing.time_seconds = 1.0;
        capture.start (dir, output, settings, false, 801);
        requested_runs++;
        assert_true (capture.wait_for_callbacks (requested_runs), "real synthetic analysis-only queue finishes");
        assert_true (capture.controller.items.length == 2 && capture.analysis_dispatches == 2
                && capture.conversion_dispatches == 0, "analysis processes both candidates without encoding outputs");
        if (capture.controller.items.length != 2) return;
        string desired = capture.controller.items[0].output_path;
        for (int i = 0; i < capture.controller.items.length; i++) {
            BulkItem item = capture.controller.items[i];
            assert_string_equal (item.state, "ready", "analysis-only item remains ready for review: " + item.status);
            assert_true (item.recommendation != null, "analysis-only item retains the full Smart Optimizer recommendation");
            assert_false (FileUtils.test (item.output_path, FileTest.EXISTS), "analysis-only item does not create its planned output");
        }
        assert_true (capture.output_signals == 0, "analysis-only queue publishes no output result");
        assert_true (desired.length > 0, "analysis resolves a concrete captured output name");
        if (desired.length == 0) return;
        if (!write_prepared_test_file (desired, "pre-existing output sentinel")) return;
        capture.start (dir, output, settings, true, 802, false);
        requested_runs++;
        assert_true (capture.wait_for_callbacks (requested_runs), "real sequential synthetic conversion queue finishes");
        assert_true (capture.analysis_dispatches == 0 && capture.conversion_dispatches == 2,
            "Convert uses retained per-file settings without analyzing again");
        assert_false (capture.overlapping_items || capture.out_of_order,
            "each item finishes analysis and conversion before the next item starts");
        assert_true (capture.output_signals == 1 && capture.published_count == 2,
            "one aggregate output result contains both published conversions");
        assert_string_equal (read_prepared_test_file (desired), "pre-existing output sentinel",
            "queue publication preserves a destination that existed before conversion");
        string previous_output = "";
        for (int i = 0; i < capture.controller.items.length; i++) {
            BulkItem item = capture.controller.items[i];
            assert_string_equal (item.state, "completed", "synthetic queue item completes: " + item.status);
            assert_true (item.output_path != desired && item.output_path != previous_output,
                "colliding custom names become distinct published outputs");
            previous_output = item.output_path;
            string reason;
            bool usable = FfprobeUtils.output_file_is_usable (item.output_path, out reason, null, ffprobe);
            assert_true (usable, "published queue output is a real usable video: " + reason);
            string[] probe = { ffprobe, "-v", "error", "-select_streams", "v:0", "-show_entries",
                "stream=width,height", "-of", "csv=p=0", item.output_path };
            assert_true (run_command_for_test (probe, out stdout_text, out stderr_text,
                    "inspect synthetic bulk output crop") == 0 && stdout_text.strip () == "160,90",
                "captured General crop is applied independently to each queue output");
            double duration = FfprobeUtils.probe_duration (item.output_path, null, ffprobe);
            assert_true (duration >= 0.9 && duration <= 1.1, "captured General seek and duration apply to each output");
        }
        BulkItem retained_first = capture.controller.items[0];
        string retained_output = retained_first.output_path;
        capture.start (dir, output, settings, true, 803);
        requested_runs++;
        assert_true (capture.wait_for_callbacks (requested_runs), "second Convert on the same finite queue finishes");
        assert_true (capture.analysis_dispatches == 0 && capture.conversion_dispatches == 0,
            "second Convert skips already completed items without optimization or encoding");
        assert_true (capture.controller.items[0] == retained_first
                && capture.controller.items[0].output_path == retained_output,
            "second Convert retains completed item identities and their published paths");
        assert_true (capture.output_signals == 1 && capture.published_count == 2,
            "second Convert publishes no duplicate output results");
        capture.controller.reset_queue ();
        assert_true (capture.controller.items.length == 0, "explicit idle reset forgets the previous completed finite queue");
        capture.cancel_first_conversion = true;
        capture.start (dir, output, settings, true, 804);
        requested_runs++;
        assert_true (capture.wait_for_callbacks (requested_runs), "stopped synthetic queue waits for terminal cleanup");
        assert_true (capture.analysis_dispatches == 1 && capture.conversion_dispatches == 1,
            "stop during the first converting transition prevents dispatch of the second source");
        assert_true (capture.controller.items[0].state == "cancelled"
                && capture.controller.items[1].state == "pending"
                && capture.controller.items[1].status.down ().contains ("cancelled"),
            "active row is cancelled while the unstarted row stays queued with a cancellation explanation");
        assert_true (capture.output_signals == 1 && capture.published_count == 2,
            "cancelled queue publishes no extra outputs and retains earlier completed results");
        assert_true (capture.finished_signals == 4 && capture.last_finished_id == 804
                && capture.finished_after_release && !capture.controller.is_running,
            "each invocation finishes exactly once after releasing queue ownership");
        assert_true (FfprobeUtils.has_video_stream (first, null, ffprobe)
                && FfprobeUtils.has_video_stream (second, null, ffprobe), "all synthetic source files remain usable after queue stop");
    } catch (Error e) {
        Test.fail_printf ("synthetic bulk integration failed: %s", e.message);
    } finally {
        capture.controller.cancel ();
        capture.wait_for_callbacks (requested_runs, 15000);
        cleanup_bulk_fixture_tree (dir);
    }
}

private bool make_bulk_synthetic_source (string ffmpeg, string path) {
    string stdout_text, stderr_text;
    string[] generate = { ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin",
        "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=12:duration=1",
        "-c:v", "ffv1", "-pix_fmt", "yuv420p", "-an", path };
    int result = run_command_for_test (generate, out stdout_text, out stderr_text,
        "generate small synthetic bulk source");
    assert_true (result == 0, "synthetic source generation succeeds: " + stderr_text);
    return result == 0;
}

private void run_bulk_real_codec_case (int codec_index, bool quality_mode) {
    if (!ensure_gtk_widget_tests_available ()) return;
    string? ffmpeg = Environment.find_program_in_path ("ffmpeg");
    string? ffprobe = Environment.find_program_in_path ("ffprobe");
    if (ffmpeg == null || ffprobe == null) {
        Test.skip ("FFmpeg and FFprobe are required for synthetic codec integration");
        return;
    }
    string[] encoders = { "libx264", "libx265", "libvpx-vp9", "libsvtav1" };
    string[] expected_codecs = { "h264", "hevc", "vp9", "av1" };
    string encoder = encoders[codec_index];
    string stdout_text, stderr_text;
    if (run_command_for_test ({ ffmpeg, "-hide_banner", "-encoders" }, out stdout_text, out stderr_text,
            "inspect available FFmpeg encoders") != 0 || !stdout_text.contains (" " + encoder + " ")) {
        Test.skip ("FFmpeg does not expose the " + encoder + " encoder");
        return;
    }
    if (quality_mode) {
        int filter_result = run_command_for_test ({ ffmpeg, "-hide_banner", "-filters" },
            out stdout_text, out stderr_text, "inspect available quality measurement filters");
        if (filter_result != 0 || !FfmpegRuntimeCapabilities.filter_listing_has_libvmaf (stdout_text)) {
            Test.skip ("FFmpeg does not expose libvmaf for measured quality-mode integration");
            return;
        }
    }
    string dir = prepared_fixture_dir ();
    if (dir.length == 0) return;
    var capture = new BulkQueueCapture ();
    int requested_runs = 0;
    try {
        string input = Path.build_filename (dir, "synthetic-source.mkv");
        string output = Path.build_filename (dir, "output");
        if (!make_bulk_synthetic_source (ffmpeg, input)) return;
        var settings = new BulkConversionSettings ();
        settings.codec = smart_codec_case_name (codec_index);
        settings.codec_settings.container = codec_index >= 2 ? ContainerExt.WEBM : ContainerExt.MKV;
        settings.runtime_options.ffmpeg_path = ffmpeg;
        settings.runtime_options.ffprobe_path = ffprobe;
        settings.runtime_options.generate_collage_thumbnail = false;
        settings.target_mb = 4;
        settings.strip_audio = true;
        settings.quality_mode = quality_mode;
        settings.quality_intent = SmartOptimizerLogic.QualityIntent.HIGH;
        if (!quality_mode && codec_index == 0) {
            // Height 240 is valid only after 320x180 has rotated to 180x320.
            // Checking the original dimensions would reject this valid crop.
            settings.general_settings.rotate = Rotation.CW_90;
            settings.general_settings.crop_enabled = true;
            settings.general_settings.crop_value = "160:240:0:0";
        }
        capture.start (dir, output, settings, true, (uint64) (850 + codec_index + (quality_mode ? 10 : 0)));
        requested_runs++;
        assert_true (capture.wait_for_callbacks (requested_runs), "synthetic codec queue reaches terminal cleanup");
        assert_true (capture.controller.items.length == 1, "synthetic codec queue contains one source");
        if (capture.controller.items.length != 1) return;
        BulkItem item = capture.controller.items[0];
        assert_string_equal (item.state, "completed", settings.codec + " synthetic conversion completes: " + item.status);
        assert_true (capture.analysis_dispatches == 1 && capture.conversion_dispatches == 1
                && capture.output_signals == 1 && capture.published_count == 1,
            "synthetic codec item is analyzed, encoded and published exactly once");
        assert_true (item.recommendation != null, "published item retains its complete optimizer recommendation");
        if (item.recommendation != null) {
            assert_true (item.recommendation.pinned_axis == (quality_mode ? PinnedAxis.QUALITY : PinnedAxis.SIZE),
                "the selected size or measured quality axis reaches the per-file optimizer");
        }
        string reason;
        bool usable = FfprobeUtils.output_file_is_usable (item.output_path, out reason, null, ffprobe);
        assert_true (usable, "synthetic codec output is usable: " + reason);
        int codec_result = run_command_for_test ({ ffprobe, "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=codec_name", "-of", "default=noprint_wrappers=1:nokey=1", item.output_path },
            out stdout_text, out stderr_text, "inspect published synthetic codec");
        assert_true (codec_result == 0 && stdout_text.strip () == expected_codecs[codec_index],
            "published synthetic video uses the selected " + expected_codecs[codec_index] + " codec");
        if (!quality_mode && codec_index == 0) {
            int crop_result = run_command_for_test ({ ffprobe, "-v", "error", "-select_streams", "v:0",
                "-show_entries", "stream=width,height", "-of", "csv=p=0", item.output_path },
                out stdout_text, out stderr_text, "inspect rotated nonsquare crop");
            assert_true (crop_result == 0 && stdout_text.strip () == "160,240",
                "crop validation uses dimensions after the General 90-degree rotation");
            capture.controller.reset_queue ();
            settings.general_settings.crop_value = "240:160:0:0";
            capture.start (dir, output, settings, false, 875);
            requested_runs++;
            assert_true (capture.wait_for_callbacks (requested_runs), "invalid post-rotation crop is rejected promptly");
            assert_true (capture.controller.items[0].state == "failed"
                    && capture.controller.items[0].status.contains ("outside"),
                "a crop fitting only the unrotated source fails before optimization or conversion");
            assert_true (capture.conversion_dispatches == 0, "invalid rotated crop launches no prepared conversion");
        }
    } finally {
        capture.controller.cancel ();
        capture.wait_for_callbacks (requested_runs, 15000);
        cleanup_bulk_fixture_tree (dir);
    }
}

private void test_bulk_size_x264 () { run_bulk_real_codec_case (0, false); }
private void test_bulk_size_x265 () { run_bulk_real_codec_case (1, false); }
private void test_bulk_size_vp9 () { run_bulk_real_codec_case (2, false); }
private void test_bulk_size_svt_av1 () { run_bulk_real_codec_case (3, false); }
private void test_bulk_quality_x264 () { run_bulk_real_codec_case (0, true); }
private void test_bulk_quality_x265 () { run_bulk_real_codec_case (1, true); }
private void test_bulk_quality_vp9 () { run_bulk_real_codec_case (2, true); }
private void test_bulk_quality_svt_av1 () { run_bulk_real_codec_case (3, true); }

private void test_bulk_late_collage_cancellation_keeps_verified_video () {
    if (!ensure_gtk_widget_tests_available ()) return;
    string? ffmpeg = Environment.find_program_in_path ("ffmpeg");
    string? ffprobe = Environment.find_program_in_path ("ffprobe");
    if (ffmpeg == null || ffprobe == null) {
        Test.skip ("FFmpeg and FFprobe are required for optional collage cancellation integration");
        return;
    }
    string dir = prepared_fixture_dir ();
    if (dir.length == 0) return;
    var capture = new BulkQueueCapture ();
    int requested_runs = 0;
    string release = Path.build_filename (dir, "collage.release");
    try {
        string first = Path.build_filename (dir, "a-synthetic.mkv");
        string second = Path.build_filename (dir, "b-synthetic.mkv");
        string marker = Path.build_filename (dir, "collage.started");
        string wrapper = Path.build_filename (dir, "collage-wrapper.sh");
        string output = Path.build_filename (dir, "output");
        if (!make_bulk_synthetic_source (ffmpeg, first)) return;
        File.new_for_path (first).copy (File.new_for_path (second), FileCopyFlags.NONE);
        // All real probing, calibration and encoding use FFmpeg. Only the
        // optional PNG command pauses so cancellation occurs at a known stage.
        string script = "#!/bin/sh\nfor argument in \"$@\"; do\n"
            + " case \"$argument\" in *-collage.png)\n"
            + "  : > " + Shell.quote (marker) + "\n"
            + "  trap 'exit 143' TERM INT\n"
            + "  while [ ! -f " + Shell.quote (release) + " ]; do sleep 0.02; done\n"
            + "  exit 0 ;;\n esac\ndone\nexec " + Shell.quote (ffmpeg) + " \"$@\"\n";
        if (!write_prepared_test_file (wrapper, script, true)) return;
        var settings = new BulkConversionSettings ();
        settings.codec = "x264";
        settings.codec_settings.container = ContainerExt.MKV;
        settings.runtime_options.ffmpeg_path = wrapper;
        settings.runtime_options.ffprobe_path = ffprobe;
        settings.runtime_options.generate_collage_thumbnail = true;
        settings.runtime_options.collage_size = CollageSize.HD_720;
        settings.target_mb = 4;
        settings.strip_audio = true;
        capture.start (dir, output, settings, true, 880);
        requested_runs++;
        assert_true (spin_main_context_until_deadline (() => { return FileUtils.test (marker, FileTest.EXISTS); }, 30000),
            "first item's verified video reaches the controlled optional collage helper");
        if (!FileUtils.test (marker, FileTest.EXISTS)) return;
        capture.controller.cancel ();
        assert_true (capture.wait_for_callbacks (requested_runs, 15000), "late cancellation reaps the optional helper and finishes the queue");
        assert_true (capture.analysis_dispatches == 1 && capture.conversion_dispatches == 1,
            "cancelling optional collage work prevents any second item dispatch");
        assert_true (capture.controller.items.length == 2, "late-cancel queue retains both source rows");
        if (capture.controller.items.length != 2) return;
        BulkItem completed = capture.controller.items[0];
        assert_string_equal (completed.state, "completed", "verified video remains completed after optional collage cancellation");
        assert_true (completed.status.down ().contains ("cancel"), "completed row explains that optional work was cancelled");
        assert_true (capture.controller.items[1].state == "pending", "unstarted second item stays queued after late cancellation");
        assert_true (capture.output_signals == 1 && capture.published_count == 1,
            "late cancellation still publishes the one verified main video");
        string reason;
        bool usable = FfprobeUtils.output_file_is_usable (completed.output_path, out reason, null, ffprobe);
        assert_true (usable, "kept late-cancel video is usable: " + reason);
        assert_false (FileUtils.test (ConversionUtils.build_collage_output_path (completed.output_path), FileTest.EXISTS),
            "cancelled optional collage does not claim a nonexistent PNG output");
        assert_true (capture.finished_signals == 1 && capture.last_finished_id == 880
                && capture.finished_after_release && !capture.controller.is_running,
            "late-cancel queue releases ownership and finishes exactly once");
    } catch (Error e) {
        Test.fail_printf ("late collage cancellation integration failed: %s", e.message);
    } finally {
        write_prepared_test_file (release, "release cleanup");
        capture.controller.cancel ();
        capture.wait_for_callbacks (requested_runs, 15000);
        cleanup_bulk_fixture_tree (dir);
    }
}

private void test_bulk_match_source_size_waits_for_each_file () {
    if (!ensure_gtk_widget_tests_available ()) return;
    string dir = prepared_fixture_dir ();
    if (dir.length == 0) return;
    var settings = AppSettings.get_default ();
    bool saved_match = settings.smart_optimizer_match_source_size;
    try {
        settings.smart_optimizer_match_source_size = true;
        var tab = new X264Tab ();
        string first = Path.build_filename (dir, "first.mkv");
        string second = Path.build_filename (dir, "second.mkv");
        if (!write_prepared_test_file (first, string.nfill (2 * 1024 * 1024, 'a'))
                || !write_prepared_test_file (second, string.nfill (3 * 1024 * 1024, 'b'))) return;
        tab.update_source_file_size (first);
        tab.set_folder_input_mode (true);
        tab.update_source_file_size (dir);
        int64 settle_deadline = get_monotonic_time () + 50 * TimeSpan.MILLISECOND;
        assert_true (spin_main_context_until_deadline (() => { return get_monotonic_time () >= settle_deadline; }, 1000),
            "retired file-size query has time to deliver its stale result");
        assert_true (tab.match_source_size_active && tab.get_source_file_size_bytes () == -1,
            "folder transition retires a pending size query and keeps Match Source Size selected");
        tab.set_folder_input_mode (false);
        tab.update_source_file_size (first);
        assert_true (spin_main_context_until_deadline (() => { return tab.get_source_file_size_bytes () == 2 * 1024 * 1024; }, 3000),
            "first individual source obtains its own byte count after returning from folder mode");
        assert_true (tab.match_source_size_active && tab.get_target_mb () == 2,
            "first file matches its own two-MiB source target");
        tab.set_folder_input_mode (true);
        assert_true (tab.match_source_size_active && tab.get_source_file_size_bytes () == -1,
            "folder mode clears the single-file observation while retaining the matching request");
        tab.set_folder_input_mode (false);
        tab.update_source_file_size (second);
        assert_true (spin_main_context_until_deadline (() => { return tab.get_source_file_size_bytes () == 3 * 1024 * 1024; }, 3000),
            "later individual source gets a fresh size observation");
        assert_true (tab.match_source_size_active && tab.get_target_mb () == 3,
            "later file matches its own three-MiB target rather than a prior source or folder");
    } finally {
        settings.smart_optimizer_match_source_size = saved_match;
        cleanup_bulk_fixture_tree (dir);
    }
}

private class BulkAdmissionGate : Object {
    public bool allowed = true;
    public bool permits_input () { return allowed; }
}

private bool wait_bulk_input_kind (FilePickers pickers, InputSourceKind expected, int timeout_ms = 3000) {
    MainContext context = MainContext.default ();
    int64 deadline = get_monotonic_time () + timeout_ms * TimeSpan.MILLISECOND;
    while (get_monotonic_time () < deadline) {
        while (context.pending ()) context.iteration (false);
        if (pickers.kind == expected) return true;
        Thread.usleep (1000);
    }
    return pickers.kind == expected;
}

private bool wait_bulk_detection_idle (GeneralTab general, int timeout_ms = 3000) {
    MainContext context = MainContext.default ();
    int64 deadline = get_monotonic_time () + timeout_ms * TimeSpan.MILLISECOND;
    while (get_monotonic_time () < deadline) {
        while (context.pending ()) context.iteration (false);
        if (!general.is_source_detection_active ()) return true;
        Thread.usleep (1000);
    }
    return !general.is_source_detection_active ();
}

private void test_bulk_input_classification_admission_and_general_preservation () {
    if (!ensure_gtk_widget_tests_available ()) return;
    string dir = prepared_fixture_dir ();
    if (dir.length == 0) return;
    var pickers = new FilePickers ();
    var general = new GeneralTab ();
    var gate = new BulkAdmissionGate ();
    pickers.set_input_admission (gate.permits_input);
    try {
        string first = Path.build_filename (dir, "first.mkv");
        string second = Path.build_filename (dir, "second.mp4");
        string extensionless = Path.build_filename (dir, "source-without-extension");
        string folder = Path.build_filename (dir, "folder-named-video.mp4");
        assert_true (DirUtils.create (folder, 0700) == 0, "typed-input fixture creates a directory with a video suffix");
        if (!write_prepared_test_file (first, "first synthetic source")
                || !write_prepared_test_file (second, "second synthetic source")
                || !write_prepared_test_file (extensionless, "extensionless synthetic source")) return;
        pickers.request_input (extensionless);
        assert_true (wait_bulk_input_kind (pickers, InputSourceKind.FILE),
            "an existing regular file without an extension remains a valid individual-file selection");
        assert_string_equal (pickers.source_path, extensionless, "extensionless individual source path is retained");
        general.crop_check.active = true;
        general.crop_value.text = "320:180:4:6";
        general.delogo_check.active = true;
        general.delogo_value.text = "4:6:20:24";
        general.preserve_metadata.active = true;
        general.remove_chapters.active = true;
        general.video_speed_check.active = true;
        general.video_speed.set_value (25.0);
        general.seek_check.active = true;
        general.seek_ss.set_value (3.0);
        general.time_check.active = true;
        general.time_ss.set_value (7.0);
        pickers.request_input (first);
        assert_true (wait_bulk_input_kind (pickers, InputSourceKind.FILE), "regular video input resolves to the typed file mode");
        assert_string_equal (pickers.source_path, first, "typed source retains the accepted file path");
        pickers.request_input (folder);
        assert_true (wait_bulk_input_kind (pickers, InputSourceKind.FOLDER), "filesystem directory wins over its video-like suffix");
        general.set_folder_input_mode (true);
        assert_false (general.detect_crop_button.sensitive || general.detect_logo_button.sensitive
                || general.detect_moving_logo_button.sensitive, "folder mode disables every source-specific detection button");
        var snapshot = general.snapshot_settings ();
        var timing = general.snapshot_timing_only ();
        assert_true (snapshot.crop_enabled && snapshot.crop_value == "320:180:4:6"
                && snapshot.delogo_enabled && snapshot.delogo_regions == "4:6:20:24",
            "file-to-folder transition preserves entered crop and logo-removal settings");
        assert_true (snapshot.preserve_metadata && snapshot.remove_chapters
                && snapshot.video_speed_enabled && snapshot.video_speed_percent == 25.0,
            "folder mode keeps metadata, chapters and speed settings");
        assert_true (timing.seek_enabled && timing.seek_seconds == 3.0
                && timing.time_enabled && timing.time_seconds == 7.0,
            "folder mode keeps the General timing request");
        pickers.output_entry.set_text (folder);
        pickers.set_operation_locked (true);
        pickers.request_input (second);
        pickers.input_entry.set_text (second);
        pickers.output_entry.set_text (dir);
        assert_true (pickers.kind == InputSourceKind.FOLDER, "busy admission cannot replace the typed source model");
        assert_string_equal (pickers.source_path, folder, "busy request preserves the accepted source");
        assert_string_equal (pickers.input_entry.get_text (), folder, "raw input writes are also rejected while busy");
        assert_string_equal (pickers.output_entry.get_text (), folder, "busy output writes preserve the accepted destination");
        pickers.set_operation_locked (false);
        gate.allowed = false;
        pickers.request_input (second);
        pickers.input_entry.set_text (second);
        assert_true (pickers.kind == InputSourceKind.FOLDER, "shared admission gate rejects legacy input-entry writes too");
        gate.allowed = true;
        pickers.request_input (second);
        assert_true (wait_bulk_input_kind (pickers, InputSourceKind.FILE), "unlocking allows a new individual video input");
        general.set_folder_input_mode (false);
        assert_true (general.detect_crop_button.sensitive && general.detect_logo_button.sensitive
                && general.detect_moving_logo_button.sensitive, "returning to file mode restores source detectors");
        snapshot = general.snapshot_settings ();
        assert_true (snapshot.crop_value == "320:180:4:6" && snapshot.delogo_regions == "4:6:20:24"
                && snapshot.video_speed_enabled, "folder-to-file transition preserves the same General values");

        // A superseded asynchronous classification must not put the old folder
        // back after a newer file request, or admit a result after busy starts.
        pickers.request_input (folder);
        pickers.request_input (first);
        assert_true (wait_bulk_input_kind (pickers, InputSourceKind.FILE), "newer file request retires in-flight folder classification");
        assert_string_equal (pickers.source_path, first, "stale folder result cannot replace the newer accepted file");
        pickers.request_input (folder);
        gate.allowed = false;
        assert_true (wait_bulk_input_kind (pickers, InputSourceKind.FILE), "classification rechecks operation admission before accepting");
        assert_string_equal (pickers.source_path, first, "denied in-flight result restores the last accepted typed source");
    } finally {
        pickers.set_operation_locked (false);
        gate.allowed = true;
        cleanup_bulk_fixture_tree (dir);
    }
}

private void test_bulk_folder_mode_retires_crop_worker_and_blocks_direct_detectors () {
    if (!ensure_gtk_widget_tests_available ()) return;
    string dir = prepared_fixture_dir ();
    if (dir.length == 0) return;
    var saved = ConversionRuntimeOptions.capture_current ();
    var general = new GeneralTab ();
    var console = new ConsoleTab ();
    int activity_changes = 0;
    ulong activity_id = general.source_detection_activity_changed.connect (() => { activity_changes++; });
    string release = Path.build_filename (dir, "crop.release");
    try {
        string input = Path.build_filename (dir, "synthetic-input.mkv");
        string executable = Path.build_filename (dir, "crop-ffmpeg.sh");
        string marker = Path.build_filename (dir, "crop.started");
        string script = "#!/bin/sh\n: > " + Shell.quote (marker)
            + "\nwhile [ ! -f " + Shell.quote (release) + " ]; do sleep 0.02; done\n"
            + "printf 'crop=640:360:0:0\\n'\n";
        if (!write_prepared_test_file (input, "synthetic input bytes")
                || !write_prepared_test_file (executable, script, true)) return;
        AppSettings.get_default ().ffmpeg_path = executable;
        general.start_crop_detection (input, console);
        assert_true (general.is_source_detection_active (), "crop detector registers its live worker before returning");
        assert_true (activity_changes == 1, "main-window admission gets notified when detection starts");
        assert_true (spin_main_context_until_deadline (() => { return FileUtils.test (marker, FileTest.EXISTS); }, 3000),
            "fake crop worker starts before the source mode changes");
        general.set_folder_input_mode (true);
        general.crop_check.active = true;
        general.crop_value.text = "320:180:4:6";
        general.delogo_check.active = true;
        general.delogo_value.text = "4:6:20:24";
        general.start_crop_detection (input, console);
        general.start_logo_detection (input, console);
        general.start_logo_detection (input, console, true);
        assert_true (general.is_source_detection_active (), "retired worker remains active until it actually exits");
        if (!write_prepared_test_file (release, "release")) return;
        assert_true (wait_bulk_detection_idle (general), "retired crop worker eventually releases source-detection admission");
        assert_true (activity_changes == 2, "main-window Convert sensitivity refreshes even after a stale detector completes");
        assert_string_equal (general.crop_value.text, "320:180:4:6", "stale crop completion cannot overwrite preserved folder settings");
        assert_string_equal (general.delogo_value.text, "4:6:20:24", "direct logo-detector calls are blocked in folder mode");
        assert_false (general.detect_crop_button.sensitive || general.detect_logo_button.sensitive
                || general.detect_moving_logo_button.sensitive, "stale completion cannot re-enable folder detectors");
        general.start_crop_detection (input, console);
        general.start_logo_detection (input, console);
        general.start_logo_detection (input, console, true);
        assert_false (general.is_source_detection_active (), "folder-mode direct detector calls launch no additional workers");
        general.set_folder_input_mode (false);
        assert_true (general.detect_crop_button.sensitive && general.detect_logo_button.sensitive
                && general.detect_moving_logo_button.sensitive, "file mode restores detector controls after retired work finishes");
    } finally {
        write_prepared_test_file (release, "release cleanup");
        wait_bulk_detection_idle (general);
        general.disconnect (activity_id);
        restore_prepared_runtime_preferences (saved);
        cleanup_bulk_fixture_tree (dir);
    }
}

private void test_sampled_logo_windows_match_real_ffmpeg_frames () {
    string? ffmpeg = Environment.find_program_in_path ("ffmpeg");
    if (ffmpeg == null) { Test.skip ("FFmpeg is required for sample-frame comparison"); return; }
    string dir = prepared_fixture_dir ();
    if (dir.length == 0) return;
    try {
        string source = Path.build_filename (dir, "sample-source.mkv");
        string stdout_text, stderr_text;
        int result = run_command_for_test ({ ffmpeg, "-v", "error", "-f", "lavfi", "-i",
            "testsrc2=size=64x64:rate=5:duration=4", "-c:v", "ffv1", source },
            out stdout_text, out stderr_text, "generate source for timed-logo calibration");
        assert_true (result == 0, "generated source: " + stderr_text);
        if (result != 0) return;
        var optimizer = new SmartOptimizer ();
        string actual_graph = optimizer.sampled_filter_graph_for_test (
            "delogo=x=4:y=4:w=12:h=12:enable='between(t,2,2.5)'", { 0.0, 2.0 }, 1.0);
        string expected_graph = "[0:v]null[a];[1:v]delogo=x=4:y=4:w=12:h=12:enable='between(t,0,0.5)'[b];"
            + "[a][b]concat=n=2:v=1:a=0[v]";
        string actual_frames;
        result = run_command_for_test ({ ffmpeg, "-v", "error", "-ss", "0", "-t", "1", "-i", source,
            "-ss", "2", "-t", "1", "-i", source, "-filter_complex", actual_graph,
            "-map", "[v]", "-f", "framemd5", "-" }, out actual_frames, out stderr_text,
            "measure actual sampled-logo output frames");
        assert_true (result == 0, "actual graph executes: " + stderr_text);
        result = run_command_for_test ({ ffmpeg, "-v", "error", "-ss", "0", "-t", "1", "-i", source,
            "-ss", "2", "-t", "1", "-i", source, "-filter_complex", expected_graph,
            "-map", "[v]", "-f", "framemd5", "-" }, out stdout_text, out stderr_text,
            "measure independent source-window expectation");
        assert_true (result == 0, "reference graph executes: " + stderr_text);
        assert_string_equal (actual_frames, stdout_text,
            "sampled optimizer frames match independently specified local logo windows");
    } finally { cleanup_bulk_fixture_tree (dir); }
}

private void test_sampled_logo_windows_follow_source_seek () {
    string chain = "delogo=x=4:y=4:w=12:h=12:enable='between(t,10,14)',"
        + "delogo=x=20:y=4:w=8:h=8,drawtext=text='comma,between(t,10,14)':x=1:y=1";
    var optimizer = new SmartOptimizer ();
    string graph = optimizer.sampled_filter_graph_for_test (chain, { 0.0, 9.004, 12.0, 20.0 }, 3.0);
    assert_contains (graph, "[0:v]delogo=x=20:y=4:w=8:h=8,drawtext=", "early sample omits inactive timed logo");
    assert_contains (graph, "[1:v]delogo=x=4:y=4:w=12:h=12:enable='between(t,1.000000,3.000000)'",
        "sample seek rounds identically to FFmpeg and clips window at sample end");
    assert_contains (graph, "[2:v]delogo=x=4:y=4:w=12:h=12:enable='between(t,0.000000,2.000000)'",
        "overlapping window clips at sample start");
    assert_contains (graph, "[3:v]delogo=x=20:y=4:w=8:h=8,drawtext=", "late sample omits expired timed logo");
    assert_contains (graph, "drawtext=text='comma,between(t,10,14)'", "quoted unrelated expressions are preserved");
    string only_timed = "delogo=x=4:y=4:w=12:h=12:enable='between(t,10,14)'";
    assert_contains (optimizer.sampled_filter_graph_for_test (only_timed, { 20.0 }, 3.0),
        "[0:v]null[s0]", "inactive-only sample retains valid graph connectivity");
    string[] chains = { FilterBuilder.retarget_timed_delogo_filters (only_timed, 12.0, 3.0), "" };
    string analysis = SmartOptimizerLogic.independent_analysis_filter_spec (2, only_timed, "signalstats", chains);
    assert_contains (analysis, "between(t,0.000000,2.000000)", "independent analysis uses local timing");
    assert_contains (analysis, "[1:v]signalstats[analysis1]", "inactive independent sample still measures video");
}

void main (string[] args) {
    Test.init (ref args);


    Test.add_func ("/bulk-conversion/widgets/manual/two-pass/x264", test_bulk_manual_two_pass_x264);
    Test.add_func ("/bulk-conversion/widgets/manual/two-pass/x265", test_bulk_manual_two_pass_x265);
    Test.add_func ("/bulk-conversion/widgets/manual/two-pass/vp9", test_bulk_manual_two_pass_vp9);
    Test.add_func ("/bulk-conversion/widgets/manual/two-pass/svt-av1", test_bulk_manual_two_pass_svt);
    Test.add_func ("/bulk-conversion/widgets/manual/audio-and-cancel", test_bulk_manual_audio_and_cancel);
    Test.add_func ("/bulk-conversion/widgets/partial-analysis-and-stale-source", test_bulk_partial_optimization_and_stale_sources);
    Test.add_func ("/bulk-conversion/settings/saved-edits", test_bulk_saved_settings_merge_preserves_per_file_choices);
    Test.add_func ("/bulk-conversion/widgets/manual/profile-parity", test_bulk_manual_adapter_matches_single_file);
    Test.add_func ("/bulk-conversion/widgets/manual/x264", test_bulk_manual_x264);
    Test.add_func ("/bulk-conversion/widgets/manual/x265", test_bulk_manual_x265);
    Test.add_func ("/bulk-conversion/widgets/manual/vp9", test_bulk_manual_vp9);
    Test.add_func ("/bulk-conversion/widgets/manual/svt-av1", test_bulk_manual_svt);
    Test.add_func ("/bulk-conversion/calibration/timed-logo-real-frames", test_sampled_logo_windows_match_real_ffmpeg_frames);
    Test.add_func ("/bulk-conversion/calibration/timed-logo-sample-seek", test_sampled_logo_windows_follow_source_seek);
    Test.add_func ("/bulk-conversion/scan/top-level-sort-and-aliases",
        test_bulk_scan_sorts_top_level_videos_and_deduplicates_aliases);
    Test.add_func ("/bulk-conversion/scan/pre-cancel",
        test_bulk_scan_precancel_does_not_return_partial_queue);
    Test.add_func ("/bulk-conversion/publish/collisions-and-source-aliases",
        test_bulk_publish_preserves_late_collisions_and_protected_source_aliases);
    Test.add_func ("/bulk-conversion/settings/copy-isolation",
        test_bulk_settings_copy_owns_every_per_job_input);
    Test.add_func ("/bulk-conversion/widgets/synthetic-sequential-queue-and-stop",
        test_bulk_queue_analyzes_converts_and_stops_sequentially);
    Test.add_func ("/bulk-conversion/widgets/late-collage-cancel-keeps-video",
        test_bulk_late_collage_cancellation_keeps_verified_video);
    Test.add_func ("/bulk-conversion/widgets/match-source-size-per-file",
        test_bulk_match_source_size_waits_for_each_file);
    Test.add_func ("/bulk-conversion/widgets/codecs/size/x264", test_bulk_size_x264);
    Test.add_func ("/bulk-conversion/widgets/codecs/size/x265", test_bulk_size_x265);
    Test.add_func ("/bulk-conversion/widgets/codecs/size/vp9", test_bulk_size_vp9);
    Test.add_func ("/bulk-conversion/widgets/codecs/size/svt-av1", test_bulk_size_svt_av1);
    Test.add_func ("/bulk-conversion/widgets/codecs/quality/x264", test_bulk_quality_x264);
    Test.add_func ("/bulk-conversion/widgets/codecs/quality/x265", test_bulk_quality_x265);
    Test.add_func ("/bulk-conversion/widgets/codecs/quality/vp9", test_bulk_quality_vp9);
    Test.add_func ("/bulk-conversion/widgets/codecs/quality/svt-av1", test_bulk_quality_svt_av1);
    Test.add_func ("/bulk-conversion/widgets/typed-input-admission-and-preservation",
        test_bulk_input_classification_admission_and_general_preservation);
    Test.add_func ("/bulk-conversion/widgets/retired-detector-and-direct-guards",
        test_bulk_folder_mode_retires_crop_worker_and_blocks_direct_detectors);

    Test.add_func ("/prepared-conversion/config/runtime-and-profile-copy",
        test_prepared_config_and_runtime_are_deep_copies);
    Test.add_func ("/prepared-conversion/probes/captured-controlled-execution",
        test_prepared_probes_use_explicit_path_and_controlled_capture);
    Test.add_func ("/prepared-conversion/widgets/passlog-and-request-ownership",
        test_prepared_worker_owns_passlog_and_captured_request);
    Test.add_func ("/prepared-conversion/widgets/cancel-initial-probe-and-retry",
        test_prepared_worker_cancels_initial_probe_and_can_retry);
    Test.add_func ("/prepared-conversion/optimizer/captured-runtime-and-pre-cancel",
        test_prepared_optimizer_captures_runtime_and_precancel_skips_spawn);
    Test.add_func ("/prepared-conversion/naming/captured-options-and-calibration-retarget",
        test_prepared_naming_and_calibration_filter_contracts);

    Test.add_func ("/smart-codec/golden/all-four-codecs",
        test_smart_codec_resolver_matches_legacy_goldens);
    Test.add_func ("/smart-codec/widgets/frozen-profile-parity",
        test_smart_codec_widgets_match_legacy_goldens);
    Test.add_func ("/smart-codec/policy/full-effort-features",
        test_smart_codec_resolver_retains_complete_effort_policy);
    Test.add_func ("/smart-codec/policy/audio-reset-and-copy-block",
        test_smart_codec_resolver_audio_policy_and_processing_reset);
    Test.add_func ("/smart-codec/ownership/request-and-profile-isolation",
        test_smart_codec_resolver_owns_inputs_and_profiles);
    Test.add_func ("/smart-codec/policy/inactive-crf-reset-defaults",
        test_smart_codec_resolver_preserves_inactive_crf_defaults);
    Test.add_func ("/smart-codec/ownership/filter-depth-variants",
        test_smart_codec_resolver_selects_owned_filter_depth_variants);
    Test.add_func ("/smart-codec/widgets/target-recommendation-ownership",
        test_smart_codec_target_adapter_does_not_mutate_recommendation);


    Test.add_func ("/encode-profile/composition/preserves-caller-state",
        test_encode_profile_composition_does_not_mutate_callers);
    Test.add_func ("/encode-profile/copy/general-nested-state",
        test_general_settings_copy_isolates_nested_state);
    Test.add_func ("/encode-profile/copy/codec-source-observations",
        test_codec_settings_copy_isolates_source_observations);
    Test.add_func ("/encode-profile/composition/processing-contract",
        test_encode_profile_composition_preserves_processing_contract);
    Test.add_func ("/encode-profile/copy/frozen-execution-state",
        test_encode_profile_copy_freezes_execution_state);
    Test.add_func ("/encode-profile/composition/independent-jobs",
        test_encode_profile_jobs_do_not_leak_audio_or_format);
    Test.add_func ("/encode-profile/adapter/effective-format-private-state",
        test_encode_profile_adapter_reconciles_effective_format_privately);
    Test.add_func ("/encode-profile/composition/without-general",
        test_encode_profile_composition_without_general_uses_defaults);

    Test.add_func ("/combine/widgets/move-up-button",
        test_move_up_button_reorders_files);
    Test.add_func ("/combine/widgets/preview-hides-popout-button",
        test_combine_preview_hides_popout_button);
    Test.add_func ("/players/video/fullscreen-control-state",
        test_video_player_fullscreen_control_state);
    Test.add_func ("/players/video/fullscreen-shortcut-releases-player",
        test_video_player_fullscreen_shortcut_releases_player);
    Test.add_func ("/combine/widgets/preview-player-releases-on-close",
        test_combine_preview_player_releases_on_close);
    Test.add_func ("/combine/widgets/preview-fullscreen-window-state",
        test_combine_preview_fullscreen_window_state);
    Test.add_func ("/trim/widgets/preview-fullscreen-window-state",
        test_trim_preview_fullscreen_window_state);
    Test.add_func ("/players/video/duration-state-transitions",
        test_video_player_duration_state_transitions);
    Test.add_func ("/players/audio/duration-state-transitions",
        test_audio_player_duration_state_transitions);
    Test.add_func ("/players/video/speed-resets-per-preview",
        test_video_player_speed_resets_per_preview);
    Test.add_func ("/players/audio/speed-resets-per-preview",
        test_audio_player_speed_resets_per_preview);
    Test.add_func ("/players/video/speed-reaches-mpv-without-scaling-time",
        test_video_player_speed_reaches_mpv_without_scaling_time);
    Test.add_func ("/players/video/failed-load-releases-backend-resources",
        test_video_player_failed_load_releases_backend_resources);
    Test.add_func ("/players/video/disables-mpv-timing-lookahead",
        test_video_player_disables_mpv_timing_lookahead);
    Test.add_func ("/combine/file-pickers/combine-lock-clears-and-disables-input",
        test_file_pickers_combine_lock_clears_and_disables_input);
    Test.add_func ("/app-settings/recent-inputs/bounded-deduplicated-pruned",
        test_recent_input_history_is_bounded_deduplicated_and_pruned);
    Test.add_func ("/app-settings/recent-inputs/folders-persist-and-clear",
        test_recent_input_folders_persist_and_obey_history_preference);
    Test.add_func ("/app-settings/bit-depth-warning/dialog-preference-persists",
        test_bit_depth_warning_dialog_preference_persists);
    Test.add_func ("/app-settings/smart-optimizer/quality-ceiling-persists",
        test_quality_ceiling_preference_persists);
    Test.add_func ("/app-settings/collage/size-persists",
        test_collage_size_preference_persists);
    Test.add_func ("/hamburger/recent-inputs/full-path-tooltip",
        test_recent_input_menu_item_exposes_full_path_tooltip);
    Test.add_func ("/hamburger/recent-inputs/repeated-refresh-is-stable",
        test_recent_input_menu_repeated_refresh_is_stable);
    Test.add_func ("/combine/information/clears-stale-input-when-removed",
        test_information_tab_clears_stale_input_when_input_removed);
    Test.add_func ("/combine/information/output-hides-input-and-shows-summary",
        test_information_tab_combine_output_hides_input_and_shows_summary);
    Test.add_func ("/combine/information/png-output-hides-frame-rate-and-relabels-codec",
        test_information_tab_png_output_hides_frame_rate_and_uses_image_codec_label);
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
    Test.add_func ("/combine/runner/copy-command-strips-metadata-when-disabled",
        test_copy_command_strips_metadata_when_preserve_metadata_disabled);
    Test.add_func ("/combine/runner/copy-command-no-audio",
        test_copy_command_disables_audio_when_inputs_have_no_audio);
    Test.add_func ("/combine/runner/reencode-command-sar-normalization",
        test_reencode_command_normalizes_sample_aspect_ratio);
    Test.add_func ("/combine/runner/reencode-command-filter-and-flags",
        test_reencode_command_generates_expected_filter_and_flags);
    Test.add_func ("/combine/runner/reencode-command-image-watermark-topology",
        test_reencode_command_image_watermark_topology);
    Test.add_func ("/combine/runner/reencode-command-text-watermark-no-extra-input",
        test_reencode_command_text_watermark_no_extra_input);
    Test.add_func ("/combine/window/remove-file-cancels-pending-probe",
        test_remove_file_cancels_inflight_probe_and_unblocks_combine);
    Test.add_func ("/combine/window/copy-mode-sar-mismatch",
        test_copy_mode_disables_on_sample_aspect_ratio_mismatch);
    Test.add_func ("/combine/window/reencode-subtitle-describes-compatible-general-settings",
        test_reencode_codec_subtitle_describes_supported_general_settings);
    Test.add_func ("/combine/overwrite/freezes-launch-file-list",
        test_pending_overwrite_freezes_launch_file_list);
    Test.add_func ("/combine/output-path/sanitizes-before-overwrite-check",
        test_converter_output_path_is_sanitized_before_overwrite_check);
    Test.add_func ("/collage/runner/handles-degenerate-sources",
        test_collage_handles_degenerate_sources);
    Test.add_func ("/collage/size/row-follows-the-switch",
        test_collage_size_row_follows_the_switch);
    Test.add_func ("/collage/size/tiles-the-grid-exactly",
        test_collage_sizes_tile_the_grid_exactly);
    Test.add_func ("/collage/size/reaches-the-ffmpeg-command",
        test_collage_size_reaches_the_ffmpeg_command);
    Test.add_func ("/collage/runner/writes-png-beside-source",
        test_collage_runner_writes_png_beside_source);
    Test.add_func ("/collage/runner/releases-itself-after-a-run",
        test_collage_runner_does_not_strand_itself);
    Test.add_func ("/collage/window/locks-source-while-running",
        test_collage_window_locks_the_source_while_running);
    Test.add_func ("/collage/window/generate-gated-on-real-source",
        test_collage_window_gates_generate_on_a_real_source);
    Test.add_func ("/convert/runner/non-watermark-off-keeps-existing-mapping",
        test_conversion_runner_non_watermark_off_keeps_existing_mapping_behavior);
    Test.add_func ("/convert/runner/non-watermark-on-maps-primary-video-and-all-audio",
        test_conversion_runner_non_watermark_on_maps_primary_video_and_all_audio);
    Test.add_func ("/convert/progress/frame-count-accounts-for-video-speed",
        test_conversion_frame_count_accounts_for_video_speed);
    Test.add_func ("/convert/audio/fade-follows-audio-speed",
        test_conversion_audio_fade_follows_audio_speed);
    Test.add_func ("/convert/runner/duration-bounds-the-input",
        test_conversion_runner_duration_bounds_the_input);
    Test.add_func ("/convert/runner/video-only-resets-output-timestamps",
        test_conversion_runner_video_only_resets_output_timestamps);
    Test.add_func ("/convert/runner/video-only-adds-timestamp-filter-to-empty-chain",
        test_conversion_runner_video_only_adds_timestamp_filter_to_empty_chain);
    Test.add_func ("/convert/runner/retained-audio-does-not-reset-video-independently",
        test_conversion_runner_retained_audio_does_not_reset_video_independently);
    Test.add_func ("/convert/runner/subtitles-block-independent-video-reset",
        test_conversion_runner_subtitles_block_independent_video_reset);
    Test.add_func ("/convert/runner/retained-chapters-block-video-reset",
        test_conversion_runner_retained_chapters_block_video_reset);
    Test.add_func ("/convert/runner/removed-chapters-allow-video-reset",
        test_conversion_runner_removed_chapters_allow_video_reset);
    Test.add_func ("/convert/runner/unknown-topology-fails-closed",
        test_conversion_runner_unknown_topology_fails_closed);
    Test.add_func ("/convert/runner/video-only-watermark-excludes-input-subtitles",
        test_conversion_runner_video_only_watermark_excludes_input_subtitles);
    Test.add_func ("/convert/runner/image-watermark-toggle-off-maps-first-audio",
        test_conversion_runner_image_watermark_toggle_off_maps_first_audio_only);
    Test.add_func ("/convert/runner/image-watermark-toggle-on-maps-all-audio",
        test_conversion_runner_image_watermark_toggle_on_maps_all_audio);
    Test.add_func ("/convert/runner/image-watermark-preserves-selected-10bit",
        test_conversion_runner_image_watermark_preserves_selected_10bit);
    Test.add_func ("/convert/runner/pass1-image-watermark-keeps-audio-mapping-disabled",
        test_conversion_runner_pass1_image_watermark_keeps_audio_mapping_disabled);
    Test.add_func ("/convert/runner/pass2-toggle-on-maps-primary-video-and-all-audio",
        test_conversion_runner_pass2_maps_primary_video_and_all_audio_when_toggle_on);
    Test.add_func ("/convert/runner/pass2-image-watermark-toggle-off-maps-first-audio",
        test_conversion_runner_pass2_image_watermark_toggle_off_maps_first_audio_only);
    Test.add_func ("/convert/runner/pass2-image-watermark-toggle-on-maps-all-audio",
        test_conversion_runner_pass2_image_watermark_toggle_on_maps_all_audio);
    Test.add_func ("/convert/runner/peak-detect-toggle-off-maps-first-audio",
        test_conversion_runner_peak_detect_toggle_off_maps_first_audio_only);
    Test.add_func ("/convert/runner/peak-detect-toggle-on-maps-all-audio",
        test_conversion_runner_peak_detect_toggle_on_maps_all_audio);
    Test.add_func ("/convert/runner/collage-output-path-uses-png-sidecar-name",
        test_conversion_runner_collage_output_path_uses_png_sidecar_name);
    Test.add_func ("/convert/runner/collage-command-uses-percentage-timestamps",
        test_conversion_runner_collage_command_uses_percentage_timestamps);
    Test.add_func ("/convert/runner/nonzero-pts-media-and-collage-integration",
        test_conversion_runner_nonzero_pts_media_and_collage_integration);
    Test.add_func ("/process-runner/capture-is-cancellable",
        test_process_runner_capture_is_cancellable);
    Test.add_func ("/convert/progress-prefers-real-video-duration",
        test_converter_progress_prefers_real_video_duration);
    Test.add_func ("/convert/runner/single-frame-collage-integration",
        test_conversion_runner_single_frame_collage_integration);
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
    Test.add_func ("/combine/keep-all-audio/disabled-at-construction",
        test_combine_disables_keep_all_audio_at_construction);
    Test.add_func ("/combine/keep-all-audio/close-releases-constraint",
        test_closing_combine_window_releases_keep_all_audio_constraint);
    Test.add_func ("/combine/keep-all-audio/trim-style-clear-does-not-clear-preserved-state",
        test_trim_style_clear_does_not_clear_keep_all_audio_while_combine_is_open);

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

    // Watermark constraint tests
    Test.add_func ("/combine/watermark/active-watermark-forces-reencode",
        test_active_watermark_forces_reencode);
    Test.add_func ("/combine/watermark/clearing-text-releases-constraint",
        test_clearing_watermark_text_releases_constraint);
    Test.add_func ("/combine/watermark/effective-state-requires-text",
        test_watermark_effective_state_requires_text);
    Test.add_func ("/combine/watermark/drawtext-unavailable-disables-ui",
        test_drawtext_unavailable_disables_watermark_ui);
    Test.add_func ("/combine/svt-av1/crf-two-pass-probe-supported",
        test_svt_av1_crf_two_pass_probe_reports_supported);
    Test.add_func ("/combine/svt-av1/crf-two-pass-probe-unsupported",
        test_svt_av1_crf_two_pass_probe_reports_unsupported);
    Test.add_func ("/combine/svt-av1/crf-two-pass-probe-prefers-error-over-info",
        test_svt_av1_crf_two_pass_probe_prefers_error_over_info);
    Test.add_func ("/combine/vmaf/filter-parser-exact-name",
        test_vmaf_filter_parser_requires_exact_libvmaf_name);
    Test.add_func ("/combine/encoder-pixel-format/parser-exact-token",
        test_encoder_pixel_format_parser_requires_exact_token);
    Test.add_func ("/combine/vmaf/probe-supported-and-unsupported",
        test_vmaf_probe_reports_supported_and_unsupported);
    Test.add_func ("/combine/vmaf/probe-binary-error",
        test_vmaf_probe_reports_binary_errors_separately);
    Test.add_func ("/combine/smart-optimizer/report-native-sharpness",
        test_smart_optimizer_report_includes_native_sharpness_decision);
    Test.add_func ("/combine/smart-optimizer/final-size-comparison",
        test_conversion_report_compares_smart_target_with_actual_bytes);
    Test.add_func ("/combine/smart-optimizer/direct-args-temporal-tuning",
        test_smart_optimizer_direct_args_include_temporal_tuning);
    Test.add_func ("/combine/smart-optimizer/apply-temporal-tuning",
        test_smart_optimizer_applies_temporal_tuning_to_codec_tabs);
    Test.add_func ("/combine/smart-optimizer/shared-output-timing",
        test_shared_output_timing_resolution);
    Test.add_func ("/combine/svt-av1/crf-two-pass-ui-reacts-to-capability",
        test_svt_av1_crf_two_pass_capability_updates_visibility);
    Test.add_func ("/combine/svt-av1/crf-two-pass-backstop-fails-fast",
        test_svt_av1_crf_two_pass_backstop_fails_fast);
    Test.add_func ("/combine/svt-av1/aq-variance-enables-variance-boost",
        test_svt_av1_aq_variance_enables_variance_boost);
    Test.add_func ("/combine/x265/level-reaches-encoder-in-main-tier",
        test_x265_level_reaches_encoder_in_main_tier);
    Test.add_func ("/combine/x265/default-psy-rd-and-deblock-leave-tune-alone",
        test_x265_default_psy_rd_and_deblock_leave_tune_alone);
    Test.add_func ("/combine/x265/reference-frames-auto-follows-preset",
        test_x265_reference_frames_auto_follows_preset);
    Test.add_func ("/combine/vp9/speed-follows-deadline",
        test_vp9_speed_follows_deadline);
    Test.add_func ("/combine/vp9/frame-parallel-off-is-sent",
        test_vp9_frame_parallel_off_is_sent);
    Test.add_func ("/smart-codec/widgets/vp9-tab-follows-two-pass-and-deadline",
        test_smart_codec_widgets_vp9_tab_follows_two_pass_and_deadline);

    // FilterBuilder drawtext tests
    Test.add_func ("/combine/drawtext/basic-drawtext-output",
        test_drawtext_basic_output);
    Test.add_func ("/combine/drawtext/position-presets",
        test_drawtext_position_presets);
    Test.add_func ("/combine/drawtext/escaping-special-chars",
        test_drawtext_escaping);
    Test.add_func ("/combine/drawtext/disabled-produces-no-filter",
        test_drawtext_disabled_produces_nothing);
    Test.add_func ("/combine/drawtext/combine-post-output-includes-watermark",
        test_combine_post_output_includes_watermark);
    Test.add_func ("/combine/drawtext/utf8-text-preserved",
        test_drawtext_utf8_text_preserved);
    Test.add_func ("/combine/drawtext/custom-color",
        test_drawtext_custom_color);
    Test.add_func ("/combine/drawtext/dark-color-gets-light-shadow",
        test_drawtext_dark_color_gets_light_shadow);

    // Image watermark tests
    Test.add_func ("/combine/image-watermark/image-mode-skips-drawtext",
        test_image_mode_skips_drawtext);
    Test.add_func ("/combine/image-watermark/overlay-fragment-basic",
        test_image_overlay_fragment_basic);
    Test.add_func ("/combine/image-watermark/overlay-fragment-full-opacity",
        test_image_overlay_fragment_full_opacity);
    Test.add_func ("/combine/image-watermark/overlay-fragment-original-size",
        test_image_overlay_fragment_original_size);
    Test.add_func ("/combine/image-watermark/overlay-output-format-mapping",
        test_overlay_output_format_mapping);
    Test.add_func ("/combine/image-watermark/overlay-fragment-preserves-10bit",
        test_image_overlay_fragment_preserves_10bit);
    Test.add_func ("/combine/image-watermark/overlay-position-presets",
        test_image_overlay_position_presets);
    Test.add_func ("/combine/image-watermark/effective-state-requires-file",
        test_image_watermark_effective_state);
    Test.add_func ("/combine/image-watermark/overlay-unavailable-disables-ui",
        test_overlay_unavailable_disables_image_watermark);
    Test.add_func ("/combine/image-watermark/mode-switch-unlocks-available-filter",
        test_mode_switch_unlocks_when_other_filter_available);
    Test.add_func ("/combine/image-watermark/snapshot-fields",
        test_image_watermark_snapshot_fields);
    Test.add_func ("/combine/image-watermark/encode-profile-carries-fields",
        test_encode_profile_carries_watermark_fields);
    Test.add_func ("/general/logo-removal/timed-regions-count-as-enabled",
        test_timed_regions_enable_logo_removal);
    Test.add_func ("/general/logo-removal/both-detect-buttons-reset-together",
        test_both_logo_detect_buttons_reset_together);

    Test.run ();
}
