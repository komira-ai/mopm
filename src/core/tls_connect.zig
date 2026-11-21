//! The TLS connection of an `https` request, made by mopm rather than by the standard client so that the handshake's own
//! error is kept. Zig 0.12's `std.http.Client.connectTcp` reports every error of `std.crypto.tls.Client.init` as
//! `TlsInitializationFailed`: a handshake the peer broke off and a certificate the client rejects read the same. A broken
//! handshake is worth a second try (http.zig retries `TlsInitializationFailed`); a wrong certificate is not, since every
//! try meets the same certificate. So `connect` makes the TCP connection with the client's own `connectTcp`, runs the
//! handshake itself, and hands the connection to `client.open` (its `connection` option): a rejected certificate keeps
//! its name (`CertificateHostMismatch`, `TlsCertificateNotVerified`, ...), which http.zig does not retry, and every other
//! handshake failure is `TlsInitializationFailed`, as the client would have said.

const std = @import("std");

/// The system's certificates, read into `client` once, as the standard client reads them before its first https request.
pub fn loadCertificates(client: *std.http.Client) error{CertificateBundleLoadFailure}!void {
    if (!client.next_https_rescan_certs) return;
    client.ca_bundle.rescan(client.allocator) catch return error.CertificateBundleLoadFailure;
    client.next_https_rescan_certs = false;
}

/// A TLS connection to `host:port`, made as the standard client makes one (its `connectTcp`, then the handshake against
/// `client.ca_bundle`), in the client's pool for `client.open` to send on and `client.deinit` to close. A certificate the
/// handshake rejects is its own error (`certificateRejected`); any other failed handshake is `TlsInitializationFailed`.
/// Errors of the TCP connection are the client's own. On an error nothing stays open.
pub fn connect(client: *std.http.Client, host: []const u8, port: u16) !*std.http.Client.Connection {
    const conn = try client.connectTcp(host, port, .plain);
    errdefer {
        conn.closing = true;
        client.connection_pool.release(client.allocator, conn);
    }
    const tls = try client.allocator.create(std.crypto.tls.Client);
    errdefer client.allocator.destroy(tls);
    tls.* = std.crypto.tls.Client.init(conn.stream, client.ca_bundle, host) catch |e| {
        return if (certificateRejected(e)) e else error.TlsInitializationFailed;
    };
    // As the standard client does for https: the answer's Content-Length is what detects a truncated body.
    tls.allow_truncation_attacks = true;
    conn.tls_client = tls;
    conn.protocol = .tls;
    return conn;
}

/// The errors of `std.crypto.tls.Client.init` (Zig 0.12.0) that say the server's certificate is wrong: it does not name
/// the host, its chain does not lead to a trusted certificate or fails a check (dates, signatures, encoding), or the server
/// could not prove it holds the certificate's key. The key exchange's own failures are `TlsDecryptFailure` there, so the
/// signature and encoding names come only from the certificate. A second try meets the same certificate: these are final.
pub const certificate_rejections = [_][]const u8{
    "CertificateFieldHasInvalidLength",        "CertificateHostMismatch",               "CertificatePublicKeyInvalid",
    "CertificateExpired",                      "CertificateFieldHasWrongDataType",      "CertificateIssuerMismatch",
    "CertificateNotYetValid",                  "CertificateSignatureAlgorithmMismatch", "CertificateSignatureAlgorithmUnsupported",
    "CertificateSignatureInvalid",             "CertificateSignatureInvalidLength",     "CertificateSignatureNamedCurveUnsupported",
    "CertificateSignatureUnsupportedBitCount", "CertificateTimeInvalid",                "CertificateHasUnrecognizedObjectId",
    "CertificateHasInvalidBitString",          "UnsupportedCertificateVersion",         "TlsCertificateNotVerified",
    "TlsBadSignatureScheme",                   "TlsBadRsaSignatureBitCount",            "SignatureVerificationFailed",
    "InvalidSignature",                        "InvalidEncoding",                       "IdentityElement",
    "NonCanonical",                            "NotSquare",                             "WeakPublicKey",
    "MessageTooLong",                          "NegativeIntoUnsigned",                  "TargetTooSmall",
    "BufferTooSmall",
};

