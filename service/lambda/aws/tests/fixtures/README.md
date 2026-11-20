Test-only certificates and keys for `tests/http.rs` and `tests/native_roots.rs`. Nothing outside those tests trusts or uses them.
All are EC P-256 and valid for 100 years.

| file | what |
|---|---|
| `ca.der`, `ca.pem` | the CA the client under test trusts (the same certificate in DER and in PEM) |
| `leaf.der`, `leaf_key.der` | a server certificate for the IP address 127.0.0.1 issued by that CA, and its PKCS#8 key |
| `other_leaf.der`, `other_leaf_key.der` | a server certificate for 127.0.0.1 issued by another CA, which nothing here trusts, and its key |
