//! The executable only forwards to the library: run as a process with a malformed function name, it exits with a failure
//! and says why on standard output (the log's destination).

use std::process::Command;

#[test]
fn the_executable_exits_with_a_failure_and_logs_a_malformed_function_name() {
    let out = Command::new(env!("CARGO_BIN_EXE_fn_web_session"))
        .env("AWS_LAMBDA_FUNCTION_NAME", "web-session")
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(1));
    let log = String::from_utf8(out.stdout).unwrap();
    assert!(log.contains(r#""error":"cold start: AWS_LAMBDA_FUNCTION_NAME is \"web-session\", not mopm-<stage>-<function>""#), "{log}");
}
