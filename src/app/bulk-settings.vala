using GLib;

/** Everything that can affect a folder job, captured before its first yield. */
public class BulkConversionSettings : Object {
    public string codec = "x265";
    public Object builder_settings = new X265BuilderSnapshot ();
    public bool two_pass = false;
    internal HashTable<string, bool> edited_fields = new HashTable<string, bool> (str_hash, str_equal);
    public CodecTabSettingsSnapshot codec_settings = new CodecTabSettingsSnapshot ();
    public GeneralSettingsSnapshot general_settings = new GeneralSettingsSnapshot ();
    public GeneralTimingSettingsSnapshot timing = new GeneralTimingSettingsSnapshot ();
    public ConversionRuntimeOptions runtime_options = new ConversionRuntimeOptions ();
    public OutputNamingSettingsSnapshot naming = new OutputNamingSettingsSnapshot ();
    public int target_mb = 4;
    public bool match_source_size = false;
    public bool quality_mode = false;
    public SmartOptimizerLogic.QualityIntent quality_intent = SmartOptimizerLogic.QualityIntent.MEDIUM;
    public ContentOverride content_override = ContentOverride.AUTO;
    public bool optimize_for_delivery = false;
    public bool strip_audio = false;

    public BulkConversionSettings copy () {
        var settings = new BulkConversionSettings ();
        settings.codec = codec;
        settings.builder_settings = BulkSettingsEdits.copy_builder (builder_settings);
        BulkSettingsEdits.set_general (settings.builder_settings, general_settings);
        settings.two_pass = two_pass;
        edited_fields.foreach ((key, value) => { settings.edited_fields.insert (key, value); });
        settings.codec_settings = codec_settings.copy ();
        settings.general_settings = general_settings.copy ();
        settings.timing.seek_enabled = timing.seek_enabled;
        settings.timing.seek_hours = timing.seek_hours;
        settings.timing.seek_minutes = timing.seek_minutes;
        settings.timing.seek_seconds = timing.seek_seconds;
        settings.timing.time_enabled = timing.time_enabled;
        settings.timing.time_hours = timing.time_hours;
        settings.timing.time_minutes = timing.time_minutes;
        settings.timing.time_seconds = timing.time_seconds;
        settings.runtime_options = runtime_options.copy ();
        settings.naming = naming.copy ();
        settings.target_mb = target_mb;
        settings.match_source_size = match_source_size;
        settings.quality_mode = quality_mode;
        settings.quality_intent = quality_intent;
        settings.content_override = content_override;
        settings.optimize_for_delivery = optimize_for_delivery;
        settings.strip_audio = strip_audio;
        return settings;
    }
}

/** Apply edits relative to the Optimize-time controls, retaining per-file values.
 * All results own their nested mutable state; source observations are refreshed by
 * the controller. Keep these typed merges in sync with settings snapshot fields.
 */
public class BulkSettingsEdits : Object {
    public static X264BuilderSnapshot merge_x264_builder_snapshot (X264BuilderSnapshot baseline, X264BuilderSnapshot current, X264BuilderSnapshot optimized, HashTable<string, bool>? edits = null) {
        var result = new X264BuilderSnapshot ();
        result.preset = (edits != null && edits.contains ("X264BuilderSnapshot.preset")) || current.preset != baseline.preset ? current.preset : optimized.preset;
        result.profile = (edits != null && edits.contains ("X264BuilderSnapshot.profile")) || current.profile != baseline.profile ? current.profile : optimized.profile;
        result.rc_mode = (edits != null && edits.contains ("X264BuilderSnapshot.rc_mode")) || current.rc_mode != baseline.rc_mode ? current.rc_mode : optimized.rc_mode;
        result.crf = (edits != null && edits.contains ("X264BuilderSnapshot.crf")) || current.crf != baseline.crf ? current.crf : optimized.crf;
        result.qp = (edits != null && edits.contains ("X264BuilderSnapshot.qp")) || current.qp != baseline.qp ? current.qp : optimized.qp;
        result.abr_bitrate_kbps = (edits != null && edits.contains ("X264BuilderSnapshot.abr_bitrate_kbps")) || current.abr_bitrate_kbps != baseline.abr_bitrate_kbps ? current.abr_bitrate_kbps : optimized.abr_bitrate_kbps;
        result.cbr_bitrate_kbps = (edits != null && edits.contains ("X264BuilderSnapshot.cbr_bitrate_kbps")) || current.cbr_bitrate_kbps != baseline.cbr_bitrate_kbps ? current.cbr_bitrate_kbps : optimized.cbr_bitrate_kbps;
        result.tune = (edits != null && edits.contains ("X264BuilderSnapshot.tune")) || current.tune != baseline.tune ? current.tune : optimized.tune;
        result.level = (edits != null && edits.contains ("X264BuilderSnapshot.level")) || current.level != baseline.level ? current.level : optimized.level;
        result.keyint_text = (edits != null && edits.contains ("X264BuilderSnapshot.keyint_text")) || current.keyint_text != baseline.keyint_text ? current.keyint_text : optimized.keyint_text;
        result.ref_frames = (edits != null && edits.contains ("X264BuilderSnapshot.ref_frames")) || current.ref_frames != baseline.ref_frames ? current.ref_frames : optimized.ref_frames;
        result.bframes = (edits != null && edits.contains ("X264BuilderSnapshot.bframes")) || current.bframes != baseline.bframes ? current.bframes : optimized.bframes;
        result.b_adapt = (edits != null && edits.contains ("X264BuilderSnapshot.b_adapt")) || current.b_adapt != baseline.b_adapt ? current.b_adapt : optimized.b_adapt;
        result.weightp = (edits != null && edits.contains ("X264BuilderSnapshot.weightp")) || current.weightp != baseline.weightp ? current.weightp : optimized.weightp;
        result.deblock_enabled = (edits != null && edits.contains ("X264BuilderSnapshot.deblock_enabled")) || current.deblock_enabled != baseline.deblock_enabled ? current.deblock_enabled : optimized.deblock_enabled;
        result.deblock_alpha = (edits != null && edits.contains ("X264BuilderSnapshot.deblock_alpha")) || current.deblock_alpha != baseline.deblock_alpha ? current.deblock_alpha : optimized.deblock_alpha;
        result.deblock_beta = (edits != null && edits.contains ("X264BuilderSnapshot.deblock_beta")) || current.deblock_beta != baseline.deblock_beta ? current.deblock_beta : optimized.deblock_beta;
        result.me = (edits != null && edits.contains ("X264BuilderSnapshot.me")) || current.me != baseline.me ? current.me : optimized.me;
        result.me_range = (edits != null && edits.contains ("X264BuilderSnapshot.me_range")) || current.me_range != baseline.me_range ? current.me_range : optimized.me_range;
        result.subme = (edits != null && edits.contains ("X264BuilderSnapshot.subme")) || current.subme != baseline.subme ? current.subme : optimized.subme;
        result.psy_rd_enabled = (edits != null && edits.contains ("X264BuilderSnapshot.psy_rd_enabled")) || current.psy_rd_enabled != baseline.psy_rd_enabled ? current.psy_rd_enabled : optimized.psy_rd_enabled;
        result.psy_rd = (edits != null && edits.contains ("X264BuilderSnapshot.psy_rd")) || current.psy_rd != baseline.psy_rd ? current.psy_rd : optimized.psy_rd;
        result.psy_trellis = (edits != null && edits.contains ("X264BuilderSnapshot.psy_trellis")) || current.psy_trellis != baseline.psy_trellis ? current.psy_trellis : optimized.psy_trellis;
        result.cabac = (edits != null && edits.contains ("X264BuilderSnapshot.cabac")) || current.cabac != baseline.cabac ? current.cabac : optimized.cabac;
        result.mbtree = (edits != null && edits.contains ("X264BuilderSnapshot.mbtree")) || current.mbtree != baseline.mbtree ? current.mbtree : optimized.mbtree;
        result.lookahead_enabled = (edits != null && edits.contains ("X264BuilderSnapshot.lookahead_enabled")) || current.lookahead_enabled != baseline.lookahead_enabled ? current.lookahead_enabled : optimized.lookahead_enabled;
        result.lookahead = (edits != null && edits.contains ("X264BuilderSnapshot.lookahead")) || current.lookahead != baseline.lookahead ? current.lookahead : optimized.lookahead;
        result.aq_mode = (edits != null && edits.contains ("X264BuilderSnapshot.aq_mode")) || current.aq_mode != baseline.aq_mode ? current.aq_mode : optimized.aq_mode;
        result.aq_strength = (edits != null && edits.contains ("X264BuilderSnapshot.aq_strength")) || current.aq_strength != baseline.aq_strength ? current.aq_strength : optimized.aq_strength;
        result.abr_vbv = (edits != null && edits.contains ("X264BuilderSnapshot.abr_vbv")) || current.abr_vbv != baseline.abr_vbv ? current.abr_vbv : optimized.abr_vbv;
        result.open_gop = (edits != null && edits.contains ("X264BuilderSnapshot.open_gop")) || current.open_gop != baseline.open_gop ? current.open_gop : optimized.open_gop;
        result.threads = (edits != null && edits.contains ("X264BuilderSnapshot.threads")) || current.threads != baseline.threads ? current.threads : optimized.threads;
        return result;
    }

