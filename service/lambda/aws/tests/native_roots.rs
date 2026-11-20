//! `HyperHttpClient::with_native_roots`: the client trusts what the system's root store holds, read the way the SDK's
//! clients read it (rustls-native-certs). The store here is `SSL_CERT_FILE`, which, when it is set, is the only place
//! that is read: so the test sets it to the test CA and never reads the host's own store. The environment belongs to the
//! whole process, so this is the one test of its binary, and its two cases run in order.

mod common;

use std::time::Duration;

use common::{https, tls_front, trusted_cert};
use mopm_aws::http::HyperHttpClient;
use mopm_ports::http::{HttpClient, HttpRequest, Method};
use mopm_testing::fake_http::{FakeHttp, Reply};

#[tokio::test]
async fn the_client_trusts_the_system_roots_and_refuses_to_start_without_any() {
    // The working directory is the package's, under cargo and under buildrules alike.
    std::env::remove_var("SSL_CERT_DIR");

    std::env::set_var("SSL_CERT_FILE", "tests/fixtures/absent.pem");
    let e = HyperHttpClient::with_native_roots(1024).err().expect("no roots, no client");
    assert!(e.to_string().starts_with("infrastructure fault: no root certificates to trust: no native root CA certificates found"), "{e}");

    std::env::set_var("SSL_CERT_FILE", "tests/fixtures/ca.pem");
    let client = HyperHttpClient::with_native_roots(1024).unwrap();
    let fake = FakeHttp::start(vec![Reply::new(200).body("trusted")]);
    let addr = tls_front(&fake, trusted_cert()).await;
    let req = HttpRequest { method: Method::Get, url: https(addr, "/"), headers: vec![], body: vec![], timeout: Duration::from_secs(30) };
    assert_eq!(client.send(req).await.unwrap().body, b"trusted");
}
