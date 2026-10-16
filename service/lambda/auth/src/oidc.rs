//! CI identity tokens (`auth/oidc.ts`): a GitHub Actions workflow proves who it is with a short-lived
//! signed token, and the registry exchanges it, for a package a matching trusted publisher is registered for,
//! against a 15 minute publish token for exactly one version of that package.
//!
//! [`JwtVerifier`] checks the token. The algorithm is fixed here, RS256, and never read from the token: the
//! header's `alg` is only compared to that. The key comes from the issuer's published key set (by `kid`), never
//! from anything the token carries (`jwk`, `jku`, `x5c` in its header are not looked at). The signature is
//! checked by `jsonwebtoken` (pure-Rust RSA); every claim rule below is ours and tested, because their messages
//! and order are the API's.

use std::collections::HashMap;
use std::future::Future;
use std::sync::{Arc, Mutex, MutexGuard};

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use jsonwebtoken::{Algorithm, DecodingKey};
use mopm_core::error::{oidc_invalid, ErrorCode, RegistryError};
use mopm_core::version::canonical_version;
use mopm_ports::auth::AuthStore;
use mopm_ports::env::{Clock, Rng};
use mopm_ports::error::PortResult;
use mopm_ports::types::{TokenKind, TokenScope, TrustedPublisher};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;

use crate::http::{HttpClient, HttpRequest};
use crate::js;
use crate::tokens::{error, iso_at, is_valid_package_name, mint_token, now_ms, unavailable, TokenFields, OIDC_TOKEN_TTL_MS};

pub const GITHUB_OIDC_ISSUER: &str = "https://token.actions.githubusercontent.com";
pub const GITHUB_JWKS_URL: &str = "https://token.actions.githubusercontent.com/.well-known/jwks";

const MAX_JWT_LENGTH: usize = 8192;

/// One key of a JSON Web Key Set (RFC 7517), as far as an RSA verification key goes.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Jwk {
    pub kty: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kid: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub n: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub e: Option<String>,
    #[serde(default, rename = "use", skip_serializing_if = "Option::is_none")]
    pub use_: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub alg: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct JwkSet {
    #[serde(default)]
    pub keys: Vec<Jwk>,
}

/// The key set could not be fetched or read. The verifier answers `unavailable`: it is no verdict on the token.
#[derive(Clone, Debug, PartialEq, Eq, Error)]
#[error("{0}")]
pub struct JwksUnavailable(pub String);

pub trait JwksSource: Send + Sync {
    fn fetch(&self) -> impl Future<Output = Result<JwkSet, JwksUnavailable>> + Send;
}

/// The issuer's key set over HTTPS.
pub struct HttpJwks {
    client: HttpClient,
    url: String,
}

impl HttpJwks {
    pub fn new(client: HttpClient, url: impl Into<String>) -> Self {
        HttpJwks { client, url: url.into() }
    }

    /// GitHub's.
    pub fn github(client: HttpClient) -> Self {
        Self::new(client, GITHUB_JWKS_URL)
    }

    pub fn url(&self) -> &str {
        &self.url
    }
}

impl JwksSource for HttpJwks {
    async fn fetch(&self) -> Result<JwkSet, JwksUnavailable> {
        let res = self.client.send(HttpRequest::get(&self.url).header("accept", "application/json")).await.map_err(|e| JwksUnavailable(format!("the key set could not be fetched: {e}")))?;
        if !res.is_success() {
            return Err(JwksUnavailable(format!("JWKS answered {}", res.status)));
        }
        serde_json::from_slice(&res.body).map_err(|_| JwksUnavailable("JWKS answered something that is not a key set".into()))
    }
}

/// The claims of a GitHub Actions token that passed [`JwtVerifier::verify`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GithubActionsClaims {
    pub repository: String,
    pub repository_id: String,
    pub repository_owner_id: String,
    pub workflow_ref: String,
    pub environment: Option<String>,
}

#[derive(Clone, Debug)]
pub struct JwtVerifierOptions {
    pub issuer: String,
    /// Accepted audiences: `mopm.dev`, or the stage host.
    pub audiences: Vec<String>,
    /// Clock skew allowed on `exp`, `nbf` and `iat`, in seconds.
    pub leeway_seconds: i64,
    pub jwks_ttl_ms: i64,
    /// After a key set fetch, an unknown `kid` does not trigger another before this long: an attacker cannot make
    /// us fetch once per request.
    pub jwks_min_refetch_ms: i64,
}

impl JwtVerifierOptions {
    pub fn github(audiences: Vec<String>) -> Self {
        JwtVerifierOptions { issuer: GITHUB_OIDC_ISSUER.into(), audiences, leeway_seconds: 60, jwks_ttl_ms: 10 * 60_000, jwks_min_refetch_ms: 60_000 }
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
#[error("at least one audience is required")]
pub struct NoAudience;

#[derive(Default)]
struct KeyCache {
    keys: HashMap<String, Arc<DecodingKey>>,
    fetched_at: i64,
}

pub struct JwtVerifier<J> {
    options: JwtVerifierOptions,
    jwks: J,
    clock: Arc<dyn Clock>,
    cache: Mutex<KeyCache>,
}

fn invalid(why: &str) -> RegistryError {
    oidc_invalid(why)
}

/// `claims.key` where `claims` is a JSON object. Anything else (an array, a string) has no keys, as in JavaScript.
fn field<'a>(v: &'a Value, key: &str) -> Option<&'a Value> {
    v.as_object().and_then(|o| o.get(key))
}

