using GLib;
using Gtk;

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

private void assert_int_equal (int actual, int expected, string context) {
    if (actual != expected) {
        Test.fail_printf ("%s expected %d but got %d", context, expected, actual);
    }
}

private void assert_output_kind_equal (OperationOutputKind actual,
                                       OperationOutputKind expected,
                                       string context) {
    if (actual != expected) {
        Test.fail_printf ("%s expected output kind %d but got %d",
            context, (int) expected, (int) actual);
    }
}

private void assert_string_equal (string actual, string expected, string context) {
    if (actual != expected) {
        Test.fail_printf ("%s expected '%s' but got '%s'", context, expected, actual);
    }
}

private void assert_string_not_equal (string actual, string unexpected, string context) {
    if (actual == unexpected) {
        Test.fail_printf ("%s unexpectedly matched '%s'", context, unexpected);
    }
}

private void assert_contains (string actual, string expected_fragment, string context) {
    if (!actual.contains (expected_fragment)) {
        Test.fail_printf ("%s expected to find '%s' in '%s'",
            context, expected_fragment, actual);
    }
}

private void assert_array_has_adjacent_pair (string[] values,
                                             string expected_left,
                                             string expected_right,
                                             string context) {
    for (int i = 0; i < values.length - 1; i++) {
        if (values[i] == expected_left && values[i + 1] == expected_right) {
            return;
        }
    }

    Test.fail_printf ("%s expected pair ['%s', '%s']",
        context, expected_left, expected_right);
}

private void assert_array_not_contains (string[] values, string unexpected, string context) {
    foreach (string value in values) {
        if (value == unexpected) {
            Test.fail_printf ("%s did not expect '%s'", context, unexpected);
            return;
        }
    }
}

private string get_argv_value_after (string[] values,
                                     string option,
                                     string context) {
    for (int i = 0; i < values.length - 1; i++) {
        if (values[i] == option)
            return values[i + 1];
    }

    Test.fail_printf ("%s expected option '%s'", context, option);
    return "";
}

private void assert_double_equal (double actual, double expected, string context) {
    if (Math.fabs (actual - expected) > 0.000001) {
        Test.fail_printf ("%s expected %.6f but got %.6f", context, expected, actual);
    }
}

private SubtitleStream make_stream (int sub_index, string title = "") {
    var stream = new SubtitleStream ();
    stream.sub_index = sub_index;
    stream.title = title;
    stream.codec_name = "subrip";
    return stream;
}

private ExternalSubtitle make_external (string path) {
    var ext = new ExternalSubtitle ();
    ext.file_path = path;
    return ext;
}

private TrimSegment make_segment (double start, double end, string label) {
    var seg = new TrimSegment (start, end);
    seg.label = label;
    return seg;
}

private bool gtk_widget_tests_ready = false;
private bool gtk_widget_tests_available = false;

private bool ensure_gtk_widget_tests_available () {
    if (!gtk_widget_tests_ready) {
        gtk_widget_tests_available = Gtk.init_check ();
        gtk_widget_tests_ready = true;
    }

    if (!gtk_widget_tests_available) {
        Test.skip ("GTK could not initialize");
        return false;
    }

    return true;
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

private double probe_media_duration_seconds (string path, string context) {
    string[] cmd = {
        AppSettings.get_default ().ffprobe_path,
        "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=nw=1:nk=1",
        path
    };

    string stdout_buf, stderr_buf;
    int status = run_command_for_test (cmd, out stdout_buf, out stderr_buf, context);
    if (status != 0) {
        Test.fail_printf ("%s failed to probe duration for '%s': %s",
            context, path, stderr_buf.strip ());
    }

    return double.parse (stdout_buf.strip ());
}

private double parse_duration_field_for_test (string text) {
    string trimmed = text.strip ();
    if (trimmed.length == 0 || trimmed == "N/A") return -1.0;

    if (!trimmed.contains (":")) {
        double plain = double.parse (trimmed);
        return plain > 0.0 ? plain : -1.0;
    }

    string[] parts = trimmed.split (":");
    if (parts.length != 3) return -1.0;

    return double.parse (parts[0]) * 3600.0
         + double.parse (parts[1]) * 60.0
         + double.parse (parts[2]);
}

/**
 * Per-stream duration, which is what a synced speed change has to be judged on:
 * a container duration is a single number covering both streams and would hide
 * a drift between them. Matroska carries it as a DURATION tag rather than a
 * stream field, so both forms are accepted.
 */
private double probe_stream_duration_seconds (string path,
                                              string stream_spec,
                                              string context) {
    string[] cmd = {
        AppSettings.get_default ().ffprobe_path,
        "-v", "error",
        "-select_streams", stream_spec,
        "-show_entries", "stream=duration:stream_tags=DURATION",
        "-of", "default=nw=1:nk=1",
        path
    };

    string stdout_buf, stderr_buf;
    int status = run_command_for_test (cmd, out stdout_buf, out stderr_buf, context);
    if (status != 0) {
        Test.fail_printf ("%s failed to probe stream '%s' in '%s': %s",
            context, stream_spec, path, stderr_buf.strip ());
        return 0.0;
    }

    foreach (unowned string line in stdout_buf.split ("\n")) {
        double parsed = parse_duration_field_for_test (line);
        if (parsed > 0.0) return parsed;
    }

    Test.fail_printf ("%s found no duration for stream '%s' in '%s'",
        context, stream_spec, path);
    return 0.0;
}

private string probe_video_pixel_format (string path, string context) {
    string[] cmd = {
        AppSettings.get_default ().ffprobe_path,
        "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=pix_fmt",
        "-of", "default=nw=1:nk=1",
        path
    };

    string stdout_buf, stderr_buf;
    int status = run_command_for_test (cmd, out stdout_buf, out stderr_buf, context);
    if (status != 0) {
        Test.fail_printf ("%s failed to probe pixel format for '%s': %s",
            context, path, stderr_buf.strip ());
    }
    return stdout_buf.strip ();
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

private string resolve_test_asset_path (string filename) {
    string cwd = Environment.get_current_dir ();
    string[] candidates = {
        Path.build_filename (cwd, "tests", filename),
        Path.build_filename (cwd, "..", "tests", filename),
        Path.build_filename (cwd, "..", "..", "tests", filename)
    };

    foreach (unowned string candidate in candidates) {
        if (FileUtils.test (candidate, FileTest.EXISTS)) {
            return candidate;
        }
    }

    Test.fail_printf ("could not resolve test asset '%s' from cwd '%s'",
        filename, cwd);
    return "";
}

private EncodeProfileSnapshot make_subtitle_burn_in_profile_for_test (bool preserve_all_audio_tracks,
                                                                      string? watermark_path = null) {
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "23" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "128k" };
    profile.video_filters =
        "zscale=w=trunc(iw*2.000000/2)*2:h=trunc(ih*2.000000/2)*2:filter=lanczos";
    profile.preserve_all_audio_tracks = preserve_all_audio_tracks;

    if (watermark_path != null) {
        profile.watermark_enabled = true;
        profile.watermark_mode = "image";
        profile.watermark_image_path = watermark_path;
        profile.watermark_image_width = 120;
        profile.watermark_position = "Top Right";
        profile.watermark_opacity = 0.85;
        profile.watermark_margin = 10;
    }

    return profile;
}

private EncodeProfileSnapshot make_trim_reencode_profile_for_test (string watermark_path) {
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "23" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "128k" };
    profile.watermark_enabled = true;
    profile.watermark_mode = "image";
    profile.watermark_image_path = watermark_path;
    profile.watermark_image_width = 120;
    profile.watermark_position = "Bottom Right";
    profile.watermark_opacity = 1.0;
    profile.watermark_margin = 10;
    return profile;
}

private SmartOptimizerImageWatermark make_smart_watermark_for_test (
    string watermark_path
) {
    var general = new GeneralSettingsSnapshot ();
    general.watermark_enabled = true;
    general.watermark_mode = "image";
    general.watermark_image_path = watermark_path;
    general.watermark_image_width = 60;
    general.watermark_position = "Top Left";
    general.watermark_opacity = 0.75;
    general.watermark_margin = 7;

    SmartOptimizerImageWatermark? watermark =
        FilterBuilder.snapshot_smart_image_watermark (general);
    assert_true (watermark != null,
        "Smart image watermark snapshot is active");
    return watermark;
}

private void test_smart_watermark_calibration_and_reference_topology () {
    string input_path = resolve_test_asset_path ("test_dvd.vob");
    string watermark_path = resolve_test_asset_path ("watermarktestimage.jpg");
    SmartOptimizerImageWatermark watermark =
        make_smart_watermark_for_test (watermark_path);
    var optimizer = new SmartOptimizer ();

    string[] direct = optimizer.build_watermarked_calibration_cmd_for_test (
        input_path, "/tmp/smart-watermark-direct.mkv",
        "scale=640:360,format=yuv420p10le", PixelFormat.YUV420P10LE,
        watermark);
    assert_array_has_adjacent_pair (direct, "-i", watermark_path,
        "Smart direct calibration includes watermark input");
    string direct_fc = get_filter_complex_from_argv (
        direct, "Smart direct watermark calibration");
    assert_contains (direct_fc, "concat=n=1:v=1:a=0[vpre]",
        "Smart direct calibration overlays after filtered sample concat");
    assert_contains (direct_fc,
        "overlay=x=7:y=7:format=yuv420p10[v]",
        "Smart direct calibration preserves decided 10-bit output");

    string[] reference = optimizer.build_watermarked_reference_cmd_for_test (
        input_path, "/tmp/smart-watermark-reference.mkv",
        "scale=640:360,format=yuv420p10le", PixelFormat.YUV420P10LE,
        watermark);
    assert_array_has_adjacent_pair (reference, "-i", watermark_path,
        "Quality reference includes watermark input");
    assert_contains (get_filter_complex_from_argv (
            reference, "Smart watermarked Quality reference"),
        "overlay=x=7:y=7:format=yuv420p10[v]",
        "VMAF reference renders the same 10-bit watermark pixels");

    string[] no_watermark = optimizer.build_watermarked_calibration_cmd_for_test (
        input_path, "/tmp/smart-no-watermark.mkv",
        "scale=640:360", PixelFormat.YUV420P, null);
    assert_array_not_contains (no_watermark, watermark_path,
        "No-watermark Smart calibration has no extra image input");
    assert_false (get_filter_complex_from_argv (
            no_watermark, "Smart calibration without watermark").contains ("overlay="),
        "No-watermark Smart calibration topology remains unchanged");
}

private void test_smart_watermark_snapshot_tracks_file_and_settings () {
    string tmp_dir;
    try {
        tmp_dir = DirUtils.make_tmp ("ffmpeg-smart-watermark-identity-XXXXXX");
    } catch (Error e) {
        Test.fail_printf ("failed to create temp directory: %s", e.message);
        return;
    }

    try {
        string watermark_path = Path.build_filename (tmp_dir, "watermark.bin");
        FileUtils.set_contents (watermark_path, "first");

        var general = new GeneralSettingsSnapshot ();
        general.watermark_enabled = true;
        general.watermark_mode = "image";
        general.watermark_image_path = watermark_path;
        general.watermark_image_width = 80;
        general.watermark_position = "Bottom Right";
        general.watermark_opacity = 0.5;
        general.watermark_margin = 10;

        SmartOptimizerImageWatermark? first =
            FilterBuilder.snapshot_smart_image_watermark (general);
        assert_true (first != null, "first watermark snapshot exists");
        string first_identity = first.cache_identity ();

        // Changing the file in place must miss even though its path is stable.
        FileUtils.set_contents (watermark_path, "second-and-longer");
        SmartOptimizerImageWatermark? changed_file =
            FilterBuilder.snapshot_smart_image_watermark (general);
        assert_true (changed_file != null, "changed-file watermark snapshot exists");
        assert_true (changed_file.cache_identity () != first_identity,
            "watermark file contents change cache identity");

        // A rendered setting change must also miss without touching the file.
        general.watermark_opacity = 0.75;
        SmartOptimizerImageWatermark? changed_setting =
            FilterBuilder.snapshot_smart_image_watermark (general);
        assert_true (changed_setting != null,
            "changed-setting watermark snapshot exists");
        assert_true (changed_setting.cache_identity ()
                != changed_file.cache_identity (),
            "watermark rendering setting changes cache identity");
    } catch (Error e) {
        Test.fail_printf ("watermark identity test failed: %s", e.message);
    } finally {
        cleanup_exec_test_dir (tmp_dir);
    }
}

