// ═══════════════════════════════════════════════════════════════════════════════
//  Constants
// ═══════════════════════════════════════════════════════════════════════════════

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
}

// ── Audio Codec FFmpeg identifiers ───────────────────────────────────────────

namespace AudioCodecFFmpeg {
    public const string OPUS   = "libopus";
    public const string AAC    = "aac";
    public const string MP3    = "libmp3lame";
    public const string FLAC   = "flac";
    public const string VORBIS = "libvorbis";
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

// ── Scaling Algorithms ───────────────────────────────────────────────────────

namespace ScaleAlgorithm {
    public const string POINT = "point";
}

// ── Frame Rate Labels ────────────────────────────────────────────────────────

namespace FrameRateLabel {
    public const string ORIGINAL = "Original";
    public const string CUSTOM   = "Custom";
}
