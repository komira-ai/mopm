//! A syntax check of the shell scripts in `run:` steps, standing in for the
//! `bash -n` an earlier Ruby lint ran: the build farm's image has no shell, and a
//! build action runs none.
//!
//! This is NOT bash. It is a scanner that finds the mistakes a script gets
//! when someone edits it: an unterminated ' " ` $( ${ or $(( , a missing or
//! stray fi / done / esac / } , then / else / elif / do outside the compound
//! command that owns it, a `;;` outside a case, an empty command before ; & |
//! at the top level, and a ) with no (. What bash accepts and this refuses, or
//! the reverse, is listed in tests/drivers/shell_syntax_test.zig; the
//! gaps are the price of a farm with no bash.
//!
//! An unterminated here-document is not an error (bash warns and goes on), so
//! it is not one here either.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Verdict = union(enum) {
    ok,
    /// What the scanner objected to, with the byte offset.
    bad: []const u8,
};

pub fn check(a: Allocator, script: []const u8) !Verdict {
    var sh = Sh{ .a = a, .s = script, .pending = std.ArrayList(Heredoc).init(a) };
    sh.list(0) catch |err| switch (err) {
        error.Syntax => return .{ .bad = sh.why },
        else => return err,
    };
    return .ok;
}

const Heredoc = struct { delim: []const u8, strip: bool };

