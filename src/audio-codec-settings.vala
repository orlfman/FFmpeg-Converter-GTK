public class AudioProcessingSettingsSnapshot : Object {
    public bool normalize_enabled = false;
    public bool normalize_ebu = true;
    public double peak_normalize_gain_db = 0.0;
    public bool fade_in_enabled = false;
    public double fade_in_duration = 2.0;
    public bool fade_out_enabled = false;
    public double fade_out_duration = 2.0;
    public int channel_downmix = 0;

    public AudioProcessingSettingsSnapshot copy () {
        var snapshot = new AudioProcessingSettingsSnapshot ();
        snapshot.normalize_enabled = normalize_enabled;
        snapshot.normalize_ebu = normalize_ebu;
        snapshot.peak_normalize_gain_db = peak_normalize_gain_db;
        snapshot.fade_in_enabled = fade_in_enabled;
        snapshot.fade_in_duration = fade_in_duration;
        snapshot.fade_out_enabled = fade_out_enabled;
        snapshot.fade_out_duration = fade_out_duration;
        snapshot.channel_downmix = channel_downmix;
        return snapshot;
    }

    public bool requires_audio_reencode () {
        return normalize_enabled
            || fade_in_enabled
            || fade_out_enabled
            || channel_downmix != 0;
    }
}

public class AudioSettingsSnapshot : Object {
    public bool enabled = true;
    public string codec = AudioCodecName.COPY;
    public AudioSourceInfo source { get; set; default = new AudioSourceInfo (); }
    public AudioSourceInfo[] all_sources { get; set; default = {}; }
    public int sample_rate_hz = 0;
    public int bitrate_kbps = 128;
    public string opus_vbr_mode = "Default";
    public bool opus_surround_fix = true;
    public string aac_quality = "Disabled";
    public string mp3_vbr_quality = "Disabled";
    public string flac_compression = "5";
    public string vorbis_quality = "Disabled";
    public string sample_format = "Source";

    public string source_codec_name {
        get { return source.codec_name; }
        set { source.codec_name = value; }
    }

    public int source_channels {
        get { return source.channels; }
        set { source.channels = value; }
    }

    public string source_sample_fmt {
        get { return source.sample_fmt; }
        set { source.sample_fmt = value; }
    }

    public int source_bits_per_raw_sample {
        get { return source.bits_per_raw_sample; }
        set { source.bits_per_raw_sample = value; }
    }

    public AudioSettingsSnapshot copy () {
        var snapshot = new AudioSettingsSnapshot ();
        snapshot.enabled = enabled;
        snapshot.codec = codec;
        snapshot.source = source.copy ();
        AudioSourceInfo[] sources_copy = {};
        foreach (unowned AudioSourceInfo s in all_sources) {
            sources_copy += s.copy ();
        }
        snapshot.all_sources = sources_copy;
        snapshot.sample_rate_hz = sample_rate_hz;
        snapshot.bitrate_kbps = bitrate_kbps;
        snapshot.opus_vbr_mode = opus_vbr_mode;
        snapshot.opus_surround_fix = opus_surround_fix;
        snapshot.aac_quality = aac_quality;
        snapshot.mp3_vbr_quality = mp3_vbr_quality;
        snapshot.flac_compression = flac_compression;
        snapshot.vorbis_quality = vorbis_quality;
        snapshot.sample_format = sample_format;
        return snapshot;
    }
}