private void test_smart_watermark_commands_execute_at_8_and_10_bit () {
    string tmp_dir;
    try {
        tmp_dir = DirUtils.make_tmp ("ffmpeg-smart-watermark-XXXXXX");
    } catch (Error e) {
        Test.fail_printf ("failed to create temp directory: %s", e.message);
        return;
    }

    try {
        string input_path = resolve_test_asset_path ("test_dvd.vob");
        string watermark_path = resolve_test_asset_path ("watermarktestimage.jpg");
        SmartOptimizerImageWatermark watermark =
            make_smart_watermark_for_test (watermark_path);
        var optimizer = new SmartOptimizer ();

        string output8 = Path.build_filename (tmp_dir, "calibration-8bit.mkv");
        string[] command8 = optimizer.build_watermarked_calibration_cmd_for_test (
            input_path, output8, "scale=640:360,format=yuv420p",
            PixelFormat.YUV420P, watermark);
        string stdout_buf, stderr_buf;
        int status8 = run_command_for_test (
            command8, out stdout_buf, out stderr_buf,
            "8-bit Smart watermark calibration");
        assert_true (status8 == 0,
            "8-bit Smart watermark calibration executes: " + stderr_buf.strip ());
        assert_string_equal (probe_video_pixel_format (
                output8, "8-bit Smart watermark output"),
            PixelFormat.YUV420P,
            "8-bit Smart watermark output pixel format");

        string output10 = Path.build_filename (tmp_dir, "calibration-10bit.mkv");
        string[] command10 = optimizer.build_watermarked_calibration_cmd_for_test (
            input_path, output10, "scale=640:360,format=yuv420p10le",
            PixelFormat.YUV420P10LE, watermark);
        int status10 = run_command_for_test (
            command10, out stdout_buf, out stderr_buf,
            "10-bit Smart watermark calibration");
        assert_true (status10 == 0,
            "10-bit Smart watermark calibration executes: " + stderr_buf.strip ());
        assert_string_equal (probe_video_pixel_format (
                output10, "10-bit Smart watermark output"),
            PixelFormat.YUV420P10LE,
            "10-bit Smart watermark output pixel format");

        // Quality Mode uses this lossless intermediate as both its encoded
        // source and its VMAF reference, so the watermark must execute here too.
        string reference10 = Path.build_filename (tmp_dir, "reference-10bit.mkv");
        string[] reference_cmd = optimizer.build_watermarked_reference_cmd_for_test (
            input_path, reference10, "scale=640:360,format=yuv420p10le",
            PixelFormat.YUV420P10LE, watermark);
        int reference_status = run_command_for_test (
            reference_cmd, out stdout_buf, out stderr_buf,
            "10-bit Smart watermarked Quality reference");
        assert_true (reference_status == 0,
            "10-bit Smart watermarked Quality reference executes: "
                + stderr_buf.strip ());
        assert_string_equal (probe_video_pixel_format (
                reference10, "10-bit Smart Quality reference"),
            PixelFormat.YUV420P10LE,
            "10-bit Smart Quality reference pixel format");
    } finally {
        cleanup_exec_test_dir (tmp_dir);
    }
}

private void assert_toggle_aware_audio_mapping (string[] argv,
                                                string expected_video_map,
                                                bool preserve_all_audio_tracks,
                                                string context) {
    assert_array_has_adjacent_pair (argv, "-map", expected_video_map,
        @"$context maps the expected video output");

    if (preserve_all_audio_tracks) {
        assert_array_has_adjacent_pair (argv, "-map", "0:a?",
            @"$context maps all audio streams when toggle is on");
        assert_array_not_contains (argv, "0:a:0?",
            @"$context should not map only the first audio stream when toggle is on");
    } else {
        assert_array_has_adjacent_pair (argv, "-map", "0:a:0?",
            @"$context maps only the first audio stream when toggle is off");
        assert_array_not_contains (argv, "0:a?",
            @"$context should not map all audio streams when toggle is off");
    }
}

private string get_filter_complex_from_argv (string[] argv, string context) {
    for (int i = 0; i < argv.length - 1; i++) {
        if (argv[i] == "-filter_complex") {
            return argv[i + 1];
        }
    }

    Test.fail_printf ("%s expected a -filter_complex argument", context);
    return "";
}

private string get_adjacent_arg_value (string[] argv, string arg_name, string context) {
    for (int i = 0; i < argv.length - 1; i++) {
        if (argv[i] == arg_name) {
            return argv[i + 1];
        }
    }

    Test.fail_printf ("%s expected a %s argument", context, arg_name);
    return "";
}

private void test_trim_chapter_derivation_preserves_existing_order_and_appends_new () {
    var chapters = new GenericArray<ChapterInfo> ();
    var ch1 = new ChapterInfo (0, "One", 0.0, 10.0);
    ch1.selected = true;
    chapters.add (ch1);
    var ch2 = new ChapterInfo (1, "Two", 10.0, 20.0);
    ch2.selected = true;
    chapters.add (ch2);
    var ch3 = new ChapterInfo (2, "Three", 20.0, 30.0);
    ch3.selected = true;
    chapters.add (ch3);

    var existing = new GenericArray<TrimSegment> ();
    existing.add (make_segment (10.0, 20.0, "Two old"));
    existing.add (make_segment (0.0, 10.0, "One old"));

    var result = TrimTab.derive_chapter_segments_for_test (chapters, existing);

    assert_int_equal (result.length, 3, "trim chapter derivation count");
    assert_string_equal (result[0].label, "Two old", "trim chapter derivation preserves first kept segment");
    assert_string_equal (result[1].label, "One old", "trim chapter derivation preserves second kept segment");
    assert_string_equal (result[2].label, "Three", "trim chapter derivation appends new chapter");
}

private void test_trim_segment_edit_move_delete_and_crop_helpers () {
    var segments = new GenericArray<TrimSegment> ();
    segments.add (make_segment (0.0, 5.0, "A"));
    segments.add (make_segment (5.0, 10.0, "B"));
    segments.add (make_segment (10.0, 15.0, "C"));

    TrimTab.move_segment_down_for_test (segments, 0);
    assert_string_equal (segments[0].label, "B", "trim move down");
    assert_string_equal (segments[1].label, "A", "trim move down");

    TrimTab.move_segment_up_for_test (segments, 2);
    assert_string_equal (segments[1].label, "C", "trim move up");
    assert_string_equal (segments[2].label, "A", "trim move up");

    var editable = make_segment (10.0, 15.0, "Editable");
    assert_true (
        TrimTab.apply_segment_start_edit_for_test (editable, 11.0),
        "trim valid start edit");
    assert_double_equal (editable.start_time, 11.0, "trim valid start edit applied");

    assert_false (
        TrimTab.apply_segment_start_edit_for_test (editable, 15.0),
        "trim invalid start edit rejected");
    assert_double_equal (editable.start_time, 11.0, "trim invalid start edit unchanged");

    assert_true (
        TrimTab.apply_segment_end_edit_for_test (editable, 14.0),
        "trim valid end edit");
    assert_double_equal (editable.end_time, 14.0, "trim valid end edit applied");

    assert_false (
        TrimTab.apply_segment_end_edit_for_test (editable, 10.0),
        "trim invalid end edit rejected");
    assert_double_equal (editable.end_time, 14.0, "trim invalid end edit unchanged");

    TrimTab.apply_crop_to_segment_for_test (editable, "1920:800:0:140");
    assert_string_equal (editable.crop_value, "1920:800:0:140", "trim crop application");

    TrimTab.delete_segment_for_test (segments, 1);
    assert_int_equal (segments.length, 2, "trim delete segment count");
    assert_string_equal (segments[1].label, "A", "trim delete removes middle segment");
}

private void test_trim_unknown_duration_segment_ranges () {
    double start;
    double end;

    assert_true (TrimTab.try_get_quick_segment_range_for_test (
            25.0, 0.0, out start, out end),
        "unknown duration accepts a bounded quick segment");
    assert_double_equal (start, 25.0,
        "unknown duration quick segment preserves its start");
    assert_double_equal (end, 35.0,
        "unknown duration quick segment uses a ten-second endpoint");

    assert_true (TrimTab.try_get_quick_segment_range_for_test (
            28.0, 30.0, out start, out end),
        "known duration accepts a shortened final segment");
    assert_double_equal (end, 30.0,
        "known duration clamps a quick segment to EOF");

    assert_false (TrimTab.try_get_quick_segment_range_for_test (
            30.0, 30.0, out start, out end),
        "known duration rejects a zero-length segment at EOF");

    var through_eof = TrimSegment.through_end_of_file (4.0);
    assert_false (through_eof.has_finite_end (),
        "through-EOF segment records its unbounded endpoint");
    assert_double_equal (through_eof.start_time, 4.0,
        "through-EOF segment preserves its start");
    assert_double_equal (through_eof.get_duration (), 0.0,
        "through-EOF segment does not invent a duration");
}

private void test_trim_runner_guard_helpers () {
    assert_true (
        TrimTab.runner_callback_matches_active_operation_for_test (true, 42, 42),
        "trim runner guard matches");
    assert_false (
        TrimTab.runner_callback_matches_active_operation_for_test (false, 42, 42),
        "trim runner guard requires same runner");
    assert_false (
        TrimTab.runner_callback_matches_active_operation_for_test (true, 42, 99),
        "trim runner guard requires matching operation id");
    assert_true (
        TrimTab.export_failure_counts_as_cancelled_for_test (false, true),
        "trim cancellation state includes runner cancellation");
    assert_true (
        TrimTab.export_failure_counts_as_cancelled_for_test (true, false),
        "trim cancellation state includes pending cancel");
    assert_false (
        TrimTab.export_failure_counts_as_cancelled_for_test (false, false),
        "trim cancellation state stays false otherwise");
}

private void test_trim_output_base_honours_naming_mode_outside_chapter_split () {
    // Trim Only / Crop Only / Crop & Trim take the Preferences naming-mode
    // name; the suffixes that follow it are composed separately.
    assert_string_equal (
        TrimTab.select_output_base_for_test (false, "myvideo", "a8a1m6g5"),
        "a8a1m6g5",
        "trim export adopts the resolved naming-mode name");

    // Chapter Split is exempt — it names its files after the chapters, so it
    // stays on the source's own basename no matter what the preference says.
    assert_string_equal (
        TrimTab.select_output_base_for_test (true, "myvideo", "a8a1m6g5"),
        "myvideo",
        "chapter split ignores the naming mode");

    // Default mode resolves to the source basename, so the two agree and
    // existing filenames are unchanged.
    assert_string_equal (
        TrimTab.select_output_base_for_test (false, "myvideo", "myvideo"),
        "myvideo",
        "default naming mode leaves the source name in place");

    // Nothing resolved — fall back to the source rather than emitting a name
    // that is nothing but a suffix.
    assert_string_equal (
        TrimTab.select_output_base_for_test (false, "myvideo", ""),
        "myvideo",
        "an unresolved base falls back to the source name");
}

private void test_trim_separate_segment_names_compose_around_the_base () {
    var used_names = new HashTable<string, bool> (str_hash, str_equal);

    // The naming-mode name replaces only the name; "-segment-NNN" and the
    // container extension are composed around it untouched.
    assert_string_equal (
        TrimTab.build_separate_output_name_for_test (
            false, "myvideo", "a8a1m6g5", ".mp4",
            new TrimSegment (0.0, 5.0), 0, used_names),
        "a8a1m6g5-segment-001.mp4",
        "separate segment name is built around the naming-mode name");

    // A labelled chapter keeps the source name AND its label — the naming mode
    // is passed in but must not reach this branch.
    var labelled = new TrimSegment (0.0, 5.0);
    labelled.label = "Chapter 3";
    assert_string_equal (
        TrimTab.build_separate_output_name_for_test (
            true, "myvideo", "a8a1m6g5", ".mkv", labelled, 0, used_names),
        "myvideo-Chapter 3.mkv",
        "chapter split keeps naming itself from source and label");

    // An unlabelled chapter falls through to the "-segment-NNN" form, and must
    // still ignore the naming mode rather than picking it up on the way past.
    assert_string_equal (
        TrimTab.build_separate_output_name_for_test (
            true, "myvideo", "a8a1m6g5", ".mkv",
            new TrimSegment (0.0, 5.0), 4,
            new HashTable<string, bool> (str_hash, str_equal)),
        "myvideo-segment-005.mkv",
        "unlabelled chapter keeps the source name");
}

private void test_trim_crop_only_names_a_single_file_not_a_segment () {
    // Crop Only produces exactly one file whatever the export-separate switch
    // says, so it must take the single-output "-cropped" name.
    assert_false (
        TrimTab.uses_per_segment_names_for_test (true, TrimTab.Mode.CROP_ONLY),
        "crop only never names per segment");
    assert_false (
        TrimTab.uses_per_segment_names_for_test (false, TrimTab.Mode.CROP_ONLY),
        "crop only stays single-output with export separate off");

    // The modes that really can emit several files still do.
    assert_true (
        TrimTab.uses_per_segment_names_for_test (true, TrimTab.Mode.TRIM_ONLY),
        "trim only names per segment when exporting separately");
    assert_true (
        TrimTab.uses_per_segment_names_for_test (true, TrimTab.Mode.TRIM_AND_CROP),
        "crop & trim names per segment when exporting separately");
    assert_true (
        TrimTab.uses_per_segment_names_for_test (true, TrimTab.Mode.CHAPTER_SPLIT),
        "chapter split names per segment when exporting separately");
    assert_false (
        TrimTab.uses_per_segment_names_for_test (false, TrimTab.Mode.TRIM_ONLY),
        "a combined export never names per segment");
}

