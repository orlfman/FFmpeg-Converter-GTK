using Gtk;

public class CodecPresets : Object {

    // ═════════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Find a string in a DropDown's model and select it.
     * Safe to call even if the label doesn't exist in the current model.
     */
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

    /**
     * Configure audio settings: enable the expander, pick codec + bitrate.
     * Must be called AFTER the container has been set (so the audio model
     * has already been rebuilt by the tab's container-change signal).
     */
    private static void configure_audio (AudioSettings audio,
                                         string codec_name,
                                         int bitrate_idx,
                                         int flac_level = -1) {
        audio.audio_expander.set_enable_expansion (true);
        set_dropdown_by_label (audio.codec_combo, codec_name);

        if (codec_name == "FLAC" && flac_level >= 0)
            audio.flac_compression_combo.set_selected ((uint) flac_level);
        else if (bitrate_idx >= 0)
            audio.bitrate_combo.set_selected ((uint) bitrate_idx);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SVT-AV1
    // ═════════════════════════════════════════════════════════════════════════

    public static void apply_svt_av1 (SvtAv1Tab tab, string preset) {
        if (preset == "Custom") return;

        // Start from a clean slate
        tab.reset_defaults ();

        switch (preset) {

        case "Streaming":
            tab.preset_spin.set_value (10);
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (38);
            tab.container_combo.set_selected (0);     // mkv
            tab.tune_combo.set_selected (0);          // Auto
            tab.grain_expander.set_enable_expansion (false);
            tab.lookahead_expander.set_enable_expansion (false);
            tab.cdef_switch.set_active (true);
            tab.restoration_switch.set_active (true);
            tab.tf_switch.set_active (true);
            tab.dlf_switch.set_active (true);
            tab.tpl_switch.set_active (false);
            tab.low_latency_switch.set_active (true);
            tab.fast_decode_combo.set_selected (0);   // Auto
            tab.scm_combo.set_selected (0);           // Auto
            configure_audio (tab.audio_settings, "Opus", 1);  // 128k
            break;

        case "Anime":
            tab.preset_spin.set_value (6);
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (28);
            tab.container_combo.set_selected (0);     // mkv
            tab.tune_combo.set_selected (0);          // Auto
            tab.grain_expander.set_enable_expansion (false);
            tab.lookahead_expander.set_enable_expansion (true);
            tab.lookahead_spin.set_value (120);
            tab.cdef_switch.set_active (true);
            tab.restoration_switch.set_active (true);
            tab.tf_switch.set_active (true);
            tab.dlf_switch.set_active (true);
            tab.tpl_switch.set_active (true);
            tab.low_latency_switch.set_active (false);
            tab.scm_combo.set_selected (0);           // Auto
            configure_audio (tab.audio_settings, "Opus", 2);  // 192k
            break;

        case "Low":
            tab.preset_spin.set_value (12);
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (42);
            tab.container_combo.set_selected (0);     // mkv
            tab.tune_combo.set_selected (0);          // Auto
            tab.grain_expander.set_enable_expansion (false);
            tab.lookahead_expander.set_enable_expansion (false);
            tab.cdef_switch.set_active (true);
            tab.restoration_switch.set_active (false);
            tab.tf_switch.set_active (true);
            tab.dlf_switch.set_active (true);
            tab.tpl_switch.set_active (false);
            tab.low_latency_switch.set_active (false);
            set_dropdown_by_label (tab.fast_decode_combo, "1");
            configure_audio (tab.audio_settings, "Opus", 0);  // 64k
            break;

        case "Medium":
            tab.preset_spin.set_value (8);
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (35);
            tab.container_combo.set_selected (0);     // mkv
            tab.tune_combo.set_selected (0);          // Auto
            tab.grain_expander.set_enable_expansion (false);
            tab.lookahead_expander.set_enable_expansion (false);
            tab.cdef_switch.set_active (true);
            tab.restoration_switch.set_active (true);
            tab.tf_switch.set_active (true);
            tab.dlf_switch.set_active (true);
            tab.tpl_switch.set_active (true);
            tab.low_latency_switch.set_active (false);
            configure_audio (tab.audio_settings, "Opus", 1);  // 128k
            break;

        case "High":
            tab.preset_spin.set_value (5);
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (26);
            tab.container_combo.set_selected (0);     // mkv
            tab.tune_combo.set_selected (0);          // Auto
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
            configure_audio (tab.audio_settings, "Opus", 2);  // 192k
            break;

        case "Very High":
            tab.preset_spin.set_value (3);
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (18);
            tab.container_combo.set_selected (0);     // mkv
            tab.tune_combo.set_selected (0);          // Auto
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
            configure_audio (tab.audio_settings, "FLAC", -1, 8);
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
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (28);
            tab.container_combo.set_selected (1);     // mp4
            set_dropdown_by_label (tab.tune_combo, "zerolatency");
            tab.sao_switch.set_active (true);
            tab.deblock_expander.set_enable_expansion (true);
            tab.deblock_alpha_spin.set_value (0);
            tab.deblock_beta_spin.set_value (0);
            tab.lookahead_expander.set_enable_expansion (false);
            tab.psy_rd_expander.set_enable_expansion (true);
            tab.psy_rd_spin.set_value (2.0);
            tab.cutree_switch.set_active (true);
            configure_audio (tab.audio_settings, "AAC", 1);  // 128k
            break;

        case "Anime":
            set_dropdown_by_label (tab.preset_combo, "medium");
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (22);
            tab.container_combo.set_selected (0);     // mkv
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
            configure_audio (tab.audio_settings, "Opus", 2);  // 192k
            break;

        case "Low":
            set_dropdown_by_label (tab.preset_combo, "veryfast");
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (30);
            tab.container_combo.set_selected (0);     // mkv
            tab.tune_combo.set_selected (0);          // Auto
            tab.lookahead_expander.set_enable_expansion (false);
            tab.psy_rd_expander.set_enable_expansion (true);
            tab.psy_rd_spin.set_value (2.0);
            tab.cutree_switch.set_active (true);
            configure_audio (tab.audio_settings, "Opus", 0);  // 64k
            break;

        case "Medium":
            set_dropdown_by_label (tab.preset_combo, "medium");
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (24);
            tab.container_combo.set_selected (0);     // mkv
            tab.tune_combo.set_selected (0);          // Auto
            tab.sao_switch.set_active (true);
            tab.deblock_expander.set_enable_expansion (true);
            tab.deblock_alpha_spin.set_value (0);
            tab.deblock_beta_spin.set_value (0);
            tab.lookahead_expander.set_enable_expansion (false);
            tab.psy_rd_expander.set_enable_expansion (true);
            tab.psy_rd_spin.set_value (2.0);
            tab.cutree_switch.set_active (true);
            configure_audio (tab.audio_settings, "Opus", 1);  // 128k
            break;

        case "High":
            set_dropdown_by_label (tab.preset_combo, "slow");
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (20);
            tab.container_combo.set_selected (0);     // mkv
            tab.tune_combo.set_selected (0);          // Auto
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
            configure_audio (tab.audio_settings, "Opus", 2);  // 192k
            break;

        case "Very High":
            set_dropdown_by_label (tab.preset_combo, "veryslow");
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (17);
            tab.container_combo.set_selected (0);     // mkv
            tab.tune_combo.set_selected (0);          // Auto
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
            configure_audio (tab.audio_settings, "FLAC", -1, 8);
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
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (23);
            tab.container_combo.set_selected (1);     // mp4
            tab.profile_combo.set_selected (0);       // Auto
            set_dropdown_by_label (tab.tune_combo, "zerolatency");
            tab.cabac_switch.set_active (true);
            tab.mbtree_switch.set_active (true);
            tab.deblock_expander.set_enable_expansion (true);
            tab.deblock_alpha_spin.set_value (0);
            tab.deblock_beta_spin.set_value (0);
            tab.lookahead_expander.set_enable_expansion (false);
            configure_audio (tab.audio_settings, "AAC", 1);  // 128k
            break;

        case "Anime":
            set_dropdown_by_label (tab.preset_combo, "medium");
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (20);
            tab.container_combo.set_selected (0);     // mkv
            tab.profile_combo.set_selected (0);       // Auto
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
            configure_audio (tab.audio_settings, "Opus", 2);  // 192k
            break;

        case "Low":
            set_dropdown_by_label (tab.preset_combo, "ultrafast");
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (28);
            tab.container_combo.set_selected (0);     // mkv
            tab.profile_combo.set_selected (0);       // Auto
            tab.tune_combo.set_selected (0);          // Auto
            tab.cabac_switch.set_active (false);
            set_dropdown_by_label (tab.me_combo, "dia");
            tab.subme_combo.set_selected (1);
            tab.bframes_spin.set_value (0);
            tab.mbtree_switch.set_active (false);
            tab.lookahead_expander.set_enable_expansion (false);
            configure_audio (tab.audio_settings, "Opus", 0);  // 64k
            break;

        case "Medium":
            set_dropdown_by_label (tab.preset_combo, "medium");
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (21);
            tab.container_combo.set_selected (0);     // mkv
            tab.profile_combo.set_selected (0);       // Auto
            tab.tune_combo.set_selected (0);          // Auto
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
            configure_audio (tab.audio_settings, "Opus", 1);  // 128k
            break;

        case "High":
            set_dropdown_by_label (tab.preset_combo, "slow");
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (18);
            tab.container_combo.set_selected (0);     // mkv
            set_dropdown_by_label (tab.profile_combo, "High");
            tab.tune_combo.set_selected (0);          // Auto
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
            configure_audio (tab.audio_settings, "Opus", 2);  // 192k
            break;

        case "Very High":
            set_dropdown_by_label (tab.preset_combo, "veryslow");
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (16);
            tab.container_combo.set_selected (0);     // mkv
            set_dropdown_by_label (tab.profile_combo, "High");
            tab.tune_combo.set_selected (0);          // Auto
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
            configure_audio (tab.audio_settings, "FLAC", -1, 8);
            break;

        case "Imageboards":
            set_dropdown_by_label (tab.preset_combo, "medium");
            tab.rc_mode_combo.set_selected (2);       // ABR
            tab.abr_bitrate_spin.set_value (700);
            tab.container_combo.set_selected (1);     // mp4
            set_dropdown_by_label (tab.profile_combo, "High");
            tab.tune_combo.set_selected (0);          // Auto
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
            configure_audio (tab.audio_settings, "AAC", 0);   // 64k
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
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (36);
            tab.container_combo.set_selected (0);     // webm
            tab.tune_content_combo.set_selected (0);  // Default
            tab.aq_mode_combo.set_selected (0);       // Disabled
            tab.altref_expander.set_enable_expansion (false);
            tab.lookahead_expander.set_enable_expansion (false);
            tab.row_mt_switch.set_active (true);
            set_dropdown_by_label (tab.tile_columns_combo, "2");
            tab.frame_parallel_switch.set_active (true);
            configure_audio (tab.audio_settings, "Opus", 1);  // 128k
            break;

        case "Anime":
            tab.speed_spin.set_value (4);
            set_dropdown_by_label (tab.quality_combo, "good");
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (28);
            tab.container_combo.set_selected (1);     // mkv
            tab.tune_content_combo.set_selected (0);  // Default
            tab.aq_mode_combo.set_selected (0);       // Disabled
            tab.altref_expander.set_enable_expansion (true);
            tab.arnr_maxframes_spin.set_value (7);
            tab.arnr_strength_spin.set_value (5);
            tab.lookahead_expander.set_enable_expansion (true);
            tab.lag_in_frames_spin.set_value (25);
            tab.row_mt_switch.set_active (true);
            tab.frame_parallel_switch.set_active (false);
            configure_audio (tab.audio_settings, "Opus", 2);  // 192k
            break;

        case "Low":
            tab.speed_spin.set_value (8);
            set_dropdown_by_label (tab.quality_combo, "realtime");
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (42);
            tab.container_combo.set_selected (0);     // webm
            tab.tune_content_combo.set_selected (0);  // Default
            tab.altref_expander.set_enable_expansion (false);
            tab.lookahead_expander.set_enable_expansion (false);
            tab.row_mt_switch.set_active (true);
            set_dropdown_by_label (tab.tile_columns_combo, "2");
            tab.frame_parallel_switch.set_active (true);
            configure_audio (tab.audio_settings, "Opus", 0);  // 64k
            break;

        case "Medium":
            tab.speed_spin.set_value (4);
            set_dropdown_by_label (tab.quality_combo, "good");
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (31);
            tab.container_combo.set_selected (0);     // webm
            tab.tune_content_combo.set_selected (0);  // Default
            tab.altref_expander.set_enable_expansion (true);
            tab.arnr_maxframes_spin.set_value (7);
            tab.arnr_strength_spin.set_value (5);
            tab.lookahead_expander.set_enable_expansion (false);
            tab.row_mt_switch.set_active (true);
            tab.frame_parallel_switch.set_active (false);
            configure_audio (tab.audio_settings, "Opus", 1);  // 128k
            break;

        case "High":
            tab.speed_spin.set_value (2);
            set_dropdown_by_label (tab.quality_combo, "good");
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (24);
            tab.container_combo.set_selected (1);     // mkv
            tab.tune_content_combo.set_selected (0);  // Default
            set_dropdown_by_label (tab.aq_mode_combo, "Complexity");
            tab.altref_expander.set_enable_expansion (true);
            tab.arnr_maxframes_spin.set_value (7);
            tab.arnr_strength_spin.set_value (5);
            tab.lookahead_expander.set_enable_expansion (true);
            tab.lag_in_frames_spin.set_value (25);
            tab.row_mt_switch.set_active (true);
            tab.frame_parallel_switch.set_active (false);
            configure_audio (tab.audio_settings, "Opus", 2);  // 192k
            break;

        case "Very High":
            tab.speed_spin.set_value (0);
            set_dropdown_by_label (tab.quality_combo, "best");
            tab.rc_mode_combo.set_selected (0);       // CRF
            tab.crf_spin.set_value (15);
            tab.container_combo.set_selected (1);     // mkv
            tab.tune_content_combo.set_selected (0);  // Default
            set_dropdown_by_label (tab.aq_mode_combo, "Complexity");
            tab.altref_expander.set_enable_expansion (true);
            tab.arnr_maxframes_spin.set_value (7);
            tab.arnr_strength_spin.set_value (5);
            tab.lookahead_expander.set_enable_expansion (true);
            tab.lag_in_frames_spin.set_value (25);
            tab.row_mt_switch.set_active (true);
            tab.frame_parallel_switch.set_active (false);
            configure_audio (tab.audio_settings, "FLAC", -1, 8);
            break;

        case "Imageboards":
            tab.speed_spin.set_value (4);
            set_dropdown_by_label (tab.quality_combo, "good");
            tab.rc_mode_combo.set_selected (1);       // Constrained Quality
            tab.cq_level_spin.set_value (35);
            tab.cq_bitrate_spin.set_value (700);
            tab.container_combo.set_selected (0);     // webm
            tab.tune_content_combo.set_selected (0);  // Default
            tab.two_pass_switch.set_active (true);
            tab.altref_expander.set_enable_expansion (true);
            tab.arnr_maxframes_spin.set_value (7);
            tab.arnr_strength_spin.set_value (5);
            tab.lookahead_expander.set_enable_expansion (true);
            tab.lag_in_frames_spin.set_value (25);
            tab.row_mt_switch.set_active (true);
            tab.frame_parallel_switch.set_active (false);
            configure_audio (tab.audio_settings, "Opus", 0);  // 64k
            break;
        }
    }
}
