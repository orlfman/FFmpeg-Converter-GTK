using GLib;

/** Everything that can affect a folder job, captured before its first yield. */
public class BulkConversionSettings : Object {
    public string codec = "x265";
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

public class BulkItem : Object {
    public string path;
    public string state = "pending";
    public string status = "Waiting";
    public string output_path = "";
    public OperationOutputResult? result = null;
    public OptimizationRecommendation? recommendation = null;
    // Device/inode identify aliases; size/mtime detect changes while analyzing.
    internal string file_identity = "";
    internal string file_revision = "";
    internal int64 size_bytes = 0;
    internal string canonical_path;

    public BulkItem (string path) {
        this.path = path;
        canonical_path = Posix.realpath (path) ?? File.new_for_path (path).get_path () ?? path;
    }
}

/** Sequential folder analysis/conversion. Its converter never publishes staging paths. */
public class BulkConversionController : Object {
    public GenericArray<BulkItem> items { get; private set; default = new GenericArray<BulkItem> (); }
    public bool is_running { get; private set; default = false; }
    public signal void changed ();
    public signal void finished (uint64 operation_id);
    public signal void output_ready (OperationOutputResult result);

    private StatusArea status_area;
    private ConsoleTab console_tab;
    private Converter converter;
    private Cancellable? active_cancel = null;
    private bool stop_requested = false;
    private string queued_folder = "";
    private string queued_output = "";
    private const string SCAN_ATTRIBUTES = "standard::name,standard::type,standard::size,unix::device,unix::inode,time::modified,time::modified-usec";

    public BulkConversionController (StatusArea status_area,
                                     ConsoleTab console_tab,
                                     GeneralTab general_tab) {
        this.status_area = status_area;
        this.console_tab = console_tab;
        converter = new Converter (status_area, console_tab, general_tab);
    }

    public void cancel () {
        if (!is_running)
            return;
        // This remains set even if Converter treats a collage cancellation as
        // optional and emits success for the already-encoded main video.
        stop_requested = true;
        if (active_cancel != null)
            active_cancel.cancel ();
        converter.cancel ();
    }

    /** Forget a previous finite queue only when no worker owns it. */
    public void reset_queue () {
        if (is_running)
            return;
        queued_folder = "";
        queued_output = "";
        items = new GenericArray<BulkItem> ();
        changed ();
    }

    private static void check_cancelled (Cancellable? cancellable) throws Error {
        if (cancellable != null && cancellable.is_cancelled ())
            throw new IOError.CANCELLED ("Folder processing cancelled.");
    }

    private static string identity_from_info (FileInfo info) {
        if (!info.has_attribute (FileAttribute.UNIX_DEVICE)
                || !info.has_attribute (FileAttribute.UNIX_INODE))
            return "";
        return "%u:%s".printf (
            info.get_attribute_uint32 (FileAttribute.UNIX_DEVICE),
            info.get_attribute_uint64 (FileAttribute.UNIX_INODE).to_string ());
    }

    private static string revision_from_info (FileInfo info) {
        return "%s:%s:%u".printf (info.get_size ().to_string (),
            info.get_attribute_uint64 (FileAttribute.TIME_MODIFIED).to_string (),
            info.get_attribute_uint32 (FileAttribute.TIME_MODIFIED_USEC));
    }

    private static string? stat_identity (string path, bool follow = true) {
        Posix.Stat info;
        int result = follow ? Posix.stat (path, out info) : Posix.lstat (path, out info);
        if (result != 0)
            return null;
        return "%s:%s".printf (((uint64) info.st_dev).to_string (),
            ((uint64) info.st_ino).to_string ());
    }

    private static bool is_video_name (string name) {
        string lower = name.down ();
        foreach (unowned string extension in VideoFileConstants.VIDEO_EXTENSIONS) {
            if (lower.has_suffix (extension))
                return true;
        }
        return false;
    }

