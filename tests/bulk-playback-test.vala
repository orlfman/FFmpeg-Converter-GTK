using GLib;

private string root;
private bool gtk_available;
private string launched;
private int launches = 0;

private bool pump (owned SourceFunc predicate, int ms = 4000) {
    int64 deadline = get_monotonic_time () + ms * TimeSpan.MILLISECOND;
    do {
        while (MainContext.default ().pending ()) MainContext.default ().iteration (false);
        if (predicate ()) return true;
        Thread.usleep (1000);
    } while (get_monotonic_time () < deadline);
    return predicate ();
}
private string fixture (string name) {
    string path = Path.build_filename (root, name);
    try { FileUtils.set_contents (path, "fixture"); } catch (Error e) { error ("%s", e.message); }
    return path;
}
private GenericArray<BulkItem> items (uint count) {
    var result = new GenericArray<BulkItem> ();
    for (uint i = 0; i < count; i++) result.add (new BulkItem (Path.build_filename (root, "video-%04u.mkv".printf (i))));
    return result;
}
private void complete (BulkItem item, string path) {
    item.state = "completed";
    item.status = "Completed";
    item.output_path = path;
    item.result = new OperationOutputResult.for_multiple_files ({path, path + ".jpg"}, root, path);
}
private bool play (BulkPlaybackModel model, BulkPlaybackEntry entry, bool output,
                   Cancellable? cancel = null) {
    bool done = false, success = false;
    model.play.begin (entry, output, cancel, (source, result) => {
        try { model.play.end (result); success = true; } catch (Error e) { }
        done = true;
    });
    assert (pump (() => done));
    return success;
}
private void test_model () {
    var model = new BulkPlaybackModel ();
    var batch = new GenericArray<BulkItem> ();
    string input = fixture ("-café 'input'; [1].mkv");
    string output = fixture ("collision (2).mkv");
    batch.add (new BulkItem (input));
    batch[0].output_path = output; // Old colliding file does not prove completion.
    model.replace (batch);
    var entry = (BulkPlaybackEntry) model.entries.get_item (0);
    assert (model.inputs == 1 && model.outputs == 0);
    assert (!play (model, entry, true));
    assert (play (model, entry, false));
    assert (launched == input);
    complete (batch[0], output);
    model.update (batch[0]);
    assert (model.entries.get_item (0) == entry);
    assert (model.completed == 1 && model.outputs == 1);
    assert (play (model, entry, true));
    assert (launched == output); // Never collage path.
    batch[0].state = "failed";
    model.update (batch[0]);
    assert (model.completed == 0 && model.failed == 1 && model.outputs == 0);
    assert (!play (model, entry, true));
    complete (batch[0], output);
    model.update (batch[0]);
    var cancelled = new Cancellable (); cancelled.cancel ();
    assert (!play (model, entry, true, cancelled));
    int before = launches;
    bool done = false;
    model.play.begin (entry, true, null, (s, r) => {
        try { model.play.end (r); assert_not_reached (); } catch (Error e) { assert (e is IOError.CANCELLED); }
        done = true;
    });
    model.clear ();
    assert (pump (() => done));
    assert (launches == before);
    model.replace (batch);
    entry = (BulkPlaybackEntry) model.entries.get_item (0);
    FileUtils.remove (output);
    assert (!play (model, entry, true));
    assert (!entry.eligible (true) && model.outputs == 0);
    assert (entry.eligible (false));
    // A file that comes back becomes playable again without a Rescan.
    bool rechecked = false;
    model.recheck_unavailable.begin ((s, r) => { model.recheck_unavailable.end (r); rechecked = true; });
    assert (pump (() => rechecked));
    assert (!entry.eligible (true) && model.outputs == 0); // Still missing.
    fixture ("collision (2).mkv");
    rechecked = false;
    model.recheck_unavailable.begin ((s, r) => { model.recheck_unavailable.end (r); rechecked = true; });
    assert (pump (() => rechecked));
    assert (entry.eligible (true) && model.outputs == 1 && model.inputs == 1);
    assert (play (model, entry, true) && launched == output);
    // A symlink to a regular input remains playable; a directory does not.
    string link = Path.build_filename (root, "linked.mkv");
    assert (Posix.symlink (input, link) == 0);
    batch = new GenericArray<BulkItem> (); batch.add (new BulkItem (link));
    model.replace (batch);
    assert (play (model, (BulkPlaybackEntry) model.entries.get_item (0), false));
    batch = new GenericArray<BulkItem> (); batch.add (new BulkItem (root));
    model.replace (batch);
    assert (!play (model, (BulkPlaybackEntry) model.entries.get_item (0), false));
    model.shutdown ();
}
private bool require_display () {
    if (gtk_available) return true;
    Test.skip ("GTK display unavailable"); return false;
}
private void snapshot_for_test (Gtk.Window window, string name) {
    string? directory = Environment.get_variable ("FFGTK_PLAYBACK_SCREENSHOT_DIR");
    if (directory == null) return;
    var paintable = new Gtk.WidgetPaintable (window);
    var snapshot = new Gtk.Snapshot ();
    paintable.snapshot (snapshot, window.get_width (), window.get_height ());
    var node = snapshot.to_node ();
    assert (node != null);
    var texture = window.get_native ().get_renderer ().render_texture (node, null);
    assert (texture.save_to_png (Path.build_filename (directory, name)));
}
private void test_dialog () {
    if (!require_display ()) return;
    var window = new Adw.Window ();
    window.set_default_size (800, 650);
    window.present ();
    var model = new BulkPlaybackModel ();
    var batch = items (200);
    model.replace (batch);
    var dialog = new BulkPlaybackDialog (model, false);
    dialog.present (window);
    assert (pump (() => dialog.get_mapped ()));
    assert (dialog.matches_for_test () == 200);
    assert (dialog.get_height () <= 650);
    dialog.select_for_test (150);
    var selected = dialog.selected_for_test ();
    dialog.scroll_for_test (400);
    pump (() => false, 60);
    double scroll_before = dialog.scroll_value_for_test ();
    assert (scroll_before > 0);
    snapshot_for_test (window, "dialog-200.png");
    uint created_before = BulkPlaybackRow.created;
    batch[0].status = "Checking";
    model.update (batch[0]);
    pump (() => false, 40);
    assert (dialog.selected_for_test () == selected);
    assert (dialog.scroll_value_for_test () == scroll_before);
    assert (BulkPlaybackRow.created == created_before);
    int64 start = get_monotonic_time ();
    dialog.search_for_test ("video-0199");
    assert (pump (() => dialog.matches_for_test () == 1));
    double elapsed = (get_monotonic_time () - start) / 1000.0;
    Test.message ("200-entry search: %.3f ms", elapsed);
    assert (dialog.selected_for_test () == null);
    // Enter in the search field plays the top match when nothing is selected.
    fixture ("video-0199.mkv");
    int enter_before = launches;
    dialog.search_activate_for_test ();
    assert (pump (() => launches == enter_before + 1));
    assert (launched == batch[199].path);
    dialog.search_for_test ("does not exist"); assert (pump (() => dialog.matches_for_test () == 0));
    dialog.search_activate_for_test (); // No match: nothing to play.
    pump (() => false, 40);
    assert (launches == enter_before + 1);
    dialog.search_for_test (""); assert (pump (() => dialog.matches_for_test () == 200));
    window.set_default_size (420, 500);
    pump (() => false, 150);
    assert (dialog.get_width () <= window.get_width ());
    snapshot_for_test (window, "dialog-narrow.png");
    window.set_default_size (800, 650);
    dialog.stop (); dialog.force_close ();
    complete (batch[0], fixture ("Café output (2).mkv")); model.update (batch[0]);
    var outputs = new BulkPlaybackDialog (model, true);
    outputs.present (window);
    assert (pump (() => outputs.get_mapped ()));
    outputs.search_for_test ("CAFÉ"); pump (() => false, 80); assert (outputs.matches_for_test () == 1);
    outputs.select_for_test (0);
    selected = outputs.selected_for_test ();
    complete (batch[1], fixture ("Café output (3).mkv")); model.update (batch[1]);
    assert (pump (() => outputs.matches_for_test () == 2));
    assert (outputs.selected_for_test () == selected);
    assert (outputs.count_for_test ().contains ("2 matches"));
    int before = launches;
    outputs.play_for_test ();
    assert (pump (() => launches == before + 1));
    assert (launched == batch[0].result.primary_file_path);
    FileUtils.remove (batch[0].result.primary_file_path);
    outputs.play_for_test ();
    assert (pump (() => outputs.error_for_test ()));
    assert (launches == before + 1);
    outputs.select_for_test (0); // Remaining eligible output after refilter.
    outputs.play_for_test ();
    outputs.close (); // Real close-attempt path must cancel before animation.
    pump (() => false, 60);
    assert (launches == before + 1); // Close cancels outstanding metadata lookup.
    batch = items (1000); model.replace (batch);
    uint creation_start = BulkPlaybackRow.created;
    dialog = new BulkPlaybackDialog (model, false); dialog.present (window);
    assert (pump (() => dialog.get_mapped ()));
    pump (() => false, 80);
    uint created = BulkPlaybackRow.created - creation_start;
    Test.message ("1000-entry dialog created %u rows", created);
    assert (created < 500); // GTK keeps a bounded overscan pool, not one widget per item.
    dialog.search_for_test ("video-0999"); assert (pump (() => dialog.matches_for_test () == 1));
    model.clear ();
    assert (pump (() => !dialog.get_mapped ()));
    // Repeated open/close must release the dialog and its model subscriptions.
    for (int i = 0; i < 4; i++) {
        BulkPlaybackDialog? transient = new BulkPlaybackDialog (model, false);
        var weak_dialog = WeakRef (transient);
        transient.present (window);
        pump (() => false, 30);
        if (i % 2 == 0) transient.close (); else transient.escape_for_test ();
        transient = null;
        assert (pump (() => weak_dialog.get () == null));
    }
    model.shutdown ();
    window.destroy ();
}
private void test_row () {
    if (!require_display ()) return;
    var row = new BulkPlaybackRow (true);
    var first = new BulkPlaybackEntry (new BulkItem ("/first.mkv"));
    var second = new BulkPlaybackEntry (new BulkItem ("/second.mkv"));
    int clicks = 0;
    row.play_requested.connect ((entry, output) => { assert (entry == second && !output); clicks++; });
    for (int i = 0; i < 100; i++) { row.bind_entry (first); row.bind_entry (null); row.bind_entry (second); }
    first.status = "Old row changed"; first.changed ();
    row.click_for_test (false);
    assert (clicks == 1);
    row.bind_entry (null);
    row.click_for_test (false);
    assert (clicks == 1);
}
private void test_window () {
    if (!require_display ()) return;
    try {
        var app = new Adw.Application ("com.github.pieman.BulkPlaybackTest", ApplicationFlags.NON_UNIQUE);
        app.register (null);
        var window = new MainWindow (app);
        window.present ();
        assert (pump (() => window.get_mapped ()));
        string folder = Path.build_filename (root, "batch");
        DirUtils.create (folder, 0700);
        string input = Path.build_filename (folder, "source.mkv"); FileUtils.set_contents (input, "fixture");
        var picks = window.playback_pickers_for_test ();
        var model = window.playback_model_for_test ();
        picks.request_input (folder);
        assert (pump (() => picks.kind == InputSourceKind.FOLDER && model.inputs == 1));
        assert (window.playback_bulk_visible_for_test () && !window.playback_trim_sensitive_for_test ());
        var view_input = app.lookup_action ("view-input") as SimpleAction;
        var view_output = app.lookup_action ("view-output") as SimpleAction;
        assert (pump (() => view_input.enabled));
        assert (!view_output.enabled);
        view_input.activate (null);
        var dialog = window.playback_dialog_for_test ();
        assert (dialog != null);
        dialog.select_for_test (0);
        int before = launches; dialog.play_for_test ();
        assert (pump (() => launches == before + 1));
        assert (launched == input && picks.source_path == folder);
        assert (picks.kind == InputSourceKind.FOLDER && !window.playback_trim_sensitive_for_test ());
        view_input.activate (null); assert (window.playback_dialog_for_test () == dialog);
        // Use authoritative completed-item state without running an encoder in this UI test.
        var batch = new GenericArray<BulkItem> (); batch.add (new BulkItem (input));
        complete (batch[0], fixture ("window output.mkv"));
        window.playback_items_for_test (batch);
        assert (pump (() => view_output.enabled && window.playback_dialog_for_test () == null));
        picks.set_operation_locked (true); // Playback is independent of input admission.
        view_output.activate (null);
        dialog = window.playback_dialog_for_test (); assert (dialog != null && dialog.is_output ());
        dialog.select_for_test (0); dialog.play_for_test ();
        assert (pump (() => launches == before + 2));
        assert (launched == batch[0].result.primary_file_path && picks.source_path == folder);
        dialog.play_for_test ();
        window.playback_items_for_test (new GenericArray<BulkItem> ());
        pump (() => false, 80);
        assert (launches == before + 2 && !view_output.enabled);
        picks.set_operation_locked (false);
        uint rows_before = BulkPlaybackRow.created;
        var large = items (1000);
        window.playback_items_for_test (large);
        pump (() => false, 80);
        uint main_rows = BulkPlaybackRow.created - rows_before;
        Test.message ("1000-entry MainWindow list created %u rows", main_rows);
        assert (main_rows < 500);
        snapshot_for_test (window, "main-1000.png");
        uint before_update = BulkPlaybackRow.created;
        large[950].status = "Converting"; large[950].state = "converting";
        model.update (large[950]);
        pump (() => false, 40);
        assert (BulkPlaybackRow.created == before_update);
        picks.request_input (input);
        assert (pump (() => picks.kind == InputSourceKind.FILE));
        assert (!window.playback_bulk_visible_for_test () && window.playback_trim_sensitive_for_test ());
        view_input.activate (null); assert (launched == input);
        window.close ();
        pump (() => false, 80);
    } catch (Error e) { error ("%s", e.message); }
}
private void test_real_queue () {
    if (!require_display ()) return;
    string? ffmpeg = Environment.find_program_in_path ("ffmpeg");
    if (ffmpeg == null) { Test.skip ("FFmpeg not installed"); return; }
    try {
        string folder = Path.build_filename (root, "real-batch");
        DirUtils.create (folder, 0700);
        string first = Path.build_filename (folder, "01 source.mkv");
        string second = Path.build_filename (folder, "02 source.mkv");
        int status; string out_text, err_text;
        Process.spawn_sync (null, {ffmpeg, "-v", "error", "-f", "lavfi", "-i",
            "color=c=blue:s=160x90:r=10:d=0.3", "-c:v", "mpeg4", first}, null,
            SpawnFlags.SEARCH_PATH, null, out out_text, out err_text, out status);
        assert (status == 0);
        File.new_for_path (first).copy (File.new_for_path (second), FileCopyFlags.NONE);
        var app = new Adw.Application ("com.github.pieman.BulkPlaybackQueueTest", ApplicationFlags.NON_UNIQUE);
        app.register (null);
        var window = new MainWindow (app); window.present ();
        var picks = window.playback_pickers_for_test ();
        var model = window.playback_model_for_test ();
        var controller = window.playback_controller_for_test ();
        picks.request_input (folder);
        assert (pump (() => picks.kind == InputSourceKind.FOLDER && model.inputs == 2));
        bool finished = false;
        bool cancel_after_first = true;
        controller.item_changed.connect ((item) => {
            if (cancel_after_first && item.state == "completed") controller.cancel ();
        });
        controller.finished.connect (() => { finished = true; });
        window.playback_convert_for_test ();
        assert (pump (() => finished, 30000));
        assert (model.completed == 1 && model.outputs == 1 && model.inputs == 2);
        assert (controller.items[0].state == "completed");
        assert (controller.items[1].state != "completed");
        var output_action = app.lookup_action ("view-output") as SimpleAction;
        assert (pump (() => output_action.enabled));
        output_action.activate (null);
        var dialog = window.playback_dialog_for_test (); assert (dialog != null);
        assert (dialog.matches_for_test () == 1);
        dialog.select_for_test (0);
        int before = launches; dialog.play_for_test ();
        assert (pump (() => launches == before + 1));
        assert (launched == controller.items[0].result.primary_file_path);
        assert (FileUtils.test (launched, FileTest.IS_REGULAR));
        assert (picks.source_path == folder && picks.kind == InputSourceKind.FOLDER);
        Test.message ("Real x264 bulk conversion published one video; cancellation retained its playable output and stopped the next item");
        // Editing the output field and restoring it replaces the list with a
        // folder preview while the controller keeps its queue. The next run
        // reuses that queue and the list must follow it again.
        picks.output_entry.set_text ("x");
        pump (() => false, 200);
        picks.output_entry.set_text ("");
        assert (pump (() => model.entries.get_n_items () == 2 && model.completed == 0));
        cancel_after_first = false;
        finished = false;
        window.playback_convert_for_test ();
        assert (pump (() => finished, 30000));
        assert (controller.items[0].state == "completed" && controller.items[1].state == "completed");
        assert (pump (() => model.completed == 2 && model.outputs == 2));
        assert (((BulkPlaybackEntry) model.entries.get_item (1)).item == controller.items[1]);
        assert (pump (() => output_action.enabled));
        window.close ();
        pump (() => false, 60);
    } catch (Error e) { error ("%s", e.message); }
}

