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
    private SubtitlesTab subtitles_tab;
    private Converter converter;
    private HamburgerMenu hamburger;
    private Button cancel_button;
    private StatusArea status_area;
    private Adw.ViewStack view_stack;

    public AppController (FilePickers file_pickers,
                          GeneralTab general_tab,
                          SvtAv1Tab svt_tab,
                          X265Tab x265_tab,
                          X264Tab x264_tab,
                          Vp9Tab vp9_tab,
                          InformationTab info_tab,
                          ConsoleTab console_tab,
                          TrimTab trim_tab,
                          SubtitlesTab subtitles_tab,
                          Converter converter,
                          HamburgerMenu hamburger,
                          Button cancel_button,
                          StatusArea status_area,
                          Adw.ViewStack view_stack) {
        this.file_pickers   = file_pickers;
        this.general_tab    = general_tab;
        this.svt_tab        = svt_tab;
        this.x265_tab       = x265_tab;
        this.x264_tab       = x264_tab;
        this.vp9_tab        = vp9_tab;
        this.info_tab       = info_tab;
        this.console_tab    = console_tab;
        this.trim_tab       = trim_tab;
        this.subtitles_tab  = subtitles_tab;
        this.converter      = converter;
        this.hamburger      = hamburger;
        this.cancel_button  = cancel_button;
        this.status_area    = status_area;
        this.view_stack     = view_stack;

        wire_all ();
    }

    private void wire_all () {
        wire_file_input_changed ();
        wire_crop_detection ();
        wire_audio_speed_constraint ();
        wire_video_speed_constraint ();
        wire_normalize_audio_constraint ();
        wire_conversion_done ();
        wire_trim_done ();
        wire_trim_tab_focus ();
        wire_subtitle_done ();
    }

    // ── Input file changed → probe info, load trim preview, load subtitles ──

    private void wire_file_input_changed () {
        file_pickers.input_entry.changed.connect (() => {
            string path = file_pickers.input_entry.get_text ();
            info_tab.load_input_info (path);
            info_tab.reset_output ();
            trim_tab.load_video (path);
            subtitles_tab.load_video (path);
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

    // ── Normalize audio → disable "Copy" in all codec tab audio lists ───────
    //    Mirrors wire_audio_speed_constraint: loudnorm is an audio filter
    //    and audio filters require re-encoding (copy won't apply them).

    private void wire_normalize_audio_constraint () {
        general_tab.normalize_audio.notify["active"].connect (() => {
            bool on = general_tab.normalize_audio.active;
            svt_tab.audio_settings.update_for_normalize (on);
            x265_tab.audio_settings.update_for_normalize (on);
            x264_tab.audio_settings.update_for_normalize (on);
            vp9_tab.audio_settings.update_for_normalize (on);
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

    // ── Crop & Trim tab focus → lock / unlock conflicting General tab controls ─
    //
    //  Locking is tab-scoped: the General tab's seek/time/crop controls are
    //  only blocked while the Crop & Trim tab is the visible page.  Navigating
    //  to any other tab (codec tabs, General, etc.) fully restores them so the
    //  user can use them for normal conversions.
    //
    //  On navigate-to-trim  → apply current Crop & Trim mode's locks.
    //  On navigate-away     → pass -1 to fully unlock everything.
    //  On mode change while in focus → re-apply new mode's locks.
    //
    //  The mode_changed signal in TrimTab's apply_mode() still fires, but
    //  we only honour it when the trim tab is actually visible.

    private void wire_trim_tab_focus () {
        // ── React to tab switches ────────────────────────────────────────────
        view_stack.notify["visible-child-name"].connect (() => {
            sync_general_tab_locks ();
        });

        // ── Also re-apply whenever the mode dropdown changes inside TrimTab ──
        // apply_mode() already calls general_tab.notify_trim_tab_mode, but
        // now that call is guarded in TrimTab only when in focus — handled
        // below via sync_general_tab_locks — so we hook mode changes here too.
        // TrimTab emits nothing useful for this anymore; we rely on the
        // view_stack signal for focus and on apply_mode's direct call for
        // in-focus mode changes (which already checks general_tab != null).
        // Nothing extra needed here — apply_mode handles it directly when focused.

        // ── Set correct initial state (app starts on General tab, not Trim) ──
        sync_general_tab_locks ();
    }

    /**
     * Apply or remove General tab locks based on whether the Crop & Trim tab
     * is the currently visible page.
     */
    private void sync_general_tab_locks () {
        string? page = view_stack.visible_child_name;
        if (page == "trim") {
            // Trim tab is in focus — lock based on its current mode
            general_tab.notify_trim_tab_mode (trim_tab.get_current_mode ());
        } else {
            // Any other tab — unlock everything in the General tab
            general_tab.notify_trim_tab_mode (-1);
        }
    }

    // ── Subtitle operation done → probe output, update hamburger, disable cancel ──

    private void wire_subtitle_done () {
        subtitles_tab.subtitle_done.connect ((output_path) => {
            info_tab.load_output_info (output_path);
            hamburger.set_last_output_file (output_path);
            cancel_button.set_sensitive (false);
        });
    }
}
