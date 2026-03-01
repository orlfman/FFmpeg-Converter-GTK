using Gtk;

// ═══════════════════════════════════════════════════════════════════════════════
//  TrimBuilder — ICodecBuilder for the Trim tab's stream-copy mode
//
//  When the user selects "Copy Streams" in the Trim tab, this builder is
//  returned by TrimTab.get_codec_builder().  It emits "-c:v copy -c:a copy"
//  so no re-encoding takes place — segments are cut at keyframe boundaries.
//
//  When the user selects "Re-encode", the Trim tab instead delegates to the
//  real codec tab's builder (SvtAv1Builder / X265Builder).
// ═══════════════════════════════════════════════════════════════════════════════

public class TrimBuilder : Object, ICodecBuilder {

    public string get_codec_name () {
        return "copy";
    }

    public string[] get_codec_args (ICodecTab codec_tab) {
        return { "-c:v", "copy", "-c:a", "copy" };
    }
}
