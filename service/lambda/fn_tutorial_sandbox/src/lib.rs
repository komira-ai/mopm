//! fn_tutorial_sandbox: the `tutorial-sandbox` Lambda (`docs/design/tutorial-sign-in.md`, sections 4 and 5).
//! `POST /api/v2/tutorial/sandbox` gives a signed-in browser a sandbox on E2B and what it needs to reach it. All the
//! logic is here; `src/main.rs` forwards to [`run`].
//!
//! * [`args`]: the one flag, `--aws-endpoint-url`;
//! * [`start`]: the cold start and the AWS clients;
//! * [`handler`]: the request, [`Function`]: the checks in order, the E2B call, the answer and its one log line;
//! * [`key`]: the E2B key, kept once it has been read;
//! * [`log`]: the log lines;
//! * [`clock`]: the system's time.

pub mod args;
pub mod clock;
pub mod handler;
pub mod key;
pub mod log;
pub mod start;

use std::sync::Arc;

use lambda_runtime::{service_fn, Error, LambdaEvent};
use mopm_ports::http::HttpClient;

pub use args::Options;
pub use handler::Function;
pub use start::{start, Endpoints, Env, Parts, StartError};

/// The largest answer body the HTTPS client reads: E2B's answers are small.
pub const MAX_BODY_BYTES: usize = 64 * 1024;

/// E2B's API, the base of the create call.
pub use mopm_e2b::E2B_API;

/// The arguments of this process after the program's name.
pub fn process_args() -> Vec<String> {
    std::env::args().skip(1).collect()
}

/// The function: parses `args` (the arguments after the program's name), starts, and serves Lambda invocations until
/// the runtime stops them. `http` is the outbound client and `e2b_api` is E2B's base URL.
pub async fn run<H: HttpClient>(args: Vec<String>, http: H, e2b_api: &str) -> Result<(), Error> {
    let options = Options::parse(args)?;
    let parts = Parts {
        http,
        e2b_api: e2b_api.to_string(),
        clock: Arc::new(clock::SystemClock),
        sink: log::stdout_sink(),
    };
    let function = start(&Env::from_process(), &Endpoints::from(&options), parts).await?;
    let function = &function;
    lambda_runtime::run(service_fn(
        |event: LambdaEvent<aws_lambda_events::apigw::ApiGatewayV2httpRequest>| async move {
            Ok::<_, Error>(function.invoke(event.payload).await)
        },
    ))
    .await
}

#[cfg(test)]
mod handler_tests;
#[cfg(test)]
mod start_tests;
#[cfg(test)]
mod test_support;
#[cfg(test)]
mod unavailable_tests;
