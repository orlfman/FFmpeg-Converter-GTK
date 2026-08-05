using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  CollageRunner — On-demand 4-4-4 collage generation for an existing video
//
//  ConversionRunner and TrimRunner already write a "<name>-collage.png" sidecar
//  as a post-encode pass over a file they just produced. This runner performs
//  the same pass for a file the user picked, with no encode in front of it, so
//  there is no config-derived duration to fall back on: the video's own packet
//  timeline is the only source of truth, and a file whose timeline cannot be
//  read is reported rather than guessed at.
//
//  Command construction stays in ConversionUtils so all three callers produce
//  an identical collage.
// ═══════════════════════════════════════════════════════════════════════════════

public class CollageRunner : Object {

    private ProcessRunner runner = new ProcessRunner ();
    private string source_path = "";

    // UI reference (nullable — set before run)
    public ConsoleTab? console_tab { get; set; default = null; }

    // ── Signals ─────────────────────────────────────────────────────────────
    public signal void collage_done (OperationOutputResult output_result);
    public signal void collage_failed (string message);
    public signal void collage_cancelled (string cancel_message);
    public signal void collage_progress (string message);

    // ═════════════════════════════════════════════════════════════════════════
    //  PUBLIC API
    // ═════════════════════════════════════════════════════════════════════════

    public void run (string source_path) {
        this.source_path = source_path;

        runner.set_event_logger (log_line);
        runner.prepare_for_new_execution ();

        try {
            new Thread<void>.try ("collage-thread", () => {
                try {
                    run_internal ();
                } finally {
                    // ProcessRunner keeps an owned reference to this callback's
                    // target while this runner owns the ProcessRunner, so the
                    // pair strands itself. The other runners live as long as
                    // their tab and never notice; this one is built per run and
                    // would leak on every click, so drop the logger once the run
                    // is over to close the cycle.
                    runner.set_event_logger (null);
                }
            });
        } catch (Error e) {
            runner.set_event_logger (null);
            report_failed ("Failed to start the collage thread: " + e.message);
        }
    }

    public void cancel () {
        runner.cancel ();
    }

    public bool is_cancelled () {
        return runner.is_cancelled ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Runs on the collage thread
    // ═════════════════════════════════════════════════════════════════════════

    private void run_internal () {
        if (!FileUtils.test (source_path, FileTest.IS_REGULAR)) {
            report_failed (@"The selected file no longer exists:\n$source_path");
            return;
        }

        // Every probe below reports failure as a plain false, so an ffprobe that
        // cannot even start is indistinguishable from a file with no video in
        // it. Resolve the tools first, otherwise a bad path in Preferences gets
        // reported as a problem with the user's video.
        string? tool_problem = find_unusable_tool ();
        if (tool_problem != null) {
            report_failed (tool_problem);
            return;
        }

        report_progress ("Reading video timeline…");

        if (!FfprobeUtils.has_video_stream (source_path)) {
            report_failed (
                "The selected file has no video stream, so there are no frames "
                + "to build a collage from."
            );
            return;
        }
        if (runner.is_cancelled ()) {
            report_cancelled ();
            return;
        }

        string? collage_output_path =
            ConversionUtils.resolve_collage_output_path (source_path);
        if (collage_output_path == null || collage_output_path.length == 0) {
            report_failed (
                "Could not determine a writable output path next to the source file."
            );
            return;
        }

        double video_start_time = 0.0;
        bool single_frame_video = false;
        VideoTimelineProbeResult video_timeline =
            FfprobeUtils.probe_video_timeline (
                source_path, runner.execute_capture);
        if (runner.is_cancelled ()) {
            report_cancelled ();
            return;
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
        } else {
            report_failed (
                "Could not read a usable video timeline from the selected file, "
                + "so the twelve capture points cannot be placed safely."
            );
            return;
        }
        if (!single_frame_video && duration_seconds <= 0.0) {
            report_failed (
                "Could not determine the duration of the selected file."
            );
            return;
        }

        report_progress ("Generating 4-4-4 collage thumbnail…");

        string[] collage_cmd = ConversionUtils.build_collage_argv (
            AppSettings.get_default ().ffmpeg_path,
            source_path,
            collage_output_path,
            duration_seconds,
            video_start_time,
            single_frame_video,
            AppSettings.get_default ().collage_size
        );
        log_line ("Collage command: "
            + ConversionUtils.format_command_for_display (collage_cmd));

        int exit = runner.execute (collage_cmd, (clean) => {
            if (ConversionUtils.should_log_ffmpeg_line (clean)) {
                log_line (clean);
            }
        });

        if (exit != 0) {
            if (runner.is_cancelled ()) {
                report_cancelled ();
            } else {
                report_failed (
                    @"FFmpeg failed while generating the collage (exit code $exit). "
                    + "See the Console tab for details."
                );
            }
            return;
        }

        // Exit zero does not prove a file was written — a run that decoded no
        // frames still exits cleanly.
        if (!FileUtils.test (collage_output_path, FileTest.EXISTS)) {
            if (runner.is_cancelled ()) {
                report_cancelled ();
            } else {
                report_failed (
                    "FFmpeg completed but the PNG collage file was not created."
                );
            }
            return;
        }

        log_line ("[Collage] Created " + collage_output_path);
        report_done (
            new OperationOutputResult.for_file (
                collage_output_path,
                OperationOutputSource.GENERIC,
                Path.get_basename (source_path)
            )
        );
    }

    private static string? find_unusable_tool () {
        var settings = AppSettings.get_default ();

        if (resolve_tool (settings.ffprobe_path) == null) {
            return @"ffprobe could not be found at '$(settings.ffprobe_path)'. "
                + "Check the FFmpeg paths in Preferences.";
        }
        if (resolve_tool (settings.ffmpeg_path) == null) {
            return @"FFmpeg could not be found at '$(settings.ffmpeg_path)'. "
                + "Check the FFmpeg paths in Preferences.";
        }
        return null;
    }

    private static string? resolve_tool (string configured_path) {
        if (configured_path.length == 0)
            return null;

        if (configured_path.contains ("/")) {
            return FileUtils.test (configured_path, FileTest.IS_EXECUTABLE)
                ? configured_path
                : null;
        }
        return Environment.find_program_in_path (configured_path);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  MAIN-THREAD MARSHALLING
    // ═════════════════════════════════════════════════════════════════════════

    // Console only. ProcessRunner has already printed its own terminal wording
    // by the time it hands the console phrasing to this logger, so printing
    // here would put both variants of the same event on the terminal.
    private void log_line (string text) {
        if (console_tab != null) {
            Idle.add (() => {
                console_tab.add_line (text);
                return Source.REMOVE;
            });
        }
    }

    private void report_progress (string message) {
        Idle.add (() => {
            collage_progress (message);
            return Source.REMOVE;
        });
    }

    private void report_done (OperationOutputResult output_result) {
        Idle.add (() => {
            collage_done (output_result);
            return Source.REMOVE;
        });
    }

    private void report_failed (string message) {
        Idle.add (() => {
            collage_failed (message);
            return Source.REMOVE;
        });
    }

    private void report_cancelled () {
        string cancel_message = runner.get_cancel_completion_message ();
        Idle.add (() => {
            collage_cancelled (cancel_message);
            return Source.REMOVE;
        });
    }
}
