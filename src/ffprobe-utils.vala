using GLib;

namespace FfprobeUtils {

    /**
     * Probe the frame rate of the first video stream in @input_file
     * using ffprobe.  Returns 0.0 on any failure so callers can fall
     * back to a default.
     */
    public double probe_input_fps (string input_file) {
        try {
            string[] cmd = {
                AppSettings.get_default ().ffprobe_path,
                "-v", "quiet",
                "-select_streams", "v:0",
                "-show_entries", "stream=r_frame_rate",
                "-of", "csv=p=0",
                input_file
            };
            string stdout_text, stderr_text;
            int status;

            Process.spawn_sync (null, cmd, null, SpawnFlags.SEARCH_PATH,
                                null, out stdout_text, out stderr_text, out status);

            if (status != 0 || stdout_text == null)
                return 0.0;

            // Typical output: "24000/1001" or "30/1" or "29.97"
            string raw = stdout_text.strip ();

            if (raw.contains ("/")) {
                string[] parts = raw.split ("/");
                if (parts.length >= 2) {
                    double num = double.parse (parts[0].strip ());
                    double den = double.parse (parts[1].strip ());
                    if (den > 0.0)
                        return num / den;
                }
            }

            double plain = double.parse (raw);
            if (plain > 0.0) return plain;

        } catch (Error e) {
            // probe failed — caller uses fallback
        }
        return 0.0;
    }

    /**
     * Probe the total duration of @input_file in seconds using ffprobe.
     * Returns 0.0 on any failure so callers can treat it as "unknown duration"
     * and fall back to pulse-mode progress.
     *
     * Previously lived in Converter — moved here so any component that needs
     * duration (Converter, TrimRunner, SubtitlesRunner) can use it without
     * depending on Converter.
     */
    public double probe_duration (string input_file) {
        try {
            string[] cmd = {
                AppSettings.get_default ().ffprobe_path,
                "-v", "quiet",
                "-print_format", "csv=p=0",
                "-show_entries", "format=duration",
                input_file
            };
            string stdout_buf, stderr_buf;
            int status;

            Process.spawn_sync (null, cmd, null,
                                SpawnFlags.SEARCH_PATH,
                                null, out stdout_buf, out stderr_buf, out status);

            if (status == 0) {
                double dur = double.parse (stdout_buf.strip ());
                if (dur > 0) return dur;
            }
        } catch (Error e) {
            print ("ffprobe duration error: %s\n", e.message);
        }
        return 0.0;
    }
}
