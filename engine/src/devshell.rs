//! Optional additions to the project's development shell.
//!
//! Tier 2 of making the Config page write things, and it runs straight into
//! the rule tier 1 established: **never parse or patch hand-written Nix**.
//! `flake.nix` carries comments that cost hours to learn - why `libglvnd` is
//! in `buildInputs` and not `packages`, why `QT_FORCE_STDERR_LOGGING` is set
//! at all. A program editing that text would eventually eat them.
//!
//! So the same shape as settings: one generated file, rewritten whole, that
//! the flake imports. The flake keeps its prose; this holds a list.
//!
//! **Only additions that can be verified afterwards.** Every entry names a
//! panel stat that flips once the change is live, so "did it work?" has an
//! answer in the app rather than being left to you. An addition nothing can
//! confirm is not offered - an app that claims to have changed something it
//! cannot observe is the failure mode this project keeps guarding against.

use std::path::PathBuf;

use anyhow::{bail, Result};
use serde::Serialize;

/// One thing that can be added to the dev shell.
#[derive(Debug, Clone, Serialize)]
pub struct Extra {
    pub key: &'static str,
    pub label: &'static str,
    /// Nix expression for a package to add, if any.
    pub package: Option<&'static str>,
    /// Environment variables the shell should carry, as (name, nix expr).
    pub env: Vec<(&'static str, &'static str)>,
    /// The panel stat that becomes true once this is live, so the claim is
    /// checkable rather than asserted.
    pub verified_by: &'static str,
    pub what: &'static str,
    pub why: &'static str,
    pub if_wrong: &'static str,
}

/// Everything the app may add. Adding an entry here is the only way to make
/// a new package offerable.
pub fn known() -> Vec<Extra> {
    vec![
        Extra {
            key: "lld",
            label: "lld linker",
            package: Some("lld"),
            env: vec![],
            verified_by: "rust.lld_available",
            what: "Adds the <tt>lld</tt> linker. Rust links the \
                   <tt>wasm32-unknown-unknown</tt> target with it, and \
                   nothing else here uses it.",
            why: "Off is the normal state here, not a missing piece: the \
                  browser UI links through <tt>emcc</tt>, and nothing in \
                  this project builds the bare \
                  <tt>wasm32-unknown-unknown</tt> target that needs \
                  <tt>lld</tt>.",
            if_wrong: "A bare-wasm build stopping at <tt>linker `lld` not \
                       found</tt> is this package missing, not a broken \
                       toolchain - the error names the linker, not the \
                       target. Switched on it is one small unused package.",
        },
        Extra {
            key: "rust-src",
            label: "Standard library sources (rust-src)",
            package: Some("rustPlatform.rustLibSrc"),
            env: vec![("RUST_SRC_PATH", "pkgs.rustPlatform.rustLibSrc")],
            verified_by: "rust.rust_src_available",
            what: "Adds the standard library source text and points \
                   RUST_SRC_PATH at it.",
            why: "rust-analyzer resolves std by reading these sources. \
                  Installing rustc does not bring them - they are a separate \
                  package. Without them the editor starts, runs, and reports \
                  every Vec, String and Option as unresolved, which reads as \
                  a broken language server rather than a missing component.",
            if_wrong: "Affects the editor only. No build behaviour changes, \
                       and nothing gets slower.",
        },
    ]
}

pub fn find(key: &str) -> Option<Extra> {
    known().into_iter().find(|e| e.key == key)
}

/// Where the generated file lives, relative to the project.
const RELATIVE: &str = "nix/devshell-extras.nix";

pub fn extras_path() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("NIXDASH_DEVSHELL_FILE") {
        return Some(PathBuf::from(p));
    }
    let dir = if let Ok(d) = std::env::var("NIXDASH_PROJECT_DIR") {
        PathBuf::from(d)
    } else {
        PathBuf::from(std::env::var("HOME").ok()?).join("Projects/nixdash")
    };
    dir.is_dir().then(|| dir.join(RELATIVE))
}

/// Which extras the generated file currently enables.
///
/// Parsing is tolerated only because the file's shape is ours: it is
/// regenerated whole on every write, so each key appears as its own marker
/// comment and nothing has to be inferred from Nix syntax.
pub fn read_enabled(text: &str) -> Vec<String> {
    known()
        .into_iter()
        .filter(|e| text.contains(&format!("# nixdash:{}", e.key)))
        .map(|e| e.key.to_string())
        .collect()
}

