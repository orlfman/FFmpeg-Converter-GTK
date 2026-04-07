// ═══════════════════════════════════════════════════════════════════════════════
//  Constants
// ═══════════════════════════════════════════════════════════════════════════════

// ── Application Version ─────────────────────────────────────────────────────

namespace AppVersion {
    public const string VERSION = "1.5.6";
}

namespace ProjectUrls {
    public const string REPOSITORY = "https://github.com/orlfman/FFmpeg-Converter-GTK";
    public const string RELEASES = REPOSITORY + "/releases";
    public const string ISSUES = REPOSITORY + "/issues";
}

// ── Rate Control Modes (UI labels used in codec tab DropDowns) ───────────────

namespace RateControl {
    public const string CRF = "CRF";
    public const string QP  = "QP";
    public const string VBR = "VBR";
    public const string ABR = "ABR";
    public const string CBR = "CBR";
    public const string CONSTRAINED_QUALITY = "Constrained Quality";
    public const string LOSSLESS = "Lossless";
}

// ── Audio Codec Names (UI labels shown in audio DropDown) ────────────────────

namespace AudioCodecName {
    public const string COPY   = "Copy";
    public const string OPUS   = "Opus";
    public const string AAC    = "AAC";
    public const string MP3    = "MP3";
    public const string FLAC   = "FLAC";
    public const string VORBIS = "Vorbis";
    public const string WAV    = "WAV";
}

// ── Audio Codec Option Lists (single source of truth for all UIs) ────────────
//
// Returned as fresh owned arrays so Vala never needs to pass const gchar **
// through mutable string[] APIs — eliminating the const-discard warnings.

namespace AudioCodecOptions {
    public string[] aac_quality () {
        return { "Disabled", "0.1", "0.3", "0.5", "1", "1.5", "2" };
    }

    public string[] mp3_vbr () {
        return { "Disabled", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };
    }