private void test_launcher_handoff () {
    if (!require_display ()) return;
    string? ffmpeg = Environment.find_program_in_path ("ffmpeg");
    string? ffplay = Environment.find_program_in_path ("ffplay");
    if (ffmpeg == null || ffplay == null) { Test.skip ("FFmpeg/ffplay not installed"); return; }
    try {
        string video = Path.build_filename (root, "real sample.mkv");
        int status;
        string stdout_text, stderr_text;
        Process.spawn_sync (null, {ffmpeg, "-v", "error", "-f", "lavfi", "-i",
            "color=c=blue:s=160x90:r=10:d=0.3", "-c:v", "mpeg4", video}, null,
            SpawnFlags.SEARCH_PATH, null, out stdout_text, out stderr_text, out status);
        assert (status == 0);
        string marker = Path.build_filename (root, "player-finished");
        string wrapper = Path.build_filename (root, "ffplay-wrapper");
        FileUtils.set_contents (wrapper, "#!/bin/sh\n" + Shell.quote (ffplay)
            + " \"$@\"\nresult=$?\nprintf '%s' \"$result\" > " + Shell.quote (marker) + "\nexit \"$result\"\n");
        Posix.chmod (wrapper, 0700);
        var settings = AppSettings.get_default ();
        settings.play_with_ffplay = true;
        settings.ffplay_path = wrapper;
        PlaybackLauncher.test_launch = null;
        PlaybackLauncher.launch (video);
        assert (pump (() => FileUtils.test (marker, FileTest.IS_REGULAR), 10000));
        string exit_text; FileUtils.get_contents (marker, out exit_text);
        assert (exit_text == "0");
        // Register a fake desktop player only in this test's isolated XDG roots.
        string desktop_marker = Path.build_filename (root, "desktop-uri");
        string desktop_player = Path.build_filename (root, "desktop-player");
        FileUtils.set_contents (desktop_player, "#!/bin/sh\nprintf '%s' \"$1\" > " + Shell.quote (desktop_marker) + "\n");
        Posix.chmod (desktop_player, 0700);
        var handler = AppInfo.create_from_commandline (Shell.quote (desktop_player),
            "Bulk Playback Test", AppInfoCreateFlags.SUPPORTS_URIS);
        assert (handler.set_as_default_for_type ("video/x-matroska"));
        foreach (string binary in new string[] { "ffgtk-deliberately-missing-player", "/nonexistent/ffgtk-player" }) {
            FileUtils.remove (desktop_marker);
            settings.ffplay_path = binary;
            // The fallback must say why it happened, not switch players silently.
            Test.expect_message (null, LogLevelFlags.LEVEL_WARNING, "*falling back to the default player*");
            PlaybackLauncher.launch (video);
            Test.assert_expected_messages ();
            assert (pump (() => FileUtils.test (desktop_marker, FileTest.IS_REGULAR)));
            string uri; FileUtils.get_contents (desktop_marker, out uri);
            assert (File.new_for_commandline_arg (uri).equal (File.new_for_path (video)));
        }
        settings.play_with_ffplay = false;
        FileUtils.remove (desktop_marker);
        PlaybackLauncher.launch (video);
        assert (pump (() => FileUtils.test (desktop_marker, FileTest.IS_REGULAR)));
        Test.message ("Real ffplay completed synthetic video; desktop preference and missing/failed ffplay fallbacks passed");
        settings.ffplay_path = "ffplay";
        handler.delete ();
        PlaybackLauncher.test_launch = (path) => { launched = path; launches++; };
    } catch (Error e) { error ("%s", e.message); }
}

