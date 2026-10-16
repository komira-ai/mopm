//! Reads every entry of an uncompressed tar, enforcing entry types, paths and the budget as it goes
//! (`validate/tar.ts`). Hand-written on purpose: the `tar` crate normalises what this must refuse (pax overrides,
//! long names, lying sizes).

use std::collections::BTreeMap;

use mopm_core::limits::Limits;

use crate::codes::{fail, fail_at, Checked, RuleCode};
use crate::js;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    File,
    Dir,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TarEntry {
    /// Normalised, relative, '/'-separated path with no trailing slash.
    pub path: String,
    pub kind: Kind,
    pub data: Vec<u8>,
}

/// Running totals shared by every tar of one package.
#[derive(Clone, Copy, Debug, Default)]
pub struct Budget {
    pub files: u64,
    pub bytes: u64,
}

const BLOCK: usize = 512;

fn cstr(buf: &[u8], start: usize, len: usize) -> &[u8] {
    let field = &buf[start..start + len];
    let end = field.iter().position(|b| *b == 0).unwrap_or(len);
    &field[..end]
}

fn octal(buf: &[u8], start: usize, len: usize, what: &str) -> Checked<u64> {
    if buf[start] & 0x80 != 0 {
        return fail(RuleCode::TarHeader, format!("tar {what} uses base-256 encoding"));
    }
    let text = js::latin1(cstr(buf, start, len));
    let s = text.trim_matches(js::is_space);
    if s.is_empty() {
        return Ok(0);
    }
    if !s.bytes().all(|b| (b'0'..=b'7').contains(&b)) {
        return fail(RuleCode::TarHeader, format!("tar {what} is not an octal number"));
    }
    Ok(js::parse_int(s, 8).and_then(|v| u64::try_from(v).ok()).unwrap_or(u64::MAX))
}

/// Normalise one tar path. Refuses anything that is not a plain relative path: absolute paths, '..',
/// backslashes, control characters, empty segments. A leading './' is dropped.
pub fn safe_path(raw: &str) -> Checked<String> {
    if raw.is_empty() {
        return fail(RuleCode::PathUnsafe, "empty path");
    }
    if raw.chars().any(|c| (c as u32) < 0x20 || c as u32 == 0x7f) {
        let shown = serde_json::to_string(raw).unwrap_or_default();
        return fail_at(RuleCode::PathUnsafe, format!("path {shown} has a control character"), raw);
    }
    if raw.contains('\\') {
        return fail_at(RuleCode::PathUnsafe, format!("path '{raw}' has a backslash"), raw);
    }
    let b = raw.as_bytes();
    if raw.starts_with('/') || (b.len() >= 2 && b[0].is_ascii_alphabetic() && b[1] == b':') {
        return fail_at(RuleCode::PathAbsolute, format!("path '{raw}' is absolute"), raw);
    }
    let mut parts: Vec<&str> = raw.split('/').collect();
    while parts.len() > 1 && parts[0] == "." {
        parts.remove(0);
    }
    if parts.len() > 1 && parts[parts.len() - 1].is_empty() {
        parts.pop(); // directory trailing slash
    }
    for seg in &parts {
        if *seg == ".." {
            return fail_at(RuleCode::PathTraversal, format!("path '{raw}' climbs out of the package root"), raw);
        }
        if seg.is_empty() || *seg == "." {
            return fail_at(RuleCode::PathUnsafe, format!("path '{raw}' has an empty or '.' segment"), raw);
        }
    }
    Ok(parts.join("/"))
}

fn malformed_pax<T>() -> Checked<T> {
    fail(RuleCode::TarHeader, "malformed pax record")
}

fn pax(data: &[u8]) -> Checked<BTreeMap<String, String>> {
    let mut out = BTreeMap::new();
    let mut p = 0usize;
    while p < data.len() {
        let Some(sp) = data[p..].iter().position(|b| *b == 0x20).map(|i| p + i) else { return malformed_pax() };
        let len = js::parse_int(&js::latin1(&data[p..sp]), 10);
        let Some(len) = len.filter(|l| *l >= (sp - p + 3) as i128 && p as i128 + *l <= data.len() as i128) else { return malformed_pax() };
        let len = len as usize;
        if data[p + len - 1] != 0x0a {
            return malformed_pax();
        }
        let rec = &data[sp + 1..p + len - 1];
        let Some(eq) = rec.iter().position(|b| *b == 0x3d) else { return malformed_pax() };
        match (js::decode_utf8(&rec[..eq]), js::decode_utf8(&rec[eq + 1..])) {
            (Some(k), Some(v)) => {
                out.insert(k, v);
            }
            _ => return fail(RuleCode::PathUnsafe, "pax record is not UTF-8"),
        }
        p += len;
    }
    Ok(out)
}

