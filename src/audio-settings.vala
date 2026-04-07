using Gtk;
using Adw;

// ═══════════════════════════════════════════════════════════════════════════════
//  AudioSettings — Reusable audio encoding widget
// ═══════════════════════════════════════════════════════════════════════════════

public enum AudioSettingsMode {
    STANDARD,
    TRANSCODE_ONLY
}

public enum AudioProbeDisplayState {
    UNKNOWN,
    CHECKING,
    FOUND,
    MISSING,
    ERROR
}

public enum AudioCopyBlockerReason {
    NONE,
    COMBINE_REENCODE,
    TRIM_CONCAT_FILTER,
    AUDIO_SPEED,
    AUDIO_PROCESSING,
    SOURCE_CONTAINER_INCOMPATIBLE
}

public class AudioCopyAvailabilityResult : Object {
    public bool copy_allowed { get; set; default = true; }
    public AudioCopyBlockerReason primary_blocker { get; set; default = AudioCopyBlockerReason.NONE; }
    public AudioCopyBlockerReason[] all_blockers = {};
    public string fallback_codec { get; set; default = ""; }
    public string source_codec_label { get; set; default = ""; }
    public string container_label { get; set; default = ""; }
}

public class AudioSettings : Object {
    private const string SAMPLE_RATE_SOURCE = "Source";
    private AudioSettingsMode mode;

    // ── Widgets ──────────────────────────────────────────────────────────────
    private Adw.PreferencesGroup group;
    private Box audio_status_header;
    private Image audio_status_icon;
    private Label audio_status_label;

    public Adw.ExpanderRow? audio_expander { get; private set; }
    private Switch?   keep_all_audio_switch;
    public DropDown  codec_combo           { get; private set; }
    public DropDown  sample_rate_combo     { get; private set; }
    public DropDown  bitrate_combo         { get; private set; }
    public DropDown  sample_format_combo   { get; private set; }
    public DropDown  opus_vbr_combo        { get; private set; }
    public Switch    opus_surround_fix     { get; private set; }
    public DropDown  aac_quality_combo     { get; private set; }
    public DropDown  mp3_vbr_combo         { get; private set; }
    public DropDown  flac_compression_combo { get; private set; }
    public DropDown  vorbis_quality_combo  { get; private set; }

    // Rows (for visibility control)
    private Adw.ActionRow? keep_all_audio_row;
    private Adw.ActionRow codec_row;
    private Adw.ActionRow sample_rate_row;
    private Adw.ActionRow bitrate_row;
    private Adw.ActionRow sample_format_row;
    private Adw.ActionRow opus_vbr_row;
    private Adw.ActionRow opus_surround_row;
    private Adw.ActionRow aac_quality_row;
    private Adw.ActionRow mp3_vbr_row;
    private Adw.ActionRow flac_compression_row;
    private Adw.ActionRow vorbis_quality_row;

    // State for codec list constraints
    private string current_container = ContainerExt.MKV;
    private bool   speed_active = false;
    private bool   processing_active = false;
    private bool   concat_filter_active = false;
    private bool   combine_reencode_active = false;
    private bool   desired_audio_enabled = true;
    private bool   suppress_audio_enabled_tracking = false;
    private bool   suppress_codec_tracking = false;
    private AudioProbeDisplayState audio_probe_state = AudioProbeDisplayState.UNKNOWN;
    private string current_status_css_class = "";
    private AudioSourceInfo source_audio = new AudioSourceInfo ();
    private AudioSourceInfo[] all_source_audio = {};
    private string desired_codec = "";

    // Display-only badge override (set by Combine, shown only when probe state is UNKNOWN)
    private bool   has_audio_status_override = false;
    private string audio_status_override_icon = "";
    private string audio_status_override_text = "";
    private string audio_status_override_css = "";

    public signal void changed ();

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public AudioSettings (AudioSettingsMode mode = AudioSettingsMode.STANDARD,
                          string initial_container = ContainerExt.MKV) {
        this.mode = mode;
        this.current_container = initial_container;
        inject_audio_status_css ();
        build_ui ();
        connect_signals ();
        desired_codec = get_codec_text ();
        update_codec_visibility ();
        if (uses_probe_ui ()) {
            set_audio_probe_state (AudioProbeDisplayState.UNKNOWN);
        }
    }

