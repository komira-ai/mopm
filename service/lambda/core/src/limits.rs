//! Size and shape caps of the package validator. All are enforced while reading, so a hostile
//! archive cannot make the validator allocate past them.

/// The caps. `Default` is the registry's own.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Limits {
    /// Bytes of the uploaded archive (a package is at most 100 MB, decimal).
    pub max_archive_bytes: u64,
    /// Bytes of any one unpacked file.
    pub max_file_bytes: u64,
    /// Bytes of all unpacked files together (both tars of a .conda).
    pub max_unpacked_bytes: u64,
    /// Entries (files and directories) over the whole package.
    pub max_files: u64,
    /// Unpacked bytes over compressed bytes of one compressed stream, applied once it is past `ratio_floor_bytes`.
    pub max_ratio: u64,
    /// A stream below this many unpacked bytes is never judged by ratio (small, highly regular files are normal).
    pub ratio_floor_bytes: u64,
    /// Bytes of `<name>.mopm.json` and `info/index.json`.
    pub max_metadata_bytes: u64,
}

impl Limits {
    /// `DEFAULT_LIMITS`.
    pub const DEFAULT: Limits = Limits {
        max_archive_bytes: 100_000_000,
        max_file_bytes: 128 * 1024 * 1024,
        max_unpacked_bytes: 512 * 1024 * 1024,
        max_files: 2000,
        max_ratio: 200,
        ratio_floor_bytes: 1024 * 1024,
        max_metadata_bytes: 1024 * 1024,
    };
}

impl Default for Limits {
    fn default() -> Self {
        Limits::DEFAULT
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_defaults_are_the_typescript_registrys() {
        // service/api/src/validate/limits.ts DEFAULT_LIMITS, number by number.
        let d = Limits::default();
        assert_eq!(d.max_archive_bytes, 100_000_000);
        assert_eq!(d.max_file_bytes, 134_217_728);
        assert_eq!(d.max_unpacked_bytes, 536_870_912);
        assert_eq!(d.max_files, 2000);
        assert_eq!(d.max_ratio, 200);
        assert_eq!(d.ratio_floor_bytes, 1_048_576);
        assert_eq!(d.max_metadata_bytes, 1_048_576);
    }
}
