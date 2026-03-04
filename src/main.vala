using Gtk;
using Adw;

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
    private ConsoleTab console_tab;
    private GeneralTab general_tab;
    private TrimTab trim_tab;
    private SubtitlesTab subtitles_tab;
    private Adw.ViewStack view_stack;
    private HamburgerMenu hamburger;

    // Prevent GC from collecting the controller
    private AppController controller;

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
            cancel_button, status_area
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  COMPONENT CREATION
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
        subtitles_tab.set_ui_refs (
            status_area.status_label,
            status_area.progress_bar,
            console_tab
        );

        hamburger = new HamburgerMenu (this, file_pickers);

        converter = new Converter (
            status_area.status_label,
            status_area.progress_bar,
            console_tab,
            general_tab
        );
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

        toolbar_view.set_content (content_box);

        // ── Bottom bar: revealed when header has no room for tabs ────────────
        var switcher_bar = new Adw.ViewSwitcherBar ();
        switcher_bar.set_stack (view_stack);
        switcher_title.bind_property ("title-visible", switcher_bar, "reveal",
            BindingFlags.SYNC_CREATE);
        toolbar_view.add_bottom_bar (switcher_bar);

        set_content (toolbar_view);
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

        var convert_button = new Button.with_label ("Convert");
        convert_button.add_css_class ("suggested-action");
        convert_button.set_size_request (200, 48);
        convert_button.clicked.connect (on_convert_clicked);
        bar.append (convert_button);

        return bar;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  USER ACTIONS
    // ═════════════════════════════════════════════════════════════════════════

    private void on_convert_clicked () {
        string? page = view_stack.visible_child_name;
        ICodecTab? active_codec_tab = null;

        switch (page) {
            case "svt-av1": active_codec_tab = svt_tab;  break;
            case "x265":    active_codec_tab = x265_tab; break;
            case "x264":    active_codec_tab = x264_tab; break;
            case "vp9":     active_codec_tab = vp9_tab;  break;
            case "trim":    active_codec_tab = trim_tab;  break;
        }

        if (active_codec_tab == null) {
            // ── Subtitles Tab gets its own path (remux, no encoding) ─────────
            if (page == "subtitles") {
                if (!subtitles_tab.can_apply ()) {
                    status_area.set_status ("⚠️ Load a file with subtitle tracks or add external subtitles first!");
                    return;
                }

                string expected = subtitles_tab.get_expected_output_path ();
                if (expected != "" && FileUtils.test (expected, FileTest.EXISTS)) {
                    show_subtitle_overwrite_dialog (expected);
                } else {
                    subtitles_tab.start_apply ();
                    cancel_button.set_sensitive (true);
                }
                return;
            }

            status_area.set_status ("⚠️ Please select a codec tab (SVT-AV1, x265, x264, VP9, Crop & Trim, or Subtitles) first!");
            return;
        }

        // ── Crop & Trim Tab gets its own conversion path ─────────────────────
        if (active_codec_tab is TrimTab) {
            var trim = (TrimTab) active_codec_tab;
            string input = file_pickers.input_entry.get_text ();
            string out_folder = file_pickers.output_entry.get_text ();

            string expected = trim.get_expected_output_path (input, out_folder);
            if (expected != "" && FileUtils.test (expected, FileTest.EXISTS)) {
                show_trim_overwrite_dialog (trim, input, out_folder, expected);
            } else {
                trim.start_trim_export (
                    input, out_folder,
                    status_area.status_label,
                    status_area.progress_bar,
                    console_tab
                );
                cancel_button.set_sensitive (true);
            }
            return;
        }

        // ── Normal codec conversion path ─────────────────────────────────────
        string input_file = file_pickers.input_entry.get_text ();
        if (input_file == "") {
            status_area.set_status ("⚠️ Please select an input file first!");
            return;
        }

        ICodecBuilder builder = active_codec_tab.get_codec_builder ();

        string output_file = Converter.compute_output_path (
            input_file,
            file_pickers.output_entry.get_text (),
            builder,
            active_codec_tab
        );

        if (FileUtils.test (output_file, FileTest.EXISTS)) {
            show_overwrite_dialog (input_file, output_file, active_codec_tab, builder);
        } else {
            begin_conversion (input_file, output_file, active_codec_tab, builder);
        }
    }

    private void show_overwrite_dialog (string input_file,
                                        string output_file,
                                        ICodecTab codec_tab,
                                        ICodecBuilder builder) {
        string basename = Path.get_basename (output_file);

        var dialog = new Adw.AlertDialog (
            "File Already Exists",
            @"\"$basename\" already exists in the output folder.\n\nWhat would you like to do?"
        );

        dialog.add_response ("cancel", "Cancel");
        dialog.add_response ("rename", "Auto-Rename");
        dialog.add_response ("overwrite", "Overwrite");

        dialog.set_response_appearance ("overwrite", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_response_appearance ("rename", Adw.ResponseAppearance.SUGGESTED);
        dialog.set_default_response ("rename");
        dialog.set_close_response ("cancel");

        dialog.choose.begin (this, null, (obj, res) => {
            string response = dialog.choose.end (res);

            if (response == "overwrite") {
                begin_conversion (input_file, output_file, codec_tab, builder);
            } else if (response == "rename") {
                string unique = Converter.find_unique_path (output_file);
                begin_conversion (input_file, unique, codec_tab, builder);
            }
        });
    }

    private void show_trim_overwrite_dialog (TrimTab trim,
                                              string input_file,
                                              string output_folder,
                                              string expected_path) {
        string basename = Path.get_basename (expected_path);

        var dialog = new Adw.AlertDialog (
            "File Already Exists",
            @"\"$basename\" already exists in the output folder.\n\nWhat would you like to do?"
        );

        dialog.add_response ("cancel", "Cancel");
        dialog.add_response ("overwrite", "Overwrite");

        dialog.set_response_appearance ("overwrite", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_default_response ("cancel");
        dialog.set_close_response ("cancel");

        dialog.choose.begin (this, null, (obj, res) => {
            string response = dialog.choose.end (res);

            if (response == "overwrite") {
                trim.start_trim_export (
                    input_file, output_folder,
                    status_area.status_label,
                    status_area.progress_bar,
                    console_tab
                );
                cancel_button.set_sensitive (true);
            }
        });
    }

    private void show_subtitle_overwrite_dialog (string expected_path) {
        string basename = Path.get_basename (expected_path);

        var dialog = new Adw.AlertDialog (
            "File Already Exists",
            @"\"$basename\" already exists in the output folder.\n\nWhat would you like to do?"
        );

        dialog.add_response ("cancel", "Cancel");
        dialog.add_response ("rename", "Auto-Rename");
        dialog.add_response ("overwrite", "Overwrite");

        dialog.set_response_appearance ("overwrite", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_response_appearance ("rename", Adw.ResponseAppearance.SUGGESTED);
        dialog.set_default_response ("rename");
        dialog.set_close_response ("cancel");

        dialog.choose.begin (this, null, (obj, res) => {
            string response = dialog.choose.end (res);

            if (response == "overwrite") {
                subtitles_tab.start_apply (true);
                cancel_button.set_sensitive (true);
            } else if (response == "rename") {
                subtitles_tab.start_apply (false);
                cancel_button.set_sensitive (true);
            }
        });
    }

    private void begin_conversion (string input_file,
                                   string output_file,
                                   ICodecTab codec_tab,
                                   ICodecBuilder builder) {
        converter.start_conversion (input_file, output_file, codec_tab, builder);
        cancel_button.set_sensitive (true);
    }

    private void on_cancel_clicked () {
        if (subtitles_tab.is_busy ()) {
            subtitles_tab.cancel_operation ();
            status_area.set_status ("⏹️ Subtitle operation cancelled by user.");
        } else if (trim_tab.is_exporting ()) {
            trim_tab.cancel_trim ();
            status_area.set_status ("⏹️ Export cancelled by user.");
        } else {
            converter.cancel ();
            status_area.set_status ("⏹️ Conversion cancelled by user.");
        }
        cancel_button.set_sensitive (false);
    }
}

int main (string[] args) {
    var app = new Adw.Application ("com.github.pieman.FFmpegConverterGTK", ApplicationFlags.DEFAULT_FLAGS);

    app.activate.connect (() => {
        var win = new MainWindow (app);
        win.present ();
    });

    return app.run (args);
}
