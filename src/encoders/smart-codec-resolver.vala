// Complete Smart Optimizer recommendation application, expressed as data so
// ordinary codec tabs and sequential jobs use the same encoder policy.
public class SmartCodecResolution : Object {
    public string codec_name = "";
    public Object builder_settings;
    public CodecTabSettingsSnapshot codec_settings = new CodecTabSettingsSnapshot ();
    public GeneralSettingsSnapshot? general_settings = null;
    public bool two_pass = false;

    public EncodeProfileSnapshot to_profile () {
        return CodecUtils.compose_encode_profile (
            codec_name, build_codec_args (), codec_settings, general_settings);
    }

    private string[] build_codec_args () {
        if (builder_settings is X264BuilderSnapshot)
            return X264Builder.build_args_from_snapshot ((X264BuilderSnapshot) builder_settings);
        else if (builder_settings is X265BuilderSnapshot)
            return X265Builder.build_args_from_snapshot ((X265BuilderSnapshot) builder_settings);
        else if (builder_settings is Vp9BuilderSnapshot)
            return Vp9Builder.build_args_from_snapshot ((Vp9BuilderSnapshot) builder_settings);
        else if (builder_settings is SvtAv1BuilderSnapshot)
            return SvtAv1Builder.build_args_from_snapshot ((SvtAv1BuilderSnapshot) builder_settings);
        return {};
    }
}

public class SmartCodecResolver : Object {
    public static SmartCodecResolution? resolve (
        OptimizationRecommendation rec,
        CodecTabSettingsSnapshot requested,
        GeneralSettingsSnapshot? general_settings = null,
        bool audio_copy_allowed = true,
        bool strip_audio = false) {
        string codec = (rec.codec ?? "").down ();
        if (codec != "x264" && codec != "x265"
                && codec != "vp9" && codec != "svt-av1")
            return null;

        var result = new SmartCodecResolution ();
        result.codec_name = codec == "vp9" ? "VP9"
            : codec == "svt-av1" ? "SVT-AV1" : codec;
        result.two_pass = rec.two_pass && rec.target_bitrate_kbps > 0;
        result.general_settings = general_settings != null ? general_settings.copy () : null;
        if (result.general_settings != null && rec.strip_metadata)
            result.general_settings.preserve_metadata = false;

        // The ordinary appliers reset codec/audio processing to defaults, but
        // restore the requested container and retain the source observations.
        var settings = result.codec_settings;
        settings.container = rec.force_compat_container
            ? ((codec == "x264" || codec == "x265") ? "mp4" : "webm")
            : requested.container;
        settings.keyframe_settings.keyint_text = rec.keyint_frames > 0
            ? rec.keyint_frames.to_string () : "Auto";
        settings.keyframe_settings.custom_mode = 3;
        if (result.general_settings != null) {
            settings.keyframe_settings.frame_rate_text = result.general_settings.frame_rate_text;
            settings.keyframe_settings.custom_frame_rate_text = result.general_settings.custom_frame_rate_text;
        }
        bool effective_copy_allowed = audio_copy_allowed;
        if (result.general_settings != null) {
            effective_copy_allowed = effective_copy_allowed
                && Math.fabs (FilterBuilder.get_audio_speed_multiplier (
                    result.general_settings) - 1.0) < 1e-9;
        }
        settings.audio_settings = resolve_audio (rec, requested.audio_settings,
            effective_copy_allowed, strip_audio);

        bool has_recommended_format = rec.recommended_pix_fmt != null
            && rec.recommended_pix_fmt.length > 0;
        bool ten_bit = has_recommended_format && rec.recommended_pix_fmt.contains ("10");
        // The normal appliers choose 4:2:0-only profiles for these codecs.
        // SVT's selector is also restricted to 4:2:0 under its Auto profile.
        if (codec == "x264" || has_recommended_format) {
            if (codec != "svt-av1" || is_known_pixel_format (rec.recommended_pix_fmt))
                settings.pixel_format = CodecUtils.pixel_format_settings_from_ffmpeg_pix_fmt (
                    ten_bit ? PixelFormat.YUV420P10LE : PixelFormat.YUV420P);
        }
        if (result.general_settings != null) {
            result.general_settings.pixel_format = settings.pixel_format.copy ();
            result.general_settings.video_filters.select_bit_depth (
                settings.pixel_format.ten_bit_selected);
        }

        switch (codec) {
            case "x264":
                result.builder_settings = resolve_x264 (rec, result);
                break;
            case "x265":
                result.builder_settings = resolve_x265 (rec, result, has_recommended_format, ten_bit);
                break;
            case "vp9":
                result.builder_settings = resolve_vp9 (rec, result, has_recommended_format, ten_bit);
                break;
            case "svt-av1":
                result.builder_settings = resolve_svt_av1 (rec, result);
                break;
        }
        return result;
    }

