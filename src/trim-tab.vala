using Gtk;
using Adw;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  TrimSegment — Data object for a start/end time range + optional crop
// ═══════════════════════════════════════════════════════════════════════════════

public class TrimSegment : Object {
    public double start_time  { get; set; }
    public double end_time    { get; set; }
    public string crop_value  { get; set; default = ""; }
    public string label       { get; set; default = ""; }   // optional display name (used for chapter filenames)

    public TrimSegment (double start, double end) {
        this.start_time = start;
        this.end_time   = end;
    }

    public double get_duration () {
        return (end_time - start_time).clamp (0.0, double.MAX);
    }

    public bool has_crop () {
        return crop_value != null && crop_value.strip ().length > 0;
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SegmentCodecArgs — Wrapper for per-segment FFmpeg video codec arguments
//
//  Vala does not support arrays as generic type arguments, so this thin
//  wrapper allows GenericArray<SegmentCodecArgs> to carry string[] payloads.
// ═══════════════════════════════════════════════════════════════════════════════

public class SegmentCodecArgs : Object {
    public string[] args;

    public SegmentCodecArgs (owned string[] args) {
        this.args = (owned) args;
    }

    public bool is_empty () {
        return args == null || args.length == 0;
    }
}

public enum TrimOutputConflictPolicy {
    OVERWRITE,
    AUTO_RENAME
}

// ═══════════════════════════════════════════════════════════════════════════════
//  TrimTab — Video trimming, cropping, chapter splitting, and segment management
//
//  Modes:
//    • Trim Only     — cut segments (original behaviour)
//    • Crop Only     — crop the entire video with interactive overlay
//    • Crop & Trim   — segments with optional per-segment or global crop
//    • Chapter Split — detect embedded chapters and export them individually
//                      or concatenate selected chapters into one file
//
//  The crop rectangle is drawn interactively on the video player and maps
//  directly to FFmpeg's  crop=W:H:X:Y  filter.
// ═══════════════════════════════════════════════════════════════════════════════

public class TrimTab : Box, ICodecTab {

    // ── Mode ─────────────────────────────────────────────────────────────────
    public enum Mode { TRIM_ONLY, CROP_ONLY, TRIM_AND_CROP, CHAPTER_SPLIT }
    private Mode current_mode = Mode.TRIM_ONLY;
    private DropDown mode_dropdown;

    // ── Video Player ─────────────────────────────────────────────────────────
    private VideoPlayer player;

    // ── Mark In / Out state ──────────────────────────────────────────────────
    private double mark_in  = 0.0;
    private double mark_out = 0.0;
    private Label mark_in_label;
    private Label mark_out_label;

    // ── Segment list ─────────────────────────────────────────────────────────
    private GenericArray<TrimSegment> segments = new GenericArray<TrimSegment> ();
    private Adw.PreferencesGroup segments_group;
    private Gtk.ListBox segment_listbox;
    private Label segment_count_label;

    // ── Crop Controls ────────────────────────────────────────────────────────
    private Adw.PreferencesGroup crop_group;
    private Entry crop_value_display;
    private Switch crop_scope_switch;        // ON = per-segment, OFF = global
    private Adw.ActionRow crop_scope_row;
    private Button crop_reset_btn;
    private Button crop_apply_all_btn;
    private string global_crop_value = "";   // stored global crop

    // ── Output mode ──────────────────────────────────────────────────────────
    private Switch copy_mode_switch;
    private Switch keyframe_cut_switch;
    private Adw.ActionRow keyframe_cut_row;
    private Adw.ActionRow reencode_codec_row;
    private DropDown codec_choice;
    private Switch export_separate_switch;

    // ── Smart Optimizer (per-segment) ──────────────────────────────────────
    private Switch smart_optimize_switch;
    private Adw.ActionRow smart_optimize_row;
    private SmartOptimizer? smart_optimizer = null;
    private Cancellable? smart_cancel = null;

    // ── Sections (for visibility toggling) ───────────────────────────────────
    private Adw.PreferencesGroup mark_group;
    private Adw.PreferencesGroup output_group;

    // ── Chapter Split ──────────────────────────────────────────────────────
    private Adw.PreferencesGroup chapter_list_group;
    private Gtk.ListBox chapter_listbox;
    private Button chapter_select_all_btn;
    private Button chapter_select_none_btn;
    private GenericArray<ChapterInfo> detected_chapters = new GenericArray<ChapterInfo> ();
    private string loaded_video_path = "";     // currently loaded video file
    private uint chapter_scan_generation = 0;
    private Cancellable? chapter_scan_cancellable = null;

    // ── External references (set by MainWindow) ──────────────────────────────
    private GeneralTab? _general_tab = null;
    public GeneralTab? general_tab {
        get { return _general_tab; }
        set {
            _general_tab = value;
            // NOTE: We intentionally do NOT call notify_trim_tab_mode here.
            // Locking only activates when the Crop & Trim tab is actually in
            // focus.  AppController.wire_trim_tab_focus() owns that logic and
            // fires on every ViewStack page change, including the initial state.
        }
    }
    public SvtAv1Tab?  svt_tab      { get; set; default = null; }
    public X265Tab?    x265_tab     { get; set; default = null; }
    public X264Tab?    x264_tab     { get; set; default = null; }
    public Vp9Tab?     vp9_tab      { get; set; default = null; }

    // ── Trim runner ──────────────────────────────────────────────────────────
    private TrimRunner? active_runner = null;
    private uint64 active_operation_id = 0;
    private bool cancel_pending = false;
    private bool speed_locked = false;  // true when speed filters force re-encode

    // ── Signals ──────────────────────────────────────────────────────────────
    public signal void trim_done (OperationOutputResult output_result);
    public signal void trim_succeeded (uint64 operation_id, OperationOutputResult output_result);
    public signal void trim_failed (uint64 operation_id);
    public signal void trim_cancelled (uint64 operation_id);

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public TrimTab () {
        Object (orientation: Orientation.VERTICAL, spacing: 24);
        set_margin_top (24);
        set_margin_bottom (24);
        set_margin_start (24);
        set_margin_end (24);

        inject_segment_css ();

        build_mode_selector ();
        build_player_section ();
        build_crop_controls ();
        build_mark_controls ();
        build_chapter_list_section ();
        build_segment_list ();
        build_output_settings ();

        // Apply initial mode visibility
        apply_mode (Mode.TRIM_ONLY);
    }

    public override void dispose () {
        cancel_chapter_scan ();
        base.dispose ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ICodecTab INTERFACE
    // ═════════════════════════════════════════════════════════════════════════

    public ICodecBuilder get_codec_builder () {
        if (copy_mode_switch.active) {
            return new TrimBuilder ();
        }
        int sel = (int) codec_choice.get_selected ();
        if (sel == 0 && svt_tab != null)  return svt_tab.get_codec_builder ();
        if (sel == 1 && x265_tab != null) return x265_tab.get_codec_builder ();
        if (sel == 2 && x264_tab != null) return x264_tab.get_codec_builder ();
        if (sel == 3 && vp9_tab != null)  return vp9_tab.get_codec_builder ();
        return new TrimBuilder ();
    }

    public bool get_two_pass () { return false; }
    public string get_container () { return "mkv"; }
    public CodecTabSettingsSnapshot snapshot_settings (
        GeneralSettingsSnapshot? general_settings = null) {
        var snapshot = new CodecTabSettingsSnapshot ();
        snapshot.container = "mkv";
        snapshot.keyframe_settings = snapshot_keyframe_settings (general_settings);
        snapshot.audio_settings = new AudioSettingsSnapshot ();
        return snapshot;
    }
    public KeyframeSettingsSnapshot snapshot_keyframe_settings (
        GeneralSettingsSnapshot? general_settings) {
        return new KeyframeSettingsSnapshot ();
    }
    public string[] get_audio_args () { return { "-c:a", "copy" }; }

    /** Returns the current operation mode as an int (0=Trim Only, 1=Crop Only, 2=Crop & Trim). */
    public int get_current_mode () { return (int) current_mode; }

    /** True when the current export settings will re-encode through any codec. */
    public bool will_reencode_output () {
        if (current_mode == Mode.CHAPTER_SPLIT)
            return !copy_mode_switch.active;

        if (current_mode == Mode.CROP_ONLY)
            return global_crop_value.strip ().length > 0;

        if (!copy_mode_switch.active)
            return true;

        if (current_mode == Mode.TRIM_AND_CROP
            && !crop_scope_switch.active
            && global_crop_value.strip ().length > 0) {
            return true;
        }

        for (int i = 0; i < segments.length; i++) {
            if (segments[i].has_crop ())
                return true;
        }

        return false;
    }

    /** True when the current export settings will re-encode through SVT-AV1. */
    public bool will_use_svt_av1_reencode () {
        if ((int) codec_choice.get_selected () != 0)
            return false;

        return will_reencode_output ();
    }

    public BaseCodecTab? get_selected_reencode_codec_tab () {
        if (!reencode_codec_row.get_visible ())
            return null;

        switch ((int) codec_choice.get_selected ()) {
            case 0:  return svt_tab;
            case 1:  return x265_tab;
            case 2:  return x264_tab;
            case 3:  return vp9_tab;
            default: return null;
        }
    }

    public bool selected_reencode_audio_probe_pending () {
        BaseCodecTab? codec_tab = get_selected_reencode_codec_tab ();
        return codec_tab != null && codec_tab.audio_settings.is_audio_probe_pending ();
    }

    public void load_video (string path) {
        cancel_chapter_scan ();
        loaded_video_path = path;

        // Clear any stale crop from the previous video
        player.crop_overlay.clear_crop ();
        global_crop_value = "";
        update_crop_display ("", 0, 0, 0, 0);

        // Clear any stale trim/chapter state from the previous video
        reset_trim_state ();

        if (path.length == 0) {
            player.clear ();
            return;
        }

        player.load_file (path);

        // Auto-scan for chapters in the background
        scan_chapters_async (path);
    }

    /**
     * Launch the trim/crop/export pipeline.
     */
    public bool start_trim_export (string input_file,
                                   string output_folder,
                                   StatusArea status_area,
                                   ConsoleTab console_tab,
                                   uint64 operation_id,
                                   TrimOutputConflictPolicy output_policy = TrimOutputConflictPolicy.OVERWRITE) {
        ProgressBar progress_bar = status_area.progress_bar;

        if (has_pending_or_active_export ()) {
            status_area.set_status ("⚠️ An export is already running or being prepared.");
            return false;
        }

        if (will_reencode_output () && selected_reencode_audio_probe_pending ()) {
            status_area.set_status (
                "⏳ Checking source audio stream. Please wait a moment and try again.");
            return false;
        }

        // For Chapter Split mode, build segments from selected chapters
        if (current_mode == Mode.CHAPTER_SPLIT) {
            if (input_file == null || input_file.strip () == "") {
                status_area.set_status ("⚠️ Please select an input file first.");
                return false;
            }
            // Build segments from selected chapters
            rebuild_chapter_segments ();
            if (segments.length == 0) {
                status_area.set_status ("⚠️ No chapters selected — select at least one chapter to export.");
                return false;
            }

            var segs = new GenericArray<TrimSegment> ();
            for (int i = 0; i < segments.length; i++) {
                segs.add (segments[i]);
            }

            active_operation_id = operation_id;
            cancel_pending = false;
            maybe_smart_optimize_then_launch (input_file, output_folder, status_area,
                           progress_bar, console_tab, segs, false, operation_id,
                           output_policy);
            return true;
        }

        // For Crop Only mode, create a virtual full-video segment
        if (current_mode == Mode.CROP_ONLY) {
            if (input_file == null || input_file.strip () == "") {
                status_area.set_status ("⚠️ Please select an input file first.");
                return false;
            }
            if (global_crop_value.strip () == "") {
                status_area.set_status ("⚠️ Draw a crop rectangle on the video first.");
                return false;
            }
            // Create one segment spanning the whole file
            var full_seg = new TrimSegment (0, player.get_duration_seconds ());
            full_seg.crop_value = global_crop_value;

            var segs = new GenericArray<TrimSegment> ();
            segs.add (full_seg);

            active_operation_id = operation_id;
            cancel_pending = false;
            maybe_smart_optimize_then_launch (input_file, output_folder, status_area,
                           progress_bar, console_tab, segs, true, operation_id,
                           output_policy);
            return true;
        }

        // Trim Only or Crop & Trim
        if (input_file == null || input_file.strip () == "") {
            status_area.set_status ("⚠️ Please select an input file first.");
            return false;
        }
        if (segments.length == 0) {
            status_area.set_status ("⚠️ Add at least one segment before exporting.");
            return false;
        }

        var segs = new GenericArray<TrimSegment> ();

        // If global crop and Crop & Trim mode, clone segments that need the
        // global crop stamped so the original segments stay clean for re-export
        bool stamp_global_crop = current_mode == Mode.TRIM_AND_CROP
            && !crop_scope_switch.active
            && global_crop_value.strip ().length > 0;

        for (int i = 0; i < segments.length; i++) {
            if (stamp_global_crop && !segments[i].has_crop ()) {
                var clone = new TrimSegment (segments[i].start_time, segments[i].end_time);
                clone.label = segments[i].label;
                clone.crop_value = global_crop_value;
                segs.add (clone);
            } else {
                segs.add (segments[i]);
            }
        }

        // Determine if any segment has a crop (forces re-encode)
        bool any_crop = false;
        for (int i = 0; i < segs.length; i++) {
            if (segs[i].has_crop ()) { any_crop = true; break; }
        }

        active_operation_id = operation_id;
        cancel_pending = false;
        maybe_smart_optimize_then_launch (input_file, output_folder, status_area,
                       progress_bar, console_tab, segs, any_crop, operation_id,
                       output_policy);
        return true;
    }

    private void launch_runner (string input_file,
                                string output_folder,
                                StatusArea status_area,
                                ProgressBar progress_bar,
                                ConsoleTab console_tab,
                                GenericArray<TrimSegment> segs,
                                bool force_reencode,
                                uint64 operation_id,
                                TrimOutputConflictPolicy output_policy,
                                GenericArray<SegmentCodecArgs>? smart_codec_args = null,
                                GeneralSettingsSnapshot? snapped_general_settings = null) {

        var runner = new TrimRunner ();
        runner.input_file      = input_file;
        runner.output_folder   = output_folder;
        // When exporting separate files, each segment can independently
        // decide copy vs re-encode, so don't globally force re-encode
        bool global_force = force_reencode && !export_separate_switch.active;
        runner.copy_mode       = copy_mode_switch.active && !global_force;
        runner.keyframe_cut    = keyframe_cut_switch.active;
        runner.export_separate = export_separate_switch.active;
        runner.video_width     = player.intrinsic_width;
        runner.video_height    = player.intrinsic_height;
        runner.status_area     = status_area;
        runner.progress_bar    = progress_bar;
        runner.console_tab     = console_tab;

        GenericArray<string>? resolved_outputs = resolve_output_paths (
            input_file, output_folder, segs, output_policy);
        if (resolved_outputs == null) {
            status_area.set_status ("Could not derive unique output path(s).");
            fail_operation (operation_id);
            return;
        }
        if (resolved_outputs.length > 0) {
            runner.primary_output_path = resolved_outputs[0];
        }
        if (export_separate_switch.active) {
            runner.set_separate_output_paths (resolved_outputs);
        }

        // Set output suffix and status label based on mode
        if (current_mode == Mode.CHAPTER_SPLIT) {
            runner.output_suffix   = "-chapter";
            runner.operation_label = "Chapter split";
        } else if (current_mode == Mode.CROP_ONLY) {
            runner.output_suffix   = "-cropped";
            runner.operation_label = "Crop";
        } else if (current_mode == Mode.TRIM_AND_CROP) {
            runner.output_suffix   = "-cropped-trimmed";
            runner.operation_label = "Crop & Trim export";
        } else {
            runner.output_suffix   = "-trimmed";
            runner.operation_label = "Trim export";
        }

        // Snapshot re-encode settings on the main thread when some path
        // needs encoding. The runner only consumes plain data objects.
        if (!runner.copy_mode || force_reencode) {
            int sel = (int) codec_choice.get_selected ();
            ICodecBuilder? builder = null;
            ICodecTab? codec_tab = null;
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
            }

            if (builder != null && codec_tab != null) {
                PixelFormatSettingsSnapshot? pixel_format =
                    (codec_tab is BaseCodecTab)
                    ? ((BaseCodecTab) codec_tab).snapshot_pixel_format_settings ()
                    : null;
                GeneralSettingsSnapshot general_settings = (snapped_general_settings != null)
                    ? snapped_general_settings
                    : general_tab.snapshot_settings (pixel_format);
                runner.reencode_profile = CodecUtils.snapshot_encode_profile (
                    builder, codec_tab, general_settings);
            }
        }

        // Per-segment Smart Optimizer codec overrides
        if (smart_codec_args != null) {
            runner.set_per_segment_codec_args (smart_codec_args);
        }

        runner.set_segments (segs);

        runner.export_done.connect ((output_result) => {
            if (active_runner != runner || active_operation_id != operation_id) {
                return;
            }

            complete_active_operation (operation_id, false, output_result);
        });
        runner.export_failed.connect ((msg) => {
            if (active_runner != runner || active_operation_id != operation_id) {
                return;
            }

            complete_active_operation (operation_id, cancel_pending || runner.is_cancelled ());
        });

        active_runner = runner;
        runner.run ();
    }

    public void cancel_trim () {
        if (active_operation_id == 0) {
            return;
        }

        cancel_pending = true;

        // Cancel any in-flight Smart Optimizer analysis
        if (smart_cancel != null) {
            smart_cancel.cancel ();
        }
        if (active_runner != null) {
            active_runner.cancel ();
        }
    }

    private bool has_pending_or_active_export () {
        return active_operation_id != 0 || active_runner != null || smart_cancel != null;
    }

    public bool is_exporting () {
        return has_pending_or_active_export ();
    }

    /**
     * Check if Smart Optimizer should be used and route accordingly.
     * If Smart Optimizer is active, runs async per-segment analysis first
     * then launches the runner. Otherwise launches immediately.
     */
    private void maybe_smart_optimize_then_launch (string input_file,
                                                    string output_folder,
                                                    StatusArea status_area,
                                                    ProgressBar progress_bar,
                                                    ConsoleTab console_tab,
                                                    GenericArray<TrimSegment> segs,
                                                    bool force_reencode,
                                                    uint64 operation_id,
                                                    TrimOutputConflictPolicy output_policy) {
        if (smart_optimize_switch.active
            && !copy_mode_switch.active
            && export_separate_switch.active) {
            run_smart_then_export.begin (
                input_file, output_folder, status_area, progress_bar,
                console_tab, segs, force_reencode, operation_id,
                output_policy);
        } else {
            launch_runner (input_file, output_folder, status_area,
                           progress_bar, console_tab, segs, force_reencode,
                           operation_id, output_policy);
        }
    }

    /**
     * Per-segment Smart Optimizer pipeline.
     *
     * For each segment:
     *  1. Stream-copy to a temp file (fast, gives the optimizer a standalone
     *     file with the segment's actual content)
     *  2. Run SmartOptimizer on the temp file
     *  3. Build FFmpeg codec args from the recommendation
     *  4. Clean up temp file
     *
     * Segments where optimization fails or the target is impossible are
     * dropped entirely — the user opted into Smart Optimizer because they
     * need the target file size, so giving them unoptimized output would
     * be worse than skipping.
     *
     * When all surviving segments are analyzed, launches TrimRunner with
     * per-segment codec overrides.
     */
    private async void run_smart_then_export (string input_file,
                                               string output_folder,
                                               StatusArea status_area,
                                               ProgressBar progress_bar,
                                               ConsoleTab console_tab,
                                               GenericArray<TrimSegment> segs,
                                               bool force_reencode,
                                               uint64 operation_id,
                                               TrimOutputConflictPolicy output_policy) {
        if (smart_optimizer == null) {
            smart_optimizer = new SmartOptimizer ();
        }

        // Cancel any previous optimization
        if (smart_cancel != null) {
            smart_cancel.cancel ();
        }
        smart_cancel = new Cancellable ();
        var cancel = smart_cancel;

        int target_mb  = AppSettings.get_default ().smart_optimizer_target_mb;
        int codec_sel  = (int) codec_choice.get_selected ();
        string preferred_codec;
        switch (codec_sel) {
            case 0:  preferred_codec = "svt-av1"; break;
            case 1:  preferred_codec = "x265";    break;
            case 3:  preferred_codec = "vp9";     break;
            default: preferred_codec = "x264";    break;
        }

        GeneralSettingsSnapshot? general_settings_snapshot = null;
        string shared_video_filter_chain = "";
        BaseCodecTab? selected_codec_tab = null;
        if (general_tab != null) {
            selected_codec_tab = get_selected_reencode_codec_tab ();
            PixelFormatSettingsSnapshot? pixel_format = (selected_codec_tab != null)
                ? selected_codec_tab.snapshot_pixel_format_settings ()
                : null;
            general_settings_snapshot = general_tab.snapshot_settings (pixel_format);
            shared_video_filter_chain = FilterBuilder.build_video_filter_chain_from_snapshot (
                general_settings_snapshot, false, preferred_codec);
        }

        // Parallel arrays — only segments that pass optimization are kept
        var ok_segs = new GenericArray<TrimSegment> ();
        var ok_args = new GenericArray<SegmentCodecArgs> ();
        var skipped = new GenericArray<string> ();   // names of dropped segments

        // Create temp directory for segment analysis files
        string tmp_dir;
        try {
            tmp_dir = DirUtils.make_tmp ("smart-opt-XXXXXX");
        } catch (Error e) {
            status_area.set_status ("❌ Failed to create temp directory: " + e.message);
            release_smart_cancel (cancel);
            fail_operation (operation_id);
            return;
        }

        bool cancelled = false;

        for (int i = 0; i < segs.length; i++) {
            if (cancel.is_cancelled ()) {
                status_area.set_status ("⏹️ Smart Optimizer cancelled.");
                cancelled = true;
                break;
            }

            var seg = segs[i];
            string seg_name = (seg.label != null && seg.label.strip ().length > 0)
                ? "\"%s\"".printf (seg.label)
                : "Segment %d".printf (i + 1);

            status_area.set_status ("🧠 Smart Optimizer: analyzing %s (%d/%d)…".printf (
                seg_name, i + 1, segs.length));

            // ── 1. Stream-copy segment to temp file ────────────────────────
            string tmp_seg = Path.build_filename (tmp_dir, "seg_%d.mkv".printf (i));
            int copy_exit = -1;

            try {
                string[] copy_cmd = {
                    AppSettings.get_default ().ffmpeg_path, "-y",
                    "-ss", ConversionUtils.format_ffmpeg_double (seg.start_time, "%.6f"),
                    "-t",  ConversionUtils.format_ffmpeg_double (seg.get_duration (), "%.6f"),
                    "-i",  input_file,
                    "-c",  "copy",
                    "-map_chapters", "-1",
                    tmp_seg
                };
                string stdout_buf, stderr_buf;
                Process.spawn_sync (null, copy_cmd, null,
                                    SpawnFlags.SEARCH_PATH,
                                    null, out stdout_buf, out stderr_buf, out copy_exit);
            } catch (Error e) {
                console_tab.add_line ("[Smart Optimizer] ⏭️ Skipping %s — temp extract failed: %s"
                    .printf (seg_name, e.message));
                skipped.add (seg_name);
                continue;
            }

            if (copy_exit != 0) {
                console_tab.add_line ("[Smart Optimizer] ⏭️ Skipping %s — temp extract failed (exit %d)"
                    .printf (seg_name, copy_exit));
                skipped.add (seg_name);
                continue;
            }

            // ── 2. Run SmartOptimizer on the temp file ─────────────────────
            var ctx = OptimizationContext ();
            if (shared_video_filter_chain.length > 0) {
                ctx.video_filter_chain = shared_video_filter_chain;
            }
            if (selected_codec_tab != null
                && !selected_codec_tab.audio_settings.is_audio_enabled_for_output ()) {
                ctx.strip_audio = true;
            }
            // Audio budget is determined by the optimizer based on size tier.

            try {
                var rec = yield smart_optimizer.optimize_for_target_size (
                    tmp_seg, target_mb, preferred_codec, ctx, cancel);

                if (rec.is_impossible) {
                    console_tab.add_line ("[Smart Optimizer] ⏭️ Skipping %s — target %d MB is unreachable"
                        .printf (seg_name, target_mb));
                    string fail_details = SmartOptimizer.format_recommendation (rec);
                    foreach (unowned string line in fail_details.split ("\n")) {
                        console_tab.add_line ("[Smart Optimizer]   " + line);
                    }
                    skipped.add (seg_name);
                } else {
                    // ── 3. Build codec args from recommendation ────────────
                    string[] smart_args = CodecUtils.build_smart_codec_args (
                        rec, general_settings_snapshot);
                    ok_segs.add (seg);
                    ok_args.add (new SegmentCodecArgs (smart_args));

                    console_tab.add_line ("[Smart Optimizer] ✅ %s → CRF %d / %s (est. %d KiB, %s)"
                        .printf (seg_name, rec.crf, rec.preset,
                                 rec.estimated_size_kib,
                                 rec.content_type.to_label ()));

                    // Log full details to console (same as codec tab path)
                    string details = SmartOptimizer.format_recommendation (rec);
                    foreach (unowned string line in details.split ("\n")) {
                        console_tab.add_line ("[Smart Optimizer]   " + line);
                    }
                }

            } catch (IOError e) {
                if (e is IOError.CANCELLED) {
                    status_area.set_status ("⏹️ Smart Optimizer cancelled.");
                    cancelled = true;
                    FileUtils.unlink (tmp_seg);
                    break;
                }
                console_tab.add_line ("[Smart Optimizer] ⏭️ Skipping %s — error: %s"
                    .printf (seg_name, e.message));
                skipped.add (seg_name);
            } catch (Error e) {
                console_tab.add_line ("[Smart Optimizer] ⏭️ Skipping %s — error: %s"
                    .printf (seg_name, e.message));
                skipped.add (seg_name);
            }

            // ── 4. Clean up temp file ──────────────────────────────────────
            FileUtils.unlink (tmp_seg);
        }

        // Clean up temp directory
        DirUtils.remove (tmp_dir);
        release_smart_cancel (cancel);

        if (!can_continue_active_operation (operation_id)) {
            fail_operation (operation_id);
            return;
        }

        if (cancelled) {
            fail_operation (operation_id);
            return;
        }

        // ── Report skipped segments ─────────────────────────────────────────
        if (skipped.length > 0) {
            var sb = new StringBuilder ();
            for (int i = 0; i < skipped.length; i++) {
                if (i > 0) sb.append (", ");
                sb.append (skipped[i]);
            }
            console_tab.add_line ("[Smart Optimizer] Skipped %d segment%s: %s"
                .printf (skipped.length,
                         skipped.length == 1 ? "" : "s",
                         sb.str));
        }

        // ── Check if anything survived ──────────────────────────────────────
        if (ok_segs.length == 0) {
            status_area.set_status ("⚠️ Smart Optimizer: all segments failed to meet the %d MB target — nothing to export."
                .printf (target_mb));
            fail_operation (operation_id);
            return;
        }

        // ── Launch TrimRunner with only the segments that passed ────────────
        if (skipped.length > 0) {
            status_area.set_status ("🧠 Analysis complete — exporting %d of %d segments (%d skipped)…"
                .printf (ok_segs.length, segs.length, skipped.length));
        } else {
            status_area.set_status ("🧠 Analysis complete — exporting %d segments…"
                .printf (ok_segs.length));
        }

        launch_runner (input_file, output_folder, status_area, progress_bar,
                       console_tab, ok_segs, force_reencode, operation_id,
                       output_policy,
                       ok_args, general_settings_snapshot);
    }

    private bool can_continue_active_operation (uint64 operation_id) {
        return active_operation_id == operation_id && !cancel_pending;
    }

    private void release_smart_cancel (Cancellable cancel) {
        if (smart_cancel == cancel) {
            smart_cancel = null;
        }
    }

    private void complete_active_operation (uint64 operation_id,
                                            bool was_cancelled,
                                            OperationOutputResult? output_result = null) {
        active_runner = null;
        active_operation_id = 0;
        cancel_pending = false;

        if (was_cancelled) {
            trim_cancelled (operation_id);
            return;
        }

        if (output_result != null) {
            trim_done (output_result);
            trim_succeeded (operation_id, output_result);
            return;
        }

        trim_failed (operation_id);
    }

    private void fail_operation (uint64 operation_id) {
        if (active_operation_id != operation_id) {
            return;
        }

        complete_active_operation (operation_id, cancel_pending);
    }

    private string get_output_extension (string input_file) {
        string basename = Path.get_basename (input_file);
        int dot = basename.last_index_of_char ('.');
        string input_ext = (dot > 0) ? basename.substring (dot) : ".mkv";

        if (copy_mode_switch.active) {
            return input_ext;
        }

        int sel = (int) codec_choice.get_selected ();
        ICodecTab? tab = null;
        if (sel == 0) tab = svt_tab;
        else if (sel == 1) tab = x265_tab;
        else if (sel == 2) tab = x264_tab;
        else if (sel == 3) tab = vp9_tab;

        if (tab != null) {
            string container = tab.get_container ();
            return (container.length > 0) ? "." + container : ".mkv";
        }

        return ".mkv";
    }

    private string get_output_suffix () {
        if (current_mode == Mode.CHAPTER_SPLIT) return "-chapter";
        if (current_mode == Mode.CROP_ONLY) return "-cropped";
        if (current_mode == Mode.TRIM_AND_CROP) return "-cropped-trimmed";
        return "-trimmed";
    }

    private string build_separate_output_name (string name_no_ext,
                                               string out_ext,
                                               TrimSegment? seg,
                                               int index,
                                               HashTable<string, bool> used_names) {
        if (current_mode == Mode.CHAPTER_SPLIT
            && seg != null
            && seg.label != null
            && seg.label.strip ().length > 0) {
            string safe = sanitize_filename (seg.label);
            string candidate = @"$name_no_ext-$safe";
            if (used_names.contains (candidate)) {
                int dup_count = 2;
                string deduped = @"$candidate ($dup_count)";
                while (used_names.contains (deduped)) {
                    dup_count++;
                    deduped = @"$candidate ($dup_count)";
                }
                candidate = deduped;
            }
            used_names.set (candidate, true);
            return @"$candidate$out_ext";
        }

        string num = pad_segment_number (index + 1);
        return @"$name_no_ext-segment-$num$out_ext";
    }

    private string? resolve_output_path_conflict (string path,
                                                  TrimOutputConflictPolicy output_policy,
                                                  HashTable<string, bool> reserved_paths) {
        string resolved = path;
        if (output_policy == TrimOutputConflictPolicy.AUTO_RENAME) {
            string? unique = ConversionUtils.find_unique_path_with_reserved (path, reserved_paths);
            if (unique == null || unique.length == 0)
                return null;
            resolved = unique;
        }

        reserved_paths.set (resolved, true);
        return resolved;
    }

    private GenericArray<string>? resolve_output_paths (string input_file,
                                                        string output_folder,
                                                        GenericArray<TrimSegment> segs,
                                                        TrimOutputConflictPolicy output_policy) {
        var resolved_paths = new GenericArray<string> ();

        string basename = Path.get_basename (input_file);
        int dot = basename.last_index_of_char ('.');
        string name_no_ext = (dot > 0) ? basename.substring (0, dot) : basename;
        string out_ext = get_output_extension (input_file);
        string out_dir = (output_folder != null && output_folder != "")
            ? output_folder
            : Path.get_dirname (input_file);

        var reserved_paths = new HashTable<string, bool> (str_hash, str_equal);

        if (export_separate_switch.active) {
            var used_names = new HashTable<string, bool> (str_hash, str_equal);
            int count = (current_mode == Mode.CROP_ONLY) ? 1 : segs.length;
            for (int i = 0; i < count; i++) {
                TrimSegment? seg = (i < segs.length) ? segs[i] : null;
                string seg_name = build_separate_output_name (
                    name_no_ext, out_ext, seg, i, used_names);
                string seg_path = Path.build_filename (out_dir, seg_name);
                string? resolved = resolve_output_path_conflict (
                    seg_path, output_policy, reserved_paths);
                if (resolved == null || resolved.length == 0)
                    return null;
                resolved_paths.add (resolved);
            }
            return resolved_paths;
        }

        string combined_path = Path.build_filename (
            out_dir, @"$name_no_ext$(get_output_suffix ())$out_ext");
        string? resolved = resolve_output_path_conflict (
            combined_path, output_policy, reserved_paths);
        if (resolved == null || resolved.length == 0)
            return null;
        resolved_paths.add (resolved);
        return resolved_paths;
    }

    /**
     * Compute the expected output path(s) for the overwrite check.
     * Returns the first path that already exists on disk, or "" if none exist.
     * Handles both combined output and export-separate modes.
     */
    public string get_expected_output_path (string input_file, string output_folder) {
        GenericArray<string>? expected_paths = resolve_output_paths (
            input_file,
            output_folder,
            segments,
            TrimOutputConflictPolicy.OVERWRITE
        );
        if (expected_paths == null)
            return "";

        for (int i = 0; i < expected_paths.length; i++) {
            if (FileUtils.test (expected_paths[i], FileTest.EXISTS)) {
                return expected_paths[i];
            }
        }

        return "";
    }

    private static string pad_segment_number (int n) {
        return ConversionUtils.pad_segment_number (n);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CSS — Segment time entry validation styles
    //
    //  Injected once for the entire app. Uses translucent borders that work
    //  well with both light and dark Adwaita themes.
    // ═════════════════════════════════════════════════════════════════════════

    private static bool segment_css_injected = false;

    private static void inject_segment_css () {
        if (segment_css_injected) return;
        segment_css_injected = true;

        var css = new CssProvider ();
        css.load_from_string (
            "entry.segment-valid {\n" +
            "    border-color: @success_color;\n" +
            "    box-shadow: 0 0 0 1px alpha(@success_color, 0.35);\n" +
            "    transition: border-color 150ms ease, box-shadow 150ms ease;\n" +
            "}\n" +
            "entry.segment-error {\n" +
            "    border-color: @error_color;\n" +
            "    box-shadow: 0 0 0 1px alpha(@error_color, 0.35);\n" +
            "    transition: border-color 150ms ease, box-shadow 150ms ease;\n" +
            "}\n"
        );
        StyleContext.add_provider_for_display (
            Gdk.Display.get_default (),
            css,
            STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SEGMENT TIME VALIDATION
    //
    //  Fix #6: Validate start/end time entries and show red/green borders.
    //
    //  Checks:
    //   • Value is non-negative
    //   • Start time < end time for the same segment
    //   • Value does not exceed video duration (when known)
    //
    //  Called on every keystroke (changed signal) for live feedback,
    //  and on Enter (activate signal) to gate whether the edit is committed.
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Validate a time entry and apply the appropriate CSS class.
     *
     * @param entry          The Entry widget to style
     * @param parsed_value   The parsed time in seconds
     * @param other_value    The other boundary of the segment (end if this is start, vice versa)
     * @param is_start       true if this entry is the start time, false for end time
     * @return               true if the value is valid
     */
    private bool validate_segment_time (Entry entry, double parsed_value,
                                        double other_value, bool is_start) {
        string? error_reason = null;

        // 1. Non-negative
        if (parsed_value < 0.0) {
            error_reason = "Time cannot be negative";
        }

        // 2. Start must be before end
        if (error_reason == null) {
            if (is_start && parsed_value >= other_value) {
                error_reason = "Start must be before end";
            } else if (!is_start && parsed_value <= other_value) {
                error_reason = "End must be after start";
            }
        }

        // 3. Within video duration (when known)
        if (error_reason == null) {
            double duration = player.get_duration_seconds ();
            if (duration > 0.0 && parsed_value > duration) {
                error_reason = "Exceeds video duration";
            }
        }

        // Apply visual feedback
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

    // ═════════════════════════════════════════════════════════════════════════
    //  UI — Mode Selector
    // ═════════════════════════════════════════════════════════════════════════

    private void build_mode_selector () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Mode");
        group.set_description ("Choose what you would like to do");

        var mode_row = new Adw.ActionRow ();
        mode_row.set_title ("Operation");
        mode_row.set_subtitle ("Select between trimming, cropping, or both");
        mode_row.set_icon_name ("applications-multimedia-symbolic");

        mode_dropdown = new DropDown (new StringList (
            { "✂️  Trim Only", "🔲  Crop Only", "🔲✂️  Crop & Trim", "📖  Chapter Split" }
        ), null);
        mode_dropdown.set_valign (Align.CENTER);
        mode_dropdown.set_selected (0);
        mode_dropdown.notify["selected"].connect (() => {
            int sel = (int) mode_dropdown.get_selected ();
            Mode m = (sel == 0) ? Mode.TRIM_ONLY :
                     (sel == 1) ? Mode.CROP_ONLY :
                     (sel == 2) ? Mode.TRIM_AND_CROP : Mode.CHAPTER_SPLIT;
            apply_mode (m);
        });
        mode_row.add_suffix (mode_dropdown);
        group.add (mode_row);

        append (group);
    }

    private void apply_mode (Mode m) {
        Mode previous_mode = current_mode;
        current_mode = m;

        // When leaving Chapter Split mode, clear the auto-generated segments
        // so they don't leak into Trim Only / Crop & Trim as stale entries.
        if (previous_mode == Mode.CHAPTER_SPLIT && m != Mode.CHAPTER_SPLIT) {
            segments = new GenericArray<TrimSegment> ();
            rebuild_segment_rows ();
        }

        bool show_crop = (m == Mode.CROP_ONLY || m == Mode.TRIM_AND_CROP);
        bool show_trim = (m == Mode.TRIM_ONLY || m == Mode.TRIM_AND_CROP);
        bool show_chapters = (m == Mode.CHAPTER_SPLIT);

        // Toggle crop overlay on the video player
        player.set_crop_active (show_crop);

        // Toggle section visibility
        crop_group.set_visible (show_crop);
        mark_group.set_visible (show_trim);
        segments_group.set_visible (show_trim || show_chapters);
        chapter_list_group.set_visible (show_chapters);

        // Crop scope row only makes sense in Crop & Trim mode
        crop_scope_row.set_visible (m == Mode.TRIM_AND_CROP);
        crop_apply_all_btn.set_visible (m == Mode.TRIM_AND_CROP);

        // Crop overlay only active in crop modes — player stays visible in all modes
        // so users can preview chapters, segments, etc.

        // In Crop Only mode, disable export-separate (doesn't apply)
        if (m == Mode.CROP_ONLY) {
            export_separate_switch.set_active (false);
        }
        // Chapter Split defaults to separate files, but user can turn it off
        // to concatenate selected chapters into a single file
        if (m == Mode.CHAPTER_SPLIT) {
            export_separate_switch.set_active (true);
            export_separate_switch.set_sensitive (true);
        } else {
            export_separate_switch.set_sensitive (show_trim);
        }

        // Crop always requires re-encode (both Crop Only and Crop & Trim)
        if (m == Mode.CROP_ONLY || m == Mode.TRIM_AND_CROP) {
            copy_mode_switch.set_active (false);
            copy_mode_switch.set_sensitive (false);
        } else if (m == Mode.CHAPTER_SPLIT) {
            // Chapter Split defaults to copy mode (lossless, fast)
            copy_mode_switch.set_active (true);
            copy_mode_switch.set_sensitive (true);
        } else if (speed_locked) {
            // Speed filters are active — keep re-encode forced
            copy_mode_switch.set_active (false);
            copy_mode_switch.set_sensitive (false);
        } else {
            copy_mode_switch.set_sensitive (true);
        }

        update_codec_row_visibility ();

        // In Chapter Split mode, rebuild segments from selected chapters
        if (show_chapters) {
            segments_group.set_title ("Selected Chapters");
            segments_group.set_description ("Chapters selected for export");
            rebuild_chapter_segments ();
        } else {
            segments_group.set_title ("Segments");
            segments_group.set_description ("Segments will be exported in the order listed below");
        }

        // ── Update General tab locks when mode changes ────────────────────────
        if (general_tab != null) {
            general_tab.notify_trim_tab_mode ((int) m);
        }
    }

    /**
     * Show the re-encode codec row whenever re-encoding will be needed:
     *  - Copy mode is OFF (user chose re-encode)
     *  - Crop Only mode (always re-encodes)
     *  - Crop & Trim mode (crop segments will need re-encoding regardless of copy setting)
     */
    private void update_codec_row_visibility () {
        bool show = !copy_mode_switch.active
                    || current_mode == Mode.CROP_ONLY
                    || current_mode == Mode.TRIM_AND_CROP;
        reencode_codec_row.set_visible (show);

        // Adjust subtitle to clarify when copy is ON but crop forces re-encode
        if (copy_mode_switch.active && current_mode == Mode.TRIM_AND_CROP) {
            reencode_codec_row.set_subtitle ("Segments with crop will be re-encoded using this codec");
        } else {
            reencode_codec_row.set_subtitle ("Uses the selected codec tab plus shared General filters and timing options");
        }

    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI — Video Player
    // ═════════════════════════════════════════════════════════════════════════

    private void build_player_section () {
        player = new VideoPlayer ();
        append (player);

        // Wire crop overlay changes to our display
        player.crop_overlay.crop_changed.connect (on_crop_overlay_changed);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI — Crop Controls
    // ═════════════════════════════════════════════════════════════════════════

    private void build_crop_controls () {
        crop_group = new Adw.PreferencesGroup ();
        crop_group.set_title ("Crop");
        crop_group.set_description ("Draw a rectangle on the video to define the crop area. Hold Shift while dragging to lock aspect ratio");
        crop_group.set_visible (false);

        // ── Crop value display ───────────────────────────────────────────────
        var value_row = new Adw.ActionRow ();
        value_row.set_title ("Crop Value");
        value_row.set_subtitle ("W:H:X:Y — drag on the video; all values snap to even numbers");
        value_row.set_icon_name ("image-crop-symbolic");

        crop_value_display = new Entry ();
        crop_value_display.set_editable (false);
        crop_value_display.set_can_focus (false);
        crop_value_display.set_placeholder_text ("No crop defined");
        crop_value_display.set_width_chars (20);
        crop_value_display.set_valign (Align.CENTER);
        crop_value_display.add_css_class ("monospace");
        value_row.add_suffix (crop_value_display);

        crop_group.add (value_row);

        // ── Crop scope (global vs per-segment) ──────────────────────────────
        crop_scope_row = new Adw.ActionRow ();
        crop_scope_row.set_title ("Per-Segment Crop");
        crop_scope_row.set_subtitle ("When enabled, each segment stores its own crop. When off, one crop applies to all.");
        crop_scope_row.set_icon_name ("view-list-symbolic");

        crop_scope_switch = new Switch ();
        crop_scope_switch.set_valign (Align.CENTER);
        crop_scope_switch.set_active (false);
        crop_scope_switch.notify["active"].connect (() => {
            rebuild_segment_rows ();
        });
        crop_scope_row.add_suffix (crop_scope_switch);
        crop_scope_row.set_activatable_widget (crop_scope_switch);
        crop_scope_row.set_visible (false);
        crop_group.add (crop_scope_row);

        // ── Action buttons ───────────────────────────────────────────────────
        var actions_row = new Adw.ActionRow ();
        actions_row.set_title ("Actions");

        crop_reset_btn = new Button.with_label ("Reset");
        crop_reset_btn.add_css_class ("destructive-action");
        crop_reset_btn.set_valign (Align.CENTER);
        crop_reset_btn.set_tooltip_text ("Clear the crop rectangle");
        crop_reset_btn.clicked.connect (() => {
            player.crop_overlay.clear_crop ();
        });
        actions_row.add_suffix (crop_reset_btn);

        crop_apply_all_btn = new Button.with_label ("Apply to All Segments");
        crop_apply_all_btn.add_css_class ("suggested-action");
        crop_apply_all_btn.set_valign (Align.CENTER);
        crop_apply_all_btn.set_tooltip_text ("Copy the current crop to every segment");
        crop_apply_all_btn.set_visible (false);
        crop_apply_all_btn.clicked.connect (() => {
            string cv = player.crop_overlay.get_crop_string ();
            if (cv == "") return;
            for (int i = 0; i < segments.length; i++) {
                segments[i].crop_value = cv;
            }
            rebuild_segment_rows ();
        });
        actions_row.add_suffix (crop_apply_all_btn);

        crop_group.add (actions_row);

        append (crop_group);
    }

    private void on_crop_overlay_changed (int w, int h, int x, int y) {
        string val = (w > 0 && h > 0)
            ? "%d:%d:%d:%d".printf (w, h, x, y)
            : "";

        // Update global crop
        global_crop_value = val;

        update_crop_display (val, w, h, x, y);
    }

    private void update_crop_display (string val, int w, int h, int x, int y) {
        if (val == "") {
            crop_value_display.set_text ("");
            crop_value_display.set_tooltip_text ("Drag on the video to define a crop area");
        } else {
            crop_value_display.set_text (val);
            crop_value_display.set_tooltip_text ("%d × %d at (%d, %d)".printf (w, h, x, y));
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI — Mark In / Mark Out / Add Segment
    // ═════════════════════════════════════════════════════════════════════════

    private void build_mark_controls () {
        mark_group = new Adw.PreferencesGroup ();
        mark_group.set_title ("Segment Controls");
        mark_group.set_description ("Mark time points and create segments from the current playback position");

        // ── Mark In ──────────────────────────────────────────────────────────
        var in_row = new Adw.ActionRow ();
        in_row.set_title ("Mark In");
        in_row.set_subtitle ("Start point for the next segment");

        mark_in_label = new Label ("00:00:00.000");
        mark_in_label.add_css_class ("monospace");
        mark_in_label.set_valign (Align.CENTER);
        in_row.add_suffix (mark_in_label);

        var mark_in_btn = new Button.with_label ("Set");
        mark_in_btn.set_valign (Align.CENTER);
        mark_in_btn.add_css_class ("suggested-action");
        mark_in_btn.set_tooltip_text ("Mark current position as segment start");
        mark_in_btn.clicked.connect (() => {
            mark_in = player.get_position_seconds ();
            mark_in_label.set_text (VideoPlayer.format_time (mark_in));
        });
        in_row.add_suffix (mark_in_btn);
        mark_group.add (in_row);

        // ── Mark Out ─────────────────────────────────────────────────────────
        var out_row = new Adw.ActionRow ();
        out_row.set_title ("Mark Out");
        out_row.set_subtitle ("End point for the next segment");

        mark_out_label = new Label ("00:00:00.000");
        mark_out_label.add_css_class ("monospace");
        mark_out_label.set_valign (Align.CENTER);
        out_row.add_suffix (mark_out_label);

        var mark_out_btn = new Button.with_label ("Set");
        mark_out_btn.set_valign (Align.CENTER);
        mark_out_btn.add_css_class ("suggested-action");
        mark_out_btn.set_tooltip_text ("Mark current position as segment end");
        mark_out_btn.clicked.connect (() => {
            mark_out = player.get_position_seconds ();
            mark_out_label.set_text (VideoPlayer.format_time (mark_out));
        });
        out_row.add_suffix (mark_out_btn);
        mark_group.add (out_row);

        // ── Add Segment button ───────────────────────────────────────────────
        var add_row = new Adw.ActionRow ();
        add_row.set_title ("Add Segment");
        add_row.set_subtitle ("Create a new segment from the current In/Out marks");

        var add_btn = new Button.with_label ("Add");
        add_btn.set_valign (Align.CENTER);
        add_btn.add_css_class ("suggested-action");
        add_btn.clicked.connect (on_add_segment);
        add_row.add_suffix (add_btn);

        var add_at_btn = new Button.with_label ("Add at Position");
        add_at_btn.set_valign (Align.CENTER);
        add_at_btn.add_css_class ("flat");
        add_at_btn.set_tooltip_text ("Add a 10-second segment starting at the current position");
        add_at_btn.clicked.connect (on_add_at_position);
        add_row.add_suffix (add_at_btn);

        var reset_segments_btn = new Button.with_label ("Reset");
        reset_segments_btn.set_valign (Align.CENTER);
        reset_segments_btn.add_css_class ("destructive-action");
        reset_segments_btn.set_tooltip_text ("Remove all segments and reset marks");
        reset_segments_btn.clicked.connect (reset_trim_state);
        add_row.add_suffix (reset_segments_btn);

        mark_group.add (add_row);
        append (mark_group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI — Segment List
    // ═════════════════════════════════════════════════════════════════════════

    private void build_segment_list () {
        segments_group = new Adw.PreferencesGroup ();
        segments_group.set_title ("Segments");

        segment_count_label = new Label ("No segments defined");
        segment_count_label.add_css_class ("dim-label");
        segments_group.set_description ("Segments will be exported in the order listed below");

        segment_listbox = new Gtk.ListBox ();
        segment_listbox.set_selection_mode (SelectionMode.NONE);
        segment_listbox.add_css_class ("boxed-list");
        segment_listbox.set_margin_top (8);
        segments_group.add (segment_listbox);
        segments_group.add (segment_count_label);

        append (segments_group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ═════════════════════════════════════════════════════════════════════════
    //  UI — Chapter List (checkable rows + select all/none)
    // ═════════════════════════════════════════════════════════════════════════

    private void build_chapter_list_section () {
        chapter_list_group = new Adw.PreferencesGroup ();
        chapter_list_group.set_title ("Chapters");
        chapter_list_group.set_description ("Select which chapters to export");
        chapter_list_group.set_visible (false);

        chapter_listbox = new Gtk.ListBox ();
        chapter_listbox.set_selection_mode (SelectionMode.NONE);
        chapter_listbox.add_css_class ("boxed-list");
        chapter_listbox.set_margin_top (8);
        chapter_list_group.add (chapter_listbox);

        // ── Selection action row ─────────────────────────────────────────────
        var select_row = new Adw.ActionRow ();
        select_row.set_title ("Selection");

        chapter_select_all_btn = new Button.with_label ("Select All");
        chapter_select_all_btn.set_valign (Align.CENTER);
        chapter_select_all_btn.add_css_class ("flat");
        chapter_select_all_btn.clicked.connect (() => {
            set_all_chapters_selected (true);
        });
        select_row.add_suffix (chapter_select_all_btn);

        chapter_select_none_btn = new Button.with_label ("Select None");
        chapter_select_none_btn.set_valign (Align.CENTER);
        chapter_select_none_btn.add_css_class ("flat");
        chapter_select_none_btn.clicked.connect (() => {
            set_all_chapters_selected (false);
        });
        select_row.add_suffix (chapter_select_none_btn);

        chapter_list_group.add (select_row);

        append (chapter_list_group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CHAPTER DETECTION — Auto-scan on file load
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Scan a file for chapters asynchronously (called from load_video).
     * Uses cancellable ffprobe async I/O to avoid blocking the UI.
     * Updates the chapter list group description with the result.
     */
    private void scan_chapters_async (string path) {
        var cancellable = new Cancellable ();
        chapter_scan_cancellable = cancellable;
        uint generation = ++chapter_scan_generation;

        FfprobeUtils.probe_chapters_async.begin (path, cancellable, (obj, res) => {
            var chapters = FfprobeUtils.probe_chapters_async.end (res);

            if (chapter_scan_cancellable == cancellable) {
                chapter_scan_cancellable = null;
            }

            if (cancellable.is_cancelled ())
                return;

            // Discard stale results if a newer load replaced this scan,
            // including same-path reloads.
            if (generation != chapter_scan_generation || loaded_video_path != path)
                return;

            detected_chapters = chapters;
            rebuild_chapter_list ();

            // Update the chapter list group description with scan results
            if (chapters.length > 0) {
                chapter_list_group.set_description (
                    "📖 %d chapter%s found — select which to export".printf (
                        chapters.length,
                        chapters.length == 1 ? "" : "s"));
            } else {
                chapter_list_group.set_description (
                    "No chapters found in this file");
            }

            // If already in Chapter Split mode, update segments
            if (current_mode == Mode.CHAPTER_SPLIT) {
                rebuild_chapter_segments ();
            }
        });
    }

    private void cancel_chapter_scan () {
        if (chapter_scan_cancellable != null) {
            chapter_scan_cancellable.cancel ();
            chapter_scan_cancellable = null;
        }
    }

    /**
     * Rebuild the chapter list UI from the detected_chapters array.
     */
    private void rebuild_chapter_list () {
        // Clear existing rows
        Gtk.Widget? child = chapter_listbox.get_first_child ();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling ();
            chapter_listbox.remove (child);
            child = next;
        }

        if (detected_chapters.length == 0) return;

        for (int i = 0; i < detected_chapters.length; i++) {
            var ch = detected_chapters[i];
            int idx = i;  // capture for closure

            var row = new Adw.ActionRow ();
            row.set_title (ch.title);
            row.set_subtitle ("%s → %s  (%s)".printf (
                VideoPlayer.format_time (ch.start_time),
                VideoPlayer.format_time (ch.end_time),
                format_duration (ch.get_duration ())
            ));

            // Chapter number badge
            var num_label = new Label ("#%d".printf (i + 1));
            num_label.add_css_class ("dim-label");
            num_label.add_css_class ("monospace");
            num_label.set_valign (Align.CENTER);
            row.add_prefix (num_label);

            // Seek-to-chapter button — lets the user preview the chapter
            var seek_btn = new Button.from_icon_name ("find-location-symbolic");
            seek_btn.set_tooltip_text ("Seek player to chapter start");
            seek_btn.set_valign (Align.CENTER);
            seek_btn.add_css_class ("flat");
            seek_btn.clicked.connect (() => {
                player.seek_to (detected_chapters[idx].start_time);
            });
            row.add_suffix (seek_btn);

            // Selection checkbox
            var check = new CheckButton ();
            check.set_active (ch.selected);
            check.set_valign (Align.CENTER);
            check.toggled.connect (() => {
                detected_chapters[idx].selected = check.active;
                // Update segment list in real time
                if (current_mode == Mode.CHAPTER_SPLIT) {
                    rebuild_chapter_segments ();
                }
            });
            row.add_suffix (check);
            row.set_activatable_widget (check);

            chapter_listbox.append (row);
        }
    }

    /**
     * Set all chapters to selected or unselected.
     */
    private void set_all_chapters_selected (bool selected) {
        for (int i = 0; i < detected_chapters.length; i++) {
            detected_chapters[i].selected = selected;
        }
        rebuild_chapter_list ();
        if (current_mode == Mode.CHAPTER_SPLIT) {
            rebuild_chapter_segments ();
        }
    }

    /**
     * Build TrimSegments from selected chapters and populate the segments list.
     * Preserves existing order: keeps segments whose chapter is still selected
     * (in their current position), removes deselected ones, and appends newly
     * selected chapters at the end. This way, user reordering survives
     * checkbox toggles.
     */
    private void rebuild_chapter_segments () {
        // Build a set of currently-selected chapter time ranges for fast lookup
        var selected_set = new HashTable<string, ChapterInfo> (str_hash, str_equal);
        for (int i = 0; i < detected_chapters.length; i++) {
            var ch = detected_chapters[i];
            if (ch.selected) {
                string key = "%.6f:%.6f".printf (ch.start_time, ch.end_time);
                selected_set.set (key, ch);
            }
        }

        // Pass 1: Keep existing segments that are still selected (preserving order)
        var kept = new GenericArray<TrimSegment> ();
        var kept_keys = new HashTable<string, bool> (str_hash, str_equal);
        for (int i = 0; i < segments.length; i++) {
            var seg = segments[i];
            string key = "%.6f:%.6f".printf (seg.start_time, seg.end_time);
            if (selected_set.contains (key)) {
                kept.add (seg);
                kept_keys.set (key, true);
            }
        }

        // Pass 2: Append newly selected chapters (not already in the kept list)
        for (int i = 0; i < detected_chapters.length; i++) {
            var ch = detected_chapters[i];
            if (!ch.selected) continue;
            string key = "%.6f:%.6f".printf (ch.start_time, ch.end_time);
            if (!kept_keys.contains (key)) {
                var seg = new TrimSegment (ch.start_time, ch.end_time);
                seg.label = ch.title;
                kept.add (seg);
            }
        }

        segments = kept;
        rebuild_segment_rows ();
    }

    // sanitize_filename delegates to ConversionUtils.sanitize_segment_name
    private static string sanitize_filename (string name) {
        return ConversionUtils.sanitize_segment_name (name);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI — Output Settings
    // ═════════════════════════════════════════════════════════════════════════

    private void build_output_settings () {
        output_group = new Adw.PreferencesGroup ();
        output_group.set_title ("Output Settings");
        output_group.set_description ("Choose how segments are encoded and exported");

        // ── Copy Streams toggle ──────────────────────────────────────────────
        var copy_row = new Adw.ActionRow ();
        copy_row.set_title ("Copy Streams (Fast)");
        copy_row.set_subtitle ("No re-encoding — fast stream copy");

        copy_mode_switch = new Switch ();
        copy_mode_switch.set_valign (Align.CENTER);
        copy_mode_switch.set_active (true);
        copy_row.add_suffix (copy_mode_switch);
        copy_row.set_activatable_widget (copy_mode_switch);
        output_group.add (copy_row);

        // ── Keyframe Cut toggle (only visible when copy mode is ON) ──────────
        keyframe_cut_row = new Adw.ActionRow ();
        keyframe_cut_row.set_title ("Cut at Nearest Keyframe");
        keyframe_cut_row.set_subtitle ("Faster but may shift cut points to the nearest keyframe. Disable for precise timestamps (slower).");

        keyframe_cut_switch = new Switch ();
        keyframe_cut_switch.set_valign (Align.CENTER);
        keyframe_cut_switch.set_active (true);
        keyframe_cut_row.add_suffix (keyframe_cut_switch);
        keyframe_cut_row.set_activatable_widget (keyframe_cut_switch);
        keyframe_cut_row.set_visible (copy_mode_switch.active);
        output_group.add (keyframe_cut_row);

        // ── Re-encode Codec selector ─────────────────────────────────────────
        reencode_codec_row = new Adw.ActionRow ();
        reencode_codec_row.set_title ("Re-encode Codec");
        reencode_codec_row.set_subtitle ("Uses the selected codec tab plus shared General filters and timing options");

        codec_choice = new DropDown (new StringList ({ "SVT-AV1", "x265", "x264", "VP9" }), null);
        codec_choice.set_valign (Align.CENTER);
        codec_choice.set_selected (0);
        reencode_codec_row.add_suffix (codec_choice);
        reencode_codec_row.set_visible (false);
        output_group.add (reencode_codec_row);

        copy_mode_switch.notify["active"].connect (() => {
            update_codec_row_visibility ();
            update_concat_audio_constraint ();
            update_smart_optimize_visibility ();
            keyframe_cut_row.set_visible (copy_mode_switch.active);
        });

        // ── Export as separate files ─────────────────────────────────────────
        var separate_row = new Adw.ActionRow ();
        separate_row.set_title ("Export as Separate Files");
        separate_row.set_subtitle ("Each segment becomes its own numbered file instead of concatenating");

        export_separate_switch = new Switch ();
        export_separate_switch.set_valign (Align.CENTER);
        export_separate_switch.set_active (false);
        export_separate_switch.notify["active"].connect (() => {
            update_concat_audio_constraint ();
            update_smart_optimize_visibility ();
        });
        separate_row.add_suffix (export_separate_switch);
        separate_row.set_activatable_widget (export_separate_switch);
        output_group.add (separate_row);

        // ── Smart Optimizer per-segment ──────────────────────────────────────
        smart_optimize_row = new Adw.ActionRow ();
        smart_optimize_row.set_title ("Smart Optimizer");
        smart_optimize_row.set_subtitle ("Analyze each segment individually for content-aware CRF and preset");
        smart_optimize_row.set_icon_name ("starred-symbolic");

        smart_optimize_switch = new Switch ();
        smart_optimize_switch.set_valign (Align.CENTER);
        smart_optimize_switch.set_active (false);
        smart_optimize_row.add_suffix (smart_optimize_switch);
        smart_optimize_row.set_activatable_widget (smart_optimize_switch);
        smart_optimize_row.set_visible (false);
        output_group.add (smart_optimize_row);

        append (output_group);
    }

    /**
     * Show the Smart Optimizer toggle when all conditions are met:
     *  - Re-encoding is active (copy mode OFF)
     *  - Export as separate files is ON
     */
    private void update_smart_optimize_visibility () {
        bool show = !copy_mode_switch.active && export_separate_switch.active;
        smart_optimize_row.set_visible (show);

        // Turn off the switch when hidden to avoid stale state
        if (!show && smart_optimize_switch.active) {
            smart_optimize_switch.set_active (false);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SPEED CONSTRAINT — force re-encode when speed filters are active
    // ═════════════════════════════════════════════════════════════════════════

    public void update_for_speed (bool video_speed_on, bool audio_speed_on) {
        speed_locked = video_speed_on || audio_speed_on;
        if (speed_locked) {
            copy_mode_switch.set_active (false);
            copy_mode_switch.set_sensitive (false);
        } else {
            // Restore sensitivity unless crop-only mode overrides
            if (current_mode != Mode.CROP_ONLY && current_mode != Mode.TRIM_AND_CROP) {
                copy_mode_switch.set_sensitive (true);
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CONCAT FILTER AUDIO CONSTRAINT
    //
    //  PATH A (concat filter) routes audio through -filter_complex, which
    //  decodes it — making -c:a copy impossible.  When PATH A will be used,
    //  disable "Copy" in all codec tabs' audio dropdowns so the user picks
    //  a real codec.  When the conditions change, re-enable it.
    //
    //  PATH A conditions: re-encode + multi-segment + combined output
    //   → !copy_mode && !export_separate && segments.length > 1
    // ═════════════════════════════════════════════════════════════════════════

    private void update_concat_audio_constraint () {
        bool would_use_concat_filter = !copy_mode_switch.active
                                       && !export_separate_switch.active
                                       && segments.length > 1;

        if (svt_tab != null)  svt_tab.audio_settings.update_for_concat_filter (would_use_concat_filter);
        if (x265_tab != null) x265_tab.audio_settings.update_for_concat_filter (would_use_concat_filter);
        if (x264_tab != null) x264_tab.audio_settings.update_for_concat_filter (would_use_concat_filter);
        if (vp9_tab != null)  vp9_tab.audio_settings.update_for_concat_filter (would_use_concat_filter);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SEGMENT MANAGEMENT — Reset
    // ═════════════════════════════════════════════════════════════════════════

    private void reset_trim_state () {
        // Clear all segments
        segments = new GenericArray<TrimSegment> ();
        rebuild_segment_rows ();

        // Reset mark in/out
        mark_in = 0.0;
        mark_out = 0.0;
        mark_in_label.set_text ("00:00:00.000");
        mark_out_label.set_text ("00:00:00.000");

        // Clear chapter state (will be re-populated by auto-scan in load_video)
        detected_chapters = new GenericArray<ChapterInfo> ();
        rebuild_chapter_list ();
        chapter_list_group.set_description ("Select which chapters to export");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SEGMENT MANAGEMENT — Add
    // ═════════════════════════════════════════════════════════════════════════

    private void on_add_segment () {
        double start = mark_in;
        double end   = mark_out;

        if (start > end) {
            double tmp = start;
            start = end;
            end = tmp;
        }

        if (end - start < 0.001) {
            mark_out_label.set_text ("⚠️ Set a different Out point");
            return;
        }

        var seg = new TrimSegment (start, end);

        // In Crop & Trim mode, stamp the current crop onto the segment
        if (current_mode == Mode.TRIM_AND_CROP) {
            if (crop_scope_switch.active) {
                // Per-segment: use the live overlay crop
                string cv = player.crop_overlay.get_crop_string ();
                if (cv != "") seg.crop_value = cv;
            } else {
                // Global: stamp the global crop value
                if (global_crop_value.strip ().length > 0)
                    seg.crop_value = global_crop_value;
            }
        }

        add_segment_to_list (seg);
    }

    private void on_add_at_position () {
        double pos = player.get_position_seconds ();
        double dur = player.get_duration_seconds ();
        double end = (pos + 10.0).clamp (0.0, dur);
        if (end <= pos) end = dur;

        var seg = new TrimSegment (pos, end);

        // In Crop & Trim mode, stamp the current crop
        if (current_mode == Mode.TRIM_AND_CROP) {
            if (crop_scope_switch.active) {
                string cv = player.crop_overlay.get_crop_string ();
                if (cv != "") seg.crop_value = cv;
            } else {
                if (global_crop_value.strip ().length > 0)
                    seg.crop_value = global_crop_value;
            }
        }

        add_segment_to_list (seg);

        mark_in = pos;
        mark_out = end;
        mark_in_label.set_text (VideoPlayer.format_time (pos));
        mark_out_label.set_text (VideoPlayer.format_time (end));
    }

    private void add_segment_to_list (TrimSegment seg) {
        segments.add (seg);
        rebuild_segment_rows ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SEGMENT MANAGEMENT — Rebuild ListBox rows
    // ═════════════════════════════════════════════════════════════════════════

    private void rebuild_segment_rows () {
        Gtk.Widget? child = segment_listbox.get_first_child ();
        while (child != null) {
            Gtk.Widget? next = child.get_next_sibling ();
            segment_listbox.remove (child);
            child = next;
        }

        for (int i = 0; i < segments.length; i++) {
            var row = build_segment_row (i);
            segment_listbox.append (row);
        }

        if (segments.length == 0) {
            if (current_mode == Mode.CHAPTER_SPLIT) {
                segment_count_label.set_text ("No chapters selected");
            } else {
                segment_count_label.set_text ("No segments defined");
            }
        } else {
            double total = 0.0;
            for (int i = 0; i < segments.length; i++) {
                total += segments[i].get_duration ();
            }
            string unit = (current_mode == Mode.CHAPTER_SPLIT) ? "chapter" : "segment";
            segment_count_label.set_text (
                "%d %s%s — total duration %s".printf (
                    segments.length,
                    unit,
                    segments.length == 1 ? "" : "s",
                    VideoPlayer.format_time (total)
                )
            );
        }

        // Update audio copy constraint — PATH A (concat filter) can't do
        // audio copy, so disable it when that path would be active
        update_concat_audio_constraint ();
    }

    private Gtk.Widget build_segment_row (int index) {
        var seg = segments[index];

        // ── Closure safety ───────────────────────────────────────────────────
        // Vala closures capture variables by reference.  Although `index` is a
        // method parameter (not a loop variable), we capture it into a single
        // local so that every lambda below closes over the same per-row value.
        // Do NOT remove this — without it, future refactors that inline this
        // method into a loop would silently break.
        int idx = index;

        var row = new Adw.ActionRow ();
        // Use chapter title as row title when available, fall back to number
        if (seg.label != null && seg.label.strip ().length > 0) {
            row.set_title ("#%d — %s".printf (idx + 1, seg.label));
        } else {
            row.set_title ("#%d".printf (idx + 1));
        }

        // Build subtitle with optional crop indicator
        string time_str = "%s → %s  (%s)".printf (
            VideoPlayer.format_time (seg.start_time),
            VideoPlayer.format_time (seg.end_time),
            format_duration (seg.get_duration ())
        );
        if (seg.has_crop ()) {
            time_str += "  🔲 " + seg.crop_value;
        }
        row.set_subtitle (time_str);

        // ── Chapter mode: simplified rows with reorder controls ────────────────
        // In Chapter Split mode, segments are auto-generated from the chapter
        // list. Time editing and delete don't apply (use the checkboxes above),
        // but reordering lets the user control export/concat order.
        if (current_mode == Mode.CHAPTER_SPLIT) {
            // ── Move Up ──────────────────────────────────────────────────────
            var up_btn = new Button.from_icon_name ("go-up-symbolic");
            up_btn.set_tooltip_text ("Move chapter up");
            up_btn.set_valign (Align.CENTER);
            up_btn.add_css_class ("flat");
            up_btn.set_sensitive (index > 0);
            up_btn.clicked.connect (() => {
                if (idx > 0) swap_segments (idx, idx - 1);
            });
            row.add_suffix (up_btn);

            // ── Move Down ────────────────────────────────────────────────────
            var down_btn = new Button.from_icon_name ("go-down-symbolic");
            down_btn.set_tooltip_text ("Move chapter down");
            down_btn.set_valign (Align.CENTER);
            down_btn.add_css_class ("flat");
            down_btn.set_sensitive (index < segments.length - 1);
            down_btn.clicked.connect (() => {
                if (idx < segments.length - 1) swap_segments (idx, idx + 1);
            });
            row.add_suffix (down_btn);

            return row;
        }

        // ── Start time editor ────────────────────────────────────────────────
        var start_entry = new Entry ();
        start_entry.set_text (VideoPlayer.format_time (seg.start_time));
        start_entry.set_width_chars (13);
        start_entry.set_max_width_chars (13);
        start_entry.set_valign (Align.CENTER);
        start_entry.add_css_class ("monospace");
        start_entry.set_tooltip_text ("Start time (editable)");

        // Fix #6: Live validation on every keystroke
        start_entry.changed.connect (() => {
            double parsed = VideoPlayer.parse_time (start_entry.get_text ());
            validate_segment_time (start_entry, parsed, segments[idx].end_time, true);
        });

        // Fix #6: Only commit the value if validation passes
        start_entry.activate.connect (() => {
            double new_val = VideoPlayer.parse_time (start_entry.get_text ());
            bool valid = validate_segment_time (start_entry, new_val, segments[idx].end_time, true);
            if (valid) {
                segments[idx].start_time = new_val;
                rebuild_segment_rows ();
            }
        });
        row.add_suffix (start_entry);

        var arrow = new Label ("→");
        arrow.set_valign (Align.CENTER);
        arrow.add_css_class ("dim-label");
        arrow.set_margin_start (4);
        arrow.set_margin_end (4);
        row.add_suffix (arrow);

        // ── End time editor ──────────────────────────────────────────────────
        var end_entry = new Entry ();
        end_entry.set_text (VideoPlayer.format_time (seg.end_time));
        end_entry.set_width_chars (13);
        end_entry.set_max_width_chars (13);
        end_entry.set_valign (Align.CENTER);
        end_entry.add_css_class ("monospace");
        end_entry.set_tooltip_text ("End time (editable)");

        // Fix #6: Live validation on every keystroke
        end_entry.changed.connect (() => {
            double parsed = VideoPlayer.parse_time (end_entry.get_text ());
            validate_segment_time (end_entry, parsed, segments[idx].start_time, false);
        });

        // Fix #6: Only commit the value if validation passes
        end_entry.activate.connect (() => {
            double new_val = VideoPlayer.parse_time (end_entry.get_text ());
            bool valid = validate_segment_time (end_entry, new_val, segments[idx].start_time, false);
            if (valid) {
                segments[idx].end_time = new_val;
                rebuild_segment_rows ();
            }
        });
        row.add_suffix (end_entry);

        // ── Crop button (Crop & Trim per-segment mode) ──────────────────────
        if (current_mode == Mode.TRIM_AND_CROP && crop_scope_switch.active) {
            var crop_btn = new Button.from_icon_name (
                seg.has_crop () ? "image-crop-symbolic" : "list-add-symbolic"
            );
            crop_btn.set_tooltip_text (
                seg.has_crop () ? "Update crop from current overlay" : "Set crop from current overlay"
            );
            crop_btn.set_valign (Align.CENTER);
            crop_btn.add_css_class ("flat");
            if (seg.has_crop ()) crop_btn.add_css_class ("accent");
            crop_btn.clicked.connect (() => {
                string cv = player.crop_overlay.get_crop_string ();
                segments[idx].crop_value = cv;
                rebuild_segment_rows ();
            });
            row.add_suffix (crop_btn);
        }

        // ── Seek button ──────────────────────────────────────────────────────
        var seek_btn = new Button.from_icon_name ("find-location-symbolic");
        seek_btn.set_tooltip_text ("Seek player to segment start");
        seek_btn.set_valign (Align.CENTER);
        seek_btn.add_css_class ("flat");
        seek_btn.clicked.connect (() => {
            player.seek_to (segments[idx].start_time);
        });
        row.add_suffix (seek_btn);

        // ── Move Up ──────────────────────────────────────────────────────────
        var up_btn = new Button.from_icon_name ("go-up-symbolic");
        up_btn.set_tooltip_text ("Move segment up");
        up_btn.set_valign (Align.CENTER);
        up_btn.add_css_class ("flat");
        up_btn.set_sensitive (index > 0);
        up_btn.clicked.connect (() => {
            if (idx > 0) swap_segments (idx, idx - 1);
        });
        row.add_suffix (up_btn);

        // ── Move Down ────────────────────────────────────────────────────────
        var down_btn = new Button.from_icon_name ("go-down-symbolic");
        down_btn.set_tooltip_text ("Move segment down");
        down_btn.set_valign (Align.CENTER);
        down_btn.add_css_class ("flat");
        down_btn.set_sensitive (index < segments.length - 1);
        down_btn.clicked.connect (() => {
            if (idx < segments.length - 1) swap_segments (idx, idx + 1);
        });
        row.add_suffix (down_btn);

        // ── Delete ───────────────────────────────────────────────────────────
        var delete_btn = new Button.from_icon_name ("user-trash-symbolic");
        delete_btn.set_tooltip_text ("Remove this segment");
        delete_btn.set_valign (Align.CENTER);
        delete_btn.add_css_class ("flat");
        delete_btn.add_css_class ("error");
        delete_btn.clicked.connect (() => {
            remove_segment (idx);
        });
        row.add_suffix (delete_btn);

        return row;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SEGMENT MANAGEMENT — Reorder & Delete
    // ═════════════════════════════════════════════════════════════════════════

    private void swap_segments (int a, int b) {
        if (a < 0 || b < 0 || a >= segments.length || b >= segments.length) return;
        var tmp = segments[a];
        segments[a] = segments[b];
        segments[b] = tmp;
        rebuild_segment_rows ();
    }

    private void remove_segment (int index) {
        if (index < 0 || index >= segments.length) return;
        segments.remove_index (index);
        rebuild_segment_rows ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    private static string format_duration (double secs) {
        if (secs < 0) secs = 0;

        if (secs < 60.0) {
            return "%.1fs".printf (secs);
        }

        int total = (int) secs;
        int h = total / 3600;
        int m = (total % 3600) / 60;
        int s = total % 60;

        if (h > 0)
            return "%dh %dm %ds".printf (h, m, s);
        return "%dm %ds".printf (m, s);
    }
}
