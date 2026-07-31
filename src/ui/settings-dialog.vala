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

    private class BinaryRowBinding : Object {
        public unowned SettingsDialog owner;
        public Entry entry;
        public Label status;
        public string default_name;
        public bool check_codec_support;
        public BinaryValidationState validation_state;

        public void on_entry_changed () {
            owner.validate_path (entry, status, default_name, check_codec_support, validation_state);
        }

        public void on_browse_clicked () {
            owner.pick_binary_file (entry, default_name);
        }
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
    private Adw.ComboRow container_default_combo;
    private Adw.EntryRow custom_name_entry;
    private Adw.SwitchRow overwrite_switch;
    private Adw.SwitchRow generate_collage_thumbnail_switch;
    private Adw.SwitchRow play_with_ffplay_switch;
    private Adw.ComboRow hwdec_combo;
    private Adw.ActionRow hwdec_status_row;
    private Adw.ComboRow preview_quality_combo;
    private bool loading_preview_quality = false;
    private Adw.ComboRow preview_cache_combo;
    private bool loading_preview_cache = false;
    // MpvStatus outlives this dialog, so the handler it holds must be released
    // explicitly or the next status change calls into a destroyed dialog.
    private ulong hwdec_status_handler = 0;
    private ulong gpu_status_handler = 0;
    // set_selected () during load must not be mistaken for the user choosing.
    private bool loading_hwdec_mode = false;
    private Adw.SwitchRow recently_opened_switch;
    private Adw.SwitchRow verify_unknown_audio_copy_switch;
    private Adw.SwitchRow show_bit_depth_warning_dialog_switch;
    private Adw.ActionRow overwrite_warning_row;
    private Adw.ActionRow preview_row;

    // ── Manual update check ───────────────────────────────────────────────────
    private Adw.ActionRow update_row;
    private Button update_check_button;
    private Button update_release_button;
    private Gtk.Spinner update_spinner;
    private Cancellable? update_check_cancellable = null;
    private uint update_check_generation = 0;
    private string update_release_url = ProjectUrls.RELEASES;

    // ── Smart Optimizer ────────────────────────────────────────────────────────
    // Same order and meaning as BaseCodecTab's QUALITY_INTENT_LABELS — the
    // stored value is that dropdown's index, so the two must stay aligned.
    // Worded for the global control: "Target Size" here means every tab's.
    private const string[] QUALITY_CEILING_LABELS = {
        "Off — use Target Size",
        "Low — acceptable (maximum VMAF 88)",
        "Medium — good (maximum VMAF 92)",
        "High — visually near-transparent (maximum VMAF 95)",
        "Ultra — archival (maximum VMAF 97)"
    };
    private SpinButton target_mb_spin;
    private Adw.SwitchRow auto_convert_switch;
    private Adw.SwitchRow strip_audio_switch;
    private Adw.SwitchRow match_source_size_switch;
    private Adw.ComboRow quality_ceiling_row;
    private Adw.PreferencesGroup target_size_group;
    private Adw.PreferencesGroup target_presets_group;

    // ── Status labels for path validation ─────────────────────────────────────
    private Label ffmpeg_status;
    private Label ffprobe_status;
    private Label ffplay_status;
    private HashTable<unowned Label, Image> status_icons =
        new HashTable<unowned Label, Image> (direct_hash, direct_equal);
    private BinaryValidationState ffmpeg_validation = new BinaryValidationState ();
    private BinaryValidationState ffprobe_validation = new BinaryValidationState ();
    private BinaryValidationState ffplay_validation = new BinaryValidationState ();
    private GenericArray<BinaryRowBinding> binary_row_bindings =
        new GenericArray<BinaryRowBinding> ();

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public SettingsDialog () {
        Object ();

        set_title ("Preferences");
        set_search_enabled (false);

        // Five pages no longer fit the header switcher at libadwaita's default
        // 640px, and it silently falls back to a bottom switcher bar. Widening
        // keeps the tabs in the header where the other four always were; the
        // dialog still shrinks below this on small displays.
        set_content_width (760);

        inject_settings_css ();

        // Tab order: General → Player → Output → Binaries → Smart Optimizer
        add (build_general_page ());
        add (build_player_page ());
        add (build_output_page ());
        add (build_binaries_page ());
        add (build_smart_optimizer_page ());

        load_from_settings ();

        // Persist when the dialog closes
        this.closed.connect (() => {
            cancel_validation (ffmpeg_validation);
            cancel_validation (ffprobe_validation);
            cancel_validation (ffplay_validation);
            cancel_update_check ();

            disconnect_status_handlers ();
            save_to_settings ();
        });
    }

    /**
     * Release the handlers MpvStatus holds on this dialog.
     *
     * MpvStatus is a process-lifetime singleton, so a handler left connected
     * calls into a destroyed dialog the next time a preview reports its
     * decoder. Idempotent, and run from both "closed" and dispose (): closing
     * covers the ordinary path, and dispose () covers any teardown that never
     * emits "closed" — the parent window being destroyed with the dialog still
     * up, say.
     */
    private void disconnect_status_handlers () {
        if (hwdec_status_handler != 0) {
            MpvStatus.get_default ().disconnect (hwdec_status_handler);
            hwdec_status_handler = 0;
        }
        if (gpu_status_handler != 0) {
            MpvStatus.get_default ().disconnect (gpu_status_handler);
            gpu_status_handler = 0;
        }
    }

    public override void dispose () {
        disconnect_status_handlers ();
        base.dispose ();
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
            "    color: @success_color;\n" +
            "    font-size: 0.85em;\n" +
            "}\n" +
            ".settings-path-missing {\n" +
            "    color: @error_color;\n" +
            "    font-size: 0.85em;\n" +
            "}\n" +
            ".settings-path-checking {\n" +
            "    color: @warning_color;\n" +
            "    font-size: 0.85em;\n" +
            "}\n" +
            ".settings-path-warning {\n" +
            "    color: @warning_color;\n" +
            "    font-size: 0.85em;\n" +
            "}\n" +
            ".settings-overwrite-warning .title {\n" +
            "    color: @warning_color;\n" +
            "    font-size: 0.85em;\n" +
            "}\n"
        );
        GtkCompat.add_provider_for_display (
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
            "Choose how output files are named during codec conversion, and by " +
            "the Trim Only, Crop Only and Crop & Trim exports. " +
            "Suffixes and the container extension are always appended automatically. " +
            "Chapter Split names its files after the chapters themselves."
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
        overwrite_warning_row.set_title ("Existing files will be silently replaced — data may be lost");
        overwrite_warning_row.add_prefix (new Gtk.Image.from_icon_name ("dialog-warning-symbolic"));
        overwrite_warning_row.add_css_class ("settings-overwrite-warning");
        overwrite_warning_row.set_activatable (false);
        overwrite_warning_row.set_visible (false);

        overwrite_switch.notify["active"].connect (() => {
            overwrite_warning_row.set_visible (overwrite_switch.get_active ());
        });

        overwrite_group.add (overwrite_switch);
        overwrite_group.add (overwrite_warning_row);
        page.add (overwrite_group);

        var generated_outputs_group = new Adw.PreferencesGroup ();
        generated_outputs_group.set_title ("Generated Outputs");
        generated_outputs_group.set_description (
            "Optionally create a PNG collage sidecar from each newly encoded video."
        );

        generate_collage_thumbnail_switch = new Adw.SwitchRow ();
        generate_collage_thumbnail_switch.set_title (
            "Generate 4-4-4 PNG Collage Thumbnail"
        );
        generate_collage_thumbnail_switch.set_subtitle (
            "Creates output-name-collage.png using frames from 8%, 16%, 24%, 32%, 40%, 48%, 56%, 64%, 72%, 80%, 88%, and 96% of the finished video"
        );
        generated_outputs_group.add (generate_collage_thumbnail_switch);
        page.add (generated_outputs_group);

        var history_group = new Adw.PreferencesGroup ();
        history_group.set_title ("Recent Files");
        history_group.set_description (
            "Control whether input-file history is stored and shown in the hamburger menu."
        );

        recently_opened_switch = new Adw.SwitchRow ();
        recently_opened_switch.set_title ("Remember Recently Opened Files");
        recently_opened_switch.set_subtitle (
            "Keep up to 20 input files for quick reopening. Turning this off clears stored history and hides the menu."
        );
        history_group.add (recently_opened_switch);
        page.add (history_group);

        var container_group = new Adw.PreferencesGroup ();
        container_group.set_title ("Default Container");
        container_group.set_description (
            "Choose which container each codec tab starts with and returns to when Reset is pressed."
        );

        container_default_combo = new Adw.ComboRow ();
        container_default_combo.set_title ("Mode");
        container_default_combo.set_subtitle (ContainerDefaultMode.DEFAULT.get_description ());

        var container_mode_model = new Gtk.StringList (null);
        container_mode_model.append (ContainerDefaultMode.DEFAULT.get_label ());
        container_mode_model.append (ContainerDefaultMode.MKV.get_label ());
        container_mode_model.append (ContainerDefaultMode.CODEC_SPECIFIC.get_label ());
        container_default_combo.set_model (container_mode_model);

        container_default_combo.notify["selected"].connect (() => {
            ContainerDefaultMode mode =
                index_to_container_default_mode (container_default_combo.get_selected ());
            container_default_combo.set_subtitle (mode.get_description ());
        });

        container_group.add (container_default_combo);
        page.add (container_group);

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

        var warning_group = new Adw.PreferencesGroup ();
        warning_group.set_title ("Conversion Warnings");
        warning_group.set_description (
            "Choose whether advisory conversion warnings require confirmation."
        );

        show_bit_depth_warning_dialog_switch = new Adw.SwitchRow ();
        show_bit_depth_warning_dialog_switch.set_title (
            "Show Bit-Depth Warning Dialog"
        );
        show_bit_depth_warning_dialog_switch.set_subtitle (
            "When off, an unset output depth for a source above 8-bit is still " +
            "checked and logged to the Console, but conversion continues automatically"
        );
        warning_group.add (show_bit_depth_warning_dialog_switch);
        page.add (warning_group);

        var updates_group = new Adw.PreferencesGroup ();
        updates_group.set_title ("Software Updates");
        updates_group.set_description (
            "Check GitHub for a newer published release. Nothing is downloaded or installed automatically."
        );

        update_row = new Adw.ActionRow ();
        update_row.set_title ("FFmpeg Converter GTK");
        update_row.set_subtitle (
            "Installed version: %s".printf (AppVersion.VERSION));
        update_row.add_prefix (
            new Image.from_icon_name ("system-software-update-symbolic"));

        update_spinner = new Gtk.Spinner ();
        update_spinner.set_valign (Align.CENTER);
        update_spinner.set_visible (false);
        update_row.add_suffix (update_spinner);

        update_release_button = new Button.with_label ("View Release");
        update_release_button.set_valign (Align.CENTER);
        update_release_button.set_visible (false);
        update_release_button.clicked.connect (() => {
            open_update_release_page ();
        });
        update_row.add_suffix (update_release_button);

        update_check_button = new Button.with_label ("Check for Updates");
        update_check_button.set_valign (Align.CENTER);
        update_check_button.add_css_class ("suggested-action");
        update_check_button.clicked.connect (() => {
            check_for_updates.begin ();
        });
        update_row.add_suffix (update_check_button);

        updates_group.add (update_row);
        page.add (updates_group);

        return page;
    }

    private void cancel_update_check () {
        update_check_generation++;
        if (update_check_cancellable != null) {
            update_check_cancellable.cancel ();
            update_check_cancellable = null;
        }
    }

    private async void check_for_updates () {
        cancel_update_check ();
        var cancellable = new Cancellable ();
        update_check_cancellable = cancellable;
        uint generation = ++update_check_generation;

        update_check_button.set_sensitive (false);
        update_release_button.set_visible (false);
        update_spinner.set_visible (true);
        update_spinner.start ();
        update_row.set_subtitle (
            "Checking GitHub… Installed version: %s".printf (AppVersion.VERSION));

        try {
            var checker = new UpdateChecker (AppVersion.VERSION);
            UpdateCheckResult result = yield checker.check_latest (cancellable);
            if (generation != update_check_generation || cancellable.is_cancelled ())
                return;

            switch (result.availability) {
                case UpdateAvailability.UPDATE_AVAILABLE:
                    // os-release identifies Arch-family systems; point those
                    // users at the AUR and everyone else at the GitHub release.
                    if (InstallDetection.detect () == InstallOrigin.ARCH_BASED_SYSTEM) {
                        update_row.set_subtitle (
                            ("Version %s is available — installed version: %s. "
                             + "This is an Arch-based system; update it with "
                             + "your AUR helper.").printf (
                                result.latest_version, result.current_version));
                        update_release_url = ProjectUrls.AUR;
                        update_release_button.set_label ("View on AUR");
                    } else {
                        update_row.set_subtitle (
                            "Version %s is available — installed version: %s".printf (
                                result.latest_version, result.current_version));
                        update_release_url = result.release_url;
                        update_release_button.set_label ("View Release");
                    }
                    update_release_button.set_visible (true);
                    break;
                case UpdateAvailability.NEWER_THAN_LATEST:
                    update_row.set_subtitle (
                        "Installed version %s is newer than the latest release (%s).".printf (
                            result.current_version, result.latest_version));
                    break;
                case UpdateAvailability.UP_TO_DATE:
                default:
                    update_row.set_subtitle (
                        "You are up to date — version %s is the latest release.".printf (
                            result.current_version));
                    break;
            }
            update_check_button.set_label ("Check Again");
        } catch (IOError.CANCELLED e) {
            // Closing the dialog cancels the request; no stale UI update.
        } catch (Error e) {
            if (generation == update_check_generation) {
                update_row.set_subtitle (
                    "Could not check for updates: %s".printf (e.message));
                update_check_button.set_label ("Try Again");
            }
        } finally {
            if (generation == update_check_generation) {
                update_spinner.stop ();
                update_spinner.set_visible (false);
                update_check_button.set_sensitive (true);
                if (update_check_cancellable == cancellable)
                    update_check_cancellable = null;
            }
        }
    }

    private void open_update_release_page () {
        try {
            AppInfo.launch_default_for_uri (update_release_url, null);
        } catch (Error e) {
            update_row.set_subtitle (
                "Could not open the release page: %s".printf (e.message));
        }
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

    private static ContainerDefaultMode index_to_container_default_mode (uint idx) {
        switch (idx) {
            case 1:  return ContainerDefaultMode.MKV;
            case 2:  return ContainerDefaultMode.CODEC_SPECIFIC;
            default: return ContainerDefaultMode.DEFAULT;
        }
    }

    private static uint container_default_mode_to_index (ContainerDefaultMode mode) {
        switch (mode) {
            case ContainerDefaultMode.MKV:            return 1;
            case ContainerDefaultMode.CODEC_SPECIFIC: return 2;
            default:                                  return 0;
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
    //  PAGE 2 — Player
    // ═════════════════════════════════════════════════════════════════════════

    private Adw.PreferencesPage build_player_page () {
        var page = new Adw.PreferencesPage ();
        page.set_title ("Player");
        page.set_icon_name ("media-playback-start-symbolic");

        var playback_group = new Adw.PreferencesGroup ();
        playback_group.set_title ("Playback");
        playback_group.set_description (
            "Choose how Playback menu actions open input and output videos."
        );

        play_with_ffplay_switch = new Adw.SwitchRow ();
        play_with_ffplay_switch.set_title ("Play with ffplay");
        play_with_ffplay_switch.set_subtitle (
            "Off uses your desktop's default video player. On uses the "
            + "separately configured ffplay executable for input and output"
        );
        playback_group.add (play_with_ffplay_switch);
        page.add (playback_group);

        // Separate from Playback above: that group governs the external player
        // launched from the Playback menu, this one the embedded preview.
        var preview_group = new Adw.PreferencesGroup ();
        preview_group.set_title ("Preview Player");
        preview_group.set_description (
            "Settings for the video and audio previews shown in Crop & Trim and the Audio tab."
        );

        hwdec_combo = new Adw.ComboRow ();
        hwdec_combo.set_title ("Hardware Decoding");

        // See the note in BaseCodecTab.add_smart_optimizer_rows: a named const
        // string[] is not NULL-terminated, so gtk_string_list_new () reads past
        // the end. Building the list by known length avoids that.
        var hwdec_model = new Gtk.StringList (null);
        foreach (HwdecMode mode in HwdecMode.all ()) {
            hwdec_model.append (mode.get_label ());
        }
        hwdec_combo.set_model (hwdec_model);
        hwdec_combo.notify["selected"].connect (on_hwdec_mode_changed);
        preview_group.add (hwdec_combo);

        // mpv silently decodes in software when it cannot honour the requested
        // decoder, so this reports what actually happened rather than letting
        // the selection speak for itself.
        //
        // A row of its own rather than more of the combo's subtitle: the row
        // splits its width between the text and the selected value, and a
        // two-line subtitle leaves so little for the value that "Automatic
        // (recommended)" ellipsises to "Automatic (re…". Same shape as the
        // filename Preview row above.
        hwdec_status_row = new Adw.ActionRow ();
        hwdec_status_row.set_title ("Decoder In Use");
        preview_group.add (hwdec_status_row);

        hwdec_status_handler = MpvStatus.get_default ()
            .notify["active-hwdec"].connect (update_hwdec_subtitle);
        gpu_status_handler = MpvStatus.get_default ()
            .notify["active-gpu"].connect (update_hwdec_subtitle);
        update_hwdec_subtitle ();

        preview_quality_combo = new Adw.ComboRow ();
        preview_quality_combo.set_title ("Image Quality");

        var quality_model = new Gtk.StringList (null);
        foreach (PreviewQuality quality in PreviewQuality.all ()) {
            quality_model.append (quality.get_label ());
        }
        preview_quality_combo.set_model (quality_model);
        preview_quality_combo.notify["selected"].connect (
            on_preview_quality_changed);
        preview_group.add (preview_quality_combo);

        preview_cache_combo = new Adw.ComboRow ();
        preview_cache_combo.set_title ("Read-Ahead Buffer");

        var cache_model = new Gtk.StringList (null);
        foreach (PreviewCacheSize size in PreviewCacheSize.all ()) {
            cache_model.append (size.get_label ());
        }
        preview_cache_combo.set_model (cache_model);
        preview_cache_combo.notify["selected"].connect (
            on_preview_cache_changed);
        preview_group.add (preview_cache_combo);

        page.add (preview_group);

        return page;
    }

    private static PreviewQuality index_to_preview_quality (uint idx) {
        PreviewQuality[] modes = PreviewQuality.all ();
        return idx < modes.length ? modes[idx] : PreviewQuality.FAST;
    }

    private static uint preview_quality_to_index (PreviewQuality quality) {
        PreviewQuality[] modes = PreviewQuality.all ();
        for (uint i = 0; i < modes.length; i++) {
            if (modes[i] == quality) return i;
        }
        return 0;
    }

    /** Applied immediately, for the same reason the decoder mode is. */
    private void on_preview_quality_changed () {
        PreviewQuality quality =
            index_to_preview_quality (preview_quality_combo.get_selected ());
        preview_quality_combo.set_subtitle (quality.get_description ());

        if (loading_preview_quality) return;

        var s = AppSettings.get_default ();
        if (s.preview_quality == quality) return;

        s.preview_quality = quality;
        s.save ();
    }

    /**
     * The CPU's own name, for when nothing else is doing the decoding.
     *
     * Read once and cached: it cannot change while the process runs, and this
     * is called again on every status change. "model name" is how x86 spells
     * it in /proc/cpuinfo — one line per logical CPU, all identical, so the
     * first is enough. Other architectures word the file differently, and a
     * miss returns null so the caller can omit the field rather than guess.
     */
    private static string? cpu_model = null;
    private static bool cpu_model_read = false;

    private static string? get_cpu_model () {
        if (cpu_model_read) return cpu_model;
        cpu_model_read = true;

        string contents;
        try {
            if (!FileUtils.get_contents ("/proc/cpuinfo", out contents))
                return null;
        } catch (FileError e) {
            debug ("SettingsDialog: could not read /proc/cpuinfo: %s", e.message);
            return null;
        }

        foreach (string line in contents.split ("\n")) {
            if (!line.has_prefix ("model name")) continue;

            int colon = line.index_of (":");
            if (colon < 0) continue;

            string name = line.substring (colon + 1).strip ();
            if (name != "") cpu_model = name;
            break;
        }

        return cpu_model;
    }

    private static PreviewCacheSize index_to_preview_cache (uint idx) {
        PreviewCacheSize[] sizes = PreviewCacheSize.all ();
        return idx < sizes.length ? sizes[idx] : PreviewCacheSize.SMALL;
    }

    private static uint preview_cache_to_index (PreviewCacheSize size) {
        PreviewCacheSize[] sizes = PreviewCacheSize.all ();
        for (uint i = 0; i < sizes.length; i++) {
            if (sizes[i] == size) return i;
        }
        return 0;
    }

    /** Applied immediately, for the same reason the decoder mode is. */
    private void on_preview_cache_changed () {
        PreviewCacheSize size =
            index_to_preview_cache (preview_cache_combo.get_selected ());
        preview_cache_combo.set_subtitle (size.get_description ());

        if (loading_preview_cache) return;

        var s = AppSettings.get_default ();
        if (s.preview_cache_size == size) return;

        s.preview_cache_size = size;
        s.save ();
    }

    private static HwdecMode index_to_hwdec_mode (uint idx) {
        HwdecMode[] modes = HwdecMode.all ();
        return idx < modes.length ? modes[idx] : HwdecMode.AUTOMATIC;
    }

    private static uint hwdec_mode_to_index (HwdecMode mode) {
        HwdecMode[] modes = HwdecMode.all ();
        for (uint i = 0; i < modes.length; i++) {
            if (modes[i] == mode) return i;
        }
        return 0;
    }

    /**
     * Applied immediately rather than when the dialog closes.
     *
     * mpv honours a runtime "hwdec" change by reinitialising its decoder, so an
     * open preview picks the new one up without losing its position — and the
     * subtitle below can only report what was actually chosen if the choice has
     * actually been made. Waiting for close would leave the row describing the
     * previous decoder for as long as the user looks at it.
     */
    private void on_hwdec_mode_changed () {
        update_hwdec_subtitle ();

        if (loading_hwdec_mode) return;

        var s = AppSettings.get_default ();
        HwdecMode mode = index_to_hwdec_mode (hwdec_combo.get_selected ());
        if (s.hwdec_mode == mode) return;

        s.hwdec_mode = mode;
        s.save ();
    }

    private void update_hwdec_subtitle () {
        if (hwdec_combo == null || hwdec_status_row == null) return;

        HwdecMode mode = index_to_hwdec_mode (hwdec_combo.get_selected ());
        hwdec_combo.set_subtitle (mode.get_description ());

        // Adw.ActionRow parses its subtitle as Pango markup, so a bare
        // ampersand renders the whole line as nothing at all. Keep these free
        // of markup characters, and escape the one part that comes from mpv.
        string? active = MpvStatus.get_default ().active_hwdec;
        string status;
        if (active == null) {
            status = "Shown once a preview is open";
        } else if (active == "unknown") {
            status = "Could not be read from the player";
        } else if (active == "no") {
            // Software decoding still runs somewhere, so name it — the row
            // reads as a dead end otherwise. Left out entirely when the CPU
            // cannot be identified, rather than padded with "unknown".
            string? cpu = get_cpu_model ();
            string on_cpu = cpu == null ? "" : " on " + Markup.escape_text (cpu);

            // Asking for software and getting it is not a failure worth
            // reporting as one; asking for a decoder and getting software is.
            status = mode == HwdecMode.OFF
                ? "Software decoding" + on_cpu
                : "Software decoding" + on_cpu
                  + " — no hardware decoder was available";
        } else {
            status = Markup.escape_text (active);

            // Named separately from the decoder because the two do not follow
            // from each other: on a machine with both an integrated and a
            // discrete GPU, VAAPI and Vulkan routinely open different ones.
            // Absent for any driver whose wording MpvBackend cannot parse, so
            // this appends rather than assuming it is there.
            string? gpu = MpvStatus.get_default ().active_gpu;
            if (gpu != null) {
                status += " on " + Markup.escape_text (gpu);
            }
        }

        hwdec_status_row.set_subtitle (status);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PAGE 3 — FFmpeg Binaries
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
                          "Media player used by Playback menu actions when enabled",
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
        var binding = new BinaryRowBinding ();
        binding.owner = this;
        binding.entry = entry;
        binding.status = status;
        binding.default_name = default_name;
        binding.check_codec_support = check_codec_support;
        binding.validation_state = validation_state;
        binary_row_bindings.add (binding);
        entry.changed.connect (binding.on_entry_changed);
        row.add_suffix (entry);

        var browse_btn = new Button.from_icon_name ("document-open-symbolic");
        browse_btn.set_tooltip_text ("Browse for %s binary".printf (default_name));
        browse_btn.add_css_class ("flat");
        browse_btn.set_valign (Align.CENTER);
        browse_btn.clicked.connect (binding.on_browse_clicked);
        row.add_suffix (browse_btn);

        group.add (row);

        // Status line below the row
        var status_row = new Adw.ActionRow ();
        status_row.set_activatable (false);

        var status_icon = new Image ();
        status_icon.set_pixel_size (16);
        status_icon.set_valign (Align.CENTER);
        status_row.add_prefix (status_icon);
        status_icons.insert (status, status_icon);

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
                    "Checking system %s → %s".printf (default_name, display_path),
                    "Using system %s → %s".printf (default_name, display_path),
                    "System %s at %s failed to run".printf (default_name, display_path),
                    check_codec_support,
                    default_name
                );
            } else {
                set_status (status,
                    "%s not found in PATH".printf (default_name),
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
                        "Ready: %s\nRuntime probe skipped for the fake hang test helper."
                            .printf (display_path),
                        "settings-path-found");
                } else {
                    schedule_runtime_validation (
                        status,
                        validation_state,
                        generation,
                        normalized,
                        "Checking: %s".printf (display_path),
                        "Ready: %s".printf (display_path),
                        "Cannot run on this system: %s".printf (display_path),
                        check_codec_support,
                        default_name
                    );
                }
            } else if (FileUtils.test (normalized, FileTest.EXISTS)) {
                set_status (status,
                    "Not executable: %s".printf (display_path),
                    "settings-path-missing");
            } else {
                set_status (status,
                    "File not found: %s".printf (display_path),
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
                    "Found in PATH → %s\nRuntime probe skipped for the fake hang test helper."
                        .printf (display_found),
                    "settings-path-found");
            } else {
                schedule_runtime_validation (
                    status,
                    validation_state,
                    generation,
                    found,
                    "Checking PATH entry \"%s\" → %s".printf (path, display_found),
                    "Found in PATH → %s".printf (display_found),
                    "\"%s\" resolves to %s but failed to run".printf (path, display_found),
                    check_codec_support,
                    default_name
                );
            }
        } else {
            set_status (status,
                "\"%s\" not found in PATH".printf (path),
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
                                              bool check_codec_support,
                                              string expected_tool) {
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
                expected_tool,
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
                                               string expected_tool,
                                               Cancellable cancellable) {
        BinaryProbeResult result;
        try {
            result = yield probe_binary_runtime (binary_path, check_codec_support,
                                                 expected_tool, cancellable);
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
            set_status (
                status,
                success_text + "\n" + result.codec_warning,
                "settings-path-warning"
            );
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
                                                          string expected_tool,
                                                          Cancellable cancellable) throws Error {
        var launcher = new SubprocessLauncher (
            SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
        string[] cmd = { binary_path, "-version" };
        var proc = SubprocessCompat.spawnv (launcher, cmd);

        bool timed_out = false;
        uint timeout_id = 0;
        var local_cancel = new Cancellable ();
        ulong parent_id = cancellable.connect (() => { local_cancel.cancel (); });
        timeout_id = Timeout.add (2000, () => {
            timed_out = true;
            local_cancel.cancel ();
            timeout_id = 0;
            return Source.REMOVE;
        });

        string stdout_buf;
        string stderr_buf;
        try {
            yield proc.communicate_utf8_async (null, local_cancel, out stdout_buf, out stderr_buf);
        } catch (Error e) {
            proc.force_exit ();
            if (timeout_id != 0) {
                Source.remove (timeout_id);
            }
            cancellable.disconnect (parent_id);
            if (timed_out) {
                throw new IOError.TIMED_OUT ("Version probe timed out");
            }
            throw e;
        }

        if (timeout_id != 0) {
            Source.remove (timeout_id);
        }
        cancellable.disconnect (parent_id);

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

        // Identity probe: verify the binary is actually the expected tool
        yield probe_binary_identity (binary_path, expected_tool, cancellable);

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

    /**
     * Verify a binary is actually the expected FFmpeg tool by running
     * a capability-specific probe that only the correct tool accepts.
     */
    private async void probe_binary_identity (string binary_path,
                                              string expected_tool,
                                              Cancellable cancellable) throws Error {
        string[] cmd;
        switch (expected_tool) {
            case "ffmpeg":
                // -filter_complex_threads is ffmpeg-only; ffprobe/ffplay reject it at option parsing
                cmd = { binary_path, "-filter_complex_threads", "1", "-version" };
                break;
            case "ffprobe":
                cmd = { binary_path, "-v", "error",
                        "-show_program_version", "-of", "json" };
                break;
            case "ffplay":
                cmd = { binary_path, "-showmode", "waves", "-version" };
                break;
            default:
                return;
        }

        try {
            yield run_subprocess_capture (cmd, cancellable);
        } catch (IOError.CANCELLED e) {
            throw e;
        } catch (IOError.TIMED_OUT e) {
            throw new IOError.FAILED (
                "This does not appear to be %s — identity probe timed out."
                    .printf (expected_tool));
        } catch (Error e) {
            throw new IOError.FAILED (
                "This does not appear to be %s — identity probe failed."
                    .printf (expected_tool));
        }
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
        var proc = SubprocessCompat.spawnv (launcher, cmd);

        bool timed_out = false;
        uint timeout_id = 0;
        var local_cancel = new Cancellable ();
        ulong parent_id = cancellable.connect (() => { local_cancel.cancel (); });
        timeout_id = Timeout.add (2000, () => {
            timed_out = true;
            local_cancel.cancel ();
            timeout_id = 0;
            return Source.REMOVE;
        });

        string stdout_buf;
        string stderr_buf;
        try {
            yield proc.communicate_utf8_async (null, local_cancel, out stdout_buf, out stderr_buf);
        } catch (Error e) {
            proc.force_exit ();
            if (timeout_id != 0) {
                Source.remove (timeout_id);
            }
            cancellable.disconnect (parent_id);
            if (timed_out) {
                throw new IOError.TIMED_OUT ("Subprocess probe timed out");
            }
            throw e;
        }

        if (timeout_id != 0) {
            Source.remove (timeout_id);
        }
        cancellable.disconnect (parent_id);

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

        Image? icon = status_icons.lookup (status);
        if (icon != null) {
            string icon_name;
            switch (css_class) {
                case "settings-path-found":    icon_name = "emblem-default-symbolic"; break;
                case "settings-path-missing":  icon_name = "dialog-error-symbolic";   break;
                case "settings-path-checking": icon_name = "content-loading-symbolic"; break;
                case "settings-path-warning":  icon_name = "dialog-warning-symbolic";  break;
                default:                       icon_name = "dialog-information-symbolic"; break;
            }
            icon.set_from_icon_name (icon_name);

            icon.remove_css_class ("settings-path-found");
            icon.remove_css_class ("settings-path-missing");
            icon.remove_css_class ("settings-path-checking");
            icon.remove_css_class ("settings-path-warning");
            icon.add_css_class (css_class);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PAGE 4 — Output
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
        row.add_prefix (new Image.from_icon_name ("folder-open-symbolic"));

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
        output_dir_apply_btn.add_css_class ("success");
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
    //  PAGE 5 — Smart Optimizer
    // ═════════════════════════════════════════════════════════════════════════

    private Adw.PreferencesPage build_smart_optimizer_page () {
        var page = new Adw.PreferencesPage ();
        page.set_title ("Optimizer");
        page.set_icon_name ("starred-symbolic");

        var group = new Adw.PreferencesGroup ();
        target_size_group = group;
        group.set_title ("Target File Size");
        group.set_description (
            "The Smart Optimizer analyzes your video and recommends encoding " +
            "settings (CRF, preset, bitrate) to hit this target size. " +
            "Works for any target from tiny imageboard uploads to large quality-focused encodes."
        );

        var target_row = new Adw.ActionRow ();
        target_row.set_title ("Target Size (MB)");
        target_row.set_subtitle ("Maximum output file size — smaller targets require more compression");
        target_row.add_prefix (new Image.from_icon_name ("drive-harddisk-symbolic"));

        target_mb_spin = new SpinButton.with_range (
            SmartOptimizerLogic.TARGET_MB_MIN, SmartOptimizerLogic.TARGET_MB_MAX, 1);
        target_mb_spin.set_value (4);
        target_mb_spin.set_valign (Align.CENTER);
        target_mb_spin.set_width_chars (5);
        target_row.add_suffix (target_mb_spin);

        group.add (target_row);
        page.add (group);

        // ── Presets group ─────────────────────────────────────────────────
        var presets_group = new Adw.PreferencesGroup ();
        target_presets_group = presets_group;
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

        // Mirrors the per-tab control exactly, including "Off". Anything
        // other than Off pins quality and lets size float, so this is the
        // global form of "enable the quality ceiling".
        quality_ceiling_row = new Adw.ComboRow ();
        quality_ceiling_row.set_title ("Quality Ceiling");
        quality_ceiling_row.set_subtitle (
            "Sets every codec tab; each tab can still be changed. " +
            "Anything but Off pins quality and lets file size follow.");
        // See the note in BaseCodecTab.add_smart_optimizer_rows: a named const
        // string[] is not NULL-terminated, so gtk_string_list_new() reads past
        // the end. The helper appends by known length instead.
        quality_ceiling_row.set_model (
            CodecUtils.build_dropdown_string_list (QUALITY_CEILING_LABELS));
        quality_ceiling_row.set_selected (0);
        behavior_group.add (quality_ceiling_row);

        match_source_size_switch = new Adw.SwitchRow ();
        match_source_size_switch.set_title ("Match Source Size");
        match_source_size_switch.set_subtitle (
            "Force every codec tab to target the source file's own size, " +
            "rounded to the nearest MB. Disable to control each tab independently.");
        // A forced source-matched target makes the stored target irrelevant,
        // so the whole Target File Size section is disabled while it is on.
        match_source_size_switch.notify["active"].connect (
            sync_target_size_sensitivity);
        behavior_group.add (match_source_size_switch);

        auto_convert_switch = new Adw.SwitchRow ();
        auto_convert_switch.set_title ("Auto-Convert");
        auto_convert_switch.set_subtitle (
            "Start conversion automatically when optimization completes. " +
            "Sets every codec tab; each tab can still be changed.");
        behavior_group.add (auto_convert_switch);

        strip_audio_switch = new Adw.SwitchRow ();
        strip_audio_switch.set_title ("No Audio");
        strip_audio_switch.set_subtitle (
            "Strip audio from analysis and output. " +
            "Sets every codec tab; each tab can still be changed.");
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
        container_default_combo.set_selected (
            container_default_mode_to_index (s.container_default_mode)
        );
        custom_name_entry.set_text (s.output_custom_name);
        custom_name_entry.set_visible (s.output_name_mode == OutputNameMode.CUSTOM);
        overwrite_switch.set_active (s.overwrite_enabled);
        generate_collage_thumbnail_switch.set_active (s.generate_collage_thumbnail);
        play_with_ffplay_switch.set_active (s.play_with_ffplay);
        loading_hwdec_mode = true;
        hwdec_combo.set_selected (hwdec_mode_to_index (s.hwdec_mode));
        loading_hwdec_mode = false;

        loading_preview_quality = true;
        preview_quality_combo.set_selected (
            preview_quality_to_index (s.preview_quality));
        loading_preview_quality = false;
        // set_selected () is silent when the index is already right, so the
        // subtitle has to be seeded either way.
        on_preview_quality_changed ();

        loading_preview_cache = true;
        preview_cache_combo.set_selected (
            preview_cache_to_index (s.preview_cache_size));
        loading_preview_cache = false;
        on_preview_cache_changed ();
        recently_opened_switch.set_active (s.recently_opened_enabled);
        verify_unknown_audio_copy_switch.set_active (
            s.verify_unknown_audio_copy_preflight
        );
        show_bit_depth_warning_dialog_switch.set_active (
            s.show_bit_depth_warning_dialog
        );

        // Explicitly initialize state that relies on notify signals,
        // because set_selected(0) on a fresh combo (already at 0) won't
        // fire notify["selected"], leaving the subtitle at its default.
        name_mode_combo.set_subtitle (s.output_name_mode.get_description ());
        container_default_combo.set_subtitle (s.container_default_mode.get_description ());
        overwrite_warning_row.set_visible (s.overwrite_enabled);

        // Initialize preview
        update_name_preview ();

        target_mb_spin.set_value (s.smart_optimizer_target_mb);
        match_source_size_switch.set_active (s.smart_optimizer_match_source_size);
        quality_ceiling_row.set_selected ((uint) s.smart_optimizer_quality_ceiling);
        auto_convert_switch.set_active (s.smart_optimizer_auto_convert);
        strip_audio_switch.set_active (s.smart_optimizer_strip_audio);

        // set_active() above only fires notify when the value actually changed,
        // so apply the dependent state explicitly.
        sync_target_size_sensitivity ();

        // Trigger initial validation
        validate_path (ffmpeg_entry,  ffmpeg_status,  "ffmpeg",  true,  ffmpeg_validation);
        validate_path (ffprobe_entry, ffprobe_status, "ffprobe", false, ffprobe_validation);
        validate_path (ffplay_entry,  ffplay_status,  "ffplay",  false, ffplay_validation);
    }

    private void sync_target_size_sensitivity () {
        if (target_size_group == null || match_source_size_switch == null) return;

        bool editable = !match_source_size_switch.get_active ();
        target_size_group.set_sensitive (editable);
        if (target_presets_group != null)
            target_presets_group.set_sensitive (editable);
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
        s.container_default_mode =
            index_to_container_default_mode (container_default_combo.get_selected ());
        s.output_custom_name = custom_name_entry.get_text ().strip ();
        s.overwrite_enabled = overwrite_switch.get_active ();
        s.generate_collage_thumbnail = generate_collage_thumbnail_switch.get_active ();
        s.play_with_ffplay = play_with_ffplay_switch.get_active ();
        // Already applied and saved the moment it changed; written again here
        // only so this function remains a complete picture of the dialog.
        s.hwdec_mode = index_to_hwdec_mode (hwdec_combo.get_selected ());
        s.preview_quality =
            index_to_preview_quality (preview_quality_combo.get_selected ());
        s.preview_cache_size =
            index_to_preview_cache (preview_cache_combo.get_selected ());
        s.recently_opened_enabled = recently_opened_switch.get_active ();
        s.verify_unknown_audio_copy_preflight =
            verify_unknown_audio_copy_switch.get_active ();
        s.show_bit_depth_warning_dialog =
            show_bit_depth_warning_dialog_switch.get_active ();

        s.smart_optimizer_target_mb = (int) target_mb_spin.get_value ();
        s.smart_optimizer_match_source_size = match_source_size_switch.get_active ();
        s.smart_optimizer_quality_ceiling = (int) quality_ceiling_row.get_selected ();
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
