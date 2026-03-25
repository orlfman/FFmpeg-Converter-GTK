using Gtk;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  AudioSegment — Simple start/end time pair for waveform highlight rendering
// ═══════════════════════════════════════════════════════════════════════════════

public class AudioSegment : Object {
    public double start_time { get; set; }
    public double end_time   { get; set; }

    public AudioSegment (double start, double end) {
        this.start_time = start;
        this.end_time   = end;
    }

    public double get_duration () {
        return (end_time - start_time).clamp (0.0, double.MAX);
    }

    public AudioSegment copy () {
        return new AudioSegment (start_time, end_time);
    }
}

class AudioWaveformCacheEntry : Object {
    public ConversionUtils.FileSignature signature;
    public Gdk.Texture texture;

    public AudioWaveformCacheEntry (ConversionUtils.FileSignature signature,
                                    Gdk.Texture texture) {
        this.signature = signature;
        this.texture = texture;
    }
}

class AudioPlaybackCacheEntry : Object {
    public ConversionUtils.FileSignature signature;
    public string extracted_path;

    public AudioPlaybackCacheEntry (ConversionUtils.FileSignature signature,
                                    string extracted_path) {
        this.signature = signature;
        this.extracted_path = extracted_path;
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  AudioPlayer — Waveform-based audio player with segment highlights
//
//  Uses Gtk.MediaFile for playback and FFmpeg showwavespic for waveform
//  generation.  The waveform is displayed as a Gtk.Picture with an
//  click-to-seek waveform and segment highlight drawing.
// ═══════════════════════════════════════════════════════════════════════════════

public class AudioPlayer : Box {

    // ── Widgets ──────────────────────────────────────────────────────────────
    private Gtk.Picture waveform_picture;
    private Gtk.Overlay waveform_overlay;
    private Gtk.Frame waveform_frame;
    private Gtk.DrawingArea segment_overlay;
    private Gtk.Spinner waveform_spinner;
    private Gtk.Label spinner_label;
    private Box spinner_box;
    private Gtk.GestureDrag waveform_drag;
    private Gtk.Label time_label;
    private Gtk.Label duration_label;
    private Gtk.Button play_button;
    private Gtk.MediaFile? media = null;

    // ── State ────────────────────────────────────────────────────────────────
    private uint update_source = 0;
    private uint prepare_poll = 0;
    private uint scrub_reset_source = 0;
    private ulong media_prepared_handler_id = 0;
    private bool user_scrubbing = false;
    private bool is_playing = false;
    private bool prepared_handled = false;
    private double _duration = 0.0;
    private string? waveform_tmp_path = null;
    private Cancellable? waveform_cancellable = null;
    private Subprocess? waveform_proc = null;
    private uint waveform_generation = 0;
    private string current_waveform_input_path = "";
    private int current_waveform_stream_index = 0;
    private string? playback_tmp_path = null;
    private Cancellable? playback_extract_cancellable = null;
    private Subprocess? playback_extract_proc = null;
    private uint playback_extract_generation = 0;
    private ulong style_manager_dark_handler_id = 0;
    private HashTable<string, AudioWaveformCacheEntry> waveform_cache =
        new HashTable<string, AudioWaveformCacheEntry> (str_hash, str_equal);
    private string[] waveform_cache_lru = {};
    private HashTable<string, AudioPlaybackCacheEntry> playback_cache =
        new HashTable<string, AudioPlaybackCacheEntry> (str_hash, str_equal);
    private string[] playback_cache_lru = {};

    private const int MAX_WAVEFORM_CACHE_ENTRIES = 12;
    private const int MAX_PLAYBACK_CACHE_ENTRIES = 4;

    // ── Segment highlights ───────────────────────────────────────────────────
    private GenericArray<AudioSegment> highlight_segments = new GenericArray<AudioSegment> ();

    // ── Signals ──────────────────────────────────────────────────────────────
    public signal void position_changed (double seconds);
    public signal void media_ready (double duration_seconds);

    // ═════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═════════════════════════════════════════════════════════════════════════

    public AudioPlayer () {
        Object (orientation: Orientation.VERTICAL, spacing: 0);
        PlayerStyles.ensure_loaded ();
        inject_audio_player_css ();
        build_ui ();
        connect_style_manager ();
    }

    private static bool audio_player_css_injected = false;

    private static void inject_audio_player_css () {
        if (audio_player_css_injected) return;
        audio_player_css_injected = true;

        var css = new CssProvider ();
        css.load_from_string (
            // Waveform container — theme-aware surface
            ".waveform-frame {\n" +
            "    background: mix(@window_bg_color, @window_fg_color, 0.08);\n" +
            "    border-radius: 10px;\n" +
            "    border: 1px solid alpha(@window_fg_color, 0.08);\n" +
            "}\n" +
            // Loading overlay — matches waveform background
            ".waveform-loading {\n" +
            "    background: alpha(mix(@window_bg_color, @window_fg_color, 0.08), 0.9);\n" +
            "    border-radius: 10px;\n" +
            "}\n"
        );
        GtkCompat.add_provider_for_display (
            Gdk.Display.get_default (),
            css,
            STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }

    private void connect_style_manager () {
        var style_manager = Adw.StyleManager.get_default ();
        style_manager_dark_handler_id = style_manager.notify["dark"].connect (() => {
            refresh_waveform_for_theme_change ();
        });
    }

    private void disconnect_style_manager () {
        if (style_manager_dark_handler_id == 0)
            return;

        Adw.StyleManager.get_default ().disconnect (style_manager_dark_handler_id);
        style_manager_dark_handler_id = 0;
    }

    private void refresh_waveform_for_theme_change () {
        if (current_waveform_input_path.length == 0)
            return;

        generate_waveform_async (
            current_waveform_input_path,
            current_waveform_stream_index
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  UI CONSTRUCTION
    // ═════════════════════════════════════════════════════════════════════════

    private void build_ui () {

        // ── Waveform Display ────────────────────────────────────────────────
        waveform_frame = new Gtk.Frame (null);
        waveform_frame.add_css_class ("waveform-frame");

        waveform_picture = new Gtk.Picture ();
        waveform_picture.set_size_request (-1, 140);
        waveform_picture.set_vexpand (false);
        waveform_picture.set_content_fit (ContentFit.FILL);

        // Segment highlight overlay (drawn on top of waveform)
        segment_overlay = new Gtk.DrawingArea ();
        segment_overlay.set_draw_func (draw_segment_highlights);

        // Spinner for waveform generation (fills entire overlay, content centered)
        spinner_box = new Box (Orientation.VERTICAL, 8);
        spinner_box.set_halign (Align.CENTER);
        spinner_box.set_valign (Align.CENTER);
        spinner_box.set_hexpand (true);
        spinner_box.set_vexpand (true);
        spinner_box.add_css_class ("waveform-loading");
        waveform_spinner = new Gtk.Spinner ();
        waveform_spinner.set_size_request (32, 32);
        spinner_label = new Gtk.Label ("Generating waveform…");
        spinner_label.add_css_class ("dim-label");
        spinner_box.append (waveform_spinner);
        spinner_box.append (spinner_label);
        spinner_box.set_visible (false);

        waveform_overlay = new Gtk.Overlay ();
        waveform_overlay.set_child (waveform_picture);
        waveform_overlay.add_overlay (segment_overlay);
        waveform_overlay.add_overlay (spinner_box);

        waveform_frame.set_child (waveform_overlay);
        append (waveform_frame);

        // ── Waveform click/drag seek (on segment_overlay for matched coords) ─
        segment_overlay.set_cursor_from_name ("pointer");

        var click = new Gtk.GestureClick ();
        click.set_button (1);
        click.pressed.connect ((n_press, x, y) => {
            seek_to_waveform_x (x);
        });
        segment_overlay.add_controller (click);

        waveform_drag = new Gtk.GestureDrag ();
        waveform_drag.drag_begin.connect ((start_x, start_y) => {
            user_scrubbing = true;
            seek_to_waveform_x (start_x);
        });
        waveform_drag.drag_update.connect (on_waveform_drag_update);
        waveform_drag.drag_end.connect ((offset_x, offset_y) => {
            cancel_scrub_reset ();
            scrub_reset_source = Timeout.add (120, () => {
                user_scrubbing = false;
                scrub_reset_source = 0;
                return Source.REMOVE;
            });
        });
        segment_overlay.add_controller (waveform_drag);

        // ── Transport Controls ──────────────────────────────────────────────
        var controls = new Box (Orientation.HORIZONTAL, 0);
        controls.set_halign (Align.CENTER);
        controls.set_margin_top (8);
        controls.set_margin_bottom (4);
        controls.add_css_class ("transport-bar");

        // Seek buttons — grouped as a linked box
        var seek_group = new Box (Orientation.HORIZONTAL, 0);
        seek_group.add_css_class ("linked");

        var seek_back = new Button.from_icon_name ("media-seek-backward-symbolic");
        seek_back.set_tooltip_text ("Seek back 5 seconds");
        seek_back.clicked.connect (() => seek_relative (-5.0));
        seek_group.append (seek_back);

        var fine_back = new Button.from_icon_name ("go-previous-symbolic");
        fine_back.set_tooltip_text ("Step back 0.1 seconds");
        fine_back.clicked.connect (() => {
            ensure_paused ();
            seek_relative (-0.1);
        });
        seek_group.append (fine_back);

        controls.append (seek_group);

        // Play / Pause — center focus
        play_button = new Button.from_icon_name ("media-playback-start-symbolic");
        play_button.set_tooltip_text ("Play / Pause");
        play_button.add_css_class ("suggested-action");
        play_button.add_css_class ("circular");
        play_button.set_margin_start (10);
        play_button.set_margin_end (10);
        play_button.clicked.connect (toggle_playback);
        controls.append (play_button);

        // Forward seek group
        var fwd_group = new Box (Orientation.HORIZONTAL, 0);
        fwd_group.add_css_class ("linked");

        var fine_fwd = new Button.from_icon_name ("go-next-symbolic");
        fine_fwd.set_tooltip_text ("Step forward 0.1 seconds");
        fine_fwd.clicked.connect (() => {
            ensure_paused ();
            seek_relative (0.1);
        });
        fwd_group.append (fine_fwd);

        var seek_fwd = new Button.from_icon_name ("media-seek-forward-symbolic");
        seek_fwd.set_tooltip_text ("Seek forward 5 seconds");
        seek_fwd.clicked.connect (() => seek_relative (5.0));
        fwd_group.append (seek_fwd);

        controls.append (fwd_group);

        // Time display — styled readout
        var time_box = new Box (Orientation.HORIZONTAL, 4);
        time_box.add_css_class ("transport-time");
        time_box.set_margin_start (14);

        time_label = new Label ("00:00:00.000");
        time_label.add_css_class ("monospace");
        time_box.append (time_label);

        var slash = new Label ("/");
        slash.add_css_class ("dim-label");
        time_box.append (slash);

        duration_label = new Label ("00:00:00.000");
        duration_label.add_css_class ("monospace");
        duration_label.add_css_class ("dim-label");
        time_box.append (duration_label);

        controls.append (time_box);

        append (controls);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PUBLIC API
    // ═════════════════════════════════════════════════════════════════════════

    public void load_file (string path, int stream_index = 0) {
        reset_player_state ();
        current_waveform_input_path = path;
        current_waveform_stream_index = stream_index;
        ConversionUtils.FileSignature? signature = (path.length > 0)
            ? ConversionUtils.query_file_signature (path)
            : null;

        // Start waveform generation (targets specific stream)
        generate_waveform_async (path, stream_index, signature);

        if (stream_index > 0) {
            if (signature != null) {
                var cached = lookup_playback_cache (signature, stream_index);
                if (cached != null) {
                    load_media_from_path (cached.extracted_path);
                    return;
                }
            }

            // Extract specific audio stream to temp file for playback
            extract_and_load_playback.begin (path, stream_index, signature);
        } else {
            // Default: load original file directly (first audio stream)
            load_media_from_path (path);
        }
    }

    // ── Playback stream extraction (for non-primary streams) ────────────────

    private void load_media_from_path (string path) {
        var file = GLib.File.new_for_path (path);
        media = Gtk.MediaFile.for_file (file);

        media_prepared_handler_id = media.notify["prepared"].connect (on_media_prepared_notify);

        prepare_poll = Timeout.add (100, () => {
            if (media != null && media.is_prepared ()) {
                on_media_prepared (media);
                prepare_poll = 0;
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });
    }

    private async void extract_and_load_playback (string input_path,
                                                  int stream_index,
                                                  ConversionUtils.FileSignature? signature = null) {
        uint gen = ++playback_extract_generation;
        var cancel = new Cancellable ();
        playback_extract_cancellable = cancel;

        string tmp_path;
        try {
            int fd;
            fd = FileUtils.open_tmp ("audio-play-XXXXXX.mka", out tmp_path);
            Posix.close (fd);
        } catch (Error e) {
            debug ("AudioPlayer: failed to create playback temp file: %s, falling back", e.message);
            load_media_from_path (input_path);
            return;
        }

        playback_tmp_path = tmp_path;

        string[] cmd = {
            AppSettings.get_default ().ffmpeg_path,
            "-y",
            "-i", input_path,
            "-map", "0:a:%d".printf (stream_index),
            "-vn", "-sn",
            "-c:a", "copy",
            tmp_path
        };

        try {
            var launcher = new SubprocessLauncher (
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            var proc = SubprocessCompat.spawnv (launcher, cmd);
            playback_extract_proc = proc;

            string? stdout_buf, stderr_buf;
            try {
                yield proc.communicate_utf8_async (null, cancel, out stdout_buf, out stderr_buf);
            } catch (Error e) {
                clear_playback_extract_proc (proc);
                if (cancel.is_cancelled () || gen != playback_extract_generation) {
                    FileUtils.unlink (tmp_path);
                    return;
                }
                debug ("AudioPlayer: playback extraction failed: %s, falling back", e.message);
                cleanup_playback_tmp ();
                load_media_from_path (input_path);
                return;
            }

            clear_playback_extract_proc (proc);

            // Stale: a newer extraction has started — clean up our file only
            if (cancel.is_cancelled () || gen != playback_extract_generation) {
                FileUtils.unlink (tmp_path);
                return;
            }

            if (proc.get_successful ()) {
                if (signature != null) {
                    store_playback_cache (signature, stream_index, tmp_path);
                    if (playback_tmp_path == tmp_path) {
                        playback_tmp_path = null;
                    }
                }
                load_media_from_path (tmp_path);
            } else {
                debug ("AudioPlayer: playback extraction ffmpeg failed, falling back to original");
                cleanup_playback_tmp ();
                // Fall back to original file (plays first audio stream)
                load_media_from_path (input_path);
            }
        } catch (Error e) {
            debug ("AudioPlayer: failed to spawn playback extraction: %s, falling back", e.message);
            if (gen == playback_extract_generation) {
                cleanup_playback_tmp ();
                // Fall back to original file
                load_media_from_path (input_path);
            } else {
                FileUtils.unlink (tmp_path);
            }
        }
    }

    private void clear_playback_extract_proc (Subprocess proc) {
        if (playback_extract_proc == proc) {
            playback_extract_proc = null;
        }
    }

    private void cleanup_playback_tmp () {
        if (playback_tmp_path != null) {
            FileUtils.unlink (playback_tmp_path);
            playback_tmp_path = null;
        }
    }

    private void cancel_playback_extract () {
        if (playback_extract_cancellable != null) {
            playback_extract_cancellable.cancel ();
            playback_extract_cancellable = null;
        }
        if (playback_extract_proc != null) {
            playback_extract_proc.force_exit ();
            playback_extract_proc = null;
        }
        cleanup_playback_tmp ();
    }

    private string build_playback_cache_key (string path, int stream_index) {
        return "%s|%d".printf (path, stream_index);
    }

    private void remove_playback_cache_key_from_lru (string key) {
        int idx = -1;
        for (int i = 0; i < playback_cache_lru.length; i++) {
            if (playback_cache_lru[i] == key) {
                idx = i;
                break;
            }
        }

        if (idx < 0)
            return;

        string[] next = {};
        for (int i = 0; i < playback_cache_lru.length; i++) {
            if (i != idx)
                next += playback_cache_lru[i];
        }
        playback_cache_lru = next;
    }

    private void touch_playback_cache_key (string key) {
        remove_playback_cache_key_from_lru (key);
        playback_cache_lru += key;

        while (playback_cache_lru.length > MAX_PLAYBACK_CACHE_ENTRIES) {
            string evicted = playback_cache_lru[0];
            var evicted_entry = playback_cache.lookup (evicted);
            string[] next = {};
            for (int i = 1; i < playback_cache_lru.length; i++)
                next += playback_cache_lru[i];
            playback_cache_lru = next;
            playback_cache.remove (evicted);
            if (evicted_entry != null) {
                FileUtils.unlink (evicted_entry.extracted_path);
            }
        }
    }

    private void clear_playback_cache_for_path (string path) {
        string[] keys = playback_cache_lru;
        for (int i = 0; i < keys.length; i++) {
            string key = keys[i];
            var entry = playback_cache.lookup (key);
            if (entry != null && entry.signature.path == path) {
                playback_cache.remove (key);
                remove_playback_cache_key_from_lru (key);
                FileUtils.unlink (entry.extracted_path);
            }
        }
    }

    private AudioPlaybackCacheEntry? lookup_playback_cache (
        ConversionUtils.FileSignature signature,
        int stream_index
    ) {
        string key = build_playback_cache_key (signature.path, stream_index);
        var entry = playback_cache.lookup (key);
        if (entry == null)
            return null;

        if (!entry.signature.matches (signature)) {
            clear_playback_cache_for_path (signature.path);
            return null;
        }

        if (!FileUtils.test (entry.extracted_path, FileTest.EXISTS)) {
            playback_cache.remove (key);
            remove_playback_cache_key_from_lru (key);
            return null;
        }

        touch_playback_cache_key (key);
        return entry;
    }

    private void store_playback_cache (ConversionUtils.FileSignature signature,
                                       int stream_index,
                                       string extracted_path) {
        string key = build_playback_cache_key (signature.path, stream_index);
        var existing = playback_cache.lookup (key);
        if (existing != null) {
            if (!existing.signature.matches (signature)) {
                clear_playback_cache_for_path (signature.path);
            } else if (existing.extracted_path != extracted_path) {
                FileUtils.unlink (existing.extracted_path);
            }
        }

        playback_cache.insert (
            key,
            new AudioPlaybackCacheEntry (signature, extracted_path)
        );
        touch_playback_cache_key (key);
    }

    private void clear_playback_cache () {
        string[] keys = playback_cache_lru;
        for (int i = 0; i < keys.length; i++) {
            var entry = playback_cache.lookup (keys[i]);
            if (entry != null) {
                FileUtils.unlink (entry.extracted_path);
            }
        }
        playback_cache.remove_all ();
        playback_cache_lru = {};
    }

    public void clear () {
        reset_player_state ();
        current_waveform_input_path = "";
        current_waveform_stream_index = 0;
        media = null;
        time_label.set_text (VideoPlayer.format_time (0.0));
        duration_label.set_text (VideoPlayer.format_time (0.0));
        waveform_picture.set_paintable (null);
        _duration = 0.0;
    }

    public double get_position_seconds () {
        if (media == null) return 0.0;
        return (double) media.get_timestamp () / 1000000.0;
    }

    public void seek_to (double seconds) {
        if (media == null) return;
        int64 target = (int64) (seconds * 1000000.0);
        int64 dur = media.get_duration ();
        if (dur > 0) {
            target = target.clamp (0, dur);
        }
        media.seek (target);
    }

    public void set_segments (GenericArray<AudioSegment> segs) {
        highlight_segments = segs;
        segment_overlay.queue_draw ();
    }

    public void cleanup () {
        reset_player_state ();
        current_waveform_input_path = "";
        current_waveform_stream_index = 0;
        clear_waveform_cache ();
        clear_playback_cache ();
    }

    public override void dispose () {
        disconnect_style_manager ();
        cleanup ();
        base.dispose ();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Waveform generation
    // ═════════════════════════════════════════════════════════════════════════

    private void generate_waveform_async (string input_path,
                                          int stream_index = 0,
                                          ConversionUtils.FileSignature? signature = null) {
        cancel_waveform ();

        if (input_path.length == 0)
            return;

        bool is_dark = Adw.StyleManager.get_default ().dark;
        ConversionUtils.FileSignature? effective_signature = signature;
        if (effective_signature == null) {
            effective_signature = ConversionUtils.query_file_signature (input_path);
        }
        if (effective_signature != null) {
            var cached = lookup_waveform_cache (effective_signature, stream_index, is_dark);
            if (cached != null) {
                waveform_picture.set_paintable (cached.texture);
                segment_overlay.queue_draw ();
                hide_spinner ();
                return;
            }
        }

        var cancel = new Cancellable ();
        waveform_cancellable = cancel;
        uint gen = ++waveform_generation;

        spinner_box.set_visible (true);
        waveform_spinner.start ();
        waveform_picture.set_paintable (null);

        string tmp_path;
        try {
            int fd;
            fd = FileUtils.open_tmp ("waveform-XXXXXX.png", out tmp_path);
            Posix.close (fd);
        } catch (Error e) {
            debug ("AudioPlayer: failed to create temp file for waveform: %s", e.message);
            spinner_box.set_visible (false);
            waveform_spinner.stop ();
            return;
        }

        waveform_tmp_path = tmp_path;

        // Pick waveform color based on current color scheme
        string waveform_color = is_dark ? "#7ab3e8" : "#2a6db5";

        string[] cmd = {
            AppSettings.get_default ().ffmpeg_path,
            "-i", input_path,
            "-filter_complex",
            "[0:a:%d]aformat=channel_layouts=mono,showwavespic=s=1920x200:colors=%s".printf (stream_index, waveform_color),
            "-frames:v", "1",
            "-y",
            tmp_path
        };

        try {
            var launcher = new SubprocessLauncher (
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            var proc = SubprocessCompat.spawnv (launcher, cmd);
            waveform_proc = proc;

            proc.communicate_utf8_async.begin (null, cancel, (obj, res) => {
                string? stdout_buf, stderr_buf;
                try {
                    proc.communicate_utf8_async.end (res, out stdout_buf, out stderr_buf);
                } catch (Error e) {
                    if (!cancel.is_cancelled ()) {
                        debug ("AudioPlayer: waveform generation failed: %s", e.message);
                    }
                    clear_waveform_proc (proc);
                    FileUtils.unlink (tmp_path);
                    hide_spinner ();
                    return;
                }

                clear_waveform_proc (proc);

                if (cancel.is_cancelled () || gen != waveform_generation) {
                    // Process finished after cancellation — clean up orphaned temp file
                    FileUtils.unlink (tmp_path);
                    hide_spinner ();
                    return;
                }

                if (proc.get_successful ()) {
                    load_waveform_image (tmp_path, effective_signature, stream_index, is_dark);
                } else {
                    debug ("AudioPlayer: waveform ffmpeg failed");
                    FileUtils.unlink (tmp_path);
                }

                hide_spinner ();
            });
        } catch (Error e) {
            debug ("AudioPlayer: failed to spawn waveform process: %s", e.message);
            FileUtils.unlink (tmp_path);
            waveform_tmp_path = null;
            hide_spinner ();
        }
    }

    private void load_waveform_image (string path,
                                      ConversionUtils.FileSignature? signature = null,
                                      int stream_index = 0,
                                      bool dark_theme = false) {
        try {
            var texture = Gdk.Texture.from_filename (path);
            waveform_picture.set_paintable (texture);
            if (signature != null) {
                store_waveform_cache (signature, stream_index, dark_theme, texture);
            }
        } catch (Error e) {
            debug ("AudioPlayer: failed to load waveform image: %s", e.message);
        }
        // Texture is loaded into memory; temp file no longer needed
        FileUtils.unlink (path);
        if (waveform_tmp_path == path) {
            waveform_tmp_path = null;
        }
    }

    private void hide_spinner () {
        Idle.add (() => {
            spinner_box.set_visible (false);
            waveform_spinner.stop ();
            return Source.REMOVE;
        });
    }

    private void cancel_waveform () {
        if (waveform_cancellable != null) {
            waveform_cancellable.cancel ();
            waveform_cancellable = null;
        }

        // Kill the FFmpeg process so it doesn't continue writing to the
        // temp file after we delete it, and to avoid wasting CPU.
        if (waveform_proc != null) {
            waveform_proc.force_exit ();
            waveform_proc = null;
        }

        spinner_box.set_visible (false);
        waveform_spinner.stop ();

        if (waveform_tmp_path != null) {
            FileUtils.unlink (waveform_tmp_path);
            waveform_tmp_path = null;
        }
    }

    private void clear_waveform_proc (Subprocess proc) {
        if (waveform_proc == proc) {
            waveform_proc = null;
        }
    }

    private string build_waveform_cache_key (string path, int stream_index, bool dark_theme) {
        return "%s|%d|%s".printf (path, stream_index, dark_theme ? "dark" : "light");
    }

    private void remove_waveform_cache_key_from_lru (string key) {
        int idx = -1;
        for (int i = 0; i < waveform_cache_lru.length; i++) {
            if (waveform_cache_lru[i] == key) {
                idx = i;
                break;
            }
        }

        if (idx < 0)
            return;

        string[] next = {};
        for (int i = 0; i < waveform_cache_lru.length; i++) {
            if (i != idx)
                next += waveform_cache_lru[i];
        }
        waveform_cache_lru = next;
    }

    private void touch_waveform_cache_key (string key) {
        remove_waveform_cache_key_from_lru (key);
        waveform_cache_lru += key;

        while (waveform_cache_lru.length > MAX_WAVEFORM_CACHE_ENTRIES) {
            string evicted = waveform_cache_lru[0];
            string[] next = {};
            for (int i = 1; i < waveform_cache_lru.length; i++)
                next += waveform_cache_lru[i];
            waveform_cache_lru = next;
            waveform_cache.remove (evicted);
        }
    }

    private void clear_waveform_cache_for_path (string path) {
        string[] keys = waveform_cache_lru;
        for (int i = 0; i < keys.length; i++) {
            string key = keys[i];
            var entry = waveform_cache.lookup (key);
            if (entry != null && entry.signature.path == path) {
                waveform_cache.remove (key);
                remove_waveform_cache_key_from_lru (key);
            }
        }
    }

    private AudioWaveformCacheEntry? lookup_waveform_cache (
        ConversionUtils.FileSignature signature,
        int stream_index,
        bool dark_theme
    ) {
        string key = build_waveform_cache_key (signature.path, stream_index, dark_theme);
        var entry = waveform_cache.lookup (key);
        if (entry == null)
            return null;

        if (!entry.signature.matches (signature)) {
            clear_waveform_cache_for_path (signature.path);
            return null;
        }

        touch_waveform_cache_key (key);
        return entry;
    }

    private void store_waveform_cache (ConversionUtils.FileSignature signature,
                                       int stream_index,
                                       bool dark_theme,
                                       Gdk.Texture texture) {
        string key = build_waveform_cache_key (signature.path, stream_index, dark_theme);
        var existing = waveform_cache.lookup (key);
        if (existing != null && !existing.signature.matches (signature)) {
            clear_waveform_cache_for_path (signature.path);
        }

        waveform_cache.insert (
            key,
            new AudioWaveformCacheEntry (signature, texture)
        );
        touch_waveform_cache_key (key);
    }

    private void clear_waveform_cache () {
        waveform_cache.remove_all ();
        waveform_cache_lru = {};
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Segment highlight drawing
    // ═════════════════════════════════════════════════════════════════════════

    private void draw_segment_highlights (DrawingArea area, Cairo.Context cr,
                                          int width, int height) {
        if (_duration <= 0.0)
            return;

        // Draw segment regions
        if (highlight_segments.length > 0) {
            for (int i = 0; i < highlight_segments.length; i++) {
                var seg = highlight_segments[i];
                double x_start = (seg.start_time / _duration) * width;
                double x_end = (seg.end_time / _duration) * width;
                double seg_width = (x_end - x_start).clamp (1.0, width);

                // Filled region
                cr.set_source_rgba (0.35, 0.60, 0.90, 0.22);
                cr.rectangle (x_start, 0, seg_width, height);
                cr.fill ();

                // Bright edge lines at segment boundaries
                cr.set_source_rgba (0.40, 0.65, 0.95, 0.6);
                cr.set_line_width (1.0);
                cr.move_to (x_start, 0);
                cr.line_to (x_start, height);
                cr.stroke ();
                cr.move_to (x_start + seg_width, 0);
                cr.line_to (x_start + seg_width, height);
                cr.stroke ();
            }
        }

        // Playhead — theme-aware line with subtle glow
        double pos = get_position_seconds ();
        if (pos > 0.0) {
            double x = (pos / _duration) * width;
            bool dark = Adw.StyleManager.get_default ().dark;

            // Glow
            if (dark) {
                cr.set_source_rgba (1.0, 1.0, 1.0, 0.15);
            } else {
                cr.set_source_rgba (0.0, 0.0, 0.0, 0.12);
            }
            cr.set_line_width (5.0);
            cr.move_to (x, 0);
            cr.line_to (x, height);
            cr.stroke ();

            // Core line
            if (dark) {
                cr.set_source_rgba (1.0, 1.0, 1.0, 0.9);
            } else {
                cr.set_source_rgba (0.15, 0.15, 0.15, 0.9);
            }
            cr.set_line_width (1.5);
            cr.move_to (x, 0);
            cr.line_to (x, height);
            cr.stroke ();
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Playback control
    // ═════════════════════════════════════════════════════════════════════════

    private void reset_player_state () {
        stop_update_timer ();
        stop_prepare_poll ();
        cancel_waveform ();
        cancel_playback_extract ();
        cancel_scrub_reset ();
        disconnect_media_prepared_handler ();

        if (media != null) {
            media.set_playing (false);
            media = null;
        }

        user_scrubbing = false;
        is_playing = false;
        prepared_handled = false;
        play_button.set_icon_name ("media-playback-start-symbolic");
    }

    private void ensure_paused () {
        if (media == null) return;
        if (is_playing) {
            media.set_playing (false);
            is_playing = false;
            play_button.set_icon_name ("media-playback-start-symbolic");
        }
    }

    private void disconnect_media_prepared_handler () {
        if (media != null && media_prepared_handler_id != 0) {
            media.disconnect (media_prepared_handler_id);
            media_prepared_handler_id = 0;
        }
    }

    private void on_media_prepared_notify (Object source_object, ParamSpec pspec) {
        var source_media = source_object as Gtk.MediaFile;
        if (source_media != null) {
            on_media_prepared (source_media);
        }
    }

    private void on_media_prepared (Gtk.MediaFile source_media) {
        if (media == null || source_media != media || !source_media.is_prepared ()) return;

        double dur = (double) source_media.get_duration () / 1000000.0;
        if (dur <= 0.0) return;

        if (prepared_handled) return;
        prepared_handled = true;

        stop_prepare_poll ();
        disconnect_media_prepared_handler ();

        _duration = dur;
        duration_label.set_text (VideoPlayer.format_time (dur));
        time_label.set_text (VideoPlayer.format_time (0.0));

        start_update_timer ();
        media_ready (dur);
    }

    private void toggle_playback () {
        if (media == null) return;

        if (is_playing) {
            media.set_playing (false);
            is_playing = false;
            play_button.set_icon_name ("media-playback-start-symbolic");
        } else {
            media.set_playing (true);
            is_playing = true;
            play_button.set_icon_name ("media-playback-pause-symbolic");
        }
    }

    private void seek_relative (double seconds) {
        if (media == null) return;
        int64 current = media.get_timestamp ();
        int64 target = current + (int64) (seconds * 1000000.0);
        int64 dur = media.get_duration ();
        if (dur > 0) {
            target = target.clamp (0, dur);
        }
        media.seek (target);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Waveform seek
    // ═════════════════════════════════════════════════════════════════════════

    private void seek_to_waveform_x (double x) {
        if (media == null || _duration <= 0.0) return;

        int width = segment_overlay.get_width ();
        if (width <= 0) return;

        double fraction = (x / (double) width).clamp (0.0, 1.0);
        double seconds = fraction * _duration;

        int64 seek_pos = (int64) (seconds * 1000000.0);
        int64 dur = media.get_duration ();
        if (dur > 0) {
            seek_pos = seek_pos.clamp (0, dur);
        }
        media.seek (seek_pos);
        time_label.set_text (VideoPlayer.format_time (seconds));
        segment_overlay.queue_draw ();
    }

    private void on_waveform_drag_update (double offset_x, double offset_y) {
        double start_x;
        double start_y;
        if (!waveform_drag.get_start_point (out start_x, out start_y))
            return;
        seek_to_waveform_x (start_x + offset_x);
    }

    private void cancel_scrub_reset () {
        if (scrub_reset_source != 0) {
            Source.remove (scrub_reset_source);
            scrub_reset_source = 0;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL — Periodic position update
    // ═════════════════════════════════════════════════════════════════════════

    private void start_update_timer () {
        stop_update_timer ();
        update_source = Timeout.add (100, () => {
            if (!user_scrubbing && media != null) {
                double pos = get_position_seconds ();
                time_label.set_text (VideoPlayer.format_time (pos));
                position_changed (pos);
                segment_overlay.queue_draw ();

                bool gst_playing = media.get_playing ();
                if (is_playing && !gst_playing) {
                    is_playing = false;
                    play_button.set_icon_name ("media-playback-start-symbolic");
                }
            }
            return Source.CONTINUE;
        });
    }

    private void stop_update_timer () {
        if (update_source != 0) {
            Source.remove (update_source);
            update_source = 0;
        }
    }

    private void stop_prepare_poll () {
        if (prepare_poll != 0) {
            Source.remove (prepare_poll);
            prepare_poll = 0;
        }
    }
}
