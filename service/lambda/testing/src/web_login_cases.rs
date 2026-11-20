//! The contract of the `WebLoginStore` port, run against every adapter by
//! [`web_login_contract_tests!`](crate::web_login_contract_tests). Time comes from a [`FixedClock`] the case moves.

use mopm_ports::env::{iso_millis, Clock};
use mopm_ports::web_login::{WebLoginRecord, WebLoginStore};

use crate::env::FixedClock;

/// 2026-11-19T12:00:00.000Z
const START_MS: i64 = 1_795_089_600_000;

fn h(n: u32) -> String {
    format!("{n:064}")
}

/// A row stored at `START_MS` that lives ten minutes, as `start` stores it.
fn row(n: u32) -> WebLoginRecord {
    WebLoginRecord {
        id: h(n),
        state_hash: h(1000 + n),
        code_verifier: format!("verifier-{n}-0123456789abcdefghijklmnopqrstuvwxyz0123456"),
        return_to: format!("/tutorial/lesson-{n}?step=2"),
        expires_at: START_MS / 1000 + 600,
        consumed_at: None,
    }
}

pub async fn a_row_is_consumed_once_and_comes_back_whole_with_consumed_at<S: WebLoginStore>(s: S) {
    let clock = FixedClock::at_millis(START_MS);
    s.put(&row(1)).await.unwrap();
    clock.advance_millis(4_250);
    let taken = s.consume(&h(1), clock.now()).await.unwrap();
    assert_eq!(taken, Some(WebLoginRecord { consumed_at: Some("2026-11-19T12:00:04.250Z".to_string()), ..row(1) }));
    assert_eq!(iso_millis(clock.now()), "2026-11-19T12:00:04.250Z");
    clock.advance_millis(1);
    assert_eq!(s.consume(&h(1), clock.now()).await.unwrap(), None, "a second consume gets nothing");
}

pub async fn a_row_stored_with_consumed_at_is_not_consumable<S: WebLoginStore>(s: S) {
    let clock = FixedClock::at_millis(START_MS);
    let taken = WebLoginRecord { consumed_at: Some("2026-11-19T11:59:00.000Z".to_string()), ..row(1) };
    s.put(&taken).await.unwrap();
    assert_eq!(s.consume(&h(1), clock.now()).await.unwrap(), None);
    // Stored again without consumed_at, the row is consumable: what refused it was consumed_at alone.
    s.put(&row(1)).await.unwrap();
    let again = s.consume(&h(1), clock.now()).await.unwrap();
    assert_eq!(again, Some(WebLoginRecord { consumed_at: Some("2026-11-19T12:00:00.000Z".to_string()), ..row(1) }));
}

pub async fn an_unknown_id_is_not_consumable<S: WebLoginStore>(s: S) {
    let clock = FixedClock::at_millis(START_MS);
    s.put(&row(1)).await.unwrap();
    assert_eq!(s.consume(&h(2), clock.now()).await.unwrap(), None);
    assert!(s.consume(&h(1), clock.now()).await.unwrap().is_some(), "the stored row is untouched");
}

pub async fn a_row_is_consumable_until_the_millisecond_before_expires_at<S: WebLoginStore>(s: S) {
    let clock = FixedClock::at_millis(START_MS);
    s.put(&row(1)).await.unwrap();
    s.put(&row(2)).await.unwrap();
    clock.advance_millis(600_000 - 1);
    let last_moment = s.consume(&h(1), clock.now()).await.unwrap();
    assert_eq!(last_moment.and_then(|r| r.consumed_at).as_deref(), Some("2026-11-19T12:09:59.999Z"));
    clock.advance_millis(1);
    assert_eq!(s.consume(&h(2), clock.now()).await.unwrap(), None, "expired at expires_at");
}

pub async fn an_expired_row_stays_refused_and_is_not_marked_consumed<S: WebLoginStore>(s: S) {
    let clock = FixedClock::at_millis(START_MS);
    s.put(&row(1)).await.unwrap();
    clock.advance_millis(3_600_000);
    assert_eq!(s.consume(&h(1), clock.now()).await.unwrap(), None);
    assert_eq!(s.consume(&h(1), clock.now()).await.unwrap(), None);
    // A refused consume wrote nothing: at a time before expiry (a skewed caller), the row is still whole.
    let earlier = jiff::Timestamp::from_millisecond(START_MS).unwrap();
    assert_eq!(s.consume(&h(1), earlier).await.unwrap(), Some(WebLoginRecord { consumed_at: Some("2026-11-19T12:00:00.000Z".to_string()), ..row(1) }));
}

pub async fn consuming_one_row_leaves_the_others_consumable<S: WebLoginStore>(s: S) {
    let clock = FixedClock::at_millis(START_MS);
    for n in 1..=3 {
        s.put(&row(n)).await.unwrap();
    }
    assert!(s.consume(&h(2), clock.now()).await.unwrap().is_some());
    let one = s.consume(&h(1), clock.now()).await.unwrap();
    assert_eq!(one.map(|r| r.return_to), Some("/tutorial/lesson-1?step=2".to_string()));
    let three = s.consume(&h(3), clock.now()).await.unwrap();
    assert_eq!(three.map(|r| r.state_hash), Some(h(1003)));
}

pub async fn of_two_racing_consumes_exactly_one_gets_the_row<S: WebLoginStore>(s: S) {
    let clock = FixedClock::at_millis(START_MS);
    s.put(&row(1)).await.unwrap();
    let id = h(1);
    let (a, b) = tokio::join!(s.consume(&id, clock.now()), s.consume(&id, clock.now()));
    let got: Vec<WebLoginRecord> = [a.unwrap(), b.unwrap()].into_iter().flatten().collect();
    assert_eq!(got, vec![WebLoginRecord { consumed_at: Some("2026-11-19T12:00:00.000Z".to_string()), ..row(1) }]);
}

#[macro_export]
macro_rules! web_login_contract_tests {
    ($make:expr) => {
        $crate::contract_tests!(
            $make,
            $crate::web_login_cases,
            [
                a_row_is_consumed_once_and_comes_back_whole_with_consumed_at,
                a_row_stored_with_consumed_at_is_not_consumable,
                an_unknown_id_is_not_consumable,
                a_row_is_consumable_until_the_millisecond_before_expires_at,
                an_expired_row_stays_refused_and_is_not_marked_consumed,
                consuming_one_row_leaves_the_others_consumable,
                of_two_racing_consumes_exactly_one_gets_the_row,
            ]
        );
    };
}