    /** A finite, deterministic, top-level list, following file aliases once. */
    public static async GenericArray<BulkItem> scan_folder (
        string folder,
        string excluded_output,
        Cancellable? cancellable = null) throws Error {
        check_cancelled (cancellable);
        var candidates = new GenericArray<BulkItem> ();
        File directory = File.new_for_path (folder);
        FileEnumerator enumerator = yield directory.enumerate_children_async (
            SCAN_ATTRIBUTES, FileQueryInfoFlags.NONE, Priority.DEFAULT, cancellable);
        string? excluded_real = excluded_output.length > 0 ? Posix.realpath (excluded_output) : null;
        string? folder_real = Posix.realpath (folder);
        try {
            while (true) {
                check_cancelled (cancellable);
                var entries = yield enumerator.next_files_async (64, Priority.DEFAULT, cancellable);
                if (entries == null)
                    break;
                foreach (FileInfo entry in entries) {
                    if (!is_video_name (entry.get_name ()))
                        continue;
                    File child = directory.get_child (entry.get_name ());
                    string? child_path = child.get_path ();
                    if (child_path == null)
                        continue;
                    FileInfo info;
                    try {
                        info = yield child.query_info_async (SCAN_ATTRIBUTES,
                            FileQueryInfoFlags.NONE, Priority.DEFAULT, cancellable);
                    } catch (IOError.CANCELLED e) {
                        throw e;
                    } catch (Error e) {
                        // Broken links and disappearing directory entries are
                        // not inputs; files which later become unreadable fail
                        // visibly in their existing queue row.
                        continue;
                    }
                    if (info.get_file_type () != FileType.REGULAR)
                        continue;
                    string? real = Posix.realpath (child_path);
                    if (excluded_real != null && excluded_real != folder_real && real != null
                            && (real == excluded_real || real.has_prefix (excluded_real + "/")))
                        continue;
                    string identity = identity_from_info (info);
                    if (identity.length == 0)
                        throw new IOError.NOT_SUPPORTED ("The source filesystem cannot identify file aliases safely.");
                    var item = new BulkItem (child_path);
                    item.file_identity = identity;
                    item.file_revision = revision_from_info (info);
                    item.size_bytes = info.get_size ();
                    candidates.add (item);
                }
            }
        } finally {
            // Do not use a cancelled token to close the enumerator itself.
            try {
                yield enumerator.close_async (Priority.DEFAULT, null);
            } catch (Error e) {
                debug ("Bulk folder enumerator cleanup: %s", e.message);
            }
        }
        check_cancelled (cancellable);
        candidates.sort ((a, b) => { return strcmp (a.path, b.path); });
        var unique = new GenericArray<BulkItem> ();
        var seen = new HashTable<string, bool> (str_hash, str_equal);
        for (int i = 0; i < candidates.length; i++) {
            BulkItem item = candidates[i];
            if (seen.contains (item.file_identity))
                continue;
            seen.insert (item.file_identity, true);
            unique.add (item);
        }
        return unique;
    }

    /** An exclusively-created directory on the destination filesystem. */
    public static string create_staging_directory (string output_folder) throws Error {
        if (!FileUtils.test (output_folder, FileTest.IS_DIR))
            throw new IOError.NOT_DIRECTORY ("The output folder is unavailable.");
        for (int attempt = 0; attempt < 32; attempt++) {
            string path = Path.build_filename (output_folder, ".ffmpeg-bulk-" + Uuid.string_random ());
            if (Posix.mkdir (path, 0700) == 0)
                return path;
            int error_number = Posix.errno;
            if (error_number != Posix.EEXIST)
                throw IOError.from_errno (error_number);
        }
        throw new IOError.EXISTS ("Could not allocate an exclusive staging directory.");
    }

    private static string numbered_path (string desired_path, int suffix) {
        if (suffix == 0)
            return desired_path;
        string name = Path.get_basename (desired_path);
        int dot = name.last_index_of_char ('.');
        string stem = dot > 0 ? name.substring (0, dot) : name;
        string extension = dot > 0 ? name.substring (dot) : "";
        return Path.build_filename (Path.get_dirname (desired_path),
            "%s-%d%s".printf (stem, suffix, extension));
    }

    private static string canonical_destination (string path) {
        string? parent = Posix.realpath (Path.get_dirname (path));
        return parent != null
            ? Path.build_filename (parent, Path.get_basename (path))
            : (File.new_for_path (path).get_path () ?? path);
    }

    /** Atomic no-clobber publication; never falls back to copy or replacement. */
    public static string publish_staged_file (string staged_path,
                                               string desired_path,
                                               GenericArray<BulkItem>? protected_inputs = null) throws Error {
        Posix.Stat info;
        if (Posix.lstat (staged_path, out info) != 0)
            throw IOError.from_errno (Posix.errno);
        if (!Posix.S_ISREG (info.st_mode))
            throw new IOError.INVALID_ARGUMENT ("Only an owned regular staged file can be published.");
        string? staged_identity = stat_identity (staged_path, false);
        if (protected_inputs != null) {
            for (int i = 0; i < protected_inputs.length; i++) {
                BulkItem input = protected_inputs[i];
                if (staged_identity == input.file_identity
                        || staged_identity == stat_identity (input.path))
                    throw new IOError.PERMISSION_DENIED ("A staged output aliases a queued input file.");
            }
        }
        for (int attempt = 0; attempt < 10000; attempt++) {
            string destination = numbered_path (desired_path, attempt);
            bool queued_path = false;
            if (protected_inputs != null) {
                string canonical = canonical_destination (destination);
                for (int i = 0; i < protected_inputs.length; i++) {
                    BulkItem input = protected_inputs[i];
                    if (canonical == canonical_destination (input.path)
                            || canonical == input.canonical_path) {
                        queued_path = true;
                        break;
                    }
                }
            }
            if (queued_path)
                continue;
            if (Posix.link (staged_path, destination) == 0) {
                // The new directory entry already names the complete output.
                // A failed unlink leaves only our extra staging link to clean.
                Posix.unlink (staged_path);
                return destination;
            }
            int error_number = Posix.errno;
            if (error_number != Posix.EEXIST)
                throw IOError.from_errno (error_number);
        }
        throw new IOError.EXISTS ("No unused output filename could be allocated.");
    }

