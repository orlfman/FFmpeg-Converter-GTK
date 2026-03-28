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

private AudioSettingsSnapshot make_opus_snapshot () {
    var snapshot = new AudioSettingsSnapshot ();
    snapshot.codec = AudioCodecName.OPUS;
    snapshot.bitrate_kbps = 160;
    snapshot.source_channels = 2;
    return snapshot;
}

private void test_add_audio_replace_maps_only_first_external_audio_stream () {
    string cmd = join_cmd (AudioBuilder.build_add_audio_cmd (
        "video.mkv",
        "extra.mka",
        "output.mkv",
        true,
        2,
        true,
        false,
        { "-c:a", "copy" }
    ));

    assert_contains (cmd, "-map 1:a:0", "replace add-audio command");
    assert_not_contains (cmd, "-map 1:a ", "replace add-audio command");
}

private void test_add_audio_append_keeps_existing_audio_and_maps_only_first_new_stream () {
    string cmd = join_cmd (AudioBuilder.build_add_audio_cmd (
        "video.mkv",
        "extra.mka",
        "output.mkv",
        false,
        2,
        true,
        false,
        { "-c:a", "copy" }
    ));

    assert_contains (cmd, "-map 0:a?", "append add-audio command");
    assert_contains (cmd, "-map 1:a:0", "append add-audio command");
    assert_not_contains (cmd, "-map 1:a ", "append add-audio command");
}

private void test_add_audio_preserves_attachments_and_data_with_global_copy () {
    string cmd = join_cmd (AudioBuilder.build_add_audio_cmd (
        "video.mkv",
        "extra.flac",
        "output.mkv",
        false,
        1,
        true,
        false,
        { "-c:a", "copy" }
    ));

    assert_contains (cmd, "-map 0:t?", "attachment preservation");
    assert_contains (cmd, "-map 0:d?", "data preservation");
    assert_contains (cmd, "-c copy", "global stream copy");
}

private void test_add_audio_targets_new_track_codec_override_when_appending () {
    var snapshot = make_opus_snapshot ();
    string[] audio_args = AudioSettings.build_transcode_args_from_snapshot (snapshot, true, 0);

    string cmd = join_cmd (AudioBuilder.build_add_audio_cmd (
        "video.mkv",
        "extra.wav",
        "output.mkv",
        false,
        2,
        true,
        false,
        audio_args
    ));

    assert_contains (cmd, "-c copy", "append transcode command");
    assert_contains (cmd, "-c:a:2 libopus", "append transcode command");
}

private void test_add_audio_uses_plain_audio_codec_override_when_no_existing_audio () {
    var snapshot = make_opus_snapshot ();
    string[] audio_args = AudioSettings.build_transcode_args_from_snapshot (snapshot, true, 0);

    string cmd = join_cmd (AudioBuilder.build_add_audio_cmd (
        "video-no-audio.mkv",
        "extra.wav",
        "output.mkv",
        false,
        0,
        false,
        false,
        audio_args
    ));

    assert_contains (cmd, "-c copy", "single-track transcode command");
    assert_contains (cmd, "-c:a libopus", "single-track transcode command");
    assert_not_contains (cmd, "-c:a:0 libopus", "single-track transcode command");
}

void main (string[] args) {
    Test.init (ref args);

    Test.add_func (
        "/audio-add-builder/replace-maps-only-first-external-audio-stream",
        test_add_audio_replace_maps_only_first_external_audio_stream
    );
    Test.add_func (
        "/audio-add-builder/append-keeps-existing-audio-and-maps-only-first-new-stream",
        test_add_audio_append_keeps_existing_audio_and_maps_only_first_new_stream
    );
    Test.add_func (
        "/audio-add-builder/preserves-attachments-and-data-with-global-copy",
        test_add_audio_preserves_attachments_and_data_with_global_copy
    );
    Test.add_func (
        "/audio-add-builder/targets-new-track-codec-override-when-appending",
        test_add_audio_targets_new_track_codec_override_when_appending
    );
    Test.add_func (
        "/audio-add-builder/uses-plain-audio-codec-override-when-no-existing-audio",
        test_add_audio_uses_plain_audio_codec_override_when_no_existing_audio
    );

    Test.run ();
}
