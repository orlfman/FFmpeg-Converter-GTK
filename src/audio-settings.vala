using Gtk;
using Adw;

// ═══════════════════════════════════════════════════════════════════════════════
//  AudioSettings — Reusable audio encoding widget
// ═══════════════════════════════════════════════════════════════════════════════

public class AudioSettingsSnapshot : Object {
    public bool enabled = true;
    public string codec = AudioCodecName.COPY;
    public string source_codec_name = "";
    public int sample_rate_hz = 0;
    public int bitrate_kbps = 128;
    public string opus_vbr_mode = "Default";
    public bool opus_surround_fix = true;
    public string aac_quality = "Disabled";
    public string mp3_vbr_quality = "Disabled";
    public string flac_compression = "5";
    public string vorbis_quality = "Disabled";
}

public enum AudioProbeDisplayState {
    UNKNOWN,
    CHECKING,
    FOUND,
    MISSING,
    ERROR
}

private class ContainerAudioPolicy : Object {
    public string[] selectable_codecs { get; construct set; default = {}; }
    public string[] copy_compatible_source_codecs { get; construct set; default = {}; }
    public string fallback_codec { get; construct set; default = ""; }
}

public class AudioSettings : Object {
    private const string SAMPLE_RATE_SOURCE = "Source";

    // ── Widgets ──────────────────────────────────────────────────────────────
    private Adw.PreferencesGroup group;
    private Box audio_status_header;
    private Image audio_status_icon;
    private Label audio_status_label;

    public Adw.ExpanderRow audio_expander  { get; private set; }
    public DropDown  codec_combo           { get; private set; }
    public DropDown  sample_rate_combo     { get; private set; }
    public DropDown  bitrate_combo         { get; private set; }
    public DropDown  opus_vbr_combo        { get; private set; }
    public Switch    opus_surround_fix     { get; private set; }
    public DropDown  aac_quality_combo     { get; private set; }
    public DropDown  mp3_vbr_combo         { get; private set; }
    public DropDown  flac_compression_combo { get; private set; }
    public DropDown  vorbis_quality_combo  { get; private set; }

    // Rows (for visibility control)
    private Adw.ActionRow codec_row;
    private Adw.ActionRow sample_rate_row;
    private Adw.ActionRow bitrate_row;
    private Adw.ActionRow opus_vbr_row;
    private Adw.ActionRow opus_surround_row;
    private Adw.ActionRow aac_quality_row;
    private Adw.ActionRow mp3_vbr_row;
    private Adw.ActionRow flac_compression_row;
    private Adw.ActionRow vorbis_quality_row;

    // State for codec list constraints
    private string current_container = ContainerExt.MKV;
    private bool   speed_active = false;
    private bool   normalize_active = false;
    private bool   concat_filter_active = false;
    private bool   desired_audio_enabled = true;
    private bool   suppress_audio_enabled_tracking = false;
    private AudioProbeDisplayState audio_probe_state = AudioProbeDisplayState.UNKNOWN;
    private string current_status_css_class = "";
    private string source_audio_codec_name = "";

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public AudioSettings () {
        inject_audio_status_css ();
        build_ui ();
        connect_signals ();
        update_codec_visibility ();
        set_audio_probe_state (AudioProbeDisplayState.UNKNOWN);
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
            "}\n"
        );
        StyleContext.add_provider_for_display (
            Gdk.Display.get_default (),
            css,
            STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }

