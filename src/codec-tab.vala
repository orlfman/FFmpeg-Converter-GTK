public interface ICodecTab : Object {
    public abstract ICodecBuilder get_codec_builder ();
    public abstract bool get_two_pass ();
    public abstract string get_container ();
    public abstract CodecTabSettingsSnapshot snapshot_settings (
        GeneralSettingsSnapshot? general_settings = null);
    public abstract KeyframeSettingsSnapshot snapshot_keyframe_settings (
        GeneralSettingsSnapshot? general_settings);
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
    public abstract int get_target_mb ();
    /**
     * True when the user pinned a quality target instead of a size target.
     * The two are mutually exclusive: one axis is the constraint, the other
     * is the prediction.
     */
    public abstract bool get_quality_mode_active ();
    /** Meaningful only when get_quality_mode_active() is true. */
    public abstract SmartOptimizerLogic.QualityIntent get_quality_intent ();
    /**
     * User's content assertion. Applies to BOTH modes — the classifier cannot
     * detect animation, so this is the reliable path to correct handling.
     */
    public abstract ContentOverride get_content_override ();
    /**
     * Delivery constraint — composable with either axis, which is why it is a
     * toggle rather than an entry in the quality list.
     */
    public abstract bool get_optimize_for_delivery ();
    public abstract AudioSettings get_audio_settings_ref ();
    public abstract void apply_smart_recommendation (OptimizationRecommendation rec);
    public abstract void update_source_file_size (string file_path);
}
