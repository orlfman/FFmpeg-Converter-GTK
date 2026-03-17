using Gtk;
using Adw;

// ═══════════════════════════════════════════════════════════════════════════════
//  SettingsDialog — Application preferences
//
//  Uses Adw.PreferencesDialog for a polished, native GNOME settings experience.
//
//  Sections:
//    General         — output filename format & overwrite behavior
//    Output          — default output directory
//    FFmpeg Binaries — custom paths for ffmpeg, ffprobe, and ffplay
//    Smart Optimizer — target file size for content-aware encoding
//
//  Most changes are persisted via AppSettings when the dialog closes.
//  The default output directory is explicit-apply to avoid clobbering the
//  session-only output folder selected in the main window.
// ═══════════════════════════════════════════════════════════════════════════════

public class SettingsDialog : Adw.PreferencesDialog {
    private const uint BINARY_VALIDATION_DEBOUNCE_MS = 300;

    private class BinaryValidationState : Object {
        public uint generation = 0;
        public uint debounce_id = 0;
        public Cancellable? cancellable = null;
    }

    // ── Path entries ──────────────────────────────────────────────────────────
    private Entry ffmpeg_entry;
    private Entry ffprobe_entry;
    private Entry ffplay_entry;

    // ── Output directory ──────────────────────────────────────────────────────
    private Entry output_dir_entry;
    private Button output_dir_apply_btn;
    private string saved_output_dir = "";

    // ── General settings ────────────────────────────────────────────────────
    private Adw.ComboRow name_mode_combo;
    private Adw.EntryRow custom_name_entry;
    private Adw.SwitchRow overwrite_switch;
    private Adw.SwitchRow verify_unknown_audio_copy_switch;
    private Adw.ActionRow overwrite_warning_row;
    private Adw.ActionRow preview_row;

    // ── Smart Optimizer ────────────────────────────────────────────────────────
    private SpinButton target_mb_spin;
    private Adw.SwitchRow auto_convert_switch;
    private Adw.SwitchRow strip_audio_switch;