    public static X265BuilderSnapshot merge_x265_builder_snapshot (X265BuilderSnapshot baseline, X265BuilderSnapshot current, X265BuilderSnapshot optimized, HashTable<string, bool>? edits = null) {
        var result = new X265BuilderSnapshot ();
        result.preset = (edits != null && edits.contains ("X265BuilderSnapshot.preset")) || current.preset != baseline.preset ? current.preset : optimized.preset;
        result.profile = (edits != null && edits.contains ("X265BuilderSnapshot.profile")) || current.profile != baseline.profile ? current.profile : optimized.profile;
        result.rc_mode = (edits != null && edits.contains ("X265BuilderSnapshot.rc_mode")) || current.rc_mode != baseline.rc_mode ? current.rc_mode : optimized.rc_mode;
        result.crf = (edits != null && edits.contains ("X265BuilderSnapshot.crf")) || current.crf != baseline.crf ? current.crf : optimized.crf;
        result.qp = (edits != null && edits.contains ("X265BuilderSnapshot.qp")) || current.qp != baseline.qp ? current.qp : optimized.qp;
        result.abr_bitrate_kbps = (edits != null && edits.contains ("X265BuilderSnapshot.abr_bitrate_kbps")) || current.abr_bitrate_kbps != baseline.abr_bitrate_kbps ? current.abr_bitrate_kbps : optimized.abr_bitrate_kbps;
        result.cbr_bitrate_kbps = (edits != null && edits.contains ("X265BuilderSnapshot.cbr_bitrate_kbps")) || current.cbr_bitrate_kbps != baseline.cbr_bitrate_kbps ? current.cbr_bitrate_kbps : optimized.cbr_bitrate_kbps;
        result.tune = (edits != null && edits.contains ("X265BuilderSnapshot.tune")) || current.tune != baseline.tune ? current.tune : optimized.tune;
        result.level = (edits != null && edits.contains ("X265BuilderSnapshot.level")) || current.level != baseline.level ? current.level : optimized.level;
        result.keyint_text = (edits != null && edits.contains ("X265BuilderSnapshot.keyint_text")) || current.keyint_text != baseline.keyint_text ? current.keyint_text : optimized.keyint_text;
        result.sao = (edits != null && edits.contains ("X265BuilderSnapshot.sao")) || current.sao != baseline.sao ? current.sao : optimized.sao;
        result.ref_frames = (edits != null && edits.contains ("X265BuilderSnapshot.ref_frames")) || current.ref_frames != baseline.ref_frames ? current.ref_frames : optimized.ref_frames;
        result.weightp = (edits != null && edits.contains ("X265BuilderSnapshot.weightp")) || current.weightp != baseline.weightp ? current.weightp : optimized.weightp;
        result.deblock_enabled = (edits != null && edits.contains ("X265BuilderSnapshot.deblock_enabled")) || current.deblock_enabled != baseline.deblock_enabled ? current.deblock_enabled : optimized.deblock_enabled;
        result.deblock_alpha = (edits != null && edits.contains ("X265BuilderSnapshot.deblock_alpha")) || current.deblock_alpha != baseline.deblock_alpha ? current.deblock_alpha : optimized.deblock_alpha;
        result.deblock_beta = (edits != null && edits.contains ("X265BuilderSnapshot.deblock_beta")) || current.deblock_beta != baseline.deblock_beta ? current.deblock_beta : optimized.deblock_beta;
        result.pmode = (edits != null && edits.contains ("X265BuilderSnapshot.pmode")) || current.pmode != baseline.pmode ? current.pmode : optimized.pmode;
        result.psy_rd_enabled = (edits != null && edits.contains ("X265BuilderSnapshot.psy_rd_enabled")) || current.psy_rd_enabled != baseline.psy_rd_enabled ? current.psy_rd_enabled : optimized.psy_rd_enabled;
        result.psy_rd = (edits != null && edits.contains ("X265BuilderSnapshot.psy_rd")) || current.psy_rd != baseline.psy_rd ? current.psy_rd : optimized.psy_rd;
        result.cutree = (edits != null && edits.contains ("X265BuilderSnapshot.cutree")) || current.cutree != baseline.cutree ? current.cutree : optimized.cutree;
        result.lookahead_enabled = (edits != null && edits.contains ("X265BuilderSnapshot.lookahead_enabled")) || current.lookahead_enabled != baseline.lookahead_enabled ? current.lookahead_enabled : optimized.lookahead_enabled;
        result.lookahead = (edits != null && edits.contains ("X265BuilderSnapshot.lookahead")) || current.lookahead != baseline.lookahead ? current.lookahead : optimized.lookahead;
        result.aq_mode = (edits != null && edits.contains ("X265BuilderSnapshot.aq_mode")) || current.aq_mode != baseline.aq_mode ? current.aq_mode : optimized.aq_mode;
        result.aq_strength = (edits != null && edits.contains ("X265BuilderSnapshot.aq_strength")) || current.aq_strength != baseline.aq_strength ? current.aq_strength : optimized.aq_strength;
        result.abr_vbv = (edits != null && edits.contains ("X265BuilderSnapshot.abr_vbv")) || current.abr_vbv != baseline.abr_vbv ? current.abr_vbv : optimized.abr_vbv;
        result.threads = (edits != null && edits.contains ("X265BuilderSnapshot.threads")) || current.threads != baseline.threads ? current.threads : optimized.threads;
        result.frame_threads = (edits != null && edits.contains ("X265BuilderSnapshot.frame_threads")) || current.frame_threads != baseline.frame_threads ? current.frame_threads : optimized.frame_threads;
        return result;
    }

    public static Vp9BuilderSnapshot merge_vp9_builder_snapshot (Vp9BuilderSnapshot baseline, Vp9BuilderSnapshot current, Vp9BuilderSnapshot optimized, HashTable<string, bool>? edits = null) {
        var result = new Vp9BuilderSnapshot ();
        result.speed = (edits != null && edits.contains ("Vp9BuilderSnapshot.speed")) || current.speed != baseline.speed ? current.speed : optimized.speed;
        result.quality_deadline = (edits != null && edits.contains ("Vp9BuilderSnapshot.quality_deadline")) || current.quality_deadline != baseline.quality_deadline ? current.quality_deadline : optimized.quality_deadline;
        result.profile = (edits != null && edits.contains ("Vp9BuilderSnapshot.profile")) || current.profile != baseline.profile ? current.profile : optimized.profile;
        result.rc_mode = (edits != null && edits.contains ("Vp9BuilderSnapshot.rc_mode")) || current.rc_mode != baseline.rc_mode ? current.rc_mode : optimized.rc_mode;
        result.crf = (edits != null && edits.contains ("Vp9BuilderSnapshot.crf")) || current.crf != baseline.crf ? current.crf : optimized.crf;
        result.cq_level = (edits != null && edits.contains ("Vp9BuilderSnapshot.cq_level")) || current.cq_level != baseline.cq_level ? current.cq_level : optimized.cq_level;
        result.cq_bitrate_kbps = (edits != null && edits.contains ("Vp9BuilderSnapshot.cq_bitrate_kbps")) || current.cq_bitrate_kbps != baseline.cq_bitrate_kbps ? current.cq_bitrate_kbps : optimized.cq_bitrate_kbps;
        result.vbr_bitrate_kbps = (edits != null && edits.contains ("Vp9BuilderSnapshot.vbr_bitrate_kbps")) || current.vbr_bitrate_kbps != baseline.vbr_bitrate_kbps ? current.vbr_bitrate_kbps : optimized.vbr_bitrate_kbps;
        result.cbr_bitrate_kbps = (edits != null && edits.contains ("Vp9BuilderSnapshot.cbr_bitrate_kbps")) || current.cbr_bitrate_kbps != baseline.cbr_bitrate_kbps ? current.cbr_bitrate_kbps : optimized.cbr_bitrate_kbps;
        result.tune_content = (edits != null && edits.contains ("Vp9BuilderSnapshot.tune_content")) || current.tune_content != baseline.tune_content ? current.tune_content : optimized.tune_content;
        result.aq_mode = (edits != null && edits.contains ("Vp9BuilderSnapshot.aq_mode")) || current.aq_mode != baseline.aq_mode ? current.aq_mode : optimized.aq_mode;
        result.sharpness_enabled = (edits != null && edits.contains ("Vp9BuilderSnapshot.sharpness_enabled")) || current.sharpness_enabled != baseline.sharpness_enabled ? current.sharpness_enabled : optimized.sharpness_enabled;
        result.sharpness = (edits != null && edits.contains ("Vp9BuilderSnapshot.sharpness")) || current.sharpness != baseline.sharpness ? current.sharpness : optimized.sharpness;
        result.lookahead_enabled = (edits != null && edits.contains ("Vp9BuilderSnapshot.lookahead_enabled")) || current.lookahead_enabled != baseline.lookahead_enabled ? current.lookahead_enabled : optimized.lookahead_enabled;
        result.lag_in_frames = (edits != null && edits.contains ("Vp9BuilderSnapshot.lag_in_frames")) || current.lag_in_frames != baseline.lag_in_frames ? current.lag_in_frames : optimized.lag_in_frames;
        result.altref_enabled = (edits != null && edits.contains ("Vp9BuilderSnapshot.altref_enabled")) || current.altref_enabled != baseline.altref_enabled ? current.altref_enabled : optimized.altref_enabled;
        result.arnr_maxframes = (edits != null && edits.contains ("Vp9BuilderSnapshot.arnr_maxframes")) || current.arnr_maxframes != baseline.arnr_maxframes ? current.arnr_maxframes : optimized.arnr_maxframes;
        result.arnr_strength = (edits != null && edits.contains ("Vp9BuilderSnapshot.arnr_strength")) || current.arnr_strength != baseline.arnr_strength ? current.arnr_strength : optimized.arnr_strength;
        result.row_mt = (edits != null && edits.contains ("Vp9BuilderSnapshot.row_mt")) || current.row_mt != baseline.row_mt ? current.row_mt : optimized.row_mt;
        result.frame_parallel = (edits != null && edits.contains ("Vp9BuilderSnapshot.frame_parallel")) || current.frame_parallel != baseline.frame_parallel ? current.frame_parallel : optimized.frame_parallel;
        result.undershoot_enabled = (edits != null && edits.contains ("Vp9BuilderSnapshot.undershoot_enabled")) || current.undershoot_enabled != baseline.undershoot_enabled ? current.undershoot_enabled : optimized.undershoot_enabled;
        result.undershoot = (edits != null && edits.contains ("Vp9BuilderSnapshot.undershoot")) || current.undershoot != baseline.undershoot ? current.undershoot : optimized.undershoot;
        result.overshoot = (edits != null && edits.contains ("Vp9BuilderSnapshot.overshoot")) || current.overshoot != baseline.overshoot ? current.overshoot : optimized.overshoot;
        result.keyint_text = (edits != null && edits.contains ("Vp9BuilderSnapshot.keyint_text")) || current.keyint_text != baseline.keyint_text ? current.keyint_text : optimized.keyint_text;
        result.tile_columns = (edits != null && edits.contains ("Vp9BuilderSnapshot.tile_columns")) || current.tile_columns != baseline.tile_columns ? current.tile_columns : optimized.tile_columns;
        result.tile_rows = (edits != null && edits.contains ("Vp9BuilderSnapshot.tile_rows")) || current.tile_rows != baseline.tile_rows ? current.tile_rows : optimized.tile_rows;
        result.threads = (edits != null && edits.contains ("Vp9BuilderSnapshot.threads")) || current.threads != baseline.threads ? current.threads : optimized.threads;
        return result;
    }

