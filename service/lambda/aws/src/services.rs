//! The S3, SQS, CloudFront and Secrets Manager adapters (`publish/aws.ts`, `http/oauth-secret.ts`), on the
//! official SDK. The TypeScript versions sign by hand over `fetch`; here nothing signs a request but the SDK.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use aws_sdk_cloudfront::types::{InvalidationBatch, Paths};
use aws_sdk_s3::error::SdkError;
use aws_sdk_s3::presigning::PresigningConfig;
use aws_sdk_s3::primitives::ByteStream;
use base64::engine::general_purpose::STANDARD;
use base64::Engine as _;
use mopm_ports::env::Clock;
use mopm_ports::error::{PortError, PortResult};
use mopm_ports::publish::{Invalidator, ObjectInfo, ObjectStore, PresignRequest, PresignedPut, Presigner, PutOptions, PutOutcome, Queue, QueueMessage};
use mopm_ports::secrets::SecretReader;
use sha2::{Digest, Sha256};

use crate::dynamo::fault;

/// The HTTP status of a failed call, when the service answered.
fn status_of<E>(e: &SdkError<E, aws_sdk_s3::config::http::HttpResponse>) -> Option<u16> {
    e.raw_response().map(|r| r.status().as_u16())
}

// ---- S3 ---------------------------------------------------------------------------------------------------

/// The channel bucket.
pub struct S3Channel {
    client: aws_sdk_s3::Client,
    bucket: String,
}

impl S3Channel {
    pub fn new(client: aws_sdk_s3::Client, bucket: impl Into<String>) -> Self {
        S3Channel { client, bucket: bucket.into() }
    }
}

/// Without `s3:ListBucket` a missing key answers 403, so 403 and 404 both mean "not there" for a read.
fn absent(status: Option<u16>) -> bool {
    matches!(status, Some(403 | 404))
}

impl ObjectStore for S3Channel {
    async fn head(&self, key: &str) -> PortResult<Option<ObjectInfo>> {
        match self.client.head_object().bucket(&self.bucket).key(key).send().await {
            Ok(o) => Ok(Some(ObjectInfo { size: u64::try_from(o.content_length().unwrap_or(0)).unwrap_or(0) })),
            Err(e) if absent(status_of(&e)) => Ok(None),
            Err(e) => Err(fault(&format!("s3 HEAD {key}"), e)),
        }
    }

    async fn get(&self, key: &str) -> PortResult<Option<Vec<u8>>> {
        match self.client.get_object().bucket(&self.bucket).key(key).send().await {
            Ok(o) => {
                let bytes = o.body.collect().await.map_err(|e| PortError::fault(format!("s3 GET {key}: {e}")))?;
                Ok(Some(bytes.to_vec()))
            }
            Err(e) if absent(status_of(&e)) => Ok(None),
            Err(e) => Err(fault(&format!("s3 GET {key}"), e)),
        }
    }

    async fn put(&self, key: &str, body: &[u8], opts: &PutOptions) -> PortResult<PutOutcome> {
        let mut put = self
            .client
            .put_object()
            .bucket(&self.bucket)
            .key(key)
            .body(ByteStream::from(body.to_vec()))
            .content_type(&opts.content_type)
            .checksum_sha256(STANDARD.encode(Sha256::digest(body)));
        if let Some(cc) = &opts.cache_control {
            put = put.cache_control(cc);
        }
        if opts.create_only {
            put = put.if_none_match("*");
        }
        match put.send().await {
            Ok(_) => Ok(PutOutcome::Created),
            Err(e) if status_of(&e) == Some(412) => Ok(PutOutcome::Exists),
            Err(e) => Err(fault(&format!("s3 PUT {key}"), e)),
        }
    }

    async fn delete(&self, key: &str) -> PortResult<()> {
        match self.client.delete_object().bucket(&self.bucket).key(key).send().await {
            Ok(_) => Ok(()),
            Err(e) if status_of(&e) == Some(404) => Ok(()),
            Err(e) => Err(fault(&format!("s3 DELETE {key}"), e)),
        }
    }
}

/// A presigned PUT pinned to one exact Content-Length and one sha256: both headers are part of the
/// signature, so S3 itself refuses any other bytes (a wrong length is a signature mismatch; a wrong body is
/// `BadDigest`). The URL is signed with the credentials of the client and works for as long as they do.
pub struct S3Presigner {
    client: aws_sdk_s3::Client,
    bucket: String,
    clock: Arc<dyn Clock>,
}

