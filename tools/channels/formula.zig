//! The Homebrew formula, rendered from the release's SHA256SUMS.
//!
//! The checksums in the formula come from that one file and nowhere else: nothing is downloaded and nothing is
//! hashed here, so a formula can only say what the verified SHA256SUMS says. The formula is a binary formula (no
//! build, no bottles): four `url`/`sha256` pairs under `on_macos`/`on_linux` and `on_arm`/`on_intel`, `bin.install`
//! of the program, and a `test do` that requires `<name> --version` to print `<name> <version>`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const version_mod = @import("version.zig");

pub const Info = struct {
    /// The program and the formula: `mopm`. Lower case letters, digits and `-`.
    name: []const u8,
    /// `X.Y.Z`.
    version: []const u8,
    desc: []const u8,
    homepage: []const u8,
    license: []const u8,
    /// `owner/name` of the GitHub repository the release is in; the URL base is derived from it.
    repo: []const u8 = "",
    /// Where the four tarballs are, instead of the release of `repo` (a `file://` directory for the install gate).
    url_base: ?[]const u8 = null,
    /// Write `version "X.Y.Z"` (the default). Brew can usually read it from the URL.
    explicit_version: bool = true,
};

pub const Error = error{
    BadInfo,
    BadSumsLine,
    BadHash,
    DuplicateName,
    MissingTarball,
    UnexpectedTarball,
};

const Target = struct { suffix: []const u8, os: []const u8, cpu: []const u8 };

/// In the order the formula lists them.
const targets = [_]Target{
    .{ .suffix = "macos-arm64", .os = "macos", .cpu = "arm" },
    .{ .suffix = "macos-x86_64", .os = "macos", .cpu = "intel" },
    .{ .suffix = "linux-aarch64", .os = "linux", .cpu = "arm" },
    .{ .suffix = "linux-x86_64", .os = "linux", .cpu = "intel" },
};

pub const Sum = struct { hash: []const u8, name: []const u8 };

/// The lines of a SHA256SUMS file: `<64 lower-case hex>  <file name>`. A file name has no `/`.
pub fn parseSums(a: Allocator, text: []const u8) ![]Sum {
    var out = std.ArrayList(Sum).init(a);
    errdefer out.deinit();
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (line.len < 67 or line[64] != ' ' or line[65] != ' ') return error.BadSumsLine;
        const hash = line[0..64];
        for (hash) |ch| {
            if (!((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'))) return error.BadHash;
        }
        const name = line[66..];
        if (std.mem.indexOfAny(u8, name, "/ \t\r*") != null) return error.BadSumsLine;
        for (out.items) |s| {
            if (std.mem.eql(u8, s.name, name)) return error.DuplicateName;
        }
        try out.append(.{ .hash = hash, .name = name });
    }
    return out.toOwnedSlice();
}

fn plainText(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| {
        if (ch < 0x20 or ch == 0x7f or ch == '"' or ch == '\\' or ch == '#') return false;
    }
    return true;
}

fn validName(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isLower(s[0])) return false;
    for (s) |ch| {
        if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '-') return false;
    }
    return s[s.len - 1] != '-';
}

fn validRepo(s: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse return false;
    if (slash == 0 or slash == s.len - 1 or std.mem.indexOfScalarPos(u8, s, slash + 1, '/') != null) return false;
    for (s) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.' and ch != '/') return false;
    }
    return true;
}

/// `mopm` is `Mopm`, `my-tool` is `MyTool`: the class name Homebrew expects for a formula file.
fn className(a: Allocator, name: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    var up = true;
    for (name) |ch| {
        if (ch == '-') {
            up = true;
            continue;
        }
        try out.append(if (up) std.ascii.toUpper(ch) else ch);
        up = false;
    }
    return out.toOwnedSlice();
}

