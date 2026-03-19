using Gtk;
using Adw;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  ActiveOperation — Tracks the primary operation MainWindow launched
//
//  Conversion, trim, subtitle extract, and subtitle apply runs are tracked
//  explicitly so cancel dispatch and close protection stay consistent across
//  all long-running operations.
// ═══════════════════════════════════════════════════════════════════════════════

private enum ActiveOperation {
    IDLE,
    CONVERTING,
    TRIMMING,
    SUBTITLE_EXTRACT,
    SUBTITLE_APPLY
}

private enum AudioCopyUnknownPreflightResult {
    PROCEED,
    BLOCK,
    CANCELLED
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MainWindow — Application window layout and user action handlers
// ═══════════════════════════════════════════════════════════════════════════════

public class MainWindow : Adw.ApplicationWindow {
    private FilePickers file_pickers;
    private SvtAv1Tab svt_tab;
    private X265Tab x265_tab;
    private X264Tab x264_tab;
    private Vp9Tab vp9_tab;
    private InformationTab info_tab;
    private StatusArea status_area;
    private Converter converter;
    private Button cancel_button;
    private Button convert_button;
    private ConsoleTab console_tab;
    private GeneralTab general_tab;
    private TrimTab trim_tab;
    private SubtitlesTab subtitles_tab;
    private Adw.ViewStack view_stack;
    private HamburgerMenu hamburger;
    private Adw.ToastOverlay toast_overlay;

    // Prevent GC from collecting the controller
    private AppController controller;

    // Explicit operation tracking for clean cancel dispatch
    private ActiveOperation current_operation = ActiveOperation.IDLE;
    private uint64 active_operation_id = 0;
    private uint64 next_operation_id = 1;
    private bool operation_launch_pending = false;
    private Adw.AlertDialog? active_preflight_dialog = null;
    private Cancellable? active_preflight_dialog_cancellable = null;
    private Cancellable? active_preflight_probe_cancellable = null;

    // Queued auto-convert: if Smart Optimizer finishes while another operation
    // is running, remember the codec so we can start conversion when idle.
    private string? pending_auto_convert_codec = null;

    // Cache the probed source bit depth for the current input path so
    // repeated convert attempts do not re-run ffprobe unnecessarily.
    private ConversionUtils.CachedFileProbe<int> cached_input_bit_depth =
        new ConversionUtils.CachedFileProbe<int> ();

    // Smart Optimizer runs concurrently with other operations (it's analysis,
    // not output encoding), so it's tracked separately from ActiveOperation.
    private bool smart_optimizer_active = false;
    private bool close_after_cancellation = false;

    // Guard against re-entrant close_request during the confirmation dialog
    private bool close_dialog_open = false;

    public MainWindow (Adw.Application app) {
        Object (application: app);

        set_title ("FFmpeg Converter GTK");
        set_default_size (1280, 720);

        create_components ();
        build_layout ();

        controller = new AppController (
            file_pickers, general_tab,
            svt_tab, x265_tab, x264_tab, vp9_tab,
            info_tab, console_tab, trim_tab,
            subtitles_tab,
            converter, hamburger,
            cancel_button, status_area,
            view_stack
        );

        // Smart Optimizer lifecycle: enable cancel button while running.
        // Tracked separately from ActiveOperation since analysis can run
        // concurrently with a conversion/trim/subtitle operation.
        controller.smart_optimizer_running.connect ((running) => {
            smart_optimizer_active = running;
            update_cancel_button_state ();
            maybe_finish_close_after_cancellation ();
        });

        // Auto-convert: Smart Optimizer requests conversion start.
        // Ensure the correct codec tab is visible (user may have switched
        // tabs while the optimizer was analyzing).  If another operation is
        // still running, queue the codec so conversion starts when idle.
        controller.auto_convert_requested.connect ((codec) => {
            if (can_start_primary_operation ()) {
                view_stack.set_visible_child_name (codec);
                on_convert_clicked ();
            } else {
                pending_auto_convert_codec = codec;
                status_area.set_status ("Auto-convert queued for %s — waiting for current operation…".printf (codec.up ()),
                    StatusIcon.WAITING_ICON, StatusIcon.WAITING_CSS);
            }
        });

        // Reset operation state only for the specific run MainWindow started.
        // AppController separately handles output-info and output actions.
        converter.conversion_succeeded.connect ((operation_id, output_result) => {
            if (!complete_tracked_operation (
                    ActiveOperation.CONVERTING, operation_id, true)) {
                return;
            }

            post_success_toast ("Conversion complete", output_result);
            maybe_finish_close_after_cancellation ();
        });
        converter.conversion_failed.connect ((operation_id) => {
            complete_tracked_operation_with_close (
                ActiveOperation.CONVERTING, operation_id, true);
        });
        converter.conversion_cancelled.connect ((operation_id) => {
            complete_tracked_operation_with_close (
                ActiveOperation.CONVERTING, operation_id, true);
        });
        trim_tab.trim_succeeded.connect ((operation_id, output_result) => {
            if (!complete_tracked_operation (
                    ActiveOperation.TRIMMING, operation_id, true)) {
                return;
            }

            post_success_toast ("Export complete", output_result);
            maybe_finish_close_after_cancellation ();
        });
        trim_tab.trim_failed.connect ((operation_id) => {
            complete_tracked_operation_with_close (
                ActiveOperation.TRIMMING, operation_id, true);
        });
        trim_tab.trim_cancelled.connect ((operation_id) => {
            complete_tracked_operation_with_close (
                ActiveOperation.TRIMMING, operation_id, true);
        });
        subtitles_tab.subtitle_extract_requested.connect ((input_file, stream, output_path) => {
            uint64 operation_id;
            if (!reserve_pending_operation (ActiveOperation.SUBTITLE_EXTRACT, out operation_id)) {
                status_area.set_status (
                    @"A $(get_operation_label (current_operation)) $(get_operation_activity_phrase ()). Cancel it before starting another one.",
                    StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS
                );
                return;
            }

            start_subtitle_extract (operation_id, input_file, stream, output_path);
        });
        subtitles_tab.subtitle_extract_all_requested.connect ((input_file, output_dir, base_name) => {
            uint64 operation_id;
            if (!reserve_pending_operation (ActiveOperation.SUBTITLE_EXTRACT, out operation_id)) {
                status_area.set_status (
                    @"A $(get_operation_label (current_operation)) $(get_operation_activity_phrase ()). Cancel it before starting another one.",
                    StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS
                );
                return;
            }

            start_subtitle_extract_all (operation_id, input_file, output_dir, base_name);
        });
        subtitles_tab.subtitle_extract_succeeded.connect ((operation_id, output_result) => {
            if (!complete_tracked_operation (
                    ActiveOperation.SUBTITLE_EXTRACT, operation_id, true)) {
                return;
            }

            post_success_toast ("Subtitles extracted", output_result);
            maybe_finish_close_after_cancellation ();
        });
        subtitles_tab.subtitle_extract_failed.connect ((operation_id) => {
            complete_tracked_operation_with_close (
                ActiveOperation.SUBTITLE_EXTRACT, operation_id, true);
        });
        subtitles_tab.subtitle_extract_cancelled.connect ((operation_id) => {
            complete_tracked_operation_with_close (
                ActiveOperation.SUBTITLE_EXTRACT, operation_id, true);
        });
        subtitles_tab.subtitle_apply_succeeded.connect ((operation_id, output_result) => {
            if (!complete_tracked_operation (
                    ActiveOperation.SUBTITLE_APPLY, operation_id, true)) {
                return;
            }

            post_success_toast ("Subtitles applied", output_result);
            maybe_finish_close_after_cancellation ();
        });
        subtitles_tab.subtitle_apply_failed.connect ((operation_id) => {
            complete_tracked_operation_with_close (
                ActiveOperation.SUBTITLE_APPLY, operation_id, true);
        });
        subtitles_tab.subtitle_apply_cancelled.connect ((operation_id) => {
            complete_tracked_operation_with_close (
                ActiveOperation.SUBTITLE_APPLY, operation_id, true);
        });

        // ── Close-request guard: prevent orphaned FFmpeg processes ────────
        close_request.connect (on_close_request);
    }

