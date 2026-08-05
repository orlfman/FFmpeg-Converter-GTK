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

            // A zero exit status is not proof the encode produced anything.
            // When a filter chain yields no frames ffmpeg still exits 0 and
            // leaves a header-only file behind, and without this the user is
            // told the conversion succeeded and handed an unplayable file.
            string output_problem;
            if (!FfprobeUtils.output_file_is_usable (safe_output, out output_problem)) {
                if (!converter.is_cancelled (process_runner))
                    converter.report_error_if_active (process_runner, output_problem);
                return;
            }

            report_smart_size_result (safe_output);

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

    internal static string format_smart_size_comparison (int target_size_kib,
                                                         int planned_size_kib,
                                                         double planning_uncertainty,
                                                         int64 actual_bytes) {
        if (target_size_kib <= 0 || actual_bytes < 0)
            return "";

        double actual_kib = (double) actual_bytes / 1024.0;
        double requested_difference_kib = actual_kib - target_size_kib;
        double requested_difference_percent =
            requested_difference_kib / target_size_kib * 100.0;
        var report = new StringBuilder ();
        report.append ("[Smart Optimizer] ── Final size ──\n");
        report.append ("[Smart Optimizer]   Requested:  %d KiB\n".printf (
            target_size_kib));
        if (planned_size_kib > 0) {
            report.append ("[Smart Optimizer]   Planned:    %d KiB (approximately ±%.0f%%)\n"
                .printf (planned_size_kib,
                    planning_uncertainty.clamp (0.0, 0.50) * 100.0));
        }
        report.append ("[Smart Optimizer]   Actual:     %.0f KiB\n".printf (
            actual_kib));
        report.append ("[Smart Optimizer]   Requested difference: %+.0f KiB (%+.1f%%)"
            .printf (requested_difference_kib,
                requested_difference_percent));

        if (planned_size_kib > 0) {
            double planned_difference_kib = actual_kib - planned_size_kib;
            double planned_difference_percent =
                planned_difference_kib / planned_size_kib * 100.0;
            bool within_plan = Math.fabs (planned_difference_percent)
                <= planning_uncertainty.clamp (0.0, 0.50) * 100.0;
            report.append ("\n[Smart Optimizer]   Planned difference:   %+.0f KiB (%+.1f%%; %s ±%.0f%% uncertainty)"
                .printf (planned_difference_kib,
                    planned_difference_percent,
                    within_plan ? "within" : "outside",
                    planning_uncertainty.clamp (0.0, 0.50) * 100.0));
        }
        return report.str;
    }

    private void report_smart_size_result (string output_path) {
        if (config.smart_requested_size_kib <= 0)
            return;

        try {
            var info = File.new_for_path (output_path).query_info (
                FileAttribute.STANDARD_SIZE,
                FileQueryInfoFlags.NONE
            );
            string report = format_smart_size_comparison (
                config.smart_requested_size_kib,
                config.smart_planned_size_kib,
                config.smart_planning_uncertainty,
                info.get_size ());
            foreach (unowned string line in report.split ("\n")) {
                converter.log_console_if_active (process_runner, line);
            }
        } catch (Error e) {
            warning ("Could not report Smart Optimizer final size for %s: %s",
                output_path, e.message);
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

        double video_start_time = 0.0;
        bool single_frame_video = false;
        VideoTimelineProbeResult video_timeline =
            FfprobeUtils.probe_video_timeline (
                output_path, process_runner.execute_capture);
        if (converter.is_cancelled (process_runner)) {
            collage_cancelled = true;
            return null;
        }

        bool confirmed_single_frame = video_timeline.success
            && video_timeline.packet_count_complete
            && video_timeline.packet_count == 1;
        double duration_seconds = video_timeline.get_duration ();
        if (confirmed_single_frame) {
            video_start_time = video_timeline.start_time;
            single_frame_video = true;
        } else if (video_timeline.success && duration_seconds > 0.0) {
            video_start_time = video_timeline.start_time;
            duration_seconds = video_timeline.get_seek_span ();
        } else if (video_timeline.start_time_known
                   && config.video_source_span_seconds > 0.0) {
            video_start_time = video_timeline.start_time;
            // Collage frames are seeked in the output file, so this fallback
            // has to be the output's length rather than the source span it was
            // read from — otherwise a sped-up encode sends the later seeks
            // past the final frame.
            duration_seconds = video_output_duration_seconds (
                config.video_source_span_seconds);
            converter.log_console_if_active (
                process_runner,
                "[Collage] Could not read the tail packet; using the encoded video duration with the measured video start."
            );
        } else {
            converter.log_console_if_active (
                process_runner,
                "[Collage] Could not determine a safe video timeline; skipping collage generation."
            );
            return null;
        }
        if (!single_frame_video && duration_seconds <= 0.0) {
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
            duration_seconds,
            video_start_time,
            single_frame_video,
            AppSettings.get_default ().collage_size
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

    private bool can_reset_video_timestamps_without_desync () {
        if (!is_audio_disabled ())
            return false;

        // Chapters are copied independently of stream mapping unless the user
        // explicitly removes them. Their timestamps would not follow setpts.
        if (!config.timed_stream_topology_known)
            return false;
        if (config.input_has_chapters && !config.profile.remove_chapters)
            return false;

        // Image-watermark commands explicitly map only [outv] when audio is
        // disabled, so embedded subtitles cannot be selected. The ordinary
        // -vf path uses FFmpeg's automatic mapping and may retain one.
        return is_image_watermark_active ()
            || !config.input_has_subtitle_stream;
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
        // Duration selects a stretch of the source, so it has to bound the
        // input. As an output option it would be measured after the filter
        // chain, where a speed filter has rewritten the timestamps: the encode
        // would then cover a different stretch than the one the rest of the app
        // already assumes it covers. SmartOptimizer samples the source between
        // trim_start_seconds and trim_end_seconds, and timed logo removal
        // clamps its enable windows to the same span — both in source time.
        //
        // Without a speed filter the two placements are identical, so this only
        // changes the combination that was inconsistent.
        //
        // Placed ahead of the first -i so it binds to the source alone. An
        // image watermark adds a second -i below, and that one is a single
        // still frame which must stay unbounded.
        if (config.time_enabled) {
            cmd += "-t";
            cmd += config.time_timestamp;
        }

        cmd += "-i"; cmd += input;

        if (is_image_watermark_active ()) {
            cmd += "-i";
            cmd += config.profile.watermark_image_path;

            // Build filter_complex: existing video filters + overlay
            string vf = get_video_filters ();
            string fc;
            if (vf.length > 0) {
                fc = "[0:v]" + vf + "[vf_out]; ";
                fc += FilterBuilder.build_image_overlay_fragment (
                    "[1:v]", "[vf_out]", "[outv]",
                    config.profile.watermark_position,
                    config.profile.watermark_margin,
                    config.profile.watermark_opacity,
                    config.profile.watermark_image_width,
                    config.profile.overlay_format);
            } else {
                fc = FilterBuilder.build_image_overlay_fragment (
                    "[1:v]", "[0:v]", "[outv]",
                    config.profile.watermark_position,
                    config.profile.watermark_margin,
                    config.profile.watermark_opacity,
                    config.profile.watermark_image_width,
                    config.profile.overlay_format);
            }

            cmd += "-filter_complex";
            cmd += fc;
            cmd += "-map";
            cmd += "[outv]";

            if (map_audio && !is_audio_disabled ()) {
                cmd += "-map";
                cmd += get_explicit_audio_map_spec ();
            }
        } else {
            string vf = get_video_filters ();
            if (vf != "") {
                cmd += "-vf"; cmd += vf;
            }
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
     * Build the progress-pipe arguments.
     * Returns an array that the caller appends to its command.
     *
     * The duration limit used to live here. It bounds the input now, so it is
     * emitted by build_common_prefix ahead of the first -i instead.
     */
    private string[] build_progress_args () {
        string[] args = {};

        args += "-progress"; args += "pipe:2";
        return args;
    }

    /**
     * The profile's video chain, with logo removal rebuilt against the
     * timestamps the filter graph will actually see.
     *
     * The Seek option puts -ss ahead of -i, and frames then arrive starting near
     * zero rather than at their source timestamps — so a timed region's
     * interval has to be shifted back by the seek or it fires at the wrong
     * moment. Without seeking this returns profile.video_filters unchanged.
     */
    private string get_video_filters () {
        double offset = config.seek_enabled
            ? ConversionUtils.parse_ffmpeg_timestamp (config.seek_timestamp)
            : 0.0;
        double span = config.time_enabled
            ? ConversionUtils.parse_ffmpeg_timestamp (config.time_timestamp)
            : 0.0;
        string filters = FilterBuilder.build_video_filter_chain_for_segment (
            config.profile, offset, null, span);

        // A genuinely video-only output can begin at a positive PTS because
        // an omitted stream (usually audio) started earlier. If that offset is carried
        // into the output, the muxer reports the last timestamp as its
        // duration: players then reach EOF while their seek bars still show
        // the leading gap, and percentage-based collage seeks can run past
        // the final frame.  Reset the completed video timeline after every
        // other timestamp-changing filter so the first encoded frame is zero.
        //
        // Do not independently reset video when audio is retained.  Doing so
        // could erase an intentional A/V start offset and desynchronize the
        // converted file.
        if (can_reset_video_timestamps_without_desync ()) {
            filters = filters.length > 0
                ? filters + ",setpts=PTS-STARTPTS"
                : "setpts=PTS-STARTPTS";
        }

        return filters;
    }

    private string[] build_peak_analysis_pre_input_args () {
        string[] args = {};

        if (config.seek_enabled) {
            args += "-ss";
            args += config.seek_timestamp;
        }
        // Bound on the input for the same reason the encode does — see
        // build_common_prefix. The analysis has to measure the same stretch of
        // source the encode writes, or it normalizes against a peak taken from
        // somewhere else.
        if (config.time_enabled) {
            args += "-t";
            args += config.time_timestamp;
        }

        return args;
    }

    /**
     * Build metadata flags when the output is a real file (not /dev/null).
     * Returns an array that the caller appends to its command.
     *
     * FFmpeg copies global metadata from the first input by default, so
     * "preserve off" must emit an explicit -map_metadata -1 — otherwise the
     * toggle (and Smart Optimizer's strip_metadata, which is applied by
     * switching preserve off) silently does nothing.
     */
    private string[] build_metadata_args () {
        string[] args = {};

        args += "-map_metadata";
        args += config.profile.preserve_metadata ? "0" : "-1";
        if (config.profile.remove_chapters) { args += "-map_chapters"; args += "-1"; }

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

        foreach (string a in build_progress_args ()) cmd += a;

        cmd += "-f"; cmd += "null";
        cmd += "/dev/null";
        return cmd;
    }

    private string[] build_pass2 (string input, string safe_output) {
        string[] cmd = build_common_prefix (input);

        cmd += "-pass"; cmd += "2";
        cmd += "-passlogfile"; cmd += config.passlog_base;

        foreach (string a in build_metadata_args ()) cmd += a;
        foreach (string a in build_progress_args ()) cmd += a;
        foreach (string a in get_audio_args_with_filters ()) cmd += a;

        cmd += safe_output;
        return cmd;
    }

    private string[] build_single_pass (string input, string safe_output) {
        string[] cmd = build_common_prefix (input);

        foreach (string a in build_metadata_args ()) cmd += a;
        foreach (string a in build_progress_args ()) cmd += a;
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
            && config.source_span_seconds <= 0.0) {
            warning ("ConversionRunner: audio fade-out requested but output duration is unknown; skipping fade-out filter.");
        }

        return FilterBuilder.build_peak_analysis_audio_filter_chain (
            config.profile.audio_filters,
            config.profile.audio_processing,
            audio_output_duration_seconds (),
            true,
            true
        );
    }

    /**
     * How long the audio actually runs once the chain has been applied.
     *
     * merge_profile_audio_filter_chain appends the processing filters after
     * the profile's own, so afade sits downstream of atempo and places its
     * fade on the sped-up timeline. Handing it the source span would put a
     * fade-out past the end of a shortened track, where it never fires.
     */
    private double audio_output_duration_seconds () {
        double speed = config.profile.audio_speed_multiplier;
        if (!speed.is_finite () || speed <= 0.0) return config.source_span_seconds;

        return config.source_span_seconds / speed;
    }

    /** The video counterpart, for a span already measured on the source. */
    private double video_output_duration_seconds (double source_span) {
        double speed = config.profile.video_speed_multiplier;
        if (!speed.is_finite () || speed <= 0.0) return source_span;

        return source_span / speed;
    }

    private string[] build_peak_detect_cmd (string input) {
        return FilterBuilder.build_audio_peak_detect_cmd (
            input,
            build_peak_analysis_audio_filters (),
            build_peak_analysis_pre_input_args (),
            null,
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
            && config.source_span_seconds <= 0.0) {
            warning ("ConversionRunner: audio fade-out requested but output duration is unknown; skipping fade-out filter.");
        }

        return FilterBuilder.merge_profile_audio_filter_chain (
            config.profile.audio_filters,
            config.profile.audio_processing,
            audio_output_duration_seconds (),
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
                                                   double duration_seconds,
                                                   double video_start_time = 0.0,
                                                   bool single_frame_video = false,
                                                   CollageSize collage_size
                                                       = CollageSize.FHD_1080) {
        return ConversionUtils.build_collage_argv (
            AppSettings.get_default ().ffmpeg_path,
            output_path,
            collage_output_path,
            duration_seconds,
            video_start_time,
            single_frame_video,
            collage_size
        );
    }
#endif
}
