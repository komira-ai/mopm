//! cargo_to_buck: writes third_party/rust/crates.bzl from what Cargo already knows.
//!
//!   cargo_to_buck --metadata M.json --lock Cargo.lock --tree T.txt \
//!                 --sizes S.txt --overrides O.json --out BUCK [--check COMMITTED]
//!
//!   M.json  cargo metadata --format-version 1 --filter-platform x86_64-unknown-linux-gnu --locked
//!   T.txt   cargo tree --workspace -e normal --target x86_64-unknown-linux-gnu --prefix none -f '{p}|{f}'
//!           (the crates linked into a binary, with the features Cargo resolved for each)
//!   Cargo.lock       the sha256 of every `.crate`
//!   S.txt   one line per crate: `<name>-<version>.crate <bytes>` (ls -l of Cargo's registry cache)
//!   O.json  what no tool can know: the outcome of a crate's build script for the
//!           pinned rustc, as {"<name> <version>": {class, why, cfgs, patch, native_deps}}
//!
//! Writes the BUCK file to --out; with --check, fails unless the committed file is byte for byte that. Nothing here is a guess: a crate with a build
//! script and no entry in O.json is an error.

const std = @import("std");
const Value = std.json.Value;

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cargo_to_buck: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

const Pkg = struct {
    name: []const u8,
    version: []const u8,
    id: []const u8,
    edition: []const u8,
    root: []const u8 = "src/lib.rs",
    lib_name: []const u8 = "",
    proc_macro: bool = false,
    has_build: bool = false,
    features: std.ArrayList([]const u8),
    sha: []const u8 = "",
    size: u64 = 0,
    target: []const u8 = "",
    dup: bool = false,
};

fn str(v: Value) []const u8 {
    return switch (v) {
        .string => |s| s,
        else => die("expected a string", .{}),
    };
}

fn key(a: std.mem.Allocator, name: []const u8, version: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s} {s}", .{ name, version });
}