fn is_base64url(s: &str) -> bool {
    s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn decode_json_part(part: &str) -> Result<Value, RegistryError> {
    if !is_base64url(part) {
        return Err(invalid("malformed token"));
    }
    let bytes = URL_SAFE_NO_PAD.decode(part).map_err(|_| invalid("malformed token"))?;
    // Buffer.toString('utf8') replaces what is not UTF-8; JSON.parse then decides.
    serde_json::from_str(&String::from_utf8_lossy(&bytes)).map_err(|_| invalid("malformed token"))
}

/// `typeof v === 'number' && isFinite(v)`.
fn number(v: Option<&Value>) -> Option<f64> {
    v.and_then(Value::as_f64).filter(|f| f.is_finite())
}

fn text(v: &Value, key: &str) -> Option<String> {
    field(v, key).and_then(Value::as_str).map(str::to_string)
}

impl<J: JwksSource> JwtVerifier<J> {
    pub fn new(options: JwtVerifierOptions, jwks: J, clock: Arc<dyn Clock>) -> Result<Self, NoAudience> {
        if options.audiences.is_empty() {
            return Err(NoAudience);
        }
        Ok(JwtVerifier { options, jwks, clock, cache: Mutex::new(KeyCache::default()) })
    }

    fn cache(&self) -> MutexGuard<'_, KeyCache> {
        self.cache.lock().expect("the key cache's lock is never held across a panic")
    }

    async fn refresh(&self) -> Result<(), RegistryError> {
        let set = self.jwks.fetch().await.map_err(|_| unavailable())?;
        let mut keys = HashMap::new();
        for k in set.keys {
            let usable = k.kty == "RSA" && k.use_.as_deref().is_none_or(|u| u.is_empty() || u == "sig");
            let (Some(kid), Some(n), Some(e)) = (k.kid.filter(|kid| !kid.is_empty()), k.n, k.e) else { continue };
            if !usable {
                continue;
            }
            // A key we cannot read is skipped.
            if let Ok(key) = DecodingKey::from_rsa_components(&n, &e) {
                keys.insert(kid, Arc::new(key));
            }
        }
        let mut cache = self.cache();
        cache.keys = keys;
        cache.fetched_at = now_ms(self.clock.as_ref());
        Ok(())
    }

    async fn key_for(&self, kid: &str) -> Result<Arc<DecodingKey>, RegistryError> {
        let (empty, fetched_at) = {
            let c = self.cache();
            (c.keys.is_empty(), c.fetched_at)
        };
        if empty || now_ms(self.clock.as_ref()) - fetched_at >= self.options.jwks_ttl_ms {
            self.refresh().await?;
        }
        let (found, fetched_at) = {
            let c = self.cache();
            (c.keys.get(kid).cloned(), c.fetched_at)
        };
        if let Some(k) = found {
            return Ok(k);
        }
        if now_ms(self.clock.as_ref()) - fetched_at >= self.options.jwks_min_refetch_ms {
            self.refresh().await?; // the issuer rotated its keys
            if let Some(k) = self.cache().keys.get(kid).cloned() {
                return Ok(k);
            }
        }
        Err(invalid("unknown signing key"))
    }

    /// Check a GitHub Actions identity token: structure, algorithm, signature against the issuer's key set, then
    /// issuer, audience, `exp`, `nbf`, `iat`, and the claims the trust decision needs.
    pub async fn verify(&self, jwt: &str) -> Result<GithubActionsClaims, RegistryError> {
        if jwt.is_empty() || js::length(jwt) > MAX_JWT_LENGTH {
            return Err(invalid("malformed token"));
        }
        let parts: Vec<&str> = jwt.split('.').collect();
        let &[head, body, sig] = parts.as_slice() else { return Err(invalid("malformed token")) };
        let header = decode_json_part(head)?;
        let claims = decode_json_part(body)?;
        if !matches!(header, Value::Object(_) | Value::Array(_)) || !matches!(claims, Value::Object(_) | Value::Array(_)) {
            return Err(invalid("malformed token"));
        }
        // The algorithm is ours. `none`, HMAC (the key-confusion attack) and every other are refused here, before a
        // key is looked up or fetched.
        if field(&header, "alg").and_then(Value::as_str) != Some("RS256") {
            return Err(invalid("unsupported algorithm"));
        }
        let Some(kid) = field(&header, "kid").and_then(Value::as_str).filter(|k| !k.is_empty()) else { return Err(invalid("missing key id")) };

        let key = self.key_for(kid).await?;
        if !is_base64url(sig) {
            return Err(invalid("malformed token"));
        }
        let message = format!("{head}.{body}");
        if !jsonwebtoken::crypto::verify(sig, message.as_bytes(), &key, Algorithm::RS256).unwrap_or(false) {
            return Err(invalid("bad signature"));
        }

        let now_s = (now_ms(self.clock.as_ref()).div_euclid(1000)) as f64;
        let leeway = self.options.leeway_seconds as f64;
        if field(&claims, "iss").and_then(Value::as_str) != Some(self.options.issuer.as_str()) {
            return Err(invalid("wrong issuer"));
        }
        let audience_ok = match field(&claims, "aud") {
            Some(Value::Array(a)) => a.iter().any(|v| v.as_str().is_some_and(|s| self.options.audiences.iter().any(|x| x == s))),
            Some(Value::String(s)) => self.options.audiences.iter().any(|x| x == s),
            _ => false,
        };
        if !audience_ok {
            return Err(invalid("wrong audience"));
        }
        let Some(exp) = number(field(&claims, "exp")) else { return Err(invalid("missing expiry")) };
        if exp + leeway <= now_s {
            return Err(invalid("token expired"));
        }
        if let Some(nbf) = field(&claims, "nbf") {
            if !nbf.is_number() || nbf.as_f64().is_none_or(|n| n - leeway > now_s) {
                return Err(invalid("token not yet valid"));
            }
        }
        let Some(iat) = number(field(&claims, "iat")) else { return Err(invalid("missing issued-at")) };
        if iat - leeway > now_s {
            return Err(invalid("token issued in the future"));
        }
        let required = |name: &str| text(&claims, name).filter(|s| !s.is_empty()).ok_or_else(|| invalid(&format!("missing claim {name}")));
        Ok(GithubActionsClaims {
            repository: required("repository")?,
            repository_id: required("repository_id")?,
            repository_owner_id: required("repository_owner_id")?,
            workflow_ref: required("workflow_ref")?,
            environment: text(&claims, "environment"),
        })
    }
}