    private static bool is_known_pixel_format (string? pix_fmt) {
        var selection = CodecUtils.pixel_format_settings_from_ffmpeg_pix_fmt (pix_fmt);
        return selection.eight_bit_selected || selection.ten_bit_selected;
    }

    private static int select_audio_bitrate (int requested_kbps) {
        // Match the old dropdown: a non-selectable malformed value leaves the
        // reset 128 kbps selection alone rather than inventing a new rung.
        foreach (int kbps in AudioCodecOptions.bitrate_values ()) {
            if (kbps == requested_kbps)
                return kbps;
        }
        return 128;
    }

    private static int fallback_audio_kbps (EncodeEffort effort) {
        switch (effort) {
            case EncodeEffort.MINIMAL: return 64;
            case EncodeEffort.LOW: return 128;
            case EncodeEffort.MEDIUM: return 192;
            case EncodeEffort.HIGH: return 256;
            case EncodeEffort.MAXIMUM: return 320;
            default: return 128;
        }
    }

    private static AudioSettingsSnapshot resolve_audio (
        OptimizationRecommendation rec,
        AudioSettingsSnapshot requested,
        bool copy_allowed,
        bool strip_audio) {
        var audio = new AudioSettingsSnapshot ();
        AudioSettingsSnapshot source_copy = requested.copy ();
        audio.source = source_copy.source;
        audio.all_sources = source_copy.all_sources;
        audio.enabled = !strip_audio && audio.source.presence != MediaStreamPresence.ABSENT;
        audio.preserve_all_audio_tracks = rec.preserve_all_audio_tracks_effective;
        if (rec.stream_copy_audio && copy_allowed) {
            audio.codec = AudioCodecName.COPY;
            return audio;
        }

        audio.codec = rec.resolved_container == "webm" ? AudioCodecName.OPUS : AudioCodecName.AAC;
        if (rec.stream_copy_audio && rec.recommended_audio_kbps > 0) {
            audio.bitrate_kbps = select_audio_bitrate (
                SmartOptimizerLogic.snap_audio_kbps_up (rec.recommended_audio_kbps));
        } else {
            audio.bitrate_kbps = select_audio_bitrate (rec.audio_encode_kbps > 0
                ? rec.audio_encode_kbps : fallback_audio_kbps (rec.effort));
        }
        return audio;
    }

    private static string resolve_preset (string? requested) {
        switch (requested) {
            case "ultrafast": case "superfast": case "veryfast": case "faster":
            case "fast": case "medium": case "slow": case "slower":
            case "veryslow": case "placebo":
                return requested;
            default:
                return "medium";
        }
    }

