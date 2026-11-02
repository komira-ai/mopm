//! Probe: komira's pinned Mojo 1.0.0, unpacked by the farm, runs from
//! mopm's cell: `mojo --version`, `mojo build` of a hello program (linked by
//! `cc`, which is komira's zig), and the built program runs. Nothing else is
//! on the farm's PATH: no shell, no system C compiler.

const std = @import("std");
const h = @import("harness.zig");
const mojo_env = @import("mojo_env.zig");

test "probe: mojo --version, mojo build, run" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    var rep = h.Report{};
    const m = try mojo_env.Mojo.init(a);
    const pre = try h.join(a, &.{ m.work, "prefix" });
    try m.prefix(pre, true);

    const v = try m.run(pre, &.{"--version"}, null);
    std.debug.print("mojo --version: exit {d}: {s}", .{ v.code, v.text });
    rep.check("mojo --version", !v.signaled and v.code == 0 and h.contains(v.text, "1.0.0"), "no version 1.0.0");

    const src = try h.join(a, &.{ m.work, "hello.mojo" });
    try h.writeFile(src, "def main():\n    print(\"hello from the probe\")\n");
    const exe = try h.join(a, &.{ m.work, "hello" });
    const b = try m.run(pre, &.{ "build", src, "-o", exe }, null);
    std.debug.print("mojo build: exit {d}\n{s}", .{ b.code, b.text });
    rep.check("mojo build", !b.signaled and b.code == 0, "mojo build failed");

    var empty = std.process.EnvMap.init(a);
    const r = try h.run(a, &.{exe}, &empty, .{});
    std.debug.print("hello: exit {d}: {s}", .{ r.code, r.text });
    rep.check("the built program runs in an empty environment", !r.signaled and r.code == 0 and h.contains(r.text, "hello from the probe"), "wrong output");
    try rep.finish();
}
