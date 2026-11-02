//! A reader for the MessagePack shapes of conda sharded repodata (CEP 16): maps, arrays, strings, binary values and
//! unsigned integers, and `skip` for everything else a shard may hold. It reads a byte slice and returns slices of it;
//! it allocates nothing.
//!
//! Untrusted input: a length is checked against the bytes that remain before anything is read or looped over (a map of
//! n pairs takes at least 2n bytes, an array of n values at least n), nesting is limited to `max_depth`, and extension
//! types and the reserved marker 0xc1 are refused. A reader that fails keeps `pos` where the failing value began when
//! the value was of the wrong type, so the caller may try another reading of it.

const std = @import("std");

pub const Error = error{
    /// The input ends inside a value, or a length claims more than the input holds.
    Truncated,
    /// The value is not of the kind asked for, or is a negative number where an unsigned one was asked for.
    BadType,
    /// Maps and arrays nest deeper than `max_depth`.
    TooDeep,
    /// An extension type, or the reserved marker 0xc1.
    Unsupported,
};

pub const Kind = enum { nil, boolean, int, float, str, bin, array, map, ext };

pub const max_depth: u8 = 32;

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn atEnd(self: Reader) bool {
        return self.pos == self.buf.len;
    }

    fn take(self: *Reader, n: usize) Error![]const u8 {
        if (n > self.buf.len - self.pos) return error.Truncated;
        const s = self.buf[self.pos..][0..n];
        self.pos += n;
        return s;
    }

    fn byte(self: *Reader) Error!u8 {
        return (try self.take(1))[0];
    }

    fn be(self: *Reader, comptime T: type) Error!T {
        const s = try self.take(@sizeOf(T));
        return std.mem.readInt(T, s[0..@sizeOf(T)], .big);
    }

    /// Puts the marker byte `m` (just read) back: the value is not what was asked for.
    fn wrong(self: *Reader) Error {
        self.pos -= 1;
        return error.BadType;
    }

    /// The kind of the next value, without reading it.
    pub fn peek(self: Reader) Error!Kind {
        if (self.pos >= self.buf.len) return error.Truncated;
        return switch (self.buf[self.pos]) {
            0x00...0x7f, 0xe0...0xff, 0xcc...0xd3 => .int,
            0x80...0x8f, 0xde, 0xdf => .map,
            0x90...0x9f, 0xdc, 0xdd => .array,
            0xa0...0xbf, 0xd9...0xdb => .str,
            0xc0 => .nil,
            0xc2, 0xc3 => .boolean,
            0xc4...0xc6 => .bin,
            0xca, 0xcb => .float,
            0xc7...0xc9, 0xd4...0xd8 => .ext,
            0xc1 => error.Unsupported,
        };
    }

    /// The number of key and value pairs of the map that starts here.
    pub fn mapLen(self: *Reader) Error!u32 {
        const m = try self.byte();
        const n: u32 = switch (m) {
            0x80...0x8f => m & 0x0f,
            0xde => try self.be(u16),
            0xdf => try self.be(u32),
            else => return self.wrong(),
        };
        if (@as(u64, n) * 2 > self.buf.len - self.pos) return error.Truncated;
        return n;
    }

    /// The number of values of the array that starts here.
    pub fn arrayLen(self: *Reader) Error!u32 {
        const m = try self.byte();
        const n: u32 = switch (m) {
            0x90...0x9f => m & 0x0f,
            0xdc => try self.be(u16),
            0xdd => try self.be(u32),
            else => return self.wrong(),
        };
        if (n > self.buf.len - self.pos) return error.Truncated;
        return n;
    }

    /// A string, as a slice of the input (its bytes are not checked to be UTF-8).
    pub fn str(self: *Reader) Error![]const u8 {
        const m = try self.byte();
        const n: usize = switch (m) {
            0xa0...0xbf => m & 0x1f,
            0xd9 => try self.be(u8),
            0xda => try self.be(u16),
            0xdb => try self.be(u32),
            else => return self.wrong(),
        };
        return self.take(n);
    }

    /// A binary value, as a slice of the input.
    pub fn bin(self: *Reader) Error![]const u8 {
        const m = try self.byte();
        const n: usize = switch (m) {
            0xc4 => try self.be(u8),
            0xc5 => try self.be(u16),
            0xc6 => try self.be(u32),
            else => return self.wrong(),
        };
        return self.take(n);
    }

    /// An integer that is not negative, in whichever of the encodings it was written.
    pub fn uint(self: *Reader) Error!u64 {
        const start = self.pos;
        const m = try self.byte();
        switch (m) {
            0x00...0x7f => return m,
            0xcc => return try self.be(u8),
            0xcd => return try self.be(u16),
            0xce => return try self.be(u32),
            0xcf => return try self.be(u64),
            0xd0 => return self.signed(start, try self.be(i8)),
            0xd1 => return self.signed(start, try self.be(i16)),
            0xd2 => return self.signed(start, try self.be(i32)),
            0xd3 => return self.signed(start, try self.be(i64)),
            else => return self.wrong(),
        }
    }

    fn signed(self: *Reader, start: usize, v: anytype) Error!u64 {
        if (v < 0) {
            self.pos = start;
            return error.BadType;
        }
        return @intCast(v);
    }

    /// Steps over one value of any kind, whole.
    pub fn skip(self: *Reader) Error!void {
        try self.skipAt(0);
    }

    fn skipAt(self: *Reader, depth: u8) Error!void {
        if (depth > max_depth) return error.TooDeep;
        switch (try self.peek()) {
            .map => {
                const n = try self.mapLen();
                var i: u64 = 0;
                while (i < @as(u64, n) * 2) : (i += 1) try self.skipAt(depth + 1);
            },
            .array => {
                const n = try self.arrayLen();
                var i: u32 = 0;
                while (i < n) : (i += 1) try self.skipAt(depth + 1);
            },
            .str => _ = try self.str(),
            .bin => _ = try self.bin(),
            .nil, .boolean, .int, .float => _ = try self.take(fixedSize(self.buf[self.pos])),
            .ext => return error.Unsupported,
        }
    }

    /// The bytes of a nil, boolean, integer or float value, marker included.
    fn fixedSize(m: u8) usize {
        return switch (m) {
            0x00...0x7f, 0xe0...0xff, 0xc0, 0xc2, 0xc3 => 1,
            0xcc, 0xd0 => 2,
            0xcd, 0xd1 => 3,
            0xce, 0xd2, 0xca => 5,
            0xcf, 0xd3, 0xcb => 9,
            else => unreachable,
        };
    }
};
