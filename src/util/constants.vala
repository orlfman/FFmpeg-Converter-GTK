// ═══════════════════════════════════════════════════════════════════════════════
//  Constants
// ═══════════════════════════════════════════════════════════════════════════════

// ── Application Version ─────────────────────────────────────────────────────

namespace AppVersion {
    public const string VERSION = "2.0.0";
}

// ── Application Identity ────────────────────────────────────────────────────
//
// Everything that has to differ between a release build and a development
// build installed beside it. Set by meson's `profile` option — see the
// DEVELOPMENT_PROFILE block in meson.build.
//
// APP_ID matters most: GApplication is single-instance per ID, so a devel
// build sharing the release ID would not start its own process at all. It
// would hand off to the running release app, and you would be looking at the
// installed version while believing you were testing your build.

namespace AppIdentity {
#if DEVELOPMENT_PROFILE
    public const string APP_ID = "com.github.pieman.FFmpegConverterGTKDevel";
    public const string CONFIG_DIR = "FFmpeg-Converter-GTK-Devel";
    public const string WINDOW_TITLE = "FFmpeg Converter GTK (Development)";
#else
    public const string APP_ID = "com.github.pieman.FFmpegConverterGTK";
    public const string CONFIG_DIR = "FFmpeg-Converter-GTK";
    public const string WINDOW_TITLE = "FFmpeg Converter GTK";
#endif
}

namespace ProjectUrls {
    public const string REPOSITORY = "https://github.com/orlfman/FFmpeg-Converter-GTK";
    public const string RELEASES = REPOSITORY + "/releases";
    public const string ISSUES = REPOSITORY + "/issues";
    public const string AUR = "https://aur.archlinux.org/packages/ffmpeg-converter-gtk";
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

    /**
     * The audio bitrates the UI can express, as numbers.
     *
     * The Smart Optimizer snaps its computed audio budget onto these rungs
     * (see SmartOptimizerLogic.snap_audio_kbps_down), so the value it reserves
     * in the size estimate is the value the encoder is actually given.  Keep
     * this ascending — the snapping assumes it.
     */
    public int[] bitrate_values () {
        return { 64, 128, 192, 256, 320, 384, 448, 512 };
    }

    public string[] bitrates () {
        int[] values = bitrate_values ();
        string[] labels = new string[values.length];
        for (int i = 0; i < values.length; i++)
            labels[i] = bitrate_label (values[i]);
        return labels;
    }

