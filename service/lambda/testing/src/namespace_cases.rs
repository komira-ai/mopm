//! The contract of the `NamespaceStore` port, the login's part of `service/api/test/auth-namespaces.test.ts`, run
//! against every adapter by [`namespace_contract_tests!`](crate::namespace_contract_tests).

use mopm_ports::namespaces::{NamespaceKind, NamespaceRecord, NamespaceStore, UserNamespace};

const T1: &str = "2026-11-19T12:00:00.000Z";
const T2: &str = "2026-11-20T08:30:00.000Z";

fn user(namespace: &str, github_id: u64, created_at: &str) -> NamespaceRecord {
    NamespaceRecord { namespace: namespace.to_string(), kind: NamespaceKind::User, github_id, created_at: created_at.to_string(), created_by: None }
}

pub async fn a_free_login_becomes_the_accounts_user_namespace_in_lower_case<S: NamespaceStore>(s: S) {
    assert_eq!(s.ensure_user_namespace(7, "Alice-Dev", T1).await.unwrap(), Some(UserNamespace::Created(user("alice-dev", 7, T1))));
}

pub async fn a_later_login_holds_the_namespace_and_answers_the_first_row<S: NamespaceStore>(s: S) {
    s.ensure_user_namespace(7, "alice", T1).await.unwrap();
    assert_eq!(s.ensure_user_namespace(7, "ALICE", T2).await.unwrap(), Some(UserNamespace::Held(user("alice", 7, T1))));
    assert_eq!(s.ensure_user_namespace(7, "alice", T2).await.unwrap(), Some(UserNamespace::Held(user("alice", 7, T1))));
}

pub async fn a_namespace_held_by_another_github_id_is_none_and_stays_theirs<S: NamespaceStore>(s: S) {
    s.ensure_user_namespace(7, "alice", T1).await.unwrap();
    // Someone who later took the login `alice` on GitHub (a new numeric id) gets nothing.
    assert_eq!(s.ensure_user_namespace(8, "alice", T2).await.unwrap(), None);
    assert_eq!(s.ensure_user_namespace(8, "Alice", T2).await.unwrap(), None);
    assert_eq!(s.ensure_user_namespace(7, "alice", T2).await.unwrap(), Some(UserNamespace::Held(user("alice", 7, T1))));
}

pub async fn a_renamed_account_gains_its_new_login_and_keeps_the_old<S: NamespaceStore>(s: S) {
    assert_eq!(s.ensure_user_namespace(7, "old-name", T1).await.unwrap(), Some(UserNamespace::Created(user("old-name", 7, T1))));
    assert_eq!(s.ensure_user_namespace(7, "new-name", T2).await.unwrap(), Some(UserNamespace::Created(user("new-name", 7, T2))));
    assert_eq!(s.ensure_user_namespace(7, "old-name", T2).await.unwrap(), Some(UserNamespace::Held(user("old-name", 7, T1))));
}

pub async fn reserved_logins_are_none_and_their_near_misses_are_created<S: NamespaceStore>(s: S) {
    for login in ["index", "quarantine", "native-mirror", "poll", "Poll", "noarch", "linux-64", "osx-arm64", "win-64", "emscripten-wasm32"] {
        assert_eq!(s.ensure_user_namespace(7, login, T1).await.unwrap(), None, "{login:?}");
        assert_eq!(s.ensure_user_namespace(8, login, T1).await.unwrap(), None, "{login:?}: nothing was stored for 7 either");
    }
    for login in ["indexes", "linux", "noarch-64", "linux-64-x"] {
        assert_eq!(s.ensure_user_namespace(7, login, T1).await.unwrap(), Some(UserNamespace::Created(user(login, 7, T1))), "{login:?}");
    }
}

pub async fn logins_out_of_the_grammar_are_none_and_the_longest_in_it_is_created<S: NamespaceStore>(s: S) {
    let too_long = "a".repeat(40);
    for login in ["", "a_b", "-a", "a-", "a--b", "a.b", "ä", too_long.as_str()] {
        assert_eq!(s.ensure_user_namespace(7, login, T1).await.unwrap(), None, "{login:?}");
    }
    let longest = "a".repeat(39);
    assert_eq!(s.ensure_user_namespace(7, &longest, T1).await.unwrap(), Some(UserNamespace::Created(user(&longest, 7, T1))));
}

pub async fn of_two_racing_creates_one_wins_and_the_loser_answers_from_the_winners_row<S: NamespaceStore>(s: S) {
    use UserNamespace::{Created, Held};
    // Two accounts: the winner's row is stored, the loser gets nothing.
    let (a, b) = tokio::join!(s.ensure_user_namespace(7, "race", T1), s.ensure_user_namespace(8, "race", T2));
    let got = (a.unwrap(), b.unwrap());
    let seven_won = (Some(Created(user("race", 7, T1))), None);
    let eight_won = (None, Some(Created(user("race", 8, T2))));
    assert!([seven_won, eight_won].contains(&got), "{got:?}");
    // The winner is the one that got a row.
    let (id, at) = got.0.as_ref().map_or((8, T2), |_| (7, T1));
    assert_eq!(s.ensure_user_namespace(id, "race", T2).await.unwrap(), Some(Held(user("race", id, at))));

    // One account in two logins at once: one creates, the other holds that same row.
    let (a, b) = tokio::join!(s.ensure_user_namespace(9, "twice", T1), s.ensure_user_namespace(9, "twice", T2));
    let got = (a.unwrap(), b.unwrap());
    let first_won = (Some(Created(user("twice", 9, T1))), Some(Held(user("twice", 9, T1))));
    let second_won = (Some(Held(user("twice", 9, T2))), Some(Created(user("twice", 9, T2))));
    assert!([first_won, second_won].contains(&got), "{got:?}");
}

#[macro_export]
macro_rules! namespace_contract_tests {
    ($make:expr) => {
        $crate::contract_tests!(
            $make,
            $crate::namespace_cases,
            [
                a_free_login_becomes_the_accounts_user_namespace_in_lower_case,
                a_later_login_holds_the_namespace_and_answers_the_first_row,
                a_namespace_held_by_another_github_id_is_none_and_stays_theirs,
                a_renamed_account_gains_its_new_login_and_keeps_the_old,
                reserved_logins_are_none_and_their_near_misses_are_created,
                logins_out_of_the_grammar_are_none_and_the_longest_in_it_is_created,
                of_two_racing_creates_one_wins_and_the_loser_answers_from_the_winners_row,
            ]
        );
    };
}
