//! No single info body may be long enough to need scrolling.
//!
//! `InfoButton.qml`'s header states the rule: when a panel carries more than
//! about three screens of prose, split it with `sections` rather than making
//! people scroll past what they did not want. It was stated only in a comment
//! and was promptly broken by a 2607-character tab - written, reviewed and
//! shipped without anyone rereading the header it violated.
//!
//! A hook was the obvious enforcement and is the wrong one here. The hook
//! this project already has fires on the editor's write tools, and an agent
//! editing through `sed` or a here-doc never trips it - which is exactly how
//! that 2607-character tab was written. A test cannot be side-stepped by
//! changing how the file is edited, and the quality gate already runs it.
//!
//! What it measures is CHARACTERS, including markup, not rendered height. A
//! proxy, deliberately: the panel sizes itself to its tallest tab and the
//! real limit is the window, which a test cannot see. The threshold is set
//! from the corpus rather than invented - see LIMIT.
//!
//! Lives in the engine's test directory for the dull reason that this is the
//! only test harness the project has; it reads `../qml` as data.

use std::{
    fs,
    path::{Path, PathBuf},
};

/// Characters in one body, markup included, before it is too long.
///
/// Calibrated against the 362 bodies that existed when this was written:
/// median 108, longest 1548. 1800 leaves every one of them alone and catches
/// the next outlier. Raising it is a decision about the product, not a way to
/// get a red test green - if a body genuinely needs more room, it needs
/// splitting into sections, which is the whole point.
const LIMIT: usize = 1800;

/// Bodies that have earned their length, with the argument for it.
///
/// Expected to stay empty. "It reads better as one block" is not an argument:
/// tabs exist precisely so that it can read as one block per tab.
const EXEMPT: &[(&str, &str)] = &[];

fn roots() -> Vec<PathBuf> {
    let engine = Path::new(env!("CARGO_MANIFEST_DIR"));
    let repo = engine.parent().expect("engine/ has a parent");
    vec![engine.join("src"), repo.join("qml")]
}

fn sources(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for e in entries.flatten() {
        let p = e.path();
        if p.is_dir() {
            sources(&p, out);
        } else if matches!(
            p.extension().and_then(|x| x.to_str()),
            Some("rs") | Some("qml")
        ) {
            out.push(p);
        }
    }
}

/// Reads the string literal whose opening quote is at `open`, following
/// `+` concatenation, and returns its text plus the index past the end.
///
/// Three things have to be undone to get the text a reader actually sees:
/// escapes, the backslash-newline continuation both Rust and JS use to wrap a
/// long literal in source, and QML's habit of splitting one body across
/// several literals joined with `+`. Measuring the first fragment only would
/// let any body pass by being wrapped differently.
fn read_literal(c: &[char], open: usize) -> (String, usize) {
    let mut out = String::new();
    let mut i = open;
    loop {
        i += 1; // past the opening quote
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
        i += 1; // past the closing quote

        let mut j = i;
        while j < c.len() && c[j].is_whitespace() {
            j += 1;
        }
        if j < c.len() && c[j] == '+' {
            let mut k = j + 1;
            while k < c.len() && c[k].is_whitespace() {
                k += 1;
            }
            if k < c.len() && c[k] == '"' {
                i = k;
                continue;
            }
        }
        return (out, i);
    }
}

fn matches_at(c: &[char], i: usize, pat: &str) -> bool {
    pat.chars()
        .enumerate()
        .all(|(n, ch)| c.get(i + n) == Some(&ch))
}

/// The opening quote of the literal assigned at `i`, if `i` starts `field:`.
fn value_at(c: &[char], i: usize, field: &str) -> Option<usize> {
    if !matches_at(c, i, field) {
        return None;
    }
    // Not a longer identifier ending in this one: `if_wrong` must not match
    // inside `root_if_wrong`.
    if i > 0 && (c[i - 1].is_alphanumeric() || c[i - 1] == '_') {
        return None;
    }
    let mut j = i + field.chars().count();
    while j < c.len() && c[j].is_whitespace() {
        j += 1;
    }
    (j < c.len() && c[j] == '"').then_some(j)
}

/// The nearest `title:` before `at`, which is how a section identifies itself.
fn title_before(c: &[char], at: usize) -> Option<String> {
    let from = at.saturating_sub(600);
    (from..at)
        .rev()
        .find_map(|i| value_at(c, i, "title:").map(|q| read_literal(c, q).0))
}

#[test]
fn no_info_body_is_long_enough_to_need_scrolling() {
    let mut files = Vec::new();
    for r in roots() {
        sources(&r, &mut files);
    }

    let mut checked = 0usize;
    let mut failures = Vec::new();

    for path in files {
        let Ok(text) = fs::read_to_string(&path) else {
            continue;
        };
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        let c: Vec<char> = text.chars().collect();

        let mut i = 0usize;
        while i < c.len() {
            let field = ["body:", "what:", "why:", "if_wrong:", "ifWrong:"]
                .into_iter()
                .find_map(|f| value_at(&c, i, f).map(|q| (f, q)));

            let Some((field, quote)) = field else {
                i += 1;
                continue;
            };

            let (body, end) = read_literal(&c, quote);
            i = end;
            checked += 1;

            if body.chars().count() <= LIMIT {
                continue;
            }
            let label =
                title_before(&c, quote).unwrap_or_else(|| field.trim_end_matches(':').to_string());
            let key = format!("{name}:{label}");
            if EXEMPT.iter().any(|(k, _)| *k == key) {
                continue;
            }
            let line = text[..text.char_indices().nth(quote).map(|(b, _)| b).unwrap_or(0)]
                .lines()
                .count();
            failures.push(format!(
                "{name}:{line} - \"{label}\" is {} characters, over the {LIMIT} limit.\n    \
                 More room means a tab or a link, never more characters: split \
                 it into sections, or link out if the material is upstream's \
                 to hold rather than ours. A reader should not have to scroll \
                 past the part they did not want. See the header of \
                 qml/InfoButton.qml.",
                body.chars().count()
            ));
        }
    }

    assert!(
        checked > 100,
        "matched only {checked} bodies - the scanner is broken"
    );
    assert!(
        failures.is_empty(),
        "{} of {checked} info bodies are too long:\n\n{}",
        failures.len(),
        failures.join("\n\n")
    );
}

/// An exemption without a reason is just a silenced test.
#[test]
fn every_length_exemption_is_argued() {
    for (key, reason) in EXEMPT {
        assert!(
            reason.len() > 60,
            "{key}: exemption reason is {} chars - argue why this body cannot \
             be split, or split it",
            reason.len()
        );
    }
}