    private static void cleanup_staging_directory (string path, string expected_identity) {
        // Never traverse or delete a replacement directory or follow children.
        if (stat_identity (path, false) != expected_identity)
            return;
        try {
            Dir directory = Dir.open (path);
            string? name;
            while ((name = directory.read_name ()) != null) {
                string child = Path.build_filename (path, name);
                Posix.Stat info;
                if (Posix.lstat (child, out info) == 0
                        && (Posix.S_ISREG (info.st_mode) || Posix.S_ISLNK (info.st_mode)))
                    Posix.unlink (child);
            }
            DirUtils.remove (path);
        } catch (FileError e) {
            // An unavailable destination cannot safely be cleaned here.
        }
    }

    private void update_item (BulkItem item, string state, string status) {
        item.state = state;
        item.status = status;
        changed ();
    }

    private async void validate_source (BulkItem item, Cancellable cancellable) throws Error {
        check_cancelled (cancellable);
        FileInfo info = yield File.new_for_path (item.path).query_info_async (
            SCAN_ATTRIBUTES, FileQueryInfoFlags.NONE, Priority.DEFAULT, cancellable);
        if (info.get_file_type () != FileType.REGULAR
                || identity_from_info (info) != item.file_identity
                || revision_from_info (info) != item.file_revision)
            throw new IOError.FAILED ("The source file changed after the folder was scanned.");
    }

    private static double timing_seconds (double hours, double minutes, double seconds) {
        return hours * 3600.0 + minutes * 60.0 + seconds;
    }

    private static string timestamp (double seconds) {
        char[] buffer = new char[64];
        return seconds.format (buffer, "%.6f");
    }

    private static void validate_delogo_rectangle (int x, int y, int width, int height,
                                                    int source_width, int source_height) throws Error {
        // FFmpeg's interpolation needs one real frame pixel around the area.
        if (x < 1 || y < 1 || width < 1 || height < 1
                || x >= source_width || y >= source_height
                || width >= source_width - x || height >= source_height - y)
            throw new IOError.INVALID_ARGUMENT ("A General logo-removal region lies outside this video or lacks its required frame border.");
    }

    private static void validate_geometry (GeneralSettingsSnapshot general, string? stream_text) throws Error {
        if (!general.crop_enabled && !general.delogo_enabled)
            return;
        int source_width = 0, source_height = 0;
        bool video = false;
        if (stream_text != null) {
            foreach (string line in stream_text.split ("\n")) {
                if (line == "[STREAM]") {
                    source_width = 0;
                    source_height = 0;
                    video = false;
                } else if (line == "codec_type=video") {
                    video = true;
                } else if (line.has_prefix ("width=")) {
                    int.try_parse (line.substring (6), out source_width);
                } else if (line.has_prefix ("height=")) {
                    int.try_parse (line.substring (7), out source_height);
                } else if (line == "[/STREAM]" && video) {
                    break;
                }
            }
        }
        if (source_width <= 0 || source_height <= 0)
            throw new IOError.FAILED ("Could not verify this file's dimensions for the General geometry settings.");
        // Delogo is applied in source coordinates before rotation and crop.
        if (general.delogo_enabled) {
            foreach (string chunk in general.delogo_regions.split (",")) {
                string entry = chunk.strip ();
                LogoRegion[] regions = LogoDetectorLogic.parse_regions (entry);
                TimedLogoRegion[] timed = LogoDetectorLogic.parse_timed_regions (entry);
                if (entry.length == 0 || regions.length + timed.length != 1)
                    throw new IOError.INVALID_ARGUMENT ("A General logo-removal entry is malformed. Use x:y:w:h or start-end:x:y:w:h.");
                foreach (LogoRegion region in regions)
                    validate_delogo_rectangle (region.x, region.y, region.width, region.height,
                        source_width, source_height);
                foreach (TimedLogoRegion region in timed)
                    validate_delogo_rectangle (region.x, region.y, region.width, region.height,
                        source_width, source_height);
            }
        }
        if (!general.crop_enabled)
            return;
        string[] values = general.crop_value.split (":");
        int width = 0, height = 0, x = 0, y = 0;
        if (values.length != 4
                || !ConversionUtils.try_parse_non_negative_int_strict (values[0], out width)
                || !ConversionUtils.try_parse_non_negative_int_strict (values[1], out height)
                || !ConversionUtils.try_parse_non_negative_int_strict (values[2], out x)
                || !ConversionUtils.try_parse_non_negative_int_strict (values[3], out y)
                || width <= 0 || height <= 0)
            throw new IOError.INVALID_ARGUMENT ("The General crop must be a valid w:h:x:y rectangle.");
        // FilterBuilder applies General rotation before its crop rectangle.
        if (general.rotate == Rotation.CW_90 || general.rotate == Rotation.CCW_90) {
            int rotated_width = source_height;
            source_height = source_width;
            source_width = rotated_width;
        }
        if (x > source_width || y > source_height
                || width > source_width - x || height > source_height - y)
            throw new IOError.INVALID_ARGUMENT ("The General crop lies outside this video's dimensions.");
    }

