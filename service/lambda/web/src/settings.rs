//! What a website function learns at cold start (docs/design/tutorial-sign-in.md, section 5): its stage, from
//! Lambda's own `AWS_LAMBDA_FUNCTION_NAME` (`mopm-<stage>-<function>`, a platform-set marker and the only
//! environment variable these functions read), and the stage's settings, the item `stage_settings` of the
//! stage's `config` table, which the stack writes at deploy.
//!
//! The item (key `key`, as every item of that table):
//!
//! ```json
//! { "key": "stage_settings",
//!   "redirect_uri": "https://mopm.dev/api/v2/auth/web/callback",
//!   "site_origin": "https://mopm.dev",
//!   "require_two_factor": true,
//!   "e2b_template_id": "<template id>",
//!   "e2b_domain": "e2b.app",
//!   "sandbox_timeout_seconds": 1800 }
//! ```
//!
//! Every field is required, and an item that breaks a rule below fails the cold start by name: a wrong
//! setting is a deploy mistake, and no function answers with half of it. Fields the item has beyond these are
//! ignored, so a newer stack's item still loads.

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::future::Future;

use mopm_ports::error::{PortError, PortResult};
use serde::Deserialize;
use thiserror::Error;

/// Lambda's variable naming the function.
pub const FUNCTION_NAME_ENV: &str = "AWS_LAMBDA_FUNCTION_NAME";
/// The key of the settings item in the `config` table.
pub const STAGE_SETTINGS_KEY: &str = "stage_settings";

/// Why a function cannot start.
#[derive(Debug, Error)]
pub enum SetupError {
    #[error("{FUNCTION_NAME_ENV} is not set")]
    FunctionNameMissing,
    #[error("{FUNCTION_NAME_ENV} is not valid UTF-8")]
    FunctionNameNotUnicode,
    #[error("{FUNCTION_NAME_ENV} is {0:?}, not mopm-<stage>-<function>")]
    FunctionNameMalformed(String),
    #[error("the config table has no {STAGE_SETTINGS_KEY} item")]
    StageSettingsMissing,
    #[error("the {STAGE_SETTINGS_KEY} item is not valid: {0}")]
    StageSettingsInvalid(String),
    #[error("the secret {0} does not exist")]
    SecretMissing(String),
    #[error("the secret {0} is empty")]
    SecretEmpty(String),
    #[error("reading {what}: {source}")]
    Port {
        what: String,
        #[source]
        source: PortError,
    },
}

/// A stage's name (`beta`, `gamma`, `prod`): lower-case letters and digits.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Stage(String);

impl Stage {
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The id of the stage's secret `name`: `mopm/<stage>/<name>`.
    pub fn secret_id(&self, name: &str) -> String {
        format!("mopm/{}/{name}", self.0)
    }

    /// The name of the stage's table `name`: `mopm-<stage>-<name>`.
    pub fn table(&self, name: &str) -> String {
        format!("mopm-{}-{name}", self.0)
    }
}

/// A function's name, `mopm-<stage>-<function>`, read apart.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FunctionName {
    pub stage: Stage,
    /// `web-login`, `web-session`, `tutorial-sandbox`: lower-case words joined by single hyphens.
    pub function: String,
}

fn is_word(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
}

/// The function name `value` (the variable's value; `None` when it is not set) read as
/// `mopm-<stage>-<function>`: the stage is one word, the function one or more joined by single hyphens.
pub fn parse_function_name(value: Option<&OsStr>) -> Result<FunctionName, SetupError> {
    let raw = value.ok_or(SetupError::FunctionNameMissing)?.to_str().ok_or(SetupError::FunctionNameNotUnicode)?;
    let malformed = || SetupError::FunctionNameMalformed(raw.to_string());
    let (stage, function) = raw.strip_prefix("mopm-").and_then(|rest| rest.split_once('-')).ok_or_else(malformed)?;
    if !is_word(stage) || !function.split('-').all(is_word) {
        return Err(malformed());
    }
    Ok(FunctionName { stage: Stage(stage.to_string()), function: function.to_string() })
}

