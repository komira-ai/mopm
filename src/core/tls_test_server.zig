//! For tests only: a loopback peer that plays the server side of a TLS 1.3 handshake, one connection at a time, so the
//! TLS connection of http.zig and tls_connect.zig is tested with no network and no system certificate. It speaks just
//! enough TLS 1.3 for Zig 0.12's client: x25519 and TLS_AES_128_GCM_SHA256, an Ed25519 certificate built here, and, when
//! it holds the certificate's key, CertificateVerify, Finished and one encrypted answer to one request.

const std = @import("std");
const tls = std.crypto.tls;
const Ed25519 = std.crypto.sign.Ed25519;

const P = tls.HandshakeCipherT(std.crypto.aead.aes_gcm.Aes128Gcm, std.crypto.hash.sha2.Sha256);

/// The key every test certificate is made with: a fixed seed, so a run is repeatable.
pub fn testKey() !Ed25519.KeyPair {
    return Ed25519.KeyPair.create([_]u8{42} ** Ed25519.KeyPair.seed_length);
}

/// A self-signed Ed25519 certificate (DER) whose subject and issuer are `CN=<name>`, valid from 2026-11-01 to 2049.
pub fn certificate(arena: std.mem.Allocator, key: Ed25519.KeyPair, name: []const u8) ![]u8 {
    const ed25519_algo = [_]u8{ 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70 };
    const rdn = try der(arena, 0x30, &.{try der(arena, 0x31, &.{try der(arena, 0x30, &.{ &[_]u8{ 0x06, 0x03, 0x55, 0x04, 0x03 }, try der(arena, 0x0c, &.{name}) })})});
    const validity = try der(arena, 0x30, &.{ try der(arena, 0x17, &.{"261101000000Z"}), try der(arena, 0x17, &.{"491231235959Z"}) });
    const spki = try der(arena, 0x30, &.{ &ed25519_algo, try der(arena, 0x03, &.{ &[_]u8{0}, &key.public_key.toBytes() }) });
    const tbs = try der(arena, 0x30, &.{ &[_]u8{ 0x02, 0x01, 0x01 }, &ed25519_algo, rdn, validity, rdn, spki });
    const sig = try key.sign(tbs, null);
    return der(arena, 0x30, &.{ tbs, &ed25519_algo, try der(arena, 0x03, &.{ &[_]u8{0}, &sig.toBytes() }) });
}

/// One DER element: `tag`, its length, then `parts` one after the other.
fn der(arena: std.mem.Allocator, tag: u8, parts: []const []const u8) ![]u8 {
    var len: usize = 0;
    for (parts) |p| len += p.len;
    var out = std.ArrayList(u8).init(arena);
    try out.append(tag);
    if (len < 0x80) {
        try out.append(@intCast(len));
    } else if (len < 0x100) {
        try out.appendSlice(&.{ 0x81, @intCast(len) });
    } else {
        try out.appendSlice(&.{ 0x82, @intCast(len >> 8), @intCast(len & 0xff) });
    }
    for (parts) |p| try out.appendSlice(p);
    return out.items;
}

/// Makes `client` trust `cert` (DER), as if it were in the system's bundle.
pub fn trust(client: *std.http.Client, cert: []const u8) !void {
    const start: u32 = @intCast(client.ca_bundle.bytes.items.len);
    try client.ca_bundle.bytes.appendSlice(client.allocator, cert);
    try client.ca_bundle.parseCert(client.allocator, start, std.time.timestamp());
}

