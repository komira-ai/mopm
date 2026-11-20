//! The executable only forwards to the library (`fn_web_session::runtime`).

fn main() -> std::process::ExitCode {
    fn_web_session::runtime::main()
}
