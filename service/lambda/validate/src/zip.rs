//! A strict reader for the outer zip of a `.conda` (`validate/zip.ts`). It reads the central directory, cross-checks
//! every local header against it, refuses overlapping entries (the "quine" zip bomb), encryption, zip64, multi-disk
//! archives and any method but stored and deflate, and checks the CRC-32 of what it returns. A `.conda` is at most
//! 100 MB, so zip64 is never needed.
//!
//! It is hand-written on purpose: the `zip` crate normalises what this must refuse.

use std::collections::BTreeSet;
use std::io::Read;

use mopm_core::limits::Limits;

use crate::codes::{fail, fail_at, Checked, RuleCode};

#[derive(Debug)]
pub struct ZipEntry {
    pub name: String,
    pub data: Vec<u8>,
}

const EOCD_SIG: u32 = 0x0605_4b50;
const CEN_SIG: u32 = 0x0201_4b50;
const LOC_SIG: u32 = 0x0403_4b50;

fn bad<T>(m: impl std::fmt::Display) -> Checked<T> {
    fail(RuleCode::ArchiveCorrupt, format!("zip: {m}"))
}

/// An out-of-range read of the archive (`RangeError` in the TypeScript): the archive is structurally damaged.
fn damaged<T>() -> Checked<T> {
    fail(RuleCode::ArchiveCorrupt, "the archive is structurally damaged")
}

fn u16_at(b: &[u8], at: usize) -> Checked<u16> {
    match b.get(at..at + 2) {
        Some(s) => Ok(u16::from_le_bytes([s[0], s[1]])),
        None => damaged(),
    }
}

fn u32_at(b: &[u8], at: usize) -> Checked<u32> {
    match b.get(at..at + 4) {
        Some(s) => Ok(u32::from_le_bytes([s[0], s[1], s[2], s[3]])),
        None => damaged(),
    }
}

/// CRC-32 of the data, as a zip stores it.
pub fn crc32(data: &[u8]) -> u32 {
    crc32fast::hash(data)
}

fn inflate(raw: &[u8], limit: usize) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let mut dec = flate2::read::DeflateDecoder::new(raw).take(limit as u64 + 1);
    dec.read_to_end(&mut out).ok()?;
    (out.len() <= limit).then_some(out)
}

