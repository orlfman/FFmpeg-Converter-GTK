using GLib;

/** A stable presentation object: controller fields are copied only on updates. */
public class BulkPlaybackEntry : Object {
    public BulkItem item;
    public string path;
    public string state = "";
    public string status = "";
    public string output_path = "";
    public string video_path = "";
    public string input_search = "";
    public string output_search = "";
    public bool input_available = true;
    public bool output_available = true;
    public signal void changed ();

    public BulkPlaybackEntry (BulkItem item) {
        this.item = item;
        path = item.path;
        refresh ();
    }
    public bool eligible (bool output) {
        return output ? state == "completed" && video_path.length > 0 && output_available
                      : path.length > 0 && input_available;
    }
    public string target (bool output) { return output ? video_path : path; }
    public void refresh () {
        string next_video = item.state == "completed" && item.result != null
            ? item.result.primary_file_path : "";
        if (next_video != video_path) output_available = true;
        state = item.state;
        status = item.status;
        output_path = item.output_path;
        video_path = next_video;
        input_search = Path.get_basename (path).casefold ();
        output_search = input_search + "\n" + Path.get_basename (video_path).casefold ();
        changed ();
    }
}

/** GTK-thread batch model. No filesystem work is done by filters or row binds. */
public class BulkPlaybackModel : Object {
    public ListStore entries { get; private set; }
    public uint generation { get; private set; default = 0; }
    public uint completed { get; private set; default = 0; }
    public uint ready { get; private set; default = 0; }
    public uint failed { get; private set; default = 0; }
    public uint inputs { get; private set; default = 0; }
    public uint outputs { get; private set; default = 0; }
    public signal void changed ();
    public signal void reset ();
    private HashTable<BulkItem, BulkPlaybackEntry> by_item = new HashTable<BulkItem, BulkPlaybackEntry> (direct_hash, direct_equal);
    private Cancellable batch_cancel = new Cancellable ();
    private uint notify_idle = 0;

    public BulkPlaybackModel () { entries = new ListStore (typeof (BulkPlaybackEntry)); }
    private void count (BulkPlaybackEntry entry, bool add) {
        if (entry.state == "completed") completed = add ? completed + 1 : completed - 1;
        if (entry.state == "ready") ready = add ? ready + 1 : ready - 1;
        if (entry.state == "failed") failed = add ? failed + 1 : failed - 1;
        if (entry.eligible (false)) inputs = add ? inputs + 1 : inputs - 1;
        if (entry.eligible (true)) outputs = add ? outputs + 1 : outputs - 1;
    }
    private void schedule_changed () {
        if (notify_idle != 0) return;
        notify_idle = Idle.add (() => { notify_idle = 0; changed (); return Source.REMOVE; });
    }
    public void replace (GenericArray<BulkItem> items) {
        generation++;
        batch_cancel.cancel ();
        batch_cancel = new Cancellable ();
        reset ();
        by_item.remove_all ();
        completed = ready = failed = inputs = outputs = 0;
        Object[] additions = new Object[items.length];
        for (int i = 0; i < items.length; i++) {
            var entry = new BulkPlaybackEntry (items[i]);
            by_item.insert (items[i], entry);
            count (entry, true);
            additions[i] = entry;
        }
        entries.splice (0, entries.get_n_items (), additions);
        schedule_changed ();
    }
    public void update (BulkItem item) {
        var entry = by_item.lookup (item);
        if (entry == null) return;
        count (entry, false);
        entry.refresh ();
        count (entry, true);
        schedule_changed ();
    }
    public void clear () { replace (new GenericArray<BulkItem> ()); }
    public void shutdown () {
        clear ();
        batch_cancel.cancel ();
        if (notify_idle != 0) { Source.remove (notify_idle); notify_idle = 0; }
    }
    private bool rechecking = false;
    /**
     * Give rows that failed a file check another chance. A failed check marks
     * the row unavailable so it leaves the playback lists, but the cause is
     * often temporary (network or removable storage, a file moved back), and
     * nothing else would ever look again short of a Rescan. Only unavailable
     * rows are examined, asynchronously; callers invoke this at natural
     * moments such as the window regaining focus or the dialog opening.
     */
    public async void recheck_unavailable () {
        if (rechecking) return;
        rechecking = true;
        uint version = generation;
        var batch = batch_cancel;
        BulkPlaybackEntry[] pending = {};
        for (uint i = 0; i < entries.get_n_items (); i++) {
            var entry = (BulkPlaybackEntry) entries.get_item (i);
            if (!entry.input_available || !entry.output_available) pending += entry;
        }
        foreach (var entry in pending) {
            foreach (bool output in new bool[] { false, true }) {
                if (output ? entry.output_available : entry.input_available) continue;
                string path = entry.target (output);
                if (path.length == 0) continue;
                bool regular = false;
                try {
                    var info = yield File.new_for_path (path).query_info_async (
                        FileAttribute.STANDARD_TYPE, FileQueryInfoFlags.NONE, Priority.DEFAULT, batch);
                    regular = info.get_file_type () == FileType.REGULAR;
                } catch (Error e) {
                    // Still unavailable, or the batch went away.
                }
                if (batch.is_cancelled () || version != generation) { rechecking = false; return; }
                if (!regular || by_item.lookup (entry.item) != entry || path != entry.target (output))
                    continue;
                count (entry, false);
                if (output) entry.output_available = true; else entry.input_available = true;
                count (entry, true);
                entry.changed ();
                schedule_changed ();
            }
        }
        rechecking = false;
    }
    public async void play (BulkPlaybackEntry entry, bool output, Cancellable? request = null) throws Error {
        uint version = generation;
        if (by_item.lookup (entry.item) != entry || !entry.eligible (output))
            throw new IOError.NOT_FOUND ("This video is no longer available in the batch.");
        string path = entry.target (output);
        var token = new Cancellable ();
        var batch = batch_cancel;
        ulong batch_handler = batch.cancelled.connect (() => { token.cancel (); });
        ulong request_handler = request == null ? 0 : request.cancelled.connect (() => { token.cancel (); });
        if (batch.is_cancelled () || (request != null && request.is_cancelled ())) token.cancel ();
        try {
            var info = yield File.new_for_path (path).query_info_async (
                FileAttribute.STANDARD_TYPE, FileQueryInfoFlags.NONE, Priority.DEFAULT, token);
            if (token.is_cancelled () || version != generation) throw new IOError.CANCELLED ("Playback cancelled");
            if (by_item.lookup (entry.item) != entry || !entry.eligible (output) || path != entry.target (output))
                throw new IOError.CANCELLED ("Playback selection changed");
            if (info.get_file_type () != FileType.REGULAR)
                throw new IOError.NOT_REGULAR_FILE ("The selected video is no longer a regular file.");
        } catch (Error e) {
            if (token.is_cancelled () || version != generation)
                throw new IOError.CANCELLED ("Playback selection changed");
            if (!(e is IOError.CANCELLED) && version == generation) {
                count (entry, false);
                if (output) entry.output_available = false; else entry.input_available = false;
                count (entry, true);
                entry.changed ();
                schedule_changed ();
            }
            throw e;
        } finally {
            batch.disconnect (batch_handler);
            if (request != null && request_handler != 0) request.disconnect (request_handler);
        }
        // No yield between final generation/eligibility check and process handoff.
        PlaybackLauncher.launch (path);
    }
}
