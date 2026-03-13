using GLib;

public enum OperationOutputKind {
    FILE,
    DIRECTORY,
    MULTIPLE_FILES
}

public class OperationOutputResult : Object {
    public OperationOutputKind kind { get; construct set; default = OperationOutputKind.FILE; }
    public string[] output_paths { get; construct set; default = {}; }
    public string primary_file_path { get; construct set; default = ""; }
    public string open_folder_path { get; construct set; default = ""; }

    public OperationOutputResult.for_file (string path) {
        string[] paths = { path };
        Object (
            kind: OperationOutputKind.FILE,
            output_paths: paths,
            primary_file_path: path,
            open_folder_path: Path.get_dirname (path)
        );
    }

    public OperationOutputResult.for_directory (string path) {
        string[] paths = new string[0];
        Object (
            kind: OperationOutputKind.DIRECTORY,
            output_paths: paths,
            primary_file_path: "",
            open_folder_path: path
        );
    }

    public OperationOutputResult.for_multiple_files (owned string[] paths,
                                                     string open_folder_path,
                                                     string primary_file_path = "") {
        Object (
            kind: OperationOutputKind.MULTIPLE_FILES,
            output_paths: (owned) paths,
            primary_file_path: primary_file_path,
            open_folder_path: open_folder_path
        );
    }

    public static OperationOutputResult from_paths (owned string[] paths,
                                                    string open_folder_path = "") {
        if (paths.length == 1) {
            string primary_path = paths[0];
            return new OperationOutputResult.for_multiple_files (
                (owned) paths,
                open_folder_path,
                primary_path
            );
        }

        if (paths.length == 0 && open_folder_path.length > 0) {
            return new OperationOutputResult.for_directory (open_folder_path);
        }

        return new OperationOutputResult.for_multiple_files ((owned) paths, open_folder_path);
    }

    public int get_output_count () {
        if (output_paths.length > 0) {
            return output_paths.length;
        }

        if (kind == OperationOutputKind.FILE || primary_file_path.length > 0) {
            return 1;
        }

        if (kind == OperationOutputKind.DIRECTORY && open_folder_path.length > 0) {
            return 1;
        }

        return 0;
    }

    public string get_open_folder_target () {
        if (open_folder_path.length > 0) {
            return open_folder_path;
        }

        if (primary_file_path.length > 0) {
            return Path.get_dirname (primary_file_path);
        }

        if (output_paths.length > 0) {
            return Path.get_dirname (output_paths[0]);
        }

        return "";
    }

    public string get_display_label () {
        switch (kind) {
            case OperationOutputKind.FILE:
                return basename_or_path (primary_file_path);

            case OperationOutputKind.DIRECTORY:
                return basename_or_path (get_open_folder_target ());

            case OperationOutputKind.MULTIPLE_FILES:
                int count = get_output_count ();
                return (count > 0)
                    ? @"$count file$(count == 1 ? "" : "s")"
                    : "Multiple files";

            default:
                return "Output";
        }
    }

    public string get_notification_body () {
        switch (kind) {
            case OperationOutputKind.FILE:
                return @"$(get_display_label ()) is ready.";

            case OperationOutputKind.DIRECTORY:
                return @"Saved to $(get_display_label ()).";

            case OperationOutputKind.MULTIPLE_FILES:
                int count = get_output_count ();
                if (count > 0) {
                    return @"$count file$(count == 1 ? " is" : "s are") ready.";
                }
                return "Multiple outputs are ready.";

            default:
                return "Output is ready.";
        }
    }

    public bool prefers_folder_action () {
        return kind != OperationOutputKind.FILE;
    }

    public static string[] copy_paths (GenericArray<string> paths) {
        string[] copied = new string[paths.length];
        for (int i = 0; i < paths.length; i++) {
            copied[i] = paths[i];
        }
        return copied;
    }

    private static string basename_or_path (string path) {
        if (path.length == 0) {
            return "";
        }

        string basename = Path.get_basename (path);
        return basename.length > 0 ? basename : path;
    }
}
