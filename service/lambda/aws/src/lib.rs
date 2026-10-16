//! mopm_aws: the ports on the AWS SDK for Rust. DynamoDB adapters of the three stores; the S3, SQS,
//! CloudFront and Secrets Manager adapters come in the next change.

pub mod dynamo;

#[cfg(test)]
mod dynamo_tests;
#[cfg(test)]
mod dynamo_specifics;
