//! Verdict codes of the package validator (`validate/codes.ts`). [`RejectionCode`](mopm_core::rejection::RejectionCode) is
//! the contract's catalogue: what a client sees in `PublishStatus.rejection_code`. [`RuleCode`] is finer and also
//! stable: the exact rule that fired, for logs, the `message` and tests. Every rule maps to exactly one rejection code.

use mopm_core::rejection::RejectionCode;

macro_rules! rules {
    ($($variant:ident => ($text:literal, $rejection:ident)),+ $(,)?) => {
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
        pub enum RuleCode { $($variant),+ }

        impl RuleCode {
            pub const ALL: &'static [RuleCode] = &[$(RuleCode::$variant),+];

            pub const fn as_str(self) -> &'static str {
                match self { $(RuleCode::$variant => $text),+ }
            }

            pub const fn rejection(self) -> RejectionCode {
                match self { $(RuleCode::$variant => RejectionCode::$rejection),+ }
            }

            pub fn parse(s: &str) -> Option<RuleCode> {
                match s { $($text => Some(RuleCode::$variant),)+ _ => None }
            }
        }
    };
}

rules! {
    // archive_invalid: not a package archive we can read
    NotAnArchive => ("not_an_archive", ArchiveInvalid),
    ArchiveCorrupt => ("archive_corrupt", ArchiveInvalid),
    FormatNotAllowed => ("format_not_allowed", ArchiveInvalid),
    CondaLayout => ("conda_layout", ArchiveInvalid),
    TarHeader => ("tar_header", ArchiveInvalid),
    MojocMissing => ("mojoc_missing", ArchiveInvalid),
    // path_not_allowed: a path or entry type the registry never accepts
    PathAbsolute => ("path_absolute", PathNotAllowed),
    PathTraversal => ("path_traversal", PathNotAllowed),
    PathUnsafe => ("path_unsafe", PathNotAllowed),
    Symlink => ("symlink", PathNotAllowed),
    Hardlink => ("hardlink", PathNotAllowed),
    SpecialFile => ("special_file", PathNotAllowed),
    DuplicatePath => ("duplicate_path", PathNotAllowed),
    UnicodeCollision => ("unicode_collision", PathNotAllowed),
    BinDir => ("bin_dir", PathNotAllowed),
    LinkScript => ("link_script", PathNotAllowed),
    LayoutNotAllowed => ("layout_not_allowed", PathNotAllowed),
    NativeUndeclared => ("native_undeclared", PathNotAllowed),
    // limit_exceeded
    ArchiveTooLarge => ("archive_too_large", LimitExceeded),
    FileTooLarge => ("file_too_large", LimitExceeded),
    UnpackedTooLarge => ("unpacked_too_large", LimitExceeded),
    TooManyFiles => ("too_many_files", LimitExceeded),
    CompressionRatio => ("compression_ratio", LimitExceeded),
    ManifestTooLarge => ("manifest_too_large", LimitExceeded),
    // manifest_invalid: metadata missing, malformed or inconsistent
    ManifestMissing => ("manifest_missing", ManifestInvalid),
    ManifestJson => ("manifest_json", ManifestInvalid),
    ManifestSchema => ("manifest_schema", ManifestInvalid),
    IndexMissing => ("index_missing", ManifestInvalid),
    IndexInvalid => ("index_invalid", ManifestInvalid),
    NameMismatch => ("name_mismatch", ManifestInvalid),
    VersionMismatch => ("version_mismatch", ManifestInvalid),
    SubdirMismatch => ("subdir_mismatch", ManifestInvalid),
    CompilerMissing => ("compiler_missing", ManifestInvalid),
    CompilerMismatch => ("compiler_mismatch", ManifestInvalid),
    DepsMismatch => ("deps_mismatch", ManifestInvalid),
    NativeMissing => ("native_missing", ManifestInvalid),
    NativePath => ("native_path", ManifestInvalid),
    // others
    FilenameMismatch => ("filename_mismatch", FilenameMismatch),
    Sha256Mismatch => ("sha256_mismatch", Sha256Mismatch),
    ManifestSha256Mismatch => ("manifest_sha256_mismatch", Sha256Mismatch),
    DependencyNotAllowed => ("dependency_not_allowed", DependencyNotAllowed),
}

