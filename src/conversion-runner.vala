using Gtk;

public class ConversionRunner {

    private Converter converter;
    private ICodecBuilder codec_builder;

    public ConversionRunner (Converter converter, ICodecBuilder codec_builder) {
        this.converter = converter;
        this.codec_builder = codec_builder;
    }

    public void run (string input, string output, bool two_pass) {
        converter.passlog_base = "/tmp/svtav1_passlog_" + GLib.get_monotonic_time ().to_string ();
        string vf = FilterBuilder.build_video_filter_chain (converter.general_tab);
        string af = FilterBuilder.build_audio_filter_chain (converter.general_tab);
        string safe_output = converter.sanitize_filename (output);
        string codec_name = codec_builder.get_codec_name ();

	string[] codec_args = codec_builder.get_codec_args (converter.codec_tab);

	if (converter.codec_tab is SvtAv1Tab) {
            foreach (string kf_arg in ((SvtAv1Tab) converter.codec_tab).resolve_keyframe_args (
                         input, converter.general_tab)) {
                codec_args += kf_arg;
            }
        } else if (converter.codec_tab is X265Tab) {
            foreach (string kf_arg in ((X265Tab) converter.codec_tab).resolve_keyframe_args (
                         input, converter.general_tab)) {
                codec_args += kf_arg;
            }
        }

        try {
            if (two_pass) {
                converter.set_phase (ConversionPhase.PASS1);
                converter.update_status ("🔄 Pass 1/2: Analyzing video...");
                string[] pass1 = build_pass1 (input, vf, converter.passlog_base, codec_args);
                if (converter.execute_ffmpeg (pass1, true) != 0) {
                    converter.report_error ("Pass 1 failed.");
                    return;
                }

                converter.set_phase (ConversionPhase.PASS2);
                converter.update_status (@"🔄 Pass 2/2: Encoding final $codec_name video...");
                string[] pass2 = build_pass2 (input, safe_output, vf, af, converter.passlog_base, codec_args);
                if (converter.execute_ffmpeg (pass2) != 0) {
                    converter.report_error ("Pass 2 failed.");
                    return;
                }
            } else {
                converter.set_phase (ConversionPhase.PASS2);
                converter.update_status (@"🔄 Encoding with $codec_name (single pass...)");
                string[] cmd = build_single_pass (input, safe_output, vf, af, codec_args);
                if (converter.execute_ffmpeg (cmd) != 0) {
                    converter.report_error ("Encoding failed.");
                    return;
                }
            }
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

    private string[] build_pass1 (string input, string vf, string passlog_base, string[] codec_args) {
        string[] cmd = { "ffmpeg", "-y" };
        if (converter.general_tab.seek_check.active) {
            string s = @"$(converter.general_tab.seek_hh.text):$(converter.general_tab.seek_mm.text):$(converter.general_tab.seek_ss.text)";
            cmd += "-ss"; cmd += s;
        }
        cmd += "-i"; cmd += input;
        if (vf != "") { cmd += "-vf"; cmd += vf; }
        foreach (string arg in codec_args) cmd += arg;
        cmd += "-pass"; cmd += "1";
        cmd += "-passlogfile"; cmd += passlog_base;
        cmd += "-an";
        if (converter.general_tab.time_check.active) {
            string t = @"$(converter.general_tab.time_hh.text):$(converter.general_tab.time_mm.text):$(converter.general_tab.time_ss.text)";
            cmd += "-t"; cmd += t;
        }
        cmd += "-f"; cmd += "null";
        cmd += "-progress"; cmd += "pipe:2";
        cmd += "/dev/null";
        return cmd;
    }

    private string[] build_pass2 (string input, string safe_output, string vf, string af, string passlog_base, string[] codec_args) {
        string[] cmd = { "ffmpeg", "-y" };
        if (converter.general_tab.seek_check.active) {
            string s = @"$(converter.general_tab.seek_hh.text):$(converter.general_tab.seek_mm.text):$(converter.general_tab.seek_ss.text)";
            cmd += "-ss"; cmd += s;
        }
        cmd += "-i"; cmd += input;
        if (vf != "") { cmd += "-vf"; cmd += vf; }
        foreach (string arg in codec_args) cmd += arg;
        cmd += "-pass"; cmd += "2";
        cmd += "-passlogfile"; cmd += passlog_base;
        if (converter.general_tab.preserve_metadata.active) { cmd += "-map_metadata"; cmd += "0"; }
        if (converter.general_tab.remove_chapters.active) { cmd += "-map_chapters"; cmd += "-1"; }
        if (converter.general_tab.time_check.active) {
            string t = @"$(converter.general_tab.time_hh.text):$(converter.general_tab.time_mm.text):$(converter.general_tab.time_ss.text)";
            cmd += "-t"; cmd += t;
        }
	foreach (string a in get_audio_args_with_filters (af)) cmd += a;
        cmd += "-progress"; cmd += "pipe:2";
        cmd += safe_output;
        return cmd;
    }

    private string[] build_single_pass (string input, string safe_output, string vf, string af, string[] codec_args) {
        string[] cmd = { "ffmpeg", "-y" };
        if (converter.general_tab.seek_check.active) {
            string s = @"$(converter.general_tab.seek_hh.text):$(converter.general_tab.seek_mm.text):$(converter.general_tab.seek_ss.text)";
            cmd += "-ss"; cmd += s;
        }
        cmd += "-i"; cmd += input;
        if (vf != "") { cmd += "-vf"; cmd += vf; }
        foreach (string arg in codec_args) cmd += arg;
        if (converter.general_tab.preserve_metadata.active) { cmd += "-map_metadata"; cmd += "0"; }
        if (converter.general_tab.remove_chapters.active) { cmd += "-map_chapters"; cmd += "-1"; }
        if (converter.general_tab.time_check.active) {
            string t = @"$(converter.general_tab.time_hh.text):$(converter.general_tab.time_mm.text):$(converter.general_tab.time_ss.text)";
            cmd += "-t"; cmd += t;
        }
	foreach (string a in get_audio_args_with_filters (af)) cmd += a;
        cmd += "-progress"; cmd += "pipe:2";
        cmd += safe_output;
        return cmd;
    }
    
	private string[] get_audio_args_with_filters (string af) {
        string[] audio_args = get_audio_args ();

        // If no general audio filters to apply, return as-is
        if (af == "") return audio_args;

        // Cannot apply audio filters when audio is disabled or stream-copied
        if (audio_args.length > 0 && (audio_args[0] == "-an" ||
            (audio_args.length >= 2 && audio_args[0] == "-c:a" && audio_args[1] == "copy")))
            return audio_args;

        // Merge the general audio filter chain (atempo, loudnorm) with any
        // -af already emitted by audio-settings (e.g. Opus surround fix).
        string[] merged = {};
        bool found_af = false;
        for (int i = 0; i < audio_args.length; i++) {
            if (audio_args[i] == "-af" && i + 1 < audio_args.length) {
                // Merge: prepend our general filters before the codec-specific ones
                merged += "-af";
                merged += af + "," + audio_args[i + 1];
                i++;  // skip the value we just merged
                found_af = true;
            } else {
                merged += audio_args[i];
            }
        }

        if (!found_af) {
            // No existing -af from audio-settings, just add ours
            merged += "-af";
            merged += af;
        }

        return merged;
    }

	private string[] get_audio_args () {
        if (converter.codec_tab is SvtAv1Tab) {
            return ((SvtAv1Tab) converter.codec_tab).audio_settings.get_audio_args ();
        } else if (converter.codec_tab is X265Tab) {
            return ((X265Tab) converter.codec_tab).audio_settings.get_audio_args ();
        }
        return { "-c:a", "copy" };
    }
    
}