private void test_trim_collage_fallback_durations_use_segment_context () {
    var runner = new TrimRunner ();

    var segments = new GenericArray<TrimSegment> ();
    segments.add (new TrimSegment (2.0, 7.5));
    segments.add (new TrimSegment (10.0, 14.0));
    segments.add (new TrimSegment (20.0, 29.25));
    runner.set_segments (segments);

    var combined_outputs = new GenericArray<string> ();
    combined_outputs.add ("/tmp/movie-trimmed.mkv");
    double[] combined_durations = runner.compute_fallback_durations_for_test (
        combined_outputs,
        false
    );

    assert_int_equal (combined_durations.length, 1,
        "combined collage fallback duration count");
    assert_double_equal (combined_durations[0], 18.75,
        "combined collage fallback sums all selected segments");

    var separate_outputs = new GenericArray<string> ();
    separate_outputs.add ("/tmp/movie-segment-001.mkv");
    separate_outputs.add ("/tmp/movie-segment-002.mkv");
    separate_outputs.add ("/tmp/movie-segment-003.mkv");
    double[] separate_durations = runner.compute_fallback_durations_for_test (
        separate_outputs,
        true
    );

    assert_int_equal (separate_durations.length, 3,
        "separate collage fallback duration count");
    assert_double_equal (separate_durations[0], 5.5,
        "separate collage fallback uses first segment duration");
    assert_double_equal (separate_durations[1], 4.0,
        "separate collage fallback uses second segment duration");
    assert_double_equal (separate_durations[2], 9.25,
        "separate collage fallback uses third segment duration");
}

private void test_trim_collage_output_results_preserve_primary_outputs () {
    var runner = new TrimRunner ();

    var single_primary = new GenericArray<string> ();
    single_primary.add ("/tmp/movie-trimmed.mkv");
    var no_collages = new GenericArray<string> ();

    OperationOutputResult single_result =
        runner.build_export_output_result_for_test (
            single_primary,
            no_collages,
            "/tmp",
            false
        );
    assert_output_kind_equal (single_result.kind, OperationOutputKind.FILE,
        "single trim output without collage stays a file result");
    assert_string_equal (single_result.primary_file_path, "/tmp/movie-trimmed.mkv",
        "single trim output primary path");
    assert_int_equal (single_result.output_paths.length, 1,
        "single trim output path count");
    assert_string_equal (single_result.output_paths[0], "/tmp/movie-trimmed.mkv",
        "single trim output path");

    var single_collages = new GenericArray<string> ();
    single_collages.add ("/tmp/movie-trimmed-collage.png");
    OperationOutputResult single_with_collage =
        runner.build_export_output_result_for_test (
            single_primary,
            single_collages,
            "/tmp",
            false
        );
    assert_output_kind_equal (single_with_collage.kind, OperationOutputKind.MULTIPLE_FILES,
        "single trim output plus collage becomes a multi-file result");
    assert_string_equal (single_with_collage.primary_file_path, "/tmp/movie-trimmed.mkv",
        "single trim output plus collage keeps video primary");
    assert_int_equal (single_with_collage.output_paths.length, 2,
        "single trim output plus collage path count");
    assert_string_equal (single_with_collage.output_paths[0], "/tmp/movie-trimmed.mkv",
        "single trim output plus collage first path");
    assert_string_equal (single_with_collage.output_paths[1], "/tmp/movie-trimmed-collage.png",
        "single trim output plus collage second path");

    var separate_primary = new GenericArray<string> ();
    separate_primary.add ("/tmp/movie-segment-001.mkv");
    separate_primary.add ("/tmp/movie-segment-002.mkv");

    OperationOutputResult separate_without_collages =
        runner.build_export_output_result_for_test (
            separate_primary,
            no_collages,
            "/tmp",
            true
        );
    assert_output_kind_equal (
        separate_without_collages.kind,
        OperationOutputKind.MULTIPLE_FILES,
        "separate trim output without collage stays a multi-file result"
    );
    assert_string_equal (separate_without_collages.open_folder_path, "/tmp",
        "separate trim output open folder");
    assert_int_equal (separate_without_collages.output_paths.length, 2,
        "separate trim output path count");

    var separate_collages = new GenericArray<string> ();
    separate_collages.add ("/tmp/movie-segment-001-collage.png");
    separate_collages.add ("/tmp/movie-segment-002-collage.png");
    OperationOutputResult separate_with_collages =
        runner.build_export_output_result_for_test (
            separate_primary,
            separate_collages,
            "/tmp",
            true
        );
    assert_output_kind_equal (
        separate_with_collages.kind,
        OperationOutputKind.MULTIPLE_FILES,
        "separate trim output plus collages is a multi-file result"
    );
    assert_string_equal (separate_with_collages.primary_file_path,
        "/tmp/movie-segment-001.mkv",
        "separate trim output plus collages keeps first video primary");
    assert_int_equal (separate_with_collages.output_paths.length, 4,
        "separate trim output plus collages path count");
    assert_string_equal (separate_with_collages.output_paths[0],
        "/tmp/movie-segment-001.mkv",
        "separate trim output plus collages first video path");
    assert_string_equal (separate_with_collages.output_paths[2],
        "/tmp/movie-segment-001-collage.png",
        "separate trim output plus collages first collage path");
}

private void test_trim_image_watermark_preserves_segment_duration () {
    string tmp_dir;
    try {
        tmp_dir = DirUtils.make_tmp ("ffmpeg-trim-image-watermark-XXXXXX");
    } catch (Error e) {
        Test.fail_printf ("failed to create temp directory: %s", e.message);
        return;
    }

    try {
        string input_path = resolve_test_asset_path ("test_dvd.vob");
        string output_path = Path.build_filename (tmp_dir, "trimmed.mkv");
        string watermark_path = resolve_test_asset_path ("watermarktestimage.jpg");

        var runner = new TrimRunner ();
        runner.input_file = input_path;
        runner.copy_mode = false;

        var segments = new GenericArray<TrimSegment> ();
        segments.add (new TrimSegment (1.0, 3.0));
        runner.set_segments (segments);

        var profile = new EncodeProfileSnapshot ();
        profile.container = ContainerExt.MKV;
        profile.codec_args = { "-c:v", "libx264", "-crf", "23" };
        profile.audio_args = { "-c:a", "aac", "-b:a", "128k" };
        profile.watermark_enabled = true;
        profile.watermark_mode = "image";
        profile.watermark_image_path = watermark_path;
        profile.watermark_image_width = 120;
        profile.watermark_position = "Bottom Right";
        profile.watermark_opacity = 1.0;
        profile.watermark_margin = 10;
        runner.reencode_profile = profile;

        int exit_code = runner.run_extract_segment_for_widget_test (0, output_path);
        assert_true (exit_code == 0, "trim image watermark extract exit code");

        double duration = probe_media_duration_seconds (
            output_path,
            "trim image watermark duration probe");
        assert_true (Math.fabs (duration - 2.0) < 0.2,
            "trim image watermark preserves requested segment duration");
    } finally {
        cleanup_exec_test_dir (tmp_dir);
    }
}

/**
 * A speed filter must not move the segment's end point.
 *
 * The segment's start is selected on the input with -ss, so the limit that
 * closes it has to be an input option too. As an output option it lands after
 * the filter chain, where a speed filter has already rewritten the timestamps
 * it would be compared against — which put the two ends of one segment on
 * different clocks. A 2s segment at 0.5x came out 2s long instead of 4s, with
 * the back half of the range silently missing, and at 2x it ran past the end
 * point to EOF instead of stopping.
 *
 * Both directions are checked because they fail in opposite ways, and neither
 * is visible in the output: the file plays cleanly and stays in sync, it just
 * is not the range that was asked for.
 */
private void test_trim_speed_filter_preserves_segment_range () {
    string tmp_dir;
    try {
        tmp_dir = DirUtils.make_tmp ("ffmpeg-trim-speed-XXXXXX");
    } catch (Error e) {
        Test.fail_printf ("failed to create temp directory: %s", e.message);
        return;
    }

    try {
        string input_path = resolve_test_asset_path ("test_dvd.vob");

        // 0.5x — the segment must stretch to twice its source span, not stay
        // put and lose its tail.
        string slow_path = Path.build_filename (tmp_dir, "slow.mkv");
        var slow_runner = new TrimRunner ();
        slow_runner.input_file = input_path;
        slow_runner.copy_mode = false;

        var slow_segments = new GenericArray<TrimSegment> ();
        slow_segments.add (new TrimSegment (1.0, 3.0));
        slow_runner.set_segments (slow_segments);

        var slow_profile = new EncodeProfileSnapshot ();
        slow_profile.container = ContainerExt.MKV;
        slow_profile.codec_args = { "-c:v", "libx264", "-crf", "23" };
        slow_profile.audio_args = { "-c:a", "aac", "-b:a", "128k" };
        slow_profile.video_filters_skip_delogo = "setpts=2.000000*PTS";
        slow_profile.audio_filters = "atempo=0.500000";
        slow_runner.reencode_profile = slow_profile;

        int slow_exit = slow_runner.run_extract_segment_for_widget_test (
            0, slow_path);
        assert_true (slow_exit == 0, "slowed segment extract exit code");

        string[] slow_argv = slow_runner.get_last_ffmpeg_argv_for_widget_test ();
        assert_array_not_contains (slow_argv, "-to",
            "slowed segment bounds the input rather than the output");

        double slow_duration = probe_media_duration_seconds (
            slow_path, "slowed segment duration probe");
        assert_true (Math.fabs (slow_duration - 4.0) < 0.3,
            "0.5x keeps the whole 2s segment and stretches it to 4s");

        // 2x — the segment must compress to half its span and stop at its end
        // point, rather than running on to EOF.
        string fast_path = Path.build_filename (tmp_dir, "fast.mkv");
        var fast_runner = new TrimRunner ();
        fast_runner.input_file = input_path;
        fast_runner.copy_mode = false;

        var fast_segments = new GenericArray<TrimSegment> ();
        fast_segments.add (new TrimSegment (1.0, 3.0));
        fast_runner.set_segments (fast_segments);

        var fast_profile = new EncodeProfileSnapshot ();
        fast_profile.container = ContainerExt.MKV;
        fast_profile.codec_args = { "-c:v", "libx264", "-crf", "23" };
        fast_profile.audio_args = { "-c:a", "aac", "-b:a", "128k" };
        fast_profile.video_filters_skip_delogo = "setpts=0.500000*PTS";
        fast_profile.audio_filters = "atempo=2.000000";
        fast_runner.reencode_profile = fast_profile;

        int fast_exit = fast_runner.run_extract_segment_for_widget_test (
            0, fast_path);
        assert_true (fast_exit == 0, "sped-up segment extract exit code");

        double fast_duration = probe_media_duration_seconds (
            fast_path, "sped-up segment duration probe");
        assert_true (Math.fabs (fast_duration - 1.0) < 0.3,
            "2x stops at the segment end instead of running to EOF");

        // Without a speed filter the two forms agree, so the ordinary path
        // must be untouched by the move.
        string plain_path = Path.build_filename (tmp_dir, "plain.mkv");
        var plain_runner = new TrimRunner ();
        plain_runner.input_file = input_path;
        plain_runner.copy_mode = false;

        var plain_segments = new GenericArray<TrimSegment> ();
        plain_segments.add (new TrimSegment (1.0, 3.0));
        plain_runner.set_segments (plain_segments);

        var plain_profile = new EncodeProfileSnapshot ();
        plain_profile.container = ContainerExt.MKV;
        plain_profile.codec_args = { "-c:v", "libx264", "-crf", "23" };
        plain_profile.audio_args = { "-c:a", "aac", "-b:a", "128k" };
        plain_runner.reencode_profile = plain_profile;

        int plain_exit = plain_runner.run_extract_segment_for_widget_test (
            0, plain_path);
        assert_true (plain_exit == 0, "unmodified segment extract exit code");

        double plain_duration = probe_media_duration_seconds (
            plain_path, "unmodified segment duration probe");
        assert_true (Math.fabs (plain_duration - 2.0) < 0.2,
            "a segment without a speed filter still spans its source range");
    } finally {
        cleanup_exec_test_dir (tmp_dir);
    }
}

private TrimRunner make_segment_speed_runner_for_test (string input_path,
                                                       TrimSegment segment,
                                                       string global_setpts = "",
                                                       string global_atempo = "") {
    var runner = new TrimRunner ();
    runner.input_file = input_path;
    runner.copy_mode = true;   // the segment's own speed must override this

    var segs = new GenericArray<TrimSegment> ();
    segs.add (segment);
    runner.set_segments (segs);

    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "23" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "128k" };
    profile.video_filters_skip_delogo = global_setpts;
    profile.audio_filters = global_atempo;
    runner.reencode_profile = profile;

    return runner;
}

