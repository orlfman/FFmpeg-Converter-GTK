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

private AudioExtractConfig make_transcode_config () {
    var config = new AudioExtractConfig ();
    config.copy_mode = false;
    config.audio_settings.codec = AudioCodecName.OPUS;
    config.source_audio_index = 0;
    return config;
}

private void test_basic_extract_maps_primary_audio () {
    var config = new AudioExtractConfig ();
    config.copy_mode = true;
    config.source_audio_index = 0;

    string cmd = join_cmd (AudioBuilder.build_basic_extract_cmd (
        "input.mkv", "output.mka", config, 123.0));

    assert_contains (cmd, "-map 0:a:0", "basic extract command");
}

private void test_segment_extract_maps_primary_audio () {
    var config = new AudioExtractConfig ();
    config.copy_mode = true;
    config.source_audio_index = 0;

    string cmd = join_cmd (AudioBuilder.build_segment_extract_cmd (
        "input.mkv", "output.mka", config, 5.0, 10.0));

    assert_contains (cmd, "-map 0:a:0", "segment extract command");
}

private void test_concat_filter_uses_explicit_primary_stream () {
    var config = make_transcode_config ();
    var segments = new GenericArray<AudioSegment> ();
    segments.add (new AudioSegment (0.0, 5.0));
    segments.add (new AudioSegment (10.0, 15.0));

    string cmd = join_cmd (AudioBuilder.build_concat_filter_cmd (
        "input.mkv", "output.opus", config, segments));

    assert_contains (cmd, "[0:a:0]", "concat filter command");
    assert_contains (cmd, "[1:a:0]", "concat filter command");
}

private void test_peak_normalization_uses_volume_gain () {
    var config = make_transcode_config ();
    config.normalize_enabled = true;
    config.normalize_ebu = false;
    config.peak_normalize_gain_db = 3.5;

    string filters = AudioBuilder.build_filter_chain_for_segment (config, 30.0, true, true);

    assert_contains (filters, "volume=3.50dB", "peak normalization filter chain");
    assert_not_contains (filters, "replaygain", "peak normalization filter chain");
}

private void test_peak_normalization_skips_zero_db_gain () {
    var config = make_transcode_config ();
    config.normalize_enabled = true;
    config.normalize_ebu = false;
    config.peak_normalize_gain_db = 0.0;

    string filters = AudioBuilder.build_filter_chain_for_segment (config, 30.0, true, true);

    assert_not_contains (filters, "volume=", "zero-gain peak normalization filter chain");
}

private void test_peak_detect_cmd_uses_volumedetect_without_gain_filter () {
    var config = make_transcode_config ();
    config.normalize_enabled = true;
    config.normalize_ebu = false;
    config.peak_normalize_gain_db = 6.0;
    config.fade_out_enabled = true;
    config.fade_out_duration = 2.0;

    string cmd = join_cmd (AudioBuilder.build_basic_peak_detect_cmd (
        "input.mkv", config, 20.0));

    assert_contains (cmd, "volumedetect", "peak detect command");
    assert_not_contains (cmd, "volume=6.00dB", "peak detect command");
}

private void test_analysis_filter_chain_excludes_ebu_normalization () {
    var config = make_transcode_config ();
    config.normalize_enabled = true;
    config.normalize_ebu = true;
    config.fade_out_enabled = true;
    config.fade_out_duration = 2.0;

    string filters = AudioBuilder.build_analysis_filter_chain_for_segment (
        config, 20.0, true, true);

    assert_contains (filters, "afade=t=out", "analysis filter chain");
    assert_not_contains (filters, AudioNormalization.EBU_R128_FILTER, "analysis filter chain");
}

private void test_peak_detect_cmd_mirrors_opus_surround_fix_downmix () {
    var config = make_transcode_config ();
    config.normalize_enabled = true;
    config.normalize_ebu = false;
    config.audio_settings.opus_surround_fix = true;
    config.source_channels = 6;

    string cmd = join_cmd (AudioBuilder.build_basic_peak_detect_cmd (
        "input.mkv", config, 20.0));

    assert_contains (cmd, "-ac 2", "peak detect command with opus surround fix");
}

