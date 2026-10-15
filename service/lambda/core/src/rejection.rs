//! The contract's catalogue of reasons a publish is rejected (spec/api/openapi.yaml `RejectionCode`):
//! what a client sees in `PublishStatus.rejection_code`. The finer rule codes of the validator map
//! onto these and come with the validator.

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RejectionCode {
    ArchiveInvalid,
    PathNotAllowed,
    LimitExceeded,
    ManifestInvalid,
    FilenameMismatch,
    Sha256Mismatch,
    DependencyNotAllowed,
}

impl RejectionCode {
    pub const ALL: [RejectionCode; 7] = [
        RejectionCode::ArchiveInvalid,
        RejectionCode::PathNotAllowed,
        RejectionCode::LimitExceeded,
        RejectionCode::ManifestInvalid,
        RejectionCode::FilenameMismatch,
        RejectionCode::Sha256Mismatch,
        RejectionCode::DependencyNotAllowed,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            RejectionCode::ArchiveInvalid => "archive_invalid",
            RejectionCode::PathNotAllowed => "path_not_allowed",
            RejectionCode::LimitExceeded => "limit_exceeded",
            RejectionCode::ManifestInvalid => "manifest_invalid",
            RejectionCode::FilenameMismatch => "filename_mismatch",
            RejectionCode::Sha256Mismatch => "sha256_mismatch",
            RejectionCode::DependencyNotAllowed => "dependency_not_allowed",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serde_spells_each_code_as_the_contract_does() {
        for c in RejectionCode::ALL {
            assert_eq!(serde_json::to_string(&c).unwrap(), format!("\"{}\"", c.as_str()));
            assert_eq!(serde_json::from_str::<RejectionCode>(&format!("\"{}\"", c.as_str())).unwrap(), c);
        }
        assert!(serde_json::from_str::<RejectionCode>("\"nope\"").is_err());
    }

    #[test]
    fn the_codes_are_the_typescript_registrys() {
        // service/api/src/validate/codes.ts RejectionCode.
        let ts = ["archive_invalid", "path_not_allowed", "limit_exceeded", "manifest_invalid", "filename_mismatch", "sha256_mismatch", "dependency_not_allowed"];
        assert_eq!(RejectionCode::ALL.map(RejectionCode::as_str), ts);
    }
}