    public string[] flac_compression () {
        return { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12" };
    }
    public const int FLAC_COMPRESSION_DEFAULT = 5;

    public string[] vorbis_quality () {
        return { "Disabled", "-1", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" };
    }

    public string[] opus_vbr () {
        return { "Default", "Constrained", "Off" };
    }

    public string[] sample_rates () {
        return {
            "Source", "8 kHz", "12 kHz", "16 kHz", "22.05 kHz", "24 kHz",
            "32 kHz", "44.1 kHz", "48 kHz", "88.2 kHz", "96 kHz",
            "176.4 kHz", "192 kHz"
        };
    }

    public string[] bitrates () {
        return {
            "64 kbps", "128 kbps", "192 kbps", "256 kbps",
            "320 kbps", "384 kbps", "448 kbps", "512 kbps"
        };
    }
    public const int BITRATE_DEFAULT = 1;  // 128 kbps
}

// ── Audio Codec FFmpeg identifiers ───────────────────────────────────────────

namespace AudioCodecFFmpeg {
    public const string OPUS   = "libopus";
    public const string AAC    = "aac";
    public const string MP3    = "libmp3lame";
    public const string FLAC   = "flac";
    public const string VORBIS = "libvorbis";
    public const string WAV    = "pcm_s16le";
}

// ── Shared string-array helpers ─────────────────────────────────────────────

namespace StringArrayUtils {
    public string[] copy_generic_array (GenericArray<string> items) {
        string[] copy = new string[items.length];
        for (int i = 0; i < items.length; i++) {
            copy[i] = items[i];
        }
        return copy;
    }
}

// ── Audio normalization filters ─────────────────────────────────────────────

namespace AudioNormalization {
    public const string EBU_R128_FILTER = "loudnorm=I=-23:TP=-1.5:LRA=11";
}

// ── Container Extensions ─────────────────────────────────────────────────────

namespace ContainerExt {
    public const string MKV  = "mkv";
    public const string MP4  = "mp4";
    public const string WEBM = "webm";
}

// ── Rotation / Flip Labels ───────────────────────────────────────────────────

namespace Rotation {
    public const string NONE               = "No Rotation";
    public const string CW_90              = "90° Clockwise";
    public const string CCW_90             = "90° Counterclockwise";
    public const string ROTATE_180         = "180°";
    public const string HORIZONTAL_FLIP    = "Horizontal Flip";
    public const string VERTICAL_FLIP      = "Vertical Flip";
}

// ── Pixel Format Strings ─────────────────────────────────────────────────────

namespace PixelFormat {
    public const string YUV420P      = "yuv420p";
    public const string YUV422P      = "yuv422p";
    public const string YUV444P      = "yuv444p";
    public const string YUV420P10LE  = "yuv420p10le";
    public const string YUV422P10LE  = "yuv422p10le";
    public const string YUV444P10LE  = "yuv444p10le";
}

// ── Chroma Subsampling Labels ────────────────────────────────────────────────

namespace Chroma {
    public const string C420 = "4:2:0";
    public const string C422 = "4:2:2";
    public const string C444 = "4:4:4";
}

// ── Output Filename Modes ────────────────────────────────────────────────────

public enum OutputNameMode {
    DEFAULT,     // Current behavior: <original>-<codec>.<ext>
    CUSTOM,      // User-defined custom name
    RANDOM,      // Random alphanumeric string
    DATE,        // Timestamp: YYYY-MM-DD_HH-MM-SS
    METADATA;    // Video metadata "title" tag, fallback to filename

    public string to_string () {
        switch (this) {
            case CUSTOM:   return "custom";
            case RANDOM:   return "random";
            case DATE:     return "date";
            case METADATA: return "metadata";
            default:       return "default";
        }
    }

    public static OutputNameMode from_string (string val) {
        switch (val.down ().strip ()) {
            case "custom":   return CUSTOM;
            case "random":   return RANDOM;
            case "date":     return DATE;
            case "metadata": return METADATA;
            default:         return DEFAULT;
        }
    }

    public string get_label () {
        switch (this) {
            case CUSTOM:   return "Custom Name";
            case RANDOM:   return "Random";
            case DATE:     return "Date & Time";
            case METADATA: return "Metadata Title";
            default:       return "Default";
        }
    }

    public string get_description () {
        switch (this) {
            case CUSTOM:   return "Use a custom name you define below";
            case RANDOM:   return "Generate a random alphanumeric name";
            case DATE:     return "Use a timestamp (e.g. 2025-03-07_14-30-00)";
            case METADATA: return "Use the video's metadata title, or fall back to the filename";
            default:       return "Original filename with codec suffix appended";
        }
    }
}

public enum ContainerDefaultMode {
    DEFAULT,
    MKV,
    CODEC_SPECIFIC;

    public string to_string () {
        switch (this) {
            case MKV:            return "mkv";
            case CODEC_SPECIFIC: return "codec_specific";
            default:             return "default";
        }
    }

    public static ContainerDefaultMode from_string (string val) {
        switch (val.down ().strip ()) {
            case "mkv":            return MKV;
            case "codec_specific": return CODEC_SPECIFIC;
            default:               return DEFAULT;
        }
    }

    public string get_label () {
        switch (this) {
            case MKV:            return "MKV";
            case CODEC_SPECIFIC: return "Codec";
            default:             return "Default";
        }
    }

    public string get_description () {
        switch (this) {
            case MKV:
                return "Prefer MKV on every codec tab";
            case CODEC_SPECIFIC:
                return "WebM for SVT-AV1 and VP9, and MP4 for x264 and x265";
            default:
                return "Use each codec tab's built-in default container";
        }
    }

    public string resolve_container_for_codec (string codec) {
        string normalized = codec.down ().strip ();
        switch (this) {
            case MKV:
                return ContainerExt.MKV;
            case CODEC_SPECIFIC:
                switch (normalized) {
                    case "svt-av1":
                    case "vp9":
                        return ContainerExt.WEBM;
                    case "x264":
                    case "x265":
                        return ContainerExt.MP4;
                    default:
                        break;
                }
                break;
            case DEFAULT:
            default:
                break;
        }

        switch (normalized) {
            case "vp9":
                return ContainerExt.WEBM;
            default:
                return ContainerExt.MKV;
        }
    }
}

// ── Scaling Mode Labels ──────────────────────────────────────────────────────

namespace ScaleMode {
    public const string ORIGINAL   = "Original";
    public const string RESOLUTION = "Resolution Preset";
    public const string CUSTOM     = "Custom Resolution";
    public const string PERCENTAGE = "Percentage Scaling";
}

// ── Scaling Algorithms ───────────────────────────────────────────────────────

namespace ScaleAlgorithm {
    public const string POINT = "point";
}

// ── Frame Rate Labels ────────────────────────────────────────────────────────

namespace FrameRateLabel {
    public const string ORIGINAL = "Original";
    public const string CUSTOM   = "Custom";
}

namespace GtkCompat {
    [CCode (cname = "gtk_style_context_add_provider_for_display",
            cheader_filename = "gtk/gtk.h")]
    public extern static void add_provider_for_display (Gdk.Display display,
                                                        Gtk.StyleProvider provider,
                                                        uint priority);

    [CCode (cname = "gtk_style_context_remove_provider_for_display",
            cheader_filename = "gtk/gtk.h")]
    public extern static void remove_provider_for_display (Gdk.Display display,
                                                           Gtk.StyleProvider provider);
}

namespace SubprocessCompat {
    [CCode (cname = "ffcg_subprocess_launcher_spawnv_compat")]
    public extern static Subprocess spawnv (
        SubprocessLauncher launcher,
        [CCode (array_null_terminated = true)] string[] argv
    ) throws Error;
}
