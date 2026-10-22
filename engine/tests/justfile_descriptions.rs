//! Every recipe must describe itself in `just --list`.
//!
//! `just --list` is the documented way into this project - CLAUDE.md sends
//! you there before anything else - so a recipe that does not describe itself
//! is invisible to the one command meant to reveal it.
//!
//! The rule being enforced is the Justfile's own:
//!
//! > `just --list` shows the LAST comment line above a recipe, so each one
//! > keeps a single-line summary adjacent and its reasoning above a blank
//! > line.
//!
//! Written down there, and then broken by three of fourteen recipes. `fresh`
//! and `run` had the order inverted - summary at the top of the block,
//! reasoning below - so `--list` printed the last line of the reasoning:
//!
//! ```text
//! fresh  # and a pattern loose enough to catch both also catches this script.
//! run    # qml_url() in ui/src/main.rs. Putting it here would enshrine that trap.
//! ```
//!
//! `which` printed nothing at all, because its summary had drifted upwards
//! and was sitting above `run` - which is also why `run` carried two summary
//! lines and showed neither of them.
//!
//! None of that is a build failure, a lint, or anything a reader of the file
//! would notice: it is only visible by running `just --list` and looking. A
//! convention that lives in a comment is not a convention - the same lesson
//! `qml-grid-heights` and `qml_command_lines` are already here to record.

use std::fs;

/// Recipes allowed no summary, each with the reason why.
///
/// Empty, and worth keeping that way: fourteen recipes all manage a line.
const EXEMPT: &[(&str, &str)] = &[];

fn justfile() -> String {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("engine/ has a parent")
        .join("Justfile");
    fs::read_to_string(path).expect("Justfile should be readable")
}

/// The name of the recipe this line declares, if it declares one.
///
/// A recipe header starts at column 0 and ends in a colon, with an optional
/// parameter list: `name:`, `name dep:`, `name param="default":`. An
/// assignment (`x := y`) is not one, which is what the `:=` guard is for -
/// there are none today, and a test that silently reclassifies one later is
/// worse than one that never saw it.
fn recipe_name(line: &str) -> Option<String> {
    let (head, rest) = line.split_once(':')?;
    if rest.starts_with('=') {
        return None;
    }
    let name = head.split_whitespace().next()?;
    if name.is_empty() || !name.chars().all(|c| c.is_ascii_lowercase() || c == '-') {
        return None;
    }
    Some(name.to_string())
}

/// Each recipe, with the contiguous comment block directly above it.
///
/// Contiguous is the whole point: a blank line, or a body line, ends a block.
/// That is exactly how `just` decides what to print, so parsing it any other
/// way would test something other than what the user sees.
fn recipes() -> Vec<(usize, String, Vec<String>)> {
    let text = justfile();
    let mut out = Vec::new();
    let mut block: Vec<String> = Vec::new();

    for (i, line) in text.lines().enumerate() {
        if let Some(comment) = line.strip_prefix('#') {
            block.push(comment.trim().to_string());
            continue;
        }
        // An attribute - `[group('window')]`, `[private]` - sits between the
        // comment and the recipe and is part of the declaration, not a break
        // in it. `just` still prints the comment above it, so neither may
        // this: treating one as a block-ender reported eight recipes as
        // undocumented the day attributes were introduced.
        if line.starts_with('[') {
            continue;
        }
        if line.trim().is_empty() || line.starts_with(char::is_whitespace) {
            block.clear();
            continue;
        }
        if let Some(name) = recipe_name(line) {
            out.push((i + 1, name, block.clone()));
        }
        block.clear();
    }
    out
}

#[test]
fn every_recipe_describes_itself_in_just_list() {
    let mut failures = Vec::new();

    for (line, name, block) in recipes() {
        if EXEMPT.iter().any(|(r, _)| *r == name) {
            continue;
        }

        let Some(summary) = block.last() else {
            failures.push(format!(
                "Justfile:{line} `{name}` has no comment above it, so \
                 `just --list` prints nothing for it.\n    Put a one-line \
                 summary directly above the recipe."
            ));
            continue;
        };

        // More than one line in the contiguous block means the reasoning was
        // written below the summary instead of above a blank line, and the
        // reasoning's last line is what `--list` will print.
        if block.len() > 1 {
            failures.push(format!(
                "Justfile:{line} `{name}` has {} comment lines directly above \
                 it, so `just --list` prints the last one:\n      {summary}\n    \
                 Keep the one-line summary adjacent to the recipe and put the \
                 reasoning above a blank line.",
                block.len()
            ));
            continue;
        }

        // A summary is a sentence. The fragments this test was written for
        // were mid-sentence continuations, and both of these catch them.
        if !summary.ends_with('.') {
            failures.push(format!(
                "Justfile:{line} `{name}`'s summary does not end in a full \
                 stop, which is what a continued sentence looks like:\n      \
                 {summary}"
            ));
        } else if !summary.starts_with(|c: char| c.is_ascii_uppercase()) {
            failures.push(format!(
                "Justfile:{line} `{name}`'s summary does not start with a \
                 capital, which is what a continued sentence looks like:\n      \
                 {summary}"
            ));
        }
    }

    assert!(
        failures.is_empty(),
        "{} recipe(s) do not describe themselves in `just --list`:\n\n{}\n",
        failures.len(),
        failures.join("\n\n")
    );
}

#[test]
fn the_scanner_finds_the_recipes_that_are_supposed_to_be_there() {
    // A parser that quietly matched nothing would pass the test above while
    // checking not one recipe - the failure mode every scanner in this
    // directory guards against.
    let found: Vec<String> = recipes().into_iter().map(|(_, n, _)| n).collect();
    assert!(
        found.len() >= 12,
        "only {} recipes found - the Justfile parser is broken: {found:?}",
        found.len()
    );
    for expected in ["gate", "desktop", "browser", "serve", "which", "fresh"] {
        assert!(
            found.iter().any(|n| n == expected),
            "`{expected}` is not among the recipes found: {found:?}"
        );
    }
}

#[test]
fn every_description_exemption_is_argued() {
    for (recipe, reason) in EXEMPT {
        assert!(
            reason.len() > 60,
            "the exemption for `{recipe}` is {} characters: {reason:?}\n\
             A recipe hidden from `just --list` needs a real reason, not a \
             note that one exists.",
            reason.len()
        );
    }
}
