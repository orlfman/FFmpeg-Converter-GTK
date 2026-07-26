using GLib;

public errordomain UpdateCheckError {
    HTTP,
    INVALID_RESPONSE,
    INVALID_VERSION
}

public enum UpdateAvailability {
    UP_TO_DATE,
    UPDATE_AVAILABLE,
    NEWER_THAN_LATEST
}

/** Result returned by one user-requested GitHub release check. */
public class UpdateCheckResult : Object {
    public string current_version;
    public string latest_version;
    public string release_url;
    public UpdateAvailability availability;

    public UpdateCheckResult (string current_version,
                              string latest_version,
                              string release_url,
                              UpdateAvailability availability) {
        this.current_version = current_version;
        this.latest_version = latest_version;
        this.release_url = release_url;
        this.availability = availability;
    }
}

/**
 * Where this copy of the app came from, so update advice can point somewhere
 * the user can actually act on.
 *
 * Deliberately NOT "is this an Arch distro". Someone on Arch who built from
 * source must still be sent to the GitHub release — telling them to update
 * via the AUR would be wrong, and would step on the very install the
 * Makefile's pacman guard exists to protect. The question is whether THIS
 * binary belongs to the package, which is what `pacman -Qo` answers.
 */
public enum InstallOrigin {
    UNKNOWN,
    AUR_PACKAGE
}

public class InstallDetection : Object {
    /**
     * Arch package name. Kept here rather than in constants.vala so this
     * module stays linkable on its own — constants.vala declares Gtk externs,
     * and pulling GTK into the update-checker test just to read one string
     * would not be a good trade.
     */
    public const string ARCH_PACKAGE_NAME = "ffmpeg-converter-gtk";

    /**
     * Does `pacman -Qo <path>` output say the file belongs to our package?
     *
     * Split out from the process call so the parsing is testable without a
     * pacman database. Output looks like:
     *   /usr/bin/ffmpeg-converter-gtk is owned by ffmpeg-converter-gtk 1.5.8-1
     */
    public static bool owned_by_package (string pacman_output, string package_name) {
        if (pacman_output.length == 0 || package_name.length == 0)
            return false;
        // "is owned by <pkg> <version>" — match the token after the marker so
        // a path that merely contains the package name cannot pass.
        int marker = pacman_output.index_of ("is owned by ");
        if (marker < 0)
            return false;
        string tail = pacman_output.substring (marker + "is owned by ".length).strip ();
        string[] parts = tail.split (" ");
        return parts.length > 0 && parts[0] == package_name;
    }

    private static bool cached = false;
    private static InstallOrigin cached_origin = InstallOrigin.UNKNOWN;

    /** Cached: the answer cannot change while the process is running. */
    public static InstallOrigin detect () {
        if (cached)
            return cached_origin;
        cached = true;
        cached_origin = InstallOrigin.UNKNOWN;

        if (Environment.find_program_in_path ("pacman") == null)
            return cached_origin;

        string exe_path;
        try {
            exe_path = FileUtils.read_link ("/proc/self/exe");
        } catch (Error e) {
            return cached_origin;
        }
        if (exe_path.length == 0)
            return cached_origin;

        try {
            string stdout_buf;
            int status;
            Process.spawn_sync (
                null,
                { "pacman", "-Qo", exe_path },
                null,
                SpawnFlags.SEARCH_PATH | SpawnFlags.STDERR_TO_DEV_NULL,
                null,
                out stdout_buf,
                null,
                out status);
            // A file pacman does not own is a non-zero exit, not an error.
            if (status == 0
                    && owned_by_package (stdout_buf, ARCH_PACKAGE_NAME)) {
                cached_origin = InstallOrigin.AUR_PACKAGE;
            }
        } catch (SpawnError e) {
            // pacman missing or unrunnable — stay UNKNOWN and use GitHub.
        }
        return cached_origin;
    }
}

/**
 * Manual update checker backed by GitHub's latest-release API.
 *
 * Nothing runs on startup and nothing is downloaded. The Preferences dialog
 * creates this object only after the user presses "Check for Updates".
 */
public class UpdateChecker : Object {
    private const string LATEST_RELEASE_API =
        "https://api.github.com/repos/orlfman/FFmpeg-Converter-GTK/releases/latest";
    private const string TRUSTED_RELEASE_PREFIX =
        "https://github.com/orlfman/FFmpeg-Converter-GTK/releases/";
    private const string RELEASES_FALLBACK =
        "https://github.com/orlfman/FFmpeg-Converter-GTK/releases";
    private const uint REQUEST_TIMEOUT_SECONDS = 15;

    private string current_version;

    public UpdateChecker (string current_version) {
        this.current_version = current_version;
    }

