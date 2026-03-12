using Gtk;
using Adw;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  ActiveOperation — Tracks which operation is running for clean cancellation
//
//  Instead of interrogating three different objects (subtitles_tab.is_busy,
//  trim_tab.is_exporting, converter) to figure out what to cancel, we
//  explicitly track which operation was started.  This eliminates the implicit
//  priority chain and ensures cancel always dispatches to the right target.
// ═══════════════════════════════════════════════════════════════════════════════

private enum ActiveOperation {
    IDLE,
    CONVERTING,
    TRIMMING,
    SUBTITLE_APPLY
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
    private BaseCodecTab? general_tab_sync_owner = null;

    // Prevent GC from collecting the controller
    private AppController controller;

    // Explicit operation tracking for clean cancel dispatch
    private ActiveOperation current_operation = ActiveOperation.IDLE;
    private uint64 active_operation_id = 0;
    private uint64 next_operation_id = 1;

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
        });

        // Auto-convert: Smart Optimizer requests conversion start.
        // Ensure the correct codec tab is visible (user may have switched
        // tabs while the optimizer was analyzing).  If another operation is
        // still running, queue the codec so conversion starts when idle.
        controller.auto_convert_requested.connect ((codec) => {
            if (current_operation == ActiveOperation.IDLE) {
                view_stack.set_visible_child_name (codec);
                on_convert_clicked ();
            } else {
                pending_auto_convert_codec = codec;
                status_area.set_status ("⏳ Auto-convert queued for %s — waiting for current operation…".printf (codec.up ()));
            }
        });

        // Reset operation state only for the specific run MainWindow started.
        // AppController separately handles output-info and hamburger updates
        // via the legacy success signals.
        converter.conversion_succeeded.connect ((operation_id, output_path) => {
            if (!complete_tracked_operation (
                    ActiveOperation.CONVERTING, operation_id, true)) {
                return;
            }

            post_success_toast ("Conversion complete", output_path);
        });
        converter.conversion_failed.connect ((operation_id) => {
            complete_tracked_operation (ActiveOperation.CONVERTING, operation_id, true);
        });
        trim_tab.trim_succeeded.connect ((operation_id, output_path) => {
            if (!complete_tracked_operation (
                    ActiveOperation.TRIMMING, operation_id, true)) {
                return;
            }

            post_success_toast ("Export complete", output_path);
        });
        trim_tab.trim_failed.connect ((operation_id) => {
            complete_tracked_operation (ActiveOperation.TRIMMING, operation_id, true);
        });
        subtitles_tab.subtitle_apply_succeeded.connect ((operation_id, output_path) => {
            if (!complete_tracked_operation (
                    ActiveOperation.SUBTITLE_APPLY, operation_id, true)) {
                return;
            }

            post_success_toast ("Subtitles applied", output_path);
        });
        subtitles_tab.subtitle_apply_failed.connect ((operation_id) => {
            complete_tracked_operation (ActiveOperation.SUBTITLE_APPLY, operation_id, true);
        });

        // ── Close-request guard: prevent orphaned FFmpeg processes ────────
        close_request.connect (on_close_request);
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
        svt_tab.general_tab = general_tab;
        x265_tab     = new X265Tab ();
        x265_tab.general_tab = general_tab;
        x264_tab     = new X264Tab ();
        x264_tab.general_tab = general_tab;
        vp9_tab      = new Vp9Tab ();
        vp9_tab.general_tab = general_tab;
        info_tab     = new InformationTab ();
        console_tab  = new ConsoleTab ();
        status_area  = new StatusArea ();

        trim_tab = new TrimTab ();
        trim_tab.general_tab = general_tab;
        trim_tab.svt_tab     = svt_tab;
        trim_tab.x265_tab   = x265_tab;
        trim_tab.x264_tab   = x264_tab;
        trim_tab.vp9_tab    = vp9_tab;
        trim_tab.general_tab_context_changed.connect (() => {
            if (view_stack != null && view_stack.visible_child_name == "trim") {
                update_general_tab_sync_owner ();
            }
        });

        subtitles_tab = new SubtitlesTab ();
        subtitles_tab.file_pickers = file_pickers;
        subtitles_tab.general_tab  = general_tab;
        subtitles_tab.svt_tab      = svt_tab;
        subtitles_tab.x265_tab     = x265_tab;
        subtitles_tab.x264_tab     = x264_tab;
        subtitles_tab.vp9_tab      = vp9_tab;
        subtitles_tab.general_tab_context_changed.connect (() => {
            if (view_stack != null && view_stack.visible_child_name == "subtitles") {
                update_general_tab_sync_owner ();
            }
        });
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
            update_general_tab_sync_owner ();
        });
        update_convert_sensitivity ();
        update_general_tab_sync_owner ();
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
        convert_button.set_sensitive (active && current_operation == ActiveOperation.IDLE);
    }

    private string get_operation_label (ActiveOperation operation,
                                        string idle_fallback = "operation") {
        switch (operation) {
            case ActiveOperation.CONVERTING:     return "conversion";
            case ActiveOperation.TRIMMING:       return "export";
            case ActiveOperation.SUBTITLE_APPLY: return "subtitle apply";
            default:                             return idle_fallback;
        }
    }

    private void set_general_format_options (DropDown dropdown,
                                             string[] options,
                                             string fallback_option) {
        CodecUtils.set_dropdown_options (dropdown, options, fallback_option);
    }

    private void restore_general_tab_format_options () {
        set_general_format_options (general_tab.eight_bit_format,
                                    { "8-bit 4:2:0", "8-bit 4:2:2", "8-bit 4:4:4" },
                                    "8-bit 4:2:0");
        set_general_format_options (general_tab.ten_bit_format,
                                    { "10-bit 4:2:0", "10-bit 4:2:2", "10-bit 4:4:4" },
                                    "10-bit 4:2:0");
    }

    private void update_general_tab_sync_owner () {
        string? page = view_stack.visible_child_name;

        if (page == "svt-av1") {
            general_tab_sync_owner = svt_tab;
        } else if (page == "x265") {
            general_tab_sync_owner = x265_tab;
        } else if (page == "x264") {
            general_tab_sync_owner = x264_tab;
        } else if (page == "vp9") {
            general_tab_sync_owner = vp9_tab;
        } else if (page == "trim") {
            general_tab_sync_owner = trim_tab.get_general_tab_sync_owner ();
        } else if (page == "subtitles") {
            general_tab_sync_owner = subtitles_tab.get_general_tab_sync_owner ();
        } else if (page != "general") {
            general_tab_sync_owner = null;
        }

        svt_tab.general_tab_sync_active = (general_tab_sync_owner == svt_tab);
        x265_tab.general_tab_sync_active = (general_tab_sync_owner == x265_tab);
        x264_tab.general_tab_sync_active = (general_tab_sync_owner == x264_tab);
        vp9_tab.general_tab_sync_active = (general_tab_sync_owner == vp9_tab);

        if (general_tab_sync_owner != null) {
            general_tab_sync_owner.sync_general_tab_now ();
        } else {
            restore_general_tab_format_options ();
        }
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
        if (current_operation != ActiveOperation.IDLE) {
            status_area.set_status (
                @"⚠️ A $(get_operation_label (current_operation)) is already running. Cancel it before starting another one."
            );
            return;
        }

        string? page = view_stack.visible_child_name;

        // ── Subtitles has its own path (remux / burn-in, no codec tab) ────
        if (page == "subtitles") {
            start_subtitle_apply ();
            return;
        }

        // ── Look up the codec tab for all other convertible pages ─────────
        ICodecTab? codec_tab = lookup_codec_tab (page);
        if (codec_tab == null) {
            status_area.set_status (
                "⚠️ Please select a codec tab (SVT-AV1, x265, x264, VP9, Crop & Trim, or Subtitles) first!");
            return;
        }

        // ── Validate input file early (covers both trim and codec paths) ──
        string input_file = file_pickers.input_entry.get_text ();
        if (input_file == "") {
            status_area.set_status ("⚠️ Please select an input file first!");
            return;
        }

        // ── Dispatch to the appropriate conversion path ───────────────────
        if (codec_tab is TrimTab) {
            start_trim_operation ((TrimTab) codec_tab, input_file);
        } else {
            start_codec_conversion (input_file, codec_tab);
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

    private delegate void ProceedCallback ();

    private int get_cached_input_bit_depth (string input_file) {
        if (input_file == "")
            return 0;

        ConversionUtils.FileSignature? current_signature =
            ConversionUtils.query_file_signature (input_file);

        if (current_signature != null) {
            var cached_entry = cached_input_bit_depth.lookup (current_signature);
            if (cached_entry != null && cached_entry.value > 0)
                return cached_entry.value;
        }

        int probed_bits = FfprobeUtils.probe_video_bit_depth (input_file);
        if (probed_bits > 0 && current_signature != null) {
            cached_input_bit_depth.store (current_signature, probed_bits);
        }

        return probed_bits;
    }

    private bool get_implicit_depth_warning (string input_file,
                                             out string source_depth,
                                             out string fallback_depth) {
        source_depth = "";
        fallback_depth = "";

        if (general_tab.eight_bit_check.active || general_tab.ten_bit_check.active)
            return false;

        int source_bits = get_cached_input_bit_depth (input_file);
        if (source_bits <= 8)
            return false;

        source_depth = "%d-bit".printf (source_bits);
        fallback_depth = "8-bit";
        return true;
    }

    private void maybe_warn_implicit_depth_downgrade (string input_file,
                                                      owned ProceedCallback on_continue) {
        string source_depth;
        string fallback_depth;
        if (!get_implicit_depth_warning (input_file, out source_depth, out fallback_depth)) {
            on_continue ();
            return;
        }

        var dialog = new Adw.AlertDialog (
            "Output Bit Depth Is Unset",
            @"The source video appears to be $source_depth, but no output bit depth is selected in the General tab.\n\nDepending on the encoder, FFmpeg may fall back to $fallback_depth unless you explicitly enable 10-Bit Color."
        );

        dialog.add_response ("cancel", "Cancel");
        dialog.add_response ("continue", "Continue");
        dialog.set_response_appearance ("continue", Adw.ResponseAppearance.SUGGESTED);
        dialog.set_default_response ("continue");
        dialog.set_close_response ("cancel");

        dialog.choose.begin (this, null, (obj, res) => {
            string response = dialog.choose.end (res);
            if (response == "continue")
                on_continue ();
        });
    }

    private bool get_svt_av1_chroma_warning (out string requested_format,
                                             out string effective_format) {
        requested_format = "";
        effective_format = "";

        if (general_tab.ten_bit_check.active) {
            requested_format = CodecUtils.get_dropdown_text (general_tab.ten_bit_format);
            effective_format = "10-bit 4:2:0";
        } else if (general_tab.eight_bit_check.active) {
            requested_format = CodecUtils.get_dropdown_text (general_tab.eight_bit_format);
            effective_format = "8-bit 4:2:0";
        } else {
            return false;
        }

        return !requested_format.contains (Chroma.C420);
    }

    private void maybe_warn_svt_av1_chroma_downgrade (owned ProceedCallback on_continue) {
        string requested_format;
        string effective_format;
        if (!get_svt_av1_chroma_warning (out requested_format, out effective_format)) {
            on_continue ();
            return;
        }

        var dialog = new Adw.AlertDialog (
            "SVT-AV1 Will Encode as 4:2:0",
            @"The General tab is set to $requested_format, but SVT-AV1 in this app/runtime encodes as $effective_format.\n\nIf you continue, the output will use $effective_format."
        );

        dialog.add_response ("cancel", "Cancel");
        dialog.add_response ("continue", @"Convert as $effective_format");
        dialog.set_response_appearance ("continue", Adw.ResponseAppearance.SUGGESTED);
        dialog.set_default_response ("continue");
        dialog.set_close_response ("cancel");

        dialog.choose.begin (this, null, (obj, res) => {
            string response = dialog.choose.end (res);
            if (response == "continue")
                on_continue ();
        });
    }

    // ── Subtitles path ───────────────────────────────────────────────────────

    private void start_subtitle_apply () {
        if (!subtitles_tab.can_apply ()) {
            status_area.set_status (
                "⚠️ Load a file with subtitle tracks or add external subtitles first!");
            return;
        }

        if (subtitles_tab.is_burn_in_mode ()) {
            string input_file = subtitles_tab.get_input_file ();
            maybe_warn_implicit_depth_downgrade (input_file, () => {
                if (subtitles_tab.will_use_svt_av1_burn_in ()) {
                    maybe_warn_svt_av1_chroma_downgrade (() => {
                        continue_start_subtitle_apply ();
                    });
                    return;
                }

                continue_start_subtitle_apply ();
            });
            return;
        }

        continue_start_subtitle_apply ();
    }

    private void continue_start_subtitle_apply () {
        var settings = AppSettings.get_default ();
        string expected = subtitles_tab.get_expected_output_path ();

        if (settings.overwrite_enabled) {
            // Overwrite protection disabled — always proceed directly
            launch_subtitle_apply (true);
        } else if (expected != "" && FileUtils.test (expected, FileTest.EXISTS)) {
            confirm_overwrite (expected, true,
                () => {
                    launch_subtitle_apply (true);
                },
                () => {
                    launch_subtitle_apply (false);
                }
            );
        } else {
            launch_subtitle_apply ();
        }
    }

    // ── Crop & Trim path ─────────────────────────────────────────────────────

    private void start_trim_operation (TrimTab trim, string input_file) {
        if (!trim.will_reencode_output ()) {
            continue_start_trim_operation (trim, input_file);
            return;
        }

        maybe_warn_implicit_depth_downgrade (input_file, () => {
            if (trim.will_use_svt_av1_reencode ()) {
                maybe_warn_svt_av1_chroma_downgrade (() => {
                    continue_start_trim_operation (trim, input_file);
                });
                return;
            }

            continue_start_trim_operation (trim, input_file);
        });
    }

    private void continue_start_trim_operation (TrimTab trim, string input_file) {
        string out_folder = file_pickers.output_entry.get_text ();
        string expected = trim.get_expected_output_path (input_file, out_folder);

        var settings = AppSettings.get_default ();

        if (settings.overwrite_enabled) {
            // Overwrite protection disabled — always proceed directly
            launch_trim_export (trim, input_file, out_folder);
        } else if (expected != "" && FileUtils.test (expected, FileTest.EXISTS)) {
            confirm_overwrite (expected, false,
                () => {
                    launch_trim_export (trim, input_file, out_folder);
                }
            );
        } else {
            launch_trim_export (trim, input_file, out_folder);
        }
    }

    // ── Normal codec conversion path ─────────────────────────────────────────

    private void start_codec_conversion (string input_file, ICodecTab codec_tab) {
        maybe_warn_implicit_depth_downgrade (input_file, () => {
            if (codec_tab is SvtAv1Tab) {
                maybe_warn_svt_av1_chroma_downgrade (() => {
                    continue_start_codec_conversion (input_file, codec_tab);
                });
                return;
            }

            continue_start_codec_conversion (input_file, codec_tab);
        });
    }

    private void continue_start_codec_conversion (string input_file, ICodecTab codec_tab) {
        ICodecBuilder builder = codec_tab.get_codec_builder ();

        string output_file = Converter.compute_output_path (
            input_file,
            file_pickers.output_entry.get_text (),
            builder,
            codec_tab
        );

        var settings = AppSettings.get_default ();

        if (settings.overwrite_enabled) {
            // Overwrite protection disabled — always proceed directly
            begin_conversion (input_file, output_file, codec_tab, builder);
        } else if (FileUtils.test (output_file, FileTest.EXISTS)) {
            confirm_overwrite (output_file, true,
                () => { begin_conversion (input_file, output_file, codec_tab, builder); },
                () => {
                    string unique = Converter.find_unique_path (output_file);
                    begin_conversion (input_file, unique, codec_tab, builder);
                }
            );
        } else {
            begin_conversion (input_file, output_file, codec_tab, builder);
        }
    }

    private void begin_conversion (string input_file,
                                   string output_file,
                                   ICodecTab codec_tab,
                                   ICodecBuilder builder) {
        uint64 operation_id = reserve_operation_id ();
        if (!converter.start_conversion (
                input_file, output_file, codec_tab, builder, operation_id)) {
            return;
        }

        activate_cancel (ActiveOperation.CONVERTING, operation_id);
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
                                    owned OverwriteCallback? on_rename = null) {
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

        dialog.choose.begin (this, null, (obj, res) => {
            string response = dialog.choose.end (res);

            if (response == "overwrite") {
                on_overwrite ();
            } else if (response == "rename" && on_rename != null) {
                on_rename ();
            }
        });
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  OPERATION LIFECYCLE HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    private void launch_subtitle_apply (bool allow_overwrite = false) {
        uint64 operation_id = reserve_operation_id ();
        if (!subtitles_tab.start_apply (operation_id, allow_overwrite)) {
            return;
        }

        activate_cancel (ActiveOperation.SUBTITLE_APPLY, operation_id);
    }

    private void launch_trim_export (TrimTab trim,
                                     string input_file,
                                     string output_folder) {
        uint64 operation_id = reserve_operation_id ();
        if (!trim.start_trim_export (
                input_file, output_folder, status_area, console_tab, operation_id)) {
            return;
        }

        activate_cancel (ActiveOperation.TRIMMING, operation_id);
    }

    private uint64 reserve_operation_id () {
        return next_operation_id++;
    }

    /** Record the active operation and update the Cancel button. */
    private void activate_cancel (ActiveOperation operation, uint64 operation_id) {
        current_operation = operation;
        active_operation_id = operation_id;
        update_cancel_button_state ();
        update_convert_sensitivity ();
    }

    private bool complete_tracked_operation (ActiveOperation operation,
                                             uint64 operation_id,
                                             bool drain_auto_convert_queue) {
        if (current_operation != operation || active_operation_id != operation_id) {
            return false;
        }

        current_operation = ActiveOperation.IDLE;
        active_operation_id = 0;
        update_cancel_button_state ();
        update_convert_sensitivity ();

        if (drain_auto_convert_queue) {
            drain_pending_auto_convert ();
        }

        return true;
    }

    private void update_cancel_button_state () {
        cancel_button.set_sensitive (
            smart_optimizer_active || current_operation != ActiveOperation.IDLE
        );
    }

    /** If Smart Optimizer queued an auto-convert while busy, start it now. */
    private void drain_pending_auto_convert () {
        string? codec = pending_auto_convert_codec;
        if (codec == null) return;
        pending_auto_convert_codec = null;

        if (current_operation == ActiveOperation.IDLE) {
            view_stack.set_visible_child_name (codec);
            on_convert_clicked ();
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  USER ACTIONS — Cancel
    //
    //  Dispatches to the correct cancel target based on the tracked
    //  operation, instead of probing multiple objects to guess which
    //  one is active.
    // ═════════════════════════════════════════════════════════════════════════

    private void on_cancel_clicked () {
        string? message = cancel_current_operation ();
        if (message != null) {
            status_area.set_status (message);
        }
    }

    /**
     * Cancel whatever operation is currently running.
     * Returns a status message describing what was cancelled, or null if idle.
     */
    private string? cancel_current_operation () {
        string? message = null;

        switch (current_operation) {
            case ActiveOperation.SUBTITLE_APPLY:
                subtitles_tab.cancel_operation ();
                message = "⏹️ Subtitle operation cancelled by user.";
                break;

            case ActiveOperation.TRIMMING:
                trim_tab.cancel_trim ();
                message = "⏹️ Export cancelled by user.";
                break;

            case ActiveOperation.CONVERTING:
                converter.cancel ();
                message = "⏹️ Conversion cancelled by user.";
                break;

            default:
                break;
        }

        // Always cancel the optimizer too — it can run alongside other operations.
        if (smart_optimizer_active) {
            controller.cancel_smart_optimizer ();
            smart_optimizer_active = false;
            if (message == null) {
                message = "⏹️ Smart Optimizer cancelled by user.";
            }
        }

        current_operation = ActiveOperation.IDLE;
        active_operation_id = 0;
        update_cancel_button_state ();
        update_convert_sensitivity ();
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
        if (current_operation == ActiveOperation.IDLE && !smart_optimizer_active) {
            return false;  // No operation running — allow close
        }

        // Prevent stacking multiple confirmation dialogs
        if (close_dialog_open) return true;
        close_dialog_open = true;

        string operation_label = get_operation_label (
            current_operation,
            smart_optimizer_active ? "optimization" : "operation"
        );

        var dialog = new Adw.AlertDialog (
            "Operation in Progress",
            @"A $operation_label is currently running.\n\nClosing now will cancel it and may leave incomplete output files."
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

        // Allow a moment for the subprocess SIGTERM to land, then close.
        Timeout.add (150, () => {
            destroy ();
            return Source.REMOVE;
        });
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  TOAST NOTIFICATIONS — Non-intrusive success / error overlays
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Post a success toast with an optional "Open Folder" action button.
     * Also sends a system notification so the user is informed when the app
     * is in the background or unfocused.
     */
    private void post_success_toast (string title, string output_path) {
        string basename = Path.get_basename (output_path);

        // ── In-app toast ─────────────────────────────────────────────────────
        var toast = new Adw.Toast (@"$title — $basename");
        toast.set_timeout (5);

        // "Open Folder" action to reveal the file in the system file manager
        // If output_path is itself a directory (e.g. extract-all), open it directly
        string parent_dir = FileUtils.test (output_path, FileTest.IS_DIR)
            ? output_path
            : Path.get_dirname (output_path);
        if (parent_dir.length > 0 && FileUtils.test (parent_dir, FileTest.IS_DIR)) {
            toast.set_button_label ("Open Folder");
            toast.button_clicked.connect (() => {
                try {
                    var folder = File.new_for_path (parent_dir);
                    AppInfo.launch_default_for_uri (folder.get_uri (), null);
                } catch (Error e) {
                    warning ("Failed to open folder: %s", e.message);
                }
            });
        }

        toast_overlay.add_toast (toast);

        // ── System notification (visible when the app is unfocused) ──────────
        send_system_notification (title, basename, output_path);
    }

    /**
     * Send a desktop notification via GLib.Notification.
     *
     * Integrates with the GNOME / freedesktop notification daemon so the
     * user is informed even when the window is minimized or another app
     * has focus.  The notification's default action brings the window to
     * the foreground; the "View" button opens the output in the default
     * video player.
     */
    private void send_system_notification (string title, string basename, string output_path) {
        var app = (GLib.Application) get_application ();
        if (app == null) return;

        var notification = new GLib.Notification (title);
        notification.set_body (@"$basename is ready.");

        // "View" button → open the output file with the default video player.
        // Clicking the notification body itself activates the app (built-in
        // GApplication behavior — no explicit action needed).
        notification.add_button ("View", "app.view-output");

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
