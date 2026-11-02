//! Tests of the MessagePack reader (msgpack.zig): each shape sharded repodata uses, in each width it may be written in,
//! and each way untrusted bytes can lie. mopm_core.zig runs them with the rest.

const std = @import("std");
const msgpack = @import("msgpack.zig");

const Reader = msgpack.Reader;

// Defect it catches: a string, map or integer read at the wrong width, so a name or a size of a shard is misread.
test "msgpack: strings, binary values and integers are read in every width they are written in" {
    const doc = [_]u8{
        0xa3, 'a', 'b', 'c', // fixstr
        0xd9, 0x02, 'h', 'i', // str 8
        0xda, 0x00, 0x01, 'x', // str 16
        0xdb, 0x00, 0x00, 0x00, 0x01, 'y', // str 32
        0xc4, 0x02, 1, 2, // bin 8
        0xc5, 0x00, 0x01, 9, // bin 16
        0xc6, 0x00, 0x00, 0x00, 0x00, // bin 32, empty
        0x05, // positive fixint
        0xcc, 0xff, // uint 8
        0xcd, 0x01, 0x00, // uint 16
        0xce, 0x00, 0x01, 0x00, 0x00, // uint 32
        0xcf, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, // uint 64
        0xd0, 0x7f, // int 8, not negative
        0xd3, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, // int 64, not negative
    };
    var r = Reader.init(&doc);
    try std.testing.expectEqualStrings("abc", try r.str());
    try std.testing.expectEqualStrings("hi", try r.str());
    try std.testing.expectEqualStrings("x", try r.str());
    try std.testing.expectEqualStrings("y", try r.str());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, try r.bin());
    try std.testing.expectEqualSlices(u8, &.{9}, try r.bin());
    try std.testing.expectEqual(@as(usize, 0), (try r.bin()).len);
    try std.testing.expectEqual(@as(u64, 5), try r.uint());
    try std.testing.expectEqual(@as(u64, 255), try r.uint());
    try std.testing.expectEqual(@as(u64, 256), try r.uint());
    try std.testing.expectEqual(@as(u64, 65536), try r.uint());
    try std.testing.expectEqual(@as(u64, 1 << 32), try r.uint());
    try std.testing.expectEqual(@as(u64, 127), try r.uint());
    try std.testing.expectEqual(@as(u64, 256), try r.uint());
    try std.testing.expect(r.atEnd());
}

test "msgpack: map and array lengths in every width" {
    const doc = [_]u8{
        0x81, 0xa1, 'k', 0x01, // fixmap of one pair
        0xde, 0x00, 0x01, 0xa1, 'k', 0x02, // map 16
        0xdf, 0x00, 0x00, 0x00, 0x01, 0xa1, 'k', 0x03, // map 32
        0x91, 0x01, // fixarray
        0xdc, 0x00, 0x01, 0x01, // array 16
        0xdd, 0x00, 0x00, 0x00, 0x01, 0x01, // array 32
    };
    var r = Reader.init(&doc);
    for (0..3) |_| {
        try std.testing.expectEqual(@as(u32, 1), try r.mapLen());
        try std.testing.expectEqualStrings("k", try r.str());
        try r.skip();
    }
    for (0..3) |_| {
        try std.testing.expectEqual(@as(u32, 1), try r.arrayLen());
        try r.skip();
    }
    try std.testing.expect(r.atEnd());
}

// Defect it catches: a value of another kind being read as the one asked for (a name taken from a number), or a
// failed read that moves on so that the retry reads the middle of a value.
test "msgpack: a value of another kind is BadType and is not consumed; a negative number is not unsigned" {
    const doc = [_]u8{ 0xa1, 'a', 0x01, 0xff, 0xd0, 0xff, 0xca, 0, 0, 0, 0 };
    var r = Reader.init(&doc);
    try std.testing.expectError(error.BadType, r.uint());
    try std.testing.expectError(error.BadType, r.mapLen());
    try std.testing.expectError(error.BadType, r.arrayLen());
    try std.testing.expectError(error.BadType, r.bin());
    try std.testing.expectEqualStrings("a", try r.str());
    try std.testing.expectError(error.BadType, r.str());
    try std.testing.expectEqual(@as(u64, 1), try r.uint());
    // negative fixint, then a negative int 8: both refuse and stay
    try std.testing.expectError(error.BadType, r.uint());
    try r.skip();
    try std.testing.expectError(error.BadType, r.uint());
    try std.testing.expectEqual(msgpack.Kind.int, try r.peek());
    try r.skip();
    try std.testing.expectEqual(msgpack.Kind.float, try r.peek());
    try r.skip();
    try std.testing.expect(r.atEnd());
}

