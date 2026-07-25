using Gtk;
using Adw;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  CombineWindow — Standalone window for joining multiple video files
//
//  Supports copy mode (lossless, strict match) and re-encode mode with full
//  normalization. Uses MainWindow's output folder as the single output
//  location source of truth, and participates in MainWindow's single-
//  operation model via a bool-returning reservation delegate and completion
//  signals.
// ═══════════════════════════════════════════════════════════════════════════════

public delegate bool ReserveOperationFunc (out uint64 operation_id);
// Returns the current MainWindow output folder so Combine stays in sync even
// after the window is already open.
public delegate string GetOutputFolderFunc ();

public interface IOperationStateSource : Object {
    public signal void operation_state_changed (bool is_idle);
    public abstract bool is_operation_idle ();
}

public class CombineWindow : Adw.Window {
    private class CombineLaunchRequest : Object {
        public bool copy_mode { get; set; default = true; }
        public string output_path { get; set; default = ""; }
        public GenericArray<CombineFile> files { get; set; default = new GenericArray<CombineFile> (); }
        public EncodeProfileSnapshot? reencode_profile { get; set; default = null; }
        public bool preserve_metadata { get; set; default = false; }
        public bool generate_chapters { get; set; default = false; }
        public bool remove_source_chapters { get; set; default = false; }
        public bool crossfade_enabled { get; set; default = false; }
        public double crossfade_duration { get; set; default = 0.5; }
        public string crossfade_type { get; set; default = "fade"; }
    }

    // ── Binding helpers (replace captured lambdas to avoid -Wcast-function-type) ─
    private class CombineFileRowBinding : Object {
        public unowned CombineWindow owner;
        public Adw.ActionRow row;
        public Button? move_up_button;
        public int idx;

        public void on_preview_clicked () {
            owner.show_preview (idx);
        }

        public void on_move_up_clicked () {
            owner.move_file_up (idx);
        }

        public void on_move_down_clicked () {
            owner.move_file_down (idx);
        }

        public void on_remove_clicked () {
            owner.remove_file (idx);
        }

        public Gdk.ContentProvider? on_drag_prepare (double x, double y) {
            owner._drag_from_idx = idx;
            var val = Value (typeof (string));
            val.set_string (CombineWindow.DRAG_ORIGIN_COMBINE);
            return new Gdk.ContentProvider.for_value (val);
        }

        public void on_drag_begin (DragSource source, Gdk.Drag drag) {
            var paintable = new WidgetPaintable (row);
            source.set_icon (paintable, 0, 0);
        }

        public bool on_drag_cancel (DragSource source, Gdk.Drag drag, Gdk.DragCancelReason reason) {
            owner._drag_from_idx = -1;
            return false;
        }

        public void on_drag_end (DragSource source, Gdk.Drag drag, bool delete_data) {
            owner._drag_from_idx = -1;
        }

        public bool on_drop (Value val, double x, double y) {
            string? origin = val.get_string ();
            if (origin != CombineWindow.DRAG_ORIGIN_COMBINE) {
                owner._drag_from_idx = -1;
                return false;
            }
            if (owner._drag_from_idx >= 0 && owner._drag_from_idx != idx) {
                owner.swap_files (owner._drag_from_idx, idx);
            }
            owner._drag_from_idx = -1;
            return true;
        }
    }

    private class CombineRunnerBinding : Object {
        public unowned CombineWindow owner;
        public uint64 operation_id;

        public void on_done (OperationOutputResult result) {
            owner.handle_runner_done (operation_id, result);
        }

        public void on_failed (string message) {
            owner.handle_runner_failed (operation_id, message);
        }

        public void on_cancelled (string cancel_message) {
            owner.handle_runner_cancelled (operation_id, cancel_message);
        }
    }

    // ── Codec tab references (shared with MainWindow, read-only) ────────────
    private SvtAv1Tab svt_tab;
    private X265Tab x265_tab;
    private X264Tab x264_tab;
    private Vp9Tab vp9_tab;
    private GeneralTab general_tab;
    private GetOutputFolderFunc get_output_folder;
    private ReserveOperationFunc reserve_operation;
    private unowned IOperationStateSource op_state_source;
    private ulong op_state_handler_id = 0;

    // ── MainWindow UI references for routing output ─────────────────────────
    private StatusArea? main_status_area;
    private ConsoleTab? main_console_tab;

    // ── Signals (MainWindow listens) ──────────────────────────────────────────
    public signal void combine_started (uint64 operation_id);
    public signal void combine_succeeded (uint64 operation_id, OperationOutputResult result);
    public signal void combine_failed (uint64 operation_id, string message);
    public signal void combine_cancelled (uint64 operation_id, string cancel_message);
    public signal void window_closing ();

    // ── File list ───────────────────────────────────────────────────────────
    private GenericArray<CombineFile> files = new GenericArray<CombineFile> ();
    private Adw.PreferencesGroup files_group;
    private GenericArray<Adw.ActionRow> file_rows = new GenericArray<Adw.ActionRow> ();

    // ── Options ─────────────────────────────────────────────────────────────
    private Adw.SwitchRow copy_mode_switch;
    private bool user_prefers_copy_mode = true;
    private bool copy_mode_updating = false;  // suppress notify during programmatic changes
    private Adw.ActionRow reencode_codec_row;
    private DropDown codec_choice;
    private Label audio_reencode_note;
    private Adw.SwitchRow generate_chapters_switch;
    private Adw.SwitchRow crossfade_switch;
    private Adw.ActionRow crossfade_duration_row;
    private SpinButton crossfade_duration_spin;
    private Adw.ActionRow crossfade_type_row;
    private DropDown crossfade_type_choice;
    private bool user_prefers_crossfade = false;
    private bool crossfade_updating = false;

    // ── Action area ─────────────────────────────────────────────────────────
    private Button combine_button;
    private Button cancel_button;

    // ── Status area ─────────────────────────────────────────────────────────
    private Label status_label;

    // ── State ───────────────────────────────────────────────────────────────
    private bool combining = false;
    private bool operation_reserved = false;
    private uint64 active_operation_id = 0;
    private CombineRunner? active_runner = null;
    private CombineRunnerBinding? active_runner_binding = null;
    private GenericArray<CombineFileRowBinding> file_row_bindings =
        new GenericArray<CombineFileRowBinding> ();
    private Adw.AlertDialog? pending_overwrite_dialog = null;
    private Cancellable? pending_overwrite_cancellable = null;
    private int pending_probes = 0;
    private GenericArray<Cancellable> probe_cancellables = new GenericArray<Cancellable> ();
    private bool operation_idle = true;  // tracks MainWindow state
    private bool tearing_down = false;

    // ── Preview ─────────────────────────────────────────────────────────────
    private Adw.Window? preview_window = null;
    private VideoPlayer? preview_player = null;

    // ── Crossfade/fade constraint ──────────────────────────────────────────
    private BaseCodecTab? constrained_codec_tab = null;
    private AudioProcessingSettingsSnapshot? saved_fade_snapshot = null;
    private bool general_timing_constrained = false;
    private GeneralTimingSettingsSnapshot? saved_general_timing_snapshot = null;
    private bool general_speed_constrained = false;
    private GeneralSpeedSettingsSnapshot? saved_general_speed_snapshot = null;
    private bool general_crop_constrained = false;
    private GeneralCropSettingsSnapshot? saved_general_crop_snapshot = null;
    private bool watermark_forces_reencode = false;

