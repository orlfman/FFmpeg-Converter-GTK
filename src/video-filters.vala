using Gtk;
using Adw;

// ═══════════════════════════════════════════════════════════════════════════════
//  VideoFilters — Configurable video processing filters
//
//  Usage from GeneralTab:
//      video_filters = new VideoFilters ();
//      append (video_filters.get_widget ());
//
//  From FilterBuilder:
//      string[] f = tab.video_filters.get_processing_filters ();
//      string   h = tab.video_filters.get_hdr_filter ();
// ═══════════════════════════════════════════════════════════════════════════════

public class VideoFilters : Object {

    private Box container;

    // ═════════════════════════════════════════════════════════════════════════
    //  PUBLIC WIDGETS — Restoration
    // ═════════════════════════════════════════════════════════════════════════

    // Deinterlace
    public Switch   deinterlace_check   { get; private set; }
    public DropDown deinterlace_mode    { get; private set; }
    public DropDown deinterlace_parity  { get; private set; }

    // Deblock
    public Switch     deblock_check     { get; private set; }
    public SpinButton deblock_alpha     { get; private set; }
    public SpinButton deblock_beta      { get; private set; }

    // Deflicker
    public Switch     deflicker_check   { get; private set; }
    public SpinButton deflicker_size    { get; private set; }
    public DropDown   deflicker_mode    { get; private set; }

    // ── ExpanderRows for restoration
    private Adw.ExpanderRow deinterlace_expander;
    private Adw.ExpanderRow deblock_expander;
    private Adw.ExpanderRow deflicker_expander;

    // ═════════════════════════════════════════════════════════════════════════
    //  PUBLIC WIDGETS — Noise Reduction
    // ═════════════════════════════════════════════════════════════════════════

    // HQDn3d (fast, lightweight)
    public Switch     hqdn3d_check      { get; private set; }
    public SpinButton hqdn3d_luma_s     { get; private set; }
    public SpinButton hqdn3d_chroma_s   { get; private set; }
    public SpinButton hqdn3d_luma_t     { get; private set; }
    public SpinButton hqdn3d_chroma_t   { get; private set; }

    // NLMeans (high-quality, slow)
    public Switch     nlmeans_check     { get; private set; }
    public Switch     nlmeans_gpu       { get; private set; }
    public SpinButton nlmeans_strength  { get; private set; }
    public SpinButton nlmeans_patch     { get; private set; }
    public SpinButton nlmeans_research  { get; private set; }

    // Median
    public Switch     median_check      { get; private set; }
    public SpinButton median_radius     { get; private set; }

    // ── ExpanderRows for noise reduction
    private Adw.ExpanderRow hqdn3d_expander;
    private Adw.ExpanderRow nlmeans_expander;
    private Adw.ExpanderRow median_expander;

    // ═════════════════════════════════════════════════════════════════════════
    //  PUBLIC WIDGETS — Sharpening
    // ═════════════════════════════════════════════════════════════════════════

    // Unsharp Mask
    public Switch     unsharp_check         { get; private set; }
    public DropDown   unsharp_matrix        { get; private set; }
    public SpinButton unsharp_luma_amount   { get; private set; }
    public SpinButton unsharp_chroma_amount { get; private set; }

    // Adaptive Sharpen (cas)
    public Switch     cas_check             { get; private set; }
    public SpinButton cas_strength          { get; private set; }

    // ── ExpanderRows for sharpening
    private Adw.ExpanderRow unsharp_expander;
    private Adw.ExpanderRow cas_expander;

    // ═════════════════════════════════════════════════════════════════════════
    //  PUBLIC WIDGETS — Blur
    // ═════════════════════════════════════════════════════════════════════════

    // Box Blur
    public Switch     boxblur_check     { get; private set; }
    public SpinButton boxblur_luma      { get; private set; }
    public SpinButton boxblur_chroma    { get; private set; }
    public SpinButton boxblur_passes    { get; private set; }

    // Gaussian Blur
    public Switch     gblur_check       { get; private set; }
    public SpinButton gblur_sigma       { get; private set; }

    // ── ExpanderRows for blur
    private Adw.ExpanderRow boxblur_expander;
    private Adw.ExpanderRow gblur_expander;

    // ═════════════════════════════════════════════════════════════════════════
    //  PUBLIC WIDGETS — Grain & Texture
    // ═════════════════════════════════════════════════════════════════════════

    // Film Grain
    public Switch     grain_check       { get; private set; }
    public SpinButton grain_strength    { get; private set; }
    public Switch     grain_temporal    { get; private set; }
    public DropDown   grain_type        { get; private set; }

    // Debanding
    public Switch     deband_check      { get; private set; }
    public SpinButton deband_1thr       { get; private set; }
    public SpinButton deband_range      { get; private set; }
    public Switch     deband_blur       { get; private set; }