/// The text of `Formula/<name>.rb`.
pub fn render(a: Allocator, info: Info, sums_text: []const u8) ![]u8 {
    if (!validName(info.name)) return error.BadInfo;
    _ = version_mod.Version.parse(info.version) catch return error.BadInfo;
    if (!plainText(info.desc) or !plainText(info.homepage) or !plainText(info.license)) return error.BadInfo;
    const base: []const u8 = if (info.url_base) |b| blk: {
        if (!plainText(b) or std.mem.indexOfAny(u8, b, " \t") != null) return error.BadInfo;
        break :blk std.mem.trimRight(u8, b, "/");
    } else blk: {
        if (!validRepo(info.repo)) return error.BadInfo;
        break :blk try std.fmt.allocPrint(a, "https://github.com/{s}/releases/download/v{s}", .{ info.repo, info.version });
    };

    const sums = try parseSums(a, sums_text);
    // Every tarball of this name in the file must be one of the four of this version: a stray older one is a mistake.
    const prefix = try std.fmt.allocPrint(a, "{s}-", .{info.name});
    for (sums) |s| {
        if (!std.mem.startsWith(u8, s.name, prefix) or !std.mem.endsWith(u8, s.name, ".tar.gz")) continue;
        var expected = false;
        for (targets) |tg| {
            const want = try std.fmt.allocPrint(a, "{s}-{s}-{s}.tar.gz", .{ info.name, info.version, tg.suffix });
            if (std.mem.eql(u8, want, s.name)) expected = true;
        }
        if (!expected) return error.UnexpectedTarball;
    }

    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    const w = out.writer();
    try w.print("class {s} < Formula\n", .{try className(a, info.name)});
    try w.print("  desc \"{s}\"\n  homepage \"{s}\"\n", .{ info.desc, info.homepage });
    if (info.explicit_version) try w.print("  version \"{s}\"\n", .{info.version});
    try w.print("  license \"{s}\"\n", .{info.license});
    for ([_][]const u8{ "macos", "linux" }) |os| {
        try w.print("\n  on_{s} do\n", .{os});
        for ([_][]const u8{ "arm", "intel" }) |cpu| {
            for (targets) |tg| {
                if (!std.mem.eql(u8, tg.os, os) or !std.mem.eql(u8, tg.cpu, cpu)) continue;
                const file = try std.fmt.allocPrint(a, "{s}-{s}-{s}.tar.gz", .{ info.name, info.version, tg.suffix });
                var hash: ?[]const u8 = null;
                for (sums) |s| {
                    if (std.mem.eql(u8, s.name, file)) hash = s.hash;
                }
                try w.print("    on_{s} do\n      url \"{s}/{s}\"\n      sha256 \"{s}\"\n    end\n", .{ cpu, base, file, hash orelse return error.MissingTarball });
            }
        }
        try w.writeAll("  end\n");
    }
    try w.print("\n  def install\n    bin.install \"{s}\"\n  end\n", .{info.name});
    try w.print("\n  test do\n    assert_match \"{s} #{{version}}\", shell_output(\"#{{bin}}/{s} --version\")\n  end\n", .{ info.name, info.name });
    try w.writeAll("end\n");
    return out.toOwnedSlice();
}

// ---- tests -------------------------------------------------------------------------------

const t = std.testing;

const h_macos_arm = "1111111111111111111111111111111111111111111111111111111111111111";
const h_macos_x86 = "2222222222222222222222222222222222222222222222222222222222222222";
const h_linux_arm = "3333333333333333333333333333333333333333333333333333333333333333";
const h_linux_x86 = "4444444444444444444444444444444444444444444444444444444444444444";
const h_deb = "5555555555555555555555555555555555555555555555555555555555555555";
const h_bad = "ZZ" ++ "1" ** 62;

const sums_ok =
    h_linux_x86 ++ "  mopm-1.2.3-linux-x86_64.tar.gz\n" ++
    h_linux_arm ++ "  mopm-1.2.3-linux-aarch64.tar.gz\n" ++
    h_macos_arm ++ "  mopm-1.2.3-macos-arm64.tar.gz\n" ++
    h_macos_x86 ++ "  mopm-1.2.3-macos-x86_64.tar.gz\n" ++
    h_deb ++ "  mopm_1.2.3_amd64.deb\n";

fn sampleInfo() Info {
    return .{ .name = "mopm", .version = "1.2.3", .desc = "Package manager for Mojo", .homepage = "https://mopm.dev", .license = "Apache-2.0", .repo = "komira-ai/mopm" };
}

