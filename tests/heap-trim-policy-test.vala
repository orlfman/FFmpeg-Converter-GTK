using GLib;

private const int64 KIB = 1024;
private const int64 MIB = 1024 * 1024;
private const int64 GIB = 1024 * 1024 * 1024;

private void assert_equal_int64 (int64 actual, int64 expected, string context) {
    if (actual != expected) {
        Test.fail_printf ("%s expected %s but got %s",
                          context,
                          expected.to_string (),
                          actual.to_string ());
    }
}

private void assert_true (bool value, string context) {
    if (!value) Test.fail_printf ("%s expected true but got false", context);
}

private void assert_false (bool value, string context) {
    if (value) Test.fail_printf ("%s expected false but got true", context);
}

// ── VmRSS parsing ───────────────────────────────────────────────────────────

private const string REAL_STATUS = """Name:	ffmpeg-converte
Umask:	0022
State:	S (sleeping)
Tgid:	192583
Pid:	192583
VmPeak:	40555384 kB
VmSize:	40331988 kB
VmLck:	       0 kB
VmRSS:	  431728 kB
RssAnon:	  245920 kB
RssFile:	  185780 kB
VmSwap:	       0 kB
Threads:	57
""";

private void test_parses_vmrss_from_real_status_block () {
    assert_equal_int64 (HeapTrimPolicy.parse_vmrss_bytes (REAL_STATUS),
                        431728 * KIB,
                        "VmRSS from a real /proc/self/status block");
}

private void test_does_not_confuse_vmrss_with_similar_fields () {
    // RssAnon/RssFile/VmPeak all appear before or after VmRSS and must not be
    // picked up by a loose prefix match.
    int64 parsed = HeapTrimPolicy.parse_vmrss_bytes (REAL_STATUS);
    assert_false (parsed == 40555384 * KIB, "must not read VmPeak");
    assert_false (parsed == 245920 * KIB, "must not read RssAnon");
    assert_false (parsed == 185780 * KIB, "must not read RssFile");
}

private void test_parses_the_measured_spike_value () {
    string status = "VmRSS:\t38052692 kB\n";
    assert_equal_int64 (HeapTrimPolicy.parse_vmrss_bytes (status),
                        38052692 * KIB,
                        "36 GiB spike value");
}

private void test_missing_field_is_unknown () {
    string status = "Name:\tthing\nThreads:\t4\n";
    assert_equal_int64 (HeapTrimPolicy.parse_vmrss_bytes (status), -1,
                        "absent VmRSS");
}

private void test_empty_input_is_unknown () {
    assert_equal_int64 (HeapTrimPolicy.parse_vmrss_bytes (""), -1,
                        "empty status text");
}

private void test_unexpected_unit_is_unknown () {
    // If the kernel ever stops reporting kB, silently treating the number as
    // kB would be off by a factor of 1024.
    assert_equal_int64 (HeapTrimPolicy.parse_vmrss_bytes ("VmRSS:\t512 MB\n"), -1,
                        "unexpected unit");
    assert_equal_int64 (HeapTrimPolicy.parse_vmrss_bytes ("VmRSS:\t512\n"), -1,
                        "missing unit");
}

private void test_malformed_value_is_unknown () {
    assert_equal_int64 (HeapTrimPolicy.parse_vmrss_bytes ("VmRSS:\tnonsense kB\n"), -1,
                        "non-numeric value");
    assert_equal_int64 (HeapTrimPolicy.parse_vmrss_bytes ("VmRSS:\t kB\n"), -1,
                        "empty value");
    assert_equal_int64 (HeapTrimPolicy.parse_vmrss_bytes ("VmRSS:\t-8 kB\n"), -1,
                        "negative value");
}

private void test_zero_rss_is_parsed_not_rejected () {
    // Zero is a legitimate reading, distinct from "unknown".
    assert_equal_int64 (HeapTrimPolicy.parse_vmrss_bytes ("VmRSS:\t0 kB\n"), 0,
                        "zero RSS");
}

// ── Trim policy ─────────────────────────────────────────────────────────────

private void test_trims_after_releasing_a_large_source () {
    assert_true (HeapTrimPolicy.should_trim (36L * GIB, true),
                 "36 GiB after replacing an input");
}

private void test_does_not_trim_without_a_previous_input () {
    // First file loaded into a fresh window: nothing was released, so a trim
    // would only cost page faults.
    assert_false (HeapTrimPolicy.should_trim (36L * GIB, false),
                  "high RSS but no prior input");
}

private void test_does_not_trim_during_ordinary_editing () {
    assert_false (HeapTrimPolicy.should_trim (213 * MIB, true),
                  "clean-launch baseline");
    assert_false (HeapTrimPolicy.should_trim (600 * MIB, true),
                  "ordinary small input");
}

private void test_threshold_boundary () {
    assert_false (HeapTrimPolicy.should_trim (HeapTrimPolicy.RSS_TRIGGER_BYTES - 1, true),
                  "one byte below the trigger");
    assert_true (HeapTrimPolicy.should_trim (HeapTrimPolicy.RSS_TRIGGER_BYTES, true),
                 "exactly at the trigger");
}

private void test_unknown_rss_does_not_trim () {
    // parse_vmrss_bytes returns -1 when it cannot read RSS; that must not be
    // treated as either "small" or "huge".
    assert_false (HeapTrimPolicy.should_trim (-1, true), "unknown RSS");
}

public static int main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/heap-trim/parses-real-status-block",
                   test_parses_vmrss_from_real_status_block);
    Test.add_func ("/heap-trim/ignores-similar-fields",
                   test_does_not_confuse_vmrss_with_similar_fields);
    Test.add_func ("/heap-trim/parses-spike-value",
                   test_parses_the_measured_spike_value);
    Test.add_func ("/heap-trim/missing-field-is-unknown",
                   test_missing_field_is_unknown);
    Test.add_func ("/heap-trim/empty-input-is-unknown",
                   test_empty_input_is_unknown);
    Test.add_func ("/heap-trim/unexpected-unit-is-unknown",
                   test_unexpected_unit_is_unknown);
    Test.add_func ("/heap-trim/malformed-value-is-unknown",
                   test_malformed_value_is_unknown);
    Test.add_func ("/heap-trim/zero-rss-is-parsed",
                   test_zero_rss_is_parsed_not_rejected);

    Test.add_func ("/heap-trim/trims-after-large-source",
                   test_trims_after_releasing_a_large_source);
    Test.add_func ("/heap-trim/no-trim-without-previous-input",
                   test_does_not_trim_without_a_previous_input);
    Test.add_func ("/heap-trim/no-trim-during-ordinary-editing",
                   test_does_not_trim_during_ordinary_editing);
    Test.add_func ("/heap-trim/threshold-boundary",
                   test_threshold_boundary);
    Test.add_func ("/heap-trim/unknown-rss-does-not-trim",
                   test_unknown_rss_does_not_trim);

    return Test.run ();
}
