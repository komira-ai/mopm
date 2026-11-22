//! A function name that is not `mopm-<stage>-<function>` ends the process entry with a failure before it makes a
//! client or polls the runtime API. The only test of this file: it sets the process's environment.

use std::net::TcpListener;
use std::process::ExitCode;

#[test]
fn a_malformed_function_name_fails_the_entry_without_a_poll_of_the_runtime_api() {
    let runtime_api = TcpListener::bind("127.0.0.1:0").unwrap();
    std::env::set_var(
        "AWS_LAMBDA_RUNTIME_API",
        runtime_api.local_addr().unwrap().to_string(),
    );
    std::env::set_var("AWS_LAMBDA_FUNCTION_NAME", "web-session");

    let exit = fn_web_session::runtime::main();

    assert!(exit == ExitCode::FAILURE);
    // A connection to the listener would be waiting in its backlog: there is none.
    runtime_api.set_nonblocking(true).unwrap();
    let accepted = runtime_api.accept();
    assert_eq!(
        accepted.err().map(|e| e.kind()),
        Some(std::io::ErrorKind::WouldBlock)
    );
}