    public static SvtAv1BuilderSnapshot merge_svt_av1_builder_snapshot (SvtAv1BuilderSnapshot baseline, SvtAv1BuilderSnapshot current, SvtAv1BuilderSnapshot optimized, HashTable<string, bool>? edits = null) {
        var result = new SvtAv1BuilderSnapshot ();
        result.preset = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.preset")) || current.preset != baseline.preset ? current.preset : optimized.preset;
        result.rc_mode = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.rc_mode")) || current.rc_mode != baseline.rc_mode ? current.rc_mode : optimized.rc_mode;
        result.crf = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.crf")) || current.crf != baseline.crf ? current.crf : optimized.crf;
        result.qp = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.qp")) || current.qp != baseline.qp ? current.qp : optimized.qp;
        result.vbr_bitrate_kbps = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.vbr_bitrate_kbps")) || current.vbr_bitrate_kbps != baseline.vbr_bitrate_kbps ? current.vbr_bitrate_kbps : optimized.vbr_bitrate_kbps;
        result.mbr_enabled = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.mbr_enabled")) || current.mbr_enabled != baseline.mbr_enabled ? current.mbr_enabled : optimized.mbr_enabled;
        result.mbr_bitrate_kbps = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.mbr_bitrate_kbps")) || current.mbr_bitrate_kbps != baseline.mbr_bitrate_kbps ? current.mbr_bitrate_kbps : optimized.mbr_bitrate_kbps;
        result.level = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.level")) || current.level != baseline.level ? current.level : optimized.level;
        result.keyint_text = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.keyint_text")) || current.keyint_text != baseline.keyint_text ? current.keyint_text : optimized.keyint_text;
        result.tune_selected = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.tune_selected")) || current.tune_selected != baseline.tune_selected ? current.tune_selected : optimized.tune_selected;
        result.lookahead_enabled = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.lookahead_enabled")) || current.lookahead_enabled != baseline.lookahead_enabled ? current.lookahead_enabled : optimized.lookahead_enabled;
        result.lookahead = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.lookahead")) || current.lookahead != baseline.lookahead ? current.lookahead : optimized.lookahead;
        result.aq_mode = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.aq_mode")) || current.aq_mode != baseline.aq_mode ? current.aq_mode : optimized.aq_mode;
        result.aq_strength = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.aq_strength")) || current.aq_strength != baseline.aq_strength ? current.aq_strength : optimized.aq_strength;
        result.grain_enabled = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.grain_enabled")) || current.grain_enabled != baseline.grain_enabled ? current.grain_enabled : optimized.grain_enabled;
        result.grain_strength = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.grain_strength")) || current.grain_strength != baseline.grain_strength ? current.grain_strength : optimized.grain_strength;
        result.grain_denoise_selected = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.grain_denoise_selected")) || current.grain_denoise_selected != baseline.grain_denoise_selected ? current.grain_denoise_selected : optimized.grain_denoise_selected;
        result.cdef = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.cdef")) || current.cdef != baseline.cdef ? current.cdef : optimized.cdef;
        result.restoration = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.restoration")) || current.restoration != baseline.restoration ? current.restoration : optimized.restoration;
        result.dlf = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.dlf")) || current.dlf != baseline.dlf ? current.dlf : optimized.dlf;
        result.tf = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.tf")) || current.tf != baseline.tf ? current.tf : optimized.tf;
        result.tpl = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.tpl")) || current.tpl != baseline.tpl ? current.tpl : optimized.tpl;
        result.low_latency = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.low_latency")) || current.low_latency != baseline.low_latency ? current.low_latency : optimized.low_latency;
        result.superres_enabled = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.superres_enabled")) || current.superres_enabled != baseline.superres_enabled ? current.superres_enabled : optimized.superres_enabled;
        result.superres_mode_selected = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.superres_mode_selected")) || current.superres_mode_selected != baseline.superres_mode_selected ? current.superres_mode_selected : optimized.superres_mode_selected;
        result.superres_denom = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.superres_denom")) || current.superres_denom != baseline.superres_denom ? current.superres_denom : optimized.superres_denom;
        result.sharpness_enabled = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.sharpness_enabled")) || current.sharpness_enabled != baseline.sharpness_enabled ? current.sharpness_enabled : optimized.sharpness_enabled;
        result.sharpness = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.sharpness")) || current.sharpness != baseline.sharpness ? current.sharpness : optimized.sharpness;
        result.scm = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.scm")) || current.scm != baseline.scm ? current.scm : optimized.scm;
        result.fast_decode = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.fast_decode")) || current.fast_decode != baseline.fast_decode ? current.fast_decode : optimized.fast_decode;
        result.qm_enabled = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.qm_enabled")) || current.qm_enabled != baseline.qm_enabled ? current.qm_enabled : optimized.qm_enabled;
        result.qm_min = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.qm_min")) || current.qm_min != baseline.qm_min ? current.qm_min : optimized.qm_min;
        result.qm_max = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.qm_max")) || current.qm_max != baseline.qm_max ? current.qm_max : optimized.qm_max;
        result.tile_rows = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.tile_rows")) || current.tile_rows != baseline.tile_rows ? current.tile_rows : optimized.tile_rows;
        result.tile_columns = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.tile_columns")) || current.tile_columns != baseline.tile_columns ? current.tile_columns : optimized.tile_columns;
        result.threads = (edits != null && edits.contains ("SvtAv1BuilderSnapshot.threads")) || current.threads != baseline.threads ? current.threads : optimized.threads;
        return result;
    }

    public static GeneralSettingsSnapshot merge_general_settings_snapshot (GeneralSettingsSnapshot baseline, GeneralSettingsSnapshot current, GeneralSettingsSnapshot optimized, HashTable<string, bool>? edits = null) {
        var result = new GeneralSettingsSnapshot ();
        result.scale_mode = (edits != null && edits.contains ("GeneralSettingsSnapshot.scale_mode")) || current.scale_mode != baseline.scale_mode ? current.scale_mode : optimized.scale_mode;
        result.resolution_preset_value = (edits != null && edits.contains ("GeneralSettingsSnapshot.resolution_preset_value")) || current.resolution_preset_value != baseline.resolution_preset_value ? current.resolution_preset_value : optimized.resolution_preset_value;
        result.custom_resolution_value = (edits != null && edits.contains ("GeneralSettingsSnapshot.custom_resolution_value")) || current.custom_resolution_value != baseline.custom_resolution_value ? current.custom_resolution_value : optimized.custom_resolution_value;
        result.scale_width_multiplier = (edits != null && edits.contains ("GeneralSettingsSnapshot.scale_width_multiplier")) || current.scale_width_multiplier != baseline.scale_width_multiplier ? current.scale_width_multiplier : optimized.scale_width_multiplier;
        result.scale_height_multiplier = (edits != null && edits.contains ("GeneralSettingsSnapshot.scale_height_multiplier")) || current.scale_height_multiplier != baseline.scale_height_multiplier ? current.scale_height_multiplier : optimized.scale_height_multiplier;
        result.scale_algorithm = (edits != null && edits.contains ("GeneralSettingsSnapshot.scale_algorithm")) || current.scale_algorithm != baseline.scale_algorithm ? current.scale_algorithm : optimized.scale_algorithm;
        result.scale_range = (edits != null && edits.contains ("GeneralSettingsSnapshot.scale_range")) || current.scale_range != baseline.scale_range ? current.scale_range : optimized.scale_range;
        result.rotate = (edits != null && edits.contains ("GeneralSettingsSnapshot.rotate")) || current.rotate != baseline.rotate ? current.rotate : optimized.rotate;
        result.crop_enabled = (edits != null && edits.contains ("GeneralSettingsSnapshot.crop_enabled")) || current.crop_enabled != baseline.crop_enabled ? current.crop_enabled : optimized.crop_enabled;
        result.crop_value = (edits != null && edits.contains ("GeneralSettingsSnapshot.crop_value")) || current.crop_value != baseline.crop_value ? current.crop_value : optimized.crop_value;
        result.video_filters = merge_video_filter_settings_snapshot (baseline.video_filters, current.video_filters, optimized.video_filters, edits);
        result.pixel_format = merge_pixel_format_settings_snapshot (baseline.pixel_format, current.pixel_format, optimized.pixel_format, edits);
        result.frame_rate_text = (edits != null && edits.contains ("GeneralSettingsSnapshot.frame_rate_text")) || current.frame_rate_text != baseline.frame_rate_text ? current.frame_rate_text : optimized.frame_rate_text;
        result.custom_frame_rate_text = (edits != null && edits.contains ("GeneralSettingsSnapshot.custom_frame_rate_text")) || current.custom_frame_rate_text != baseline.custom_frame_rate_text ? current.custom_frame_rate_text : optimized.custom_frame_rate_text;
        result.video_speed_enabled = (edits != null && edits.contains ("GeneralSettingsSnapshot.video_speed_enabled")) || current.video_speed_enabled != baseline.video_speed_enabled ? current.video_speed_enabled : optimized.video_speed_enabled;
        result.video_speed_percent = (edits != null && edits.contains ("GeneralSettingsSnapshot.video_speed_percent")) || current.video_speed_percent != baseline.video_speed_percent ? current.video_speed_percent : optimized.video_speed_percent;
        result.audio_speed_enabled = (edits != null && edits.contains ("GeneralSettingsSnapshot.audio_speed_enabled")) || current.audio_speed_enabled != baseline.audio_speed_enabled ? current.audio_speed_enabled : optimized.audio_speed_enabled;
        result.audio_speed_percent = (edits != null && edits.contains ("GeneralSettingsSnapshot.audio_speed_percent")) || current.audio_speed_percent != baseline.audio_speed_percent ? current.audio_speed_percent : optimized.audio_speed_percent;
        result.color_filter = (edits != null && edits.contains ("GeneralSettingsSnapshot.color_filter")) || current.color_filter != baseline.color_filter ? current.color_filter : optimized.color_filter;
        result.preserve_metadata = (edits != null && edits.contains ("GeneralSettingsSnapshot.preserve_metadata")) || current.preserve_metadata != baseline.preserve_metadata ? current.preserve_metadata : optimized.preserve_metadata;
        result.remove_chapters = (edits != null && edits.contains ("GeneralSettingsSnapshot.remove_chapters")) || current.remove_chapters != baseline.remove_chapters ? current.remove_chapters : optimized.remove_chapters;
        result.watermark_enabled = (edits != null && edits.contains ("GeneralSettingsSnapshot.watermark_enabled")) || current.watermark_enabled != baseline.watermark_enabled ? current.watermark_enabled : optimized.watermark_enabled;
        result.watermark_mode = (edits != null && edits.contains ("GeneralSettingsSnapshot.watermark_mode")) || current.watermark_mode != baseline.watermark_mode ? current.watermark_mode : optimized.watermark_mode;
        result.watermark_text = (edits != null && edits.contains ("GeneralSettingsSnapshot.watermark_text")) || current.watermark_text != baseline.watermark_text ? current.watermark_text : optimized.watermark_text;
        result.watermark_position = (edits != null && edits.contains ("GeneralSettingsSnapshot.watermark_position")) || current.watermark_position != baseline.watermark_position ? current.watermark_position : optimized.watermark_position;
        result.watermark_color = (edits != null && edits.contains ("GeneralSettingsSnapshot.watermark_color")) || current.watermark_color != baseline.watermark_color ? current.watermark_color : optimized.watermark_color;
        result.watermark_opacity = (edits != null && edits.contains ("GeneralSettingsSnapshot.watermark_opacity")) || current.watermark_opacity != baseline.watermark_opacity ? current.watermark_opacity : optimized.watermark_opacity;
        result.watermark_margin = (edits != null && edits.contains ("GeneralSettingsSnapshot.watermark_margin")) || current.watermark_margin != baseline.watermark_margin ? current.watermark_margin : optimized.watermark_margin;
        result.watermark_font_size = (edits != null && edits.contains ("GeneralSettingsSnapshot.watermark_font_size")) || current.watermark_font_size != baseline.watermark_font_size ? current.watermark_font_size : optimized.watermark_font_size;
        result.watermark_image_path = (edits != null && edits.contains ("GeneralSettingsSnapshot.watermark_image_path")) || current.watermark_image_path != baseline.watermark_image_path ? current.watermark_image_path : optimized.watermark_image_path;
        result.watermark_image_width = (edits != null && edits.contains ("GeneralSettingsSnapshot.watermark_image_width")) || current.watermark_image_width != baseline.watermark_image_width ? current.watermark_image_width : optimized.watermark_image_width;
        result.delogo_enabled = (edits != null && edits.contains ("GeneralSettingsSnapshot.delogo_enabled")) || current.delogo_enabled != baseline.delogo_enabled ? current.delogo_enabled : optimized.delogo_enabled;
        result.delogo_regions = (edits != null && edits.contains ("GeneralSettingsSnapshot.delogo_regions")) || current.delogo_regions != baseline.delogo_regions ? current.delogo_regions : optimized.delogo_regions;
        return result;
    }

