//! The state machine of a version: `pending -> published -> yanked <-> published`, and any ->
//! `tombstoned` (terminal). `pending -> tombstoned` is how a rejected publish burns its number.
//!
//! [`apply_event`] is a pure function of the record and the event, as `applyEvent` of the
//! TypeScript registry is; an event that changes nothing (a second yank, a publish of a
//! published version, a second tombstone) is [`Applied::Unchanged`] rather than a copy with
//! a bumped `rev`.
//!
//! A `pending` row tagged with a `group_id` belongs to a group publish: a single `Publish` of it is
//! refused (`invalid_transition`), so a single publish can neither take over nor show a group's member.

use crate::error::{Detail, ErrorCode, RegistryError};
use crate::types::{Dep, FileRef, NativeRef, Tombstone, VersionRecord, VersionState};

/// What the validator learned from the archives, written when the version goes `pending -> published`:
/// a pending record is only a reserved number, and these fields come from the validated files. The
/// display fields are what the commit request carried; `None` leaves the record's as they are.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PublishFill {
    pub version: String,
    pub build: String,
    pub requires_mojo: String,
    pub deps: Vec<Dep>,
    pub native: Vec<NativeRef>,
    pub files: Vec<FileRef>,
    pub manifest_sha256: String,
    pub published_at: String,
    pub published_by: Option<String>,
    pub description: Option<String>,
    pub license: Option<String>,
    pub repository: Option<String>,
    pub homepage: Option<String>,
    pub keywords: Option<Vec<String>>,
    pub readme: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VersionEvent {
    Publish(Option<Box<PublishFill>>),
    Yank { reason: String },
    Unyank,
    /// `unpublished`: a pending version being burned by a rejected publish; no file was ever published,
    /// so none is kept.
    Tombstone { reason_code: String, date: String, unpublished: bool },
}

impl VersionEvent {
    /// The event as it is named in messages: `publish`, `yank`, `unyank`, `tombstone`.
    pub const fn name(&self) -> &'static str {
        match self {
            VersionEvent::Publish(_) => "publish",
            VersionEvent::Yank { .. } => "yank",
            VersionEvent::Unyank => "unyank",
            VersionEvent::Tombstone { .. } => "tombstone",
        }
    }
}

/// The result of an event.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Applied {
    /// The event changes nothing; the record stands (and keeps its `rev`).
    Unchanged,
    /// The next record, with `rev` + 1.
    Changed(VersionRecord),
}

impl Applied {
    /// The record after the event: the given one when nothing changed.
    pub fn into_record(self, current: &VersionRecord) -> VersionRecord {
        match self {
            Applied::Unchanged => current.clone(),
            Applied::Changed(r) => r,
        }
    }
}

/// An event the state does not allow: `invalid_transition` (409).
fn illegal_transition(rec: &VersionRecord, ev: &VersionEvent) -> RegistryError {
    let action = ev.name();
    let state = rec.state.as_str();
    let detail: Detail = [("action", action), ("name", rec.name.as_str()), ("version", rec.version.as_str()), ("state", state)]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
    RegistryError::new(ErrorCode::InvalidTransition, format!("Cannot {action} '{}' {}: it is {state}.", rec.name, rec.version), detail)
}

fn changed(rec: &VersionRecord, patch: impl FnOnce(&mut VersionRecord)) -> Applied {
    let mut next = rec.clone();
    patch(&mut next);
    next.rev = rec.rev + 1;
    Applied::Changed(next)
}

fn tombstoned(rec: &VersionRecord, reason_code: &str, date: &str, unpublished: bool) -> Applied {
    // The bytes are gone; the sha256 stays so a lock can be explained.
    let files = if rec.state == VersionState::Pending && unpublished {
        Vec::new()
    } else {
        rec.files.iter().map(|f| FileRef { url: None, ..f.clone() }).collect()
    };
    changed(rec, |r| {
        r.state = VersionState::Tombstoned;
        r.tombstone = Some(Tombstone { reason_code: reason_code.to_string(), date: date.to_string() });
        r.files = files;
        r.yank_reason = None;
    })
}

