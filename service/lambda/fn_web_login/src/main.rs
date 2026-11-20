//! The Lambda executable: everything is in the library.

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), fn_web_login::RunError> {
    fn_web_login::run().await
}
