// Vendored, unmodified, from komira-ai/buildrules pull request #19 (branch coverage/floors), commit 3277431a50603ec0792531d2683dd64fbdcae40b, file rules/coverage/tools/fixtures/zig_cover/mini.zig.
// A stopgap: delete this copy when the buildrules pin in .buckconfig includes that change (vendor/buildrules_coverage/README.md).
//! The code under test of zig_cover_exe_test.zig: three arms of one function, and a function no test calls.
pub fn classify(n: i32) []const u8 {
    if (n < 0) {
        return "negative";
    }
    if (n == 0) {
        return "zero";
    }
    return "positive";
}

// Nothing refers to this function, so the compiler never analyses it and the executable holds no code for it.
pub fn never_called(n: i32) i32 {
    return n + 1;
}
