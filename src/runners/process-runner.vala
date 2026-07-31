using GLib;
using Posix;

// ═══════════════════════════════════════════════════════════════════════════════
//  ProcessRunner — Thread-safe FFmpeg process execution
//
//  Shared by both Converter and TrimRunner. Provides:
//   • Mutex-guarded subprocess tracking and cancelled state
//   • Race-free SIGTERM via Gio.Subprocess
//   • SIGTERM → SIGKILL escalation on a watchdog thread
//   • Streaming stderr reader with configurable line callback
//   • Clean cancellation from any thread
//   • Single-owner lifecycle: preparing a new execution force-exits any stale child
//
// ═══════════════════════════════════════════════════════════════════════════════

public class ProcessRunner : Object {
    public enum CancelOutcome {
        NONE,
        REQUESTED,
        STOPPED_GRACEFULLY,
        STOPPED_BY_SIGTERM,
        FORCE_STOPPED
    }

    // ── Thread-safe shared state ────────────────────────────────────────────
    private Mutex state_mutex = Mutex ();
    private Subprocess? current_process = null;
    private Pid current_pid = 0;
    private bool cancelled = false;
    private CancelOutcome cancel_outcome = CancelOutcome.NONE;
    private uint64 current_execution_id = 0;
    private uint64 escalation_execution_id = 0;
    private uint64 next_execution_id = 1;

    // ── Optional line callback (for progress parsing, logging, etc.) ────────
    public delegate void LineCallback (string line);
    public delegate void EventCallback (string message);
    private EventCallback? event_logger = null;

    public void set_event_logger (owned EventCallback? callback) {
        event_logger = (owned) callback;
    }

    private void log_event (string terminal_message, string? console_message = null) {
        print ("%s\n", terminal_message);

        if (event_logger != null) {
            event_logger (console_message ?? terminal_message);
        }
    }

    private Pid extract_pid (Subprocess process) {
        string? id_str = process.get_identifier ();
        if (id_str == null) return 0;

        int parsed = 0;
        if (!int.try_parse (id_str, out parsed) || parsed <= 0) {
            print ("ProcessRunner: Failed to parse subprocess identifier '%s'\n", id_str);
            return 0;
        }

        return (Pid) parsed;
    }

    private void clear_current_process_if_current (uint64 execution_id,
                                                   Subprocess process) {
        state_mutex.lock ();
        try {
            if (current_execution_id == execution_id && current_process == process) {
                current_process = null;
                current_pid = 0;
                current_execution_id = 0;
                escalation_execution_id = 0;
            }
        } finally {
            state_mutex.unlock ();
        }
    }

    private void set_cancel_outcome_if_cancelled (CancelOutcome outcome) {
        state_mutex.lock ();
        try {
            if (cancelled) {
                cancel_outcome = outcome;
            }
        } finally {
            state_mutex.unlock ();
        }
    }

    public CancelOutcome get_cancel_outcome () {
        CancelOutcome outcome;

        state_mutex.lock ();
        try {
            outcome = cancel_outcome;
        } finally {
            state_mutex.unlock ();
        }

        return outcome;
    }

    public string get_cancel_completion_message () {
        switch (get_cancel_outcome ()) {
            case CancelOutcome.STOPPED_GRACEFULLY:
            case CancelOutcome.STOPPED_BY_SIGTERM:
                return "FFmpeg stopped cleanly.";
            case CancelOutcome.FORCE_STOPPED:
                return "FFmpeg was force-stopped.";
            case CancelOutcome.REQUESTED:
                return "FFmpeg stop was requested.";
            default:
                return "FFmpeg cancellation completed.";
        }
    }

