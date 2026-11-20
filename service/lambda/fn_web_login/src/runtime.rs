//! What turns the library into a running Lambda function: the real clock and random source, the stage's `config` table
//! over DynamoDB, the cold start that reads everything the function needs once ([`cold_start`]), the log format, and
//! [`run`], which `main.rs` forwards to.
//!
//! The environment variable the function reads is `AWS_LAMBDA_FUNCTION_NAME` (`mopm-<stage>-<function>`), a
//! platform-set marker that names the stage and so its tables and secrets. The AWS SDK reads its own provider-standard
//! variables (credentials, region, endpoint). Nothing else is configuration from the environment: the redirect URI, the
//! site origin and the two-factor rule are the `stage_settings` item.

use std::fmt;
use std::sync::Arc;

use aws_config::{BehaviorVersion, SdkConfig};
use aws_lambda_events::apigw::ApiGatewayV2httpRequest;
use aws_sdk_dynamodb::error::DisplayErrorContext;
use aws_sdk_dynamodb::types::AttributeValue;
use jiff::Timestamp;
use lambda_runtime::{service_fn, LambdaEvent};
use mopm_aws::dynamo::{AuthTables, DynamoAuthStore, DynamoNamespaceStore, DynamoWebLoginStore};
use mopm_aws::http::HyperHttpClient;
use mopm_aws::services::SecretsManagerReader;
use mopm_ports::env::{Clock, Rng};
use mopm_ports::error::{PortError, PortResult};
use mopm_web::edge::EdgeCheck;
use mopm_web::settings::{
    function_name_from_env, ConfigTable, FunctionName, SetupError, StageSettings,
};
use thiserror::Error;
use tracing_subscriber::fmt::MakeWriter;

use crate::github::GitHubEndpoints;
use crate::login::WebLogin;
use crate::oauth::{OAuthApp, OAuthError};

/// The longest answer read from GitHub (its answers are a few kilobytes).
pub const MAX_RESPONSE_BYTES: usize = 256 * 1024;

/// The wall clock.
#[derive(Clone, Copy, Debug, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> Timestamp {
        Timestamp::now()
    }
}

/// The operating system's random source (`getrandom`).
#[derive(Clone, Copy, Debug, Default)]
pub struct OsRng;

/// Fills `buf` from `source`. A source that fails stops the invocation: no token or secret may be made from bytes that
/// are not random.
fn fill_with(buf: &mut [u8], source: &mut dyn FnMut(&mut [u8]) -> Result<(), getrandom::Error>) {
    if let Err(e) = source(buf) {
        panic!("the operating system's random source failed: {e}");
    }
}

impl Rng for OsRng {
    fn fill(&self, buf: &mut [u8]) {
        fill_with(buf, &mut getrandom::fill);
    }
}

/// The stage's `config` table (`mopm-<stage>-config`), read by item key.
pub struct DynamoConfigTable {
    client: aws_sdk_dynamodb::Client,
    table: String,
}

impl DynamoConfigTable {
    pub fn new(client: aws_sdk_dynamodb::Client, table: String) -> DynamoConfigTable {
        DynamoConfigTable { client, table }
    }
}

impl ConfigTable for DynamoConfigTable {
    async fn get_item(&self, key: &str) -> PortResult<Option<serde_json::Value>> {
        let out = self
            .client
            .get_item()
            .table_name(&self.table)
            .key("key", AttributeValue::S(key.to_string()))
            .send()
            .await
            .map_err(|e| {
                PortError::fault(format!(
                    "dynamodb GetItem on {}: {}",
                    self.table,
                    DisplayErrorContext(e)
                ))
            })?;
        out.item
            .map(|item| {
                serde_dynamo::from_item::<_, serde_json::Value>(item).map_err(PortError::fault)
            })
            .transpose()
    }
}

/// The function as it runs: DynamoDB's stores, GitHub over HTTPS, the wall clock and the OS's randomness.
pub type App = WebLogin<
    DynamoAuthStore,
    DynamoNamespaceStore,
    DynamoWebLoginStore,
    HyperHttpClient,
    SystemClock,
    OsRng,
