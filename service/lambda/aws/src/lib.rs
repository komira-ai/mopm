//! mopm_aws: the ports on the AWS SDK for Rust: the DynamoDB adapters of the three stores (`dynamo`) and the
//! S3, SQS, CloudFront and Secrets Manager ones (`services`).

pub mod dynamo;
pub mod services;

#[cfg(test)]
mod dynamo_tests;
#[cfg(test)]
mod dynamo_specifics;
#[cfg(test)]
mod services_tests;
