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

#if COMBINE_WINDOW_TEST_BUILD
    internal ConversionRunner.for_command_test (ConversionConfig config) {
        this.converter = null;
        this.process_runner = null;
        this.config = config;
    }
#endif

    public void run (string input, string output, bool two_pass, uint64 operation_id) {
        string safe_output = ConversionUtils.sanitize_filename (output);
        bool succeeded = false;
        bool collage_attempted = false;
        bool collage_cancelled = false;
        string? collage_path = null;
        OperationOutputResult? output_result = null;

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

            converter.set_optional_phase_if_active (
                process_runner,
                ConversionPhase.FINALIZING
            );
            succeeded = true;

            if (AppSettings.get_default ().generate_collage_thumbnail) {
                converter.set_optional_phase_if_active (
                    process_runner,
                    ConversionPhase.COLLAGE
                );

                if (converter.is_cancelled (process_runner)) {
                    collage_attempted = true;
                    collage_cancelled = true;
                    converter.consume_optional_cancellation_if_active (process_runner);
                } else {
                    collage_path = maybe_generate_collage_thumbnail (
                        safe_output,
                        out collage_attempted,
                        out collage_cancelled
                    );
                    if (collage_cancelled) {
                        converter.consume_optional_cancellation_if_active (process_runner);
                    }
                }
            } else if (converter.is_cancelled (process_runner)) {
                converter.consume_optional_cancellation_if_active (process_runner);
            }

            output_result = build_success_output_result (safe_output, collage_path);

            if (collage_path != null) {
                converter.update_status_if_active (
                    process_runner,
                    @"Conversion completed successfully!\n\nSaved files:\n$safe_output\n$collage_path",
                    StatusIcon.SUCCESS_ICON, StatusIcon.SUCCESS_CSS
                );
            } else if (collage_cancelled) {
                converter.update_status_if_active (
                    process_runner,
                    @"Conversion completed successfully!\n\nSaved to:\n$safe_output\n\nCollage PNG generation was cancelled.",
                    StatusIcon.NOTICE_ICON, StatusIcon.NOTICE_CSS
                );
            } else if (collage_attempted) {
                converter.update_status_if_active (
                    process_runner,
                    @"Conversion completed successfully!\n\nSaved to:\n$safe_output\n\nCollage PNG was not generated. Check the console for details.",
                    StatusIcon.NOTICE_ICON, StatusIcon.NOTICE_CSS
                );
            } else {
                converter.update_status_if_active (
                    process_runner,
                    @"Conversion completed successfully!\n\nSaved to:\n$safe_output",
                    StatusIcon.SUCCESS_ICON, StatusIcon.SUCCESS_CSS
                );
            }
        } finally {
            converter.finish_conversion (
                operation_id,
                process_runner,
                succeeded,
                succeeded ? output_result : null
            );
        }
    }

    private OperationOutputResult build_success_output_result (string output_path,
                                                               string? collage_path = null) {
        if (collage_path == null || collage_path.length == 0) {
            return new OperationOutputResult.for_file (output_path);
        }

        string[] paths = { output_path, collage_path };
        return new OperationOutputResult.for_multiple_files (
            (owned) paths,
            Path.get_dirname (output_path),
            output_path
        );
    }

    private string? maybe_generate_collage_thumbnail (string output_path,
                                                      out bool collage_attempted,
                                                      out bool collage_cancelled) {
        collage_attempted = false;
        collage_cancelled = false;

        if (!FfprobeUtils.has_video_stream (output_path)) {
            converter.log_console_if_active (
                process_runner,
                "[Collage] Output has no video stream; skipping collage generation."
            );
            return null;
        }

        collage_attempted = true;
        string? collage_output_path = resolve_collage_output_path (output_path);
        if (collage_output_path == null || collage_output_path.length == 0) {
            converter.log_console_if_active (
                process_runner,
                "[Collage] Could not determine a writable output path; skipping collage generation."
            );
            return null;
        }
        string final_collage_path = collage_output_path;

        double duration_seconds = FfprobeUtils.probe_duration (output_path);
        if (duration_seconds <= 0.0) {
            duration_seconds = config.output_duration_seconds;
        }
        if (duration_seconds <= 0.0) {
            converter.log_console_if_active (
                process_runner,
                "[Collage] Could not determine the finished video duration; skipping collage generation."
            );
            return null;
        }

        converter.set_phase_if_active (process_runner, ConversionPhase.COLLAGE);
        converter.update_status_if_active (
            process_runner,
            "Generating 4-4-4 collage thumbnail...",
            StatusIcon.PROGRESS_ICON,
            StatusIcon.PROGRESS_CSS
        );

        string[] collage_cmd = ConversionUtils.build_collage_argv (
            AppSettings.get_default ().ffmpeg_path,
            output_path,
            final_collage_path,
            duration_seconds
        );
        string display_cmd = ConversionUtils.format_command_for_display (collage_cmd);
        converter.log_console_if_active (process_runner, "Collage command: " + display_cmd);

        int exit = process_runner.execute (collage_cmd, (clean) => {
            if (!converter.accepts_runner_updates (process_runner)) {
                return;
            }

            if (ConversionUtils.should_log_ffmpeg_line (clean)) {
                converter.log_console_if_active (process_runner, clean);
            }
        });

        if (exit != 0) {
            if (converter.is_cancelled (process_runner)) {
                collage_cancelled = true;
            } else {
                converter.log_console_if_active (
                    process_runner,
                    "[Collage] FFmpeg failed while generating the PNG collage thumbnail."
                );
            }
            return null;
        }

        if (!FileUtils.test (final_collage_path, FileTest.EXISTS)) {
            converter.log_console_if_active (
                process_runner,
                "[Collage] FFmpeg completed but the PNG collage file was not created."
            );
            return null;
        }

        converter.log_console_if_active (
            process_runner,
            "[Collage] Created " + final_collage_path
        );
        return final_collage_path;
    }

    private string? resolve_collage_output_path (string output_path) {
        return ConversionUtils.resolve_collage_output_path (output_path);
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
    //      -filter_complex "...[outv]" -map [outv]
    //      [-map 0:a:0? | -map 0:a?] [codec_args...]
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

    private string get_explicit_audio_map_spec () {
        return config.profile.preserve_all_audio_tracks ? "0:a?" : "0:a:0?";
    }

    /**
     * Build the shared command prefix.
     *
     * @param input       the input file path
     * @param map_audio   whether to include audio mapping for filter_complex
     *                    paths.  Pass false for pass-1 which always adds -an.
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

            if (map_audio && !is_audio_disabled ()) {
                cmd += "-map";
                cmd += get_explicit_audio_map_spec ();
            }
        } else if (config.profile.video_filters != "") {
            cmd += "-vf"; cmd += config.profile.video_filters;
        }

        // When preserve_all_audio_tracks is on and we are NOT in a
        // filter_complex (image-watermark) path, explicitly map the
        // primary video stream plus all audio streams so FFmpeg keeps
        // every audio track without broadening video selection.
        // The watermark path handles audio mapping above so the toggle
        // can choose between the first audio stream and all audio streams.
        if (!is_image_watermark_active ()
                && map_audio
                && !is_audio_disabled ()
                && config.profile.preserve_all_audio_tracks) {
            cmd += "-map";
            cmd += "0:v:0";
            cmd += "-map";
            cmd += "0:a?";
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
            get_explicit_audio_map_spec ()
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

#if COMBINE_WINDOW_TEST_BUILD
    internal string[] build_single_pass_argv_for_test (string input, string output) {
        return build_single_pass (input, output);
    }

    internal string[] build_pass1_argv_for_test (string input) {
        return build_pass1 (input);
    }

    internal string[] build_pass2_argv_for_test (string input, string output) {
        return build_pass2 (input, output);
    }

    internal string[] build_peak_detect_argv_for_test (string input) {
        return build_peak_detect_cmd (input);
    }

    internal string build_collage_output_path_for_test (string output_path) {
        return ConversionUtils.build_collage_output_path (output_path);
    }

    internal string[] build_collage_argv_for_test (string output_path,
                                                   string collage_output_path,
                                                   double duration_seconds) {
        return ConversionUtils.build_collage_argv (
            AppSettings.get_default ().ffmpeg_path,
            output_path,
            collage_output_path,
            duration_seconds
        );
    }
#endif
}