/**
 * A segment's own speed stretches or compresses it, and both streams land on
 * the same length — that shared length is the entire point of driving video and
 * audio from one control.
 */
private void test_trim_segment_speed_scales_both_streams () {
    string tmp_dir;
    try {
        tmp_dir = DirUtils.make_tmp ("ffmpeg-trim-segment-speed-XXXXXX");
    } catch (Error e) {
        Test.fail_printf ("failed to create temp directory: %s", e.message);
        return;
    }

    try {
        string input_path = resolve_test_asset_path ("test_dvd.vob");

        // −50% — a 2s segment becomes 4s.
        var slow_segment = new TrimSegment (1.0, 3.0);
        slow_segment.speed_percent = -50.0;
        assert_true (slow_segment.has_speed_change (),
            "−50% counts as a speed change");

        string slow_path = Path.build_filename (tmp_dir, "slow.mkv");
        var slow_runner = make_segment_speed_runner_for_test (
            input_path, slow_segment);

        int slow_exit = slow_runner.run_extract_segment_for_widget_test (
            0, slow_path);
        assert_true (slow_exit == 0, "slowed segment extract exit code");

        string[] slow_argv = slow_runner.get_last_ffmpeg_argv_for_widget_test ();
        assert_array_has_adjacent_pair (slow_argv, "-c:v", "libx264",
            "a segment speed forces a re-encode even in copy mode");
        assert_array_not_contains (slow_argv, "-to",
            "a sped segment bounds the input rather than the output");

        double slow_video = probe_stream_duration_seconds (
            slow_path, "v:0", "slowed segment video duration");
        double slow_audio = probe_stream_duration_seconds (
            slow_path, "a:0", "slowed segment audio duration");
        assert_true (Math.fabs (slow_video - 4.0) < 0.3,
            "−50% stretches the 2s segment to 4s of video");
        assert_true (Math.fabs (slow_audio - 4.0) < 0.3,
            "−50% stretches the 2s segment to 4s of audio");
        assert_true (Math.fabs (slow_video - slow_audio) < 0.2,
            "video and audio stay the same length at −50%");

        // +100% — the same segment becomes 1s, and stops there rather than
        // running on to EOF.
        var fast_segment = new TrimSegment (1.0, 3.0);
        fast_segment.speed_percent = 100.0;

        string fast_path = Path.build_filename (tmp_dir, "fast.mkv");
        var fast_runner = make_segment_speed_runner_for_test (
            input_path, fast_segment);

        int fast_exit = fast_runner.run_extract_segment_for_widget_test (
            0, fast_path);
        assert_true (fast_exit == 0, "sped-up segment extract exit code");

        double fast_video = probe_stream_duration_seconds (
            fast_path, "v:0", "sped-up segment video duration");
        double fast_audio = probe_stream_duration_seconds (
            fast_path, "a:0", "sped-up segment audio duration");
        assert_true (Math.fabs (fast_video - 1.0) < 0.3,
            "+100% compresses the 2s segment to 1s of video");
        assert_true (Math.fabs (fast_audio - 1.0) < 0.3,
            "+100% compresses the 2s segment to 1s of audio");
        assert_true (Math.fabs (fast_video - fast_audio) < 0.2,
            "video and audio stay the same length at +100%");

        // 0% leaves the segment alone. Asserted on the decision rather than on
        // an export, because stream-copying this asset into Matroska fails on
        // its unset timestamps for reasons that have nothing to do with speed.
        var plain_segment = new TrimSegment (1.0, 3.0);
        assert_false (plain_segment.has_speed_change (),
            "0% is not a speed change");
        assert_double_equal (plain_segment.get_speed_multiplier (), 1.0,
            "0% resolves to source speed");
        assert_double_equal (plain_segment.get_output_duration (), 2.0,
            "a segment at source speed keeps its span");
    } finally {
        cleanup_exec_test_dir (tmp_dir);
    }
}

/**
 * A segment speed stacks with the General tab's rather than replacing it, so a
 * 0.5x segment under a 2x global comes back out at source speed.
 */
private void test_trim_segment_speed_stacks_with_general_tab () {
    string tmp_dir;
    try {
        tmp_dir = DirUtils.make_tmp ("ffmpeg-trim-speed-stack-XXXXXX");
    } catch (Error e) {
        Test.fail_printf ("failed to create temp directory: %s", e.message);
        return;
    }

    try {
        string input_path = resolve_test_asset_path ("test_dvd.vob");

        var segment = new TrimSegment (1.0, 3.0);
        segment.speed_percent = -50.0;

        string output_path = Path.build_filename (tmp_dir, "stacked.mkv");
        var runner = make_segment_speed_runner_for_test (
            input_path, segment, "setpts=0.500000*PTS", "atempo=2.000000");

        int exit = runner.run_extract_segment_for_widget_test (0, output_path);
        assert_true (exit == 0, "stacked speed extract exit code");

        double video = probe_stream_duration_seconds (
            output_path, "v:0", "stacked video duration");
        double audio = probe_stream_duration_seconds (
            output_path, "a:0", "stacked audio duration");
        assert_true (Math.fabs (video - 2.0) < 0.3,
            "0.5x segment under a 2x global comes out at source speed");
        assert_true (Math.fabs (video - audio) < 0.2,
            "stacking keeps video and audio on the same length");
    } finally {
        cleanup_exec_test_dir (tmp_dir);
    }
}

/**
 * The speed setpts has to sit behind logo removal. delogo's timed regions match
 * on the segment-local clock, so a setpts ahead of them would rewrite the very
 * timestamps their intervals are tested against.
 */
private void test_trim_segment_speed_follows_logo_removal () {
    var runner = new TrimRunner ();
    runner.reencode_profile = make_logo_removal_profile_for_test ();

    var seg = new TrimSegment (1.0, 3.0);
    seg.speed_percent = -50.0;

    string vf = runner.build_segment_vf_for_test (seg);
    assert_string_equal (vf,
        "delogo=x=1:y=1:w=170:h=218,crop=640:480:0:0,"
        + "scale=1280:-2:flags=lanczos,setpts=2.000000*PTS",
        "segment speed is appended to the tail of the chain");

    int delogo_pos = vf.index_of ("delogo=");
    int setpts_pos = vf.index_of ("setpts=");
    assert_true (delogo_pos >= 0, "segment chain keeps logo removal");
    assert_true (setpts_pos > delogo_pos,
        "segment speed never precedes logo removal");

    // No profile at all — the copy-mode-with-crop path still has to carry the
    // speed, because a speed alone is enough to force a re-encode.
    var bare_runner = new TrimRunner ();
    var bare_seg = new TrimSegment (1.0, 3.0);
    bare_seg.speed_percent = 100.0;
    assert_string_equal (bare_runner.build_segment_vf_for_test (bare_seg),
        "setpts=0.500000*PTS",
        "a speed change survives a missing re-encode profile");

    var unchanged = new TrimSegment (1.0, 3.0);
    assert_string_equal (bare_runner.build_segment_vf_for_test (unchanged), "",
        "a segment at source speed adds no filter");
}

/**
 * afade runs downstream of every speed filter, so its start has to be measured
 * on the post-speed timeline. Handed the source span instead, a fade-out on a
 * shortened track lands past the end and never fires.
 */
private void test_trim_segment_fade_out_follows_output_timeline () {
    string input_path = resolve_test_asset_path ("test_dvd.vob");

    var runner = new TrimRunner ();
    runner.input_file = input_path;

    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.audio_args = { "-c:a", "aac", "-b:a", "128k" };
    profile.audio_processing.fade_out_enabled = true;
    profile.audio_processing.fade_out_duration = 1.0;
    runner.reencode_profile = profile;

    // Baseline: no speed anywhere, so the fade sits one second before the end
    // of a ten-second segment.
    var plain_segs = new GenericArray<TrimSegment> ();
    plain_segs.add (new TrimSegment (0.0, 10.0));
    runner.set_segments (plain_segs);

    string[] plain_cmd = runner.build_peak_detect_command_for_widget_test (0);
    assert_contains (get_argv_value_after (plain_cmd, "-af", "plain fade chain"),
        "afade=t=out:st=9.00", "fade-out sits one second before a 10s segment");

    // The General tab's speed alone: the track is 5s of output, so the fade
    // belongs at 4s. This is the case that was silently broken.
    var global_runner = new TrimRunner ();
    global_runner.input_file = input_path;
    var global_profile = new EncodeProfileSnapshot ();
    global_profile.container = ContainerExt.MKV;
    global_profile.audio_args = { "-c:a", "aac", "-b:a", "128k" };
    global_profile.audio_filters = "atempo=2.000000";
    global_profile.audio_speed_multiplier = 2.0;
    global_profile.audio_processing.fade_out_enabled = true;
    global_profile.audio_processing.fade_out_duration = 1.0;
    global_runner.reencode_profile = global_profile;

    var global_segs = new GenericArray<TrimSegment> ();
    global_segs.add (new TrimSegment (0.0, 10.0));
    global_runner.set_segments (global_segs);

    string global_chain = get_argv_value_after (
        global_runner.build_peak_detect_command_for_widget_test (0),
        "-af", "global speed fade chain");
    assert_contains (global_chain, "afade=t=out:st=4.00",
        "a 2x global speed puts the fade at 4s, not past the end of a 5s track");

    // A segment speed has to be counted the same way, and stack with it: 2x
    // global on top of 2x segment is a 2.5s track, so the fade starts at 1.5s.
    var segment_runner = new TrimRunner ();
    segment_runner.input_file = input_path;
    segment_runner.reencode_profile = global_profile;

    var sped = new TrimSegment (0.0, 10.0);
    sped.speed_percent = 100.0;
    var sped_segs = new GenericArray<TrimSegment> ();
    sped_segs.add (sped);
    segment_runner.set_segments (sped_segs);

    string sped_chain = get_argv_value_after (
        segment_runner.build_peak_detect_command_for_widget_test (0),
        "-af", "stacked speed fade chain");
    assert_contains (sped_chain, "afade=t=out:st=1.50",
        "segment and global speed stack when the fade is placed");
    assert_contains (sped_chain, "atempo=2.000000,atempo=2.000000",
        "the segment's atempo joins the General tab's at the head of the chain");
}

/** Cloning a segment carries every field, not just the ones a call site recalls. */
private void test_trim_segment_copy_preserves_all_fields () {
    var finite = new TrimSegment (2.0, 8.0);
    finite.crop_value = "640:480:0:0";
    finite.label = "Chapter 3";
    finite.speed_percent = -25.0;

    var finite_copy = finite.copy ();
    assert_double_equal (finite_copy.start_time, 2.0, "copied start time");
    assert_double_equal (finite_copy.end_time, 8.0, "copied end time");
    assert_string_equal (finite_copy.crop_value, "640:480:0:0", "copied crop");
    assert_string_equal (finite_copy.label, "Chapter 3", "copied label");
    assert_double_equal (finite_copy.speed_percent, -25.0, "copied speed");
    assert_true (finite_copy.has_finite_end (), "copied finite end");

    // The one that used to be dropped: a through-EOF range reconstructed by
    // hand becomes a zero-length export.
    var through_eof = TrimSegment.through_end_of_file (5.0);
    var eof_copy = through_eof.copy ();
    assert_false (eof_copy.has_finite_end (),
        "copying preserves a through-EOF range");
}

private void test_trim_crop_through_eof_omits_duration_limit () {
    string tmp_dir;
    try {
        tmp_dir = DirUtils.make_tmp ("ffmpeg-trim-through-eof-XXXXXX");
    } catch (Error e) {
        Test.fail_printf ("failed to create temp directory: %s", e.message);
        return;
    }

    try {
        string input_path = resolve_test_asset_path ("test_dvd.vob");
        string output_path = Path.build_filename (tmp_dir, "cropped-through-eof.mkv");

        var runner = new TrimRunner ();
        runner.input_file = input_path;
        runner.copy_mode = false;

        var segment = TrimSegment.through_end_of_file ();
        segment.crop_value = "320:240:0:0";
        var segments = new GenericArray<TrimSegment> ();
        segments.add (segment);
        runner.set_segments (segments);

        var profile = new EncodeProfileSnapshot ();
        profile.container = ContainerExt.MKV;
        profile.codec_args = { "-c:v", "libx264", "-crf", "23" };
        profile.audio_args = { "-c:a", "aac" };
        profile.audio_processing.fade_out_enabled = true;
        profile.audio_processing.fade_out_duration = 0.5;
        runner.reencode_profile = profile;

        int exit_code = runner.run_extract_segment_for_widget_test (0, output_path);
        assert_true (exit_code == 0,
            "unknown-duration full-file crop reaches EOF successfully");
        string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();
        assert_array_not_contains (argv,
            "-to", "unknown-duration full-file crop omits FFmpeg duration limit");
        assert_array_not_contains (argv,
            "-t", "unknown-duration full-file crop omits FFmpeg duration option");
        string audio_filters = get_argv_value_after (
            argv, "-af", "unknown-duration full-file crop audio filters");
        assert_contains (audio_filters, "afade=t=out:",
            "unknown-duration full-file crop preserves requested audio fade-out");

        double input_duration = probe_media_duration_seconds (
            input_path, "through-EOF input duration probe");
        double output_duration = probe_media_duration_seconds (
            output_path, "through-EOF output duration probe");
        assert_true (Math.fabs (output_duration - input_duration) < 0.3,
            "unknown-duration full-file crop preserves the complete input");
    } finally {
        cleanup_exec_test_dir (tmp_dir);
    }
}