/// Render the whole file from the set of enabled keys.
pub fn render(enabled: &[String]) -> String {
    let all = known();
    let chosen: Vec<&Extra> = all
        .iter()
        .filter(|e| enabled.iter().any(|k| k == e.key))
        .collect();

    let mut packages = String::new();
    for e in &chosen {
        if let Some(pkg) = e.package {
            // The marker comment is what read_enabled looks for, so the file
            // never has to be parsed as Nix to know what is on.
            packages.push_str(&format!("    {pkg}   # nixdash:{}\n", e.key));
        }
    }
    if packages.is_empty() {
        packages.push_str("    # (none enabled)\n");
    }

    let mut env = String::new();
    for e in &chosen {
        for (name, expr) in &e.env {
            env.push_str(&format!(
                "    {name} = \"${{{expr}}}\";   # nixdash:{}\n",
                e.key
            ));
        }
    }

    format!(
        "# Generated by nixdash. Rewritten in full whenever a development\n\
         # shell addition is toggled - edits made here by hand will be lost.\n\
         #\n\
         # flake.nix imports this and appends it to the default devShell, so\n\
         # the flake keeps its comments and this file holds only the list.\n\
         #\n\
         # Writing this changes nothing on its own: re-enter the shell with\n\
         # `nix develop` for it to take effect.\n\
         {{ pkgs }}:\n\
         {{\n\
         \x20 packages = with pkgs; [\n\
         {packages}\x20 ];\n\
         \n\
         \x20 env = {{\n\
         {env}\x20 }};\n\
         }}\n"
    )
}

#[derive(Debug, Serialize)]
pub struct Change {
    pub key: String,
    pub enabled: bool,
    pub path: String,
    pub rendered: String,
    pub diff: Vec<String>,
}

/// Work out what toggling one extra would produce, without writing it.
pub fn plan(current: &str, path: &str, key: &str, enable: bool) -> Result<Change> {
    if find(key).is_none() {
        bail!("no dev shell addition {key}");
    }
    let mut enabled = read_enabled(current);
    enabled.retain(|k| k != key);
    if enable {
        enabled.push(key.to_string());
    }

    let rendered = render(&enabled);
    Ok(Change {
        key: key.to_string(),
        enabled: enable,
        path: path.to_string(),
        diff: crate::settings::line_diff(current, &rendered),
        rendered,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_file_is_valid_and_enables_nothing() {
        let text = render(&[]);
        assert!(text.contains("(none enabled)"));
        assert!(read_enabled(&text).is_empty());
    }

    #[test]
    fn a_rendered_file_reads_back_as_what_was_enabled() {
        let text = render(&["lld".into()]);
        assert_eq!(read_enabled(&text), vec!["lld"]);
        assert!(text.contains("lld   # nixdash:lld"));
    }

    #[test]
    fn an_extra_with_env_emits_both_package_and_variable() {
        let text = render(&["rust-src".into()]);
        assert!(text.contains("rustPlatform.rustLibSrc"), "{text}");
        assert!(text.contains("RUST_SRC_PATH"), "{text}");
        assert_eq!(read_enabled(&text), vec!["rust-src"]);
    }

    #[test]
    fn toggling_off_removes_only_that_entry() {
        let both = render(&["lld".into(), "rust-src".into()]);
        let change = plan(&both, "/tmp/x.nix", "lld", false).unwrap();
        let left = read_enabled(&change.rendered);
        assert_eq!(left, vec!["rust-src"], "{:?}", left);
    }

    #[test]
    fn toggling_on_twice_does_not_duplicate() {
        let once = render(&["lld".into()]);
        let change = plan(&once, "/tmp/x.nix", "lld", true).unwrap();
        assert_eq!(change.rendered.matches("# nixdash:lld").count(), 1);
    }

    #[test]
    fn unknown_keys_cannot_be_written() {
        assert!(plan("", "/tmp/x.nix", "evil", true).is_err());
    }

    #[test]
    fn every_extra_names_a_stat_that_confirms_it() {
        // The honesty rule: nothing is offered that the app cannot check
        // afterwards. A `panel.stat` reference keeps that mechanical.
        for e in known() {
            assert!(
                e.verified_by.contains('.'),
                "{}: verified_by must be panel.stat, got {:?}",
                e.key,
                e.verified_by
            );
        }
    }

    #[test]
    fn the_generated_file_says_it_is_generated_and_needs_a_new_shell() {
        let text = render(&["lld".into()]);
        assert!(text.contains("Generated by nixdash"));
        assert!(text.contains("nix develop"));
    }
}
