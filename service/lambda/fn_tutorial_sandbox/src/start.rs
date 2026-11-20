//! The cold start: what the function reads before it answers anything, and the clients it builds.
//!
//! 1. the stage, from `AWS_LAMBDA_FUNCTION_NAME` (`mopm-<stage>-<function>`);
//! 2. the stage's settings, the item `stage_settings` of `mopm-<stage>-config`;
//! 3. the edge secret `mopm/<stage>/edge-origin`;
//! 4. the E2B key `mopm/<stage>/e2b`, once ([`KeyCache`]).
//!
//! A failure of 1 to 3 fails the start, and nothing answers; so does a `sandbox_timeout_s` above `u32::MAX` (the type of E2B's
//! `timeout`), a wrong setting like any other, whether or not the stage names a template. A key that is not there does not
//! fail the start (see [`crate::key`]).
//!
//! The AWS clients are built without `aws-config`: the region from `AWS_REGION` and static credentials from
//! `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and, when there is one, `AWS_SESSION_TOKEN`; Lambda sets all of them.
//! The SDK's retries are off: a failed read is `tutorial_unavailable` or `internal_error` for that request, and a
//! failed cold start is run again by Lambda. Where they send requests is [`Endpoints`] (`--aws-endpoint-url` sets both). No
//! other environment variable is read.

use std::ffi::OsString;
use std::sync::Arc;

use aws_sdk_dynamodb::config::BehaviorVersion;
use mopm_aws::dynamo::{AuthTables, DynamoAuthStore, DynamoConfigTable};
use mopm_aws::services::SecretsManagerReader;
use mopm_e2b::Settings;
use mopm_ports::env::Clock;
use mopm_ports::http::HttpClient;
use mopm_web::csrf::CsrfCheck;
use mopm_web::edge::EdgeCheck;
use mopm_web::settings::{parse_function_name, SetupError, StageSettings, FUNCTION_NAME_ENV};
use mopm_web::SessionAuth;
use thiserror::Error;

use crate::args::{ArgsError, Options};
use crate::clock::SharedClock;
use crate::handler::Function;
use crate::key::KeyCache;
use crate::log::Sink;

/// The name of the E2B secret under `mopm/<stage>/`.
pub const E2B_SECRET: &str = "e2b";

/// Why the function did not start.
#[derive(Debug, Error)]
pub enum StartError {
    /// The command line.
    #[error("{0}")]
    Args(#[from] ArgsError),
    /// The stage or its settings or the edge secret (by name, from `mopm_web`).
    #[error("{0}")]
    Setup(#[from] SetupError),
    /// An environment variable the AWS clients need is not set.
    #[error("{0} is not set")]
    MissingEnv(&'static str),
    /// The stage's sandbox timeout is more seconds than E2B's create call takes (a `u32`).
    #[error("the stage_settings item is not valid: sandbox_timeout_s {0} is more than {max} seconds", max = u32::MAX)]
    TimeoutTooLong(u64),
}

/// The environment variables the function reads, as the process has them.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Env {
    /// `AWS_LAMBDA_FUNCTION_NAME`.
    pub function_name: Option<OsString>,
    /// `AWS_REGION`.
    pub region: Option<String>,
    /// `AWS_ACCESS_KEY_ID`.
    pub access_key_id: Option<String>,
    /// `AWS_SECRET_ACCESS_KEY`.
    pub secret_access_key: Option<String>,
    /// `AWS_SESSION_TOKEN`.
    pub session_token: Option<String>,
}

impl Env {
    /// The process's own environment.
    pub fn from_process() -> Env {
        let var = |name: &str| std::env::var(name).ok();
        Env {
            function_name: std::env::var_os(FUNCTION_NAME_ENV),
            region: var("AWS_REGION"),
            access_key_id: var("AWS_ACCESS_KEY_ID"),
            secret_access_key: var("AWS_SECRET_ACCESS_KEY"),
            session_token: var("AWS_SESSION_TOKEN"),
        }
    }
}

/// What `main` supplies: the parts that differ between the Lambda and a test.
pub struct Parts<H> {
    /// The outbound HTTPS client (the one to E2B).
    pub http: H,
    /// E2B's API base, [`mopm_e2b::E2B_API`] in the function.
    pub e2b_api: String,
    /// The clock.
    pub clock: Arc<dyn Clock>,
    /// Where the log lines go.
    pub sink: Sink,
}

/// Where the two AWS clients send their requests; `None` leaves the SDK's own endpoint.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Endpoints {
    /// DynamoDB's.
    pub dynamodb: Option<String>,
    /// Secrets Manager's.
    pub secrets: Option<String>,
}

impl From<&Options> for Endpoints {
    /// `--aws-endpoint-url` points both clients at one endpoint.
    fn from(options: &Options) -> Endpoints {
        Endpoints {
            dynamodb: options.aws_endpoint_url.clone(),
            secrets: options.aws_endpoint_url.clone(),
        }
    }
}

/// The two AWS clients' shared settings.
struct Aws {
    region: String,
    access_key_id: String,
    secret_access_key: String,
    session_token: Option<String>,
}

impl Aws {
    fn new(env: &Env) -> Result<Aws, StartError> {
        let need = |value: &Option<String>, name: &'static str| {
            value.clone().ok_or(StartError::MissingEnv(name))
        };
        Ok(Aws {
            region: need(&env.region, "AWS_REGION")?,
            access_key_id: need(&env.access_key_id, "AWS_ACCESS_KEY_ID")?,
            secret_access_key: need(&env.secret_access_key, "AWS_SECRET_ACCESS_KEY")?,
            session_token: env.session_token.clone(),
        })
    }
}