private void test_trim_image_watermark_export_maps_first_audio_only () {
    string tmp_dir;
    try {
        tmp_dir = DirUtils.make_tmp ("ffmpeg-trim-image-watermark-map-XXXXXX");
    } catch (Error e) {
        Test.fail_printf ("failed to create temp directory: %s", e.message);
        return;
    }

    try {
        string input_path = resolve_test_asset_path ("test_dvd.vob");
        string output_path = Path.build_filename (tmp_dir, "trimmed-map-check.mkv");
        string watermark_path = resolve_test_asset_path ("watermarktestimage.jpg");

        var runner = new TrimRunner ();
        runner.input_file = input_path;
        runner.copy_mode = false;

        var segments = new GenericArray<TrimSegment> ();
        segments.add (new TrimSegment (1.0, 3.0));
        runner.set_segments (segments);
        runner.reencode_profile = make_trim_reencode_profile_for_test (watermark_path);

        int exit_code = runner.run_extract_segment_for_widget_test (0, output_path);
        assert_true (exit_code == 0, "trim image watermark export exit code");

        string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();
        assert_array_has_adjacent_pair (argv, "-map", "[outv]",
            "trim image watermark export maps filtered video output");
        assert_array_has_adjacent_pair (argv, "-map", "0:a:0?",
            "trim image watermark export maps only the first audio stream");
        assert_array_not_contains (argv, "0:a?",
            "trim image watermark export should not map all audio streams");
    } finally {
        cleanup_exec_test_dir (tmp_dir);
    }
}

private void test_trim_smart_segment_preserves_recommended_10bit_overlay () {
    string tmp_dir;
    try {
        tmp_dir = DirUtils.make_tmp ("ffmpeg-trim-smart-overlay-XXXXXX");
    } catch (Error e) {
        Test.fail_printf ("failed to create temp directory: %s", e.message);
        return;
    }

    try {
        string input_path = resolve_test_asset_path ("test_dvd.vob");
        string output_path = Path.build_filename (tmp_dir, "smart-overlay.mkv");
        string watermark_path = resolve_test_asset_path ("watermarktestimage.jpg");

        var runner = new TrimRunner ();
        runner.input_file = input_path;
        runner.copy_mode = false;

        var segments = new GenericArray<TrimSegment> ();
        segments.add (new TrimSegment (1.0, 2.0));
        runner.set_segments (segments);
        runner.reencode_profile =
            make_trim_reencode_profile_for_test (watermark_path);
        runner.reencode_profile.video_filters_skip_delogo =
            "scale=iw:ih,format=" + PixelFormat.YUV420P;
        runner.reencode_profile.video_filters_skip_crop_and_delogo =
            runner.reencode_profile.video_filters_skip_delogo;

        var smart_args = new GenericArray<SegmentCodecArgs> ();
        smart_args.add (new SegmentCodecArgs (
            { "-c:v", "ffv1", "-pix_fmt", PixelFormat.YUV420P10LE },
            PixelFormat.YUV420P10LE));
        runner.set_per_segment_codec_args (smart_args);

        int exit_code = runner.run_extract_segment_for_widget_test (0, output_path);
        assert_true (exit_code == 0,
            "Smart Trim 10-bit watermark export exit code");

        string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();
        string filter_complex = get_filter_complex_from_argv (
            argv, "Smart Trim 10-bit watermark export");
        assert_contains (filter_complex, "format=yuv420p10le[vf_out]",
            "Smart Trim normalizes decoded frames to the recommended depth");
        assert_false (filter_complex.contains ("format=yuv420p,"),
            "Smart Trim does not first discard precision through stale 8-bit output");
        assert_contains (filter_complex, ":format=yuv420p10[outv]",
            "Smart Trim carries the recommendation through the overlay");
        assert_array_has_adjacent_pair (argv, "-pix_fmt", PixelFormat.YUV420P10LE,
            "Smart Trim retains the recommendation in encoder arguments");
    } finally {
        cleanup_exec_test_dir (tmp_dir);
    }
}

private void test_trim_peak_detect_maps_first_audio_only () {
    string input_path = resolve_test_asset_path ("test_dvd.vob");
    string watermark_path = resolve_test_asset_path ("watermarktestimage.jpg");

    var runner = new TrimRunner ();
    runner.input_file = input_path;

    var segments = new GenericArray<TrimSegment> ();
    segments.add (new TrimSegment (1.0, 3.0));
    runner.set_segments (segments);
    runner.reencode_profile = make_trim_reencode_profile_for_test (watermark_path);

    string[] argv = runner.build_peak_detect_command_for_widget_test (0);
    assert_array_has_adjacent_pair (argv, "-map", "0:a:0?",
        "trim peak detect maps only the first audio stream");
    assert_array_not_contains (argv, "0:a?",
        "trim peak detect should not map all audio streams");
}

private void test_subtitle_peak_detect_toggle_off_maps_first_audio_only () {
    string input_path = resolve_test_asset_path ("test2.vob");

    var runner = new SubtitlesRunner ();
    var profile = make_subtitle_burn_in_profile_for_test (false);

    string[] argv = runner.build_peak_detect_command_for_widget_test (
        input_path,
        profile,
        120.0);

    assert_array_has_adjacent_pair (argv, "-map", "0:a:0?",
        "subtitle peak detect maps only the first audio stream when toggle is off");
    assert_array_not_contains (argv, "0:a?",
        "subtitle peak detect should not map all audio streams when toggle is off");
}

private void test_subtitle_peak_detect_toggle_on_maps_all_audio () {
    string input_path = resolve_test_asset_path ("test2.vob");

    var runner = new SubtitlesRunner ();
    var profile = make_subtitle_burn_in_profile_for_test (true);

    string[] argv = runner.build_peak_detect_command_for_widget_test (
        input_path,
        profile,
        120.0);

    assert_array_has_adjacent_pair (argv, "-map", "0:a?",
        "subtitle peak detect maps all audio streams when toggle is on");
    assert_array_not_contains (argv, "0:a:0?",
        "subtitle peak detect should not map only the first audio stream when toggle is on");
}

private void test_subtitle_burn_in_bitmap_image_watermark_toggle_off_topology () {
    string input_path = resolve_test_asset_path ("test2.vob");
    string sub_path = "/tmp/eng-test-sub.sup";
    string watermark_path = resolve_test_asset_path ("watermarktestimage.jpg");

    var runner = new SubtitlesRunner ();
    var profile = make_subtitle_burn_in_profile_for_test (false, watermark_path);
    profile.overlay_format = "yuv420p10";

    string[] argv = runner.build_burn_in_command_for_widget_test (
        input_path,
        "/tmp/subtitle-burnin-image-wm.mkv",
        -1,
        sub_path,
        true,
        profile,
        120.0);

    assert_array_has_adjacent_pair (argv, "-i", input_path,
        "subtitle burn-in includes primary input");
    assert_array_has_adjacent_pair (argv, "-i", sub_path,
        "subtitle burn-in includes external bitmap subtitle input");
    assert_array_has_adjacent_pair (argv, "-i", watermark_path,
        "subtitle burn-in includes watermark image input");
    assert_toggle_aware_audio_mapping (argv, "[outv]", false,
        "bitmap subtitle burn-in with image watermark");

    string filter_complex = get_filter_complex_from_argv (argv,
        "bitmap subtitle burn-in with image watermark");

    assert_contains (filter_complex,
        "[0:v][1:0]overlay=format=yuv420p10[subbedv]",
        "subtitle burn-in preserves 10-bit while overlaying bitmap subtitles");
    assert_contains (filter_complex, "[subbedv]zscale=",
        "subtitle burn-in applies general video filters after subtitle overlay");
    assert_contains (filter_complex, "[2:v]scale=120:-1",
        "subtitle burn-in uses watermark image as third input");
    assert_contains (filter_complex, "colorchannelmixer=aa=0.85",
        "subtitle burn-in applies watermark opacity");
    assert_contains (filter_complex,
        "overlay=x=main_w-overlay_w-10:y=10:format=yuv420p10[outv]",
        "subtitle burn-in preserves 10-bit through the watermark overlay");
}

private void test_subtitle_burn_in_bitmap_image_watermark_toggle_on_topology () {
    string input_path = resolve_test_asset_path ("test2.vob");
    string sub_path = "/tmp/eng-test-sub.sup";
    string watermark_path = resolve_test_asset_path ("watermarktestimage.jpg");

    var runner = new SubtitlesRunner ();
    var profile = make_subtitle_burn_in_profile_for_test (true, watermark_path);

    string[] argv = runner.build_burn_in_command_for_widget_test (
        input_path,
        "/tmp/subtitle-burnin-image-wm-all-audio.mkv",
        -1,
        sub_path,
        true,
        profile,
        120.0);

    assert_array_has_adjacent_pair (argv, "-i", watermark_path,
        "bitmap subtitle burn-in includes watermark image input when toggle is on");
    assert_toggle_aware_audio_mapping (argv, "[outv]", true,
        "bitmap subtitle burn-in with image watermark");
}

private void test_subtitle_burn_in_text_image_watermark_toggle_off_topology () {
    string input_path = resolve_test_asset_path ("test2.vob");
    string watermark_path = resolve_test_asset_path ("watermarktestimage.jpg");
    string sub_path = resolve_test_asset_path ("eng-test-sub.srt");

    var runner = new SubtitlesRunner ();
    var profile = make_subtitle_burn_in_profile_for_test (false, watermark_path);

    string[] argv = runner.build_burn_in_command_for_widget_test (
        input_path,
        "/tmp/subtitle-burnin-text-image-wm.mkv",
        -1,
        sub_path,
        false,
        profile,
        120.0);

    assert_array_has_adjacent_pair (argv, "-i", input_path,
        "text subtitle burn-in includes primary input");
    assert_array_has_adjacent_pair (argv, "-i", watermark_path,
        "text subtitle burn-in includes watermark image input");
    assert_toggle_aware_audio_mapping (argv, "[outv]", false,
        "text subtitle burn-in with image watermark");

    int input_count = 0;
    bool has_vf = false;
    string filter_complex = get_filter_complex_from_argv (argv,
        "text subtitle burn-in with image watermark");
    for (int i = 0; i < argv.length; i++) {
        if (argv[i] == "-i") input_count++;
        if (argv[i] == "-vf") has_vf = true;
    }

    assert_true (input_count == 2,
        "text subtitle burn-in uses only main video and watermark inputs");
    assert_false (has_vf,
        "text subtitle burn-in switches to filter_complex when image watermark is active");
    assert_contains (filter_complex, "[0:v]subtitles=",
        "text subtitle burn-in renders subtitles from a filter graph");
    assert_contains (filter_complex, "eng-test-sub.srt",
        "text subtitle burn-in references the real srt fixture");
    assert_contains (filter_complex, ",zscale=",
        "text subtitle burn-in applies general video filters after subtitle render");
    assert_contains (filter_complex, "filter=lanczos[subbedv];",
        "text subtitle burn-in labels filtered subtitle video before watermark overlay");
    assert_contains (filter_complex, "[1:v]scale=120:-1",
        "text subtitle burn-in uses watermark image as second input");
    assert_contains (filter_complex, "colorchannelmixer=aa=0.85",
        "text subtitle burn-in applies watermark opacity");
    assert_contains (filter_complex, "overlay=x=main_w-overlay_w-10:y=10[outv]",
        "text subtitle burn-in overlays watermark at requested position");
}

private void test_subtitle_burn_in_text_image_watermark_toggle_on_topology () {
    string input_path = resolve_test_asset_path ("test2.vob");
    string watermark_path = resolve_test_asset_path ("watermarktestimage.jpg");
    string sub_path = resolve_test_asset_path ("eng-test-sub.srt");

    var runner = new SubtitlesRunner ();
    var profile = make_subtitle_burn_in_profile_for_test (true, watermark_path);

    string[] argv = runner.build_burn_in_command_for_widget_test (
        input_path,
        "/tmp/subtitle-burnin-text-image-wm-all-audio.mkv",
        -1,
        sub_path,
        false,
        profile,
        120.0);

    assert_toggle_aware_audio_mapping (argv, "[outv]", true,
        "text subtitle burn-in with image watermark");
}

