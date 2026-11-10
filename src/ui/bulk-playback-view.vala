using Gtk;
using GLib;

/** Recycled by ListView; callbacks always read the currently bound entry. */
public class BulkPlaybackRow : Box {
    private Label name_label = new Label ("");
    private Label detail = new Label ("");
    private Label output_label = new Label ("");
    private Button input_button = new Button ();
    private Button output_button = new Button ();
    private BulkPlaybackEntry? entry;
    private ulong entry_handler = 0;
    private bool output_mode;
    public signal void play_requested (BulkPlaybackEntry entry, bool output);
#if BULK_PLAYBACK_TEST_BUILD
    internal static uint created = 0;
    internal void click_for_test (bool output) { if (output) output_button.clicked (); else input_button.clicked (); }
#endif
    public BulkPlaybackRow (bool buttons, bool output_mode = false) {
        Object (orientation: Orientation.HORIZONTAL, spacing: 8);
#if BULK_PLAYBACK_TEST_BUILD
        created++;
#endif
        this.output_mode = output_mode;
        margin_top = margin_bottom = 6;
        margin_start = margin_end = 12;
        var text = new Box (Orientation.VERTICAL, 2);
        text.hexpand = true;
        foreach (var label in new Label[] { name_label, detail, output_label }) {
            label.xalign = 0;
            label.ellipsize = Pango.EllipsizeMode.MIDDLE;
            text.append (label);
        }
        // Status text carries failure reasons; wrap it so they can be read
        // in place rather than only in a tooltip.
        detail.ellipsize = Pango.EllipsizeMode.NONE;
        detail.wrap = true;
        detail.wrap_mode = Pango.WrapMode.WORD_CHAR;
        detail.add_css_class ("dim-label");
        output_label.add_css_class ("dim-label");
        append (text);
        // Labelled, not icon-only: two unlabelled icons did not say which
        // button plays the source and which the converted file.
        var input_content = new Adw.ButtonContent ();
        input_content.icon_name = "media-playback-start-symbolic";
        input_content.label = "Input";
        input_button.child = input_content;
        var output_content = new Adw.ButtonContent ();
        output_content.icon_name = "media-playback-start-symbolic";
        output_content.label = "Output";
        output_button.child = output_content;
        input_button.tooltip_text = "Play Input";
        output_button.tooltip_text = "Play Output";
        input_button.update_property (AccessibleProperty.LABEL, "Play Input", -1);
        output_button.update_property (AccessibleProperty.LABEL, "Play Output", -1);
        input_button.valign = output_button.valign = Align.CENTER;
        input_button.visible = output_button.visible = buttons;
        append (input_button);
        append (output_button);
        input_button.clicked.connect (() => { if (entry != null) play_requested (entry, false); });
        output_button.clicked.connect (() => { if (entry != null) play_requested (entry, true); });
    }
    public void bind_entry (BulkPlaybackEntry? next) {
        if (entry != null && entry_handler != 0) entry.disconnect (entry_handler);
        entry_handler = 0;
        entry = next;
        if (entry != null) {
            entry_handler = entry.changed.connect (refresh);
            refresh ();
        }
    }
    private void refresh () {
        if (entry == null) return;
        name_label.label = Path.get_basename (output_mode ? entry.video_path : entry.path);
        name_label.tooltip_text = output_mode ? entry.video_path : entry.path;
        detail.label = entry.status;
        detail.tooltip_text = entry.status;
        output_label.label = output_mode ? "Source: " + entry.path : "Output: " + entry.output_path;
        output_label.tooltip_text = output_mode ? entry.path : entry.output_path;
        output_label.visible = output_mode || entry.output_path.length > 0;
        input_button.sensitive = entry.eligible (false);
        output_button.sensitive = entry.eligible (true);
    }
    public static SignalListItemFactory factory (bool buttons, bool output, BulkPlaybackModel model,
                                                owned PlaybackErrorFunc? report_error = null) {
        var factory = new SignalListItemFactory ();
        factory.setup.connect ((obj) => {
            var item = (ListItem) obj;
            var row = new BulkPlaybackRow (buttons, output);
            row.play_requested.connect ((entry, is_output) => {
                model.play.begin (entry, is_output, null, (source, result) => {
                    try { model.play.end (result); }
                    catch (Error e) {
                        if (!(e is IOError.CANCELLED) && report_error != null) report_error (e.message);
                    }
                });
            });
            item.child = row;
        });
        factory.bind.connect ((obj) => {
            var item = (ListItem) obj;
            ((BulkPlaybackRow) item.child).bind_entry ((BulkPlaybackEntry) item.item);
        });
        factory.unbind.connect ((obj) => { ((BulkPlaybackRow) ((ListItem) obj).child).bind_entry (null); });
        return factory;
    }
}

public delegate void PlaybackErrorFunc (string message);

public class BulkPlaybackDialog : Adw.Dialog {
    public signal void dismissed (BulkPlaybackDialog dialog);
    private BulkPlaybackModel batch;
    private bool output;
    private SearchEntry search = new SearchEntry ();
    private Label count_label = new Label ("");
    private Label empty_label = new Label ("");
    private Label error_label = new Label ("");
    private Button play_button = new Button.with_label ("Play");
    private CustomFilter filter;
    private FilterListModel filtered;
    private SingleSelection selection;
    private ListView list;
    private ScrolledWindow scroll;
    private string query = "";
    private ulong changed_handler;
    private ulong reset_handler;
    private Cancellable request = new Cancellable ();
    private bool stopped = false;

