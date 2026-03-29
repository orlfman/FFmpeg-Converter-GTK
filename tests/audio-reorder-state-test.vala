using Gtk;
using GLib;

// ═══════════════════════════════════════════════════════════════════════════════
//  Audio Reorder State Tests
//
//  Exercises the real static methods inside AudioTab via the _for_test()
//  accessors (gated behind AUDIO_REORDER_TEST_BUILD).  These tests catch
//  regressions in move, changed-detection, and reset logic.
// ═══════════════════════════════════════════════════════════════════════════════

// ── Helpers ─────────────────────────────────────────────────────────────────

private GenericArray<int> make_indices (int[] values) {
    var indices = new GenericArray<int> ();
    foreach (int v in values) indices.add (v);
    return indices;
}

private void assert_indices (GenericArray<int> indices, int[] expected, string context) {
    if (indices.length != expected.length) {
        Test.fail_printf ("%s: expected length %d, got %d",
            context, expected.length, indices.length);
        return;
    }
    for (int i = 0; i < expected.length; i++) {
        if (indices[i] != expected[i]) {
            Test.fail_printf ("%s: index[%d] expected %d, got %d",
                context, i, expected[i], indices[i]);
        }
    }
}

private void assert_string_equal (string? actual, string? expected, string context) {
    string a = actual ?? "(null)";
    string e = expected ?? "(null)";
    if (actual != expected) {
        Test.fail_printf ("%s: expected '%s', got '%s'", context, e, a);
    }
}

// ── reorder problem validation ──────────────────────────────────────────────

private void test_problem_requires_input_file () {
    assert_string_equal (
        AudioTab.resolve_reorder_problem_for_test ("", false, 0, false),
        "Load a file to begin reordering audio streams!",
        "missing input file"
    );
}

private void test_problem_requires_audio_streams () {
    assert_string_equal (
        AudioTab.resolve_reorder_problem_for_test ("input.mkv", false, 0, false),
        "The selected file has no audio streams.",
        "no audio streams"
    );
}

private void test_problem_requires_multiple_audio_streams () {
    assert_string_equal (
        AudioTab.resolve_reorder_problem_for_test ("input.mkv", true, 1, false),
        "Reordering requires a file with at least two audio streams.",
        "single audio stream"
    );
}

private void test_problem_requires_changed_order () {
    assert_string_equal (
        AudioTab.resolve_reorder_problem_for_test ("input.mkv", true, 2, false),
        "Rearrange the audio stream order before starting!",
        "unchanged reorder"
    );
}

private void test_problem_is_null_when_ready () {
    assert_string_equal (
        AudioTab.resolve_reorder_problem_for_test ("input.mkv", true, 2, true),
        null,
        "ready to reorder"
    );
}

// ── is_reorder_changed ──────────────────────────────────────────────────────

private void test_natural_order_is_unchanged () {
    var indices = make_indices ({ 0, 1, 2 });
    assert (AudioTab.check_reorder_changed_for_test (indices, 3) == false);
}

private void test_swapped_order_is_changed () {
    var indices = make_indices ({ 1, 0 });
    assert (AudioTab.check_reorder_changed_for_test (indices, 2) == true);
}

private void test_reversed_three_streams_is_changed () {
    var indices = make_indices ({ 2, 1, 0 });
    assert (AudioTab.check_reorder_changed_for_test (indices, 3) == true);
}

private void test_length_mismatch_is_unchanged () {
    var indices = make_indices ({ 0 });
    assert (AudioTab.check_reorder_changed_for_test (indices, 3) == false);
}

private void test_empty_indices_is_unchanged () {
    var indices = new GenericArray<int> ();
    assert (AudioTab.check_reorder_changed_for_test (indices, 0) == false);
    assert (AudioTab.check_reorder_changed_for_test (indices, 2) == false);
}

// ── move ────────────────────────────────────────────────────────────────────

private void test_move_down () {
    var indices = make_indices ({ 0, 1, 2 });
    AudioTab.move_reorder_indices_for_test (indices, 0, 1);
    assert_indices (indices, { 1, 0, 2 }, "move 0→1");
}

private void test_move_up () {
    var indices = make_indices ({ 0, 1, 2 });
    AudioTab.move_reorder_indices_for_test (indices, 2, 1);
    assert_indices (indices, { 0, 2, 1 }, "move 2→1");
}

private void test_move_first_to_last () {
    // Swap: positions 0 and 2 exchange values, position 1 unchanged
    var indices = make_indices ({ 0, 1, 2 });
    AudioTab.move_reorder_indices_for_test (indices, 0, 2);
    assert_indices (indices, { 2, 1, 0 }, "swap 0↔2");
}

private void test_move_last_to_first () {
    // Swap: positions 2 and 0 exchange values, position 1 unchanged
    var indices = make_indices ({ 0, 1, 2 });
    AudioTab.move_reorder_indices_for_test (indices, 2, 0);
    assert_indices (indices, { 2, 1, 0 }, "swap 2↔0");
}

private void test_move_out_of_bounds_low_is_noop () {
    var indices = make_indices ({ 0, 1 });
    AudioTab.move_reorder_indices_for_test (indices, 0, -1);
    assert_indices (indices, { 0, 1 }, "move to -1");
}

