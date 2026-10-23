use std::path::PathBuf;

use anyhow::Result;

use super::{Action, ActionInfo, ActionKind, ActionProvider, RunCommand, Urgency};
use crate::collector::Subject;

/// Rebuild the browser UI when it has fallen behind the shared QML.
///
/// Offered only when it is actually stale, because an always-present "rebuild
/// the thing" is noise. The staleness test is the same one the qt-wasm panel
/// makes, duplicated here rather than shared through the registry: an action
/// provider must stay cheap and independent of whether a panel has sampled
/// yet, and these are two stat calls.
pub struct WasmStale;

pub(super) fn project_dir() -> Option<PathBuf> {
    if let Ok(dir) = std::env::var("NIXDASH_PROJECT_DIR") {
        let p = PathBuf::from(dir);
        return p.is_dir().then_some(p);
    }
    let home = std::env::var("HOME").ok()?;
    let p = PathBuf::from(home).join("Projects/nixdash");
    p.is_dir().then_some(p)
}

fn mtime(p: &std::path::Path) -> Option<std::time::SystemTime> {
    std::fs::metadata(p).ok()?.modified().ok()
}

fn newest_qml(dir: &std::path::Path) -> Option<(std::time::SystemTime, String)> {
    let mut newest: Option<(std::time::SystemTime, String)> = None;
    for entry in std::fs::read_dir(dir.join("qml")).ok()?.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("qml") {
            continue;
        }
        if let Some(t) = mtime(&path) {
            let name = path.file_name()?.to_string_lossy().to_string();
            if newest.as_ref().is_none_or(|(best, _)| t > *best) {
                newest = Some((t, name));
            }
        }
    }
    newest
}

impl ActionProvider for WasmStale {
    fn id(&self) -> &'static str {
        "wasm"
    }

    fn actions(&self) -> Result<Vec<Action>> {
        let Some(dir) = project_dir() else {
            return Ok(Vec::new());
        };
        // `current`, not `build`: build.sh flips that symlink only on a
        // successful link, so a FAILED build leaves build/ newer than qml/
        // and silences this action for ever while the stale bundle is still
        // what gets served. The symlink is followed, so this is the mtime of
        // the release it points at.
        let wasm = dir.join("ui-wasm/current/nixdash_ui_wasm_app.wasm");
        let Some(built_at) = mtime(&wasm) else {
            // Never built is not drift. Building it for the first time is a
            // decision about whether you want a browser UI at all, not
            // maintenance, so it is not offered as an action.
            return Ok(Vec::new());
        };
        let Some((qml_at, newest_file)) = newest_qml(&dir) else {
            return Ok(Vec::new());
        };
        if qml_at <= built_at {
            return Ok(Vec::new());
        }

        let behind = qml_at
            .duration_since(built_at)
            .map(|d| {
                let m = d.as_secs() / 60;
                if m >= 120 {
                    format!("{} hours", m / 60)
                } else {
                    format!("{m} minutes")
                }
            })
            .unwrap_or_else(|_| "some time".into());

        Ok(vec![Action {
            id: "rebuild-wasm-ui".into(),
            title: "Rebuild the browser UI".into(),
            subject: Subject::Qt,
            kind: ActionKind::Shell,
            why: format!(
                "The compiled WebAssembly UI is {behind} older than {newest_file}. \
                 It is still serving the previous build, which looks identical \
                 to working."
            ),
            info: ActionInfo {
                what: "Runs ui-wasm/build.sh inside the wasm dev shell, which \
                       recompiles the shared QML to WebAssembly. The desktop \
                       and browser UIs are built from the same qml/ \
                       directory, but only the desktop one is rebuilt by a \
                       normal cargo build.",
                if_wrong: "This takes several minutes and needs the wasm dev \
                           shell - a separate toolchain with emcc and a \
                           wasm32 Rust target that the default shell does not \
                           have. If it fails immediately with a missing \
                           QT_WASM_TOOLCHAIN, the shell did not activate. \
                           Nothing is lost by not running it: only the \
                           browser UI is affected, and the desktop one is \
                           already current.",
            },
            command: "nix develop .#wasm --command bash ui-wasm/build.sh\n\
                      # then serve it:\n\
                      ./ui-wasm/serve.sh"
                .into(),
            // The displayed text ends with the serve step, which must not be
            // conflated with the build - running both would leave a web
            // server holding the terminal.
            run: Some(RunCommand {
                program: "nix".into(),
                args: vec![
                    "develop".into(),
                    ".#wasm".into(),
                    "--command".into(),
                    "bash".into(),
                    "ui-wasm/build.sh".into(),
                ],
                elevate: false,
                cwd: Some(dir.display().to_string()),
            }),
            effects: vec![
                "Recompiles the browser UI from the current qml/".into(),
                "Takes several minutes; the desktop UI is unaffected".into(),
                "Writes only into ui-wasm/build, which is disposable".into(),
            ],
            needs_root: false,
            urgency: Urgency::Advised,
        }])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_run_spec_omits_the_serve_step() {
        // The displayed command ends with serve.sh, which would hold a web
        // server open forever. Only the build may run.
        for action in WasmStale.actions().unwrap() {
            let run = action.run.as_ref().expect("stale wasm must be runnable");
            assert!(
                !run.args.iter().any(|a| a.contains("serve")),
                "serve step leaked into the run spec: {:?}",
                run.args
            );
            assert!(run.args.iter().any(|a| a.contains("build.sh")));
            assert!(!run.elevate, "a project build must never ask for root");
            assert!(run.cwd.is_some(), "a project build needs its directory");
        }
    }

    #[test]
    fn nothing_is_offered_when_there_is_no_build_to_be_stale() {
        // Guards against the action appearing on a machine that has simply
        // never built the browser UI, where it would be noise forever.
        let Some(dir) = project_dir() else { return };
        if !dir.join("ui-wasm/build/nixdash_ui_wasm_app.wasm").exists() {
            assert!(WasmStale.actions().unwrap().is_empty());
        }
    }
}
