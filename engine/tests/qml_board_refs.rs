//! A provenance line that points at a numbered board must name one that
//! exists.
//!
//! `DevPage.qml` ends with a board of runnable command lines, and each line's
//! `↳` names the board that decides when to use it - "3 · Draws something
//! (twice)" rather than a bare "board 3". The full title was chosen over the
//! number precisely so that this test is possible: a renamed or renumbered
//! board breaks a string match, where a number would have gone on pointing
//! confidently at whatever now sits in that position.
//!
//! The pointer has to name a board in the SAME file, because what it means is
//! "the board above, on this page".
//!
//! Scope is deliberately narrow. A provenance line is usually a file path or
//! a note, and only the ones shaped like a numbered board - a leading digit
//! and a `·` - are read as cross-references. Everything else is left alone.
//!
//! Lives in the engine's test directory for the dull reason that this is the
//! only test harness the project has; it reads `../qml` as data.

use std::{
    fs,
    path::{Path, PathBuf},
};

fn qml_files() -> Vec<PathBuf> {
    let engine = Path::new(env!("CARGO_MANIFEST_DIR"));
    let qml = engine.parent().expect("engine/ has a parent").join("qml");
    let mut out = Vec::new();
    if let Ok(entries) = fs::read_dir(&qml) {
        for e in entries.flatten() {
            let p = e.path();
            if p.extension().and_then(|x| x.to_str()) == Some("qml") {
                out.push(p);
            }
        }
    }
    out.sort();
    out
}

/// Reads the string literal whose opening quote is at `open`, undoing escapes
/// and the backslash-newline continuation QML uses to wrap a long literal.
///
/// `+` concatenation is not followed. Neither field this reads uses it, and a
/// concatenated value would still yield its first fragment - which is where a
/// pointer lives, so the check would still see it.
fn read_literal(c: &[char], open: usize) -> String {
    let mut out = String::new();
    let mut i = open + 1;
    while i < c.len() && c[i] != '"' {
        if c[i] == '\\' && i + 1 < c.len() {
            if c[i + 1] == '\n' {
                i += 2;
                while i < c.len() && (c[i] == ' ' || c[i] == '\t') {
                    i += 1;
                }
            } else {
                out.push(c[i + 1]);
                i += 2;
            }
        } else {
            out.push(c[i]);
            i += 1;
        }
    }
    out
}

fn matches_at(c: &[char], i: usize, pat: &str) -> bool {
    pat.chars()
        .enumerate()
        .all(|(n, ch)| c.get(i + n) == Some(&ch))
}

/// Every `field:` string literal in the file, with the 1-based line it is on.
fn values(c: &[char], field: &str) -> Vec<(usize, String)> {
    let mut out = Vec::new();
    let mut line = 1usize;
    let mut i = 0usize;
    while i < c.len() {
        if c[i] == '\n' {
            line += 1;
        }
        // Not a longer identifier ending in this one.
        let standalone = i == 0 || !(c[i - 1].is_alphanumeric() || c[i - 1] == '_');
        if standalone && matches_at(c, i, field) {
            let mut j = i + field.chars().count();
            while j < c.len() && (c[j] == ' ' || c[j] == '\t') {
                j += 1;
            }
            if j < c.len() && c[j] == '"' {
                out.push((line, read_literal(c, j)));
            }
        }
        i += 1;
    }
    out
}

/// The board a provenance line points at: the text before the first ` - `,
/// when it is shaped like a numbered board. `None` for ordinary provenance.
fn pointer(source: &str) -> Option<&str> {
    let head = source.split(" - ").next()?.trim();
    if !head.starts_with(|ch: char| ch.is_ascii_digit()) {
        return None;
    }
    head.contains(" · ").then_some(head)
}

#[test]
fn every_board_pointer_names_a_board_in_the_same_file() {
    let mut checked = 0usize;
    let mut failures = Vec::new();

    for path in qml_files() {
        let Ok(text) = fs::read_to_string(&path) else {
            continue;
        };
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        let c: Vec<char> = text.chars().collect();

        let titles: Vec<String> = values(&c, "title:").into_iter().map(|(_, t)| t).collect();

        for (line, source) in values(&c, "source:") {
            let Some(target) = pointer(&source) else {
                continue;
            };
            checked += 1;
            if !titles.iter().any(|t| t == target) {
                failures.push(format!(
                    "{name}:{line} points at \"{target}\", which is not a \
                     section title in that file.\n    Titles there: {}\n    \
                     Either the board was renamed and this pointer was left \
                     behind, or the pointer has a typo. A reader following it \
                     finds nothing.",
                    titles
                        .iter()
                        .map(|t| format!("{t:?}"))
                        .collect::<Vec<_>>()
                        .join(", ")
                ));
            }
        }
    }

    assert!(
        checked >= 3,
        "found only {checked} board pointers - the scanner is broken, or the \
         command lines on the Dev page lost their ↳ references"
    );
    assert!(
        failures.is_empty(),
        "{} of {checked} board pointers do not resolve:\n\n{}",
        failures.len(),
        failures.join("\n\n")
    );
}
