using Gtk;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  AppController — Cross-component signal wiring and coordination
//
//  Extracted from MainWindow to separate layout (what widgets exist and where)
//  from behavior (how widgets interact with each other).
//
//  MainWindow creates all widgets and passes them here.
//  AppController wires up every signal connection between them.
// ═══════════════════════════════════════════════════════════════════════════════

public class AppController : Object {

    // ── References ──────────────────────────────────────────────────────────
    private FilePickers file_pickers;
    private GeneralTab general_tab;
    private SvtAv1Tab svt_tab;
    private X265Tab x265_tab;
    private X264Tab x264_tab;
    private Vp9Tab vp9_tab;
    private InformationTab info_tab;
    private ConsoleTab console_tab;
    private TrimTab trim_tab;
    private Converter converter;
    private HamburgerMenu hamburger;
    private Button cancel_button;
    private StatusArea status_area;

    public AppController (FilePickers file_pickers,
                          GeneralTab general_tab,
                          SvtAv1Tab svt_tab,
                          X265Tab x265_tab,
                          X264Tab x264_tab,
                          Vp9Tab vp9_tab,
                          InformationTab info_tab,
                          ConsoleTab console_tab,
                          TrimTab trim_tab,
                          Converter converter,
                          HamburgerMenu hamburger,
                          Button cancel_button,
                          StatusArea status_area) {
        this.file_pickers = file_pickers;
        this.general_tab  = general_tab;
        this.svt_tab      = svt_tab;
        this.x265_tab     = x265_tab;
        this.x264_tab     = x264_tab;
        this.vp9_tab      = vp9_tab;
        this.info_tab     = info_tab;
        this.console_tab  = console_tab;
        this.trim_tab     = trim_tab;
        this.converter    = converter;
        this.hamburger    = hamburger;
        this.cancel_button = cancel_button;
        this.status_area  = status_area;

        wire_all ();
    }

    private void wire_all () {
        wire_file_input_changed ();
        wire_crop_detection ();
        wire_audio_speed_constraint ();
        wire_video_speed_constraint ();
        wire_conversion_done ();
        wire_trim_done ();
        wire_trim_mode_changed ();
    }

    // ── Input file changed → probe info, load trim preview ──────────────────

    private void wire_file_input_changed () {
        file_pickers.input_entry.changed.connect (() => {
            string path = file_pickers.input_entry.get_text ();
            info_tab.load_input_info (path);
            info_tab.reset_output ();
            trim_tab.load_video (path);
        });
    }

    // ── Crop detection button → uses input file + console ───────────────────

    private void wire_crop_detection () {
        general_tab.detect_crop_button.clicked.connect (() => {
            string input_file = file_pickers.input_entry.get_text ();
            general_tab.start_crop_detection (input_file, console_tab);
        });
    }

    // ── Audio speed → disable "Copy" in all codec tab audio lists ───────────

    private void wire_audio_speed_constraint () {
        general_tab.audio_speed_check.notify["active"].connect (() => {
            bool on = general_tab.audio_speed_check.active;
            svt_tab.audio_settings.update_for_audio_speed (on);
            x265_tab.audio_settings.update_for_audio_speed (on);
            x264_tab.audio_settings.update_for_audio_speed (on);
            vp9_tab.audio_settings.update_for_audio_speed (on);
        });
    }

    // ── Video/Audio speed → force re-encode in Trim tab ─────────────────────

    private void wire_video_speed_constraint () {
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
    }

    // ── Conversion done → probe output, update hamburger, disable cancel ────

    private void wire_conversion_done () {
        converter.conversion_done.connect ((output_path) => {
            info_tab.load_output_info (output_path);
            hamburger.set_last_output_file (output_path);
            cancel_button.set_sensitive (false);
        });
    }

    // ── Trim done → same as conversion done ─────────────────────────────────

    private void wire_trim_done () {
        trim_tab.trim_done.connect ((output_path) => {
            info_tab.load_output_info (output_path);
            hamburger.set_last_output_file (output_path);
            cancel_button.set_sensitive (false);
        });
    }

    // ── Trim mode changed → disable General tab crop when trim handles it ───

    private void wire_trim_mode_changed () {
        trim_tab.mode_changed.connect ((mode) => {
            bool trim_handles_crop = (mode != 0);  // 0 = TRIM_ONLY
            general_tab.crop_expander.set_sensitive (!trim_handles_crop);
            if (trim_handles_crop) {
                general_tab.crop_expander.set_enable_expansion (false);
                general_tab.crop_check.set_active (false);
            }
        });
    }
}
