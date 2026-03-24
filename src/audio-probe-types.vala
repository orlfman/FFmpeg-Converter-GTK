public enum MediaStreamPresence {
    UNKNOWN,
    ABSENT,
    PRESENT,
    ERROR
}

public class AudioStreamProbeResult : Object {
    public MediaStreamPresence presence { get; set; default = MediaStreamPresence.UNKNOWN; }
    public string codec_name { get; set; default = ""; }
    public int channels { get; set; default = 0; }
    public string sample_fmt { get; set; default = ""; }
    public int bits_per_raw_sample { get; set; default = 0; }
}