private void test_subtitle_burn_in_bitmap_no_watermark_toggle_off_topology () {
    string input_path = resolve_test_asset_path ("test2.vob");
    string sub_path = "/tmp/eng-test-sub.sup";

    var runner = new SubtitlesRunner ();
    var profile = make_subtitle_burn_in_profile_for_test (false);

    string[] argv = runner.build_burn_in_command_for_widget_test (
        input_path,
        "/tmp/subtitle-burnin-bitmap-no-wm.mkv",
        -1,
        sub_path,
        true,
        profile,
        120.0);

    assert_toggle_aware_audio_mapping (argv, "[outv]", false,
        "bitmap subtitle burn-in without watermark");

    int input_count = 0;
    foreach (string arg in argv) {
        if (arg == "-i") input_count++;
    }
    assert_int_equal (input_count, 2,
        "bitmap subtitle burn-in without watermark uses only main video and subtitle inputs");

    string filter_complex = get_filter_complex_from_argv (argv,
        "bitmap subtitle burn-in without watermark");
    assert_contains (filter_complex, "[0:v][1:0]overlay[subbedv]",
        "bitmap subtitle burn-in without watermark overlays subtitles before video filters");
    assert_contains (filter_complex, "[subbedv]zscale=",
        "bitmap subtitle burn-in without watermark keeps general video filters");
}

private void test_subtitle_burn_in_bitmap_no_watermark_toggle_on_topology () {
    string input_path = resolve_test_asset_path ("test2.vob");
    string sub_path = "/tmp/eng-test-sub.sup";

    var runner = new SubtitlesRunner ();
    var profile = make_subtitle_burn_in_profile_for_test (true);

    string[] argv = runner.build_burn_in_command_for_widget_test (
        input_path,
        "/tmp/subtitle-burnin-bitmap-no-wm-all-audio.mkv",
        -1,
        sub_path,
        true,
        profile,
        120.0);

    assert_toggle_aware_audio_mapping (argv, "[outv]", true,
        "bitmap subtitle burn-in without watermark");
}

private void test_subtitle_burn_in_text_no_watermark_toggle_off_topology () {
    string input_path = resolve_test_asset_path ("test2.vob");
    string sub_path = resolve_test_asset_path ("eng-test-sub.srt");

    var runner = new SubtitlesRunner ();
    var profile = make_subtitle_burn_in_profile_for_test (false);

    string[] argv = runner.build_burn_in_command_for_widget_test (
        input_path,
        "/tmp/subtitle-burnin-text-no-wm.mkv",
        -1,
        sub_path,
        false,
        profile,
        120.0);

    assert_toggle_aware_audio_mapping (argv, "0:v", false,
        "text subtitle burn-in without watermark");
    string vf = get_adjacent_arg_value (argv, "-vf",
        "text subtitle burn-in without watermark");
    assert_contains (vf, "subtitles=",
        "text subtitle burn-in without watermark uses the subtitle filter");
    assert_contains (vf, "eng-test-sub.srt",
        "text subtitle burn-in without watermark references the real srt fixture");
    assert_contains (vf, profile.video_filters,
        "text subtitle burn-in without watermark keeps the general video filters");
    assert_array_not_contains (argv, "-filter_complex",
        "text subtitle burn-in without watermark should stay on the -vf path");
}

private void test_subtitle_burn_in_text_no_watermark_toggle_on_topology () {
    string input_path = resolve_test_asset_path ("test2.vob");
    string sub_path = resolve_test_asset_path ("eng-test-sub.srt");

    var runner = new SubtitlesRunner ();
    var profile = make_subtitle_burn_in_profile_for_test (true);

    string[] argv = runner.build_burn_in_command_for_widget_test (
        input_path,
        "/tmp/subtitle-burnin-text-no-wm-all-audio.mkv",
        -1,
        sub_path,
        false,
        profile,
        120.0);

    assert_toggle_aware_audio_mapping (argv, "0:v", true,
        "text subtitle burn-in without watermark");
    string vf = get_adjacent_arg_value (argv, "-vf",
        "text subtitle burn-in without watermark when toggle is on");
    assert_contains (vf, "subtitles=",
        "text subtitle burn-in without watermark keeps the subtitle filter when toggle is on");
    assert_contains (vf, profile.video_filters,
        "text subtitle burn-in without watermark keeps general video filters when toggle is on");
    assert_array_not_contains (argv, "-filter_complex",
        "text subtitle burn-in without watermark should stay on the -vf path when toggle is on");
}

private void test_subtitle_burn_in_text_image_watermark_executes () {
    string tmp_dir;
    try {
        tmp_dir = DirUtils.make_tmp ("ffmpeg-subtitle-burnin-text-imagewm-XXXXXX");
    } catch (Error e) {
        Test.fail_printf ("failed to create temp directory: %s", e.message);
        return;
    }

    try {
        string input_path = resolve_test_asset_path ("test_dvd.vob");
        string watermark_path = resolve_test_asset_path ("watermarktestimage.jpg");
        string sub_path = resolve_test_asset_path ("eng-test-sub.srt");
        string output_path = Path.build_filename (tmp_dir, "burnin-text-imagewm.mkv");

        var runner = new SubtitlesRunner ();
        var profile = new EncodeProfileSnapshot ();
        profile.container = ContainerExt.MKV;
        profile.codec_args = {
            "-c:v", "libx264",
            "-preset", "ultrafast",
            "-crf", "30"
        };
        profile.audio_args = { "-an" };
        profile.video_filters =
            "zscale=w=trunc(iw*2.000000/2)*2:h=trunc(ih*2.000000/2)*2:filter=lanczos";
        profile.watermark_enabled = true;
        profile.watermark_mode = "image";
        profile.watermark_image_path = watermark_path;
        profile.watermark_image_width = 120;
        profile.watermark_position = "Top Right";
        profile.watermark_opacity = 0.85;
        profile.watermark_margin = 10;

        string[] cmd = runner.build_burn_in_command_for_widget_test (
            input_path,
            output_path,
            -1,
            sub_path,
            false,
            profile,
            4.9658);

        string stdout_buf, stderr_buf;
        int status = run_command_for_test (
            cmd,
            out stdout_buf,
            out stderr_buf,
            "text subtitle burn-in image watermark execute");
        if (status != 0) {
            Test.fail_printf (
                "text subtitle burn-in image watermark execute failed: %s",
                stderr_buf.strip ());
        }

        assert_true (FileUtils.test (output_path, FileTest.EXISTS),
            "text subtitle burn-in execution creates output file");

        double duration = probe_media_duration_seconds (
            output_path,
            "text subtitle burn-in execution duration probe");
        assert_true (duration > 4.0 && duration < 6.0,
            "text subtitle burn-in execution preserves approximate duration");
    } finally {
        cleanup_exec_test_dir (tmp_dir);
    }
}

private void test_trim_chapter_checkbox_updates_model_and_segments () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var tab = new TrimTab ();
    var chapters = new GenericArray<ChapterInfo> ();
    chapters.add (new ChapterInfo (0, "Intro", 0.0, 10.0));
    chapters.add (new ChapterInfo (1, "Middle", 10.0, 20.0));

    tab.load_detected_chapters_for_widget_test (chapters);

    var check = tab.get_chapter_checkbox_for_widget_test (0);
    assert_true (check != null, "trim widget chapter checkbox exists");
    assert_false (chapters[0].selected, "trim widget chapter starts unselected");

    check.set_active (true);

    assert_true (chapters[0].selected, "trim widget chapter toggle updates model");
    assert_int_equal (tab.get_segment_count_for_widget_test (), 1, "trim widget chapter toggle rebuilds segments");
    assert_string_not_equal (
        tab.get_segment_count_label_for_widget_test (),
        "No chapters selected",
        "trim widget chapter toggle updates summary");
}

private void test_trim_move_button_reorders_segments () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var tab = new TrimTab ();
    var segments = new GenericArray<TrimSegment> ();
    segments.add (make_segment (0.0, 5.0, "First"));
    segments.add (make_segment (5.0, 10.0, "Second"));

    tab.load_segments_for_widget_test (segments);

    var move_up = tab.get_segment_move_up_button_for_widget_test (1);
    assert_true (move_up != null, "trim widget move-up button exists");

    move_up.clicked ();

    assert_string_equal (
        tab.get_segment_label_for_widget_test (0),
        "Second",
        "trim widget move-up reorders segments");
}

private void test_trim_drag_drop_reorders_segments () {
    if (!ensure_gtk_widget_tests_available ())
        return;

    var tab = new TrimTab ();
    var segments = new GenericArray<TrimSegment> ();
    segments.add (make_segment (0.0, 5.0, "First"));
    segments.add (make_segment (5.0, 10.0, "Second"));
    segments.add (make_segment (10.0, 15.0, "Third"));

    tab.load_segments_for_widget_test (segments);

    // Drag segment 0 ("First") onto segment 2 ("Third") — should swap
    var result = tab.simulate_segment_drag_drop_for_widget_test (0, 2);
    assert_true (result, "trim drag-drop returns true on valid drop");
    assert_string_equal (
        tab.get_segment_label_for_widget_test (0),
        "Third",
        "trim drag-drop swaps source to target position");
    assert_string_equal (
        tab.get_segment_label_for_widget_test (2),
        "First",
        "trim drag-drop swaps target to source position");
    assert_string_equal (
        tab.get_segment_label_for_widget_test (1),
        "Second",
        "trim drag-drop leaves other segments unchanged");
}

private void test_subtitles_reorder_move_remove_and_default_helpers () {
    var detected = new GenericArray<SubtitleStream> ();
    var s0 = make_stream (0, "English");
    var s1 = make_stream (1, "Spanish");
    var s2 = make_stream (2, "French");
    detected.add (s0);
    detected.add (s1);
    detected.add (s2);

    var added = new GenericArray<ExternalSubtitle> ();
    var e0 = make_external ("a.srt");
    var e1 = make_external ("b.srt");
    added.add (e0);
    added.add (e1);

    SubtitlesTab.move_detected_for_test (detected, s1, -1);
    assert_int_equal (detected[0].sub_index, 1, "subtitles move detected up");
    assert_int_equal (detected[1].sub_index, 0, "subtitles move detected up");

    SubtitlesTab.reorder_detected_for_test (detected, 0, 2);
    assert_int_equal (detected[0].sub_index, 2, "subtitles reorder detected swap");
    assert_int_equal (detected[1].sub_index, 0, "subtitles reorder detected swap");
    assert_int_equal (detected[2].sub_index, 1, "subtitles reorder detected swap");

    SubtitlesTab.move_added_for_test (added, 1, -1);
    assert_string_equal (added[0].file_path, "b.srt", "subtitles move added up");

    var e2 = make_external ("c.srt");
    added.add (e2);
    SubtitlesTab.reorder_added_for_test (added, 0, 2);
    assert_string_equal (added[0].file_path, "c.srt", "subtitles reorder added swap");
    assert_string_equal (added[1].file_path, "a.srt", "subtitles reorder added middle");
    assert_string_equal (added[2].file_path, "b.srt", "subtitles reorder added swap");

    SubtitlesTab.remove_added_for_test (added, 0);
    assert_int_equal (added.length, 2, "subtitles remove added count");
    assert_string_equal (added[0].file_path, "a.srt", "subtitles remove added survivor");
    assert_string_equal (added[1].file_path, "b.srt", "subtitles remove added trailing");

    SubtitlesTab.set_detected_default_for_test (detected, added, detected[0], true);
    assert_true (detected[0].is_default, "subtitles detected default set");

    SubtitlesTab.set_added_default_for_test (detected, added, added[0], true);
    assert_false (detected[0].is_default, "subtitles detected default cleared by added default");
    assert_true (added[0].is_default, "subtitles added default set");
}

private void test_subtitles_order_and_completion_helpers () {
    var detected = new GenericArray<SubtitleStream> ();
    var s0 = make_stream (0);
    var s1 = make_stream (1);
    s1.marked_remove = true;
    var s2 = make_stream (2);
    detected.add (s0);
    detected.add (s1);
    detected.add (s2);

    var added = new GenericArray<ExternalSubtitle> ();
    added.add (make_external ("one.srt"));
    added.add (make_external ("two.srt"));

    var order = SubtitlesTab.build_remux_order_for_test (detected, added);
    assert_int_equal (order.length, 4, "subtitles remux order count");
    assert_int_equal (order[0], 0, "subtitles remux order first detected");
    assert_int_equal (order[1], 2, "subtitles remux order skips removed detected");
    assert_int_equal (order[2], 3, "subtitles remux order first external");
    assert_int_equal (order[3], 4, "subtitles remux order second external");

    bool busy = true;
    uint64 active_extract = 77;
    uint64 finished_extract = SubtitlesTab.finish_extract_operation_for_test (
        ref busy, ref active_extract);
    assert_uint64_equal (finished_extract, 77, "subtitles finish extract returns op id");
    assert_false (busy, "subtitles finish extract clears busy");
    assert_uint64_equal (active_extract, 0, "subtitles finish extract clears active id");

    busy = true;
    uint64 active_apply = 88;
    assert_false (
        SubtitlesTab.finish_apply_operation_for_test (ref busy, ref active_apply, 12),
        "subtitles finish apply ignores non-matching id");
    assert_true (busy, "subtitles finish apply keeps busy on non-match");
    assert_uint64_equal (active_apply, 88, "subtitles finish apply keeps active id on non-match");

    assert_true (
        SubtitlesTab.finish_apply_operation_for_test (ref busy, ref active_apply, 88),
        "subtitles finish apply handles matching id");
    assert_false (busy, "subtitles finish apply clears busy");
    assert_uint64_equal (active_apply, 0, "subtitles finish apply clears active id");
}

