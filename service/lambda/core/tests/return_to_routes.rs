//! `return_to` against the site's own route vectors (site/test/fixtures/routes.json, which `parseRoute` and the edge
//! router are tested against): a path is kept exactly when the edge router serves a page for it (the home page, the
//! app shell or a docs page), and every other vector, a redirect, a search or a pass to the bucket, falls back.

use mopm_core::return_to::{validate_return_to, RETURN_TO_FALLBACK};
use serde_json::Value;

const ROUTES: &str = include_str!("../../../../site/test/fixtures/routes.json");

fn serves_a_page(edge: &str) -> bool {
    edge == "/index.html"
        || edge == "/app.html"
        || (edge.starts_with("/docs/") && edge.ends_with("index.html"))
}

#[test]
fn a_path_is_kept_exactly_when_the_site_serves_a_page_for_it() {
    let doc: Value = serde_json::from_str(ROUTES).unwrap();
    let vectors = doc["vectors"].as_array().unwrap();
    let mut kept = 0;
    for v in vectors {
        let path = v["path"].as_str().unwrap();
        let edge = v["edge"].as_str().unwrap();
        let want = if serves_a_page(edge) {
            path
        } else {
            RETURN_TO_FALLBACK
        };
        assert_eq!(validate_return_to(path), want, "{path:?} (edge {edge:?})");
        kept += usize::from(want == path);
    }
    // Both outcomes occur, so neither half of the rule is vacuous.
    assert!(
        kept > 0 && kept < vectors.len(),
        "{kept} of {}",
        vectors.len()
    );
}
