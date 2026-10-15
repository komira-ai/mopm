//! A TLS 1.2 and a TLS 1.3 handshake between a rustls client and a rustls server over
//! loopback, both on the aws-lc-rs provider, which is komira's AWS-LC linked into the test.
//!
//! What it proves: the whole chain links and runs (rustls, aws-lc-rs, the bindings
//! rewritten to komira's symbol prefix, the AWS-LC archive); the negotiated protocol is
//! the one each test forced; certificate verification runs (a wrong server name fails);
//! and the crypto library is AWS-LC 1.39.0, read from the library itself.

use std::ffi::CStr;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::Arc;
use std::thread;

use rustls::crypto::aws_lc_rs;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName};
use rustls::{ClientConfig, ClientConnection, RootCertStore, ServerConfig, ServerConnection, StreamOwned};

const CA: &[u8] = include_bytes!("fixtures/ca.der");
const LEAF: &[u8] = include_bytes!("fixtures/leaf.der");
const LEAF_KEY: &[u8] = include_bytes!("fixtures/leaf_key.der");

fn server_config(version: &'static rustls::SupportedProtocolVersion) -> Arc<ServerConfig> {
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(LEAF_KEY.to_vec()));
    Arc::new(
        ServerConfig::builder_with_provider(Arc::new(aws_lc_rs::default_provider()))
            .with_protocol_versions(&[version])
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(vec![CertificateDer::from(LEAF.to_vec())], key)
            .unwrap(),
    )
}

fn client_config() -> ClientConfig {
    let mut roots = RootCertStore::empty();
    roots.add(CertificateDer::from(CA.to_vec())).unwrap();
    // Both ends accept either version; the server's choice decides.
    ClientConfig::builder_with_provider(Arc::new(aws_lc_rs::default_provider()))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_root_certificates(roots)
        .with_no_client_auth()
}

/// One exchange: the client sends "ping", the server answers "pong".
/// Returns what the client negotiated: protocol version and cipher suite.
fn exchange(version: &'static rustls::SupportedProtocolVersion, server_name: &'static str) -> std::io::Result<(rustls::ProtocolVersion, String)> {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let config = server_config(version);
    let server = thread::spawn(move || {
        let (tcp, _) = listener.accept().unwrap();
        let mut tls = StreamOwned::new(ServerConnection::new(config).unwrap(), tcp);
        let mut buf = [0u8; 4];
        // A failed handshake (a client that refuses us) ends here.
        if tls.read_exact(&mut buf).is_ok() {
            assert_eq!(&buf, b"ping");
            tls.write_all(b"pong").unwrap();
            tls.flush().unwrap();
            tls.conn.send_close_notify();
            let _ = tls.flush();
        }
    });
    let tcp = TcpStream::connect(addr).unwrap();
    let name = ServerName::try_from(server_name).unwrap();
    let mut tls = StreamOwned::new(ClientConnection::new(Arc::new(client_config()), name).unwrap(), tcp);
    let result = (|| {
        tls.write_all(b"ping")?;
        let mut buf = [0u8; 4];
        tls.read_exact(&mut buf)?;
        assert_eq!(&buf, b"pong");
        Ok((
            tls.conn.protocol_version().unwrap(),
            format!("{:?}", tls.conn.negotiated_cipher_suite().unwrap().suite()),
        ))
    })();
    drop(tls);
    server.join().unwrap();
    result
}

#[test]
fn tls13_handshake_and_exchange() {
    let (version, suite) = exchange(&rustls::version::TLS13, "localhost").unwrap();
    assert_eq!(version, rustls::ProtocolVersion::TLSv1_3);
    assert!(suite.starts_with("TLS13_"), "{suite}");
}

#[test]
fn tls12_handshake_and_exchange() {
    let (version, suite) = exchange(&rustls::version::TLS12, "localhost").unwrap();
    assert_eq!(version, rustls::ProtocolVersion::TLSv1_2);
    assert!(suite.starts_with("TLS_ECDHE_ECDSA_"), "{suite}");
}

#[test]
fn a_wrong_server_name_is_refused() {
    for version in [&rustls::version::TLS12, &rustls::version::TLS13] {
        let err = exchange(version, "other.example").unwrap_err();
        assert!(err.to_string().contains("certificate"), "{err}");
    }
}

#[test]
fn the_library_is_komiras_aws_lc() {
    // SAFETY: OpenSSL_version(0) returns a pointer to a static NUL-terminated string.
    let text = unsafe { CStr::from_ptr(aws_lc_sys::OpenSSL_version(0)) }.to_str().unwrap();
    assert!(text.starts_with("AWS-LC 1.39.0"), "{text}");
}
