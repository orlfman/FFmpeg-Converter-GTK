using Gtk;

// GTK adapters for the shared, data-only Smart Optimizer recommendation policy.
// Keep value decisions in SmartCodecResolver; these methods only reset and
// populate widgets so ordinary conversions use the same profile as queued jobs.
public class CodecPresets : Object {

    public static void set_dropdown_by_label (DropDown dropdown, string label) {
        var model = dropdown.get_model ();
        if (model == null) return;
        uint n = model.get_n_items ();
        for (uint i = 0; i < n; i++) {
            var item = model.get_item (i) as StringObject;
            if (item != null && item.string == label) {
                dropdown.set_selected (i);
                return;
            }
        }
    }

    /** Recommendations may carry an exact numeric GOP absent from stock rows. */
    private static void set_keyframe_value (DropDown dropdown, string value) {
        int numeric_value;
        if (!int.try_parse (value, out numeric_value) || numeric_value <= 0) {
            set_dropdown_by_label (dropdown, value);
            return;
        }
        var model = dropdown.get_model () as StringList;
        if (model == null) return;
        for (uint i = 0; i < model.get_n_items (); i++) {
            if (model.get_string (i) == value) {
                dropdown.set_selected (i);
                return;
            }
        }
        model.append (value);
        dropdown.set_selected (model.get_n_items () - 1);
    }

    private static bool has_audio_copy_choice (AudioSettings audio) {
        var model = audio.codec_combo.get_model () as StringList;
        if (model == null) return false;
        for (uint i = 0; i < model.get_n_items (); i++) {
            if (model.get_string (i) == AudioCodecName.COPY)
                return true;
        }
        return false;
    }

    /** Called after reset_defaults(), while the audio override scope is held. */
    private static SmartCodecResolution? resolve_for_tab (
        string codec,
        BaseCodecTab tab,
        OptimizationRecommendation rec,
        string requested_container) {
        // The public per-codec appliers historically use their target tab,
        // even when a caller reuses a recommendation struct from another tab.
        OptimizationRecommendation normalized = rec;
        normalized.codec = codec;
        var requested = tab.snapshot_settings ();
        requested.container = requested_container;
        SmartCodecResolution? resolution = SmartCodecResolver.resolve (normalized, requested);
        if (resolution == null) return null;

        set_dropdown_by_label (tab.container_combo, resolution.codec_settings.container);
        // Container selection rebuilds the available audio-codec choices. The
        // final decision must use the same Copy availability as the live tab,
        // including General audio-speed constraints that survive a reset.
        return SmartCodecResolver.resolve (
            normalized, requested, null, has_audio_copy_choice (tab.audio_settings));
    }

    private static void apply_audio (
        BaseCodecTab tab,
        SmartCodecResolution resolution,
        bool requested_keep_all_audio) {
        AudioSettingsSnapshot audio = resolution.codec_settings.audio_settings;
        // The widget remains enabled for a recommendation; source-audio
        // observations still authoritatively suppress output when it is absent.
        tab.audio_settings.set_audio_enabled (true);
        set_dropdown_by_label (tab.audio_settings.codec_combo, audio.codec);
        set_dropdown_by_label (tab.audio_settings.bitrate_combo,
            AudioCodecOptions.bitrate_label (audio.bitrate_kbps));
        tab.audio_settings.set_keep_all_audio_requested (requested_keep_all_audio);
        tab.audio_settings.set_smart_optimizer_preserve_all_override (
            audio.preserve_all_audio_tracks);
    }