/// Whether the handshake error `e` is one of `certificate_rejections`.
pub fn certificateRejected(e: anyerror) bool {
    const name = @errorName(e);
    for (certificate_rejections) |c| {
        if (std.mem.eql(u8, name, c)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------- tests

test "every error the pinned handshake can return is a rejected certificate or a failure worth a second try" {
    const set = @typeInfo(std.crypto.tls.Client.InitError(std.net.Stream)).ErrorSet.?;
    // Every listed rejection is an error the handshake can return, so the list has no dead name.
    for (certificate_rejections) |c| {
        var found = false;
        inline for (set) |e| found = found or std.mem.eql(u8, e.name, c);
        if (!found) std.debug.print("not an error of std.crypto.tls.Client.init: {s}\n", .{c});
        try std.testing.expect(found);
    }
    // And every error whose name says certificate is listed, but for the alerts: a `TlsAlert...Certificate...` is the
    // server's word about a client certificate, which mopm never sends, and is retried like every other alert.
    var rejected: usize = 0;
    inline for (set) |info| {
        if (certificateRejected(@field(anyerror, info.name))) {
            rejected += 1;
        } else {
            const unlisted = std.mem.indexOf(u8, info.name, "Certificate") != null and !std.mem.startsWith(u8, info.name, "TlsAlert");
            if (unlisted) std.debug.print("not listed: {s}\n", .{info.name});
            try std.testing.expect(!unlisted);
        }
    }
    try std.testing.expectEqual(certificate_rejections.len, rejected);
    // A broken connection, a damaged record and an alert from the server are failures of the connection.
    for ([_]anyerror{ error.ConnectionResetByPeer, error.EndOfStream, error.TlsConnectionTruncated, error.TlsBadRecordMac, error.TlsDecryptFailure, error.TlsAlertHandshakeFailure }) |e| {
        try std.testing.expect(!certificateRejected(e));
    }
}

fn loopbackServer() !std.net.Server {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    return addr.listen(.{ .reuse_address = true });
}

/// A client that reads no system certificates: its bundle is empty and marked read, so a test touches no system path.
fn offlineClient(arena: std.mem.Allocator) std.http.Client {
    return .{ .allocator = arena, .next_https_rescan_certs = false };
}

/// A loopback peer that takes one connection, writes `reply` and closes it: a peer that is not a TLS server.
const NotTls = struct {
    server: std.net.Server,
    reply: []const u8,

    fn run(t: *NotTls) void {
        const conn = t.server.accept() catch return;
        defer conn.stream.close();
        conn.stream.writeAll(t.reply) catch {};
    }
};

test "a handshake the peer breaks off is TlsInitializationFailed, and the connection is let go" {
    // A peer that closes at once, and one that answers plain HTTP: neither is a certificate, so both are retried.
    for ([_][]const u8{ "", "HTTP/1.1 400 Bad Request\r\ncontent-length: 0\r\n\r\n" }) |reply| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        var t = NotTls{ .server = try loopbackServer(), .reply = reply };
        defer t.server.deinit();
        const th = try std.Thread.spawn(.{}, NotTls.run, .{&t});
        defer th.join();
        var client = offlineClient(arena_state.allocator());
        defer client.deinit();
        try std.testing.expectError(error.TlsInitializationFailed, connect(&client, "127.0.0.1", t.server.listen_address.getPort()));
        try std.testing.expect(client.connection_pool.used.first == null);
    }
}

test "the certificates are read once, and not again once read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var client = offlineClient(arena_state.allocator());
    defer client.deinit();
    try loadCertificates(&client);
    try std.testing.expect(!client.next_https_rescan_certs);
    try std.testing.expectEqual(@as(u32, 0), client.ca_bundle.map.count());
}

// A self-signed P-256 certificate whose only name is `wrong.example` (made for this test; its key was discarded).
const cert_wrong_name =
    \\3082019f30820145a00302010202141ec602d8c4b59288bc8a63579f97e4bdb8fae065300a06082a8648ce3d040302301831
    \\16301406035504030c0d77726f6e672e6578616d706c65301e170d3236313132313137313833395a170d3336313131383137
    \\313833395a30183116301406035504030c0d77726f6e672e6578616d706c653059301306072a8648ce3d020106082a8648ce
    \\3d03010703420004092d92faff2d69b5edf8b3e418ea5060f4bdb5f4b83e3ba07d30ec1ae9f5f507c538e6743f3345d21b70
    \\40d8a4b0db4ebd78072eda30b2235b5275598da85733a36d306b301d0603551d0e04160414359098d36378fd2944ea240a7c
    \\97ebd8db5006f5301f0603551d23041830168014359098d36378fd2944ea240a7c97ebd8db5006f5300f0603551d130101ff
    \\040530030101ff30180603551d110411300f820d77726f6e672e6578616d706c65300a06082a8648ce3d0403020348003045
    \\022100e0ef1eb01f1adac490097e33c37e519167b1f352d59e66bd28ea0625a121bd6502207fb257060a6403fa8af8faaaf0
    \\f8179ac22207454b4a350342663b729fadbb0e
;

// A self-signed P-256 certificate that names `127.0.0.1`, signed by no certificate a client trusts (same origin).
const cert_untrusted =
    \\3082019430820139a003020102021478089a63f4da88e0978ee61851be40d467cfd13c300a06082a8648ce3d040302301431
    \\12301006035504030c093132372e302e302e31301e170d3236313132313137313931385a170d333631313138313731393138
    \\5a30143112301006035504030c093132372e302e302e313059301306072a8648ce3d020106082a8648ce3d03010703420004
    \\579aca4fca9df7ced6b3944142dde6fe872c10609327b14b9b9a8222333fa090ed3861109ff1809e44a1f8e8a2f51fd5403d
    \\c71e8861b75ad90d9148664bce91a3693067301d0603551d0e041604146d1035f69c1979b7938bc679eac914c421155e6630
    \\1f0603551d230418301680146d1035f69c1979b7938bc679eac914c421155e66300f0603551d130101ff040530030101ff30
    \\140603551d11040d300b82093132372e302e302e31300a06082a8648ce3d040302034900304602210090f21d287b7e3bff14
    \\04eaecba5220572f988361d7026e8288d1653214f3db6202210098379ed2c62f6cde0857ec79d0379efd29daae1647402a50
    \\8be9f127e2b5ecf6
;

fn derOf(arena: std.mem.Allocator, comptime hex_lines: []const u8) ![]u8 {
    var hex = std.ArrayList(u8).init(arena);
    for (hex_lines) |c| if (c != '\n') try hex.append(c);
    const out = try arena.alloc(u8, hex.items.len / 2);
    return std.fmt.hexToBytes(out, hex.items);
}

/// A loopback peer that plays a TLS 1.3 server as far as its certificate, for one connection: ServerHello (x25519,
/// TLS_AES_128_GCM_SHA256), then, encrypted with the handshake keys, EncryptedExtensions, a Certificate holding `cert`
/// and a CertificateVerify that proves nothing. A client must stop at the certificate: the server holds no key for it.
const CertServer = struct {
    server: std.net.Server,
    cert: []const u8,
    failed: ?anyerror = null,

    const P = std.crypto.tls.HandshakeCipherT(std.crypto.aead.aes_gcm.Aes128Gcm, std.crypto.hash.sha2.Sha256);

    fn run(s: *CertServer) void {
        s.serve() catch |e| {
            s.failed = e;
        };
    }

    fn serve(s: *CertServer) !void {
        const conn = try s.server.accept();
        defer conn.stream.close();
        const r = conn.stream.reader();
        var hello_buf: [4096]u8 = undefined;
        var header: [5]u8 = undefined;
        try r.readNoEof(&header);
        const hello = hello_buf[0..std.mem.readInt(u16, header[3..5], .big)];
        try r.readNoEof(hello);
        const ch = try readClientHello(hello);

        const kp = try std.crypto.dh.X25519.KeyPair.create([_]u8{7} ** 32);
        const shared = try std.crypto.dh.X25519.scalarmult(kp.secret_key, ch.x25519);
        var sh: [128]u8 = undefined;
        var w = std.io.fixedBufferStream(&sh);
        const sw = w.writer();
        try sw.writeAll(&([_]u8{ 0x02, 0, 0, 0, 0x03, 0x03 } ++ [_]u8{0x11} ** 32));
        try sw.writeByte(@intCast(ch.session_id.len));
        try sw.writeAll(ch.session_id);
        try sw.writeAll(&.{ 0x13, 0x01, 0x00, 0x00, 46, 0x00, 0x2b, 0x00, 0x02, 0x03, 0x04, 0x00, 0x33, 0x00, 36, 0x00, 0x1d, 0x00, 32 });
        try sw.writeAll(&kp.public_key);
        const server_hello = w.getWritten();
        std.mem.writeInt(u24, server_hello[1..4], @intCast(server_hello.len - 4), .big);

        var transcript = P.Hash.init(.{});
        transcript.update(hello);
        transcript.update(server_hello);
        const hello_hash = transcript.peek();
        const zeroes = [1]u8{0} ** P.Hash.digest_length;
        const empty_hash = std.crypto.tls.emptyHash(P.Hash);
        const early_secret = P.Hkdf.extract(&[1]u8{0}, &zeroes);
        const derived = std.crypto.tls.hkdfExpandLabel(P.Hkdf, early_secret, "derived", &empty_hash, P.Hash.digest_length);
        const handshake_secret = P.Hkdf.extract(&derived, &shared);
        const server_secret = std.crypto.tls.hkdfExpandLabel(P.Hkdf, handshake_secret, "s hs traffic", &hello_hash, P.Hash.digest_length);
        const key = std.crypto.tls.hkdfExpandLabel(P.Hkdf, server_secret, "key", "", P.AEAD.key_length);
        const iv = std.crypto.tls.hkdfExpandLabel(P.Hkdf, server_secret, "iv", "", P.AEAD.nonce_length);

        var out: [4096]u8 = undefined;
        try conn.stream.writeAll(&([_]u8{ 0x16, 0x03, 0x03 } ++ @as([2]u8, @bitCast(std.mem.nativeToBig(u16, @intCast(server_hello.len))))));
        try conn.stream.writeAll(server_hello);
        // EncryptedExtensions, empty.
        try writeSealed(conn.stream, &out, key, iv, 0, &.{ 0x08, 0, 0, 2, 0, 0 });
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
        try writeSealed(conn.stream, &out, key, iv, 1, msg[0 .. 4 + body_len]);
        // CertificateVerify (ecdsa_secp256r1_sha256) with an empty signature: a client that trusted the chain would refuse it.
        try writeSealed(conn.stream, &out, key, iv, 2, &.{ 0x0f, 0, 0, 4, 0x04, 0x03, 0, 0 });
        // Wait for the client to give up, so it reads everything sent before the connection closes.
        _ = conn.stream.read(&out) catch 0;
    }

    /// One handshake message as a TLS 1.3 record, encrypted with the server's handshake key; `seq` counts records.
    fn writeSealed(stream: std.net.Stream, out: []u8, key: [P.AEAD.key_length]u8, iv: [P.AEAD.nonce_length]u8, seq: u64, message: []const u8) !void {
        const inner_len = message.len + 1;
        const header: [5]u8 = [_]u8{ 0x17, 0x03, 0x03 } ++ @as([2]u8, @bitCast(std.mem.nativeToBig(u16, @intCast(inner_len + P.AEAD.tag_length))));
        var inner: [1100]u8 = undefined;
        @memcpy(inner[0..message.len], message);
        inner[message.len] = 0x16;
        var nonce = iv;
        const tail = std.mem.readInt(u64, nonce[nonce.len - 8 ..], .big);
        std.mem.writeInt(u64, nonce[nonce.len - 8 ..], tail ^ seq, .big);
        var tag: [P.AEAD.tag_length]u8 = undefined;
        P.AEAD.encrypt(out[0..inner_len], &tag, inner[0..inner_len], &header, nonce, key);
        try stream.writeAll(&header);
        try stream.writeAll(out[0..inner_len]);
        try stream.writeAll(&tag);
    }

    const ClientHello = struct { session_id: []const u8, x25519: [32]u8 };

    /// The session id and the x25519 key share of a ClientHello handshake message.
    fn readClientHello(m: []const u8) !ClientHello {
        var d = std.crypto.tls.Decoder.fromTheirSlice(@constCast(m));
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

fn startCertServer(cert: []const u8) !*CertServer {
    const s = try std.testing.allocator.create(CertServer);
    s.* = .{ .server = try loopbackServer(), .cert = cert };
    return s;
}

test "a server certificate that does not name the host, or that no trusted certificate vouches for, keeps its own error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cases = [_]struct { cert: []const u8, want: anyerror }{
        .{ .cert = try derOf(a, cert_wrong_name), .want = error.CertificateHostMismatch },
        .{ .cert = try derOf(a, cert_untrusted), .want = error.TlsCertificateNotVerified },
    };
    for (cases) |c| {
        // mopm's connection: the certificate's error, which http.zig does not retry.
        {
            const s = try startCertServer(c.cert);
            defer std.testing.allocator.destroy(s);
            defer s.server.deinit();
            const th = try std.Thread.spawn(.{}, CertServer.run, .{s});
            var client = offlineClient(a);
            const got = connect(&client, "127.0.0.1", s.server.listen_address.getPort());
            client.deinit();
            th.join();
            try std.testing.expectEqual(@as(?anyerror, null), s.failed);
            try std.testing.expectError(c.want, got);
        }
        // The standard client's own connection to the same server says only TlsInitializationFailed, which is why
        // mopm makes the handshake itself.
        {
            const s = try startCertServer(c.cert);
            defer std.testing.allocator.destroy(s);
            defer s.server.deinit();
            const th = try std.Thread.spawn(.{}, CertServer.run, .{s});
            var client = offlineClient(a);
            const got = client.connectTcp("127.0.0.1", s.server.listen_address.getPort(), .tls);
            client.deinit();
            th.join();
            try std.testing.expectError(error.TlsInitializationFailed, got);
        }
    }
}