    private async OperationOutputResult? execute_prepared (BulkItem item,
                                                           string output_path,
                                                           ConversionConfig config,
                                                           bool two_pass,
                                                           uint64 operation_id) {
        OperationOutputResult? result = null;
        bool terminal = false;
        ulong succeeded_id = converter.conversion_succeeded.connect ((id, output) => {
            if (id != operation_id || terminal)
                return;
            terminal = true;
            result = output;
            execute_prepared.callback ();
        });
        ulong failed_id = converter.conversion_failed.connect ((id) => {
            if (id != operation_id || terminal)
                return;
            terminal = true;
            execute_prepared.callback ();
        });
        ulong cancelled_id = converter.conversion_cancelled.connect ((id, message) => {
            if (id != operation_id || terminal)
                return;
            terminal = true;
            execute_prepared.callback ();
        });
        bool started = converter.start_prepared_conversion (
            item.path, output_path, config, two_pass, operation_id);
        if (started)
            yield;
        converter.disconnect (succeeded_id);
        converter.disconnect (failed_id);
        converter.disconnect (cancelled_id);
        // Terminal signals run after Converter has reaped its worker children
        // and cleaned its pass logs. No next item starts before this resumes.
        return result;
    }

    private static bool destination_healthy (string output_folder) {
        try {
            File directory = File.new_for_path (output_folder);
            FileInfo info = directory.query_info ("standard::type,access::can-write",
                FileQueryInfoFlags.NONE);
            if (info.get_file_type () != FileType.DIRECTORY
                    || (info.has_attribute (FileAttribute.ACCESS_CAN_WRITE)
                        && !info.get_attribute_boolean (FileAttribute.ACCESS_CAN_WRITE)))
                return false;
            FileInfo filesystem = directory.query_filesystem_info ("filesystem::free,filesystem::readonly");
            if (filesystem.get_attribute_boolean (FileAttribute.FILESYSTEM_READONLY))
                return false;
            if (filesystem.has_attribute (FileAttribute.FILESYSTEM_FREE)
                    && filesystem.get_attribute_uint64 (FileAttribute.FILESYSTEM_FREE) < 1024 * 1024)
                return false;
            return true;
        } catch (Error e) {
            return false;
        }
    }

    private static bool destination_accepts_write (string output_folder) {
        if (!destination_healthy (output_folder))
            return false;
        // Free-space reporting does not expose per-user quotas. A tiny,
        // exclusively-created file detects quota/inode exhaustion as well.
        File probe_file = File.new_for_path (Path.build_filename (
            output_folder, ".ffmpeg-bulk-write-" + Uuid.string_random ()));
        FileOutputStream? stream = null;
        bool created = false;
        try {
            stream = probe_file.create (FileCreateFlags.PRIVATE);
            created = true;
            uint8[] data = { 0 };
            size_t written;
            stream.write_all (data, out written);
            stream.close ();
            stream = null;
            return written == data.length;
        } catch (Error e) {
            return false;
        } finally {
            if (stream != null) {
                try { stream.close (); } catch (Error e) { }
            }
            if (created) {
                try { probe_file.delete (); } catch (Error e) { }
            }
        }
    }

    private static void validate_executable (string configured_path, string label) throws Error {
        string? executable = configured_path.contains ("/")
            ? configured_path : Environment.find_program_in_path (configured_path);
        if (configured_path.length == 0 || executable == null
                || !FileUtils.test (executable, FileTest.IS_REGULAR)
                || !FileUtils.test (executable, FileTest.IS_EXECUTABLE))
            throw new IOError.NOT_FOUND ("The captured %s executable is unavailable or not executable.".printf (label));
    }

