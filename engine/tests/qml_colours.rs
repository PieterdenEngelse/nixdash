//! Every colour is defined in `Style.qml` and nowhere else.
//!
//! Phase 13a of `docs/layout-plan.md` centralised 62 hex literals spread over
//! 13 files - 20 distinct shades, three greens for "good", three reds for
//! "bad" - each picked independently while writing the file it appeared in.
//! The problem was never which hues; it was that one role had several values
//! and nothing said which was right.
//!
//! 13a's own "done when" asked for two things: zero literals outside
//! `Style.qml`, and a test enforcing it. The first was done in 7310c30. This
//! is the second, which went unwritten for ten days - long enough for the
//! centralisation to have quietly rotted, and the reason a convention without
//! a check is only a convention until someone is in a hurry.
//!
//! **Comments are not violations.** `MonitorPage.qml` reasons about a contrast
//! ratio in prose, and `Main.qml` recounts the light-assuming literals that
//! 13a removed; both name hex values and neither paints anything. So this
//! scans string literals only, tracking strings and comments as it goes
//! rather than regexing the file - a `//` inside `"https://doc.qt.io/…"` is
//! not a comment, and a `#ffffff` inside a comment is not a colour.
//!
//! Lives in the engine's test directory for the dull reason that this is the
//! only test harness the project has; it reads `../qml` as data.

use std::{
    fs,
    path::{Path, PathBuf},
};

/// The one file allowed to name colours.
const PALETTE: &str = "Style.qml";

/// Literals that have earned their place, with the argument for them.
///
/// Expected to stay empty. "It is only used once" is not an argument - that is
/// precisely a role with one use, which is a role, which belongs in Style.qml.
const EXEMPT: &[(&str, &str)] = &[];

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

/// Hex colour literals appearing inside string literals, as (line, text).
///
/// QML has no bare colour syntax - a colour is always a string, or a `#rrggbb`
/// inside one of the rich-text bodies - so being in a string is what separates
/// a painted colour from one merely talked about.
fn colours_in_strings(src: &str) -> Vec<(usize, String)> {
    let c: Vec<char> = src.chars().collect();
    let mut out = Vec::new();
    let mut line = 1usize;
    let mut i = 0usize;

    while i < c.len() {
        match c[i] {
            '\n' => {
                line += 1;
                i += 1;
            }
            // A comment, which may contain anything at all.
            '/' if c.get(i + 1) == Some(&'/') => {
                while i < c.len() && c[i] != '\n' {
                    i += 1;
                }
            }
            '/' if c.get(i + 1) == Some(&'*') => {
                i += 2;
                while i < c.len() && !(c[i] == '*' && c.get(i + 1) == Some(&'/')) {
                    if c[i] == '\n' {
                        line += 1;
                    }
                    i += 1;
                }
                i = (i + 2).min(c.len());
            }
            '"' | '\'' => {
                let quote = c[i];
                i += 1;
                while i < c.len() && c[i] != quote {
                    // An escape, including the backslash-newline QML uses to
                    // wrap a long literal.
                    if c[i] == '\\' && i + 1 < c.len() {
                        if c[i + 1] == '\n' {
                            line += 1;
                        }
                        i += 2;
                        continue;
                    }
                    if c[i] == '\n' {
                        line += 1;
                    }
                    if c[i] == '#' {
                        let hex: String = c[i + 1..]
                            .iter()
                            .take_while(|ch| ch.is_ascii_hexdigit())
                            .collect();
                        if matches!(hex.len(), 3 | 6 | 8) {
                            out.push((line, format!("#{hex}")));
                        }
                    }
                    i += 1;
                }
                i += 1; // past the closing quote
            }
            _ => i += 1,
        }
    }
    out
}

#[test]
fn no_colour_is_defined_outside_the_palette() {
    let mut failures = Vec::new();
    let mut scanned = 0usize;

    for path in qml_files() {
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        if name == PALETTE {
            continue;
        }
        let Ok(src) = fs::read_to_string(&path) else {
            continue;
        };
        scanned += 1;

        for (line, hex) in colours_in_strings(&src) {
            let key = format!("{name}:{hex}");
            if EXEMPT.iter().any(|(k, _)| *k == key) {
                continue;
            }
            failures.push(format!(
                "{name}:{line} paints {hex} directly.\n    Give the role a \
                 name in {PALETTE} and use it, so the next file that needs \
                 this shade cannot pick a different one. That is what 13a \
                 was for; see docs/layout-plan.md."
            ));
        }
    }

    assert!(
        scanned > 10,
        "scanned only {scanned} files besides {PALETTE} - the scanner is broken"
    );
    assert!(
        failures.is_empty(),
        "{} colour literal(s) outside {PALETTE}:\n\n{}",
        failures.len(),
        failures.join("\n\n")
    );
}

/// A scanner that finds nothing would pass the test above on an empty read.
#[test]
fn the_scanner_finds_the_colours_that_are_supposed_to_be_there() {
    let palette = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("engine/ has a parent")
        .join("qml")
        .join(PALETTE);
    let src = fs::read_to_string(&palette).expect("Style.qml should be readable");
    let found = colours_in_strings(&src);
    assert!(
        found.len() > 20,
        "found only {} colours in {PALETTE} - the scanner does not work",
        found.len()
    );
}

/// An exemption without a reason is just a silenced test.
#[test]
fn every_colour_exemption_is_argued() {
    for (key, reason) in EXEMPT {
        assert!(
            reason.len() > 60,
            "{key}: exemption reason is {} chars - argue why this colour \
             cannot be a named role, or name it",
            reason.len()
        );
    }
}
