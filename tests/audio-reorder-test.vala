using Gtk;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  Stubs — only what AudioBuilder needs to compile standalone
// ═══════════════════════════════════════════════════════════════════════════════

namespace CodecUtils {
    public StringList build_dropdown_string_list (string[] options) {
        var model = new StringList (null);
        foreach (unowned string option in options) {
            model.append (option);
        }
        return model;
    }
}

public class AppSettings : Object {
    private static AppSettings? instance = null;
    public string ffmpeg_path { get; set; default = "ffmpeg"; }

    public static AppSettings get_default () {
        if (instance == null) {
            instance = new AppSettings ();
        }
        return instance;
    }
}

namespace ConversionUtils {
    public string format_ffmpeg_double (double value, string format = "%g") {
        char[] buffer = new char[64];
        value.format (buffer, format);
        return (string) buffer;
    }
}

public class AudioSegment : Object {
    public double start_time { get; set; }
    public double end_time { get; set; }

    public AudioSegment (double start, double end) {
        start_time = start;
        end_time = end;
    }

    public double get_duration () {
        return (end_time - start_time).clamp (0.0, double.MAX);
    }
}

private void assert_contains (string haystack, string needle, string context) {
    if (!haystack.contains (needle)) {
        Test.fail_printf ("%s missing '%s'\nactual: %s", context, needle, haystack);
    }
}

private void assert_not_contains (string haystack, string needle, string context) {
    if (haystack.contains (needle)) {
        Test.fail_printf ("%s unexpectedly contained '%s'\nactual: %s", context, needle, haystack);
    }
}