    private static async void preflight_runtime (BulkConversionSettings settings,
                                                 FfmpegRuntimeCapabilities capabilities,
                                                 Cancellable cancellable) throws Error {
        check_cancelled (cancellable);
        validate_executable (settings.runtime_options.ffmpeg_path, "FFmpeg");
        validate_executable (settings.runtime_options.ffprobe_path, "FFprobe");
        string encoder;
        switch (settings.codec) {
            case "x264": encoder = "libx264"; break;
            case "x265": encoder = "libx265"; break;
            case "vp9": encoder = "libvpx-vp9"; break;
            case "svt-av1": encoder = "libsvtav1"; break;
            default: throw new IOError.INVALID_ARGUMENT ("Select a supported video codec.");
        }
        var capability = yield capabilities.get_encoder_pixel_format_capability (
            settings.runtime_options.ffmpeg_path, encoder, "yuv420p", cancellable);
        check_cancelled (cancellable);
        // Some valid builds expose a 10-bit-only encoder. The resolver and
        // optimizer still enforce this particular source's depth constraints.
        if (capability.status == EncoderPixelFormatCapabilityStatus.UNSUPPORTED) {
            capability = yield capabilities.get_encoder_pixel_format_capability (
                settings.runtime_options.ffmpeg_path, encoder, "yuv420p10le", cancellable);
            check_cancelled (cancellable);
        }
        if (capability.status != EncoderPixelFormatCapabilityStatus.SUPPORTED)
            throw new IOError.NOT_SUPPORTED (capability.reason
                ?? "The selected encoder is unavailable in the captured FFmpeg build.");
        if (settings.quality_mode) {
            var vmaf = yield capabilities.get_vmaf_capability (
                settings.runtime_options.ffmpeg_path, cancellable);
            check_cancelled (cancellable);
            if (vmaf.status != VmafCapabilityStatus.SUPPORTED)
                throw new IOError.NOT_SUPPORTED (vmaf.reason
                    ?? "Quality Target requires FFmpeg with the libvmaf filter.");
        }
    }