    private static X264BuilderSnapshot resolve_x264 (
        OptimizationRecommendation rec, SmartCodecResolution result) {
        var snapshot = new X264BuilderSnapshot ();
        snapshot.general_settings = result.general_settings;
        snapshot.preset = resolve_preset (rec.preset);
        snapshot.profile = result.codec_settings.pixel_format.ten_bit_selected ? "High10" : "High";
        snapshot.abr_bitrate_kbps = 2000;
        snapshot.cbr_bitrate_kbps = 2000;
        snapshot.crf = result.two_pass ? 23 : int.max (0, int.min (51, rec.crf));
        snapshot.rc_mode = result.two_pass ? RateControl.ABR : RateControl.CRF;
        if (result.two_pass) {
            snapshot.abr_bitrate_kbps = int.max (100, int.min (50000, rec.target_bitrate_kbps));
            snapshot.abr_vbv = true;
        }
        var tuning = SmartOptimizerLogic.decide_encoder_tuning (
            "x264", rec.effort, rec.content_type, rec.grain_score,
            rec.detail_score, rec.source_bit_depth, rec.fast_decode);
        snapshot.tune = tuning.tune.length > 0 ? tuning.tune : "Auto";
        snapshot.cabac = true;
        snapshot.mbtree = true;
        snapshot.weightp = true;
        snapshot.deblock_enabled = true;
        snapshot.psy_rd_enabled = true;
        snapshot.b_adapt = 2;
        snapshot.psy_rd = 1.0;
        switch (rec.effort) {
            case EncodeEffort.MINIMAL:
                snapshot.ref_frames = "3";
                snapshot.bframes = 3;
                snapshot.me = "hex";
                snapshot.subme = 7;
                snapshot.me_range = 16;
                snapshot.psy_trellis = 0.0;
                break;
            case EncodeEffort.LOW:
                snapshot.ref_frames = "4";
                snapshot.bframes = 4;
                snapshot.me = "hex";
                snapshot.subme = 8;
                snapshot.me_range = 16;
                snapshot.psy_trellis = 0.1;
                break;
            case EncodeEffort.MEDIUM:
                snapshot.ref_frames = "5";
                snapshot.bframes = 5;
                snapshot.me = "umh";
                snapshot.subme = 9;
                snapshot.me_range = 24;
                snapshot.psy_trellis = 0.15;
                break;
            case EncodeEffort.HIGH:
                snapshot.ref_frames = "6";
                snapshot.bframes = 6;
                snapshot.me = "umh";
                snapshot.subme = 10;
                snapshot.me_range = 32;
                snapshot.deblock_alpha = -1;
                snapshot.deblock_beta = -1;
                snapshot.psy_trellis = 0.2;
                snapshot.open_gop = true;
                break;
            case EncodeEffort.MAXIMUM:
                snapshot.ref_frames = "8";
                snapshot.bframes = 8;
                snapshot.me = "umh";
                snapshot.subme = 11;
                snapshot.me_range = 32;
                snapshot.deblock_alpha = -1;
                snapshot.deblock_beta = -1;
                snapshot.psy_trellis = 0.25;
                snapshot.open_gop = true;
                break;
        }
        snapshot.keyint_text = result.codec_settings.keyframe_settings.keyint_text;
        snapshot.lookahead_enabled = rec.lookahead_frames > 0;
        if (snapshot.lookahead_enabled)
            snapshot.lookahead = int.min (250, rec.lookahead_frames);
        return snapshot;
    }

    private static X265BuilderSnapshot resolve_x265 (
        OptimizationRecommendation rec, SmartCodecResolution result,
        bool has_recommended_format, bool ten_bit) {
        var snapshot = new X265BuilderSnapshot ();
        snapshot.general_settings = result.general_settings;
        snapshot.preset = resolve_preset (rec.preset);
        snapshot.profile = has_recommended_format ? (ten_bit ? "Main10" : "Main") : "Auto";
        snapshot.crf = result.two_pass ? 28 : int.max (0, int.min (51, rec.crf));
        snapshot.rc_mode = result.two_pass ? RateControl.ABR : RateControl.CRF;
        if (result.two_pass) {
            snapshot.abr_bitrate_kbps = int.max (100, int.min (50000, rec.target_bitrate_kbps));
            snapshot.abr_vbv = true;
        }
        var tuning = SmartOptimizerLogic.decide_encoder_tuning (
            "x265", rec.effort, rec.content_type, rec.grain_score,
            rec.detail_score, rec.source_bit_depth, rec.fast_decode);
        snapshot.tune = tuning.tune.length > 0 ? tuning.tune : "Auto";
        snapshot.sao = true;
        snapshot.deblock_enabled = true;
        snapshot.psy_rd_enabled = true;
        snapshot.cutree = true;
        snapshot.weightp = true;
        snapshot.psy_rd = double.max (0.0, double.min (5.0, tuning.psy_rd));
        switch (rec.effort) {
            case EncodeEffort.MINIMAL: snapshot.ref_frames = "3"; break;
            case EncodeEffort.LOW: snapshot.ref_frames = "4"; break;
            case EncodeEffort.MEDIUM:
                snapshot.ref_frames = "4";
                snapshot.pmode = true; break;
            case EncodeEffort.HIGH:
            case EncodeEffort.MAXIMUM:
                snapshot.ref_frames = "5";
                snapshot.pmode = true;
                snapshot.deblock_alpha = -1;
                snapshot.deblock_beta = -1;
                break;
        }
        snapshot.keyint_text = result.codec_settings.keyframe_settings.keyint_text;
        snapshot.lookahead = rec.lookahead_frames > 0 ? int.min (250, rec.lookahead_frames) : 40;
        snapshot.lookahead_enabled = rec.lookahead_frames > 0;
        return snapshot;
    }

