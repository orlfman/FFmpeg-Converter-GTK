using Gtk;

// ═══════════════════════════════════════════════════════════════════════════════
//  ConversionRunner — Builds and executes FFmpeg commands for encoding
// ═══════════════════════════════════════════════════════════════════════════════

public class ConversionRunner {

    private Converter converter;
    private ProcessRunner process_runner;
    private ConversionConfig config;
    private string[]? resolved_codec_args = null;

    public ConversionRunner (Converter converter,
                             ProcessRunner process_runner,
                             ConversionConfig config) {
        this.converter      = converter;
        this.process_runner = process_runner;
        this.config         = config;
    }

    public void run (string input, string output, bool two_pass, uint64 operation_id) {
        string safe_output = ConversionUtils.sanitize_filename (output);
        bool succeeded = false;

        try {
            if (!validate_svt_av1_constant_quality_two_pass_compatibility (two_pass)) {
                return;
            }

            if (!prepare_peak_normalization (
                    input,
                    two_pass ? ConversionPhase.PASS1 : ConversionPhase.ENCODING)) {
                return;
            }

            if (two_pass) {
                if (converter.is_cancelled (process_runner)) return;

                converter.set_phase_if_active (process_runner, ConversionPhase.PASS1);
                converter.update_status_if_active (process_runner, "Pass 1/2: Analyzing video...",
                    StatusIcon.PROGRESS_ICON, StatusIcon.PROGRESS_CSS);
                string[] pass1 = build_pass1 (input);
                if (converter.execute_ffmpeg (process_runner, pass1, 0.0, 50.0) != 0) {
                    if (!converter.is_cancelled (process_runner))
                        converter.report_error_if_active (process_runner, "Pass 1 failed.");
                    return;
                }

                if (converter.is_cancelled (process_runner)) return;

                converter.set_phase_if_active (process_runner, ConversionPhase.PASS2);
                converter.update_status_if_active (
                    process_runner,
                    @"Pass 2/2: Encoding final $(config.profile.codec_name) video...",
                    StatusIcon.PROGRESS_ICON, StatusIcon.PROGRESS_CSS);
                string[] pass2 = build_pass2 (input, safe_output);
                if (converter.execute_ffmpeg (process_runner, pass2, 50.0, 50.0) != 0) {
                    if (!converter.is_cancelled (process_runner))
                        converter.report_error_if_active (process_runner, "Pass 2 failed.");
                    return;
                }
            } else {
                if (converter.is_cancelled (process_runner)) return;

                converter.set_phase_if_active (process_runner, ConversionPhase.ENCODING);
                converter.update_status_if_active (
                    process_runner,
                    @"Encoding with $(config.profile.codec_name) (single pass...)",
                    StatusIcon.PROGRESS_ICON, StatusIcon.PROGRESS_CSS);
                string[] cmd = build_single_pass (input, safe_output);
                if (converter.execute_ffmpeg (process_runner, cmd) != 0) {
                    if (!converter.is_cancelled (process_runner))
                        converter.report_error_if_active (process_runner, "Encoding failed.");
                    return;
                }
            }

            if (converter.is_cancelled (process_runner)) return;

            converter.update_status_if_active (
                process_runner,
                @"Conversion completed successfully!\n\nSaved to:\n$safe_output",
                StatusIcon.SUCCESS_ICON, StatusIcon.SUCCESS_CSS);
            succeeded = true;
        } finally {
            converter.finish_conversion (
                operation_id,
                process_runner,
                succeeded,
                succeeded ? safe_output : null
            );
        }
    }

