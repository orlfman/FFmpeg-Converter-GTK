using GLib;

// AppSettings shares this one clamp with the otherwise unrelated optimizer.
// Keep the focused backend test target small by supplying the same bounds here.
namespace SmartOptimizerLogic {
    public int clamp_target_mb (int value) {
        return value.clamp (1, 16384);
    }
}

private bool spin_until (owned SourceFunc done, int timeout_ms) {
    MainContext context = MainContext.default ();
    int64 deadline = get_monotonic_time () + (int64) timeout_ms * 1000;

    while (!done () && get_monotonic_time () < deadline) {
        while (context.pending ())
            context.iteration (false);

        if (done ())
            break;

        Timeout.add (5, () => Source.REMOVE);
        context.iteration (true);
    }

    while (context.pending ())
        context.iteration (false);

    return done ();
}

private void run_failed_load_closes_backend (bool with_video) {
    string? temp_dir = null;

    try {
        temp_dir = DirUtils.make_tmp ("mpv-backend-failure-XXXXXX");
        string missing_path = Path.build_filename (temp_dir, "missing-media.mkv");

        var backend = new MpvBackend (with_video);
        bool failed = false;
        string detail = "";
        backend.load_failed.connect ((message) => {
            failed = true;
            detail = message;
        });

        // loadfile is asynchronous: accepting the command is not the same as
        // successfully opening the media.
        assert_true (backend.open (missing_path));
        assert_true (backend.has_core_for_test ());
        assert_true (backend.has_event_source_for_test ());
        // This headless test deliberately has no Gtk.Picture. The display-backed
        // player test covers the render context and GTK frame-clock source.
        assert_false (backend.has_render_context_for_test ());
        assert_false (backend.has_render_tick_for_test ());
        assert_true (spin_until (() => failed, 3000));
        assert_true (detail.length > 0);
        assert_false (backend.loaded);
        assert_true (backend.duration == 0.0);
        assert_false (backend.has_core_for_test ());
        assert_false (backend.has_render_context_for_test ());
        assert_false (backend.has_event_source_for_test ());
        assert_false (backend.has_render_tick_for_test ());

        // The failure handler already closed it; a second close must remain
        // harmless because player recovery calls close defensively too.
        backend.close ();
        assert_false (backend.loaded);
    } catch (FileError e) {
        Test.fail_printf ("failed to create temporary test directory: %s", e.message);
    } finally {
        if (temp_dir != null)
            DirUtils.remove (temp_dir);
    }
}

/**
 * Build a one-second clip with @audio_tracks audio streams. Returns null when
 * ffmpeg is unavailable or fails, so the caller can skip rather than fail.
 */
private string? make_clip_with_audio_tracks (string dir, int audio_tracks) {
    string path = Path.build_filename (dir, "tracks.mkv");

    string[] argv = { "ffmpeg", "-v", "error", "-y",
                      "-f", "lavfi", "-i", "testsrc2=s=160x120:rate=10:d=1" };
    for (int i = 0; i < audio_tracks; i++) {
        argv += "-f";
        argv += "lavfi";
        argv += "-i";
        argv += "sine=f=%d:d=1".printf (300 + i * 100);
    }
    argv += "-map"; argv += "0:v";
    for (int i = 0; i < audio_tracks; i++) {
        argv += "-map";
        argv += "%d:a".printf (i + 1);
    }
    argv += "-c:v"; argv += "libx264";
    argv += "-pix_fmt"; argv += "yuv420p";
    argv += "-c:a"; argv += "libopus";
    argv += path;

    try {
        int status = 0;
        Process.spawn_sync (null, argv, null,
                            SpawnFlags.SEARCH_PATH
                            | SpawnFlags.STDOUT_TO_DEV_NULL
                            | SpawnFlags.STDERR_TO_DEV_NULL,
                            null, null, null, out status);
        if (status != 0 || !FileUtils.test (path, FileTest.EXISTS))
            return null;
        return path;
    } catch (SpawnError e) {
        return null;
    }
}