// Logo removal is expressed in source-frame coordinates, so a segment crop must
// never be emitted ahead of it: cropping first moves the frame out from under
// delogo, which then blurs whatever sits at those coordinates in the cropped
// picture and leaves the watermark alone. Verified against real footage —
// delogo after a crop=1080:520:200:200 paints a smear over the middle of the
// shot instead of the corner logo.
private EncodeProfileSnapshot make_logo_removal_profile_for_test () {
    var profile = new EncodeProfileSnapshot ();
    profile.delogo_enabled = true;
    profile.delogo_regions = "1:1:170:218";
    profile.video_filters_skip_delogo =
        "crop=640:480:0:0,scale=1280:-2:flags=lanczos";
    profile.video_filters_skip_crop_and_delogo = "scale=1280:-2:flags=lanczos";
    profile.video_filters_skip_crop =
        "delogo=x=1:y=1:w=170:h=218,scale=1280:-2:flags=lanczos";
    profile.video_filters =
        "delogo=x=1:y=1:w=170:h=218,crop=640:480:0:0,scale=1280:-2:flags=lanczos";
    return profile;
}

private void test_trim_segment_crop_follows_logo_removal () {
    var runner = new TrimRunner ();
    runner.reencode_profile = make_logo_removal_profile_for_test ();

    var cropped = new TrimSegment (1.0, 3.0);
    cropped.crop_value = "1080:520:200:200";
    string vf = runner.build_segment_vf_for_test (cropped);
    assert_string_equal (vf,
        "delogo=x=1:y=1:w=170:h=218,crop=1080:520:200:200,scale=1280:-2:flags=lanczos",
        "segment crop is spliced in after logo removal");

    int delogo_pos = vf.index_of ("delogo=");
    int crop_pos = vf.index_of ("crop=");
    assert_true (delogo_pos >= 0, "segment chain keeps logo removal");
    assert_true (crop_pos > delogo_pos, "segment crop never precedes logo removal");

    // An already-prefixed crop value must not double up the filter name.
    var prefixed = new TrimSegment (1.0, 3.0);
    prefixed.crop_value = "crop=1080:520:200:200";
    assert_string_equal (runner.build_segment_vf_for_test (prefixed), vf,
        "prefixed segment crop value produces the same chain");

    // Without a segment crop the General tab's own chain is used untouched,
    // crop and all — that path was already correct and must not change.
    var plain = new TrimSegment (1.0, 3.0);
    assert_string_equal (runner.build_segment_vf_for_test (plain),
        "delogo=x=1:y=1:w=170:h=218,crop=640:480:0:0,scale=1280:-2:flags=lanczos",
        "segment without a crop uses the full general chain");
}

private void test_trim_segment_crop_without_logo_removal () {
    var runner = new TrimRunner ();
    var profile = new EncodeProfileSnapshot ();
    profile.video_filters_skip_delogo = "crop=640:480:0:0,scale=1280:-2:flags=lanczos";
    profile.video_filters_skip_crop_and_delogo = "scale=1280:-2:flags=lanczos";
    profile.video_filters_skip_crop = "scale=1280:-2:flags=lanczos";
    profile.video_filters = "crop=640:480:0:0,scale=1280:-2:flags=lanczos";
    runner.reencode_profile = profile;

    var cropped = new TrimSegment (1.0, 3.0);
    cropped.crop_value = "1080:520:200:200";
    assert_string_equal (runner.build_segment_vf_for_test (cropped),
        "crop=1080:520:200:200,scale=1280:-2:flags=lanczos",
        "logo removal off leaves no empty filter slot");

    // No profile at all — the copy-mode-with-crop path.
    var bare = new TrimRunner ();
    var bare_seg = new TrimSegment (1.0, 3.0);
    bare_seg.crop_value = "1080:520:200:200";
    assert_string_equal (bare.build_segment_vf_for_test (bare_seg),
        "crop=1080:520:200:200",
        "segment crop stands alone without a re-encode profile");
}

// A timed region's interval is on the source timeline, but a segment decoded
// with -ss ahead of -i is handed frames whose timestamps start near zero
// (measured with showinfo, not assumed). Without the shift, delogo would switch
// on at the wrong moment in the segment — or, for a late region, never.
private void test_trim_segment_shifts_timed_regions_to_segment_time () {
    var runner = new TrimRunner ();
    var profile = new EncodeProfileSnapshot ();
    profile.delogo_enabled = true;
    profile.delogo_regions = "30.0-45.0:1416:1:504:288";
    profile.video_filters_skip_delogo = "scale=1280:-2:flags=lanczos";
    profile.video_filters_skip_crop_and_delogo = "scale=1280:-2:flags=lanczos";
    runner.reencode_profile = profile;

    // A segment starting at 25s sees the region from its own 5s mark.
    var late = new TrimSegment (25.0, 50.0);
    string vf = runner.build_segment_vf_for_test (late);
    assert_string_equal (vf,
        "delogo=x=1416:y=1:w=504:h=288:enable='between(t,5.000,20.000)',"
        + "scale=1280:-2:flags=lanczos",
        "timed region shifted into segment time");

    // A segment that ends before the region begins gets no delogo at all,
    // rather than a filter that can only ever be off.
    var early = new TrimSegment (0.0, 10.0);
    assert_string_equal (runner.build_segment_vf_for_test (early),
        "scale=1280:-2:flags=lanczos",
        "region the segment never reaches is dropped");

    // Composes with a segment crop, still in the right order.
    var cropped = new TrimSegment (25.0, 50.0);
    cropped.crop_value = "1080:520:200:200";
    string cropped_vf = runner.build_segment_vf_for_test (cropped);
    assert_string_equal (cropped_vf,
        "delogo=x=1416:y=1:w=504:h=288:enable='between(t,5.000,20.000)',"
        + "crop=1080:520:200:200,scale=1280:-2:flags=lanczos",
        "timed region precedes the segment crop and keeps its shifted interval");
}

// ── End-to-end: logo removal through the Crop & Trim export path ────────────
//
// The string tests above pin the filter chain. This one runs the real export
// and measures pixels, because an ordering bug composes perfectly well on
// paper — it just paints the wrong part of the picture.
//
// Measured on testvideo-raptor-watermark.webm (1280×720, opaque logo at
// 1:1:170:218), each export compared against the same export with logo
// removal switched off:
//
//   crop=1080:520:200:200 — logo outside the kept area
//     delogo before crop → PSNR inf    nothing painted inside the crop
//     delogo after crop  → PSNR 31.7   smear over the middle of the shot
//   crop=1280:620:0:0 — logo inside the kept area
//     delogo before crop → PSNR 28.7   logo actually painted out
//
// Checking both directions matters: "identical when the target is cropped
// away" alone would also pass if delogo silently stopped running.
private EncodeProfileSnapshot make_logo_removal_export_profile_for_test (
        bool logo_removal_on) {
    var general = new GeneralSettingsSnapshot ();
    general.delogo_enabled = logo_removal_on;
    general.delogo_regions = "1:1:170:218";

    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "23", "-preset", "veryfast" };
    profile.audio_args = { "-an" };

    // Populated the same way CodecUtils.snapshot_encode_profile populates it.
    profile.delogo_enabled = general.delogo_enabled;
    profile.delogo_regions = general.delogo_regions;
    profile.video_filters =
        FilterBuilder.build_video_filter_chain_from_snapshot (general);
    profile.video_filters_skip_delogo =
        FilterBuilder.build_video_filter_chain_from_snapshot (general, false, "", true);
    profile.video_filters_skip_crop_and_delogo =
        FilterBuilder.build_video_filter_chain_from_snapshot (general, true, "", true);
    return profile;
}

private void export_cropped_segment_for_test (string input_path,
                                              string crop_value,
                                              bool logo_removal_on,
                                              string output_path) {
    var runner = new TrimRunner ();
    runner.input_file = input_path;
    runner.copy_mode = false;

    var segments = new GenericArray<TrimSegment> ();
    var seg = new TrimSegment (1.0, 3.0);
    seg.crop_value = crop_value;
    segments.add (seg);
    runner.set_segments (segments);
    runner.reencode_profile =
        make_logo_removal_export_profile_for_test (logo_removal_on);

    int exit_code = runner.run_extract_segment_for_widget_test (0, output_path);
    assert_true (exit_code == 0,
        "trim logo removal export exit code for crop " + crop_value);
}

private double measure_video_psnr_for_test (string reference,
                                            string compared,
                                            string context) {
    string[] cmd = {
        AppSettings.get_default ().ffmpeg_path,
        "-hide_banner",
        "-i", reference,
        "-i", compared,
        "-lavfi", "psnr",
        "-f", "null", "-"
    };

    string stdout_buf, stderr_buf;
    int status = run_command_for_test (cmd, out stdout_buf, out stderr_buf, context);
    if (status != 0) {
        Test.fail_printf ("%s failed to compare '%s' with '%s': %s",
            context, reference, compared, stderr_buf.strip ());
        return 0.0;
    }

    int marker = stderr_buf.last_index_of ("average:");
    if (marker < 0) {
        Test.fail_printf ("%s found no PSNR summary in ffmpeg output: %s",
            context, stderr_buf.strip ());
        return 0.0;
    }

    string tail = stderr_buf.substring (marker + 8).strip ();
    int end = tail.index_of (" ");
    string token = end > 0 ? tail.substring (0, end) : tail;
    // Identical frames are reported as "inf" rather than a number.
    if (token.has_prefix ("inf")) return double.INFINITY;
    return double.parse (token);
}

private void test_trim_segment_crop_export_keeps_logo_removal_in_source_frame () {
    string tmp_dir;
    try {
        tmp_dir = DirUtils.make_tmp ("ffmpeg-trim-delogo-crop-XXXXXX");
    } catch (Error e) {
        Test.fail_printf ("failed to create temp directory: %s", e.message);
        return;
    }

    try {
        string input_path = resolve_test_asset_path ("testvideo-raptor-watermark.webm");

        // The crop discards the watermark's source coordinates, so a correctly
        // ordered chain leaves the kept picture untouched.
        string outside_on = Path.build_filename (tmp_dir, "outside-on.mkv");
        string outside_off = Path.build_filename (tmp_dir, "outside-off.mkv");
        export_cropped_segment_for_test (input_path, "1080:520:200:200", true, outside_on);
        export_cropped_segment_for_test (input_path, "1080:520:200:200", false, outside_off);

        double outside = measure_video_psnr_for_test (outside_off, outside_on,
            "trim logo removal outside-crop comparison");
        assert_true (outside > 60.0,
            "logo removal paints nothing inside a crop that excludes it (PSNR %.1f dB)"
                .printf (outside));

        // The crop keeps them, so the watermark must still be painted out.
        string inside_on = Path.build_filename (tmp_dir, "inside-on.mkv");
        string inside_off = Path.build_filename (tmp_dir, "inside-off.mkv");
        export_cropped_segment_for_test (input_path, "1280:620:0:0", true, inside_on);
        export_cropped_segment_for_test (input_path, "1280:620:0:0", false, inside_off);

        double inside = measure_video_psnr_for_test (inside_off, inside_on,
            "trim logo removal inside-crop comparison");
        assert_true (inside < 45.0,
            "logo removal still paints the watermark when the crop keeps it (PSNR %.1f dB)"
                .printf (inside));
    } finally {
        cleanup_exec_test_dir (tmp_dir);
    }
}

