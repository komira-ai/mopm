//! A reader for the MessagePack shapes of conda sharded repodata (CEP 16): maps, arrays, strings, binary values and
//! unsigned integers, and `skip` for everything else. (Interface only; the reading follows.)

pub const Error = error{ Truncated, BadType, TooDeep, Unsupported };

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
    pub fn peek(self: Reader) Error!Kind {
        _ = self;
        return error.Unsupported;
    }
    pub fn mapLen(self: *Reader) Error!u32 {
        _ = self;
        return error.Unsupported;
    }
    pub fn arrayLen(self: *Reader) Error!u32 {
        _ = self;
        return error.Unsupported;
    }
    pub fn str(self: *Reader) Error![]const u8 {
        _ = self;
        return error.Unsupported;
    }
    pub fn bin(self: *Reader) Error![]const u8 {
        _ = self;
        return error.Unsupported;
    }
    pub fn uint(self: *Reader) Error!u64 {
        _ = self;
        return error.Unsupported;
    }
    pub fn skip(self: *Reader) Error!void {
        _ = self;
        return error.Unsupported;
    }
};