test "each platform block carries its own tarball's URL and the hash listed for it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try render(a, sampleInfo(), sums_ok);
    const split = std.mem.indexOf(u8, text, "  on_linux do\n") orelse return error.TestNoLinuxBlock;
    const macos_half = text[0..split];
    const linux_half = text[split..];
    const cases = [_]struct { half: []const u8, cpu: []const u8, file: []const u8, hash: []const u8 }{
        .{ .half = macos_half, .cpu = "arm", .file = "mopm-1.2.3-macos-arm64.tar.gz", .hash = h_macos_arm },
        .{ .half = macos_half, .cpu = "intel", .file = "mopm-1.2.3-macos-x86_64.tar.gz", .hash = h_macos_x86 },
        .{ .half = linux_half, .cpu = "arm", .file = "mopm-1.2.3-linux-aarch64.tar.gz", .hash = h_linux_arm },
        .{ .half = linux_half, .cpu = "intel", .file = "mopm-1.2.3-linux-x86_64.tar.gz", .hash = h_linux_x86 },
    };
    for (cases) |c| {
        const want = try std.fmt.allocPrint(a, "    on_{s} do\n      url \"https://github.com/komira-ai/mopm/releases/download/v1.2.3/{s}\"\n      sha256 \"{s}\"\n    end\n", .{ c.cpu, c.file, c.hash });
        try t.expect(std.mem.indexOf(u8, c.half, want) != null);
    }
    try t.expect(std.mem.indexOf(u8, text, h_deb) == null); // the deb is not in the formula
    try t.expect(std.mem.startsWith(u8, text, "class Mopm < Formula\n"));
    try t.expect(std.mem.indexOf(u8, text, "  version \"1.2.3\"\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "bin.install \"mopm\"") != null);
    try t.expect(std.mem.indexOf(u8, text, "assert_match \"mopm #{version}\", shell_output(\"#{bin}/mopm --version\")") != null);
    try t.expect(std.mem.endsWith(u8, text, "end\n"));
}

test "the same inputs give the same formula; the version line can be left out; a file:// base replaces the release URL" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try render(a, sampleInfo(), sums_ok);
    try t.expectEqualStrings(one, try render(a, sampleInfo(), sums_ok));
    var no_version = sampleInfo();
    no_version.explicit_version = false;
    try t.expect(std.mem.indexOf(u8, try render(a, no_version, sums_ok), "  version ") == null);
    var local = sampleInfo();
    local.url_base = "file:///work/dist/";
    local.repo = "";
    const text = try render(a, local, sums_ok);
    try t.expect(std.mem.indexOf(u8, text, "url \"file:///work/dist/mopm-1.2.3-linux-x86_64.tar.gz\"") != null);
    try t.expect(std.mem.indexOf(u8, text, "github.com") == null);
}

test "a missing tarball, a stray one of another version, a bad line or hash are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const no_macos_x86 = h_linux_x86 ++ "  mopm-1.2.3-linux-x86_64.tar.gz\n" ++ h_linux_arm ++ "  mopm-1.2.3-linux-aarch64.tar.gz\n" ++ h_macos_arm ++ "  mopm-1.2.3-macos-arm64.tar.gz\n";
    try t.expectError(error.MissingTarball, render(a, sampleInfo(), no_macos_x86));
    try t.expectError(error.UnexpectedTarball, render(a, sampleInfo(), sums_ok ++ h_deb ++ "  mopm-1.2.2-macos-arm64.tar.gz\n"));
    try t.expectError(error.BadHash, render(a, sampleInfo(), h_bad ++ "  mopm-1.2.3-macos-arm64.tar.gz\n"));
    try t.expectError(error.BadSumsLine, render(a, sampleInfo(), h_deb ++ " mopm-1.2.3-macos-arm64.tar.gz\n"));
    try t.expectError(error.BadSumsLine, render(a, sampleInfo(), h_deb ++ "  dir/mopm-1.2.3-macos-arm64.tar.gz\n"));
    try t.expectError(error.DuplicateName, render(a, sampleInfo(), sums_ok ++ h_deb ++ "  mopm-1.2.3-macos-arm64.tar.gz\n"));
    // Upper-case hex is not what sha256sum writes.
    try t.expectError(error.BadHash, parseSums(a, "A" ** 64 ++ "  x\n"));
}

test "the info is checked: names, version, text that would break out of the Ruby string, the repo" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var i = sampleInfo();
    i.name = "Mopm";
    try t.expectError(error.BadInfo, render(a, i, sums_ok));
    i = sampleInfo();
    i.version = "1.2";
    try t.expectError(error.BadInfo, render(a, i, sums_ok));
    i = sampleInfo();
    i.desc = "evil\" ; system(\"x\") ; \"";
    try t.expectError(error.BadInfo, render(a, i, sums_ok));
    i = sampleInfo();
    i.desc = "interpolate #{1+1}";
    try t.expectError(error.BadInfo, render(a, i, sums_ok));
    i = sampleInfo();
    i.homepage = "https://x\nend";
    try t.expectError(error.BadInfo, render(a, i, sums_ok));
    i = sampleInfo();
    i.repo = "no-slash";
    try t.expectError(error.BadInfo, render(a, i, sums_ok));
    i = sampleInfo();
    i.repo = "a/b/c";
    try t.expectError(error.BadInfo, render(a, i, sums_ok));
}

test "class names: mopm is Mopm, my-tool is MyTool" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("Mopm", try className(a, "mopm"));
    try t.expectEqualStrings("MyTool", try className(a, "my-tool"));
}