fn lessPkg(_: void, x: *Pkg, y: *Pkg) bool {
    const o = std.mem.order(u8, x.name, y.name);
    if (o != .eq) return o == .lt;
    return std.mem.order(u8, x.version, y.version) == .lt;
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn q(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn strList(w: anytype, indent: []const u8, name: []const u8, items: []const []const u8) !void {
    if (items.len == 0) return;
    try w.print("{s}{s} = [", .{ indent, name });
    if (items.len <= 3) {
        for (items, 0..) |s, i| {
            if (i > 0) try w.writeAll(", ");
            try q(w, s);
        }
        try w.writeAll("],\n");
    } else {
        try w.writeAll("\n");
        for (items) |s| {
            try w.print("{s}    ", .{indent});
            try q(w, s);
            try w.writeAll(",\n");
        }
        try w.print("{s}],\n", .{indent});
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    var meta_path: []const u8 = "";
    var lock_path: []const u8 = "";
    var tree_path: []const u8 = "";
    var sizes_path: []const u8 = "";
    var out_path: []const u8 = "";
    var check_path: []const u8 = "";
    var ov_path: []const u8 = "";
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const f = args[i];
        const v = args[i + 1];
        if (std.mem.eql(u8, f, "--metadata")) meta_path = v else if (std.mem.eql(u8, f, "--lock")) lock_path = v else if (std.mem.eql(u8, f, "--tree")) tree_path = v else if (std.mem.eql(u8, f, "--sizes")) sizes_path = v else if (std.mem.eql(u8, f, "--out")) out_path = v else if (std.mem.eql(u8, f, "--check")) check_path = v else if (std.mem.eql(u8, f, "--overrides")) ov_path = v else die("unknown flag {s}", .{f});
    }
    if (meta_path.len == 0 or lock_path.len == 0 or tree_path.len == 0 or sizes_path.len == 0 or out_path.len == 0 or ov_path.len == 0) die("usage: see the file header", .{});
    const cwd = std.fs.cwd();

    // The crates linked into a binary, with their resolved features.
    var pkgs = std.StringHashMap(*Pkg).init(a);
    const tree = try cwd.readFileAlloc(a, tree_path, 1 << 24);
    var lines = std.mem.splitScalar(u8, tree, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const bar = std.mem.indexOfScalar(u8, line, '|') orelse die("tree line without |: {s}", .{line});
        var head = std.mem.tokenizeScalar(u8, line[0..bar], ' ');
        const name = head.next().?;
        const ver = std.mem.trimLeft(u8, head.next().?, "v");
        if (std.mem.indexOfScalar(u8, line[0..bar], '(') != null and std.mem.indexOf(u8, line[0..bar], "(/") != null) continue; // workspace member
        const k = try key(a, name, ver);
        const gop = try pkgs.getOrPut(k);
        if (!gop.found_existing) {
            const p = try a.create(Pkg);
            p.* = .{ .name = name, .version = ver, .id = "", .edition = "2021", .features = std.ArrayList([]const u8).init(a) };
            gop.value_ptr.* = p;
        }
        var fs = std.mem.tokenizeScalar(u8, line[bar + 1 ..], ',');
        while (fs.next()) |f| {
            const ft = std.mem.trim(u8, f, " ");
            var have = false;
            for (gop.value_ptr.*.features.items) |x| {
                if (std.mem.eql(u8, x, ft)) have = true;
            }
            if (!have) try gop.value_ptr.*.features.append(try a.dupe(u8, ft));
        }
    }

    // Checksums.
    const lock = try cwd.readFileAlloc(a, lock_path, 1 << 24);
    var ll = std.mem.splitScalar(u8, lock, '\n');
    var cur_name: []const u8 = "";
    var cur_ver: []const u8 = "";
    while (ll.next()) |l| {
        if (std.mem.startsWith(u8, l, "name = ")) cur_name = std.mem.trim(u8, l[7..], "\"");
        if (std.mem.startsWith(u8, l, "version = ")) cur_ver = std.mem.trim(u8, l[10..], "\"");
        if (std.mem.startsWith(u8, l, "checksum = ")) {
            if (pkgs.get(try key(a, cur_name, cur_ver))) |p| p.sha = try a.dupe(u8, std.mem.trim(u8, l[11..], "\""));
        }
    }

    var sizes = std.StringHashMap(u64).init(a);
    var sl = std.mem.splitScalar(u8, try cwd.readFileAlloc(a, sizes_path, 1 << 24), '\n');
    while (sl.next()) |l| {
        var f = std.mem.tokenizeScalar(u8, l, ' ');
        const n = f.next() orelse continue;
        try sizes.put(n, try std.fmt.parseInt(u64, f.next().?, 10));
    }

    // Cargo metadata: the library target, edition, dependency edges.
    const mtext = try cwd.readFileAlloc(a, meta_path, 1 << 28);
    const meta = (try std.json.parseFromSlice(Value, a, mtext, .{})).value;
    var by_id = std.StringHashMap(*Pkg).init(a);
    for (meta.object.get("packages").?.array.items) |pj| {
        const o = pj.object;
        const name = str(o.get("name").?);
        const ver = str(o.get("version").?);
        const p = pkgs.get(try key(a, name, ver)) orelse continue;
        p.id = str(o.get("id").?);
        p.edition = str(o.get("edition").?);
        const manifest_dir = std.fs.path.dirname(str(o.get("manifest_path").?)).?;
        for (o.get("targets").?.array.items) |tj| {
            const kinds = tj.object.get("kind").?.array.items;
            for (kinds) |kj| {
                const kind = str(kj);
                if (std.mem.eql(u8, kind, "custom-build")) p.has_build = true;
                if (std.mem.eql(u8, kind, "lib") or std.mem.eql(u8, kind, "rlib") or std.mem.eql(u8, kind, "proc-macro")) {
                    p.lib_name = try a.dupe(u8, str(tj.object.get("name").?));
                    p.proc_macro = std.mem.eql(u8, kind, "proc-macro");
                    const sp = str(tj.object.get("src_path").?);
                    p.root = try a.dupe(u8, sp[manifest_dir.len + 1 ..]);
                }
            }
        }
        try by_id.put(p.id, p);
        const crate_file = try std.fmt.allocPrint(a, "{s}-{s}.crate", .{ name, ver });
        p.size = sizes.get(crate_file) orelse die("no size for {s} in the sizes file", .{crate_file});
    }

    var list = std.ArrayList(*Pkg).init(a);
    var it = pkgs.valueIterator();
    while (it.next()) |p| {
        if (p.*.id.len == 0) die("{s} {s} is in the tree but not in the metadata", .{ p.*.name, p.*.version });
        if (p.*.sha.len == 0) die("{s} {s} has no checksum in Cargo.lock", .{ p.*.name, p.*.version });
        try list.append(p.*);
    }
    std.mem.sort(*Pkg, list.items, {}, lessPkg);
    // Target names: the crate name, with the version when two versions are linked.
    for (list.items) |p| {
        for (list.items) |o| {
            if (o != p and std.mem.eql(u8, o.name, p.name)) p.dup = true;
        }
        p.target = if (p.dup) try std.fmt.allocPrint(a, "{s}-{s}", .{ p.name, p.version }) else p.name;
    }

    const ov = (try std.json.parseFromSlice(Value, a, try cwd.readFileAlloc(a, ov_path, 1 << 24), .{})).value;

    var out = std.ArrayList(u8).init(a);
    const w = out.writer();
    try w.writeAll("# Generated by third_party/rust/gen (cargo_to_buck.zig) from cargo metadata, Cargo.lock and\n# overrides.json. Do not edit by hand: change overrides.json or the Cargo manifests and regenerate.\n\n");
    try w.writeAll("load(\"//tools/cargo:cargo.bzl\", \"cargo_crate\")\n\ndef crates():\n");
    const body_start = out.items.len;

    for (list.items) |p| {
        const k = try key(a, p.name, p.version);
        const o = ov.object.get(k);
        if (p.has_build and o == null) die("{s} has a build script and no entry in overrides.json", .{k});
        if (o) |ob| {
            try w.print("# build script ({s}): ", .{if (ob.object.get("class")) |c| str(c) else "?"});
            try w.print("{s}\n", .{if (ob.object.get("why")) |c| str(c) else ""});
        }
        try w.writeAll("cargo_crate(\n");
        try w.print("    name = \"{s}\",\n    version = \"{s}\",\n    sha256 = \"{s}\",\n    size = {d},\n", .{ p.target, p.version, p.sha, p.size });
        if (!std.mem.eql(u8, p.target, p.name)) try w.print("    crate = \"{s}\",\n", .{p.name});
        const def_name = try a.dupe(u8, p.name);
        std.mem.replaceScalar(u8, def_name, '-', '_');
        if (!std.mem.eql(u8, def_name, p.lib_name)) try w.print("    crate_name = \"{s}\",\n", .{p.lib_name});
        if (!std.mem.eql(u8, p.root, "src/lib.rs")) try w.print("    crate_root = \"{s}\",\n", .{p.root});
        if (!std.mem.eql(u8, p.edition, "2021")) try w.print("    edition = \"{s}\",\n", .{p.edition});
        std.mem.sort([]const u8, p.features.items, {}, lessStr);
        try strList(w, "    ", "features", p.features.items);
        if (o) |ob| {
            if (ob.object.get("cfgs")) |c| {
                var cs = std.ArrayList([]const u8).init(a);
                for (c.array.items) |x| try cs.append(str(x));
                try strList(w, "    ", "cfgs", cs.items);
            }
        }
        if (p.proc_macro) try w.writeAll("    proc_macro = True,\n");

        // Dependencies: normal edges whose target is linked.
        var deps = std.ArrayList([]const u8).init(a);
        var renamed = std.ArrayList([]const u8).init(a);
        for (meta.object.get("resolve").?.object.get("nodes").?.array.items) |nj| {
            if (!std.mem.eql(u8, str(nj.object.get("id").?), p.id)) continue;
            for (nj.object.get("deps").?.array.items) |dj| {
                var normal = false;
                for (dj.object.get("dep_kinds").?.array.items) |kj| {
                    if (kj.object.get("kind").? == .null) normal = true;
                }
                if (!normal) continue;
                const d = by_id.get(str(dj.object.get("pkg").?)) orelse continue;
                const alias = str(dj.object.get("name").?);
                const label = try std.fmt.allocPrint(a, ":{s}", .{d.target});
                if (std.mem.eql(u8, alias, d.lib_name)) {
                    try deps.append(label);
                } else {
                    try renamed.append(try std.fmt.allocPrint(a, "{s}={s}", .{ alias, label }));
                }
            }
        }
        std.mem.sort([]const u8, deps.items, {}, lessStr);
        std.mem.sort([]const u8, renamed.items, {}, lessStr);
        // Duplicate edges (one per dependency kind) collapse.
        var uniq = std.ArrayList([]const u8).init(a);
        for (deps.items) |d| {
            if (uniq.items.len == 0 or !std.mem.eql(u8, uniq.items[uniq.items.len - 1], d)) try uniq.append(d);
        }
        try strList(w, "    ", "deps", uniq.items);
        if (renamed.items.len > 0) {
            try w.writeAll("    renamed_deps = {\n");
            var last: []const u8 = "";
            for (renamed.items) |r| {
                if (std.mem.eql(u8, r, last)) continue;
                last = r;
                const eq = std.mem.indexOfScalar(u8, r, '=').?;
                try w.writeAll("        ");
                try q(w, r[0..eq]);
                try w.writeAll(": ");
                try q(w, r[eq + 1 ..]);
                try w.writeAll(",\n");
            }
            try w.writeAll("    },\n");
        }
        if (o) |ob| {
            if (ob.object.get("patch")) |pt| {
                try w.writeAll("    patch = {\n");
                if (pt.object.get("copy")) |c| {
                    var cs = std.ArrayList([]const u8).init(a);
                    for (c.array.items) |x| try cs.append(str(x));
                    try w.writeAll("        \"copy\": [");
                    for (cs.items) |x| {
                        try q(w, x);
                        try w.writeAll(", ");
                    }
                    try w.writeAll("],\n");
                }
                if (pt.object.get("sub")) |subs| {
                    try w.writeAll("        \"sub\": [\n");
                    for (subs.array.items) |s| {
                        try w.writeAll("            {\"file\": ");
                        try q(w, str(s.object.get("file").?));
                        try w.writeAll(", \"from\": ");
                        try q(w, str(s.object.get("from").?));
                        try w.writeAll(", \"to\": ");
                        try q(w, str(s.object.get("to").?));
                        if (s.object.get("count")) |c| try w.print(", \"count\": {d}", .{c.integer});
                        try w.writeAll("},\n");
                    }
                    try w.writeAll("        ],\n");
                }
                if (pt.object.get("add")) |adds| {
                    try w.writeAll("        \"add\": [\n");
                    for (adds.array.items) |s| {
                        const content = try std.mem.replaceOwned(u8, a, str(s.object.get("content").?), "$VERSION_PATCH", blk: {
                            var vp = std.mem.splitScalar(u8, p.version, '.');
                            _ = vp.next();
                            _ = vp.next();
                            break :blk vp.next().?;
                        });
                        try w.writeAll("            {\"file\": ");
                        try q(w, str(s.object.get("file").?));
                        try w.writeAll(", \"content\": ");
                        try q(w, content);
                        try w.writeAll("},\n");
                    }
                    try w.writeAll("        ],\n");
                }
                try w.writeAll("    },\n");
            }
        }
        try w.writeAll(")\n\n");
    }
    // The crates are the body of one macro: indent them.
    {
        const body = try a.dupe(u8, out.items[body_start..]);
        out.shrinkRetainingCapacity(body_start);
        var bl = std.mem.splitScalar(u8, body, '\n');
        while (bl.next()) |l| {
            if (l.len > 0) try out.appendSlice("    ");
            try out.appendSlice(l);
            try out.append('\n');
        }
        while (out.items.len > 1 and out.items[out.items.len - 1] == '\n' and out.items[out.items.len - 2] == '\n') _ = out.pop();
    }
    if (check_path.len > 0) {
        const have = try cwd.readFileAlloc(a, check_path, 1 << 28);
        if (!std.mem.eql(u8, have, out.items)) die("{s} is not what the inputs generate; regenerate it (build :gen and copy its output)", .{check_path});
    }
    try cwd.writeFile(out_path, out.items);
}