private void test_peak_detect_cmd_processing_downmix_overrides_opus_surround_fix () {
    var config = make_transcode_config ();
    config.normalize_enabled = true;
    config.normalize_ebu = false;
    config.audio_settings.opus_surround_fix = true;
    config.source_channels = 6;
    config.channel_downmix = 2;

    string cmd = join_cmd (AudioBuilder.build_basic_peak_detect_cmd (
        "input.mkv", config, 20.0));

    assert_not_contains (cmd, "-ac 2 -ac 1", "peak detect command with explicit mono downmix");
    assert_contains (cmd, "-ac 1", "peak detect command with explicit mono downmix");
}

private void test_basic_extract_processing_downmix_overrides_opus_surround_fix () {
    var config = make_transcode_config ();
    config.audio_settings.opus_surround_fix = true;
    config.source_channels = 6;
    config.channel_downmix = 2;

    string cmd = join_cmd (AudioBuilder.build_basic_extract_cmd (
        "input.mkv", "output.opus", config, 20.0));

    assert_not_contains (cmd, "-ac 2 -ac 1", "basic extract command with explicit mono downmix");
    assert_contains (cmd, "-ac 1", "basic extract command with explicit mono downmix");
}

private void test_peak_detect_cmd_omits_opus_sample_format_args_for_null_output () {
    var config = make_transcode_config ();
    config.normalize_enabled = true;
    config.normalize_ebu = false;
    config.audio_settings.sample_format = "32-bit float";

    string cmd = join_cmd (AudioBuilder.build_basic_peak_detect_cmd (
        "input.mkv", config, 20.0));

    assert_not_contains (cmd, "-sample_fmt", "peak detect command for opus float");
}

private void test_peak_detect_cmd_omits_flac_bit_depth_args_for_null_output () {
    var config = new AudioExtractConfig ();
    config.copy_mode = false;
    config.audio_settings.codec = AudioCodecName.FLAC;
    config.normalize_enabled = true;
    config.normalize_ebu = false;
    config.audio_settings.sample_format = "24-bit";

    string cmd = join_cmd (AudioBuilder.build_basic_peak_detect_cmd (
        "input.mkv", config, 20.0));

    assert_not_contains (cmd, "-sample_fmt", "peak detect command for flac 24-bit");
    assert_not_contains (cmd, "-bits_per_raw_sample", "peak detect command for flac 24-bit");
}

private void test_concat_filter_applies_ebu_normalization_once_after_concat () {
    var config = make_transcode_config ();
    config.normalize_enabled = true;
    config.normalize_ebu = true;

    var segments = new GenericArray<AudioSegment> ();
    segments.add (new AudioSegment (0.0, 5.0));
    segments.add (new AudioSegment (10.0, 15.0));

    string cmd = join_cmd (AudioBuilder.build_concat_filter_cmd (
        "input.mkv", "output.opus", config, segments));

    assert_contains (
        cmd,
        "concat=n=2:v=0:a=1[concat];[concat]loudnorm=I=-23:TP=-1.5:LRA=11[out]",
        "concat loudnorm placement"
    );
    assert_not_contains (cmd, "[0:a:0]loudnorm", "concat loudnorm should not be per-segment");
    assert_not_contains (cmd, "[1:a:0]loudnorm", "concat loudnorm should not be per-segment");
}

private void test_output_extension_uses_shared_audio_settings () {
    var config = new AudioExtractConfig ();

    config.copy_mode = false;
    config.audio_settings.codec = AudioCodecName.FLAC;
    assert_contains (AudioBuilder.get_output_extension (config, "aac"), ".flac",
        "transcode output extension");

    config.copy_mode = true;
    assert_contains (AudioBuilder.get_output_extension (config, "libopus"), ".opus",
        "copy output extension");
}

