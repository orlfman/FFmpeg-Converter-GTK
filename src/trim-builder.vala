// ═══════════════════════════════════════════════════════════════════════════════
//  TrimBuilder — ICodecBuilder for the Trim tab's stream-copy mode
//
//  When the user selects "Copy Streams" in the Trim tab, this builder is
//  returned by TrimTab.get_codec_builder().  It emits "-c:v copy -c:a copy"
//  so no re-encoding takes place — segments are cut at keyframe boundaries.
//
//  When the user selects "Re-encode", the Trim tab instead delegates to the
//  real codec tab's builder (SvtAv1Builder / X265Builder / etc.) via
//  codec_tab.get_codec_builder(), which creates a typed builder automatically.
// ═══════════════════════════════════════════════════════════════════════════════

public class TrimBuilder : Object, ICodecBuilder {

    public Object? snapshot_settings (
        GeneralSettingsSnapshot? general_settings = null) {
        if (general_settings != null)
            return general_settings;
        return null;
    }

    public string get_codec_name () {
        return "copy";
    }

    public string[] build_codec_args_from_snapshot (Object? snapshot) {
        return { "-c:v", "copy", "-c:a", "copy" };
    }

    public string[] get_codec_args () {
        return build_codec_args_from_snapshot (snapshot_settings ());
    }
}
