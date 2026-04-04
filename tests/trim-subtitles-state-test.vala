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
        Test.message ("Skipping widget test: GTK could not initialize");
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

private void test_subtitle_burn_in_bitmap_image_watermark_topology () {
    string input_path = resolve_test_asset_path ("test2.vob");
    string sub_path = resolve_test_asset_path ("eng-test-sub.sup");
    string watermark_path = resolve_test_asset_path ("watermarktestimage.jpg");

    var runner = new SubtitlesRunner ();
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "23" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "128k" };
    profile.video_filters =
        "zscale=w=trunc(iw*2.000000/2)*2:h=trunc(ih*2.000000/2)*2:filter=lanczos";
    profile.watermark_enabled = true;
    profile.watermark_mode = "image";
    profile.watermark_image_path = watermark_path;
    profile.watermark_image_width = 120;
    profile.watermark_position = "Top Right";
    profile.watermark_opacity = 0.85;
    profile.watermark_margin = 10;

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
    assert_array_has_adjacent_pair (argv, "-map", "[outv]",
        "subtitle burn-in maps filtered video output");
    assert_array_has_adjacent_pair (argv, "-map", "0:a?",
        "subtitle burn-in preserves audio mapping");

    string filter_complex = "";
    for (int i = 0; i < argv.length - 1; i++) {
        if (argv[i] == "-filter_complex") {
            filter_complex = argv[i + 1];
            break;
        }
    }

    assert_contains (filter_complex, "[0:v][1:0]overlay[subbedv]",
        "subtitle burn-in overlays external bitmap subtitles first");
    assert_contains (filter_complex, "[subbedv]zscale=",
        "subtitle burn-in applies general video filters after subtitle overlay");
    assert_contains (filter_complex, "[2:v]scale=120:-1",
        "subtitle burn-in uses watermark image as third input");
    assert_contains (filter_complex, "colorchannelmixer=aa=0.85",
        "subtitle burn-in applies watermark opacity");
    assert_contains (filter_complex, "overlay=x=main_w-overlay_w-10:y=10[outv]",
        "subtitle burn-in overlays watermark at requested position");
}

private void test_subtitle_burn_in_text_image_watermark_topology () {
    string input_path = resolve_test_asset_path ("test2.vob");
    string watermark_path = resolve_test_asset_path ("watermarktestimage.jpg");
    string sub_path = resolve_test_asset_path ("eng-test-sub.srt");

    var runner = new SubtitlesRunner ();
    var profile = new EncodeProfileSnapshot ();
    profile.container = ContainerExt.MKV;
    profile.codec_args = { "-c:v", "libx264", "-crf", "23" };
    profile.audio_args = { "-c:a", "aac", "-b:a", "128k" };
    profile.video_filters =
        "zscale=w=trunc(iw*2.000000/2)*2:h=trunc(ih*2.000000/2)*2:filter=lanczos";
    profile.watermark_enabled = true;
    profile.watermark_mode = "image";
    profile.watermark_image_path = watermark_path;
    profile.watermark_image_width = 120;
    profile.watermark_position = "Top Right";
    profile.watermark_opacity = 0.85;
    profile.watermark_margin = 10;

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
    assert_array_has_adjacent_pair (argv, "-map", "[outv]",
        "text subtitle burn-in maps filtered video output");
    assert_array_has_adjacent_pair (argv, "-map", "0:a?",
        "text subtitle burn-in preserves audio mapping");

    int input_count = 0;
    bool has_vf = false;
    string filter_complex = "";
    for (int i = 0; i < argv.length; i++) {
        if (argv[i] == "-i") input_count++;
        if (argv[i] == "-vf") has_vf = true;
        if (i < argv.length - 1 && argv[i] == "-filter_complex") {
            filter_complex = argv[i + 1];
        }
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

void main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/trim/chapters/derive", test_trim_chapter_derivation_preserves_existing_order_and_appends_new);
    Test.add_func ("/trim/segments/edit-move-delete-crop", test_trim_segment_edit_move_delete_and_crop_helpers);
    Test.add_func ("/trim/runner/guards", test_trim_runner_guard_helpers);
    Test.add_func ("/trim/runner/image-watermark-preserves-duration",
        test_trim_image_watermark_preserves_segment_duration);
    Test.add_func ("/subtitles/burn-in/bitmap-image-watermark-topology",
        test_subtitle_burn_in_bitmap_image_watermark_topology);
    Test.add_func ("/subtitles/burn-in/text-image-watermark-topology",
        test_subtitle_burn_in_text_image_watermark_topology);
    Test.add_func ("/trim/widgets/chapter-checkbox", test_trim_chapter_checkbox_updates_model_and_segments);
    Test.add_func ("/trim/widgets/move-button", test_trim_move_button_reorders_segments);
    Test.add_func ("/trim/widgets/drag-drop", test_trim_drag_drop_reorders_segments);
    Test.add_func ("/subtitles/state/reorder-move-remove-default", test_subtitles_reorder_move_remove_and_default_helpers);
    Test.add_func ("/subtitles/state/order-and-completion", test_subtitles_order_and_completion_helpers);

    Test.run ();
}
