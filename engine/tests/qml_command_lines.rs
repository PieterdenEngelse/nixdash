//! A command the Dev page shows must be one the `Justfile` defines.
//!
//! The page tells you which build applies to what, so it is full of command
//! strings - and every one of them is a copy of something the Justfile
//! defines. A copy drifts, which is the whole argument of phase 13f in
//! `docs/layout-plan.md`: CLAUDE.md turned out to hold two spellings of the
//! same build. Within an hour of writing the Justfile this page had already
//! disagreed with it, twice over - one board joined a recipe's two commands
//! with `&&`, and another prescribed `cargo test --all` for a comment change,
//! which is the slow gate running for the cheapest possible edit.
//!
//! A shown command passes if either
//!
//! - it names a recipe: `just <name>`, where the recipe exists; or
//! - it **equals** one of a recipe's body lines, after a leading
//!   `cd ~/Projects/nixdash && ` is stripped (a recipe runs from the repo
//!   root already) and each `{{ param }}` is replaced by the default from its
//!   signature, so `NIXDASH_PORT={{ port }}` matches `NIXDASH_PORT=3199` and
//!   a wrong port still fails.
//!
//! Equality against a body line rather than a substring of the file, and that
//! difference is most of the test's value. `cargo test --all` appears inside
//! `gate-all`'s body, so a substring rule called it defined - which is
//! precisely how this page came to prescribe the slow gate for a comment
//! change and keep passing. A fragment of some other recipe is not a command
//! this project defines, and a page that wants to show one must name the
//! recipe instead.
//!
//! **An ellipsis means "abbreviated on purpose".** A column is narrow and
//! some rows show `nix develop ./ui-wasm … build.sh` rather than the whole line,
//! with the full form on the "Commands" board. `…` is the marker for
//! that, and a value carrying one is skipped rather than being made to match
//! something it is openly not.
//!
//! Earlier this scanned only the "Commands" board, so board 4's command
//! column was never read at all. Narrow tests miss what is next to them.
//!
//! Lives in the engine's test directory for the dull reason that this is the
//! only test harness the project has; it reads `../qml` and `../Justfile` as
//! data.

use std::{fs, path::Path};

/// Lines that are shown but deliberately have no recipe, with the argument.
const EXEMPT: &[(&str, &str)] = &[(
    "sudo nixos-rebuild switch",
    "The system half, and the one command on that page which is not this \
     project's to run. nixdash never needs it for itself - it appears there \
     to answer \"which of the two switches?\", and a recipe would imply this \
     repo drives system rebuilds, which it deliberately does not: the engine \
     holds no privilege and /etc/nixos belongs to the machine, not the tree.",
)];

/// What makes a `value:` a command rather than prose. "read the ↳ line" and
/// "+ both build.rs" are values too, and neither is something you run.
const COMMAND_STARTS: &[&str] = &[
    "just ",
    "cd ",
    "nix ",
    "cargo ",
    "sudo ",
    "home-manager ",
    "systemctl ",
    "./",
    "NIXDASH_PORT=",
    "PORT=",
];

fn repo() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("engine/ has a parent")
}

/// Recipe names, and the recipes' body lines with `{{ param }}` resolved.
///
/// A body line is an indented line under a recipe header, trimmed. Comments
/// and blank lines are not bodies, so prose that happens to quote a command -
/// and this Justfile quotes several, explaining why they are not used - can
/// never make the page's copy look defined.
///
/// Each recipe's parameters are resolved in ITS OWN body, which is the whole
/// subtlety here. This was one global substitution per parameter name, sound
/// only while no two recipes shared a parameter name - and the comment saying
/// so named `port` as the only one. Three recipes take `port` now
/// (`watch-browser`, `engine`, `serve`), and the global pass resolved every
/// `{{ port }}` in the file to the default of whichever recipe appeared
/// FIRST. So `engine`'s body came out as `NIXDASH_PORT=8099` - watch-browser's
/// default, from eighty lines earlier - and the Dev page's correct `3199`
/// was reported as a command that no recipe defines.
///
/// The failure pointed at the page, which was right, and at a recipe that
/// existed and matched. Scoping the substitution is what makes the two agree
/// again, and it cannot drift back: a fourth recipe taking `port` changes
/// nothing now.
fn justfile() -> (Vec<String>, Vec<String>) {
    let text = fs::read_to_string(repo().join("Justfile")).expect("Justfile should be readable");
    let mut names = Vec::new();
    let mut bodies: Vec<String> = Vec::new();
    // Parameters of the recipe whose body we are currently inside.
    let mut params: Vec<(String, String)> = Vec::new();

    for line in text.lines() {
        // Indented: a body line of the recipe last seen. A leading `@`
        // suppresses echo in just and is not part of the command.
        if line.starts_with(char::is_whitespace) {
            let body = line.trim().trim_start_matches('@');
            if body.is_empty() || body.starts_with('#') {
                continue;
            }
            let mut body = body.to_string();
            for (param, default) in &params {
                body = body.replace(&format!("{{{{ {param} }}}}"), default);
            }
            bodies.push(body);
            continue;
        }
        // A recipe line starts at column 0 and ends in a colon:
        // `name:` or `name param="default":`
        if line.starts_with('#') {
            continue;
        }
        let Some((head, _)) = line.split_once(':') else {
            continue;
        };
        let mut parts = head.split_whitespace();
        let Some(name) = parts.next() else {
            continue;
        };
        if !name.chars().all(|ch| ch.is_ascii_lowercase() || ch == '-') {
            continue;
        }
        names.push(name.to_string());
        params.clear();
        for part in parts {
            if let Some((param, rest)) = part.split_once("=\"") {
                params.push((param.to_string(), rest.trim_end_matches('"').to_string()));
            }
        }
    }

    (names, bodies)
}

