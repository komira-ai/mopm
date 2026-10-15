//! sdk_probe: the official AWS SDK for Rust (aws-config, DynamoDB, S3) with HTTPS on rustls over
//! AWS-LC, built by Buck2. With an endpoint argument it does one GetItem against it; without,
//! it builds the clients the way a Lambda would, from the environment, and says so.

mod probe;

#[tokio::main(flavor = "current_thread")]
async fn main() {
    if let Some(endpoint) = std::env::args().nth(1) {
        let client = probe::client(&endpoint);
        match probe::get_title(&client, "spike", "k1").await {
            Ok(title) => println!("title: {title:?}"),
            Err(e) => {
                eprintln!("GetItem failed: {e}");
                std::process::exit(1);
            }
        }
        return;
    }
    let config = aws_config::defaults(aws_config::BehaviorVersion::latest())
        .region("us-east-1")
        .load()
        .await;
    let dynamodb = aws_sdk_dynamodb::Client::new(&config);
    let s3 = aws_sdk_s3::Client::new(&config);
    println!(
        "clients built: dynamodb in {:?}, s3 in {:?}",
        dynamodb.config().region().map(|r| r.as_ref()),
        s3.config().region().map(|r| r.as_ref()),
    );
}