/**
 * An audio index past the end of the file leaves mpv with nothing selected, so
 * an audio-only backend fails the load rather than opening a mute preview. mpv
 * blames that on "no audio or video data played" without mentioning the
 * selection, and by then its track list is gone — so the backend has to name
 * the requested stream itself or the failure is undiagnosable.
 */
private void test_out_of_range_audio_index_reports_the_stream () {
    string? temp_dir = null;

    try {
        temp_dir = DirUtils.make_tmp ("mpv-backend-aid-XXXXXX");

        string? path = make_clip_with_audio_tracks (temp_dir, 2);
        if (path == null) {
            Test.skip ("ffmpeg unavailable, cannot build a multi-track fixture");
            return;
        }

        var backend = new MpvBackend (false);
        bool failed = false;
        string detail = "";
        backend.load_failed.connect ((message) => {
            failed = true;
            detail = message;
        });

        // Stream 5 of a file with two audio streams.
        assert_true (backend.open (path, 5));
        assert_true (spin_until (() => failed, 5000));
        assert_true (detail.contains ("audio stream 5"));

        // Terminal, exactly as any other load failure is.
        assert_false (backend.loaded);
        assert_false (backend.has_core_for_test ());
        assert_false (backend.has_event_source_for_test ());

        // An in-range index must still load and select precisely that stream.
        // mpv counts audio tracks from 1, so index 1 is "aid=2".
        var second = new MpvBackend (false);
        bool ready = false;
        second.file_loaded.connect (() => ready = true);

        assert_true (second.open (path, 1));
        assert_true (spin_until (() => ready, 5000));
        assert_cmpint (second.audio_track_count_for_test (), CompareOperator.EQ, 2);
        assert_cmpstr (second.selected_aid_for_test (), CompareOperator.EQ, "2");

        second.close ();

        FileUtils.remove (path);
    } catch (FileError e) {
        Test.fail_printf ("failed to create temporary test directory: %s", e.message);
    } finally {
        if (temp_dir != null)
            DirUtils.remove (temp_dir);
    }
}

/**
 * MPV_EVENT_SHUTDOWN leaves destruction as the only legal operation on the
 * handle. Returning from the event pump without tearing down used to keep the
 * core and its timers alive, and because the poll timer holds a reference to
 * the backend, that pinned the whole object behind a poll that could never
 * accomplish anything again.
 */
private void test_shutdown_tears_down_the_core () {
    string? temp_dir = null;

    try {
        temp_dir = DirUtils.make_tmp ("mpv-backend-shutdown-XXXXXX");

        string? path = make_clip_with_audio_tracks (temp_dir, 1);
        if (path == null) {
            Test.skip ("ffmpeg unavailable, cannot build a fixture");
            return;
        }

        var backend = new MpvBackend (false);
        bool ready = false;
        bool failed = false;
        backend.file_loaded.connect (() => ready = true);
        backend.load_failed.connect (() => failed = true);

        assert_true (backend.open (path));
        assert_true (spin_until (() => ready, 5000));
        assert_true (backend.has_core_for_test ());
        assert_true (backend.has_event_source_for_test ());

        backend.request_shutdown_for_test ();
        assert_true (spin_until (() => failed, 5000));

        assert_false (backend.has_core_for_test ());
        assert_false (backend.has_event_source_for_test ());
        assert_false (backend.loaded);

        backend.close ();
        FileUtils.remove (path);
    } catch (FileError e) {
        Test.fail_printf ("failed to create temporary test directory: %s", e.message);
    } finally {
        if (temp_dir != null)
            DirUtils.remove (temp_dir);
    }
}

/**
 * Events and frames now arrive through mpv's wakeup and render-update
 * callbacks, which fire on mpv's own threads and schedule idles onto the main
 * loop. Closing while a load is still in flight is therefore the interesting
 * case: an idle can already be queued for a handle that is about to go away.
 *
 * Cycles open/close hard enough to hit that window repeatedly, mixing loads
 * that succeed with loads that fail, and asserts that nothing runs against a
 * torn-down core afterwards.
 */
