public class AudioCompatibility : Object {
    public string container { get; set; default = ContainerExt.MKV; }
    public bool can_copy { get; set; default = true; }
    public string fallback_codec { get; set; default = ""; }
}

public class ContainerAudioPolicy : Object {
    public string[] selectable_codecs { get; construct set; default = {}; }
    public string[] copy_compatible_source_codecs { get; construct set; default = {}; }
    public string fallback_codec { get; construct set; default = ""; }
}

namespace AudioCompatibilityLogic {

    private static string[] get_permissive_transcode_codecs_internal () {
        return {
            AudioCodecName.OPUS,
            AudioCodecName.AAC,
            AudioCodecName.MP3,
            AudioCodecName.FLAC,
            AudioCodecName.VORBIS,
            AudioCodecName.WAV
        };
    }

    private static string[] prepend_copy_codec (string[] codecs) {
        string[] selectable = { AudioCodecName.COPY };
        foreach (unowned string codec in codecs) {
            selectable += codec;
        }
        return selectable;
    }

    public string[] get_permissive_transcode_codecs () {
        return get_permissive_transcode_codecs_internal ();
    }

    public string normalize_source_audio_codec_name (string codec_name) {
        string normalized = codec_name.down ().strip ();
        switch (normalized) {
            case "libopus":
                return "opus";
            case "libvorbis":
                return "vorbis";
            case "mp4a":
                return "aac";
            default:
                return normalized;
        }
    }

    public ContainerAudioPolicy get_container_audio_policy (string container) {
        switch (container.down ().strip ()) {
            case ContainerExt.WEBM:
                return new ContainerAudioPolicy () {
                    selectable_codecs = { AudioCodecName.COPY, AudioCodecName.OPUS, AudioCodecName.VORBIS },
                    copy_compatible_source_codecs = { "opus", "vorbis" },
                    fallback_codec = AudioCodecName.OPUS
                };
            case ContainerExt.MP4:
                return new ContainerAudioPolicy () {
                    selectable_codecs = { AudioCodecName.COPY, AudioCodecName.AAC, AudioCodecName.MP3, AudioCodecName.OPUS },
                    copy_compatible_source_codecs = { "aac", "mp3", "opus", "alac", "ac3", "eac3" },
                    fallback_codec = AudioCodecName.AAC
                };
            default:
                return new ContainerAudioPolicy () {
                    selectable_codecs = prepend_copy_codec (get_permissive_transcode_codecs_internal ()),
                    copy_compatible_source_codecs = {},
                    fallback_codec = ""
                };
        }
    }

    public string[] get_selectable_codecs_for_container (string container) {
        return get_container_audio_policy (container).selectable_codecs;
    }

    public bool container_supports_audio_copy (string container,
                                               AudioSourceInfo source) {
        string normalized_codec = normalize_source_audio_codec_name (source.codec_name);
        ContainerAudioPolicy policy = get_container_audio_policy (container);

        if (normalized_codec.length == 0)
            return true;

        foreach (string codec in policy.copy_compatible_source_codecs) {
            if (codec == normalized_codec) {
                return true;
            }
        }

        return policy.copy_compatible_source_codecs.length == 0;
    }

    public bool container_supports_audio_copy_for_codec (string container,
                                                         string source_codec_name) {
        var source = new AudioSourceInfo ();
        source.codec_name = source_codec_name;
        return container_supports_audio_copy (container, source);
    }

    /**
     * Check whether ALL source audio streams can be copied into the
     * target container.  Returns true only if every stream's codec is
     * compatible.  When all_sources is empty, falls back to checking
     * just the primary source.
     *
     * @param incompatible_codec  set to the first incompatible codec
     *                            name found, or "" if all are compatible.
     */
    public bool container_supports_audio_copy_all_streams (
        string container,
        AudioSourceInfo primary_source,
        AudioSourceInfo[] all_sources,
        out string incompatible_codec) {

        incompatible_codec = "";

        if (all_sources.length == 0) {
            bool ok = container_supports_audio_copy (container, primary_source);
            if (!ok) {
                incompatible_codec = primary_source.codec_name;
            }
            return ok;
        }

        foreach (unowned AudioSourceInfo source in all_sources) {
            if (!container_supports_audio_copy (container, source)) {
                incompatible_codec = source.codec_name;
                return false;
            }
        }

        return true;
    }

    public string get_copy_fallback_codec_for_container (string container) {
        return get_container_audio_policy (container).fallback_codec;
    }

    public bool container_requires_audio_copy_verification (string container) {
        ContainerAudioPolicy policy = get_container_audio_policy (container);
        return policy.copy_compatible_source_codecs.length > 0
            && policy.fallback_codec.length > 0;
    }

    private static bool is_lossless_audio_codec_for_source_depth (AudioSourceInfo source) {
        string normalized = normalize_source_audio_codec_name (source.codec_name);
        return normalized == "flac"
            || normalized == "alac"
            || normalized == "wavpack"
            || normalized == "ape"
            || normalized == "tta"
            || normalized == "tak"
            || normalized == "mlp"
            || normalized == "truehd"
            || normalized.has_prefix ("pcm_");
    }

    public string infer_source_depth_label (AudioSourceInfo source) {
        string source_fmt = source.sample_fmt.down ();
        if (source.bits_per_raw_sample > 0) {
            switch (source.bits_per_raw_sample) {
            case 8:
                return "8-bit";
            case 16:
                return "16-bit";
            case 24:
                return "24-bit";
            case 32:
                if (source_fmt == "flt" || source_fmt == "fltp") {
                    return "32-bit float";
                }
                return "32-bit";
            case 64:
                if (source_fmt == "dbl" || source_fmt == "dblp") {
                    return "64-bit float";
                }
                return "64-bit";
            default:
                break;
            }
        }

        if (!is_lossless_audio_codec_for_source_depth (source)) {
            return "";
        }

        switch (source_fmt) {
        case "u8":
        case "u8p":
            return "8-bit";
        case "s16":
        case "s16p":
            return "16-bit";
        case "s32":
        case "s32p":
            // Many 24-bit lossless sources decode into s32 containers.
            // Without bits_per_raw_sample, treat this as unknown rather than
            // over-promising true 32-bit preservation.
            return "";
        case "s64":
        case "s64p":
            return "64-bit";
        case "flt":
        case "fltp":
            return "32-bit float";
        case "dbl":
        case "dblp":
            return "64-bit float";
        default:
            return "";
        }
    }

    public AudioCompatibility evaluate (AudioSourceInfo source,
                                        string container) {
        var compatibility = new AudioCompatibility ();
        compatibility.container = container;
        compatibility.can_copy = container_supports_audio_copy (container, source);
        compatibility.fallback_codec = get_copy_fallback_codec_for_container (container);
        return compatibility;
    }
}
