//! The canary Lambda: an API Gateway v2 handler on the runtime and event crates the
//! registry's functions will use (lambda_runtime, aws_lambda_events). It answers every
//! request with a JSON body that echoes the `name` query parameter (default "world")
//! and the raw path. It exists to hold the build: `e2e_test.zig` runs the built
//! binary against a fake Lambda runtime API and compares what it answers byte for byte.

use aws_lambda_events::apigw::{ApiGatewayV2httpRequest, ApiGatewayV2httpResponse};
use aws_lambda_events::encodings::Body;
use aws_lambda_events::http::{header, HeaderValue};
use lambda_runtime::{run, service_fn, Error, LambdaEvent};

async fn handler(event: LambdaEvent<ApiGatewayV2httpRequest>) -> Result<ApiGatewayV2httpResponse, Error> {
    let request = event.payload;
    let name = request.query_string_parameters.first("name").unwrap_or("world");
    let body = serde_json::json!({
        "hello": name,
        "path": request.raw_path.as_deref().unwrap_or(""),
    })
    .to_string();
    // The response type is non_exhaustive: a default, then its public fields.
    let mut response = ApiGatewayV2httpResponse::default();
    response.status_code = 200;
    response.headers.insert(header::CONTENT_TYPE, HeaderValue::from_static("application/json"));
    response.body = Some(Body::Text(body));
    Ok(response)
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Error> {
    tracing_subscriber::fmt().json().with_max_level(tracing::Level::INFO).without_time().init();
    run(service_fn(handler)).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use lambda_runtime::Context;

    fn request(query: &str) -> ApiGatewayV2httpRequest {
        serde_json::from_value(serde_json::json!({
            "version": "2.0",
            "routeKey": "GET /hello",
            "rawPath": "/hello",
            "rawQueryString": query,
            "headers": {"host": "api.example"},
            "queryStringParameters": if query.is_empty() { serde_json::json!({}) } else { serde_json::json!({"name": "komira"}) },
            "requestContext": {
                "accountId": "example",
                "apiId": "api",
                "domainName": "api.example",
                "http": {"method": "GET", "path": "/hello", "protocol": "HTTP/1.1", "sourceIp": "0.0.0.0", "userAgent": "test"},
                "requestId": "id",
                "routeKey": "GET /hello",
                "stage": "$default",
                "time": "01/Jan/2026:00:00:00 +0000",
                "timeEpoch": 1767225600000_i64
            },
            "isBase64Encoded": false
        }))
        .unwrap()
    }

    async fn answer(query: &str) -> String {
        let response = handler(LambdaEvent::new(request(query), Context::default())).await.unwrap();
        serde_json::to_string(&response).unwrap()
    }

    #[tokio::test]
    async fn echoes_the_name_parameter_and_the_path() {
        assert_eq!(
            answer("name=komira").await,
            r#"{"statusCode":200,"headers":{"content-type":"application/json"},"multiValueHeaders":{},"body":"{\"hello\":\"komira\",\"path\":\"/hello\"}","isBase64Encoded":false,"cookies":[]}"#
        );
    }

    #[tokio::test]
    async fn defaults_the_name_to_world() {
        let text = answer("").await;
        assert!(text.contains(r#"{\"hello\":\"world\",\"path\":\"/hello\"}"#), "{text}");
    }
}
