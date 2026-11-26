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
/// `client.ca_bundle`), in the client's pool for `client.open` to send on (a Request releases it; until one does, `release`). A certificate the
/// handshake rejects is its own error (`certificateRejected`); any other failed handshake is `TlsInitializationFailed`.
/// Errors of the TCP connection are the client's own. On an error nothing stays open.
pub fn connect(client: *std.http.Client, host: []const u8, port: u16) !*std.http.Client.Connection {
    const conn = try client.connectTcp(host, port, .plain);
    errdefer release(client, conn);
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

/// Closes `conn`, a connection of `client` that no request owns, and takes it out of the client's pool.
pub fn release(client: *std.http.Client, conn: *std.http.Client.Connection) void {
    conn.closing = true;
    client.connection_pool.release(client.allocator, conn);
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

test "a client whose certificates were read already is left as it is" {
    // The reading itself (the system's certificate files) is not run here: a test touches no system path.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var client = offlineClient(arena_state.allocator());
    defer client.deinit();
    try loadCertificates(&client);
    try std.testing.expect(!client.next_https_rescan_certs);
    try std.testing.expectEqual(@as(u32, 0), client.ca_bundle.map.count());
}

const test_server = @import("tls_test_server.zig");

test "a server certificate that does not name the host, or that no trusted certificate vouches for, keeps its own error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const key = try test_server.testKey();
    const wrong_name = try test_server.certificate(a, key, "wrong.example");
    const right_name = try test_server.certificate(a, key, "127.0.0.1");
    const cases = [_]struct { cert: []const u8, trusted: bool, want: anyerror }{
        // The name is checked first, so trusting the certificate does not help.
        .{ .cert = wrong_name, .trusted = true, .want = error.CertificateHostMismatch },
        .{ .cert = right_name, .trusted = false, .want = error.TlsCertificateNotVerified },
    };
    for (cases) |c| {
        // mopm's connection: the certificate's error, which http.zig does not retry.
        {
            var s: test_server.Server = undefined;
            try s.start(c.cert, null, "");
            var client = offlineClient(a);
            if (c.trusted) try test_server.trust(&client, c.cert);
            const got = connect(&client, "127.0.0.1", s.port());
            client.deinit();
            s.stop();
            try std.testing.expectEqual(@as(?anyerror, null), s.failed);
            try std.testing.expectError(c.want, got);
        }
        // The standard client's own connection to the same server says only TlsInitializationFailed, which is why
        // mopm makes the handshake itself.
        {
            var s: test_server.Server = undefined;
            try s.start(c.cert, null, "");
            var client = offlineClient(a);
            if (c.trusted) try test_server.trust(&client, c.cert);
            const got = client.connectTcp("127.0.0.1", s.port(), .tls);
            client.deinit();
            s.stop();
            try std.testing.expectError(error.TlsInitializationFailed, got);
        }
    }
}

test "a certificate for another host is refused as soon as it arrives, and the server sees the connection closed before its CertificateVerify" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const key = try test_server.testKey();
    const cert = try test_server.certificate(a, key, "wrong.example");
    // The server holds its CertificateVerify until connect has returned: connect must not wait for it, and the
    // server then writes to a connection the client has closed.
    var hold = std.Thread.ResetEvent{};
    var s: test_server.Server = undefined;
    try s.startHeld(cert, &hold);
    var client = offlineClient(a);
    try test_server.trust(&client, cert);
    const got = connect(&client, "127.0.0.1", s.port());
    const let_go = client.connection_pool.used.first == null;
    client.deinit();
    hold.set();
    s.stop();
    try std.testing.expectError(error.CertificateHostMismatch, got);
    try std.testing.expect(let_go);
    try std.testing.expectEqual(@as(?anyerror, null), s.failed);
}

test "a trusted certificate for the host gives a TLS connection, in the client's pool, that carries a request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const key = try test_server.testKey();
    const cert = try test_server.certificate(a, key, "127.0.0.1");
    var s: test_server.Server = undefined;
    try s.start(cert, key, "HTTP/1.1 204 No Content\r\n\r\n");
    var client = offlineClient(a);
    try test_server.trust(&client, cert);
    const conn = try connect(&client, "127.0.0.1", s.port());
    try std.testing.expectEqual(std.http.Client.Connection.Protocol.tls, conn.protocol);
    try std.testing.expect(client.connection_pool.used.first != null);
    // What is written goes through TLS: the server reads it in clear only after decrypting it.
    try conn.writer().writeAll("GET / HTTP/1.1\r\n\r\n");
    try conn.flush();
    var answer: [64]u8 = undefined;
    const n = try conn.read(&answer);
    try std.testing.expectEqualStrings("HTTP/1.1 204 No Content\r\n\r\n", answer[0..n]);
    release(&client, conn);
    try std.testing.expect(client.connection_pool.used.first == null);
    client.deinit();
    s.stop();
    try std.testing.expectEqual(@as(?anyerror, null), s.failed);
    try std.testing.expectEqualStrings("GET / HTTP/1.1\r\n\r\n", s.request[0..s.request_len]);
}