pub const Server = struct {
    listener: std.net.Server,
    cert: []const u8,
    /// The certificate's key: with it, the handshake is completed and `answer` is sent to the first request; without
    /// it, the server stops after a CertificateVerify that proves nothing.
    key: ?Ed25519.KeyPair = null,
    answer: []const u8 = "",
    /// The first bytes of the request the client sent, in clear.
    request: [256]u8 = undefined,
    request_len: usize = 0,
    failed: ?anyerror = null,
    thread: ?std.Thread = null,

    /// A server on 127.0.0.1 and a port the system picks, serving one connection on a thread of its own.
    pub fn start(s: *Server, cert: []const u8, key: ?Ed25519.KeyPair, answer: []const u8) !void {
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        s.* = .{ .listener = try addr.listen(.{ .reuse_address = true }), .cert = cert, .key = key, .answer = answer };
        s.thread = try std.Thread.spawn(.{}, run, .{s});
    }

    pub fn port(s: *Server) u16 {
        return s.listener.listen_address.getPort();
    }

    /// Waits for the connection to end, and closes the listener.
    pub fn stop(s: *Server) void {
        if (s.thread) |t| t.join();
        s.listener.deinit();
    }

    fn run(s: *Server) void {
        s.serve() catch |e| {
            s.failed = e;
        };
    }

    fn serve(s: *Server) !void {
        const conn = try s.listener.accept();
        defer conn.stream.close();
        var hello_buf: [4096]u8 = undefined;
        const hello = (try readRecord(conn.stream, &hello_buf)).body;
        const ch = try readClientHello(hello);

        const kp = try std.crypto.dh.X25519.KeyPair.create([_]u8{7} ** 32);
        const shared = try std.crypto.dh.X25519.scalarmult(kp.secret_key, ch.x25519);
        var sh: [128]u8 = undefined;
        var w = std.io.fixedBufferStream(&sh);
        const sw = w.writer();
        try sw.writeAll(&([_]u8{ 0x02, 0, 0, 0, 0x03, 0x03 } ++ [_]u8{0x11} ** 32));
        try sw.writeByte(@intCast(ch.session_id.len));
        try sw.writeAll(ch.session_id);
        // TLS_AES_128_GCM_SHA256, no compression, then supported_versions (TLS 1.3) and key_share (x25519).
        try sw.writeAll(&.{ 0x13, 0x01, 0x00, 0x00, 46, 0x00, 0x2b, 0x00, 0x02, 0x03, 0x04, 0x00, 0x33, 0x00, 36, 0x00, 0x1d, 0x00, 32 });
        try sw.writeAll(&kp.public_key);
        const server_hello = w.getWritten();
        std.mem.writeInt(u24, server_hello[1..4], @intCast(server_hello.len - 4), .big);

        var transcript = P.Hash.init(.{});
        transcript.update(hello);
        transcript.update(server_hello);
        const hello_hash = transcript.peek();
        const zeroes = [1]u8{0} ** P.Hash.digest_length;
        const empty_hash = tls.emptyHash(P.Hash);
        const early_secret = P.Hkdf.extract(&[1]u8{0}, &zeroes);
        const hs_derived = tls.hkdfExpandLabel(P.Hkdf, early_secret, "derived", &empty_hash, P.Hash.digest_length);
        const handshake_secret = P.Hkdf.extract(&hs_derived, &shared);
        const server_secret = tls.hkdfExpandLabel(P.Hkdf, handshake_secret, "s hs traffic", &hello_hash, P.Hash.digest_length);
        const hs = Keys.of(server_secret);

        try conn.stream.writeAll(&([_]u8{ 0x16, 0x03, 0x03 } ++ big16(server_hello.len)));
        try conn.stream.writeAll(server_hello);

        // EncryptedExtensions, empty.
        const ee = [_]u8{ 0x08, 0, 0, 2, 0, 0 };
        transcript.update(&ee);
        try writeSealed(conn.stream, hs, 0, 0x16, &ee);

        // Certificate: no request context, one entry with no extensions.
        var msg: [1024]u8 = undefined;
        const n = s.cert.len;
        const body_len = 1 + 3 + 3 + n + 2;
        msg[0] = 0x0b;
        std.mem.writeInt(u24, msg[1..4], @intCast(body_len), .big);
        msg[4] = 0;
        std.mem.writeInt(u24, msg[5..8], @intCast(3 + n + 2), .big);
        std.mem.writeInt(u24, msg[8..11], @intCast(n), .big);
        @memcpy(msg[11..][0..n], s.cert);
        msg[11 + n] = 0;
        msg[12 + n] = 0;
        transcript.update(msg[0 .. 4 + body_len]);
        try writeSealed(conn.stream, hs, 1, 0x16, msg[0 .. 4 + body_len]);

        const key = s.key orelse {
            // CertificateVerify (ecdsa_secp256r1_sha256) with an empty signature: a client that trusted the chain would
            // refuse it, so a client must stop at the certificate.
            try writeSealed(conn.stream, hs, 2, 0x16, &.{ 0x0f, 0, 0, 4, 0x04, 0x03, 0, 0 });
            // Wait for the client to give up, so it reads everything sent before the connection closes.
            var sink: [64]u8 = undefined;
            _ = conn.stream.read(&sink) catch 0;
            return;
        };

        // CertificateVerify: the certificate's key signs the transcript so far (ed25519).
        const signed = [_]u8{0x20} ** 64 ++ "TLS 1.3, server CertificateVerify\x00".* ++ transcript.peek();
        const sig = (try key.sign(&signed, null)).toBytes();
        const cv = [_]u8{ 0x0f, 0, 0, 4 + 64, 0x08, 0x07, 0, 64 } ++ sig;
        transcript.update(&cv);
        try writeSealed(conn.stream, hs, 2, 0x16, &cv);

        // Finished.
        const finished_key = tls.hkdfExpandLabel(P.Hkdf, server_secret, "finished", "", P.Hmac.key_length);
        const fin = [_]u8{ 0x14, 0, 0, P.Hmac.mac_length } ++ tls.hmac(P.Hmac, &transcript.peek(), finished_key);
        transcript.update(&fin);
        try writeSealed(conn.stream, hs, 3, 0x16, &fin);

        // The application keys.
        const handshake_hash = transcript.finalResult();
        const ap_derived = tls.hkdfExpandLabel(P.Hkdf, handshake_secret, "derived", &empty_hash, P.Hash.digest_length);
        const master_secret = P.Hkdf.extract(&ap_derived, &zeroes);
        const client_ap = Keys.of(tls.hkdfExpandLabel(P.Hkdf, master_secret, "c ap traffic", &handshake_hash, P.Hash.digest_length));
        const server_ap = Keys.of(tls.hkdfExpandLabel(P.Hkdf, master_secret, "s ap traffic", &handshake_hash, P.Hash.digest_length));

        // The client's change_cipher_spec and Finished (not checked: the client's side is not under test), then its
        // first application record, which holds the request.
        var buf: [4096]u8 = undefined;
        var encrypted: usize = 0;
        while (true) {
            const rec = try readRecord(conn.stream, &buf);
            if (rec.type != 0x17) continue;
            encrypted += 1;
            if (encrypted < 2) continue;
            const clear = try open(client_ap, 0, rec.header, rec.body);
            s.request_len = @min(clear.len - 1, s.request.len);
            @memcpy(s.request[0..s.request_len], clear[0..s.request_len]);
            break;
        }
        try writeSealed(conn.stream, server_ap, 0, 0x17, s.answer);
        var sink: [256]u8 = undefined;
        while ((conn.stream.read(&sink) catch 0) > 0) {}
    }

    const Keys = struct {
        key: [P.AEAD.key_length]u8,
        iv: [P.AEAD.nonce_length]u8,

        fn of(secret: [P.Hash.digest_length]u8) Keys {
            return .{
                .key = tls.hkdfExpandLabel(P.Hkdf, secret, "key", "", P.AEAD.key_length),
                .iv = tls.hkdfExpandLabel(P.Hkdf, secret, "iv", "", P.AEAD.nonce_length),
            };
        }

        fn nonce(k: Keys, seq: u64) [P.AEAD.nonce_length]u8 {
            var out = k.iv;
            const tail = std.mem.readInt(u64, out[out.len - 8 ..], .big);
            std.mem.writeInt(u64, out[out.len - 8 ..], tail ^ seq, .big);
            return out;
        }
    };

    fn big16(n: usize) [2]u8 {
        return @bitCast(std.mem.nativeToBig(u16, @intCast(n)));
    }

    /// `message` of content type `inner` as one TLS 1.3 record encrypted with `k`; `seq` counts the records sent with it.
    fn writeSealed(stream: std.net.Stream, k: Keys, seq: u64, inner: u8, message: []const u8) !void {
        var buf: [2048]u8 = undefined;
        var out: [2048]u8 = undefined;
        const inner_len = message.len + 1;
        const header: [5]u8 = [_]u8{ 0x17, 0x03, 0x03 } ++ big16(inner_len + P.AEAD.tag_length);
        @memcpy(buf[0..message.len], message);
        buf[message.len] = inner;
        var tag: [P.AEAD.tag_length]u8 = undefined;
        P.AEAD.encrypt(out[0..inner_len], &tag, buf[0..inner_len], &header, k.nonce(seq), k.key);
        try stream.writeAll(&header);
        try stream.writeAll(out[0..inner_len]);
        try stream.writeAll(&tag);
    }

    /// The clear text of a record encrypted with `k` (its inner content type last).
    fn open(k: Keys, seq: u64, header: [5]u8, body: []u8) ![]u8 {
        if (body.len < P.AEAD.tag_length + 1) return error.ShortRecord;
        const text = body[0 .. body.len - P.AEAD.tag_length];
        const tag = body[body.len - P.AEAD.tag_length ..][0..P.AEAD.tag_length].*;
        try P.AEAD.decrypt(text, text, tag, &header, k.nonce(seq), k.key);
        return text;
    }

    const Record = struct { type: u8, header: [5]u8, body: []u8 };

    fn readRecord(stream: std.net.Stream, buf: []u8) !Record {
        var header: [5]u8 = undefined;
        try stream.reader().readNoEof(&header);
        const len = std.mem.readInt(u16, header[3..5], .big);
        if (len > buf.len) return error.RecordTooLong;
        try stream.reader().readNoEof(buf[0..len]);
        return .{ .type = header[0], .header = header, .body = buf[0..len] };
    }

    const ClientHello = struct { session_id: []const u8, x25519: [32]u8 };

    /// The session id and the x25519 key share of a ClientHello handshake message.
    fn readClientHello(m: []const u8) !ClientHello {
        var d = tls.Decoder.fromTheirSlice(@constCast(m));
        try d.ensure(4 + 2 + 32 + 1);
        d.skip(4 + 2 + 32);
        const sid_len = d.decode(u8);
        try d.ensure(sid_len + 2);
        const session_id = d.slice(sid_len);
        const suites_len = d.decode(u16);
        try d.ensure(suites_len + 1);
        d.skip(suites_len);
        const compression_len = d.decode(u8);
        try d.ensure(compression_len + 2);
        d.skip(compression_len);
        var exts = try d.sub(d.decode(u16));
        while (!exts.eof()) {
            try exts.ensure(4);
            const kind = exts.decode(u16);
            var ext = try exts.sub(exts.decode(u16));
            if (kind != 0x0033) continue;
            try ext.ensure(2);
            var shares = try ext.sub(ext.decode(u16));
            while (!shares.eof()) {
                try shares.ensure(4);
                const group = shares.decode(u16);
                const len = shares.decode(u16);
                try shares.ensure(len);
                const k = shares.slice(len);
                if (group == 0x001d and len == 32) return .{ .session_id = session_id, .x25519 = k[0..32].* };
            }
        }
        return error.NoX25519KeyShare;
    }
};