const Sh = struct {
    a: Allocator,
    s: []const u8,
    i: usize = 0,
    pending: std.ArrayList(Heredoc),
    why: []const u8 = "",

    const Error = error{ Syntax, OutOfMemory };

    fn fail(self: *Sh, comptime msg: []const u8) Error {
        self.why = std.fmt.allocPrint(self.a, "{s} at byte {d}", .{ msg, self.i }) catch msg;
        return error.Syntax;
    }

    fn at(self: *Sh, off: usize) u8 {
        return if (self.i + off < self.s.len) self.s[self.i + off] else 0;
    }

    /// The commands up to the `)` that closes this level (`close` is `)`), or
    /// the end of the script (`close` is 0).
    fn list(self: *Sh, close: u8) Error!void {
        var kw = std.ArrayList(u8).init(self.a); // open compound commands: i if, l loop, c case, { brace
        var cmd = true; // the next word starts a command
        var redirect = false; // the next word is a redirection's target
        var after_function = false; // the next word is the name in `function name`
        while (true) {
            if (self.i >= self.s.len) {
                if (close != 0) return self.fail("unexpected end of file looking for `)'");
                if (kw.items.len != 0) return self.fail("unexpected end of file: a compound command is not closed");
                return;
            }
            const ch = self.s[self.i];
            const top: u8 = if (kw.items.len == 0) 0 else kw.items[kw.items.len - 1];
            switch (ch) {
                ' ', '\t' => self.i += 1,
                '\n' => {
                    self.i += 1;
                    self.bodies();
                    cmd = true;
                },
                '\\' => {
                    if (self.at(1) == '\n') {
                        self.i += 2;
                    } else {
                        const w = try self.word();
                        _ = w;
                        cmd = false;
                    }
                },
                '#' => {
                    while (self.i < self.s.len and self.s[self.i] != '\n') self.i += 1;
                },
                ';' => {
                    if (self.at(1) == ';') {
                        if (top != 'c' and close == 0) return self.fail("unexpected `;;' outside a case");
                        self.i += 2;
                        if (self.at(0) == '&') self.i += 1;
                    } else {
                        if (cmd and close == 0) return self.fail("unexpected `;': empty command");
                        self.i += 1;
                    }
                    cmd = true;
                },
                '&' => {
                    if (cmd and close == 0) return self.fail("unexpected `&': empty command");
                    self.i += if (self.at(1) == '&') @as(usize, 2) else 1;
                    cmd = true;
                },
                '|' => {
                    if (cmd and close == 0) return self.fail("unexpected `|': empty command");
                    self.i += if (self.at(1) == '|' or self.at(1) == '&') @as(usize, 2) else 1;
                    cmd = true;
                },
                '<', '>' => {
                    if ((ch == '<' or ch == '>') and self.at(1) == '(') {
                        self.i += 2; // process substitution
                        try self.list(')');
                        cmd = false;
                    } else if (ch == '<' and self.at(1) == '<' and self.at(2) != '<') {
                        try self.heredoc();
                        // the delimiter was read with the operator: no redirection target follows
                    } else {
                        if (ch == '<' and self.at(1) == '<') {
                            self.i += 3;
                        } else if ((ch == '>' and (self.at(1) == '>' or self.at(1) == '&' or self.at(1) == '|')) or (ch == '<' and (self.at(1) == '&' or self.at(1) == '>'))) {
                            self.i += 2;
                        } else {
                            self.i += 1;
                        }
                        redirect = true;
                    }
                },
                '(' => {
                    self.i += 1;
                    const inner = self.i;
                    try self.list(')');
                    // `f() {` : an empty pair of parentheses is a function definition, a command follows
                    cmd = std.mem.trim(u8, self.s[inner .. self.i - 1], " \t\n").len == 0;
                },
                ')' => {
                    if (top == 'c') {
                        self.i += 1; // the end of a case pattern
                        cmd = true;
                    } else if (close == ')') {
                        if (kw.items.len != 0) return self.fail("a compound command is not closed before `)'");
                        self.i += 1;
                        return;
                    } else {
                        return self.fail("unexpected `)'");
                    }
                },
                else => {
                    const start = self.i;
                    const plain = try self.word();
                    const w = self.s[start..self.i];
                    if (redirect) {
                        redirect = false;
                        cmd = false;
                        continue;
                    }
                    if (after_function) {
                        after_function = false;
                        cmd = true; // `function name {`: the brace opens a group
                        continue;
                    }
                    if (!plain or !cmd) {
                        cmd = false;
                        continue;
                    }
                    try self.keyword(&kw, &cmd, w);
                    if (std.mem.eql(u8, w, "function")) after_function = true;
                },
            }
        }
    }

    fn keyword(self: *Sh, kw: *std.ArrayList(u8), cmd: *bool, w: []const u8) Error!void {
        const top: u8 = if (kw.items.len == 0) 0 else kw.items[kw.items.len - 1];
        const eql = std.mem.eql;
        if (eql(u8, w, "if")) {
            try kw.append('i');
        } else if (eql(u8, w, "then") or eql(u8, w, "elif") or eql(u8, w, "else")) {
            if (top != 'i') return self.fail("`then', `elif' or `else' outside an if");
        } else if (eql(u8, w, "fi")) {
            if (top != 'i') return self.fail("`fi' without an if");
            _ = kw.pop();
            cmd.* = false;
        } else if (eql(u8, w, "while") or eql(u8, w, "until")) {
            try kw.append('l');
        } else if (eql(u8, w, "for") or eql(u8, w, "select")) {
            try kw.append('l');
            cmd.* = false;
        } else if (eql(u8, w, "do")) {
            if (top != 'l') return self.fail("`do' outside a loop");
        } else if (eql(u8, w, "done")) {
            if (top != 'l') return self.fail("`done' without a loop");
            _ = kw.pop();
            cmd.* = false;
        } else if (eql(u8, w, "case")) {
            try kw.append('c');
            cmd.* = false;
        } else if (eql(u8, w, "esac")) {
            if (top != 'c') return self.fail("`esac' without a case");
            _ = kw.pop();
            cmd.* = false;
        } else if (eql(u8, w, "{")) {
            try kw.append('{');
        } else if (eql(u8, w, "}")) {
            if (top != '{') return self.fail("`}' without a `{'");
            _ = kw.pop();
            cmd.* = false;
        } else if (eql(u8, w, "!") or eql(u8, w, "time")) {
            // still at the start of a command
        } else {
            cmd.* = false;
            return;
        }
        // then, else, elif, do, if, while, until, {: a command follows
        if (eql(u8, w, "then") or eql(u8, w, "elif") or eql(u8, w, "else") or eql(u8, w, "do") or eql(u8, w, "if") or eql(u8, w, "while") or eql(u8, w, "until") or eql(u8, w, "{") or eql(u8, w, "!") or eql(u8, w, "time")) cmd.* = true;
    }

    /// One shell word (quotes and expansions included); true if it was plain
    /// text, so a keyword can be one.
    fn word(self: *Sh) Error!bool {
        var plain = true;
        while (self.i < self.s.len) {
            const ch = self.s[self.i];
            switch (ch) {
                ' ', '\t', '\n', ';', '&', '|', '<', '>', '(', ')' => break,
                '\\' => {
                    plain = false;
                    self.i += if (self.i + 1 < self.s.len) @as(usize, 2) else 1;
                },
                '\'' => {
                    plain = false;
                    self.i += 1;
                    while (self.i < self.s.len and self.s[self.i] != '\'') self.i += 1;
                    if (self.i >= self.s.len) return self.fail("unexpected EOF while looking for matching `''");
                    self.i += 1;
                },
                '"' => {
                    plain = false;
                    try self.dquote();
                },
                '`' => {
                    plain = false;
                    try self.backtick();
                },
                '$' => {
                    plain = false;
                    try self.dollar();
                },
                else => self.i += 1,
            }
        }
        return plain;
    }

    fn dquote(self: *Sh) Error!void {
        self.i += 1;
        while (true) {
            if (self.i >= self.s.len) return self.fail("unexpected EOF while looking for matching `\"'");
            switch (self.s[self.i]) {
                '\\' => self.i += 2,
                '"' => {
                    self.i += 1;
                    return;
                },
                '$' => try self.dollar(),
                '`' => try self.backtick(),
                else => self.i += 1,
            }
        }
    }

    fn backtick(self: *Sh) Error!void {
        self.i += 1;
        while (true) {
            if (self.i >= self.s.len) return self.fail("unexpected EOF while looking for matching ``'");
            switch (self.s[self.i]) {
                '\\' => self.i += 2,
                '`' => {
                    self.i += 1;
                    return;
                },
                else => self.i += 1,
            }
        }
    }

    /// At a `$`: $(...), $((...)), ${...}, $'...', or a plain parameter.
    fn dollar(self: *Sh) Error!void {
        self.i += 1;
        switch (self.at(0)) {
            '(' => {
                if (self.at(1) == '(') {
                    var depth: usize = 0;
                    while (true) {
                        if (self.i >= self.s.len) return self.fail("unexpected EOF while looking for matching `))'");
                        switch (self.s[self.i]) {
                            '(' => depth += 1,
                            ')' => depth -= 1,
                            else => {},
                        }
                        self.i += 1;
                        if (depth == 0) return;
                    }
                }
                self.i += 1;
                try self.list(')');
            },
            '{' => {
                self.i += 1;
                while (true) {
                    if (self.i >= self.s.len) return self.fail("unexpected EOF while looking for matching `}'");
                    switch (self.s[self.i]) {
                        '\\' => self.i += 2,
                        '}' => {
                            self.i += 1;
                            return;
                        },
                        '\'' => {
                            self.i += 1;
                            while (self.i < self.s.len and self.s[self.i] != '\'') self.i += 1;
                            if (self.i >= self.s.len) return self.fail("unexpected EOF while looking for matching `''");
                            self.i += 1;
                        },
                        '"' => try self.dquote(),
                        '$' => try self.dollar(),
                        '`' => try self.backtick(),
                        else => self.i += 1,
                    }
                }
            },
            '\'' => {
                self.i += 1;
                while (true) {
                    if (self.i >= self.s.len) return self.fail("unexpected EOF while looking for matching `''");
                    switch (self.s[self.i]) {
                        '\\' => self.i += 2,
                        '\'' => {
                            self.i += 1;
                            return;
                        },
                        else => self.i += 1,
                    }
                }
            },
            '#', '?', '$', '!', '@', '*', '-', '0'...'9' => self.i += 1,
            else => {},
        }
    }

    /// At `<<` (not `<<<`): read the delimiter and queue the here-document.
    fn heredoc(self: *Sh) Error!void {
        self.i += 2;
        var strip = false;
        if (self.at(0) == '-') {
            strip = true;
            self.i += 1;
        }
        while (self.at(0) == ' ' or self.at(0) == '\t') self.i += 1;
        const start = self.i;
        _ = try self.word();
        const raw = self.s[start..self.i];
        var delim = std.ArrayList(u8).init(self.a);
        for (raw) |ch| if (ch != '\'' and ch != '"' and ch != '\\') try delim.append(ch);
        try self.pending.append(.{ .delim = delim.items, .strip = strip });
    }

    /// After a newline: the bodies of the queued here-documents. One that never
    /// ends takes the rest of the script, as bash reads it (with a warning).
    fn bodies(self: *Sh) void {
        for (self.pending.items) |h| {
            while (self.i < self.s.len) {
                const end = std.mem.indexOfScalarPos(u8, self.s, self.i, '\n') orelse self.s.len;
                var line = self.s[self.i..end];
                self.i = if (end < self.s.len) end + 1 else end;
                if (h.strip) line = std.mem.trimLeft(u8, line, "\t");
                if (std.mem.eql(u8, line, h.delim)) break;
            }
        }
        self.pending.clearRetainingCapacity();
    }
};
