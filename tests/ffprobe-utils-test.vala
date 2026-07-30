using Gtk;
using GLib;

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
    public string ffprobe_path { get; set; default = "ffprobe"; }

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

    public string format_command_for_display (string[] argv) {
        return string.joinv (" ", argv);
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

private void assert_equal_int (int actual, int expected, string context) {
    if (actual != expected) {
        Test.fail_printf ("%s expected %d but got %d", context, expected, actual);
    }
}

private void assert_equal_string (string actual, string expected, string context) {
    if (actual != expected) {
        Test.fail_printf ("%s expected '%s' but got '%s'", context, expected, actual);
    }
}

private void assert_true (bool value, string context) {
    if (!value) {
        Test.fail_printf ("%s expected true", context);
    }
}

private void assert_near (double actual,
                          double expected,
                          double tolerance,
                          string context) {
    if (Math.fabs (actual - expected) > tolerance) {
        Test.fail_printf ("%s expected %.6f but got %.6f",
            context, expected, actual);
    }
}

private class ScriptedFfprobeCapture : Object {
    private string[] outputs;
    private int[] statuses;
    private int next_result = 0;
    public GenericArray<string> commands = new GenericArray<string> ();

    public ScriptedFfprobeCapture (string[] outputs, int[] statuses = {}) {
        this.outputs = outputs;
        this.statuses = statuses;
    }

    public int run (string[] argv,
                    out string stdout_text,
                    out string stderr_text) {
        commands.add (string.joinv (" ", argv));
        int index = next_result++;
        stdout_text = index < outputs.length ? outputs[index] : "";
        stderr_text = "";
        return index < statuses.length ? statuses[index] : 0;
    }
}

private void test_primary_audio_probe_parser_uses_ffprobe_csv_order () {
    AudioStreamProbeResult result =
        FfprobeUtils.parse_primary_audio_stream_output_for_test ("pcm_s24le,s32,1,24\n");

    assert_true (result.presence == MediaStreamPresence.PRESENT, "primary probe presence");
    assert_equal_string (result.codec_name, "pcm_s24le", "primary probe codec");
    assert_equal_string (result.sample_fmt, "s32", "primary probe sample format");
    assert_equal_int (result.channels, 1, "primary probe channels");
    assert_equal_int (result.bits_per_raw_sample, 24, "primary probe raw bits");
}

private void test_all_audio_streams_probe_parser_reads_stream_durations () {
    string json = """
{
  "format": { "duration": "12.5" },
  "streams": [
    {
      "codec_name": "pcm_s24le",
      "channels": 2,
      "sample_rate": "48000",
      "sample_fmt": "s32",
      "bits_per_raw_sample": "24",
      "duration": "10.25",
      "tags": { "language": "eng" }
    },
    {
      "codec_name": "aac",
      "channels": 2,
      "sample_rate": "48000",
      "sample_fmt": "fltp",
      "bits_per_raw_sample": "",
      "tags": { "language": "deu", "DURATION": "00:00:11.750000000" }
    },
    {
      "codec_name": "opus",
      "channels": 2,
      "sample_rate": "48000",
      "sample_fmt": "fltp",
      "bits_per_raw_sample": "",
      "tags": { "language": "fra" }
    }
  ]
}
""";

    AudioStreamsProbeResult result =
        FfprobeUtils.parse_all_audio_streams_output_for_test (json);

    assert_true (result.success, "all streams probe success");
    assert_equal_int ((int) result.streams.length, 3, "all streams probe count");
    assert_equal_int (result.streams[0].bits_per_raw_sample, 24, "all streams raw bits");
    assert_equal_string (result.streams[0].sample_fmt, "s32", "all streams sample format");
    assert_equal_int (result.streams[0].sample_rate, 48000, "all streams sample rate");
    assert_near (result.streams[0].duration_seconds, 10.25, 0.000001,
        "numeric stream duration wins over container duration");
    assert_near (result.streams[1].duration_seconds, 11.75, 0.000001,
        "Matroska DURATION tag supplies stream duration");
    assert_near (result.streams[2].duration_seconds, 12.5, 0.000001,
        "container duration is used only when stream duration is absent");
}

private void test_timed_stream_topology_parser_detects_subtitles_and_chapters () {
    string json = """
{
  "streams": [
    { "codec_type": "video" },
    { "codec_type": "subtitle" }
  ],
  "chapters": [
    { "start_time": "0.0", "end_time": "3.0" }
  ]
}
""";

    TimedStreamTopologyProbeResult result =
        FfprobeUtils.parse_timed_stream_topology_output_for_test (json);

    assert_true (result.success, "timed-stream topology parse success");
    assert_true (result.has_subtitle_stream, "subtitle stream detected");
    assert_true (result.has_chapters, "chapter metadata detected");
}

private void test_timed_stream_topology_parser_handles_video_only_input () {
    string json = """
{
  "streams": [ { "codec_type": "video" } ],
  "chapters": []
}
""";

    TimedStreamTopologyProbeResult result =
        FfprobeUtils.parse_timed_stream_topology_output_for_test (json);

    assert_true (result.success, "video-only topology parse success");
    assert_true (!result.has_subtitle_stream, "video-only input has no subtitles");
    assert_true (!result.has_chapters, "video-only input has no chapters");
}

private void test_timed_stream_topology_parser_rejects_incomplete_json () {
    TimedStreamTopologyProbeResult missing =
        FfprobeUtils.parse_timed_stream_topology_output_for_test ("{}");
    assert_true (!missing.success,
        "missing topology fields fail closed");

    TimedStreamTopologyProbeResult wrong_types =
        FfprobeUtils.parse_timed_stream_topology_output_for_test (
            "{\"streams\":{},\"chapters\":[]}");
    assert_true (!wrong_types.success,
        "wrong topology field types fail closed");

    TimedStreamTopologyProbeResult invalid_after_subtitle =
        FfprobeUtils.parse_timed_stream_topology_output_for_test (
            "{\"streams\":[{\"codec_type\":\"subtitle\"},3],\"chapters\":[]}");
    assert_true (!invalid_after_subtitle.success,
        "every topology element is validated after detecting a subtitle");

    TimedStreamTopologyProbeResult missing_codec_type =
        FfprobeUtils.parse_timed_stream_topology_output_for_test (
            "{\"streams\":[{}],\"chapters\":[]}");
    assert_true (!missing_codec_type.success,
        "stream objects without codec_type fail closed");

    TimedStreamTopologyProbeResult non_string_codec_type =
        FfprobeUtils.parse_timed_stream_topology_output_for_test (
            "{\"streams\":[{\"codec_type\":3}],\"chapters\":[]}");
    assert_true (!non_string_codec_type.success,
        "non-string codec_type values fail closed");
}

private void test_video_packet_timeline_parser_uses_real_packet_extent () {
    VideoTimelineProbeResult result =
        FfprobeUtils.parse_video_packet_timeline_output_for_test (
            "1.567000,0.033000\n"
            + "1.600000,0.033000\n"
            + "17.733000,0.033000\n");

    assert_true (result.success, "video packet timeline parse success");
    assert_near (result.start_time, 1.567, 0.000001, "video packet start");
    assert_near (result.end_time, 17.766, 0.000001, "video packet end");
    assert_near (result.get_duration (), 16.199, 0.000001,
        "video packet duration excludes leading timestamp gap");
    assert_near (result.get_seek_span (), 16.166, 0.000001,
        "collage seek span stops at the last real packet timestamp");
    assert_equal_int (result.packet_count, 3, "video packet count");
}

private void test_video_packet_timeline_parser_ignores_invalid_rows () {
    VideoTimelineProbeResult result =
        FfprobeUtils.parse_video_packet_timeline_output_for_test (
            "N/A,N/A\n"
            + "4.000000,N/A\n"
            + "5.000000,0.040000\n");

    assert_true (result.success, "timeline with partial packet data succeeds");
    assert_near (result.start_time, 4.0, 0.000001, "partial timeline start");
    assert_near (result.end_time, 5.04, 0.000001, "partial timeline end");
}

private void test_video_packet_timeline_parser_preserves_single_packet_start () {
    VideoTimelineProbeResult result =
        FfprobeUtils.parse_video_packet_timeline_output_for_test (
            "7.500000,N/A\n");

    assert_true (result.success, "single packet establishes a partial timeline");
    assert_true (result.start_time_known, "single packet start is known");
    assert_near (result.start_time, 7.5, 0.000001, "single packet start");
    assert_equal_int (result.packet_count, 1, "single packet count");
    assert_near (result.get_duration (), 0.0, 0.000001,
        "single packet without duration has no invented span");
    assert_near (result.get_seek_span (), 0.0, 0.000001,
        "single packet has no seek span beyond its own timestamp");
}

private void test_video_timeline_probe_uses_bounded_tail_window () {
    var capture = new ScriptedFfprobeCapture ({
        "1.500000,0.100000\n",
        "17.500000\n",
        "12.000000,0.100000\n17.400000,0.100000\n"
    });

    VideoTimelineProbeResult result = FfprobeUtils.probe_video_timeline (
        "/tmp/fake-video.mkv", capture.run);

    assert_true (result.success, "bounded timeline probe succeeds");
    assert_near (result.start_time, 1.5, 0.000001, "bounded probe start");
    assert_near (result.end_time, 17.5, 0.000001, "bounded probe end");
    assert_near (result.get_duration (), 16.0, 0.000001,
        "bounded probe excludes leading gap");
    assert_equal_int (result.packet_count, 3,
        "bounded probe knows there is more than one packet");
    assert_true (!result.packet_count_complete,
        "tail-only probe does not claim a complete packet count");
    assert_equal_int ((int) capture.commands.length, 3,
        "bounded probe uses first, duration, and tail commands");
    assert_true (capture.commands[0].contains ("-read_intervals %+#1"),
        "first probe reads one packet");
    assert_true (capture.commands[2].contains (
            "-read_intervals 12.500000%18.500000"),
        "tail probe uses an explicitly bounded final window");
}

private void test_video_timeline_probe_preserves_start_when_tail_is_unavailable () {
    var capture = new ScriptedFfprobeCapture ({
        "1.500000,0.100000\n",
        "17.500000\n",
        "", "", ""
    });

    VideoTimelineProbeResult result = FfprobeUtils.probe_video_timeline (
        "/tmp/fake-video.mkv", capture.run);

    assert_true (!result.success, "missing tail does not invent a duration");
    assert_true (result.start_time_known,
        "missing tail preserves the trustworthy first-packet timestamp");
    assert_near (result.start_time, 1.5, 0.000001,
        "partial result keeps measured video start");
    assert_equal_int (result.packet_count, 1,
        "partial result preserves first packet count");
    assert_true (!result.packet_count_complete,
        "partial result does not misidentify a multi-frame video as one frame");
}

private void test_video_timeline_probe_confirms_single_packet_without_duration () {
    var capture = new ScriptedFfprobeCapture ({
        "7.500000,N/A\n",
        "8.000000\n",
        "7.500000,N/A\n"
    });

    VideoTimelineProbeResult result = FfprobeUtils.probe_video_timeline (
        "/tmp/fake-single-frame.mkv", capture.run);

    assert_true (result.success,
        "complete packet scan confirms a duration-less single frame");
    assert_true (result.packet_count_complete,
        "single-frame packet count is complete");
    assert_equal_int (result.packet_count, 1,
        "duration-less single-frame packet count");
    assert_near (result.start_time, 7.5, 0.000001,
        "duration-less single-frame timestamp");
    assert_near (result.get_duration (), 0.0, 0.000001,
        "single frame needs no invented duration");
}

// ── Keyframe flag scanning ──────────────────────────────────────────────────

/**
 * Feed text through the scanner in fixed-size chunks, mimicking how the real
 * counter sees ffprobe's stdout arrive in arbitrary reads.
 */
private int scan_keyframes (string text, int chunk_size) {
    var scanner = new FfprobeUtils.KeyframeFlagScanner ();
    uint8[] bytes = text.data;

    int offset = 0;
    while (offset < bytes.length) {
        int take = int.min (chunk_size, bytes.length - offset);
        var chunk = new uint8[take];
        for (int i = 0; i < take; i++)
            chunk[i] = bytes[offset + i];
        scanner.feed (chunk, take);
        offset += take;
    }

    scanner.finish ();
    return scanner.count;
}

private void test_keyframe_scanner_counts_flagged_packets () {
    // csv=p=0 over packet=flags: 'K' marks a keyframe, '_' a non-keyframe, and
    // 'D' a discardable packet that may accompany either.
    string csv = "K_\n__\n__\nK_\n__\nKD\n";

    assert_equal_int (scan_keyframes (csv, 4096), 3,
        "keyframe lines counted");
}

private void test_keyframe_scanner_ignores_non_keyframe_lines () {
    assert_equal_int (scan_keyframes ("__\n__\n__\n", 4096), 0,
        "a stream with no keyframes counts zero");
    assert_equal_int (scan_keyframes ("", 4096), 0,
        "empty output counts zero");
    assert_equal_int (scan_keyframes ("\n\n\n", 4096), 0,
        "blank lines are not keyframes");
}

private void test_keyframe_scanner_counts_unterminated_final_line () {
    // ffprobe normally ends with a newline, but a truncated read must not drop
    // the last packet.
    assert_equal_int (scan_keyframes ("K_\n__\nK_", 4096), 2,
        "final line without a trailing newline still counts");
}

private void test_keyframe_scanner_is_independent_of_chunk_boundaries () {
    // The property that matters: the count cannot depend on where the reads
    // happen to split, including a split between a 'K' and its newline.
    string csv = "K_\n__\nKD\n__\n__\nK_\n";
    int expected = 3;

    for (int chunk_size = 1; chunk_size <= csv.length + 2; chunk_size++) {
        assert_equal_int (scan_keyframes (csv, chunk_size), expected,
            "keyframe count is stable at chunk size %d".printf (chunk_size));
    }
}

private void test_keyframe_scanner_matches_line_split_counting () {
    // Equivalence with the previous implementation, which split stdout on "\n"
    // and counted lines containing "K". Any drift here changes a number the
    // Information tab has always shown.
    string csv = "K_\n__\n__\nKD\n__\nK_\n__\n__\n__\nK_\n";

    int line_split_count = 0;
    foreach (string line in csv.split ("\n")) {
        if (line.contains ("K"))
            line_split_count++;
    }

    assert_equal_int (scan_keyframes (csv, 7), line_split_count,
        "byte scanner agrees with the previous line-splitting count");
}

void main (string[] args) {
    Test.init (ref args);

    Test.add_func (
        "/ffprobe-utils/primary-audio-parser-uses-actual-csv-order",
        test_primary_audio_probe_parser_uses_ffprobe_csv_order
    );
    Test.add_func (
        "/ffprobe-utils/all-audio-streams-parser-reads-stream-durations",
        test_all_audio_streams_probe_parser_reads_stream_durations
    );
    Test.add_func (
        "/ffprobe-utils/timed-stream-topology-detects-subtitles-and-chapters",
        test_timed_stream_topology_parser_detects_subtitles_and_chapters
    );
    Test.add_func (
        "/ffprobe-utils/timed-stream-topology-handles-video-only",
        test_timed_stream_topology_parser_handles_video_only_input
    );
    Test.add_func (
        "/ffprobe-utils/timed-stream-topology-rejects-incomplete-json",
        test_timed_stream_topology_parser_rejects_incomplete_json
    );
    Test.add_func (
        "/ffprobe-utils/video-packet-timeline-uses-real-extent",
        test_video_packet_timeline_parser_uses_real_packet_extent
    );
    Test.add_func (
        "/ffprobe-utils/video-packet-timeline-ignores-invalid-rows",
        test_video_packet_timeline_parser_ignores_invalid_rows
    );
    Test.add_func (
        "/ffprobe-utils/video-packet-timeline-preserves-single-packet-start",
        test_video_packet_timeline_parser_preserves_single_packet_start
    );
    Test.add_func (
        "/ffprobe-utils/video-timeline-probe-uses-bounded-tail-window",
        test_video_timeline_probe_uses_bounded_tail_window
    );
    Test.add_func (
        "/ffprobe-utils/video-timeline-probe-preserves-start-without-tail",
        test_video_timeline_probe_preserves_start_when_tail_is_unavailable
    );
    Test.add_func (
        "/ffprobe-utils/video-timeline-probe-confirms-duration-less-single-frame",
        test_video_timeline_probe_confirms_single_packet_without_duration
    );
    Test.add_func (
        "/ffprobe-utils/keyframe-scanner-counts-flagged-packets",
        test_keyframe_scanner_counts_flagged_packets
    );
    Test.add_func (
        "/ffprobe-utils/keyframe-scanner-ignores-non-keyframe-lines",
        test_keyframe_scanner_ignores_non_keyframe_lines
    );
    Test.add_func (
        "/ffprobe-utils/keyframe-scanner-counts-unterminated-final-line",
        test_keyframe_scanner_counts_unterminated_final_line
    );
    Test.add_func (
        "/ffprobe-utils/keyframe-scanner-is-independent-of-chunk-boundaries",
        test_keyframe_scanner_is_independent_of_chunk_boundaries
    );
    Test.add_func (
        "/ffprobe-utils/keyframe-scanner-matches-line-split-counting",
        test_keyframe_scanner_matches_line_split_counting
    );

    Test.run ();
}
