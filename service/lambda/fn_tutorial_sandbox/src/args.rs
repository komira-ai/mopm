//! The command line: one optional flag, `--aws-endpoint-url <url>`, which points the DynamoDB and Secrets Manager
//! clients at one endpoint (the end-to-end test's loopback server). Lambda starts the function without arguments.
//! Anything else fails the start: a flag the function does not know is a deploy mistake, not something to ignore.

use thiserror::Error;

/// The flag that points the AWS clients at one endpoint.
pub const AWS_ENDPOINT_FLAG: &str = "--aws-endpoint-url";

/// What the command line set.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Options {
    /// `--aws-endpoint-url`: the endpoint of both AWS clients; `None` leaves the SDK's own endpoints.
    pub aws_endpoint_url: Option<String>,
}

/// An argument the function does not take.
#[derive(Clone, Debug, PartialEq, Eq, Error)]
pub enum ArgsError {
    /// A flag other than `--aws-endpoint-url`, or a bare word.
    #[error("unknown argument {0:?}; the only flag is --aws-endpoint-url <url>")]
    Unknown(String),
    /// `--aws-endpoint-url` as the last argument.
    #[error("--aws-endpoint-url needs a value")]
    MissingValue,
    /// `--aws-endpoint-url` twice.
    #[error("--aws-endpoint-url is given twice")]
    Repeated,
}

impl Options {
    /// The options of the arguments after the program's name.
    pub fn parse(args: impl IntoIterator<Item = String>) -> Result<Options, ArgsError> {
        let mut options = Options::default();
        let mut args = args.into_iter();
        while let Some(arg) = args.next() {
            if arg != AWS_ENDPOINT_FLAG {
                return Err(ArgsError::Unknown(arg));
            }
            let value = args.next().ok_or(ArgsError::MissingValue)?;
            if options.aws_endpoint_url.replace(value).is_some() {
                return Err(ArgsError::Repeated);
            }
        }
        Ok(options)
    }
}
