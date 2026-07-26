// smart-optimizer-cache.vala
// Persistent calibration sample cache for the Smart Optimizer.
//
// A calibration sample is a measured (CRF → full-length size KiB) point.
// It stays valid as long as everything that shaped the measurement is
// unchanged: the input file (path, size, mtime), codec, calibration
// preset, pixel format, video filter chain, trim window, sample
// positions, and the complexity extrapolation weight.  All of those are
// folded into the cache key, so a stale hit is impossible short of an
// mtime-preserving file edit.
//
// The payoff: re-running the optimizer with only a different target size
// (same tier → same preset/pix_fmt) reuses the measured points and skips
// the matching calibration encodes entirely.  Different tiers still get
// partial reuse wherever their CRF windows overlap.
//
// Storage: one JSON file directly under the app temp root (per-boot on
// tmpfs /tmp — deliberately self-cleaning; it sits OUTSIDE the per-run
// temp dirs so conversion cleanup never removes it), most-recently-used
// entry first, capped at MAX_ENTRIES.  All I/O failures degrade to
// "no cache" with a warning — never an error.

using GLib;
using Json;

public class SmartOptimizerCache : GLib.Object {

    private const int    CACHE_FORMAT_VERSION = 1;
    private const int    MAX_ENTRIES = 32;
    private const string FIELD_SEP = "\x1f";

    /** Test hook: overrides the on-disk cache file location. */
    public static string? cache_file_override = null;

    /**
     * One measured probe. A size is always present; VMAF only when the run
     * that produced it was a quality solve, since Size Mode never measures it.
     */
    private class Sample : GLib.Object {
        public double size_kib;
        public double vmaf;          // 0.0 = not measured
        public Sample (double size_kib, double vmaf) {
            this.size_kib = size_kib;
            this.vmaf = vmaf;
        }
    }

    private string key;
    private HashTable<int, Sample> samples =
        new HashTable<int, Sample> (direct_hash, direct_equal);
    private bool dirty = false;

    private SmartOptimizerCache (string key) {
        this.key = key;
        load ();
    }

    /**
     * Create a cache handle for one optimizer run.  Returns null when the
     * input file cannot be stat'd (no identity → no safe caching).
     */
    public static SmartOptimizerCache? try_create (
        string   input_file,
        string   codec,
        int      preset_idx,
        string   pix_fmt,
        string   video_filter_chain,
        double   trim_start,
        double   encode_duration,
        double   segment_duration,
        double[] positions,
        double   extrapolation_weight
    ) {
        int64 file_size, mtime;
        if (!stat_input (input_file, out file_size, out mtime))
            return null;
        string key = build_cache_key (
            input_file, file_size, mtime, codec, preset_idx, pix_fmt,
            video_filter_chain, trim_start, encode_duration,
            segment_duration, positions, extrapolation_weight);
        return new SmartOptimizerCache (key);
    }

    /**
     * Deterministic key over every input that shapes a calibration sample.
     * Doubles are rounded so re-derived values that agree to display
     * precision hash identically.
     */
    public static string build_cache_key (
        string   input_file,
        int64    file_size,
        int64    mtime,
        string   codec,
        int      preset_idx,
        string   pix_fmt,
        string   video_filter_chain,
        double   trim_start,
        double   encode_duration,
        double   segment_duration,
        double[] positions,
        double   extrapolation_weight
    ) {
        var sb = new StringBuilder ();
        sb.append ("v%d".printf (CACHE_FORMAT_VERSION));
        sb.append (FIELD_SEP); sb.append (input_file);
        sb.append (FIELD_SEP); sb.append (file_size.to_string ());
        sb.append (FIELD_SEP); sb.append (mtime.to_string ());
        sb.append (FIELD_SEP); sb.append (codec);
        sb.append (FIELD_SEP); sb.append (preset_idx.to_string ());
        sb.append (FIELD_SEP); sb.append (pix_fmt);
        sb.append (FIELD_SEP); sb.append (video_filter_chain);
        sb.append (FIELD_SEP); sb.append ("%.2f".printf (trim_start));
        sb.append (FIELD_SEP); sb.append ("%.3f".printf (encode_duration));
        sb.append (FIELD_SEP); sb.append ("%.3f".printf (segment_duration));
        sb.append (FIELD_SEP); sb.append ("%.4f".printf (extrapolation_weight));
        for (int i = 0; i < positions.length; i++) {
            sb.append (FIELD_SEP);
            sb.append ("%.2f".printf (positions[i]));
        }
        return sb.str;
    }

    public bool lookup (int crf, out double size_kib) {
        Sample? v = samples.lookup (crf);
        if (v == null) {
            size_kib = 0.0;
            return false;
        }
        size_kib = v.size_kib;
        return true;
    }

    /**
     * Quality-mode lookup: succeeds only when the stored sample carries a VMAF
     * score. A size-only hit is useless to the quality solver — it would still
     * have to encode the probe to measure the score, so there would be nothing
     * to save.
     */
    public bool lookup_with_vmaf (int crf, out double size_kib, out double vmaf) {
        size_kib = 0.0;
        vmaf = 0.0;
        Sample? v = samples.lookup (crf);
        if (v == null || v.vmaf <= 0.0)
            return false;
        size_kib = v.size_kib;
        vmaf = v.vmaf;
        return true;
    }

    public void record (int crf, double size_kib) {
        if (size_kib <= 0)
            return;
        // Preserve any VMAF already measured for this CRF — a later size-only
        // write must not silently discard it.
        Sample? existing = samples.lookup (crf);
        double keep_vmaf = (existing != null) ? existing.vmaf : 0.0;
        samples.replace (crf, new Sample (size_kib, keep_vmaf));
        dirty = true;
    }

