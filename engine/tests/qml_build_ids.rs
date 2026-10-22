//! A Run button's id must name something the engine can actually run.
//!
//! The Dev page's "Commands" rows carry a `buildId`, and pressing one
//! posts that id to `/api/builds/{id}/run`. The id is the whole contract: the
//! page sends no command, and the engine looks the id up in a compile-time
//! list. So a typo is not a compile error on either side - it is a button
//! that 404s when pressed, which is exactly the failure this project has been
//! bitten by before (`qml_board_refs` exists for the same reason, for panel
//! ids).
//!
//! Both directions are checked. An id in QML with no entry is a dead button;
//! an entry with no id in QML is something runnable that nothing can reach,
//! which is usually a row that was renamed or deleted.

use std::{collections::BTreeSet, fs};

/// Ids the engine defines, read from the registry rather than copied here -
/// a second list would be the drift this test exists to catch.
fn defined() -> BTreeSet<String> {
    nixdash_engine::builds::all()
        .iter()
        .map(|b| b.id.to_string())
        .collect()
}

/// Every `buildId: "…"` that appears in the QML tree.
fn referenced() -> BTreeSet<(String, String)> {
    let mut out = BTreeSet::new();
    let dir = std::path::Path::new("../qml");
    for entry in fs::read_dir(dir).expect("read ../qml") {
        let path = entry.expect("dir entry").path();
        if path.extension().and_then(|e| e.to_str()) != Some("qml") {
            continue;
        }
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("?")
            .to_string();
        let text = fs::read_to_string(&path).expect("read qml");
        for (i, _) in text.match_indices("buildId:") {
            let rest = &text[i + "buildId:".len()..];
            // The value is a quoted literal; anything else is not an id this
            // test can check, and there are none today.
            let Some(open) = rest.find('"') else { continue };
            let after = &rest[open + 1..];
            let Some(close) = after.find('"') else {
                continue;
            };
            out.insert((name.clone(), after[..close].to_string()));
        }
    }
    out
}

#[test]
fn every_build_id_in_qml_is_runnable() {
    let defined = defined();
    let dangling: Vec<String> = referenced()
        .iter()
        .filter(|(_, id)| !defined.contains(id))
        .map(|(file, id)| format!("{file} references buildId \"{id}\""))
        .collect();

    assert!(
        dangling.is_empty(),
        "these Run buttons would 404 when pressed - no such entry in \
         engine/src/builds.rs:\n  {}\ndefined: {:?}",
        dangling.join("\n  "),
        defined
    );
}

#[test]
fn every_runnable_build_is_reachable() {
    let referenced: BTreeSet<String> = referenced().into_iter().map(|(_, id)| id).collect();
    let unreachable: Vec<String> = defined()
        .into_iter()
        .filter(|id| !referenced.contains(id))
        .collect();

    assert!(
        unreachable.is_empty(),
        "these entries can be run but no button reaches them - a renamed or \
         deleted row leaves this behind: {unreachable:?}"
    );
}
