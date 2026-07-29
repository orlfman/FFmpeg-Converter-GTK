using Gtk;
using GLib;

private class SmartOptimizerRunSnapshot : Object {
    public string input_file = "";
    public ConversionUtils.FileSignature? input_signature = null;
    public ConversionUtils.FileSignature? watermark_image_signature = null;
    public GeneralSettingsSnapshot general_settings = new GeneralSettingsSnapshot ();
    public bool seek_enabled = false;
    public double seek_seconds = 0.0;
    public bool time_enabled = false;
    public double time_seconds = 0.0;
    public string container = "";
    public int target_mb = 0;
    public bool match_source_size = false;
    public int64 source_file_size_bytes = -1;
    public ContentOverride content_override = ContentOverride.AUTO;
    public bool optimize_for_delivery = false;
    public bool quality_mode = false;
    public SmartOptimizerLogic.QualityIntent quality_intent =
        SmartOptimizerLogic.QualityIntent.MEDIUM;
    public bool strip_audio_requested = false;
    public bool audio_output_enabled = true;
    public bool audio_probe_pending = false;
    public bool preserve_all_audio_tracks = false;
    public bool audio_requires_reencode = false;
    public string ffmpeg_path = "";
    public string ffprobe_path = "";
}

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

    // ── Input tracking ───────────────────────────────────────────────────────
    // Whether an input change is replacing an earlier file, which is the only
    // case where a heap trim has anything to hand back.
    private string previous_input_path = "";

    // ── FFmpeg capability probing ────────────────────────────────────────────
    private Cancellable? drawtext_probe_cancel = null;
    private int drawtext_probe_generation = 0;
    private bool drawtext_probe_cache_valid = false;
    private string drawtext_probe_cache_path = "";
    private bool drawtext_probe_cache_available = true;
    private string? drawtext_probe_cache_reason = null;
    private bool overlay_probe_cache_available = true;
    private string? overlay_probe_cache_reason = null;
    private bool delogo_probe_cache_available = true;
    private string? delogo_probe_cache_reason = null;
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

        ffmpeg_runtime_capabilities = new FfmpegRuntimeCapabilities ();
        smart_optimizer = new SmartOptimizer (ffmpeg_runtime_capabilities);
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

    private void release_smart_optimizer_cancel (Cancellable cancellable) {
        if (smart_opt_cancel == cancellable)
            smart_opt_cancel = null;
    }

    private SmartOptimizerRunSnapshot capture_smart_optimizer_run_snapshot (
        string input_file,
        string codec,
        GeneralSettingsSnapshot general_settings
    ) {
        var snapshot = new SmartOptimizerRunSnapshot ();
        snapshot.input_file = input_file;
        ConversionUtils.FileSignature? input_signature =
            ConversionUtils.query_file_signature (input_file);
        snapshot.input_signature = input_signature;
        if (input_signature != null)
            snapshot.source_file_size_bytes = input_signature.size;
        snapshot.general_settings = general_settings;
        if (general_settings.watermark_enabled
                && general_settings.watermark_mode == "image"
                && general_settings.watermark_image_path.strip ().length > 0) {
            snapshot.watermark_image_signature =
                ConversionUtils.query_file_signature (
                    general_settings.watermark_image_path);
        }

        var settings = AppSettings.get_default ();
        snapshot.target_mb = settings.smart_optimizer_target_mb;

        snapshot.seek_enabled = general_tab.is_seek_enabled ();
        if (snapshot.seek_enabled)
            snapshot.seek_seconds = general_tab.get_seek_seconds ();
        snapshot.time_enabled = general_tab.is_time_enabled ();
        if (snapshot.time_enabled)
            snapshot.time_seconds = general_tab.get_time_seconds ();

        BaseCodecTab? codec_tab = lookup_base_codec_tab (codec);
        ISmartCodecTab? smart_tab = codec_registry.get (codec);
        if (codec_tab != null) {
            snapshot.container = codec_tab.get_container ();
            snapshot.match_source_size = codec_tab.match_source_size_active;
        }
        if (smart_tab != null) {
            snapshot.target_mb = smart_tab.get_target_mb ();
            snapshot.content_override = smart_tab.get_content_override ();
            snapshot.optimize_for_delivery = smart_tab.get_optimize_for_delivery ();
            snapshot.quality_mode = smart_tab.get_quality_mode_active ();
            snapshot.quality_intent = smart_tab.get_quality_intent ();
            snapshot.strip_audio_requested = smart_tab.get_strip_audio_active ();

            AudioSettings audio = smart_tab.get_audio_settings_ref ();
            snapshot.audio_output_enabled = audio.is_audio_enabled_for_output ();
            snapshot.audio_probe_pending = audio.is_audio_probe_pending ();
            snapshot.preserve_all_audio_tracks = audio.get_keep_all_audio_requested ();
            snapshot.audio_requires_reencode = audio.requires_audio_reencode ();
        }

        // Match Source is derived from the same synchronous file identity used
        // by the stale-result guard. The codec tab's size label is populated
        // asynchronously and can legitimately change from -1 while Smart is
        // running; it must never shape or invalidate the optimization target.
        snapshot.target_mb = SmartOptimizerLogic.resolve_target_mb (
            snapshot.target_mb,
            snapshot.match_source_size,
            input_signature != null ? input_signature.size : -1);

        snapshot.ffmpeg_path = settings.ffmpeg_path;
        snapshot.ffprobe_path = settings.ffprobe_path;
        return snapshot;
    }

    private static bool string_arrays_equal (string[] left, string[] right) {
        if (left.length != right.length)
            return false;
        for (int i = 0; i < left.length; i++) {
            if (left[i] != right[i])
                return false;
        }
        return true;
    }

    private static bool general_settings_equal (GeneralSettingsSnapshot left,
                                                GeneralSettingsSnapshot right) {
        return left.scale_mode == right.scale_mode
            && left.resolution_preset_value == right.resolution_preset_value
            && left.custom_resolution_value == right.custom_resolution_value
            && left.scale_width_multiplier == right.scale_width_multiplier
            && left.scale_height_multiplier == right.scale_height_multiplier
            && left.scale_algorithm == right.scale_algorithm
            && left.scale_range == right.scale_range
            && left.rotate == right.rotate
            && left.crop_enabled == right.crop_enabled
            && left.crop_value == right.crop_value
            && left.frame_rate_text == right.frame_rate_text
            && left.custom_frame_rate_text == right.custom_frame_rate_text
            && left.video_speed_enabled == right.video_speed_enabled
            && left.video_speed_percent == right.video_speed_percent
            && left.audio_speed_enabled == right.audio_speed_enabled
            && left.audio_speed_percent == right.audio_speed_percent
            && left.color_filter == right.color_filter
            && left.preserve_metadata == right.preserve_metadata
            && left.remove_chapters == right.remove_chapters
            && left.watermark_enabled == right.watermark_enabled
            && left.watermark_mode == right.watermark_mode
            && left.watermark_text == right.watermark_text
            && left.watermark_position == right.watermark_position
            && left.watermark_color == right.watermark_color
            && left.watermark_opacity == right.watermark_opacity
            && left.watermark_margin == right.watermark_margin
            && left.watermark_font_size == right.watermark_font_size
            && left.watermark_image_path == right.watermark_image_path
            && left.watermark_image_width == right.watermark_image_width
            && left.delogo_enabled == right.delogo_enabled
            && left.delogo_regions == right.delogo_regions
            && left.pixel_format.eight_bit_selected
                == right.pixel_format.eight_bit_selected
            && left.pixel_format.eight_bit_format_text
                == right.pixel_format.eight_bit_format_text
            && left.pixel_format.ten_bit_selected
                == right.pixel_format.ten_bit_selected
            && left.pixel_format.ten_bit_format_text
                == right.pixel_format.ten_bit_format_text
            && left.video_filters.hdr_filter == right.video_filters.hdr_filter
            && string_arrays_equal (
                left.video_filters.processing_filters,
                right.video_filters.processing_filters);
    }

    private static bool smart_optimizer_mode_settings_equal (
        SmartOptimizerRunSnapshot left,
        SmartOptimizerRunSnapshot right
    ) {
        // Only the active decision axis can shape this run. Target controls
        // are irrelevant in Quality mode; quality intent is irrelevant in
        // Target Size mode.
        return SmartOptimizerLogic.run_mode_settings_equal (
            left.quality_mode, left.quality_intent,
            left.match_source_size, left.target_mb,
            right.quality_mode, right.quality_intent,
            right.match_source_size, right.target_mb);
    }

    private static bool optional_file_signatures_equal (
        ConversionUtils.FileSignature? left,
        ConversionUtils.FileSignature? right
    ) {
        if (left == null || right == null)
            return left == null && right == null;
        return left.matches (right);
    }

    private bool smart_optimizer_run_snapshot_matches (
        SmartOptimizerRunSnapshot expected,
        string codec
    ) {
        if (file_pickers.input_entry.get_text () != expected.input_file)
            return false;

        ConversionUtils.FileSignature? current_signature =
            ConversionUtils.query_file_signature (expected.input_file);
        if (expected.input_signature == null || current_signature == null
                || !expected.input_signature.matches (current_signature))
            return false;

        BaseCodecTab? codec_tab = lookup_base_codec_tab (codec);
        PixelFormatSettingsSnapshot? pixel_format = (codec_tab != null)
            ? codec_tab.snapshot_pixel_format_settings () : null;
        GeneralSettingsSnapshot current_general =
            general_tab.snapshot_settings (pixel_format);
        SmartOptimizerRunSnapshot current = capture_smart_optimizer_run_snapshot (
            expected.input_file, codec, current_general);

        return general_settings_equal (
                expected.general_settings, current.general_settings)
            && optional_file_signatures_equal (
                expected.watermark_image_signature,
                current.watermark_image_signature)
            && expected.seek_enabled == current.seek_enabled
            && expected.seek_seconds == current.seek_seconds
            && expected.time_enabled == current.time_enabled
            && expected.time_seconds == current.time_seconds
            && expected.container == current.container
            && smart_optimizer_mode_settings_equal (expected, current)
            && expected.content_override == current.content_override
            && expected.optimize_for_delivery == current.optimize_for_delivery
            && expected.strip_audio_requested == current.strip_audio_requested
            && expected.audio_output_enabled == current.audio_output_enabled
            && expected.audio_probe_pending == current.audio_probe_pending
            && expected.preserve_all_audio_tracks == current.preserve_all_audio_tracks
            && expected.audio_requires_reencode == current.audio_requires_reencode
            && expected.ffmpeg_path == current.ffmpeg_path
            && expected.ffprobe_path == current.ffprobe_path;
    }

    private void wire_all () {
        wire_file_input_changed ();
        wire_crop_detection ();
        wire_logo_detection ();
        wire_audio_speed_constraint ();
        wire_video_speed_constraint ();
        wire_watermark_constraint ();
        wire_logo_removal_constraint ();
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
            general_tab.set_delogo_available (
                delogo_probe_cache_available,
                delogo_probe_cache_reason
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
        bool dl_available = false;
        string? dl_reason = null;

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
            dl_available = filters_output_supports_filter (filters_output, "delogo");
            if (!dl_available) {
                dl_reason = "Unavailable — the selected FFmpeg build does not include the delogo filter";
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
            ol_available, ol_reason,
            dl_available, dl_reason);
    }

    private void apply_filter_probe_result (string ffmpeg_path,
                                            bool dt_available,
                                            string? dt_reason,
                                            bool ol_available,
                                            string? ol_reason,
                                            bool dl_available,
                                            string? dl_reason) {
        drawtext_probe_cache_valid = true;
        drawtext_probe_cache_path = ffmpeg_path;
        drawtext_probe_cache_available = dt_available;
        drawtext_probe_cache_reason = dt_reason;
        overlay_probe_cache_available = ol_available;
        overlay_probe_cache_reason = ol_reason;
        delogo_probe_cache_available = dl_available;
        delogo_probe_cache_reason = dl_reason;
        general_tab.set_drawtext_available (dt_available, dt_reason);
        general_tab.set_overlay_available (ol_available, ol_reason);
        general_tab.set_delogo_available (dl_available, dl_reason);
    }

    private void apply_filter_probe_error_result (string failure_reason) {
        general_tab.set_drawtext_available (false, failure_reason);
        general_tab.set_overlay_available (false, failure_reason);
        general_tab.set_delogo_available (false, failure_reason);
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
            // A recommendation belongs to the exact file that was measured.
            // Cancel immediately; the end-of-run signature guard below is the
            // backstop for changes that race with async completion.
            if (smart_opt_cancel != null)
                cancel_smart_optimizer ();
            string path = file_pickers.input_entry.get_text ();
            bool replaced_previous_input = previous_input_path.strip ().length > 0;
            previous_input_path = path;
            info_tab.load_input_info (path);
            info_tab.reset_output ();
            general_tab.reset_crop ();
            general_tab.reset_logo_removal ();
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

            // Both players have just torn down their pipelines for the outgoing
            // file. Hand the freed pages back once teardown and the new load
            // settle; the request coalesces and is a no-op below the RSS gate.
            HeapTrim.request (replaced_previous_input);
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

    // ── Watermark detection button → uses input file + console ──────────────

    private void wire_logo_detection () {
        general_tab.logo_detect_clicked.connect (() => {
            string input_file = file_pickers.input_entry.get_text ();
            general_tab.start_logo_detection (input_file, console_tab);
        });
        general_tab.logo_detect_moving_clicked.connect (() => {
            string input_file = file_pickers.input_entry.get_text ();
            general_tab.start_logo_detection (input_file, console_tab, true);
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

    // ── Logo removal → force re-encode in Trim tab ──────────────────────────

    private void wire_logo_removal_constraint () {
        general_tab.logo_removal_toggled.connect ((on) => {
            trim_tab.update_for_logo_removal (on);
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
        // A new analysis supersedes any not-yet-consumed report staged by an
        // older recommendation, including when this run cannot start.
        converter.stage_smart_size_report ("", 0, 0, 0.0);

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
        // Hold this run's token locally. smart_opt_cancel is shared state that
        // the NEXT invocation replaces, so reading it back after a yield would
        // hand this run the successor's fresh, uncancelled token — the check
        // would pass and a superseded run would keep going. The local
        // reference also keeps the object alive after dispose() nulls the
        // property, so an explicit cancel still registers here.
        var my_cancel = new Cancellable ();
        smart_opt_cancel = my_cancel;
        int my_generation = ++smart_opt_generation;

        // Look up the codec tab once — used for target size, audio probe,
        // strip-audio, and applying the final recommendation.
        var smart_tab = codec_registry.get (codec);

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
        GeneralSettingsSnapshot general_snapshot =
            general_tab.snapshot_settings (pixel_format);
        ctx.video_filter_chain = FilterBuilder.build_video_filter_chain_from_snapshot (
            general_snapshot, false, codec);
        ctx.image_watermark = FilterBuilder.snapshot_smart_image_watermark (
            general_snapshot);
        ctx.tone_mapping_active = ctx.video_filter_chain.contains ("tonemap=");
        double parsed_output_fps = 0.0;
        if (CodecUtils.try_resolve_output_fps_from_snapshot (
                general_snapshot, out parsed_output_fps)) {
            ctx.output_fps = parsed_output_fps;
        }
        ctx.video_speed_multiplier =
            FilterBuilder.get_video_speed_multiplier (general_snapshot);
        if (codec_tab != null) {
            ctx.output_container = codec_tab.get_container ();
        }

        // Freeze every input that can shape analysis, calibration, or the
        // recommendation before the first yield. The same state is verified
        // again immediately before applying the result.
        SmartOptimizerRunSnapshot run_snapshot =
            capture_smart_optimizer_run_snapshot (
                input_file, codec, general_snapshot);
        if (run_snapshot.input_signature == null) {
            status_area.stop_progress ();
            smart_optimizer_running (false);
            status_area.set_status (
                "Smart Optimizer: the selected input file could not be read.",
                StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
            release_smart_optimizer_cancel (my_cancel);
            return;
        }
        if (ctx.image_watermark != null
                && run_snapshot.watermark_image_signature == null) {
            status_area.stop_progress ();
            smart_optimizer_running (false);
            status_area.set_status (
                "Smart Optimizer: the selected watermark image could not be read.",
                StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
            release_smart_optimizer_cancel (my_cancel);
            return;
        }
        int target_mb = run_snapshot.target_mb;
        ctx.content_override = run_snapshot.content_override;
        ctx.optimize_for_delivery = run_snapshot.optimize_for_delivery;
        bool quality_mode = run_snapshot.quality_mode;
        var quality_intent = run_snapshot.quality_intent;

        if (run_snapshot.audio_probe_pending) {
            status_area.set_status (
                "Checking source audio stream. Please wait a moment and try Smart Optimizer again.",
                StatusIcon.WAITING_ICON, StatusIcon.WAITING_CSS);
            status_area.stop_progress ();
            smart_optimizer_running (false);
            release_smart_optimizer_cancel (my_cancel);
            return;
        }

        bool strip_audio = run_snapshot.strip_audio_requested
            || !run_snapshot.audio_output_enabled;
        ctx.strip_audio = strip_audio;
        ctx.preserve_all_audio_tracks_requested =
            run_snapshot.preserve_all_audio_tracks;
        ctx.audio_requires_reencode = run_snapshot.audio_requires_reencode;

        // Effective duration — if seek/time are set, the encode is shorter
        if (run_snapshot.seek_enabled || run_snapshot.time_enabled) {
            double full_dur = yield FfprobeUtils.probe_duration_async (
                input_file, my_cancel);
            // Both halves are load-bearing after a resume: the local token
            // catches an explicit cancel of THIS run, and the generation
            // catches supersession by a newer one. Testing only the token
            // would miss the case where a successor cancelled us and then
            // installed its own; testing the shared property would read that
            // successor's token and find it healthy.
            if (my_cancel.is_cancelled () || my_generation != smart_opt_generation) {
                if (my_generation == smart_opt_generation) {
                    status_area.stop_progress ();
                    smart_optimizer_running (false);
                    status_area.set_status ("Smart Optimizer cancelled.",
                        StatusIcon.CANCELLED_ICON, StatusIcon.CANCELLED_CSS);
                    release_smart_optimizer_cancel (my_cancel);
                }
                return;
            }
            double start = 0.0;
            double end   = full_dur;

            if (run_snapshot.seek_enabled) {
                start = run_snapshot.seek_seconds;
            }
            if (run_snapshot.time_enabled) {
                end = double.min (start + run_snapshot.time_seconds, full_dur);
            }

            ctx.trim_start_seconds = start;
            if (full_dur > 0) {
                ctx.trim_end_seconds = end;
            }

            double eff = end - start;
            if (eff > 0 && eff < full_dur) {
                ctx.effective_duration = eff;
            } else if (run_snapshot.time_enabled) {
                double requested = run_snapshot.time_seconds;
                if (requested > 0) {
                    ctx.effective_duration = requested;
                }
            }

            // Match Source Size aims at the whole file, but a seek/time trim
            // encodes only part of it — scale the target to the portion being
            // kept so it holds the source's bytes-per-second density instead
            // of inheriting a target large enough to impose no constraint.
            if (codec_tab != null
                && run_snapshot.match_source_size
                && run_snapshot.source_file_size_bytes > 0
                && full_dur > 0 && eff > 0) {
                target_mb = SmartOptimizerLogic.match_source_target_mb_for_window (
                    run_snapshot.source_file_size_bytes, eff, full_dur);
            }
        }

        // Quality Target cannot function without the configured FFmpeg's
        // libvmaf filter. Check before probing the video; Target Size does not
        // use VMAF and deliberately bypasses this guard.
        if (quality_mode) {
            VmafCapability vmaf_capability;
            try {
                vmaf_capability = yield ffmpeg_runtime_capabilities.get_vmaf_capability (
                    run_snapshot.ffmpeg_path, my_cancel);
            } catch (IOError.CANCELLED e) {
                if (my_generation == smart_opt_generation) {
                    status_area.stop_progress ();
                    smart_optimizer_running (false);
                    status_area.set_status ("Smart Optimizer cancelled.",
                        StatusIcon.CANCELLED_ICON, StatusIcon.CANCELLED_CSS);
                    release_smart_optimizer_cancel (my_cancel);
                }
                return;
            } catch (Error e) {
                if (my_generation != smart_opt_generation)
                    return;
                status_area.stop_progress ();
                smart_optimizer_running (false);
                status_area.set_status (
                    "Quality Target could not check FFmpeg for libvmaf: %s".printf (e.message),
                    StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
                release_smart_optimizer_cancel (my_cancel);
                return;
            }

            if (my_generation != smart_opt_generation)
                return;
            if (my_cancel.is_cancelled ()) {
                status_area.stop_progress ();
                smart_optimizer_running (false);
                status_area.set_status ("Smart Optimizer cancelled.",
                    StatusIcon.CANCELLED_ICON, StatusIcon.CANCELLED_CSS);
                release_smart_optimizer_cancel (my_cancel);
                return;
            }
            if (vmaf_capability.status != VmafCapabilityStatus.SUPPORTED) {
                string reason = vmaf_capability.reason
                    ?? "Quality Target requires FFmpeg with the libvmaf filter. "
                        + "Target Size remains available.";
                status_area.stop_progress ();
                smart_optimizer_running (false);
                status_area.set_status (reason,
                    StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
                console_tab.add_line ("[Smart Optimizer] " + reason);
                release_smart_optimizer_cancel (my_cancel);
                return;
            }
        }

        status_area.set_status (quality_mode
            ? "Smart Optimizer: measuring the %s quality ceiling for %s…".printf (
                quality_intent.to_label (), codec.up ())
            : "Smart Optimizer: analyzing video for %d MB %s target…".printf (
                target_mb, codec.up ()),
            StatusIcon.SEARCH_ICON, StatusIcon.SEARCH_CSS);

        // Audio bitrate — determined by the optimizer based on size tier.
        // Do not override here; the optimizer picks the right audio budget
        // for the target size and stores it in the recommendation.

        try {
            var rec = quality_mode
                ? yield smart_optimizer.optimize_for_quality (
                    input_file, quality_intent, preferred_codec, ctx, my_cancel)
                : yield smart_optimizer.optimize_for_target_size (
                    input_file, target_mb, preferred_codec, ctx, my_cancel);

            // A superseded run must not act on its result. Everything below
            // mutates shared state the live run now owns — it applies settings
            // to the codec tab, takes over the status area, and can fire
            // auto-convert, which would start an encode from a recommendation
            // the user has already replaced. Being cancelled normally raises
            // out of the yield above into the guarded catch; this covers
            // supersession that lands between completion and resumption.
            if (my_generation != smart_opt_generation)
                return;

            // Cancellation can land after the worker completed but before this
            // continuation resumed. Also reject any result whose file or
            // analysis-relevant settings no longer match the frozen snapshot.
            if (my_cancel.is_cancelled ()) {
                status_area.stop_progress ();
                smart_optimizer_running (false);
                status_area.set_status ("Smart Optimizer cancelled.",
                    StatusIcon.CANCELLED_ICON, StatusIcon.CANCELLED_CSS);
                release_smart_optimizer_cancel (my_cancel);
                return;
            }
            if (!smart_optimizer_run_snapshot_matches (run_snapshot, codec)) {
                status_area.stop_progress ();
                smart_optimizer_running (false);
                status_area.set_status (
                    "Smart Optimizer: input or settings changed; result discarded. Run it again.",
                    StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
                console_tab.add_line (
                    "[Smart Optimizer] Input or analysis settings changed while optimization was running; the stale recommendation was not applied.");
                release_smart_optimizer_cancel (my_cancel);
                return;
            }

            status_area.stop_progress ();

            if (rec.is_impossible) {
                status_area.set_status (quality_mode
                    ? "Smart Optimizer: could not measure quality for this video."
                    : "Smart Optimizer: target may be unreachable.",
                    StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
                console_tab.add_line ("[Smart Optimizer] " + rec.notes);
                if (my_generation == smart_opt_generation)
                    smart_optimizer_running (false);
                release_smart_optimizer_cancel (my_cancel);
                return;
            }

            // Apply recommendation via the codec registry
            if (smart_tab != null) {
                smart_tab.apply_smart_recommendation (rec);
                if (strip_audio) {
                    smart_tab.get_audio_settings_ref ().set_audio_enabled (false);
                }
            }

            // Carry the exact solved target—not a re-read of the spin button—
            // into the next matching conversion. This preserves trim-scaled
            // Match Source targets and lets the runner report actual bytes.
            converter.stage_smart_size_report (
                rec.codec,
                rec.pinned_axis == PinnedAxis.SIZE ? rec.target_size_kib : 0,
                rec.pinned_axis == PinnedAxis.SIZE && rec.two_pass
                    ? rec.expected_final_size_kib : 0,
                rec.pinned_axis == PinnedAxis.SIZE && rec.two_pass
                    ? rec.expected_size_error_fraction : 0.0);

            // Strip metadata for tiny targets — every byte counts
            if (rec.strip_metadata) {
                general_tab.preserve_metadata.set_active (false);
            }

            // Both numbers, always — the pinned one and the predicted one.
            // A missing x264 High10 capability is surfaced without a modal,
            // and auto-convert is withheld so the warning is actionable.
            if (rec.bit_depth_attention_required) {
                status_area.set_status (
                    "Smart Optimizer: 10-bit cannot be preserved with this x264; recommendation applied for review.",
                    StatusIcon.WARNING_ICON, StatusIcon.WARNING_CSS);
                console_tab.add_line (
                    "[Smart Optimizer] WARNING: " + rec.bit_depth_attention_reason);
            } else {
                status_area.set_status (rec.vmaf_measured
                    ? "Smart Optimizer: CRF %d / %s — VMAF %.1f, est. %.1f MiB".printf (
                        rec.crf, rec.preset, rec.estimated_vmaf,
                        rec.estimated_size_kib / 1024.0)
                    : "Smart Optimizer: CRF %d / %s — est. %d KiB".printf (
                        rec.crf, rec.preset, rec.estimated_size_kib),
                    StatusIcon.SUCCESS_ICON, StatusIcon.SUCCESS_CSS);
            }

            // Log full details to console
            string details = SmartOptimizer.format_recommendation (rec);
            foreach (unowned string line in details.split ("\n")) {
                console_tab.add_line ("[Smart Optimizer] " + line);
            }

            // Auto-convert: trigger conversion if the active tab has it enabled
            bool auto_convert_enabled = (smart_tab != null)
                ? smart_tab.get_auto_convert_active () : false;
            bool should_auto_convert = auto_convert_enabled
                && !rec.bit_depth_attention_required;

            if (should_auto_convert) {
                console_tab.add_line ("[Smart Optimizer] Auto-convert enabled — starting conversion…");
                auto_convert_requested (codec);
            } else if (auto_convert_enabled && rec.bit_depth_attention_required) {
                console_tab.add_line (
                    "[Smart Optimizer] Auto-convert not started because the configured x264 cannot preserve this source's bit depth.");
            }

            if (my_generation == smart_opt_generation)
                smart_optimizer_running (false);
            release_smart_optimizer_cancel (my_cancel);

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
                release_smart_optimizer_cancel (my_cancel);
            }
        } catch (Error e) {
            if (my_generation == smart_opt_generation) {
                status_area.stop_progress ();
                smart_optimizer_running (false);
                status_area.set_status ("Smart Optimizer error: %s".printf (e.message),
                    StatusIcon.ERROR_ICON, StatusIcon.ERROR_CSS);
                console_tab.add_line ("[Smart Optimizer] ERROR: " + e.message);
                release_smart_optimizer_cancel (my_cancel);
            }
        }

    }
}
