public class AudioSourceInfo : Object {
    public MediaStreamPresence presence { get; set; default = MediaStreamPresence.UNKNOWN; }
    public int stream_index { get; set; default = 0; }
    public string codec_name { get; set; default = ""; }
    public int channels { get; set; default = 0; }
    public int sample_rate { get; set; default = 0; }
    public string sample_fmt { get; set; default = ""; }
    public int bits_per_raw_sample { get; set; default = 0; }
    public string language { get; set; default = ""; }

    public AudioSourceInfo copy () {
        var source = new AudioSourceInfo ();
        source.presence = presence;
        source.stream_index = stream_index;
        source.codec_name = codec_name;
        source.channels = channels;
        source.sample_rate = sample_rate;
        source.sample_fmt = sample_fmt;
        source.bits_per_raw_sample = bits_per_raw_sample;
        source.language = language;
        return source;
    }
}

namespace AudioSourceLogic {

    public AudioSourceInfo from_probe_result (AudioStreamProbeResult probe) {
        var source = new AudioSourceInfo ();
        source.presence = probe.presence;
        source.codec_name = probe.codec_name;
        source.channels = probe.channels;
        source.sample_fmt = probe.sample_fmt;
        source.bits_per_raw_sample = probe.bits_per_raw_sample;
        return source;
    }

    public AudioSourceInfo from_stream_info (AudioStreamInfo info) {
        var source = new AudioSourceInfo ();
        source.presence = MediaStreamPresence.PRESENT;
        source.stream_index = info.audio_index;
        source.codec_name = info.codec_name;
        source.channels = info.channels;
        source.sample_rate = info.sample_rate;
        source.sample_fmt = info.sample_fmt;
        source.bits_per_raw_sample = info.bits_per_raw_sample;
        source.language = info.language;
        return source;
    }

    public string get_copy_extension_for_codec_name (string codec_name) {
        string lower = codec_name.down ();
        if (lower == "aac" || lower == AudioCodecFFmpeg.AAC) return ".m4a";
        if (lower == "alac") return ".m4a";
        if (lower == "mp3" || lower == AudioCodecFFmpeg.MP3 || lower == "libmp3lame") return ".mp3";
        if (lower == "opus" || lower == AudioCodecFFmpeg.OPUS || lower == "libopus") return ".opus";
        if (lower == "flac" || lower == AudioCodecFFmpeg.FLAC) return ".flac";
        if (lower == "vorbis" || lower == AudioCodecFFmpeg.VORBIS || lower == "libvorbis") return ".ogg";
        if (lower == "ac3") return ".ac3";
        if (lower == "eac3") return ".eac3";
        if (lower == "dts" || lower == "dca") return ".dts";
        if (lower == "wav" || lower == "pcm_s16le" || lower == "pcm_s24le" || lower == "pcm_s32le"
            || lower == "pcm_f32le" || lower.has_prefix ("pcm_")) return ".wav";
        return ".mka";
    }

    public string get_copy_extension (AudioSourceInfo source) {
        return get_copy_extension_for_codec_name (source.codec_name);
    }
}