    // ── ExpanderRows for grain
    private Adw.ExpanderRow grain_expander;
    private Adw.ExpanderRow deband_expander;

    // ═════════════════════════════════════════════════════════════════════════
    //  PUBLIC WIDGETS — HDR Tone Mapping
    // ═════════════════════════════════════════════════════════════════════════

    public Switch     hdr_tonemap_check { get; private set; }
    public DropDown   tonemap_mode      { get; private set; }
    public SpinButton tonemap_desat     { get; private set; }

    private Adw.ExpanderRow hdr_expander;
    private Adw.ActionRow   tonemap_desat_row;

    // External reference for pixel format awareness
    private Switch? ten_bit_ref = null;

    // Called by GeneralTab after construction to allow 10-bit awareness
    public void set_ten_bit_reference (Switch check) {
        ten_bit_ref = check;
    }

    private bool is_ten_bit_selected () {
        return ten_bit_ref != null && ten_bit_ref.active;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public VideoFilters () {
        container = new Box (Orientation.VERTICAL, 24);

        build_restoration_group ();
        build_noise_reduction_group ();
        build_sharpening_group ();
        build_blur_group ();
        build_grain_texture_group ();
        build_hdr_group ();
    }

    public Widget get_widget () {
        return container;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  RESTORATION
    // ═════════════════════════════════════════════════════════════════════════

    private void build_restoration_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Restoration");
        group.set_description ("Fix artifacts from older or damaged sources");

        // ── Deinterlace ──────────────────────────────────────────────────────
        deinterlace_check = new Switch ();
        deinterlace_check.set_active (false);

        deinterlace_expander = new Adw.ExpanderRow ();
        deinterlace_expander.set_title ("Deinterlace");
        deinterlace_expander.set_subtitle ("Remove interlacing artifacts (yadif)");
        deinterlace_expander.set_show_enable_switch (true);
        deinterlace_expander.set_enable_expansion (false);

        deinterlace_check.bind_property ("active", deinterlace_expander,
            "enable-expansion", BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        var di_mode_row = new Adw.ActionRow ();
        di_mode_row.set_title ("Mode");
        di_mode_row.set_subtitle ("Send Field outputs double the frame rate");
        deinterlace_mode = new DropDown (new StringList (
            { "Send Frame", "Send Field" }
        ), null);
        deinterlace_mode.set_valign (Align.CENTER);
        deinterlace_mode.set_selected (0);
        di_mode_row.add_suffix (deinterlace_mode);
        deinterlace_expander.add_row (di_mode_row);

        var di_parity_row = new Adw.ActionRow ();
        di_parity_row.set_title ("Field Parity");
        di_parity_row.set_subtitle ("Auto-detect works for most sources");
        deinterlace_parity = new DropDown (new StringList (
            { "Auto", "Top Field First", "Bottom Field First" }
        ), null);
        deinterlace_parity.set_valign (Align.CENTER);
        deinterlace_parity.set_selected (0);
        di_parity_row.add_suffix (deinterlace_parity);
        deinterlace_expander.add_row (di_parity_row);

        group.add (deinterlace_expander);

        // ── Deblock ──────────────────────────────────────────────────────────
        deblock_check = new Switch ();
        deblock_check.set_active (false);

        deblock_expander = new Adw.ExpanderRow ();
        deblock_expander.set_title ("Deblock");
        deblock_expander.set_subtitle ("Reduce blocky compression artifacts");
        deblock_expander.set_show_enable_switch (true);
        deblock_expander.set_enable_expansion (false);

        deblock_check.bind_property ("active", deblock_expander,
            "enable-expansion", BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        var db_alpha_row = new Adw.ActionRow ();
        db_alpha_row.set_title ("Strength (Alpha)");
        db_alpha_row.set_subtitle ("Higher values deblock more aggressively");
        deblock_alpha = new SpinButton.with_range (-6, 6, 1);
        deblock_alpha.set_value (0);
        deblock_alpha.set_valign (Align.CENTER);
        db_alpha_row.add_suffix (deblock_alpha);
        deblock_expander.add_row (db_alpha_row);

        var db_beta_row = new Adw.ActionRow ();
        db_beta_row.set_title ("Threshold (Beta)");
        db_beta_row.set_subtitle ("Controls which edges are treated as block boundaries");
        deblock_beta = new SpinButton.with_range (-6, 6, 1);
        deblock_beta.set_value (0);
        deblock_beta.set_valign (Align.CENTER);
        db_beta_row.add_suffix (deblock_beta);
        deblock_expander.add_row (db_beta_row);

        group.add (deblock_expander);

        // ── Deflicker ────────────────────────────────────────────────────────
        deflicker_check = new Switch ();
        deflicker_check.set_active (false);

        deflicker_expander = new Adw.ExpanderRow ();
        deflicker_expander.set_title ("Deflicker");
        deflicker_expander.set_subtitle ("Smooth brightness fluctuations in timelapses or old footage");
        deflicker_expander.set_show_enable_switch (true);
        deflicker_expander.set_enable_expansion (false);

        deflicker_check.bind_property ("active", deflicker_expander,
            "enable-expansion", BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        var df_mode_row = new Adw.ActionRow ();
        df_mode_row.set_title ("Averaging Mode");
        deflicker_mode = new DropDown (new StringList (
            { "Arithmetic Mean", "Geometric Mean", "Harmonic Mean", "Median" }
        ), null);
        deflicker_mode.set_valign (Align.CENTER);
        deflicker_mode.set_selected (0);
        df_mode_row.add_suffix (deflicker_mode);
        deflicker_expander.add_row (df_mode_row);

        var df_size_row = new Adw.ActionRow ();
        df_size_row.set_title ("Window Size");
        df_size_row.set_subtitle ("Number of frames to average (must be odd)");
        deflicker_size = new SpinButton.with_range (3, 99, 2);
        deflicker_size.set_value (5);
        deflicker_size.set_valign (Align.CENTER);
        df_size_row.add_suffix (deflicker_size);
        deflicker_expander.add_row (df_size_row);

        group.add (deflicker_expander);

        container.append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  NOISE REDUCTION
    // ═════════════════════════════════════════════════════════════════════════

    private void build_noise_reduction_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Noise Reduction");
        group.set_description ("Reduce unwanted noise and grain from video");

        // ── HQDn3d (fast) ────────────────────────────────────────────────────
        hqdn3d_check = new Switch ();
        hqdn3d_check.set_active (false);

        hqdn3d_expander = new Adw.ExpanderRow ();
        hqdn3d_expander.set_title ("Denoise (hqdn3d)");
        hqdn3d_expander.set_subtitle ("Fast, lightweight temporal + spatial denoiser");
        hqdn3d_expander.set_show_enable_switch (true);
        hqdn3d_expander.set_enable_expansion (false);

        hqdn3d_check.bind_property ("active", hqdn3d_expander,
            "enable-expansion", BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        var hq_ls_row = new Adw.ActionRow ();
        hq_ls_row.set_title ("Luma Spatial");
        hq_ls_row.set_subtitle ("Spatial smoothing of brightness (0 = off)");
        hqdn3d_luma_s = new SpinButton.with_range (0.0, 20.0, 0.5);
        hqdn3d_luma_s.set_value (4.0);
        hqdn3d_luma_s.set_digits (1);
        hqdn3d_luma_s.set_valign (Align.CENTER);
        hq_ls_row.add_suffix (hqdn3d_luma_s);
        hqdn3d_expander.add_row (hq_ls_row);

        var hq_cs_row = new Adw.ActionRow ();
        hq_cs_row.set_title ("Chroma Spatial");
        hq_cs_row.set_subtitle ("Spatial smoothing of color (0 = off)");
        hqdn3d_chroma_s = new SpinButton.with_range (0.0, 20.0, 0.5);
        hqdn3d_chroma_s.set_value (3.0);
        hqdn3d_chroma_s.set_digits (1);
        hqdn3d_chroma_s.set_valign (Align.CENTER);
        hq_cs_row.add_suffix (hqdn3d_chroma_s);
        hqdn3d_expander.add_row (hq_cs_row);

        var hq_lt_row = new Adw.ActionRow ();
        hq_lt_row.set_title ("Luma Temporal");
        hq_lt_row.set_subtitle ("Frame-to-frame smoothing of brightness");
        hqdn3d_luma_t = new SpinButton.with_range (0.0, 20.0, 0.5);
        hqdn3d_luma_t.set_value (6.0);
        hqdn3d_luma_t.set_digits (1);
        hqdn3d_luma_t.set_valign (Align.CENTER);
        hq_lt_row.add_suffix (hqdn3d_luma_t);
        hqdn3d_expander.add_row (hq_lt_row);

        var hq_ct_row = new Adw.ActionRow ();
        hq_ct_row.set_title ("Chroma Temporal");
        hq_ct_row.set_subtitle ("Frame-to-frame smoothing of color");
        hqdn3d_chroma_t = new SpinButton.with_range (0.0, 20.0, 0.5);
        hqdn3d_chroma_t.set_value (4.5);
        hqdn3d_chroma_t.set_digits (1);
        hqdn3d_chroma_t.set_valign (Align.CENTER);
        hq_ct_row.add_suffix (hqdn3d_chroma_t);
        hqdn3d_expander.add_row (hq_ct_row);

        group.add (hqdn3d_expander);

        // ── NLMeans (high quality) ───────────────────────────────────────────
        nlmeans_check = new Switch ();
        nlmeans_check.set_active (false);

        nlmeans_expander = new Adw.ExpanderRow ();
        nlmeans_expander.set_title ("NLMeans Denoise");
        nlmeans_expander.set_subtitle ("High-quality non-local means denoiser — slower but superior");
        nlmeans_expander.set_show_enable_switch (true);
        nlmeans_expander.set_enable_expansion (false);

        nlmeans_check.bind_property ("active", nlmeans_expander,
            "enable-expansion", BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        var nl_str_row = new Adw.ActionRow ();
        nl_str_row.set_title ("Denoise Strength");
        nl_str_row.set_subtitle ("Higher values remove more noise but may blur detail");
        nlmeans_strength = new SpinButton.with_range (1.0, 30.0, 0.5);
        nlmeans_strength.set_value (3.5);
        nlmeans_strength.set_digits (1);
        nlmeans_strength.set_valign (Align.CENTER);
        nl_str_row.add_suffix (nlmeans_strength);
        nlmeans_expander.add_row (nl_str_row);

        var nl_patch_row = new Adw.ActionRow ();
        nl_patch_row.set_title ("Patch Size");
        nl_patch_row.set_subtitle ("Size of comparison patches (odd, 3–15)");
        nlmeans_patch = new SpinButton.with_range (3, 15, 2);
        nlmeans_patch.set_value (7);
        nlmeans_patch.set_valign (Align.CENTER);
        nl_patch_row.add_suffix (nlmeans_patch);
        nlmeans_expander.add_row (nl_patch_row);

        var nl_res_row = new Adw.ActionRow ();
        nl_res_row.set_title ("Research Window");
        nl_res_row.set_subtitle ("Search area size — larger is slower but better (odd, 3–31)");
        nlmeans_research = new SpinButton.with_range (3, 31, 2);
        nlmeans_research.set_value (15);
        nlmeans_research.set_valign (Align.CENTER);
        nl_res_row.add_suffix (nlmeans_research);
        nlmeans_expander.add_row (nl_res_row);

        var nl_gpu_row = new Adw.ActionRow ();
        nl_gpu_row.set_title ("GPU Acceleration (OpenCL)");
        nl_gpu_row.set_subtitle ("Offloads to GPU — much faster, requires FFmpeg built with --enable-opencl");
        nlmeans_gpu = new Switch ();
        nlmeans_gpu.set_active (false);
        nlmeans_gpu.set_valign (Align.CENTER);
        nl_gpu_row.add_suffix (nlmeans_gpu);
        nl_gpu_row.set_activatable_widget (nlmeans_gpu);
        nlmeans_expander.add_row (nl_gpu_row);

        group.add (nlmeans_expander);

        // ── Median ───────────────────────────────────────────────────────────
        median_check = new Switch ();
        median_check.set_active (false);

        median_expander = new Adw.ExpanderRow ();
        median_expander.set_title ("Median Filter");
        median_expander.set_subtitle ("Remove salt-and-pepper noise by replacing each pixel with its neighborhood median");
        median_expander.set_show_enable_switch (true);
        median_expander.set_enable_expansion (false);

        median_check.bind_property ("active", median_expander,
            "enable-expansion", BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        var med_r_row = new Adw.ActionRow ();
        med_r_row.set_title ("Radius");
        med_r_row.set_subtitle ("Neighborhood size (1–5, higher = stronger)");
        median_radius = new SpinButton.with_range (1, 5, 1);
        median_radius.set_value (2);
        median_radius.set_valign (Align.CENTER);
        med_r_row.add_suffix (median_radius);
        median_expander.add_row (med_r_row);

        group.add (median_expander);

        container.append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  SHARPENING
    // ═════════════════════════════════════════════════════════════════════════

    private void build_sharpening_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Sharpening");
        group.set_description ("Enhance edge definition and fine detail");

        // ── Unsharp Mask ─────────────────────────────────────────────────────
        unsharp_check = new Switch ();
        unsharp_check.set_active (false);

        unsharp_expander = new Adw.ExpanderRow ();
        unsharp_expander.set_title ("Unsharp Mask");
        unsharp_expander.set_subtitle ("Classic sharpening — negative values blur instead");
        unsharp_expander.set_show_enable_switch (true);
        unsharp_expander.set_enable_expansion (false);

        unsharp_check.bind_property ("active", unsharp_expander,
            "enable-expansion", BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        var us_matrix_row = new Adw.ActionRow ();
        us_matrix_row.set_title ("Matrix Size");
        us_matrix_row.set_subtitle ("Larger kernels affect broader areas");
        unsharp_matrix = new DropDown (new StringList (
            { "3×3 (Tight)", "5×5 (Standard)", "7×7 (Wide)", "9×9 (Very Wide)", "13×13 (Maximum)" }
        ), null);
        unsharp_matrix.set_valign (Align.CENTER);
        unsharp_matrix.set_selected (1);
        us_matrix_row.add_suffix (unsharp_matrix);
        unsharp_expander.add_row (us_matrix_row);

        var us_la_row = new Adw.ActionRow ();
        us_la_row.set_title ("Luma Amount");
        us_la_row.set_subtitle ("Brightness sharpening strength (negative = soften)");
        unsharp_luma_amount = new SpinButton.with_range (-2.0, 5.0, 0.1);
        unsharp_luma_amount.set_value (1.0);
        unsharp_luma_amount.set_digits (1);
        unsharp_luma_amount.set_valign (Align.CENTER);
        us_la_row.add_suffix (unsharp_luma_amount);
        unsharp_expander.add_row (us_la_row);

        var us_ca_row = new Adw.ActionRow ();
        us_ca_row.set_title ("Chroma Amount");
        us_ca_row.set_subtitle ("Color channel sharpening (usually lower than luma)");
        unsharp_chroma_amount = new SpinButton.with_range (-2.0, 5.0, 0.1);
        unsharp_chroma_amount.set_value (0.5);
        unsharp_chroma_amount.set_digits (1);
        unsharp_chroma_amount.set_valign (Align.CENTER);
        us_ca_row.add_suffix (unsharp_chroma_amount);
        unsharp_expander.add_row (us_ca_row);

        group.add (unsharp_expander);

        // ── Contrast Adaptive Sharpen (CAS) ──────────────────────────────────
        cas_check = new Switch ();
        cas_check.set_active (false);

        cas_expander = new Adw.ExpanderRow ();
        cas_expander.set_title ("Contrast Adaptive Sharpen");
        cas_expander.set_subtitle ("AMD CAS — sharpens without ringing on edges (FFmpeg 5.0+)");
        cas_expander.set_show_enable_switch (true);
        cas_expander.set_enable_expansion (false);

        cas_check.bind_property ("active", cas_expander,
            "enable-expansion", BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        var cas_str_row = new Adw.ActionRow ();
        cas_str_row.set_title ("Strength");
        cas_str_row.set_subtitle ("0 = lightest sharpening, 1 = maximum");
        cas_strength = new SpinButton.with_range (0.0, 1.0, 0.05);
        cas_strength.set_value (0.4);
        cas_strength.set_digits (2);
        cas_strength.set_valign (Align.CENTER);
        cas_str_row.add_suffix (cas_strength);
        cas_expander.add_row (cas_str_row);

        group.add (cas_expander);

        container.append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  BLUR
    // ═════════════════════════════════════════════════════════════════════════

    private void build_blur_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Blur");
        group.set_description ("Soften the image or specific channels");

        // ── Box Blur ─────────────────────────────────────────────────────────
        boxblur_check = new Switch ();
        boxblur_check.set_active (false);

        boxblur_expander = new Adw.ExpanderRow ();
        boxblur_expander.set_title ("Box Blur");
        boxblur_expander.set_subtitle ("Fast uniform blur — multiple passes approximate Gaussian");
        boxblur_expander.set_show_enable_switch (true);
        boxblur_expander.set_enable_expansion (false);

        boxblur_check.bind_property ("active", boxblur_expander,
            "enable-expansion", BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        var bb_lr_row = new Adw.ActionRow ();
        bb_lr_row.set_title ("Luma Radius");
        bb_lr_row.set_subtitle ("Blur radius for brightness");
        boxblur_luma = new SpinButton.with_range (1, 20, 1);
        boxblur_luma.set_value (2);
        boxblur_luma.set_valign (Align.CENTER);
        bb_lr_row.add_suffix (boxblur_luma);
        boxblur_expander.add_row (bb_lr_row);

        var bb_cr_row = new Adw.ActionRow ();
        bb_cr_row.set_title ("Chroma Radius");
        bb_cr_row.set_subtitle ("Blur radius for color channels");
        boxblur_chroma = new SpinButton.with_range (1, 20, 1);
        boxblur_chroma.set_value (2);
        boxblur_chroma.set_valign (Align.CENTER);
        bb_cr_row.add_suffix (boxblur_chroma);
        boxblur_expander.add_row (bb_cr_row);

        var bb_pass_row = new Adw.ActionRow ();
        bb_pass_row.set_title ("Passes");
        bb_pass_row.set_subtitle ("More passes = smoother result (3 ≈ Gaussian)");
        boxblur_passes = new SpinButton.with_range (1, 10, 1);
        boxblur_passes.set_value (1);
        boxblur_passes.set_valign (Align.CENTER);
        bb_pass_row.add_suffix (boxblur_passes);
        boxblur_expander.add_row (bb_pass_row);

        group.add (boxblur_expander);

        // ── Gaussian Blur ────────────────────────────────────────────────────
        gblur_check = new Switch ();
        gblur_check.set_active (false);

        gblur_expander = new Adw.ExpanderRow ();
        gblur_expander.set_title ("Gaussian Blur");
        gblur_expander.set_subtitle ("Smooth, natural blur using Gaussian distribution");
        gblur_expander.set_show_enable_switch (true);
        gblur_expander.set_enable_expansion (false);

        gblur_check.bind_property ("active", gblur_expander,
            "enable-expansion", BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        var gb_sig_row = new Adw.ActionRow ();
        gb_sig_row.set_title ("Sigma");
        gb_sig_row.set_subtitle ("Standard deviation — higher = stronger blur");
        gblur_sigma = new SpinButton.with_range (0.1, 50.0, 0.5);
        gblur_sigma.set_value (1.5);
        gblur_sigma.set_digits (1);
        gblur_sigma.set_valign (Align.CENTER);
        gb_sig_row.add_suffix (gblur_sigma);
        gblur_expander.add_row (gb_sig_row);

        group.add (gblur_expander);

        container.append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  GRAIN & TEXTURE
    // ═════════════════════════════════════════════════════════════════════════

    private void build_grain_texture_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("Grain &amp; Texture");
        group.set_description ("Add or remove texture artifacts");

        // ── Film Grain ───────────────────────────────────────────────────────
        grain_check = new Switch ();
        grain_check.set_active (false);

        grain_expander = new Adw.ExpanderRow ();
        grain_expander.set_title ("Film Grain");
        grain_expander.set_subtitle ("Synthesize organic film-like grain texture");
        grain_expander.set_show_enable_switch (true);
        grain_expander.set_enable_expansion (false);

        grain_check.bind_property ("active", grain_expander,
            "enable-expansion", BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        var gr_str_row = new Adw.ActionRow ();
        gr_str_row.set_title ("Strength");
        gr_str_row.set_subtitle ("Amount of grain to add (1–100)");
        grain_strength = new SpinButton.with_range (1, 100, 1);
        grain_strength.set_value (12);
        grain_strength.set_valign (Align.CENTER);
        gr_str_row.add_suffix (grain_strength);
        grain_expander.add_row (gr_str_row);

        var gr_type_row = new Adw.ActionRow ();
        gr_type_row.set_title ("Distribution");
        gr_type_row.set_subtitle ("Uniform is harsher, Gaussian is more natural");
        grain_type = new DropDown (new StringList (
            { "Uniform", "Gaussian" }
        ), null);
        grain_type.set_valign (Align.CENTER);
        grain_type.set_selected (0);
        gr_type_row.add_suffix (grain_type);
        grain_expander.add_row (gr_type_row);

        var gr_temp_row = new Adw.ActionRow ();
        gr_temp_row.set_title ("Temporal Variation");
        gr_temp_row.set_subtitle ("Varies grain each frame for a more organic look");
        grain_temporal = new Switch ();
        grain_temporal.set_active (true);
        grain_temporal.set_valign (Align.CENTER);
        gr_temp_row.add_suffix (grain_temporal);
        gr_temp_row.set_activatable_widget (grain_temporal);
        grain_expander.add_row (gr_temp_row);

        group.add (grain_expander);

        // ── Debanding ────────────────────────────────────────────────────────
        deband_check = new Switch ();
        deband_check.set_active (false);

        deband_expander = new Adw.ExpanderRow ();
        deband_expander.set_title ("Debanding");
        deband_expander.set_subtitle ("Remove color banding from gradients (sky, shadows)");
        deband_expander.set_show_enable_switch (true);
        deband_expander.set_enable_expansion (false);

        deband_check.bind_property ("active", deband_expander,
            "enable-expansion", BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        var db_thr_row = new Adw.ActionRow ();
        db_thr_row.set_title ("Threshold");
        db_thr_row.set_subtitle ("Banding detection sensitivity (higher = more aggressive)");
        deband_1thr = new SpinButton.with_range (0.005, 0.2, 0.005);
        deband_1thr.set_value (0.02);
        deband_1thr.set_digits (3);
        deband_1thr.set_valign (Align.CENTER);
        db_thr_row.add_suffix (deband_1thr);
        deband_expander.add_row (db_thr_row);

        var db_range_row = new Adw.ActionRow ();
        db_range_row.set_title ("Range");
        db_range_row.set_subtitle ("Pixel neighborhood to analyze (higher = slower)");
        deband_range = new SpinButton.with_range (1, 64, 1);
        deband_range.set_value (16);
        deband_range.set_valign (Align.CENTER);
        db_range_row.add_suffix (deband_range);
        deband_expander.add_row (db_range_row);

        var db_blur_row = new Adw.ActionRow ();
        db_blur_row.set_title ("Post-Blur");
        db_blur_row.set_subtitle ("Smooth over debanded areas to hide transitions");
        deband_blur = new Switch ();
        deband_blur.set_active (true);
        deband_blur.set_valign (Align.CENTER);
        db_blur_row.add_suffix (deband_blur);
        db_blur_row.set_activatable_widget (deband_blur);
        deband_expander.add_row (db_blur_row);

        group.add (deband_expander);

        container.append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  HDR TONE MAPPING
    // ═════════════════════════════════════════════════════════════════════════

    private void build_hdr_group () {
        var group = new Adw.PreferencesGroup ();
        group.set_title ("HDR Tone Mapping");
        group.set_description ("Convert HDR content for standard displays");

        hdr_tonemap_check = new Switch ();
        hdr_tonemap_check.set_active (false);

        hdr_expander = new Adw.ExpanderRow ();
        hdr_expander.set_title ("HDR to SDR");
        hdr_expander.set_subtitle ("Tone map HDR content for standard displays");
        hdr_expander.set_show_enable_switch (true);
        hdr_expander.set_enable_expansion (false);

        hdr_tonemap_check.bind_property ("active", hdr_expander,
            "enable-expansion", BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        var mode_row = new Adw.ActionRow ();
        mode_row.set_title ("Mode");
        tonemap_mode = new DropDown (new StringList (
            { "Standard", "Less Saturation", "Custom" }
        ), null);
        tonemap_mode.set_valign (Align.CENTER);
        tonemap_mode.set_selected (0);
        mode_row.add_suffix (tonemap_mode);
        hdr_expander.add_row (mode_row);

        tonemap_desat_row = new Adw.ActionRow ();
        tonemap_desat_row.set_title ("Desaturation");
        tonemap_desat_row.set_subtitle ("Custom desaturation level (0.00 – 1.00)");
        tonemap_desat = new SpinButton.with_range (0.0, 1.0, 0.01);
        tonemap_desat.set_value (0.35);
        tonemap_desat.set_digits (2);
        tonemap_desat.set_valign (Align.CENTER);
        tonemap_desat_row.add_suffix (tonemap_desat);
        tonemap_desat_row.set_visible (false);
        hdr_expander.add_row (tonemap_desat_row);

        // Signal: show/hide desaturation row
        tonemap_mode.notify["selected"].connect (() => {
            var item = tonemap_mode.selected_item as StringObject;
            string mode = item != null ? item.string : "";
            tonemap_desat_row.set_visible (mode == "Custom");
        });

        group.add (hdr_expander);

        container.append (group);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  FILTER STRING BUILDERS
    // ═════════════════════════════════════════════════════════════════════════

    // Returns processing filters (everything except HDR, which needs
    // special pipeline placement).  Called by FilterBuilder.
    public string[] get_processing_filters () {
        string[] filters = {};

        // ── Restoration ──────────────────────────────────────────────────────
        if (deinterlace_check.active) {
            int mode = (int) deinterlace_mode.get_selected ();   // 0=frame, 1=field
            int parity;
            switch (deinterlace_parity.get_selected ()) {
                case 1:  parity = 0; break;    // TFF
                case 2:  parity = 1; break;    // BFF
                default: parity = -1; break;   // Auto
            }
            filters += "yadif=%d:%d".printf (mode, parity);
        }

        if (deblock_check.active) {
            int a = (int) deblock_alpha.get_value ();
            int b = (int) deblock_beta.get_value ();
            filters += "deblock=filter=strong:block=8:alpha=%d:beta=%d".printf (a, b);
        }

        if (deflicker_check.active) {
            string[] modes = { "am", "gm", "hm", "median" };
            int idx = (int) deflicker_mode.get_selected ();
            string m = (idx >= 0 && idx < modes.length) ? modes[idx] : "am";
            int sz = (int) deflicker_size.get_value ();
            // Ensure odd
            if (sz % 2 == 0) sz++;
            filters += "deflicker=mode=%s:size=%d".printf (m, sz);
        }

        // ── Noise Reduction ──────────────────────────────────────────────────
        if (hqdn3d_check.active) {
            filters += "hqdn3d=%.1f:%.1f:%.1f:%.1f".printf (
                hqdn3d_luma_s.get_value (),
                hqdn3d_chroma_s.get_value (),
                hqdn3d_luma_t.get_value (),
                hqdn3d_chroma_t.get_value ()
            );
        }

        if (nlmeans_check.active) {
            double s = nlmeans_strength.get_value ();
            int p = (int) nlmeans_patch.get_value ();
            int r = (int) nlmeans_research.get_value ();

            if (nlmeans_gpu.active) {
                // OpenCL GPU path: upload → process → download
                // nlmeans_opencl supports limited formats — use the
                // highest bit depth that OpenCL can handle
                bool ten_bit = is_ten_bit_selected ();
                string fmt = ten_bit ? "yuv420p10le" : "yuv420p";
                filters += "format=" + fmt;
                filters += "hwupload";
                filters += "nlmeans_opencl=h=%.1f:p=%d:r=%d".printf (s, p, r);
                filters += "hwdownload";
                filters += "format=" + fmt;
            } else {
                filters += "nlmeans=s=%.1f:p=%d:r=%d".printf (s, p, r);
            }
        }

        if (median_check.active) {
            filters += "median=radius=%d".printf ((int) median_radius.get_value ());
        }

        // ── Sharpening ───────────────────────────────────────────────────────
        if (unsharp_check.active) {
            int[] sizes = { 3, 5, 7, 9, 13 };
            int idx = (int) unsharp_matrix.get_selected ();
            int sz = (idx >= 0 && idx < sizes.length) ? sizes[idx] : 5;
            filters += "unsharp=%d:%d:%.1f:%d:%d:%.1f".printf (
                sz, sz, unsharp_luma_amount.get_value (),
                sz, sz, unsharp_chroma_amount.get_value ()
            );
        }

        if (cas_check.active) {
            filters += "cas=%.2f".printf (cas_strength.get_value ());
        }

        // ── Blur ─────────────────────────────────────────────────────────────
        if (boxblur_check.active) {
            int lr = (int) boxblur_luma.get_value ();
            int cr = (int) boxblur_chroma.get_value ();
            int p  = (int) boxblur_passes.get_value ();
            filters += "boxblur=%d:%d:%d:%d".printf (lr, p, cr, p);
        }

        if (gblur_check.active) {
            filters += "gblur=sigma=%.1f".printf (gblur_sigma.get_value ());
        }

        // ── Grain & Texture ──────────────────────────────────────────────────
        if (grain_check.active) {
            int str = (int) grain_strength.get_value ();
            string flags = "";
            bool gauss = (grain_type.get_selected () == 1);
            if (grain_temporal.active && gauss)     flags = "t+n";
            else if (grain_temporal.active)          flags = "t";
            else if (gauss)                          flags = "n";
            if (flags != "")
                filters += "noise=alls=%d:allf=%s".printf (str, flags);
            else
                filters += "noise=alls=%d".printf (str);
        }

        if (deband_check.active) {
            string thr = "%.3f".printf (deband_1thr.get_value ());
            int range = (int) deband_range.get_value ();
            int blur = deband_blur.active ? 1 : 0;
            filters += "deband=1thr=%s:2thr=%s:3thr=%s:4thr=%s:range=%d:blur=%d".printf (
                thr, thr, thr, thr, range, blur
            );
        }

        return filters;
    }

    // Returns the HDR tonemap filter string (or "" if disabled).
    // Kept separate because it requires special placement in the pipeline
    // (after zscale linear conversion, before final output format).
    public string get_hdr_filter () {
        if (!hdr_tonemap_check.active) return "";

        string desat = "0.35";
        var item = tonemap_mode.selected_item as StringObject;
        string mode = item != null ? item.string : "";
        if (mode == "Less Saturation") desat = "0.00";
        else if (mode == "Custom") desat = "%.2f".printf (tonemap_desat.get_value ());

        return "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=%s,zscale=t=bt709:m=bt709:r=tv".printf (desat);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  RESET
    // ═════════════════════════════════════════════════════════════════════════

    public void reset_defaults () {
        // Restoration
        deinterlace_check.set_active (false);
        deinterlace_mode.set_selected (0);
        deinterlace_parity.set_selected (0);

        deblock_check.set_active (false);
        deblock_alpha.set_value (0);
        deblock_beta.set_value (0);

        deflicker_check.set_active (false);
        deflicker_mode.set_selected (0);
        deflicker_size.set_value (5);

        // Noise Reduction
        hqdn3d_check.set_active (false);
        hqdn3d_luma_s.set_value (4.0);
        hqdn3d_chroma_s.set_value (3.0);
        hqdn3d_luma_t.set_value (6.0);
        hqdn3d_chroma_t.set_value (4.5);

        nlmeans_check.set_active (false);
        nlmeans_gpu.set_active (false);
        nlmeans_strength.set_value (3.5);
        nlmeans_patch.set_value (7);
        nlmeans_research.set_value (15);

        median_check.set_active (false);
        median_radius.set_value (2);

        // Sharpening
        unsharp_check.set_active (false);
        unsharp_matrix.set_selected (1);
        unsharp_luma_amount.set_value (1.0);
        unsharp_chroma_amount.set_value (0.5);

        cas_check.set_active (false);
        cas_strength.set_value (0.4);

        // Blur
        boxblur_check.set_active (false);
        boxblur_luma.set_value (2);
        boxblur_chroma.set_value (2);
        boxblur_passes.set_value (1);

        gblur_check.set_active (false);
        gblur_sigma.set_value (1.5);

        // Grain & Texture
        grain_check.set_active (false);
        grain_strength.set_value (12);
        grain_type.set_selected (0);
        grain_temporal.set_active (true);

        deband_check.set_active (false);
        deband_1thr.set_value (0.02);
        deband_range.set_value (16);
        deband_blur.set_active (true);

        // HDR
        hdr_tonemap_check.set_active (false);
        tonemap_mode.set_selected (0);
        tonemap_desat.set_value (0.35);
    }
}
