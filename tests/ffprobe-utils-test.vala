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

private void test_primary_audio_probe_parser_uses_ffprobe_csv_order () {
    AudioStreamProbeResult result =
        FfprobeUtils.parse_primary_audio_stream_output_for_test ("pcm_s24le,s32,1,24\n");

    assert_true (result.presence == MediaStreamPresence.PRESENT, "primary probe presence");
    assert_equal_string (result.codec_name, "pcm_s24le", "primary probe codec");
    assert_equal_string (result.sample_fmt, "s32", "primary probe sample format");
    assert_equal_int (result.channels, 1, "primary probe channels");
    assert_equal_int (result.bits_per_raw_sample, 24, "primary probe raw bits");
}

private void test_all_audio_streams_probe_parser_reads_string_bits_field () {
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
      "tags": { "language": "eng" }
    }
  ]
}
""";

    AudioStreamsProbeResult result =
        FfprobeUtils.parse_all_audio_streams_output_for_test (json);

    assert_true (result.success, "all streams probe success");
    assert_equal_int ((int) result.streams.length, 1, "all streams probe count");
    assert_equal_int (result.streams[0].bits_per_raw_sample, 24, "all streams raw bits");
    assert_equal_string (result.streams[0].sample_fmt, "s32", "all streams sample format");
    assert_equal_int (result.streams[0].sample_rate, 48000, "all streams sample rate");
}

void main (string[] args) {
    Test.init (ref args);

    Test.add_func (
        "/ffprobe-utils/primary-audio-parser-uses-actual-csv-order",
        test_primary_audio_probe_parser_uses_ffprobe_csv_order
    );
    Test.add_func (
        "/ffprobe-utils/all-audio-streams-parser-reads-string-bits-field",
        test_all_audio_streams_probe_parser_reads_string_bits_field
    );

    Test.run ();
}
