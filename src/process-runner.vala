using GLib;
using Posix;

// ═══════════════════════════════════════════════════════════════════════════════
//  ProcessRunner — Thread-safe FFmpeg process execution
//
//  Shared by both Converter and TrimRunner. Provides:
//   • Mutex-guarded PID and cancelled state
//   • Proper Posix.kill() with return-value checking (not try/catch)
//   • SIGTERM → SIGKILL escalation after 3 seconds with generation guard
//   • Streaming stderr reader with configurable line callback
//   • Clean cancellation from any thread
//
// ═══════════════════════════════════════════════════════════════════════════════

public class ProcessRunner : Object {

    // ── Thread-safe shared state ────────────────────────────────────────────
    private Mutex state_mutex = Mutex ();
    private Pid current_pid = 0;
    private bool cancelled = false;

    // Generation counter — incremented on each reset().
    // The SIGKILL escalation timeout captures the generation at cancel time
    // and skips the kill if reset() has been called since, which means the
    // PID may have been recycled by the OS for an unrelated process.
    private int64 cancel_generation = 0;

    // ── Optional line callback (for progress parsing, logging, etc.) ────────
    public delegate void LineCallback (string line);

    // ═════════════════════════════════════════════════════════════════════════
    //  CANCELLATION
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Mark as cancelled and send SIGTERM to the running FFmpeg process.
     * Safe to call from any thread (main or background).
     */
    public void cancel () {
        state_mutex.lock ();
        cancelled = true;
        Pid pid_to_kill = current_pid;
        current_pid = 0;
        int64 gen = cancel_generation;
        state_mutex.unlock ();

        if (pid_to_kill <= 0) return;

        // Posix.kill() returns int — does NOT throw exceptions in Vala.
        if (Posix.kill (pid_to_kill, Posix.Signal.TERM) != 0) {
            print ("ProcessRunner: Failed to send SIGTERM to PID %d: errno %d\n",
                   pid_to_kill, Posix.errno);
        } else {
            print ("ProcessRunner: Sent SIGTERM to FFmpeg (PID %d)\n", pid_to_kill);
        }

        // Escalate to SIGKILL after 3 seconds if process is still alive.
        //
        // Timeout.add() always attaches to the global default main context,
        // so this is safe to call from any thread — the old Idle.add wrapper
        // was unnecessary.
        //
        // The generation guard prevents killing a recycled PID: if reset()
        // is called before the timeout fires, cancel_generation will have
        // changed and the kill is skipped.
        Pid kill_pid = pid_to_kill;
        int64 kill_gen = gen;
        Timeout.add (3000, () => {
            state_mutex.lock ();
            bool still_valid = (cancel_generation == kill_gen);
            state_mutex.unlock ();

            if (still_valid && Posix.kill (kill_pid, 0) == 0) {
                print ("ProcessRunner: PID %d still alive after 3s — sending SIGKILL\n", kill_pid);
                Posix.kill (kill_pid, Posix.Signal.KILL);
            }
            return Source.REMOVE;
        });
    }

    /**
     * Check whether cancellation has been requested.
     * Thread-safe — can be called from any thread.
     */
    public bool is_cancelled () {
        state_mutex.lock ();
        bool c = cancelled;
        state_mutex.unlock ();
        return c;
    }

    /**
     * Reset the cancelled flag. Call before starting a new operation.
     * Increments the generation counter so any pending SIGKILL escalation
     * from a previous cancel() will be safely skipped.
     */
    public void reset () {
        state_mutex.lock ();
        cancelled = false;
        current_pid = 0;
        cancel_generation++;
        state_mutex.unlock ();
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
        try {
            var launcher = new SubprocessLauncher (SubprocessFlags.STDERR_PIPE);
            var process = launcher.spawnv (argv);

            // Safe PID handling — only store valid positive PIDs
            string? id_str = process.get_identifier ();
            if (id_str != null) {
                int parsed = int.parse (id_str);
                if (parsed > 0) {
                    state_mutex.lock ();
                    current_pid = (Pid) parsed;
                    state_mutex.unlock ();
                }
            }

            var reader = new DataInputStream (process.get_stderr_pipe ());

            string line;
            while ((line = reader.read_line (null)) != null) {
                // Early exit if cancelled
                if (is_cancelled ()) break;

                string clean = line.strip ();
                if (clean.length == 0) continue;

                if (on_line != null) {
                    on_line (clean);
                }
            }

            process.wait ();

            state_mutex.lock ();
            current_pid = 0;
            state_mutex.unlock ();

            return process.get_exit_status ();

        } catch (Error e) {
            if (on_line != null) {
                on_line ("❌ FFmpeg launch error: " + e.message);
            }

            state_mutex.lock ();
            current_pid = 0;
            state_mutex.unlock ();

            return -1;
        }
    }
}