/// Read every entry of an uncompressed tar, enforcing entry types, paths and the budget as it goes.
pub fn read_tar(buf: &[u8], limits: &Limits, budget: &mut Budget) -> Checked<Vec<TarEntry>> {
    let mut entries = Vec::new();
    let mut p = 0usize;
    let mut long_name: Option<String> = None;
    let mut pax_next: Option<BTreeMap<String, String>> = None;
    loop {
        if p + BLOCK > buf.len() {
            return fail(RuleCode::TarHeader, "tar is truncated (no end marker)");
        }
        let h = &buf[p..p + BLOCK];
        if h.iter().all(|b| *b == 0) {
            // End marker: everything after must be zero padding.
            if buf[p..].iter().any(|b| *b != 0) {
                return fail(RuleCode::TarHeader, "tar has data after its end marker");
            }
            if long_name.is_some() || pax_next.is_some() {
                return fail(RuleCode::TarHeader, "tar ends after an extended header");
            }
            return Ok(entries);
        }
        let stored = octal(h, 148, 8, "checksum")?;
        let sum: u64 = h.iter().enumerate().map(|(i, b)| if (148..156).contains(&i) { 0x20 } else { u64::from(*b) }).sum();
        if sum != stored {
            return fail(RuleCode::TarHeader, "tar header checksum is wrong");
        }

        let type_byte = if h[156] == 0 { b'0' } else { h[156] };
        let type_char = char::from(type_byte);
        let mut size: i128 = i128::from(octal(h, 124, 12, "size")?);
        let magic = js::latin1(cstr(h, 257, 6));
        let mut raw_name: Vec<u8> = cstr(h, 0, 100).to_vec();
        if magic == "ustar" {
            let prefix = cstr(h, 345, 155);
            if !prefix.is_empty() {
                raw_name = [prefix, b"/", raw_name.as_slice()].concat();
            }
        }
        if let Some(px) = &pax_next {
            if let Some(s) = px.get("size") {
                match js::parse_int(s, 10) {
                    Some(v) if v >= 0 && v <= 9_007_199_254_740_991 => size = v,
                    _ => return fail(RuleCode::TarHeader, "pax size is not a number"),
                }
            }
        }
        p += BLOCK;

        let is_meta = matches!(type_char, 'x' | 'g' | 'L' | 'K');
        let carries_data = is_meta || type_char == '0' || type_char == '7';
        if carries_data && size > i128::from(limits.max_file_bytes) {
            return fail_at(RuleCode::FileTooLarge, format!("tar entry is {size} bytes"), js::latin1(&raw_name));
        }
        let data_len = if carries_data { size as usize } else { 0 };
        let padded = data_len.div_ceil(BLOCK) * BLOCK;
        if p + padded > buf.len() {
            return fail(RuleCode::TarHeader, "tar is truncated inside an entry");
        }
        let data = &buf[p..p + data_len];
        p += padded;

        if type_char == 'x' {
            pax_next = Some(pax(data)?);
            continue;
        }
        if type_char == 'g' || type_char == 'K' {
            continue; // global pax (ignored) and GNU long link target (links are refused anyway)
        }
        if type_char == 'L' {
            let end = data.iter().position(|b| *b == 0).unwrap_or(data.len());
            long_name = Some(String::from_utf8_lossy(&data[..end]).to_string());
            continue;
        }

        let name = match (&long_name, pax_next.as_ref().and_then(|px| px.get("path"))) {
            (Some(n), _) => n.clone(),
            (None, Some(n)) => n.clone(),
            (None, None) => match js::decode_utf8(&raw_name) {
                Some(n) => n,
                None => return fail(RuleCode::PathUnsafe, "tar path is not UTF-8"),
            },
        };
        long_name = None;
        pax_next = None;
        if type_char == '5' && (name == "." || name == "./") {
            continue; // the root directory entry some tools write
        }
        let path = safe_path(&name)?;

        match type_char {
            '2' => return fail_at(RuleCode::Symlink, format!("'{path}' is a symbolic link; the registry accepts none"), path),
            '1' => return fail_at(RuleCode::Hardlink, format!("'{path}' is a hard link; the registry accepts none"), path),
            '3' | '4' | '6' | '7' | 'S' => {
                return fail_at(RuleCode::SpecialFile, format!("'{path}' is a device, FIFO, contiguous or sparse file"), path)
            }
            '0' | '5' => {}
            other => {
                let shown = serde_json::to_string(&other.to_string()).unwrap_or_default();
                return fail_at(RuleCode::TarHeader, format!("'{path}' has unknown entry type {shown}"), path);
            }
        }
        budget.files += 1;
        if budget.files > limits.max_files {
            return fail(RuleCode::TooManyFiles, format!("more than {} entries", limits.max_files));
        }
        if type_char == '0' {
            budget.bytes += data.len() as u64;
            if budget.bytes > limits.max_unpacked_bytes {
                return fail(RuleCode::UnpackedTooLarge, format!("unpacked size exceeds {} bytes", limits.max_unpacked_bytes));
            }
            entries.push(TarEntry { path, kind: Kind::File, data: data.to_vec() });
        } else {
            entries.push(TarEntry { path, kind: Kind::Dir, data: Vec::new() });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A tar header, built here.
    fn header(name: &str, size: usize, typ: u8) -> Vec<u8> {
        let mut h = vec![0u8; BLOCK];
        h[..name.len()].copy_from_slice(name.as_bytes());
        h[100..107].copy_from_slice(b"0000644");
        h[124..135].copy_from_slice(format!("{size:011o}").as_bytes());
        h[156] = typ;
        h[257..262].copy_from_slice(b"ustar");
        seal(&mut h);
        h
    }

    /// Write the checksum of the header into it.
    fn seal(h: &mut [u8]) {
        h[148..156].fill(b' ');
        let sum: u32 = h.iter().map(|b| u32::from(*b)).sum();
        h[148..155].copy_from_slice(format!("{sum:06o}\0").as_bytes());
        h[155] = b' ';
    }

    fn entry(name: &str, data: &[u8], typ: u8) -> Vec<u8> {
        let mut out = header(name, data.len(), typ);
        out.extend_from_slice(data);
        out.resize(out.len().div_ceil(BLOCK) * BLOCK, 0);
        out
    }

    fn tar(parts: &[Vec<u8>]) -> Vec<u8> {
        let mut t = parts.concat();
        t.extend_from_slice(&[0u8; 1024]);
        t
    }

    fn read(t: &[u8]) -> Checked<Vec<TarEntry>> {
        read_tar(t, &Limits::DEFAULT, &mut Budget::default())
    }

    fn refusal(t: &[u8]) -> (RuleCode, String) {
        let e = read(t).err().expect("a refusal");
        (e.rule, e.message)
    }

    #[test]
    fn reads_files_and_directories() {
        let t = tar(&[entry("lib/", b"", b'5'), entry("lib/a.txt", b"hello", b'0')]);
        let got = read(&t).unwrap();
        assert_eq!(got, vec![
            TarEntry { path: "lib".into(), kind: Kind::Dir, data: vec![] },
            TarEntry { path: "lib/a.txt".into(), kind: Kind::File, data: b"hello".to_vec() },
        ]);
    }

    #[test]
    fn counts_files_and_bytes_in_the_shared_budget() {
        let t = tar(&[entry("a", b"12345", b'0'), entry("d/", b"", b'5')]);
        let mut b = Budget::default();
        read_tar(&t, &Limits::DEFAULT, &mut b).unwrap();
        assert_eq!((b.files, b.bytes), (2, 5));
        let l = Limits { max_files: 1, ..Limits::DEFAULT };
        let e = read_tar(&t, &l, &mut Budget::default()).unwrap_err();
        assert_eq!((e.rule, e.message.as_str()), (RuleCode::TooManyFiles, "more than 1 entries"));
        let l = Limits { max_unpacked_bytes: 4, ..Limits::DEFAULT };
        let e = read_tar(&t, &l, &mut Budget::default()).unwrap_err();
        assert_eq!((e.rule, e.message.as_str()), (RuleCode::UnpackedTooLarge, "unpacked size exceeds 4 bytes"));
    }

    #[test]
    fn refuses_links_devices_and_unknown_types_naming_the_path() {
        for (typ, rule) in [(b'2', RuleCode::Symlink), (b'1', RuleCode::Hardlink), (b'3', RuleCode::SpecialFile), (b'4', RuleCode::SpecialFile), (b'6', RuleCode::SpecialFile), (b'S', RuleCode::SpecialFile)] {
            let e = read(&tar(&[entry("x", b"", typ)])).unwrap_err();
            assert_eq!((e.rule, e.path.as_deref()), (rule, Some("x")), "{}", typ as char);
        }
        let e = read(&tar(&[entry("x", b"", b'Z')])).unwrap_err();
        assert_eq!((e.rule, e.message.as_str()), (RuleCode::TarHeader, "'x' has unknown entry type \"Z\""));
    }

    #[test]
    fn a_wrong_checksum_a_missing_end_marker_and_data_after_it_are_refused() {
        let mut t = tar(&[entry("a", b"x", b'0')]);
        t[0] = b'b';
        assert_eq!(refusal(&t), (RuleCode::TarHeader, "tar header checksum is wrong".into()));
        let t = entry("a", b"x", b'0');
        assert_eq!(refusal(&t), (RuleCode::TarHeader, "tar is truncated (no end marker)".into()));
        let mut t = tar(&[entry("a", b"x", b'0')]);
        let n = t.len();
        t[n - 1] = 1;
        assert_eq!(refusal(&t), (RuleCode::TarHeader, "tar has data after its end marker".into()));
        let t = [header("a", 1000, b'0'), vec![0u8; 100]].concat();
        assert_eq!(refusal(&t), (RuleCode::TarHeader, "tar is truncated inside an entry".into()));
    }

    #[test]
    fn base_256_and_non_octal_numbers_are_refused() {
        let mut h = header("a", 0, b'0');
        h[124] = 0x80;
        seal(&mut h);
        assert_eq!(refusal(&tar(&[h])), (RuleCode::TarHeader, "tar size uses base-256 encoding".into()));
        let mut h = header("a", 0, b'0');
        h[124..135].copy_from_slice(b"00000000009");
        seal(&mut h);
        assert_eq!(refusal(&tar(&[h])), (RuleCode::TarHeader, "tar size is not an octal number".into()));
    }

    #[test]
    fn a_pax_path_and_a_gnu_long_name_override_the_header_name() {
        let rec = |k: &str, v: &str| {
            let body = format!(" {k}={v}\n");
            let len = body.len() + 2; // the length digits (two for lengths 10..99)
            format!("{len}{body}")
        };
        let pax_data = rec("path", "lib/long_name.txt");
        let t = tar(&[entry("PaxHeader", pax_data.as_bytes(), b'x'), entry("short", b"x", b'0')]);
        assert_eq!(read(&t).unwrap()[0].path, "lib/long_name.txt");
        let t = tar(&[entry("././@LongLink", b"lib/gnu_long.txt\0", b'L'), entry("short", b"x", b'0')]);
        assert_eq!(read(&t).unwrap()[0].path, "lib/gnu_long.txt");
        // An extended header with nothing after it.
        let t = tar(&[entry("PaxHeader", pax_data.as_bytes(), b'x')]);
        assert_eq!(refusal(&t), (RuleCode::TarHeader, "tar ends after an extended header".into()));
    }

    #[test]
    fn a_pax_size_overrides_the_header_size_and_a_malformed_record_is_refused() {
        let body = "10 size=5\n";
        let t = tar(&[entry("P", body.as_bytes(), b'x'), { let mut e = header("a", 0, b'0'); e.extend_from_slice(&[b'1', b'2', b'3', b'4', b'5']); e.resize(BLOCK * 2, 0); e }]);
        assert_eq!(read(&t).unwrap()[0].data, b"12345");
        let t = tar(&[entry("P", b"garbage", b'x'), entry("a", b"", b'0')]);
        assert_eq!(refusal(&t), (RuleCode::TarHeader, "malformed pax record".into()));
    }

    #[test]
    fn the_root_directory_entry_is_skipped_and_a_dot_slash_prefix_is_dropped() {
        let t = tar(&[entry("./", b"", b'5'), entry("./lib/a", b"x", b'0')]);
        let got = read(&t).unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].path, "lib/a");
    }

    #[test]
    fn safe_path_is_the_typescripts() {
        assert_eq!(safe_path("a/b").unwrap(), "a/b");
        assert_eq!(safe_path("./a").unwrap(), "a");
        assert_eq!(safe_path("././a/").unwrap(), "a");
        let table = [
            ("", RuleCode::PathUnsafe, "empty path"),
            ("/a", RuleCode::PathAbsolute, "path '/a' is absolute"),
            ("C:x", RuleCode::PathAbsolute, "path 'C:x' is absolute"),
            ("a\\b", RuleCode::PathUnsafe, "path 'a\\b' has a backslash"),
            ("a/../b", RuleCode::PathTraversal, "path 'a/../b' climbs out of the package root"),
            ("a//b", RuleCode::PathUnsafe, "path 'a//b' has an empty or '.' segment"),
            ("a/./b", RuleCode::PathUnsafe, "path 'a/./b' has an empty or '.' segment"),
            ("a\u{1}b", RuleCode::PathUnsafe, "path \"a\\u0001b\" has a control character"),
            ("a\u{7f}b", RuleCode::PathUnsafe, "path \"a\u{7f}b\" has a control character"),
        ];
        for (raw, rule, message) in table {
            let e = safe_path(raw).unwrap_err();
            assert_eq!((e.rule, e.message.as_str()), (rule, message), "{raw:?}");
        }
        assert_eq!(safe_path(".").unwrap_err().message, "path '.' has an empty or '.' segment");
    }
}