    // ── Status labels for path validation ─────────────────────────────────────
    private Label ffmpeg_status;
    private Label ffprobe_status;
    private Label ffplay_status;
    private BinaryValidationState ffmpeg_validation = new BinaryValidationState ();
    private BinaryValidationState ffprobe_validation = new BinaryValidationState ();
    private BinaryValidationState ffplay_validation = new BinaryValidationState ();

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public SettingsDialog () {
        Object ();

        set_title ("Preferences");
        set_search_enabled (false);

        inject_settings_css ();

        // Tab order: General → Output → Binaries → Smart Optimizer
        add (build_general_page ());
        add (build_output_page ());
        add (build_binaries_page ());
        add (build_smart_optimizer_page ());

        load_from_settings ();

        // Persist when the dialog closes
        this.closed.connect (() => {
            cancel_validation (ffmpeg_validation);
            cancel_validation (ffprobe_validation);
            cancel_validation (ffplay_validation);
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
            "}\n" +
            ".settings-path-checking {\n" +
            "    color: #e5a50a;\n" +
            "    font-size: 0.85em;\n" +
            "}\n" +
            ".settings-path-warning {\n" +
            "    color: #e5a50a;\n" +
            "    font-size: 0.85em;\n" +
            "}\n" +
            ".settings-overwrite-warning .title {\n" +
            "    color: #e5a50a;\n" +
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
    //  PAGE 1 — General
    // ═════════════════════════════════════════════════════════════════════════

    private Adw.PreferencesPage build_general_page () {
        var page = new Adw.PreferencesPage ();
        page.set_title ("General");
        page.set_icon_name ("preferences-other-symbolic");

        // ── Output Filename Format ────────────────────────────────────────────
        var naming_group = new Adw.PreferencesGroup ();
        naming_group.set_title ("Output Filename");
        naming_group.set_description (
            "Choose how output files are named during codec conversion. " +
            "The codec suffix and container extension are always appended automatically."
        );

        // Mode selector — subtitle doubles as a dynamic description that
        // explains the currently selected mode.  This keeps the text
        // left-aligned and naturally wrapped, matching libadwaita conventions.
        name_mode_combo = new Adw.ComboRow ();
        name_mode_combo.set_title ("Naming Mode");
        name_mode_combo.set_subtitle (OutputNameMode.DEFAULT.get_description ());

        var mode_model = new Gtk.StringList (null);
        mode_model.append (OutputNameMode.DEFAULT.get_label ());
        mode_model.append (OutputNameMode.CUSTOM.get_label ());
        mode_model.append (OutputNameMode.RANDOM.get_label ());
        mode_model.append (OutputNameMode.DATE.get_label ());
        mode_model.append (OutputNameMode.METADATA.get_label ());
        name_mode_combo.set_model (mode_model);

        // Custom name entry row — hidden by default, only shown in Custom mode
        custom_name_entry = new Adw.EntryRow ();
        custom_name_entry.set_title ("Custom Name");
        custom_name_entry.set_show_apply_button (false);
        custom_name_entry.set_visible (false);

        // Preview row — uses the ActionRow's own subtitle for the filename
        // so it flows horizontally across the full row width.
        preview_row = new Adw.ActionRow ();
        preview_row.set_title ("Preview");
        preview_row.set_subtitle ("original_name-x265.mkv");

        // Wire up combo change → update subtitle + show/hide custom entry + preview
        name_mode_combo.notify["selected"].connect (() => {
            uint sel = name_mode_combo.get_selected ();
            OutputNameMode mode = index_to_mode (sel);

            name_mode_combo.set_subtitle (mode.get_description ());
            custom_name_entry.set_visible (mode == OutputNameMode.CUSTOM);
            update_name_preview ();
        });

        // Wire up custom name typing → update preview
        custom_name_entry.changed.connect (() => {
            update_name_preview ();
        });

        naming_group.add (name_mode_combo);
        naming_group.add (custom_name_entry);
        naming_group.add (preview_row);
        page.add (naming_group);

        // ── Overwrite Behavior ────────────────────────────────────────────────
        var overwrite_group = new Adw.PreferencesGroup ();
        overwrite_group.set_title ("File Overwrite");
        overwrite_group.set_description (
            "Control whether existing output files are overwritten without confirmation."
        );

        overwrite_switch = new Adw.SwitchRow ();
        overwrite_switch.set_title ("Always Overwrite");
        overwrite_switch.set_subtitle (
            "Skip the overwrite confirmation dialog and always replace existing files"
        );

        // Warning row — uses the ActionRow's own title so the text flows
        // horizontally across the full width instead of stacking in a box.
        // The entire row hides/shows so no empty gap remains when disabled.
        overwrite_warning_row = new Adw.ActionRow ();
        overwrite_warning_row.set_title ("⚠ Existing files will be silently replaced — data may be lost");
        overwrite_warning_row.add_css_class ("settings-overwrite-warning");
        overwrite_warning_row.set_activatable (false);
        overwrite_warning_row.set_visible (false);

        overwrite_switch.notify["active"].connect (() => {
            overwrite_warning_row.set_visible (overwrite_switch.get_active ());
        });

        overwrite_group.add (overwrite_switch);
        overwrite_group.add (overwrite_warning_row);
        page.add (overwrite_group);

        var compatibility_group = new Adw.PreferencesGroup ();
        compatibility_group.set_title ("Audio Copy Verification");
        compatibility_group.set_description (
            "Check that the source audio can actually be copied into MP4 or WebM before starting."
        );

        verify_unknown_audio_copy_switch = new Adw.SwitchRow ();
        verify_unknown_audio_copy_switch.set_title (
            "Check Audio Before Converting"
        );
        verify_unknown_audio_copy_switch.set_subtitle (
            "When it's unclear whether the source audio can be copied as-is, " +
            "quickly inspect the file first. If the audio isn't compatible, " +
            "it will be re-encoded automatically instead of failing mid-conversion."
        );
        compatibility_group.add (verify_unknown_audio_copy_switch);
        page.add (compatibility_group);

        return page;
    }

    /**
     * Map a ComboRow index to the corresponding OutputNameMode.
     */
    private static OutputNameMode index_to_mode (uint idx) {
        switch (idx) {
            case 1:  return OutputNameMode.CUSTOM;
            case 2:  return OutputNameMode.RANDOM;
            case 3:  return OutputNameMode.DATE;
            case 4:  return OutputNameMode.METADATA;
            default: return OutputNameMode.DEFAULT;
        }
    }

    /**
     * Map an OutputNameMode back to a ComboRow index.
     */
    private static uint mode_to_index (OutputNameMode mode) {
        switch (mode) {
            case OutputNameMode.CUSTOM:   return 1;
            case OutputNameMode.RANDOM:   return 2;
            case OutputNameMode.DATE:     return 3;
            case OutputNameMode.METADATA: return 4;
            default:                      return 0;
        }
    }

    /**
     * Update the filename preview label based on current combo selection
     * and custom name entry text.
     */
    private void update_name_preview () {
        uint sel = name_mode_combo.get_selected ();
        OutputNameMode mode = index_to_mode (sel);

        string stem;
        switch (mode) {
            case OutputNameMode.CUSTOM:
                string custom = custom_name_entry.get_text ().strip ();
                stem = (custom.length > 0) ? @"$custom-x265" : "my_video-x265";
                break;
            case OutputNameMode.RANDOM:
                // Static example to avoid confusing preview changes
                stem = "a7k2m9x4-x265";
                break;
            case OutputNameMode.DATE:
                stem = @"$(ConversionUtils.generate_timestamp_name ())-x265";
                break;
            case OutputNameMode.METADATA:
                stem = "Video_Title-x265";
                break;
            default:
                stem = "original_name-x265";
                break;
        }

        preview_row.set_subtitle (@"$stem.mkv");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PAGE 2 — FFmpeg Binaries
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
                          ffmpeg_entry, ffmpeg_status, "ffmpeg", true, ffmpeg_validation);
        page.add (ffmpeg_group);

        // ── FFprobe ──────────────────────────────────────────────────────────
        var ffprobe_group = new Adw.PreferencesGroup ();
        ffprobe_group.set_title ("FFprobe");

        ffprobe_entry  = new Entry ();
        ffprobe_status = new Label ("");
        build_binary_row (ffprobe_group, "ffprobe Path",
                          "Media analyzer — used for duration probing and stream info",
                          ffprobe_entry, ffprobe_status, "ffprobe", false, ffprobe_validation);
        page.add (ffprobe_group);

        // ── FFplay ───────────────────────────────────────────────────────────
        var ffplay_group = new Adw.PreferencesGroup ();
        ffplay_group.set_title ("FFplay");

        ffplay_entry  = new Entry ();
        ffplay_status = new Label ("");
        build_binary_row (ffplay_group, "ffplay Path",
                          "Media player — reserved for future playback features",
                          ffplay_entry, ffplay_status, "ffplay", false, ffplay_validation);
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
            validate_path (ffmpeg_entry,  ffmpeg_status,  "ffmpeg",  true,  ffmpeg_validation);
            validate_path (ffprobe_entry, ffprobe_status, "ffprobe", false, ffprobe_validation);
            validate_path (ffplay_entry,  ffplay_status,  "ffplay",  false, ffplay_validation);
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
                                   string default_name,
                                   bool check_codec_support,
                                   BinaryValidationState validation_state) {
        var row = new Adw.ActionRow ();
        row.set_title (title);
        row.set_subtitle (subtitle);

        entry.set_placeholder_text (default_name + "  (uses system PATH)");
        entry.set_width_chars (30);
        entry.set_hexpand (false);
        entry.set_valign (Align.CENTER);
        entry.add_css_class ("monospace");
        entry.changed.connect (() => {
            validate_path (entry, status, default_name, check_codec_support, validation_state);
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
        status_row.set_activatable (false);
        status.set_halign (Align.FILL);
        status.set_valign (Align.CENTER);
        status.set_hexpand (true);
        status.set_xalign (0.0f);
        status.set_wrap (true);
        status.set_wrap_mode (Pango.WrapMode.WORD_CHAR);
        status.set_selectable (true);
        status_row.add_prefix (status);
        group.add (status_row);
    }

    private void pick_binary_file (Entry target_entry, string binary_name) {
        var dialog = new Gtk.FileDialog ();
        dialog.set_title ("Select %s binary".printf (binary_name));

        string current = AppSettings.expand_home_path (target_entry.get_text ().strip ());
        if (current.length > 0 && FileUtils.test (current, FileTest.EXISTS)) {
            dialog.set_initial_folder (
                File.new_for_path (Path.get_dirname (current)));
        }

        dialog.open.begin (
            (Gtk.Window) this.get_root (), null, (obj, res) => {
            try {
                var file = dialog.open.end (res);
                target_entry.set_text (AppSettings.collapse_home_path (file.get_path ()));
            } catch (Error e) {
                // User cancelled
            }
        });
    }

    /**
     * Validate a binary path and update the status label.
     * Handles: empty (system default), file paths, and bare names in PATH.
     */
    private void validate_path (Entry entry, Label status, string default_name,
                                bool check_codec_support,
                                BinaryValidationState validation_state) {
        string path = entry.get_text ().strip ();

        uint generation = begin_validation (validation_state);

        if (path.length == 0) {
            // Empty → system default via PATH
            string? found = Environment.find_program_in_path (default_name);
            if (found != null) {
                string display_path = AppSettings.collapse_home_path (found);
                schedule_runtime_validation (
                    status,
                    validation_state,
                    generation,
                    found,
                    "⟳ Checking system %s → %s".printf (default_name, display_path),
                    "✓ Using system %s → %s".printf (default_name, display_path),
                    "✗ System %s at %s failed to run".printf (default_name, display_path),
                    check_codec_support
                );
            } else {
                set_status (status,
                    "⚠ %s not found in PATH".printf (default_name),
                    "settings-path-missing");
            }
            return;
        }

        string normalized = AppSettings.normalize_executable_path (path, default_name);
        string display_path = AppSettings.collapse_home_path (normalized);

        // Explicit file path (absolute, home-relative, or slash-containing relative path)
        if (path.has_prefix ("/") || path.has_prefix ("~") || path.contains ("/")) {
            if (is_executable_file (normalized)) {
                if (is_runtime_probe_exempt (normalized)) {
                    set_status (status,
                        "✓ Ready: %s\nRuntime probe skipped for the fake hang test helper."
                            .printf (display_path),
                        "settings-path-found");
                } else {
                    schedule_runtime_validation (
                        status,
                        validation_state,
                        generation,
                        normalized,
                        "⟳ Checking: %s".printf (display_path),
                        "✓ Ready: %s".printf (display_path),
                        "✗ Cannot run on this system: %s".printf (display_path),
                        check_codec_support
                    );
                }
            } else if (FileUtils.test (normalized, FileTest.EXISTS)) {
                set_status (status,
                    "✗ Not executable: %s".printf (display_path),
                    "settings-path-missing");
            } else {
                set_status (status,
                    "✗ File not found: %s".printf (display_path),
                    "settings-path-missing");
            }
            return;
        }

        // Bare name → search PATH
        string? found = Environment.find_program_in_path (path);
        if (found != null) {
            string display_found = AppSettings.collapse_home_path (found);
            if (is_runtime_probe_exempt (found)) {
                set_status (status,
                    "✓ Found in PATH → %s\nRuntime probe skipped for the fake hang test helper."
                        .printf (display_found),
                    "settings-path-found");
            } else {
                schedule_runtime_validation (
                    status,
                    validation_state,
                    generation,
                    found,
                    "⟳ Checking PATH entry \"%s\" → %s".printf (path, display_found),
                    "✓ Found in PATH → %s".printf (display_found),
                    "✗ \"%s\" resolves to %s but failed to run".printf (path, display_found),
                    check_codec_support
                );
            }
        } else {
            set_status (status,
                "⚠ \"%s\" not found in PATH".printf (path),
                "settings-path-missing");
        }
    }

    private bool is_executable_file (string path) {
        return FileUtils.test (path, FileTest.EXISTS)
            && !FileUtils.test (path, FileTest.IS_DIR)
            && FileUtils.test (path, FileTest.IS_EXECUTABLE);
    }

    private bool is_runtime_probe_exempt (string path) {
        return Path.get_basename (path) == "fake-ffmpeg-hang.sh";
    }

    private uint begin_validation (BinaryValidationState validation_state) {
        cancel_validation (validation_state);
        validation_state.generation++;
        return validation_state.generation;
    }

    private void cancel_validation (BinaryValidationState validation_state) {
        if (validation_state.debounce_id != 0) {
            Source.remove (validation_state.debounce_id);
            validation_state.debounce_id = 0;
        }
        if (validation_state.cancellable != null) {
            validation_state.cancellable.cancel ();
            validation_state.cancellable = null;
        }
    }

    private void schedule_runtime_validation (Label status,
                                              BinaryValidationState validation_state,
                                              uint generation,
                                              string binary_path,
                                              string pending_text,
                                              string success_prefix,
                                              string failure_prefix,
                                              bool check_codec_support) {
        var cancellable = new Cancellable ();
        validation_state.cancellable = cancellable;

        set_status (status, pending_text, "settings-path-checking");

        validation_state.debounce_id = Timeout.add (BINARY_VALIDATION_DEBOUNCE_MS, () => {
            validation_state.debounce_id = 0;
            if (validation_state.generation != generation
                || validation_state.cancellable != cancellable
                || cancellable.is_cancelled ()) {
                return Source.REMOVE;
            }

            validate_runtime_async.begin (
                status,
                validation_state,
                generation,
                binary_path,
                success_prefix,
                failure_prefix,
                check_codec_support,
                cancellable
            );
            return Source.REMOVE;
        });
    }

    private async void validate_runtime_async (Label status,
                                               BinaryValidationState validation_state,
                                               uint generation,
                                               string binary_path,
                                               string success_prefix,
                                               string failure_prefix,
                                               bool check_codec_support,
                                               Cancellable cancellable) {
        BinaryProbeResult result;
        try {
            result = yield probe_binary_runtime (binary_path, check_codec_support, cancellable);
        } catch (IOError.CANCELLED e) {
            if (validation_state.cancellable == cancellable) {
                validation_state.cancellable = null;
            }
            return;
        } catch (Error e) {
            if (validation_state.cancellable == cancellable) {
                validation_state.cancellable = null;
            }
            if (validation_state.generation != generation || cancellable.is_cancelled ()) {
                return;
            }

            set_status (status,
                failure_prefix + "\n" + describe_runtime_error (e.message),
                "settings-path-missing");
            return;
        }

        if (validation_state.cancellable == cancellable) {
            validation_state.cancellable = null;
        }
        if (validation_state.generation != generation || cancellable.is_cancelled ()) {
            return;
        }

        string success_text = success_prefix + "\n" + result.runtime_summary;
        if (result.codec_warning != null) {
            set_status (status,
                success_text + "\n" + result.codec_warning,
                "settings-path-warning");
        } else {
            set_status (status, success_text, "settings-path-found");
        }
    }

    private class BinaryProbeResult : Object {
        public string runtime_summary { get; set; default = ""; }
        public string? codec_warning { get; set; default = null; }
    }

    private async BinaryProbeResult probe_binary_runtime (string binary_path,
                                                          bool check_codec_support,
                                                          Cancellable cancellable) throws Error {
        var launcher = new SubprocessLauncher (
            SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
        string[] cmd = { binary_path, "-version" };
        var proc = launcher.spawnv (cmd);

        bool timed_out = false;
        uint timeout_id = 0;
        timeout_id = Timeout.add (2000, () => {
            timed_out = true;
            cancellable.cancel ();
            timeout_id = 0;
            return Source.REMOVE;
        });

        string stdout_buf;
        string stderr_buf;
        try {
            yield proc.communicate_utf8_async (null, cancellable, out stdout_buf, out stderr_buf);
        } catch (Error e) {
            proc.force_exit ();
            if (timeout_id != 0) {
                Source.remove (timeout_id);
            }
            if (timed_out) {
                throw new IOError.TIMED_OUT ("Version probe timed out");
            }
            throw e;
        }

        if (timeout_id != 0) {
            Source.remove (timeout_id);
        }

        if (!proc.get_successful ()) {
            string? detail = first_nonempty_line (stderr_buf);
            if (detail == null) {
                detail = first_nonempty_line (stdout_buf);
            }
            if (detail == null) {
                detail = "Version probe exited with status %d".printf (proc.get_exit_status ());
            }
            throw new IOError.FAILED (detail);
        }

        var result = new BinaryProbeResult ();
        result.runtime_summary = describe_runtime_success (stdout_buf, stderr_buf);
        if (check_codec_support) {
            result.codec_warning = yield probe_ffmpeg_codec_support (binary_path, cancellable);
        }
        return result;
    }

    private string describe_runtime_error (string message) {
        string detail = first_nonempty_line (message) ?? message.strip ();
        if (detail.index_of ("cannot execute binary file") >= 0
            || detail.index_of ("Exec format error") >= 0) {
            return "Wrong CPU architecture or unsupported executable format.";
        }
        if (detail.index_of ("Version probe timed out") >= 0) {
            return "Started, but did not answer a quick -version probe.";
        }
        if (detail.index_of ("Permission denied") >= 0) {
            return "Permission denied while starting the executable.";
        }
        if (detail.index_of ("No such file or directory") >= 0) {
            return "Missing interpreter, dynamic loader, or dependent library.";
        }
        return detail;
    }

    private string describe_runtime_success (string? stdout_buf, string? stderr_buf) {
        string? detail = first_nonempty_line (stdout_buf);
        if (detail == null) {
            detail = first_nonempty_line (stderr_buf);
        }
        if (detail == null) {
            return "Responded to -version successfully.";
        }

        detail = detail.strip ();
        if (detail.length > 160) {
            detail = detail.substring (0, 157) + "...";
        }
        return detail;
    }

    private async string? probe_ffmpeg_codec_support (string binary_path,
                                                      Cancellable cancellable) throws Error {
        string encoders_output = yield run_subprocess_capture (
            { binary_path, "-hide_banner", "-encoders" }, cancellable);

        string[] required_encoders = {
            "libsvtav1",
            "libx264",
            "libx265",
            "libvpx-vp9"
        };
        string[] codec_labels = {
            "SVT-AV1",
            "x264",
            "x265",
            "VP9"
        };

        string[] missing = {};
        for (int i = 0; i < required_encoders.length; i++) {
            if (!encoders_output.contains (required_encoders[i])) {
                missing += codec_labels[i];
            }
        }

        if (missing.length == 0) {
            return null;
        }

        return "Missing codec support: %s.".printf (string.joinv (", ", missing));
    }

    private async string run_subprocess_capture (string[] cmd,
                                                 Cancellable cancellable) throws Error {
        var launcher = new SubprocessLauncher (
            SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
        var proc = launcher.spawnv (cmd);

        bool timed_out = false;
        uint timeout_id = 0;
        timeout_id = Timeout.add (2000, () => {
            timed_out = true;
            cancellable.cancel ();
            timeout_id = 0;
            return Source.REMOVE;
        });

        string stdout_buf;
        string stderr_buf;
        try {
            yield proc.communicate_utf8_async (null, cancellable, out stdout_buf, out stderr_buf);
        } catch (Error e) {
            proc.force_exit ();
            if (timeout_id != 0) {
                Source.remove (timeout_id);
            }
            if (timed_out) {
                throw new IOError.TIMED_OUT ("Subprocess probe timed out");
            }
            throw e;
        }

        if (timeout_id != 0) {
            Source.remove (timeout_id);
        }

        if (!proc.get_successful ()) {
            string? detail = first_nonempty_line (stderr_buf);
            if (detail == null) {
                detail = first_nonempty_line (stdout_buf);
            }
            if (detail == null) {
                detail = "Subprocess probe exited with status %d".printf (proc.get_exit_status ());
            }
            throw new IOError.FAILED (detail);
        }

        return (stdout_buf ?? "") + "\n" + (stderr_buf ?? "");
    }

    private string? first_nonempty_line (string? text) {
        if (text == null) {
            return null;
        }

        foreach (string line in text.split ("\n")) {
            string clean = line.strip ();
            if (clean.length > 0) {
                return clean;
            }
        }

        return null;
    }

    private void set_status (Label status, string text, string css_class) {
        status.remove_css_class ("settings-path-found");
        status.remove_css_class ("settings-path-missing");
        status.remove_css_class ("settings-path-checking");
        status.remove_css_class ("settings-path-warning");
        status.set_text (text);
        status.add_css_class (css_class);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PAGE 3 — Output
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

        output_dir_apply_btn = new Button.from_icon_name ("object-select-symbolic");
        output_dir_apply_btn.set_tooltip_text ("Save as default output directory");
        output_dir_apply_btn.add_css_class ("flat");
        output_dir_apply_btn.add_css_class ("suggested-action");
        output_dir_apply_btn.set_valign (Align.CENTER);
        output_dir_apply_btn.set_sensitive (false);
        output_dir_apply_btn.clicked.connect (() => {
            apply_output_directory_setting ();
        });
        row.add_suffix (output_dir_apply_btn);

        var clear_btn = new Button.from_icon_name ("edit-clear-symbolic");
        clear_btn.set_tooltip_text ("Clear the staged default output directory");
        clear_btn.add_css_class ("flat");
        clear_btn.set_valign (Align.CENTER);
        clear_btn.clicked.connect (() => {
            output_dir_entry.set_text ("");
        });
        row.add_suffix (clear_btn);

        output_dir_entry.changed.connect (() => {
            update_output_dir_apply_state ();
        });

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
    //  PAGE 4 — Smart Optimizer
    // ═════════════════════════════════════════════════════════════════════════

    private Adw.PreferencesPage build_smart_optimizer_page () {
        var page = new Adw.PreferencesPage ();
        page.set_title ("Optimizer");
        page.set_icon_name ("starred-symbolic");

        var group = new Adw.PreferencesGroup ();
        group.set_title ("Target File Size");
        group.set_description (
            "The Smart Optimizer analyzes your video and recommends encoding " +
            "settings (CRF, preset, bitrate) to hit this target size. " +
            "Works for any target from tiny imageboard uploads to large quality-focused encodes."
        );

        var target_row = new Adw.ActionRow ();
        target_row.set_title ("Target Size (MB)");
        target_row.set_subtitle ("Maximum output file size — smaller targets require more compression");
        target_row.set_icon_name ("drive-harddisk-symbolic");

        target_mb_spin = new SpinButton.with_range (1, 4096, 1);
        target_mb_spin.set_value (4);
        target_mb_spin.set_valign (Align.CENTER);
        target_mb_spin.set_width_chars (5);
        target_row.add_suffix (target_mb_spin);

        group.add (target_row);
        page.add (group);

        // ── Presets group ─────────────────────────────────────────────────
        var presets_group = new Adw.PreferencesGroup ();
        presets_group.set_title ("Presets");

        // ── General purpose ──────────────────────────────────────────────
        var general_row = new Adw.ActionRow ();
        general_row.set_title ("General");
        general_row.set_subtitle ("Targets for messaging, email, and sharing");

        var general_box = new Box (Orientation.HORIZONTAL, 6);
        general_box.set_valign (Align.CENTER);
        general_box.set_homogeneous (true);

        var btn_25 = new Button.with_label ("25 MB");
        btn_25.add_css_class ("flat");
        btn_25.clicked.connect (() => { target_mb_spin.set_value (25); });
        general_box.append (btn_25);

        var btn_50 = new Button.with_label ("50 MB");
        btn_50.add_css_class ("flat");
        btn_50.clicked.connect (() => { target_mb_spin.set_value (50); });
        general_box.append (btn_50);

        var btn_100 = new Button.with_label ("100 MB");
        btn_100.add_css_class ("flat");
        btn_100.clicked.connect (() => { target_mb_spin.set_value (100); });
        general_box.append (btn_100);

        var btn_500 = new Button.with_label ("500 MB");
        btn_500.add_css_class ("flat");
        btn_500.clicked.connect (() => { target_mb_spin.set_value (500); });
        general_box.append (btn_500);

        general_row.add_suffix (general_box);
        presets_group.add (general_row);

        // ── Imageboard limits ────────────────────────────────────────────
        var presets_row = new Adw.ActionRow ();
        presets_row.set_title ("Imageboard");
        presets_row.set_subtitle ("Common upload limits for 4chan, forums, etc.");

        var presets_box = new Box (Orientation.HORIZONTAL, 6);
        presets_box.set_valign (Align.CENTER);
        presets_box.set_homogeneous (true);

        var btn_2 = new Button.with_label ("2 MB");
        btn_2.add_css_class ("flat");
        btn_2.clicked.connect (() => { target_mb_spin.set_value (2); });
        presets_box.append (btn_2);

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
        presets_group.add (presets_row);

        page.add (presets_group);

        // ── Behavior group ────────────────────────────────────────────────
        var behavior_group = new Adw.PreferencesGroup ();
        behavior_group.set_title ("Behavior");

        auto_convert_switch = new Adw.SwitchRow ();
        auto_convert_switch.set_title ("Auto-Convert");
        auto_convert_switch.set_subtitle (
            "Force auto-convert on for all codec tabs. " +
            "Disable to control each tab independently.");
        behavior_group.add (auto_convert_switch);

        strip_audio_switch = new Adw.SwitchRow ();
        strip_audio_switch.set_title ("No Audio");
        strip_audio_switch.set_subtitle (
            "Force audio stripping on all codec tabs. " +
            "Disable to control each tab independently.");
        behavior_group.add (strip_audio_switch);

        page.add (behavior_group);

        return page;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  LOAD / SAVE — Sync with AppSettings
    // ═════════════════════════════════════════════════════════════════════════

    private void load_from_settings () {
        var s = AppSettings.get_default ();

        // Only show custom paths — leave empty for defaults
        string ffmpeg = s.ffmpeg_path;
        ffmpeg_entry.set_text ((ffmpeg == "ffmpeg") ? "" : AppSettings.collapse_home_path (ffmpeg));

        string ffprobe = s.ffprobe_path;
        ffprobe_entry.set_text ((ffprobe == "ffprobe") ? "" : AppSettings.collapse_home_path (ffprobe));

        string ffplay = s.ffplay_path;
        ffplay_entry.set_text ((ffplay == "ffplay") ? "" : AppSettings.collapse_home_path (ffplay));

        saved_output_dir = s.default_output_dir;
        output_dir_entry.set_text (saved_output_dir);
        update_output_dir_apply_state ();

        // General settings
        name_mode_combo.set_selected (mode_to_index (s.output_name_mode));
        custom_name_entry.set_text (s.output_custom_name);
        custom_name_entry.set_visible (s.output_name_mode == OutputNameMode.CUSTOM);
        overwrite_switch.set_active (s.overwrite_enabled);
        verify_unknown_audio_copy_switch.set_active (
            s.verify_unknown_audio_copy_preflight
        );

        // Explicitly initialize state that relies on notify signals,
        // because set_selected(0) on a fresh combo (already at 0) won't
        // fire notify["selected"], leaving the subtitle at its default.
        name_mode_combo.set_subtitle (s.output_name_mode.get_description ());
        overwrite_warning_row.set_visible (s.overwrite_enabled);

        // Initialize preview
        update_name_preview ();

        target_mb_spin.set_value (s.smart_optimizer_target_mb);
        auto_convert_switch.set_active (s.smart_optimizer_auto_convert);
        strip_audio_switch.set_active (s.smart_optimizer_strip_audio);

        // Trigger initial validation
        validate_path (ffmpeg_entry,  ffmpeg_status,  "ffmpeg",  true,  ffmpeg_validation);
        validate_path (ffprobe_entry, ffprobe_status, "ffprobe", false, ffprobe_validation);
        validate_path (ffplay_entry,  ffplay_status,  "ffplay",  false, ffplay_validation);
    }

    private void save_to_settings () {
        var s = AppSettings.get_default ();

        string ffmpeg_val = ffmpeg_entry.get_text ().strip ();
        s.ffmpeg_path = (ffmpeg_val.length > 0) ? ffmpeg_val : "ffmpeg";

        string ffprobe_val = ffprobe_entry.get_text ().strip ();
        s.ffprobe_path = (ffprobe_val.length > 0) ? ffprobe_val : "ffprobe";

        string ffplay_val = ffplay_entry.get_text ().strip ();
        s.ffplay_path = (ffplay_val.length > 0) ? ffplay_val : "ffplay";

        // General settings
        s.output_name_mode = index_to_mode (name_mode_combo.get_selected ());
        s.output_custom_name = custom_name_entry.get_text ().strip ();
        s.overwrite_enabled = overwrite_switch.get_active ();
        s.verify_unknown_audio_copy_preflight =
            verify_unknown_audio_copy_switch.get_active ();

        s.smart_optimizer_target_mb = (int) target_mb_spin.get_value ();
        s.smart_optimizer_auto_convert = auto_convert_switch.get_active ();
        s.smart_optimizer_strip_audio = strip_audio_switch.get_active ();

        s.save ();
    }

    private void update_output_dir_apply_state () {
        if (output_dir_apply_btn == null) return;

        string staged = output_dir_entry.get_text ().strip ();
        bool changed = staged != saved_output_dir;
        output_dir_apply_btn.set_sensitive (changed);
    }

    private void apply_output_directory_setting () {
        string staged = output_dir_entry.get_text ().strip ();
        var s = AppSettings.get_default ();

        s.default_output_dir = staged;
        s.save ();
        s.default_output_dir_applied (staged);

        saved_output_dir = staged;
        update_output_dir_apply_state ();
    }
}
