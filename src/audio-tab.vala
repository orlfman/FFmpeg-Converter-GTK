using Gtk;
using Adw;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  AudioTab — Audio extraction from video files
//
//  Supports stream copy, transcoding with full codec controls, audio
//  processing (normalization, fade, downmix), a waveform-based audio player
//  with multi-segment trimming, and batch extraction of all audio tracks.
//
//  NOT based on BaseCodecTab — this is a standalone Box like SubtitlesTab.
// ═══════════════════════════════════════════════════════════════════════════════

public class AudioTab : Box {

    private class SegmentRowBinding : Object {
        public unowned AudioTab owner;
        public Entry start_entry;
        public Entry end_entry;
        public int idx;

        public void on_start_changed () {
            owner.validate_segment_start_entry (start_entry, idx);
        }

        public void on_start_activate () {
            owner.activate_segment_start_entry (start_entry, idx);
        }

        public void on_end_changed () {
            owner.validate_segment_end_entry (end_entry, idx);
        }

        public void on_end_activate () {
            owner.activate_segment_end_entry (end_entry, idx);
        }

        public void on_seek_clicked () {
            owner.seek_to_segment_start (idx);
        }

        public void on_move_up_clicked () {
            owner.move_segment_up (idx);
        }

        public void on_move_down_clicked () {
            owner.move_segment_down (idx);
        }

        public void on_delete_clicked () {
            owner.delete_segment (idx);
        }
    }

    private class RunnerBinding : Object {
        public unowned AudioTab owner;
        public unowned AudioRunner runner_inst;
        public uint64 operation_id;

        public void on_extract_done (OperationOutputResult output_result) {
            owner.handle_runner_extract_done (runner_inst, operation_id, output_result);
        }

        public void on_extract_failed (string msg) {
            owner.handle_runner_extract_failed (runner_inst, operation_id);
        }
    }

    // ── Signals ──────────────────────────────────────────────────────────────
    public signal void audio_extract_succeeded (uint64 operation_id, OperationOutputResult output_result);
    public signal void audio_extract_failed (uint64 operation_id);
    public signal void audio_extract_cancelled (uint64 operation_id);
    public signal void audio_extract_all_requested ();
    public signal void source_audio_probe_updated (AudioStreamProbeResult audio_probe);

    // ── Audio Player ─────────────────────────────────────────────────────────
    private AudioPlayer player;

    // ── Mark In / Out ────────────────────────────────────────────────────────
    private double mark_in = 0.0;
    private double mark_out = 0.0;
    private Label mark_in_label;
    private Label mark_out_label;

    // ── Segments ─────────────────────────────────────────────────────────────
    private GenericArray<AudioSegment> segments = new GenericArray<AudioSegment> ();
    private Adw.PreferencesGroup segments_group;
    private Gtk.ListBox segment_listbox;
    private Label segment_count_label;

    // ── Stream info ──────────────────────────────────────────────────────────
    private Adw.PreferencesGroup info_group;
    private Adw.ActionRow stream_info_row;
    private Adw.StatusPage no_audio_page;
    private bool has_audio = false;
    private string current_input_file = "";
    private AudioSourceInfo primary_audio_source = new AudioSourceInfo ();
    private double loaded_duration = 0.0;
    private uint probe_generation = 0;
    private Cancellable? probe_cancellable = null;
    private GenericArray<AudioStreamInfo> all_audio_streams = new GenericArray<AudioStreamInfo> ();
    private DropDown? stream_dropdown = null;
    private Image stream_icon;
    private Label? stream_count_badge = null;
    private int selected_stream_index = 0;

    // ── Output mode ──────────────────────────────────────────────────────────
    private Adw.SwitchRow copy_mode_row;
    private Adw.SwitchRow export_separate_row;

    // ── Shared audio codec controls (transcode only) ────────────────────────
    private Adw.PreferencesGroup codec_group;
    private AudioSettings audio_settings;

    // ── Audio processing ─────────────────────────────────────────────────────
    private Adw.PreferencesGroup processing_group;
    private AudioProcessingSettings audio_processing_settings;
    private Adw.SwitchRow metadata_row_switch;

    // Visibility-tracked containers
    private Box seg_box;
    private Adw.ActionRow add_seg_row;
    private Separator? output_separator;

    // ── Extract All ──────────────────────────────────────────────────────────
    private Button extract_all_button;
    private Adw.PreferencesGroup? extract_all_group;
    private Adw.ActionRow? extract_all_summary_row;

    // ── Runner ───────────────────────────────────────────────────────────────
    private AudioRunner? active_runner = null;
    private uint64 active_operation_id = 0;
    private bool cancel_pending = false;
    private RunnerBinding? active_runner_binding = null;
    private GenericArray<SegmentRowBinding> segment_row_bindings =
        new GenericArray<SegmentRowBinding> ();

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public AudioTab () {
        Object (orientation: Orientation.VERTICAL, spacing: 24);
        set_margin_top (24);
        set_margin_bottom (24);
        set_margin_start (24);
        set_margin_end (24);

        inject_audio_tab_css ();

        build_status_banner ();
        build_player_section ();
        build_mark_controls ();
        build_segment_list ();

        // Visual separator between editing and output sections
        output_separator = new Separator (Orientation.HORIZONTAL);
        output_separator.set_margin_top (4);
        output_separator.set_margin_bottom (4);
        output_separator.set_visible (false);
        append (output_separator);

        build_output_mode ();
        build_codec_controls ();
        build_processing_options ();
        build_extract_all ();

        update_mode_visibility ();
    }