    public static void apply_smart_x264 (X264Tab tab, OptimizationRecommendation rec) {
        string requested_container = tab.get_container ();
        bool requested_keep_all_audio = tab.audio_settings.get_keep_all_audio_requested ();
        tab.audio_settings.begin_smart_optimizer_override_application ();
        try {
            tab.reset_defaults ();
            SmartCodecResolution? resolution = resolve_for_tab (
                "x264", tab, rec, requested_container);
            if (resolution == null) return;
            var settings = resolution.builder_settings as X264BuilderSnapshot;
            assert (settings != null);
            set_dropdown_by_label (tab.preset_combo, settings.preset);
            set_dropdown_by_label (tab.profile_combo, settings.profile);
            tab.apply_recommended_pixel_format (rec.recommended_pix_fmt);
            set_dropdown_by_label (tab.rc_mode_combo, settings.rc_mode);
            tab.crf_spin.set_value (settings.crf);
            tab.qp_spin.set_value (settings.qp);
            tab.abr_bitrate_spin.set_value (settings.abr_bitrate_kbps);
            tab.cbr_bitrate_spin.set_value (settings.cbr_bitrate_kbps);
            set_dropdown_by_label (tab.tune_combo, settings.tune);
            set_dropdown_by_label (tab.level_combo, settings.level);
            set_dropdown_by_label (tab.ref_frames_combo, settings.ref_frames);
            tab.bframes_spin.set_value (settings.bframes);
            tab.b_adapt_combo.set_selected ((uint) settings.b_adapt);
            tab.weightp_switch.set_active (settings.weightp);
            tab.deblock_expander.set_enable_expansion (settings.deblock_enabled);
            tab.deblock_alpha_spin.set_value (settings.deblock_alpha);
            tab.deblock_beta_spin.set_value (settings.deblock_beta);
            set_dropdown_by_label (tab.me_combo, settings.me);
            tab.me_range_spin.set_value (settings.me_range);
            tab.subme_combo.set_selected ((uint) settings.subme);
            tab.psy_rd_expander.set_enable_expansion (settings.psy_rd_enabled);
            tab.psy_rd_spin.set_value (settings.psy_rd);
            tab.psy_trellis_spin.set_value (settings.psy_trellis);
            tab.cabac_switch.set_active (settings.cabac);
            tab.mbtree_switch.set_active (settings.mbtree);
            tab.lookahead_expander.set_enable_expansion (settings.lookahead_enabled);
            tab.lookahead_spin.set_value (settings.lookahead);
            set_dropdown_by_label (tab.aq_mode_combo, settings.aq_mode);
            tab.aq_strength_spin.set_value (settings.aq_strength);
            tab.abr_vbv_switch.set_active (settings.abr_vbv);
            tab.open_gop_switch.set_active (settings.open_gop);
            set_dropdown_by_label (tab.threads_combo, settings.threads);
            tab.two_pass_switch.set_active (resolution.two_pass);
            set_keyframe_value (tab.keyint_combo, settings.keyint_text);
            tab.custom_keyframe_combo.set_selected (
                (uint) resolution.codec_settings.keyframe_settings.custom_mode);
            apply_audio (tab, resolution, requested_keep_all_audio);
        } finally {
            tab.audio_settings.end_smart_optimizer_override_application ();
        }
    }