    public static CodecTabSettingsSnapshot merge_codec_tab_settings_snapshot (CodecTabSettingsSnapshot baseline, CodecTabSettingsSnapshot current, CodecTabSettingsSnapshot optimized, HashTable<string, bool>? edits = null) {
        var result = new CodecTabSettingsSnapshot ();
        result.container = (edits != null && edits.contains ("CodecTabSettingsSnapshot.container")) || current.container != baseline.container ? current.container : optimized.container;
        result.keyframe_settings = merge_keyframe_settings_snapshot (baseline.keyframe_settings, current.keyframe_settings, optimized.keyframe_settings, edits);
        result.audio_settings = merge_audio_settings_snapshot (baseline.audio_settings, current.audio_settings, optimized.audio_settings, edits);
        result.audio_processing = merge_audio_processing_settings_snapshot (baseline.audio_processing, current.audio_processing, optimized.audio_processing, edits);
        result.pixel_format = merge_pixel_format_settings_snapshot (baseline.pixel_format, current.pixel_format, optimized.pixel_format, edits);
        return result;
    }

    public static KeyframeSettingsSnapshot merge_keyframe_settings_snapshot (KeyframeSettingsSnapshot baseline, KeyframeSettingsSnapshot current, KeyframeSettingsSnapshot optimized, HashTable<string, bool>? edits = null) {
        var result = new KeyframeSettingsSnapshot ();
        result.keyint_text = (edits != null && edits.contains ("KeyframeSettingsSnapshot.keyint_text")) || current.keyint_text != baseline.keyint_text ? current.keyint_text : optimized.keyint_text;
        result.custom_mode = (edits != null && edits.contains ("KeyframeSettingsSnapshot.custom_mode")) || current.custom_mode != baseline.custom_mode ? current.custom_mode : optimized.custom_mode;
        result.frame_rate_text = (edits != null && edits.contains ("KeyframeSettingsSnapshot.frame_rate_text")) || current.frame_rate_text != baseline.frame_rate_text ? current.frame_rate_text : optimized.frame_rate_text;
        result.custom_frame_rate_text = (edits != null && edits.contains ("KeyframeSettingsSnapshot.custom_frame_rate_text")) || current.custom_frame_rate_text != baseline.custom_frame_rate_text ? current.custom_frame_rate_text : optimized.custom_frame_rate_text;
        return result;
    }

    public static PixelFormatSettingsSnapshot merge_pixel_format_settings_snapshot (PixelFormatSettingsSnapshot baseline, PixelFormatSettingsSnapshot current, PixelFormatSettingsSnapshot optimized, HashTable<string, bool>? edits = null) {
        var result = new PixelFormatSettingsSnapshot ();
        result.eight_bit_selected = (edits != null && edits.contains ("PixelFormatSettingsSnapshot.eight_bit_selected")) || current.eight_bit_selected != baseline.eight_bit_selected ? current.eight_bit_selected : optimized.eight_bit_selected;
        result.eight_bit_format_text = (edits != null && edits.contains ("PixelFormatSettingsSnapshot.eight_bit_format_text")) || current.eight_bit_format_text != baseline.eight_bit_format_text ? current.eight_bit_format_text : optimized.eight_bit_format_text;
        result.ten_bit_selected = (edits != null && edits.contains ("PixelFormatSettingsSnapshot.ten_bit_selected")) || current.ten_bit_selected != baseline.ten_bit_selected ? current.ten_bit_selected : optimized.ten_bit_selected;
        result.ten_bit_format_text = (edits != null && edits.contains ("PixelFormatSettingsSnapshot.ten_bit_format_text")) || current.ten_bit_format_text != baseline.ten_bit_format_text ? current.ten_bit_format_text : optimized.ten_bit_format_text;
        return result;
    }

    public static VideoFilterSettingsSnapshot merge_video_filter_settings_snapshot (VideoFilterSettingsSnapshot baseline, VideoFilterSettingsSnapshot current, VideoFilterSettingsSnapshot optimized, HashTable<string, bool>? edits = null) {
        var result = new VideoFilterSettingsSnapshot ();
        result.processing_filters = ((edits != null && edits.contains ("VideoFilterSettingsSnapshot.processing_filters")) || string.joinv ("\x1f", baseline.processing_filters) != string.joinv ("\x1f", current.processing_filters)
            ? current.processing_filters : optimized.processing_filters).copy ();
        result.hdr_filter = (edits != null && edits.contains ("VideoFilterSettingsSnapshot.hdr_filter")) || current.hdr_filter != baseline.hdr_filter ? current.hdr_filter : optimized.hdr_filter;
        result.has_depth_variants = (edits != null && edits.contains ("VideoFilterSettingsSnapshot.has_depth_variants")) || current.has_depth_variants != baseline.has_depth_variants ? current.has_depth_variants : optimized.has_depth_variants;
        result.processing_filters_eight_bit = ((edits != null && edits.contains ("VideoFilterSettingsSnapshot.processing_filters_eight_bit")) || string.joinv ("\x1f", baseline.processing_filters_eight_bit) != string.joinv ("\x1f", current.processing_filters_eight_bit)
            ? current.processing_filters_eight_bit : optimized.processing_filters_eight_bit).copy ();
        result.processing_filters_ten_bit = ((edits != null && edits.contains ("VideoFilterSettingsSnapshot.processing_filters_ten_bit")) || string.joinv ("\x1f", baseline.processing_filters_ten_bit) != string.joinv ("\x1f", current.processing_filters_ten_bit)
            ? current.processing_filters_ten_bit : optimized.processing_filters_ten_bit).copy ();
        return result;
    }

    public static AudioProcessingSettingsSnapshot merge_audio_processing_settings_snapshot (AudioProcessingSettingsSnapshot baseline, AudioProcessingSettingsSnapshot current, AudioProcessingSettingsSnapshot optimized, HashTable<string, bool>? edits = null) {
        var result = new AudioProcessingSettingsSnapshot ();
        result.normalize_enabled = (edits != null && edits.contains ("AudioProcessingSettingsSnapshot.normalize_enabled")) || current.normalize_enabled != baseline.normalize_enabled ? current.normalize_enabled : optimized.normalize_enabled;
        result.normalize_ebu = (edits != null && edits.contains ("AudioProcessingSettingsSnapshot.normalize_ebu")) || current.normalize_ebu != baseline.normalize_ebu ? current.normalize_ebu : optimized.normalize_ebu;
        result.peak_normalize_gain_db = (edits != null && edits.contains ("AudioProcessingSettingsSnapshot.peak_normalize_gain_db")) || current.peak_normalize_gain_db != baseline.peak_normalize_gain_db ? current.peak_normalize_gain_db : optimized.peak_normalize_gain_db;
        result.fade_in_enabled = (edits != null && edits.contains ("AudioProcessingSettingsSnapshot.fade_in_enabled")) || current.fade_in_enabled != baseline.fade_in_enabled ? current.fade_in_enabled : optimized.fade_in_enabled;
        result.fade_in_duration = (edits != null && edits.contains ("AudioProcessingSettingsSnapshot.fade_in_duration")) || current.fade_in_duration != baseline.fade_in_duration ? current.fade_in_duration : optimized.fade_in_duration;
        result.fade_out_enabled = (edits != null && edits.contains ("AudioProcessingSettingsSnapshot.fade_out_enabled")) || current.fade_out_enabled != baseline.fade_out_enabled ? current.fade_out_enabled : optimized.fade_out_enabled;
        result.fade_out_duration = (edits != null && edits.contains ("AudioProcessingSettingsSnapshot.fade_out_duration")) || current.fade_out_duration != baseline.fade_out_duration ? current.fade_out_duration : optimized.fade_out_duration;
        result.channel_downmix = (edits != null && edits.contains ("AudioProcessingSettingsSnapshot.channel_downmix")) || current.channel_downmix != baseline.channel_downmix ? current.channel_downmix : optimized.channel_downmix;
        return result;
    }