// One macro for the two SDK crates: each has its own `Config`, `Credentials` and `Region` types.
macro_rules! client {
    ($sdk:ident, $aws:expr, $endpoint:expr) => {{
        use $sdk::config::{retry::RetryConfig, Credentials, Region};
        let credentials = Credentials::new(
            &$aws.access_key_id,
            &$aws.secret_access_key,
            $aws.session_token.clone(),
            None,
            "environment",
        );
        let mut config = $sdk::Config::builder()
            .behavior_version(BehaviorVersion::latest())
            .region(Region::new($aws.region.clone()))
            .credentials_provider(credentials)
            .retry_config(RetryConfig::disabled());
        config.set_endpoint_url($endpoint.clone());
        $sdk::Client::from_conf(config.build())
    }};
}

/// The cold start: reads what the function needs and builds it.
pub async fn start<H: HttpClient>(
    env: &Env,
    endpoints: &Endpoints,
    parts: Parts<H>,
) -> Result<Function<DynamoAuthStore, H, SecretsManagerReader>, StartError> {
    let name = parse_function_name(env.function_name.as_deref())?;
    let stage = name.stage;
    let aws = Aws::new(env)?;
    let dynamo = client!(aws_sdk_dynamodb, aws, endpoints.dynamodb);
    let secrets =
        SecretsManagerReader::new(client!(aws_sdk_secretsmanager, aws, endpoints.secrets));

    let settings = StageSettings::load(&DynamoConfigTable::new(
        dynamo.clone(),
        stage.table("config"),
    ))
    .await?;
    let edge = EdgeCheck::load(&secrets, &stage).await?;
    let clock = SharedClock(parts.clock);
    let store = DynamoAuthStore::new(
        dynamo,
        AuthTables::for_stage(stage.as_str()),
        Arc::new(clock.clone()),
    );
    let key = KeyCache::new(stage.secret_id(E2B_SECRET));
    // The key is read once now. Whatever the result, the function starts: only a key that is there is kept.
    let _ = key.get(&secrets).await;

    let timeout_s = u32::try_from(settings.sandbox_timeout_seconds)
        .map_err(|_| StartError::TimeoutTooLong(settings.sandbox_timeout_seconds))?;
    let e2b = settings.e2b_template_id.map(|template_id| Settings {
        api_base: parts.e2b_api,
        stage: stage.as_str().to_string(),
        template_id,
        timeout_s,
        e2b_domain: settings.e2b_domain,
    });
    Ok(Function {
        auth: SessionAuth::new(
            edge,
            CsrfCheck::new(&settings.site_origin),
            store,
            clock.clone(),
        ),
        http: parts.http,
        secrets,
        key,
        e2b,
        clock,
        sink: parts.sink,
    })
}