    private void build_ui () {
        group = new Adw.PreferencesGroup ();
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

        audio_expander = new Adw.ExpanderRow ();
        audio_expander.set_title ("Include Audio");
        audio_expander.set_subtitle ("Disable to strip audio entirely from the output");
        audio_expander.set_show_enable_switch (true);
        audio_expander.set_enable_expansion (true);

        // ── Codec ────────────────────────────────────────────────────────────
        codec_row = new Adw.ActionRow ();
        codec_row.set_title ("Codec");
        codec_row.set_subtitle ("Copy passes audio through without re-encoding");
        codec_combo = new DropDown (new StringList (
            { AudioCodecName.COPY, AudioCodecName.OPUS, AudioCodecName.AAC,
              AudioCodecName.MP3, AudioCodecName.FLAC, AudioCodecName.VORBIS }
        ), null);
        codec_combo.set_valign (Align.CENTER);
        codec_combo.set_selected (0);
        codec_row.add_suffix (codec_combo);
        audio_expander.add_row (codec_row);

        // ── Sample Rate ──────────────────────────────────────────────────────
        sample_rate_row = new Adw.ActionRow ();
        sample_rate_row.set_title ("Sample Rate");
        sample_rate_row.set_subtitle (
            "Source preserves the input rate; choose a target only when resampling intentionally");
        sample_rate_combo = new DropDown (new StringList (
            {
                SAMPLE_RATE_SOURCE,
                "8 kHz", "12 kHz", "16 kHz", "22.05 kHz", "24 kHz",
                "32 kHz", "44.1 kHz", "48 kHz", "88.2 kHz", "96 kHz",
                "176.4 kHz", "192 kHz"
            }
        ), null);
        sample_rate_combo.set_valign (Align.CENTER);
        sample_rate_combo.set_selected (0);
        sample_rate_row.add_suffix (sample_rate_combo);
        sample_rate_row.set_visible (false);
        audio_expander.add_row (sample_rate_row);

        // ── Bitrate ──────────────────────────────────────────────────────────
        bitrate_row = new Adw.ActionRow ();
        bitrate_row.set_title ("Bitrate");
        bitrate_row.set_subtitle ("Higher = better quality, larger file");
        bitrate_combo = new DropDown (new StringList (
            { "64 kbps", "128 kbps", "192 kbps", "256 kbps",
              "320 kbps", "384 kbps", "448 kbps", "512 kbps" }
        ), null);
        bitrate_combo.set_valign (Align.CENTER);
        bitrate_combo.set_selected (1);
        bitrate_row.add_suffix (bitrate_combo);
        bitrate_row.set_visible (false);
        audio_expander.add_row (bitrate_row);

        // ── Opus VBR Mode ────────────────────────────────────────────────────
        opus_vbr_row = new Adw.ActionRow ();
        opus_vbr_row.set_title ("VBR Mode");
        opus_vbr_row.set_subtitle ("Variable bitrate mode for Opus encoding");
        opus_vbr_combo = new DropDown (new StringList (
            { "Default", "Constrained", "Off" }
        ), null);
        opus_vbr_combo.set_valign (Align.CENTER);
        opus_vbr_combo.set_selected (0);
        opus_vbr_row.add_suffix (opus_vbr_combo);
        opus_vbr_row.set_visible (false);
        audio_expander.add_row (opus_vbr_row);

        // ── Opus Surround ────────────────────────────────────────────────────
        opus_surround_row = new Adw.ActionRow ();
        opus_surround_row.set_title ("Surround Compatibility");
        opus_surround_row.set_subtitle ("Remap non-standard layouts like 5.1(side) so Opus can encode them");
        opus_surround_fix = new Switch ();
        opus_surround_fix.set_valign (Align.CENTER);
        opus_surround_fix.set_active (true);
        opus_surround_row.add_suffix (opus_surround_fix);
        opus_surround_row.set_activatable_widget (opus_surround_fix);
        opus_surround_row.set_visible (false);
        audio_expander.add_row (opus_surround_row);

        // ── AAC Quality ──────────────────────────────────────────────────────
        aac_quality_row = new Adw.ActionRow ();
        aac_quality_row.set_title ("Quality Scale");
        aac_quality_row.set_subtitle ("Disabled uses bitrate instead");
        aac_quality_combo = new DropDown (new StringList (
            { "Disabled", "0.1", "0.5", "1" }
        ), null);
        aac_quality_combo.set_valign (Align.CENTER);
        aac_quality_combo.set_selected (0);
        aac_quality_row.add_suffix (aac_quality_combo);
        aac_quality_row.set_visible (false);
        audio_expander.add_row (aac_quality_row);

        // ── MP3 VBR Quality ──────────────────────────────────────────────────
        mp3_vbr_row = new Adw.ActionRow ();
        mp3_vbr_row.set_title ("VBR Quality");
        mp3_vbr_row.set_subtitle ("0 = best quality — Disabled uses bitrate instead");
        mp3_vbr_combo = new DropDown (new StringList (
            { "Disabled", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" }
        ), null);
        mp3_vbr_combo.set_valign (Align.CENTER);
        mp3_vbr_combo.set_selected (0);
        mp3_vbr_row.add_suffix (mp3_vbr_combo);
        mp3_vbr_row.set_visible (false);
        audio_expander.add_row (mp3_vbr_row);

        // ── FLAC Compression ─────────────────────────────────────────────────
        flac_compression_row = new Adw.ActionRow ();
        flac_compression_row.set_title ("Compression Level");
        flac_compression_row.set_subtitle ("Higher = slower but smaller file (0–12)");
        flac_compression_combo = new DropDown (new StringList (
            { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12" }
        ), null);
        flac_compression_combo.set_valign (Align.CENTER);
        flac_compression_combo.set_selected (5);
        flac_compression_row.add_suffix (flac_compression_combo);
        flac_compression_row.set_visible (false);
        audio_expander.add_row (flac_compression_row);

        // ── Vorbis Quality ───────────────────────────────────────────────────
        vorbis_quality_row = new Adw.ActionRow ();
        vorbis_quality_row.set_title ("Quality");
        vorbis_quality_row.set_subtitle ("Higher = better — Disabled uses bitrate instead");
        vorbis_quality_combo = new DropDown (new StringList (
            { "Disabled", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" }
        ), null);
        vorbis_quality_combo.set_valign (Align.CENTER);
        vorbis_quality_combo.set_selected (0);
        vorbis_quality_row.add_suffix (vorbis_quality_combo);
        vorbis_quality_row.set_visible (false);
        audio_expander.add_row (vorbis_quality_row);

        group.add (audio_expander);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SIGNALS
    // ═════════════════════════════════════════════════════════════════════════

    private void connect_signals () {
        codec_combo.notify["selected"].connect (update_codec_visibility);
        aac_quality_combo.notify["selected"].connect (update_codec_visibility);
        mp3_vbr_combo.notify["selected"].connect (update_codec_visibility);
        vorbis_quality_combo.notify["selected"].connect (update_codec_visibility);
        audio_expander.notify["enable-expansion"].connect (() => {
            if (!suppress_audio_enabled_tracking && audio_expander.sensitive) {
                desired_audio_enabled = audio_expander.enable_expansion;
            }
        });
    }

    private static bool codec_uses_quality_scale (string codec,
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

        sample_rate_row.set_visible (!is_copy);
        bitrate_row.set_visible (!is_copy && codec != AudioCodecName.FLAC);
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
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CONTAINER FILTERING
    // ═════════════════════════════════════════════════════════════════════════

    public void update_for_container (string container) {
        current_container = container;
        rebuild_codec_list ();
    }

    public void apply_source_audio_state (string codec_name, AudioProbeDisplayState state) {
        source_audio_codec_name = normalize_source_audio_codec_name (codec_name);
        apply_audio_probe_state (state, false);
        rebuild_codec_list ();
    }

    public void apply_source_audio_probe_result (AudioStreamProbeResult audio_probe) {
        switch (audio_probe.presence) {
        case MediaStreamPresence.PRESENT:
            apply_source_audio_state (audio_probe.codec_name, AudioProbeDisplayState.FOUND);
            break;
        case MediaStreamPresence.ABSENT:
            apply_source_audio_state ("", AudioProbeDisplayState.MISSING);
            break;
        case MediaStreamPresence.UNKNOWN:
        default:
            apply_source_audio_state ("", AudioProbeDisplayState.ERROR);
            break;
        }
    }

    public void update_for_audio_speed (bool active) {
        speed_active = active;
        rebuild_codec_list ();
    }

    /**
     * When audio normalization (loudnorm) is enabled, stream-copy must be
     * disabled because audio filters require re-encoding.
     */
    public void update_for_normalize (bool active) {
        normalize_active = active;
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

    /**
     * True when audio filters (speed change, normalization, concat) are
     * active and stream-copy is not possible — audio must be re-encoded.
     */
    public bool requires_audio_reencode () {
        return speed_active || normalize_active || concat_filter_active;
    }

    public void set_audio_enabled (bool enabled) {
        desired_audio_enabled = enabled;

        if (audio_probe_state == AudioProbeDisplayState.MISSING) {
            audio_expander.set_sensitive (false);
            set_audio_expander_enabled (false);
            return;
        }

        audio_expander.set_sensitive (true);
        set_audio_expander_enabled (enabled);
    }

    public bool is_audio_enabled_for_output () {
        return audio_expander.enable_expansion
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

        switch (state) {
        case AudioProbeDisplayState.UNKNOWN:
            set_audio_status ("dialog-question-symbolic",
                              "Audio status unavailable",
                              "audio-status-neutral");
            restore_user_audio_state ();
            break;
        case AudioProbeDisplayState.CHECKING:
            set_audio_status ("view-refresh-symbolic",
                              "Checking audio stream...",
                              "audio-status-checking");
            audio_expander.set_sensitive (false);
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
            audio_expander.set_sensitive (false);
            set_audio_expander_enabled (false);
            break;
        case AudioProbeDisplayState.ERROR:
        default:
            set_audio_status ("dialog-warning-symbolic",
                              "Unable to inspect audio",
                              "audio-status-checking");
            restore_user_audio_state ();
            break;
        }

        if (rebuild_after) {
            rebuild_codec_list ();
        }
    }

    private void restore_user_audio_state () {
        set_audio_enabled (desired_audio_enabled);
    }

    private void set_audio_expander_enabled (bool enabled) {
        suppress_audio_enabled_tracking = true;
        audio_expander.set_enable_expansion (enabled);
        suppress_audio_enabled_tracking = false;
    }

    private void set_audio_status (string icon_name, string text, string css_class) {
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
        ContainerAudioPolicy policy = get_container_audio_policy (current_container);
        string[] codecs = policy.selectable_codecs;

        if (speed_active || normalize_active || concat_filter_active) {
            string[] filtered = {};
            foreach (string c in codecs) {
                if (c != AudioCodecName.COPY) filtered += c;
            }
            codecs = filtered;
        }

        if (!is_copy_available_for_current_source ()) {
            string[] filtered = {};
            foreach (string c in codecs) {
                if (c != AudioCodecName.COPY) filtered += c;
            }
            codecs = filtered;
        }

        var new_list = new StringList (codecs);
        codec_combo.set_model (new_list);

        bool found = false;
        for (uint i = 0; i < new_list.get_n_items (); i++) {
            if (new_list.get_string (i) == current) {
                codec_combo.set_selected (i);
                found = true;
                break;
            }
        }
        if (!found)
            codec_combo.set_selected (0);

        update_codec_row_subtitle ();
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
        snapshot.enabled = audio_expander.enable_expansion
            && audio_probe_state != AudioProbeDisplayState.MISSING;
        snapshot.codec = get_codec_text ();
        snapshot.source_codec_name = source_audio_codec_name;

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
        return snapshot;
    }

    public string[] get_audio_args () {
        return build_audio_args_from_snapshot (snapshot_settings ());
    }

    public static string[] build_audio_args_from_snapshot (AudioSettingsSnapshot snapshot) {
        if (!snapshot.enabled)
            return { "-an" };

        string codec = snapshot.codec;

        if (codec == AudioCodecName.COPY)
            return { "-c:a", "copy" };

        string[] args = {};

        // Map UI codec name → FFmpeg codec identifier
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

        // Keep the source sample rate unless the user explicitly requested resampling.
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

        // Bitrate applies only when the selected codec is not lossless and
        // no codec-specific quality scale is active.
        if (codec != AudioCodecName.FLAC && !use_quality_scale) {
            args += "-b:a";
            args += snapshot.bitrate_kbps.to_string () + "k";
        }

        // ── Codec-specific options ───────────────────────────────────────────
        if (codec == AudioCodecName.OPUS) {
            if (snapshot.opus_surround_fix) {
                args += "-af";
                args += "aformat=channel_layouts=7.1|5.1|stereo|mono";
            }
            args += "-mapping_family";
            args += "1";

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

        return args;
    }

    public static void coerce_copy_selection_for_container (AudioSettingsSnapshot snapshot,
                                                            string container) {
        if (snapshot.codec != AudioCodecName.COPY)
            return;

        if (container_supports_audio_copy (container, snapshot.source_codec_name))
            return;

        string fallback_codec = get_copy_fallback_codec_for_container (container);
        if (fallback_codec.length > 0) {
            snapshot.codec = fallback_codec;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  RESET
    // ═════════════════════════════════════════════════════════════════════════

    public void reset_defaults () {
        set_audio_enabled (true);
        codec_combo.set_selected (0);
        sample_rate_combo.set_selected (0);
        bitrate_combo.set_selected (1);
        opus_vbr_combo.set_selected (0);
        opus_surround_fix.set_active (true);
        aac_quality_combo.set_selected (0);
        mp3_vbr_combo.set_selected (0);
        flac_compression_combo.set_selected (5);
        vorbis_quality_combo.set_selected (0);
        update_codec_visibility ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    private string get_codec_text () {
        var item = codec_combo.selected_item as StringObject;
        return item != null ? item.string : AudioCodecName.COPY;
    }

    private string get_dropdown_text (DropDown dropdown) {
        var item = dropdown.selected_item as StringObject;
        return item != null ? item.string : "";
    }

    private bool is_copy_available_for_current_source () {
        if (audio_probe_state != AudioProbeDisplayState.FOUND)
            return true;

        return container_supports_audio_copy (current_container, source_audio_codec_name);
    }

    private void update_codec_row_subtitle () {
        if (audio_probe_state == AudioProbeDisplayState.FOUND
            && !container_supports_audio_copy (current_container, source_audio_codec_name)) {
            codec_row.set_subtitle (
                "Copy unavailable: source %s audio is not supported in %s, so audio will be re-encoded"
                .printf (
                    format_audio_codec_label (source_audio_codec_name),
                    format_container_label (current_container)
                )
            );
            return;
        }

        codec_row.set_subtitle ("Copy passes audio through without re-encoding");
    }

    public static bool container_supports_audio_copy (string container,
                                                      string source_codec_name) {
        string normalized_codec = normalize_source_audio_codec_name (source_codec_name);
        ContainerAudioPolicy policy = get_container_audio_policy (container);

        if (normalized_codec.length == 0)
            return true;

        foreach (string codec in policy.copy_compatible_source_codecs) {
            if (codec == normalized_codec) {
                return true;
            }
        }

        return policy.copy_compatible_source_codecs.length == 0;
    }

    public static string get_copy_fallback_codec_for_container (string container) {
        return get_container_audio_policy (container).fallback_codec;
    }

    public static bool container_requires_audio_copy_verification (string container) {
        ContainerAudioPolicy policy = get_container_audio_policy (container);
        return policy.copy_compatible_source_codecs.length > 0
            && policy.fallback_codec.length > 0;
    }

    private static string normalize_source_audio_codec_name (string codec_name) {
        string normalized = codec_name.down ().strip ();
        switch (normalized) {
            case "libopus":
                return "opus";
            case "libvorbis":
                return "vorbis";
            case "mp4a":
                return "aac";
            default:
                return normalized;
        }
    }

    private static string format_audio_codec_label (string codec_name) {
        switch (normalize_source_audio_codec_name (codec_name)) {
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

    private static ContainerAudioPolicy get_container_audio_policy (string container) {
        switch (container.down ().strip ()) {
            case ContainerExt.WEBM:
                return new ContainerAudioPolicy () {
                    selectable_codecs = { AudioCodecName.COPY, AudioCodecName.OPUS, AudioCodecName.VORBIS },
                    copy_compatible_source_codecs = { "opus", "vorbis" },
                    fallback_codec = AudioCodecName.OPUS
                };
            case ContainerExt.MP4:
                return new ContainerAudioPolicy () {
                    selectable_codecs = { AudioCodecName.COPY, AudioCodecName.AAC, AudioCodecName.MP3, AudioCodecName.OPUS },
                    copy_compatible_source_codecs = { "aac", "mp3", "opus", "alac", "ac3", "eac3" },
                    fallback_codec = AudioCodecName.AAC
                };
            default:
                return new ContainerAudioPolicy () {
                    selectable_codecs = {
                        AudioCodecName.COPY,
                        AudioCodecName.OPUS,
                        AudioCodecName.AAC,
                        AudioCodecName.MP3,
                        AudioCodecName.FLAC,
                        AudioCodecName.VORBIS
                    },
                    copy_compatible_source_codecs = {},
                    fallback_codec = ""
                };
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
