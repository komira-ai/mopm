//! Owner namespaces (`auth/namespaces.ts`): the row of the `namespaces` table and what a login does about
//! the account's user namespace (`ensureUserNamespace`). The organization side of that file (members,
//! `createOrgNamespace`) is not here: nothing in Rust uses it yet.
//!
//! A namespace is keyed by its string and bound to a GitHub numeric id, never to a login: a renamed account
//! keeps its old namespace and gains its new login as a second one if that is free.

use std::future::Future;

use serde::{Deserialize, Serialize};

use crate::error::PortResult;

/// The longest namespace: GitHub's longest login.
const NAMESPACE_MAX_LENGTH: usize = 39;

/// The channel bucket's other top-level prefixes, and `poll` (the path segment of
/// `POST /api/v2/namespaces/poll`), which would otherwise read as a namespace.
const RESERVED_NAMESPACES: [&str; 4] = ["index", "quarantine", "native-mirror", "poll"];

/// The platforms of a conda subdir (`<platform>-<arch>`); with `noarch`, the shapes no namespace may have,
/// since a channel URL would be ambiguous.
const CONDA_SUBDIR_PLATFORMS: [&str; 7] = [
    "linux",
    "osx",
    "win",
    "freebsd",
    "zos",
    "wasi",
    "emscripten",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NamespaceKind {
    User,
    Org,
}

/// A row of `mopm-<stage>-namespaces`, keyed by `namespace` (`NamespaceRecord` of `namespaces.ts`). In the table,
/// `dynamo-namespace-store.ts` stores `github_id` as a string (the index key) with the number beside it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct NamespaceRecord {
    pub namespace: String,
    pub kind: NamespaceKind,
    /// The user's or the organization's GitHub numeric id: the binding. It never changes.
    pub github_id: u64,
    pub created_at: String,
    /// Organization namespaces only: the GitHub account that registered it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_by: Option<u64>,
}

/// What a login did about the account's user namespace, when the account has one under this login.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UserNamespace {
    /// The lower-cased login was free and is now this row.
    Created(NamespaceRecord),
    /// The account already held it (an earlier login, or a create that ran at the same time): the stored row.
    Held(NamespaceRecord),
}

pub trait NamespaceStore: Send + Sync {
    /// At every login: the login, lower-cased, becomes the account's user namespace when
    /// [`user_namespace_for`] allows it and no row has that string. `Some(Created)` with the new row, or
    /// `Some(Held)` with the stored row when `github_id` already holds it. `None`, and nothing written, when
    /// the login is out of the grammar or reserved, or another GitHub id holds the string. The account's
    /// earlier namespaces are untouched.
    ///
    /// Create-once and atomic: of two creates of one string at the same time one stores its row, and the
    /// other answers from that row (`Held` for the same GitHub id, `None` for another). No row is ever
    /// overwritten or deleted.
    fn ensure_user_namespace(
        &self,
        github_id: u64,
        login: &str,
        now: &str,
    ) -> impl Future<Output = PortResult<Option<UserNamespace>>> + Send;
}

/// The user namespace a login would have: the login in lower case, when that is in the grammar (letters,
/// digits and single hyphens, 1 to 39 characters) and not reserved (`index`, `quarantine`, `native-mirror`, `poll`, or
/// the shape of a conda subdir). `namespaceProblem` of `namespaces.ts`; every adapter decides with it.
pub fn user_namespace_for(login: &str) -> Option<String> {
    let ns = login.to_lowercase();
    (in_grammar(&ns) && !reserved(&ns)).then_some(ns)
}

/// `^[a-z0-9]+(-[a-z0-9]+)*$`, at most 39 characters.
fn in_grammar(ns: &str) -> bool {
    ns.len() <= NAMESPACE_MAX_LENGTH
        && ns.split('-').all(|part| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
        })
}

