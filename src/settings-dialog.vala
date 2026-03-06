using Gtk;
using Adw;

// ═══════════════════════════════════════════════════════════════════════════════
//  SettingsDialog — Application preferences
//
//  Uses Adw.PreferencesDialog for a polished, native GNOME settings experience.
//
//  Sections:
//    FFmpeg Binaries — custom paths for ffmpeg, ffprobe, and ffplay
//    Output          — default output directory
//    Smart Optimizer — target file size for content-aware encoding
//
//  Changes are persisted via AppSettings when the dialog closes.
// ═══════════════════════════════════════════════════════════════════════════════

public class SettingsDialog : Adw.PreferencesDialog {

    // ── Path entries ──────────────────────────────────────────────────────────
    private Entry ffmpeg_entry;
    private Entry ffprobe_entry;
    private Entry ffplay_entry;

    // ── Output directory ──────────────────────────────────────────────────────
    private Entry output_dir_entry;

    // ── Smart Optimizer ────────────────────────────────────────────────────────
    private SpinButton target_mb_spin;

    // ── Status labels for path validation ─────────────────────────────────────
    private Label ffmpeg_status;
    private Label ffprobe_status;
    private Label ffplay_status;

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public SettingsDialog () {
        Object ();

        set_title ("Preferences");
        set_search_enabled (false);

        inject_settings_css ();

        add (build_binaries_page ());
        add (build_output_page ());
        add (build_smart_optimizer_page ());

        load_from_settings ();

        // Persist when the dialog closes
        this.closed.connect (() => {
            save_to_settings ();
        });
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CSS
    // ═════════════════════════════════════════════════════════════════════════

    private static bool css_injected = false;

    private static void inject_settings_css () {
        if (css_injected) return;
        css_injected = true;

        var css = new CssProvider ();
        css.load_from_string (
            ".settings-path-found {\n" +
            "    color: #16c464;\n" +
            "    font-size: 0.85em;\n" +
            "}\n" +
            ".settings-path-missing {\n" +
            "    color: #e74856;\n" +
            "    font-size: 0.85em;\n" +
            "}\n"
        );
        StyleContext.add_provider_for_display (
            Gdk.Display.get_default (),
            css,
            STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PAGE 1 — FFmpeg Binaries
    // ═════════════════════════════════════════════════════════════════════════

    private Adw.PreferencesPage build_binaries_page () {
        var page = new Adw.PreferencesPage ();
        page.set_title ("Binaries");
        page.set_icon_name ("application-x-executable-symbolic");

        // ── Description ──────────────────────────────────────────────────────
        var info_group = new Adw.PreferencesGroup ();
        info_group.set_description (
            "Set custom paths to use specific FFmpeg builds. " +
            "Leave empty to use the system default found in PATH."
        );
        page.add (info_group);

        // ── FFmpeg ───────────────────────────────────────────────────────────
        var ffmpeg_group = new Adw.PreferencesGroup ();
        ffmpeg_group.set_title ("FFmpeg");

        ffmpeg_entry  = new Entry ();
        ffmpeg_status = new Label ("");
        build_binary_row (ffmpeg_group, "ffmpeg Path",
                          "Encoder, decoder, and muxer — the core tool",
                          ffmpeg_entry, ffmpeg_status, "ffmpeg");
        page.add (ffmpeg_group);

        // ── FFprobe ──────────────────────────────────────────────────────────
        var ffprobe_group = new Adw.PreferencesGroup ();
        ffprobe_group.set_title ("FFprobe");

        ffprobe_entry  = new Entry ();
        ffprobe_status = new Label ("");
        build_binary_row (ffprobe_group, "ffprobe Path",
                          "Media analyzer — used for duration probing and stream info",
                          ffprobe_entry, ffprobe_status, "ffprobe");
        page.add (ffprobe_group);

        // ── FFplay ───────────────────────────────────────────────────────────
        var ffplay_group = new Adw.PreferencesGroup ();
        ffplay_group.set_title ("FFplay");

        ffplay_entry  = new Entry ();
        ffplay_status = new Label ("");
        build_binary_row (ffplay_group, "ffplay Path",
                          "Media player — reserved for future playback features",
                          ffplay_entry, ffplay_status, "ffplay");
        page.add (ffplay_group);

        // ── Reset All Paths ──────────────────────────────────────────────────
        var actions_group = new Adw.PreferencesGroup ();

        var reset_row = new Adw.ActionRow ();
        reset_row.set_title ("Reset All Paths");
        reset_row.set_subtitle ("Restore ffmpeg, ffprobe, and ffplay to system defaults");

        var reset_btn = new Button.with_label ("Reset");
        reset_btn.add_css_class ("destructive-action");
        reset_btn.set_valign (Align.CENTER);
        reset_btn.clicked.connect (() => {
            ffmpeg_entry.set_text ("");
            ffprobe_entry.set_text ("");
            ffplay_entry.set_text ("");
            validate_path (ffmpeg_entry,  ffmpeg_status,  "ffmpeg");
            validate_path (ffprobe_entry, ffprobe_status, "ffprobe");
            validate_path (ffplay_entry,  ffplay_status,  "ffplay");
        });
        reset_row.add_suffix (reset_btn);
        actions_group.add (reset_row);

        page.add (actions_group);

        return page;
    }

    /**
     * Build a binary-path row with entry, browse button, and status label.
     */
    private void build_binary_row (Adw.PreferencesGroup group,
                                   string title,
                                   string subtitle,
                                   Entry entry,
                                   Label status,
                                   string default_name) {
        var row = new Adw.ActionRow ();
        row.set_title (title);
        row.set_subtitle (subtitle);

        entry.set_placeholder_text (default_name + "  (uses system PATH)");
        entry.set_width_chars (30);
        entry.set_hexpand (false);
        entry.set_valign (Align.CENTER);
        entry.add_css_class ("monospace");
        entry.changed.connect (() => {
            validate_path (entry, status, default_name);
        });
        row.add_suffix (entry);

        var browse_btn = new Button.from_icon_name ("document-open-symbolic");
        browse_btn.set_tooltip_text ("Browse for %s binary".printf (default_name));
        browse_btn.add_css_class ("flat");
        browse_btn.set_valign (Align.CENTER);
        browse_btn.clicked.connect (() => {
            pick_binary_file (entry, default_name);
        });
        row.add_suffix (browse_btn);

        group.add (row);

        // Status line below the row
        var status_row = new Adw.ActionRow ();
        status.set_halign (Align.START);
        status.set_valign (Align.CENTER);
        status_row.add_suffix (status);
        group.add (status_row);
    }

    private void pick_binary_file (Entry target_entry, string binary_name) {
        var dialog = new Gtk.FileDialog ();
        dialog.set_title ("Select %s binary".printf (binary_name));

        string current = target_entry.get_text ().strip ();
        if (current.length > 0 && FileUtils.test (current, FileTest.EXISTS)) {
            dialog.set_initial_folder (
                File.new_for_path (Path.get_dirname (current)));
        }

        dialog.open.begin (
            (Gtk.Window) this.get_root (), null, (obj, res) => {
            try {
                var file = dialog.open.end (res);
                target_entry.set_text (file.get_path ());
            } catch (Error e) {
                // User cancelled
            }
        });
    }

    /**
     * Validate a binary path and update the status label.
     * Handles: empty (system default), absolute paths, and bare names in PATH.
     */
    private void validate_path (Entry entry, Label status, string default_name) {
        string path = entry.get_text ().strip ();

        status.remove_css_class ("settings-path-found");
        status.remove_css_class ("settings-path-missing");

        if (path.length == 0) {
            // Empty → system default via PATH
            string? found = Environment.find_program_in_path (default_name);
            if (found != null) {
                status.set_text ("✓ Using system %s → %s".printf (default_name, found));
                status.add_css_class ("settings-path-found");
            } else {
                status.set_text ("⚠ %s not found in PATH".printf (default_name));
                status.add_css_class ("settings-path-missing");
            }
            return;
        }

        // Absolute path
        if (path.has_prefix ("/")) {
            if (FileUtils.test (path, FileTest.EXISTS)) {
                status.set_text ("✓ Found: %s".printf (path));
                status.add_css_class ("settings-path-found");
            } else {
                status.set_text ("✗ File not found: %s".printf (path));
                status.add_css_class ("settings-path-missing");
            }
            return;
        }

        // Home-relative path
        if (path.has_prefix ("~")) {
            string expanded = Environment.get_home_dir () + path.substring (1);
            if (FileUtils.test (expanded, FileTest.EXISTS)) {
                status.set_text ("✓ Found: %s".printf (expanded));
                status.add_css_class ("settings-path-found");
            } else {
                status.set_text ("✗ File not found: %s".printf (expanded));
                status.add_css_class ("settings-path-missing");
            }
            return;
        }

        // Bare name → search PATH
        string? found = Environment.find_program_in_path (path);
        if (found != null) {
            status.set_text ("✓ Found in PATH → %s".printf (found));
            status.add_css_class ("settings-path-found");
        } else {
            status.set_text ("⚠ \"%s\" not found in PATH".printf (path));
            status.add_css_class ("settings-path-missing");
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PAGE 2 — Output
    // ═════════════════════════════════════════════════════════════════════════

    private Adw.PreferencesPage build_output_page () {
        var page = new Adw.PreferencesPage ();
        page.set_title ("Output");
        page.set_icon_name ("folder-symbolic");

        var group = new Adw.PreferencesGroup ();
        group.set_title ("Default Output Directory");
        group.set_description (
            "When set, the output folder will default to this directory for new sessions. " +
            "Leave empty to save output alongside the input file."
        );

        var row = new Adw.ActionRow ();
        row.set_title ("Directory");
        row.set_subtitle ("Where finished files are saved by default");
        row.set_icon_name ("folder-open-symbolic");

        output_dir_entry = new Entry ();
        output_dir_entry.set_placeholder_text ("Same as input file");
        output_dir_entry.set_width_chars (30);
        output_dir_entry.set_hexpand (false);
        output_dir_entry.set_valign (Align.CENTER);
        output_dir_entry.add_css_class ("monospace");
        row.add_suffix (output_dir_entry);

        var browse_btn = new Button.from_icon_name ("document-open-symbolic");
        browse_btn.set_tooltip_text ("Choose default output directory");
        browse_btn.add_css_class ("flat");
        browse_btn.set_valign (Align.CENTER);
        browse_btn.clicked.connect (() => {
            pick_output_directory ();
        });
        row.add_suffix (browse_btn);

        var clear_btn = new Button.from_icon_name ("edit-clear-symbolic");
        clear_btn.set_tooltip_text ("Clear — save alongside input file");
        clear_btn.add_css_class ("flat");
        clear_btn.set_valign (Align.CENTER);
        clear_btn.clicked.connect (() => {
            output_dir_entry.set_text ("");
        });
        row.add_suffix (clear_btn);

        group.add (row);
        page.add (group);

        return page;
    }

    private void pick_output_directory () {
        var dialog = new Gtk.FileDialog ();
        dialog.set_title ("Choose Default Output Directory");

        string current = output_dir_entry.get_text ().strip ();
        if (current.length > 0 && FileUtils.test (current, FileTest.IS_DIR)) {
            dialog.set_initial_folder (File.new_for_path (current));
        }

        dialog.select_folder.begin (
            (Gtk.Window) this.get_root (), null, (obj, res) => {
            try {
                var folder = dialog.select_folder.end (res);
                output_dir_entry.set_text (folder.get_path ());
            } catch (Error e) {
                // User cancelled
            }
        });
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PAGE 3 — Smart Optimizer
    // ═════════════════════════════════════════════════════════════════════════

    private Adw.PreferencesPage build_smart_optimizer_page () {
        var page = new Adw.PreferencesPage ();
        page.set_title ("Smart Optimizer");
        page.set_icon_name ("speedometer-symbolic");

        var group = new Adw.PreferencesGroup ();
        group.set_title ("Target File Size");
        group.set_description (
            "The Smart Optimizer analyzes your video and recommends encoding " +
            "settings (CRF, preset, bitrate) to hit this target size. " +
            "Designed for imageboard upload limits."
        );

        var target_row = new Adw.ActionRow ();
        target_row.set_title ("Target Size (MB)");
        target_row.set_subtitle ("Maximum output file size — smaller targets require more compression");
        target_row.set_icon_name ("drive-harddisk-symbolic");

        target_mb_spin = new SpinButton.with_range (1, 100, 1);
        target_mb_spin.set_value (4);
        target_mb_spin.set_valign (Align.CENTER);
        target_mb_spin.set_width_chars (4);
        target_row.add_suffix (target_mb_spin);

        group.add (target_row);

        // ── Common presets row ────────────────────────────────────────────────
        var presets_row = new Adw.ActionRow ();
        presets_row.set_title ("Quick Presets");
        presets_row.set_subtitle ("Common imageboard file size limits");

        var presets_box = new Box (Orientation.HORIZONTAL, 6);
        presets_box.set_valign (Align.CENTER);

        var btn_2 = new Button.with_label ("2 MB");
        btn_2.add_css_class ("flat");
        btn_2.clicked.connect (() => { target_mb_spin.set_value (2); });
        presets_box.append (btn_2);

        var btn_3 = new Button.with_label ("3 MB");
        btn_3.add_css_class ("flat");
        btn_3.clicked.connect (() => { target_mb_spin.set_value (3); });
        presets_box.append (btn_3);

        var btn_4 = new Button.with_label ("4 MB");
        btn_4.add_css_class ("flat");
        btn_4.clicked.connect (() => { target_mb_spin.set_value (4); });
        presets_box.append (btn_4);

        var btn_6 = new Button.with_label ("6 MB");
        btn_6.add_css_class ("flat");
        btn_6.clicked.connect (() => { target_mb_spin.set_value (6); });
        presets_box.append (btn_6);

        var btn_8 = new Button.with_label ("8 MB");
        btn_8.add_css_class ("flat");
        btn_8.clicked.connect (() => { target_mb_spin.set_value (8); });
        presets_box.append (btn_8);

        presets_row.add_suffix (presets_box);
        group.add (presets_row);

        page.add (group);

        return page;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  LOAD / SAVE — Sync with AppSettings
    // ═════════════════════════════════════════════════════════════════════════

    private void load_from_settings () {
        var s = AppSettings.get_default ();

        // Only show custom paths — leave empty for defaults
        string ffmpeg = s.ffmpeg_path;
        ffmpeg_entry.set_text ((ffmpeg == "ffmpeg") ? "" : ffmpeg);

        string ffprobe = s.ffprobe_path;
        ffprobe_entry.set_text ((ffprobe == "ffprobe") ? "" : ffprobe);

        string ffplay = s.ffplay_path;
        ffplay_entry.set_text ((ffplay == "ffplay") ? "" : ffplay);

        output_dir_entry.set_text (s.default_output_dir);

        target_mb_spin.set_value (s.smart_optimizer_target_mb);

        // Trigger initial validation
        validate_path (ffmpeg_entry,  ffmpeg_status,  "ffmpeg");
        validate_path (ffprobe_entry, ffprobe_status, "ffprobe");
        validate_path (ffplay_entry,  ffplay_status,  "ffplay");
    }

    private void save_to_settings () {
        var s = AppSettings.get_default ();

        string ffmpeg_val = ffmpeg_entry.get_text ().strip ();
        s.ffmpeg_path = (ffmpeg_val.length > 0) ? ffmpeg_val : "ffmpeg";

        string ffprobe_val = ffprobe_entry.get_text ().strip ();
        s.ffprobe_path = (ffprobe_val.length > 0) ? ffprobe_val : "ffprobe";

        string ffplay_val = ffplay_entry.get_text ().strip ();
        s.ffplay_path = (ffplay_val.length > 0) ? ffplay_val : "ffplay";

        s.default_output_dir = output_dir_entry.get_text ().strip ();

        s.smart_optimizer_target_mb = (int) target_mb_spin.get_value ();

        s.save ();
    }
}