private void test_copy_output_extension_prefers_shared_source_model () {
    var config = new AudioExtractConfig ();
    config.copy_mode = true;
    config.source_audio.codec_name = "alac";

    assert_contains (
        AudioBuilder.get_output_extension (config, ""),
        ".m4a",
        "copy output extension from shared source model"
    );
}

private void test_probe_result_to_mp4_alac_copy_chain_keeps_copy_and_m4a () {
    var probe = new AudioStreamProbeResult ();
    probe.presence = MediaStreamPresence.PRESENT;
    probe.codec_name = "alac";
    probe.channels = 2;

    AudioSourceInfo source = AudioSourceLogic.from_probe_result (probe);
    AudioCompatibility compatibility =
        AudioCompatibilityLogic.evaluate (source, ContainerExt.MP4);

    assert_contains (AudioSourceLogic.get_copy_extension (source), ".m4a",
        "mp4 alac preferred copy extension");
    if (!compatibility.can_copy) {
        Test.fail_printf ("mp4 alac chain expected copy to remain available");
    }

    var snapshot = new AudioSettingsSnapshot ();
    snapshot.enabled = true;
    snapshot.codec = AudioCodecName.COPY;
    snapshot.source = source.copy ();
    AudioSettings.coerce_copy_selection_for_container (snapshot, ContainerExt.MP4);

    var config = new AudioExtractConfig ();
    config.copy_mode = true;
    config.audio_settings = snapshot;
    config.source_audio = source.copy ();

    string args = join_cmd (AudioBuilder.build_codec_args (config));
    string ext = AudioBuilder.get_output_extension (config, "");

    assert_contains (args, "-c:a copy", "mp4 alac copy args");
    assert_contains (ext, ".m4a", "mp4 alac output extension");
}

private void test_codec_args_skip_bitrate_when_quality_mode_is_enabled () {
    var aac_config = new AudioExtractConfig ();
    aac_config.copy_mode = false;
    aac_config.audio_settings.codec = AudioCodecName.AAC;
    aac_config.audio_settings.aac_quality = "0.5";
    string aac_args = join_cmd (AudioBuilder.build_codec_args (aac_config));
    assert_contains (aac_args, "-q:a 0.5", "aac quality mode codec args");
    assert_not_contains (aac_args, "-b:a", "aac quality mode codec args");

    var mp3_config = new AudioExtractConfig ();
    mp3_config.copy_mode = false;
    mp3_config.audio_settings.codec = AudioCodecName.MP3;
    mp3_config.audio_settings.mp3_vbr_quality = "2";
    string mp3_args = join_cmd (AudioBuilder.build_codec_args (mp3_config));
    assert_contains (mp3_args, "-q:a 2", "mp3 quality mode codec args");
    assert_not_contains (mp3_args, "-b:a", "mp3 quality mode codec args");

    var vorbis_config = new AudioExtractConfig ();
    vorbis_config.copy_mode = false;
    vorbis_config.audio_settings.codec = AudioCodecName.VORBIS;
    vorbis_config.audio_settings.vorbis_quality = "-1";
    string vorbis_args = join_cmd (AudioBuilder.build_codec_args (vorbis_config));
    assert_contains (vorbis_args, "-q:a -1", "vorbis quality mode codec args");
    assert_not_contains (vorbis_args, "-b:a", "vorbis quality mode codec args");
}

