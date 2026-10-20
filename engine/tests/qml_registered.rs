//! Every file in `qml/` must be listed in **both** resource lists.
//!
//! One `qml/` directory is compiled into two programs, and each has its own
//! list: `ui/build.rs` and `ui-wasm/rust/build.rs`. A file missing from one is
//! simply absent from that program's resource bundle, and the symptom is a
//! failed import rather than a missing file - so the desktop UI can work
//! perfectly while the browser one fails to load, from the same edit.
//!
//! This was documented in CLAUDE.md and on the Dev page, and guarded by a
//! `PostToolUse` hook that only fires when an agent writes through the
//! editor's tools. An edit made with `sed` - or by a person in vim - never
//! trips it.
//!
//! It matters more now than it did. `NIXDASH_QML_DIR` makes the desktop UI
//! read `qml/` straight from disk, so a new component renders there without
//! being in either list; the omission then surfaces at the next real build,
//! or in the browser, long after the edit. Hot reload without this test would
//! trade one class of fast feedback for a slower class of confusion.
//!
//! Both directions are checked: a file that no list mentions, and a list
//! entry whose file no longer exists - which is what a rename leaves behind.
//!
//! Lives in the engine's test directory for the dull reason that this is the
//! only test harness the project has; it reads the tree as data.

use std::{collections::BTreeSet, fs, path::Path};

const LISTS: &[&str] = &["ui/build.rs", "ui-wasm/rust/build.rs"];

fn repo() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("engine/ has a parent")
}

/// The `.qml` files on disk, as the `qml/<name>` strings a list would hold.
fn qml_files() -> BTreeSet<String> {
    let dir = repo().join("qml");
    let mut out = BTreeSet::new();
    for entry in fs::read_dir(&dir)
        .expect("qml/ should be readable")
        .flatten()
    {
        let path = entry.path();
        if path.extension().and_then(|x| x.to_str()) == Some("qml") {
            let name = path.file_name().unwrap().to_string_lossy();
            out.insert(format!("qml/{name}"));
        }
    }
    out
}

/// The `"qml/…"` strings a build script lists.
fn listed(list: &str) -> BTreeSet<String> {
    let text = fs::read_to_string(repo().join(list)).unwrap_or_else(|_| panic!("{list} missing"));
    let mut out = BTreeSet::new();
    let mut rest = text.as_str();
    while let Some(at) = rest.find("\"qml/") {
        let after = &rest[at + 1..];
        match after.find('"') {
            Some(end) => {
                out.insert(after[..end].to_string());
                rest = &after[end + 1..];
            }
            None => break,
        }
    }
    out
}

#[test]
fn every_qml_file_is_in_both_resource_lists() {
    let on_disk = qml_files();
    assert!(
        on_disk.len() > 20,
        "found only {} files in qml/ - the scanner is broken",
        on_disk.len()
    );

    let mut failures = Vec::new();
    for list in LISTS {
        let listed = listed(list);

        for file in on_disk.difference(&listed) {
            failures.push(format!(
                "{list} does not list {file}\n    Without it, that program's \
                 bundle has no such file and the import fails at runtime - \
                 while the other program, whose list does have it, works."
            ));
        }
        for stale in listed.difference(&on_disk) {
            failures.push(format!(
                "{list} lists {stale}, which is not on disk\n    A rename \
                 leaves this behind; the build then fails on a file nobody \
                 edited."
            ));
        }
    }

    assert!(
        failures.is_empty(),
        "{} resource-list problem(s) across {} files:\n\n{}",
        failures.len(),
        on_disk.len(),
        failures.join("\n\n")
    );
}