    public static AudioSettingsSnapshot merge_audio_settings_snapshot (AudioSettingsSnapshot baseline, AudioSettingsSnapshot current, AudioSettingsSnapshot optimized, HashTable<string, bool>? edits = null) {
        var result = new AudioSettingsSnapshot ();
        result.enabled = (edits != null && edits.contains ("AudioSettingsSnapshot.enabled")) || current.enabled != baseline.enabled ? current.enabled : optimized.enabled;
        result.codec = (edits != null && edits.contains ("AudioSettingsSnapshot.codec")) || current.codec != baseline.codec ? current.codec : optimized.codec;
        result.preserve_all_audio_tracks = (edits != null && edits.contains ("AudioSettingsSnapshot.preserve_all_audio_tracks")) || current.preserve_all_audio_tracks != baseline.preserve_all_audio_tracks ? current.preserve_all_audio_tracks : optimized.preserve_all_audio_tracks;
        result.sample_rate_hz = (edits != null && edits.contains ("AudioSettingsSnapshot.sample_rate_hz")) || current.sample_rate_hz != baseline.sample_rate_hz ? current.sample_rate_hz : optimized.sample_rate_hz;
        result.bitrate_kbps = (edits != null && edits.contains ("AudioSettingsSnapshot.bitrate_kbps")) || current.bitrate_kbps != baseline.bitrate_kbps ? current.bitrate_kbps : optimized.bitrate_kbps;
        result.opus_vbr_mode = (edits != null && edits.contains ("AudioSettingsSnapshot.opus_vbr_mode")) || current.opus_vbr_mode != baseline.opus_vbr_mode ? current.opus_vbr_mode : optimized.opus_vbr_mode;
        result.opus_surround_fix = (edits != null && edits.contains ("AudioSettingsSnapshot.opus_surround_fix")) || current.opus_surround_fix != baseline.opus_surround_fix ? current.opus_surround_fix : optimized.opus_surround_fix;
        result.aac_quality = (edits != null && edits.contains ("AudioSettingsSnapshot.aac_quality")) || current.aac_quality != baseline.aac_quality ? current.aac_quality : optimized.aac_quality;
        result.mp3_vbr_quality = (edits != null && edits.contains ("AudioSettingsSnapshot.mp3_vbr_quality")) || current.mp3_vbr_quality != baseline.mp3_vbr_quality ? current.mp3_vbr_quality : optimized.mp3_vbr_quality;
        result.flac_compression = (edits != null && edits.contains ("AudioSettingsSnapshot.flac_compression")) || current.flac_compression != baseline.flac_compression ? current.flac_compression : optimized.flac_compression;
        result.vorbis_quality = (edits != null && edits.contains ("AudioSettingsSnapshot.vorbis_quality")) || current.vorbis_quality != baseline.vorbis_quality ? current.vorbis_quality : optimized.vorbis_quality;
        result.sample_format = (edits != null && edits.contains ("AudioSettingsSnapshot.sample_format")) || current.sample_format != baseline.sample_format ? current.sample_format : optimized.sample_format;
        return result;
    }

    public static void record_changes (BulkConversionSettings before, BulkConversionSettings after, HashTable<string, bool> edits) {
        if (before.two_pass != after.two_pass) edits.insert ("two_pass", true);
        record_general_settings_snapshot (before.general_settings, after.general_settings, edits);
        record_codec_tab_settings_snapshot (before.codec_settings, after.codec_settings, edits);
        if (before.builder_settings is X264BuilderSnapshot && after.builder_settings is X264BuilderSnapshot)
            record_x264_builder_snapshot ((X264BuilderSnapshot) before.builder_settings, (X264BuilderSnapshot) after.builder_settings, edits);
        if (before.builder_settings is X265BuilderSnapshot && after.builder_settings is X265BuilderSnapshot)
            record_x265_builder_snapshot ((X265BuilderSnapshot) before.builder_settings, (X265BuilderSnapshot) after.builder_settings, edits);
        if (before.builder_settings is Vp9BuilderSnapshot && after.builder_settings is Vp9BuilderSnapshot)
            record_vp9_builder_snapshot ((Vp9BuilderSnapshot) before.builder_settings, (Vp9BuilderSnapshot) after.builder_settings, edits);
        if (before.builder_settings is SvtAv1BuilderSnapshot && after.builder_settings is SvtAv1BuilderSnapshot)
            record_svt_av1_builder_snapshot ((SvtAv1BuilderSnapshot) before.builder_settings, (SvtAv1BuilderSnapshot) after.builder_settings, edits);
        // Rate control and its values/two-pass choice form one user decision.
        if (edits.contains ("X264BuilderSnapshot.rc_mode")
                || edits.contains ("X264BuilderSnapshot.crf")
                || edits.contains ("X264BuilderSnapshot.qp")
                || edits.contains ("X264BuilderSnapshot.abr_bitrate_kbps")
                || edits.contains ("X264BuilderSnapshot.cbr_bitrate_kbps")) {
            edits.insert ("X264BuilderSnapshot.rc_mode", true);
            edits.insert ("X264BuilderSnapshot.crf", true);
            edits.insert ("X264BuilderSnapshot.qp", true);
            edits.insert ("X264BuilderSnapshot.abr_bitrate_kbps", true);
            edits.insert ("X264BuilderSnapshot.cbr_bitrate_kbps", true);
            edits.insert ("two_pass", true);
        }
        if (edits.contains ("X265BuilderSnapshot.rc_mode")
                || edits.contains ("X265BuilderSnapshot.crf")
                || edits.contains ("X265BuilderSnapshot.qp")
                || edits.contains ("X265BuilderSnapshot.abr_bitrate_kbps")
                || edits.contains ("X265BuilderSnapshot.cbr_bitrate_kbps")) {
            edits.insert ("X265BuilderSnapshot.rc_mode", true);
            edits.insert ("X265BuilderSnapshot.crf", true);
            edits.insert ("X265BuilderSnapshot.qp", true);
            edits.insert ("X265BuilderSnapshot.abr_bitrate_kbps", true);
            edits.insert ("X265BuilderSnapshot.cbr_bitrate_kbps", true);
            edits.insert ("two_pass", true);
        }
        if (edits.contains ("Vp9BuilderSnapshot.rc_mode")
                || edits.contains ("Vp9BuilderSnapshot.crf")
                || edits.contains ("Vp9BuilderSnapshot.cq_level")
                || edits.contains ("Vp9BuilderSnapshot.cq_bitrate_kbps")
                || edits.contains ("Vp9BuilderSnapshot.vbr_bitrate_kbps")
                || edits.contains ("Vp9BuilderSnapshot.cbr_bitrate_kbps")) {
            edits.insert ("Vp9BuilderSnapshot.rc_mode", true);
            edits.insert ("Vp9BuilderSnapshot.crf", true);
            edits.insert ("Vp9BuilderSnapshot.cq_level", true);
            edits.insert ("Vp9BuilderSnapshot.cq_bitrate_kbps", true);
            edits.insert ("Vp9BuilderSnapshot.vbr_bitrate_kbps", true);
            edits.insert ("Vp9BuilderSnapshot.cbr_bitrate_kbps", true);
            edits.insert ("two_pass", true);
        }
        if (edits.contains ("SvtAv1BuilderSnapshot.rc_mode")
                || edits.contains ("SvtAv1BuilderSnapshot.crf")
                || edits.contains ("SvtAv1BuilderSnapshot.qp")
                || edits.contains ("SvtAv1BuilderSnapshot.vbr_bitrate_kbps")
                || edits.contains ("SvtAv1BuilderSnapshot.mbr_enabled")
                || edits.contains ("SvtAv1BuilderSnapshot.mbr_bitrate_kbps")) {
            edits.insert ("SvtAv1BuilderSnapshot.rc_mode", true);
            edits.insert ("SvtAv1BuilderSnapshot.crf", true);
            edits.insert ("SvtAv1BuilderSnapshot.qp", true);
            edits.insert ("SvtAv1BuilderSnapshot.vbr_bitrate_kbps", true);
            edits.insert ("SvtAv1BuilderSnapshot.mbr_enabled", true);
            edits.insert ("SvtAv1BuilderSnapshot.mbr_bitrate_kbps", true);
            edits.insert ("two_pass", true);
        }
    }

