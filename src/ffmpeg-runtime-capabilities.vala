using GLib;

public enum SvtAv1CrfTwoPassCapabilityStatus {
    UNKNOWN,
    PROBING,
    SUPPORTED,
    UNSUPPORTED,
    ERROR
}

public class SvtAv1CrfTwoPassCapability : Object {
    public SvtAv1CrfTwoPassCapabilityStatus status {
        get; set; default = SvtAv1CrfTwoPassCapabilityStatus.UNKNOWN;
    }
    public string? reason { get; set; default = null; }

    public SvtAv1CrfTwoPassCapability copy () {
        var duplicate = new SvtAv1CrfTwoPassCapability ();
        duplicate.status = status;
        duplicate.reason = reason;
        return duplicate;
    }
}

public class FfmpegRuntimeCapabilities : Object {
    private const uint SVT_CRF_TWO_PASS_PROBE_TIMEOUT_MS = 15000;

    private HashTable<string, SvtAv1CrfTwoPassCapability> svt_crf_two_pass_cache =
        new HashTable<string, SvtAv1CrfTwoPassCapability> (str_hash, str_equal);
    private SvtAv1CrfTwoPassCapability current_svt_crf_two_pass =
        new SvtAv1CrfTwoPassCapability ();

    public signal void svt_crf_two_pass_changed (SvtAv1CrfTwoPassCapability capability);

    public SvtAv1CrfTwoPassCapability get_current_svt_crf_two_pass () {
        return current_svt_crf_two_pass.copy ();
    }

    public void set_current_svt_crf_two_pass (SvtAv1CrfTwoPassCapabilityStatus status,
                                              string? reason = null) {
        current_svt_crf_two_pass.status = status;
        current_svt_crf_two_pass.reason = reason;
        svt_crf_two_pass_changed (current_svt_crf_two_pass.copy ());
    }

    public bool lookup_cached_svt_crf_two_pass (string binary_path,
                                                out SvtAv1CrfTwoPassCapability capability) {
        string cache_key = build_binary_cache_key (binary_path);
        SvtAv1CrfTwoPassCapability? cached = svt_crf_two_pass_cache.lookup (cache_key);
        if (cached == null) {
            capability = new SvtAv1CrfTwoPassCapability ();
            return false;
        }

        capability = cached.copy ();
        return true;
    }

    public void cache_svt_crf_two_pass (string binary_path,
                                        SvtAv1CrfTwoPassCapability capability) {
        string cache_key = build_binary_cache_key (binary_path);
        svt_crf_two_pass_cache.insert (cache_key, capability.copy ());
    }

    public static string build_binary_cache_key (string binary_path) {
        string resolved_path = AppSettings.normalize_executable_path (binary_path, "ffmpeg");
        if (!resolved_path.contains ("/") && !Path.is_absolute (resolved_path)) {
            string? found = Environment.find_program_in_path (resolved_path);
            if (found != null) {
                resolved_path = found;
            }
        }

        var file = File.new_for_path (resolved_path);
        try {
            var info = file.query_info (
                "standard::size,time::modified,time::modified-usec",
                FileQueryInfoFlags.NONE
            );

            int64 modified_unix = 0;
            DateTime? modified_time = info.get_modification_date_time ();
            if (modified_time != null) {
                modified_unix = modified_time.to_unix ();
            }

            return resolved_path
                + "|" + ((int64) info.get_size ()).to_string ()
                + "|" + modified_unix.to_string ()
                + "|" + ((int64) info.get_attribute_uint32 ("time::modified-usec")).to_string ();
        } catch (Error e) {
            return resolved_path;
        }
    }

    public static async SvtAv1CrfTwoPassCapability probe_svt_av1_crf_two_pass (
        string binary_path,
        Cancellable cancellable) throws Error {
        string? run_dir = null;
        string passlog_base = "";

        try {
            run_dir = ConversionUtils.create_managed_temp_run_dir (
                "runtime-capability",
                "svt-av1-crf-two-pass"
            );
            if (run_dir == null) {
                var failed = new SvtAv1CrfTwoPassCapability ();
                failed.status = SvtAv1CrfTwoPassCapabilityStatus.ERROR;
                failed.reason =
                    "SVT-AV1 CRF/QP two-pass: could not create a temporary probe directory.";
                return failed;
            }

            passlog_base = Path.build_filename (run_dir, "passlog");

            string[] base_cmd = {
                binary_path,
                "-hide_banner", "-loglevel", "error", "-nostdin",
                "-f", "lavfi", "-i", "color=c=black:s=64x64:r=2:d=1.0",
                "-frames:v", "2",
                "-an",
                "-c:v", "libsvtav1",
                "-preset", "8",
                "-crf", "40"
            };

            string[] pass1 = {};
            foreach (string arg in base_cmd) {
                pass1 += arg;
            }
            pass1 += "-pass";
            pass1 += "1";
            pass1 += "-passlogfile";
            pass1 += passlog_base;
            pass1 += "-f";
            pass1 += "null";
            pass1 += "-";
            yield run_subprocess_capture (pass1, cancellable);

            string[] pass2 = {};
            foreach (string arg in base_cmd) {
                pass2 += arg;
            }
            pass2 += "-pass";
            pass2 += "2";
            pass2 += "-passlogfile";
            pass2 += passlog_base;
            pass2 += "-f";
            pass2 += "null";
            pass2 += "-";
            yield run_subprocess_capture (pass2, cancellable);

            var supported = new SvtAv1CrfTwoPassCapability ();
            supported.status = SvtAv1CrfTwoPassCapabilityStatus.SUPPORTED;
            supported.reason = "SVT-AV1 CRF/QP two-pass: supported by this FFmpeg build.";
            return supported;
        } catch (IOError.CANCELLED e) {
            throw e;
        } catch (Error e) {
            string detail = describe_probe_error (e.message);

            var capability = new SvtAv1CrfTwoPassCapability ();
            if (e.message.index_of ("CRF does not support multi-pass") >= 0) {
                capability.status = SvtAv1CrfTwoPassCapabilityStatus.UNSUPPORTED;
                capability.reason =
                    "SVT-AV1 CRF/QP two-pass: unsupported by this FFmpeg/SVT-AV1 build.";
            } else {
                capability.status = SvtAv1CrfTwoPassCapabilityStatus.ERROR;
                capability.reason =
                    "SVT-AV1 CRF/QP two-pass: could not be verified (" + detail + ").";
            }
            return capability;
        } finally {
            cleanup_probe_artifacts (passlog_base, run_dir);
        }
    }

