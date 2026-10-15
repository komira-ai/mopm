//! Hello-world API Gateway v2 handler: answers every request with a JSON body that echoes
//! the `name` query parameter (default "world") and the raw path. The spike's e2e test
//! (../fake_runtime) holds this output byte for byte.

use lambda_http::{run, service_fn, Body, Error, Request, RequestExt, Response};

async fn handler(event: Request) -> Result<Response<Body>, Error> {
    let name = event
        .query_string_parameters_ref()
        .and_then(|q| q.first("name"))
        .unwrap_or("world");
    let body = serde_json::json!({
        "hello": name,
        "path": event.raw_http_path(),
    })
    .to_string();
    let response = Response::builder()
        .status(200)
        .header("content-type", "application/json")
        .body(Body::Text(body))?;
    Ok(response)
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Error> {
    run(service_fn(handler)).await
}