/// [`parse_function_name`] of this process's `AWS_LAMBDA_FUNCTION_NAME`.
pub fn function_name_from_env() -> Result<FunctionName, SetupError> {
    parse_function_name(std::env::var_os(FUNCTION_NAME_ENV).as_deref())
}

/// The stage's `config` table, by item key. Each item comes back as JSON, its numbers as numbers.
pub trait ConfigTable: Send + Sync {
    fn get_item(&self, key: &str) -> impl Future<Output = PortResult<Option<serde_json::Value>>> + Send;
}

/// A table in memory, for tests.
impl ConfigTable for BTreeMap<String, serde_json::Value> {
    async fn get_item(&self, key: &str) -> PortResult<Option<serde_json::Value>> {
        Ok(self.get(key).cloned())
    }
}

/// The stage's settings (the item above).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct StageSettings {
    /// The `redirect_uri` the sign-in sends GitHub, exactly: under `site_origin`.
    pub redirect_uri: String,
    /// The site's origin, `https://<site>` with no path: the exact `Origin` a `POST` must carry and the base
    /// of the callback's redirect.
    pub site_origin: String,
    /// Whether a GitHub account without two-factor authentication is refused at sign-in.
    pub require_two_factor: bool,
    /// The E2B template the tutorial's sandboxes start from.
    pub e2b_template_id: String,
    /// The base domain of a sandbox's address when E2B's answer has none.
    pub e2b_domain: String,
    /// How long E2B keeps a sandbox, in seconds; more than zero.
    pub sandbox_timeout_seconds: u64,
}

fn is_origin(s: &str) -> bool {
    s.strip_prefix("https://").is_some_and(|host| !host.is_empty() && host.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'.' || b == b'-'))
}

impl StageSettings {
    /// The settings in `item`, checked.
    pub fn from_item(item: serde_json::Value) -> Result<StageSettings, SetupError> {
        let s: StageSettings = serde_json::from_value(item).map_err(|e| SetupError::StageSettingsInvalid(e.to_string()))?;
        let invalid = |why: &str| Err(SetupError::StageSettingsInvalid(why.to_string()));
        if !is_origin(&s.site_origin) {
            return invalid("site_origin is not https:// and a lower-case host");
        }
        if !s.redirect_uri.strip_prefix(&s.site_origin).is_some_and(|path| path.starts_with('/')) {
            return invalid("redirect_uri is not a path under site_origin");
        }
        if s.e2b_template_id.is_empty() || s.e2b_domain.is_empty() {
            return invalid("e2b_template_id and e2b_domain must not be empty");
        }
        if s.sandbox_timeout_seconds == 0 {
            return invalid("sandbox_timeout_seconds must be more than zero");
        }
        Ok(s)
    }

    /// Reads and checks the `stage_settings` item of `table`.
    pub async fn load(table: &impl ConfigTable) -> Result<StageSettings, SetupError> {
        StageSettings::from_lookup(table.get_item(STAGE_SETTINGS_KEY).await)
    }

