using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  AudioExtractConfig — Snapshot of all audio extraction settings
//
//  Captured on the main thread before spawning background work, so the
//  runner never touches UI widgets directly.
// ═══════════════════════════════════════════════════════════════════════════════

public class AudioExtractConfig : Object {
    // ── Mode ─────────────────────────────────────────────────────────────────
    public bool copy_mode { get; set; default = true; }
    public AudioSourceInfo source_audio { get; set; default = new AudioSourceInfo (); }

    // ── Codec settings (transcode only) ──────────────────────────────────────
    public AudioSettingsSnapshot audio_settings { get; set; default = new AudioSettingsSnapshot (); }

    // ── Processing options ───────────────────────────────────────────────────
    public AudioProcessingSettingsSnapshot processing { get; set; default = new AudioProcessingSettingsSnapshot (); }
    public bool strip_metadata { get; set; default = false; }

    // ── Source info ─────────────────────────────────────────────────────────
    public int source_audio_index {
        get { return source_audio.stream_index; }
        set { source_audio.stream_index = value; }
    }

    public int source_channels {
        get { return source_audio.channels; }
        set { source_audio.channels = value; }
    }

    public bool normalize_enabled {
        get { return processing.normalize_enabled; }
        set { processing.normalize_enabled = value; }
    }

    public bool normalize_ebu {
        get { return processing.normalize_ebu; }
        set { processing.normalize_ebu = value; }
    }

    public double peak_normalize_gain_db {
        get { return processing.peak_normalize_gain_db; }
        set { processing.peak_normalize_gain_db = value; }
    }

    public bool fade_in_enabled {
        get { return processing.fade_in_enabled; }
        set { processing.fade_in_enabled = value; }
    }

    public double fade_in_duration {
        get { return processing.fade_in_duration; }
        set { processing.fade_in_duration = value; }
    }

    public bool fade_out_enabled {
        get { return processing.fade_out_enabled; }
        set { processing.fade_out_enabled = value; }
    }

    public double fade_out_duration {
        get { return processing.fade_out_duration; }
        set { processing.fade_out_duration = value; }
    }

    public int channel_downmix {
        get { return processing.channel_downmix; }
        set { processing.channel_downmix = value; }
    }

    // ── Segments ─────────────────────────────────────────────────────────────
    public bool export_separate { get; set; default = false; }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  AudioStreamInfo — Probed audio stream data for Extract All Tracks
// ═══════════════════════════════════════════════════════════════════════════════

public class AudioStreamInfo : Object {
    public int audio_index { get; set; default = 0; }
    public string codec_name { get; set; default = ""; }
    public int channels { get; set; default = 0; }
    public int sample_rate { get; set; default = 0; }
    public string sample_fmt { get; set; default = ""; }
    public int bits_per_raw_sample { get; set; default = 0; }
    public string language { get; set; default = ""; }

