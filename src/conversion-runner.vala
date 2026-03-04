using Gtk;

// ═══════════════════════════════════════════════════════════════════════════════
//  ConversionRunner — Builds and executes FFmpeg commands for encoding
// ═══════════════════════════════════════════════════════════════════════════════

public class ConversionRunner {

    private Converter converter;
    private ConversionConfig config;

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
                converter.update_status (@"🔄 Pass 2/2: Encoding final $(config.codec_name) video...");
                string[] pass2 = build_pass2 (input, safe_output);
                if (converter.execute_ffmpeg (pass2, 50.0, 50.0) != 0) {
                    if (!converter.is_cancelled ())
                        converter.report_error ("Pass 2 failed.");
                    return;
                }
            } else {
                if (converter.is_cancelled ()) return;

                converter.set_phase (ConversionPhase.PASS2);
                converter.update_status (@"🔄 Encoding with $(config.codec_name) (single pass...)");
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
    //  COMMAND BUILDERS
    //  All data comes from ConversionConfig
    // ═════════════════════════════════════════════════════════════════════════

    private string[] build_pass1 (string input) {
        string[] cmd = { AppSettings.get_default ().ffmpeg_path, "-y" };

        if (config.seek_enabled) {
            cmd += "-ss";
            cmd += config.seek_timestamp;
        }

        cmd += "-i"; cmd += input;

        if (config.video_filters != "") {
            cmd += "-vf"; cmd += config.video_filters;
        }

        foreach (string arg in config.codec_args) cmd += arg;

        cmd += "-pass"; cmd += "1";
        cmd += "-passlogfile"; cmd += config.passlog_base;
        cmd += "-an";

        if (config.time_enabled) {
            cmd += "-t";
            cmd += config.time_timestamp;
        }

        cmd += "-f"; cmd += "null";
        cmd += "-progress"; cmd += "pipe:2";
        cmd += "/dev/null";
        return cmd;
    }

    private string[] build_pass2 (string input, string safe_output) {
        string[] cmd = { AppSettings.get_default ().ffmpeg_path, "-y" };

        if (config.seek_enabled) {
            cmd += "-ss";
            cmd += config.seek_timestamp;
        }

        cmd += "-i"; cmd += input;

        if (config.video_filters != "") {
            cmd += "-vf"; cmd += config.video_filters;
        }

        foreach (string arg in config.codec_args) cmd += arg;

        cmd += "-pass"; cmd += "2";
        cmd += "-passlogfile"; cmd += config.passlog_base;

        if (config.preserve_metadata) { cmd += "-map_metadata"; cmd += "0"; }
        if (config.remove_chapters)   { cmd += "-map_chapters"; cmd += "-1"; }

        if (config.time_enabled) {
            cmd += "-t";
            cmd += config.time_timestamp;
        }

        foreach (string a in get_audio_args_with_filters ()) cmd += a;

        cmd += "-progress"; cmd += "pipe:2";
        cmd += safe_output;
        return cmd;
    }

    private string[] build_single_pass (string input, string safe_output) {
        string[] cmd = { AppSettings.get_default ().ffmpeg_path, "-y" };

        if (config.seek_enabled) {
            cmd += "-ss";
            cmd += config.seek_timestamp;
        }

        cmd += "-i"; cmd += input;

        if (config.video_filters != "") {
            cmd += "-vf"; cmd += config.video_filters;
        }

        foreach (string arg in config.codec_args) cmd += arg;

        if (config.preserve_metadata) { cmd += "-map_metadata"; cmd += "0"; }
        if (config.remove_chapters)   { cmd += "-map_chapters"; cmd += "-1"; }

        if (config.time_enabled) {
            cmd += "-t";
            cmd += config.time_timestamp;
        }

        foreach (string a in get_audio_args_with_filters ()) cmd += a;

        cmd += "-progress"; cmd += "pipe:2";
        cmd += safe_output;
        return cmd;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  AUDIO ARGS (from ConversionConfig, not from live widgets)
    // ═════════════════════════════════════════════════════════════════════════

    private string[] get_audio_args_with_filters () {
        return FilterBuilder.merge_audio_filters (config.audio_filters, config.audio_args);
    }
}