    public BulkPlaybackDialog (BulkPlaybackModel batch, bool output) {
        this.batch = batch;
        this.output = output;
        title = output ? "Play Output Video" : "Play Input Video";
        content_width = 720;
        content_height = 520;
        var toolbar = new Adw.ToolbarView ();
        toolbar.add_top_bar (new Adw.HeaderBar ());
        var box = new Box (Orientation.VERTICAL, 8);
        box.margin_start = box.margin_end = 12;
        box.margin_bottom = 12;
        search.placeholder_text = "Search videos";
        search.set_search_delay (50);
        search.update_property (AccessibleProperty.LABEL, "Search videos", -1);
        box.append (search);
        filter = new CustomFilter ((obj) => {
            var entry = (BulkPlaybackEntry) obj;
            return entry.eligible (output) && (output ? entry.output_search : entry.input_search).contains (query);
        });
        filtered = new FilterListModel (batch.entries, filter);
        selection = new SingleSelection (filtered);
        selection.autoselect = false;
        selection.can_unselect = true;
        list = new ListView (selection, BulkPlaybackRow.factory (false, output, batch));
        list.add_css_class ("boxed-list");
        list.activate.connect ((position) => {
            selection.selected = position;
            play_selected ();
        });
        scroll = new ScrolledWindow ();
        scroll.set_policy (PolicyType.NEVER, PolicyType.AUTOMATIC);
        scroll.vexpand = true;
        scroll.child = list;
        box.append (scroll);
        box.append (empty_label);
        error_label.wrap = true;
        error_label.add_css_class ("error");
        error_label.visible = false;
        box.append (error_label);
        var footer = new Box (Orientation.HORIZONTAL, 12);
        count_label.hexpand = true;
        count_label.xalign = 0;
        count_label.wrap = true;
        footer.append (count_label);
        play_button.add_css_class ("suggested-action");
        footer.append (play_button);
        box.append (footer);
        toolbar.content = box;
        child = toolbar;
        focus_widget = search;
        search.search_changed.connect (() => {
            query = search.text.casefold ();
            refilter ();
        });
        search.activate.connect (() => {
            // Enter from the search field plays the top match when nothing
            // has been picked yet, as a search box is expected to.
            if (!stopped && selection.selected_item == null && filtered.get_n_items () > 0)
                selection.selected = 0;
            play_selected ();
        });
        selection.selection_changed.connect (() => { update_labels (); });
        play_button.clicked.connect (play_selected);
        changed_handler = batch.changed.connect (refilter);
        reset_handler = batch.reset.connect (() => { stop (); force_close (); });
        // Intercept a normal close before its animation, so an outstanding
        // metadata lookup cannot launch a player while the dialog is closing.
        can_close = false;
        close_attempt.connect (() => { stop (); force_close (); });
        search.stop_search.connect (() => { close (); });
        closed.connect (() => { stop (); dismissed (this); });
        update_labels ();
    }
    public bool is_output () { return output; }
    public void stop () {
        if (stopped) return;
        stopped = true;
        request.cancel ();
        batch.disconnect (changed_handler);
        batch.disconnect (reset_handler);
        // The custom filter owns its closure, which references this dialog.
        // Break that ownership cycle even when closing an empty list.
        filtered.set_model (null);
        filter.set_filter_func (null);
    }
    private void refilter () {
        if (stopped) return;
        var selected = selection.selected_item;
        filter.changed (FilterChange.DIFFERENT);
        if (selected != null) {
            for (uint i = 0; i < filtered.get_n_items (); i++) {
                if (filtered.get_item (i) == selected) { selection.selected = i; break; }
            }
        }
        update_labels ();
    }
    private void update_labels () {
        uint total = output ? batch.outputs : batch.inputs;
        uint matches = filtered.get_n_items ();
        string description = output ? "%u completed videos".printf (total) : "%u input videos".printf (total);
        count_label.label = query.length == 0 ? description : "%u matches · %s".printf (matches, description);
        count_label.update_property (AccessibleProperty.LABEL, count_label.label, -1);
        empty_label.label = query.length > 0 ? "No matching videos" : output ? "No completed videos yet" : "No available input videos";
        empty_label.visible = matches == 0;
        var entry = selection.selected_item as BulkPlaybackEntry;
        play_button.sensitive = entry != null && entry.eligible (output);
    }
    private void play_selected () {
        var entry = selection.selected_item as BulkPlaybackEntry;
        if (stopped || entry == null || !entry.eligible (output)) return;
        request.cancel ();
        request = new Cancellable ();
        error_label.visible = false;
        batch.play.begin (entry, output, request, (source, result) => {
            try { batch.play.end (result); }
            catch (Error e) {
                if (!stopped && !(e is IOError.CANCELLED)) {
                    error_label.label = "Could not play video: " + e.message;
                    error_label.visible = true;
                }
            }
        });
    }
#if BULK_PLAYBACK_TEST_BUILD
    internal void escape_for_test () { search.stop_search (); }
    internal void search_activate_for_test () { search.activate (); }
    internal void search_for_test (string text) { search.text = text; }
    internal void scroll_for_test (double value) { scroll.vadjustment.value = value; }
    internal double scroll_value_for_test () { return scroll.vadjustment.value; }
    internal uint matches_for_test () { return filtered.get_n_items (); }
    internal void select_for_test (uint position) { selection.selected = position; }
    internal BulkPlaybackEntry? selected_for_test () { return selection.selected_item as BulkPlaybackEntry; }
    internal void play_for_test () { play_selected (); }
    internal string count_for_test () { return count_label.label; }
    internal bool error_for_test () { return error_label.visible; }
#endif
}