fn fill(r: &mut VersionRecord, f: &PublishFill) {
    r.version.clone_from(&f.version);
    r.build.clone_from(&f.build);
    r.requires_mojo.clone_from(&f.requires_mojo);
    r.deps.clone_from(&f.deps);
    r.native.clone_from(&f.native);
    r.files.clone_from(&f.files);
    r.manifest_sha256.clone_from(&f.manifest_sha256);
    r.published_at.clone_from(&f.published_at);
    if f.published_by.is_some() {
        r.published_by.clone_from(&f.published_by);
    }
    if f.description.is_some() {
        r.description.clone_from(&f.description);
    }
    if f.license.is_some() {
        r.license.clone_from(&f.license);
    }
    if f.repository.is_some() {
        r.repository.clone_from(&f.repository);
    }
    if f.homepage.is_some() {
        r.homepage.clone_from(&f.homepage);
    }
    if f.keywords.is_some() {
        r.keywords.clone_from(&f.keywords);
    }
    if f.readme.is_some() {
        r.readme.clone_from(&f.readme);
    }
}

/// The next record for an event.
pub fn apply_event(rec: &VersionRecord, ev: &VersionEvent) -> Result<Applied, RegistryError> {
    use VersionEvent as E;
    use VersionState as S;
    match (rec.state, ev) {
        (S::Tombstoned, E::Tombstone { .. }) => Ok(Applied::Unchanged),
        (S::Tombstoned, _) => Err(illegal_transition(rec, ev)),

        // A pending row that belongs to a group is published by the group's own steps, never by a single publish.
        (S::Pending, E::Publish(_)) if rec.group_id.is_some() => Err(illegal_transition(rec, ev)),
        (S::Pending, E::Publish(f)) => Ok(changed(rec, |r| {
            r.state = S::Published;
            if let Some(f) = f {
                fill(r, f);
            }
        })),
        (S::Pending, E::Tombstone { reason_code, date, unpublished }) => Ok(tombstoned(rec, reason_code, date, *unpublished)),
        (S::Pending, _) => Err(illegal_transition(rec, ev)),

        (S::Published, E::Publish(_)) => Ok(Applied::Unchanged),
        (S::Published, E::Unyank) => Err(illegal_transition(rec, ev)),
        (S::Published, E::Yank { reason }) => {
            if reason.is_empty() {
                return Err(RegistryError::new(
                    ErrorCode::InvalidRequest,
                    "A yank needs a reason.",
                    [("detail".to_string(), "a yank needs a reason".to_string())].into_iter().collect(),
                ));
            }
            Ok(changed(rec, |r| {
                r.state = S::Yanked;
                r.yank_reason = Some(reason.clone());
            }))
        }
        (S::Published, E::Tombstone { reason_code, date, unpublished }) => Ok(tombstoned(rec, reason_code, date, *unpublished)),

        (S::Yanked, E::Yank { .. }) => Ok(Applied::Unchanged),
        (S::Yanked, E::Unyank) => Ok(changed(rec, |r| {
            r.state = S::Published;
            r.yank_reason = None;
        })),
        (S::Yanked, E::Tombstone { reason_code, date, unpublished }) => Ok(tombstoned(rec, reason_code, date, *unpublished)),
        (S::Yanked, E::Publish(_)) => Err(illegal_transition(rec, ev)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures::{group_row, hex, rec};
    use VersionState as S;

    fn yank() -> VersionEvent {
        VersionEvent::Yank { reason: "broken".to_string() }
    }
    fn publish() -> VersionEvent {
        VersionEvent::Publish(None)
    }
    fn tomb() -> VersionEvent {
        VersionEvent::Tombstone { reason_code: "malware".to_string(), date: "2026-10-12".to_string(), unpublished: false }
    }
    fn at(state: S) -> VersionRecord {
        let mut r = rec("p", "1.0.0");
        r.state = state;
        if state == S::Yanked {
            r.yank_reason = Some("old".to_string());
        }
        r
    }

    #[test]
    fn the_transition_table() {
        // [from, event, to]; to = None means the event is refused. service/api/test/state.test.ts, row by row.
        let table: Vec<(S, VersionEvent, Option<S>)> = vec![
            (S::Pending, publish(), Some(S::Published)),
            (S::Pending, tomb(), Some(S::Tombstoned)),
            (S::Pending, yank(), None),
            (S::Pending, VersionEvent::Unyank, None),
            (S::Published, yank(), Some(S::Yanked)),
            (S::Published, VersionEvent::Unyank, None),
            (S::Published, publish(), Some(S::Published)),
            (S::Published, tomb(), Some(S::Tombstoned)),
            (S::Yanked, VersionEvent::Unyank, Some(S::Published)),
            (S::Yanked, yank(), Some(S::Yanked)),
            (S::Yanked, tomb(), Some(S::Tombstoned)),
            (S::Yanked, publish(), None),
            (S::Tombstoned, publish(), None),
            (S::Tombstoned, yank(), None),
            (S::Tombstoned, VersionEvent::Unyank, None),
            (S::Tombstoned, tomb(), Some(S::Tombstoned)),
        ];
        assert_eq!(table.len(), 16, "4 states x 4 events");
        for (from, ev, to) in table {
            let r = at(from);
            match to {
                None => assert_eq!(apply_event(&r, &ev).unwrap_err().code, ErrorCode::InvalidTransition, "{from:?} + {}", ev.name()),
                Some(to) => assert_eq!(apply_event(&r, &ev).unwrap().into_record(&r).state, to, "{from:?} + {}", ev.name()),
            }
        }
    }

    #[test]
    fn a_real_change_bumps_rev_and_an_idempotent_one_changes_nothing() {
        let p = at(S::Published);
        match apply_event(&p, &yank()).unwrap() {
            Applied::Changed(n) => assert_eq!(n.rev, p.rev + 1),
            Applied::Unchanged => panic!("a yank of a published version changes it"),
        }
        assert_eq!(apply_event(&p, &publish()).unwrap(), Applied::Unchanged);
        let y = at(S::Yanked);
        assert_eq!(apply_event(&y, &yank()).unwrap(), Applied::Unchanged);
        // The first reason stands.
        assert_eq!(apply_event(&y, &yank()).unwrap().into_record(&y).yank_reason.as_deref(), Some("old"));
    }

    #[test]
    fn unyank_drops_the_reason_and_yank_sets_it() {
        let y = at(S::Yanked);
        let un = apply_event(&y, &VersionEvent::Unyank).unwrap().into_record(&y);
        assert_eq!(un.yank_reason, None);
        assert_eq!(un.rev, y.rev + 1);
        let p = at(S::Published);
        assert_eq!(apply_event(&p, &yank()).unwrap().into_record(&p).yank_reason.as_deref(), Some("broken"));
    }

    #[test]
    fn a_yank_needs_a_reason() {
        let p = at(S::Published);
        let err = apply_event(&p, &VersionEvent::Yank { reason: String::new() }).unwrap_err();
        assert_eq!(err.code, ErrorCode::InvalidRequest);
        assert_eq!(err.status(), 400);
        assert_eq!(err.message, "A yank needs a reason.");
        assert_eq!(err.detail["detail"], "a yank needs a reason");
    }

    #[test]
    fn a_tombstone_removes_urls_keeps_sha256_and_drops_a_yank_reason() {
        let y = at(S::Yanked);
        assert!(y.files.iter().all(|f| f.url.is_some()));
        let t = apply_event(&y, &tomb()).unwrap().into_record(&y);
        assert_eq!(t.state, S::Tombstoned);
        assert_eq!(t.tombstone, Some(Tombstone { reason_code: "malware".to_string(), date: "2026-10-12".to_string() }));
        assert_eq!(t.yank_reason, None);
        assert!(!t.files.is_empty());
        for f in &t.files {
            assert_eq!(f.url, None);
            assert_eq!(f.sha256, hex('a'));
        }
    }

    #[test]
    fn burning_a_pending_version_keeps_no_file_only_when_it_was_never_published() {
        let pending = at(S::Pending);
        let burned = VersionEvent::Tombstone { reason_code: "rejected".to_string(), date: "2026-10-12".to_string(), unpublished: true };
        assert!(apply_event(&pending, &burned).unwrap().into_record(&pending).files.is_empty());
        // The same flag on a published version does not drop its files.
        let published = at(S::Published);
        let t = apply_event(&published, &burned).unwrap().into_record(&published);
        assert_eq!(t.files.len(), 1);
        assert_eq!(t.files[0].url, None);
        // And a pending tombstone without the flag keeps them, without urls.
        let kept = apply_event(&pending, &tomb()).unwrap().into_record(&pending);
        assert_eq!(kept.files.len(), 1);
        assert_eq!(kept.files[0].url, None);
    }

    #[test]
    fn publish_writes_what_the_validator_learned() {
        let pending = at(S::Pending);
        let mut f = PublishFill {
            version: "1.0.0".to_string(),
            build: "mojo1.1.0_0".to_string(),
            requires_mojo: "==1.1.0".to_string(),
            deps: vec![Dep { name: "q".to_string(), range: None }],
            native: vec![],
            files: vec![],
            manifest_sha256: hex('9'),
            published_at: "2026-10-14T00:00:00Z".to_string(),
            published_by: Some("octocat".to_string()),
            description: Some("d".to_string()),
            license: None,
            repository: None,
            homepage: None,
            keywords: Some(vec!["k".to_string()]),
            readme: None,
        };
        let p = apply_event(&pending, &VersionEvent::Publish(Some(Box::new(f.clone())))).unwrap().into_record(&pending);
        assert_eq!(p.state, S::Published);
        assert_eq!(p.rev, 1);
        assert_eq!((p.build.as_str(), p.requires_mojo.as_str(), p.manifest_sha256.as_str()), ("mojo1.1.0_0", "==1.1.0", hex('9').as_str()));
        assert_eq!(p.published_by.as_deref(), Some("octocat"));
        assert_eq!(p.description.as_deref(), Some("d"));
        assert_eq!(p.keywords, Some(vec!["k".to_string()]));
        assert!(p.files.is_empty());
        // A field the fill does not carry stays as the record had it.
        let mut with_license = at(S::Pending);
        with_license.license = Some("MIT".to_string());
        f.published_by = None;
        let q = apply_event(&with_license, &VersionEvent::Publish(Some(Box::new(f)))).unwrap().into_record(&with_license);
        assert_eq!(q.license.as_deref(), Some("MIT"));
        assert_eq!(q.published_by, None);
    }

    #[test]
    fn refused_transitions_carry_the_code_the_status_and_the_spec_message() {
        // service/api/test/state.test.ts `refused`.
        let cases: Vec<(S, VersionEvent, &str)> = vec![
            (S::Pending, yank(), "Cannot yank 'p' 1.0.0: it is pending."),
            (S::Tombstoned, yank(), "Cannot yank 'p' 1.0.0: it is tombstoned."),
            (S::Published, VersionEvent::Unyank, "Cannot unyank 'p' 1.0.0: it is published."),
            (S::Pending, VersionEvent::Unyank, "Cannot unyank 'p' 1.0.0: it is pending."),
            (S::Tombstoned, VersionEvent::Unyank, "Cannot unyank 'p' 1.0.0: it is tombstoned."),
            (S::Tombstoned, publish(), "Cannot publish 'p' 1.0.0: it is tombstoned."),
            (S::Yanked, publish(), "Cannot publish 'p' 1.0.0: it is yanked."),
        ];
        for (from, ev, message) in cases {
            let err = apply_event(&at(from), &ev).unwrap_err();
            assert_eq!(err.code, ErrorCode::InvalidTransition);
            assert_eq!(err.status(), 409);
            assert_eq!(err.message, message);
            // The template renders to the same text from the detail.
            let view = crate::error::publish_error_view(&err);
            assert_eq!(view.body.message, message);
        }
    }

    #[test]
    fn a_tombstoned_version_never_changes() {
        let t = at(S::Tombstoned);
        for ev in [publish(), yank(), VersionEvent::Unyank] {
            assert!(apply_event(&t, &ev).is_err());
        }
        assert_eq!(apply_event(&t, &tomb()).unwrap(), Applied::Unchanged);
    }

    fn fill_for(version: &str) -> PublishFill {
        PublishFill {
            version: version.to_string(),
            build: "mojo1.0.0_0".to_string(),
            requires_mojo: "==1.0.0".to_string(),
            deps: vec![],
            native: vec![],
            files: vec![],
            manifest_sha256: hex('9'),
            published_at: "2026-10-14T00:00:00Z".to_string(),
            published_by: None,
            description: None,
            license: None,
            repository: None,
            homepage: None,
            keywords: None,
            readme: None,
        }
    }

    #[test]
    fn a_single_publish_refuses_a_pending_row_that_belongs_to_a_group() {
        // Reserved (no stamp), staged now, and staged at an attempt that has since moved on: none is the single path's to publish.
        for stamp in [None, Some(1), Some(7)] {
            let row = group_row(at(S::Pending), "g1", stamp);
            for ev in [VersionEvent::Publish(None), VersionEvent::Publish(Some(Box::new(fill_for("1.0.0"))))] {
                let err = apply_event(&row, &ev).unwrap_err();
                assert_eq!(err.code, ErrorCode::InvalidTransition, "stamp {stamp:?}");
                assert_eq!(err.status(), 409);
                assert_eq!(err.message, "Cannot publish 'p' 1.0.0: it is pending.");
            }
        }
    }

    #[test]
    fn a_pending_row_without_a_group_still_publishes() {
        // The guard is the group tag and nothing else: a stamp alone (it cannot occur without the tag) does not make a group row.
        let mut row = at(S::Pending);
        assert_eq!(apply_event(&row, &publish()).unwrap().into_record(&row).state, S::Published);
        row.staged_attempt = Some(1);
        assert_eq!(apply_event(&row, &publish()).unwrap().into_record(&row).state, S::Published);
    }

    #[test]
    fn a_group_row_can_be_burned_and_a_published_one_is_changed_without_losing_its_group() {
        // The group's own failure path burns its numbers: a tombstone is not refused, and it keeps the tag.
        let staged = group_row(at(S::Pending), "g1", Some(2));
        let burned = VersionEvent::Tombstone { reason_code: "rejected".to_string(), date: "2026-10-12".to_string(), unpublished: true };
        let t = apply_event(&staged, &burned).unwrap().into_record(&staged);
        assert_eq!((t.state, t.group_id.as_deref(), t.staged_attempt), (S::Tombstoned, Some("g1"), Some(2)));
        // A row the group flipped ignores its group: single events act on it as on any published row, and the tag survives.
        let flipped = VersionRecord { state: S::Published, ..group_row(at(S::Pending), "g1", Some(2)) };
        assert_eq!(apply_event(&flipped, &publish()).unwrap(), Applied::Unchanged);
        let y = apply_event(&flipped, &yank()).unwrap().into_record(&flipped);
        assert_eq!((y.state, y.group_id.as_deref(), y.staged_attempt), (S::Yanked, Some("g1"), Some(2)));
        let u = apply_event(&y, &VersionEvent::Unyank).unwrap().into_record(&y);
        assert_eq!((u.state, u.group_id.as_deref(), u.staged_attempt), (S::Published, Some("g1"), Some(2)));
    }
}
