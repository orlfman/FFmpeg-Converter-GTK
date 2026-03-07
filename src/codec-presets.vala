using Gtk;

public class CodecPresets : Object {

    // ═════════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ═════════════════════════════════════════════════════════════════════════

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

    private static void configure_audio (AudioSettings audio,
                                         string codec_name,
                                         int bitrate_idx,
                                         int flac_level = -1) {
        audio.audio_expander.set_enable_expansion (true);
        set_dropdown_by_label (audio.codec_combo, codec_name);

        if (codec_name == AudioCodecName.FLAC && flac_level >= 0)
            audio.flac_compression_combo.set_selected ((uint) flac_level);
        else if (bitrate_idx >= 0)
            audio.bitrate_combo.set_selected ((uint) bitrate_idx);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SVT-AV1
    // ═════════════════════════════════════════════════════════════════════════

    public static void apply_svt_av1 (SvtAv1Tab tab, string preset) {
        if (preset == "Custom") return;
        tab.reset_defaults ();

        switch (preset) {

        case "Streaming":
            tab.preset_spin.set_value (10);
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (38);
            tab.container_combo.set_selected (0);
            tab.tune_combo.set_selected (0);
            tab.grain_expander.set_enable_expansion (false);
            tab.lookahead_expander.set_enable_expansion (false);
            tab.cdef_switch.set_active (true);
            tab.restoration_switch.set_active (true);
            tab.tf_switch.set_active (true);
            tab.dlf_switch.set_active (true);
            tab.tpl_switch.set_active (false);
            tab.low_latency_switch.set_active (true);
            tab.fast_decode_combo.set_selected (0);
            tab.scm_combo.set_selected (0);
            configure_audio (tab.audio_settings, AudioCodecName.OPUS, 1);
            break;

        case "Anime":
            tab.preset_spin.set_value (6);
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (28);
            tab.container_combo.set_selected (0);
            tab.tune_combo.set_selected (0);
            tab.grain_expander.set_enable_expansion (false);
            tab.lookahead_expander.set_enable_expansion (true);
            tab.lookahead_spin.set_value (120);
            tab.cdef_switch.set_active (true);
            tab.restoration_switch.set_active (true);
            tab.tf_switch.set_active (true);
            tab.dlf_switch.set_active (true);
            tab.tpl_switch.set_active (true);
            tab.low_latency_switch.set_active (false);
            tab.scm_combo.set_selected (0);
            configure_audio (tab.audio_settings, AudioCodecName.OPUS, 2);
            break;

        case "Low":
            tab.preset_spin.set_value (12);
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (42);
            tab.container_combo.set_selected (0);
            tab.tune_combo.set_selected (0);
            tab.grain_expander.set_enable_expansion (false);
            tab.lookahead_expander.set_enable_expansion (false);
            tab.cdef_switch.set_active (true);
            tab.restoration_switch.set_active (false);
            tab.tf_switch.set_active (true);
            tab.dlf_switch.set_active (true);
            tab.tpl_switch.set_active (false);
            tab.low_latency_switch.set_active (false);
            set_dropdown_by_label (tab.fast_decode_combo, "1");
            configure_audio (tab.audio_settings, AudioCodecName.OPUS, 0);
            break;

        case "Medium":
            tab.preset_spin.set_value (8);
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (35);
            tab.container_combo.set_selected (0);
            tab.tune_combo.set_selected (0);
            tab.grain_expander.set_enable_expansion (false);
            tab.lookahead_expander.set_enable_expansion (false);
            tab.cdef_switch.set_active (true);
            tab.restoration_switch.set_active (true);
            tab.tf_switch.set_active (true);
            tab.dlf_switch.set_active (true);
            tab.tpl_switch.set_active (true);
            tab.low_latency_switch.set_active (false);
            configure_audio (tab.audio_settings, AudioCodecName.OPUS, 1);
            break;

        case "High":
            tab.preset_spin.set_value (5);
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (26);
            tab.container_combo.set_selected (0);
            tab.tune_combo.set_selected (0);
            tab.grain_expander.set_enable_expansion (true);
            tab.grain_strength_spin.set_value (8);
            tab.lookahead_expander.set_enable_expansion (true);
            tab.lookahead_spin.set_value (120);
            tab.cdef_switch.set_active (true);
            tab.restoration_switch.set_active (true);
            tab.tf_switch.set_active (true);
            tab.dlf_switch.set_active (true);
            tab.tpl_switch.set_active (true);
            tab.low_latency_switch.set_active (false);
            configure_audio (tab.audio_settings, AudioCodecName.OPUS, 2);
            break;

        case "Very High":
            tab.preset_spin.set_value (3);
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (18);
            tab.container_combo.set_selected (0);
            tab.tune_combo.set_selected (0);
            tab.grain_expander.set_enable_expansion (true);
            tab.grain_strength_spin.set_value (15);
            tab.lookahead_expander.set_enable_expansion (true);
            tab.lookahead_spin.set_value (120);
            tab.cdef_switch.set_active (true);
            tab.restoration_switch.set_active (true);
            tab.tf_switch.set_active (true);
            tab.dlf_switch.set_active (true);
            tab.tpl_switch.set_active (true);
            tab.low_latency_switch.set_active (false);
            tab.qm_expander.set_enable_expansion (true);
            tab.qm_min_spin.set_value (8);
            tab.qm_max_spin.set_value (15);
            configure_audio (tab.audio_settings, AudioCodecName.FLAC, -1, 8);
            break;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  x265
    // ═════════════════════════════════════════════════════════════════════════

    public static void apply_x265 (X265Tab tab, string preset) {
        if (preset == "Custom") return;
        tab.reset_defaults ();

        switch (preset) {

        case "Streaming":
            set_dropdown_by_label (tab.preset_combo, "faster");
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (28);
            tab.container_combo.set_selected (1);
            set_dropdown_by_label (tab.tune_combo, "zerolatency");
            tab.sao_switch.set_active (true);
            tab.deblock_expander.set_enable_expansion (true);
            tab.deblock_alpha_spin.set_value (0);
            tab.deblock_beta_spin.set_value (0);
            tab.lookahead_expander.set_enable_expansion (false);
            tab.psy_rd_expander.set_enable_expansion (true);
            tab.psy_rd_spin.set_value (2.0);
            tab.cutree_switch.set_active (true);
            configure_audio (tab.audio_settings, AudioCodecName.AAC, 1);
            break;

        case "Anime":
            set_dropdown_by_label (tab.preset_combo, "medium");
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (22);
            tab.container_combo.set_selected (0);
            set_dropdown_by_label (tab.tune_combo, "animation");
            tab.sao_switch.set_active (true);
            set_dropdown_by_label (tab.ref_frames_combo, "4");
            tab.deblock_expander.set_enable_expansion (true);
            tab.deblock_alpha_spin.set_value (1);
            tab.deblock_beta_spin.set_value (1);
            tab.lookahead_expander.set_enable_expansion (true);
            tab.lookahead_spin.set_value (40);
            tab.psy_rd_expander.set_enable_expansion (true);
            tab.psy_rd_spin.set_value (0.5);
            tab.cutree_switch.set_active (true);
            configure_audio (tab.audio_settings, AudioCodecName.OPUS, 2);
            break;

        case "Low":
            set_dropdown_by_label (tab.preset_combo, "veryfast");
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (30);
            tab.container_combo.set_selected (0);
            tab.tune_combo.set_selected (0);
            tab.lookahead_expander.set_enable_expansion (false);
            tab.psy_rd_expander.set_enable_expansion (true);
            tab.psy_rd_spin.set_value (2.0);
            tab.cutree_switch.set_active (true);
            configure_audio (tab.audio_settings, AudioCodecName.OPUS, 0);
            break;

        case "Medium":
            set_dropdown_by_label (tab.preset_combo, "medium");
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (24);
            tab.container_combo.set_selected (0);
            tab.tune_combo.set_selected (0);
            tab.sao_switch.set_active (true);
            tab.deblock_expander.set_enable_expansion (true);
            tab.deblock_alpha_spin.set_value (0);
            tab.deblock_beta_spin.set_value (0);
            tab.lookahead_expander.set_enable_expansion (false);
            tab.psy_rd_expander.set_enable_expansion (true);
            tab.psy_rd_spin.set_value (2.0);
            tab.cutree_switch.set_active (true);
            configure_audio (tab.audio_settings, AudioCodecName.OPUS, 1);
            break;

        case "High":
            set_dropdown_by_label (tab.preset_combo, "slow");
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (20);
            tab.container_combo.set_selected (0);
            tab.tune_combo.set_selected (0);
            tab.sao_switch.set_active (true);
            set_dropdown_by_label (tab.ref_frames_combo, "4");
            tab.deblock_expander.set_enable_expansion (true);
            tab.deblock_alpha_spin.set_value (0);
            tab.deblock_beta_spin.set_value (0);
            tab.lookahead_expander.set_enable_expansion (true);
            tab.lookahead_spin.set_value (60);
            tab.psy_rd_expander.set_enable_expansion (true);
            tab.psy_rd_spin.set_value (2.0);
            tab.cutree_switch.set_active (true);
            tab.pmode_switch.set_active (true);
            configure_audio (tab.audio_settings, AudioCodecName.OPUS, 2);
            break;

        case "Very High":
            set_dropdown_by_label (tab.preset_combo, "veryslow");
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (17);
            tab.container_combo.set_selected (0);
            tab.tune_combo.set_selected (0);
            tab.sao_switch.set_active (true);
            set_dropdown_by_label (tab.ref_frames_combo, "5");
            tab.deblock_expander.set_enable_expansion (true);
            tab.deblock_alpha_spin.set_value (-1);
            tab.deblock_beta_spin.set_value (-1);
            tab.lookahead_expander.set_enable_expansion (true);
            tab.lookahead_spin.set_value (120);
            tab.psy_rd_expander.set_enable_expansion (true);
            tab.psy_rd_spin.set_value (2.0);
            tab.cutree_switch.set_active (true);
            tab.pmode_switch.set_active (true);
            tab.weightp_switch.set_active (true);
            configure_audio (tab.audio_settings, AudioCodecName.FLAC, -1, 8);
            break;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  x264
    // ═════════════════════════════════════════════════════════════════════════

    public static void apply_x264 (X264Tab tab, string preset) {
        if (preset == "Custom") return;
        tab.reset_defaults ();

        switch (preset) {

        case "Streaming":
            set_dropdown_by_label (tab.preset_combo, "veryfast");
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (23);
            tab.container_combo.set_selected (1);
            tab.profile_combo.set_selected (0);
            set_dropdown_by_label (tab.tune_combo, "zerolatency");
            tab.cabac_switch.set_active (true);
            tab.mbtree_switch.set_active (true);
            tab.deblock_expander.set_enable_expansion (true);
            tab.deblock_alpha_spin.set_value (0);
            tab.deblock_beta_spin.set_value (0);
            tab.lookahead_expander.set_enable_expansion (false);
            configure_audio (tab.audio_settings, AudioCodecName.AAC, 1);
            break;

        case "Anime":
            set_dropdown_by_label (tab.preset_combo, "medium");
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (20);
            tab.container_combo.set_selected (0);
            tab.profile_combo.set_selected (0);
            set_dropdown_by_label (tab.tune_combo, "animation");
            set_dropdown_by_label (tab.ref_frames_combo, "4");
            tab.bframes_spin.set_value (5);
            set_dropdown_by_label (tab.b_adapt_combo, "Optimal");
            tab.cabac_switch.set_active (true);
            tab.deblock_expander.set_enable_expansion (true);
            tab.deblock_alpha_spin.set_value (1);
            tab.deblock_beta_spin.set_value (1);
            tab.psy_rd_expander.set_enable_expansion (true);
            tab.psy_rd_spin.set_value (0.4);
            tab.psy_trellis_spin.set_value (0.0);
            tab.lookahead_expander.set_enable_expansion (true);
            tab.lookahead_spin.set_value (60);
            configure_audio (tab.audio_settings, AudioCodecName.OPUS, 2);
            break;

        case "Low":
            set_dropdown_by_label (tab.preset_combo, "ultrafast");
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (28);
            tab.container_combo.set_selected (0);
            tab.profile_combo.set_selected (0);
            tab.tune_combo.set_selected (0);
            tab.cabac_switch.set_active (false);
            set_dropdown_by_label (tab.me_combo, "dia");
            tab.subme_combo.set_selected (1);
            tab.bframes_spin.set_value (0);
            tab.mbtree_switch.set_active (false);
            tab.lookahead_expander.set_enable_expansion (false);
            configure_audio (tab.audio_settings, AudioCodecName.OPUS, 0);
            break;

        case "Medium":
            set_dropdown_by_label (tab.preset_combo, "medium");
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (21);
            tab.container_combo.set_selected (0);
            tab.profile_combo.set_selected (0);
            tab.tune_combo.set_selected (0);
            set_dropdown_by_label (tab.ref_frames_combo, "3");
            tab.bframes_spin.set_value (3);
            tab.cabac_switch.set_active (true);
            set_dropdown_by_label (tab.me_combo, "hex");
            tab.subme_combo.set_selected (7);
            tab.mbtree_switch.set_active (true);
            tab.deblock_expander.set_enable_expansion (true);
            tab.deblock_alpha_spin.set_value (0);
            tab.deblock_beta_spin.set_value (0);
            tab.psy_rd_expander.set_enable_expansion (true);
            tab.psy_rd_spin.set_value (1.0);
            tab.psy_trellis_spin.set_value (0.0);
            configure_audio (tab.audio_settings, AudioCodecName.OPUS, 1);
            break;

        case "High":
            set_dropdown_by_label (tab.preset_combo, "slow");
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (18);
            tab.container_combo.set_selected (0);
            set_dropdown_by_label (tab.profile_combo, "High");
            tab.tune_combo.set_selected (0);
            set_dropdown_by_label (tab.ref_frames_combo, "5");
            tab.bframes_spin.set_value (5);
            set_dropdown_by_label (tab.b_adapt_combo, "Optimal");
            tab.cabac_switch.set_active (true);
            set_dropdown_by_label (tab.me_combo, "umh");
            tab.subme_combo.set_selected (9);
            tab.me_range_spin.set_value (24);
            tab.mbtree_switch.set_active (true);
            tab.deblock_expander.set_enable_expansion (true);
            tab.deblock_alpha_spin.set_value (0);
            tab.deblock_beta_spin.set_value (0);
            tab.psy_rd_expander.set_enable_expansion (true);
            tab.psy_rd_spin.set_value (1.0);
            tab.psy_trellis_spin.set_value (0.15);
            tab.lookahead_expander.set_enable_expansion (true);
            tab.lookahead_spin.set_value (60);
            tab.weightp_switch.set_active (true);
            configure_audio (tab.audio_settings, AudioCodecName.OPUS, 2);
            break;

        case "Very High":
            set_dropdown_by_label (tab.preset_combo, "veryslow");
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (16);
            tab.container_combo.set_selected (0);
            set_dropdown_by_label (tab.profile_combo, "High");
            tab.tune_combo.set_selected (0);
            set_dropdown_by_label (tab.ref_frames_combo, "8");
            tab.bframes_spin.set_value (8);
            set_dropdown_by_label (tab.b_adapt_combo, "Optimal");
            tab.cabac_switch.set_active (true);
            set_dropdown_by_label (tab.me_combo, "umh");
            tab.subme_combo.set_selected (10);
            tab.me_range_spin.set_value (32);
            tab.mbtree_switch.set_active (true);
            tab.deblock_expander.set_enable_expansion (true);
            tab.deblock_alpha_spin.set_value (-1);
            tab.deblock_beta_spin.set_value (-1);
            tab.psy_rd_expander.set_enable_expansion (true);
            tab.psy_rd_spin.set_value (1.0);
            tab.psy_trellis_spin.set_value (0.25);
            tab.lookahead_expander.set_enable_expansion (true);
            tab.lookahead_spin.set_value (120);
            tab.weightp_switch.set_active (true);
            configure_audio (tab.audio_settings, AudioCodecName.FLAC, -1, 8);
            break;

        case "Imageboards":
            set_dropdown_by_label (tab.preset_combo, "medium");
            tab.rc_mode_combo.set_selected (2);       // ABR
            tab.abr_bitrate_spin.set_value (700);
            tab.container_combo.set_selected (1);
            set_dropdown_by_label (tab.profile_combo, "High");
            tab.tune_combo.set_selected (0);
            tab.two_pass_switch.set_active (true);
            set_dropdown_by_label (tab.ref_frames_combo, "3");
            tab.bframes_spin.set_value (3);
            tab.cabac_switch.set_active (true);
            set_dropdown_by_label (tab.me_combo, "hex");
            tab.subme_combo.set_selected (7);
            tab.mbtree_switch.set_active (true);
            tab.deblock_expander.set_enable_expansion (true);
            tab.deblock_alpha_spin.set_value (0);
            tab.deblock_beta_spin.set_value (0);
            tab.psy_rd_expander.set_enable_expansion (true);
            tab.psy_rd_spin.set_value (1.0);
            tab.psy_trellis_spin.set_value (0.0);
            tab.lookahead_expander.set_enable_expansion (true);
            tab.lookahead_spin.set_value (40);
            configure_audio (tab.audio_settings, AudioCodecName.AAC, 0);
            break;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  VP9
    // ═════════════════════════════════════════════════════════════════════════

    public static void apply_vp9 (Vp9Tab tab, string preset) {
        if (preset == "Custom") return;
        tab.reset_defaults ();

        switch (preset) {

        case "Streaming":
            tab.speed_spin.set_value (6);
            set_dropdown_by_label (tab.quality_combo, "good");
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (36);
            tab.container_combo.set_selected (0);
            tab.tune_content_combo.set_selected (0);
            tab.aq_mode_combo.set_selected (0);
            tab.altref_expander.set_enable_expansion (false);
            tab.lookahead_expander.set_enable_expansion (false);
            tab.row_mt_switch.set_active (true);
            set_dropdown_by_label (tab.tile_columns_combo, "2");
            tab.frame_parallel_switch.set_active (true);
            configure_audio (tab.audio_settings, AudioCodecName.OPUS, 1);
            break;

        case "Anime":
            tab.speed_spin.set_value (4);
            set_dropdown_by_label (tab.quality_combo, "good");
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (28);
            tab.container_combo.set_selected (1);
            tab.tune_content_combo.set_selected (0);
            tab.aq_mode_combo.set_selected (0);
            tab.altref_expander.set_enable_expansion (true);
            tab.arnr_maxframes_spin.set_value (7);
            tab.arnr_strength_spin.set_value (5);
            tab.lookahead_expander.set_enable_expansion (true);
            tab.lag_in_frames_spin.set_value (25);
            tab.row_mt_switch.set_active (true);
            tab.frame_parallel_switch.set_active (false);
            configure_audio (tab.audio_settings, AudioCodecName.OPUS, 2);
            break;

        case "Low":
            tab.speed_spin.set_value (8);
            set_dropdown_by_label (tab.quality_combo, "realtime");
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (42);
            tab.container_combo.set_selected (0);
            tab.tune_content_combo.set_selected (0);
            tab.altref_expander.set_enable_expansion (false);
            tab.lookahead_expander.set_enable_expansion (false);
            tab.row_mt_switch.set_active (true);
            set_dropdown_by_label (tab.tile_columns_combo, "2");
            tab.frame_parallel_switch.set_active (true);
            configure_audio (tab.audio_settings, AudioCodecName.OPUS, 0);
            break;

        case "Medium":
            tab.speed_spin.set_value (4);
            set_dropdown_by_label (tab.quality_combo, "good");
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (31);
            tab.container_combo.set_selected (0);
            tab.tune_content_combo.set_selected (0);
            tab.altref_expander.set_enable_expansion (true);
            tab.arnr_maxframes_spin.set_value (7);
            tab.arnr_strength_spin.set_value (5);
            tab.lookahead_expander.set_enable_expansion (false);
            tab.row_mt_switch.set_active (true);
            tab.frame_parallel_switch.set_active (false);
            configure_audio (tab.audio_settings, AudioCodecName.OPUS, 1);
            break;

        case "High":
            tab.speed_spin.set_value (2);
            set_dropdown_by_label (tab.quality_combo, "good");
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (24);
            tab.container_combo.set_selected (1);
            tab.tune_content_combo.set_selected (0);
            set_dropdown_by_label (tab.aq_mode_combo, "Complexity");
            tab.altref_expander.set_enable_expansion (true);
            tab.arnr_maxframes_spin.set_value (7);
            tab.arnr_strength_spin.set_value (5);
            tab.lookahead_expander.set_enable_expansion (true);
            tab.lag_in_frames_spin.set_value (25);
            tab.row_mt_switch.set_active (true);
            tab.frame_parallel_switch.set_active (false);
            configure_audio (tab.audio_settings, AudioCodecName.OPUS, 2);
            break;

        case "Very High":
            tab.speed_spin.set_value (0);
            set_dropdown_by_label (tab.quality_combo, "best");
            tab.rc_mode_combo.set_selected (0);
            tab.crf_spin.set_value (15);
            tab.container_combo.set_selected (1);
            tab.tune_content_combo.set_selected (0);
            set_dropdown_by_label (tab.aq_mode_combo, "Complexity");
            tab.altref_expander.set_enable_expansion (true);
            tab.arnr_maxframes_spin.set_value (7);
            tab.arnr_strength_spin.set_value (5);
            tab.lookahead_expander.set_enable_expansion (true);
            tab.lag_in_frames_spin.set_value (25);
            tab.row_mt_switch.set_active (true);
            tab.frame_parallel_switch.set_active (false);
            configure_audio (tab.audio_settings, AudioCodecName.FLAC, -1, 8);
            break;

        case "Imageboards":
            tab.speed_spin.set_value (4);
            set_dropdown_by_label (tab.quality_combo, "good");
            tab.rc_mode_combo.set_selected (1);       // Constrained Quality
            tab.cq_level_spin.set_value (35);
            tab.cq_bitrate_spin.set_value (700);
            tab.container_combo.set_selected (0);
            tab.tune_content_combo.set_selected (0);
            tab.two_pass_switch.set_active (true);
            tab.altref_expander.set_enable_expansion (true);
            tab.arnr_maxframes_spin.set_value (7);
            tab.arnr_strength_spin.set_value (5);
            tab.lookahead_expander.set_enable_expansion (true);
            tab.lag_in_frames_spin.set_value (25);
            tab.row_mt_switch.set_active (true);
            tab.frame_parallel_switch.set_active (false);
            configure_audio (tab.audio_settings, AudioCodecName.OPUS, 0);
            break;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SMART OPTIMIZER — TIER-AWARE AUDIO HELPER
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Configure audio for a Smart Optimizer preset based on size tier.
     * Bitrate combo indices: 0=64, 1=128, 2=192, 3=256, 4=320 kbps.
     */
    private static void configure_smart_audio (AudioSettings audio,
                                                SizeTier tier,
                                                string container) {
        bool is_webm = (container == "webm");
        switch (tier) {
            case SizeTier.TINY:
                configure_audio (audio,
                    is_webm ? AudioCodecName.OPUS : AudioCodecName.AAC, 0);
                break;
            case SizeTier.SMALL:
                configure_audio (audio, AudioCodecName.OPUS, 1);
                break;
            case SizeTier.MEDIUM:
                configure_audio (audio, AudioCodecName.OPUS, 2);
                break;
            case SizeTier.LARGE:
                configure_audio (audio, AudioCodecName.OPUS, 3);
                break;
            case SizeTier.XLARGE:
                configure_audio (audio, AudioCodecName.FLAC, -1, 8);
                break;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SMART OPTIMIZER → x264
    // ═════════════════════════════════════════════════════════════════════════

    public static void apply_smart_x264 (X264Tab tab, OptimizationRecommendation rec) {
        tab.reset_defaults ();
        SizeTier tier = rec.size_tier;

        // Container — mp4 for tiny (imageboard compat), mkv otherwise
        if (tier == SizeTier.TINY) {
            tab.container_combo.set_selected (1);   // mp4
        } else {
            tab.container_combo.set_selected (0);   // mkv
        }
        set_dropdown_by_label (tab.profile_combo, "High");

        // Preset
        set_dropdown_by_label (tab.preset_combo, rec.preset);

        // Rate control
        if (rec.two_pass && rec.target_bitrate_kbps > 0) {
            tab.rc_mode_combo.set_selected (2);   // ABR
            tab.abr_bitrate_spin.set_value (rec.target_bitrate_kbps);
            tab.two_pass_switch.set_active (true);
        } else {
            tab.rc_mode_combo.set_selected (0);   // CRF
            tab.crf_spin.set_value (rec.crf);
        }

        // Content-aware tune
        switch (rec.content_type) {
            case ContentType.ANIME:
                set_dropdown_by_label (tab.tune_combo, "animation");
                break;
            case ContentType.SCREENCAST:
                set_dropdown_by_label (tab.tune_combo, "stillimage");
                break;
            default:
                tab.tune_combo.set_selected (0);
                break;
        }

        // ── Tier-scaled encoder features ─────────────────────────────────
        tab.cabac_switch.set_active (true);
        tab.mbtree_switch.set_active (true);
        tab.weightp_switch.set_active (true);
        tab.deblock_expander.set_enable_expansion (true);
        tab.psy_rd_expander.set_enable_expansion (true);

        switch (tier) {
            case SizeTier.TINY:
                set_dropdown_by_label (tab.ref_frames_combo, "3");
                tab.bframes_spin.set_value (3);
                set_dropdown_by_label (tab.b_adapt_combo, "Optimal");
                set_dropdown_by_label (tab.me_combo, "hex");
                tab.subme_combo.set_selected (7);
                tab.me_range_spin.set_value (16);
                tab.deblock_alpha_spin.set_value (0);
                tab.deblock_beta_spin.set_value (0);
                tab.psy_rd_spin.set_value (1.0);
                tab.psy_trellis_spin.set_value (0.0);
                tab.lookahead_expander.set_enable_expansion (true);
                tab.lookahead_spin.set_value (40);
                tab.open_gop_switch.set_active (false);
                break;

            case SizeTier.SMALL:
                set_dropdown_by_label (tab.ref_frames_combo, "4");
                tab.bframes_spin.set_value (4);
                set_dropdown_by_label (tab.b_adapt_combo, "Optimal");
                set_dropdown_by_label (tab.me_combo, "hex");
                tab.subme_combo.set_selected (8);
                tab.me_range_spin.set_value (16);
                tab.deblock_alpha_spin.set_value (0);
                tab.deblock_beta_spin.set_value (0);
                tab.psy_rd_spin.set_value (1.0);
                tab.psy_trellis_spin.set_value (0.1);
                tab.lookahead_expander.set_enable_expansion (true);
                tab.lookahead_spin.set_value (50);
                tab.open_gop_switch.set_active (false);
                break;

            case SizeTier.MEDIUM:
                set_dropdown_by_label (tab.ref_frames_combo, "5");
                tab.bframes_spin.set_value (5);
                set_dropdown_by_label (tab.b_adapt_combo, "Optimal");
                set_dropdown_by_label (tab.me_combo, "umh");
                tab.subme_combo.set_selected (9);
                tab.me_range_spin.set_value (24);
                tab.deblock_alpha_spin.set_value (0);
                tab.deblock_beta_spin.set_value (0);
                tab.psy_rd_spin.set_value (1.0);
                tab.psy_trellis_spin.set_value (0.15);
                tab.lookahead_expander.set_enable_expansion (true);
                tab.lookahead_spin.set_value (60);
                tab.open_gop_switch.set_active (false);
                break;

            case SizeTier.LARGE:
                set_dropdown_by_label (tab.ref_frames_combo, "6");
                tab.bframes_spin.set_value (6);
                set_dropdown_by_label (tab.b_adapt_combo, "Optimal");
                set_dropdown_by_label (tab.me_combo, "umh");
                tab.subme_combo.set_selected (10);
                tab.me_range_spin.set_value (32);
                tab.deblock_alpha_spin.set_value (-1);
                tab.deblock_beta_spin.set_value (-1);
                tab.psy_rd_spin.set_value (1.0);
                tab.psy_trellis_spin.set_value (0.2);
                tab.lookahead_expander.set_enable_expansion (true);
                tab.lookahead_spin.set_value (80);
                tab.open_gop_switch.set_active (true);
                break;

            case SizeTier.XLARGE:
                set_dropdown_by_label (tab.ref_frames_combo, "8");
                tab.bframes_spin.set_value (8);
                set_dropdown_by_label (tab.b_adapt_combo, "Optimal");
                set_dropdown_by_label (tab.me_combo, "umh");
                tab.subme_combo.set_selected (11);
                tab.me_range_spin.set_value (32);
                tab.deblock_alpha_spin.set_value (-1);
                tab.deblock_beta_spin.set_value (-1);
                tab.psy_rd_spin.set_value (1.0);
                tab.psy_trellis_spin.set_value (0.25);
                tab.lookahead_expander.set_enable_expansion (true);
                tab.lookahead_spin.set_value (120);
                tab.open_gop_switch.set_active (true);
                break;
        }

        // Audio
        string container = (tier == SizeTier.TINY) ? "mp4" : "mkv";
        configure_smart_audio (tab.audio_settings, tier, container);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SMART OPTIMIZER → VP9
    // ═════════════════════════════════════════════════════════════════════════

    public static void apply_smart_vp9 (Vp9Tab tab, OptimizationRecommendation rec) {
        tab.reset_defaults ();
        SizeTier tier = rec.size_tier;

        // Container — webm for tiny, mkv for larger (broader audio support)
        if (tier == SizeTier.TINY) {
            tab.container_combo.set_selected (0);   // webm
        } else {
            tab.container_combo.set_selected (1);   // mkv
        }

        // Speed
        string speed_str = rec.preset.replace ("cpu-used ", "");
        int speed_val = int.parse (speed_str);
        tab.speed_spin.set_value (speed_val);

        // Quality deadline — "good" provides excellent quality at all tiers;
        // "best" is prohibitively slow with negligible visual gain.
        set_dropdown_by_label (tab.quality_combo, "good");

        // Rate control
        if (rec.two_pass && rec.target_bitrate_kbps > 0) {
            tab.rc_mode_combo.set_selected (1);   // Constrained Quality
            tab.cq_level_spin.set_value (rec.crf);
            tab.cq_bitrate_spin.set_value (rec.target_bitrate_kbps);
            tab.two_pass_switch.set_active (true);
        } else {
            tab.rc_mode_combo.set_selected (0);   // CRF
            tab.crf_spin.set_value (rec.crf);
        }

        // Content-aware tuning
        if (rec.content_type == ContentType.SCREENCAST) {
            set_dropdown_by_label (tab.tune_content_combo, "Screen");
        } else {
            tab.tune_content_combo.set_selected (0);
        }

        // ── Tier-scaled encoder features ─────────────────────────────────
        tab.row_mt_switch.set_active (true);
        tab.frame_parallel_switch.set_active (false);
        tab.lookahead_expander.set_enable_expansion (true);
        tab.lag_in_frames_spin.set_value (25);   // VP9 max is 25

        switch (tier) {
            case SizeTier.TINY:
                tab.altref_expander.set_enable_expansion (true);
                tab.arnr_maxframes_spin.set_value (7);
                tab.arnr_strength_spin.set_value (5);
                tab.aq_mode_combo.set_selected (0);
                break;

            case SizeTier.SMALL:
                tab.altref_expander.set_enable_expansion (true);
                tab.arnr_maxframes_spin.set_value (7);
                tab.arnr_strength_spin.set_value (5);
                set_dropdown_by_label (tab.aq_mode_combo, "Complexity");
                break;

            case SizeTier.MEDIUM:
                tab.altref_expander.set_enable_expansion (true);
                tab.arnr_maxframes_spin.set_value (9);
                tab.arnr_strength_spin.set_value (6);
                set_dropdown_by_label (tab.aq_mode_combo, "Complexity");
                break;

            case SizeTier.LARGE:
                tab.altref_expander.set_enable_expansion (true);
                tab.arnr_maxframes_spin.set_value (12);
                tab.arnr_strength_spin.set_value (6);
                set_dropdown_by_label (tab.aq_mode_combo, "Complexity");
                break;

            case SizeTier.XLARGE:
                tab.altref_expander.set_enable_expansion (true);
                tab.arnr_maxframes_spin.set_value (15);
                tab.arnr_strength_spin.set_value (6);
                set_dropdown_by_label (tab.aq_mode_combo, "Complexity");
                break;
        }

        // Audio
        string container = (tier == SizeTier.TINY) ? "webm" : "mkv";
        configure_smart_audio (tab.audio_settings, tier, container);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SMART OPTIMIZER → x265
    // ═════════════════════════════════════════════════════════════════════════

    public static void apply_smart_x265 (X265Tab tab, OptimizationRecommendation rec) {
        tab.reset_defaults ();
        SizeTier tier = rec.size_tier;

        // Container — always mkv for x265
        tab.container_combo.set_selected (0);

        // Preset
        set_dropdown_by_label (tab.preset_combo, rec.preset);

        // Rate control
        if (rec.two_pass && rec.target_bitrate_kbps > 0) {
            tab.rc_mode_combo.set_selected (2);   // ABR
            tab.abr_bitrate_spin.set_value (rec.target_bitrate_kbps);
            tab.two_pass_switch.set_active (true);
        } else {
            tab.rc_mode_combo.set_selected (0);   // CRF
            tab.crf_spin.set_value (rec.crf);
        }

        // Content-aware tune
        if (rec.content_type == ContentType.ANIME) {
            set_dropdown_by_label (tab.tune_combo, "animation");
        } else if (tier >= SizeTier.LARGE
                   && (rec.content_type == ContentType.LIVE_ACTION
                       || rec.content_type == ContentType.MIXED)) {
            // At generous budgets, preserve natural film grain rather
            // than smearing it for compression — improves perceived quality
            set_dropdown_by_label (tab.tune_combo, "grain");
        } else {
            tab.tune_combo.set_selected (0);
        }

        // ── Tier-scaled encoder features ─────────────────────────────────
        tab.sao_switch.set_active (true);
        tab.deblock_expander.set_enable_expansion (true);
        tab.psy_rd_expander.set_enable_expansion (true);
        tab.cutree_switch.set_active (true);
        tab.weightp_switch.set_active (true);

        switch (tier) {
            case SizeTier.TINY:
                set_dropdown_by_label (tab.ref_frames_combo, "3");
                tab.deblock_alpha_spin.set_value (0);
                tab.deblock_beta_spin.set_value (0);
                tab.psy_rd_spin.set_value (2.0);
                tab.pmode_switch.set_active (false);
                tab.lookahead_expander.set_enable_expansion (true);
                tab.lookahead_spin.set_value (40);
                break;

            case SizeTier.SMALL:
                set_dropdown_by_label (tab.ref_frames_combo, "4");
                tab.deblock_alpha_spin.set_value (0);
                tab.deblock_beta_spin.set_value (0);
                tab.psy_rd_spin.set_value (2.0);
                tab.pmode_switch.set_active (false);
                tab.lookahead_expander.set_enable_expansion (true);
                tab.lookahead_spin.set_value (50);
                break;

            case SizeTier.MEDIUM:
                set_dropdown_by_label (tab.ref_frames_combo, "4");
                tab.deblock_alpha_spin.set_value (0);
                tab.deblock_beta_spin.set_value (0);
                tab.psy_rd_spin.set_value (2.5);
                tab.pmode_switch.set_active (true);
                tab.lookahead_expander.set_enable_expansion (true);
                tab.lookahead_spin.set_value (60);
                break;

            case SizeTier.LARGE:
                set_dropdown_by_label (tab.ref_frames_combo, "5");
                tab.deblock_alpha_spin.set_value (-1);
                tab.deblock_beta_spin.set_value (-1);
                tab.psy_rd_spin.set_value (3.0);
                tab.pmode_switch.set_active (true);
                tab.lookahead_expander.set_enable_expansion (true);
                tab.lookahead_spin.set_value (80);
                break;

            case SizeTier.XLARGE:
                set_dropdown_by_label (tab.ref_frames_combo, "5");
                tab.deblock_alpha_spin.set_value (-1);
                tab.deblock_beta_spin.set_value (-1);
                tab.psy_rd_spin.set_value (3.5);
                tab.pmode_switch.set_active (true);
                tab.lookahead_expander.set_enable_expansion (true);
                tab.lookahead_spin.set_value (120);
                break;
        }

        // Audio
        configure_smart_audio (tab.audio_settings, tier, "mkv");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SMART OPTIMIZER → SVT-AV1
    // ═════════════════════════════════════════════════════════════════════════

    public static void apply_smart_svt_av1 (SvtAv1Tab tab, OptimizationRecommendation rec) {
        tab.reset_defaults ();
        SizeTier tier = rec.size_tier;

        // Container — always mkv for AV1
        tab.container_combo.set_selected (0);

        // Preset
        string preset_str = rec.preset.replace ("preset ", "");
        int preset_val = int.parse (preset_str);
        tab.preset_spin.set_value (preset_val);

        // Rate control
        if (rec.two_pass && rec.target_bitrate_kbps > 0) {
            tab.rc_mode_combo.set_selected (2);   // VBR
            tab.vbr_bitrate_spin.set_value (rec.target_bitrate_kbps);
            tab.two_pass_switch.set_active (true);
        } else {
            tab.rc_mode_combo.set_selected (0);   // CRF
            tab.crf_spin.set_value (rec.crf);
        }

        // Content-aware screen content mode
        if (rec.content_type == ContentType.SCREENCAST) {
            set_dropdown_by_label (tab.scm_combo, "Auto-Detect");
        }

        // ── Tier-scaled encoder features ─────────────────────────────────
        tab.cdef_switch.set_active (true);
        tab.restoration_switch.set_active (true);
        tab.tf_switch.set_active (true);
        tab.dlf_switch.set_active (true);
        tab.tpl_switch.set_active (true);
        tab.low_latency_switch.set_active (false);

        // Film grain — only for live-action/mixed at MEDIUM+ tiers
        bool use_grain = (tier >= SizeTier.MEDIUM)
            && (rec.content_type == ContentType.LIVE_ACTION
                || rec.content_type == ContentType.MIXED);

        switch (tier) {
            case SizeTier.TINY:
                tab.grain_expander.set_enable_expansion (false);
                tab.qm_expander.set_enable_expansion (false);
                tab.sharpness_expander.set_enable_expansion (false);
                tab.lookahead_expander.set_enable_expansion (true);
                tab.lookahead_spin.set_value (60);
                break;

            case SizeTier.SMALL:
                tab.grain_expander.set_enable_expansion (use_grain);
                if (use_grain) {
                    tab.grain_strength_spin.set_value (8);
                    tab.grain_denoise_combo.set_selected (1);
                }
                tab.qm_expander.set_enable_expansion (false);
                tab.sharpness_expander.set_enable_expansion (false);
                tab.lookahead_expander.set_enable_expansion (true);
                tab.lookahead_spin.set_value (80);
                break;

            case SizeTier.MEDIUM:
                tab.grain_expander.set_enable_expansion (use_grain);
                if (use_grain) {
                    tab.grain_strength_spin.set_value (10);
                    tab.grain_denoise_combo.set_selected (1);
                }
                tab.qm_expander.set_enable_expansion (true);
                tab.qm_min_spin.set_value (8);
                tab.qm_max_spin.set_value (12);
                tab.sharpness_expander.set_enable_expansion (false);
                tab.lookahead_expander.set_enable_expansion (true);
                tab.lookahead_spin.set_value (100);
                break;

            case SizeTier.LARGE:
                tab.grain_expander.set_enable_expansion (use_grain);
                if (use_grain) {
                    tab.grain_strength_spin.set_value (12);
                    tab.grain_denoise_combo.set_selected (1);
                }
                tab.qm_expander.set_enable_expansion (true);
                tab.qm_min_spin.set_value (8);
                tab.qm_max_spin.set_value (13);
                tab.sharpness_expander.set_enable_expansion (true);
                tab.sharpness_spin.set_value (2);
                tab.lookahead_expander.set_enable_expansion (true);
                tab.lookahead_spin.set_value (120);
                break;

            case SizeTier.XLARGE:
                tab.grain_expander.set_enable_expansion (use_grain);
                if (use_grain) {
                    tab.grain_strength_spin.set_value (15);
                    tab.grain_denoise_combo.set_selected (1);
                }
                tab.qm_expander.set_enable_expansion (true);
                tab.qm_min_spin.set_value (8);
                tab.qm_max_spin.set_value (15);
                tab.sharpness_expander.set_enable_expansion (true);
                tab.sharpness_spin.set_value (3);
                tab.lookahead_expander.set_enable_expansion (true);
                tab.lookahead_spin.set_value (120);
                break;
        }

        // Audio
        configure_smart_audio (tab.audio_settings, tier, "mkv");
    }
}