private void test_open_close_cycles_leave_nothing_running () {
    string? temp_dir = null;

    try {
        temp_dir = DirUtils.make_tmp ("mpv-backend-cycle-XXXXXX");

        string? path = make_clip_with_audio_tracks (temp_dir, 1);
        if (path == null) {
            Test.skip ("ffmpeg unavailable, cannot build a fixture");
            return;
        }
        string missing = Path.build_filename (temp_dir, "missing.mkv");

        var backend = new MpvBackend (false);
        int signals_after_close = 0;
        bool closed = false;

        backend.file_loaded.connect (() => { if (closed) signals_after_close++; });
        backend.load_failed.connect (() => { if (closed) signals_after_close++; });

        for (int i = 0; i < 30; i++) {
            closed = false;
            assert_true (backend.open (i % 3 == 0 ? missing : path));
            assert_true (backend.has_event_source_for_test ());

            // Close at a different point in the load each iteration, so the
            // teardown lands before, during and after the callbacks fire.
            int spins = i % 5;
            for (int s = 0; s < spins; s++) {
                MainContext.default ().iteration (false);
            }

            closed = true;
            backend.close ();

            assert_false (backend.has_core_for_test ());
            assert_false (backend.has_event_source_for_test ());
            assert_false (backend.has_render_tick_for_test ());
            assert_false (backend.loaded);

            // Anything already queued runs now. It must find the torn-down
            // state and do nothing rather than touching a dead handle.
            for (int s = 0; s < 20; s++) {
                MainContext.default ().iteration (false);
            }
        }

        assert_cmpint (signals_after_close, CompareOperator.EQ, 0);

        // Still usable afterwards: the coalescing flags must not have been left
        // latched by a cycle that closed mid-flight.
        closed = false;
        bool ready = false;
        backend.file_loaded.connect (() => ready = true);
        assert_true (backend.open (path));
        assert_true (spin_until (() => ready, 5000));

        backend.close ();
        FileUtils.remove (path);
    } catch (FileError e) {
        Test.fail_printf ("failed to create temporary test directory: %s", e.message);
    } finally {
        if (temp_dir != null)
            DirUtils.remove (temp_dir);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Pure decisions
//
//  Branch-level cover for the arithmetic the backend does before it touches
//  libmpv or GTK. The cases above drive a live core, which exercises the happy
//  path of each of these but not their edges.
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Three different coordinate spaces exist here and confusing them is the
 * expensive mistake: a wrong render size makes a preview look wrong and
 * someone notices, whereas a wrong crop space silently writes a wrong file.
 */
private void test_crop_space_swaps_axes_only_on_quarter_turns () {
    // Upright and half turns keep the coded axes.
    assert_cmpint (MpvBackend.crop_space_width (0, 1920, 1080), CompareOperator.EQ, 1920);
    assert_cmpint (MpvBackend.crop_space_height (0, 1920, 1080), CompareOperator.EQ, 1080);
    assert_cmpint (MpvBackend.crop_space_width (180, 1920, 1080), CompareOperator.EQ, 1920);
    assert_cmpint (MpvBackend.crop_space_height (180, 1920, 1080), CompareOperator.EQ, 1080);

    // Quarter turns swap them, in both directions.
    assert_cmpint (MpvBackend.crop_space_width (90, 1920, 1080), CompareOperator.EQ, 1080);
    assert_cmpint (MpvBackend.crop_space_height (90, 1920, 1080), CompareOperator.EQ, 1920);
    assert_cmpint (MpvBackend.crop_space_width (270, 1920, 1080), CompareOperator.EQ, 1080);
    assert_cmpint (MpvBackend.crop_space_height (270, 1920, 1080), CompareOperator.EQ, 1920);

    assert_true (MpvBackend.is_quarter_turn (90));
    assert_true (MpvBackend.is_quarter_turn (270));
    assert_false (MpvBackend.is_quarter_turn (0));
    assert_false (MpvBackend.is_quarter_turn (180));
}

/**
 * display_aspect is the drawn aspect, which differs from the crop space
 * whenever pixels are not square — the case the two must not be confused in.
 */
private void test_display_aspect_reports_drawn_shape () {
    // 720x576 with 64:45 pixels is drawn 1024x576.
    assert_cmpfloat (MpvBackend.aspect_of (1024, 576), CompareOperator.GT, 1.77);
    assert_cmpfloat (MpvBackend.aspect_of (1024, 576), CompareOperator.LT, 1.78);

    // Rotated a quarter turn it is drawn 576x1024, and the correction has moved
    // to the other axis rather than simply inverting.
    assert_cmpfloat (MpvBackend.aspect_of (576, 1024), CompareOperator.GT, 0.56);
    assert_cmpfloat (MpvBackend.aspect_of (576, 1024), CompareOperator.LT, 0.57);

    // Unknown until dimensions arrive, and never a division by zero.
    assert_cmpfloat (MpvBackend.aspect_of (0, 1080), CompareOperator.EQ, 0.0);
    assert_cmpfloat (MpvBackend.aspect_of (1920, 0), CompareOperator.EQ, 0.0);
    assert_cmpfloat (MpvBackend.aspect_of (-1, -1), CompareOperator.EQ, 0.0);
}

private void test_rotation_normalisation_and_filters () {
    assert_cmpint (MpvBackend.normalize_rotation (90), CompareOperator.EQ, 90);
    assert_cmpint (MpvBackend.normalize_rotation (180), CompareOperator.EQ, 180);
    assert_cmpint (MpvBackend.normalize_rotation (270), CompareOperator.EQ, 270);
    assert_cmpint (MpvBackend.normalize_rotation (0), CompareOperator.EQ, 0);

    // Wraps, including the negative angles containers actually carry.
    assert_cmpint (MpvBackend.normalize_rotation (450), CompareOperator.EQ, 90);
    assert_cmpint (MpvBackend.normalize_rotation (-90), CompareOperator.EQ, 270);
    assert_cmpint (MpvBackend.normalize_rotation (-270), CompareOperator.EQ, 90);
    assert_cmpint (MpvBackend.normalize_rotation (360), CompareOperator.EQ, 0);

    // Anything off the right angles cannot be expressed as a transpose, so it
    // is treated as upright rather than guessed at.
    assert_cmpint (MpvBackend.normalize_rotation (45), CompareOperator.EQ, 0);
    assert_cmpint (MpvBackend.normalize_rotation (91), CompareOperator.EQ, 0);

    // Clockwise, matching mpv's angle and ffmpeg's own autorotate.
    assert_cmpstr (MpvBackend.rotation_filter (90), CompareOperator.EQ, "transpose=clock");
    assert_cmpstr (MpvBackend.rotation_filter (270), CompareOperator.EQ, "transpose=cclock");
    assert_cmpstr (MpvBackend.rotation_filter (180), CompareOperator.EQ,
                   "transpose=clock,transpose=clock");
    assert_null (MpvBackend.rotation_filter (0));
}

/**
 * The paintable is held back until the transpose has taken effect, or a
 * sideways frame reaches the screen and is snapped upright a moment later.
 */
private void test_rotation_settles_only_once_axes_swap () {
    // Nothing to wait for when there is no quarter turn.
    assert_true (MpvBackend.rotation_is_settled (0, 1920, 1080, 1920, 1080));
    assert_true (MpvBackend.rotation_is_settled (180, 1920, 1080, 1920, 1080));

    // Quarter turn, drawn frame still the coded orientation: not settled.
    assert_false (MpvBackend.rotation_is_settled (90, 1920, 1080, 1920, 1080));
    assert_false (MpvBackend.rotation_is_settled (270, 1080, 1920, 1080, 1920));

    // Once the axes have swapped it is settled.
    assert_true (MpvBackend.rotation_is_settled (90, 1920, 1080, 1080, 1920));
    assert_true (MpvBackend.rotation_is_settled (270, 1080, 1920, 1920, 1080));

    // A square frame is the same either way, so it must not wait forever.
    assert_true (MpvBackend.rotation_is_settled (90, 1080, 1080, 1080, 1080));
}

/**
 * The Preferences enums are stored as tokens, never as dropdown indices, so
 * that reordering a list cannot silently change what an existing settings file
 * means. These check the tokens survive a round trip and that the values handed
 * to mpv keep the properties the backend depends on.
 */
private void test_preview_enums_round_trip_and_stay_valid () {
    foreach (HwdecMode mode in HwdecMode.all ()) {
        assert_true (HwdecMode.from_string (mode.to_string ()) == mode);

        // The preview renders in software, so frames must come back to system
        // memory: every decoder offered has to be a copy mode, or "no". A
        // plain GPU-surface mode would render nothing at all.
        //
        // Matched on "copy" appearing anywhere rather than as a suffix,
        // because mpv spells the automatic ones "auto-copy-safe" and
        // "auto-copy-unsafe" — the qualifier comes after the copy.
        foreach (string part in mode.to_mpv_option ().split (",")) {
            assert_true (part == "no" || "copy" in part);
        }

        assert_true (mode.get_label () != "");
        assert_true (mode.get_description () != "");
    }

    foreach (PreviewQuality quality in PreviewQuality.all ()) {
        assert_true (PreviewQuality.from_string (quality.to_string ()) == quality);

        // Flat name/value pairs, so an odd length would silently drop the last
        // option — or read past the end of the array.
        string[] opts = quality.to_mpv_options ();
        assert_true (opts.length > 0);
        assert_true (opts.length % 2 == 0);
    }

    foreach (PreviewCacheSize size in PreviewCacheSize.all ()) {
        assert_true (PreviewCacheSize.from_string (size.to_string ()) == size);
        assert_true (size.forward_bytes () != "");
        assert_true (size.back_bytes () != "");
    }

    // An unknown token is a settings file from a newer build, or a corrupt
    // one. Both must land on the safe default rather than anything exotic.
    assert_true (HwdecMode.from_string ("bogus") == HwdecMode.AUTOMATIC);
    assert_true (PreviewQuality.from_string ("bogus") == PreviewQuality.FAST);
    assert_true (PreviewCacheSize.from_string ("bogus") == PreviewCacheSize.SMALL);

    // Small is what the demuxer bound was before it became configurable, and
    // changing it would quietly change the default memory profile.
    assert_cmpstr (PreviewCacheSize.SMALL.forward_bytes (),
                   CompareOperator.EQ, "32MiB");
    assert_cmpstr (PreviewCacheSize.SMALL.back_bytes (),
                   CompareOperator.EQ, "16MiB");
}

/**
 * The GPU name is scraped out of mpv's log because no property reports it, so
 * the exact wording of two driver messages is load-bearing. Both strings below
 * are verbatim from ffmpeg 62 as shipped, captured with --msg-level=all=debug.
 */
private void test_gpu_name_parsed_from_decoder_log () {
    // Vulkan: the device class and PCI id are noise and get dropped.
    assert_cmpstr (
        MpvBackend.parse_gpu_from_log (
            "Vulkan: Device 0 selected: AMD Radeon RX 9070 XT (RADV GFX1201) (discrete) (0x7550)"),
        CompareOperator.EQ, "AMD Radeon RX 9070 XT (RADV GFX1201)");

    assert_cmpstr (
        MpvBackend.parse_gpu_from_log (
            "Vulkan: Device 1 selected: Intel(R) Graphics (ARL) (integrated) (0x7d67)"),
        CompareOperator.EQ, "Intel(R) Graphics (ARL)");

    // VAAPI: the trailing driver version dates the package, not the hardware.
    assert_cmpstr (
        MpvBackend.parse_gpu_from_log (
            "VAAPI: VAAPI driver: Intel iHD driver for Intel(R) Gen Graphics - 26.1.5 ()."),
        CompareOperator.EQ, "Intel iHD driver for Intel(R) Gen Graphics");

    // The enumeration lines that precede the selection must not be mistaken
    // for it — on a hybrid machine they name the GPU that was NOT chosen.
    assert_null (MpvBackend.parse_gpu_from_log (
        "Vulkan:     1: Intel(R) Graphics (ARL) (integrated) (0x7d67)"));

    // Unrelated chatter reports nothing rather than guessing.
    assert_null (MpvBackend.parse_gpu_from_log (
        "Vulkan: Using device extension VK_KHR_push_descriptor"));
    assert_null (MpvBackend.parse_gpu_from_log (""));
}

private void test_render_size_fits_drawn_aspect_without_upscaling () {
    int w, h;

    // Widget larger than the source: clamped to the source, never upscaled.
    assert_true (MpvBackend.fit_render_size (3000, 3000, 1280, 720, out w, out h));
    assert_cmpint (w, CompareOperator.EQ, 1280);
    assert_cmpint (h, CompareOperator.EQ, 720);

    // Widget smaller: scaled down at the drawn aspect, not the widget's.
    assert_true (MpvBackend.fit_render_size (640, 640, 1280, 720, out w, out h));
    assert_cmpint (w, CompareOperator.EQ, 640);
    assert_cmpint (h, CompareOperator.EQ, 360);

    // Capped at 1920x1080 however large the widget and source are.
    assert_true (MpvBackend.fit_render_size (5000, 5000, 3840, 2160, out w, out h));
    assert_cmpint (w, CompareOperator.EQ, 1920);
    assert_cmpint (h, CompareOperator.EQ, 1080);

    // Portrait sources are limited by the height cap, not the width one.
    assert_true (MpvBackend.fit_render_size (5000, 5000, 2160, 3840, out w, out h));
    assert_cmpint (h, CompareOperator.EQ, 1080);
    assert_cmpint (w, CompareOperator.EQ, 608);

    // Never degenerate: a widget of a couple of pixels still yields a target
    // mpv can render into.
    assert_true (MpvBackend.fit_render_size (1, 1, 1920, 1080, out w, out h));
    assert_cmpint (w, CompareOperator.GE, 2);
    assert_cmpint (h, CompareOperator.GE, 2);

    // Nothing known yet, or the widget is unallocated.
    assert_false (MpvBackend.fit_render_size (800, 600, 0, 0, out w, out h));
    assert_false (MpvBackend.fit_render_size (0, 0, 1920, 1080, out w, out h));
    assert_false (MpvBackend.fit_render_size (-5, 600, 1920, 1080, out w, out h));
}

private void test_frame_geometry_rounds_stride_to_64_bytes () {
    int stride, size, row_bytes;

    // Already aligned: 1920 * 4 is a multiple of 64.
    assert_true (MpvBackend.frame_geometry_for (1920, 1080,
                                                out stride, out size, out row_bytes));
    assert_cmpint (stride, CompareOperator.EQ, 7680);
    assert_cmpint (row_bytes, CompareOperator.EQ, 7680);
    assert_cmpint (size, CompareOperator.EQ, 7680 * 1080);

    // 1080 * 4 = 4320 rounds up to 4352, leaving 32 bytes of padding per row.
    assert_true (MpvBackend.frame_geometry_for (1080, 1920,
                                                out stride, out size, out row_bytes));
    assert_cmpint (stride, CompareOperator.EQ, 4352);
    assert_cmpint (row_bytes, CompareOperator.EQ, 4320);
    assert_cmpint (stride - row_bytes, CompareOperator.EQ, 32);
    assert_cmpint (size, CompareOperator.EQ, 4352 * 1920);

    // Stride is always a multiple of 64, and always covers the visible row.
    for (int width = 1; width <= 200; width++) {
        assert_true (MpvBackend.frame_geometry_for (width, 4,
                                                    out stride, out size, out row_bytes));
        assert_cmpint (stride % 64, CompareOperator.EQ, 0);
        assert_cmpint (stride, CompareOperator.GE, row_bytes);
        assert_cmpint (size, CompareOperator.EQ, stride * 4);
    }

    assert_false (MpvBackend.frame_geometry_for (0, 1080,
                                                 out stride, out size, out row_bytes));
    assert_false (MpvBackend.frame_geometry_for (1920, 0,
                                                 out stride, out size, out row_bytes));
}

private void test_audio_index_mapping_and_range_check () {
    // Zero-based to mpv's one-based aid.
    assert_cmpstr (MpvBackend.aid_option_for_index (0), CompareOperator.EQ, "1");
    assert_cmpstr (MpvBackend.aid_option_for_index (1), CompareOperator.EQ, "2");
    assert_cmpstr (MpvBackend.aid_option_for_index (7), CompareOperator.EQ, "8");

    // In range for a two-stream file.
    assert_false (MpvBackend.audio_index_is_out_of_range (0, 2));
    assert_false (MpvBackend.audio_index_is_out_of_range (1, 2));

    // Past the end.
    assert_true (MpvBackend.audio_index_is_out_of_range (2, 2));
    assert_true (MpvBackend.audio_index_is_out_of_range (5, 2));

    // "Let mpv choose" is never out of range.
    assert_false (MpvBackend.audio_index_is_out_of_range (-1, 2));

    // A file with no audio is not an out-of-range selection: there is nothing
    // to select and no fallback that would help.
    assert_false (MpvBackend.audio_index_is_out_of_range (0, 0));
    assert_false (MpvBackend.audio_index_is_out_of_range (3, 0));
}

private void test_failed_audio_load_closes_backend () {
    run_failed_load_closes_backend (false);
}

private void test_failed_video_load_closes_backend () {
    run_failed_load_closes_backend (true);
}

int main (string[] args) {
    string config_root;
    try {
        config_root = DirUtils.make_tmp ("mpv-backend-config-XXXXXX");
    } catch (FileError e) {
        stderr.printf ("failed to create isolated config directory: %s\n", e.message);
        return 1;
    }

    // MpvBackend consults the AppSettings singleton for hwdec policy. Keep the
    // integration test isolated from the user's real settings file.
    Environment.set_variable ("XDG_CONFIG_HOME", config_root, true);

    Test.init (ref args);

    // Pure decisions: no libmpv core, no display, no fixtures.
    Test.add_func ("/mpv-backend/logic/crop-space-swaps-on-quarter-turns",
                   test_crop_space_swaps_axes_only_on_quarter_turns);
    Test.add_func ("/mpv-backend/logic/display-aspect-reports-drawn-shape",
                   test_display_aspect_reports_drawn_shape);
    Test.add_func ("/mpv-backend/logic/rotation-normalisation-and-filters",
                   test_rotation_normalisation_and_filters);
    Test.add_func ("/mpv-backend/logic/rotation-settles-once-axes-swap",
                   test_rotation_settles_only_once_axes_swap);
    Test.add_func ("/mpv-backend/logic/render-size-fits-without-upscaling",
                   test_render_size_fits_drawn_aspect_without_upscaling);
    Test.add_func ("/mpv-backend/logic/gpu-name-parsed-from-decoder-log",
                   test_gpu_name_parsed_from_decoder_log);
    Test.add_func ("/mpv-backend/logic/preview-enums-round-trip",
                   test_preview_enums_round_trip_and_stay_valid);
    Test.add_func ("/mpv-backend/logic/frame-geometry-stride-alignment",
                   test_frame_geometry_rounds_stride_to_64_bytes);
    Test.add_func ("/mpv-backend/logic/audio-index-mapping-and-range",
                   test_audio_index_mapping_and_range_check);

    Test.add_func ("/mpv-backend/failed-audio-load-closes-core",
                   test_failed_audio_load_closes_backend);
    Test.add_func ("/mpv-backend/failed-video-load-closes-core",
                   test_failed_video_load_closes_backend);
    Test.add_func ("/mpv-backend/out-of-range-audio-index-reports-the-stream",
                   test_out_of_range_audio_index_reports_the_stream);
    Test.add_func ("/mpv-backend/shutdown-tears-down-the-core",
                   test_shutdown_tears_down_the_core);
    Test.add_func ("/mpv-backend/open-close-cycles-leave-nothing-running",
                   test_open_close_cycles_leave_nothing_running);
    int result = Test.run ();

    string app_config_dir = Path.build_filename (config_root,
                                                  "FFmpeg-Converter-GTK");
    DirUtils.remove (app_config_dir);
    DirUtils.remove (config_root);
    return result;
}
