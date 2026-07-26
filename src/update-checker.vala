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