    /// What [`StageSettings::load`] makes of the table's answer (not generic, so one instantiation covers it).
    fn from_lookup(found: PortResult<Option<serde_json::Value>>) -> Result<StageSettings, SetupError> {
        let item = found.map_err(|source| SetupError::Port { what: format!("the {STAGE_SETTINGS_KEY} item"), source })?.ok_or(SetupError::StageSettingsMissing)?;
        StageSettings::from_item(item)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn os(s: &str) -> Option<&OsStr> {
        Some(OsStr::new(s))
    }

    #[test]
    fn a_function_name_gives_its_stage_and_function() {
        let f = parse_function_name(os("mopm-beta-web-session")).unwrap();
        assert_eq!(f.stage.as_str(), "beta");
        assert_eq!(f.function, "web-session");
        let f = parse_function_name(os("mopm-prod-tutorial-sandbox")).unwrap();
        assert_eq!(f, FunctionName { stage: Stage("prod".to_string()), function: "tutorial-sandbox".to_string() });
        assert_eq!(parse_function_name(os("mopm-gamma2-x")).unwrap().stage.as_str(), "gamma2");
    }

    #[test]
    fn a_stage_names_its_secrets_and_tables() {
        let stage = parse_function_name(os("mopm-beta-web-login")).unwrap().stage;
        assert_eq!(stage.secret_id("edge-origin"), "mopm/beta/edge-origin");
        assert_eq!(stage.table("config"), "mopm-beta-config");
    }

    #[test]
    fn malformed_function_names_are_refused_by_name() {
        for bad in [
            "",
            "mopm",
            "mopm-",
            "mopm-beta",
            "mopm-beta-",
            "mopm--web-login",
            "mopm-Beta-web-login",
            "mopm-beta-web--login",
            "mopm-beta-web-login-",
            "mopm-beta-Web-login",
            "mopm-beta-web_login",
            "other-beta-web-login",
            " mopm-beta-web-login",
        ] {
            let err = parse_function_name(os(bad)).unwrap_err();
            assert_eq!(err.to_string(), format!("AWS_LAMBDA_FUNCTION_NAME is {bad:?}, not mopm-<stage>-<function>"), "{bad:?}");
        }
    }

    #[test]
    fn an_unset_function_name_is_refused() {
        assert_eq!(parse_function_name(None).unwrap_err().to_string(), "AWS_LAMBDA_FUNCTION_NAME is not set");
    }

    #[cfg(unix)]
    #[test]
    fn a_function_name_that_is_not_utf8_is_refused() {
        use std::os::unix::ffi::OsStrExt;
        let err = parse_function_name(Some(OsStr::from_bytes(b"mopm-beta-\xff"))).unwrap_err();
        assert_eq!(err.to_string(), "AWS_LAMBDA_FUNCTION_NAME is not valid UTF-8");
    }

    /// The environment read is the parse of the variable's value: whatever this process has (no test sets it).
    #[test]
    fn the_environment_read_parses_the_lambda_variable() {
        let ours = function_name_from_env().map_err(|e| e.to_string());
        let direct = parse_function_name(std::env::var_os("AWS_LAMBDA_FUNCTION_NAME").as_deref()).map_err(|e| e.to_string());
        assert_eq!(ours, direct);
    }

    fn item() -> serde_json::Value {
        json!({
            "key": "stage_settings",
            "redirect_uri": "https://beta.mopm.dev/api/v2/auth/web/callback",
            "site_origin": "https://beta.mopm.dev",
            "require_two_factor": true,
            "e2b_template_id": "tpl-123",
            "e2b_domain": "e2b.app",
            "sandbox_timeout_seconds": 1800
        })
    }

    fn table(item: Option<serde_json::Value>) -> BTreeMap<String, serde_json::Value> {
        item.into_iter().map(|i| (STAGE_SETTINGS_KEY.to_string(), i)).collect()
    }

    #[tokio::test]
    async fn the_item_loads_into_the_settings() {
        let s = StageSettings::load(&table(Some(item()))).await.unwrap();
        assert_eq!(
            s,
            StageSettings {
                redirect_uri: "https://beta.mopm.dev/api/v2/auth/web/callback".to_string(),
                site_origin: "https://beta.mopm.dev".to_string(),
                require_two_factor: true,
                e2b_template_id: "tpl-123".to_string(),
                e2b_domain: "e2b.app".to_string(),
                sandbox_timeout_seconds: 1800,
            }
        );
    }

    #[tokio::test]
    async fn fields_a_newer_stack_adds_are_ignored() {
        let mut i = item();
        i["a_later_setting"] = json!({"nested": [1, 2]});
        assert_eq!(StageSettings::load(&table(Some(i))).await.unwrap().e2b_domain, "e2b.app");
    }

    #[tokio::test]
    async fn a_missing_item_fails_the_start() {
        assert_eq!(StageSettings::load(&table(None)).await.unwrap_err().to_string(), "the config table has no stage_settings item");
    }

    struct Broken;

    impl ConfigTable for Broken {
        async fn get_item(&self, _: &str) -> PortResult<Option<serde_json::Value>> {
            Err(PortError::fault("throttled"))
        }
    }

    #[tokio::test]
    async fn a_table_that_fails_fails_the_start_naming_the_item() {
        let err = StageSettings::load(&Broken).await.unwrap_err();
        assert_eq!(err.to_string(), "reading the stage_settings item: infrastructure fault: throttled");
        assert!(std::error::Error::source(&err).is_some());
    }

    fn refused(i: serde_json::Value) -> String {
        StageSettings::from_item(i).unwrap_err().to_string()
    }

    #[test]
    fn each_missing_or_mistyped_field_is_refused() {
        for field in ["redirect_uri", "site_origin", "require_two_factor", "e2b_template_id", "e2b_domain", "sandbox_timeout_seconds"] {
            let mut i = item();
            i.as_object_mut().unwrap().remove(field);
            assert_eq!(refused(i), format!("the stage_settings item is not valid: missing field `{field}`"));
        }
        let mut i = item();
        i["require_two_factor"] = json!("true");
        assert!(refused(i).starts_with("the stage_settings item is not valid: invalid type: string \"true\", expected a boolean"));
        let mut i = item();
        i["sandbox_timeout_seconds"] = json!(-1);
        assert!(refused(i).starts_with("the stage_settings item is not valid: invalid value: integer `-1`"));
    }

    #[test]
    fn a_site_origin_that_is_not_https_and_a_bare_lower_case_host_is_refused() {
        for bad in ["http://beta.mopm.dev", "https://", "https://beta.mopm.dev/", "https://Beta.mopm.dev", "https://beta.mopm.dev:443", "beta.mopm.dev"] {
            let mut i = item();
            i["site_origin"] = json!(bad);
            i["redirect_uri"] = json!(format!("{bad}/api/v2/auth/web/callback"));
            assert_eq!(refused(i), "the stage_settings item is not valid: site_origin is not https:// and a lower-case host", "{bad}");
        }
    }

    #[test]
    fn a_redirect_uri_outside_the_site_origin_is_refused() {
        for bad in ["https://api.beta.mopm.dev/api/v2/auth/web/callback", "https://beta.mopm.dev.evil/cb", "https://beta.mopm.dev", "https://beta.mopm.devx/cb"] {
            let mut i = item();
            i["redirect_uri"] = json!(bad);
            assert_eq!(refused(i), "the stage_settings item is not valid: redirect_uri is not a path under site_origin", "{bad}");
        }
    }

    #[test]
    fn empty_e2b_settings_and_a_zero_timeout_are_refused() {
        for field in ["e2b_template_id", "e2b_domain"] {
            let mut i = item();
            i[field] = json!("");
            assert_eq!(refused(i), "the stage_settings item is not valid: e2b_template_id and e2b_domain must not be empty", "{field}");
        }
        let mut i = item();
        i["sandbox_timeout_seconds"] = json!(0);
        assert_eq!(refused(i), "the stage_settings item is not valid: sandbox_timeout_seconds must be more than zero");
        let mut i = item();
        i["sandbox_timeout_seconds"] = json!(1);
        assert_eq!(StageSettings::from_item(i).unwrap().sandbox_timeout_seconds, 1);
    }

    #[test]
    fn a_site_origin_with_digits_and_hyphens_is_an_origin() {
        let mut i = item();
        i["site_origin"] = json!("https://pr-12.beta.mopm.dev");
        i["redirect_uri"] = json!("https://pr-12.beta.mopm.dev/api/v2/auth/web/callback");
        assert_eq!(StageSettings::from_item(i).unwrap().site_origin, "https://pr-12.beta.mopm.dev");
    }
}