    private bool validate_svt_av1_constant_quality_two_pass_compatibility (bool two_pass) {
        if (!two_pass || config.profile.codec_name != "SVT-AV1") {
            return true;
        }

        bool has_constant_quality = false;
        foreach (string arg in config.profile.codec_args) {
            if (arg == "-crf" || arg == "-qp") {
                has_constant_quality = true;
                break;
            }
        }
        if (!has_constant_quality) {
            return true;
        }

        switch (config.svt_crf_two_pass_status) {
            case SvtAv1CrfTwoPassCapabilityStatus.SUPPORTED:
                return true;

            case SvtAv1CrfTwoPassCapabilityStatus.UNSUPPORTED:
                converter.report_error_if_active (
                    process_runner,
                    config.svt_crf_two_pass_reason
                        ?? "This FFmpeg build does not support SVT-AV1 CRF/QP two-pass. "
                           + "Use single-pass CRF/QP or switch to VBR two-pass."
                );
                return false;

            case SvtAv1CrfTwoPassCapabilityStatus.PROBING:
            case SvtAv1CrfTwoPassCapabilityStatus.UNKNOWN:
                converter.report_error_if_active (
                    process_runner,
                    "SVT-AV1 CRF/QP two-pass support has not been verified for the selected "
                    + "FFmpeg build. Open Preferences > Binaries and validate the ffmpeg path."
                );
                return false;

            case SvtAv1CrfTwoPassCapabilityStatus.ERROR:
                converter.report_error_if_active (
                    process_runner,
                    config.svt_crf_two_pass_reason
                        ?? "SVT-AV1 CRF/QP two-pass support could not be verified for the "
                           + "selected FFmpeg build. Open Preferences > Binaries and "
                           + "validate the ffmpeg path."
                );
                return false;

            default:
                return false;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SHARED COMMAND PREFIX
    //
    //  All three command builders share the same prefix:
    //    ffmpeg -y [-ss timestamp] -i input [-vf filters] [codec_args...]
    //
    //  When image watermarking is active, the prefix becomes:
    //    ffmpeg -y [-ss timestamp] -i input -i watermark.png
    //      -filter_complex "...[outv]" -map [outv] -map 0:a? [codec_args...]
    //
    //  Extracting this avoids duplicating seek, input, filter, and codec
    //  argument logic three times — a bug fix in any of these now only
    //  needs to happen in one place.
    // ═════════════════════════════════════════════════════════════════════════

    private bool is_image_watermark_active () {
        return config.profile.watermark_enabled
            && config.profile.watermark_mode == "image"
            && config.profile.watermark_image_path.length > 0;
    }

    private bool is_audio_disabled () {
        return config.profile.audio_args.length > 0
            && config.profile.audio_args[0] == "-an";
    }

    /**
     * Build the shared command prefix.
     *
     * @param input       the input file path
     * @param map_audio   whether to add audio mapping for filter_complex paths.
     *                    Pass false for pass-1 (which always adds -an later).
     */
    private string[] build_common_prefix (string input, bool map_audio = true) {
        string[] cmd = { AppSettings.get_default ().ffmpeg_path, "-y" };

        if (config.seek_enabled) {
            cmd += "-ss";
            cmd += config.seek_timestamp;
        }

        cmd += "-i"; cmd += input;

        if (is_image_watermark_active ()) {
            cmd += "-i";
            cmd += config.profile.watermark_image_path;

            // Build filter_complex: existing video filters + overlay
            string vf = config.profile.video_filters;
            string fc;
            if (vf.length > 0) {
                fc = "[0:v]" + vf + "[vf_out]; ";
                fc += FilterBuilder.build_image_overlay_fragment (
                    "[1:v]", "[vf_out]", "[outv]",
                    config.profile.watermark_position,
                    config.profile.watermark_margin,
                    config.profile.watermark_opacity,
                    config.profile.watermark_image_width);
            } else {
                fc = FilterBuilder.build_image_overlay_fragment (
                    "[1:v]", "[0:v]", "[outv]",
                    config.profile.watermark_position,
                    config.profile.watermark_margin,
                    config.profile.watermark_opacity,
                    config.profile.watermark_image_width);
            }

            cmd += "-filter_complex";
            cmd += fc;
            cmd += "-map";
            cmd += "[outv]";

            // Map only the best audio stream (0:a:0) to match the default
            // stream selection that FFmpeg uses when no -map is specified.
            // Using 0:a (without :0) would map ALL audio streams, breaking
            // progress tracking on inputs with multiple audio tracks.
            if (map_audio && !is_audio_disabled ()) {
                cmd += "-map";
                cmd += "0:a:0?";
            }
        } else if (config.profile.video_filters != "") {
            cmd += "-vf"; cmd += config.profile.video_filters;
        }

        foreach (string arg in get_codec_args (input)) cmd += arg;

        return cmd;
    }

    private string[] get_codec_args (string input) {
        if (resolved_codec_args == null) {
            resolved_codec_args = CodecUtils.build_codec_args_from_snapshot (
                config.profile, input);
        }
        return resolved_codec_args;
    }

    /**
     * Build the shared time-limit and progress-pipe arguments.
     * Returns an array that the caller appends to its command.
     */
    private string[] build_time_and_progress_args () {
        string[] args = {};

        if (config.time_enabled) {
            args += "-t";
            args += config.time_timestamp;
        }

        args += "-progress"; args += "pipe:2";
        return args;
    }

    private string[] build_peak_analysis_pre_input_args () {
        string[] args = {};

        if (config.seek_enabled) {
            args += "-ss";
            args += config.seek_timestamp;
        }

        return args;
    }

    private string[] build_peak_analysis_post_input_args () {
        string[] args = {};

        if (config.time_enabled) {
            args += "-t";
            args += config.time_timestamp;
        }

        return args;
    }

    /**
     * Build metadata flags when the output is a real file (not /dev/null).
     * Returns an array that the caller appends to its command.
     */
    private string[] build_metadata_args () {
        string[] args = {};

        if (config.profile.preserve_metadata) { args += "-map_metadata"; args += "0"; }
        if (config.profile.remove_chapters)   { args += "-map_chapters"; args += "-1"; }

        return args;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  COMMAND BUILDERS
    //  All data comes from ConversionConfig via build_common_prefix.
    // ═════════════════════════════════════════════════════════════════════════

    private string[] build_pass1 (string input) {
        string[] cmd = build_common_prefix (input, false);

        cmd += "-pass"; cmd += "1";
        cmd += "-passlogfile"; cmd += config.passlog_base;
        cmd += "-an";

        foreach (string a in build_time_and_progress_args ()) cmd += a;

        cmd += "-f"; cmd += "null";
        cmd += "/dev/null";
        return cmd;
    }

    private string[] build_pass2 (string input, string safe_output) {
        string[] cmd = build_common_prefix (input);

        cmd += "-pass"; cmd += "2";
        cmd += "-passlogfile"; cmd += config.passlog_base;

        foreach (string a in build_metadata_args ()) cmd += a;
        foreach (string a in build_time_and_progress_args ()) cmd += a;
        foreach (string a in get_audio_args_with_filters ()) cmd += a;

        cmd += safe_output;
        return cmd;
    }

    private string[] build_single_pass (string input, string safe_output) {
        string[] cmd = build_common_prefix (input);

        foreach (string a in build_metadata_args ()) cmd += a;
        foreach (string a in build_time_and_progress_args ()) cmd += a;
        foreach (string a in get_audio_args_with_filters ()) cmd += a;

        cmd += safe_output;
        return cmd;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  AUDIO ARGS (from ConversionConfig, not from live widgets)
    // ═════════════════════════════════════════════════════════════════════════

    private string[] get_audio_args_with_filters () {
        return FilterBuilder.merge_audio_filters (
            build_audio_filters (), config.profile.audio_args);
    }

    private bool needs_peak_analysis () {
        if (config.profile.audio_args.length > 0 && config.profile.audio_args[0] == "-an") {
            return false;
        }

        return ConversionUtils.audio_processing_needs_peak_analysis (
            config.profile.audio_processing);
    }

    private string build_peak_analysis_audio_filters () {
        if (config.profile.audio_processing.fade_out_enabled
            && config.profile.audio_processing.fade_out_duration > 0.0
            && config.output_duration_seconds <= 0.0) {
            warning ("ConversionRunner: audio fade-out requested but output duration is unknown; skipping fade-out filter.");
        }

        return FilterBuilder.build_peak_analysis_audio_filter_chain (
            config.profile.audio_filters,
            config.profile.audio_processing,
            config.output_duration_seconds,
            true,
            true
        );
    }

    private string[] build_peak_detect_cmd (string input) {
        return FilterBuilder.build_audio_peak_detect_cmd (
            input,
            build_peak_analysis_audio_filters (),
            build_peak_analysis_pre_input_args (),
            build_peak_analysis_post_input_args (),
            FilterBuilder.extract_peak_analysis_output_args (config.profile.audio_args),
            "0:a?"
        );
    }

    private bool prepare_peak_normalization (string input, ConversionPhase phase) {
        if (!needs_peak_analysis ()) {
            return true;
        }

        config.profile.audio_processing.peak_normalize_gain_db = 0.0;

        converter.set_phase_if_active (process_runner, phase);
        converter.update_status_if_active (
            process_runner,
            "Analyzing audio peak for normalization...",
            StatusIcon.PROGRESS_ICON,
            StatusIcon.PROGRESS_CSS
        );

        string[] cmd = build_peak_detect_cmd (input);
        converter.show_command_if_active (process_runner, cmd);

        double max_volume_db = 0.0;
        bool found_max_volume = false;

        int exit = process_runner.execute (cmd, (line) => {
            if (!converter.accepts_runner_updates (process_runner)) {
                return;
            }

            double parsed_max = 0.0;
            if (ConversionUtils.try_parse_max_volume_db (line, out parsed_max)) {
                max_volume_db = parsed_max;
                found_max_volume = true;
            }

            if (ConversionUtils.should_log_ffmpeg_line (line)) {
                converter.log_console_if_active (process_runner, line);
            }
        });

        if (converter.is_cancelled (process_runner)) {
            return false;
        }

        if (exit != 0) {
            converter.report_error_if_active (
                process_runner,
                "Peak normalization analysis failed."
            );
            return false;
        }

        if (!found_max_volume) {
            converter.report_error_if_active (
                process_runner,
                "Peak normalization analysis did not report a max volume."
            );
            return false;
        }

        config.profile.audio_processing.peak_normalize_gain_db =
            ConversionUtils.compute_peak_normalize_gain_db (max_volume_db);
        converter.log_console_if_active (
            process_runner,
            "[Audio] Peak normalization target %.2f dBFS, measured %.2f dBFS, gain %.2f dB"
                .printf (
                    ConversionUtils.PEAK_NORMALIZE_TARGET_DB,
                    max_volume_db,
                    config.profile.audio_processing.peak_normalize_gain_db
                )
        );
        return true;
    }

    private string build_audio_filters () {
        if (config.profile.audio_processing.fade_out_enabled
            && config.profile.audio_processing.fade_out_duration > 0.0
            && config.output_duration_seconds <= 0.0) {
            warning ("ConversionRunner: audio fade-out requested but output duration is unknown; skipping fade-out filter.");
        }

        return FilterBuilder.merge_profile_audio_filter_chain (
            config.profile.audio_filters,
            config.profile.audio_processing,
            config.output_duration_seconds,
            true,
            true,
            true
        );
    }
}