    private static void record_x264_builder_snapshot (X264BuilderSnapshot before, X264BuilderSnapshot after, HashTable<string, bool> edits) {
        if (before.preset != after.preset) edits.insert ("X264BuilderSnapshot.preset", true);
        if (before.profile != after.profile) edits.insert ("X264BuilderSnapshot.profile", true);
        if (before.rc_mode != after.rc_mode) edits.insert ("X264BuilderSnapshot.rc_mode", true);
        if (before.crf != after.crf) edits.insert ("X264BuilderSnapshot.crf", true);
        if (before.qp != after.qp) edits.insert ("X264BuilderSnapshot.qp", true);
        if (before.abr_bitrate_kbps != after.abr_bitrate_kbps) edits.insert ("X264BuilderSnapshot.abr_bitrate_kbps", true);
        if (before.cbr_bitrate_kbps != after.cbr_bitrate_kbps) edits.insert ("X264BuilderSnapshot.cbr_bitrate_kbps", true);
        if (before.tune != after.tune) edits.insert ("X264BuilderSnapshot.tune", true);
        if (before.level != after.level) edits.insert ("X264BuilderSnapshot.level", true);
        if (before.keyint_text != after.keyint_text) edits.insert ("X264BuilderSnapshot.keyint_text", true);
        if (before.ref_frames != after.ref_frames) edits.insert ("X264BuilderSnapshot.ref_frames", true);
        if (before.bframes != after.bframes) edits.insert ("X264BuilderSnapshot.bframes", true);
        if (before.b_adapt != after.b_adapt) edits.insert ("X264BuilderSnapshot.b_adapt", true);
        if (before.weightp != after.weightp) edits.insert ("X264BuilderSnapshot.weightp", true);
        if (before.deblock_enabled != after.deblock_enabled) edits.insert ("X264BuilderSnapshot.deblock_enabled", true);
        if (before.deblock_alpha != after.deblock_alpha) edits.insert ("X264BuilderSnapshot.deblock_alpha", true);
        if (before.deblock_beta != after.deblock_beta) edits.insert ("X264BuilderSnapshot.deblock_beta", true);
        if (before.me != after.me) edits.insert ("X264BuilderSnapshot.me", true);
        if (before.me_range != after.me_range) edits.insert ("X264BuilderSnapshot.me_range", true);
        if (before.subme != after.subme) edits.insert ("X264BuilderSnapshot.subme", true);
        if (before.psy_rd_enabled != after.psy_rd_enabled) edits.insert ("X264BuilderSnapshot.psy_rd_enabled", true);
        if (before.psy_rd != after.psy_rd) edits.insert ("X264BuilderSnapshot.psy_rd", true);
        if (before.psy_trellis != after.psy_trellis) edits.insert ("X264BuilderSnapshot.psy_trellis", true);
        if (before.cabac != after.cabac) edits.insert ("X264BuilderSnapshot.cabac", true);
        if (before.mbtree != after.mbtree) edits.insert ("X264BuilderSnapshot.mbtree", true);
        if (before.lookahead_enabled != after.lookahead_enabled) edits.insert ("X264BuilderSnapshot.lookahead_enabled", true);
        if (before.lookahead != after.lookahead) edits.insert ("X264BuilderSnapshot.lookahead", true);
        if (before.aq_mode != after.aq_mode) edits.insert ("X264BuilderSnapshot.aq_mode", true);
        if (before.aq_strength != after.aq_strength) edits.insert ("X264BuilderSnapshot.aq_strength", true);
        if (before.abr_vbv != after.abr_vbv) edits.insert ("X264BuilderSnapshot.abr_vbv", true);
        if (before.open_gop != after.open_gop) edits.insert ("X264BuilderSnapshot.open_gop", true);
        if (before.threads != after.threads) edits.insert ("X264BuilderSnapshot.threads", true);
    }

    private static void record_x265_builder_snapshot (X265BuilderSnapshot before, X265BuilderSnapshot after, HashTable<string, bool> edits) {
        if (before.preset != after.preset) edits.insert ("X265BuilderSnapshot.preset", true);
        if (before.profile != after.profile) edits.insert ("X265BuilderSnapshot.profile", true);
        if (before.rc_mode != after.rc_mode) edits.insert ("X265BuilderSnapshot.rc_mode", true);
        if (before.crf != after.crf) edits.insert ("X265BuilderSnapshot.crf", true);
        if (before.qp != after.qp) edits.insert ("X265BuilderSnapshot.qp", true);
        if (before.abr_bitrate_kbps != after.abr_bitrate_kbps) edits.insert ("X265BuilderSnapshot.abr_bitrate_kbps", true);
        if (before.cbr_bitrate_kbps != after.cbr_bitrate_kbps) edits.insert ("X265BuilderSnapshot.cbr_bitrate_kbps", true);
        if (before.tune != after.tune) edits.insert ("X265BuilderSnapshot.tune", true);
        if (before.level != after.level) edits.insert ("X265BuilderSnapshot.level", true);
        if (before.keyint_text != after.keyint_text) edits.insert ("X265BuilderSnapshot.keyint_text", true);
        if (before.sao != after.sao) edits.insert ("X265BuilderSnapshot.sao", true);
        if (before.ref_frames != after.ref_frames) edits.insert ("X265BuilderSnapshot.ref_frames", true);
        if (before.weightp != after.weightp) edits.insert ("X265BuilderSnapshot.weightp", true);
        if (before.deblock_enabled != after.deblock_enabled) edits.insert ("X265BuilderSnapshot.deblock_enabled", true);
        if (before.deblock_alpha != after.deblock_alpha) edits.insert ("X265BuilderSnapshot.deblock_alpha", true);
        if (before.deblock_beta != after.deblock_beta) edits.insert ("X265BuilderSnapshot.deblock_beta", true);
        if (before.pmode != after.pmode) edits.insert ("X265BuilderSnapshot.pmode", true);
        if (before.psy_rd_enabled != after.psy_rd_enabled) edits.insert ("X265BuilderSnapshot.psy_rd_enabled", true);
        if (before.psy_rd != after.psy_rd) edits.insert ("X265BuilderSnapshot.psy_rd", true);
        if (before.cutree != after.cutree) edits.insert ("X265BuilderSnapshot.cutree", true);
        if (before.lookahead_enabled != after.lookahead_enabled) edits.insert ("X265BuilderSnapshot.lookahead_enabled", true);
        if (before.lookahead != after.lookahead) edits.insert ("X265BuilderSnapshot.lookahead", true);
        if (before.aq_mode != after.aq_mode) edits.insert ("X265BuilderSnapshot.aq_mode", true);
        if (before.aq_strength != after.aq_strength) edits.insert ("X265BuilderSnapshot.aq_strength", true);
        if (before.abr_vbv != after.abr_vbv) edits.insert ("X265BuilderSnapshot.abr_vbv", true);
        if (before.threads != after.threads) edits.insert ("X265BuilderSnapshot.threads", true);
        if (before.frame_threads != after.frame_threads) edits.insert ("X265BuilderSnapshot.frame_threads", true);
    }

    private static void record_vp9_builder_snapshot (Vp9BuilderSnapshot before, Vp9BuilderSnapshot after, HashTable<string, bool> edits) {
        if (before.speed != after.speed) edits.insert ("Vp9BuilderSnapshot.speed", true);
        if (before.quality_deadline != after.quality_deadline) edits.insert ("Vp9BuilderSnapshot.quality_deadline", true);
        if (before.profile != after.profile) edits.insert ("Vp9BuilderSnapshot.profile", true);
        if (before.rc_mode != after.rc_mode) edits.insert ("Vp9BuilderSnapshot.rc_mode", true);
        if (before.crf != after.crf) edits.insert ("Vp9BuilderSnapshot.crf", true);
        if (before.cq_level != after.cq_level) edits.insert ("Vp9BuilderSnapshot.cq_level", true);
        if (before.cq_bitrate_kbps != after.cq_bitrate_kbps) edits.insert ("Vp9BuilderSnapshot.cq_bitrate_kbps", true);
        if (before.vbr_bitrate_kbps != after.vbr_bitrate_kbps) edits.insert ("Vp9BuilderSnapshot.vbr_bitrate_kbps", true);
        if (before.cbr_bitrate_kbps != after.cbr_bitrate_kbps) edits.insert ("Vp9BuilderSnapshot.cbr_bitrate_kbps", true);
        if (before.tune_content != after.tune_content) edits.insert ("Vp9BuilderSnapshot.tune_content", true);
        if (before.aq_mode != after.aq_mode) edits.insert ("Vp9BuilderSnapshot.aq_mode", true);
        if (before.sharpness_enabled != after.sharpness_enabled) edits.insert ("Vp9BuilderSnapshot.sharpness_enabled", true);
        if (before.sharpness != after.sharpness) edits.insert ("Vp9BuilderSnapshot.sharpness", true);
        if (before.lookahead_enabled != after.lookahead_enabled) edits.insert ("Vp9BuilderSnapshot.lookahead_enabled", true);
        if (before.lag_in_frames != after.lag_in_frames) edits.insert ("Vp9BuilderSnapshot.lag_in_frames", true);
        if (before.altref_enabled != after.altref_enabled) edits.insert ("Vp9BuilderSnapshot.altref_enabled", true);
        if (before.arnr_maxframes != after.arnr_maxframes) edits.insert ("Vp9BuilderSnapshot.arnr_maxframes", true);
        if (before.arnr_strength != after.arnr_strength) edits.insert ("Vp9BuilderSnapshot.arnr_strength", true);
        if (before.row_mt != after.row_mt) edits.insert ("Vp9BuilderSnapshot.row_mt", true);
        if (before.frame_parallel != after.frame_parallel) edits.insert ("Vp9BuilderSnapshot.frame_parallel", true);
        if (before.undershoot_enabled != after.undershoot_enabled) edits.insert ("Vp9BuilderSnapshot.undershoot_enabled", true);
        if (before.undershoot != after.undershoot) edits.insert ("Vp9BuilderSnapshot.undershoot", true);
        if (before.overshoot != after.overshoot) edits.insert ("Vp9BuilderSnapshot.overshoot", true);
        if (before.keyint_text != after.keyint_text) edits.insert ("Vp9BuilderSnapshot.keyint_text", true);
        if (before.tile_columns != after.tile_columns) edits.insert ("Vp9BuilderSnapshot.tile_columns", true);
        if (before.tile_rows != after.tile_rows) edits.insert ("Vp9BuilderSnapshot.tile_rows", true);
        if (before.threads != after.threads) edits.insert ("Vp9BuilderSnapshot.threads", true);
    }

