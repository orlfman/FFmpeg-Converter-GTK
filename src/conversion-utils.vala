using Gtk;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  ConversionUtils — Pure utility functions for the conversion pipeline
//
//  Extracted from Converter to give it a single responsibility.
//  These are all stateless helpers: path computation, filename sanitization,
//  timestamp building/parsing, and time field validation.
// ═══════════════════════════════════════════════════════════════════════════════

namespace ConversionUtils {

    // ═════════════════════════════════════════════════════════════════════════
    //  OUTPUT PATH COMPUTATION
    // ═════════════════════════════════════════════════════════════════════════

    public string compute_output_path (string input_file,
                                       string output_folder,
                                       ICodecBuilder builder,
                                       ICodecTab codec_tab) {
        string out_folder = (output_folder != "")
            ? output_folder
            : Path.get_dirname (input_file);

        string codec_name = builder.get_codec_name ().down ();
        string codec_suffix = codec_name.contains ("av1") ? "av1" : codec_name;

        string container_ext = codec_tab.get_container ();
        if (container_ext == "") container_ext = ContainerExt.MKV;

        string basename = Path.get_basename (input_file);
        int dot_pos = basename.last_index_of_char ('.');
        string name_no_ext = (dot_pos > 0) ? basename.substring (0, dot_pos) : basename;

        return @"$out_folder/$name_no_ext-$codec_suffix.$container_ext";
    }

    public string find_unique_path (string path) {
        if (!FileUtils.test (path, FileTest.EXISTS))
            return path;

        string dir = Path.get_dirname (path);
        string basename = Path.get_basename (path);

        int dot_pos = basename.last_index_of_char ('.');
        string stem = (dot_pos > 0) ? basename.substring (0, dot_pos) : basename;
        string ext  = (dot_pos > 0) ? basename.substring (dot_pos) : "";

        int counter = 1;
        string candidate = path;
        do {
            candidate = Path.build_filename (dir, @"$stem-$counter$ext");
            counter++;
        } while (FileUtils.test (candidate, FileTest.EXISTS));

        return candidate;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  FILENAME SANITIZATION
    // ═════════════════════════════════════════════════════════════════════════

    public string sanitize_filename (string path) {
        string dir = Path.get_dirname (path);
        string name = Path.get_basename (path);

        string safe = name
            .replace ("：", "_")
            .replace ("？", "_")
            .replace ("*", "_")
            .replace ("\"", "_")
            .replace ("<", "_")
            .replace (">", "_")
            .replace ("|", "_")
            .replace ("/", "_")
            .replace ("\\", "_")
            .replace (":", "_");

        safe = safe.strip ().replace (". ", ".").replace (" .", ".");

        return Path.build_filename (dir, safe);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  TIMESTAMP BUILDING & VALIDATION
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Build a validated HH:MM:SS string from SpinButton widgets (#10).
     * SpinButtons already enforce numeric range, so this is simpler and
     * more reliable than the old Entry-based version.
     */
    public string build_timestamp (SpinButton hh, SpinButton mm, SpinButton ss) {
        int h = hh.get_value_as_int ();
        int m = mm.get_value_as_int ();
        int s = ss.get_value_as_int ();
        return "%02d:%02d:%02d".printf (h, m, s);
    }

    /**
     * Parse an FFmpeg "HH:MM:SS.mmm" timestamp into total seconds.
     * Returns -1.0 for unparseable values.
     */
    public double parse_ffmpeg_timestamp (string time_str) {
        if (time_str == "N/A" || time_str.length == 0) {
            return -1.0;
        }
        string[] parts = time_str.split (":");
        if (parts.length < 3) return -1.0;

        int hours   = int.parse (parts[0]);
        int minutes = int.parse (parts[1]);
        double seconds = double.parse (parts[2]);

        return hours * 3600.0 + minutes * 60.0 + seconds;
    }
}