private string join_cmd (string[] cmd) {
    return string.joinv (" ", cmd);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Builder tests — build_reorder_audio_cmd (exercises real production code)
// ═══════════════════════════════════════════════════════════════════════════════

private void test_reorder_maps_audio_in_specified_order () {
    string cmd = join_cmd (AudioBuilder.build_reorder_audio_cmd (
        "input.mkv", "output.mkv",
        { 2, 0, 1 },
        true, false));

    int pos_a2 = cmd.index_of ("-map 0:a:2");
    int pos_a0 = cmd.index_of ("-map 0:a:0");
    int pos_a1 = cmd.index_of ("-map 0:a:1");
    assert (pos_a2 >= 0 && pos_a0 >= 0 && pos_a1 >= 0);
    assert (pos_a2 < pos_a0);
    assert (pos_a0 < pos_a1);
}

private void test_reorder_swap_two_streams () {
    string cmd = join_cmd (AudioBuilder.build_reorder_audio_cmd (
        "input.mkv", "output.mkv",
        { 1, 0 },
        true, false));

    int pos_a1 = cmd.index_of ("-map 0:a:1");
    int pos_a0 = cmd.index_of ("-map 0:a:0");
    assert (pos_a1 >= 0 && pos_a0 >= 0);
    assert (pos_a1 < pos_a0);
}

private void test_reorder_preserves_video_streams () {
    string cmd = join_cmd (AudioBuilder.build_reorder_audio_cmd (
        "input.mkv", "output.mkv",
        { 1, 0 },
        true, false));

    assert_contains (cmd, "-map 0:v?", "video mapping");
}

private void test_reorder_keeps_subtitles_when_enabled () {
    string cmd = join_cmd (AudioBuilder.build_reorder_audio_cmd (
        "input.mkv", "output.mkv",
        { 1, 0 },
        true, false));

    assert_contains (cmd, "-map 0:s?", "subtitle preservation");
}

private void test_reorder_drops_subtitles_when_disabled () {
    string cmd = join_cmd (AudioBuilder.build_reorder_audio_cmd (
        "input.mkv", "output.mkv",
        { 1, 0 },
        false, false));

    assert_not_contains (cmd, "-map 0:s", "subtitle exclusion");
}

private void test_reorder_preserves_attachments_and_data () {
    string cmd = join_cmd (AudioBuilder.build_reorder_audio_cmd (
        "input.mkv", "output.mkv",
        { 0, 1 },
        true, false));

    assert_contains (cmd, "-map 0:t?", "attachment preservation");
    assert_contains (cmd, "-map 0:d?", "data stream preservation");
}

private void test_reorder_uses_stream_copy () {
    string cmd = join_cmd (AudioBuilder.build_reorder_audio_cmd (
        "input.mkv", "output.mkv",
        { 1, 0 },
        true, false));

    assert_contains (cmd, "-c copy", "stream copy");
}

private void test_reorder_strips_metadata_when_enabled () {
    string cmd = join_cmd (AudioBuilder.build_reorder_audio_cmd (
        "input.mkv", "output.mkv",
        { 1, 0 },
        true, true));

    assert_contains (cmd, "-map_metadata -1", "metadata stripping");
}

private void test_reorder_keeps_metadata_when_disabled () {
    string cmd = join_cmd (AudioBuilder.build_reorder_audio_cmd (
        "input.mkv", "output.mkv",
        { 1, 0 },
        true, false));

    assert_not_contains (cmd, "-map_metadata", "metadata preservation");
}

private void test_reorder_sets_first_stream_as_default () {
    string cmd = join_cmd (AudioBuilder.build_reorder_audio_cmd (
        "input.mkv", "output.mkv",
        { 2, 0, 1 },
        true, false));

    // +default adds the flag; -default removes it — neither replaces other flags
    assert_contains (cmd, "-disposition:a:0 +default", "first stream +default");
    assert_contains (cmd, "-disposition:a:1 -default", "second stream -default");
    assert_contains (cmd, "-disposition:a:2 -default", "third stream -default");
}

private void test_reorder_two_streams_disposition () {
    string cmd = join_cmd (AudioBuilder.build_reorder_audio_cmd (
        "input.mkv", "output.mkv",
        { 1, 0 },
        true, false));

    assert_contains (cmd, "-disposition:a:0 +default", "first stream +default");
    assert_contains (cmd, "-disposition:a:1 -default", "second stream -default");
}

private void test_reorder_includes_progress_flag () {
    string cmd = join_cmd (AudioBuilder.build_reorder_audio_cmd (
        "input.mkv", "output.mkv",
        { 0, 1 },
        true, false));

    assert_contains (cmd, "-progress pipe:2", "progress reporting");
}

// ═══════════════════════════════════════════════════════════════════════════════

void main (string[] args) {
    Test.init (ref args);

    AppSettings.get_default ().ffmpeg_path = "ffmpeg-test";

    Test.add_func ("/audio-reorder/builder/maps-audio-in-specified-order",
        test_reorder_maps_audio_in_specified_order);
    Test.add_func ("/audio-reorder/builder/swap-two-streams",
        test_reorder_swap_two_streams);
    Test.add_func ("/audio-reorder/builder/preserves-video-streams",
        test_reorder_preserves_video_streams);
    Test.add_func ("/audio-reorder/builder/keeps-subtitles-when-enabled",
        test_reorder_keeps_subtitles_when_enabled);
    Test.add_func ("/audio-reorder/builder/drops-subtitles-when-disabled",
        test_reorder_drops_subtitles_when_disabled);
    Test.add_func ("/audio-reorder/builder/preserves-attachments-and-data",
        test_reorder_preserves_attachments_and_data);
    Test.add_func ("/audio-reorder/builder/uses-stream-copy",
        test_reorder_uses_stream_copy);
    Test.add_func ("/audio-reorder/builder/strips-metadata-when-enabled",
        test_reorder_strips_metadata_when_enabled);
    Test.add_func ("/audio-reorder/builder/keeps-metadata-when-disabled",
        test_reorder_keeps_metadata_when_disabled);
    Test.add_func ("/audio-reorder/builder/sets-first-stream-as-default",
        test_reorder_sets_first_stream_as_default);
    Test.add_func ("/audio-reorder/builder/two-streams-disposition",
        test_reorder_two_streams_disposition);
    Test.add_func ("/audio-reorder/builder/includes-progress-flag",
        test_reorder_includes_progress_flag);

    Test.run ();
}
