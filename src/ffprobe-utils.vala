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
                "ffprobe", "-v", "quiet",
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
}