/// Every literal `value:` on the Dev page, with the line it sits on.
fn shown_values() -> Vec<(usize, String)> {
    let src = fs::read_to_string(repo().join("qml").join("DevPage.qml"))
        .expect("DevPage.qml should be readable");
    let mut out = Vec::new();
    for (n, line) in src.lines().enumerate() {
        let mut rest = line;
        while let Some(at) = rest.find("value: \"") {
            let after = &rest[at + "value: \"".len()..];
            match after.find('"') {
                Some(end) => {
                    out.push((n + 1, after[..end].to_string()));
                    rest = &after[end + 1..];
                }
                None => break,
            }
        }
    }
    out
}

#[test]
fn every_command_shown_on_the_dev_page_is_a_recipe() {
    let (names, bodies) = justfile();
    let mut checked = 0usize;
    let mut failures = Vec::new();

    for (line, value) in shown_values() {
        // Abbreviated on purpose; the full form is on the lines-in-full board.
        if value.contains('…') {
            continue;
        }
        if !COMMAND_STARTS.iter().any(|p| value.starts_with(p)) {
            continue;
        }
        if EXEMPT.iter().any(|(c, _)| *c == value) {
            continue;
        }
        checked += 1;

        // The dev-shell prefix is not part of a command's identity.
        //
        // `just` lives in the dev shell, so the full form of a recipe row -
        // the one you can paste into an ordinary terminal - is
        // `cd <repo> && nix develop --command just <name>`. That names a
        // recipe as surely as `just <name>` does, and asking for a body line
        // equal to it would mean inventing a recipe whose body is a way of
        // running recipes.
        //
        // This was nearly an EXEMPT entry instead, which would have recorded
        // "this line has no recipe" about a line whose recipe is in its own
        // text. The rule is "names a recipe, however it is reached".
        let named = value
            .strip_prefix("cd ~/Projects/nixdash && ")
            .unwrap_or(value.as_str());
        let named = named
            .strip_prefix("nix develop --command ")
            .or_else(|| named.strip_prefix("nix develop ./ui-wasm --command "))
            .unwrap_or(named);

        // `just <name>` is satisfied by the recipe existing.
        if let Some(rest) = named.strip_prefix("just ") {
            let recipe = rest.split_whitespace().next().unwrap_or("");
            if names.iter().any(|n| n == recipe) {
                continue;
            }
            failures.push(format!(
                "DevPage.qml:{line} runs `just {recipe}`, which is not a \
                 recipe.\n    Defined: {}",
                names.join(", ")
            ));
            continue;
        }

        let body = value
            .strip_prefix("cd ~/Projects/nixdash && ")
            .unwrap_or(value.as_str());
        if !bodies.iter().any(|b| b == body) {
            failures.push(format!(
                "DevPage.qml:{line} shows:\n      {value}\n    which is not a \
                 recipe body line:\n      {body}\n    Make the page and the \
                 recipe agree, name the recipe instead (`just …`), or exempt \
                 the line with a reason. A fragment of another recipe does \
                 not count - that is how `cargo test --all` passed while \
                 prescribing the slow gate for a comment change."
            ));
        }
    }

    assert!(
        checked >= 8,
        "only {checked} commands checked on the Dev page - the scanner is \
         broken, or the page lost its command columns"
    );
    assert!(
        failures.is_empty(),
        "{checked} commands checked, {} not defined:\n\n{}",
        failures.len(),
        failures.join("\n\n")
    );
}

/// An exemption without a reason is just a silenced test.
#[test]
fn every_command_exemption_is_argued() {
    for (cmd, reason) in EXEMPT {
        assert!(
            reason.len() > 60,
            "{cmd}: exemption reason is {} chars - argue why this line has no \
             recipe, or give it one",
            reason.len()
        );
    }
}
