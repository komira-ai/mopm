//! Prefix rewriting: what conda does to a file whose `paths.json` entry names
//! a `prefix_placeholder`. The placeholder is the path the package was built
//! with; the installed file must name the prefix it is installed into.
//!
//!   text    every occurrence of the placeholder becomes the prefix; a `#!`
//!           line that is then too long for the kernel (127 bytes) becomes
//!           `#!/usr/bin/env <name>`
//!   binary  every NUL-terminated string that holds the placeholder has it
//!           replaced by the prefix and is padded with NULs to its original
//!           length, so no offset in the file moves. A prefix longer than the
//!           placeholder cannot fit: that is an error, never a truncation.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The kernel's limit on a `#!` line (Linux: 127 bytes after the `#!`).
pub const shebang_max = 127;

/// `hay` with every `old` replaced by `new`.
pub fn replaceAll(a: Allocator, hay: []const u8, old: []const u8, new: []const u8) Allocator.Error![]u8 {
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    if (old.len == 0) {
        try out.appendSlice(hay);
        return out.toOwnedSlice();
    }
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, hay, i, old)) |at| {
        try out.appendSlice(hay[i..at]);
        try out.appendSlice(new);
        i = at + old.len;
    }
    try out.appendSlice(hay[i..]);
    return out.toOwnedSlice();
}

/// Rewrites the placeholder `old` to `new` in the binary `data`, in place;
/// returns how many strings it changed. `error.PrefixTooLong` when a string
/// would grow.
pub fn rewriteBinary(data: []u8, old: []const u8, new: []const u8) error{PrefixTooLong}!usize {
    if (old.len == 0) return 0;
    var changed: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, data, i, old)) |at| {
        // The string runs from the start of the match to the next NUL.
        const end = std.mem.indexOfScalarPos(u8, data, at, 0) orelse {
            // Not NUL-terminated: conda leaves it alone, and so does mopm.
            return changed;
        };
        const segment = data[at..end];
        // Replace every occurrence inside the segment, into a scratch copy.
        var tmp_buf: [8192]u8 = undefined;
        if (segment.len > tmp_buf.len) return error.PrefixTooLong;
        var n: usize = 0;
        var j: usize = 0;
        while (j < segment.len) {
            if (std.mem.startsWith(u8, segment[j..], old)) {
                if (n + new.len > tmp_buf.len) return error.PrefixTooLong;
                @memcpy(tmp_buf[n..][0..new.len], new);
                n += new.len;
                j += old.len;
            } else {
                tmp_buf[n] = segment[j];
                n += 1;
                j += 1;
            }
            if (n > segment.len) return error.PrefixTooLong;
        }
        @memcpy(data[at..][0..n], tmp_buf[0..n]);
        @memset(data[at + n .. end], 0);
        changed += 1;
        i = end;
    }
    return changed;
}

/// `text` with a too-long `#!` line replaced by
/// `#!/usr/bin/env <interpreter name> <arguments>`; unchanged otherwise.
pub fn fixShebang(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (!std.mem.startsWith(u8, text, "#!")) return text;
    const eol = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const line = std.mem.trim(u8, text[2..eol], " \t\r");
    const sp = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
    const exe = line[0..sp];
    const args = std.mem.trim(u8, line[sp..], " \t");
    if (eol - 2 <= shebang_max) return text;
    if (exe.len == 0 or std.mem.eql(u8, std.fs.path.basename(exe), "env")) return text;
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    try out.appendSlice("#!/usr/bin/env ");
    try out.appendSlice(std.fs.path.basename(exe));
    if (args.len > 0) {
        try out.append(' ');
        try out.appendSlice(args);
    }
    try out.appendSlice(text[eol..]);
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------- tests

test "text: every occurrence is replaced" {
    const a = std.testing.allocator;
    const out = try replaceAll(a, "A=/old/ph B=/old/ph/lib\n", "/old/ph", "/new/prefix");
    defer a.free(out);
    try std.testing.expectEqualStrings("A=/new/prefix B=/new/prefix/lib\n", out);
}

test "binary: the string is rewritten and NUL-padded to its length; other bytes stay" {
    const placeholder = "/placeholder_placeholder_placeholder";
    const prefix = "/env";
    var data = "\x7fELF\x00head\x00".* ++ (placeholder ++ "/lib:" ++ placeholder ++ "/x\x00").* ++ "tail\x00".*;
    const before = data.len;
    const n = try rewriteBinary(&data, placeholder, prefix);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(before, data.len);
    const want = "\x7fELF\x00head\x00" ++ "/env/lib:/env/x" ++ "\x00" ** (placeholder.len * 2 + "/lib:/x".len - "/env/lib:/env/x".len + 1) ++ "tail\x00";
    try std.testing.expectEqualSlices(u8, want, &data);
}

test "binary: a prefix longer than the placeholder is refused, and the data is untouched" {
    var data = "/short\x00".*;
    try std.testing.expectError(error.PrefixTooLong, rewriteBinary(&data, "/short", "/a/much/longer/prefix"));
    try std.testing.expectEqualSlices(u8, "/short\x00", &data);
}

test "binary: a placeholder with no NUL after it is left alone" {
    var data = "abc/placeholder".*;
    try std.testing.expectEqual(@as(usize, 0), try rewriteBinary(&data, "/placeholder", "/p"));
    try std.testing.expectEqualSlices(u8, "abc/placeholder", &data);
}

test "shebang: short ones stay; a long one becomes env" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("#!/env/bin/python\nprint(1)\n", try fixShebang(a, "#!/env/bin/python\nprint(1)\n"));
    const long = "#!/" ++ "d" ** 140 ++ "/bin/python -u\nprint(1)\n";
    try std.testing.expectEqualStrings("#!/usr/bin/env python -u\nprint(1)\n", try fixShebang(a, long));
    try std.testing.expectEqualStrings("no shebang\n", try fixShebang(a, "no shebang\n"));
}
