using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  LogoDetector — Drives FFmpeg to sample a video, then hands the pixels to
//  LogoDetectorLogic for analysis.
//
//  run() blocks, so call it from a worker thread (GeneralTab does, the same
//  way it runs crop detection).  Progress is reported through the supplied
//  log callback, which is responsible for hopping back to the main loop.
// ═══════════════════════════════════════════════════════════════════════════════

public class LogoDetectionResult : Object {
    public bool success { get; set; default = false; }

    /** "x:y:w:h" entries, comma separated, in source-frame coordinates. */
    public string regions { get; set; default = ""; }

    /** User-facing summary — the reason for the failure when !success. */
    public string message { get; set; default = ""; }

    public int region_count { get; set; default = 0; }
    public int frames_analyzed { get; set; default = 0; }
}

public delegate void LogoDetectLogFunc (string line);

namespace LogoDetector {

    /**
     * Scans @input_file for a static watermark.
     *
     * Blocks for as long as the sampling takes (a few seconds for most
     * files) and never throws — every failure comes back as an unsuccessful
     * result carrying a message fit to show the user.
     */
    public LogoDetectionResult run (string input_file,
                                    string ffmpeg_path,
                                    string ffprobe_path,
                                    LogoDetectLogFunc log) {
        var result = new LogoDetectionResult ();

        int source_w, source_h;
        if (!probe_dimensions (ffprobe_path, input_file, out source_w, out source_h)) {
            result.message = "Could not read the video resolution — is this a video file?";
            return result;
        }

        double duration = FfprobeUtils.probe_duration (input_file);
        LogoSampleWindow[] windows = LogoDetectorLogic.plan_sample_windows (duration);

        // The quick scan first.  Only if it comes back empty is the video read
        // a second time at double the width: shrinking the frame is what blurs
        // fine lettering away, and a wider scan measures the same picture more
        // faithfully rather than judging it more loosely.  Nothing is lost by
        // trying — a watermark found at 480 is returned before this happens.
        int[] widths = {
            LogoDetectorLogic.ANALYSIS_WIDTH,
            LogoDetectorLogic.ANALYSIS_WIDTH_RETRY
        };

        // Empty until a pass actually reaches a verdict; if none does, the
        // video was too small for any of them to run.
        string reason = "";
        int previous_w = 0;

        foreach (int width in widths) {
            int analysis_w, analysis_h;
            LogoDetectorLogic.compute_analysis_size (source_w, source_h,
                                                     out analysis_w, out analysis_h,
                                                     width);
            if (analysis_w < LogoDetectorLogic.MIN_ANALYSIS_DIM
                || analysis_h < LogoDetectorLogic.MIN_ANALYSIS_DIM) continue;

            // A source narrower than the retry width is already being read at
            // its own resolution; scanning it again would decode the same
            // pixels twice for the same answer.
            if (analysis_w == previous_w) break;
            previous_w = analysis_w;

            log ("[Watermark] Source %dx%d — sampling %d window(s) at %dx%d".printf (
                source_w, source_h, windows.length, analysis_w, analysis_h));

            var stats = new LogoFrameStats (analysis_w, analysis_h);
            foreach (LogoSampleWindow window in windows) {
                string? failure = sample_window (ffmpeg_path, input_file, window,
                                                 analysis_w, analysis_h, stats, log);
                if (failure != null) {
                    result.message = failure;
                    return result;
                }
            }

            result.frames_analyzed = stats.frame_count;
            if (stats.frame_count < LogoDetectorLogic.MIN_USABLE_FRAMES) {
                result.message =
                    "Only %d frames could be sampled — not enough to detect a watermark"
                    .printf (stats.frame_count);
                return result;
            }

            log ("[Watermark] Analyzing %d sampled frames".printf (stats.frame_count));

            string pass_reason;
            LogoRegion[] found = LogoDetectorLogic.detect_regions (
                stats.compute_mean (), stats.compute_stddev (),
                analysis_w, analysis_h, out pass_reason);
            if (found.length == 0) {
                log ("[Watermark] Nothing at %dpx — %s".printf (analysis_w, pass_reason));
                // The first pass explains the video; a wider retry that also
                // comes up empty has nothing better to say, and swapping the
                // wording would only make the same answer look like a
                // different one.
                if (reason.length == 0) reason = pass_reason;
                continue;
            }

            LogoRegion[] scaled = LogoDetectorLogic.scale_regions_to_source (
                found, analysis_w, analysis_h, source_w, source_h);
            if (scaled.length == 0) {
                if (reason.length == 0) {
                    reason = "The detected area could not be mapped back onto the source frame";
                }
                continue;
            }

            result.success = true;
            result.region_count = scaled.length;
            result.regions = LogoDetectorLogic.format_regions (scaled);
            result.message = LogoDetectorLogic.describe_regions (scaled);
            return result;
        }

        result.message = reason.length > 0
            ? reason
            : "The video is too small to scan for a watermark";
        return result;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  FFMPEG SAMPLING
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Decodes one window into grayscale rawvideo and folds every frame into
     * @stats.  Returns null on success, or a user-facing failure message.
     *
     * stderr is silenced rather than piped: the frames come down stdout and
     * draining a second pipe only after stdout hits EOF risks deadlocking on
     * a chatty file.  The exit status is enough to tell a real failure apart
     * from a window that simply had nothing to decode.
     */
    private string? sample_window (string ffmpeg_path, string input_file,
                                   LogoSampleWindow window,
                                   int analysis_w, int analysis_h,
                                   LogoFrameStats stats,
                                   LogoDetectLogFunc log) {
        string filter = "fps=%s,scale=%d:%d:flags=area,format=gray".printf (
            ConversionUtils.format_ffmpeg_double (window.fps, "%.4f"),
            analysis_w, analysis_h);

        string[] cmd = {
            ffmpeg_path,
            "-hide_banner", "-nostdin", "-loglevel", "error", "-nostats",
            "-ss", ConversionUtils.format_ffmpeg_double (window.start, "%.3f"),
            "-i", input_file,
            "-t", ConversionUtils.format_ffmpeg_double (window.length, "%.3f"),
            "-an", "-sn", "-dn",
            "-vf", filter,
            "-pix_fmt", "gray",
            "-f", "rawvideo",
            "-"
        };

        log ("[Watermark] " + ConversionUtils.format_command_for_display (cmd));

        int frames_before = stats.frame_count;

        try {
            var launcher = new SubprocessLauncher (
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
            var process = SubprocessCompat.spawnv (launcher, cmd);
            var stream = process.get_stdout_pipe ();

            size_t frame_bytes = (size_t) analysis_w * analysis_h;
            var frame = new uint8[frame_bytes];

            while (true) {
                size_t bytes_read;
                stream.read_all (frame, out bytes_read, null);
                if (bytes_read < frame_bytes) break;   // EOF or a torn final frame
                stats.add_frame (frame);
            }

            process.wait ();

            int gained = stats.frame_count - frames_before;
            if (gained == 0 && process.get_if_exited () && process.get_exit_status () != 0) {
                return "FFmpeg could not decode this file (exit code %d)"
                    .printf (process.get_exit_status ());
            }

            log ("[Watermark] Sampled %d frames from %.1fs".printf (gained, window.start));
        } catch (GLib.Error e) {
            return "Watermark scan failed: " + e.message;
        }

        return null;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PROBING
    // ═════════════════════════════════════════════════════════════════════════

    private bool probe_dimensions (string ffprobe_path, string input_file,
                                   out int width, out int height) {
        width = 0;
        height = 0;

        string[] cmd = {
            ffprobe_path, "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=width,height",
            "-of", "csv=s=x:p=0",
            input_file
        };

        string output;
        if (!capture_output (cmd, out output)) return false;

        // ffprobe prints "1920x1080"; some builds add a trailing separator.
        string[] parts = output.strip ().split ("x");
        if (parts.length < 2) return false;

        width = int.parse (parts[0].strip ());
        height = int.parse (parts[1].strip ());
        return width > 0 && height > 0;
    }

    private bool capture_output (string[] cmd, out string output) {
        output = "";

        try {
            var launcher = new SubprocessLauncher (
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
            var process = SubprocessCompat.spawnv (launcher, cmd);

            string? stdout_text = null;
            process.communicate_utf8 (null, null, out stdout_text, null);
            if (!process.get_successful ()) return false;

            output = stdout_text ?? "";
            return true;
        } catch (GLib.Error e) {
            return false;
        }
    }
}
