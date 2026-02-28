using Gtk;
using Adw;

// ═══════════════════════════════════════════════════════════════════════════════
//  AudioSettings — Reusable audio encoding widget
//
//  Usage from any codec tab:
//      audio_settings = new AudioSettings ();
//      append (audio_settings.get_widget ());
//
//  From ConversionRunner:
//      string[] audio_args = tab.audio_settings.get_audio_args ();
// ═══════════════════════════════════════════════════════════════════════════════

public class AudioSettings : Object {

    // ── Widgets ──────────────────────────────────────────────────────────────
    private Adw.PreferencesGroup group;

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
    private Adw.ActionRow sample_rate_row;
    private Adw.ActionRow bitrate_row;
    private Adw.ActionRow opus_vbr_row;
    private Adw.ActionRow opus_surround_row;
    private Adw.ActionRow aac_quality_row;
    private Adw.ActionRow mp3_vbr_row;
    private Adw.ActionRow flac_compression_row;
    private Adw.ActionRow vorbis_quality_row;

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public AudioSettings () {
        build_ui ();
        connect_signals ();
        update_codec_visibility ();
    }

    public Adw.PreferencesGroup get_widget () {
        return group;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  BUILD UI
    // ═════════════════════════════════════════════════════════════════════════

    private void build_ui () {
        group = new Adw.PreferencesGroup ();
        group.set_title ("Audio");
        group.set_description ("Audio stream encoding settings");

        // Main expander — enable switch controls Include / Exclude audio
        audio_expander = new Adw.ExpanderRow ();
        audio_expander.set_title ("Include Audio");
        audio_expander.set_subtitle ("Disable to strip audio entirely from the output");
        audio_expander.set_show_enable_switch (true);
        audio_expander.set_enable_expansion (true);

        // ── Codec ────────────────────────────────────────────────────────────
        var codec_row = new Adw.ActionRow ();
        codec_row.set_title ("Codec");
        codec_row.set_subtitle ("Copy passes audio through without re-encoding");
        codec_combo = new DropDown (new StringList (
            { "Copy", "Opus", "AAC", "MP3", "FLAC", "Vorbis" }
        ), null);
        codec_combo.set_valign (Align.CENTER);
        codec_combo.set_selected (0);
        codec_row.add_suffix (codec_combo);
        audio_expander.add_row (codec_row);

        // ── Sample Rate ──────────────────────────────────────────────────────
        sample_rate_row = new Adw.ActionRow ();
        sample_rate_row.set_title ("Sample Rate");
        sample_rate_row.set_subtitle ("48 kHz is standard for most content");
        sample_rate_combo = new DropDown (new StringList (
            { "8 kHz", "12 kHz", "16 kHz", "24 kHz", "48 kHz" }
        ), null);
        sample_rate_combo.set_valign (Align.CENTER);
        sample_rate_combo.set_selected (4);
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

        // ── Opus Surround Compatibility ───────────────────────────────────────
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
    }

    private void update_codec_visibility () {
        string codec = get_codec_text ();
        bool is_copy = (codec == "Copy");

        // Common rows — hidden for Copy
        sample_rate_row.set_visible (!is_copy);
        bitrate_row.set_visible (!is_copy && codec != "FLAC");

        // Codec-specific rows
        opus_vbr_row.set_visible (codec == "Opus");
        opus_surround_row.set_visible (codec == "Opus");
        aac_quality_row.set_visible (codec == "AAC");
        mp3_vbr_row.set_visible (codec == "MP3");
        flac_compression_row.set_visible (codec == "FLAC");
        vorbis_quality_row.set_visible (codec == "Vorbis");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CONTAINER FILTERING
    // ═════════════════════════════════════════════════════════════════════════

    // Call this when the parent tab's container selection changes.
    // WebM only supports Copy / Opus / Vorbis.
    public void update_for_container (string container) {
        string current = get_codec_text ();

	StringList new_list;
        if (container == "webm") {
            new_list = new StringList ({ "Copy", "Opus", "Vorbis" });
        } else if (container == "mp4") {
            new_list = new StringList ({ "Copy", "AAC", "MP3", "Opus" });
        } else {
            new_list = new StringList (
                { "Copy", "Opus", "AAC", "MP3", "FLAC", "Vorbis" }
            );
        }

        codec_combo.set_model (new_list);

        // Try to restore the previous selection
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

        update_codec_visibility ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  GET FFMPEG AUDIO ARGS
    // ═════════════════════════════════════════════════════════════════════════

    public string[] get_audio_args () {
        // Audio disabled → strip audio
        if (!audio_expander.enable_expansion)
            return { "-an" };

        string codec = get_codec_text ();

        // Copy → pass through unchanged
        if (codec == "Copy")
            return { "-c:a", "copy" };

        // ── Build full encoding args ─────────────────────────────────────────
        string[] args = {};

        // Codec name
        string ffmpeg_codec = "";
        switch (codec) {
            case "Opus":   ffmpeg_codec = "libopus";    break;
            case "AAC":    ffmpeg_codec = "aac";         break;
            case "MP3":    ffmpeg_codec = "libmp3lame";  break;
            case "FLAC":   ffmpeg_codec = "flac";        break;
            case "Vorbis": ffmpeg_codec = "libvorbis";   break;
            default:       return { "-c:a", "copy" };
        }
        args += "-c:a";
        args += ffmpeg_codec;

        // Sample rate
        string sr_text = get_dropdown_text (sample_rate_combo);
        string sr_num = sr_text.replace (" kHz", "");
        int sr = int.parse (sr_num) * 1000;
        args += "-ar";
        args += sr.to_string ();

        // Bitrate (not applicable for lossless FLAC)
        if (codec != "FLAC") {
            string br_text = get_dropdown_text (bitrate_combo);
            string br = br_text.replace (" kbps", "") + "k";
            args += "-b:a";
            args += br;
        }

        // ── Codec-specific options ───────────────────────────────────────────
        if (codec == "Opus") {
            // libopus rejects non-standard channel layouts like 5.1(side).
            // When enabled, this filter remaps to the closest standard layout.
            // It's a no-op when the source already uses a standard layout.
            if (opus_surround_fix.active) {
                args += "-af";
                args += "aformat=channel_layouts=7.1|5.1|stereo|mono";
            }
            args += "-mapping_family";
            args += "1";

            string vbr = get_dropdown_text (opus_vbr_combo);
            if (vbr == "Constrained") {
                args += "-vbr";
                args += "constrained";
            } else if (vbr == "Off") {
                args += "-vbr";
                args += "off";
            }
        } else if (codec == "AAC") {
            string q = get_dropdown_text (aac_quality_combo);
            if (q != "Disabled") {
                args += "-q:a";
                args += q;
            }
        } else if (codec == "MP3") {
            string q = get_dropdown_text (mp3_vbr_combo);
            if (q != "Disabled") {
                args += "-q:a";
                args += q;
            }
        } else if (codec == "FLAC") {
            string cl = get_dropdown_text (flac_compression_combo);
            args += "-compression_level";
            args += cl;
        } else if (codec == "Vorbis") {
            string q = get_dropdown_text (vorbis_quality_combo);
            if (q != "Disabled") {
                args += "-q:a";
                args += q;
            }
        }

        return args;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  RESET
    // ═════════════════════════════════════════════════════════════════════════

    public void reset_defaults () {
        audio_expander.set_enable_expansion (true);
        codec_combo.set_selected (0);
        sample_rate_combo.set_selected (4);
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
        return item != null ? item.string : "Copy";
    }

    private string get_dropdown_text (DropDown dropdown) {
        var item = dropdown.selected_item as StringObject;
        return item != null ? item.string : "";
    }
}
