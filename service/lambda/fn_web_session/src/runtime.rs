//! The function as a process: reads its name, builds the AWS clients, runs the cold start and serves
//! API Gateway's events through `lambda_runtime`.
//!
//! The one environment variable this reads is Lambda's own `AWS_LAMBDA_FUNCTION_NAME` (the stage comes from it). The
//! SDK's configuration (`aws_config::load_defaults`) honours the provider-standard variables: `AWS_REGION`, the
//! `AWS_*` credentials, and `AWS_ENDPOINT_URL` or a service's `AWS_ENDPOINT_URL_<SERVICE>`; `lambda_runtime` reads
//! `AWS_LAMBDA_RUNTIME_API`. A cold start that fails is logged, by name, and the process exits with a failure: the
//! platform then reports the function as failed instead of answering with half of a setup.

use std::process::ExitCode;
use std::sync::Arc;

use aws_config::BehaviorVersion;
use lambda_runtime::{run, service_fn, LambdaEvent};
use mopm_aws::dynamo::{AuthTables, DynamoAuthStore, DynamoConfigTable};
use mopm_aws::services::SecretsManagerReader;
use mopm_web::settings::{function_name_from_env, SetupError};
use thiserror::Error;

use crate::clock::SystemClock;
use crate::startup::cold_start;

/// Why the process ends.
#[derive(Debug, Error)]
pub enum RunError {
    #[error("cold start: {0}")]
    Setup(#[from] SetupError),
    /// `lambda_runtime` returned: Lambda's loop does not end, so this is the runtime API being unreachable or answering
    /// something the runtime cannot use. The value is what `run` returned, as text.
    #[error("the Lambda runtime stopped: {0}")]
    Runtime(String),
}

/// The cold start, then the runtime's loop: what `run` returned, or the setup that failed.
async fn start() -> Result<Result<(), lambda_runtime::Error>, SetupError> {
    let name = function_name_from_env()?;
    let sdk = aws_config::load_defaults(BehaviorVersion::latest()).await;
    let dynamo = aws_sdk_dynamodb::Client::new(&sdk);
    let secrets = SecretsManagerReader::new(aws_sdk_secretsmanager::Client::new(&sdk));
    let config = DynamoConfigTable::new(dynamo.clone(), name.stage.table("config"));
    let store = DynamoAuthStore::new(
        dynamo,
        AuthTables::for_stage(name.stage.as_str()),
        Arc::new(SystemClock),
    );
    let handler = Arc::new(cold_start(&name, &config, &secrets, store, SystemClock).await?);
    tracing::info!(
        function = name.function.as_str(),
        stage = name.stage.as_str(),
        "started"
    );
    let service = service_fn(
        |event: LambdaEvent<aws_lambda_events::apigw::ApiGatewayV2httpRequest>| {
            let handler = handler.clone();
            async move { Ok::<_, std::convert::Infallible>(handler.handle_event(event.payload).await) }
        },
    );
    Ok(run(service).await)
}

/// Starts the function and serves until something ends it: the setup that failed, or the runtime's loop returning.
pub async fn serve() -> RunError {
    match start().await {
        Ok(ended) => RunError::Runtime(format!("{ended:?}")),
        Err(setup) => RunError::Setup(setup),
    }
}

/// The process's entry (`src/main.rs` calls it and nothing else): logs as JSON lines and serves. Lambda's loop does not
/// end, so whatever ends [`serve`] is a failure of the process, with the reason in the log.
#[tokio::main(flavor = "current_thread")]
pub async fn main() -> ExitCode {
    // A second initialisation (a test process that ran this twice) keeps the first subscriber.
    let _ = tracing_subscriber::fmt()
        .json()
        .with_max_level(tracing::Level::INFO)
        .without_time()
        .try_init();
    let error = serve().await;
    tracing::error!(%error, "the function stopped");
    ExitCode::FAILURE
}