    private static Vp9BuilderSnapshot resolve_vp9 (
        OptimizationRecommendation rec, SmartCodecResolution result,
        bool has_recommended_format, bool ten_bit) {
        var snapshot = new Vp9BuilderSnapshot ();
        snapshot.general_settings = result.general_settings;
        snapshot.profile = has_recommended_format
            ? (ten_bit ? "Profile 2 (10-bit 4:2:0)" : "Profile 0 (8-bit 4:2:0)") : "Auto";
        snapshot.speed = int.max (0, int.min (8, int.parse ((rec.preset ?? "").replace ("cpu-used ", ""))));
        snapshot.crf = result.two_pass ? 31 : int.max (0, int.min (63, rec.crf));
        snapshot.cq_bitrate_kbps = 2000;
        snapshot.vbr_bitrate_kbps = result.two_pass
            ? int.max (100, int.min (50000, rec.target_bitrate_kbps)) : 2000;
        snapshot.cbr_bitrate_kbps = 2000;
        snapshot.rc_mode = result.two_pass ? RateControl.VBR : RateControl.CRF;
        snapshot.tune_content = rec.content_type == ContentType.SCREENCAST ? "Screen" : "Default";
        snapshot.sharpness_enabled = rec.native_sharpness > 0;
        snapshot.sharpness = snapshot.sharpness_enabled ? int.min (7, rec.native_sharpness) : 1;
        snapshot.row_mt = true;
        snapshot.frame_parallel = false;
        snapshot.altref_enabled = true;
        snapshot.aq_mode = rec.effort == EncodeEffort.MINIMAL ? "Automatic" : "Complexity";
        switch (rec.effort) {
            case EncodeEffort.MINIMAL:
            case EncodeEffort.LOW:
                snapshot.arnr_maxframes = 7;
                snapshot.arnr_strength = 5; break;
            case EncodeEffort.MEDIUM:
                snapshot.arnr_maxframes = 9;
                snapshot.arnr_strength = 6; break;
            case EncodeEffort.HIGH:
                snapshot.arnr_maxframes = 12;
                snapshot.arnr_strength = 6; break;
            case EncodeEffort.MAXIMUM:
                snapshot.arnr_maxframes = 15;
                snapshot.arnr_strength = 6; break;
        }
        snapshot.keyint_text = result.codec_settings.keyframe_settings.keyint_text;
        snapshot.lookahead_enabled = rec.lookahead_frames > 0;
        snapshot.lag_in_frames = snapshot.lookahead_enabled ? int.min (25, rec.lookahead_frames) : 25;
        snapshot.undershoot = 25;
        snapshot.overshoot = 25;
        return snapshot;
    }

    private static SvtAv1BuilderSnapshot resolve_svt_av1 (
        OptimizationRecommendation rec, SmartCodecResolution result) {
        var snapshot = new SvtAv1BuilderSnapshot ();
        snapshot.general_settings = result.general_settings;
        snapshot.preset = int.max (0, int.min (13, int.parse ((rec.preset ?? "").replace ("preset ", ""))));
        snapshot.crf = result.two_pass ? 28 : int.max (0, int.min (63, rec.crf));
        snapshot.rc_mode = result.two_pass ? RateControl.VBR : RateControl.CRF;
        if (result.two_pass)
            snapshot.vbr_bitrate_kbps = int.max (100, int.min (50000, rec.target_bitrate_kbps));
        var tuning = SmartOptimizerLogic.decide_encoder_tuning (
            "svt-av1", rec.effort, rec.content_type, rec.grain_score,
            rec.detail_score, rec.source_bit_depth, rec.fast_decode);
        snapshot.fast_decode = tuning.fast_decode_level > 0
            ? "Level %d".printf (tuning.fast_decode_level) : "Disabled";
        snapshot.grain_enabled = rec.effort != EncodeEffort.MINIMAL && tuning.film_grain;
        snapshot.grain_strength = snapshot.grain_enabled
            ? int.max (0, int.min (50, tuning.film_grain_strength)) : 0;
        snapshot.grain_denoise_selected = snapshot.grain_enabled ? 1 : 0;
        snapshot.sharpness_enabled = rec.native_sharpness > 0;
        snapshot.sharpness = snapshot.sharpness_enabled ? int.min (7, rec.native_sharpness) : 1;
        snapshot.qm_enabled = rec.effort >= EncodeEffort.MEDIUM;
        snapshot.qm_max = rec.effort == EncodeEffort.MEDIUM ? 12
            : rec.effort == EncodeEffort.HIGH ? 13
            : rec.effort == EncodeEffort.MAXIMUM ? 15 : 11;
        snapshot.keyint_text = result.codec_settings.keyframe_settings.keyint_text;
        snapshot.lookahead_enabled = rec.lookahead_frames > 0;
        snapshot.lookahead = snapshot.lookahead_enabled ? int.min (120, rec.lookahead_frames) : 35;
        return snapshot;
    }
}