    public static void apply_smart_x265 (X265Tab tab, OptimizationRecommendation rec) {
        string requested_container = tab.get_container ();
        bool requested_keep_all_audio = tab.audio_settings.get_keep_all_audio_requested ();
        tab.audio_settings.begin_smart_optimizer_override_application ();
        try {
            tab.reset_defaults ();
            SmartCodecResolution? resolution = resolve_for_tab (
                "x265", tab, rec, requested_container);
            if (resolution == null) return;
            var settings = resolution.builder_settings as X265BuilderSnapshot;
            assert (settings != null);
            set_dropdown_by_label (tab.preset_combo, settings.preset);
            set_dropdown_by_label (tab.profile_combo, settings.profile);
            tab.apply_recommended_pixel_format (rec.recommended_pix_fmt);
            set_dropdown_by_label (tab.rc_mode_combo, settings.rc_mode);
            tab.crf_spin.set_value (settings.crf);
            tab.qp_spin.set_value (settings.qp);
            tab.abr_bitrate_spin.set_value (settings.abr_bitrate_kbps);
            tab.cbr_bitrate_spin.set_value (settings.cbr_bitrate_kbps);
            set_dropdown_by_label (tab.tune_combo, settings.tune);
            set_dropdown_by_label (tab.level_combo, settings.level);
            tab.sao_switch.set_active (settings.sao);
            set_dropdown_by_label (tab.ref_frames_combo, settings.ref_frames);
            tab.weightp_switch.set_active (settings.weightp);
            tab.deblock_expander.set_enable_expansion (settings.deblock_enabled);
            tab.deblock_alpha_spin.set_value (settings.deblock_alpha);
            tab.deblock_beta_spin.set_value (settings.deblock_beta);
            tab.pmode_switch.set_active (settings.pmode);
            tab.psy_rd_expander.set_enable_expansion (settings.psy_rd_enabled);
            tab.psy_rd_spin.set_value (settings.psy_rd);
            tab.cutree_switch.set_active (settings.cutree);
            tab.lookahead_expander.set_enable_expansion (settings.lookahead_enabled);
            tab.lookahead_spin.set_value (settings.lookahead);
            set_dropdown_by_label (tab.aq_mode_combo, settings.aq_mode);
            tab.aq_strength_spin.set_value (settings.aq_strength);
            tab.abr_vbv_switch.set_active (settings.abr_vbv);
            set_dropdown_by_label (tab.threads_combo, settings.threads);
            set_dropdown_by_label (tab.frame_threads_combo, settings.frame_threads);
            tab.two_pass_switch.set_active (resolution.two_pass);
            set_keyframe_value (tab.keyint_combo, settings.keyint_text);
            tab.custom_keyframe_combo.set_selected (
                (uint) resolution.codec_settings.keyframe_settings.custom_mode);
            apply_audio (tab, resolution, requested_keep_all_audio);
        } finally {
            tab.audio_settings.end_smart_optimizer_override_application ();
        }
    }

    public static void apply_smart_vp9 (Vp9Tab tab, OptimizationRecommendation rec) {
        string requested_container = tab.get_container ();
        bool requested_keep_all_audio = tab.audio_settings.get_keep_all_audio_requested ();
        tab.audio_settings.begin_smart_optimizer_override_application ();
        try {
            tab.reset_defaults ();
            SmartCodecResolution? resolution = resolve_for_tab (
                "vp9", tab, rec, requested_container);
            if (resolution == null) return;
            var settings = resolution.builder_settings as Vp9BuilderSnapshot;
            assert (settings != null);
            // Deadline first: it sets the Speed range the value is clamped to.
            set_dropdown_by_label (tab.quality_combo, settings.quality_deadline);
            tab.speed_spin.set_value (settings.speed);
            set_dropdown_by_label (tab.profile_combo, settings.profile);
            tab.apply_recommended_pixel_format (rec.recommended_pix_fmt);
            set_dropdown_by_label (tab.rc_mode_combo, settings.rc_mode);
            tab.crf_spin.set_value (settings.crf);
            tab.cq_level_spin.set_value (settings.cq_level);
            tab.cq_bitrate_spin.set_value (settings.cq_bitrate_kbps);
            tab.vbr_bitrate_spin.set_value (settings.vbr_bitrate_kbps);
            tab.cbr_bitrate_spin.set_value (settings.cbr_bitrate_kbps);
            set_dropdown_by_label (tab.tune_content_combo, settings.tune_content);
            set_dropdown_by_label (tab.aq_mode_combo, settings.aq_mode);
            tab.sharpness_expander.set_enable_expansion (settings.sharpness_enabled);
            tab.sharpness_spin.set_value (settings.sharpness);
            tab.lookahead_expander.set_enable_expansion (settings.lookahead_enabled);
            tab.lag_in_frames_spin.set_value (settings.lag_in_frames);
            tab.altref_expander.set_enable_expansion (settings.altref_enabled);
            tab.arnr_maxframes_spin.set_value (settings.arnr_maxframes);
            tab.arnr_strength_spin.set_value (settings.arnr_strength);
            tab.row_mt_switch.set_active (settings.row_mt);
            tab.frame_parallel_switch.set_active (settings.frame_parallel);
            tab.undershoot_expander.set_enable_expansion (settings.undershoot_enabled);
            tab.undershoot_spin.set_value (settings.undershoot);
            tab.overshoot_spin.set_value (settings.overshoot);
            set_dropdown_by_label (tab.tile_columns_combo, settings.tile_columns);
            set_dropdown_by_label (tab.tile_rows_combo, settings.tile_rows);
            set_dropdown_by_label (tab.threads_combo, settings.threads);
            tab.two_pass_switch.set_active (resolution.two_pass);
            set_keyframe_value (tab.keyint_combo, settings.keyint_text);
            tab.custom_keyframe_combo.set_selected (
                (uint) resolution.codec_settings.keyframe_settings.custom_mode);
            apply_audio (tab, resolution, requested_keep_all_audio);
        } finally {
            tab.audio_settings.end_smart_optimizer_override_application ();
        }
    }