private void test_trim_video_only_reencode_normalizes_nonzero_pts () {
    string tmp_dir;
    try {
        tmp_dir = DirUtils.make_tmp ("ffmpeg-trim-nonzero-pts-XXXXXX");
    } catch (Error e) {
        Test.fail_printf ("failed to create nonzero-PTS trim directory: %s",
            e.message);
        return;
    }

    try {
        string input_path = Path.build_filename (tmp_dir, "nonzero-input.mkv");
        string output_path = Path.build_filename (tmp_dir, "normalized-trim.mkv");
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
            "create nonzero-PTS trim input");
        assert_true (make_status == 0,
            "nonzero-PTS trim input is created");

        var runner = new TrimRunner ();
        runner.input_file = input_path;
        runner.copy_mode = false;

        var segments = new GenericArray<TrimSegment> ();
        segments.add (new TrimSegment (0.0, 4.0));
        runner.set_segments (segments);

        var profile = new EncodeProfileSnapshot ();
        profile.container = ContainerExt.MKV;
        profile.codec_args = { "-c:v", "ffv1" };
        profile.audio_args = { "-an" };
        runner.reencode_profile = profile;

        int exit_code = runner.run_extract_segment_for_widget_test (
            0, output_path);
        assert_true (exit_code == 0,
            "nonzero-PTS video-only trim re-encode succeeds");

        string[] argv = runner.get_last_ffmpeg_argv_for_widget_test ();
        assert_array_has_adjacent_pair (argv, "-vf", "setpts=PTS-STARTPTS",
            "video-only trim re-encode resets its final video timeline");

        VideoTimelineProbeResult timeline =
            FfprobeUtils.probe_video_timeline (output_path);
        assert_true (timeline.success,
            "normalized trim output video timeline is readable");
        assert_true (Math.fabs (timeline.start_time) < 0.001,
            "normalized trim output starts at zero");
        assert_true (Math.fabs (timeline.get_duration () - 4.0) < 0.02,
            "normalized trim output retains the requested duration");
    } finally {
        cleanup_exec_test_dir (tmp_dir);
    }
}

private void test_trim_timestamp_normalization_respects_subtitles_and_chapters () {
    string tmp_dir;
    try {
        tmp_dir = DirUtils.make_tmp ("ffmpeg-trim-timed-streams-XXXXXX");
    } catch (Error e) {
        Test.fail_printf ("failed to create timed-stream trim directory: %s",
            e.message);
        return;
    }

    try {
        string sub_source = resolve_test_asset_path ("eng-test-sub.srt");
        string subtitle_input = Path.build_filename (tmp_dir, "subtitle-input.mkv");
        string subtitle_output = Path.build_filename (tmp_dir, "subtitle-output.mkv");
        string metadata_path = Path.build_filename (tmp_dir, "chapters.ffmeta");
        string chapter_input = Path.build_filename (tmp_dir, "chapter-input.mkv");
        string chapter_output = Path.build_filename (tmp_dir, "chapter-output.mkv");
        string chapters_removed_output =
            Path.build_filename (tmp_dir, "chapters-removed-output.mkv");
        string stdout_buf, stderr_buf;

        string[] make_subtitle_input = {
            AppSettings.get_default ().ffmpeg_path,
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=10:d=4",
            "-i", sub_source,
            "-map", "0:v:0", "-map", "1:s:0",
            "-vf", "setpts=PTS+1.5/TB",
            "-c:v", "ffv1", "-c:s", "srt",
            subtitle_input
        };
        assert_true (run_command_for_test (
                make_subtitle_input, out stdout_buf, out stderr_buf,
                "create embedded-subtitle trim input") == 0,
            "embedded-subtitle trim input is created");

        var subtitle_runner = new TrimRunner ();
        subtitle_runner.input_file = subtitle_input;
        subtitle_runner.copy_mode = false;
        var subtitle_segments = new GenericArray<TrimSegment> ();
        subtitle_segments.add (new TrimSegment (0.0, 4.0));
        subtitle_runner.set_segments (subtitle_segments);
        var subtitle_profile = new EncodeProfileSnapshot ();
        subtitle_profile.container = ContainerExt.MKV;
        subtitle_profile.codec_args = { "-c:v", "ffv1" };
        subtitle_profile.audio_args = { "-an" };
        subtitle_runner.reencode_profile = subtitle_profile;

        assert_true (subtitle_runner.run_extract_segment_for_widget_test (
                0, subtitle_output) == 0,
            "subtitle-bearing video-only trim succeeds");
        assert_array_not_contains (
            subtitle_runner.get_last_ffmpeg_argv_for_widget_test (),
            "setpts=PTS-STARTPTS",
            "retained subtitle blocks independent video timestamp reset");
        TimedStreamTopologyProbeResult subtitle_topology =
            FfprobeUtils.probe_timed_stream_topology (subtitle_output);
        assert_true (subtitle_topology.success && subtitle_topology.has_subtitle_stream,
            "retained subtitle remains present after trim");

        FileUtils.set_contents (
            metadata_path,
            ";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=2000\ntitle=Intro\n"
        );
        string[] make_chapter_input = {
            AppSettings.get_default ().ffmpeg_path,
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=10:d=4",
            "-f", "ffmetadata", "-i", metadata_path,
            "-map", "0:v:0", "-map_metadata", "1", "-map_chapters", "1",
            "-vf", "setpts=PTS+1.5/TB",
            "-c:v", "ffv1", "-an",
            chapter_input
        };
        assert_true (run_command_for_test (
                make_chapter_input, out stdout_buf, out stderr_buf,
                "create chaptered trim input") == 0,
            "chaptered trim input is created");

        var chapter_runner = new TrimRunner ();
        chapter_runner.input_file = chapter_input;
        chapter_runner.copy_mode = false;
        var chapter_segments = new GenericArray<TrimSegment> ();
        chapter_segments.add (new TrimSegment (0.0, 4.0));
        chapter_runner.set_segments (chapter_segments);
        var chapter_profile = new EncodeProfileSnapshot ();
        chapter_profile.container = ContainerExt.MKV;
        chapter_profile.codec_args = { "-c:v", "ffv1" };
        chapter_profile.audio_args = { "-an" };
        chapter_profile.preserve_metadata = true;
        chapter_runner.reencode_profile = chapter_profile;

        assert_true (chapter_runner.run_extract_segment_for_widget_test (
                0, chapter_output) == 0,
            "chapter-retaining video-only trim succeeds");
        assert_array_not_contains (
            chapter_runner.get_last_ffmpeg_argv_for_widget_test (),
            "setpts=PTS-STARTPTS",
            "retained chapters block independent video timestamp reset");

        chapter_profile.remove_chapters = true;
        assert_true (chapter_runner.run_extract_segment_for_widget_test (
                0, chapters_removed_output) == 0,
            "chapter-removing video-only trim succeeds");
        assert_array_has_adjacent_pair (
            chapter_runner.get_last_ffmpeg_argv_for_widget_test (),
            "-vf", "setpts=PTS-STARTPTS",
            "removing chapters permits safe timestamp normalization");
        TimedStreamTopologyProbeResult removed_topology =
            FfprobeUtils.probe_timed_stream_topology (chapters_removed_output);
        assert_true (removed_topology.success && !removed_topology.has_chapters,
            "removed chapters are absent from normalized trim output");
    } catch (Error e) {
        Test.fail_printf ("timed-stream trim integration setup failed: %s",
            e.message);
    } finally {
        cleanup_exec_test_dir (tmp_dir);
    }
}

void main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/trim/chapters/derive", test_trim_chapter_derivation_preserves_existing_order_and_appends_new);
    Test.add_func ("/trim/segments/edit-move-delete-crop", test_trim_segment_edit_move_delete_and_crop_helpers);
    Test.add_func ("/trim/segments/unknown-duration-ranges",
        test_trim_unknown_duration_segment_ranges);
    Test.add_func ("/trim/runner/guards", test_trim_runner_guard_helpers);
    Test.add_func ("/trim/output/naming-mode-base",
        test_trim_output_base_honours_naming_mode_outside_chapter_split);
    Test.add_func ("/trim/output/segment-name-composition",
        test_trim_separate_segment_names_compose_around_the_base);
    Test.add_func ("/trim/output/crop-only-single-file-name",
        test_trim_crop_only_names_a_single_file_not_a_segment);
    Test.add_func ("/trim/runner/collage-fallback-durations",
        test_trim_collage_fallback_durations_use_segment_context);
    Test.add_func ("/trim/runner/collage-output-results",
        test_trim_collage_output_results_preserve_primary_outputs);
    Test.add_func ("/trim/runner/image-watermark-preserves-duration",
        test_trim_image_watermark_preserves_segment_duration);
    Test.add_func ("/trim/runner/speed-preserves-segment-range",
        test_trim_speed_filter_preserves_segment_range);
    Test.add_func ("/trim/runner/segment-speed-scales-both-streams",
        test_trim_segment_speed_scales_both_streams);
    Test.add_func ("/trim/runner/segment-speed-stacks-with-general-tab",
        test_trim_segment_speed_stacks_with_general_tab);
    Test.add_func ("/trim/runner/segment-speed-follows-logo-removal",
        test_trim_segment_speed_follows_logo_removal);
    Test.add_func ("/trim/runner/segment-fade-out-follows-output-timeline",
        test_trim_segment_fade_out_follows_output_timeline);
    Test.add_func ("/trim/segments/copy-preserves-all-fields",
        test_trim_segment_copy_preserves_all_fields);
    Test.add_func ("/trim/runner/crop-through-eof",
        test_trim_crop_through_eof_omits_duration_limit);
    Test.add_func ("/trim/runner/image-watermark-maps-first-audio",
        test_trim_image_watermark_export_maps_first_audio_only);
    Test.add_func ("/trim/runner/smart-segment-preserves-10bit-overlay",
        test_trim_smart_segment_preserves_recommended_10bit_overlay);
    Test.add_func ("/smart-optimizer/watermark/calibration-reference-topology",
        test_smart_watermark_calibration_and_reference_topology);
    Test.add_func ("/smart-optimizer/watermark/snapshot-tracks-file-and-settings",
        test_smart_watermark_snapshot_tracks_file_and_settings);
    Test.add_func ("/smart-optimizer/watermark/commands-execute-8-and-10-bit",
        test_smart_watermark_commands_execute_at_8_and_10_bit);
    Test.add_func ("/trim/runner/peak-detect-maps-first-audio",
        test_trim_peak_detect_maps_first_audio_only);
    Test.add_func ("/trim/runner/segment-crop-follows-logo-removal",
        test_trim_segment_crop_follows_logo_removal);
    Test.add_func ("/trim/runner/segment-crop-without-logo-removal",
        test_trim_segment_crop_without_logo_removal);
    Test.add_func ("/trim/runner/segment-shifts-timed-regions",
        test_trim_segment_shifts_timed_regions_to_segment_time);
    Test.add_func ("/trim/runner/segment-crop-export-keeps-logo-removal-in-source-frame",
        test_trim_segment_crop_export_keeps_logo_removal_in_source_frame);
    Test.add_func ("/trim/runner/video-only-reencode-normalizes-nonzero-pts",
        test_trim_video_only_reencode_normalizes_nonzero_pts);
    Test.add_func ("/trim/runner/timestamp-normalization-respects-subtitles-and-chapters",
        test_trim_timestamp_normalization_respects_subtitles_and_chapters);
    Test.add_func ("/subtitles/burn-in/peak-detect-toggle-off-maps-first-audio",
        test_subtitle_peak_detect_toggle_off_maps_first_audio_only);
    Test.add_func ("/subtitles/burn-in/peak-detect-toggle-on-maps-all-audio",
        test_subtitle_peak_detect_toggle_on_maps_all_audio);
    Test.add_func ("/subtitles/burn-in/bitmap-image-watermark-toggle-off-topology",
        test_subtitle_burn_in_bitmap_image_watermark_toggle_off_topology);
    Test.add_func ("/subtitles/burn-in/bitmap-image-watermark-toggle-on-topology",
        test_subtitle_burn_in_bitmap_image_watermark_toggle_on_topology);
    Test.add_func ("/subtitles/burn-in/text-image-watermark-toggle-off-topology",
        test_subtitle_burn_in_text_image_watermark_toggle_off_topology);
    Test.add_func ("/subtitles/burn-in/text-image-watermark-toggle-on-topology",
        test_subtitle_burn_in_text_image_watermark_toggle_on_topology);
    Test.add_func ("/subtitles/burn-in/bitmap-no-watermark-toggle-off-topology",
        test_subtitle_burn_in_bitmap_no_watermark_toggle_off_topology);
    Test.add_func ("/subtitles/burn-in/bitmap-no-watermark-toggle-on-topology",
        test_subtitle_burn_in_bitmap_no_watermark_toggle_on_topology);
    Test.add_func ("/subtitles/burn-in/text-no-watermark-toggle-off-topology",
        test_subtitle_burn_in_text_no_watermark_toggle_off_topology);
    Test.add_func ("/subtitles/burn-in/text-no-watermark-toggle-on-topology",
        test_subtitle_burn_in_text_no_watermark_toggle_on_topology);
    Test.add_func ("/subtitles/burn-in/text-image-watermark-executes",
        test_subtitle_burn_in_text_image_watermark_executes);
    Test.add_func ("/trim/widgets/chapter-checkbox", test_trim_chapter_checkbox_updates_model_and_segments);
    Test.add_func ("/trim/widgets/move-button", test_trim_move_button_reorders_segments);
    Test.add_func ("/trim/widgets/drag-drop", test_trim_drag_drop_reorders_segments);
    Test.add_func ("/subtitles/state/reorder-move-remove-default", test_subtitles_reorder_move_remove_and_default_helpers);
    Test.add_func ("/subtitles/state/order-and-completion", test_subtitles_order_and_completion_helpers);

    Test.run ();
}