    public string display_label () {
        var parts = new GenericArray<string> ();
        parts.add ("#%d".printf (audio_index + 1));
        if (codec_name.length > 0) parts.add (codec_name);
        if (channels > 0) parts.add ("%dch".printf (channels));
        if (sample_rate > 0) parts.add ("%d Hz".printf (sample_rate));
        if (language.length > 0 && language != "und") parts.add (language);
        return string.joinv ("  ·  ", StringArrayUtils.copy_generic_array (parts));
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  AudioBuilder — Builds FFmpeg arguments for audio extraction
// ═══════════════════════════════════════════════════════════════════════════════

namespace AudioBuilder {

    private AudioSettingsSnapshot get_audio_settings (AudioExtractConfig config) {
        return config.audio_settings;
    }

    private void append_primary_audio_map (GenericArray<string> cmd,
                                           AudioExtractConfig config) {
        cmd.add ("-map");
        cmd.add ("0:a:%d".printf (config.source_audio_index));
    }

    private string build_filter_chain_for_segment_internal (AudioExtractConfig config,
                                                            double duration,
                                                            bool apply_fade_in,
                                                            bool apply_fade_out,
                                                            bool include_normalization) {
        string filters = AudioProcessingSettings.build_filter_chain_from_snapshot (
            config.processing,
            duration,
            include_normalization,
            apply_fade_in,
            apply_fade_out
        );

        return filters;
    }

    private void append_peak_analysis_output_args (GenericArray<string> cmd,
                                                   AudioExtractConfig config) {
        AudioSettingsSnapshot audio = get_audio_settings (config);

        // Mirror only output channel-count transforms that affect the decoded
        // analysis stream. Encoder-facing sample format / bit-depth flags are
        // intentionally excluded because the null muxer uses pcm_s16le.
        if (config.channel_downmix == 1) {
            cmd.add ("-ac");
            cmd.add ("2");
        } else if (config.channel_downmix == 2) {
            cmd.add ("-ac");
            cmd.add ("1");
        } else if (audio.codec == AudioCodecName.OPUS
                   && audio.opus_surround_fix
                   && config.source_channels > 2) {
            cmd.add ("-ac");
            cmd.add ("2");
        }
    }

    /**
     * Get the output file extension for a given audio codec name.
     */
    public string get_extension_for_codec (string codec_name) {
        return AudioSourceLogic.get_copy_extension_for_codec_name (codec_name);
    }

    /**
     * Get the output extension based on the selected codec in transcode mode,
     * or based on the source codec in copy mode.
     */
    public string get_output_extension (AudioExtractConfig config,
                                        string source_codec,
                                        int segment_count = 0) {
        if (config.copy_mode) {
            if (segment_count > 0) {
                string effective_source_codec =
                    (config.source_audio.codec_name.length > 0)
                    ? config.source_audio.codec_name
                    : source_codec;
                if (AudioCompatibilityLogic.normalize_source_audio_codec_name (
                        effective_source_codec) == "opus") {
                    // Stream-copying trimmed Opus directly to .opus can produce
                    // invalid Ogg granule positions. Use Matroska instead.
                    return ".mka";
                }
            }
            if (config.source_audio.codec_name.length > 0) {
                return AudioSourceLogic.get_copy_extension (config.source_audio);
            }
            return AudioSourceLogic.get_copy_extension_for_codec_name (source_codec);
        }
        return get_extension_for_codec (get_audio_settings (config).codec);
    }

    /**
     * Build the audio codec arguments for transcoding.
     */
    public string[] build_codec_args (AudioExtractConfig config) {
        if (config.copy_mode) {
            return { "-c:a", "copy" };
        }

        return AudioSettings.build_transcode_args_from_snapshot (
            get_audio_settings (config),
            false,
            config.processing.channel_downmix
        );
    }

    /**
     * Build the -af audio filter chain for a single segment or full file.
     *
     * @param apply_fade_in  Whether to apply fade-in (false for non-first segments in concat)
     * @param apply_fade_out Whether to apply fade-out (false for non-last segments in concat)
     * Returns "" if no filters are needed.
     */
    public string build_filter_chain_for_segment (AudioExtractConfig config,
                                                   double duration,
                                                   bool apply_fade_in,
                                                   bool apply_fade_out) {
        return build_filter_chain_for_segment_internal (
            config, duration, apply_fade_in, apply_fade_out, true);
    }

    /**
     * Build the filter chain used for peak-normalization analysis.
     * This keeps all non-normalization transforms so the measured peak matches
     * the requested output pipeline as closely as possible.
     */
    public string build_analysis_filter_chain_for_segment (AudioExtractConfig config,
                                                            double duration,
                                                            bool apply_fade_in,
                                                            bool apply_fade_out) {
        return build_filter_chain_for_segment_internal (
            config, duration, apply_fade_in, apply_fade_out, false);
    }

    /**
     * Build the -af audio filter chain from processing options.
     * Returns "" if no filters are needed.
     */
    public string build_filter_chain (AudioExtractConfig config, double total_duration) {
        return build_filter_chain_for_segment (config, total_duration, true, true);
    }

    /**
     * Build extra output arguments for processing options that aren't filters.
     */
    public string[] build_processing_args (AudioExtractConfig config,
                                           bool include_metadata = true) {
        AudioSettingsSnapshot audio = get_audio_settings (config);
        var args = new GenericArray<string> ();

        foreach (unowned string arg in AudioProcessingSettings.build_output_args_from_snapshot (
            config.processing)) {
            args.add (arg);
        }

        // Sample format / bit depth
        // - WAV: bit depth is set via PCM codec name in build_codec_args()
        // - FLAC: only supports s16 and s32; 24-bit = s32 + bits_per_raw_sample 24
        // - Lossy codecs (Opus/AAC/MP3/Vorbis): auto-convert to their native
        //   format, so -sample_fmt is only useful for Opus (s16/flt) and
        //   MP3 (s16p/s32p/fltp); skip for AAC/Vorbis (fltp-only).
        foreach (unowned string arg in AudioSettings.build_sample_format_args_for_snapshot (audio)) {
            args.add (arg);
        }

        // Metadata
        if (include_metadata && config.strip_metadata) {
            args.add ("-map_metadata");
            args.add ("-1");
        }

        return StringArrayUtils.copy_generic_array (args);
    }

    /**
     * Build a complete FFmpeg command for basic extraction (no segments).
     */
    public string[] build_basic_extract_cmd (string input_file,
                                              string output_file,
                                              AudioExtractConfig config,
                                              double total_duration) {
        var cmd = new GenericArray<string> ();
        cmd.add (AppSettings.get_default ().ffmpeg_path);
        cmd.add ("-y");
        cmd.add ("-i");
        cmd.add (input_file);
        cmd.add ("-vn");
        cmd.add ("-sn");
        append_primary_audio_map (cmd, config);

        // Audio filter chain
        if (!config.copy_mode) {
            string filters = build_filter_chain (config, total_duration);
            if (filters.length > 0) {
                cmd.add ("-af");
                cmd.add (filters);
            }
        }

        // Codec args
        foreach (unowned string arg in build_codec_args (config)) {
            cmd.add (arg);
        }

        // Processing args
        if (!config.copy_mode) {
            foreach (unowned string arg in build_processing_args (config)) {
                cmd.add (arg);
            }
        } else {
            // In copy mode, still allow metadata stripping
            if (config.strip_metadata) {
                cmd.add ("-map_metadata");
                cmd.add ("-1");
            }
        }

        cmd.add ("-progress");
        cmd.add ("pipe:2");
        cmd.add (output_file);
        return StringArrayUtils.copy_generic_array (cmd);
    }

    /**
     * Build a single-segment extraction command.
     */
    public string[] build_segment_extract_cmd (string input_file,
                                                string output_file,
                                                AudioExtractConfig config,
                                                double seg_start,
                                                double seg_duration) {
        var cmd = new GenericArray<string> ();
        cmd.add (AppSettings.get_default ().ffmpeg_path);
        cmd.add ("-y");

        // Input seeking
        cmd.add ("-ss");
        cmd.add (ConversionUtils.format_ffmpeg_double (seg_start, "%.6f"));
        cmd.add ("-i");
        cmd.add (input_file);
        cmd.add ("-t");
        cmd.add (ConversionUtils.format_ffmpeg_double (seg_duration, "%.6f"));

        cmd.add ("-vn");
        cmd.add ("-sn");
        append_primary_audio_map (cmd, config);

        // Audio filter chain
        if (!config.copy_mode) {
            string filters = build_filter_chain (config, seg_duration);
            if (filters.length > 0) {
                cmd.add ("-af");
                cmd.add (filters);
            }
        }

        // Codec args
        foreach (unowned string arg in build_codec_args (config)) {
            cmd.add (arg);
        }

        // Processing args
        if (!config.copy_mode) {
            foreach (unowned string arg in build_processing_args (config)) {
                cmd.add (arg);
            }
        } else {
            if (config.strip_metadata) {
                cmd.add ("-map_metadata");
                cmd.add ("-1");
            }
        }

        cmd.add ("-progress");
        cmd.add ("pipe:2");
        cmd.add (output_file);
        return StringArrayUtils.copy_generic_array (cmd);
    }

    /**
     * Build a concat filter command for multi-segment combined output (transcode only).
     */
    public string[] build_concat_filter_cmd (string input_file,
                                              string output_file,
                                              AudioExtractConfig config,
                                              GenericArray<AudioSegment> segments) {
        var cmd = new GenericArray<string> ();
        cmd.add (AppSettings.get_default ().ffmpeg_path);
        cmd.add ("-y");

        // Open each segment as a separate input
        for (int i = 0; i < segments.length; i++) {
            var seg = segments[i];
            cmd.add ("-ss");
            cmd.add (ConversionUtils.format_ffmpeg_double (seg.start_time, "%.6f"));
            cmd.add ("-t");
            cmd.add (ConversionUtils.format_ffmpeg_double (seg.get_duration (), "%.6f"));
            cmd.add ("-i");
            cmd.add (input_file);
        }

        cmd.add ("-vn");
        cmd.add ("-sn");

        // Build filter_complex
        var fc = new StringBuilder ();
        bool normalize_after_concat = config.normalize_enabled && config.normalize_ebu;
        for (int i = 0; i < segments.length; i++) {
            var seg = segments[i];
            string filters = "";

            if (!config.copy_mode) {
                filters = build_filter_chain_for_segment_internal (
                    config, seg.get_duration (),
                    i == 0,
                    i == segments.length - 1,
                    !normalize_after_concat);
            }

            if (filters.length > 0) {
                fc.append ("[%d:a:%d]%s[a%d];".printf (
                    i, config.source_audio_index, filters, i));
            } else {
                fc.append ("[%d:a:%d]acopy[a%d];".printf (
                    i, config.source_audio_index, i));
            }
        }

        // Concat
        for (int i = 0; i < segments.length; i++) {
            fc.append ("[a%d]".printf (i));
        }
        if (normalize_after_concat) {
            fc.append ("concat=n=%d:v=0:a=1[concat];".printf (segments.length));
            fc.append ("[concat]%s[out]".printf (
                AudioNormalization.EBU_R128_FILTER));
        } else {
            fc.append ("concat=n=%d:v=0:a=1[out]".printf (segments.length));
        }

        cmd.add ("-filter_complex");
        cmd.add (fc.str);
        cmd.add ("-map");
        cmd.add ("[out]");

        // Codec args
        foreach (unowned string arg in build_codec_args (config)) {
            cmd.add (arg);
        }

        // Processing args (non-filter)
        if (!config.copy_mode) {
            foreach (unowned string arg in build_processing_args (config)) {
                cmd.add (arg);
            }
        }

        cmd.add ("-progress");
        cmd.add ("pipe:2");
        cmd.add (output_file);
        return StringArrayUtils.copy_generic_array (cmd);
    }

    public string[] build_basic_peak_detect_cmd (string input_file,
                                                 AudioExtractConfig config,
                                                 double total_duration) {
        var cmd = new GenericArray<string> ();
        cmd.add (AppSettings.get_default ().ffmpeg_path);
        cmd.add ("-hide_banner");
        cmd.add ("-i");
        cmd.add (input_file);
        cmd.add ("-vn");
        cmd.add ("-sn");
        append_primary_audio_map (cmd, config);

        string filters = build_analysis_filter_chain_for_segment (
            config, total_duration, true, true);
        if (filters.length > 0) {
            cmd.add ("-af");
            cmd.add ("%s,volumedetect".printf (filters));
        } else {
            cmd.add ("-af");
            cmd.add ("volumedetect");
        }

        append_peak_analysis_output_args (cmd, config);

        cmd.add ("-f");
        cmd.add ("null");
        cmd.add ("-");
        return StringArrayUtils.copy_generic_array (cmd);
    }

    public string[] build_segment_peak_detect_cmd (string input_file,
                                                   AudioExtractConfig config,
                                                   double seg_start,
                                                   double seg_duration) {
        var cmd = new GenericArray<string> ();
        cmd.add (AppSettings.get_default ().ffmpeg_path);
        cmd.add ("-hide_banner");
        cmd.add ("-ss");
        cmd.add (ConversionUtils.format_ffmpeg_double (seg_start, "%.6f"));
        cmd.add ("-i");
        cmd.add (input_file);
        cmd.add ("-t");
        cmd.add (ConversionUtils.format_ffmpeg_double (seg_duration, "%.6f"));
        cmd.add ("-vn");
        cmd.add ("-sn");
        append_primary_audio_map (cmd, config);

        string filters = build_analysis_filter_chain_for_segment (
            config, seg_duration, true, true);
        if (filters.length > 0) {
            cmd.add ("-af");
            cmd.add ("%s,volumedetect".printf (filters));
        } else {
            cmd.add ("-af");
            cmd.add ("volumedetect");
        }

        append_peak_analysis_output_args (cmd, config);

        cmd.add ("-f");
        cmd.add ("null");
        cmd.add ("-");
        return StringArrayUtils.copy_generic_array (cmd);
    }

    public string[] build_concat_peak_detect_cmd (string input_file,
                                                  AudioExtractConfig config,
                                                  GenericArray<AudioSegment> segments) {
        var cmd = new GenericArray<string> ();
        cmd.add (AppSettings.get_default ().ffmpeg_path);
        cmd.add ("-hide_banner");

        for (int i = 0; i < segments.length; i++) {
            var seg = segments[i];
            cmd.add ("-ss");
            cmd.add (ConversionUtils.format_ffmpeg_double (seg.start_time, "%.6f"));
            cmd.add ("-t");
            cmd.add (ConversionUtils.format_ffmpeg_double (seg.get_duration (), "%.6f"));
            cmd.add ("-i");
            cmd.add (input_file);
        }

        cmd.add ("-vn");
        cmd.add ("-sn");

        var fc = new StringBuilder ();
        for (int i = 0; i < segments.length; i++) {
            var seg = segments[i];
            string filters = build_analysis_filter_chain_for_segment (
                config, seg.get_duration (),
                i == 0,
                i == segments.length - 1);

            if (filters.length > 0) {
                fc.append ("[%d:a:%d]%s[a%d];".printf (
                    i, config.source_audio_index, filters, i));
            } else {
                fc.append ("[%d:a:%d]acopy[a%d];".printf (
                    i, config.source_audio_index, i));
            }
        }

        for (int i = 0; i < segments.length; i++) {
            fc.append ("[a%d]".printf (i));
        }
        fc.append ("concat=n=%d:v=0:a=1[concat];".printf (segments.length));
        fc.append ("[concat]volumedetect[out]");

        cmd.add ("-filter_complex");
        cmd.add (fc.str);
        cmd.add ("-map");
        cmd.add ("[out]");

        append_peak_analysis_output_args (cmd, config);

        cmd.add ("-f");
        cmd.add ("null");
        cmd.add ("-");
        return StringArrayUtils.copy_generic_array (cmd);
    }

    /**
     * Build a command to extract a single track by stream index (for Extract All).
     */
    public string[] build_extract_track_cmd (string input_file,
                                              string output_file,
                                              int audio_index) {
        return {
            AppSettings.get_default ().ffmpeg_path,
            "-y",
            "-i", input_file,
            "-map", "0:a:%d".printf (audio_index),
            "-vn", "-sn",
            "-c:a", "copy",
            "-progress", "pipe:2",
            output_file
        };
    }

    /**
     * Build a command to remove audio from a file.
     * When audio_stream_index >= 0 and multiple streams exist, removes only
     * that stream.  Otherwise removes all audio.
     * Copies video and (optionally) subtitle streams without re-encoding.
     */
    public string[] build_remove_audio_cmd (string input_file,
                                             string output_file,
                                             int audio_stream_index,
                                             int total_audio_streams,
                                             bool keep_subtitles,
                                             bool strip_metadata) {
        var cmd = new GenericArray<string> ();
        cmd.add (AppSettings.get_default ().ffmpeg_path);
        cmd.add ("-y");
        cmd.add ("-i");
        cmd.add (input_file);

        // Map everything, then exclude audio:
        //  - audio_stream_index < 0 → remove ALL audio streams
        //  - single stream          → remove all (same effect)
        //  - otherwise              → remove only the selected stream
        cmd.add ("-map");
        cmd.add ("0");
        if (audio_stream_index >= 0 && total_audio_streams > 1) {
            cmd.add ("-map");
            cmd.add ("-0:a:%d".printf (audio_stream_index));
        } else {
            cmd.add ("-map");
            cmd.add ("-0:a");
        }

        if (!keep_subtitles) {
            cmd.add ("-map");
            cmd.add ("-0:s");
        }

        cmd.add ("-c");
        cmd.add ("copy");

        if (strip_metadata) {
            cmd.add ("-map_metadata");
            cmd.add ("-1");
        }

        cmd.add ("-progress");
        cmd.add ("pipe:2");
        cmd.add (output_file);
        return StringArrayUtils.copy_generic_array (cmd);
    }

    /**
     * Build a command to mux an external audio file into a video file.
     *
     * @param replace_audio  If true, drop existing audio and use only the new track.
     *                       If false, keep existing audio and append the new track.
     * @param audio_codec_args  Codec arguments for the new audio track (e.g. {"-c:a", "copy"}
     *                          or {"-c:a", "libopus", "-b:a", "128k"}).  When empty,
     *                          the new track is stream-copied.
     */
    public string[] build_add_audio_cmd (string video_file,
                                          string audio_file,
                                          string output_file,
                                          bool replace_audio,
                                          int existing_audio_streams,
                                          bool keep_subtitles,
                                          bool strip_metadata,
                                          string[] audio_codec_args) {
        var cmd = new GenericArray<string> ();
        cmd.add (AppSettings.get_default ().ffmpeg_path);
        cmd.add ("-y");
        cmd.add ("-i");
        cmd.add (video_file);
        cmd.add ("-i");
        cmd.add (audio_file);

        // Map video from first input
        cmd.add ("-map");
        cmd.add ("0:v");

        if (replace_audio) {
            // Only the new audio track
            cmd.add ("-map");
            cmd.add ("1:a");
        } else {
            // Keep existing audio, append new track
            cmd.add ("-map");
            cmd.add ("0:a?");
            cmd.add ("-map");
            cmd.add ("1:a");
        }

        // Subtitles
        if (keep_subtitles) {
            cmd.add ("-map");
            cmd.add ("0:s?");
        }

        // Copy video codec
        cmd.add ("-c:v");
        cmd.add ("copy");

        // Subtitle codec (if kept)
        if (keep_subtitles) {
            cmd.add ("-c:s");
            cmd.add ("copy");
        }

        // Audio codec: when keeping existing tracks, copy them and only
        // re-encode the newly added track (last audio output stream)
        if (replace_audio || existing_audio_streams == 0) {
            // Only one audio stream in output — apply codec args to all
            if (audio_codec_args.length > 0) {
                foreach (unowned string arg in audio_codec_args) {
                    cmd.add (arg);
                }
            } else {
                cmd.add ("-c:a");
                cmd.add ("copy");
            }
        } else {
            // Copy existing audio streams
            cmd.add ("-c:a");
            cmd.add ("copy");
            // Apply codec args only to the new track (output audio index N)
            if (audio_codec_args.length > 0) {
                int new_idx = existing_audio_streams;
                foreach (unowned string arg in audio_codec_args) {
                    // Rewrite -c:a to target the specific stream
                    if (arg == "-c:a") {
                        cmd.add ("-c:a:%d".printf (new_idx));
                    } else {
                        cmd.add (arg);
                    }
                }
            }
        }

        if (strip_metadata) {
            cmd.add ("-map_metadata");
            cmd.add ("-1");
        }

        cmd.add ("-progress");
        cmd.add ("pipe:2");
        cmd.add (output_file);
        return StringArrayUtils.copy_generic_array (cmd);
    }
}
