//! //:install_cosign: `release install-cosign` (tools/release.zig), the step release.yml's attest and verify run
//! in place of sigstore/cosign-installer. The download is replaced by a local file (`--from`) and the pin by a
//! chosen hash (`--sha256`, which the tool accepts only with `--from`), so nothing here reaches the network.
//!
//! What each case proves, and the defect it would catch:
//!   - a file with the expected sha256 is installed as <dir>/cosign, executable, and <dir> is printed (a tool that
//!     verified but did not install, or did not make it executable, or printed nothing for $GITHUB_PATH);
//!   - a file with another sha256 is refused, and neither cosign nor a partial download is left (a check that
//!     warns but installs, or leaves the bad file where the PATH finds it);
//!   - a missing file is refused and nothing is left (a failure to read taken for an empty, matching file);
//!   - a failed install also removes an older cosign in the directory (a stale binary passing for the new one);
//!   - without `--sha256` the pin in the source decides: a fake file is refused (a pin that is never compared);
//!   - `--sha256` without `--from` is refused, so the real download can only be checked against the pin;
//!   - a malformed expected hash (short, upper case) is refused (a compare that can never fail).

const std = @import("std");
const h = @import("harness.zig");

fn hexOf(bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

test "install-cosign: the good sha installs, a wrong sha, a missing file and a missing pin are refused" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try h.watchdog(120);
    const tool = try h.toolPath(a, "MOPM_RELEASE_TOOL");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try h.tmpPath(a, &tmp);
    var env = try h.environ(a);
    var rep = h.Report{};

    const payload = "#!/bin/sh\necho fake cosign\n";
    const fake = try h.join(a, &.{ root, "fake-cosign" });
    try h.writeFile(fake, payload);
    const good = hexOf(payload);
    const bad = hexOf("another file");

    // A good file: installed, executable, the directory printed.
    {
        const dir = try h.join(a, &.{ root, "good" });
        const r = try h.run(a, &.{ tool, "install-cosign", dir, "--from", fake, "--sha256", &good }, &env, .{ .capture = .stdout });
        const installed = try h.join(a, &.{ dir, "cosign" });
        rep.check("good sha: exits 0", r.code == 0 and !r.signaled, r.text);
        rep.check("good sha: prints the directory for $GITHUB_PATH", std.mem.eql(u8, h.chomp(r.text), dir), r.text);
        const body = h.readFile(a, installed) catch "";
        rep.check("good sha: <dir>/cosign holds the file", std.mem.eql(u8, body, payload), body);
        const st = std.fs.cwd().statFile(installed) catch null;
        rep.check("good sha: <dir>/cosign is executable", st != null and (st.?.mode & 0o111) == 0o111, "mode");
        rep.check("good sha: no partial download is left", !exists(try h.join(a, &.{ dir, "cosign.part" })), dir);
    }

    // A wrong sha: refused, nothing left.
    {
        const dir = try h.join(a, &.{ root, "wrong" });
        const r = try h.run(a, &.{ tool, "install-cosign", dir, "--from", fake, "--sha256", &bad }, &env, .{});
        rep.check("wrong sha: exits 1 and says it refuses", r.code == 1 and h.contains(r.text, "refusing to install"), r.text);
        rep.check("wrong sha: names both hashes", h.contains(r.text, &good) and h.contains(r.text, &bad), r.text);
        rep.check("wrong sha: no cosign is left", !exists(try h.join(a, &.{ dir, "cosign" })), dir);
        rep.check("wrong sha: no partial download is left", !exists(try h.join(a, &.{ dir, "cosign.part" })), dir);
    }

    // A missing file: refused, nothing left.
    {
        const dir = try h.join(a, &.{ root, "missing" });
        const none = try h.join(a, &.{ root, "no-such-file" });
        const r = try h.run(a, &.{ tool, "install-cosign", dir, "--from", none, "--sha256", &good }, &env, .{});
        rep.check("missing file: exits 1 and says it cannot open it", r.code == 1 and h.contains(r.text, "cannot open"), r.text);
        rep.check("missing file: no cosign is left", !exists(try h.join(a, &.{ dir, "cosign" })), dir);
        rep.check("missing file: no partial download is left", !exists(try h.join(a, &.{ dir, "cosign.part" })), dir);
    }

    // A failed install removes an older cosign too.
    {
        const dir = try h.join(a, &.{ root, "stale" });
        try h.writeFile(try h.join(a, &.{ dir, "cosign" }), "an older cosign");
        const r = try h.run(a, &.{ tool, "install-cosign", dir, "--from", fake, "--sha256", &bad }, &env, .{});
        rep.check("stale: a wrong sha is refused", r.code == 1, r.text);
        rep.check("stale: the older cosign is removed", !exists(try h.join(a, &.{ dir, "cosign" })), dir);
    }

    // The pin in the source decides when nothing replaces it.
    {
        const dir = try h.join(a, &.{ root, "pinned" });
        const r = try h.run(a, &.{ tool, "install-cosign", dir, "--from", fake }, &env, .{});
        rep.check("the source's pin: a fake file does not match it", r.code == 1 and h.contains(r.text, "refusing to install") and h.contains(r.text, &good), r.text);
        rep.check("the source's pin: no cosign is left", !exists(try h.join(a, &.{ dir, "cosign" })), dir);
    }

    // --sha256 only beside --from.
    {
        const dir = try h.join(a, &.{ root, "nofrom" });
        const r = try h.run(a, &.{ tool, "install-cosign", dir, "--sha256", &good }, &env, .{});
        rep.check("--sha256 without --from: refused before any download", r.code == 1 and h.contains(r.text, "only accepted with --from"), r.text);
        rep.check("--sha256 without --from: nothing is installed", !exists(try h.join(a, &.{ dir, "cosign" })), dir);
    }

    // A malformed expected hash.
    for ([_][]const u8{ "abc", "C956E5DFCAC53D52BCF058360D579472F0C1D2D9B69F55209E256FE7783F4C74" }) |sha| {
        const dir = try h.join(a, &.{ root, "malformed" });
        const r = try h.run(a, &.{ tool, "install-cosign", dir, "--from", fake, "--sha256", sha }, &env, .{});
        rep.check("a malformed expected sha256 is refused", r.code == 1 and h.contains(r.text, "64 lowercase hex digits"), r.text);
    }

    try rep.finish();
}