pub fn read_zip(buf: &[u8], limits: &Limits, max_entry_bytes: u64) -> Checked<Vec<ZipEntry>> {
    // End of central directory: the last signature whose comment length reaches exactly the end of file.
    let mut eocd: Option<usize> = None;
    if buf.len() >= 22 {
        let lowest = (buf.len() - 22).saturating_sub(0xffff);
        let mut i = buf.len() - 22;
        loop {
            if u32_at(buf, i)? == EOCD_SIG && i + 22 + usize::from(u16_at(buf, i + 20)?) == buf.len() {
                eocd = Some(i);
                break;
            }
            if i == lowest {
                break;
            }
            i -= 1;
        }
    }
    let Some(eocd) = eocd else { return bad("no end of central directory") };
    let disk = u16_at(buf, eocd + 4)?;
    let cd_disk = u16_at(buf, eocd + 6)?;
    let n_here = u16_at(buf, eocd + 8)?;
    let n_total = u16_at(buf, eocd + 10)?;
    let cd_size = u32_at(buf, eocd + 12)?;
    let cd_off = u32_at(buf, eocd + 16)?;
    if disk != 0 || cd_disk != 0 || n_here != n_total {
        return bad("multi-disk archives are not accepted");
    }
    if n_total == 0xffff || cd_size == 0xffff_ffff || cd_off == 0xffff_ffff {
        return bad("zip64 is not accepted");
    }
    if n_total > 16 {
        return bad(format!("too many entries ({n_total})"));
    }
    let (cd_off, cd_size) = (cd_off as usize, cd_size as usize);
    if cd_off + cd_size > eocd {
        return bad("central directory out of bounds");
    }

    let mut out = Vec::new();
    let mut spans: Vec<(usize, usize)> = Vec::new();
    let mut names = BTreeSet::new();
    let mut total: u64 = 0;
    let mut p = cd_off;
    for _ in 0..n_total {
        if p + 46 > cd_off + cd_size || u32_at(buf, p)? != CEN_SIG {
            return bad("bad central directory entry");
        }
        let flags = u16_at(buf, p + 8)?;
        let method = u16_at(buf, p + 10)?;
        let crc = u32_at(buf, p + 16)?;
        let csize = u32_at(buf, p + 20)?;
        let usize_ = u32_at(buf, p + 24)?;
        let name_len = usize::from(u16_at(buf, p + 28)?);
        let extra_len = usize::from(u16_at(buf, p + 30)?);
        let comment_len = usize::from(u16_at(buf, p + 32)?);
        let disk_start = u16_at(buf, p + 34)?;
        let lho = u32_at(buf, p + 42)?;
        if p + 46 + name_len + extra_len + comment_len > cd_off + cd_size {
            return bad("central directory entry overruns");
        }
        let name_bytes = &buf[p + 46..p + 46 + name_len];
        let Some(name) = crate::js::decode_utf8(name_bytes) else { return bad("entry name is not UTF-8") };
        p += 46 + name_len + extra_len + comment_len;
        if flags & 0x1 != 0 || flags & 0x40 != 0 {
            return bad(format!("entry '{name}' is encrypted"));
        }
        if disk_start != 0 {
            return bad("multi-disk archives are not accepted");
        }
        if csize == 0xffff_ffff || usize_ == 0xffff_ffff || lho == 0xffff_ffff {
            return bad("zip64 is not accepted");
        }
        if method != 0 && method != 8 {
            return bad(format!("entry '{name}' uses compression method {method}"));
        }
        if method == 0 && csize != usize_ {
            return bad(format!("stored entry '{name}' has unequal sizes"));
        }
        if !names.insert(name.clone()) {
            return bad(format!("duplicate entry '{name}'"));
        }
        if u64::from(usize_) > max_entry_bytes {
            return fail_at(RuleCode::FileTooLarge, format!("zip entry '{name}' is {usize_} bytes"), name);
        }
        total += u64::from(usize_);
        if total > limits.max_unpacked_bytes {
            return fail(RuleCode::UnpackedTooLarge, "zip entries together are too large");
        }
        if u64::from(usize_) > limits.ratio_floor_bytes && u64::from(usize_) > limits.max_ratio.saturating_mul(u64::from(csize).max(1)) {
            return fail_at(RuleCode::CompressionRatio, format!("zip entry '{name}' expands more than {} times", limits.max_ratio), name);
        }

        let lho = lho as usize;
        if lho + 30 > cd_off || u32_at(buf, lho)? != LOC_SIG {
            return bad(format!("entry '{name}' has a bad local header"));
        }
        let l_name_len = usize::from(u16_at(buf, lho + 26)?);
        let l_extra_len = usize::from(u16_at(buf, lho + 28)?);
        let data_start = lho + 30 + l_name_len + l_extra_len;
        let data_end = data_start + csize as usize;
        if data_end > cd_off {
            return bad(format!("entry '{name}' overruns the file"));
        }
        if buf.get(lho + 30..lho + 30 + l_name_len) != Some(name_bytes) {
            return bad(format!("entry '{name}' local header names a different file"));
        }
        spans.push((lho, data_end));

        let raw = &buf[data_start..data_end];
        let data = if method == 0 {
            raw.to_vec()
        } else {
            match inflate(raw, (usize_ as usize).max(1)) {
                Some(d) => d,
                None => return bad(format!("entry '{name}' does not inflate to its declared size")),
            }
        };
        if data.len() != usize_ as usize {
            return bad(format!("entry '{name}' is not its declared size"));
        }
        if crc32(&data) != crc {
            return bad(format!("entry '{name}' fails its CRC-32"));
        }
        out.push(ZipEntry { name, data });
    }
    spans.sort_by_key(|s| s.0);
    for w in spans.windows(2) {
        if w[1].0 < w[0].1 {
            return bad("entries overlap");
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A zip written here, by hand, with one wrong thing at a time (the corpus holds the many more).
    struct Z {
        name: String,
        data: Vec<u8>,
        method: u16,
        flags: u16,
        crc: Option<u32>,
        usize_: Option<u32>,
        csize_: Option<u32>,
    }

    fn stored(name: &str, data: &[u8]) -> Z {
        Z { name: name.into(), data: data.to_vec(), method: 0, flags: 0, crc: None, usize_: None, csize_: None }
    }

    fn build(entries: &[Z], comment: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        let mut offsets = Vec::new();
        for e in entries {
            offsets.push(out.len() as u32);
            out.extend_from_slice(&LOC_SIG.to_le_bytes());
            out.extend_from_slice(&[20, 0]);
            out.extend_from_slice(&e.flags.to_le_bytes());
            out.extend_from_slice(&e.method.to_le_bytes());
            out.extend_from_slice(&[0, 0, 0x21, 0]);
            out.extend_from_slice(&e.crc.unwrap_or_else(|| crc32(&e.data)).to_le_bytes());
            out.extend_from_slice(&e.csize_.unwrap_or(e.data.len() as u32).to_le_bytes());
            out.extend_from_slice(&e.usize_.unwrap_or(e.data.len() as u32).to_le_bytes());
            out.extend_from_slice(&(e.name.len() as u16).to_le_bytes());
            out.extend_from_slice(&[0, 0]);
            out.extend_from_slice(e.name.as_bytes());
            out.extend_from_slice(&e.data);
        }
        let cd = out.len() as u32;
        for (e, off) in entries.iter().zip(&offsets) {
            out.extend_from_slice(&CEN_SIG.to_le_bytes());
            out.extend_from_slice(&[20, 0, 20, 0]);
            out.extend_from_slice(&e.flags.to_le_bytes());
            out.extend_from_slice(&e.method.to_le_bytes());
            out.extend_from_slice(&[0, 0, 0x21, 0]);
            out.extend_from_slice(&e.crc.unwrap_or_else(|| crc32(&e.data)).to_le_bytes());
            out.extend_from_slice(&e.csize_.unwrap_or(e.data.len() as u32).to_le_bytes());
            out.extend_from_slice(&e.usize_.unwrap_or(e.data.len() as u32).to_le_bytes());
            out.extend_from_slice(&(e.name.len() as u16).to_le_bytes());
            out.extend_from_slice(&[0; 12]);
            out.extend_from_slice(&off.to_le_bytes());
            out.extend_from_slice(e.name.as_bytes());
        }
        let cd_size = out.len() as u32 - cd;
        out.extend_from_slice(&EOCD_SIG.to_le_bytes());
        out.extend_from_slice(&[0, 0, 0, 0]);
        out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
        out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
        out.extend_from_slice(&cd_size.to_le_bytes());
        out.extend_from_slice(&cd.to_le_bytes());
        out.extend_from_slice(&(comment.len() as u16).to_le_bytes());
        out.extend_from_slice(comment);
        out
    }

    fn read(z: &[u8]) -> Checked<Vec<ZipEntry>> {
        read_zip(z, &Limits::DEFAULT, 1 << 30)
    }

    fn message(z: &[u8]) -> String {
        let e = read(z).err().expect("a refusal");
        assert_eq!(e.rule, RuleCode::ArchiveCorrupt, "{}", e.message);
        e.message
    }

    #[test]
    fn reads_stored_entries_in_order() {
        let z = build(&[stored("a.txt", b"hello"), stored("b/c", b"")], b"");
        let got = read(&z).unwrap();
        assert_eq!(got.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(), ["a.txt", "b/c"]);
        assert_eq!(got[0].data, b"hello");
        assert!(got[1].data.is_empty());
    }

    #[test]
    fn reads_a_deflated_entry_and_checks_its_declared_size() {
        // A stored deflate block: BFINAL=1, BTYPE=00, LEN=5, NLEN=!5.
        let deflated = [&[0x01u8, 5, 0, 0xfa, 0xff][..], b"hello"].concat();
        let mut e = stored("a", &deflated);
        e.method = 8;
        e.crc = Some(crc32(b"hello"));
        e.usize_ = Some(5);
        assert_eq!(read(&build(&[e], b"")).unwrap()[0].data, b"hello");
        let mut smaller = stored("a", &deflated);
        smaller.method = 8;
        smaller.crc = Some(crc32(b"hello"));
        smaller.usize_ = Some(3);
        assert_eq!(message(&build(&[smaller], b"")), "zip: entry 'a' does not inflate to its declared size");
        let mut larger = stored("a", &deflated);
        larger.method = 8;
        larger.crc = Some(crc32(b"hello"));
        larger.usize_ = Some(9);
        assert_eq!(message(&build(&[larger], b"")), "zip: entry 'a' is not its declared size");
    }

    #[test]
    fn the_end_record_is_the_last_signature_whose_comment_reaches_the_end_of_the_file() {
        read(&build(&[stored("a", b"x")], b"a comment")).unwrap();
        // The LAST signature whose comment reaches the end wins, as in the TypeScript: a comment that is itself a
        // well-formed empty end record is taken for the end record (and an archive of no entries is what it reads).
        let fake = [&EOCD_SIG.to_le_bytes()[..], &[0u8; 18]].concat();
        assert!(read(&build(&[stored("a", b"x")], &fake)).unwrap().is_empty());
        // A signature whose comment length does not reach the end is not an end record.
        let near = [&EOCD_SIG.to_le_bytes()[..], &[0u8; 16], &[5u8, 0]].concat();
        assert_eq!(read(&build(&[stored("a", b"x")], &near)).unwrap()[0].name, "a");
        let mut z = build(&[stored("a", b"x")], b"");
        z.push(0);
        assert_eq!(message(&z), "zip: no end of central directory");
        assert_eq!(message(b"PK\x03\x04"), "zip: no end of central directory");
        assert_eq!(message(b""), "zip: no end of central directory");
    }

    #[test]
    fn refuses_what_a_conda_never_needs() {
        let mut enc = stored("a", b"x");
        enc.flags = 1;
        assert_eq!(message(&build(&[enc], b"")), "zip: entry 'a' is encrypted");
        let mut strong = stored("a", b"x");
        strong.flags = 0x40;
        assert_eq!(message(&build(&[strong], b"")), "zip: entry 'a' is encrypted");
        let mut m12 = stored("a", b"x");
        m12.method = 12;
        assert_eq!(message(&build(&[m12], b"")), "zip: entry 'a' uses compression method 12");
        let mut sizes = stored("a", b"xy");
        sizes.csize_ = Some(1);
        assert_eq!(message(&build(&[sizes], b"")), "zip: stored entry 'a' has unequal sizes");
        assert_eq!(message(&build(&[stored("a", b"x"), stored("a", b"y")], b"")), "zip: duplicate entry 'a'");
        let many: Vec<Z> = (0..17).map(|i| stored(&format!("f{i}"), b"x")).collect();
        assert_eq!(message(&build(&many, b"")), "zip: too many entries (17)");
        assert_eq!(read(&build(&many[..16], b"")).unwrap().len(), 16, "sixteen is read");
    }

    #[test]
    fn checks_the_crc_and_the_names() {
        let mut e = stored("a", b"x");
        e.crc = Some(0);
        assert_eq!(message(&build(&[e], b"")), "zip: entry 'a' fails its CRC-32");
        let mut z = build(&[stored("a", b"x")], b"");
        z[30] = b'b'; // the local header's name
        assert_eq!(message(&z), "zip: entry 'a' local header names a different file");
        let mut z = build(&[stored("a", b"x")], b"");
        z[0] = b'X';
        assert_eq!(message(&z), "zip: entry 'a' has a bad local header");
    }

    #[test]
    fn the_entry_and_ratio_limits_apply_from_the_directory_alone() {
        let l = Limits { max_unpacked_bytes: 10, ..Limits::DEFAULT };
        let mut e = stored("a", &[0u8; 11]);
        e.method = 0;
        let e = read_zip(&build(&[e], b""), &l, 1 << 30).err().unwrap();
        assert_eq!(e.rule, RuleCode::UnpackedTooLarge);
        let big = read_zip(&build(&[stored("a", &[0u8; 11])], b""), &Limits::DEFAULT, 10).err().unwrap();
        assert_eq!((big.rule, big.message.as_str(), big.path.as_deref()), (RuleCode::FileTooLarge, "zip entry 'a' is 11 bytes", Some("a")));
    }
}