    /** Retry the frozen queue, reanalyzing unfinished files and keeping completed outputs. */
    public async void run (string folder,
                           string output_folder,
                           BulkConversionSettings requested_settings,
                           bool convert,
                           uint64 operation_id) {
        if (is_running)
            return;
        is_running = true;
        stop_requested = false;
        var cancellable = new Cancellable ();
        active_cancel = cancellable;
        BulkConversionSettings settings = requested_settings.copy ();
        settings.codec = settings.codec.down ();
        // Bulk publication always preserves existing files, including other
        // queue inputs and files created by a second process during encoding.
        settings.runtime_options.overwrite_enabled = false;
        string? staging = null;
        string staging_identity = "";
        var published = new GenericArray<string> ();
        bool destination_failed = false;
        string? run_error = null;
        var capabilities = new FfmpegRuntimeCapabilities ();
        var optimizer = new SmartOptimizer (capabilities, settings.runtime_options);
        optimizer.progress.connect ((line) => {
            console_tab.add_line ("[Bulk Smart Optimizer] " + line);
        });
        try {
            if (settings.codec != "x264" && settings.codec != "x265"
                    && settings.codec != "vp9" && settings.codec != "svt-av1")
                throw new IOError.INVALID_ARGUMENT ("Select a supported video codec before processing a folder.");
            status_area.start_progress ();
            string folder_key = Posix.realpath (folder) ?? canonical_destination (folder);
            string output_key = Posix.realpath (output_folder) ?? canonical_destination (output_folder);
            if (folder_key != queued_folder || output_key != queued_output) {
                queued_folder = "";
                queued_output = "";
                status_area.set_status ("Scanning folder…", StatusIcon.SEARCH_ICON, StatusIcon.SEARCH_CSS);
                items = new GenericArray<BulkItem> ();
                changed ();
                items = yield scan_folder (folder, output_folder, cancellable);
                queued_folder = folder_key;
                queued_output = output_key;
                changed ();
            }
            if (items.length == 0)
                throw new IOError.NOT_FOUND ("No supported video files were found in this folder.");
            int remaining = 0;
            for (int i = 0; i < items.length; i++) {
                if (items[i].state != "completed")
                    remaining++;
            }
            if (remaining > 0) {
                status_area.set_status ("Checking FFmpeg capabilities…", StatusIcon.SEARCH_ICON, StatusIcon.SEARCH_CSS);
                yield preflight_runtime (settings, capabilities, cancellable);
            }
            if (convert && remaining > 0) {
                check_cancelled (cancellable);
                try {
                    File.new_for_path (output_folder).make_directory_with_parents (cancellable);
                } catch (IOError.EXISTS e) {
                    // A pre-existing directory is checked below; a file at
                    // this path fails the same destination validation.
                }
                if (!destination_healthy (output_folder))
                    throw new IOError.FAILED ("The output folder is unavailable, read-only, or full.");
                staging = create_staging_directory (output_folder);
                staging_identity = stat_identity (staging, false) ?? "";
                if (staging_identity.length == 0)
                    throw new IOError.FAILED ("Could not verify ownership of the staging directory.");
            }
            var watermark = FilterBuilder.snapshot_smart_image_watermark (settings.general_settings);
            if (watermark != null && watermark.file_identity == "unreadable")
                throw new IOError.NOT_FOUND ("The selected watermark image could not be read.");
            for (int index = 0; index < items.length; index++) {
                check_cancelled (cancellable);
                BulkItem item = items[index];
                if (item.state == "completed")
                    continue;
                if (convert && !destination_healthy (output_folder)) {
                    destination_failed = true;
                    break;
                }
                try {
                    update_item (item, "analyzing", "Analyzing with Smart Optimizer");
                    console_tab.add_section_header ("Bulk item %d of %u".printf (index + 1, items.length),
                        { "Input: " + item.path });
                    yield validate_source (item, cancellable);
                    double duration = yield FfprobeUtils.probe_duration_async (
                        item.path, cancellable, settings.runtime_options.ffprobe_path);
                    check_cancelled (cancellable);
                    if (!(duration > 0.0 && duration < double.MAX))
                        throw new IOError.INVALID_DATA ("Could not read a positive duration for this file.");
                    AudioStreamProbeResult primary = yield FfprobeUtils.probe_primary_audio_stream_async (
                        item.path, cancellable, settings.runtime_options.ffprobe_path);
                    check_cancelled (cancellable);
                    AudioStreamsProbeResult all_audio = yield FfprobeUtils.probe_all_audio_streams_async (
                        item.path, cancellable, settings.runtime_options.ffprobe_path);
                    check_cancelled (cancellable);
                    if (primary.presence == MediaStreamPresence.ERROR || !all_audio.success)
                        throw new IOError.INVALID_DATA ("Could not verify this file's source audio streams.");
                    CodecTabSettingsSnapshot requested = settings.codec_settings.copy ();
                    requested.audio_settings.source = AudioSourceLogic.from_probe_result (primary);
                    AudioSourceInfo[] sources = {};
                    for (int audio_index = 0; audio_index < all_audio.streams.length; audio_index++)
                        sources += AudioSourceLogic.from_stream_info (all_audio.streams[audio_index]);
                    requested.audio_settings.all_sources = sources;
                    if (sources.length > 0)
                        requested.audio_settings.source = sources[0].copy ();
                    GeneralSettingsSnapshot general = settings.general_settings.copy ();
                    if (general.crop_enabled || general.delogo_enabled) {
                        string? streams = yield FfprobeUtils.probe_format_and_streams_async (
                            item.path, cancellable, settings.runtime_options.ffprobe_path);
                        check_cancelled (cancellable);
                        validate_geometry (general, streams);
                    }
                    double start = settings.timing.seek_enabled
                        ? timing_seconds (settings.timing.seek_hours, settings.timing.seek_minutes, settings.timing.seek_seconds) : 0.0;
                    double span = settings.timing.time_enabled
                        ? timing_seconds (settings.timing.time_hours, settings.timing.time_minutes, settings.timing.time_seconds) : duration - start;
                    if (!(start >= 0.0 && start < duration) || !(span > 0.0 && span < double.MAX))
                        throw new IOError.INVALID_ARGUMENT ("The General start time or duration is outside this video's range.");
                    span = double.min (span, duration - start);
                    var ctx = OptimizationContext ();
                    ctx.content_override = settings.content_override;
                    ctx.optimize_for_delivery = settings.optimize_for_delivery;
                    ctx.output_container = requested.container;
                    ctx.strip_audio = settings.strip_audio;
                    ctx.preserve_all_audio_tracks_requested = requested.audio_settings.preserve_all_audio_tracks;
                    // Smart Optimizer resets codec-local audio processing; only
                    // captured General audio speed remains a re-encode reason.
                    ctx.audio_requires_reencode = general.audio_speed_enabled
                        && Math.fabs (general.audio_speed_percent) > 1e-9;
                    ctx.video_filter_chain = FilterBuilder.build_video_filter_chain_from_snapshot (general, false, settings.codec);
                    ctx.image_watermark = watermark;
                    ctx.tone_mapping_active = ctx.video_filter_chain.contains ("tonemap=");
                    ctx.video_speed_multiplier = FilterBuilder.get_video_speed_multiplier (general);
                    double output_fps;
                    if (CodecUtils.try_resolve_output_fps_from_snapshot (general, out output_fps))
                        ctx.output_fps = output_fps;
                    ctx.trim_start_seconds = start;
                    ctx.trim_end_seconds = start + span;
                    ctx.effective_duration = span;
                    int target_mb = SmartOptimizerLogic.resolve_target_mb (
                        settings.target_mb, settings.match_source_size, item.size_bytes);
                    if (settings.match_source_size && (settings.timing.seek_enabled || settings.timing.time_enabled))
                        target_mb = SmartOptimizerLogic.match_source_target_mb_for_window (item.size_bytes, span, duration);
                    OptimizationRecommendation rec = settings.quality_mode
                        ? yield optimizer.optimize_for_quality (item.path, settings.quality_intent, settings.codec, ctx, cancellable)
                        : yield optimizer.optimize_for_target_size (item.path, target_mb, settings.codec, ctx, cancellable);
                    check_cancelled (cancellable);
                    yield validate_source (item, cancellable);
                    if (watermark != null) {
                        var current = FilterBuilder.snapshot_smart_image_watermark (general);
                        if (current == null || current.file_identity != watermark.file_identity)
                            throw new IOError.FAILED ("The watermark image changed during folder processing.");
                    }
                    item.recommendation = rec;
                    console_tab.add_line (SmartOptimizer.format_recommendation (rec));
                    if (rec.is_impossible || rec.bit_depth_attention_required) {
                        update_item (item, "failed", rec.bit_depth_attention_required
                            ? (rec.bit_depth_attention_reason ?? "Output bit depth requires attention.")
                            : "Smart Optimizer could not solve this file: " + rec.notes);
                        continue;
                    }
                    SmartCodecResolution? resolution = SmartCodecResolver.resolve (rec, requested, general, true, settings.strip_audio);
                    if (resolution == null)
                        throw new IOError.INVALID_ARGUMENT ("Smart Optimizer returned an unsupported codec.");
                    string incompatible_codec;
                    bool copy_allowed = AudioCompatibilityLogic.container_supports_audio_copy_for_selection (
                        resolution.codec_settings.container, requested.audio_settings.source,
                        requested.audio_settings.all_sources, rec.preserve_all_audio_tracks_effective,
                        out incompatible_codec);
                    resolution = SmartCodecResolver.resolve (rec, requested, general, copy_allowed, settings.strip_audio);
                    if (resolution == null)
                        throw new IOError.INVALID_ARGUMENT ("The recommendation could not be resolved.");
                    EncodeProfileSnapshot profile = resolution.to_profile ();
                    string desired = yield ConversionUtils.compute_output_path_from_profile_async (
                        item.path, output_folder, profile, settings.naming, cancellable, settings.runtime_options.ffprobe_path);
                    check_cancelled (cancellable);
                    item.output_path = desired;
                    if (!convert) {
                        update_item (item, "ready", "Ready — " + rec.notes);
                        continue;
                    }
                    var config = new ConversionConfig ();
                    config.profile = profile;
                    config.runtime_options = settings.runtime_options.copy ();
                    config.seek_enabled = settings.timing.seek_enabled;
                    config.seek_timestamp = timestamp (start);
                    config.time_enabled = settings.timing.time_enabled;
                    config.time_timestamp = timestamp (span);
                    config.source_span_seconds = span;
                    config.video_source_span_seconds = span;
                    config.output_fps = ctx.output_fps;
                    if (rec.pinned_axis == PinnedAxis.SIZE) {
                        config.smart_requested_size_kib = rec.target_size_kib;
                        config.smart_planned_size_kib = rec.two_pass ? rec.expected_final_size_kib : 0;
                        config.smart_planning_uncertainty = rec.two_pass ? rec.expected_size_error_fraction : 0.0;
                    }
                    string stage_path = Path.build_filename (staging, "%06d.%s".printf (index + 1, profile.container));
                    update_item (item, "converting", "Converting one file at a time");
                    check_cancelled (cancellable);
                    OperationOutputResult? encoded = yield execute_prepared (item, stage_path, config,
                        resolution.two_pass, operation_id);
                    if (encoded == null) {
                        check_cancelled (cancellable);
                        update_item (item, "failed", "Conversion failed. See the console for details.");
                        if (!destination_accepts_write (output_folder)) {
                            destination_failed = true;
                            break;
                        }
                        continue;
                    }
                    // A successful video survives cancellation of optional
                    // collage work. Validate it independently of the stopped
                    // batch token, publish it, then stop further dispatch.
                    yield validate_source (item, new Cancellable ());
                    bool late_cancel = stop_requested || cancellable.is_cancelled ();
                    try {
                        string final_path = publish_staged_file (stage_path, desired, items);
                        published.add (final_path);
                        item.output_path = final_path;
                        string[] final_paths = { final_path };
                        foreach (string artifact in encoded.output_paths) {
                            if (artifact == stage_path)
                                continue;
                            // Converter-created collages live beside the staged
                            // video. Refuse any unexpected external artifact.
                            if (Path.get_dirname (artifact) != staging)
                                throw new IOError.PERMISSION_DENIED ("An output artifact is outside the owned staging directory.");
                            string artifact_desired = ConversionUtils.build_collage_output_path (final_path);
                            string final_artifact = publish_staged_file (artifact, artifact_desired, items);
                            final_paths += final_artifact;
                            published.add (final_artifact);
                        }
                        item.result = final_paths.length == 1
                            ? new OperationOutputResult.for_file (final_path)
                            : new OperationOutputResult.for_multiple_files ((owned) final_paths, output_folder, final_path);
                        update_item (item, "completed", late_cancel
                            ? "Completed — optional finalization was cancelled" : "Completed");
                    } catch (Error e) {
                        destination_failed = true;
                        update_item (item, "failed", "Could not publish the output safely: " + e.message);
                        break;
                    }
                    if (late_cancel) {
                        stop_requested = true;
                        break;
                    }
                } catch (IOError.CANCELLED e) {
                    update_item (item, "cancelled", "Cancelled");
                    throw e;
                } catch (Error e) {
                    check_cancelled (cancellable);
                    update_item (item, "failed", e.message);
                    console_tab.add_line ("[Bulk] " + Path.get_basename (item.path) + ": " + e.message);
                }
            }
        } catch (IOError.CANCELLED e) {
            stop_requested = true;
        } catch (Error e) {
            run_error = e.message;
            console_tab.add_line ("[Bulk] " + e.message);
            status_area.set_status (e.message, StatusIcon.ERROR_ICON, StatusIcon.ERROR_CSS);
        } finally {
            // This scope is reached only after analysis children and the
            // prepared converter have completed their cancellation cleanup.
            if (staging != null && staging_identity.length > 0)
                cleanup_staging_directory (staging, staging_identity);
            for (int i = 0; i < items.length; i++) {
                BulkItem item = items[i];
                if (item.state == "pending") {
                    update_item (item, "pending", stop_requested ? "Queued — processing was cancelled"
                        : destination_failed ? "Queued — the destination is unavailable or full" : "Queued — not processed");
                } else if (item.state == "analyzing" || item.state == "converting") {
                    update_item (item, stop_requested ? "cancelled" : "skipped",
                        stop_requested ? "Cancelled before processing" : destination_failed
                            ? "Skipped because the destination is unavailable or full" : "Not processed");
                }
            }
            status_area.stop_progress ();
            is_running = false;
            active_cancel = null;
            if (published.length > 0) {
                var result = new OperationOutputResult.for_multiple_files (
                    OperationOutputResult.copy_paths (published), output_folder,
                    published.length == 1 ? published[0] : "", OperationOutputSource.GENERIC,
                    "Bulk conversion");
                result.summary = "%u output file(s) saved.".printf (published.length);
                output_ready (result);
            }
            if (stop_requested)
                status_area.set_status ("Folder processing cancelled. Completed outputs were kept.",
                    StatusIcon.CANCELLED_ICON, StatusIcon.CANCELLED_CSS);
            else if (destination_failed)
                status_area.set_status ("Folder processing stopped because the destination is unavailable or full.",
                    StatusIcon.ERROR_ICON, StatusIcon.ERROR_CSS);
            else if (run_error == null) {
                int ready = 0, completed = 0, failed = 0;
                for (int i = 0; i < items.length; i++) {
                    if (items[i].state == "ready") ready++;
                    if (items[i].state == "completed") completed++;
                    if (items[i].state == "failed") failed++;
                }
                string summary = convert
                    ? "Folder conversion finished: %d completed, %d failed.".printf (completed, failed)
                    : "Folder analysis finished: %d ready, %d failed.".printf (ready, failed);
                console_tab.add_line ("[Bulk] " + summary);
                status_area.set_status (summary, failed > 0 ? StatusIcon.WARNING_ICON : StatusIcon.SUCCESS_ICON,
                    failed > 0 ? StatusIcon.WARNING_CSS : StatusIcon.SUCCESS_CSS);
            }
            changed ();
            finished (operation_id);
        }
    }
}