    public async UpdateCheckResult check_latest (
        Cancellable? cancellable = null
    ) throws Error {
        var session = new Soup.Session ();
        session.set_timeout (REQUEST_TIMEOUT_SECONDS);
        session.set_user_agent (
            "FFmpeg-Converter-GTK/%s".printf (current_version));

        var message = new Soup.Message ("GET", LATEST_RELEASE_API);
        message.get_request_headers ().replace (
            "Accept", "application/vnd.github+json");
        message.get_request_headers ().replace (
            "X-GitHub-Api-Version", "2022-11-28");

        Bytes body = yield session.send_and_read_async (
            message, Priority.DEFAULT, cancellable);

        Soup.Status status = message.get_status ();
        if (status == Soup.Status.NOT_FOUND) {
            throw new UpdateCheckError.HTTP (
                "GitHub does not have a published release for this project yet.");
        }
        if (status != Soup.Status.OK) {
            string reason = message.get_reason_phrase () ?? "Unknown response";
            throw new UpdateCheckError.HTTP (
                "GitHub returned HTTP %u (%s).",
                (uint) status, reason);
        }

        unowned uint8[]? data = body.get_data ();
        if (data == null || data.length == 0) {
            throw new UpdateCheckError.INVALID_RESPONSE (
                "GitHub returned an empty response.");
        }

        return parse_release_json (
            current_version, (string) data, (ssize_t) data.length);
    }

    /**
     * Parse a latest-release response separately from networking so malformed
     * responses and version comparison can be covered by unit tests.
     */
    public static UpdateCheckResult parse_release_json (
        string current_version,
        string json,
        ssize_t json_length = -1
    ) throws Error {
        var parser = new Json.Parser ();
        try {
            parser.load_from_data (json, json_length);
        } catch (Error e) {
            throw new UpdateCheckError.INVALID_RESPONSE (
                "GitHub returned release information that could not be read.");
        }

        unowned Json.Node? root = parser.get_root ();
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
            throw new UpdateCheckError.INVALID_RESPONSE (
                "GitHub returned release information in an unexpected format.");
        }

        unowned Json.Object release = root.get_object ();
        string latest_version = release
            .get_string_member_with_default ("tag_name", "").strip ();
        if (latest_version.length == 0) {
            throw new UpdateCheckError.INVALID_RESPONSE (
                "GitHub's response did not include a release version.");
        }

        string release_url = release
            .get_string_member_with_default ("html_url", "").strip ();
        if (!release_url.has_prefix (TRUSTED_RELEASE_PREFIX))
            release_url = RELEASES_FALLBACK;

        int comparison;
        if (!compare_versions (latest_version, current_version, out comparison)) {
            throw new UpdateCheckError.INVALID_VERSION (
                "Could not compare installed version %s with release %s.",
                current_version, latest_version);
        }

        UpdateAvailability availability;
        if (comparison > 0)
            availability = UpdateAvailability.UPDATE_AVAILABLE;
        else if (comparison < 0)
            availability = UpdateAvailability.NEWER_THAN_LATEST;
        else
            availability = UpdateAvailability.UP_TO_DATE;

        return new UpdateCheckResult (
            current_version, latest_version, release_url, availability);
    }

    /**
     * Compare release-style numeric versions such as 1.5.8 or v1.6.0.
     * A prerelease/build suffix is ignored because GitHub's latest-release
     * endpoint itself excludes prereleases.
     */
    public static bool compare_versions (
        string left,
        string right,
        out int comparison
    ) {
        comparison = 0;
        int[] left_parts = {};
        int[] right_parts = {};
        if (!parse_version (left, out left_parts)
                || !parse_version (right, out right_parts)) {
            return false;
        }

        int count = int.max (left_parts.length, right_parts.length);
        for (int i = 0; i < count; i++) {
            int left_value = (i < left_parts.length) ? left_parts[i] : 0;
            int right_value = (i < right_parts.length) ? right_parts[i] : 0;
            if (left_value == right_value)
                continue;
            comparison = (left_value > right_value) ? 1 : -1;
            return true;
        }
        return true;
    }

    private static bool parse_version (string value, out int[] parts) {
        parts = {};
        int[] parsed_parts = {};
        string normalized = value.strip ();
        if (normalized.has_prefix ("v") || normalized.has_prefix ("V"))
            normalized = normalized.substring (1);

        int suffix = normalized.index_of_char ('-');
        int build = normalized.index_of_char ('+');
        if (suffix >= 0 && build >= 0)
            suffix = int.min (suffix, build);
        else if (suffix < 0)
            suffix = build;
        if (suffix >= 0)
            normalized = normalized.substring (0, suffix);

        if (normalized.length == 0)
            return false;

        foreach (unowned string component in normalized.split (".")) {
            if (component.length == 0)
                return false;
            for (int i = 0; i < component.length; i++) {
                if (component[i] < '0' || component[i] > '9')
                    return false;
            }
            int parsed;
            if (!int.try_parse (component, out parsed) || parsed < 0)
                return false;
            parsed_parts += parsed;
        }
        parts = (owned) parsed_parts;
        return parts.length > 0;
    }
}