>;

/// Why the function cannot start. A message names what is wrong and never holds a secret.
#[derive(Debug, Error)]
pub enum StartupError {
    /// The function's name, the `stage_settings` item, or the edge secret.
    #[error(transparent)]
    Setup(#[from] SetupError),
    #[error(transparent)]
    OAuth(#[from] OAuthError),
    #[error("building the HTTPS client: {0}")]
    HttpClient(PortError),
}

/// Reads what the function needs once, at cold start: the stage's settings, the edge secret and the OAuth app, and the
/// system's root certificates for HTTPS to GitHub. Anything missing or invalid fails the start.
pub async fn cold_start(config: &SdkConfig, name: &FunctionName) -> Result<App, StartupError> {
    let http =
        HyperHttpClient::with_native_roots(MAX_RESPONSE_BYTES).map_err(StartupError::HttpClient)?;
    build(
        aws_sdk_dynamodb::Client::new(config),
        SecretsManagerReader::new(aws_sdk_secretsmanager::Client::new(config)),
        name,
        http,
    )
    .await
}

async fn build(
    dynamo: aws_sdk_dynamodb::Client,
    secrets: SecretsManagerReader,
    name: &FunctionName,
    http: HyperHttpClient,
) -> Result<App, StartupError> {
    let stage = &name.stage;
    let settings = StageSettings::load(&DynamoConfigTable::new(
        dynamo.clone(),
        stage.table("config"),
    ))
    .await?;
    let edge = EdgeCheck::load(&secrets, stage).await?;
    let app = OAuthApp::load(&secrets, stage).await?;
    Ok(WebLogin {
        settings,
        edge,
        app,
        github: GitHubEndpoints::production(),
        auth: DynamoAuthStore::new(
            dynamo.clone(),
            AuthTables::for_stage(stage.as_str()),
            Arc::new(SystemClock),
        ),
        namespaces: DynamoNamespaceStore::new(
            dynamo.clone(),
            DynamoNamespaceStore::table_for_stage(stage.as_str()),
        ),
        logins: DynamoWebLoginStore::new(
            dynamo,
            DynamoWebLoginStore::table_for_stage(stage.as_str()),
        ),
        http,
        clock: SystemClock,
        rng: OsRng,
    })
}

/// The log: JSON lines at `INFO`, with no timestamp (Lambda adds one) and no target, to `writer`.
pub fn subscriber<W>(writer: W) -> impl tracing::Subscriber + Send + Sync
where
    W: for<'w> MakeWriter<'w> + Send + Sync + 'static,
{
    tracing_subscriber::fmt()
        .json()
        .with_max_level(tracing::Level::INFO)
        .without_time()
        .with_target(false)
        .with_writer(writer)
        .finish()
}

/// Why [`run`] returned. `Debug` is the message, so that the process's exit prints it as written.
#[derive(Error)]
pub enum RunError {
    #[error("installing the log: {0}")]
    Logging(#[from] tracing::subscriber::SetGlobalDefaultError),
    #[error("the function cannot start: {0}")]
    Startup(#[from] StartupError),
    #[error("the Lambda runtime stopped: {0}")]
    Runtime(String),
}

impl fmt::Debug for RunError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, f)
    }
}

/// Installs the log, starts, and serves invocations until the runtime stops.
pub async fn run() -> Result<(), RunError> {
    tracing::subscriber::set_global_default(subscriber(std::io::stdout))?;
    let name = function_name_from_env().map_err(StartupError::from)?;
    let config = aws_config::load_defaults(BehaviorVersion::latest()).await;
    let app = Arc::new(cold_start(&config, &name).await?);
    let handler = service_fn(move |event: LambdaEvent<ApiGatewayV2httpRequest>| {
        let app = app.clone();
        async move { Ok::<_, std::convert::Infallible>(app.handle_event(event.payload).await) }
    });
    lambda_runtime::run(handler)
        .await
        .map_err(|e| RunError::Runtime(e.to_string()))
}

#[cfg(test)]
#[path = "runtime_tests.rs"]
mod tests;