    private static void record_svt_av1_builder_snapshot (SvtAv1BuilderSnapshot before, SvtAv1BuilderSnapshot after, HashTable<string, bool> edits) {
        if (before.preset != after.preset) edits.insert ("SvtAv1BuilderSnapshot.preset", true);
        if (before.rc_mode != after.rc_mode) edits.insert ("SvtAv1BuilderSnapshot.rc_mode", true);
        if (before.crf != after.crf) edits.insert ("SvtAv1BuilderSnapshot.crf", true);
        if (before.qp != after.qp) edits.insert ("SvtAv1BuilderSnapshot.qp", true);
        if (before.vbr_bitrate_kbps != after.vbr_bitrate_kbps) edits.insert ("SvtAv1BuilderSnapshot.vbr_bitrate_kbps", true);
        if (before.mbr_enabled != after.mbr_enabled) edits.insert ("SvtAv1BuilderSnapshot.mbr_enabled", true);
        if (before.mbr_bitrate_kbps != after.mbr_bitrate_kbps) edits.insert ("SvtAv1BuilderSnapshot.mbr_bitrate_kbps", true);
        if (before.level != after.level) edits.insert ("SvtAv1BuilderSnapshot.level", true);
        if (before.keyint_text != after.keyint_text) edits.insert ("SvtAv1BuilderSnapshot.keyint_text", true);
        if (before.tune_selected != after.tune_selected) edits.insert ("SvtAv1BuilderSnapshot.tune_selected", true);
        if (before.lookahead_enabled != after.lookahead_enabled) edits.insert ("SvtAv1BuilderSnapshot.lookahead_enabled", true);
        if (before.lookahead != after.lookahead) edits.insert ("SvtAv1BuilderSnapshot.lookahead", true);
        if (before.aq_mode != after.aq_mode) edits.insert ("SvtAv1BuilderSnapshot.aq_mode", true);
        if (before.aq_strength != after.aq_strength) edits.insert ("SvtAv1BuilderSnapshot.aq_strength", true);
        if (before.grain_enabled != after.grain_enabled) edits.insert ("SvtAv1BuilderSnapshot.grain_enabled", true);
        if (before.grain_strength != after.grain_strength) edits.insert ("SvtAv1BuilderSnapshot.grain_strength", true);
        if (before.grain_denoise_selected != after.grain_denoise_selected) edits.insert ("SvtAv1BuilderSnapshot.grain_denoise_selected", true);
        if (before.cdef != after.cdef) edits.insert ("SvtAv1BuilderSnapshot.cdef", true);
        if (before.restoration != after.restoration) edits.insert ("SvtAv1BuilderSnapshot.restoration", true);
        if (before.dlf != after.dlf) edits.insert ("SvtAv1BuilderSnapshot.dlf", true);
        if (before.tf != after.tf) edits.insert ("SvtAv1BuilderSnapshot.tf", true);
        if (before.tpl != after.tpl) edits.insert ("SvtAv1BuilderSnapshot.tpl", true);
        if (before.low_latency != after.low_latency) edits.insert ("SvtAv1BuilderSnapshot.low_latency", true);
        if (before.superres_enabled != after.superres_enabled) edits.insert ("SvtAv1BuilderSnapshot.superres_enabled", true);
        if (before.superres_mode_selected != after.superres_mode_selected) edits.insert ("SvtAv1BuilderSnapshot.superres_mode_selected", true);
        if (before.superres_denom != after.superres_denom) edits.insert ("SvtAv1BuilderSnapshot.superres_denom", true);
        if (before.sharpness_enabled != after.sharpness_enabled) edits.insert ("SvtAv1BuilderSnapshot.sharpness_enabled", true);
        if (before.sharpness != after.sharpness) edits.insert ("SvtAv1BuilderSnapshot.sharpness", true);
        if (before.scm != after.scm) edits.insert ("SvtAv1BuilderSnapshot.scm", true);
        if (before.fast_decode != after.fast_decode) edits.insert ("SvtAv1BuilderSnapshot.fast_decode", true);
        if (before.qm_enabled != after.qm_enabled) edits.insert ("SvtAv1BuilderSnapshot.qm_enabled", true);
        if (before.qm_min != after.qm_min) edits.insert ("SvtAv1BuilderSnapshot.qm_min", true);
        if (before.qm_max != after.qm_max) edits.insert ("SvtAv1BuilderSnapshot.qm_max", true);
        if (before.tile_rows != after.tile_rows) edits.insert ("SvtAv1BuilderSnapshot.tile_rows", true);
        if (before.tile_columns != after.tile_columns) edits.insert ("SvtAv1BuilderSnapshot.tile_columns", true);
        if (before.threads != after.threads) edits.insert ("SvtAv1BuilderSnapshot.threads", true);
    }

    private static void record_general_settings_snapshot (GeneralSettingsSnapshot before, GeneralSettingsSnapshot after, HashTable<string, bool> edits) {
        if (before.scale_mode != after.scale_mode) edits.insert ("GeneralSettingsSnapshot.scale_mode", true);
        if (before.resolution_preset_value != after.resolution_preset_value) edits.insert ("GeneralSettingsSnapshot.resolution_preset_value", true);
        if (before.custom_resolution_value != after.custom_resolution_value) edits.insert ("GeneralSettingsSnapshot.custom_resolution_value", true);
        if (before.scale_width_multiplier != after.scale_width_multiplier) edits.insert ("GeneralSettingsSnapshot.scale_width_multiplier", true);
        if (before.scale_height_multiplier != after.scale_height_multiplier) edits.insert ("GeneralSettingsSnapshot.scale_height_multiplier", true);
        if (before.scale_algorithm != after.scale_algorithm) edits.insert ("GeneralSettingsSnapshot.scale_algorithm", true);
        if (before.scale_range != after.scale_range) edits.insert ("GeneralSettingsSnapshot.scale_range", true);
        if (before.rotate != after.rotate) edits.insert ("GeneralSettingsSnapshot.rotate", true);
        if (before.crop_enabled != after.crop_enabled) edits.insert ("GeneralSettingsSnapshot.crop_enabled", true);
        if (before.crop_value != after.crop_value) edits.insert ("GeneralSettingsSnapshot.crop_value", true);
        record_video_filter_settings_snapshot (before.video_filters, after.video_filters, edits);
        record_pixel_format_settings_snapshot (before.pixel_format, after.pixel_format, edits);
        if (before.frame_rate_text != after.frame_rate_text) edits.insert ("GeneralSettingsSnapshot.frame_rate_text", true);
        if (before.custom_frame_rate_text != after.custom_frame_rate_text) edits.insert ("GeneralSettingsSnapshot.custom_frame_rate_text", true);
        if (before.video_speed_enabled != after.video_speed_enabled) edits.insert ("GeneralSettingsSnapshot.video_speed_enabled", true);
        if (before.video_speed_percent != after.video_speed_percent) edits.insert ("GeneralSettingsSnapshot.video_speed_percent", true);
        if (before.audio_speed_enabled != after.audio_speed_enabled) edits.insert ("GeneralSettingsSnapshot.audio_speed_enabled", true);
        if (before.audio_speed_percent != after.audio_speed_percent) edits.insert ("GeneralSettingsSnapshot.audio_speed_percent", true);
        if (before.color_filter != after.color_filter) edits.insert ("GeneralSettingsSnapshot.color_filter", true);
        if (before.preserve_metadata != after.preserve_metadata) edits.insert ("GeneralSettingsSnapshot.preserve_metadata", true);
        if (before.remove_chapters != after.remove_chapters) edits.insert ("GeneralSettingsSnapshot.remove_chapters", true);
        if (before.watermark_enabled != after.watermark_enabled) edits.insert ("GeneralSettingsSnapshot.watermark_enabled", true);
        if (before.watermark_mode != after.watermark_mode) edits.insert ("GeneralSettingsSnapshot.watermark_mode", true);
        if (before.watermark_text != after.watermark_text) edits.insert ("GeneralSettingsSnapshot.watermark_text", true);
        if (before.watermark_position != after.watermark_position) edits.insert ("GeneralSettingsSnapshot.watermark_position", true);
        if (before.watermark_color != after.watermark_color) edits.insert ("GeneralSettingsSnapshot.watermark_color", true);
        if (before.watermark_opacity != after.watermark_opacity) edits.insert ("GeneralSettingsSnapshot.watermark_opacity", true);
        if (before.watermark_margin != after.watermark_margin) edits.insert ("GeneralSettingsSnapshot.watermark_margin", true);
        if (before.watermark_font_size != after.watermark_font_size) edits.insert ("GeneralSettingsSnapshot.watermark_font_size", true);
        if (before.watermark_image_path != after.watermark_image_path) edits.insert ("GeneralSettingsSnapshot.watermark_image_path", true);
        if (before.watermark_image_width != after.watermark_image_width) edits.insert ("GeneralSettingsSnapshot.watermark_image_width", true);
        if (before.delogo_enabled != after.delogo_enabled) edits.insert ("GeneralSettingsSnapshot.delogo_enabled", true);
        if (before.delogo_regions != after.delogo_regions) edits.insert ("GeneralSettingsSnapshot.delogo_regions", true);
    }

    private static void record_codec_tab_settings_snapshot (CodecTabSettingsSnapshot before, CodecTabSettingsSnapshot after, HashTable<string, bool> edits) {
        if (before.container != after.container) edits.insert ("CodecTabSettingsSnapshot.container", true);
        record_keyframe_settings_snapshot (before.keyframe_settings, after.keyframe_settings, edits);
        record_audio_settings_snapshot (before.audio_settings, after.audio_settings, edits);
        record_audio_processing_settings_snapshot (before.audio_processing, after.audio_processing, edits);
        record_pixel_format_settings_snapshot (before.pixel_format, after.pixel_format, edits);
    }

    private static void record_keyframe_settings_snapshot (KeyframeSettingsSnapshot before, KeyframeSettingsSnapshot after, HashTable<string, bool> edits) {
        if (before.keyint_text != after.keyint_text) edits.insert ("KeyframeSettingsSnapshot.keyint_text", true);
        if (before.custom_mode != after.custom_mode) edits.insert ("KeyframeSettingsSnapshot.custom_mode", true);
        if (before.frame_rate_text != after.frame_rate_text) edits.insert ("KeyframeSettingsSnapshot.frame_rate_text", true);
        if (before.custom_frame_rate_text != after.custom_frame_rate_text) edits.insert ("KeyframeSettingsSnapshot.custom_frame_rate_text", true);
    }

