use super::*;

fn ts(s: &str) -> Timestamp {
    s.parse().unwrap()
}

#[test]
fn a_minted_secret_is_mopm_and_40_base32_characters() {
    for fill in [0u8, 1, 0x55, 0xaa, 0xff] {
        let s = TokenSecret::mint(&[fill; SECRET_BYTES]);
        assert_eq!(s.expose().len(), TOKEN_PREFIX.len() + 40);
        assert!(is_token(s.expose()), "{}", s.expose());
    }
}

#[test]
fn minting_encodes_most_significant_bits_first() {
    // Known values of the encoding: 0x00.. is all `a`, 0xff.. all `7`, and 0x08 then zeros starts with `b`.
    assert_eq!(
        TokenSecret::mint(&[0; SECRET_BYTES]).expose(),
        format!("mopm_{}", "a".repeat(40))
    );
    assert_eq!(
        TokenSecret::mint(&[0xff; SECRET_BYTES]).expose(),
        format!("mopm_{}", "7".repeat(40))
    );
    let mut r = [0u8; SECRET_BYTES];
    r[0] = 0x08;
    assert_eq!(
        TokenSecret::mint(&r).expose(),
        format!("mopm_b{}", "a".repeat(39))
    );
    // The last byte's low bit is the last character's low bit (25 bytes are exactly 40 groups, no padding).
    let mut r = [0u8; SECRET_BYTES];
    r[SECRET_BYTES - 1] = 1;
    assert_eq!(
        TokenSecret::mint(&r).expose(),
        format!("mopm_{}b", "a".repeat(39))
    );
}

#[test]
fn base32_pads_a_short_last_group_with_zero_bits() {
    // tokens.ts's encoder on lengths that do not fill a last group (RFC 4648 values, lowercase, no `=`).
    assert_eq!(base32(b""), "");
    assert_eq!(base32(b"f"), "my");
    assert_eq!(base32(b"fo"), "mzxq");
    assert_eq!(base32(b"foo"), "mzxw6");
    assert_eq!(base32(b"foob"), "mzxw6yq");
    assert_eq!(base32(b"fooba"), "mzxw6ytb");
    assert_eq!(base32(b"foobar"), "mzxw6ytboi");
}

#[test]
fn the_display_prefix_is_mopm_and_six() {
    let s = TokenSecret::mint(&[0x55; SECRET_BYTES]);
    assert_eq!(DISPLAY_PREFIX_LEN, 11);
    assert_eq!(s.display_prefix(), &s.expose()[..11]);
    assert!(s.display_prefix().starts_with(TOKEN_PREFIX));
}

#[test]
fn debug_shows_only_the_prefix() {
    let s = TokenSecret::mint(&[0x55; SECRET_BYTES]);
    assert_eq!(
        format!("{s:?}"),
        format!("TokenSecret({}...)", s.display_prefix())
    );
    assert!(!format!("{s:?}").contains(s.expose()));
}

#[test]
fn the_hash_is_sha256_lowercase_hex() {
    // sha256("") and sha256("abc"), the FIPS 180-2 examples.
    assert_eq!(
        hash_token(""),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    );
    assert_eq!(
        hash_token("abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
    let s = TokenSecret::mint(&[0; SECRET_BYTES]);
    assert_eq!(s.hash(), hash_token(s.expose()));
}

#[test]
fn the_grammar_accepts_32_to_64_base32_characters() {
    assert!(is_token(&format!("mopm_{}", "a".repeat(32))));
    assert!(is_token(&format!("mopm_{}", "7".repeat(64))));
    assert!(is_token("mopm_abcdefghijklmnopqrstuvwxyz234567"));
}

#[test]
fn the_grammar_refuses_everything_else() {
    for s in [
        String::new(),
        "mopm_".into(),
        format!("mopm_{}", "a".repeat(31)),
        format!("mopm_{}", "a".repeat(65)),
        format!("MOPM_{}", "a".repeat(40)),
        format!("mopm-{}", "a".repeat(40)),
        format!("xmopm_{}", "a".repeat(40)),
        format!("mopm_{}A", "a".repeat(39)),
        format!("mopm_{}1", "a".repeat(39)),
        format!("mopm_{}8", "a".repeat(39)),
        format!("mopm_{}=", "a".repeat(39)),
        format!("mopm_{} ", "a".repeat(39)),
        format!("mopm_{}\n", "a".repeat(39)),
        format!("mopm_{}é", "a".repeat(38)),
    ] {
        assert!(!is_token(&s), "{s:?}");
        assert_eq!(TokenSecret::parse(&s), None, "{s:?}");
    }
}

#[test]
fn parse_keeps_a_valid_secret_as_it_is() {
    let s = TokenSecret::mint(&[7; SECRET_BYTES]);
    assert_eq!(TokenSecret::parse(s.expose()), Some(s.clone()));
    let short = format!("mopm_{}", "q".repeat(32));
    assert_eq!(
        TokenSecret::parse(&short).unwrap().display_prefix(),
        "mopm_qqqqqq"
    );
}

#[test]
fn a_web_session_is_never_fresh_and_lasts_seven_days() {
    let s = TokenSecret::mint(&[3; SECRET_BYTES]);
    let f = web_session_fields(&s, ts("2026-11-20T10:00:00.123Z")).unwrap();
    assert_eq!(
        f,
        WebSessionFields {
            name: "web login",
            hash: s.hash(),
            prefix: s.display_prefix().to_owned(),
            created_at: "2026-11-20T10:00:00.123Z".into(),
            fresh_until: "2026-11-20T10:00:00.123Z".into(),
            expires_at: "2026-11-27T10:00:00.123Z".into(),
        }
    );
    assert_eq!(f.fresh_until, f.created_at);
}

#[test]
fn the_seven_days_are_168_hours_across_a_month_and_a_year() {
    let s = TokenSecret::mint(&[3; SECRET_BYTES]);
    let f = web_session_fields(&s, ts("2026-12-28T23:59:59.999Z")).unwrap();
    assert_eq!(f.expires_at, "2027-01-04T23:59:59.999Z");
    assert_eq!(WEB_SESSION_LIFETIME, SignedDuration::from_secs(604_800));
}

#[test]
fn times_are_written_as_to_iso_string_does() {
    let s = TokenSecret::mint(&[3; SECRET_BYTES]);
    // Whole seconds still have three decimals; below a millisecond is cut, as JavaScript's Date holds no more.
    let f = web_session_fields(&s, ts("2026-11-20T10:00:00Z")).unwrap();
    assert_eq!(f.created_at, "2026-11-20T10:00:00.000Z");
    let f = web_session_fields(&s, ts("2026-11-20T10:00:00.000999999Z")).unwrap();
    assert_eq!(f.created_at, "2026-11-20T10:00:00.000Z");
}

#[test]
fn an_expiry_past_the_last_time_is_an_error() {
    let s = TokenSecret::mint(&[3; SECRET_BYTES]);
    let late = Timestamp::MAX
        .checked_sub(SignedDuration::from_hours(1))
        .unwrap();
    let e = web_session_fields(&s, late).unwrap_err();
    assert_eq!(
        e,
        ExpiryOutOfRange {
            created_at: iso_millis(late)
        }
    );
    assert_eq!(
        e.to_string(),
        format!(
            "a session created at {} would expire after the last representable time",
            iso_millis(late)
        )
    );
}
