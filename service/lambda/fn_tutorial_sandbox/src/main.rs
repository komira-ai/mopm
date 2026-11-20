//! The `tutorial-sandbox` Lambda's executable: it forwards to the library (`fn_tutorial_sandbox::run`).

use fn_tutorial_sandbox::{process_args, run, E2B_API, MAX_BODY_BYTES};
use mopm_aws::http::HyperHttpClient as Https;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), lambda_runtime::Error> {
    let http = Https::with_native_roots(MAX_BODY_BYTES)?;
    run(process_args(), http, E2B_API).await
}
