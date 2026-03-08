using Gtk;
using Adw;

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

    // Prevent GC from collecting the controller
    private AppController controller;

    // Explicit operation tracking for clean cancel dispatch
    private ActiveOperation current_operation = ActiveOperation.IDLE;

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

        // Auto-convert: Smart Optimizer requests conversion start.
        // Ensure the correct codec tab is visible (user may have switched
        // tabs while the optimizer was analyzing), and guard against the
        // unlikely case where another operation started concurrently.
        controller.auto_convert_requested.connect ((codec) => {
            if (current_operation == ActiveOperation.IDLE) {
                view_stack.set_visible_child_name (codec);
                on_convert_clicked ();
            }
        });

        // Reset operation state when any operation completes.
        // (AppController separately handles info_tab, hamburger, and
        // cancel_button for these same signals — multiple handlers are fine.)
        converter.conversion_done.connect ((output_path) => {
            current_operation = ActiveOperation.IDLE;
            post_success_toast ("Conversion complete", output_path);
        });
        trim_tab.trim_done.connect ((output_path) => {
            current_operation = ActiveOperation.IDLE;
            post_success_toast ("Export complete", output_path);
        });
        subtitles_tab.subtitle_done.connect ((output_path) => {
            current_operation = ActiveOperation.IDLE;
            post_success_toast ("Subtitles applied", output_path);
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
        view_stack.notify["visible-child-name"].connect (update_convert_sensitivity);
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
        convert_button.set_sensitive (active);
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

    // ── Subtitles path ───────────────────────────────────────────────────────

    private void start_subtitle_apply () {
        if (!subtitles_tab.can_apply ()) {
            status_area.set_status (
                "⚠️ Load a file with subtitle tracks or add external subtitles first!");
            return;
        }

        var settings = AppSettings.get_default ();
        string expected = subtitles_tab.get_expected_output_path ();

        if (settings.overwrite_enabled) {
            // Overwrite protection disabled — always proceed directly
            subtitles_tab.start_apply (true);
            activate_cancel (ActiveOperation.SUBTITLE_APPLY);
        } else if (expected != "" && FileUtils.test (expected, FileTest.EXISTS)) {
            confirm_overwrite (expected, true,
                () => {
                    subtitles_tab.start_apply (true);
                    activate_cancel (ActiveOperation.SUBTITLE_APPLY);
                },
                () => {
                    subtitles_tab.start_apply (false);
                    activate_cancel (ActiveOperation.SUBTITLE_APPLY);
                }
            );
        } else {
            subtitles_tab.start_apply ();
            activate_cancel (ActiveOperation.SUBTITLE_APPLY);
        }
    }

    // ── Crop & Trim path ─────────────────────────────────────────────────────

    private void start_trim_operation (TrimTab trim, string input_file) {
        string out_folder = file_pickers.output_entry.get_text ();
        string expected = trim.get_expected_output_path (input_file, out_folder);

        var settings = AppSettings.get_default ();

        if (settings.overwrite_enabled) {
            // Overwrite protection disabled — always proceed directly
            trim.start_trim_export (
                input_file, out_folder, status_area, console_tab);
            activate_cancel (ActiveOperation.TRIMMING);
        } else if (expected != "" && FileUtils.test (expected, FileTest.EXISTS)) {
            confirm_overwrite (expected, false,
                () => {
                    trim.start_trim_export (
                        input_file, out_folder, status_area, console_tab);
                    activate_cancel (ActiveOperation.TRIMMING);
                }
            );
        } else {
            trim.start_trim_export (
                input_file, out_folder, status_area, console_tab);
            activate_cancel (ActiveOperation.TRIMMING);
        }
    }

    // ── Normal codec conversion path ─────────────────────────────────────────

    private void start_codec_conversion (string input_file, ICodecTab codec_tab) {
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
        converter.start_conversion (input_file, output_file, codec_tab, builder);
        activate_cancel (ActiveOperation.CONVERTING);
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

    /** Record the active operation and enable the Cancel button. */
    private void activate_cancel (ActiveOperation operation) {
        current_operation = operation;
        cancel_button.set_sensitive (true);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  USER ACTIONS — Cancel
    //
    //  Dispatches to the correct cancel target based on the tracked
    //  operation, instead of probing multiple objects to guess which
    //  one is active.
    // ═════════════════════════════════════════════════════════════════════════

    private void on_cancel_clicked () {
        switch (current_operation) {
            case ActiveOperation.SUBTITLE_APPLY:
                subtitles_tab.cancel_operation ();
                status_area.set_status ("⏹️ Subtitle operation cancelled by user.");
                break;

            case ActiveOperation.TRIMMING:
                trim_tab.cancel_trim ();
                status_area.set_status ("⏹️ Export cancelled by user.");
                break;

            case ActiveOperation.CONVERTING:
                converter.cancel ();
                status_area.set_status ("⏹️ Conversion cancelled by user.");
                break;

            default:
                break;
        }

        current_operation = ActiveOperation.IDLE;
        cancel_button.set_sensitive (false);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CLOSE REQUEST — Prevent orphaned FFmpeg processes
    //
    //  If an operation is running, intercept the window close, present a
    //  confirmation dialog, and only close after cancellation completes.
    //  When idle, allow the close immediately.
    // ═════════════════════════════════════════════════════════════════════════

    private bool on_close_request () {
        if (current_operation == ActiveOperation.IDLE) {
            return false;  // No operation running — allow close
        }

        // Prevent stacking multiple confirmation dialogs
        if (close_dialog_open) return true;
        close_dialog_open = true;

        string operation_label;
        switch (current_operation) {
            case ActiveOperation.CONVERTING:     operation_label = "conversion";     break;
            case ActiveOperation.TRIMMING:        operation_label = "export";         break;
            case ActiveOperation.SUBTITLE_APPLY:  operation_label = "subtitle apply"; break;
            default:                              operation_label = "operation";      break;
        }

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
        switch (current_operation) {
            case ActiveOperation.SUBTITLE_APPLY:
                subtitles_tab.cancel_operation ();
                break;
            case ActiveOperation.TRIMMING:
                trim_tab.cancel_trim ();
                break;
            case ActiveOperation.CONVERTING:
                converter.cancel ();
                break;
            default:
                break;
        }

        current_operation = ActiveOperation.IDLE;
        cancel_button.set_sensitive (false);

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
        string parent_dir = Path.get_dirname (output_path);
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
