# TLS on AWS-LC

`:tls_test` is a rust_test: a rustls client and server, both on the `aws-lc-rs` provider, shake hands over
loopback with TLS 1.2 and with TLS 1.3, exchange a message, and a client that expects another server name is
refused. The AWS-LC underneath is `komira//third_party/aws-lc:crypto`, linked in place of what the
`aws-lc-sys` build script would compile (see `third_party/rust/crates.bzl`).

`fixtures/` is test data: a CA, a server certificate for `localhost` it signed (both ECDSA P-256, valid for a
hundred years) and the server's key, in DER. They were made once with `openssl` (`req -x509`, `req`, `x509 -req
-CA`); the CA's key was not kept, so nothing can issue under it. The key is a test key and secures nothing.