    private int get_process_result (Subprocess process, Pid pid, bool cancel_requested) {
        if (process.get_if_exited ()) {
            if (cancel_requested) {
                set_cancel_outcome_if_cancelled (CancelOutcome.STOPPED_GRACEFULLY);
                if (pid > 0) {
                    log_event (
                        "ProcessRunner: FFmpeg process (PID %d) exited after cancel request".printf (pid),
                        "✅ FFmpeg stopped cleanly."
                    );
                } else {
                    log_event (
                        "ProcessRunner: FFmpeg process exited after cancel request",
                        "✅ FFmpeg stopped cleanly."
                    );
                }
            }
            return process.get_exit_status ();
        }

        if (process.get_if_signaled ()) {
            int signal_num = process.get_term_sig ();
            bool cancelled_by_user = cancel_requested;

            if (cancelled_by_user && signal_num == (int) Posix.Signal.TERM) {
                set_cancel_outcome_if_cancelled (CancelOutcome.STOPPED_BY_SIGTERM);
                if (pid > 0) {
                    log_event (
                        "ProcessRunner: FFmpeg process (PID %d) terminated by SIGTERM after cancel request"
                            .printf (pid),
                        "✅ FFmpeg stopped cleanly."
                    );
                } else {
                    log_event (
                        "ProcessRunner: FFmpeg process terminated by SIGTERM after cancel request",
                        "✅ FFmpeg stopped cleanly."
                    );
                }
                return 128 + signal_num;
            }

            if (cancelled_by_user && signal_num == (int) Posix.Signal.KILL) {
                set_cancel_outcome_if_cancelled (CancelOutcome.FORCE_STOPPED);
                // Fall through so the generic signal logger emits the existing
                // "FFmpeg was force-stopped." confirmation message.
            }

            if (pid > 0) {
                log_event (
                    "ProcessRunner: FFmpeg process (PID %d) terminated by signal %d".printf (
                        pid, signal_num
                    ),
                    signal_num == (int) Posix.Signal.KILL
                        ? "✅ FFmpeg was force-stopped."
                        : "⚠️ FFmpeg stopped due to signal %d.".printf (signal_num)
                );
            } else {
                log_event (
                    "ProcessRunner: FFmpeg process terminated by signal %d".printf (signal_num),
                    signal_num == (int) Posix.Signal.KILL
                        ? "✅ FFmpeg was force-stopped."
                        : "⚠️ FFmpeg stopped due to signal %d.".printf (signal_num)
                );
            }
            return 128 + signal_num;
        }

        if (pid > 0) {
            log_event ("ProcessRunner: FFmpeg process (PID %d) ended with unknown status".printf (pid));
        } else {
            log_event ("ProcessRunner: FFmpeg process ended with unknown status");
        }
        return -1;
    }

    private void start_force_exit_watchdog (uint64 execution_id,
                                            Subprocess process,
                                            Pid pid) {
        try {
            new Thread<void>.try ("ffmpeg-force-exit-watchdog", () => {
                Thread.usleep ((ulong) 3000000);

                bool should_force_exit;

                state_mutex.lock ();
                try {
                    should_force_exit = (current_execution_id == execution_id &&
                                         current_process == process);
                } finally {
                    state_mutex.unlock ();
                }

                if (!should_force_exit) {
                    return;
                }

                if (pid > 0) {
                    log_event (
                        "ProcessRunner: PID %d still alive after 3s — requesting SIGKILL".printf (pid),
                        "⚠️ FFmpeg did not stop after 3 seconds — force stopping it."
                    );
                } else {
                    log_event (
                        "ProcessRunner: FFmpeg still alive after 3s — requesting SIGKILL",
                        "⚠️ FFmpeg did not stop after 3 seconds — force stopping it."
                    );
                }

                process.force_exit ();
            });
        } catch (Error e) {
            log_event (
                "ProcessRunner: Failed to start SIGKILL watchdog: %s".printf (e.message),
                "⚠️ Failed to arm the stop watchdog — force stopping FFmpeg immediately."
            );
            log_event ("ProcessRunner: Falling back to immediate SIGKILL");
            process.force_exit ();
        }
    }

