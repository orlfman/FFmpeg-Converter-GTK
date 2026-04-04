using Gtk;
using Adw;
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

private void assert_false (bool value, string context) {
    if (value) {
        Test.fail_printf ("%s expected false", context);
    }
}

private void assert_string_array_equals (string[] actual,
                                         string[] expected,
                                         string context) {
    if (actual.length != expected.length) {
        Test.fail_printf ("%s expected %d items but got %d", context, expected.length, actual.length);
    }

    for (int i = 0; i < actual.length; i++) {
        if (actual[i] != expected[i]) {
            Test.fail_printf (
                "%s mismatch at index %d: expected '%s' but got '%s'",
                context, i, expected[i], actual[i]
            );
        }
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

private string[] filter_out_copy (string[] codecs) {
    string[] filtered = {};
    foreach (unowned string codec in codecs) {
        if (codec != AudioCodecName.COPY) {
            filtered += codec;
        }
    }
    return filtered;
}

private string join_args (string[] args) {
    return string.joinv (" ", args);
}

private AudioSettingsSnapshot make_opus_snapshot (int source_channels,
                                                  bool surround_fix = true) {
    var snapshot = new AudioSettingsSnapshot ();
    snapshot.enabled = true;
    snapshot.codec = AudioCodecName.OPUS;
    snapshot.source_channels = source_channels;
    snapshot.opus_surround_fix = surround_fix;
    return snapshot;
}

private void test_audio_settings_opus_surround_fix_downmixes_multichannel () {
    var snapshot = make_opus_snapshot (6);
    string args = join_args (AudioSettings.build_audio_args_from_snapshot (snapshot));

    assert_contains (args, "-ac 2", "audio settings opus surround fix");
    assert_contains (args, "-mapping_family 0", "audio settings opus surround fix");
    assert_not_contains (args, "aformat=channel_layouts", "audio settings opus surround fix");
}

private void test_audio_settings_opus_surround_fix_preserves_stereo_and_mono () {
    int[] channel_counts = { 2, 1 };
    foreach (int channels in channel_counts) {
        var snapshot = make_opus_snapshot (channels);
        string args = join_args (AudioSettings.build_audio_args_from_snapshot (snapshot));

        assert_not_contains (args, "-ac 2", "audio settings opus surround fix for %d channels".printf (channels));
        assert_contains (args, "-mapping_family 0", "audio settings opus surround fix for %d channels".printf (channels));
    }
}

private void test_audio_settings_opus_surround_fix_disabled_emits_no_surround_args () {
    var snapshot = make_opus_snapshot (6, false);
    string args = join_args (AudioSettings.build_audio_args_from_snapshot (snapshot));

    assert_not_contains (args, "-ac 2", "audio settings opus surround fix disabled");
    assert_not_contains (args, "-mapping_family", "audio settings opus surround fix disabled");
}

private void test_audio_settings_channel_override_suppresses_opus_surround_fix_downmix () {
    var snapshot = make_opus_snapshot (6);
    string args = join_args (AudioSettings.build_audio_args_from_snapshot (snapshot, 2));

    assert_not_contains (args, "-ac 2", "audio settings explicit downmix override");
    assert_contains (args, "-mapping_family 0", "audio settings explicit downmix override");
}

private void test_audio_settings_and_audio_builder_match_opus_surround_fix () {
    var snapshot = make_opus_snapshot (6);

    var config = new AudioExtractConfig ();
    config.copy_mode = false;
    config.source_channels = 6;
    config.audio_settings = snapshot;

    string settings_args = join_args (AudioSettings.build_audio_args_from_snapshot (snapshot));
    string builder_args = join_args (AudioBuilder.build_codec_args (config));

    assert_contains (settings_args, "-ac 2", "audio settings opus alignment");
    assert_contains (builder_args, "-ac 2", "audio builder opus alignment");
    assert_contains (settings_args, "-mapping_family 0", "audio settings opus alignment");
    assert_contains (builder_args, "-mapping_family 0", "audio builder opus alignment");
    assert_not_contains (settings_args, "aformat=channel_layouts", "audio settings opus alignment");
}

private void test_transcode_only_mode_exposes_shared_codec_list () {
    assert_string_array_equals (
        AudioSettings.get_transcode_only_codecs_for_test (),
        { AudioCodecName.OPUS, AudioCodecName.AAC, AudioCodecName.MP3,
          AudioCodecName.FLAC, AudioCodecName.VORBIS, AudioCodecName.WAV },
        "transcode-only codec list"
    );
}

private void test_mkv_container_exposes_wav_in_standard_mode () {
    assert_string_array_equals (
        AudioSettings.get_selectable_codecs_for_container_for_test (ContainerExt.MKV),
        { AudioCodecName.COPY, AudioCodecName.OPUS, AudioCodecName.AAC,
          AudioCodecName.MP3, AudioCodecName.FLAC, AudioCodecName.VORBIS,
          AudioCodecName.WAV },
        "mkv selectable codec list"
    );
}

private void test_transcode_only_mode_reuses_mkv_codec_set_without_copy () {
    assert_string_array_equals (
        AudioSettings.get_transcode_only_codecs_for_test (),
        filter_out_copy (
            AudioSettings.get_selectable_codecs_for_container_for_test (ContainerExt.MKV)
        ),
        "transcode-only shares mkv codec set without copy"
    );
}

private void test_standard_mode_uses_initial_container_policy_on_construction () {
    assert_string_array_equals (
        AudioSettings.get_initial_codec_options_for_mode_for_test (
            AudioSettingsMode.STANDARD,
            ContainerExt.MKV
        ),
        AudioSettings.get_selectable_codecs_for_container_for_test (ContainerExt.MKV),
        "standard mode initial mkv codec list"
    );

    assert_string_array_equals (
        AudioSettings.get_initial_codec_options_for_mode_for_test (
            AudioSettingsMode.STANDARD,
            ContainerExt.WEBM
        ),
        AudioSettings.get_selectable_codecs_for_container_for_test (ContainerExt.WEBM),
        "standard mode initial webm codec list"
    );
}

private void test_container_default_mode_resolves_expected_container_per_codec () {
    assert_equal_string (
        ContainerDefaultMode.DEFAULT.resolve_container_for_codec ("svt-av1"),
        ContainerExt.MKV,
        "default mode svt-av1 container"
    );
    assert_equal_string (
        ContainerDefaultMode.DEFAULT.resolve_container_for_codec ("vp9"),
        ContainerExt.WEBM,
        "default mode vp9 container"
    );
    assert_equal_string (
        ContainerDefaultMode.DEFAULT.resolve_container_for_codec ("x264"),
        ContainerExt.MKV,
        "default mode x264 container"
    );
    assert_equal_string (
        ContainerDefaultMode.DEFAULT.resolve_container_for_codec ("x265"),
        ContainerExt.MKV,
        "default mode x265 container"
    );

    assert_equal_string (
        ContainerDefaultMode.MKV.resolve_container_for_codec ("svt-av1"),
        ContainerExt.MKV,
        "mkv mode svt-av1 container"
    );
    assert_equal_string (
        ContainerDefaultMode.MKV.resolve_container_for_codec ("vp9"),
        ContainerExt.MKV,
        "mkv mode vp9 container"
    );
    assert_equal_string (
        ContainerDefaultMode.MKV.resolve_container_for_codec ("x264"),
        ContainerExt.MKV,
        "mkv mode x264 container"
    );
    assert_equal_string (
        ContainerDefaultMode.MKV.resolve_container_for_codec ("x265"),
        ContainerExt.MKV,
        "mkv mode x265 container"
    );

    assert_equal_string (
        ContainerDefaultMode.CODEC_SPECIFIC.resolve_container_for_codec ("svt-av1"),
        ContainerExt.WEBM,
        "codec-specific mode svt-av1 container"
    );
    assert_equal_string (
        ContainerDefaultMode.CODEC_SPECIFIC.resolve_container_for_codec ("vp9"),
        ContainerExt.WEBM,
        "codec-specific mode vp9 container"
    );
    assert_equal_string (
        ContainerDefaultMode.CODEC_SPECIFIC.resolve_container_for_codec ("x264"),
        ContainerExt.MP4,
        "codec-specific mode x264 container"
    );
    assert_equal_string (
        ContainerDefaultMode.CODEC_SPECIFIC.resolve_container_for_codec ("x265"),
        ContainerExt.MP4,
        "codec-specific mode x265 container"
    );
}

private void test_unknown_probe_result_stays_neutral () {
    if (AudioSettings.map_probe_presence_to_display_state_for_test (
        MediaStreamPresence.UNKNOWN) != AudioProbeDisplayState.UNKNOWN) {
        Test.fail_printf ("unknown probe should map to UNKNOWN state");
    }
}

private void test_error_probe_result_maps_to_error () {
    if (AudioSettings.map_probe_presence_to_display_state_for_test (
        MediaStreamPresence.ERROR) != AudioProbeDisplayState.ERROR) {
        Test.fail_printf ("error probe should map to ERROR state");
    }
}

private void test_sample_format_visibility_and_labels_follow_codec_rules () {
    assert_true (AudioSettings.should_show_sample_format_for_codec (AudioCodecName.WAV), "wav sample format visibility");
    assert_equal_string (AudioSettings.get_sample_format_title_for_codec (AudioCodecName.WAV), "Bit Depth", "wav sample format title");
    assert_equal_string (
        AudioSettings.get_sample_format_subtitle_for_codec (AudioCodecName.WAV),
        "Select the PCM output depth; Source preserves it when probing can determine it",
        "wav sample format subtitle"
    );
    assert_string_array_equals (
        AudioSettings.get_sample_format_labels_for_codec (AudioCodecName.WAV),
        { "Source", "16-bit", "24-bit", "32-bit", "32-bit float" },
        "wav sample format options"
    );

    assert_true (AudioSettings.should_show_sample_format_for_codec (AudioCodecName.FLAC), "flac sample format visibility");
    assert_equal_string (AudioSettings.get_sample_format_title_for_codec (AudioCodecName.FLAC), "Bit Depth", "flac sample format title");
    assert_equal_string (
        AudioSettings.get_sample_format_subtitle_for_codec (AudioCodecName.FLAC),
        "Select the FLAC output depth; Source preserves a compatible depth when probing can determine it",
        "flac sample format subtitle"
    );
    assert_string_array_equals (
        AudioSettings.get_sample_format_labels_for_codec (AudioCodecName.FLAC),
        { "Source", "16-bit", "24-bit", "32-bit" },
        "flac sample format options"
    );

    assert_true (AudioSettings.should_show_sample_format_for_codec (AudioCodecName.OPUS), "opus sample format visibility");
    assert_equal_string (AudioSettings.get_sample_format_title_for_codec (AudioCodecName.OPUS), "Sample Format", "opus sample format title");
    assert_equal_string (
        AudioSettings.get_sample_format_subtitle_for_codec (AudioCodecName.OPUS),
        "Controls encoder input format, not output bit depth",
        "opus sample format subtitle"
    );
    assert_string_array_equals (
        AudioSettings.get_sample_format_labels_for_codec (AudioCodecName.OPUS),
        { "Source", "16-bit", "32-bit float" },
        "opus sample format options"
    );

    assert_true (AudioSettings.should_show_sample_format_for_codec (AudioCodecName.MP3), "mp3 sample format visibility");
    assert_equal_string (AudioSettings.get_sample_format_title_for_codec (AudioCodecName.MP3), "Sample Format", "mp3 sample format title");

    assert_false (AudioSettings.should_show_sample_format_for_codec (AudioCodecName.AAC), "aac sample format visibility");

    assert_false (AudioSettings.should_show_sample_format_for_codec (AudioCodecName.VORBIS), "vorbis sample format visibility");
}

private void test_sample_rate_options_follow_codec_limits () {
    assert_string_array_equals (
        AudioSettings.get_sample_rate_labels_for_codec (AudioCodecName.OPUS),
        { "Source", "8 kHz", "12 kHz", "16 kHz", "24 kHz", "48 kHz" },
        "opus sample rate options"
    );

    assert_string_array_equals (
        AudioSettings.get_sample_rate_labels_for_codec (AudioCodecName.MP3),
        { "Source", "8 kHz", "12 kHz", "16 kHz", "22.05 kHz", "24 kHz",
          "32 kHz", "44.1 kHz", "48 kHz" },
        "mp3 sample rate options"
    );

    assert_string_array_equals (
        AudioSettings.get_sample_rate_labels_for_codec (AudioCodecName.AAC),
        { "Source", "8 kHz", "12 kHz", "16 kHz", "22.05 kHz", "24 kHz",
          "32 kHz", "44.1 kHz", "48 kHz", "64 kHz", "88.2 kHz", "96 kHz" },
        "aac sample rate options"
    );

    assert_string_array_equals (
        AudioSettings.get_sample_rate_labels_for_codec (AudioCodecName.FLAC),
        AudioCodecOptions.sample_rates (),
        "flac sample rate options"
    );
}

private void test_bitrate_options_follow_codec_limits () {
    assert_string_array_equals (
        AudioSettings.get_bitrate_labels_for_codec (AudioCodecName.MP3),
        { "64 kbps", "128 kbps", "192 kbps", "256 kbps", "320 kbps" },
        "mp3 bitrate options"
    );

    string[] full_bitrates = AudioCodecOptions.bitrates ();

    assert_string_array_equals (
        AudioSettings.get_bitrate_labels_for_codec (AudioCodecName.AAC),
        full_bitrates,
        "aac bitrate options"
    );

    assert_string_array_equals (
        AudioSettings.get_bitrate_labels_for_codec (AudioCodecName.OPUS),
        full_bitrates,
        "opus bitrate options"
    );
}

private void test_quality_scale_disables_bitrate_only_for_relevant_codecs () {
    assert_true (AudioSettings.should_show_bitrate_for_codec (AudioCodecName.AAC), "aac bitrate visibility");
    assert_true (
        AudioSettings.codec_uses_quality_scale (AudioCodecName.AAC, "0.5", "Disabled", "Disabled"),
        "aac bitrate sensitivity with quality"
    );

    assert_true (AudioSettings.should_show_bitrate_for_codec (AudioCodecName.VORBIS), "vorbis bitrate visibility");
    assert_true (
        AudioSettings.codec_uses_quality_scale (AudioCodecName.VORBIS, "Disabled", "Disabled", "4"),
        "vorbis bitrate sensitivity with quality"
    );

    assert_true (AudioSettings.should_show_bitrate_for_codec (AudioCodecName.MP3), "mp3 bitrate visibility");
    assert_true (
        AudioSettings.codec_uses_quality_scale (AudioCodecName.MP3, "Disabled", "2", "Disabled"),
        "mp3 bitrate sensitivity with quality"
    );

    assert_false (AudioSettings.should_show_bitrate_for_codec (AudioCodecName.FLAC), "flac bitrate visibility");
    assert_false (AudioSettings.should_show_bitrate_for_codec (AudioCodecName.WAV), "wav bitrate visibility");
}

private void test_aac_and_vorbis_ignore_sample_format_args () {
    var aac_snapshot = new AudioSettingsSnapshot ();
    aac_snapshot.enabled = true;
    aac_snapshot.codec = AudioCodecName.AAC;
    aac_snapshot.sample_format = "32-bit float";

    var vorbis_snapshot = new AudioSettingsSnapshot ();
    vorbis_snapshot.enabled = true;
    vorbis_snapshot.codec = AudioCodecName.VORBIS;
    vorbis_snapshot.sample_format = "16-bit";

    string aac_args = join_args (AudioSettings.build_audio_args_from_snapshot (aac_snapshot));
    string vorbis_args = join_args (AudioSettings.build_audio_args_from_snapshot (vorbis_snapshot));

    assert_not_contains (aac_args, "-sample_fmt", "aac sample format args");
    assert_not_contains (vorbis_args, "-sample_fmt", "vorbis sample format args");
}

private void test_wav_source_preserves_probed_pcm_depth_when_known () {
    var pcm24_snapshot = new AudioSettingsSnapshot ();
    pcm24_snapshot.enabled = true;
    pcm24_snapshot.codec = AudioCodecName.WAV;
    pcm24_snapshot.source_codec_name = "pcm_s24le";
    pcm24_snapshot.source_sample_fmt = "s32";
    pcm24_snapshot.source_bits_per_raw_sample = 24;

    var float_snapshot = new AudioSettingsSnapshot ();
    float_snapshot.enabled = true;
    float_snapshot.codec = AudioCodecName.WAV;
    float_snapshot.source_codec_name = "pcm_f32le";
    float_snapshot.source_sample_fmt = "flt";
    float_snapshot.source_bits_per_raw_sample = 32;

    string pcm24_args = join_args (AudioSettings.build_audio_args_from_snapshot (pcm24_snapshot));
    string float_args = join_args (AudioSettings.build_audio_args_from_snapshot (float_snapshot));

    assert_contains (pcm24_args, "-c:a pcm_s24le", "wav source depth preservation");
    assert_contains (float_args, "-c:a pcm_f32le", "wav source float preservation");
}

private void test_flac_source_preserves_compatible_probed_depth_when_known () {
    var snapshot = new AudioSettingsSnapshot ();
    snapshot.enabled = true;
    snapshot.codec = AudioCodecName.FLAC;
    snapshot.source_codec_name = "flac";
    snapshot.source_sample_fmt = "s32";
    snapshot.source_bits_per_raw_sample = 24;

    string args = join_args (AudioSettings.build_audio_args_from_snapshot (snapshot));

    assert_contains (args, "-sample_fmt s32", "flac source depth preservation");
    assert_contains (args, "-bits_per_raw_sample 24", "flac source depth preservation");
}

private void test_audio_compatibility_model_preserves_mp4_alac_copy () {
    var source = new AudioSourceInfo ();
    source.presence = MediaStreamPresence.PRESENT;
    source.codec_name = "alac";

    AudioCompatibility compatibility =
        AudioCompatibilityLogic.evaluate (source, ContainerExt.MP4);

    assert_true (compatibility.can_copy, "mp4 alac copy compatibility");
    assert_equal_string (compatibility.fallback_codec, AudioCodecName.AAC, "mp4 alac fallback codec");
    assert_equal_string (AudioSourceLogic.get_copy_extension (source), ".m4a", "mp4 alac copy extension");
}

private void test_audio_compatibility_model_preserves_mp4_eac3_copy_extension () {
    var source = new AudioSourceInfo ();
    source.presence = MediaStreamPresence.PRESENT;
    source.codec_name = "eac3";

    AudioCompatibility compatibility =
        AudioCompatibilityLogic.evaluate (source, ContainerExt.MP4);

    assert_true (compatibility.can_copy, "mp4 eac3 copy compatibility");
    assert_equal_string (AudioSourceLogic.get_copy_extension (source), ".eac3", "mp4 eac3 copy extension");
}

private void test_snapshot_source_model_preserves_wav_source_depth () {
    var snapshot = new AudioSettingsSnapshot ();
    snapshot.enabled = true;
    snapshot.codec = AudioCodecName.WAV;
    snapshot.source.codec_name = "pcm_s24le";
    snapshot.source.sample_fmt = "s32";
    snapshot.source.bits_per_raw_sample = 24;

    string args = join_args (AudioSettings.build_audio_args_from_snapshot (snapshot));

    assert_contains (args, "-c:a pcm_s24le", "snapshot source model wav depth");
}

private void test_probe_result_to_mp4_pcm_copy_coerces_to_aac_chain () {
    var probe = new AudioStreamProbeResult ();
    probe.presence = MediaStreamPresence.PRESENT;
    probe.codec_name = "pcm_s24le";
    probe.channels = 2;
    probe.sample_fmt = "s32";
    probe.bits_per_raw_sample = 24;

    AudioSourceInfo source = AudioSourceLogic.from_probe_result (probe);
    AudioCompatibility compatibility =
        AudioCompatibilityLogic.evaluate (source, ContainerExt.MP4);

    assert_false (compatibility.can_copy, "mp4 pcm copy compatibility");
    assert_equal_string (compatibility.fallback_codec, AudioCodecName.AAC, "mp4 pcm fallback codec");
    assert_equal_string (AudioSourceLogic.get_copy_extension (source), ".wav", "mp4 pcm preferred copy extension");

    var snapshot = new AudioSettingsSnapshot ();
    snapshot.enabled = true;
    snapshot.codec = AudioCodecName.COPY;
    snapshot.source = source.copy ();

    AudioSettings.coerce_copy_selection_for_container (snapshot, ContainerExt.MP4);

    assert_equal_string (snapshot.codec, AudioCodecName.AAC, "mp4 pcm copy coercion");

    string args = join_args (AudioSettings.build_audio_args_from_snapshot (snapshot));
    assert_contains (args, "-c:a aac", "mp4 pcm coerced args");
    assert_not_contains (args, "-c:a copy", "mp4 pcm coerced args");
}

private void test_wav_source_s32_without_raw_bits_falls_back_conservatively () {
    var snapshot = new AudioSettingsSnapshot ();
    snapshot.enabled = true;
    snapshot.codec = AudioCodecName.WAV;
    snapshot.source.codec_name = "flac";
    snapshot.source.sample_fmt = "s32";
    snapshot.source.bits_per_raw_sample = 0;

    string args = join_args (AudioSettings.build_audio_args_from_snapshot (snapshot));

    assert_contains (args, "-c:a pcm_s16le", "wav conservative s32 fallback");
    assert_not_contains (args, "-c:a pcm_s32le", "wav conservative s32 fallback");
}

private void test_flac_source_s32_without_raw_bits_avoids_guessing_depth () {
    var snapshot = new AudioSettingsSnapshot ();
    snapshot.enabled = true;
    snapshot.codec = AudioCodecName.FLAC;
    snapshot.source.codec_name = "flac";
    snapshot.source.sample_fmt = "s32";
    snapshot.source.bits_per_raw_sample = 0;

    string args = join_args (AudioSettings.build_audio_args_from_snapshot (snapshot));

    assert_contains (args, "-c:a flac", "flac conservative s32 fallback");
    assert_not_contains (args, "-sample_fmt", "flac conservative s32 fallback");
    assert_not_contains (args, "-bits_per_raw_sample", "flac conservative s32 fallback");
}

private void test_combine_reencode_constraint_restores_copy_selection_after_release () {
    if (!ensure_gtk_widget_tests_available ()) {
        return;
    }

    var settings = new AudioSettings (AudioSettingsMode.STANDARD, ContainerExt.MKV);

    assert_equal_string (
        settings.get_selected_codec_for_test (),
        AudioCodecName.COPY,
        "standard audio settings start on Copy"
    );

    settings.update_for_combine_reencode (true);

    assert_false (
        settings.is_codec_available_for_test (AudioCodecName.COPY),
        "combine constraint removes Copy from the live codec list"
    );
    assert_equal_string (
        settings.get_codec_row_subtitle_for_test (),
        "Copy disabled by Combine re-encode because audio must pass through filter_complex",
        "combine constraint subtitle explains the active blocker"
    );

    settings.update_for_combine_reencode (false);

    assert_true (
        settings.is_codec_available_for_test (AudioCodecName.COPY),
        "releasing combine constraint restores Copy to the live codec list"
    );
    assert_equal_string (
        settings.get_selected_codec_for_test (),
        AudioCodecName.COPY,
        "releasing combine constraint restores the user's Copy preference"
    );
}

private void test_manual_codec_choice_during_combine_constraint_persists_after_release () {
    if (!ensure_gtk_widget_tests_available ()) {
        return;
    }

    var settings = new AudioSettings (AudioSettingsMode.STANDARD, ContainerExt.MKV);

    settings.update_for_combine_reencode (true);
    settings.select_codec_for_test (AudioCodecName.AAC);
    settings.update_for_combine_reencode (false);

    assert_equal_string (
        settings.get_selected_codec_for_test (),
        AudioCodecName.AAC,
        "manual codec selection during combine constraint survives release"
    );
}

private void test_pipeline_constraint_subtitle_takes_priority_over_source_incompatibility () {
    if (!ensure_gtk_widget_tests_available ()) {
        return;
    }

    var settings = new AudioSettings (AudioSettingsMode.STANDARD, ContainerExt.MP4);
    settings.apply_source_audio_state ("vorbis", AudioProbeDisplayState.FOUND);

    assert_false (
        settings.is_codec_available_for_test (AudioCodecName.COPY),
        "source incompatibility removes Copy for unsupported MP4 audio"
    );
    assert_contains (
        settings.get_codec_row_subtitle_for_test (),
        "Vorbis audio track is not supported in MP4",
        "source incompatibility subtitle explains the persistent blocker"
    );

    settings.update_for_combine_reencode (true);

    assert_contains (
        settings.get_codec_row_subtitle_for_test (),
        "Combine re-encode",
        "active combine constraint takes subtitle priority over source incompatibility"
    );
}

private void test_audio_status_override_replaces_badge_when_probe_unknown () {
    if (!ensure_gtk_widget_tests_available ()) {
        return;
    }

    var settings = new AudioSettings (AudioSettingsMode.STANDARD, ContainerExt.MKV);

    assert_equal_string (
        settings.get_audio_status_badge_text_for_test (),
        "Audio status unavailable",
        "badge starts with default unknown text"
    );

    settings.set_audio_status_override (
        "media-playlist-consecutive-symbolic",
        "Audio re-encoded by Combine",
        "audio-status-neutral"
    );

    assert_equal_string (
        settings.get_audio_status_badge_text_for_test (),
        "Audio re-encoded by Combine",
        "override replaces badge when probe state is UNKNOWN"
    );

    settings.clear_audio_status_override ();

    assert_equal_string (
        settings.get_audio_status_badge_text_for_test (),
        "Audio status unavailable",
        "clearing override restores the normal probe badge"
    );
}

private void test_audio_status_override_does_not_replace_real_probe_state () {
    if (!ensure_gtk_widget_tests_available ()) {
        return;
    }

    var settings = new AudioSettings (AudioSettingsMode.STANDARD, ContainerExt.MKV);

    settings.apply_source_audio_state ("aac", AudioProbeDisplayState.FOUND);

    assert_equal_string (
        settings.get_audio_status_badge_text_for_test (),
        "Audio found",
        "badge shows real probe state"
    );

    settings.set_audio_status_override (
        "media-playlist-consecutive-symbolic",
        "Audio re-encoded by Combine",
        "audio-status-neutral"
    );

    assert_equal_string (
        settings.get_audio_status_badge_text_for_test (),
        "Audio found",
        "override does not replace badge when real probe state exists"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
//  MULTI-TRACK CONTAINER COMPATIBILITY TESTS
// ═════════════════════════════════════════════════════════════════════════════

private AudioSourceInfo make_source (string codec_name) {
    var s = new AudioSourceInfo ();
    s.presence = MediaStreamPresence.PRESENT;
    s.codec_name = codec_name;
    return s;
}

private void test_all_streams_compatible_webm_opus_only () {
    // All streams are opus — WebM should allow copy
    var primary = make_source ("opus");
    AudioSourceInfo[] all = { make_source ("opus"), make_source ("opus") };
    string incompatible;
    assert_true (
        AudioCompatibilityLogic.container_supports_audio_copy_all_streams (
            ContainerExt.WEBM, primary, all, out incompatible),
        "webm with all-opus streams should allow copy"
    );
}

private void test_mixed_streams_incompatible_webm () {
    // Primary is opus (ok), but secondary is flac (not ok for WebM)
    var primary = make_source ("opus");
    AudioSourceInfo[] all = { make_source ("opus"), make_source ("flac") };
    string incompatible;
    assert_false (
        AudioCompatibilityLogic.container_supports_audio_copy_all_streams (
            ContainerExt.WEBM, primary, all, out incompatible),
        "webm with mixed opus+flac should block copy"
    );
    assert_equal_string (incompatible, "flac",
        "incompatible codec should be flac");
}

private void test_mixed_streams_incompatible_webm_mp3 () {
    // Primary is opus, secondaries include mp3
    var primary = make_source ("opus");
    AudioSourceInfo[] all = {
        make_source ("opus"), make_source ("mp3"), make_source ("mp3")
    };
    string incompatible;
    assert_false (
        AudioCompatibilityLogic.container_supports_audio_copy_all_streams (
            ContainerExt.WEBM, primary, all, out incompatible),
        "webm with opus+mp3 should block copy"
    );
    assert_equal_string (incompatible, "mp3",
        "incompatible codec should be mp3");
}

private void test_all_streams_compatible_mp4 () {
    // AAC + MP3 are both valid in MP4
    var primary = make_source ("aac");
    AudioSourceInfo[] all = { make_source ("aac"), make_source ("mp3") };
    string incompatible;
    assert_true (
        AudioCompatibilityLogic.container_supports_audio_copy_all_streams (
            ContainerExt.MP4, primary, all, out incompatible),
        "mp4 with aac+mp3 should allow copy"
    );
}

private void test_mixed_streams_incompatible_mp4_vorbis () {
    // AAC is ok for MP4, but vorbis is not
    var primary = make_source ("aac");
    AudioSourceInfo[] all = { make_source ("aac"), make_source ("vorbis") };
    string incompatible;
    assert_false (
        AudioCompatibilityLogic.container_supports_audio_copy_all_streams (
            ContainerExt.MP4, primary, all, out incompatible),
        "mp4 with aac+vorbis should block copy"
    );
    assert_equal_string (incompatible, "vorbis",
        "incompatible codec should be vorbis");
}

private void test_empty_all_sources_falls_back_to_primary () {
    // When all_sources is empty, should check primary only
    var primary = make_source ("opus");
    AudioSourceInfo[] all = {};
    string incompatible;
    assert_true (
        AudioCompatibilityLogic.container_supports_audio_copy_all_streams (
            ContainerExt.WEBM, primary, all, out incompatible),
        "empty all_sources with compatible primary should allow copy"
    );

    var bad_primary = make_source ("flac");
    assert_false (
        AudioCompatibilityLogic.container_supports_audio_copy_all_streams (
            ContainerExt.WEBM, bad_primary, all, out incompatible),
        "empty all_sources with incompatible primary should block copy"
    );
}

private void test_coerce_copy_checks_all_streams () {
    // Snapshot with copy selected, primary is opus (ok for webm),
    // but secondary is flac (not ok for webm).  Coerce should switch
    // to the fallback codec.
    var snapshot = new AudioSettingsSnapshot ();
    snapshot.codec = AudioCodecName.COPY;
    snapshot.source = make_source ("opus");
    snapshot.all_sources = { make_source ("opus"), make_source ("flac") };

    AudioSettings.coerce_copy_selection_for_container (snapshot, ContainerExt.WEBM);

    assert_equal_string (snapshot.codec, AudioCodecName.OPUS,
        "coerce should switch to opus fallback when secondary stream is incompatible");
}

private void test_coerce_copy_preserves_when_all_compatible () {
    var snapshot = new AudioSettingsSnapshot ();
    snapshot.codec = AudioCodecName.COPY;
    snapshot.source = make_source ("opus");
    snapshot.all_sources = { make_source ("opus"), make_source ("vorbis") };

    AudioSettings.coerce_copy_selection_for_container (snapshot, ContainerExt.WEBM);

    assert_equal_string (snapshot.codec, AudioCodecName.COPY,
        "coerce should keep copy when all streams are compatible");
}

private void test_secondary_incompatible_track_disables_copy_in_widget () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var settings = new AudioSettings (AudioSettingsMode.STANDARD, ContainerExt.WEBM);

    // Build a probe result: primary opus (ok for webm), secondary flac (not ok)
    var probe = new AudioStreamProbeResult ();
    probe.presence = MediaStreamPresence.PRESENT;
    probe.codec_name = "opus";
    probe.channels = 2;
    probe.all_sources = {
        make_source ("opus"),
        make_source ("flac")
    };

    settings.apply_source_audio_probe_result (probe);

    assert_false (
        settings.is_codec_available_for_test (AudioCodecName.COPY),
        "Copy should be unavailable when a secondary track is incompatible with the container"
    );
    assert_contains (
        settings.get_codec_row_subtitle_for_test (),
        "FLAC audio track is not supported in WebM",
        "subtitle should name the incompatible codec"
    );
}

private void test_all_compatible_tracks_preserves_copy_in_widget () {
    if (!ensure_gtk_widget_tests_available ()) return;

    var settings = new AudioSettings (AudioSettingsMode.STANDARD, ContainerExt.WEBM);

    var probe = new AudioStreamProbeResult ();
    probe.presence = MediaStreamPresence.PRESENT;
    probe.codec_name = "opus";
    probe.channels = 2;
    probe.all_sources = {
        make_source ("opus"),
        make_source ("vorbis")
    };

    settings.apply_source_audio_probe_result (probe);

    assert_true (
        settings.is_codec_available_for_test (AudioCodecName.COPY),
        "Copy should remain available when all tracks are compatible"
    );
}

void main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/audio-settings/opus-surround-fix-downmixes-multichannel",
        test_audio_settings_opus_surround_fix_downmixes_multichannel);
    Test.add_func ("/audio-settings/opus-surround-fix-preserves-stereo-and-mono",
        test_audio_settings_opus_surround_fix_preserves_stereo_and_mono);
    Test.add_func ("/audio-settings/opus-surround-fix-disabled-emits-no-surround-args",
        test_audio_settings_opus_surround_fix_disabled_emits_no_surround_args);
    Test.add_func ("/audio-settings/channel-override-suppresses-opus-surround-fix-downmix",
        test_audio_settings_channel_override_suppresses_opus_surround_fix_downmix);
    Test.add_func ("/audio-settings/opus-surround-fix-matches-audio-builder",
        test_audio_settings_and_audio_builder_match_opus_surround_fix);
    Test.add_func ("/audio-settings/transcode-only-codec-list",
        test_transcode_only_mode_exposes_shared_codec_list);
    Test.add_func ("/audio-settings/mkv-container-exposes-wav",
        test_mkv_container_exposes_wav_in_standard_mode);
    Test.add_func ("/audio-settings/transcode-only-reuses-mkv-without-copy",
        test_transcode_only_mode_reuses_mkv_codec_set_without_copy);
    Test.add_func ("/audio-settings/standard-mode-uses-initial-container-policy",
        test_standard_mode_uses_initial_container_policy_on_construction);
    Test.add_func ("/audio-settings/container-default-mode-resolves-per-codec",
        test_container_default_mode_resolves_expected_container_per_codec);
    Test.add_func ("/audio-settings/unknown-probe-stays-neutral",
        test_unknown_probe_result_stays_neutral);
    Test.add_func ("/audio-settings/error-probe-maps-to-error",
        test_error_probe_result_maps_to_error);
    Test.add_func ("/audio-settings/sample-format-visibility-and-labels",
        test_sample_format_visibility_and_labels_follow_codec_rules);
    Test.add_func ("/audio-settings/sample-rate-options-follow-codec-limits",
        test_sample_rate_options_follow_codec_limits);
    Test.add_func ("/audio-settings/bitrate-options-follow-codec-limits",
        test_bitrate_options_follow_codec_limits);
    Test.add_func ("/audio-settings/quality-scale-disables-bitrate",
        test_quality_scale_disables_bitrate_only_for_relevant_codecs);
    Test.add_func ("/audio-settings/aac-and-vorbis-ignore-sample-format",
        test_aac_and_vorbis_ignore_sample_format_args);
    Test.add_func ("/audio-settings/wav-source-preserves-probed-pcm-depth-when-known",
        test_wav_source_preserves_probed_pcm_depth_when_known);
    Test.add_func ("/audio-settings/flac-source-preserves-compatible-probed-depth-when-known",
        test_flac_source_preserves_compatible_probed_depth_when_known);
    Test.add_func ("/audio-settings/combine-constraint-restores-copy-selection",
        test_combine_reencode_constraint_restores_copy_selection_after_release);
    Test.add_func ("/audio-settings/combine-constraint-preserves-manual-codec-selection",
        test_manual_codec_choice_during_combine_constraint_persists_after_release);
    Test.add_func ("/audio-settings/combine-constraint-subtitle-priority",
        test_pipeline_constraint_subtitle_takes_priority_over_source_incompatibility);
    Test.add_func ("/audio-settings/audio-status-override-replaces-badge-when-unknown",
        test_audio_status_override_replaces_badge_when_probe_unknown);
    Test.add_func ("/audio-settings/audio-status-override-does-not-replace-real-probe",
        test_audio_status_override_does_not_replace_real_probe_state);
    Test.add_func ("/audio-settings/audio-compatibility-model-preserves-mp4-alac-copy",
        test_audio_compatibility_model_preserves_mp4_alac_copy);
    Test.add_func ("/audio-settings/audio-compatibility-model-preserves-mp4-eac3-copy-extension",
        test_audio_compatibility_model_preserves_mp4_eac3_copy_extension);
    Test.add_func ("/audio-settings/snapshot-source-model-preserves-wav-source-depth",
        test_snapshot_source_model_preserves_wav_source_depth);
    Test.add_func ("/audio-settings/probe-result-to-mp4-pcm-copy-coerces-to-aac-chain",
        test_probe_result_to_mp4_pcm_copy_coerces_to_aac_chain);
    Test.add_func ("/audio-settings/wav-source-s32-without-raw-bits-falls-back-conservatively",
        test_wav_source_s32_without_raw_bits_falls_back_conservatively);
    Test.add_func ("/audio-settings/flac-source-s32-without-raw-bits-avoids-guessing-depth",
        test_flac_source_s32_without_raw_bits_avoids_guessing_depth);

    // Multi-track container compatibility tests
    Test.add_func ("/audio-settings/multi-track/all-opus-webm-allows-copy",
        test_all_streams_compatible_webm_opus_only);
    Test.add_func ("/audio-settings/multi-track/mixed-opus-flac-webm-blocks-copy",
        test_mixed_streams_incompatible_webm);
    Test.add_func ("/audio-settings/multi-track/mixed-opus-mp3-webm-blocks-copy",
        test_mixed_streams_incompatible_webm_mp3);
    Test.add_func ("/audio-settings/multi-track/aac-mp3-mp4-allows-copy",
        test_all_streams_compatible_mp4);
    Test.add_func ("/audio-settings/multi-track/aac-vorbis-mp4-blocks-copy",
        test_mixed_streams_incompatible_mp4_vorbis);
    Test.add_func ("/audio-settings/multi-track/empty-all-sources-falls-back-to-primary",
        test_empty_all_sources_falls_back_to_primary);
    Test.add_func ("/audio-settings/multi-track/coerce-copy-checks-all-streams",
        test_coerce_copy_checks_all_streams);
    Test.add_func ("/audio-settings/multi-track/coerce-preserves-copy-when-all-compatible",
        test_coerce_copy_preserves_when_all_compatible);
    Test.add_func ("/audio-settings/multi-track/secondary-incompatible-disables-copy-widget",
        test_secondary_incompatible_track_disables_copy_in_widget);
    Test.add_func ("/audio-settings/multi-track/all-compatible-preserves-copy-widget",
        test_all_compatible_tracks_preserves_copy_in_widget);

    Test.run ();
}
