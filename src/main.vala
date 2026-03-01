using Gtk;
using Adw;

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
    private Notebook notebook;

    public MainWindow (Adw.Application app) {
        Object (application: app);

        set_title ("FFmpeg Converter GTK");
        set_default_size (1280, 720);

        var toolbar_view = new Adw.ToolbarView ();
        var header = new Adw.HeaderBar ();

        // ── Hamburger menu on the LEFT side of the header bar ──
        var hamburger = new HamburgerMenu (this);
        header.pack_start (hamburger.get_button ());

        toolbar_view.add_top_bar (header);

        var content_box = new Box (Orientation.VERTICAL, 24);
        content_box.set_margin_top (32);
        content_box.set_margin_bottom (32);
        content_box.set_margin_start (32);
        content_box.set_margin_end (32);

        // File PICKERS
        file_pickers = new FilePickers ();
        content_box.append (file_pickers);

        // TABS
        notebook = new Notebook ();
        notebook.set_vexpand (true);

        // === General Tab ===
        general_tab = new GeneralTab ();
        var general_scrolled = new Gtk.ScrolledWindow ();
        general_scrolled.set_vexpand (true);
        general_scrolled.set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        general_scrolled.set_child (general_tab);
        notebook.append_page (general_scrolled, new Label ("General"));

        // === SVT-AV1 Tab ===
        svt_tab = new SvtAv1Tab ();
        var svt_scrolled = new Gtk.ScrolledWindow ();
        svt_scrolled.set_vexpand (true);
        svt_scrolled.set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        svt_scrolled.set_child (svt_tab);
        notebook.append_page (svt_scrolled, new Label ("SVT-AV1"));

        // === X265 Tab (placed between AV1 and x264) ===
        x265_tab = new X265Tab ();
        var x265_scroll = new ScrolledWindow ();
        x265_scroll.set_child (x265_tab);
        x265_scroll.set_vexpand (true);
        x265_scroll.set_policy (PolicyType.NEVER, PolicyType.AUTOMATIC);
        notebook.append_page (x265_scroll, new Label ("x265"));

        // === x264 Tab ===
        x264_tab = new X264Tab ();
        var x264_scroll = new ScrolledWindow ();
        x264_scroll.set_child (x264_tab);
        x264_scroll.set_vexpand (true);
        x264_scroll.set_policy (PolicyType.NEVER, PolicyType.AUTOMATIC);
        notebook.append_page (x264_scroll, new Label ("x264"));

        // === VP9 Tab ===
        vp9_tab = new Vp9Tab ();
        var vp9_scroll = new ScrolledWindow ();
        vp9_scroll.set_child (vp9_tab);
        vp9_scroll.set_vexpand (true);
        vp9_scroll.set_policy (PolicyType.NEVER, PolicyType.AUTOMATIC);
        notebook.append_page (vp9_scroll, new Label ("VP9"));

        // === Trim Tab ===
        trim_tab = new TrimTab ();
        trim_tab.general_tab = general_tab;
        trim_tab.svt_tab     = svt_tab;
        trim_tab.x265_tab   = x265_tab;
        trim_tab.x264_tab   = x264_tab;
        trim_tab.vp9_tab    = vp9_tab;
        var trim_scrolled = new Gtk.ScrolledWindow ();
        trim_scrolled.set_vexpand (true);
        trim_scrolled.set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        trim_scrolled.set_child (trim_tab);
        notebook.append_page (trim_scrolled, new Label ("Trim"));

        // === Information Tab ===
        info_tab = new InformationTab ();
        notebook.append_page (info_tab, new Label ("Information"));

        // === Connect Detect Crop button ===
        general_tab.detect_crop_button.clicked.connect (() => {
            string input_file = file_pickers.input_entry.get_text ();
            general_tab.start_crop_detection (input_file, console_tab);
        });

        // === Audio Speed → disable "Copy" in audio codec lists ===
        general_tab.audio_speed_check.notify["active"].connect (() => {
            bool on = general_tab.audio_speed_check.active;
            svt_tab.audio_settings.update_for_audio_speed (on);
            x265_tab.audio_settings.update_for_audio_speed (on);
            x264_tab.audio_settings.update_for_audio_speed (on);
            vp9_tab.audio_settings.update_for_audio_speed (on);
        });

        // === Video/Audio Speed → force re-encode in Trim tab ===
        general_tab.video_speed_check.notify["active"].connect (() => {
            trim_tab.update_for_speed (
                general_tab.video_speed_check.active,
                general_tab.audio_speed_check.active);
        });
        general_tab.audio_speed_check.notify["active"].connect (() => {
            trim_tab.update_for_speed (
                general_tab.video_speed_check.active,
                general_tab.audio_speed_check.active);
        });

        // === Console Tab ===
        console_tab = new ConsoleTab ();
        var console_scrolled = new ScrolledWindow ();
        console_scrolled.set_vexpand (true);
        console_scrolled.set_child (console_tab);
        notebook.append_page (console_scrolled, new Label ("Console"));

        content_box.append (notebook);

        // CANCEL and CONVERT
        var convert_section = new Box (Orientation.HORIZONTAL, 24);
        convert_section.set_hexpand (true);
        convert_section.set_margin_bottom (16);

        // Cancel
        cancel_button = new Button.with_label ("Cancel");
        cancel_button.add_css_class ("destructive-action");
        cancel_button.set_size_request (200, 48);
        cancel_button.set_sensitive (false);
        cancel_button.clicked.connect (on_cancel_clicked);
        convert_section.append (cancel_button);

        var spacer = new Box (Orientation.HORIZONTAL, 0);
        spacer.set_hexpand (true);
        convert_section.append (spacer);

        // Convert
        var convert_button = new Button.with_label ("Convert");
        convert_button.add_css_class ("suggested-action");
        convert_button.set_size_request (200, 48);
        convert_button.clicked.connect (on_convert_clicked);
        convert_section.append (convert_button);

        content_box.append (convert_section);

        // Status Area
        status_area = new StatusArea ();
        content_box.append (status_area);

        toolbar_view.set_content (content_box);
        set_content (toolbar_view);

        // (#7) Inject stable UI dependencies via constructor
        converter = new Converter (
            status_area.status_label,
            status_area.progress_bar,
            console_tab,
            general_tab
        );

        // === Wire up InformationTab ===
        // Probe input file whenever it changes
        file_pickers.input_entry.changed.connect (() => {
            string path = file_pickers.input_entry.get_text ();
            info_tab.load_input_info (path);
            info_tab.reset_output ();

            // Load video preview in the Trim tab
            trim_tab.load_video (path);
        });

        // Probe output file and show it after a successful conversion
        converter.conversion_done.connect ((output_path) => {
            info_tab.load_output_info (output_path);
            cancel_button.set_sensitive (false);
        });

        // Wire up Trim tab completion
        trim_tab.trim_done.connect ((output_path) => {
            info_tab.load_output_info (output_path);
            cancel_button.set_sensitive (false);
        });
    }

    private void on_convert_clicked () {
        int current_page = notebook.get_current_page ();
        var page_widget = notebook.get_nth_page (current_page);

        // Unwrap ScrolledWindow
        ICodecTab active_codec_tab = page_widget as ICodecTab;
        if (active_codec_tab == null && page_widget is Gtk.ScrolledWindow) {
            var inner = ((Gtk.ScrolledWindow) page_widget).get_child ();
            active_codec_tab = inner as ICodecTab;
            if (active_codec_tab == null && inner is Gtk.Viewport) {
                active_codec_tab = ((Gtk.Viewport) inner).get_child () as ICodecTab;
            }
        }

        if (active_codec_tab == null) {
            status_area.set_status ("⚠️ Please select a codec tab (SVT-AV1, x265, or Trim) first!");
            return;
        }

        // ── Trim Tab gets its own conversion path ────────────────────────────
        if (active_codec_tab is TrimTab) {
            var trim = (TrimTab) active_codec_tab;
            trim.start_trim_export (
                file_pickers.input_entry.get_text (),
                file_pickers.output_entry.get_text (),
                status_area.status_label,
                status_area.progress_bar,
                console_tab
            );
            cancel_button.set_sensitive (true);
            return;
        }

        // ── Normal codec conversion path ─────────────────────────────────────
        string input_file = file_pickers.input_entry.get_text ();
        if (input_file == "") {
            status_area.set_status ("⚠️ Please select an input file first!");
            return;
        }

        ICodecBuilder builder = active_codec_tab.get_codec_builder ();

        // (#5) Compute output path and check for overwrite
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

    // (#5) Show overwrite/rename/cancel dialog
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
            // "cancel" — do nothing
        });
    }

    /** Shared entry point after the overwrite decision is made. */
    private void begin_conversion (string input_file,
                                   string output_file,
                                   ICodecTab codec_tab,
                                   ICodecBuilder builder) {
        converter.start_conversion (input_file, output_file, codec_tab, builder);
        cancel_button.set_sensitive (true);
    }

    private void on_cancel_clicked () {
        // Cancel whichever conversion is active
        if (trim_tab.is_exporting ()) {
            trim_tab.cancel_trim ();
            status_area.set_status ("⏹️ Trim export cancelled by user.");
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
