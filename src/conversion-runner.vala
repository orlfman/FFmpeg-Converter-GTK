using Gtk;

// ═══════════════════════════════════════════════════════════════════════════════
//  ConversionRunner — Builds and executes FFmpeg commands for encoding
//
//  Refactored (#3): No longer reaches into converter.general_tab, codec_tab,
//  or passlog_base. Instead, receives a ConversionConfig with all data
//  pre-snapshot from the main thread. This:
//   • Eliminates cross-thread widget access
//   • Makes the runner testable with mock configs
//   • Decouples encoding logic from UI widget state
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
                if (converter.execute_ffmpeg (pass1, true) != 0) {
                    if (!converter.is_cancelled ())
                        converter.report_error ("Pass 1 failed.");
                    return;
                }

                if (converter.is_cancelled ()) return;

                converter.set_phase (ConversionPhase.PASS2);
                converter.update_status (@"🔄 Pass 2/2: Encoding final $(config.codec_name) video...");
                string[] pass2 = build_pass2 (input, safe_output);
                if (converter.execute_ffmpeg (pass2) != 0) {
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
    //  All data comes from ConversionConfig — no widget access (#3)
    // ═════════════════════════════════════════════════════════════════════════

    private string[] build_pass1 (string input) {
        string[] cmd = { "ffmpeg", "-y" };

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
        string[] cmd = { "ffmpeg", "-y" };

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
        string[] cmd = { "ffmpeg", "-y" };

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
        string af = config.audio_filters;
        string[] audio_args = config.audio_args;

        // If no general audio filters to apply, return as-is
        if (af == "") return audio_args;

        // Cannot apply audio filters when audio is disabled or stream-copied
        if (audio_args.length > 0 && (audio_args[0] == "-an" ||
            (audio_args.length >= 2 && audio_args[0] == "-c:a" && audio_args[1] == "copy")))
            return audio_args;

        string[] merged = {};
        bool found_af = false;
        for (int i = 0; i < audio_args.length; i++) {
            if (audio_args[i] == "-af" && i + 1 < audio_args.length) {
                merged += "-af";
                merged += af + "," + audio_args[i + 1];
                i++;
                found_af = true;
            } else {
                merged += audio_args[i];
            }
        }

        if (!found_af) {
            merged += "-af";
            merged += af;
        }

        return merged;
    }
}