/// A rule that fired: thrown inside the validator, turned into a verdict by [`crate::validate_package`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Failure {
    pub rule: RuleCode,
    pub message: String,
    pub path: Option<String>,
}

impl Failure {
    pub fn rejection(&self) -> RejectionCode {
        self.rule.rejection()
    }
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.rule.as_str(), self.message)
    }
}

impl std::error::Error for Failure {}

pub type Checked<T> = Result<T, Failure>;

pub fn fail<T>(rule: RuleCode, message: impl Into<String>) -> Checked<T> {
    Err(Failure { rule, message: message.into(), path: None })
}

pub fn fail_at<T>(rule: RuleCode, message: impl Into<String>, path: impl Into<String>) -> Checked<T> {
    Err(Failure { rule, message: message.into(), path: Some(path.into()) })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_rule_maps_to_the_contracts_rejection_code_as_the_typescript_table_does() {
        // service/api/src/validate/codes.ts RULE_TO_REJECTION.
        let ts: &[(&str, &str)] = &[
            ("not_an_archive", "archive_invalid"), ("archive_corrupt", "archive_invalid"), ("format_not_allowed", "archive_invalid"),
            ("conda_layout", "archive_invalid"), ("tar_header", "archive_invalid"), ("mojoc_missing", "archive_invalid"),
            ("path_absolute", "path_not_allowed"), ("path_traversal", "path_not_allowed"), ("path_unsafe", "path_not_allowed"),
            ("symlink", "path_not_allowed"), ("hardlink", "path_not_allowed"), ("special_file", "path_not_allowed"),
            ("duplicate_path", "path_not_allowed"), ("unicode_collision", "path_not_allowed"), ("bin_dir", "path_not_allowed"),
            ("link_script", "path_not_allowed"), ("layout_not_allowed", "path_not_allowed"), ("native_undeclared", "path_not_allowed"),
            ("archive_too_large", "limit_exceeded"), ("file_too_large", "limit_exceeded"), ("unpacked_too_large", "limit_exceeded"),
            ("too_many_files", "limit_exceeded"), ("compression_ratio", "limit_exceeded"), ("manifest_too_large", "limit_exceeded"),
            ("manifest_missing", "manifest_invalid"), ("manifest_json", "manifest_invalid"), ("manifest_schema", "manifest_invalid"),
            ("index_missing", "manifest_invalid"), ("index_invalid", "manifest_invalid"), ("name_mismatch", "manifest_invalid"),
            ("version_mismatch", "manifest_invalid"), ("subdir_mismatch", "manifest_invalid"), ("compiler_missing", "manifest_invalid"),
            ("compiler_mismatch", "manifest_invalid"), ("deps_mismatch", "manifest_invalid"), ("native_missing", "manifest_invalid"),
            ("native_path", "manifest_invalid"), ("filename_mismatch", "filename_mismatch"), ("sha256_mismatch", "sha256_mismatch"),
            ("manifest_sha256_mismatch", "sha256_mismatch"), ("dependency_not_allowed", "dependency_not_allowed"),
        ];
        assert_eq!(ts.len(), RuleCode::ALL.len(), "every rule is in the list, and no other");
        for (rule, rejection) in ts {
            let r = RuleCode::parse(rule).unwrap_or_else(|| panic!("no rule {rule}"));
            assert_eq!(r.rejection().as_str(), *rejection, "{rule}");
            assert_eq!(r.as_str(), *rule);
        }
        assert_eq!(RuleCode::parse("nope"), None);
    }
}