    // ── Drag-and-drop reorder ───────────────────────────────────────────────
    private int _drag_from_idx = -1;
    private const string DRAG_ORIGIN_COMBINE = "combine-file-reorder";

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public CombineWindow (SvtAv1Tab svt_tab,
                          X265Tab x265_tab,
                          X264Tab x264_tab,
                          Vp9Tab vp9_tab,
                          GeneralTab general_tab,
                          owned GetOutputFolderFunc get_output_folder,
                          StatusArea? status_area,
                          ConsoleTab? console_tab,
                          owned ReserveOperationFunc reserve_operation,
                          IOperationStateSource op_state_source) {
        Object ();
        this.svt_tab = svt_tab;
        this.x265_tab = x265_tab;
        this.x264_tab = x264_tab;
        this.vp9_tab = vp9_tab;
        this.general_tab = general_tab;
        this.get_output_folder = (owned) get_output_folder;
        this.main_status_area = status_area;
        this.main_console_tab = console_tab;
        this.reserve_operation = (owned) reserve_operation;
        this.op_state_source = op_state_source;

        // Subscribe to operation state changes and set initial state
        op_state_handler_id = op_state_source.operation_state_changed.connect ((is_idle) => {
            set_operation_idle (is_idle);
        });

        set_title ("Combine Videos");
        set_default_size (680, 720);

        build_ui ();
        sync_general_timing_constraint ();
        set_operation_idle (op_state_source.is_operation_idle ());
        update_combine_sensitivity ();

        // React to watermark / logo removal changes while Combine is open
        general_tab.watermark_toggled.connect (() => {
            sync_general_watermark_constraint ();
        });
        general_tab.logo_removal_toggled.connect (() => {
            sync_general_watermark_constraint ();
        });
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI CONSTRUCTION
    // ═════════════════════════════════════════════════════════════════════════

    private void build_ui () {
        var toolbar_view = new Adw.ToolbarView ();
        var header = new Adw.HeaderBar ();
        toolbar_view.add_top_bar (header);

        var scroll = new ScrolledWindow ();
        scroll.set_policy (PolicyType.NEVER, PolicyType.AUTOMATIC);
        scroll.set_vexpand (true);

        var content = new Box (Orientation.VERTICAL, 12);
        content.set_margin_top (12);
        content.set_margin_bottom (12);
        content.set_margin_start (12);
        content.set_margin_end (12);

        // ── Files group ─────────────────────────────────────────────────────
        files_group = new Adw.PreferencesGroup ();
        files_group.set_title ("Files");

        var add_button = new Button.with_label ("Add Files");
        add_button.add_css_class ("flat");
        add_button.clicked.connect (on_add_files_clicked);
        files_group.set_header_suffix (add_button);

        content.append (files_group);

        // ── File drop target (from file manager) ────────────────────────────
        var file_drop = new DropTarget (typeof (File), Gdk.DragAction.COPY);
        file_drop.drop.connect ((val, x, y) => {
            var file = val.get_object () as File;
            if (file == null) return false;
            string? path = file.get_path ();
            if (path == null) return false;
            if (is_video_file (path)) {
                add_file_path (path);
                return true;
            }
            return false;
        });
        content.add_controller (file_drop);

        var text_drop = new DropTarget (Type.STRING, Gdk.DragAction.COPY);
        text_drop.drop.connect ((val, x, y) => {
            string? text = val.get_string ();
            if (text == null) return false;
            string trimmed = text.strip ();
            // Handle newline-separated URI/path lists
            string[] lines = trimmed.split ("\n");
            bool any_added = false;
            foreach (string raw_line in lines) {
                string line = raw_line.strip ();
                if (line.has_suffix ("\r"))
                    line = line.substring (0, line.length - 1);
                string path = "";
                if (line.has_prefix ("file://")) {
                    var gfile = File.new_for_uri (line);
                    path = gfile.get_path () ?? "";
                } else {
                    path = line;
                }
                if (path.length > 0 && is_video_file (path)) {
                    add_file_path (path);
                    any_added = true;
                }
            }
            return any_added;
        });
        content.add_controller (text_drop);

        // ── Options group ───────────────────────────────────────────────────
        var options_group = new Adw.PreferencesGroup ();
        options_group.set_title ("Options");

        copy_mode_switch = new Adw.SwitchRow ();
        copy_mode_switch.set_title ("Copy Mode (Lossless)");
        copy_mode_switch.set_subtitle ("Only primary video and first audio track are preserved");
        copy_mode_switch.set_active (true);
        copy_mode_switch.notify["active"].connect (() => {
            if (!copy_mode_updating) {
                user_prefers_copy_mode = copy_mode_switch.active;
            }
            update_reencode_visibility ();
        });
        options_group.add (copy_mode_switch);

        reencode_codec_row = new Adw.ActionRow ();
        reencode_codec_row.set_title ("Re-encode Codec");
        reencode_codec_row.set_subtitle ("Uses the selected codec tab and compatible shared General settings");

        var codec_list = new StringList (null);
        codec_list.append ("SVT-AV1");
        codec_list.append ("x265");
        codec_list.append ("x264");
        codec_list.append ("VP9");
        codec_choice = new DropDown (codec_list, null);
        codec_choice.set_valign (Align.CENTER);
        codec_choice.set_selected (0);
        codec_choice.notify["selected"].connect (() => {
            sync_crossfade_fade_constraint ();
        });
        reencode_codec_row.add_suffix (codec_choice);
        reencode_codec_row.set_visible (false);
        options_group.add (reencode_codec_row);

        audio_reencode_note = new Label ("Audio will be re-encoded (stream copy is not possible with combined re-encode)");
        audio_reencode_note.add_css_class ("dim-label");
        audio_reencode_note.add_css_class ("caption");
        audio_reencode_note.set_wrap (true);
        audio_reencode_note.set_xalign (0);
        audio_reencode_note.set_margin_start (12);
        audio_reencode_note.set_visible (false);

        generate_chapters_switch = new Adw.SwitchRow ();
        generate_chapters_switch.set_title ("Generate Chapter Markers");
        generate_chapters_switch.set_subtitle ("Creates a chapter at each file boundary");
        generate_chapters_switch.set_active (false);
        options_group.add (generate_chapters_switch);

        crossfade_switch = new Adw.SwitchRow ();
        crossfade_switch.set_title ("Crossfade Transitions");
        crossfade_switch.set_subtitle ("Blend between clips");
        crossfade_switch.set_active (false);
        crossfade_switch.set_visible (false);  // hidden until re-encode mode
        crossfade_switch.notify["active"].connect (() => {
            if (!crossfade_updating) {
                user_prefers_crossfade = crossfade_switch.active;
            }
            update_crossfade_visibility ();
            sync_crossfade_fade_constraint ();
        });
        options_group.add (crossfade_switch);

        crossfade_duration_row = new Adw.ActionRow ();
        crossfade_duration_row.set_title ("Crossfade Duration");
        crossfade_duration_spin = new SpinButton.with_range (0.1, 5.0, 0.1);
        crossfade_duration_spin.set_value (0.5);
        crossfade_duration_spin.set_digits (1);
        crossfade_duration_spin.set_valign (Align.CENTER);
        crossfade_duration_row.add_suffix (crossfade_duration_spin);
        crossfade_duration_row.set_visible (false);
        options_group.add (crossfade_duration_row);

        crossfade_type_row = new Adw.ActionRow ();
        crossfade_type_row.set_title ("Transition Type");
        var transition_list = new StringList (null);
        transition_list.append ("Fade");
        transition_list.append ("Dissolve");
        transition_list.append ("Wipe Left");
        transition_list.append ("Wipe Right");
        transition_list.append ("Wipe Up");
        transition_list.append ("Wipe Down");
        transition_list.append ("Slide Left");
        transition_list.append ("Slide Right");
        crossfade_type_choice = new DropDown (transition_list, null);
        crossfade_type_choice.set_valign (Align.CENTER);
        crossfade_type_choice.set_selected (0);
        crossfade_type_row.add_suffix (crossfade_type_choice);
        crossfade_type_row.set_visible (false);
        options_group.add (crossfade_type_row);

        content.append (options_group);
        content.append (audio_reencode_note);

        // ── Action area ─────────────────────────────────────────────────────
        var action_box = new Box (Orientation.HORIZONTAL, 8);
        action_box.set_halign (Align.END);
        action_box.set_margin_top (8);

        cancel_button = new Button.with_label ("Cancel");
        cancel_button.add_css_class ("destructive-action");
        cancel_button.set_visible (false);
        cancel_button.clicked.connect (on_cancel_clicked);

        combine_button = new Button.with_label ("Combine");
        combine_button.add_css_class ("suggested-action");
        combine_button.clicked.connect (on_combine_clicked);

        action_box.append (cancel_button);
        action_box.append (combine_button);
        content.append (action_box);

        status_label = new Label ("");
        status_label.set_wrap (true);
        status_label.set_xalign (0);
        status_label.set_visible (false);
        content.append (status_label);

        scroll.set_child (content);
        toolbar_view.set_content (scroll);
        set_content (toolbar_view);

        // ── Constraints applied for the lifetime of the window ────────────
        sync_keep_all_audio_constraint ();

        // ── Close guard ─────────────────────────────────────────────────────
        close_request.connect (on_close_request);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PUBLIC API
    // ═════════════════════════════════════════════════════════════════════════

    public void cancel_combine () {
        if (active_runner != null) {
            active_runner.cancel ();
        }
    }

    /**
     * Invalidate a pending reservation and dismiss any in-flight overwrite
     * dialog (e.g. when MainWindow cancels during the overwrite prompt).
     * The dialog is force-closed and the async callback falls through to the
     * active_operation_id != op_id guard.
     */
    public void cancel_pending_combine () {
        active_operation_id = 0;
        operation_reserved = false;

        Adw.AlertDialog? dialog = pending_overwrite_dialog;
        pending_overwrite_cancellable = null;
        pending_overwrite_dialog = null;

        if (dialog != null) {
            dialog.force_close ();
        }

#if COMBINE_WINDOW_TEST_BUILD
        pending_overwrite_request_for_widget_test = null;
#endif
    }

    private void set_operation_idle (bool idle) {
        operation_idle = idle;
        update_combine_sensitivity ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CLOSE REQUEST
    // ═════════════════════════════════════════════════════════════════════════

    private bool on_close_request () {
        if (combining || operation_reserved) {
            var dialog = new Adw.AlertDialog (
                "Combine in Progress",
                "A combine operation is currently running. Cancel it before closing this window."
            );
            dialog.add_response ("ok", "OK");
            dialog.set_default_response ("ok");
            dialog.set_close_response ("ok");
            dialog.choose.begin (this, null, (obj, res) => {
                dialog.choose.end (res);
            });
            return true;  // block close
        }

        release_general_timing_constraint ();
        release_general_crop_constraint ();
        release_general_speed_constraint ();
        release_crossfade_fade_constraint ();
        release_audio_copy_constraint ();
        release_keep_all_audio_constraint ();
        clear_audio_status_override_from_all_tabs ();
        cancel_probes_for_teardown ();
        close_preview_window ();
        window_closing ();
        return false;  // allow close
    }

    public override void dispose () {
        cancel_probes_for_teardown ();
        if (op_state_handler_id != 0) {
            op_state_source.disconnect (op_state_handler_id);
            op_state_handler_id = 0;
        }
        base.dispose ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  FILE MANAGEMENT
    // ═════════════════════════════════════════════════════════════════════════

    private void on_add_files_clicked () {
        if (operation_reserved || combining) {
            return;
        }

        var dialog = new FileDialog ();
        dialog.title = "Add Video Files";

        var video_filter = new FileFilter ();
        video_filter.name = "Video Files";
        foreach (unowned string ext in VideoFileConstants.VIDEO_EXTENSIONS) {
            video_filter.add_pattern ("*" + ext);
        }

        var all_filter = new FileFilter ();
        all_filter.name = "All files";
        all_filter.add_pattern ("*");

        var filters = new GLib.ListStore (typeof (FileFilter));
        filters.append (video_filter);
        filters.append (all_filter);
        dialog.set_filters (filters);

        dialog.open_multiple.begin (this, null, (obj, res) => {
            try {
                var list = dialog.open_multiple.end (res);
                if (list != null) {
                    for (uint i = 0; i < list.get_n_items (); i++) {
                        var file = list.get_item (i) as File;
                        if (file != null) {
                            string? path = file.get_path ();
                            if (path != null && is_video_file (path)) {
                                add_file_path (path);
                            }
                        }
                    }
                }
            } catch (Error e) {
                if (!(e is Gtk.DialogError.DISMISSED)) {
                    warning ("Add files dialog error: %s", e.message);
                }
            }
        });
    }

    private void add_file_path (string path) {
        if (operation_reserved || combining) {
            return;
        }

        var cf = new CombineFile ();
        cf.path = path;
        cf.filename = Path.get_basename (path);

        // Determine extension
        string lower = path.down ();
        int dot = lower.last_index_of_char ('.');
        if (dot >= 0) {
            cf.extension = lower.substring (dot);
        }

        files.add (cf);

        var row = create_file_row (cf, files.length - 1);
        file_rows.add (row);
        files_group.add (row);

        var probe_cancellable = new Cancellable ();
        cf.probe_cancellable = probe_cancellable;
        probe_cancellables.add (probe_cancellable);
        pending_probes++;
        update_combine_sensitivity ();
        sync_audio_status_override ();
        probe_file_async.begin (cf, probe_cancellable);
    }

    private void remove_file (int idx) {
        if (operation_reserved || combining) {
            return;
        }

        if (idx < 0 || idx >= files.length) return;

        cancel_probe_for_file (files[idx]);
        files_group.remove (file_rows[idx]);
        files.remove_index (idx);
        file_rows.remove_index (idx);

        rebuild_file_rows ();
        update_copy_mode_eligibility ();
        update_combine_sensitivity ();
        sync_audio_status_override ();
    }

    private void swap_files (int from, int to) {
        if (operation_reserved || combining) {
            return;
        }

        if (from < 0 || from >= files.length || to < 0 || to >= files.length || from == to)
            return;

        // Swap in data arrays
        var tmp_file = files[from];
        files[from] = files[to];
        files[to] = tmp_file;

        var tmp_row = file_rows[from];
        file_rows[from] = file_rows[to];
        file_rows[to] = tmp_row;

        rebuild_file_rows ();
        update_copy_mode_eligibility ();
    }

    private void move_file_up (int idx) {
        if (idx > 0) swap_files (idx, idx - 1);
    }

    private void move_file_down (int idx) {
        if (idx < files.length - 1) swap_files (idx, idx + 1);
    }

    private void rebuild_file_rows () {
        // Remove all rows and re-add in order
        for (int i = 0; i < file_rows.length; i++) {
            files_group.remove (file_rows[i]);
        }

        // Recreate rows with correct indices
        file_rows = new GenericArray<Adw.ActionRow> ();
        file_row_bindings = new GenericArray<CombineFileRowBinding> ();
        for (int i = 0; i < files.length; i++) {
            var row = create_file_row (files[i], i);
            file_rows.add (row);
            files_group.add (row);
        }
    }

    private int find_file_index (CombineFile cf) {
        for (int i = 0; i < files.length; i++) {
            if (files[i] == cf) {
                return i;
            }
        }

        return -1;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  FILE ROW CREATION
    // ═════════════════════════════════════════════════════════════════════════

    private Adw.ActionRow create_file_row (CombineFile cf, int idx) {
        var row = new Adw.ActionRow ();
        row.set_title (cf.filename);
        update_row_subtitle (row, cf);

        var binding = new CombineFileRowBinding ();
        binding.owner = this;
        binding.row = row;
        binding.idx = idx;
        file_row_bindings.add (binding);

        // Preview button
        var preview_btn = new Button.from_icon_name ("media-playback-start-symbolic");
        preview_btn.set_tooltip_text ("Preview");
        preview_btn.add_css_class ("flat");
        preview_btn.set_valign (Align.CENTER);
        preview_btn.clicked.connect (binding.on_preview_clicked);
        row.add_suffix (preview_btn);

        // Move up button
        var up_btn = new Button.from_icon_name ("go-up-symbolic");
        up_btn.set_tooltip_text ("Move Up");
        up_btn.add_css_class ("flat");
        up_btn.set_valign (Align.CENTER);
        binding.move_up_button = up_btn;
        up_btn.clicked.connect (binding.on_move_up_clicked);
        row.add_suffix (up_btn);

        // Move down button
        var down_btn = new Button.from_icon_name ("go-down-symbolic");
        down_btn.set_tooltip_text ("Move Down");
        down_btn.add_css_class ("flat");
        down_btn.set_valign (Align.CENTER);
        down_btn.clicked.connect (binding.on_move_down_clicked);
        row.add_suffix (down_btn);

        // Remove button
        var remove_btn = new Button.from_icon_name ("user-trash-symbolic");
        remove_btn.set_tooltip_text ("Remove");
        remove_btn.add_css_class ("flat");
        remove_btn.set_valign (Align.CENTER);
        remove_btn.clicked.connect (binding.on_remove_clicked);
        row.add_suffix (remove_btn);

        // ── Drag-and-drop reorder ───────────────────────────────────────────
        var drag_source = new DragSource ();
        drag_source.set_actions (Gdk.DragAction.MOVE);
        drag_source.prepare.connect (binding.on_drag_prepare);
        drag_source.drag_begin.connect (binding.on_drag_begin);
        drag_source.drag_cancel.connect (binding.on_drag_cancel);
        drag_source.drag_end.connect (binding.on_drag_end);
        row.add_controller (drag_source);

        var drop_target = new DropTarget (typeof (string), Gdk.DragAction.MOVE);
        drop_target.drop.connect (binding.on_drop);
        row.add_controller (drop_target);

        return row;
    }

    private void update_row_subtitle (Adw.ActionRow row, CombineFile cf) {
        if (cf.probe_failed) {
            row.set_subtitle ("\u26a0 Probe failed \u2014 cannot combine");
            return;
        }
        if (cf.duration <= 0 && cf.width <= 0) {
            row.set_subtitle ("Probing...");
            return;
        }

        string duration_str = format_duration (cf.duration);
        string resolution_str = (cf.width > 0 && cf.height > 0)
            ? @"$(cf.width)\u00d7$(cf.height)" : "?";
        string video_str = cf.video_codec.length > 0 ? cf.video_codec : "?";
        string audio_str = cf.has_audio ? cf.audio_codec : "none";

        row.set_subtitle (@"$duration_str \u00b7 $resolution_str \u00b7 $video_str / $audio_str");

        // Mismatch warning — shown via tooltip on the row
        if (files.length > 1) {
            string warnings = get_mismatch_warnings (cf);
            if (warnings.length > 0) {
                string sub = row.get_subtitle () ?? "";
                row.set_subtitle (@"\u26a0 $sub");
                row.set_tooltip_text (warnings);
            } else {
                row.set_tooltip_text (null);
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  FFPROBE — Per-file probe
    // ═════════════════════════════════════════════════════════════════════════

    private async void probe_file_async (CombineFile cf, Cancellable probe_cancellable) {
        string[] cmd = {
            AppSettings.get_default ().ffprobe_path,
            "-v", "quiet",
            "-print_format", "json",
            "-show_entries", "stream=codec_type,codec_name,profile,pix_fmt,width,height,r_frame_rate,sample_aspect_ratio,sample_rate,channels,channel_layout",
            "-show_entries", "format=duration",
            cf.path
        };

        bool success = false;
        try {
            var launcher = new SubprocessLauncher (
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            var proc = SubprocessCompat.spawnv (launcher, cmd);

            string stdout_text;
            string stderr_text;
            yield proc.communicate_utf8_async (
                null, probe_cancellable, out stdout_text, out stderr_text);

            if (proc.get_successful () && stdout_text.length > 0) {
                parse_probe_result (cf, stdout_text);
                success = (cf.duration > 0 || cf.width > 0);
            }
        } catch (Error e) {
            if (!(e is IOError.CANCELLED)) {
                warning ("Probe failed for %s: %s", cf.filename, e.message);
            }
        }

        bool probe_was_tracked = remove_probe_cancellable (probe_cancellable);
        if (probe_was_tracked && pending_probes > 0) {
            pending_probes--;
        }
        if (cf.probe_cancellable == probe_cancellable) {
            cf.probe_cancellable = null;
        }

        if (tearing_down) {
            return;
        }

        if (!success && !(probe_cancellable.is_cancelled ())) {
            cf.probe_failed = true;
        }

        update_probe_row (cf);

        update_copy_mode_eligibility ();
        update_mismatch_warnings ();
        update_combine_sensitivity ();
        sync_audio_status_override ();
    }

    private bool remove_probe_cancellable (Cancellable probe_cancellable) {
        for (int i = 0; i < probe_cancellables.length; i++) {
            if (probe_cancellables[i] == probe_cancellable) {
                probe_cancellables.remove_index (i);
                return true;
            }
        }

        return false;
    }

    private void cancel_probe_for_file (CombineFile cf) {
        Cancellable? probe_cancellable = cf.probe_cancellable;
        if (probe_cancellable == null) {
            return;
        }

        cf.probe_cancellable = null;
        bool probe_was_tracked = remove_probe_cancellable (probe_cancellable);
        if (probe_was_tracked && pending_probes > 0) {
            pending_probes--;
        }
        probe_cancellable.cancel ();
    }

    private void cancel_probes_for_teardown () {
        if (tearing_down) {
            return;
        }

        tearing_down = true;
        pending_probes = 0;

        while (probe_cancellables.length > 0) {
            Cancellable probe_cancellable = probe_cancellables[0];
            probe_cancellables.remove_index (0);
            probe_cancellable.cancel ();
        }
    }

    private void update_probe_row (CombineFile cf) {
        int current_idx = find_file_index (cf);
        if (current_idx < 0 || current_idx >= file_rows.length) {
            return;
        }

        update_row_subtitle (file_rows[current_idx], cf);
    }

    private void parse_probe_result (CombineFile cf, string json_text) {
        try {
            var parser = new Json.Parser ();
            parser.load_from_data (json_text);
            var root = parser.get_root ().get_object ();

            // Parse format duration
            if (root.has_member ("format")) {
                var format = root.get_member ("format").get_object ();
                if (format.has_member ("duration")) {
                    string dur_str = format.get_string_member ("duration");
                    cf.duration = double.parse (dur_str);
                }
            }

            // Parse streams
            if (root.has_member ("streams")) {
                var streams = root.get_member ("streams").get_array ();
                bool found_video = false;
                bool found_audio = false;

                for (uint i = 0; i < streams.get_length (); i++) {
                    var stream = streams.get_element (i).get_object ();
                    string codec_type = stream.has_member ("codec_type")
                        ? stream.get_string_member ("codec_type") : "";

                    if (codec_type == "video" && !found_video) {
                        found_video = true;
                        if (stream.has_member ("codec_name"))
                            cf.video_codec = stream.get_string_member ("codec_name");
                        if (stream.has_member ("profile"))
                            cf.video_profile = stream.get_string_member ("profile");
                        if (stream.has_member ("pix_fmt"))
                            cf.pixel_format = stream.get_string_member ("pix_fmt");
                        if (stream.has_member ("width"))
                            cf.width = (int) stream.get_int_member ("width");
                        if (stream.has_member ("height"))
                            cf.height = (int) stream.get_int_member ("height");
                        if (stream.has_member ("r_frame_rate"))
                            cf.frame_rate = stream.get_string_member ("r_frame_rate");
                        if (stream.has_member ("sample_aspect_ratio")) {
                            string sar = stream.get_string_member ("sample_aspect_ratio");
                            if (sar != "N/A") {
                                cf.sample_aspect_ratio = sar;
                            }
                        }
                    } else if (codec_type == "audio" && !found_audio) {
                        found_audio = true;
                        cf.has_audio = true;
                        if (stream.has_member ("codec_name"))
                            cf.audio_codec = stream.get_string_member ("codec_name");
                        if (stream.has_member ("sample_rate")) {
                            string sr = stream.get_string_member ("sample_rate");
                            cf.audio_sample_rate = int.parse (sr);
                        }
                        if (stream.has_member ("channels"))
                            cf.audio_channels = (int) stream.get_int_member ("channels");
                        if (stream.has_member ("channel_layout"))
                            cf.audio_channel_layout = stream.get_string_member ("channel_layout");

                        // Infer layout if empty
                        if (cf.audio_channel_layout.length == 0 && cf.audio_channels > 0) {
                            switch (cf.audio_channels) {
                                case 1: cf.audio_channel_layout = "mono"; break;
                                case 2: cf.audio_channel_layout = "stereo"; break;
                                case 6: cf.audio_channel_layout = "5.1"; break;
                                case 8: cf.audio_channel_layout = "7.1"; break;
                            }
                        }
                    }
                }
            }
        } catch (Error e) {
            warning ("Failed to parse probe JSON for %s: %s", cf.filename, e.message);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  COPY MODE ELIGIBILITY
    // ═════════════════════════════════════════════════════════════════════════

    private void update_copy_mode_eligibility () {
        copy_mode_updating = true;

        if (files.length < 2) {
            copy_mode_switch.set_sensitive (true);
            copy_mode_switch.set_active (user_prefers_copy_mode);
            copy_mode_switch.set_subtitle ("Only primary video and first audio track are preserved");
            copy_mode_updating = false;
            update_reencode_visibility ();
            return;
        }

        string? mismatch = check_copy_eligibility ();
        if (mismatch == null) {
            copy_mode_switch.set_sensitive (true);
            copy_mode_switch.set_active (user_prefers_copy_mode);
            copy_mode_switch.set_subtitle ("Only primary video and first audio track are preserved");
        } else {
            copy_mode_switch.set_active (false);
            copy_mode_switch.set_sensitive (false);
            copy_mode_switch.set_subtitle (@"Disabled \u2014 $mismatch");
        }

        copy_mode_updating = false;

        update_reencode_visibility ();
    }

    private string? check_copy_eligibility () {
        if (files.length < 2) return null;
        var first = files[0];

        for (int i = 1; i < files.length; i++) {
            var f = files[i];
            if (f.video_codec != first.video_codec)
                return "files have different video codecs";
            if (f.video_profile != first.video_profile)
                return "files have different video profiles";
            if (f.pixel_format != first.pixel_format)
                return "files have different pixel formats";
            if (f.width != first.width || f.height != first.height)
                return "files have different resolutions";
            if (f.frame_rate != first.frame_rate)
                return "files have different frame rates";
            if (f.sample_aspect_ratio != first.sample_aspect_ratio)
                return "files have different pixel aspect ratios";
            if (f.audio_codec != first.audio_codec)
                return "files have different audio codecs";
            if (f.audio_sample_rate != first.audio_sample_rate)
                return "files have different audio sample rates";
            if (f.audio_channels != first.audio_channels)
                return "files have different audio channels";
            if (f.audio_channel_layout != first.audio_channel_layout)
                return "files have different audio channel layouts";
            if (f.extension != first.extension)
                return "files have different container formats";
        }

        return null;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  MISMATCH WARNINGS
    // ═════════════════════════════════════════════════════════════════════════

    private string get_mismatch_warnings (CombineFile cf) {
        if (files.length < 2) return "";
        var first = files[0];
        if (cf == first) return "";

        var sb = new StringBuilder ();
        if (cf.width != first.width || cf.height != first.height)
            sb.append (@"Resolution: $(cf.width)\u00d7$(cf.height) vs $(first.width)\u00d7$(first.height)\n");
        if (cf.video_codec != first.video_codec)
            sb.append (@"Video codec: $(cf.video_codec) vs $(first.video_codec)\n");
        if (cf.video_profile != first.video_profile)
            sb.append (@"Video profile: $(cf.video_profile) vs $(first.video_profile)\n");
        if (cf.pixel_format != first.pixel_format)
            sb.append (@"Pixel format: $(cf.pixel_format) vs $(first.pixel_format)\n");
        if (cf.frame_rate != first.frame_rate)
            sb.append (@"Frame rate: $(cf.frame_rate) vs $(first.frame_rate)\n");
        if (cf.sample_aspect_ratio != first.sample_aspect_ratio)
            sb.append (@"Pixel aspect ratio: $(cf.sample_aspect_ratio) vs $(first.sample_aspect_ratio)\n");
        if (cf.audio_codec != first.audio_codec)
            sb.append (@"Audio codec: $(cf.audio_codec) vs $(first.audio_codec)\n");
        if (cf.audio_sample_rate != first.audio_sample_rate)
            sb.append (@"Sample rate: $(cf.audio_sample_rate) vs $(first.audio_sample_rate)\n");
        if (cf.audio_channels != first.audio_channels)
            sb.append (@"Audio channels: $(cf.audio_channels) vs $(first.audio_channels)\n");
        if (cf.audio_channel_layout != first.audio_channel_layout)
            sb.append (@"Audio layout: $(cf.audio_channel_layout) vs $(first.audio_channel_layout)\n");
        if (cf.extension != first.extension)
            sb.append (@"Container: $(cf.extension) vs $(first.extension)\n");

        return sb.str.strip ();
    }

    private void update_mismatch_warnings () {
        for (int i = 0; i < files.length && i < file_rows.length; i++) {
            update_row_subtitle (file_rows[i], files[i]);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI STATE
    // ═════════════════════════════════════════════════════════════════════════

    private void update_reencode_visibility () {
        bool reencode = !copy_mode_switch.active;
        reencode_codec_row.set_visible (reencode);
        audio_reencode_note.set_visible (reencode);
        sync_audio_copy_constraint ();
        sync_audio_status_override ();

        crossfade_updating = true;
        crossfade_switch.set_visible (reencode);
        if (!reencode && crossfade_switch.active) {
            crossfade_switch.set_active (false);
        }
        if (reencode && user_prefers_crossfade && !crossfade_switch.active) {
            crossfade_switch.set_active (true);
        }
        crossfade_updating = false;

        update_crossfade_visibility ();
        sync_crossfade_fade_constraint ();
        sync_general_speed_constraint ();
        sync_general_crop_constraint ();
        sync_general_watermark_constraint ();
    }

    private void update_crossfade_visibility () {
        bool show = crossfade_switch.active && !copy_mode_switch.active;
        crossfade_duration_row.set_visible (show);
        crossfade_type_row.set_visible (show);
    }

    private void update_combine_sensitivity () {
        bool any_probe_failed = false;
        for (int i = 0; i < files.length; i++) {
            if (files[i].probe_failed) {
                any_probe_failed = true;
                break;
            }
        }

        bool can_combine = files.length >= 2
            && pending_probes == 0
            && !any_probe_failed
            && operation_idle
            && !combining;
        combine_button.set_sensitive (can_combine);
        update_files_description ();
    }

    private void update_files_description () {
        if (files.length == 0) {
            files_group.set_description (null);
            return;
        }

        int duplicate_count = count_duplicate_paths ();
        var sb = new StringBuilder ();
        sb.append ("%d file%s".printf (files.length, files.length == 1 ? "" : "s"));
        if (duplicate_count > 0) {
            sb.append (" \u00b7 %d duplicate%s".printf (
                duplicate_count, duplicate_count == 1 ? "" : "s"));
        }
        files_group.set_description (sb.str);
    }

    private int count_duplicate_paths () {
        int duplicates = 0;
        for (int i = 0; i < files.length; i++) {
            for (int j = 0; j < i; j++) {
                if (files[i].path == files[j].path) {
                    duplicates++;
                    break;
                }
            }
        }
        return duplicates;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PREVIEW
    // ═════════════════════════════════════════════════════════════════════════

    private void ensure_preview_window () {
        if (preview_window == null) {
            preview_player = new VideoPlayer ();
            preview_player.set_popout_visible (false);
            preview_window = new Adw.Window ();
            preview_window.set_title ("Preview");
            preview_window.set_default_size (800, 540);

            var toolbar_view = new Adw.ToolbarView ();
            var header = new Adw.HeaderBar ();
            toolbar_view.add_top_bar (header);
            toolbar_view.set_content (preview_player);
            preview_window.set_content (toolbar_view);

            preview_window.close_request.connect (() => {
                preview_player.cleanup ();
                preview_window = null;
                preview_player = null;
                return false;
            });
        }
    }

    private void show_preview (int idx) {
        if (idx < 0 || idx >= files.length) return;
        string path = files[idx].path;

        ensure_preview_window ();

        preview_player.load_file (path);
        preview_window.set_title (@"Preview \u2014 $(files[idx].filename)");
        preview_window.present ();
    }

    private void close_preview_window () {
        if (preview_window != null) {
            preview_player.cleanup ();
            preview_window.close ();
            preview_window = null;
            preview_player = null;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  COMBINE ACTION
    // ═════════════════════════════════════════════════════════════════════════

    private void on_combine_clicked () {
        if (files.length < 2) return;

        // Validate crossfade duration against shortest clip
        if (crossfade_switch.active && !copy_mode_switch.active) {
            double xfade_dur = crossfade_duration_spin.get_value ();
            double min_dur = double.MAX;
            for (int i = 0; i < files.length; i++) {
                if (files[i].duration < min_dur) {
                    min_dur = files[i].duration;
                }
            }
            if (xfade_dur >= min_dur) {
                show_toast ("Crossfade duration exceeds the shortest clip");
                return;
            }
        }

        // Try to reserve the operation
        uint64 op_id;
        if (!reserve_operation (out op_id)) {
            show_toast ("Another operation is in progress");
            return;
        }

        active_operation_id = op_id;
        operation_reserved = true;

        bool is_copy = copy_mode_switch.active;

        // ── Compute output path from the shared MainWindow output folder ───
        string out_folder = get_current_output_folder ();
        string computed_output;

        if (is_copy) {
            string ext = files[0].extension.has_prefix (".")
                ? files[0].extension.substring (1) : files[0].extension;
            var codec_tab = new CombineCodecTab (ext);
            var builder = codec_tab.get_codec_builder ();
            computed_output = ConversionUtils.compute_output_path (
                files[0].path, out_folder, builder, codec_tab);
        } else {
            int sel = (int) codec_choice.get_selected ();
            ICodecBuilder builder;
            ICodecTab codec_tab;
            get_selected_codec (sel, out builder, out codec_tab);
            computed_output = ConversionUtils.compute_output_path (
                files[0].path, out_folder, builder, codec_tab);
        }

        CombineLaunchRequest request = build_launch_request (computed_output, is_copy);

        // ── Overwrite check ─────────────────────────────────────────────────
        var settings = AppSettings.get_default ();
        if (!settings.overwrite_enabled && FileUtils.test (computed_output, FileTest.EXISTS)) {
            // Show confirmation inline
            var dialog = new Adw.AlertDialog (
                "File Already Exists",
                @"\"$(Path.get_basename (computed_output))\" already exists in the output folder.\n\nWhat would you like to do?"
            );
            dialog.add_response ("cancel", "Cancel");
            dialog.add_response ("rename", "Auto-Rename");
            dialog.set_response_appearance ("rename", Adw.ResponseAppearance.SUGGESTED);
            dialog.add_response ("overwrite", "Overwrite");
            dialog.set_response_appearance ("overwrite", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.set_default_response ("rename");
            dialog.set_close_response ("cancel");

            var cancellable = new Cancellable ();
            pending_overwrite_dialog = dialog;
            pending_overwrite_cancellable = cancellable;

            dialog.choose.begin (this, cancellable, (obj, res) => {
                if (pending_overwrite_dialog == dialog) {
                    pending_overwrite_dialog = null;
                    pending_overwrite_cancellable = null;
                }

                string response = dialog.choose.end (res);
#if COMBINE_WINDOW_TEST_BUILD
                pending_overwrite_response_count_for_widget_test++;
                last_pending_overwrite_response_for_widget_test = response;
#endif
                handle_overwrite_dialog_response (op_id, request, response);
            });
            return;
        }

        launch_combine (request);
    }

    private void handle_overwrite_dialog_response (uint64 op_id,
                                                   CombineLaunchRequest request,
                                                   string response) {
        // Guard: reservation may have been invalidated by MainWindow cancel,
        // or replaced by a newer combine reservation.
        if (active_operation_id != op_id) {
            return;
        }

        if (response == "overwrite") {
            launch_combine (request);
        } else if (response == "rename") {
            string? renamed = ConversionUtils.find_unique_path (request.output_path);
            if (renamed == null) {
                active_operation_id = 0;
                operation_reserved = false;
                combine_failed (op_id, "Could not generate a unique output filename");
                show_toast ("Could not generate a unique output filename");
                return;
            }
            request.output_path = renamed;
            launch_combine (request);
        } else {
            // Cancelled — release the operation
            active_operation_id = 0;
            operation_reserved = false;
            combine_cancelled (op_id, "Cancelled by user.");
        }
    }

    private CombineLaunchRequest build_launch_request (string output, bool is_copy) {
        var request = new CombineLaunchRequest ();
        request.copy_mode = is_copy;
        request.output_path = output;
        request.preserve_metadata = general_tab.is_preserve_metadata ();
        request.generate_chapters = generate_chapters_switch.active;
        request.remove_source_chapters = general_tab.is_remove_chapters ();
        request.crossfade_enabled = crossfade_switch.active && !is_copy;
        request.crossfade_duration = crossfade_duration_spin.get_value ();
        request.crossfade_type = get_crossfade_type_name ((int) crossfade_type_choice.get_selected ());

        for (int i = 0; i < files.length; i++) {
            request.files.add (copy_combine_file (files[i]));
        }

        if (!is_copy) {
            int sel = (int) codec_choice.get_selected ();
            ICodecBuilder builder;
            ICodecTab codec_tab;
            get_selected_codec (sel, out builder, out codec_tab);

            PixelFormatSettingsSnapshot? pixel_format =
                (codec_tab is BaseCodecTab)
                ? ((BaseCodecTab) codec_tab).snapshot_pixel_format_settings ()
                : null;
            GeneralSettingsSnapshot general_settings = general_tab.snapshot_settings (pixel_format);
            var profile = CodecUtils.snapshot_encode_profile (
                builder, codec_tab, general_settings);

            // Combine re-encode audio always passes through filter_complex
            // (concat or acrossfade), which is incompatible with -c:a copy.
            // This fallback is unconditional regardless of audio processing state.
            if (has_audio_copy_args (profile.audio_args)) {
                profile.audio_args = get_combine_audio_fallback_args (profile.container);
            }

            request.reencode_profile = profile;
        }

        return request;
    }

    private static CombineFile copy_combine_file (CombineFile source) {
        var copy = new CombineFile ();
        copy.path = source.path;
        copy.filename = source.filename;
        copy.duration = source.duration;
        copy.width = source.width;
        copy.height = source.height;
        copy.video_codec = source.video_codec;
        copy.video_profile = source.video_profile;
        copy.pixel_format = source.pixel_format;
        copy.frame_rate = source.frame_rate;
        copy.sample_aspect_ratio = source.sample_aspect_ratio;
        copy.audio_codec = source.audio_codec;
        copy.audio_sample_rate = source.audio_sample_rate;
        copy.audio_channels = source.audio_channels;
        copy.audio_channel_layout = source.audio_channel_layout;
        copy.extension = source.extension;
        copy.has_audio = source.has_audio;
        copy.probe_failed = source.probe_failed;
        return copy;
    }

    private void launch_combine (CombineLaunchRequest request) {
        uint64 op_id = active_operation_id;
        operation_reserved = false;

#if COMBINE_WINDOW_TEST_BUILD
        if (capture_launch_request_for_widget_test) {
            last_launched_paths_for_widget_test = {};
            for (int i = 0; i < request.files.length; i++) {
                last_launched_paths_for_widget_test += request.files[i].path;
            }
            last_launched_output_for_widget_test = request.output_path;
            last_launched_copy_mode_for_widget_test = request.copy_mode;
            last_launched_profile_for_widget_test = request.reencode_profile;
            active_operation_id = 0;
            update_combine_sensitivity ();
            return;
        }
#endif

        combining = true;
        combine_started (op_id);
        cancel_button.set_visible (true);
        status_label.set_visible (false);
        status_label.set_text ("");
        update_combine_sensitivity ();

        // Build the runner
        var runner = new CombineRunner ();
        runner.copy_mode = request.copy_mode;
        runner.output_path = request.output_path;
        runner.progress_bar = get_shared_progress_bar ();
        runner.status_area = main_status_area;
        runner.console_tab = main_console_tab;
        runner.preserve_metadata = request.preserve_metadata;
        runner.generate_chapters = request.generate_chapters;
        runner.remove_source_chapters = request.remove_source_chapters;
        runner.crossfade_enabled = request.crossfade_enabled;
        runner.crossfade_duration = request.crossfade_duration;
        runner.crossfade_type = request.crossfade_type;

        // Set files
        var file_list = new GenericArray<CombineFile> ();
        for (int i = 0; i < request.files.length; i++) {
            file_list.add (request.files[i]);
        }
        runner.set_files (file_list);

        if (!request.copy_mode) {
            runner.reencode_profile = request.reencode_profile;
        }

        // Wire completion signals
        var runner_binding = new CombineRunnerBinding ();
        runner_binding.owner = this;
        runner_binding.operation_id = op_id;
        active_runner_binding = runner_binding;
        runner.combine_done.connect (runner_binding.on_done);
        runner.combine_failed.connect (runner_binding.on_failed);
        runner.combine_cancelled.connect (runner_binding.on_cancelled);

        active_runner = runner;
        runner.run ();
    }

    private void on_cancel_clicked () {
        cancel_combine ();
    }

    // ── Runner completion handlers (called via CombineRunnerBinding) ─────────

    private void handle_runner_done (uint64 op_id, OperationOutputResult result) {
        combining = false;
        active_operation_id = 0;
        active_runner = null;
        active_runner_binding = null;
        cancel_button.set_visible (false);
        update_combine_sensitivity ();
        combine_succeeded (op_id, result);
    }

    private void handle_runner_failed (uint64 op_id, string message) {
        combining = false;
        active_operation_id = 0;
        active_runner = null;
        active_runner_binding = null;
        cancel_button.set_visible (false);
        status_label.set_text (message);
        status_label.set_visible (true);
        update_combine_sensitivity ();
        combine_failed (op_id, message);
    }

    private void handle_runner_cancelled (uint64 op_id, string cancel_message) {
        combining = false;
        active_operation_id = 0;
        active_runner = null;
        active_runner_binding = null;
        cancel_button.set_visible (false);
        status_label.set_text ("");
        status_label.set_visible (false);
        update_combine_sensitivity ();
        combine_cancelled (op_id, cancel_message);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  GENERAL TIMING CONSTRAINT
    // ═════════════════════════════════════════════════════════════════════════

    private bool is_general_timing_constraint_active () {
        return true;
    }

    private void sync_general_timing_constraint () {
        if (is_general_timing_constraint_active ()) {
            if (!general_timing_constrained) {
                saved_general_timing_snapshot = general_tab.snapshot_timing_only ();
            }
            general_tab.set_combine_timing_constraint (true);
            general_timing_constrained = true;
        } else {
            release_general_timing_constraint ();
        }
    }

    private void release_general_timing_constraint () {
        if (!general_timing_constrained) {
            return;
        }

        general_tab.set_combine_timing_constraint (false);
        if (saved_general_timing_snapshot != null) {
            general_tab.restore_timing_only (saved_general_timing_snapshot);
            saved_general_timing_snapshot = null;
        }
        general_timing_constrained = false;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  GENERAL CROP CONSTRAINT
    // ═════════════════════════════════════════════════════════════════════════

    private bool is_general_crop_constraint_active () {
        return !copy_mode_switch.active;
    }

    private void sync_general_crop_constraint () {
        if (is_general_crop_constraint_active ()) {
            if (!general_crop_constrained) {
                saved_general_crop_snapshot = general_tab.snapshot_crop_only ();
            }
            general_tab.set_combine_crop_constraint (true);
            general_crop_constrained = true;
        } else {
            release_general_crop_constraint ();
        }
    }

    private void release_general_crop_constraint () {
        if (!general_crop_constrained) {
            return;
        }

        general_tab.set_combine_crop_constraint (false);
        if (saved_general_crop_snapshot != null) {
            general_tab.restore_crop_only (saved_general_crop_snapshot);
            saved_general_crop_snapshot = null;
        }
        general_crop_constrained = false;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  GENERAL SPEED CONSTRAINT
    // ═════════════════════════════════════════════════════════════════════════

    private bool is_general_speed_constraint_active () {
        return !copy_mode_switch.active;
    }

    private void sync_general_speed_constraint () {
        if (is_general_speed_constraint_active ()) {
            if (!general_speed_constrained) {
                saved_general_speed_snapshot = general_tab.snapshot_speeds_only ();
            }
            general_tab.set_combine_speed_constraint (true);
            general_speed_constrained = true;
        } else {
            release_general_speed_constraint ();
        }
    }

    private void release_general_speed_constraint () {
        if (!general_speed_constrained) {
            return;
        }

        general_tab.set_combine_speed_constraint (false);
        if (saved_general_speed_snapshot != null) {
            general_tab.restore_speeds_only (saved_general_speed_snapshot);
            saved_general_speed_snapshot = null;
        }
        general_speed_constrained = false;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  GENERAL WATERMARK CONSTRAINT
    //
    //  When watermark is effectively active and Combine is in re-encode mode,
    //  watermark is applied post-output automatically via the filter chain.
    //  When Combine is in copy mode, watermark cannot be applied — so if the
    //  user has watermark active, force re-encode.
    //
    //  Logo removal is subject to the same rule: delogo is a video filter, and
    //  a stream copy never runs one.
    // ═════════════════════════════════════════════════════════════════════════

    private void sync_general_watermark_constraint () {
        bool active = general_tab.is_watermark_effectively_enabled ()
                      || general_tab.is_logo_removal_effectively_enabled ();
        bool was_active = watermark_forces_reencode;
        watermark_forces_reencode = active;

        if (active) {
            if (copy_mode_switch.active) {
                copy_mode_updating = true;
                copy_mode_switch.set_active (false);
                copy_mode_updating = false;
            }
            copy_mode_switch.set_sensitive (false);
        } else if (was_active) {
            // Watermark just became inactive — delegate to the central
            // eligibility check so SAR mismatches, codec incompatibility,
            // and other constraints are respected.
            update_copy_mode_eligibility ();
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CROSSFADE / FADE CONSTRAINT
    // ═════════════════════════════════════════════════════════════════════════

    private BaseCodecTab? get_selected_base_codec_tab () {
        int sel = (int) codec_choice.get_selected ();
        ICodecBuilder builder;
        ICodecTab codec_tab;
        get_selected_codec (sel, out builder, out codec_tab);
        return codec_tab as BaseCodecTab;
    }

    private void sync_audio_copy_constraint () {
        bool constrained = !copy_mode_switch.active;
        if (svt_tab != null)  svt_tab.audio_settings.update_for_combine_reencode (constrained);
        if (x265_tab != null) x265_tab.audio_settings.update_for_combine_reencode (constrained);
        if (x264_tab != null) x264_tab.audio_settings.update_for_combine_reencode (constrained);
        if (vp9_tab != null)  vp9_tab.audio_settings.update_for_combine_reencode (constrained);
    }

    private void release_audio_copy_constraint () {
        if (svt_tab != null)  svt_tab.audio_settings.update_for_combine_reencode (false);
        if (x265_tab != null) x265_tab.audio_settings.update_for_combine_reencode (false);
        if (x264_tab != null) x264_tab.audio_settings.update_for_combine_reencode (false);
        if (vp9_tab != null)  vp9_tab.audio_settings.update_for_combine_reencode (false);
    }

    private void sync_keep_all_audio_constraint () {
        if (svt_tab != null)  svt_tab.audio_settings.set_keep_all_audio_sensitive (false);
        if (x265_tab != null) x265_tab.audio_settings.set_keep_all_audio_sensitive (false);
        if (x264_tab != null) x264_tab.audio_settings.set_keep_all_audio_sensitive (false);
        if (vp9_tab != null)  vp9_tab.audio_settings.set_keep_all_audio_sensitive (false);
    }

    private void release_keep_all_audio_constraint () {
        if (svt_tab != null)  svt_tab.audio_settings.set_keep_all_audio_sensitive (true);
        if (x265_tab != null) x265_tab.audio_settings.set_keep_all_audio_sensitive (true);
        if (x264_tab != null) x264_tab.audio_settings.set_keep_all_audio_sensitive (true);
        if (vp9_tab != null)  vp9_tab.audio_settings.set_keep_all_audio_sensitive (true);
    }

    private void sync_audio_status_override () {
        bool reencode = !copy_mode_switch.active;

        if (reencode) {
            apply_audio_status_override_to_all_tabs (
                "media-playlist-consecutive-symbolic",
                "Audio re-encoded by Combine",
                "audio-status-neutral");
            return;
        }

        // Copy mode: only show override if probes are done and audio exists
        if (pending_probes == 0 && has_any_audio_in_files ()) {
            apply_audio_status_override_to_all_tabs (
                "emblem-default-symbolic",
                "Audio copy via Combine",
                "audio-status-found");
            return;
        }

        // Probes pending or no audio — clear override, fall back to normal badge
        clear_audio_status_override_from_all_tabs ();
    }

    private bool has_any_audio_in_files () {
        for (int i = 0; i < files.length; i++) {
            if (files[i].has_audio) {
                return true;
            }
        }
        return false;
    }

    private void apply_audio_status_override_to_all_tabs (string icon, string text, string css) {
        if (svt_tab != null)  svt_tab.audio_settings.set_audio_status_override (icon, text, css);
        if (x265_tab != null) x265_tab.audio_settings.set_audio_status_override (icon, text, css);
        if (x264_tab != null) x264_tab.audio_settings.set_audio_status_override (icon, text, css);
        if (vp9_tab != null)  vp9_tab.audio_settings.set_audio_status_override (icon, text, css);
    }

    private void clear_audio_status_override_from_all_tabs () {
        if (svt_tab != null)  svt_tab.audio_settings.clear_audio_status_override ();
        if (x265_tab != null) x265_tab.audio_settings.clear_audio_status_override ();
        if (x264_tab != null) x264_tab.audio_settings.clear_audio_status_override ();
        if (vp9_tab != null)  vp9_tab.audio_settings.clear_audio_status_override ();
    }

    private bool is_crossfade_constraint_active () {
        return crossfade_switch.active && !copy_mode_switch.active;
    }

    private void sync_crossfade_fade_constraint () {
        BaseCodecTab? current_tab = get_selected_base_codec_tab ();

        // Release old tab if it's different from the new one
        if (constrained_codec_tab != null && constrained_codec_tab != current_tab) {
            restore_and_release_constrained_tab ();
        }

        if (is_crossfade_constraint_active () && current_tab != null) {
            // Snapshot current fade state before clearing, but only if we're
            // not already constraining this same tab (avoid re-snapshotting
            // the already-cleared state)
            if (constrained_codec_tab != current_tab) {
                saved_fade_snapshot = current_tab.audio_processing_settings.snapshot_fades_only ();
            }
            current_tab.set_combine_crossfade_fade_constraint (true);
            constrained_codec_tab = current_tab;
        } else {
            release_crossfade_fade_constraint ();
        }
    }

    private void release_crossfade_fade_constraint () {
        if (constrained_codec_tab != null) {
            restore_and_release_constrained_tab ();
        }
    }

    private void restore_and_release_constrained_tab () {
        if (constrained_codec_tab == null) return;

        constrained_codec_tab.set_combine_crossfade_fade_constraint (false);
        if (saved_fade_snapshot != null) {
            constrained_codec_tab.audio_processing_settings.restore_fades_only (saved_fade_snapshot);
            saved_fade_snapshot = null;
        }
        constrained_codec_tab = null;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CODEC SELECTION HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    private void get_selected_codec (int sel,
                                     out ICodecBuilder builder,
                                     out ICodecTab codec_tab) {
        if (sel == 0 && svt_tab != null) {
            builder = svt_tab.get_codec_builder ();
            codec_tab = svt_tab;
        } else if (sel == 1 && x265_tab != null) {
            builder = x265_tab.get_codec_builder ();
            codec_tab = x265_tab;
        } else if (sel == 2 && x264_tab != null) {
            builder = x264_tab.get_codec_builder ();
            codec_tab = x264_tab;
        } else if (sel == 3 && vp9_tab != null) {
            builder = vp9_tab.get_codec_builder ();
            codec_tab = vp9_tab;
        } else {
            // Fallback
            builder = svt_tab.get_codec_builder ();
            codec_tab = svt_tab;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CROSSFADE HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    private static string get_crossfade_type_name (int index) {
        switch (index) {
            case 0: return "fade";
            case 1: return "dissolve";
            case 2: return "wipeleft";
            case 3: return "wiperight";
            case 4: return "wipeup";
            case 5: return "wipedown";
            case 6: return "slideleft";
            case 7: return "slideright";
            default: return "fade";
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  AUDIO FALLBACK (§9)
    // ═════════════════════════════════════════════════════════════════════════

    private static bool has_audio_copy_args (string[] args) {
        for (int i = 0; i < args.length - 1; i++) {
            if (args[i] == "-c:a" && args[i + 1] == "copy") return true;
        }
        return false;
    }

    private static string[] get_combine_audio_fallback_args (string container) {
        switch (container.down ().strip ()) {
            case ContainerExt.WEBM:
                return { "-c:a", "libopus", "-b:a", "192k" };
            case ContainerExt.MP4:
                return { "-c:a", "aac", "-b:a", "192k" };
            default:
                // MKV and other containers
                return { "-c:a", "aac", "-b:a", "192k" };
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    private string get_current_output_folder () {
        if (get_output_folder == null) {
            return "";
        }

        string? output_folder = get_output_folder ();
        return output_folder ?? "";
    }

    private Gtk.ProgressBar? get_shared_progress_bar () {
        if (main_status_area == null) {
            return null;
        }

        return main_status_area.progress_bar;
    }

    private static bool is_video_file (string path) {
        string lower = path.down ();
        foreach (unowned string ext in VideoFileConstants.VIDEO_EXTENSIONS) {
            if (lower.has_suffix (ext)) return true;
        }
        return false;
    }

    private static string format_duration (double secs) {
        if (secs <= 0) return "0:00";
        int total = (int) secs;
        int h = total / 3600;
        int m = (total % 3600) / 60;
        int s = total % 60;
        if (h > 0) return "%d:%02d:%02d".printf (h, m, s);
        return "%d:%02d".printf (m, s);
    }

    private void show_toast (string message) {
        // Use an alert dialog as a simple notification since we don't
        // have a ToastOverlay in this window.
        var dialog = new Adw.AlertDialog ("Notice", message);
        dialog.add_response ("ok", "OK");
        dialog.set_default_response ("ok");
        dialog.set_close_response ("ok");
        dialog.choose.begin (this, null, (obj, res) => {
            dialog.choose.end (res);
        });
    }

#if COMBINE_WINDOW_TEST_BUILD
    internal void load_files_for_widget_test (string[] paths) {
        for (int i = 0; i < file_rows.length; i++) {
            files_group.remove (file_rows[i]);
        }

        files = new GenericArray<CombineFile> ();
        file_rows = new GenericArray<Adw.ActionRow> ();
        file_row_bindings = new GenericArray<CombineFileRowBinding> ();
        pending_probes = 0;

        foreach (unowned string path in paths) {
            var cf = new CombineFile ();
            cf.path = path;
            cf.filename = Path.get_basename (path);

            string lower = path.down ();
            int dot = lower.last_index_of_char ('.');
            if (dot >= 0) {
                cf.extension = lower.substring (dot);
            }

            files.add (cf);

            var row = create_file_row (cf, files.length - 1);
            file_rows.add (row);
            files_group.add (row);
        }

        update_copy_mode_eligibility ();
        update_combine_sensitivity ();
    }

    internal void click_file_move_up_for_widget_test (int idx) {
        if (idx < 0 || idx >= file_row_bindings.length)
            return;

        Button? button = file_row_bindings[idx].move_up_button;
        if (button != null) {
            button.clicked ();
        }
    }

    internal void create_preview_player_for_widget_test () {
        ensure_preview_window ();
    }

    internal bool is_preview_popout_visible_for_widget_test () {
        return preview_player != null
            && preview_player.is_popout_visible_for_widget_test ();
    }

    internal string get_file_name_for_widget_test (int idx) {
        return files[idx].filename;
    }

    internal CombineFile get_file_for_widget_test (int idx) {
        return files[idx];
    }

    internal string get_row_subtitle_for_widget_test (int idx) {
        return file_rows[idx].get_subtitle () ?? "";
    }

    internal void replay_probe_completion_for_widget_test (CombineFile cf) {
        update_probe_row (cf);
    }

    internal void complete_pending_probe_for_widget_test (CombineFile cf,
                                                          Cancellable probe_cancellable,
                                                          bool success = true) {
        bool probe_was_tracked = remove_probe_cancellable (probe_cancellable);
        if (probe_was_tracked && pending_probes > 0) {
            pending_probes--;
        }
        if (cf.probe_cancellable == probe_cancellable) {
            cf.probe_cancellable = null;
        }

        if (!success && !(probe_cancellable.is_cancelled ())) {
            cf.probe_failed = true;
        }

        update_probe_row (cf);
        update_copy_mode_eligibility ();
        update_mismatch_warnings ();
        update_combine_sensitivity ();
        sync_audio_status_override ();
    }

    internal void refresh_combine_state_for_widget_test () {
        update_copy_mode_eligibility ();
        update_mismatch_warnings ();
        update_combine_sensitivity ();
        sync_audio_status_override ();
    }

    internal Cancellable arm_pending_probe_for_widget_test () {
        var probe_cancellable = new Cancellable ();
        probe_cancellables.add (probe_cancellable);
        pending_probes++;
        return probe_cancellable;
    }

    internal Cancellable arm_pending_probe_for_file_for_widget_test (int idx) {
        var probe_cancellable = new Cancellable ();
        files[idx].probe_cancellable = probe_cancellable;
        probe_cancellables.add (probe_cancellable);
        pending_probes++;
        return probe_cancellable;
    }

    internal void remove_file_for_widget_test (int idx) {
        remove_file (idx);
    }

    internal bool invoke_close_request_for_widget_test () {
        return on_close_request ();
    }

    internal int get_pending_probe_count_for_widget_test () {
        return pending_probes;
    }

    internal bool is_combine_sensitive_for_widget_test () {
        return combine_button.get_sensitive ();
    }

    internal bool is_copy_mode_sensitive_for_widget_test () {
        return copy_mode_switch.get_sensitive ();
    }

    internal string get_copy_mode_subtitle_for_widget_test () {
        return copy_mode_switch.get_subtitle () ?? "";
    }

    internal string get_reencode_codec_subtitle_for_widget_test () {
        return reencode_codec_row.get_subtitle () ?? "";
    }

    internal void simulate_runner_cancelled_for_widget_test (uint64 op_id,
                                                             string cancel_message = "Cancelled") {
        var runner = new CombineRunner ();
        var binding = new CombineRunnerBinding ();
        binding.owner = this;
        binding.operation_id = op_id;

        combining = true;
        active_operation_id = op_id;
        active_runner = runner;
        active_runner_binding = binding;

        runner.combine_cancelled.connect (binding.on_cancelled);
        runner.combine_cancelled (cancel_message);
    }

    internal bool has_active_runner_binding_for_widget_test () {
        return active_runner_binding != null;
    }

    internal bool is_status_label_visible_for_widget_test () {
        return status_label.get_visible ();
    }

    internal void arm_pending_overwrite_for_widget_test (uint64 op_id) {
        active_operation_id = op_id;
        operation_reserved = true;

        var dialog = new Adw.AlertDialog ("Test overwrite", "Test overwrite");
        dialog.add_response ("cancel", "Cancel");
        dialog.set_close_response ("cancel");

        pending_overwrite_dialog = dialog;
        pending_overwrite_cancellable = new Cancellable ();
        pending_overwrite_request_for_widget_test = build_launch_request (
            "/tmp/test-output.mkv", true);
    }

    private bool capture_launch_request_for_widget_test = false;
    private string[] last_launched_paths_for_widget_test = {};
    private string last_launched_output_for_widget_test = "";
    private bool last_launched_copy_mode_for_widget_test = false;
    private EncodeProfileSnapshot? last_launched_profile_for_widget_test = null;
    private uint pending_overwrite_response_count_for_widget_test = 0;
    private string? last_pending_overwrite_response_for_widget_test = null;

    internal void enable_launch_capture_for_widget_test () {
        capture_launch_request_for_widget_test = true;
        last_launched_paths_for_widget_test = {};
        last_launched_output_for_widget_test = "";
        last_launched_copy_mode_for_widget_test = false;
        last_launched_profile_for_widget_test = null;
    }

    internal void arm_pending_overwrite_snapshot_for_widget_test (uint64 op_id,
                                                                  bool is_copy,
                                                                  string output_path) {
        active_operation_id = op_id;
        operation_reserved = true;

        var request = build_launch_request (output_path, is_copy);

        var dialog = new Adw.AlertDialog ("Test overwrite", "Test overwrite");
        dialog.add_response ("cancel", "Cancel");
        dialog.set_close_response ("cancel");

        pending_overwrite_dialog = dialog;
        pending_overwrite_cancellable = new Cancellable ();
        pending_overwrite_request_for_widget_test = request;
    }

    internal void replay_pending_overwrite_cancel_for_widget_test (uint64 op_id) {
        if (pending_overwrite_request_for_widget_test == null) {
            return;
        }

        var request = pending_overwrite_request_for_widget_test;
        pending_overwrite_request_for_widget_test = null;
        handle_overwrite_dialog_response (op_id, request, "cancel");
    }

    private CombineLaunchRequest? pending_overwrite_request_for_widget_test = null;

    internal void replay_pending_overwrite_launch_for_widget_test (uint64 op_id,
                                                                  string response) {
        if (pending_overwrite_request_for_widget_test == null) {
            return;
        }

        var request = pending_overwrite_request_for_widget_test;
        pending_overwrite_request_for_widget_test = null;
        handle_overwrite_dialog_response (op_id, request, response);
    }

    internal string[] get_last_launched_paths_for_widget_test () {
        return last_launched_paths_for_widget_test;
    }

    internal string get_last_launched_output_for_widget_test () {
        return last_launched_output_for_widget_test;
    }

    internal bool get_last_launched_copy_mode_for_widget_test () {
        return last_launched_copy_mode_for_widget_test;
    }

    internal bool has_pending_overwrite_dialog_for_widget_test () {
        return pending_overwrite_dialog != null;
    }

    internal bool has_pending_overwrite_cancellable_for_widget_test () {
        return pending_overwrite_cancellable != null;
    }

    internal void reset_pending_overwrite_response_capture_for_widget_test () {
        pending_overwrite_response_count_for_widget_test = 0;
        last_pending_overwrite_response_for_widget_test = null;
    }

    internal uint get_pending_overwrite_response_count_for_widget_test () {
        return pending_overwrite_response_count_for_widget_test;
    }

    internal string get_last_pending_overwrite_response_for_widget_test () {
        return last_pending_overwrite_response_for_widget_test ?? "";
    }

    internal bool is_operation_reserved_for_widget_test () {
        return operation_reserved;
    }

    internal uint64 get_active_operation_id_for_widget_test () {
        return active_operation_id;
    }

    internal EncodeProfileSnapshot? get_last_launched_profile_for_widget_test () {
        return last_launched_profile_for_widget_test;
    }

    internal bool get_crossfade_switch_active_for_widget_test () {
        return crossfade_switch.active;
    }

    internal void set_crossfade_switch_active_for_widget_test (bool active) {
        crossfade_switch.set_active (active);
    }

    internal void set_copy_mode_switch_active_for_widget_test (bool active) {
        copy_mode_switch.set_active (active);
    }

    internal void set_codec_choice_selected_for_widget_test (uint sel) {
        codec_choice.set_selected (sel);
    }

    internal bool is_audio_copy_available_in_codec_tab_for_widget_test (uint sel) {
        BaseCodecTab? tab = get_codec_tab_for_widget_test ((int) sel);
        return tab != null && tab.audio_settings.is_codec_available_for_test (AudioCodecName.COPY);
    }

    internal string get_codec_tab_selected_audio_codec_for_widget_test (uint sel) {
        BaseCodecTab? tab = get_codec_tab_for_widget_test ((int) sel);
        if (tab == null) {
            return "";
        }
        return tab.audio_settings.get_selected_codec_for_test ();
    }

    internal string get_codec_tab_audio_subtitle_for_widget_test (uint sel) {
        BaseCodecTab? tab = get_codec_tab_for_widget_test ((int) sel);
        if (tab == null) {
            return "";
        }
        return tab.audio_settings.get_codec_row_subtitle_for_test ();
    }

    internal string get_codec_tab_audio_badge_text_for_widget_test (uint sel) {
        BaseCodecTab? tab = get_codec_tab_for_widget_test ((int) sel);
        if (tab == null) {
            return "";
        }
        return tab.audio_settings.get_audio_status_badge_text_for_test ();
    }

    private BaseCodecTab? get_codec_tab_for_widget_test (int sel) {
        switch (sel) {
        case 0:
            return svt_tab;
        case 1:
            return x265_tab;
        case 2:
            return x264_tab;
        case 3:
            return vp9_tab;
        default:
            return null;
        }
    }

    internal BaseCodecTab? get_constrained_codec_tab_for_widget_test () {
        return constrained_codec_tab;
    }

    internal BaseCodecTab? get_selected_base_codec_tab_for_widget_test () {
        return get_selected_base_codec_tab ();
    }

    internal GeneralTab get_general_tab_for_widget_test () {
        return general_tab;
    }

    internal bool get_general_speed_constrained_for_widget_test () {
        return general_speed_constrained;
    }

    internal bool get_general_timing_constrained_for_widget_test () {
        return general_timing_constrained;
    }

    internal bool get_general_crop_constrained_for_widget_test () {
        return general_crop_constrained;
    }

    internal bool get_watermark_forces_reencode_for_widget_test () {
        return watermark_forces_reencode;
    }

    internal void release_general_timing_constraint_for_widget_test () {
        release_general_timing_constraint ();
    }

    internal void sync_general_timing_constraint_for_widget_test () {
        sync_general_timing_constraint ();
    }

    internal void click_combine_for_widget_test () {
        on_combine_clicked ();
    }
#endif
}