    public static void apply_smart_svt_av1 (SvtAv1Tab tab, OptimizationRecommendation rec) {
        string requested_container = tab.get_container ();
        bool requested_keep_all_audio = tab.audio_settings.get_keep_all_audio_requested ();
        tab.audio_settings.begin_smart_optimizer_override_application ();
        try {
            tab.reset_defaults ();
            SmartCodecResolution? resolution = resolve_for_tab (
                "svt-av1", tab, rec, requested_container);
            if (resolution == null) return;
            var settings = resolution.builder_settings as SvtAv1BuilderSnapshot;
            assert (settings != null);
            tab.preset_spin.set_value (settings.preset);
            set_dropdown_by_label (tab.rc_mode_combo, settings.rc_mode);
            tab.crf_spin.set_value (settings.crf);
            tab.qp_spin.set_value (settings.qp);
            tab.vbr_bitrate_spin.set_value (settings.vbr_bitrate_kbps);
            tab.mbr_expander.set_enable_expansion (settings.mbr_enabled);
            tab.mbr_bitrate_spin.set_value (settings.mbr_bitrate_kbps);
            set_dropdown_by_label (tab.level_combo, settings.level);
            tab.tune_combo.set_selected ((uint) settings.tune_selected);
            tab.lookahead_expander.set_enable_expansion (settings.lookahead_enabled);
            tab.lookahead_spin.set_value (settings.lookahead);
            set_dropdown_by_label (tab.aq_mode_combo, settings.aq_mode);
            tab.aq_strength_spin.set_value (settings.aq_strength);
            tab.grain_expander.set_enable_expansion (settings.grain_enabled);
            tab.grain_strength_spin.set_value (settings.grain_strength);
            tab.grain_denoise_combo.set_selected ((uint) settings.grain_denoise_selected);
            tab.cdef_switch.set_active (settings.cdef);
            tab.restoration_switch.set_active (settings.restoration);
            tab.dlf_switch.set_active (settings.dlf);
            tab.tf_switch.set_active (settings.tf);
            tab.tpl_switch.set_active (settings.tpl);
            tab.low_latency_switch.set_active (settings.low_latency);
            tab.superres_expander.set_enable_expansion (settings.superres_enabled);
            tab.superres_mode_combo.set_selected ((uint) settings.superres_mode_selected);
            tab.superres_denom_spin.set_value (settings.superres_denom);
            tab.sharpness_expander.set_enable_expansion (settings.sharpness_enabled);
            tab.sharpness_spin.set_value (settings.sharpness);
            set_dropdown_by_label (tab.scm_combo, settings.scm);
            set_dropdown_by_label (tab.fast_decode_combo, settings.fast_decode);
            tab.qm_expander.set_enable_expansion (settings.qm_enabled);
            tab.qm_min_spin.set_value (settings.qm_min);
            tab.qm_max_spin.set_value (settings.qm_max);
            set_dropdown_by_label (tab.tile_rows_combo, settings.tile_rows);
            set_dropdown_by_label (tab.tile_columns_combo, settings.tile_columns);
            set_dropdown_by_label (tab.threads_combo, settings.threads);
            tab.apply_recommended_pixel_format (rec.recommended_pix_fmt);
            tab.two_pass_switch.set_active (resolution.two_pass);
            set_keyframe_value (tab.keyint_combo, settings.keyint_text);
            tab.custom_keyframe_combo.set_selected (
                (uint) resolution.codec_settings.keyframe_settings.custom_mode);
            apply_audio (tab, resolution, requested_keep_all_audio);
        } finally {
            tab.audio_settings.end_smart_optimizer_override_application ();
        }
    }

}
