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

private void assert_equal_string (string actual, string expected, string context) {
    if (actual != expected) {
        Test.fail_printf ("%s expected '%s' but got '%s'", context, expected, actual);
    }
}

private void assert_equal_int (int actual, int expected, string context) {
    if (actual != expected) {
        Test.fail_printf ("%s expected %d but got %d", context, expected, actual);
    }
}

private void assert_equal_double (double actual, double expected, string context) {
    if (Math.fabs (actual - expected) > 0.0001) {
        Test.fail_printf ("%s expected %.3f but got %.3f", context, expected, actual);
    }
}

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

private void test_should_export_separate_requires_multiple_segments () {
    assert_false (
        AudioExtractLogic.should_export_separate (0, true),
        "export separate with no segments"
    );
    assert_false (
        AudioExtractLogic.should_export_separate (1, true),
        "export separate with one segment"
    );
    assert_true (
        AudioExtractLogic.should_export_separate (2, true),
        "export separate with two segments"
    );
    assert_false (
        AudioExtractLogic.should_export_separate (3, false),
        "export separate switch off"
    );
}

private void test_build_extract_all_summary_formats_success_and_failure_counts () {
    assert_equal_string (
        AudioExtractLogic.build_extract_all_summary (1, 1),
        "Extracted 1 of 1 audio track",
        "extract all summary singular"
    );
    assert_equal_string (
        AudioExtractLogic.build_extract_all_summary (2, 2),
        "Extracted 2 of 2 audio tracks",
        "extract all summary plural"
    );
    assert_equal_string (
        AudioExtractLogic.build_extract_all_summary (2, 3),
        "Extracted 2 of 3 audio tracks (1 failed)",
        "extract all summary partial"
    );
}

private AudioSettingsSnapshot make_audio_settings_snapshot () {
    var snapshot = new AudioSettingsSnapshot ();
    snapshot.codec = AudioCodecName.FLAC;
    snapshot.sample_rate_hz = 96000;
    snapshot.bitrate_kbps = 320;
    snapshot.sample_format = "24-bit";
    snapshot.flac_compression = "8";
    return snapshot;
}

private AudioProcessingSettingsSnapshot make_processing_snapshot () {
    var snapshot = new AudioProcessingSettingsSnapshot ();
    snapshot.normalize_enabled = true;
    snapshot.normalize_ebu = false;
    snapshot.fade_in_enabled = true;
    snapshot.fade_in_duration = 1.5;
    snapshot.fade_out_enabled = true;
    snapshot.fade_out_duration = 2.5;
    snapshot.channel_downmix = 2;
    return snapshot;
}

private void test_build_snapshot_config_copy_mode_preserves_extract_only_fields () {
    var original_audio_settings = make_audio_settings_snapshot ();
    var processing_snapshot = make_processing_snapshot ();

    AudioExtractConfig config = AudioExtractLogic.build_snapshot_config (
        true,
        2,
        true,
        3,
        6,
        original_audio_settings,
        processing_snapshot,
        true
    );

    assert_true (config.copy_mode, "copy-mode snapshot");
    assert_true (config.export_separate, "copy-mode export separate");
    assert_equal_int (config.source_audio_index, 3, "copy-mode source audio index");
    assert_equal_int (config.source_channels, 6, "copy-mode source channels");
    assert_true (config.strip_metadata, "copy-mode strip metadata");

    assert_false (config.normalize_enabled, "copy-mode normalize");
    assert_true (config.normalize_ebu, "copy-mode normalize mode default");
    assert_false (config.fade_in_enabled, "copy-mode fade in");
    assert_false (config.fade_out_enabled, "copy-mode fade out");
    assert_equal_int (config.channel_downmix, 0, "copy-mode channel downmix default");
    assert_equal_string (config.audio_settings.codec, AudioCodecName.COPY, "copy-mode audio settings default codec");
}

private void test_build_snapshot_config_transcode_mode_copies_shared_audio_settings () {
    var original_audio_settings = make_audio_settings_snapshot ();
    var processing_snapshot = make_processing_snapshot ();

    AudioExtractConfig config = AudioExtractLogic.build_snapshot_config (
        false,
        1,
        true,
        1,
        2,
        original_audio_settings,
        processing_snapshot,
        false
    );

    assert_false (config.copy_mode, "transcode snapshot copy mode");
    assert_false (config.export_separate, "transcode snapshot hidden separate safety net");
    assert_equal_int (config.source_audio_index, 1, "transcode snapshot source audio index");
    assert_equal_int (config.source_channels, 2, "transcode snapshot source channels");

    assert_true (config.normalize_enabled, "transcode snapshot normalize");
    assert_false (config.normalize_ebu, "transcode snapshot normalize mode");
    assert_true (config.fade_in_enabled, "transcode snapshot fade in");
    assert_equal_double (config.fade_in_duration, 1.5, "transcode snapshot fade in duration");
    assert_true (config.fade_out_enabled, "transcode snapshot fade out");
    assert_equal_double (config.fade_out_duration, 2.5, "transcode snapshot fade out duration");
    assert_equal_int (config.channel_downmix, 2, "transcode snapshot channel downmix");
    assert_false (config.strip_metadata, "transcode snapshot strip metadata");

    assert_equal_string (config.audio_settings.codec, AudioCodecName.FLAC, "transcode snapshot codec");
    assert_equal_int (config.audio_settings.sample_rate_hz, 96000, "transcode snapshot sample rate");
    assert_equal_int (config.audio_settings.bitrate_kbps, 320, "transcode snapshot bitrate");
    assert_equal_string (config.audio_settings.sample_format, "24-bit", "transcode snapshot sample format");
    assert_equal_string (config.audio_settings.flac_compression, "8", "transcode snapshot flac compression");

    original_audio_settings.codec = AudioCodecName.AAC;
    original_audio_settings.sample_format = "16-bit";
    assert_equal_string (config.audio_settings.codec, AudioCodecName.FLAC, "transcode snapshot cloned codec");
    assert_equal_string (config.audio_settings.sample_format, "24-bit", "transcode snapshot cloned sample format");
}

void main (string[] args) {
    Test.init (ref args);

    Test.add_func (
        "/audio-extract-logic/should-export-separate-requires-multiple-segments",
        test_should_export_separate_requires_multiple_segments
    );
    Test.add_func (
        "/audio-extract-logic/build-extract-all-summary-formats-success-and-failure-counts",
        test_build_extract_all_summary_formats_success_and_failure_counts
    );
    Test.add_func (
        "/audio-extract-logic/build-snapshot-config-copy-mode-preserves-extract-only-fields",
        test_build_snapshot_config_copy_mode_preserves_extract_only_fields
    );
    Test.add_func (
        "/audio-extract-logic/build-snapshot-config-transcode-mode-copies-shared-audio-settings",
        test_build_snapshot_config_transcode_mode_copies_shared_audio_settings
    );

    Test.run ();
}
