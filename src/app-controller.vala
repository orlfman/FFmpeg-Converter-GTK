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
    private const uint DRAWTEXT_PROBE_TIMEOUT_MS = 2000;

    // ── Signals ──────────────────────────────────────────────────────────────
    /** Emitted when Smart Optimizer finishes and auto-convert is enabled.
     *  Carries the codec name so MainWindow can ensure the correct tab is visible. */
    public signal void auto_convert_requested (string codec);

    /** Emitted when a Smart Optimizer run starts or finishes, so MainWindow
     *  can enable/disable the cancel button appropriately. */
    public signal void smart_optimizer_running (bool running);

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
    private AudioTab audio_tab;
    private SubtitlesTab subtitles_tab;
    private Converter converter;
    private HamburgerMenu hamburger;
    private Button cancel_button;
    private StatusArea status_area;
    private Adw.ViewStack view_stack;

    // ── Smart Optimizer ──────────────────────────────────────────────────────
    private SmartOptimizer smart_optimizer;
    private Cancellable? smart_opt_cancel = null;
    private int smart_opt_generation = 0;
    private FfmpegRuntimeCapabilities ffmpeg_runtime_capabilities;

    // ── FFmpeg capability probing ────────────────────────────────────────────
    private Cancellable? drawtext_probe_cancel = null;
    private int drawtext_probe_generation = 0;
    private bool drawtext_probe_cache_valid = false;
    private string drawtext_probe_cache_path = "";
    private bool drawtext_probe_cache_available = true;
    private string? drawtext_probe_cache_reason = null;
    private bool overlay_probe_cache_available = true;
    private string? overlay_probe_cache_reason = null;
    private Cancellable? svt_crf_two_pass_probe_cancel = null;
    private int svt_crf_two_pass_probe_generation = 0;
    private string active_svt_crf_two_pass_cache_key = "";

    // ── Codec Registry ───────────────────────────────────────────────────────
    //    Maps ViewStack page names to their ISmartCodecTab, eliminating
    //    repeated 4-way if/else chains for Smart Optimizer, audio speed
    //    constraints, and normalize-audio constraints.
    private HashTable<string, ISmartCodecTab> codec_registry;

    public AppController (FilePickers file_pickers,
                          GeneralTab general_tab,
                          SvtAv1Tab svt_tab,
                          X265Tab x265_tab,
                          X264Tab x264_tab,
                          Vp9Tab vp9_tab,
                          InformationTab info_tab,
                          ConsoleTab console_tab,
                          TrimTab trim_tab,
                          AudioTab audio_tab,
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
        this.audio_tab      = audio_tab;
        this.subtitles_tab  = subtitles_tab;
        this.converter      = converter;
        this.hamburger      = hamburger;
        this.cancel_button  = cancel_button;
        this.status_area    = status_area;
        this.view_stack     = view_stack;

        smart_optimizer = new SmartOptimizer ();
        ffmpeg_runtime_capabilities = new FfmpegRuntimeCapabilities ();
        ffmpeg_runtime_capabilities.svt_crf_two_pass_changed.connect (
            apply_svt_crf_two_pass_capability);

        // Build the codec registry — add new codecs here and they
        // automatically participate in audio constraints + Smart Optimizer.
        codec_registry = new HashTable<string, ISmartCodecTab> (str_hash, str_equal);
        codec_registry.insert ("svt-av1", svt_tab);
        codec_registry.insert ("x265",    x265_tab);
        codec_registry.insert ("x264",    x264_tab);
        codec_registry.insert ("vp9",     vp9_tab);

        wire_all ();
    }

    public override void dispose () {
        if (smart_opt_cancel != null) {
            smart_opt_cancel.cancel ();
            smart_opt_cancel = null;
        }
        if (drawtext_probe_cancel != null) {
            drawtext_probe_cancel.cancel ();
            drawtext_probe_cancel = null;
        }
        if (svt_crf_two_pass_probe_cancel != null) {
            svt_crf_two_pass_probe_cancel.cancel ();
            svt_crf_two_pass_probe_cancel = null;
        }
        base.dispose ();
    }

    /** Cancel any in-flight Smart Optimizer analysis. */
    public void cancel_smart_optimizer () {
        if (smart_opt_cancel != null) {
            smart_opt_cancel.cancel ();
            smart_opt_cancel = null;
        }
    }

    private void wire_all () {
        wire_file_input_changed ();
        wire_crop_detection ();
        wire_audio_speed_constraint ();
        wire_video_speed_constraint ();
        wire_watermark_constraint ();
        wire_drawtext_availability ();
        wire_svt_av1_crf_two_pass_capability ();
        wire_conversion_done ();
        wire_trim_done ();
        wire_trim_tab_focus ();
        wire_subtitle_done ();
        wire_audio_probe_sync ();
        wire_smart_optimizer ();
    }

    private BaseCodecTab? lookup_base_codec_tab (string codec) {
        switch (codec) {
            case "svt-av1": return svt_tab;
            case "x265":    return x265_tab;
            case "x264":    return x264_tab;
            case "vp9":     return vp9_tab;
            default:         return null;
        }
    }

    // ── FFmpeg drawtext support → enable/disable watermark UI ───────────────

    private void wire_svt_av1_crf_two_pass_capability () {
        AppSettings.get_default ().settings_changed.connect (() => {
            string ffmpeg_path = AppSettings.get_default ().ffmpeg_path;
            string cache_key = FfmpegRuntimeCapabilities.build_binary_cache_key (ffmpeg_path);
            if (cache_key == active_svt_crf_two_pass_cache_key) {
                return;
            }

            invalidate_svt_crf_two_pass_capability ();
            refresh_svt_av1_crf_two_pass_capability.begin ();
        });

        invalidate_svt_crf_two_pass_capability ();
        refresh_svt_av1_crf_two_pass_capability.begin ();
    }

    private void invalidate_svt_crf_two_pass_capability () {
        active_svt_crf_two_pass_cache_key = "";
        ffmpeg_runtime_capabilities.set_current_svt_crf_two_pass (
            SvtAv1CrfTwoPassCapabilityStatus.UNKNOWN,
            "Open Preferences > Binaries to verify whether the current FFmpeg build supports SVT-AV1 CRF/QP two-pass"
        );
    }

    private async void refresh_svt_av1_crf_two_pass_capability () {
        string ffmpeg_path = AppSettings.get_default ().ffmpeg_path;
        string cache_key = FfmpegRuntimeCapabilities.build_binary_cache_key (ffmpeg_path);

        SvtAv1CrfTwoPassCapability cached;
        if (ffmpeg_runtime_capabilities.lookup_cached_svt_crf_two_pass (ffmpeg_path, out cached)) {
            apply_svt_crf_two_pass_probe_result (cache_key, ffmpeg_path, cached);
            return;
        }

        if (svt_crf_two_pass_probe_cancel != null) {
            svt_crf_two_pass_probe_cancel.cancel ();
        }

        var cancellable = new Cancellable ();
        svt_crf_two_pass_probe_cancel = cancellable;
        int generation = ++svt_crf_two_pass_probe_generation;

        ffmpeg_runtime_capabilities.set_current_svt_crf_two_pass (
            SvtAv1CrfTwoPassCapabilityStatus.PROBING,
            "Checking whether the current FFmpeg build supports SVT-AV1 CRF/QP two-pass"
        );

        SvtAv1CrfTwoPassCapability capability;
        try {
            capability = yield FfmpegRuntimeCapabilities.probe_svt_av1_crf_two_pass (
                ffmpeg_path,
                cancellable
            );
        } catch (IOError.CANCELLED e) {
            if (svt_crf_two_pass_probe_cancel == cancellable) {
                svt_crf_two_pass_probe_cancel = null;
            }
            return;
        } catch (Error e) {
            if (svt_crf_two_pass_probe_cancel == cancellable) {
                svt_crf_two_pass_probe_cancel = null;
            }
            if (generation != svt_crf_two_pass_probe_generation || cancellable.is_cancelled ()) {
                return;
            }

            capability = new SvtAv1CrfTwoPassCapability ();
            capability.status = SvtAv1CrfTwoPassCapabilityStatus.ERROR;
            capability.reason =
                "SVT-AV1 CRF/QP two-pass: could not be verified ("
                + describe_subprocess_error (e.message) + ").";
            apply_svt_crf_two_pass_probe_result (cache_key, ffmpeg_path, capability);
            return;
        }

        if (svt_crf_two_pass_probe_cancel == cancellable) {
            svt_crf_two_pass_probe_cancel = null;
        }
        if (generation != svt_crf_two_pass_probe_generation || cancellable.is_cancelled ()) {
            return;
        }

        apply_svt_crf_two_pass_probe_result (cache_key, ffmpeg_path, capability);
    }

    private void apply_svt_crf_two_pass_probe_result (string cache_key,
                                                      string ffmpeg_path,
                                                      SvtAv1CrfTwoPassCapability capability) {
        active_svt_crf_two_pass_cache_key = cache_key;
        ffmpeg_runtime_capabilities.cache_svt_crf_two_pass (ffmpeg_path, capability);
        ffmpeg_runtime_capabilities.set_current_svt_crf_two_pass (
            capability.status,
            capability.reason
        );
    }

    private void apply_svt_crf_two_pass_capability (SvtAv1CrfTwoPassCapability capability) {
        svt_tab.set_crf_two_pass_capability (capability);
        converter.set_svt_crf_two_pass_capability (capability);
    }

    private void wire_drawtext_availability () {
        AppSettings.get_default ().settings_changed.connect (() => {
            refresh_filter_availability.begin ();
        });
        refresh_filter_availability.begin ();
    }

    private async void refresh_filter_availability () {
        string ffmpeg_path = AppSettings.get_default ().ffmpeg_path;

        if (drawtext_probe_cache_valid && ffmpeg_path == drawtext_probe_cache_path) {
            general_tab.set_drawtext_available (
                drawtext_probe_cache_available,
                drawtext_probe_cache_reason
            );
            general_tab.set_overlay_available (
                overlay_probe_cache_available,
                overlay_probe_cache_reason
            );
            return;
        }

        if (drawtext_probe_cancel != null) {
            drawtext_probe_cancel.cancel ();
        }

        var cancellable = new Cancellable ();
        drawtext_probe_cancel = cancellable;
        int generation = ++drawtext_probe_generation;

        bool dt_available = false;
        string? dt_reason = null;
        bool ol_available = false;
        string? ol_reason = null;

        try {
            string filters_output = yield run_subprocess_capture (
                { ffmpeg_path, "-hide_banner", "-filters" },
                cancellable
            );

            dt_available = filters_output_supports_filter (filters_output, "drawtext");
            if (!dt_available) {
                dt_reason = "Unavailable — the selected FFmpeg build does not include the drawtext filter";
            }
            ol_available = filters_output_supports_filter (filters_output, "overlay");
            if (!ol_available) {
                ol_reason = "Unavailable — the selected FFmpeg build does not include the overlay filter";
            }
        } catch (IOError.CANCELLED e) {
            if (drawtext_probe_cancel == cancellable) {
                drawtext_probe_cancel = null;
            }
            return;
        } catch (Error e) {
            if (drawtext_probe_cancel == cancellable) {
                drawtext_probe_cancel = null;
            }
            if (generation != drawtext_probe_generation || cancellable.is_cancelled ()) {
                return;
            }

            string failure_reason =
                "Unavailable — failed to inspect the selected FFmpeg build: "
                + describe_subprocess_error (e.message);
            apply_filter_probe_error_result (failure_reason);
            return;
        }

        if (drawtext_probe_cancel == cancellable) {
            drawtext_probe_cancel = null;
        }
        if (generation != drawtext_probe_generation || cancellable.is_cancelled ()) {
            return;
        }

        apply_filter_probe_result (ffmpeg_path,
            dt_available, dt_reason,
            ol_available, ol_reason);
    }

    private void apply_filter_probe_result (string ffmpeg_path,
                                            bool dt_available,
                                            string? dt_reason,
                                            bool ol_available,
                                            string? ol_reason) {
        drawtext_probe_cache_valid = true;
        drawtext_probe_cache_path = ffmpeg_path;
        drawtext_probe_cache_available = dt_available;
        drawtext_probe_cache_reason = dt_reason;
        overlay_probe_cache_available = ol_available;
        overlay_probe_cache_reason = ol_reason;
        general_tab.set_drawtext_available (dt_available, dt_reason);
        general_tab.set_overlay_available (ol_available, ol_reason);
    }

    private void apply_filter_probe_error_result (string failure_reason) {
        general_tab.set_drawtext_available (false, failure_reason);
        general_tab.set_overlay_available (false, failure_reason);
    }

    private static bool filters_output_supports_filter (string output, string filter_name) {
        foreach (string line in output.split ("\n")) {
            string clean = line.strip ();
            if (clean.length == 0 || clean.has_prefix ("Filters:")) {
                continue;
            }

            string[] fields = Regex.split_simple ("\\s+", clean);
            if (fields.length >= 2 && fields[1] == filter_name) {
                return true;
            }
        }

        return false;
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
        timeout_id = Timeout.add (DRAWTEXT_PROBE_TIMEOUT_MS, () => {
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

    private static string describe_subprocess_error (string message) {
        string detail = first_nonempty_line (message) ?? message.strip ();
        if (detail.index_of ("timed out") >= 0) {
            return "the ffmpeg process did not answer a quick filter probe";
        }
        if (detail.index_of ("Permission denied") >= 0) {
            return "permission was denied while starting ffmpeg";
        }
        if (detail.index_of ("No such file or directory") >= 0) {
            return "the configured ffmpeg path could not be started";
        }
        return detail;
    }

    private static string? first_nonempty_line (string? text) {
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

#if COMBINE_WINDOW_TEST_BUILD
    internal static bool filters_output_supports_drawtext_for_widget_test (string output) {
        return filters_output_supports_drawtext (output);
    }
#endif

    // ── Input file changed → probe info, load trim preview, load subtitles ──

    private void wire_file_input_changed () {
        file_pickers.input_entry.changed.connect (() => {
            string path = file_pickers.input_entry.get_text ();
            info_tab.load_input_info (path);
            info_tab.reset_output ();
            general_tab.reset_crop ();
            trim_tab.load_video (path);
            audio_tab.load_video (path);
            subtitles_tab.load_video (path);
            apply_codec_audio_source_state (
                "",
                path.strip ().length > 0
                    ? AudioProbeDisplayState.CHECKING
                    : AudioProbeDisplayState.UNKNOWN
            );
            update_codec_source_file_size (path);
        });
    }

    private void update_codec_source_file_size (string path) {
        foreach (unowned ISmartCodecTab tab in codec_registry.get_values ()) {
            tab.update_source_file_size (path);
        }
    }

    private void apply_codec_audio_source_state (string codec_name,
                                                 AudioProbeDisplayState state) {
        foreach (unowned ISmartCodecTab tab in codec_registry.get_values ()) {
            tab.get_audio_settings_ref ().apply_source_audio_state (codec_name, state);
        }
    }

    public void apply_codec_audio_probe_result (AudioStreamProbeResult audio_probe) {
        foreach (unowned ISmartCodecTab tab in codec_registry.get_values ()) {
            tab.get_audio_settings_ref ().apply_source_audio_probe_result (audio_probe);
        }
    }

    private void wire_audio_probe_sync () {
        audio_tab.source_audio_probe_updated.connect ((audio_probe) => {
            apply_codec_audio_probe_result (audio_probe);
        });
    }

    // ── Crop detection button → uses input file + console ───────────────────

    private void wire_crop_detection () {
        general_tab.crop_detect_clicked.connect (() => {
            string input_file = file_pickers.input_entry.get_text ();
            general_tab.start_crop_detection (input_file, console_tab);
        });
    }

    // ── Audio speed → disable "Copy" in all codec tab audio lists ───────────

    private void wire_audio_speed_constraint () {
        general_tab.audio_speed_toggled.connect ((on) => {
            foreach (unowned ISmartCodecTab tab in codec_registry.get_values ()) {
                tab.get_audio_settings_ref ().update_for_audio_speed (on);
            }
        });
    }

    // ── Video/Audio speed → force re-encode in Trim tab ─────────────────────

    private void wire_video_speed_constraint () {
        general_tab.video_speed_toggled.connect ((on) => {
            trim_tab.update_for_speed (on, general_tab.is_audio_speed_enabled ());
        });
        general_tab.audio_speed_toggled.connect ((on) => {
            trim_tab.update_for_speed (general_tab.is_video_speed_enabled (), on);
        });
    }

    // ── Watermark → force re-encode in Trim tab ─────────────────────────────

    private void wire_watermark_constraint () {
        general_tab.watermark_toggled.connect ((on) => {
            trim_tab.update_for_watermark (on);
        });
    }

    // ── Conversion done → probe output, update hamburger ────────────────────

    private void wire_conversion_done () {
        converter.conversion_done.connect ((output_result) => {
            apply_operation_output (output_result);
        });
    }

    // ── Trim done → same as conversion done ─────────────────────────────────

    private void wire_trim_done () {
        trim_tab.trim_done.connect ((output_result) => {
            apply_operation_output (output_result);
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

        // ── Also re-apply whenever the mode selector changes inside TrimTab ──
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

    // ── Subtitle operation done → probe output, update hamburger ────────────

    private void wire_subtitle_done () {
        subtitles_tab.subtitle_done.connect ((output_result) => {
            apply_operation_output (output_result);
        });
    }

    internal void apply_operation_output (OperationOutputResult output_result) {
        string primary_file = output_result.primary_file_path;
        if (output_result.kind == OperationOutputKind.FILE
            && primary_file.length > 0
            && FileUtils.test (primary_file, FileTest.EXISTS)) {
            info_tab.load_output_info (
                primary_file,
                output_result.source,
                output_result.source_summary
            );
        } else if (output_result.kind == OperationOutputKind.MULTIPLE_FILES
            && output_result.output_paths.length > 0) {
            info_tab.load_output_info_multiple (
                output_result.output_paths,
                output_result.source,
                output_result.source_summary
            );
        } else {
            info_tab.reset_output ();
        }

        hamburger.set_last_output_result (output_result);
        file_pickers.output_entry.set_last_output_result (output_result);
    }

    // ── Smart Optimizer → analyze video, apply recommendation to codec tab ──

    private void wire_smart_optimizer () {
        svt_tab.smart_optimizer_requested.connect (() => {
            run_smart_optimizer.begin ("svt-av1");
        });
        x265_tab.smart_optimizer_requested.connect (() => {
            run_smart_optimizer.begin ("x265");
        });
        x264_tab.smart_optimizer_requested.connect (() => {
            run_smart_optimizer.begin ("x264");
        });
        vp9_tab.smart_optimizer_requested.connect (() => {
            run_smart_optimizer.begin ("vp9");
        });
    }

    /**
     * Run the Smart Optimizer asynchronously for the given codec.
     *
     * Probes the input file, runs content detection and calibration encodes,
     * then applies the recommendation to the corresponding codec tab.
     * Progress is shown in the StatusArea; full details are logged to ConsoleTab.
     *
     * Calibration accuracy depends on knowing the actual output conditions:
     * video filters (scale, crop, etc.), effective duration (seek/time trim),
     * and output audio bitrate. All are gathered from the GeneralTab state.
     */
    private async void run_smart_optimizer (string codec) {
        string input_file = file_pickers.input_entry.get_text ();
        if (input_file.length == 0) {
            status_area.set_status ("Smart Optimizer: select an input file first.",
                StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
            return;
        }

        // Cancel any in-flight optimization
        if (smart_opt_cancel != null) {
            smart_opt_cancel.cancel ();
        }
        smart_opt_cancel = new Cancellable ();
        int my_generation = ++smart_opt_generation;

        // Look up the codec tab once — used for target size, audio probe,
        // strip-audio, and applying the final recommendation.
        var smart_tab = codec_registry.get (codec);

        // Read target from the per-tab spin box; falls back to stored
        // preference if no codec tab is found (should not happen).
        int target_mb = (smart_tab != null)
            ? smart_tab.get_target_mb ()
            : AppSettings.get_default ().smart_optimizer_target_mb;
        status_area.set_status ("Smart Optimizer: analyzing video for %d MB %s target…"
            .printf (target_mb, codec.up ()),
            StatusIcon.SEARCH_ICON, StatusIcon.SEARCH_CSS);
        status_area.start_progress ();
        smart_optimizer_running (true);

        string preferred_codec = codec;

        // ── Build optimization context from GeneralTab state ────────────
        var ctx = OptimizationContext ();

        // Video filter chain — calibration must encode at the same
        // resolution/crop/fps as the actual output
        BaseCodecTab? codec_tab = lookup_base_codec_tab (codec);
        PixelFormatSettingsSnapshot? pixel_format = (codec_tab != null)
            ? codec_tab.snapshot_pixel_format_settings ()
            : null;
        ctx.video_filter_chain = FilterBuilder.build_video_filter_chain (
            general_tab, false, codec, pixel_format);
        ctx.tone_mapping_active = ctx.video_filter_chain.contains ("tonemap=");
        if (codec_tab != null) {
            ctx.output_container = codec_tab.get_container ();
        }

        // Effective duration — if seek/time are set, the encode is shorter
        if (general_tab.is_seek_enabled () || general_tab.is_time_enabled ()) {
            double full_dur = yield FfprobeUtils.probe_duration_async (
                input_file, smart_opt_cancel);
            if (smart_opt_cancel.is_cancelled ()) {
                if (my_generation == smart_opt_generation) {
                    status_area.stop_progress ();
                    smart_optimizer_running (false);
                    status_area.set_status ("Smart Optimizer cancelled.",
                        StatusIcon.CANCELLED_ICON, StatusIcon.CANCELLED_CSS);
                }
                return;
            }
            double start = 0.0;
            double end   = full_dur;

            if (general_tab.is_seek_enabled ()) {
                start = general_tab.get_seek_seconds ();
            }
            if (general_tab.is_time_enabled ()) {
                end = double.min (start + general_tab.get_time_seconds (), full_dur);
            }

            ctx.trim_start_seconds = start;
            if (full_dur > 0) {
                ctx.trim_end_seconds = end;
            }

            double eff = end - start;
            if (eff > 0 && eff < full_dur) {
                ctx.effective_duration = eff;
            } else if (general_tab.is_time_enabled ()) {
                double requested = general_tab.get_time_seconds ();
                if (requested > 0) {
                    ctx.effective_duration = requested;
                }
            }
        }

        // Audio bitrate — determined by the optimizer based on size tier.
        // Do not override here; the optimizer picks the right audio budget
        // for the target size and stores it in the recommendation.

        // Strip audio
        if (smart_tab != null && smart_tab.get_audio_settings_ref ().is_audio_probe_pending ()) {
            status_area.set_status (
                "Checking source audio stream. Please wait a moment and try Smart Optimizer again.",
                StatusIcon.WAITING_ICON, StatusIcon.WAITING_CSS);
            status_area.stop_progress ();
            smart_optimizer_running (false);
            return;
        }

        bool strip_audio = (smart_tab != null) ? smart_tab.get_strip_audio_active () : false;
        if (smart_tab != null && !smart_tab.get_audio_settings_ref ().is_audio_enabled_for_output ()) {
            strip_audio = true;
        }
        ctx.strip_audio = strip_audio;

        // Audio filters (speed, normalize, concat) prevent stream-copy
        if (smart_tab != null) {
            ctx.audio_requires_reencode = smart_tab.get_audio_settings_ref ().requires_audio_reencode ();
        }

        try {
            var rec = yield smart_optimizer.optimize_for_target_size (
                input_file, target_mb, preferred_codec, ctx, smart_opt_cancel);

            status_area.stop_progress ();

            if (rec.is_impossible) {
                status_area.set_status ("Smart Optimizer: target may be unreachable.",
                    StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
                console_tab.add_line ("[Smart Optimizer] " + rec.notes);
                if (my_generation == smart_opt_generation)
                    smart_optimizer_running (false);
                return;
            }

            // Apply recommendation via the codec registry
            if (smart_tab != null) {
                smart_tab.apply_smart_recommendation (rec);
                if (strip_audio) {
                    smart_tab.get_audio_settings_ref ().set_audio_enabled (false);
                }
            }

            // Strip metadata for tiny targets — every byte counts
            if (rec.strip_metadata) {
                general_tab.preserve_metadata.set_active (false);
            }

            status_area.set_status ("Smart Optimizer: CRF %d / %s — est. %d KiB"
                .printf (rec.crf, rec.preset, rec.estimated_size_kib),
                StatusIcon.SUCCESS_ICON, StatusIcon.SUCCESS_CSS);

            // Log full details to console
            string details = SmartOptimizer.format_recommendation (rec);
            foreach (unowned string line in details.split ("\n")) {
                console_tab.add_line ("[Smart Optimizer] " + line);
            }

            // Auto-convert: trigger conversion if the active tab has it enabled
            bool should_auto_convert = (smart_tab != null) ? smart_tab.get_auto_convert_active () : false;

            if (should_auto_convert) {
                console_tab.add_line ("[Smart Optimizer] Auto-convert enabled — starting conversion…");
                auto_convert_requested (codec);
            }

            if (my_generation == smart_opt_generation)
                smart_optimizer_running (false);

        } catch (IOError e) {
            // Only touch UI if this is still the current run — a superseded
            // run must not hide the new run's progress bar or overwrite its status.
            if (my_generation == smart_opt_generation) {
                status_area.stop_progress ();
                smart_optimizer_running (false);
                if (e is IOError.CANCELLED) {
                    status_area.set_status ("Smart Optimizer cancelled.",
                        StatusIcon.CANCELLED_ICON, StatusIcon.CANCELLED_CSS);
                } else {
                    status_area.set_status ("Smart Optimizer error: %s".printf (e.message),
                        StatusIcon.ERROR_ICON, StatusIcon.ERROR_CSS);
                    console_tab.add_line ("[Smart Optimizer] ERROR: " + e.message);
                }
            }
        } catch (Error e) {
            if (my_generation == smart_opt_generation) {
                status_area.stop_progress ();
                smart_optimizer_running (false);
                status_area.set_status ("Smart Optimizer error: %s".printf (e.message),
                    StatusIcon.ERROR_ICON, StatusIcon.ERROR_CSS);
                console_tab.add_line ("[Smart Optimizer] ERROR: " + e.message);
            }
        }

    }
}