test "msgpack: skip steps over nested maps, arrays, floats, booleans and nil, and peek names each kind" {
    // {"a": [1, true, nil, 1.5 (float 64), {"b": "c"}], "d": float 32}
    const doc = [_]u8{
        0x82,
        0xa1, 'a', 0x95,
        0x01, 0xc3, 0xc0,
        0xcb, 0x3f, 0xf8, 0, 0, 0, 0, 0, 0,
        0x81, 0xa1, 'b', 0xa1, 'c',
        0xa1, 'd', 0xca, 0x3f, 0xc0, 0, 0,
    };
    var r = Reader.init(&doc);
    try std.testing.expectEqual(msgpack.Kind.map, try r.peek());
    try r.skip();
    try std.testing.expect(r.atEnd());
    try std.testing.expectEqual(msgpack.Kind.nil, try Reader.init(&.{0xc0}).peek());
    try std.testing.expectEqual(msgpack.Kind.boolean, try Reader.init(&.{0xc2}).peek());
    try std.testing.expectEqual(msgpack.Kind.str, try Reader.init(&.{0xd9}).peek());
    try std.testing.expectEqual(msgpack.Kind.bin, try Reader.init(&.{0xc4}).peek());
    try std.testing.expectEqual(msgpack.Kind.array, try Reader.init(&.{0xdd}).peek());
}

// Defect it catches: a cut input read as a short one, or a read past the end of the buffer.
test "msgpack: every cut of a document is Truncated, never a read past the end" {
    // {"packages": {"f": {"name": "n", "size": 70000, "depends": ["a", "b"]}}, "sha": bin 4}
    const doc = [_]u8{
        0x82,
        0xa8, 'p', 'a', 'c', 'k', 'a', 'g', 'e', 's',
        0x81, 0xa1, 'f', 0x83,
        0xa4, 'n', 'a', 'm', 'e', 0xa1, 'n',
        0xa4, 's', 'i', 'z', 'e', 0xce, 0x00, 0x01, 0x11, 0x70,
        0xa7, 'd', 'e', 'p', 'e', 'n', 'd', 's', 0x92, 0xa1, 'a', 0xa1, 'b',
        0xa3, 's', 'h', 'a', 0xc4, 0x04, 1, 2, 3, 4,
    };
    {
        var whole = Reader.init(&doc);
        try whole.skip();
        try std.testing.expect(whole.atEnd());
    }
    for (0..doc.len) |cut| {
        var r = Reader.init(doc[0..cut]);
        try std.testing.expectError(error.Truncated, r.skip());
    }
}

// Defect it catches: a claimed length trusted before the bytes are counted (a 4 GiB array in a 10-byte file).
test "msgpack: a length that claims more than the input holds is refused before anything is read" {
    var r = Reader.init(&.{ 0xdd, 0xff, 0xff, 0xff, 0xff, 0x01 });
    try std.testing.expectError(error.Truncated, r.arrayLen());
    var m = Reader.init(&.{ 0xdf, 0x7f, 0xff, 0xff, 0xff, 0x01, 0x02 });
    try std.testing.expectError(error.Truncated, m.mapLen());
    var s = Reader.init(&.{ 0xdb, 0xff, 0xff, 0xff, 0xff, 'x' });
    try std.testing.expectError(error.Truncated, s.str());
    var skipping = Reader.init(&.{ 0xdd, 0xff, 0xff, 0xff, 0xff, 0x01 });
    try std.testing.expectError(error.Truncated, skipping.skip());
}

// Defect it catches: recursion on hostile nesting (a stack overflow instead of an error).
test "msgpack: nesting past the limit is TooDeep" {
    const a = std.testing.allocator;
    const deep = try a.alloc(u8, msgpack.max_depth + 40);
    defer a.free(deep);
    @memset(deep, 0x91);
    deep[deep.len - 1] = 0x01;
    var r = Reader.init(deep);
    try std.testing.expectError(error.TooDeep, r.skip());
    // The limit itself still reads.
    const ok = try a.alloc(u8, msgpack.max_depth + 1);
    defer a.free(ok);
    @memset(ok, 0x91);
    ok[ok.len - 1] = 0x01;
    var r2 = Reader.init(ok);
    try r2.skip();
}

test "msgpack: extension types and the reserved marker are refused" {
    var fixext = Reader.init(&.{ 0xd4, 0x01, 0x00 });
    try std.testing.expectError(error.Unsupported, fixext.skip());
    var ext8 = Reader.init(&.{ 0xc7, 0x01, 0x01, 0x00 });
    try std.testing.expectError(error.Unsupported, ext8.skip());
    var reserved = Reader.init(&.{0xc1});
    try std.testing.expectError(error.Unsupported, reserved.peek());
    try std.testing.expectError(error.Unsupported, reserved.skip());
}