private void test_move_out_of_bounds_high_is_noop () {
    var indices = make_indices ({ 0, 1 });
    AudioTab.move_reorder_indices_for_test (indices, 1, 2);
    assert_indices (indices, { 0, 1 }, "move to 2");
}

private void test_move_from_out_of_bounds_is_noop () {
    var indices = make_indices ({ 0, 1 });
    AudioTab.move_reorder_indices_for_test (indices, -1, 0);
    assert_indices (indices, { 0, 1 }, "move from -1");
    AudioTab.move_reorder_indices_for_test (indices, 5, 0);
    assert_indices (indices, { 0, 1 }, "move from 5");
}

// ── reset ───────────────────────────────────────────────────────────────────

private void test_reset_restores_natural_order () {
    var indices = make_indices ({ 2, 0, 1 });
    AudioTab.reset_reorder_indices_for_test (indices, 3);
    assert_indices (indices, { 0, 1, 2 }, "reset 3 streams");
}

private void test_reset_from_empty () {
    var indices = new GenericArray<int> ();
    AudioTab.reset_reorder_indices_for_test (indices, 2);
    assert_indices (indices, { 0, 1 }, "reset from empty");
}

private void test_reset_changes_length () {
    var indices = make_indices ({ 0, 1, 2 });
    AudioTab.reset_reorder_indices_for_test (indices, 5);
    assert_indices (indices, { 0, 1, 2, 3, 4 }, "reset to 5");
}

// ── round-trip: move then check changed ─────────────────────────────────────

private void test_move_then_check_changed () {
    var indices = make_indices ({ 0, 1, 2 });
    assert (AudioTab.check_reorder_changed_for_test (indices, 3) == false);

    AudioTab.move_reorder_indices_for_test (indices, 0, 1);
    assert (AudioTab.check_reorder_changed_for_test (indices, 3) == true);
}

private void test_move_and_move_back_is_unchanged () {
    var indices = make_indices ({ 0, 1, 2 });
    AudioTab.move_reorder_indices_for_test (indices, 0, 1);
    AudioTab.move_reorder_indices_for_test (indices, 1, 0);
    assert (AudioTab.check_reorder_changed_for_test (indices, 3) == false);
}

private void test_reset_after_reorder_is_unchanged () {
    var indices = make_indices ({ 2, 0, 1 });
    assert (AudioTab.check_reorder_changed_for_test (indices, 3) == true);
    AudioTab.reset_reorder_indices_for_test (indices, 3);
    assert (AudioTab.check_reorder_changed_for_test (indices, 3) == false);
}

// ═══════════════════════════════════════════════════════════════════════════════

void main (string[] args) {
    Test.init (ref args);

    // validation
    Test.add_func ("/audio-reorder/problem/requires-input-file",
        test_problem_requires_input_file);
    Test.add_func ("/audio-reorder/problem/requires-audio-streams",
        test_problem_requires_audio_streams);
    Test.add_func ("/audio-reorder/problem/requires-multiple-audio-streams",
        test_problem_requires_multiple_audio_streams);
    Test.add_func ("/audio-reorder/problem/requires-changed-order",
        test_problem_requires_changed_order);
    Test.add_func ("/audio-reorder/problem/is-null-when-ready",
        test_problem_is_null_when_ready);

    // is_reorder_changed
    Test.add_func ("/audio-reorder/state/natural-order-is-unchanged",
        test_natural_order_is_unchanged);
    Test.add_func ("/audio-reorder/state/swapped-order-is-changed",
        test_swapped_order_is_changed);
    Test.add_func ("/audio-reorder/state/reversed-three-streams-is-changed",
        test_reversed_three_streams_is_changed);
    Test.add_func ("/audio-reorder/state/length-mismatch-is-unchanged",
        test_length_mismatch_is_unchanged);
    Test.add_func ("/audio-reorder/state/empty-indices-is-unchanged",
        test_empty_indices_is_unchanged);

    // move
    Test.add_func ("/audio-reorder/state/move-down",
        test_move_down);
    Test.add_func ("/audio-reorder/state/move-up",
        test_move_up);
    Test.add_func ("/audio-reorder/state/move-first-to-last",
        test_move_first_to_last);
    Test.add_func ("/audio-reorder/state/move-last-to-first",
        test_move_last_to_first);
    Test.add_func ("/audio-reorder/state/move-out-of-bounds-low-is-noop",
        test_move_out_of_bounds_low_is_noop);
    Test.add_func ("/audio-reorder/state/move-out-of-bounds-high-is-noop",
        test_move_out_of_bounds_high_is_noop);
    Test.add_func ("/audio-reorder/state/move-from-out-of-bounds-is-noop",
        test_move_from_out_of_bounds_is_noop);

    // reset
    Test.add_func ("/audio-reorder/state/reset-restores-natural-order",
        test_reset_restores_natural_order);
    Test.add_func ("/audio-reorder/state/reset-from-empty",
        test_reset_from_empty);
    Test.add_func ("/audio-reorder/state/reset-changes-length",
        test_reset_changes_length);

    // round-trip
    Test.add_func ("/audio-reorder/state/move-then-check-changed",
        test_move_then_check_changed);
    Test.add_func ("/audio-reorder/state/move-and-move-back-is-unchanged",
        test_move_and_move_back_is_unchanged);
    Test.add_func ("/audio-reorder/state/reset-after-reorder-is-unchanged",
        test_reset_after_reorder_is_unchanged);

    Test.run ();
}
