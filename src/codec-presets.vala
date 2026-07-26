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
                                         string? bitrate_label = null) {
        audio.set_audio_enabled (true);
        set_dropdown_by_label (audio.codec_combo, codec_name);

        if (bitrate_label != null && bitrate_label.length > 0)
            set_dropdown_by_label (audio.bitrate_combo, bitrate_label);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SMART OPTIMIZER — EFFORT-AWARE AUDIO HELPER
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Configure audio for a Smart Optimizer recommendation based on the
     * shared encoder effort level (see SmartOptimizerLogic.EncodeEffort).
     *
     * Uses the native audio codec for the container: Opus for WebM,
     * AAC for MP4. This ensures maximum compatibility — Opus is the
     * standard WebM audio codec, and AAC is the standard MP4 audio codec.
     *
     * Bitrate labels are applied directly so presets remain stable even when
     * codec-specific bitrate menus differ in length or ordering.
     */
    private static void configure_smart_audio (AudioSettings audio,
                                                OptimizationRecommendation rec,
                                                string container) {
        // When the optimizer determined source audio can be stream-copied,
        // try to set Copy.  If Copy is not available in the dropdown
        // (e.g. speed change or normalization is active), fall through
        // to the effort-based re-encode below.
        if (rec.stream_copy_audio) {
            var model = audio.codec_combo.get_model () as StringList;
            if (model != null) {
                for (uint i = 0; i < model.get_n_items (); i++) {
                    if (model.get_string (i) == AudioCodecName.COPY) {
                        configure_audio (audio, AudioCodecName.COPY);
                        return;
                    }
                }
            }
            // Copy not available — fall through to effort-based re-encode
        }

        bool is_webm = (container == "webm");
        string codec = is_webm ? AudioCodecName.OPUS : AudioCodecName.AAC;
        switch (rec.effort) {
            case EncodeEffort.MINIMAL:
                configure_audio (audio, codec, "64 kbps");
                break;
            case EncodeEffort.LOW:
                configure_audio (audio, codec, "128 kbps");
                break;
            case EncodeEffort.MEDIUM:
                configure_audio (audio, codec, "192 kbps");
                break;
            case EncodeEffort.HIGH:
                configure_audio (audio, codec, "256 kbps");
                break;
            case EncodeEffort.MAXIMUM:
                configure_audio (audio, codec, "320 kbps");
                break;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SMART OPTIMIZER → x264
    // ═════════════════════════════════════════════════════════════════════════

    public static void apply_smart_x264 (X264Tab tab, OptimizationRecommendation rec) {
        uint saved_container = tab.container_combo.get_selected ();
        bool requested_keep_all_audio = tab.audio_settings.get_keep_all_audio_requested ();
        tab.audio_settings.begin_smart_optimizer_override_application ();
        try {
            tab.reset_defaults ();
            EncodeEffort effort = rec.effort;

            // Container — forced to mp4 when the recommendation demands a
            // compatibility container (small size targets); otherwise respect
            // the user's choice.
            if (rec.force_compat_container) {
                tab.container_combo.set_selected (1);   // mp4
            } else {
                tab.container_combo.set_selected (saved_container);
            }
            set_dropdown_by_label (tab.profile_combo, "High");

            // Preset
            set_dropdown_by_label (tab.preset_combo, rec.preset);

            // Rate control
            if (rec.two_pass && rec.target_bitrate_kbps > 0) {
                tab.rc_mode_combo.set_selected (2);   // ABR
                tab.abr_bitrate_spin.set_value (rec.target_bitrate_kbps);
                tab.two_pass_switch.set_active (true);
                tab.abr_vbv_switch.set_active (true);  // VBV prevents peak bitrate spikes
            } else {
                tab.rc_mode_combo.set_selected (0);   // CRF
                tab.crf_spin.set_value (rec.crf);
            }

            // Tune. x264 accepts only ONE tune, so an explicit delivery
            // request wins over the content-derived choice — the user asked
            // for cheap decode and that cannot be combined.
            if (rec.fast_decode) {
                set_dropdown_by_label (tab.tune_combo, "fastdecode");
            } else {
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
            }

            // ── Effort-scaled encoder features ───────────────────────────────
            tab.cabac_switch.set_active (true);
            tab.mbtree_switch.set_active (true);
            tab.weightp_switch.set_active (true);
            tab.deblock_expander.set_enable_expansion (true);
            tab.psy_rd_expander.set_enable_expansion (true);

            switch (effort) {
                case EncodeEffort.MINIMAL:
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

                case EncodeEffort.LOW:
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

                case EncodeEffort.MEDIUM:
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

                case EncodeEffort.HIGH:
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

                case EncodeEffort.MAXIMUM:
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
            configure_smart_audio (tab.audio_settings, rec, rec.resolved_container);
            tab.audio_settings.set_keep_all_audio_requested (requested_keep_all_audio);
            tab.audio_settings.set_smart_optimizer_preserve_all_override (
                rec.preserve_all_audio_tracks_effective);
        } finally {
            tab.audio_settings.end_smart_optimizer_override_application ();
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SMART OPTIMIZER → VP9
    // ═════════════════════════════════════════════════════════════════════════

    public static void apply_smart_vp9 (Vp9Tab tab, OptimizationRecommendation rec) {
        uint saved_container = tab.container_combo.get_selected ();
        bool requested_keep_all_audio = tab.audio_settings.get_keep_all_audio_requested ();
        tab.audio_settings.begin_smart_optimizer_override_application ();
        try {
            tab.reset_defaults ();
            EncodeEffort effort = rec.effort;

            // Container — forced to webm when the recommendation demands a
            // compatibility container (small size targets); otherwise respect
            // the user's choice.
            if (rec.force_compat_container) {
                tab.container_combo.set_selected (0);   // webm
            } else {
                tab.container_combo.set_selected (saved_container);
            }

            // Speed
            string speed_str = rec.preset.replace ("cpu-used ", "");
            int speed_val = int.parse (speed_str);
            tab.speed_spin.set_value (speed_val);

            // Quality deadline — "good" provides excellent quality at all tiers;
            // "best" is prohibitively slow with negligible visual gain.
            set_dropdown_by_label (tab.quality_combo, "good");

            // Rate control — use pure VBR for two-pass size-targeted encodes.
            // Constrained Quality (CQ) has a CRF floor that can prevent the
            // encoder from staying under the bitrate cap on complex content.
            // VBR two-pass gives the encoder a clear bitrate target with no
            // quality minimum fighting the size constraint.
            if (rec.two_pass && rec.target_bitrate_kbps > 0) {
                tab.rc_mode_combo.set_selected (2);   // VBR
                tab.vbr_bitrate_spin.set_value (rec.target_bitrate_kbps);
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

            // ── Effort-scaled encoder features ───────────────────────────────
            tab.row_mt_switch.set_active (true);
            tab.frame_parallel_switch.set_active (false);
            tab.lookahead_expander.set_enable_expansion (true);
            tab.lag_in_frames_spin.set_value (25);   // VP9 max is 25

            switch (effort) {
                case EncodeEffort.MINIMAL:
                    tab.altref_expander.set_enable_expansion (true);
                    tab.arnr_maxframes_spin.set_value (7);
                    tab.arnr_strength_spin.set_value (5);
                    tab.aq_mode_combo.set_selected (0);
                    break;

                case EncodeEffort.LOW:
                    tab.altref_expander.set_enable_expansion (true);
                    tab.arnr_maxframes_spin.set_value (7);
                    tab.arnr_strength_spin.set_value (5);
                    set_dropdown_by_label (tab.aq_mode_combo, "Complexity");
                    break;

                case EncodeEffort.MEDIUM:
                    tab.altref_expander.set_enable_expansion (true);
                    tab.arnr_maxframes_spin.set_value (9);
                    tab.arnr_strength_spin.set_value (6);
                    set_dropdown_by_label (tab.aq_mode_combo, "Complexity");
                    break;

                case EncodeEffort.HIGH:
                    tab.altref_expander.set_enable_expansion (true);
                    tab.arnr_maxframes_spin.set_value (12);
                    tab.arnr_strength_spin.set_value (6);
                    set_dropdown_by_label (tab.aq_mode_combo, "Complexity");
                    break;

                case EncodeEffort.MAXIMUM:
                    tab.altref_expander.set_enable_expansion (true);
                    tab.arnr_maxframes_spin.set_value (15);
                    tab.arnr_strength_spin.set_value (6);
                    set_dropdown_by_label (tab.aq_mode_combo, "Complexity");
                    break;
            }

            // Audio
            configure_smart_audio (tab.audio_settings, rec, rec.resolved_container);
            tab.audio_settings.set_keep_all_audio_requested (requested_keep_all_audio);
            tab.audio_settings.set_smart_optimizer_preserve_all_override (
                rec.preserve_all_audio_tracks_effective);
        } finally {
            tab.audio_settings.end_smart_optimizer_override_application ();
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SMART OPTIMIZER → x265
    // ═════════════════════════════════════════════════════════════════════════

    public static void apply_smart_x265 (X265Tab tab, OptimizationRecommendation rec) {
        uint saved_container = tab.container_combo.get_selected ();
        bool requested_keep_all_audio = tab.audio_settings.get_keep_all_audio_requested ();
        tab.audio_settings.begin_smart_optimizer_override_application ();
        try {
            tab.reset_defaults ();
            EncodeEffort effort = rec.effort;

            // Container — forced to mp4 when the recommendation demands a
            // compatibility container (small size targets); otherwise respect
            // the user's choice.
            if (rec.force_compat_container) {
                tab.container_combo.set_selected (1);   // mp4
            } else {
                tab.container_combo.set_selected (saved_container);
            }

            // Preset
            set_dropdown_by_label (tab.preset_combo, rec.preset);

            // Rate control
            if (rec.two_pass && rec.target_bitrate_kbps > 0) {
                tab.rc_mode_combo.set_selected (2);   // ABR
                tab.abr_bitrate_spin.set_value (rec.target_bitrate_kbps);
                tab.two_pass_switch.set_active (true);
                tab.abr_vbv_switch.set_active (true);  // VBV prevents peak bitrate spikes
            } else {
                tab.rc_mode_combo.set_selected (0);   // CRF
                tab.crf_spin.set_value (rec.crf);
            }

            // Tune. x265 accepts only ONE tune, so delivery wins — see x264.
            if (rec.fast_decode) {
                set_dropdown_by_label (tab.tune_combo, "fastdecode");
            } else if (rec.content_type == ContentType.ANIME) {
                set_dropdown_by_label (tab.tune_combo, "animation");
            } else if (effort >= EncodeEffort.HIGH
                       && SmartOptimizerLogic.grain_warranted (
                           rec.grain_score, rec.content_type,
                           rec.source_bit_depth)) {
                // At generous budgets, preserve natural film grain rather
                // than smearing it — but only when grain is actually measured
                // (SmartOptimizerLogic.grain_warranted), not just from category.
                set_dropdown_by_label (tab.tune_combo, "grain");
            } else {
                tab.tune_combo.set_selected (0);
            }

            // ── Effort-scaled encoder features ───────────────────────────────
            tab.sao_switch.set_active (true);
            tab.deblock_expander.set_enable_expansion (true);
            tab.psy_rd_expander.set_enable_expansion (true);
            tab.cutree_switch.set_active (true);
            tab.weightp_switch.set_active (true);

            switch (effort) {
                case EncodeEffort.MINIMAL:
                    set_dropdown_by_label (tab.ref_frames_combo, "3");
                    tab.deblock_alpha_spin.set_value (0);
                    tab.deblock_beta_spin.set_value (0);
                    tab.psy_rd_spin.set_value (2.0);
                    tab.pmode_switch.set_active (false);
                    tab.lookahead_expander.set_enable_expansion (true);
                    tab.lookahead_spin.set_value (40);
                    break;

                case EncodeEffort.LOW:
                    set_dropdown_by_label (tab.ref_frames_combo, "4");
                    tab.deblock_alpha_spin.set_value (0);
                    tab.deblock_beta_spin.set_value (0);
                    tab.psy_rd_spin.set_value (2.0);
                    tab.pmode_switch.set_active (false);
                    tab.lookahead_expander.set_enable_expansion (true);
                    tab.lookahead_spin.set_value (50);
                    break;

                case EncodeEffort.MEDIUM:
                    set_dropdown_by_label (tab.ref_frames_combo, "4");
                    tab.deblock_alpha_spin.set_value (0);
                    tab.deblock_beta_spin.set_value (0);
                    tab.psy_rd_spin.set_value (2.5);
                    tab.pmode_switch.set_active (true);
                    tab.lookahead_expander.set_enable_expansion (true);
                    tab.lookahead_spin.set_value (60);
                    break;

                case EncodeEffort.HIGH:
                    set_dropdown_by_label (tab.ref_frames_combo, "5");
                    tab.deblock_alpha_spin.set_value (-1);
                    tab.deblock_beta_spin.set_value (-1);
                    tab.psy_rd_spin.set_value (3.0);
                    tab.pmode_switch.set_active (true);
                    tab.lookahead_expander.set_enable_expansion (true);
                    tab.lookahead_spin.set_value (80);
                    break;

                case EncodeEffort.MAXIMUM:
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
            configure_smart_audio (tab.audio_settings, rec, rec.resolved_container);
            tab.audio_settings.set_keep_all_audio_requested (requested_keep_all_audio);
            tab.audio_settings.set_smart_optimizer_preserve_all_override (
                rec.preserve_all_audio_tracks_effective);
        } finally {
            tab.audio_settings.end_smart_optimizer_override_application ();
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SMART OPTIMIZER → SVT-AV1
    // ═════════════════════════════════════════════════════════════════════════

    public static void apply_smart_svt_av1 (SvtAv1Tab tab, OptimizationRecommendation rec) {
        uint saved_container = tab.container_combo.get_selected ();
        bool requested_keep_all_audio = tab.audio_settings.get_keep_all_audio_requested ();
        tab.audio_settings.begin_smart_optimizer_override_application ();
        try {
            tab.reset_defaults ();
            EncodeEffort effort = rec.effort;

            // Container — forced to webm when the recommendation demands a
            // compatibility container (small size targets); otherwise respect
            // the user's choice.
            if (rec.force_compat_container) {
                tab.container_combo.set_selected (1);   // webm
            } else {
                tab.container_combo.set_selected (saved_container);
            }

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

            // AV1 exposes fast-decode as its own control rather than a tune,
            // so unlike x264/x265 it composes with the content settings
            // instead of displacing them. Level 1 trades a little efficiency
            // for materially cheaper decode; Level 2 costs more than most
            // streaming cases justify.
            set_dropdown_by_label (tab.fast_decode_combo,
                rec.fast_decode ? "Level 1" : "Disabled");

            // ── Effort-scaled encoder features ───────────────────────────────
            tab.cdef_switch.set_active (true);
            tab.restoration_switch.set_active (true);
            tab.tf_switch.set_active (true);
            tab.dlf_switch.set_active (true);
            tab.tpl_switch.set_active (true);
            tab.low_latency_switch.set_active (false);

            // Film grain — MEDIUM+ effort, gated on the measured grain signal
            // (clean sources are excluded even if live-action/mixed; grainy
            // sources included even if the category was uncertain). See
            // SmartOptimizerLogic.grain_warranted.
            bool use_grain = (effort >= EncodeEffort.MEDIUM)
                && SmartOptimizerLogic.grain_warranted (
                    rec.grain_score, rec.content_type, rec.source_bit_depth);

            switch (effort) {
                case EncodeEffort.MINIMAL:
                    tab.grain_expander.set_enable_expansion (false);
                    tab.qm_expander.set_enable_expansion (false);
                    tab.sharpness_expander.set_enable_expansion (false);
                    tab.lookahead_expander.set_enable_expansion (true);
                    tab.lookahead_spin.set_value (60);
                    break;

                case EncodeEffort.LOW:
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

                case EncodeEffort.MEDIUM:
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

                case EncodeEffort.HIGH:
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

                case EncodeEffort.MAXIMUM:
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
            configure_smart_audio (tab.audio_settings, rec, rec.resolved_container);
            tab.audio_settings.set_keep_all_audio_requested (requested_keep_all_audio);
            tab.audio_settings.set_smart_optimizer_preserve_all_override (
                rec.preserve_all_audio_tracks_effective);
        } finally {
            tab.audio_settings.end_smart_optimizer_override_application ();
        }
    }
}