    /** The dropdown label for a bitrate rung. */
    public string bitrate_label (int kbps) {
        return "%d kbps".printf (kbps);
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

// ── Collage Thumbnail Size ───────────────────────────────────────────────────

/**
 * How large the 4-4-4 collage sidecar is rendered.
 *
 * The names are the familiar width ladder — 1280, 1920, 2560, 3840 — and each
 * one divides evenly by the four columns, so every tile stays exactly 16:9 with
 * no rounding. The finished image is NOT that resolution's usual height: twelve
 * 16:9 tiles in a 4×3 grid make a 64:27 picture, so 1080p here means 1920×810
 * rather than 1920×1080. get_description () spells out both numbers because
 * "2K" in particular means different things to different people.
 *
 * FHD_1080 is the default and reproduces the fixed 480×270 tiles this feature
 * shipped with, so an upgrade changes nobody's output.
 */
public enum CollageSize {
    HD_720,
    FHD_1080,
    QHD_2K,
    UHD_4K;

    // Four columns by three rows — see ConversionUtils.build_collage_argv.
    public const int COLUMNS = 4;
    public const int ROWS = 3;

    public string to_string () {
        switch (this) {
            case HD_720: return "720p";
            case QHD_2K: return "2k";
            case UHD_4K: return "4k";
            default:     return "1080p";
        }
    }

    public static CollageSize from_string (string val) {
        switch (val.down ().strip ()) {
            case "720p": return HD_720;
            case "2k":   return QHD_2K;
            case "4k":   return UHD_4K;
            default:     return FHD_1080;
        }
    }

    /** Width of one captured frame in the grid. */
    public int tile_width () {
        switch (this) {
            case HD_720: return 320;
            case QHD_2K: return 640;
            case UHD_4K: return 960;
            default:     return 480;
        }
    }

    /** Height of one captured frame, always 16:9 against tile_width (). */
    public int tile_height () {
        switch (this) {
            case HD_720: return 180;
            case QHD_2K: return 360;
            case UHD_4K: return 540;
            default:     return 270;
        }
    }

    public int image_width () {
        return tile_width () * COLUMNS;
    }

    public int image_height () {
        return tile_height () * ROWS;
    }

    public string get_label () {
        switch (this) {
            case HD_720: return "720p";
            case QHD_2K: return "2K";
            case UHD_4K: return "4K";
            default:     return "1080p";
        }
    }

    /** Both numbers, because the grid is 64:27 and surprises people. */
    public string get_description () {
        return "%d × %d image, from twelve %d × %d frames".printf (
            image_width (), image_height (), tile_width (), tile_height ());
    }

    /** Every size, in the order the Preferences dropdown lists them. */
    public static CollageSize[] all () {
        return { HD_720, FHD_1080, QHD_2K, UHD_4K };
    }
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

// ── Preview Hardware Decoding ────────────────────────────────────────────────

/**
 * Which decoder the preview players ask mpv for.
 *
 * Stored as the token from to_string (), never as the dropdown index: the
 * order of the rows is a presentation detail, and an index would silently
 * change everyone's decoder the first time the list is reordered.
 *
 * to_mpv_option () is deliberately the only place the mpv spelling appears.
 * Every mode below is a "-copy" variant because the preview renders in
 * software and needs frames in system memory — see MpvBackend.apply_options.
 * If a GPU render path is ever added, the copy suffixes come off here and
 * nowhere else, and stored settings keep working untouched.
 */
public enum HwdecMode {
    AUTOMATIC,
    AUTOMATIC_NO_VULKAN,
    VAAPI,
    NVDEC,
    VULKAN,
    OFF;

    public string to_string () {
        switch (this) {
            case AUTOMATIC_NO_VULKAN: return "auto_no_vulkan";
            case VAAPI:               return "vaapi";
            case NVDEC:               return "nvdec";
            case VULKAN:              return "vulkan";
            case OFF:                 return "off";
            default:                  return "auto";
        }
    }

    public static HwdecMode from_string (string val) {
        switch (val.down ().strip ()) {
            case "auto_no_vulkan": return AUTOMATIC_NO_VULKAN;
            case "vaapi":          return VAAPI;
            case "nvdec":          return NVDEC;
            case "vulkan":         return VULKAN;
            case "off":            return OFF;
            default:               return AUTOMATIC;
        }
    }

    /**
     * The value handed to mpv's "hwdec" option.
     *
     * mpv accepts a comma-separated priority list and skips entries the machine
     * cannot provide, falling back to software decoding when none of them work
     * — which is what makes AUTOMATIC_NO_VULKAN portable rather than a
     * one-machine workaround. Verified against mpv 2.5.0.
     */
    public string to_mpv_option () {
        switch (this) {
            // Every hardware decoder except Vulkan, in the order mpv's own
            // auto-safe list prefers them. The escape hatch for the AV1/RADV
            // abort in docs/mpv-hwdec-vulkan-crash.md that still leaves an
            // NVIDIA or Intel machine hardware-decoding.
            case AUTOMATIC_NO_VULKAN:
                return "vaapi-copy,nvdec-copy,cuda-copy,amf-copy,no";
            case VAAPI:   return "vaapi-copy";
            case NVDEC:   return "nvdec-copy";
            case VULKAN:  return "vulkan-copy";
            case OFF:     return "no";
            // "safe" restricts mpv to the decoders it considers reliable, which
            // matters because this runs on hardware the project cannot test.
            default:      return "auto-copy-safe";
        }
    }

    public string get_label () {
        switch (this) {
            case AUTOMATIC_NO_VULKAN: return "Automatic, skip Vulkan";
            case VAAPI:               return "VAAPI (AMD / Intel)";
            case NVDEC:               return "NVDEC (NVIDIA)";
            case VULKAN:              return "Vulkan";
            case OFF:                 return "Off — software decoding";
            default:                  return "Automatic (recommended)";
        }
    }

    /**
     * Kept to roughly one line each. The row splits its width between this and
     * the selected value, so a description that wraps to two lines ellipsises
     * the value itself — leaving the user unable to read which mode is set,
     * which matters more than the extra sentence.
     */
    public string get_description () {
        switch (this) {
            case AUTOMATIC_NO_VULKAN:
                return "Every hardware decoder except Vulkan, which some drivers botch";
            case VAAPI:
                return "Force VAAPI, the usual choice on AMD and Intel graphics";
            case NVDEC:
                return "Force NVDEC, the usual choice on NVIDIA graphics";
            case VULKAN:
                return "Force Vulkan. Not all drivers decode reliably through it";
            case OFF:
                return "Decode previews on the CPU only — slower, and the last resort";
            default:
                return "Let mpv pick a decoder it considers reliable on this machine";
        }
    }

    /** Every mode, in the order the Preferences dropdown lists them. */
    public static HwdecMode[] all () {
        return { AUTOMATIC, AUTOMATIC_NO_VULKAN, VAAPI, NVDEC, VULKAN, OFF };
    }
}

// ── Preview Scaler Quality ───────────────────────────────────────────────────

/**
 * How much CPU the preview players spend converting and scaling each frame.
 *
 * The preview renders in software, so this is paid per frame on one CPU thread
 * — which is why Fast is the default and stays that way. Accurate exists
 * because judging banding, crop edges and chroma artifacts is the whole point
 * of previewing a conversion, and bilinear with no dithering hides all three.
 *
 * Both modes set every option explicitly rather than Fast applying mpv's
 * "sw-fast" profile. A profile cannot be un-applied at runtime, and this
 * setting has to be changeable in both directions on an open player. The Fast
 * values below are exactly what "mpv --show-profile=sw-fast" prints for
 * mpv 2.5.0, with the chroma scaler added because sw-fast leaves it at mpv's
 * default and Accurate raises it.
 */
public enum PreviewQuality {
    FAST,
    ACCURATE;

    public string to_string () {
        switch (this) {
            case ACCURATE: return "accurate";
            default:       return "fast";
        }
    }

    public static PreviewQuality from_string (string val) {
        switch (val.down ().strip ()) {
            case "accurate": return ACCURATE;
            default:         return FAST;
        }
    }

    public string get_label () {
        switch (this) {
            case ACCURATE: return "Accurate";
            default:       return "Fast";
        }
    }

    public string get_description () {
        switch (this) {
            case ACCURATE:
                return "Sharper scaling and dithering. Costs CPU on every frame";
            default:
                return "Cheapest scaling, for previews that must stay smooth";
        }
    }

    /**
     * Flat name/value pairs for mpv, applied in order.
     *
     * mpv converts with zimg where it can and libswscale otherwise
     * (sws-allow-zimg defaults to yes), so both families have to be set or the
     * mode only half applies depending on the source pixel format.
     */
    public string[] to_mpv_options () {
        switch (this) {
            case ACCURATE:
                return {
                    "sws-scaler",         "lanczos",
                    "sws-fast",           "no",
                    "zimg-scaler",        "lanczos",
                    "zimg-scaler-chroma", "lanczos",
                    "zimg-dither",        "error-diffusion",
                    "zimg-fast",          "no"
                };
            default:
                return {
                    "sws-scaler",         "bilinear",
                    "sws-fast",           "yes",
                    "zimg-scaler",        "bilinear",
                    "zimg-scaler-chroma", "bilinear",
                    "zimg-dither",        "no",
                    "zimg-fast",          "yes"
                };
        }
    }

    /** Every mode, in the order the Preferences dropdown lists them. */
    public static PreviewQuality[] all () {
        return { FAST, ACCURATE };
    }
}

// ── Preview Demuxer Cache ────────────────────────────────────────────────────

/**
 * How much of the input the preview players keep buffered.
 *
 * This is a memory bound first and a performance setting second. Read-ahead is
 * what makes scrubbing feel immediate on slow or network storage, but every
 * byte of it is resident memory — and an unbounded demuxer is the exact
 * pathology this backend was written to escape (see
 * docs/upstream-gstreamer-playbin3-matroska-memory.md). Small is therefore the
 * default and is the value the backend used before this was configurable.
 *
 * The back buffer is half the forward one throughout, which is the ratio the
 * original fixed pair used.
 */
public enum PreviewCacheSize {
    SMALL,
    MEDIUM,
    LARGE;

    public string to_string () {
        switch (this) {
            case MEDIUM: return "medium";
            case LARGE:  return "large";
            default:     return "small";
        }
    }

    public static PreviewCacheSize from_string (string val) {
        switch (val.down ().strip ()) {
            case "medium": return MEDIUM;
            case "large":  return LARGE;
            default:       return SMALL;
        }
    }

    /** mpv's "demuxer-max-bytes". */
    public string forward_bytes () {
        switch (this) {
            case MEDIUM: return "128MiB";
            case LARGE:  return "512MiB";
            default:     return "32MiB";
        }
    }

    /** mpv's "demuxer-max-back-bytes", kept at half the forward buffer. */
    public string back_bytes () {
        switch (this) {
            case MEDIUM: return "64MiB";
            case LARGE:  return "256MiB";
            default:     return "16MiB";
        }
    }

    public string get_label () {
        switch (this) {
            case MEDIUM: return "Medium (128 MiB)";
            case LARGE:  return "Large (512 MiB)";
            default:     return "Small (32 MiB)";
        }
    }

    public string get_description () {
        switch (this) {
            case MEDIUM:
                return "More read-ahead, for large files or slower disks";
            case LARGE:
                return "Most read-ahead, for network or multi-gigabyte sources";
            default:
                return "Least memory, and enough for local files on a fast disk";
        }
    }

    /** Every size, in the order the Preferences dropdown lists them. */
    public static PreviewCacheSize[] all () {
        return { SMALL, MEDIUM, LARGE };
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