/// `^(noarch|(linux|osx|win|freebsd|zos|wasi|emscripten)-[a-z0-9]+)$`, or a reserved name. Called on a
/// string in the grammar only.
fn reserved(ns: &str) -> bool {
    let subdir = match ns.split_once('-') {
        Some((platform, arch)) => CONDA_SUBDIR_PLATFORMS.contains(&platform) && !arch.contains('-'),
        None => ns == "noarch",
    };
    subdir || RESERVED_NAMESPACES.contains(&ns)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_login_in_the_grammar_is_its_namespace_in_lower_case() {
        assert_eq!(
            user_namespace_for("Alice-Dev"),
            Some("alice-dev".to_string())
        );
        assert_eq!(user_namespace_for("a"), Some("a".to_string()));
        assert_eq!(user_namespace_for("0"), Some("0".to_string()));
        assert_eq!(user_namespace_for("a1-b2-c3"), Some("a1-b2-c3".to_string()));
        let longest = "a".repeat(39);
        assert_eq!(user_namespace_for(&longest), Some(longest.clone()));
        // Lower-casing is Unicode's, as JavaScript's `toLowerCase`: the Kelvin sign becomes `k`, and the dotted
        // capital I becomes `i` plus a combining dot, which is out of the grammar.
        assert_eq!(
            user_namespace_for("\u{212A}evin"),
            Some("kevin".to_string())
        );
        assert_eq!(user_namespace_for("\u{0130}nes"), None);
    }

    #[test]
    fn a_login_out_of_the_grammar_has_no_namespace() {
        let too_long = "a".repeat(40);
        for login in [
            "",
            "-",
            "-a",
            "a-",
            "a--b",
            "a_b",
            "a.b",
            "a b",
            " a",
            "a/b",
            "ä",
            "a\u{0}",
            too_long.as_str(),
        ] {
            assert_eq!(user_namespace_for(login), None, "{login:?}");
        }
    }

    #[test]
    fn reserved_names_and_conda_subdir_shapes_have_no_namespace() {
        for login in [
            "index",
            "quarantine",
            "native-mirror",
            "poll",
            "Poll",
            "noarch",
            "NoArch",
            "linux-64",
            "linux-aarch64",
            "osx-arm64",
            "win-64",
            "freebsd-x",
            "zos-z",
            "wasi-wasm32",
            "emscripten-wasm32",
        ] {
            assert_eq!(user_namespace_for(login), None, "{login:?}");
        }
    }

    #[test]
    fn near_misses_of_a_reserved_shape_are_namespaces() {
        for login in [
            "indexes",
            "polls",
            "native",
            "mirror",
            "noarch-64",
            "linux",
            "osx",
            "linux-64-x",
            "mac-64",
            "linuxx-64",
            "xlinux-64",
        ] {
            assert_eq!(
                user_namespace_for(login),
                Some(login.to_string()),
                "{login:?}"
            );
        }
    }

    #[test]
    fn a_record_is_stored_with_kind_in_lower_case_and_created_by_absent_for_a_user() {
        let user = NamespaceRecord {
            namespace: "alice".into(),
            kind: NamespaceKind::User,
            github_id: 7,
            created_at: "2026-11-19T12:00:00.000Z".into(),
            created_by: None,
        };
        let json = serde_json::to_value(&user).unwrap();
        assert_eq!(
            json,
            serde_json::json!({"namespace": "alice", "kind": "user", "github_id": 7, "created_at": "2026-11-19T12:00:00.000Z"})
        );
        assert_eq!(
            serde_json::from_value::<NamespaceRecord>(json).unwrap(),
            user
        );
        let org = NamespaceRecord {
            namespace: "acme".into(),
            kind: NamespaceKind::Org,
            github_id: 9,
            created_at: "2026-11-19T12:00:00.000Z".into(),
            created_by: Some(7),
        };
        let json = serde_json::to_value(&org).unwrap();
        assert_eq!(
            json,
            serde_json::json!({"namespace": "acme", "kind": "org", "github_id": 9, "created_at": "2026-11-19T12:00:00.000Z", "created_by": 7})
        );
        assert_eq!(
            serde_json::from_value::<NamespaceRecord>(json).unwrap(),
            org
        );
    }
}
