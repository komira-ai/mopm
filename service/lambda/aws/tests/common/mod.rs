//! The servers the client is tested against, all on loopback with port 0: a TLS front for `mopm_testing::fake_http`
//! (the fake records the request as it arrived and answers from its script), TLS servers that misbehave on purpose,
//! and plain TCP ones. The certificates are the test-only ones in `tests/fixtures`.

#![allow(dead_code, reason = "each test binary uses a part of these helpers")]

use std::future::Future;
use std::net::SocketAddr;
use std::sync::Arc;

use mopm_testing::fake_http::FakeHttp;
use rustls::crypto::aws_lc_rs;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use rustls::{RootCertStore, ServerConfig};
use tokio::net::{TcpListener, TcpStream};
use tokio_rustls::server::TlsStream;
use tokio_rustls::TlsAcceptor;

pub const CA: &[u8] = include_bytes!("../fixtures/ca.der");
const LEAF: &[u8] = include_bytes!("../fixtures/leaf.der");
const LEAF_KEY: &[u8] = include_bytes!("../fixtures/leaf_key.der");
const OTHER_LEAF: &[u8] = include_bytes!("../fixtures/other_leaf.der");
const OTHER_LEAF_KEY: &[u8] = include_bytes!("../fixtures/other_leaf_key.der");

/// The roots the client under test trusts: the test CA only.
pub fn trusted_roots() -> RootCertStore {
    let mut roots = RootCertStore::empty();
    roots.add(CertificateDer::from(CA.to_vec())).unwrap();
    roots
}

fn server_config(leaf: &[u8], key: &[u8]) -> Arc<ServerConfig> {
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.to_vec()));
    let config = ServerConfig::builder_with_provider(Arc::new(aws_lc_rs::default_provider()))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(vec![CertificateDer::from(leaf.to_vec())], key)
        .unwrap();
    Arc::new(config)
}

/// The server certificate the client trusts (issued by the test CA for 127.0.0.1).
pub fn trusted_cert() -> Arc<ServerConfig> {
    server_config(LEAF, LEAF_KEY)
}

/// A server certificate for 127.0.0.1 from a CA the client does not trust.
pub fn untrusted_cert() -> Arc<ServerConfig> {
    server_config(OTHER_LEAF, OTHER_LEAF_KEY)
}

/// A loopback listener on a port the system picks.
async fn listen() -> (TcpListener, SocketAddr) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    (listener, addr)
}

/// Serves every TCP connection with `serve`, on the test's runtime (the server ends with it).
pub async fn tcp_server<F, Fut>(serve: F) -> SocketAddr
where
    F: Fn(TcpStream) -> Fut + Send + 'static,
    Fut: Future<Output = ()> + Send + 'static,
{
    let (listener, addr) = listen().await;
    tokio::spawn(async move {
        while let Ok((tcp, _)) = listener.accept().await {
            tokio::spawn(serve(tcp));
        }
    });
    addr
}

/// Serves every connection whose TLS handshake completes with `serve`; a refused handshake ends that connection.
pub async fn tls_server<F, Fut>(config: Arc<ServerConfig>, serve: F) -> SocketAddr
where
    F: Fn(TlsStream<TcpStream>) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = ()> + Send + 'static,
{
    let acceptor = TlsAcceptor::from(config);
    let serve = Arc::new(serve);
    tcp_server(move |tcp| {
        let acceptor = acceptor.clone();
        let serve = serve.clone();
        async move {
            if let Ok(tls) = acceptor.accept(tcp).await {
                serve(tls).await;
            }
        }
    })
    .await
}

/// `fake` behind TLS with `config`: each connection's decrypted bytes go to the fake and its answer comes back.
pub async fn tls_front(fake: &FakeHttp, config: Arc<ServerConfig>) -> SocketAddr {
    let backend: SocketAddr = fake
        .endpoint()
        .trim_start_matches("http://")
        .parse()
        .unwrap();
    tls_server(config, move |mut tls| async move {
        let mut plain = TcpStream::connect(backend).await.unwrap();
        // The fake closes after its answer, which ends the copy.
        let _ = tokio::io::copy_bidirectional(&mut tls, &mut plain).await;
    })
    .await
}

/// Reads until the end of a request's head (a request without a body is then whole).
pub async fn read_head<S: tokio::io::AsyncRead + Unpin>(stream: &mut S) -> Vec<u8> {
    use tokio::io::AsyncReadExt;
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    while !buf.windows(4).any(|w| w == b"\r\n\r\n") {
        let n = stream.read(&mut chunk).await.unwrap();
        assert!(n > 0, "the client closed before the end of its request");
        buf.extend_from_slice(&chunk[..n]);
    }
    buf
}

/// `https://127.0.0.1:<port><path>` for a server at `addr`.
pub fn https(addr: SocketAddr, path: &str) -> String {
    format!("https://{addr}{path}")
}