    private void request_cancel (uint64 execution_id,
                                 Subprocess process,
                                 Pid pid) {
        set_cancel_outcome_if_cancelled (CancelOutcome.REQUESTED);
        process.send_signal ((int) Posix.Signal.TERM);

        if (pid > 0) {
            log_event (
                "ProcessRunner: Requested SIGTERM for FFmpeg (PID %d)".printf (pid),
                "🛑 Asked FFmpeg to stop."
            );
        } else {
            log_event ("ProcessRunner: Requested SIGTERM for FFmpeg", "🛑 Asked FFmpeg to stop.");
        }

        start_force_exit_watchdog (execution_id, process, pid);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CANCELLATION
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Mark as cancelled and send SIGTERM to the running FFmpeg process.
     * Safe to call from any thread (main or background).
     * Repeated cancel() calls are intentionally idempotent for the same
     * execution: only the first request arms SIGKILL escalation.
     */
    public void cancel () {
        Subprocess? process_to_cancel = null;
        Pid pid_to_cancel = 0;
        uint64 execution_id = 0;
        bool should_request_cancel = false;

        state_mutex.lock ();
        try {
            cancelled = true;
            process_to_cancel = current_process;
            pid_to_cancel = current_pid;
            execution_id = current_execution_id;
            if (process_to_cancel != null &&
                execution_id != 0 &&
                escalation_execution_id != execution_id) {
                escalation_execution_id = execution_id;
                should_request_cancel = true;
            }
        } finally {
            state_mutex.unlock ();
        }

        if (!should_request_cancel || process_to_cancel == null) return;

        request_cancel (execution_id, process_to_cancel, pid_to_cancel);
    }

    /**
     * Check whether cancellation has been requested.
     * Thread-safe — can be called from any thread.
     */
    public bool is_cancelled () {
        bool is_cancelled;

        state_mutex.lock ();
        try {
            is_cancelled = cancelled;
        } finally {
            state_mutex.unlock ();
        }
        return is_cancelled;
    }

    /**
     * Prepare this runner for a new FFmpeg execution.
     * If a previous process is still tracked, force it down so the runner
     * remains a single-owner controller for exactly one live subprocess.
     */
    public void prepare_for_new_execution () {
        Subprocess? stale_process = null;
        Pid stale_pid = 0;

        state_mutex.lock ();
        try {
            cancelled = false;
            cancel_outcome = CancelOutcome.NONE;
            if (current_process != null) {
                stale_process = current_process;
                stale_pid = current_pid;
                current_process = null;
                current_pid = 0;
                current_execution_id = 0;
                escalation_execution_id = 0;
            }
        } finally {
            state_mutex.unlock ();
        }

        if (stale_process != null) {
            if (stale_pid > 0) {
                log_event ("ProcessRunner: Force-exiting stale FFmpeg process during runner reuse (PID %d)"
                    .printf (stale_pid));
            } else {
                log_event ("ProcessRunner: Force-exiting stale FFmpeg process during runner reuse");
            }
            stale_process.force_exit ();
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  EXECUTE FFMPEG
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Run an FFmpeg command, streaming stderr line-by-line to the callback.
     * Returns the process exit status, or -1 on launch failure.
     *
     * @param argv       The full FFmpeg command-line arguments
     * @param on_line    Optional callback for each stderr line (called from the calling thread)
     * @return           Exit status (0 = success) or -1 on error
     */
    public int execute (string[] argv, owned LineCallback? on_line = null) {
        uint64 execution_id = 0;
        Pid exec_pid = 0;
        Subprocess? process = null;

        try {
            var launcher = new SubprocessLauncher (SubprocessFlags.STDERR_PIPE);
            process = SubprocessCompat.spawnv (launcher, argv);
            bool should_cancel_immediately;

            exec_pid = extract_pid (process);

            state_mutex.lock ();
            try {
                execution_id = next_execution_id++;
                current_execution_id = execution_id;
                current_process = process;
                current_pid = exec_pid;
                escalation_execution_id = 0;
                should_cancel_immediately = cancelled;
                if (should_cancel_immediately) {
                    escalation_execution_id = execution_id;
                }
            } finally {
                state_mutex.unlock ();
            }

            // cancel() may have raced with spawnv() before the subprocess was
            // registered; honour that cancellation immediately once tracked.
            if (should_cancel_immediately) {
                request_cancel (execution_id, process, exec_pid);
            }

            var reader = new DataInputStream (process.get_stderr_pipe ());

            string line;
            bool suppress_output = false;
            while ((line = reader.read_line (null)) != null) {
                // Keep draining stderr after cancellation so FFmpeg cannot
                // block on a full pipe while we're waiting for it to exit.
                if (!suppress_output && is_cancelled ()) {
                    suppress_output = true;
                }

                string clean = line.strip ();
                if (suppress_output || clean.length == 0) continue;

                if (on_line != null) {
                    on_line (clean);
                }
            }

            process.wait ();
            bool cancel_requested = is_cancelled ();
            int result = get_process_result (process, exec_pid, cancel_requested);
            clear_current_process_if_current (execution_id, process);

            return result;

        } catch (Error e) {
            if (on_line != null) {
                on_line ("❌ FFmpeg launch error: " + e.message);
            }

            if (execution_id != 0) {
                clear_current_process_if_current (execution_id, process);
            }

            return -1;
        }
    }

    /**
     * Run a command while capturing both output streams and retaining the same
     * cancellation guarantees as execute().  This is intended for short,
     * bounded helper probes whose stdout is their result rather than a progress
     * stream.
     */
    public int execute_capture (string[] argv,
                                out string stdout_text,
                                out string stderr_text) {
        stdout_text = "";
        stderr_text = "";

        uint64 execution_id = 0;
        Pid exec_pid = 0;
        Subprocess? process = null;

        try {
            var launcher = new SubprocessLauncher (
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            process = SubprocessCompat.spawnv (launcher, argv);
            bool should_cancel_immediately;

            exec_pid = extract_pid (process);

            state_mutex.lock ();
            try {
                execution_id = next_execution_id++;
                current_execution_id = execution_id;
                current_process = process;
                current_pid = exec_pid;
                escalation_execution_id = 0;
                should_cancel_immediately = cancelled;
                if (should_cancel_immediately) {
                    escalation_execution_id = execution_id;
                }
            } finally {
                state_mutex.unlock ();
            }

            if (should_cancel_immediately) {
                request_cancel (execution_id, process, exec_pid);
            }

            process.communicate_utf8 (
                null, null, out stdout_text, out stderr_text);

            bool cancel_requested = is_cancelled ();
            int result = get_process_result (process, exec_pid, cancel_requested);
            clear_current_process_if_current (execution_id, process);
            return result;
        } catch (Error e) {
            stderr_text = e.message;
            if (execution_id != 0 && process != null) {
                clear_current_process_if_current (execution_id, process);
            }
            return -1;
        }
    }
}