    public void record_with_vmaf (int crf, double size_kib, double vmaf) {
        if (size_kib <= 0)
            return;
        samples.replace (crf, new Sample (size_kib, vmaf > 0.0 ? vmaf : 0.0));
        dirty = true;
    }

    public uint sample_count {
        get { return samples.size (); }
    }

    /**
     * Merge this run's samples into the on-disk store.  Our entry is
     * written first (most-recently-used ordering), other entries keep
     * their order, oldest beyond MAX_ENTRIES are dropped.
     */
    public void save () {
        if (!dirty)
            return;
        string path = cache_file_path ();

        // Collect entries other than ours from the existing store.
        var others = new GenericArray<Json.Node> ();
        if (FileUtils.test (path, FileTest.EXISTS)) {
            try {
                var parser = new Json.Parser ();
                parser.load_from_file (path);
                var root = parser.get_root ();
                if (root != null && root.get_node_type () == Json.NodeType.OBJECT
                        && root.get_object ().has_member ("entries")) {
                    var entries = root.get_object ().get_array_member ("entries");
                    for (uint i = 0; i < entries.get_length (); i++) {
                        unowned Json.Node node = entries.get_element (i);
                        if (node.get_node_type () != Json.NodeType.OBJECT)
                            continue;
                        if (node.get_object ().get_string_member_with_default ("key", "") == key)
                            continue;
                        others.add (node.copy ());
                    }
                }
            } catch (Error e) {
                warning ("Smart Optimizer cache: could not read %s (%s) — rewriting",
                    path, e.message);
                others = new GenericArray<Json.Node> ();
            }
        }
        while (others.length > MAX_ENTRIES - 1) {
            others.remove_index (others.length - 1);
        }

        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("version");
        builder.add_int_value (CACHE_FORMAT_VERSION);
        builder.set_member_name ("entries");
        builder.begin_array ();

        builder.begin_object ();
        builder.set_member_name ("key");
        builder.add_string_value (key);
        builder.set_member_name ("last_used");
        builder.add_int_value (get_real_time () / 1000000);
        builder.set_member_name ("samples");
        builder.begin_array ();
        samples.foreach ((crf, sample) => {
            builder.begin_array ();
            builder.add_int_value (crf);
            builder.add_double_value (sample.size_kib);
            // Third element only when measured, so entries written by
            // size-only runs stay byte-identical to the old format.
            if (sample.vmaf > 0.0)
                builder.add_double_value (sample.vmaf);
            builder.end_array ();
        });
        builder.end_array ();
        builder.end_object ();

        for (int i = 0; i < others.length; i++) {
            builder.add_value (others.get (i).copy ());
        }
        builder.end_array ();
        builder.end_object ();

        try {
            DirUtils.create_with_parents (GLib.Path.get_dirname (path), 0755);
            var generator = new Json.Generator ();
            generator.set_root (builder.get_root ());
            generator.to_file (path);
            dirty = false;
        } catch (Error e) {
            warning ("Smart Optimizer cache: failed to write %s: %s", path, e.message);
        }
    }

    private void load () {
        string path = cache_file_path ();
        if (!FileUtils.test (path, FileTest.EXISTS))
            return;
        try {
            var parser = new Json.Parser ();
            parser.load_from_file (path);
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
                return;
            var obj = root.get_object ();
            if (!obj.has_member ("entries"))
                return;
            var entries = obj.get_array_member ("entries");
            for (uint i = 0; i < entries.get_length (); i++) {
                unowned Json.Node node = entries.get_element (i);
                if (node.get_node_type () != Json.NodeType.OBJECT)
                    continue;
                var e = node.get_object ();
                if (e.get_string_member_with_default ("key", "") != key)
                    continue;
                if (!e.has_member ("samples"))
                    return;
                var arr = e.get_array_member ("samples");
                for (uint j = 0; j < arr.get_length (); j++) {
                    var s = arr.get_array_element (j);
                    if (s == null || s.get_length () < 2)
                        continue;
                    int crf = (int) s.get_int_element (0);
                    double size_kib = s.get_double_element (1);
                    // Older entries are 2-element [crf, size]; quality runs
                    // append the score. Both shapes load.
                    double vmaf = (s.get_length () >= 3)
                        ? s.get_double_element (2) : 0.0;
                    if (size_kib > 0)
                        samples.insert (crf, new Sample (size_kib, vmaf));
                }
                return;
            }
        } catch (Error e) {
            warning ("Smart Optimizer cache: failed to load %s: %s", path, e.message);
        }
    }

    private static bool stat_input (string path, out int64 size, out int64 mtime) {
        size = 0;
        mtime = 0;
        try {
            var fi = File.new_for_path (path).query_info (
                FileAttribute.STANDARD_SIZE + "," + FileAttribute.TIME_MODIFIED,
                FileQueryInfoFlags.NONE);
            size = fi.get_size ();
            mtime = (int64) fi.get_attribute_uint64 (FileAttribute.TIME_MODIFIED);
            return true;
        } catch (Error e) {
            warning ("Smart Optimizer cache: cannot stat %s: %s", path, e.message);
            return false;
        }
    }

    private static string cache_file_path () {
        if (cache_file_override != null)
            return cache_file_override;
        return GLib.Path.build_filename (
            ConversionUtils.get_app_temp_root (),
            "smart-optimizer-cache.json");
    }
}