    public Adw.PreferencesGroup get_widget () {
        return group;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  BUILD UI
    // ═════════════════════════════════════════════════════════════════════════

    private static bool css_injected = false;

    private static void inject_audio_status_css () {
        if (css_injected) return;
        css_injected = true;

        var css = new CssProvider ();
        css.load_from_string (
            ".audio-status-found {\n" +
            "    color: @success_color;\n" +
            "    font-size: 0.85em;\n" +
            "}\n" +
            ".audio-status-missing {\n" +
            "    color: @error_color;\n" +
            "    font-size: 0.85em;\n" +
            "}\n" +
            ".audio-status-checking {\n" +
            "    color: @warning_color;\n" +
            "    font-size: 0.85em;\n" +
            "}\n" +
            ".audio-status-neutral {\n" +
            "    color: @window_fg_color;\n" +
            "    font-size: 0.85em;\n" +
            "}\n" +
            ".audio-status-error {\n" +
            "    color: @warning_color;\n" +
            "    font-size: 0.85em;\n" +
            "}\n"
        );
        var display = Gdk.Display.get_default ();
        if (display == null) {
            return;
        }
        GtkCompat.add_provider_for_display (
            display,
            css,
            STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }

    private bool uses_probe_ui () {
        return mode == AudioSettingsMode.STANDARD;
    }

    private bool is_transcode_only_mode () {
        return mode == AudioSettingsMode.TRANSCODE_ONLY;
    }

    private void add_audio_row (Widget row) {
        var expander = audio_expander;
        if (expander != null) {
            expander.add_row (row);
        } else {
            group.add (row);
        }
    }

    private static string[] get_permissive_transcode_codecs () {
        return AudioCompatibilityLogic.get_permissive_transcode_codecs ();
    }

    private static string[] get_initial_codec_options_for_mode (
        AudioSettingsMode mode,
        string container = ContainerExt.MKV) {
        if (mode == AudioSettingsMode.TRANSCODE_ONLY) {
            return get_permissive_transcode_codecs ();
        }

        return AudioCompatibilityLogic.get_selectable_codecs_for_container (container);
    }

#if AUDIO_SETTINGS_TEST_BUILD
    internal static string[] get_transcode_only_codecs_for_test () {
        return get_permissive_transcode_codecs ();
    }

    internal static string[] get_selectable_codecs_for_container_for_test (string container) {
        return AudioCompatibilityLogic.get_selectable_codecs_for_container (container);
    }

    internal static string[] get_initial_codec_options_for_mode_for_test (
        AudioSettingsMode mode,
        string container = ContainerExt.MKV) {
        return get_initial_codec_options_for_mode (mode, container);
    }

    internal static AudioProbeDisplayState map_probe_presence_to_display_state_for_test (
        MediaStreamPresence presence) {
        switch (presence) {
        case MediaStreamPresence.PRESENT:
            return AudioProbeDisplayState.FOUND;
        case MediaStreamPresence.ABSENT:
            return AudioProbeDisplayState.MISSING;
        case MediaStreamPresence.ERROR:
            return AudioProbeDisplayState.ERROR;
        case MediaStreamPresence.UNKNOWN:
        default:
            return AudioProbeDisplayState.UNKNOWN;
        }
    }
#endif

    private void build_ui () {
        group = new Adw.PreferencesGroup ();
        if (uses_probe_ui ()) {
            group.set_title ("Audio");
            group.set_description ("Audio stream encoding settings");

            audio_status_header = new Box (Orientation.HORIZONTAL, 6);
            audio_status_header.set_halign (Align.END);
            audio_status_header.set_valign (Align.CENTER);

            audio_status_icon = new Image ();
            audio_status_icon.set_valign (Align.CENTER);
            audio_status_header.append (audio_status_icon);

            audio_status_label = new Label ("");
            audio_status_label.set_xalign (0.0f);
            audio_status_label.set_halign (Align.END);
            audio_status_label.set_wrap (false);
            audio_status_label.set_ellipsize (Pango.EllipsizeMode.END);
            audio_status_header.append (audio_status_label);

            group.set_header_suffix (audio_status_header);

            var expander = new Adw.ExpanderRow ();
            expander.set_title ("Include Audio");
            expander.set_subtitle ("Disable to strip audio entirely from the output");
            expander.set_show_enable_switch (true);
            expander.set_enable_expansion (true);
            expander.set_expanded (true);
            audio_expander = expander;
            group.add (expander);
        } else {
            group.set_title ("Codec Settings");
            group.set_description ("Configure the audio encoding parameters");
            audio_expander = null;
        }

        // ── Keep All Audio Tracks (STANDARD mode only) ──────────────────────
        if (!is_transcode_only_mode ()) {
            keep_all_audio_row = new Adw.ActionRow ();
            keep_all_audio_row.set_title ("Keep All Audio Tracks");
            keep_all_audio_row.set_subtitle (KEEP_ALL_AUDIO_SUBTITLE_DEFAULT);
            keep_all_audio_switch = new Switch ();
            keep_all_audio_switch.set_valign (Align.CENTER);
            keep_all_audio_switch.set_active (false);
            keep_all_audio_row.add_suffix (keep_all_audio_switch);
            keep_all_audio_row.set_activatable_widget (keep_all_audio_switch);
            add_audio_row (keep_all_audio_row);
        }

        // ── Codec ────────────────────────────────────────────────────────────
        string[] codec_options;
        codec_options = get_initial_codec_options_for_mode (mode, current_container);
        codec_row = new Adw.ActionRow ();
        codec_row.set_title ("Codec");
        codec_row.set_subtitle (
            is_transcode_only_mode ()
            ? "Choose the output codec for re-encoding"
            : "Copy passes audio through without re-encoding"
        );
        codec_combo = new DropDown (
            CodecUtils.build_dropdown_string_list (codec_options),
            null
        );
        codec_combo.set_valign (Align.CENTER);
        codec_combo.set_selected (0);
        codec_row.add_suffix (codec_combo);
        add_audio_row (codec_row);

        // ── Sample Rate ──────────────────────────────────────────────────────
        sample_rate_row = new Adw.ActionRow ();
        sample_rate_row.set_title ("Sample Rate");
        sample_rate_row.set_subtitle (
            "Source preserves the input rate; choose a target only when resampling intentionally");
        sample_rate_combo = new DropDown (CodecUtils.build_dropdown_string_list (
            AudioCodecOptions.sample_rates ()), null);
        sample_rate_combo.set_valign (Align.CENTER);
        sample_rate_combo.set_selected (0);
        sample_rate_row.add_suffix (sample_rate_combo);
        sample_rate_row.set_visible (false);
        add_audio_row (sample_rate_row);

        // ── Bitrate ──────────────────────────────────────────────────────────
        bitrate_row = new Adw.ActionRow ();
        bitrate_row.set_title ("Bitrate");
        bitrate_row.set_subtitle ("Higher = better quality, larger file");
        bitrate_combo = new DropDown (CodecUtils.build_dropdown_string_list (
            AudioCodecOptions.bitrates ()), null);
        bitrate_combo.set_valign (Align.CENTER);
        bitrate_combo.set_selected (AudioCodecOptions.BITRATE_DEFAULT);
        bitrate_row.add_suffix (bitrate_combo);
        bitrate_row.set_visible (false);
        add_audio_row (bitrate_row);

        // ── Sample Format / Bit Depth ───────────────────────────────────────
        sample_format_row = new Adw.ActionRow ();
        sample_format_row.set_title ("Bit Depth");
        sample_format_row.set_subtitle ("Options vary by codec");
        string[] sample_format_options = {
            "Source", "16-bit", "24-bit", "32-bit", "32-bit float"
        };
        sample_format_combo = new DropDown (CodecUtils.build_dropdown_string_list (
            sample_format_options
        ), null);
        sample_format_combo.set_valign (Align.CENTER);
        sample_format_combo.set_selected (0);
        sample_format_row.add_suffix (sample_format_combo);
        sample_format_row.set_visible (false);
        add_audio_row (sample_format_row);

        // ── Opus VBR Mode ────────────────────────────────────────────────────
        opus_vbr_row = new Adw.ActionRow ();
        opus_vbr_row.set_title ("VBR Mode");
        opus_vbr_row.set_subtitle ("Variable bitrate mode for Opus encoding");
        opus_vbr_combo = new DropDown (CodecUtils.build_dropdown_string_list (
            AudioCodecOptions.opus_vbr ()), null);
        opus_vbr_combo.set_valign (Align.CENTER);
        opus_vbr_combo.set_selected (0);
        opus_vbr_row.add_suffix (opus_vbr_combo);
        opus_vbr_row.set_visible (false);
        add_audio_row (opus_vbr_row);

        // ── Opus Surround ────────────────────────────────────────────────────
        opus_surround_row = new Adw.ActionRow ();
        opus_surround_row.set_title ("Surround Downmix");
        opus_surround_row.set_subtitle ("Downmix surround audio to stereo for broad Opus player compatibility");
        opus_surround_fix = new Switch ();
        opus_surround_fix.set_valign (Align.CENTER);
        opus_surround_fix.set_active (true);
        opus_surround_row.add_suffix (opus_surround_fix);
        opus_surround_row.set_activatable_widget (opus_surround_fix);
        opus_surround_row.set_visible (false);
        add_audio_row (opus_surround_row);

        // ── AAC Quality ──────────────────────────────────────────────────────
        aac_quality_row = new Adw.ActionRow ();
        aac_quality_row.set_title ("Quality Scale");
        aac_quality_row.set_subtitle ("Disabled uses bitrate instead");
        aac_quality_combo = new DropDown (CodecUtils.build_dropdown_string_list (
            AudioCodecOptions.aac_quality ()), null);
        aac_quality_combo.set_valign (Align.CENTER);
        aac_quality_combo.set_selected (0);
        aac_quality_row.add_suffix (aac_quality_combo);
        aac_quality_row.set_visible (false);
        add_audio_row (aac_quality_row);

        // ── MP3 VBR Quality ──────────────────────────────────────────────────
        mp3_vbr_row = new Adw.ActionRow ();
        mp3_vbr_row.set_title ("VBR Quality");
        mp3_vbr_row.set_subtitle ("0 = best quality — Disabled uses bitrate instead");
        mp3_vbr_combo = new DropDown (CodecUtils.build_dropdown_string_list (
            AudioCodecOptions.mp3_vbr ()), null);
        mp3_vbr_combo.set_valign (Align.CENTER);
        mp3_vbr_combo.set_selected (0);
        mp3_vbr_row.add_suffix (mp3_vbr_combo);
        mp3_vbr_row.set_visible (false);
        add_audio_row (mp3_vbr_row);

        // ── FLAC Compression ─────────────────────────────────────────────────
        flac_compression_row = new Adw.ActionRow ();
        flac_compression_row.set_title ("Compression Level");
        flac_compression_row.set_subtitle ("Higher = slower but smaller file (0–12)");
        flac_compression_combo = new DropDown (CodecUtils.build_dropdown_string_list (
            AudioCodecOptions.flac_compression ()), null);
        flac_compression_combo.set_valign (Align.CENTER);
        flac_compression_combo.set_selected (AudioCodecOptions.FLAC_COMPRESSION_DEFAULT);
        flac_compression_row.add_suffix (flac_compression_combo);
        flac_compression_row.set_visible (false);
        add_audio_row (flac_compression_row);

        // ── Vorbis Quality ───────────────────────────────────────────────────
        vorbis_quality_row = new Adw.ActionRow ();
        vorbis_quality_row.set_title ("Quality");
        vorbis_quality_row.set_subtitle ("Higher = better — Disabled uses bitrate instead");
        vorbis_quality_combo = new DropDown (CodecUtils.build_dropdown_string_list (
            AudioCodecOptions.vorbis_quality ()), null);
        vorbis_quality_combo.set_valign (Align.CENTER);
        vorbis_quality_combo.set_selected (0);
        vorbis_quality_row.add_suffix (vorbis_quality_combo);
        vorbis_quality_row.set_visible (false);
        add_audio_row (vorbis_quality_row);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SIGNALS
    // ═════════════════════════════════════════════════════════════════════════

    private void connect_signals () {
        codec_combo.notify["selected"].connect (on_codec_combo_selected_notify);
        aac_quality_combo.notify["selected"].connect (update_codec_visibility);
        mp3_vbr_combo.notify["selected"].connect (update_codec_visibility);
        vorbis_quality_combo.notify["selected"].connect (update_codec_visibility);
        if (keep_all_audio_switch != null) {
            keep_all_audio_switch.notify["active"].connect (() => {
                rebuild_codec_list ();
            });
        }
        if (audio_expander != null) {
            audio_expander.notify["enable-expansion"].connect (
                on_audio_expander_enable_expansion_notify);
        }
    }

    private void on_codec_combo_selected_notify () {
        if (!suppress_codec_tracking) {
            desired_codec = get_codec_text ();
        }
        update_codec_visibility ();
    }

    private void on_audio_expander_enable_expansion_notify () {
        var expander = audio_expander;
        if (expander == null)
            return;

        if (!suppress_audio_enabled_tracking && expander.sensitive) {
            desired_audio_enabled = expander.enable_expansion;
        }
        changed ();
    }

    internal static bool codec_uses_quality_scale (string codec,
                                                   string aac_quality,
                                                   string mp3_vbr_quality,
                                                   string vorbis_quality) {
        if (codec == AudioCodecName.AAC)
            return aac_quality != "Disabled";
        if (codec == AudioCodecName.MP3)
            return mp3_vbr_quality != "Disabled";
        if (codec == AudioCodecName.VORBIS)
            return vorbis_quality != "Disabled";
        return false;
    }

    private bool active_codec_uses_quality_scale (string codec) {
        return codec_uses_quality_scale (
            codec,
            get_dropdown_text (aac_quality_combo),
            get_dropdown_text (mp3_vbr_combo),
            get_dropdown_text (vorbis_quality_combo)
        );
    }

    private void update_codec_visibility () {
        string codec = get_codec_text ();
        bool is_copy = (codec == AudioCodecName.COPY);
        bool use_quality_scale = active_codec_uses_quality_scale (codec);

        update_sample_rate_model (codec);
        update_bitrate_model (codec);
        update_sample_format_model (codec);
        sample_rate_row.set_visible (!is_copy);
        bitrate_row.set_visible (should_show_bitrate_for_codec (codec));
        bitrate_row.set_sensitive (!use_quality_scale);
        bitrate_row.set_subtitle (
            use_quality_scale
            ? "Ignored while quality scale is enabled"
            : "Higher = better quality, larger file"
        );

        opus_vbr_row.set_visible (codec == AudioCodecName.OPUS);
        opus_surround_row.set_visible (codec == AudioCodecName.OPUS);
        aac_quality_row.set_visible (codec == AudioCodecName.AAC);
        mp3_vbr_row.set_visible (codec == AudioCodecName.MP3);
        flac_compression_row.set_visible (codec == AudioCodecName.FLAC);
        vorbis_quality_row.set_visible (codec == AudioCodecName.VORBIS);
        changed ();
    }

    private void update_sample_rate_model (string codec) {
        string prev = get_dropdown_text (sample_rate_combo);
        string[] labels = get_sample_rate_labels_for_codec (codec);

        sample_rate_combo.set_model (CodecUtils.build_dropdown_string_list (labels));
        restore_dropdown_selection (sample_rate_combo, labels, prev);
    }

    private void update_bitrate_model (string codec) {
        string prev = get_dropdown_text (bitrate_combo);
        string[] labels = get_bitrate_labels_for_codec (codec);

        bitrate_combo.set_model (CodecUtils.build_dropdown_string_list (labels));
        restore_dropdown_selection (bitrate_combo, labels, prev);
    }

    private void update_sample_format_model (string codec) {
        string prev = get_dropdown_text (sample_format_combo);
        string[] labels = get_sample_format_labels_for_codec (codec);
        bool visible = should_show_sample_format_for_codec (codec);

        sample_format_row.set_title (get_sample_format_title_for_codec (codec));
        sample_format_row.set_subtitle (get_sample_format_subtitle_for_codec (codec));

        sample_format_combo.set_model (CodecUtils.build_dropdown_string_list (labels));
        restore_dropdown_selection (sample_format_combo, labels, prev);
        sample_format_row.set_visible (visible && codec != AudioCodecName.COPY);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CONTAINER FILTERING
    // ═════════════════════════════════════════════════════════════════════════

    public void update_for_container (string container) {
        current_container = container;
        rebuild_codec_list ();
    }

    public void apply_source_audio_state (string codec_name, AudioProbeDisplayState state) {
        source_audio.codec_name = codec_name;
        if (state != AudioProbeDisplayState.FOUND) {
            source_audio = new AudioSourceInfo ();
            source_audio.codec_name = codec_name;
        }
        apply_audio_probe_state (state, false);
        rebuild_codec_list ();
    }

    public void apply_source_audio_probe_result (AudioStreamProbeResult audio_probe) {
        all_source_audio = audio_probe.all_sources;

        switch (audio_probe.presence) {
        case MediaStreamPresence.PRESENT:
            source_audio = AudioSourceLogic.from_probe_result (audio_probe);
            apply_source_audio_state (audio_probe.codec_name, AudioProbeDisplayState.FOUND);
            break;
        case MediaStreamPresence.ABSENT:
            all_source_audio = {};
            apply_source_audio_state ("", AudioProbeDisplayState.MISSING);
            break;
        case MediaStreamPresence.ERROR:
            all_source_audio = {};
            apply_source_audio_state ("", AudioProbeDisplayState.ERROR);
            break;
        case MediaStreamPresence.UNKNOWN:
        default:
            all_source_audio = {};
            apply_source_audio_state ("", AudioProbeDisplayState.UNKNOWN);
            break;
        }
    }

    public void update_for_audio_speed (bool active) {
        speed_active = active;
        rebuild_codec_list ();
    }

    /**
     * When shared audio processing is enabled, stream-copy must be disabled
     * because output filters require re-encoding.
     */
    public void update_for_processing (bool active) {
        if (processing_active == active) {
            return;
        }
        processing_active = active;
        rebuild_codec_list ();
    }

    /**
     * When the concat filter pipeline is active (multi-segment re-encode
     * with combined output), audio passes through -filter_complex which
     * decodes it — stream-copy is impossible.
     */
    public void update_for_concat_filter (bool active) {
        concat_filter_active = active;
        rebuild_codec_list ();
    }

    public void update_for_combine_reencode (bool active) {
        combine_reencode_active = active;
        rebuild_codec_list ();
    }

    private const string KEEP_ALL_AUDIO_SUBTITLE_DEFAULT =
        "Preserve all source audio tracks in the output";
    private const string KEEP_ALL_AUDIO_LOCK_REASON =
        "Disabled while Combine is open — Combine does not support multiple audio tracks";

    public void set_keep_all_audio_sensitive (bool sensitive) {
        if (keep_all_audio_row != null) {
            keep_all_audio_row.set_sensitive (sensitive);
            keep_all_audio_row.set_subtitle (
                sensitive ? KEEP_ALL_AUDIO_SUBTITLE_DEFAULT : KEEP_ALL_AUDIO_LOCK_REASON);
            keep_all_audio_row.set_tooltip_text (sensitive ? null : KEEP_ALL_AUDIO_LOCK_REASON);
        }
        if (keep_all_audio_switch != null) {
            keep_all_audio_switch.set_sensitive (sensitive);
        }
    }

    public void clear_keep_all_audio () {
        if (keep_all_audio_switch != null && keep_all_audio_switch.get_sensitive ()) {
            keep_all_audio_switch.set_active (false);
        }
    }

    /**
     * Sets a display-only badge override that replaces the normal probe badge
     * when audio_probe_state is UNKNOWN.  Used by Combine to show meaningful
     * status instead of "Audio status unavailable."
     */
    public void set_audio_status_override (string icon_name, string text, string css_class) {
        has_audio_status_override = true;
        audio_status_override_icon = icon_name;
        audio_status_override_text = text;
        audio_status_override_css = css_class;
        refresh_audio_status_display ();
    }

    public void clear_audio_status_override () {
        if (!has_audio_status_override) {
            return;
        }
        has_audio_status_override = false;
        audio_status_override_icon = "";
        audio_status_override_text = "";
        audio_status_override_css = "";
        refresh_audio_status_display ();
    }

    /**
     * True when audio filters (speed change, shared processing, concat) are
     * active and stream-copy is not possible — audio must be re-encoded.
     */
    public bool requires_audio_reencode () {
        return speed_active
            || processing_active
            || concat_filter_active
            || combine_reencode_active;
    }

    public void set_audio_enabled (bool enabled) {
        desired_audio_enabled = enabled;

        var expander = audio_expander;
        if (expander == null) {
            return;
        }

        if (audio_probe_state == AudioProbeDisplayState.MISSING) {
            expander.set_sensitive (false);
            set_audio_expander_enabled (false);
            changed ();
            return;
        }

        expander.set_sensitive (true);
        set_audio_expander_enabled (enabled);
        changed ();
    }

    public bool is_audio_enabled_for_output () {
        var expander = audio_expander;
        if (expander == null) {
            return true;
        }

        return expander.enable_expansion
            && audio_probe_state != AudioProbeDisplayState.MISSING;
    }

    public bool is_audio_probe_pending () {
        return audio_probe_state == AudioProbeDisplayState.CHECKING;
    }

    public bool is_audio_probe_uncertain () {
        return audio_probe_state == AudioProbeDisplayState.UNKNOWN
            || audio_probe_state == AudioProbeDisplayState.ERROR;
    }

    public bool should_verify_unknown_audio_copy_compatibility (string container) {
        if (audio_expander == null) {
            return false;
        }

        if (!is_audio_probe_uncertain ())
            return false;

        if (!container_requires_audio_copy_verification (container))
            return false;

        AudioSettingsSnapshot snapshot = snapshot_settings ();
        return snapshot.enabled && snapshot.codec == AudioCodecName.COPY;
    }

    public void set_audio_probe_state (AudioProbeDisplayState state) {
        apply_audio_probe_state (state, true);
    }

    private void apply_audio_probe_state (AudioProbeDisplayState state,
                                          bool rebuild_after) {
        audio_probe_state = state;

        if (!uses_probe_ui ()) {
            if (rebuild_after) {
                rebuild_codec_list ();
            }
            return;
        }

        var expander = audio_expander;
        if (expander == null) {
            if (rebuild_after) {
                rebuild_codec_list ();
            }
            return;
        }

        switch (state) {
        case AudioProbeDisplayState.UNKNOWN:
            render_unknown_audio_badge ();
            restore_user_audio_state ();
            break;
        case AudioProbeDisplayState.CHECKING:
            set_audio_status ("view-refresh-symbolic",
                              "Checking audio stream...",
                              "audio-status-checking");
            expander.set_sensitive (false);
            break;
        case AudioProbeDisplayState.FOUND:
            set_audio_status ("emblem-default-symbolic",
                              "Audio found",
                              "audio-status-found");
            restore_user_audio_state ();
            break;
        case AudioProbeDisplayState.MISSING:
            set_audio_status ("window-close-symbolic",
                              "No audio found",
                              "audio-status-missing");
            expander.set_sensitive (false);
            set_audio_expander_enabled (false);
            break;
        case AudioProbeDisplayState.ERROR:
        default:
            set_audio_status ("dialog-warning-symbolic",
                              "Unable to inspect audio",
                              "audio-status-error");
            restore_user_audio_state ();
            break;
        }

        if (rebuild_after) {
            rebuild_codec_list ();
        } else {
            changed ();
        }
    }

    private void restore_user_audio_state () {
        set_audio_enabled (desired_audio_enabled);
    }

    private void set_audio_expander_enabled (bool enabled) {
        var expander = audio_expander;
        if (expander == null) {
            return;
        }

        suppress_audio_enabled_tracking = true;
        expander.set_enable_expansion (enabled);
        suppress_audio_enabled_tracking = false;
    }

    /**
     * Re-evaluates which badge to show based on current probe state and
     * override.  Called when the override changes so the display updates
     * without re-running probe side effects.
     */
    private void refresh_audio_status_display () {
        if (!uses_probe_ui ()) {
            return;
        }
        if (audio_probe_state == AudioProbeDisplayState.UNKNOWN) {
            render_unknown_audio_badge ();
        }
        // Non-UNKNOWN states are authoritative — override never applies.
    }

    private void render_unknown_audio_badge () {
        if (has_audio_status_override) {
            set_audio_status (audio_status_override_icon,
                              audio_status_override_text,
                              audio_status_override_css);
        } else {
            set_audio_status ("dialog-question-symbolic",
                              "Audio status unavailable",
                              "audio-status-neutral");
        }
    }

    private void set_audio_status (string icon_name, string text, string css_class) {
        if (!uses_probe_ui ()) {
            return;
        }

        audio_status_icon.set_from_icon_name (icon_name);
        audio_status_label.set_text (text);
        if (current_status_css_class != css_class) {
            if (current_status_css_class.length > 0) {
                audio_status_icon.remove_css_class (current_status_css_class);
                audio_status_label.remove_css_class (current_status_css_class);
            }
            audio_status_icon.add_css_class (css_class);
            audio_status_label.add_css_class (css_class);
            current_status_css_class = css_class;
        }
    }

    private void rebuild_codec_list () {
        string current = get_codec_text ();
        string[] codecs;
        AudioCopyAvailabilityResult? evaluation = null;

        if (is_transcode_only_mode ()) {
            codecs = get_permissive_transcode_codecs ();
        } else {
            ContainerAudioPolicy policy =
                AudioCompatibilityLogic.get_container_audio_policy (current_container);
            codecs = policy.selectable_codecs;
            evaluation = evaluate_audio_copy_availability ();
            if (!evaluation.copy_allowed) {
                string[] filtered = {};
                foreach (string c in codecs) {
                    if (c != AudioCodecName.COPY) filtered += c;
                }
                codecs = filtered;
            }
        }

        var new_list = CodecUtils.build_dropdown_string_list (codecs);
        suppress_codec_tracking = true;
        codec_combo.set_model (new_list);
        restore_codec_selection (new_list, desired_codec, current);
        suppress_codec_tracking = false;

        if (!is_transcode_only_mode () && evaluation != null) {
            update_codec_row_subtitle (evaluation);
        }
        update_codec_visibility ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  GET FFMPEG AUDIO ARGS
    // ═════════════════════════════════════════════════════════════════════════

    public AudioSettingsSnapshot snapshot_settings () {
        var snapshot = new AudioSettingsSnapshot ();
        // Source-audio detection is authoritative: when the selected input
        // has no audio stream, force the exported profile to behave as -an
        // even if some caller previously left the UI toggle enabled.
        snapshot.enabled = is_audio_enabled_for_output ();
        snapshot.codec = get_codec_text ();
        snapshot.preserve_all_audio_tracks =
            keep_all_audio_switch != null && keep_all_audio_switch.active;
        snapshot.source = source_audio.copy ();
        AudioSourceInfo[] sources_copy = {};
        foreach (unowned AudioSourceInfo s in all_source_audio) {
            sources_copy += s.copy ();
        }
        snapshot.all_sources = sources_copy;

        string sr_text = get_dropdown_text (sample_rate_combo);
        snapshot.sample_rate_hz = parse_sample_rate_selection (sr_text);

        string br_text = get_dropdown_text (bitrate_combo);
        string br_num = br_text.replace (" kbps", "");
        if (br_num.length > 0)
            snapshot.bitrate_kbps = int.parse (br_num);

        snapshot.opus_vbr_mode = get_dropdown_text (opus_vbr_combo);
        snapshot.opus_surround_fix = opus_surround_fix.active;
        snapshot.aac_quality = get_dropdown_text (aac_quality_combo);
        snapshot.mp3_vbr_quality = get_dropdown_text (mp3_vbr_combo);
        snapshot.flac_compression = get_dropdown_text (flac_compression_combo);
        snapshot.vorbis_quality = get_dropdown_text (vorbis_quality_combo);
        snapshot.sample_format = get_dropdown_text (sample_format_combo);
        return snapshot;
    }

    public string[] get_audio_args () {
        return build_audio_args_from_snapshot (snapshot_settings ());
    }

    internal static string[] build_sample_format_args_for_snapshot (
        AudioSettingsSnapshot snapshot) {
        string codec = snapshot.codec;
        string[] args = {};
        string effective_sample_format = get_effective_sample_format_selection_for_codec (snapshot);

        if (codec == AudioCodecName.WAV
            || codec == AudioCodecName.AAC
            || codec == AudioCodecName.VORBIS) {
            return args;
        }

        if (codec == AudioCodecName.FLAC) {
            if (effective_sample_format == "16-bit") {
                args += "-sample_fmt";
                args += "s16";
            } else if (effective_sample_format == "24-bit") {
                args += "-sample_fmt";
                args += "s32";
                args += "-bits_per_raw_sample";
                args += "24";
            } else if (effective_sample_format == "32-bit") {
                args += "-sample_fmt";
                args += "s32";
            }
        } else if (codec == AudioCodecName.OPUS) {
            if (effective_sample_format == "16-bit") {
                args += "-sample_fmt";
                args += "s16";
            } else if (effective_sample_format == "32-bit float") {
                args += "-sample_fmt";
                args += "flt";
            }
        } else if (codec == AudioCodecName.MP3) {
            if (effective_sample_format == "16-bit") {
                args += "-sample_fmt";
                args += "s16p";
            } else if (effective_sample_format == "32-bit float") {
                args += "-sample_fmt";
                args += "fltp";
            }
        }

        return args;
    }

    internal static string[] build_transcode_args_from_snapshot (
        AudioSettingsSnapshot snapshot,
        bool include_sample_format = true,
        int channel_override = 0) {
        string codec = snapshot.codec;
        string[] args = {};
        string effective_sample_format = get_effective_sample_format_selection_for_codec (snapshot);

        if (codec == AudioCodecName.WAV) {
            args += "-c:a";
            args += resolve_wav_pcm_codec (effective_sample_format);

            if (snapshot.sample_rate_hz > 0) {
                args += "-ar";
                args += snapshot.sample_rate_hz.to_string ();
            }

            return args;
        }

        string ffmpeg_codec = "";
        switch (codec) {
            case AudioCodecName.OPUS:   ffmpeg_codec = AudioCodecFFmpeg.OPUS;   break;
            case AudioCodecName.AAC:    ffmpeg_codec = AudioCodecFFmpeg.AAC;    break;
            case AudioCodecName.MP3:    ffmpeg_codec = AudioCodecFFmpeg.MP3;    break;
            case AudioCodecName.FLAC:   ffmpeg_codec = AudioCodecFFmpeg.FLAC;   break;
            case AudioCodecName.VORBIS: ffmpeg_codec = AudioCodecFFmpeg.VORBIS; break;
            default:                    return { "-c:a", "copy" };
        }
        args += "-c:a";
        args += ffmpeg_codec;

        if (snapshot.sample_rate_hz > 0) {
            args += "-ar";
            args += snapshot.sample_rate_hz.to_string ();
        }

        bool use_quality_scale = codec_uses_quality_scale (
            codec,
            snapshot.aac_quality,
            snapshot.mp3_vbr_quality,
            snapshot.vorbis_quality
        );

        if (codec != AudioCodecName.FLAC && !use_quality_scale) {
            args += "-b:a";
            args += snapshot.bitrate_kbps.to_string () + "k";
        }

        if (codec == AudioCodecName.OPUS) {
            if (snapshot.opus_surround_fix) {
                if (channel_override == 0 && snapshot.source_channels > 2) {
                    args += "-ac";
                    args += "2";
                }
                args += "-mapping_family";
                args += "0";
            }

            string vbr = snapshot.opus_vbr_mode;
            if (vbr == "Constrained") {
                args += "-vbr";
                args += "constrained";
            } else if (vbr == "Off") {
                args += "-vbr";
                args += "off";
            }
        } else if (codec == AudioCodecName.AAC) {
            string q = snapshot.aac_quality;
            if (q != "Disabled") {
                args += "-q:a";
                args += q;
            }
        } else if (codec == AudioCodecName.MP3) {
            string q = snapshot.mp3_vbr_quality;
            if (q != "Disabled") {
                args += "-q:a";
                args += q;
            }
        } else if (codec == AudioCodecName.FLAC) {
            args += "-compression_level";
            args += snapshot.flac_compression;
        } else if (codec == AudioCodecName.VORBIS) {
            string q = snapshot.vorbis_quality;
            if (q != "Disabled") {
                args += "-q:a";
                args += q;
            }
        }

        if (include_sample_format) {
            foreach (unowned string arg in build_sample_format_args_for_snapshot (snapshot)) {
                args += arg;
            }
        }

        return args;
    }

    public static string[] build_audio_args_from_snapshot (AudioSettingsSnapshot snapshot,
                                                           int channel_override = 0) {
        if (!snapshot.enabled)
            return { "-an" };

        if (snapshot.codec == AudioCodecName.COPY)
            return { "-c:a", "copy" };

        return build_transcode_args_from_snapshot (
            snapshot,
            true,
            channel_override
        );
    }

    public static void coerce_copy_selection_for_container (AudioSettingsSnapshot snapshot,
                                                            string container) {
        if (snapshot.codec != AudioCodecName.COPY)
            return;

        string incompatible_codec;
        if (AudioCompatibilityLogic.container_supports_audio_copy_for_selection (
                container,
                snapshot.source,
                snapshot.all_sources,
                snapshot.preserve_all_audio_tracks,
                out incompatible_codec)) {
            return;
        }

        string fallback_codec = AudioCompatibilityLogic.get_copy_fallback_codec_for_container (container);
        if (fallback_codec.length > 0) {
            snapshot.codec = fallback_codec;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  RESET
    // ═════════════════════════════════════════════════════════════════════════

    public void reset_defaults () {
        set_audio_enabled (true);
        if (keep_all_audio_switch != null) {
            keep_all_audio_switch.set_active (false);
        }
        codec_combo.set_selected (0);
        sample_rate_combo.set_selected (0);
        bitrate_combo.set_selected (AudioCodecOptions.BITRATE_DEFAULT);
        opus_vbr_combo.set_selected (0);
        opus_surround_fix.set_active (true);
        aac_quality_combo.set_selected (0);
        mp3_vbr_combo.set_selected (0);
        flac_compression_combo.set_selected (AudioCodecOptions.FLAC_COMPRESSION_DEFAULT);
        vorbis_quality_combo.set_selected (0);
        sample_format_combo.set_selected (0);
        update_codec_visibility ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    private string get_codec_text () {
        var item = codec_combo.selected_item as StringObject;
        if (item != null) {
            return item.string;
        }
        return is_transcode_only_mode () ? AudioCodecName.OPUS : AudioCodecName.COPY;
    }

    private string get_dropdown_text (DropDown dropdown) {
        var item = dropdown.selected_item as StringObject;
        return item != null ? item.string : "";
    }

    private static void restore_dropdown_selection (DropDown dropdown,
                                                    string[] labels,
                                                    string? previous) {
        if (previous != null) {
            for (int i = 0; i < labels.length; i++) {
                if (labels[i] == previous) {
                    dropdown.set_selected (i);
                    return;
                }
            }
        }

        dropdown.set_selected (0);
    }

    internal static string[] get_sample_rate_labels_for_codec (string codec) {
        switch (codec) {
            case AudioCodecName.OPUS:
                return {
                    SAMPLE_RATE_SOURCE,
                    "8 kHz", "12 kHz", "16 kHz", "24 kHz", "48 kHz"
                };

            case AudioCodecName.MP3:
                return {
                    SAMPLE_RATE_SOURCE,
                    "8 kHz", "12 kHz", "16 kHz", "22.05 kHz", "24 kHz",
                    "32 kHz", "44.1 kHz", "48 kHz"
                };

            case AudioCodecName.AAC:
                return {
                    SAMPLE_RATE_SOURCE,
                    "8 kHz", "12 kHz", "16 kHz", "22.05 kHz", "24 kHz",
                    "32 kHz", "44.1 kHz", "48 kHz", "64 kHz", "88.2 kHz", "96 kHz"
                };

            default:
                return AudioCodecOptions.sample_rates ();
        }
    }

    internal static string[] get_bitrate_labels_for_codec (string codec) {
        switch (codec) {
            case AudioCodecName.MP3:
                return {
                    "64 kbps", "128 kbps", "192 kbps", "256 kbps", "320 kbps"
                };

            default:
                return AudioCodecOptions.bitrates ();
        }
    }

    internal static bool should_show_bitrate_for_codec (string codec) {
        return codec != AudioCodecName.COPY
            && codec != AudioCodecName.FLAC
            && codec != AudioCodecName.WAV;
    }

    internal static bool should_show_sample_format_for_codec (string codec) {
        return codec != AudioCodecName.COPY
            && codec != AudioCodecName.AAC
            && codec != AudioCodecName.VORBIS;
    }

    internal static string get_sample_format_title_for_codec (string codec) {
        if (codec == AudioCodecName.WAV || codec == AudioCodecName.FLAC) {
            return "Bit Depth";
        }
        return "Sample Format";
    }

    internal static string get_sample_format_subtitle_for_codec (string codec) {
        if (codec == AudioCodecName.WAV) {
            return "Select the PCM output depth; Source preserves it when probing can determine it";
        }
        if (codec == AudioCodecName.FLAC) {
            return "Select the FLAC output depth; Source preserves a compatible depth when probing can determine it";
        }
        if (codec == AudioCodecName.OPUS || codec == AudioCodecName.MP3) {
            return "Controls encoder input format, not output bit depth";
        }
        return "Not available for this codec";
    }

    internal static string[] get_sample_format_labels_for_codec (string codec) {
        if (codec == AudioCodecName.WAV) {
            return { "Source", "16-bit", "24-bit", "32-bit", "32-bit float" };
        }
        if (codec == AudioCodecName.FLAC) {
            return { "Source", "16-bit", "24-bit", "32-bit" };
        }
        return { "Source", "16-bit", "32-bit float" };
    }

    private static string infer_source_bit_depth_label (AudioSettingsSnapshot snapshot) {
        return AudioCompatibilityLogic.infer_source_depth_label (snapshot.source);
    }

    private static string get_effective_sample_format_selection_for_codec (
        AudioSettingsSnapshot snapshot) {
        if (snapshot.sample_format != "Source") {
            return snapshot.sample_format;
        }

        string source_label = infer_source_bit_depth_label (snapshot);
        if (snapshot.codec == AudioCodecName.FLAC) {
            switch (source_label) {
            case "16-bit":
            case "24-bit":
            case "32-bit":
                return source_label;
            default:
                return "Source";
            }
        }

        if (snapshot.codec == AudioCodecName.WAV) {
            return source_label;
        }

        return "Source";
    }

    private static string resolve_wav_pcm_codec (string effective_sample_format) {
        switch (effective_sample_format) {
        case "8-bit":
            return "pcm_u8";
        case "24-bit":
            return "pcm_s24le";
        case "32-bit":
            return "pcm_s32le";
        case "32-bit float":
            return "pcm_f32le";
        case "64-bit":
            return "pcm_s64le";
        case "64-bit float":
            return "pcm_f64le";
        case "16-bit":
        case "Source":
        default:
            return "pcm_s16le";
        }
    }

    private AudioCopyAvailabilityResult evaluate_audio_copy_availability () {
        var result = new AudioCopyAvailabilityResult ();
        result.fallback_codec =
            AudioCompatibilityLogic.get_copy_fallback_codec_for_container (current_container);

        AudioCopyBlockerReason[] blockers = {};
        if (combine_reencode_active) {
            blockers += AudioCopyBlockerReason.COMBINE_REENCODE;
        }
        if (concat_filter_active) {
            blockers += AudioCopyBlockerReason.TRIM_CONCAT_FILTER;
        }
        if (speed_active) {
            blockers += AudioCopyBlockerReason.AUDIO_SPEED;
        }
        if (processing_active) {
            blockers += AudioCopyBlockerReason.AUDIO_PROCESSING;
        }

        string incompatible_codec;
        bool preserve_all_audio_tracks =
            keep_all_audio_switch != null && keep_all_audio_switch.active;
        bool all_streams_copy_ok = AudioCompatibilityLogic.container_supports_audio_copy_for_selection (
            current_container,
            source_audio,
            all_source_audio,
            preserve_all_audio_tracks,
            out incompatible_codec
        );
        if (audio_probe_state == AudioProbeDisplayState.FOUND
            && !all_streams_copy_ok) {
            blockers += AudioCopyBlockerReason.SOURCE_CONTAINER_INCOMPATIBLE;
            result.source_codec_label = format_audio_codec_label (incompatible_codec);
            result.container_label = format_container_label (current_container);
        }

        result.all_blockers = blockers;
        result.primary_blocker = pick_primary_copy_blocker (blockers);
        result.copy_allowed = blockers.length == 0;
        return result;
    }

    private void update_codec_row_subtitle (AudioCopyAvailabilityResult evaluation) {
        switch (evaluation.primary_blocker) {
        case AudioCopyBlockerReason.COMBINE_REENCODE:
            codec_row.set_subtitle (
                "Copy disabled by Combine re-encode because audio must pass through filter_complex"
            );
            return;
        case AudioCopyBlockerReason.TRIM_CONCAT_FILTER:
            codec_row.set_subtitle (
                "Copy disabled: multi-segment trim combine routes audio through filter_complex"
            );
            return;
        case AudioCopyBlockerReason.AUDIO_SPEED:
            codec_row.set_subtitle (
                "Copy disabled by audio speed changes because filtered audio must be re-encoded"
            );
            return;
        case AudioCopyBlockerReason.AUDIO_PROCESSING:
            codec_row.set_subtitle (
                "Copy disabled by audio processing filters because filtered audio must be re-encoded"
            );
            return;
        case AudioCopyBlockerReason.SOURCE_CONTAINER_INCOMPATIBLE:
            codec_row.set_subtitle (
                "Copy unavailable: %s audio track is not supported in %s, so all audio will be re-encoded"
                .printf (
                    evaluation.source_codec_label,
                    evaluation.container_label
                )
            );
            return;
        case AudioCopyBlockerReason.NONE:
        default:
            break;
        }

        codec_row.set_subtitle ("Copy passes audio through without re-encoding");
    }

    private static int get_copy_blocker_priority (AudioCopyBlockerReason reason) {
        switch (reason) {
        case AudioCopyBlockerReason.COMBINE_REENCODE:
            return 0;
        case AudioCopyBlockerReason.TRIM_CONCAT_FILTER:
            return 10;
        case AudioCopyBlockerReason.AUDIO_SPEED:
            return 20;
        case AudioCopyBlockerReason.AUDIO_PROCESSING:
            return 30;
        case AudioCopyBlockerReason.SOURCE_CONTAINER_INCOMPATIBLE:
            return 40;
        case AudioCopyBlockerReason.NONE:
        default:
            return 100;
        }
    }

    private static AudioCopyBlockerReason pick_primary_copy_blocker (
        AudioCopyBlockerReason[] blockers) {
        AudioCopyBlockerReason primary = AudioCopyBlockerReason.NONE;
        int best_priority = get_copy_blocker_priority (primary);

        foreach (AudioCopyBlockerReason blocker in blockers) {
            int priority = get_copy_blocker_priority (blocker);
            if (priority < best_priority) {
                primary = blocker;
                best_priority = priority;
            }
        }

        return primary;
    }

    private void restore_codec_selection (StringList model,
                                          string preferred_codec,
                                          string current_codec) {
        string[] candidates = {};
        if (preferred_codec.length > 0) {
            candidates += preferred_codec;
        }
        if (current_codec.length > 0 && current_codec != preferred_codec) {
            candidates += current_codec;
        }

        foreach (string candidate in candidates) {
            for (uint i = 0; i < model.get_n_items (); i++) {
                if (model.get_string (i) == candidate) {
                    set_codec_selection_suppressed (i);
                    return;
                }
            }
        }

        set_codec_selection_suppressed (0);
    }

    private void set_codec_selection_suppressed (uint index) {
        suppress_codec_tracking = true;
        codec_combo.set_selected (index);
        suppress_codec_tracking = false;
    }

#if AUDIO_SETTINGS_TEST_BUILD || COMBINE_WINDOW_TEST_BUILD
    internal string[] get_available_codecs_for_test () {
        string[] codecs = {};
        var model = codec_combo.get_model () as StringList;
        if (model == null) {
            return codecs;
        }

        for (uint i = 0; i < model.get_n_items (); i++) {
            codecs += model.get_string (i);
        }
        return codecs;
    }

    internal string get_selected_codec_for_test () {
        return get_codec_text ();
    }

    internal string get_codec_row_subtitle_for_test () {
        return codec_row.get_subtitle () ?? "";
    }

    internal bool is_codec_available_for_test (string codec) {
        foreach (string candidate in get_available_codecs_for_test ()) {
            if (candidate == codec) {
                return true;
            }
        }
        return false;
    }

    internal string get_audio_status_badge_text_for_test () {
        if (audio_status_label == null) {
            return "";
        }
        return audio_status_label.get_text () ?? "";
    }
#endif

#if AUDIO_SETTINGS_TEST_BUILD || COMBINE_WINDOW_TEST_BUILD
    internal bool get_keep_all_audio_active_for_test () {
        return keep_all_audio_switch != null && keep_all_audio_switch.active;
    }

    internal void set_keep_all_audio_active_for_test (bool active) {
        if (keep_all_audio_switch != null) {
            keep_all_audio_switch.set_active (active);
        }
    }

    internal bool has_keep_all_audio_row_for_test () {
        return keep_all_audio_row != null;
    }

    internal bool get_keep_all_audio_sensitive_for_test () {
        return keep_all_audio_row != null && keep_all_audio_row.get_sensitive ();
    }

    internal string get_keep_all_audio_subtitle_for_test () {
        if (keep_all_audio_row == null) {
            return "";
        }
        return keep_all_audio_row.get_subtitle () ?? "";
    }

    internal string get_keep_all_audio_tooltip_for_test () {
        if (keep_all_audio_row == null) {
            return "";
        }
        return keep_all_audio_row.get_tooltip_text () ?? "";
    }
#endif

#if AUDIO_SETTINGS_TEST_BUILD
    internal void select_codec_for_test (string codec) {
        var model = codec_combo.get_model () as StringList;
        if (model == null) {
            return;
        }

        for (uint i = 0; i < model.get_n_items (); i++) {
            if (model.get_string (i) == codec) {
                desired_codec = codec;
                codec_combo.set_selected (i);
                return;
            }
        }
    }
#endif

    public static bool container_supports_audio_copy (string container,
                                                      string source_codec_name) {
        return AudioCompatibilityLogic.container_supports_audio_copy_for_codec (
            container, source_codec_name);
    }

    public static string get_copy_fallback_codec_for_container (string container) {
        return AudioCompatibilityLogic.get_copy_fallback_codec_for_container (container);
    }

    public static bool container_requires_audio_copy_verification (string container) {
        return AudioCompatibilityLogic.container_requires_audio_copy_verification (container);
    }

    private static string format_audio_codec_label (string codec_name) {
        switch (AudioCompatibilityLogic.normalize_source_audio_codec_name (codec_name)) {
            case "aac":
                return "AAC";
            case "ac3":
                return "AC-3";
            case "alac":
                return "ALAC";
            case "eac3":
                return "E-AC-3";
            case "mp3":
                return "MP3";
            case "opus":
                return "Opus";
            case "vorbis":
                return "Vorbis";
            default:
                return codec_name.up ();
        }
    }

    private static string format_container_label (string container) {
        switch (container.down ().strip ()) {
            case ContainerExt.MP4:
                return "MP4";
            case ContainerExt.WEBM:
                return "WebM";
            case ContainerExt.MKV:
                return "MKV";
            default:
                return container.up ();
        }
    }

    private int parse_sample_rate_selection (string selection) {
        switch (selection) {
            case SAMPLE_RATE_SOURCE: return 0;
            case "8 kHz": return 8000;
            case "12 kHz": return 12000;
            case "16 kHz": return 16000;
            case "22.05 kHz": return 22050;
            case "24 kHz": return 24000;
            case "32 kHz": return 32000;
            case "44.1 kHz": return 44100;
            case "48 kHz": return 48000;
            case "88.2 kHz": return 88200;
            case "96 kHz": return 96000;
            case "176.4 kHz": return 176400;
            case "192 kHz": return 192000;
            default: return 0;
        }
    }
}