    public override void dispose () {
        cancel_probe ();
        player.cleanup ();
        if (flash_timeout_id != 0) {
            Source.remove (flash_timeout_id);
            flash_timeout_id = 0;
        }
        base.dispose ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PUBLIC API
    // ═════════════════════════════════════════════════════════════════════════

    public void load_video (string path) {
        cancel_probe ();
        current_input_file = path;
        primary_audio_source = new AudioSourceInfo ();
        has_audio = false;
        all_audio_streams = new GenericArray<AudioStreamInfo> ();
        loaded_duration = 0.0;
        selected_stream_index = 0;

        reset_segments ();
        player.clear ();
        stream_info_row.set_title ("Detecting…");
        stream_info_row.set_subtitle ("");
        info_group.set_description (null);

        // Clean up stream selector
        if (stream_dropdown != null) {
            stream_dropdown.unparent ();
            stream_dropdown = null;
        }
        if (stream_count_badge != null) stream_count_badge.set_visible (false);

        if (path.length == 0) {
            show_no_audio ("No File Loaded", "Select an input file to extract audio");
            emit_source_audio_probe (MediaStreamPresence.UNKNOWN);
            return;
        }

        show_probe_pending ();

        // Start probing audio streams
        probe_audio_streams.begin (path);
    }

    /**
     * Start audio extraction with the current settings.
     */
    public bool start_extract (string input_file,
                                string output_folder,
                                StatusArea status_area,
                                ConsoleTab console_tab,
                                uint64 operation_id,
                                bool allow_overwrite = false) {
        if (has_pending_or_active_extract ()) {
            status_area.set_status ("An audio extraction is already running.",
                StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
            return false;
        }

        if (!has_audio) {
            status_area.set_status ("No audio stream found in the input file.",
                StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
            return false;
        }

        var config = snapshot_config ();
        if (!config.copy_mode && segments.length == 0
            && config.fade_out_enabled && loaded_duration <= 0.0) {
            status_area.set_status ("Audio duration is still loading. Please wait a moment and try again.",
                StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
            return false;
        }
        string ext = AudioBuilder.get_output_extension (
            config, primary_audio_source.codec_name, segments.length);

        // Resolve output paths
        string basename = Path.get_basename (input_file);
        int dot = basename.last_index_of_char ('.');
        string name_no_ext = (dot > 0) ? basename.substring (0, dot) : basename;
        string out_dir = (output_folder != null && output_folder != "")
            ? output_folder
            : Path.get_dirname (input_file);

        var runner_inst = new AudioRunner ();
        runner_inst.input_file = input_file;
        runner_inst.source_codec = primary_audio_source.codec_name;
        runner_inst.config = config;
        runner_inst.status_area = status_area;
        runner_inst.progress_bar = status_area.progress_bar;
        runner_inst.console_tab = console_tab;
        runner_inst.set_total_duration (loaded_duration);

        if (segments.length > 0) {
            runner_inst.set_segments (segments);

            var paths = new GenericArray<string> ();
            if (config.export_separate) {
                for (int i = 0; i < segments.length; i++) {
                    string seg_name = "%s-audio-%s%s".printf (
                        name_no_ext,
                        ConversionUtils.pad_segment_number (i + 1),
                        ext);
                    string seg_path = Path.build_filename (out_dir, seg_name);
                    if (allow_overwrite) {
                        paths.add (seg_path);
                    } else {
                        string? unique = ConversionUtils.find_unique_path (seg_path);
                        paths.add (unique ?? seg_path);
                    }
                }
                runner_inst.set_output_paths (paths);
            } else {
                string combined_path = Path.build_filename (
                    out_dir, "%s-audio%s".printf (name_no_ext, ext));
                if (allow_overwrite) {
                    runner_inst.set_primary_output (combined_path);
                } else {
                    string? unique = ConversionUtils.find_unique_path (combined_path);
                    runner_inst.set_primary_output (unique ?? combined_path);
                }
            }
        } else {
            string out_path = Path.build_filename (
                out_dir, "%s-audio%s".printf (name_no_ext, ext));
            if (allow_overwrite) {
                runner_inst.set_primary_output (out_path);
            } else {
                string? unique = ConversionUtils.find_unique_path (out_path);
                runner_inst.set_primary_output (unique ?? out_path);
            }
        }

        activate_runner (runner_inst, operation_id);
        runner_inst.run ();
        return true;
    }

    /**
     * Start extracting all audio tracks (copy mode, no segments).
     */
    public bool start_extract_all (string input_file,
                                    string output_folder,
                                    StatusArea status_area,
                                    ConsoleTab console_tab,
                                    uint64 operation_id,
                                    bool allow_overwrite = false) {
        if (has_pending_or_active_extract ()) {
            status_area.set_status ("An audio extraction is already running.",
                StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
            return false;
        }

        if (all_audio_streams.length == 0) {
            status_area.set_status ("No audio streams found in the input file.",
                StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
            return false;
        }

        string basename = Path.get_basename (input_file);
        int dot = basename.last_index_of_char ('.');
        string name_no_ext = (dot > 0) ? basename.substring (0, dot) : basename;
        string out_dir = (output_folder != null && output_folder != "")
            ? output_folder
            : Path.get_dirname (input_file);

        var runner_inst = new AudioRunner ();
        runner_inst.input_file = input_file;
        runner_inst.status_area = status_area;
        runner_inst.progress_bar = status_area.progress_bar;
        runner_inst.console_tab = console_tab;
        runner_inst.set_total_duration (loaded_duration);

        activate_runner (runner_inst, operation_id);
        runner_inst.run_extract_all (all_audio_streams, out_dir, name_no_ext, allow_overwrite);
        return true;
    }

    public void cancel_extract () {
        if (active_operation_id == 0) return;
        cancel_pending = true;
        if (active_runner != null) {
            active_runner.cancel ();
        }
    }

    public bool is_extracting () {
        return has_pending_or_active_extract ();
    }

    public bool can_extract () {
        return has_audio && current_input_file.length > 0;
    }

    public string get_input_file () {
        return current_input_file;
    }

    /**
     * Clean up the audio player (kill waveform process, delete temp files).
     * Called from the window's close_request handler since GTK4 does not
     * guarantee dispose() runs before the process exits.
     */
    public void cleanup_player () {
        player.cleanup ();
    }

    /**
     * Return the expected primary output path for the current settings,
     * without auto-rename.  Used by the overwrite protection dialog.
     */
    public string get_expected_output_path (string input_file, string output_folder) {
        if (input_file.length == 0 || !has_audio) return "";

        var config = snapshot_config ();
        string ext = AudioBuilder.get_output_extension (
            config, primary_audio_source.codec_name, segments.length);

        string basename = Path.get_basename (input_file);
        int dot = basename.last_index_of_char ('.');
        string name_no_ext = (dot > 0) ? basename.substring (0, dot) : basename;
        string out_dir = (output_folder != null && output_folder != "")
            ? output_folder
            : Path.get_dirname (input_file);

        if (segments.length > 0 && config.export_separate) {
            return Path.build_filename (out_dir, "%s-audio-%s%s".printf (
                name_no_ext,
                ConversionUtils.pad_segment_number (1),
                ext));
        }

        return Path.build_filename (out_dir, "%s-audio%s".printf (name_no_ext, ext));
    }

    /**
     * Return the expected first output path for Extract All Tracks,
     * without auto-rename.  Used by the overwrite protection dialog.
     */
    public string get_expected_extract_all_path (string input_file, string output_folder) {
        if (input_file.length == 0 || all_audio_streams.length == 0) return "";

        string basename = Path.get_basename (input_file);
        int dot = basename.last_index_of_char ('.');
        string name_no_ext = (dot > 0) ? basename.substring (0, dot) : basename;
        string out_dir = (output_folder != null && output_folder != "")
            ? output_folder
            : Path.get_dirname (input_file);

        // Use the first stream's codec for the representative path,
        // not the selected stream — Extract All always starts from track 1
        string ext = AudioSourceLogic.get_copy_extension_for_codec_name (
            all_audio_streams[0].codec_name);
        return Path.build_filename (out_dir, "%s-track-%s%s".printf (
            name_no_ext,
            ConversionUtils.pad_segment_number (1),
            ext));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  1. STATUS BANNER
    // ═════════════════════════════════════════════════════════════════════════

    private void build_status_banner () {
        // No-audio status page (hidden when audio is present)
        no_audio_page = new Adw.StatusPage ();
        no_audio_page.set_icon_name ("audio-x-generic-symbolic");
        no_audio_page.set_title ("No Audio Streams Found");
        no_audio_page.set_description ("Select a file with audio to begin extraction");
        no_audio_page.set_visible (true);
        append (no_audio_page);

        // Stream info group (visible when audio is present)
        info_group = new Adw.PreferencesGroup ();
        info_group.set_title ("Audio Stream");

        // Stream count badge (shown for multi-stream files)
        stream_count_badge = new Label ("");
        stream_count_badge.add_css_class ("source-file-size");
        stream_count_badge.set_visible (false);
        info_group.set_header_suffix (stream_count_badge);

        stream_info_row = new Adw.ActionRow ();
        stream_info_row.set_title ("Detecting…");
        stream_icon = make_icon ("audio-x-generic-symbolic");
        stream_info_row.add_prefix (stream_icon);
        info_group.add (stream_info_row);
        info_group.set_visible (false);
        append (info_group);
    }

    private void show_no_audio (string title, string description) {
        no_audio_page.set_icon_name ("audio-x-generic-symbolic");
        no_audio_page.set_title (title);
        no_audio_page.set_description (description);
        no_audio_page.set_visible (true);
        info_group.set_visible (false);
        set_controls_visible (false);
    }

    private void show_probe_pending () {
        no_audio_page.set_icon_name ("system-search-symbolic");
        no_audio_page.set_title ("Detecting Audio Streams…");
        no_audio_page.set_description ("Inspecting the selected file");
        no_audio_page.set_visible (true);
        info_group.set_visible (false);
        set_controls_visible (false);
    }

    private void show_probe_error (string description) {
        no_audio_page.set_icon_name ("dialog-warning-symbolic");
        no_audio_page.set_title ("Failed to Inspect Audio Streams");
        no_audio_page.set_description (description);
        no_audio_page.set_visible (true);
        info_group.set_visible (false);
        set_controls_visible (false);
    }

    private void show_audio_found () {
        no_audio_page.set_visible (false);
        info_group.set_visible (true);
        set_controls_visible (true);
    }

    private void set_controls_visible (bool visible) {
        player.set_visible (visible);
        if (mark_group != null) mark_group.set_visible (visible);
        if (seg_box != null) seg_box.set_visible (visible);
        if (output_separator != null) output_separator.set_visible (visible);
        if (output_group != null) output_group.set_visible (visible);
        if (codec_group != null)
            codec_group.set_visible (visible && copy_mode_row != null && !copy_mode_row.get_active ());
        if (processing_group != null)
            processing_group.set_visible (visible && copy_mode_row != null && !copy_mode_row.get_active ());
        if (extract_all_group != null) extract_all_group.set_visible (visible);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  2. AUDIO PLAYER
    // ═════════════════════════════════════════════════════════════════════════

    private void build_player_section () {
        player = new AudioPlayer ();
        player.set_visible (false);
        player.media_ready.connect ((dur) => {
            loaded_duration = dur;
        });
        append (player);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  3. MARK IN / OUT CONTROLS
    // ═════════════════════════════════════════════════════════════════════════

    private Adw.PreferencesGroup mark_group;

    private void build_mark_controls () {
        mark_group = new Adw.PreferencesGroup ();
        mark_group.set_title ("Segment Controls");
        mark_group.set_description (
            "Mark time points and create segments from the current playback position");
        mark_group.set_visible (false);

        // Mark In row
        var mark_in_row = new Adw.ActionRow ();
        mark_in_row.set_title ("Mark In");
        mark_in_row.set_subtitle ("Start point for the next segment");
        mark_in_label = new Label (VideoPlayer.format_time (0.0));
        mark_in_label.add_css_class ("monospace");
        mark_in_label.add_css_class ("mark-time-readout");
        var mark_in_btn = new Button.with_label ("Set");
        mark_in_btn.add_css_class ("suggested-action");
        mark_in_btn.set_valign (Align.CENTER);
        mark_in_btn.clicked.connect (() => {
            mark_in = player.get_position_seconds ();
            mark_in_label.set_text (VideoPlayer.format_time (mark_in));
        });
        mark_in_row.add_suffix (mark_in_label);
        mark_in_row.add_suffix (mark_in_btn);
        mark_group.add (mark_in_row);

        // Mark Out row
        var mark_out_row = new Adw.ActionRow ();
        mark_out_row.set_title ("Mark Out");
        mark_out_row.set_subtitle ("End point for the next segment");
        mark_out_label = new Label (VideoPlayer.format_time (0.0));
        mark_out_label.add_css_class ("monospace");
        mark_out_label.add_css_class ("mark-time-readout");
        var mark_out_btn = new Button.with_label ("Set");
        mark_out_btn.add_css_class ("suggested-action");
        mark_out_btn.set_valign (Align.CENTER);
        mark_out_btn.clicked.connect (() => {
            mark_out = player.get_position_seconds ();
            mark_out_label.set_text (VideoPlayer.format_time (mark_out));
        });
        mark_out_row.add_suffix (mark_out_label);
        mark_out_row.add_suffix (mark_out_btn);
        mark_group.add (mark_out_row);

        // Add Segment row — compact buttons as suffixes
        add_seg_row = new Adw.ActionRow ();
        add_seg_row.set_title ("Add Segment");
        add_seg_row.set_subtitle ("Create a new segment from the current In/Out marks");

        // Add from marks button
        var add_btn = new Button.with_label ("Add");
        add_btn.add_css_class ("suggested-action");
        add_btn.set_valign (Align.CENTER);
        add_btn.clicked.connect (() => {
            if (mark_in >= mark_out) {
                flash_invalid_marks ();
                return;
            }
            add_segment (mark_in, mark_out);
        });

        // Reset marks button
        var reset_btn = new Button.with_label ("Reset");
        reset_btn.add_css_class ("destructive-action");
        reset_btn.set_valign (Align.CENTER);
        reset_btn.clicked.connect (() => {
            mark_in = 0.0;
            mark_out = 0.0;
            mark_in_label.set_text (VideoPlayer.format_time (0.0));
            mark_out_label.set_text (VideoPlayer.format_time (0.0));
        });

        add_seg_row.add_suffix (reset_btn);
        add_seg_row.add_suffix (add_btn);
        mark_group.add (add_seg_row);

        append (mark_group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  4. SEGMENT LIST
    // ═════════════════════════════════════════════════════════════════════════

    private void build_segment_list () {
        segments_group = new Adw.PreferencesGroup ();
        segments_group.set_title ("Segments");
        segments_group.set_description ("Segments will be exported in the order listed below");

        segment_count_label = new Label ("0 segments");
        segment_count_label.add_css_class ("dim-label");
        segments_group.set_header_suffix (segment_count_label);

        segment_listbox = new Gtk.ListBox ();
        segment_listbox.set_selection_mode (SelectionMode.NONE);
        segment_listbox.add_css_class ("boxed-list");
        segments_group.add (segment_listbox);

        seg_box = new Box (Orientation.VERTICAL, 0);
        seg_box.set_visible (false);
        seg_box.append (segments_group);
        append (seg_box);
    }

    private void add_segment (double start, double end) {
        var seg = new AudioSegment (start, end);
        segments.add (seg);
        rebuild_segment_list ();
        update_waveform_highlights ();
    }

    private void remove_segment (int index) {
        if (index < 0 || index >= segments.length) return;
        segments.remove_index (index);
        rebuild_segment_list ();
        update_waveform_highlights ();
    }

    private void move_segment (int from, int to) {
        if (from < 0 || from >= segments.length || to < 0 || to >= segments.length)
            return;
        var seg = segments[from];
        segments.remove_index (from);
        segments.insert (to, seg);
        rebuild_segment_list ();
        update_waveform_highlights ();
    }

    private void reset_segments () {
        segments = new GenericArray<AudioSegment> ();
        mark_in = 0.0;
        mark_out = 0.0;
        mark_in_label.set_text (VideoPlayer.format_time (0.0));
        mark_out_label.set_text (VideoPlayer.format_time (0.0));
        rebuild_segment_list ();
        update_waveform_highlights ();
    }

    private static bool audio_tab_css_injected = false;

    private static void inject_audio_tab_css () {
        if (audio_tab_css_injected) return;
        audio_tab_css_injected = true;

        var css = new CssProvider ();
        css.load_from_string (
            // Segment validation styling
            "entry.segment-valid {\n" +
            "    border-color: @success_color;\n" +
            "    box-shadow: 0 0 0 1px alpha(@success_color, 0.35);\n" +
            "    transition: border-color 150ms ease, box-shadow 150ms ease;\n" +
            "}\n" +
            "entry.segment-error {\n" +
            "    border-color: @error_color;\n" +
            "    box-shadow: 0 0 0 1px alpha(@error_color, 0.35);\n" +
            "    transition: border-color 150ms ease, box-shadow 150ms ease;\n" +
            "}\n" +
            // Mark time readout styling
            ".mark-time-readout {\n" +
            "    background: alpha(@window_fg_color, 0.06);\n" +
            "    border-radius: 6px;\n" +
            "    padding: 4px 10px;\n" +
            "}\n" +
            // Error subtitle on ActionRow
            "row.error .subtitle {\n" +
            "    color: @error_color;\n" +
            "}\n" +
            // Clear segments row — destructive hint
            "row.clear-segments-row .title {\n" +
            "    color: @error_color;\n" +
            "    opacity: 0.85;\n" +
            "}\n"
        );
        GtkCompat.add_provider_for_display (
            Gdk.Display.get_default (),
            css,
            STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }

    private bool validate_segment_time (Entry entry, bool parse_success,
                                        double parsed_value, double other_value,
                                        bool is_start) {
        string? error_reason = null;

        if (!parse_success) {
            error_reason = "Use HH:MM:SS(.mmm) or decimal seconds";
        } else if (parsed_value < 0.0) {
            error_reason = "Time cannot be negative";
        }

        if (error_reason == null) {
            if (is_start && parsed_value >= other_value) {
                error_reason = "Start must be before end";
            } else if (!is_start && parsed_value <= other_value) {
                error_reason = "End must be after start";
            }
        }

        if (error_reason == null && loaded_duration > 0.0
            && parsed_value > loaded_duration) {
            error_reason = "Exceeds audio duration";
        }

        entry.remove_css_class ("segment-valid");
        entry.remove_css_class ("segment-error");

        if (error_reason != null) {
            entry.add_css_class ("segment-error");
            entry.set_tooltip_text (error_reason);
            return false;
        } else {
            entry.add_css_class ("segment-valid");
            entry.set_tooltip_text ("Valid");
            return true;
        }
    }

    private void rebuild_segment_list () {
        segment_row_bindings = new GenericArray<SegmentRowBinding> ();

        // Clear existing rows
        var child = segment_listbox.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            segment_listbox.remove (child);
            child = next;
        }

        double total_dur = 0.0;
        for (int i = 0; i < segments.length; i++) {
            var seg = segments[i];
            total_dur += seg.get_duration ();

            var row = new Adw.ActionRow ();
            row.set_title ("Segment %d".printf (i + 1));
            row.set_subtitle ("%.1f s".printf (seg.get_duration ()));

            // ── Start time editor ────────────────────────────────────────
            var start_entry = new Entry ();
            start_entry.set_text (VideoPlayer.format_time (seg.start_time));
            start_entry.set_width_chars (13);
            start_entry.set_max_width_chars (13);
            start_entry.set_valign (Align.CENTER);
            start_entry.add_css_class ("monospace");
            start_entry.set_tooltip_text ("Start time (editable)");
            row.add_suffix (start_entry);

            var arrow = new Label ("→");
            arrow.set_valign (Align.CENTER);
            arrow.add_css_class ("dim-label");
            arrow.set_margin_start (4);
            arrow.set_margin_end (4);
            row.add_suffix (arrow);

            // ── End time editor ──────────────────────────────────────────
            var end_entry = new Entry ();
            end_entry.set_text (VideoPlayer.format_time (seg.end_time));
            end_entry.set_width_chars (13);
            end_entry.set_max_width_chars (13);
            end_entry.set_valign (Align.CENTER);
            end_entry.add_css_class ("monospace");
            end_entry.set_tooltip_text ("End time (editable)");
            row.add_suffix (end_entry);

            var binding = new SegmentRowBinding ();
            binding.owner = this;
            binding.start_entry = start_entry;
            binding.end_entry = end_entry;
            binding.idx = i;
            segment_row_bindings.add (binding);
            start_entry.changed.connect (binding.on_start_changed);
            start_entry.activate.connect (binding.on_start_activate);
            end_entry.changed.connect (binding.on_end_changed);
            end_entry.activate.connect (binding.on_end_activate);

            // Seek button
            var seek_btn = new Button.from_icon_name ("find-location-symbolic");
            seek_btn.set_tooltip_text ("Seek to segment start");
            seek_btn.add_css_class ("flat");
            seek_btn.set_valign (Align.CENTER);
            seek_btn.clicked.connect (binding.on_seek_clicked);
            row.add_suffix (seek_btn);

            // Move up
            if (i > 0) {
                var up_btn = new Button.from_icon_name ("go-up-symbolic");
                up_btn.add_css_class ("flat");
                up_btn.set_valign (Align.CENTER);
                up_btn.set_tooltip_text ("Move up");
                up_btn.clicked.connect (binding.on_move_up_clicked);
                row.add_suffix (up_btn);
            }

            // Move down
            if (i < segments.length - 1) {
                var down_btn = new Button.from_icon_name ("go-down-symbolic");
                down_btn.add_css_class ("flat");
                down_btn.set_valign (Align.CENTER);
                down_btn.set_tooltip_text ("Move down");
                down_btn.clicked.connect (binding.on_move_down_clicked);
                row.add_suffix (down_btn);
            }

            // Delete
            var del_btn = new Button.from_icon_name ("user-trash-symbolic");
            del_btn.add_css_class ("flat");
            del_btn.set_valign (Align.CENTER);
            del_btn.set_tooltip_text ("Remove segment");
            del_btn.clicked.connect (binding.on_delete_clicked);
            row.add_suffix (del_btn);

            segment_listbox.append (row);
        }

        // Clear All row (only when there are segments)
        if (segments.length > 0) {
            var clear_row = new Adw.ActionRow ();
            clear_row.set_title ("Clear All Segments");
            clear_row.add_prefix (make_icon ("user-trash-symbolic"));
            clear_row.set_activatable (true);
            clear_row.add_css_class ("clear-segments-row");
            clear_row.activated.connect (reset_segments);
            segment_listbox.append (clear_row);
        }

        segment_count_label.set_text ("%d segment%s · %s total".printf (
            segments.length,
            segments.length == 1 ? "" : "s",
            VideoPlayer.format_time (total_dur)));

        bool multi = segments.length >= 2;
        export_separate_row.set_visible (multi);
        if (!multi) export_separate_row.set_active (false);
    }

    private void update_waveform_highlights () {
        player.set_segments (segments);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  5. OUTPUT MODE
    // ═════════════════════════════════════════════════════════════════════════

    private Adw.PreferencesGroup output_group;

    private void build_output_mode () {
        output_group = new Adw.PreferencesGroup ();
        output_group.set_title ("Output");
        output_group.set_visible (false);

        // Copy / Transcode
        copy_mode_row = new Adw.SwitchRow ();
        copy_mode_row.set_title ("Stream Copy");
        copy_mode_row.set_subtitle ("Copy audio without re-encoding (fastest, lossless)");
        copy_mode_row.set_active (true);
        copy_mode_row.notify["active"].connect (() => {
            update_mode_visibility ();
        });
        output_group.add (copy_mode_row);

        // Export Separate / Combined
        export_separate_row = new Adw.SwitchRow ();
        export_separate_row.set_title ("Export Separate Files");
        export_separate_row.set_subtitle ("Each segment as its own file (otherwise combined)");
        export_separate_row.set_active (false);
        export_separate_row.set_visible (false);
        output_group.add (export_separate_row);

        // Metadata (applies in both copy and transcode modes)
        metadata_row_switch = new Adw.SwitchRow ();
        metadata_row_switch.set_title ("Strip Metadata");
        metadata_row_switch.set_subtitle ("Remove all metadata tags from output");
        metadata_row_switch.set_active (false);
        output_group.add (metadata_row_switch);

        append (output_group);
    }

    private void update_mode_visibility () {
        bool copy = copy_mode_row != null && copy_mode_row.get_active ();
        if (codec_group != null) codec_group.set_visible (!copy && has_audio);
        if (processing_group != null) processing_group.set_visible (!copy && has_audio);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  6. CODEC CONTROLS (Transcode mode only)
    // ═════════════════════════════════════════════════════════════════════════

    private void build_codec_controls () {
        audio_settings = new AudioSettings (AudioSettingsMode.TRANSCODE_ONLY);
        codec_group = audio_settings.get_widget ();
        codec_group.set_visible (false);
        append (codec_group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  7. AUDIO PROCESSING OPTIONS
    // ═════════════════════════════════════════════════════════════════════════

    private void build_processing_options () {
        audio_processing_settings = new AudioProcessingSettings (true);
        processing_group = audio_processing_settings.get_widget ();
        processing_group.set_visible (false);

        append (processing_group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  8. EXTRACT ALL TRACKS
    // ═════════════════════════════════════════════════════════════════════════

    private void build_extract_all () {
        extract_all_group = new Adw.PreferencesGroup ();
        extract_all_group.set_title ("Quick Export");
        extract_all_group.set_visible (false);

        extract_all_summary_row = new Adw.ActionRow ();
        extract_all_summary_row.set_title ("All Audio Tracks");
        extract_all_summary_row.set_subtitle ("Stream copy · No transcoding");
        extract_all_summary_row.add_prefix (make_icon ("audio-x-generic-symbolic"));

        extract_all_button = new Button.with_label ("Extract All");
        extract_all_button.add_css_class ("suggested-action");
        extract_all_button.set_valign (Align.CENTER);
        extract_all_button.set_tooltip_text (
            "Batch-extract every audio stream as a separate file");
        extract_all_button.clicked.connect (on_extract_all_clicked);
        extract_all_summary_row.add_suffix (extract_all_button);

        extract_all_group.add (extract_all_summary_row);
        append (extract_all_group);
    }

    private void on_extract_all_clicked () {
        if (all_audio_streams.length == 0 || current_input_file.length == 0)
            return;
        audio_extract_all_requested ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  AUDIO STREAM PROBING
    // ═════════════════════════════════════════════════════════════════════════

    private void cancel_probe () {
        if (probe_cancellable != null) {
            probe_cancellable.cancel ();
            probe_cancellable = null;
        }
    }

    private async void probe_audio_streams (string input_file) {
        probe_generation++;
        uint gen = probe_generation;

        var cancel = new Cancellable ();
        probe_cancellable = cancel;

        // Probe all audio streams
        var result = yield FfprobeUtils.probe_all_audio_streams_async (input_file, cancel);

        if (cancel.is_cancelled () || gen != probe_generation)
            return;

        if (!result.success) {
            if (probe_cancellable == cancel)
                probe_cancellable = null;
            has_audio = false;
            emit_source_audio_probe (MediaStreamPresence.ERROR);
            string detail = result.error_message.length > 0
                ? result.error_message
                : "The selected file could not be inspected.";
            show_probe_error (detail);
            return;
        }

        all_audio_streams = result.streams;

        if (all_audio_streams.length == 0) {
            if (probe_cancellable == cancel)
                probe_cancellable = null;
            has_audio = false;
            emit_source_audio_probe (MediaStreamPresence.ABSENT);
            show_no_audio ("No Audio Streams Found",
                "The selected file does not contain any audio tracks");
            return;
        }

        if (probe_cancellable == cancel)
            probe_cancellable = null;
        if (result.duration_seconds > 0.0) {
            loaded_duration = result.duration_seconds;
        }

        has_audio = true;
        selected_stream_index = 0;
        primary_audio_source = AudioSourceLogic.from_stream_info (all_audio_streams[0]);
        emit_source_audio_probe (
            MediaStreamPresence.PRESENT,
            primary_audio_source.codec_name,
            primary_audio_source.channels,
            primary_audio_source.sample_fmt,
            primary_audio_source.bits_per_raw_sample
        );

        // Update icon based on channel count
        stream_icon.set_from_icon_name (icon_for_channels (all_audio_streams[0].channels));

        if (all_audio_streams.length > 1) {
            // Multi-stream: show dropdown selector
            stream_info_row.set_title ("Audio Stream");
            stream_info_row.set_subtitle ("");

            // Remove old dropdown if present
            if (stream_dropdown != null) {
                stream_dropdown.unparent ();
                stream_dropdown = null;
            }

            // Build dropdown model from stream labels
            var labels = new string[all_audio_streams.length];
            for (int i = 0; i < all_audio_streams.length; i++) {
                labels[i] = all_audio_streams[i].display_label ();
            }
            stream_dropdown = new DropDown (
                CodecUtils.build_dropdown_string_list (labels), null);
            stream_dropdown.set_selected (0);
            stream_dropdown.set_valign (Align.CENTER);
            stream_info_row.add_suffix (stream_dropdown);

            stream_dropdown.notify["selected"].connect (() => on_stream_selected ());

            // Show stream count badge
            stream_count_badge.set_text ("%d tracks".printf (all_audio_streams.length));
            stream_count_badge.set_visible (true);

            info_group.set_description (null);
        } else {
            // Single stream: static display
            stream_info_row.set_title ("Audio Stream");
            stream_info_row.set_subtitle (all_audio_streams[0].display_label ());

            if (stream_dropdown != null) {
                stream_dropdown.unparent ();
                stream_dropdown = null;
            }

            stream_count_badge.set_visible (false);
            info_group.set_description (null);
        }

        // Update Extract All summary
        if (extract_all_summary_row != null) {
            extract_all_summary_row.set_title ("%d Audio Track%s".printf (
                all_audio_streams.length,
                all_audio_streams.length == 1 ? "" : "s"));
        }

        show_audio_found ();
        player.load_file (input_file, selected_stream_index);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SNAPSHOT — Capture UI state for background work
    // ═════════════════════════════════════════════════════════════════════════

    private AudioExtractConfig snapshot_config () {
        bool copy_mode = copy_mode_row.get_active ();
        AudioSettingsSnapshot? audio_settings_snapshot = null;
        AudioProcessingSettingsSnapshot processing_snapshot = new AudioProcessingSettingsSnapshot ();
        if (!copy_mode) {
            audio_settings_snapshot = audio_settings.snapshot_settings ();
            audio_settings_snapshot.source = primary_audio_source.copy ();
            processing_snapshot = audio_processing_settings.snapshot_settings ();
        }

        AudioExtractConfig config = AudioExtractLogic.build_snapshot_config (
            copy_mode,
            segments.length,
            export_separate_row.get_active (),
            primary_audio_source.stream_index,
            primary_audio_source.channels,
            audio_settings_snapshot,
            processing_snapshot,
            metadata_row_switch.get_active ()
        );

        config.source_audio = primary_audio_source.copy ();
        return config;
    }

    private void emit_source_audio_probe (MediaStreamPresence presence,
                                          string codec_name = "",
                                          int channels = 0,
                                          string sample_fmt = "",
                                          int bits_per_raw_sample = 0) {
        var result = new AudioStreamProbeResult ();
        result.presence = presence;
        result.codec_name = codec_name;
        result.channels = channels;
        result.sample_fmt = sample_fmt;
        result.bits_per_raw_sample = bits_per_raw_sample;
        source_audio_probe_updated (result);
    }
    // ═════════════════════════════════════════════════════════════════════════
    //  OPERATION TRACKING
    // ═════════════════════════════════════════════════════════════════════════

    private bool has_pending_or_active_extract () {
        return active_operation_id != 0 || active_runner != null;
    }

    /**
     * Atomically wire up a runner and its operation ID.
     * Both fields are set together so has_pending_or_active_extract()
     * can never see an orphaned operation_id without a runner.
     */
    private void activate_runner (AudioRunner runner_inst, uint64 operation_id) {
        active_runner = runner_inst;
        active_operation_id = operation_id;
        cancel_pending = false;
        var binding = new RunnerBinding ();
        binding.owner = this;
        binding.runner_inst = runner_inst;
        binding.operation_id = operation_id;
        active_runner_binding = binding;

        runner_inst.extract_done.connect (binding.on_extract_done);
        runner_inst.extract_failed.connect (binding.on_extract_failed);
    }

    private void complete_active_operation (uint64 operation_id,
                                            bool was_cancelled,
                                            OperationOutputResult? output_result = null) {
        active_runner = null;
        active_runner_binding = null;
        active_operation_id = 0;
        cancel_pending = false;

        if (was_cancelled) {
            audio_extract_cancelled (operation_id);
            return;
        }

        if (output_result != null) {
            audio_extract_succeeded (operation_id, output_result);
            return;
        }

        audio_extract_failed (operation_id);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  STREAM SELECTION
    // ═════════════════════════════════════════════════════════════════════════

    private void on_stream_selected () {
        if (stream_dropdown == null || all_audio_streams.length == 0) return;

        int idx = (int) stream_dropdown.get_selected ();
        if (idx < 0 || idx >= all_audio_streams.length) return;
        if (idx == selected_stream_index) return;

        selected_stream_index = idx;
        var info = all_audio_streams[idx];

        // Update primary audio source
        primary_audio_source = AudioSourceLogic.from_stream_info (info);

        // Update icon for channel count
        stream_icon.set_from_icon_name (icon_for_channels (info.channels));

        // Re-emit probe update so codec tabs update
        emit_source_audio_probe (
            MediaStreamPresence.PRESENT,
            primary_audio_source.codec_name,
            primary_audio_source.channels,
            primary_audio_source.sample_fmt,
            primary_audio_source.bits_per_raw_sample
        );

        // Reset all options to defaults
        reset_segments ();
        copy_mode_row.set_active (true);
        metadata_row_switch.set_active (false);
        export_separate_row.set_active (false);
        audio_settings.reset_defaults ();
        audio_processing_settings.reset_defaults ();
        update_mode_visibility ();

        // Reload waveform player with new stream
        player.load_file (current_input_file, selected_stream_index);
    }

    private static string icon_for_channels (int channels) {
        if (channels <= 1) return "audio-input-microphone-symbolic";
        if (channels <= 2) return "audio-x-generic-symbolic";
        return "audio-speakers-symbolic";
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    private uint flash_timeout_id = 0;

    private void flash_invalid_marks () {
        mark_in_label.add_css_class ("error");
        mark_out_label.add_css_class ("error");
        add_seg_row.set_subtitle ("Mark In must be before Mark Out");
        add_seg_row.add_css_class ("error");

        if (flash_timeout_id != 0)
            Source.remove (flash_timeout_id);

        flash_timeout_id = Timeout.add (3000, () => {
            mark_in_label.remove_css_class ("error");
            mark_out_label.remove_css_class ("error");
            add_seg_row.set_subtitle ("Uses the Mark In / Mark Out points above");
            add_seg_row.remove_css_class ("error");
            flash_timeout_id = 0;
            return Source.REMOVE;
        });
    }

    internal void validate_segment_start_entry (Entry entry, int idx) {
        if (idx < 0 || idx >= segments.length) return;

        double parsed = 0.0;
        bool valid_parse = VideoPlayer.try_parse_time (entry.get_text (), out parsed);
        validate_segment_time (entry, valid_parse, parsed, segments[idx].end_time, true);
    }

    internal void activate_segment_start_entry (Entry entry, int idx) {
        if (idx < 0 || idx >= segments.length) return;

        double new_val = 0.0;
        bool valid_parse = VideoPlayer.try_parse_time (entry.get_text (), out new_val);
        bool valid = validate_segment_time (
            entry, valid_parse, new_val, segments[idx].end_time, true);
        if (!valid) return;

        segments[idx].start_time = new_val;
        rebuild_segment_list ();
        update_waveform_highlights ();
    }

    internal void validate_segment_end_entry (Entry entry, int idx) {
        if (idx < 0 || idx >= segments.length) return;

        double parsed = 0.0;
        bool valid_parse = VideoPlayer.try_parse_time (entry.get_text (), out parsed);
        validate_segment_time (entry, valid_parse, parsed, segments[idx].start_time, false);
    }

    internal void activate_segment_end_entry (Entry entry, int idx) {
        if (idx < 0 || idx >= segments.length) return;

        double new_val = 0.0;
        bool valid_parse = VideoPlayer.try_parse_time (entry.get_text (), out new_val);
        bool valid = validate_segment_time (
            entry, valid_parse, new_val, segments[idx].start_time, false);
        if (!valid) return;

        segments[idx].end_time = new_val;
        rebuild_segment_list ();
        update_waveform_highlights ();
    }

    internal void seek_to_segment_start (int idx) {
        if (idx < 0 || idx >= segments.length) return;
        player.seek_to (segments[idx].start_time);
    }

    internal void move_segment_up (int idx) {
        move_segment (idx, idx - 1);
    }

    internal void move_segment_down (int idx) {
        move_segment (idx, idx + 1);
    }

    internal void delete_segment (int idx) {
        remove_segment (idx);
    }

    internal void handle_runner_extract_done (AudioRunner runner_inst,
                                              uint64 operation_id,
                                              OperationOutputResult output_result) {
        if (active_runner != runner_inst || active_operation_id != operation_id)
            return;
        complete_active_operation (operation_id, false, output_result);
    }

    internal void handle_runner_extract_failed (AudioRunner runner_inst,
                                                uint64 operation_id) {
        if (active_runner != runner_inst || active_operation_id != operation_id)
            return;
        complete_active_operation (operation_id, cancel_pending || runner_inst.is_cancelled ());
    }

    private static Image make_icon (string icon_name) {
        var img = new Image.from_icon_name (icon_name);
        img.set_valign (Align.CENTER);
        return img;
    }
}
