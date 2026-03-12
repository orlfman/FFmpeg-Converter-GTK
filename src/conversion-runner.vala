using Gtk;

// ═══════════════════════════════════════════════════════════════════════════════
//  ConversionRunner — Builds and executes FFmpeg commands for encoding
// ═══════════════════════════════════════════════════════════════════════════════

public class ConversionRunner {

    private Converter converter;
    private ConversionConfig config;
    private string[]? resolved_codec_args = null;

    public ConversionRunner (Converter converter, ConversionConfig config) {
        this.converter = converter;
        this.config    = config;
    }

    public void run (string input, string output, bool two_pass) {
        string safe_output = ConversionUtils.sanitize_filename (output);

        try {
            if (two_pass) {
                if (converter.is_cancelled ()) return;

                converter.set_phase (ConversionPhase.PASS1);
                converter.update_status ("🔄 Pass 1/2: Analyzing video...");
                string[] pass1 = build_pass1 (input);
                if (converter.execute_ffmpeg (pass1, 0.0, 50.0) != 0) {
                    if (!converter.is_cancelled ())
                        converter.report_error ("Pass 1 failed.");
                    return;
                }

                if (converter.is_cancelled ()) return;

                converter.set_phase (ConversionPhase.PASS2);
                converter.update_status (
                    @"🔄 Pass 2/2: Encoding final $(config.profile.codec_name) video...");
                string[] pass2 = build_pass2 (input, safe_output);
                if (converter.execute_ffmpeg (pass2, 50.0, 50.0) != 0) {
                    if (!converter.is_cancelled ())
                        converter.report_error ("Pass 2 failed.");
                    return;
                }
            } else {
                if (converter.is_cancelled ()) return;

                converter.set_phase (ConversionPhase.PASS2);
                converter.update_status (
                    @"🔄 Encoding with $(config.profile.codec_name) (single pass...)");
                string[] cmd = build_single_pass (input, safe_output);
                if (converter.execute_ffmpeg (cmd) != 0) {
                    if (!converter.is_cancelled ())
                        converter.report_error ("Encoding failed.");
                    return;
                }
            }

            if (converter.is_cancelled ()) return;

            converter.update_status (@"✅ Conversion completed successfully!\n\nSaved to:\n$safe_output");

            // Notify listeners that a new output file is ready
            string completed_path = safe_output;
            Idle.add (() => {
                converter.conversion_done (completed_path);
                return Source.REMOVE;
            });
        } finally {
            converter.cleanup_after_conversion ();
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SHARED COMMAND PREFIX
    //
    //  All three command builders share the same prefix:
    //    ffmpeg -y [-ss timestamp] -i input [-vf filters] [codec_args...]
    //
    //  Extracting this avoids duplicating seek, input, filter, and codec
    //  argument logic three times — a bug fix in any of these now only
    //  needs to happen in one place.
    // ═════════════════════════════════════════════════════════════════════════

    private string[] build_common_prefix (string input) {
        string[] cmd = { AppSettings.get_default ().ffmpeg_path, "-y" };

        if (config.seek_enabled) {
            cmd += "-ss";
            cmd += config.seek_timestamp;
        }

        cmd += "-i"; cmd += input;

        if (config.profile.video_filters != "") {
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
        string[] cmd = build_common_prefix (input);

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
            config.profile.audio_filters, config.profile.audio_args);
    }
}
