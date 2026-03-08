public interface ICodecTab : Object {
    public abstract ICodecBuilder get_codec_builder ();
    public abstract bool get_two_pass ();
    public abstract string get_container ();
    public abstract string[] resolve_keyframe_args (string input_file, GeneralTab general_tab);
    public abstract string[] get_audio_args ();
}

// ═══════════════════════════════════════════════════════════════════════════════
//  ISmartCodecTab — Shared Smart Optimizer contract for codec tabs
//
//  All four codec tabs (SVT-AV1, x265, x264, VP9) share identical properties
//  for Smart Optimizer integration.  This interface lets AppController use a
//  lookup map instead of repeated 4-way if/else chains.
//
//  Uses getter methods (not abstract properties) because the implementing
//  classes declare their properties with { get; private set; } which is
//  incompatible with abstract interface properties in Vala.
//
//  Note: the smart_optimizer_requested signal is wired explicitly per-tab
//  because Vala interface signals require special handling.
// ═══════════════════════════════════════════════════════════════════════════════

public interface ISmartCodecTab : Object {
    public abstract bool get_auto_convert_active ();
    public abstract bool get_strip_audio_active ();
    public abstract AudioSettings get_audio_settings_ref ();
    public abstract void apply_smart_recommendation (OptimizationRecommendation rec);
}