private void test_processing_args_apply_sample_format_only_to_supported_codecs () {
    var flac_config = new AudioExtractConfig ();
    flac_config.copy_mode = false;
    flac_config.audio_settings.codec = AudioCodecName.FLAC;
    flac_config.audio_settings.sample_format = "24-bit";
    string flac_args = join_cmd (AudioBuilder.build_processing_args (flac_config));
    assert_contains (flac_args, "-sample_fmt s32", "flac processing args");
    assert_contains (flac_args, "-bits_per_raw_sample 24", "flac processing args");

    var mp3_config = new AudioExtractConfig ();
    mp3_config.copy_mode = false;
    mp3_config.audio_settings.codec = AudioCodecName.MP3;
    mp3_config.audio_settings.sample_format = "32-bit float";
    string mp3_args = join_cmd (AudioBuilder.build_processing_args (mp3_config));
    assert_contains (mp3_args, "-sample_fmt fltp", "mp3 processing args");

    var aac_config = new AudioExtractConfig ();
    aac_config.copy_mode = false;
    aac_config.audio_settings.codec = AudioCodecName.AAC;
    aac_config.audio_settings.sample_format = "16-bit";
    string aac_args = join_cmd (AudioBuilder.build_processing_args (aac_config));
    assert_not_contains (aac_args, "-sample_fmt", "aac processing args");
}

void main (string[] args) {
    Test.init (ref args);

    AppSettings.get_default ().ffmpeg_path = "ffmpeg-test";

    Test.add_func ("/audio-builder/basic-extract-maps-primary-audio", test_basic_extract_maps_primary_audio);
    Test.add_func ("/audio-builder/segment-extract-maps-primary-audio", test_segment_extract_maps_primary_audio);
    Test.add_func ("/audio-builder/concat-filter-uses-explicit-primary-stream", test_concat_filter_uses_explicit_primary_stream);
    Test.add_func ("/audio-builder/peak-normalization-uses-volume-gain", test_peak_normalization_uses_volume_gain);
    Test.add_func ("/audio-builder/peak-normalization-skips-zero-db-gain", test_peak_normalization_skips_zero_db_gain);
    Test.add_func ("/audio-builder/peak-detect-cmd-uses-volumedetect-without-gain-filter", test_peak_detect_cmd_uses_volumedetect_without_gain_filter);
    Test.add_func ("/audio-builder/analysis-filter-chain-excludes-ebu-normalization", test_analysis_filter_chain_excludes_ebu_normalization);
    Test.add_func ("/audio-builder/peak-detect-cmd-mirrors-opus-surround-fix-downmix", test_peak_detect_cmd_mirrors_opus_surround_fix_downmix);
    Test.add_func ("/audio-builder/peak-detect-cmd-processing-downmix-overrides-opus-surround-fix", test_peak_detect_cmd_processing_downmix_overrides_opus_surround_fix);
    Test.add_func ("/audio-builder/basic-extract-processing-downmix-overrides-opus-surround-fix", test_basic_extract_processing_downmix_overrides_opus_surround_fix);
    Test.add_func ("/audio-builder/peak-detect-cmd-omits-opus-sample-format-args-for-null-output", test_peak_detect_cmd_omits_opus_sample_format_args_for_null_output);
    Test.add_func ("/audio-builder/peak-detect-cmd-omits-flac-bit-depth-args-for-null-output", test_peak_detect_cmd_omits_flac_bit_depth_args_for_null_output);
    Test.add_func ("/audio-builder/concat-filter-applies-ebu-normalization-once-after-concat", test_concat_filter_applies_ebu_normalization_once_after_concat);
    Test.add_func ("/audio-builder/output-extension-uses-shared-audio-settings", test_output_extension_uses_shared_audio_settings);
    Test.add_func ("/audio-builder/copy-output-extension-prefers-shared-source-model", test_copy_output_extension_prefers_shared_source_model);
    Test.add_func ("/audio-builder/probe-result-to-mp4-alac-copy-chain-keeps-copy-and-m4a", test_probe_result_to_mp4_alac_copy_chain_keeps_copy_and_m4a);
    Test.add_func ("/audio-builder/codec-args-skip-bitrate-when-quality-mode-is-enabled", test_codec_args_skip_bitrate_when_quality_mode_is_enabled);
    Test.add_func ("/audio-builder/processing-args-apply-sample-format-only-to-supported-codecs", test_processing_args_apply_sample_format_only_to_supported_codecs);

    Test.run ();
}