private void remove_tree (File file) throws Error {
    if (file.query_file_type (FileQueryInfoFlags.NOFOLLOW_SYMLINKS) == FileType.DIRECTORY) {
        var children = file.enumerate_children (FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        FileInfo? child;
        while ((child = children.next_file ()) != null) remove_tree (file.get_child (child.get_name ()));
        children.close ();
    }
    file.delete ();
}
int main (string[] args) {
    Test.init (ref args);
    launched = "";
    try {
        root = DirUtils.make_tmp ("ffgtk-bulk-playback-XXXXXX");
        foreach (string name in new string[] { "config", "cache", "tmp", "data" }) DirUtils.create (Path.build_filename (root, name), 0700);
        Environment.set_variable ("XDG_CONFIG_HOME", Path.build_filename (root, "config"), true);
        Environment.set_variable ("XDG_CACHE_HOME", Path.build_filename (root, "cache"), true);
        Environment.set_variable ("XDG_DATA_HOME", Path.build_filename (root, "data"), true);
        Environment.set_variable ("TMPDIR", Path.build_filename (root, "tmp"), true);
        gtk_available = Gtk.init_check ();
        if (gtk_available) Adw.init ();
        PlaybackLauncher.test_launch = (path) => { launched = path; launches++; };
        Test.add_func ("/bulk-playback/model/eligibility-and-cancellation", test_model);
        Test.add_func ("/bulk-playback/widgets/search-live-update-and-scale", test_dialog);
        Test.add_func ("/bulk-playback/widgets/recycled-row-target", test_row);
        Test.add_func ("/bulk-playback/window/folder-playback-and-reset", test_window);
        Test.add_func ("/bulk-playback/window/real-conversion-cancellation", test_real_queue);
        Test.add_func ("/bulk-playback/launcher/real-player-and-fallback", test_launcher_handoff);
        int result = Test.run ();
        PlaybackLauncher.test_launch = null;
        remove_tree (File.new_for_path (root));
        return result;
    } catch (Error e) { stderr.printf ("%s\n", e.message); return 1; }
}
