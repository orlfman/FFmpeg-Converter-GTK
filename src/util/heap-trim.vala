using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  HeapTrim — Return freed allocator pages to the kernel after media teardown
//
//  Playback and decoding build large working sets. The player frees all of it
//  when the input changes, but glibc keeps the pages mapped: non-main arenas
//  only shrink from their top subheap, and playback leaves many 64 MiB subheaps
//  behind. The process therefore sits at its peak RSS even though almost
//  nothing is in use.
//
//  The libmpv backend bounds the peak far below what the previous GStreamer
//  path reached, so the numbers below no longer occur — but the allocator
//  retention itself is unchanged, and repeated input changes still ratchet RSS
//  upward without this.
//
//  Measured on a 9.5 GB 4K AV1 WebM (see
//  docs/input-load-memory-spike-findings.md): after switching to a small file
//  the process held 36.20 GiB RSS with 99.5% of the heap free. This code
//  returned 35.79 GiB of it — 98.9% — leaving the application running normally.
//
//  This is a cleanup for residual memory only. It does nothing for peak usage
//  while a file is loaded, because that memory is genuinely in use.
// ═══════════════════════════════════════════════════════════════════════════════

namespace HeapTrimPolicy {

    /**
     * Below this RSS a trim is not worth the page faults the next allocations
     * pay to map memory back in. A clean launch sits near 213 MiB and ordinary
     * small inputs stay well under this, so routine editing never trims.
     */
    public const int64 RSS_TRIGGER_BYTES = 1024L * 1024L * 1024L;

    /**
     * Decide whether returning free heap pages to the kernel is worthwhile.
     *
     * @param rss_bytes      current resident set size, or -1 when unknown
     * @param released_media true when media was torn down for a previous input
     */
    public bool should_trim (int64 rss_bytes, bool released_media) {
        // Nothing was released, so there is nothing to hand back.
        if (!released_media) return false;

        // An unreadable RSS is "unknown", not "small" — do not guess.
        if (rss_bytes < 0) return false;

        return rss_bytes >= RSS_TRIGGER_BYTES;
    }

    /**
     * Extract VmRSS from /proc/<pid>/status content, in bytes.
     *
     * Returns -1 when the field is absent or malformed. Callers must treat that
     * as unknown rather than as zero.
     */
    public int64 parse_vmrss_bytes (string status_text) {
        foreach (unowned string raw in status_text.split ("\n")) {
            string line = raw.strip ();
            if (!line.has_prefix ("VmRSS:")) continue;

            string value = line.substring ("VmRSS:".length).strip ();

            // The kernel always reports this field in kB; anything else means
            // the format changed and our arithmetic would be wrong.
            if (!value.has_suffix ("kB")) return -1;

            value = value.substring (0, value.length - 2).strip ();
            if (value.length == 0) return -1;

            int64 kib;
            if (!int64.try_parse (value, out kib, null, 10)) return -1;
            if (kib < 0) return -1;

            return kib * 1024;
        }

        return -1;
    }
}

namespace HeapTrim {

    [CCode (cheader_filename = "malloc.h", cname = "malloc_trim")]
    private extern int malloc_trim (size_t pad);

    /**
     * Wait for player teardown to finish and for the next input's initial
     * load to settle, so the trim does not race allocations it would only have
     * to fault straight back in.
     */
    private const uint SETTLE_DELAY_MS = 3000;

    private uint pending_source = 0;
    private bool pending_released_media = false;
    private bool trim_in_flight = false;

    /**
     * Ask for a heap trim once things settle.
     *
     * Repeated calls coalesce into one trim, so typing a path into the input
     * entry schedules a single trim rather than one per keystroke.
     *
     * Main thread only.
     */
    public void request (bool released_media) {
        if (released_media) pending_released_media = true;

        // Nothing has been released yet — the very first file loaded into a
        // fresh window — so there is no reason to arm a timer at all.
        if (!pending_released_media) return;

        if (pending_source != 0) {
            Source.remove (pending_source);
        }

        pending_source = Timeout.add (SETTLE_DELAY_MS, () => {
            pending_source = 0;
            pending_released_media = false;
            run_if_worthwhile ();
            return Source.REMOVE;
        });
    }

    /** Current resident set size in bytes, or -1 when it cannot be read. */
    public int64 current_rss_bytes () {
        string contents;
        try {
            FileUtils.get_contents ("/proc/self/status", out contents);
        } catch (FileError e) {
            return -1;
        }
        return HeapTrimPolicy.parse_vmrss_bytes (contents);
    }

    private void run_if_worthwhile () {
        int64 before = current_rss_bytes ();

        if (!HeapTrimPolicy.should_trim (before, true)) {
            debug ("HeapTrim: declined, RSS %s MiB is below the %s MiB trigger",
                   (before / (1024 * 1024)).to_string (),
                   (HeapTrimPolicy.RSS_TRIGGER_BYTES / (1024 * 1024)).to_string ());
            return;
        }

        // A previous trim is still walking the arenas; a second one would only
        // contend for the same locks.
        if (trim_in_flight) return;
        trim_in_flight = true;

        // malloc_trim madvises every free page range it finds, which costs
        // roughly 55 ms per GiB reclaimed — around two seconds for the 36 GiB
        // case this exists to solve. That would visibly freeze the UI, so it
        // runs off the main loop. It is thread-safe; the main thread blocks
        // only if it happens to allocate from an arena the trim currently
        // holds, rather than for the whole walk.
        new Thread<void> ("heap-trim", () => {
            int64 started = get_monotonic_time ();
            malloc_trim (0);
            int64 elapsed_ms = (get_monotonic_time () - started) / 1000;
            int64 after = current_rss_bytes ();

            Idle.add (() => {
                trim_in_flight = false;
                debug ("HeapTrim: RSS %s MiB -> %s MiB in %s ms",
                       (before / (1024 * 1024)).to_string (),
                       (after / (1024 * 1024)).to_string (),
                       elapsed_ms.to_string ());
                return Source.REMOVE;
            });
        });
    }
}