impl S3Presigner {
    pub fn new(client: aws_sdk_s3::Client, bucket: impl Into<String>, clock: Arc<dyn Clock>) -> Self {
        S3Presigner { client, bucket: bucket.into(), clock }
    }
}

impl Presigner for S3Presigner {
    async fn presign_put(&self, key: &str, req: &PresignRequest<'_>) -> PortResult<PresignedPut> {
        let digest = hex::decode(req.sha256).map_err(|e| PortError::fault(format!("sha256 is not hex: {e}")))?;
        let size = i64::try_from(req.size).map_err(|_| PortError::fault("size does not fit"))?;
        let config = PresigningConfig::builder()
            .start_time(self.clock.now().into())
            .expires_in(Duration::from_secs(req.expires_in_seconds))
            .build()
            .map_err(PortError::fault)?;
        let presigned = self
            .client
            .put_object()
            .bucket(&self.bucket)
            .key(key)
            .content_length(size)
            .checksum_sha256(STANDARD.encode(digest))
            .presigned(config)
            .await
            .map_err(|e| fault("s3 presign", e))?;
        let headers: BTreeMap<String, String> = presigned.headers().map(|(k, v)| (k.to_ascii_lowercase(), v.to_string())).collect();
        Ok(PresignedPut { url: presigned.uri().to_string(), headers })
    }
}

// ---- SQS --------------------------------------------------------------------------------------------------

/// `SendMessage` to one FIFO queue.
pub struct SqsFifoQueue {
    client: aws_sdk_sqs::Client,
    queue_url: String,
}

impl SqsFifoQueue {
    pub fn new(client: aws_sdk_sqs::Client, queue_url: impl Into<String>) -> Self {
        SqsFifoQueue { client, queue_url: queue_url.into() }
    }
}

impl Queue for SqsFifoQueue {
    async fn send(&self, m: &QueueMessage) -> PortResult<()> {
        self.client
            .send_message()
            .queue_url(&self.queue_url)
            .message_body(&m.body)
            .message_group_id(&m.group_id)
            .message_deduplication_id(&m.dedup_id)
            .send()
            .await
            .map(|_| ())
            .map_err(|e| fault("sqs SendMessage", e))
    }
}

// ---- CloudFront -------------------------------------------------------------------------------------------

/// `CreateInvalidation` on one distribution. The caller reference makes a repeat of the same batch harmless.
pub struct CloudFrontInvalidator {
    client: aws_sdk_cloudfront::Client,
    distribution_id: String,
}

impl CloudFrontInvalidator {
    pub fn new(client: aws_sdk_cloudfront::Client, distribution_id: impl Into<String>) -> Self {
        CloudFrontInvalidator { client, distribution_id: distribution_id.into() }
    }
}

impl Invalidator for CloudFrontInvalidator {
    async fn invalidate(&self, paths: &[String], reference: &str) -> PortResult<()> {
        let quantity = i32::try_from(paths.len()).map_err(|_| PortError::fault("too many paths"))?;
        let batch = InvalidationBatch::builder()
            .paths(Paths::builder().quantity(quantity).set_items(Some(paths.to_vec())).build().map_err(PortError::fault)?)
            .caller_reference(reference)
            .build()
            .map_err(PortError::fault)?;
        self.client
            .create_invalidation()
            .distribution_id(&self.distribution_id)
            .invalidation_batch(batch)
            .send()
            .await
            .map(|_| ())
            .map_err(|e| fault("cloudfront CreateInvalidation", e))
    }
}

// ---- Secrets Manager --------------------------------------------------------------------------------------

/// `GetSecretValue`; `None` when the secret does not exist.
pub struct SecretsManagerReader {
    client: aws_sdk_secretsmanager::Client,
}

impl SecretsManagerReader {
    pub fn new(client: aws_sdk_secretsmanager::Client) -> Self {
        SecretsManagerReader { client }
    }
}

impl SecretReader for SecretsManagerReader {
    async fn read(&self, secret_id: &str) -> PortResult<Option<String>> {
        match self.client.get_secret_value().secret_id(secret_id).send().await {
            Ok(o) => Ok(o.secret_string().map(str::to_string)),
            Err(e) if e.as_service_error().is_some_and(|s| s.is_resource_not_found_exception()) => Ok(None),
            Err(e) => Err(fault("secretsmanager GetSecretValue", e)),
        }
    }
}