    private static void record_pixel_format_settings_snapshot (PixelFormatSettingsSnapshot before, PixelFormatSettingsSnapshot after, HashTable<string, bool> edits) {
        if (before.eight_bit_selected != after.eight_bit_selected) edits.insert ("PixelFormatSettingsSnapshot.eight_bit_selected", true);
        if (before.eight_bit_format_text != after.eight_bit_format_text) edits.insert ("PixelFormatSettingsSnapshot.eight_bit_format_text", true);
        if (before.ten_bit_selected != after.ten_bit_selected) edits.insert ("PixelFormatSettingsSnapshot.ten_bit_selected", true);
        if (before.ten_bit_format_text != after.ten_bit_format_text) edits.insert ("PixelFormatSettingsSnapshot.ten_bit_format_text", true);
    }

    private static void record_video_filter_settings_snapshot (VideoFilterSettingsSnapshot before, VideoFilterSettingsSnapshot after, HashTable<string, bool> edits) {
        if (string.joinv ("\x1f", before.processing_filters) != string.joinv ("\x1f", after.processing_filters)) edits.insert ("VideoFilterSettingsSnapshot.processing_filters", true);
        if (before.hdr_filter != after.hdr_filter) edits.insert ("VideoFilterSettingsSnapshot.hdr_filter", true);
        if (before.has_depth_variants != after.has_depth_variants) edits.insert ("VideoFilterSettingsSnapshot.has_depth_variants", true);
        if (string.joinv ("\x1f", before.processing_filters_eight_bit) != string.joinv ("\x1f", after.processing_filters_eight_bit)) edits.insert ("VideoFilterSettingsSnapshot.processing_filters_eight_bit", true);
        if (string.joinv ("\x1f", before.processing_filters_ten_bit) != string.joinv ("\x1f", after.processing_filters_ten_bit)) edits.insert ("VideoFilterSettingsSnapshot.processing_filters_ten_bit", true);
    }

    private static void record_audio_processing_settings_snapshot (AudioProcessingSettingsSnapshot before, AudioProcessingSettingsSnapshot after, HashTable<string, bool> edits) {
        if (before.normalize_enabled != after.normalize_enabled) edits.insert ("AudioProcessingSettingsSnapshot.normalize_enabled", true);
        if (before.normalize_ebu != after.normalize_ebu) edits.insert ("AudioProcessingSettingsSnapshot.normalize_ebu", true);
        if (before.peak_normalize_gain_db != after.peak_normalize_gain_db) edits.insert ("AudioProcessingSettingsSnapshot.peak_normalize_gain_db", true);
        if (before.fade_in_enabled != after.fade_in_enabled) edits.insert ("AudioProcessingSettingsSnapshot.fade_in_enabled", true);
        if (before.fade_in_duration != after.fade_in_duration) edits.insert ("AudioProcessingSettingsSnapshot.fade_in_duration", true);
        if (before.fade_out_enabled != after.fade_out_enabled) edits.insert ("AudioProcessingSettingsSnapshot.fade_out_enabled", true);
        if (before.fade_out_duration != after.fade_out_duration) edits.insert ("AudioProcessingSettingsSnapshot.fade_out_duration", true);
        if (before.channel_downmix != after.channel_downmix) edits.insert ("AudioProcessingSettingsSnapshot.channel_downmix", true);
    }

    private static void record_audio_settings_snapshot (AudioSettingsSnapshot before, AudioSettingsSnapshot after, HashTable<string, bool> edits) {
        if (before.enabled != after.enabled) edits.insert ("AudioSettingsSnapshot.enabled", true);
        if (before.codec != after.codec) edits.insert ("AudioSettingsSnapshot.codec", true);
        if (before.preserve_all_audio_tracks != after.preserve_all_audio_tracks) edits.insert ("AudioSettingsSnapshot.preserve_all_audio_tracks", true);
        if (before.sample_rate_hz != after.sample_rate_hz) edits.insert ("AudioSettingsSnapshot.sample_rate_hz", true);
        if (before.bitrate_kbps != after.bitrate_kbps) edits.insert ("AudioSettingsSnapshot.bitrate_kbps", true);
        if (before.opus_vbr_mode != after.opus_vbr_mode) edits.insert ("AudioSettingsSnapshot.opus_vbr_mode", true);
        if (before.opus_surround_fix != after.opus_surround_fix) edits.insert ("AudioSettingsSnapshot.opus_surround_fix", true);
        if (before.aac_quality != after.aac_quality) edits.insert ("AudioSettingsSnapshot.aac_quality", true);
        if (before.mp3_vbr_quality != after.mp3_vbr_quality) edits.insert ("AudioSettingsSnapshot.mp3_vbr_quality", true);
        if (before.flac_compression != after.flac_compression) edits.insert ("AudioSettingsSnapshot.flac_compression", true);
        if (before.vorbis_quality != after.vorbis_quality) edits.insert ("AudioSettingsSnapshot.vorbis_quality", true);
        if (before.sample_format != after.sample_format) edits.insert ("AudioSettingsSnapshot.sample_format", true);
    }

    public static string describe (SmartCodecResolution settings) {
        EncodeProfileSnapshot profile = settings.to_profile ();
        string summary = settings.codec_name;
        for (int i = 0; i + 1 < profile.codec_args.length; i++) {
            string arg = profile.codec_args[i];
            if (arg == "-crf") summary += " · CRF " + profile.codec_args[i + 1];
            if (arg == "-qp") summary += " · QP " + profile.codec_args[i + 1];
            if (arg == "-b:v") summary += " · " + profile.codec_args[i + 1];
            if (arg == "-preset") summary += " · preset " + profile.codec_args[i + 1];
            if (arg == "-cpu-used") summary += " · cpu-used " + profile.codec_args[i + 1];
        }
        return summary + (settings.two_pass ? " · two passes" : " · one pass");
    }

    public static Object copy_builder (Object settings) {
        return merge_builder (settings, settings, settings);
    }

    public static Object merge_builder (Object baseline, Object current, Object optimized, HashTable<string, bool>? edits = null) {
        if (baseline is X264BuilderSnapshot && current is X264BuilderSnapshot && optimized is X264BuilderSnapshot)
            return merge_x264_builder_snapshot ((X264BuilderSnapshot) baseline, (X264BuilderSnapshot) current, (X264BuilderSnapshot) optimized, edits);
        if (baseline is X265BuilderSnapshot && current is X265BuilderSnapshot && optimized is X265BuilderSnapshot)
            return merge_x265_builder_snapshot ((X265BuilderSnapshot) baseline, (X265BuilderSnapshot) current, (X265BuilderSnapshot) optimized, edits);
        if (baseline is Vp9BuilderSnapshot && current is Vp9BuilderSnapshot && optimized is Vp9BuilderSnapshot)
            return merge_vp9_builder_snapshot ((Vp9BuilderSnapshot) baseline, (Vp9BuilderSnapshot) current, (Vp9BuilderSnapshot) optimized, edits);
        if (baseline is SvtAv1BuilderSnapshot && current is SvtAv1BuilderSnapshot && optimized is SvtAv1BuilderSnapshot)
            return merge_svt_av1_builder_snapshot ((SvtAv1BuilderSnapshot) baseline, (SvtAv1BuilderSnapshot) current, (SvtAv1BuilderSnapshot) optimized, edits);
        // Older programmatic Optimize callers may not capture a manual builder.
        // Preserve the resolved codec in that case, never substitute another encoder.
        if (optimized is X264BuilderSnapshot || optimized is X265BuilderSnapshot
                || optimized is Vp9BuilderSnapshot || optimized is SvtAv1BuilderSnapshot)
            return copy_builder (optimized);
        return new X265BuilderSnapshot ();
    }

    public static void set_general (Object builder, GeneralSettingsSnapshot general) {
        if (builder is X264BuilderSnapshot) ((X264BuilderSnapshot) builder).general_settings = general.copy ();
        if (builder is X265BuilderSnapshot) ((X265BuilderSnapshot) builder).general_settings = general.copy ();
        if (builder is Vp9BuilderSnapshot) ((Vp9BuilderSnapshot) builder).general_settings = general.copy ();
        if (builder is SvtAv1BuilderSnapshot) ((SvtAv1BuilderSnapshot) builder).general_settings = general.copy ();
    }

    public static SmartCodecResolution apply (SmartCodecResolution optimized,
                                               BulkConversionSettings baseline,
                                               BulkConversionSettings current) {
        record_changes (baseline, current, current.edited_fields);
        var result = new SmartCodecResolution ();
        result.codec_name = optimized.codec_name;
        result.two_pass = current.edited_fields.contains ("two_pass") || current.two_pass != baseline.two_pass ? current.two_pass : optimized.two_pass;
        result.codec_settings = merge_codec_tab_settings_snapshot (
            baseline.codec_settings, current.codec_settings, optimized.codec_settings, current.edited_fields);
        result.general_settings = merge_general_settings_snapshot (
            baseline.general_settings, current.general_settings, optimized.general_settings, current.edited_fields);
        result.builder_settings = merge_builder (baseline.builder_settings,
            current.builder_settings, optimized.builder_settings, current.edited_fields);
        result.general_settings.pixel_format = result.codec_settings.pixel_format.copy ();
        result.general_settings.video_filters.select_bit_depth (result.codec_settings.pixel_format.ten_bit_selected);
        set_general (result.builder_settings, result.general_settings);
        return result;
    }

    public static bool changed (BulkConversionSettings baseline, BulkConversionSettings current) {
        var changes = new HashTable<string, bool> (str_hash, str_equal);
        record_changes (baseline, current, changes);
        return current.edited_fields.size () > 0 || changes.size () > 0
            || baseline.timing.seek_enabled != current.timing.seek_enabled
            || baseline.timing.seek_hours != current.timing.seek_hours
            || baseline.timing.seek_minutes != current.timing.seek_minutes
            || baseline.timing.seek_seconds != current.timing.seek_seconds
            || baseline.timing.time_enabled != current.timing.time_enabled
            || baseline.timing.time_hours != current.timing.time_hours
            || baseline.timing.time_minutes != current.timing.time_minutes
            || baseline.timing.time_seconds != current.timing.time_seconds;
    }
}