    private static async string run_subprocess_capture (string[] cmd,
                                                        Cancellable cancellable) throws Error {
        var launcher = new SubprocessLauncher (
            SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
        var proc = SubprocessCompat.spawnv (launcher, cmd);

        bool timed_out = false;
        uint timeout_id = 0;
        var local_cancel = new Cancellable ();
        ulong parent_id = cancellable.connect (() => { local_cancel.cancel (); });
        timeout_id = Timeout.add (SVT_CRF_TWO_PASS_PROBE_TIMEOUT_MS, () => {
            timed_out = true;
            local_cancel.cancel ();
            timeout_id = 0;
            return Source.REMOVE;
        });

        string stdout_buf;
        string stderr_buf;
        try {
            yield proc.communicate_utf8_async (null, local_cancel, out stdout_buf, out stderr_buf);
        } catch (Error e) {
            proc.force_exit ();
            if (timeout_id != 0) {
                Source.remove (timeout_id);
            }
            cancellable.disconnect (parent_id);
            if (timed_out) {
                throw new IOError.TIMED_OUT ("SVT-AV1 CRF/QP two-pass probe timed out");
            }
            throw e;
        }

        if (timeout_id != 0) {
            Source.remove (timeout_id);
        }
        cancellable.disconnect (parent_id);

        if (!proc.get_successful ()) {
            string combined_output = build_combined_output (stderr_buf, stdout_buf);
            if (combined_output.length == 0) {
                combined_output = "SVT-AV1 CRF/QP two-pass probe exited with status %d"
                    .printf (proc.get_exit_status ());
            }
            throw new IOError.FAILED (combined_output);
        }

        return build_combined_output (stderr_buf, stdout_buf);
    }

    private static string describe_probe_error (string message) {
        string detail = select_probe_diagnostic_line (message) ?? message.strip ();
        if (detail.index_of ("timed out") >= 0) {
            return "the FFmpeg probe timed out";
        }
        if (detail.index_of ("Permission denied") >= 0) {
            return "permission was denied while starting ffmpeg";
        }
        if (detail.index_of ("No such file or directory") >= 0) {
            return "the configured ffmpeg binary could not be started";
        }
        return detail;
    }

    private static string build_combined_output (string? primary,
                                                 string? secondary) {
        string combined = "";
        if (primary != null && primary.strip ().length > 0) {
            combined += primary.strip ();
        }
        if (secondary != null && secondary.strip ().length > 0) {
            if (combined.length > 0) {
                combined += "\n";
            }
            combined += secondary.strip ();
        }
        return combined;
    }

    private static string? select_probe_diagnostic_line (string? text) {
        if (text == null) {
            return null;
        }

        string[] lines = text.split ("\n");

        foreach (string line in lines) {
            string clean = line.strip ();
            if (clean.index_of ("CRF does not support multi-pass") >= 0) {
                return clean;
            }
        }

        foreach (string line in lines) {
            string clean = line.strip ();
            string lower = clean.down ();
            if (clean.length == 0) {
                continue;
            }
            if (lower.contains ("[error]")
                || clean.has_prefix ("Error")
                || lower.contains ("invalid ")
                || lower.contains ("permission denied")
                || lower.contains ("no such file or directory")
                || lower.contains ("timed out")
                || lower.contains ("cannot write log file")) {
                return clean;
            }
        }

        foreach (string line in lines) {
            string clean = line.strip ();
            if (clean.length == 0) {
                continue;
            }
            if (!clean.has_prefix ("Svt[info]:")
                && !clean.has_prefix ("SvtMalloc[info]:")
                && !clean.has_prefix ("Svt[warn]:")) {
                return clean;
            }
        }

        return first_nonempty_line (text);
    }

    private static string? first_nonempty_line (string? text) {
        if (text == null) {
            return null;
        }

        foreach (string line in text.split ("\n")) {
            string clean = line.strip ();
            if (clean.length > 0) {
                return clean;
            }
        }

        return null;
    }

    private static void cleanup_probe_artifacts (string passlog_base,
                                                 string? run_dir) {
        if (passlog_base.length > 0) {
            string[] suffixes = {
                "-0.log", "-0.log.mbtree", "-0.log.cutree",
                "-0.log.temp", ".log", ".log.mbtree"
            };

            foreach (string suffix in suffixes) {
                try {
                    var file = File.new_for_path (passlog_base + suffix);
                    if (file.query_exists ()) {
                        file.delete ();
                    }
                } catch (Error e) {
                    // Best-effort cleanup for capability probes.
                }
            }
        }

        if (run_dir != null) {
            ConversionUtils.try_remove_empty_dir_chain (
                run_dir,
                ConversionUtils.get_app_temp_root ()
            );
        }
    }
}
