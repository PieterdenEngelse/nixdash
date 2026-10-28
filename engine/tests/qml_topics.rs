//! A topic that routes nowhere renders an empty page, silently.
//!
//! `Main.qml` holds the third navigation level in two places that have to
//! agree: `qtTopics`, which the subpage strip and the breadcrumb read, and
//! `devComponent()`, which decides what the Loader shows. Add a topic to the
//! first and forget the second and the strip offers a destination that lands
//! on the overview - no error, no warning, just the wrong page. Name a
//! `Component` whose QML file does not exist and the Loader renders nothing
//! at all.
//!
//! Bundle membership is NOT checked here. `qml_registered` already does it,
//! in both directions including the dangling entry a rename leaves behind;
//! a second weaker copy was written in this file and removed.
//!
//! Both failures were reachable when this was written. Phases 1 and 2 of
//! `docs/qt-page-plan.md` were each verified by clicking all three levels,
//! which is the only check that existed: `./qml-check` cannot see a strip
//! that sets a property nothing routes on, and an offscreen run reports no
//! QML errors at all. The plan's own phase 4 is this file - a phase is not
//! finished when the code is written, it is finished when something fails if
//! the code regresses.
//!
//! Reads `../qml/Main.qml` as data, and lives here because the engine is the
//! only test harness the project has.

use std::{fs, path::Path, path::PathBuf};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("engine/ has a parent")
        .to_path_buf()
}

fn main_qml() -> String {
    let p = repo_root().join("qml/Main.qml");
    fs::read_to_string(&p).unwrap_or_else(|e| panic!("reading {}: {e}", p.display()))
}

/// The ids declared in `qtTopics`, in order.
///
/// The empty id is the overview and is deliberately included: it is a real
/// entry in the strip, and `devComponent()` reaching it through the final
/// fallthrough rather than a branch is the thing that makes it correct.
fn declared_topics(src: &str) -> Vec<String> {
    let start = src
        .find("qtTopics:")
        .expect("Main.qml declares qtTopics - the navigation depends on it");
    let rest = &src[start..];
    let end = rest.find(']').expect("qtTopics is a list literal");
    rest[..end]
        .match_indices("\"id\":")
        .filter_map(|(i, _)| {
            let after = &rest[start_of_value(rest, i)..];
            let open = after.find('"')?;
            let tail = &after[open + 1..];
            let close = tail.find('"')?;
            Some(tail[..close].to_string())
        })
        .collect()
}

fn start_of_value(s: &str, id_at: usize) -> usize {
    id_at + "\"id\":".len().min(s.len() - id_at)
}

/// The body of `devComponent()`, where topic ids become page components.
fn dev_component_body(src: &str) -> &str {
    let start = src
        .find("function devComponent()")
        .expect("Main.qml routes the Dev tab through devComponent()");
    let rest = &src[start..];
    let open = rest.find('{').expect("a function has a body");
    let mut depth = 0i32;
    for (i, ch) in rest[open..].char_indices() {
        match ch {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return &rest[open..open + i + 1];
                }
            }
            _ => {}
        }
    }
    panic!("devComponent() body is unbalanced");
}

#[test]
fn every_qt_topic_is_routed() {
    let src = main_qml();
    let topics = declared_topics(&src);
    assert!(
        topics.len() >= 2,
        "found {} topics - the parser is broken, or the third level was removed",
        topics.len()
    );
    assert!(
        topics.iter().any(|t| t.is_empty()),
        "qtTopics has no overview entry (id \"\"), which the strip needs"
    );

    let body = dev_component_body(&src);
    let mut missing = Vec::new();
    for id in topics.iter().filter(|t| !t.is_empty()) {
        // The branch tests the id; the string literal is the only way it can.
        if !body.contains(&format!("\"{id}\"")) {
            missing.push(id.clone());
        }
    }
    assert!(
        missing.is_empty(),
        "qtTopics offers {:?}, which devComponent() never tests for.\n    \
         The subpage strip will offer that destination and the Loader will \
         fall through to the overview - no error, just the wrong page. Add a \
         branch in devComponent() and the matching Component.",
        missing
    );
}

/// Each page component a Dev route names must exist as a file.
#[test]
fn every_routed_page_exists() {
    let src = main_qml();
    let body = dev_component_body(&src);

    // `return somePage` - the Component ids the router hands to the Loader.
    let ids: Vec<&str> = body
        .lines()
        .filter_map(|l| l.trim().strip_prefix("return "))
        .map(|s| s.trim_end_matches(';').trim())
        .collect();
    assert!(
        ids.len() >= 3,
        "devComponent() returns {} components - expected the overview, the \
         Dev page and at least one topic",
        ids.len()
    );

    let qml = repo_root().join("qml");
    let mut missing = Vec::new();
    for id in &ids {
        // `Component { id: qtWasmPage  QtWasmPage { ... } }` - find the type
        // the Component wraps, which is the file that must exist.
        let Some(at) = src.find(&format!("id: {id}")) else {
            missing.push(format!("{id}: no Component declares this id"));
            continue;
        };
        let after = &src[at..];
        let Some(type_name) = after
            .lines()
            .nth(1)
            .and_then(|l| l.split_whitespace().next())
            .map(|t| t.trim_end_matches('{').to_string())
            .filter(|t| t.chars().next().is_some_and(|c| c.is_ascii_uppercase()))
        else {
            missing.push(format!("{id}: could not read the type it wraps"));
            continue;
        };
        if !qml.join(format!("{type_name}.qml")).exists() {
            missing.push(format!("{id}: qml/{type_name}.qml does not exist"));
        }
    }
    assert!(
        missing.is_empty(),
        "broken Dev routes:\n    {}",
        missing.join("\n    ")
    );
}

/// The scanners must find the shapes they are for.
///
/// Same reason as `qml_text_style.rs`: a check that reports clean is
/// indistinguishable from one that is not running, and both parsers here read
/// a hand-written format that a reformat could silently defeat.
#[test]
fn the_parsers_catch_what_they_are_for() {
    let src = r#"
    readonly property var qtTopics: [
        { "id": "", "name": "Overview" },
        { "id": "prefix", "name": "Why there is no single Qt" }
    ]
    function devComponent() {
        if (root.subject !== "qt")
            return devPage
        if (root.topic === "prefix")
            return qtPrefixPage
        return devQtPage
    }
"#;
    let topics = declared_topics(src);
    assert_eq!(topics, vec!["".to_string(), "prefix".to_string()]);

    let body = dev_component_body(src);
    assert!(body.contains("\"prefix\""), "body was {body:?}");
    assert!(
        !body.contains("\"wasm\""),
        "an unrouted topic must not appear to be routed"
    );
}