    private bool complete_tracked_operation_with_close (ActiveOperation operation,
                                                        uint64 operation_id,
                                                        bool drain_auto_convert_queue) {
        bool completed = complete_tracked_operation (
            operation, operation_id, drain_auto_convert_queue);
        if (completed) {
            maybe_finish_close_after_cancellation ();
        }
        return completed;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  COMPONENT CREATION
    //
    //  Components receive StatusArea (not raw Label + ProgressBar) so this
    //  class doesn't reach into StatusArea's internal widget structure.
    // ═════════════════════════════════════════════════════════════════════════

    private void create_components () {
        file_pickers = new FilePickers ();
        general_tab  = new GeneralTab ();
        svt_tab      = new SvtAv1Tab ();
        x265_tab     = new X265Tab ();
        x264_tab     = new X264Tab ();
        vp9_tab      = new Vp9Tab ();
        info_tab     = new InformationTab ();
        console_tab  = new ConsoleTab ();
        status_area  = new StatusArea ();

        trim_tab = new TrimTab ();
        trim_tab.general_tab = general_tab;
        trim_tab.svt_tab     = svt_tab;
        trim_tab.x265_tab   = x265_tab;
        trim_tab.x264_tab   = x264_tab;
        trim_tab.vp9_tab    = vp9_tab;

        subtitles_tab = new SubtitlesTab ();
        subtitles_tab.file_pickers = file_pickers;
        subtitles_tab.general_tab  = general_tab;
        subtitles_tab.svt_tab      = svt_tab;
        subtitles_tab.x265_tab     = x265_tab;
        subtitles_tab.x264_tab     = x264_tab;
        subtitles_tab.vp9_tab      = vp9_tab;
        subtitles_tab.set_ui_refs (status_area, console_tab);

        hamburger = new HamburgerMenu (this, file_pickers);

        converter = new Converter (status_area, console_tab, general_tab);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  LAYOUT — Adw.ViewStack + ViewSwitcherTitle + ViewSwitcherBar
    // ═════════════════════════════════════════════════════════════════════════

    private void build_layout () {
        var toolbar_view = new Adw.ToolbarView ();

        var header = new Adw.HeaderBar ();
        header.pack_start (hamburger.get_button ());

        view_stack = new Adw.ViewStack ();
        view_stack.set_vexpand (true);

        add_scrolled_page (view_stack, general_tab, "general",  "General",      "preferences-system-symbolic");
        add_scrolled_page (view_stack, svt_tab,     "svt-av1",  "SVT-AV1",     "video-x-generic-symbolic");
        add_scrolled_page (view_stack, x265_tab,    "x265",     "x265",        "video-x-generic-symbolic");
        add_scrolled_page (view_stack, x264_tab,    "x264",     "x264",        "video-x-generic-symbolic");
        add_scrolled_page (view_stack, vp9_tab,     "vp9",      "VP9",         "video-x-generic-symbolic");
        add_scrolled_page (view_stack, trim_tab,    "trim",     "Crop & Trim", "edit-cut-symbolic");
        add_scrolled_page (view_stack, subtitles_tab, "subtitles", "Subtitles", "media-view-subtitles-symbolic");

        var info_page = view_stack.add_titled (info_tab, "info", "Information");
        info_page.set_icon_name ("dialog-information-symbolic");

        add_scrolled_page (view_stack, console_tab, "console",  "Console",     "utilities-terminal-symbolic");

        var switcher_title = new Adw.ViewSwitcherTitle ();
        switcher_title.set_stack (view_stack);
        switcher_title.set_title ("FFmpeg Converter GTK");
        header.set_title_widget (switcher_title);

        toolbar_view.add_top_bar (header);

        // ── Content area ─────────────────────────────────────────────────────
        var content_box = new Box (Orientation.VERTICAL, 24);
        content_box.set_margin_top (32);
        content_box.set_margin_bottom (32);
        content_box.set_margin_start (32);
        content_box.set_margin_end (32);

        content_box.append (file_pickers);
        content_box.append (view_stack);
        content_box.append (build_button_bar ());
        content_box.append (status_area);

        // ── Toast overlay: wraps content for non-intrusive notifications ──
        toast_overlay = new Adw.ToastOverlay ();
        toast_overlay.set_child (content_box);

        toolbar_view.set_content (toast_overlay);

        // ── Bottom bar: revealed when header has no room for tabs ────────────
        var switcher_bar = new Adw.ViewSwitcherBar ();
        switcher_bar.set_stack (view_stack);
        switcher_title.bind_property ("title-visible", switcher_bar, "reveal",
            BindingFlags.SYNC_CREATE);
        toolbar_view.add_bottom_bar (switcher_bar);

        set_content (toolbar_view);

        // Disable the Convert button on tabs where it has no function
        view_stack.notify["visible-child-name"].connect (() => {
            update_convert_sensitivity ();
        });
        update_convert_sensitivity ();
    }

    /**
     * Enable the Convert button only on tabs that support conversion.
     *
     * Uses a whitelist so that new tabs default to disabled rather than
     * accidentally enabled.
     */
    private void update_convert_sensitivity () {
        string? page = view_stack.visible_child_name;
        bool active = page == "svt-av1" || page == "x265" || page == "x264"
                   || page == "vp9"     || page == "trim" || page == "subtitles";
        convert_button.set_sensitive (active && can_start_primary_operation ());
    }

    private bool can_start_primary_operation () {
        return current_operation == ActiveOperation.IDLE;
    }

    private string get_operation_label (ActiveOperation operation,
                                        string idle_fallback = "operation") {
        switch (operation) {
        case ActiveOperation.CONVERTING:     return "conversion";
        case ActiveOperation.TRIMMING:       return "export";
        case ActiveOperation.SUBTITLE_EXTRACT: return "subtitle extraction";
        case ActiveOperation.SUBTITLE_APPLY: return "subtitle apply";
        default:                             return idle_fallback;
        }
    }

    private string get_operation_activity_phrase () {
        return operation_launch_pending ? "is already being prepared" : "is already running";
    }

    /** Wrap a widget in a ScrolledWindow and add as a ViewStack page with icon. */
    private void add_scrolled_page (Adw.ViewStack stack, Widget child,
                                    string name, string title, string icon) {
        var scrolled = new ScrolledWindow ();
        scrolled.set_vexpand (true);
        scrolled.set_policy (PolicyType.NEVER, PolicyType.AUTOMATIC);
        scrolled.set_child (child);
        var page = stack.add_titled (scrolled, name, title);
        page.set_icon_name (icon);
    }

    /** Build the Cancel + Convert button row. */
    private Box build_button_bar () {
        var bar = new Box (Orientation.HORIZONTAL, 24);
        bar.set_hexpand (true);
        bar.set_margin_bottom (16);

        cancel_button = new Button.with_label ("Cancel");
        cancel_button.add_css_class ("destructive-action");
        cancel_button.set_size_request (200, 48);
        cancel_button.set_sensitive (false);
        cancel_button.clicked.connect (on_cancel_clicked);
        bar.append (cancel_button);

        var spacer = new Box (Orientation.HORIZONTAL, 0);
        spacer.set_hexpand (true);
        bar.append (spacer);

        convert_button = new Button.with_label ("Convert");
        convert_button.add_css_class ("suggested-action");
        convert_button.set_size_request (200, 48);
        convert_button.clicked.connect (on_convert_clicked);
        bar.append (convert_button);

        return bar;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  USER ACTIONS — Convert
    //
    //  The old on_convert_clicked handled four code paths in a single 75-line
    //  method.  Now it's a short dispatcher that delegates to per-path
    //  methods, each with its own validation and overwrite logic.
    // ═════════════════════════════════════════════════════════════════════════

    private void on_convert_clicked () {
        if (!can_start_primary_operation ()) {
            status_area.set_status (
                @"A $(get_operation_label (current_operation)) $(get_operation_activity_phrase ()). " +
                "Cancel it before starting another one.",
                StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS
            );
            return;
        }

        string? page = view_stack.visible_child_name;

        // ── Subtitles has its own path (remux / burn-in, no codec tab) ────
        if (page == "subtitles") {
            if (!subtitles_tab.can_apply ()) {
                status_area.set_status (
                    "Load a file with subtitle tracks or add external subtitles first!",
                    StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
                return;
            }

            uint64 operation_id;
            if (!reserve_pending_operation (ActiveOperation.SUBTITLE_APPLY, out operation_id))
                return;
            start_subtitle_apply (operation_id);
            return;
        }

        // ── Look up the codec tab for all other convertible pages ─────────
        ICodecTab? codec_tab = lookup_codec_tab (page);
        if (codec_tab == null) {
            status_area.set_status (
                "Please select a codec tab (SVT-AV1, x265, x264, VP9, Crop & Trim, or Subtitles) first!",
                StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
            return;
        }

        // ── Validate input file early (covers both trim and codec paths) ──
        string input_file = file_pickers.input_entry.get_text ();
        if (input_file == "") {
            status_area.set_status ("Please select an input file first!",
                StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
            return;
        }

        if (!(codec_tab is TrimTab) && codec_audio_probe_pending (codec_tab)) {
            status_area.set_status (
                "Checking source audio stream. Please wait a moment and try again.",
                StatusIcon.WAITING_ICON, StatusIcon.WAITING_CSS);
            return;
        }

        // ── Dispatch to the appropriate conversion path ───────────────────
        if (codec_tab is TrimTab) {
            uint64 operation_id;
            if (!reserve_pending_operation (ActiveOperation.TRIMMING, out operation_id))
                return;
            start_trim_operation ((TrimTab) codec_tab, input_file, operation_id);
        } else {
            uint64 operation_id;
            if (!reserve_pending_operation (ActiveOperation.CONVERTING, out operation_id))
                return;
            start_codec_conversion (input_file, codec_tab, operation_id);
        }
    }

    /**
     * Map a ViewStack page name to its ICodecTab.
     * Returns null for non-convertible pages.
     */
    private ICodecTab? lookup_codec_tab (string? page) {
        switch (page) {
            case "svt-av1": return svt_tab;
            case "x265":    return x265_tab;
            case "x264":    return x264_tab;
            case "vp9":     return vp9_tab;
            case "trim":    return trim_tab;
            default:         return null;
        }
    }

    private bool codec_audio_probe_pending (ICodecTab codec_tab) {
        BaseCodecTab? base_codec_tab = codec_tab as BaseCodecTab;
        if (base_codec_tab == null) {
            return false;
        }

        return base_codec_tab.audio_settings.is_audio_probe_pending ();
    }

    private delegate void ProceedCallback ();
    private delegate void DialogResponseCallback (string response);
    private delegate BaseCodecTab? PixelFormatTabProvider ();

    private bool has_explicit_pixel_format_selection (BaseCodecTab? codec_tab) {
        if (codec_tab == null) {
            return false;
        }

        PixelFormatSettingsSnapshot snapshot =
            codec_tab.snapshot_pixel_format_settings ();
        return snapshot.eight_bit_selected || snapshot.ten_bit_selected;
    }

    private async int get_cached_input_bit_depth_async (string input_file,
                                                        Cancellable? cancellable = null) {
        if (input_file == "")
            return 0;

        ConversionUtils.FileSignature? current_signature =
            ConversionUtils.query_file_signature (input_file);

        if (current_signature != null) {
            var cached_entry = cached_input_bit_depth.lookup (current_signature);
            if (cached_entry != null && cached_entry.value > 0)
                return cached_entry.value;
        }

        int probed_bits = yield FfprobeUtils.probe_video_bit_depth_async (
            input_file, cancellable);
        if (probed_bits > 0 && current_signature != null) {
            cached_input_bit_depth.store (current_signature, probed_bits);
        }

        return probed_bits;
    }

    private void maybe_warn_implicit_depth_downgrade (string input_file,
                                                      owned PixelFormatTabProvider get_codec_tab,
                                                      owned ProceedCallback on_continue,
                                                      owned ProceedCallback? on_cancel = null) {
        BaseCodecTab? codec_tab = get_codec_tab ();
        if (codec_tab == null || has_explicit_pixel_format_selection (codec_tab)) {
            on_continue ();
            return;
        }

        var cancellable = begin_preflight_probe ();
        get_cached_input_bit_depth_async.begin (input_file, cancellable, (obj, res) => {
            int source_bits = get_cached_input_bit_depth_async.end (res);
            finish_preflight_probe (cancellable);

            if (cancellable.is_cancelled ())
                return;

            BaseCodecTab? current_codec_tab = get_codec_tab ();
            if (current_codec_tab == null
                || has_explicit_pixel_format_selection (current_codec_tab)) {
                on_continue ();
                return;
            }

            if (source_bits <= 8) {
                on_continue ();
                return;
            }

            string source_depth = "%d-bit".printf (source_bits);
            string fallback_depth = "8-bit";

            var dialog = new Adw.AlertDialog (
                "Output Bit Depth Is Unset",
                @"The source video appears to be $source_depth, but no output bit depth is selected in the active codec tab.\n\nDepending on the encoder, FFmpeg may fall back to $fallback_depth unless you explicitly enable 10-Bit Color."
            );

            dialog.add_response ("cancel", "Cancel");
            dialog.add_response ("continue", "Continue");
            dialog.set_response_appearance ("continue", Adw.ResponseAppearance.SUGGESTED);
            dialog.set_default_response ("continue");
            dialog.set_close_response ("cancel");

            choose_preflight_dialog (dialog, (response) => {
                if (response == "continue") {
                    on_continue ();
                } else if (on_cancel != null) {
                    on_cancel ();
                }
            });
        });
    }

    private bool get_svt_av1_chroma_warning (BaseCodecTab svt_codec_tab,
                                             out string requested_format,
                                             out string effective_format) {
        requested_format = "";
        effective_format = "";

        PixelFormatSettingsSnapshot pixel_format =
            svt_codec_tab.snapshot_pixel_format_settings ();

        if (pixel_format.ten_bit_selected) {
            requested_format = pixel_format.ten_bit_format_text;
            effective_format = "10-bit 4:2:0";
        } else if (pixel_format.eight_bit_selected) {
            requested_format = pixel_format.eight_bit_format_text;
            effective_format = "8-bit 4:2:0";
        } else {
            return false;
        }

        return !requested_format.contains (Chroma.C420);
    }

    private void maybe_warn_svt_av1_chroma_downgrade (BaseCodecTab svt_codec_tab,
                                                      owned ProceedCallback on_continue,
                                                      owned ProceedCallback? on_cancel = null) {
        string requested_format;
        string effective_format;
        if (!get_svt_av1_chroma_warning (
                svt_codec_tab, out requested_format, out effective_format)) {
            on_continue ();
            return;
        }

        var dialog = new Adw.AlertDialog (
            "SVT-AV1 Will Encode as 4:2:0",
            @"The active codec tab is set to $requested_format, but SVT-AV1 in this app/runtime encodes as $effective_format.\n\nIf you continue, the output will use $effective_format."
        );

        dialog.add_response ("cancel", "Cancel");
        dialog.add_response ("continue", @"Convert as $effective_format");
        dialog.set_response_appearance ("continue", Adw.ResponseAppearance.SUGGESTED);
        dialog.set_default_response ("continue");
        dialog.set_close_response ("cancel");

        choose_preflight_dialog (dialog, (response) => {
            if (response == "continue") {
                on_continue ();
            } else if (on_cancel != null) {
                on_cancel ();
            }
        });
    }

    // ── Subtitles path ───────────────────────────────────────────────────────

    private void start_subtitle_extract (uint64 operation_id,
                                         string input_file,
                                         SubtitleStream stream,
                                         string output_path) {
        if (!is_pending_operation (ActiveOperation.SUBTITLE_EXTRACT, operation_id)) {
            return;
        }

        if (!subtitles_tab.start_extract (operation_id, input_file, stream, output_path)) {
            release_pending_operation (ActiveOperation.SUBTITLE_EXTRACT, operation_id, true);
            return;
        }

        activate_cancel (ActiveOperation.SUBTITLE_EXTRACT, operation_id);
    }

    private void start_subtitle_extract_all (uint64 operation_id,
                                             string input_file,
                                             string output_dir,
                                             string base_name) {
        if (!is_pending_operation (ActiveOperation.SUBTITLE_EXTRACT, operation_id)) {
            return;
        }

        if (!subtitles_tab.start_extract_all (
                operation_id, input_file, output_dir, base_name)) {
            release_pending_operation (ActiveOperation.SUBTITLE_EXTRACT, operation_id, true);
            return;
        }

        activate_cancel (ActiveOperation.SUBTITLE_EXTRACT, operation_id);
    }

    private void start_subtitle_apply (uint64 operation_id) {
        if (!is_pending_operation (ActiveOperation.SUBTITLE_APPLY, operation_id)) {
            return;
        }

        if (!subtitles_tab.can_apply ()) {
            status_area.set_status (
                "Load a file with subtitle tracks or add external subtitles first!",
                StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
            release_pending_operation (ActiveOperation.SUBTITLE_APPLY, operation_id, true);
            return;
        }

        if (subtitles_tab.is_burn_in_mode ()) {
            string input_file = subtitles_tab.get_input_file ();
            maybe_warn_implicit_depth_downgrade (input_file, () => {
                return subtitles_tab.get_selected_reencode_codec_tab ();
            }, () => {
                if (!is_pending_operation (ActiveOperation.SUBTITLE_APPLY, operation_id)) {
                    return;
                }

                if (subtitles_tab.will_use_svt_av1_burn_in ()) {
                    maybe_warn_svt_av1_chroma_downgrade (svt_tab, () => {
                        if (!is_pending_operation (ActiveOperation.SUBTITLE_APPLY, operation_id)) {
                            return;
                        }
                        continue_start_subtitle_apply (operation_id);
                    }, () => {
                        release_pending_operation (ActiveOperation.SUBTITLE_APPLY, operation_id, true);
                    });
                    return;
                }

                continue_start_subtitle_apply (operation_id);
            }, () => {
                release_pending_operation (ActiveOperation.SUBTITLE_APPLY, operation_id, true);
            });
            return;
        }

        continue_start_subtitle_apply (operation_id);
    }

    private void continue_start_subtitle_apply (uint64 operation_id) {
        continue_start_subtitle_apply_async.begin (operation_id);
    }

    private async void continue_start_subtitle_apply_async (uint64 operation_id) {
        if (!is_pending_operation (ActiveOperation.SUBTITLE_APPLY, operation_id)) {
            return;
        }

        var cancellable = begin_preflight_probe ();
        AudioCopyUnknownPreflightResult preflight_result =
            yield maybe_verify_unknown_audio_copy_compatibility (
                subtitles_tab.get_input_file (),
                subtitles_tab.get_selected_reencode_codec_tab (),
                cancellable
            );

        if (preflight_result == AudioCopyUnknownPreflightResult.CANCELLED) {
            finish_preflight_probe (cancellable);
            return;
        }

        if (preflight_result == AudioCopyUnknownPreflightResult.BLOCK) {
            finish_preflight_probe (cancellable);
            release_pending_operation (ActiveOperation.SUBTITLE_APPLY, operation_id, true);
            return;
        }

        finish_preflight_probe (cancellable);

        if (!is_pending_operation (ActiveOperation.SUBTITLE_APPLY, operation_id)) {
            return;
        }

        var settings = AppSettings.get_default ();
        string expected = subtitles_tab.get_expected_output_path ();

        if (settings.overwrite_enabled) {
            // Overwrite protection disabled — always proceed directly
            launch_subtitle_apply (operation_id, true);
        } else if (expected != "" && FileUtils.test (expected, FileTest.EXISTS)) {
            confirm_overwrite (expected, true,
                () => {
                    if (!is_pending_operation (ActiveOperation.SUBTITLE_APPLY, operation_id)) {
                        return;
                    }
                    launch_subtitle_apply (operation_id, true);
                },
                () => {
                    if (!is_pending_operation (ActiveOperation.SUBTITLE_APPLY, operation_id)) {
                        return;
                    }
                    launch_subtitle_apply (operation_id, false);
                },
                () => {
                    release_pending_operation (ActiveOperation.SUBTITLE_APPLY, operation_id, true);
                }
            );
        } else {
            launch_subtitle_apply (operation_id);
        }
    }

    // ── Crop & Trim path ─────────────────────────────────────────────────────

    private void start_trim_operation (TrimTab trim,
                                       string input_file,
                                       uint64 operation_id) {
        if (!is_pending_operation (ActiveOperation.TRIMMING, operation_id)) {
            return;
        }

        if (!trim.will_reencode_output ()) {
            continue_start_trim_operation (trim, input_file, operation_id);
            return;
        }

        maybe_warn_implicit_depth_downgrade (input_file, () => {
            return trim.get_selected_reencode_codec_tab ();
        }, () => {
            if (!is_pending_operation (ActiveOperation.TRIMMING, operation_id)) {
                return;
            }

            if (trim.will_use_svt_av1_reencode ()) {
                maybe_warn_svt_av1_chroma_downgrade (svt_tab, () => {
                    if (!is_pending_operation (ActiveOperation.TRIMMING, operation_id)) {
                        return;
                    }
                    continue_start_trim_operation (trim, input_file, operation_id);
                }, () => {
                    release_pending_operation (ActiveOperation.TRIMMING, operation_id, true);
                });
                return;
            }

            continue_start_trim_operation (trim, input_file, operation_id);
        }, () => {
            release_pending_operation (ActiveOperation.TRIMMING, operation_id, true);
        });
    }

    private void continue_start_trim_operation (TrimTab trim,
                                                string input_file,
                                                uint64 operation_id) {
        continue_start_trim_operation_async.begin (trim, input_file, operation_id);
    }

    private async void continue_start_trim_operation_async (TrimTab trim,
                                                            string input_file,
                                                            uint64 operation_id) {
        if (!is_pending_operation (ActiveOperation.TRIMMING, operation_id)) {
            return;
        }

        var cancellable = begin_preflight_probe ();
        AudioCopyUnknownPreflightResult preflight_result =
            yield maybe_verify_unknown_audio_copy_compatibility (
                input_file,
                trim.get_selected_reencode_codec_tab (),
                cancellable
            );

        if (preflight_result == AudioCopyUnknownPreflightResult.CANCELLED) {
            finish_preflight_probe (cancellable);
            return;
        }

        if (preflight_result == AudioCopyUnknownPreflightResult.BLOCK) {
            finish_preflight_probe (cancellable);
            release_pending_operation (ActiveOperation.TRIMMING, operation_id, true);
            return;
        }

        finish_preflight_probe (cancellable);

        if (!is_pending_operation (ActiveOperation.TRIMMING, operation_id)) {
            return;
        }

        string out_folder = file_pickers.output_entry.get_text ();
        string expected = trim.get_expected_output_path (input_file, out_folder);

        var settings = AppSettings.get_default ();

        if (settings.overwrite_enabled) {
            // Overwrite protection disabled — always proceed directly
            launch_trim_export (
                trim,
                input_file,
                out_folder,
                operation_id,
                TrimOutputConflictPolicy.OVERWRITE
            );
        } else if (expected != "" && FileUtils.test (expected, FileTest.EXISTS)) {
            confirm_overwrite (expected, true,
                () => {
                    if (!is_pending_operation (ActiveOperation.TRIMMING, operation_id)) {
                        return;
                    }
                    launch_trim_export (
                        trim,
                        input_file,
                        out_folder,
                        operation_id,
                        TrimOutputConflictPolicy.OVERWRITE
                    );
                },
                () => {
                    if (!is_pending_operation (ActiveOperation.TRIMMING, operation_id)) {
                        return;
                    }
                    launch_trim_export (
                        trim,
                        input_file,
                        out_folder,
                        operation_id,
                        TrimOutputConflictPolicy.AUTO_RENAME
                    );
                },
                () => {
                    release_pending_operation (ActiveOperation.TRIMMING, operation_id, true);
                }
            );
        } else {
            launch_trim_export (
                trim,
                input_file,
                out_folder,
                operation_id,
                TrimOutputConflictPolicy.OVERWRITE
            );
        }
    }

    // ── Normal codec conversion path ─────────────────────────────────────────

    private void start_codec_conversion (string input_file,
                                         ICodecTab codec_tab,
                                         uint64 operation_id) {
        BaseCodecTab? base_codec_tab = codec_tab as BaseCodecTab;
        maybe_warn_implicit_depth_downgrade (input_file, () => {
            return base_codec_tab;
        }, () => {
            if (!is_pending_operation (ActiveOperation.CONVERTING, operation_id)) {
                return;
            }

            if (codec_tab is SvtAv1Tab) {
                maybe_warn_svt_av1_chroma_downgrade (svt_tab, () => {
                    if (!is_pending_operation (ActiveOperation.CONVERTING, operation_id)) {
                        return;
                    }
                    continue_start_codec_conversion (input_file, codec_tab, operation_id);
                }, () => {
                    release_pending_operation (ActiveOperation.CONVERTING, operation_id, true);
                });
                return;
            }

            continue_start_codec_conversion (input_file, codec_tab, operation_id);
        }, () => {
            release_pending_operation (ActiveOperation.CONVERTING, operation_id, true);
        });
    }

    private void continue_start_codec_conversion (string input_file,
                                                  ICodecTab codec_tab,
                                                  uint64 operation_id) {
        continue_start_codec_conversion_async.begin (input_file, codec_tab, operation_id);
    }

    private async void continue_start_codec_conversion_async (string input_file,
                                                              ICodecTab codec_tab,
                                                              uint64 operation_id) {
        if (!is_pending_operation (ActiveOperation.CONVERTING, operation_id)) {
            return;
        }

        ICodecBuilder builder = codec_tab.get_codec_builder ();
        var cancellable = begin_preflight_probe ();
        AudioCopyUnknownPreflightResult preflight_result =
            yield maybe_verify_unknown_audio_copy_compatibility (
                input_file, codec_tab as BaseCodecTab, cancellable);

        if (preflight_result == AudioCopyUnknownPreflightResult.CANCELLED) {
            finish_preflight_probe (cancellable);
            return;
        }

        if (preflight_result == AudioCopyUnknownPreflightResult.BLOCK) {
            finish_preflight_probe (cancellable);
            release_pending_operation (ActiveOperation.CONVERTING, operation_id, true);
            return;
        }

        string output_file = yield Converter.compute_output_path_async (
            input_file,
            file_pickers.output_entry.get_text (),
            builder,
            codec_tab,
            cancellable
        );
        finish_preflight_probe (cancellable);

        if (cancellable.is_cancelled ()) {
            return;
        }

        if (!is_pending_operation (ActiveOperation.CONVERTING, operation_id)) {
            return;
        }

        var settings = AppSettings.get_default ();

        if (settings.overwrite_enabled) {
            // Overwrite protection disabled — always proceed directly
            begin_conversion (input_file, output_file, codec_tab, builder, operation_id);
        } else if (FileUtils.test (output_file, FileTest.EXISTS)) {
            confirm_overwrite (output_file, true,
                () => {
                    if (!is_pending_operation (ActiveOperation.CONVERTING, operation_id)) {
                        return;
                    }
                    begin_conversion (input_file, output_file, codec_tab, builder, operation_id);
                },
                () => {
                    if (!is_pending_operation (ActiveOperation.CONVERTING, operation_id)) {
                        return;
                    }
                    string? unique = Converter.find_unique_path (output_file);
                    if (unique == null || unique.length == 0) {
                        status_area.set_status ("Could not derive a unique output filename.",
                            StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
                        release_pending_operation (ActiveOperation.CONVERTING, operation_id, true);
                        return;
                    }
                    begin_conversion (input_file, unique, codec_tab, builder, operation_id);
                },
                () => {
                    release_pending_operation (ActiveOperation.CONVERTING, operation_id, true);
                }
            );
        } else {
            begin_conversion (input_file, output_file, codec_tab, builder, operation_id);
        }
    }

    private void begin_conversion (string input_file,
                                   string output_file,
                                   ICodecTab codec_tab,
                                   ICodecBuilder builder,
                                   uint64 operation_id) {
        if (!is_pending_operation (ActiveOperation.CONVERTING, operation_id)) {
            return;
        }

        if (!converter.start_conversion (
                input_file, output_file, codec_tab, builder, operation_id)) {
            release_pending_operation (ActiveOperation.CONVERTING, operation_id, true);
            return;
        }

        activate_cancel (ActiveOperation.CONVERTING, operation_id);
    }

    private async AudioCopyUnknownPreflightResult maybe_verify_unknown_audio_copy_compatibility (
        string input_file,
        BaseCodecTab? codec_tab,
        Cancellable cancellable) {
        if (!AppSettings.get_default ().verify_unknown_audio_copy_preflight) {
            return AudioCopyUnknownPreflightResult.PROCEED;
        }

        if (codec_tab == null) {
            return AudioCopyUnknownPreflightResult.PROCEED;
        }

        string container = codec_tab.get_container ();
        AudioSettings audio_settings = codec_tab.audio_settings;
        if (!audio_settings.should_verify_unknown_audio_copy_compatibility (container)) {
            return AudioCopyUnknownPreflightResult.PROCEED;
        }

        string previous_text, previous_icon, previous_css;
        status_area.get_full_status_snapshot (out previous_text, out previous_icon, out previous_css);
        string verification_status = "Verifying audio copy compatibility before conversion...";
        status_area.set_status (verification_status,
            StatusIcon.WAITING_ICON, StatusIcon.WAITING_CSS);

        AudioStreamProbeResult audio_probe =
            yield FfprobeUtils.probe_primary_audio_stream_async (input_file, cancellable);

        if (cancellable.is_cancelled ()) {
            return AudioCopyUnknownPreflightResult.CANCELLED;
        }

        controller.apply_codec_audio_probe_result (audio_probe);

        switch (audio_probe.presence) {
            case MediaStreamPresence.PRESENT:
                if (!AudioSettings.container_supports_audio_copy (container, audio_probe.codec_name)) {
                    string fallback_codec =
                        AudioSettings.get_copy_fallback_codec_for_container (container);
                    string container_label = container.up ();
                    status_area.set_status (
                        "Source audio cannot be copied into %s. Switched audio to %s."
                        .printf (container_label, fallback_codec),
                        StatusIcon.NOTICE_ICON, StatusIcon.NOTICE_CSS
                    );
                    console_tab.add_line (
                        "[Audio] Verified source audio is incompatible with %s copy; switched to %s."
                        .printf (container_label, fallback_codec)
                    );
                } else {
                    status_area.replace_status_if_current (
                        verification_status, previous_text, previous_icon, previous_css);
                }
                return AudioCopyUnknownPreflightResult.PROCEED;
            case MediaStreamPresence.ABSENT:
                status_area.set_status (
                    "No audio stream was found during final verification. Continuing without audio.",
                    StatusIcon.NOTICE_ICON, StatusIcon.NOTICE_CSS
                );
                console_tab.add_line (
                    "[Audio] Final compatibility check found no audio stream; conversion will continue without audio."
                );
                return AudioCopyUnknownPreflightResult.PROCEED;
            case MediaStreamPresence.UNKNOWN:
            default:
                string fallback_codec =
                    AudioSettings.get_copy_fallback_codec_for_container (container);
                status_area.set_status (
                    "Unable to verify whether source audio can be copied into %s. Select %s manually or try again."
                    .printf (container.up (), fallback_codec),
                    StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS
                );
                console_tab.add_line (
                    "[Audio] Final compatibility check could not verify whether source audio can be copied into %s."
                    .printf (container.up ())
                );
                return AudioCopyUnknownPreflightResult.BLOCK;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UNIFIED OVERWRITE DIALOG
    //
    //
    //   • offer_rename = true  → Cancel / Auto-Rename / Overwrite
    //   • offer_rename = false → Cancel / Overwrite
    //
    //  Callers pass callbacks for what should happen on each choice.
    // ═════════════════════════════════════════════════════════════════════════

    private delegate void OverwriteCallback ();

    private void confirm_overwrite (string output_path,
                                    bool offer_rename,
                                    owned OverwriteCallback on_overwrite,
                                    owned OverwriteCallback? on_rename = null,
                                    owned OverwriteCallback? on_cancel = null) {
        string basename = Path.get_basename (output_path);

        var dialog = new Adw.AlertDialog (
            "File Already Exists",
            @"\"$basename\" already exists in the output folder.\n\nWhat would you like to do?"
        );

        dialog.add_response ("cancel", "Cancel");

        if (offer_rename) {
            dialog.add_response ("rename", "Auto-Rename");
            dialog.set_response_appearance ("rename", Adw.ResponseAppearance.SUGGESTED);
            dialog.set_default_response ("rename");
        } else {
            dialog.set_default_response ("cancel");
        }

        dialog.add_response ("overwrite", "Overwrite");
        dialog.set_response_appearance ("overwrite", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_close_response ("cancel");

        choose_preflight_dialog (dialog, (response) => {
            if (response == "overwrite") {
                on_overwrite ();
            } else if (response == "rename" && on_rename != null) {
                on_rename ();
            } else if (on_cancel != null) {
                on_cancel ();
            }
        });
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  OPERATION LIFECYCLE HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    private void launch_subtitle_apply (uint64 operation_id,
                                        bool allow_overwrite = false) {
        if (!is_pending_operation (ActiveOperation.SUBTITLE_APPLY, operation_id)) {
            return;
        }

        if (!subtitles_tab.start_apply (operation_id, allow_overwrite)) {
            release_pending_operation (ActiveOperation.SUBTITLE_APPLY, operation_id, true);
            return;
        }

        activate_cancel (ActiveOperation.SUBTITLE_APPLY, operation_id);
    }

    private void launch_trim_export (TrimTab trim,
                                     string input_file,
                                     string output_folder,
                                     uint64 operation_id,
                                     TrimOutputConflictPolicy output_policy) {
        if (!is_pending_operation (ActiveOperation.TRIMMING, operation_id)) {
            return;
        }

        if (!trim.start_trim_export (
                input_file,
                output_folder,
                status_area,
                console_tab,
                operation_id,
                output_policy)) {
            release_pending_operation (ActiveOperation.TRIMMING, operation_id, true);
            return;
        }

        activate_cancel (ActiveOperation.TRIMMING, operation_id);
    }

    private uint64 reserve_operation_id () {
        return next_operation_id++;
    }

    private void choose_preflight_dialog (Adw.AlertDialog dialog,
                                          owned DialogResponseCallback on_response) {
        var cancellable = new Cancellable ();
        active_preflight_dialog = dialog;
        active_preflight_dialog_cancellable = cancellable;

        dialog.choose.begin (this, cancellable, (obj, res) => {
            if (active_preflight_dialog == dialog
                && active_preflight_dialog_cancellable == cancellable) {
                active_preflight_dialog = null;
                active_preflight_dialog_cancellable = null;
            }

            string response = dialog.choose.end (res);
            on_response (response);
        });
    }

    private void dismiss_active_preflight_dialog () {
        Cancellable? cancellable = active_preflight_dialog_cancellable;
        Adw.AlertDialog? dialog = active_preflight_dialog;

        active_preflight_dialog_cancellable = null;
        active_preflight_dialog = null;

        if (cancellable != null) {
            cancellable.cancel ();
        }

        if (dialog != null) {
            dialog.force_close ();
        }
    }

    private Cancellable begin_preflight_probe () {
        cancel_active_preflight_probe ();
        var cancellable = new Cancellable ();
        active_preflight_probe_cancellable = cancellable;
        return cancellable;
    }

    private void finish_preflight_probe (Cancellable cancellable) {
        if (active_preflight_probe_cancellable == cancellable) {
            active_preflight_probe_cancellable = null;
        }
    }

    private void cancel_active_preflight_probe () {
        Cancellable? cancellable = active_preflight_probe_cancellable;
        active_preflight_probe_cancellable = null;

        if (cancellable != null) {
            cancellable.cancel ();
        }
    }

    private bool reserve_pending_operation (ActiveOperation operation,
                                            out uint64 operation_id) {
        operation_id = 0;

        if (current_operation != ActiveOperation.IDLE) {
            return false;
        }

        operation_id = reserve_operation_id ();
        current_operation = operation;
        active_operation_id = operation_id;
        operation_launch_pending = true;
        update_subtitle_operation_lock ();
        update_cancel_button_state ();
        update_convert_sensitivity ();
        return true;
    }

    private bool is_pending_operation (ActiveOperation operation, uint64 operation_id) {
        return operation_launch_pending
            && current_operation == operation
            && active_operation_id == operation_id;
    }

    private bool release_pending_operation (ActiveOperation operation,
                                            uint64 operation_id,
                                            bool drain_auto_convert_queue) {
        if (!is_pending_operation (operation, operation_id)) {
            return false;
        }

        reset_tracked_operation_state ();

        if (drain_auto_convert_queue) {
            drain_pending_auto_convert ();
        }

        return true;
    }

    /** Record the active operation and update the Cancel button. */
    private void activate_cancel (ActiveOperation operation, uint64 operation_id) {
        current_operation = operation;
        active_operation_id = operation_id;
        operation_launch_pending = false;
        update_subtitle_operation_lock ();
        update_cancel_button_state ();
        update_convert_sensitivity ();
    }

    private bool complete_tracked_operation (ActiveOperation operation,
                                             uint64 operation_id,
                                             bool drain_auto_convert_queue) {
        if (current_operation != operation || active_operation_id != operation_id) {
            return false;
        }

        reset_tracked_operation_state ();

        if (drain_auto_convert_queue) {
            drain_pending_auto_convert ();
        }

        return true;
    }

    private void reset_tracked_operation_state () {
        current_operation = ActiveOperation.IDLE;
        active_operation_id = 0;
        operation_launch_pending = false;
        update_subtitle_operation_lock ();
        update_cancel_button_state ();
        update_convert_sensitivity ();
    }

    private void maybe_finish_close_after_cancellation () {
        if (!close_after_cancellation) {
            return;
        }

        if (current_operation != ActiveOperation.IDLE || smart_optimizer_active) {
            return;
        }

        close_after_cancellation = false;
        destroy ();
    }

    private void update_cancel_button_state () {
        cancel_button.set_sensitive (
            smart_optimizer_active
            || current_operation != ActiveOperation.IDLE
        );
    }

    private void update_subtitle_operation_lock () {
        subtitles_tab.set_operation_locked (current_operation != ActiveOperation.IDLE);
    }

    /** If Smart Optimizer queued an auto-convert while busy, start it now. */
    private void drain_pending_auto_convert () {
        string? codec = pending_auto_convert_codec;
        if (codec == null) return;

        if (!can_start_primary_operation ()) {
            return;
        }

        pending_auto_convert_codec = null;
        view_stack.set_visible_child_name (codec);
        on_convert_clicked ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  USER ACTIONS — Cancel
    //
    //  Dispatches to the correct cancel target for the tracked operation.
    // ═════════════════════════════════════════════════════════════════════════

    private void on_cancel_clicked () {
        string? message = cancel_current_operation ();
        if (message != null) {
            status_area.set_status (message,
                StatusIcon.CANCELLED_ICON, StatusIcon.CANCELLED_CSS);
            console_tab.add_line (message);
        }
    }

    /**
     * Cancel whatever operation is currently running.
     * Returns a status message describing what was cancelled, or null if idle.
     */
    private string? cancel_current_operation () {
        string? message = null;
        bool should_release_operation = true;

        cancel_active_preflight_probe ();
        dismiss_active_preflight_dialog ();

        if (operation_launch_pending) {
            message = @"Pending $(get_operation_label (current_operation)) cancelled by user.";
        } else {
            switch (current_operation) {
                case ActiveOperation.SUBTITLE_EXTRACT:
                case ActiveOperation.SUBTITLE_APPLY:
                    subtitles_tab.cancel_operation ();
                    message = "Subtitle operation cancelled by user.";
                    should_release_operation = false;
                    break;

                case ActiveOperation.TRIMMING:
                    trim_tab.cancel_trim ();
                    message = "Export cancelled by user.";
                    should_release_operation = false;
                    break;

                case ActiveOperation.CONVERTING:
                    converter.cancel ();
                    should_release_operation = false;
                    break;

                default:
                    break;
            }
        }

        // Always cancel the optimizer too — it can run alongside other operations.
        if (smart_optimizer_active) {
            controller.cancel_smart_optimizer ();
            if (message == null && current_operation == ActiveOperation.IDLE) {
                message = "Smart Optimizer cancelled by user.";
            }
        }

        if (should_release_operation) {
            current_operation = ActiveOperation.IDLE;
            active_operation_id = 0;
            operation_launch_pending = false;
            update_cancel_button_state ();
            update_convert_sensitivity ();
        }
        pending_auto_convert_codec = null;
        return message;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CLOSE REQUEST — Prevent orphaned FFmpeg processes
    //
    //  If an operation is running, intercept the window close, present a
    //  confirmation dialog, and only close after cancellation completes.
    //  When idle, allow the close immediately.
    // ═════════════════════════════════════════════════════════════════════════

    private bool on_close_request () {
        if (close_after_cancellation) {
            return true;
        }

        if (current_operation == ActiveOperation.IDLE && !smart_optimizer_active) {
            return false;  // No operation running — allow close
        }

        // Prevent stacking multiple confirmation dialogs
        if (close_dialog_open) return true;
        close_dialog_open = true;

        string operation_label = get_operation_label (
            current_operation,
            smart_optimizer_active ? "optimization" : "operation");

        var dialog = new Adw.AlertDialog (
            "Operation in Progress",
            operation_launch_pending
                ? @"A $operation_label is being prepared.\n\nClosing now will cancel it."
                : @"A $operation_label is currently running.\n\nClosing now will cancel it and may leave incomplete output files."
        );

        dialog.add_response ("stay", "Keep Working");
        dialog.add_response ("quit", "Cancel & Quit");
        dialog.set_response_appearance ("quit", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_default_response ("stay");
        dialog.set_close_response ("stay");

        dialog.choose.begin (this, null, (obj, res) => {
            string response = dialog.choose.end (res);
            close_dialog_open = false;

            if (response == "quit") {
                force_cancel_and_close ();
            }
        });

        return true;  // Block close — dialog will handle it
    }

    /**
     * Cancel any running operation and destroy the window.
     *
     * Called when the user confirms "Cancel & Quit" from the close dialog.
     * Dispatches cancellation to the correct target (same logic as
     * on_cancel_clicked) and then closes the window.
     */
    private void force_cancel_and_close () {
        cancel_current_operation ();
        close_after_cancellation = true;
        maybe_finish_close_after_cancellation ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  TOAST NOTIFICATIONS — Non-intrusive success / error overlays
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Post a success toast with an optional "Open Folder" action button.
     * Also sends a system notification so the user is informed when the app
     * is in the background or unfocused.
     */
    private void post_success_toast (string title, OperationOutputResult output_result) {
        string detail = output_result.get_display_label ();

        // ── In-app toast ─────────────────────────────────────────────────────
        var toast = new Adw.Toast (@"$title — $detail");
        toast.set_timeout (5);

        string folder_path = output_result.get_open_folder_target ();
        if (folder_path.length > 0 && FileUtils.test (folder_path, FileTest.IS_DIR)) {
            toast.set_button_label ("Open Folder");
            toast.button_clicked.connect (() => {
                try {
                    var folder = File.new_for_path (folder_path);
                    AppInfo.launch_default_for_uri (folder.get_uri (), null);
                } catch (Error e) {
                    warning ("Failed to open folder: %s", e.message);
                }
            });
        }

        toast_overlay.add_toast (toast);

        // ── System notification (visible when the app is unfocused) ──────────
        send_system_notification (title, output_result);
    }

    /**
     * Send a desktop notification via GLib.Notification.
     *
     * Integrates with the GNOME / freedesktop notification daemon so the
     * user is informed even when the window is minimized or another app
     * has focus. The action button adapts to the result type: single-file
     * outputs get "View", while directory or multi-file outputs get
     * "Open Folder".
     */
    private void send_system_notification (string title, OperationOutputResult output_result) {
        var app = (GLib.Application) get_application ();
        if (app == null) return;

        var notification = new GLib.Notification (title);
        notification.set_body (output_result.get_notification_body ());

        if (output_result.primary_file_path.length > 0
            && !output_result.prefers_folder_action ()) {
            notification.add_button ("View", "app.view-output");
        } else if (output_result.get_open_folder_target ().length > 0) {
            notification.add_button ("Open Folder", "app.open-output-folder");
        }

        app.send_notification ("operation-complete", notification);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Application entry point
//
//  activate fires on every activation — including when the user clicks the
//  dock icon while the app is already running.  We check for an existing
//  window and just present it, rather than spawning a duplicate.
// ═══════════════════════════════════════════════════════════════════════════════

int main (string[] args) {
    var app = new Adw.Application ("com.github.pieman.FFmpegConverterGTK", ApplicationFlags.DEFAULT_FLAGS);

    app.activate.connect (() => {
        var win = app.get_active_window () as MainWindow;
        if (win == null) {
            win = new MainWindow (app);
        }
        win.present ();
    });

    return app.run (args);
}