/// `workflow_ref` is `<owner>/<repo>/<path>@<git ref>`: the path, only if it belongs to `repository`.
pub fn workflow_path<'a>(workflow_ref: &'a str, repository: &str) -> Option<&'a str> {
    let head = workflow_ref.rfind('@').map_or(workflow_ref, |at| &workflow_ref[..at]);
    head.strip_prefix(repository)?.strip_prefix('/')
}

/// Matching is on GitHub's numeric ids, never on names: a repository renamed or re-created under the same name
/// does not match.
pub fn matches_trusted_publisher(tp: &TrustedPublisher, c: &GithubActionsClaims) -> bool {
    tp.repository_id == c.repository_id
        && tp.repository_owner_id == c.repository_owner_id
        && workflow_path(&c.workflow_ref, &c.repository) == Some(tp.workflow.as_str())
        && tp.environment.as_ref().is_none_or(|e| c.environment.as_ref() == Some(e))
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct OidcToken {
    /// The secret: shown here and nowhere else.
    pub token: String,
    pub token_kind: &'static str,
    pub expires_at: String,
    pub name: String,
    pub version: String,
}

pub struct OidcExchange<A, J> {
    store: Arc<A>,
    verifier: JwtVerifier<J>,
    clock: Arc<dyn Clock>,
    rng: Arc<dyn Rng>,
}

impl<A: AuthStore, J: JwksSource> OidcExchange<A, J> {
    pub fn new(store: Arc<A>, verifier: JwtVerifier<J>, clock: Arc<dyn Clock>, rng: Arc<dyn Rng>) -> Self {
        OidcExchange { store, verifier, clock, rng }
    }

    /// Verify the CI token, match a trusted publisher of the package, mint a 15 minute token for that package and version.
    pub async fn exchange(&self, jwt: &str, name: &str, version: &str) -> PortResult<OidcToken> {
        if !is_valid_package_name(name) {
            return Err(error(ErrorCode::InvalidName, format!("'{name}' is not a valid package name."), [("name", name)]).into());
        }
        canonical_version(version)?;
        let claims = self.verifier.verify(jwt).await?;
        let trusted = self.store.list_trusted_publishers(name).await?;
        if !trusted.iter().any(|tp| matches_trusted_publisher(tp, &claims)) {
            return Err(error(ErrorCode::OidcNotTrusted, format!("No trusted publisher of '{name}' matches this CI identity."), [("name", name)]).into());
        }
        let now = now_ms(self.clock.as_ref());
        let m = mint_token(
            self.store.as_ref(),
            self.rng.as_ref(),
            TokenFields {
                kind: TokenKind::Oidc,
                github_id: None,
                name: format!("ci {}", claims.repository),
                scopes: vec![TokenScope::Publish],
                packages: vec![name.to_string()],
                all_current: false,
                version: Some(version.to_string()),
                fresh_until: None,
                created_at: iso_at(now),
                expires_at: iso_at(now + OIDC_TOKEN_TTL_MS),
                issued_to: Some(claims.repository),
            },
        )
        .await?;
        Ok(OidcToken { token: m.secret, token_kind: "publish", expires_at: m.record.expires_at, name: name.to_string(), version: version.to_string() })
    }
}
