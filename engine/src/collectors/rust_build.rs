use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use anyhow::Result;
use serde::Serialize;
use serde_json::Value;

use crate::collector::{Collector, Info, PanelMeta, StatInfo, Status, Subject};

/// Is the engine you are talking to built from the code on disk?
///
/// The toolchain panel beside this one answers "could you compile here". This
/// answers the question that actually bites: **is what is running current?**
///
/// On NixOS that is easy to get wrong in a specific way. A rebuild produces a
/// new store path and rewrites the unit, but systemd does not restart user
/// services automatically here - `startServices = "suggest"` prints the
/// command instead, because restarting them takes xfconf down and kills the
/// Xfce panel. So the old binary keeps serving, from a store path that still
/// exists, answering requests perfectly. Nothing looks wrong.
///
/// Store mtimes are all normalised to 1970, so comparing file timestamps is
/// useless here. What works is a build timestamp baked in at compile time,
/// compared against the newest engine source file: if a file was edited after
/// this binary was built, the binary cannot contain that edit.
///
/// The process's *start time* was used for this and was wrong, in a way that
/// only ever failed towards reassurance: restarting a binary does not rebuild
/// it, so a restart made any build, however old, look current. The restart
/// after a switch is exactly when that mattered.
pub struct RustBuildCollector;

fn project_dir() -> Option<PathBuf> {
    if let Ok(dir) = std::env::var("NIXDASH_PROJECT_DIR") {
        let p = PathBuf::from(dir);
        return p.is_dir().then_some(p);
    }
    let home = std::env::var("HOME").ok()?;
    let p = PathBuf::from(home).join("Projects/nixdash");
    p.is_dir().then_some(p)
}

fn secs(t: std::time::SystemTime) -> Option<u64> {
    t.duration_since(UNIX_EPOCH).ok().map(|d| d.as_secs())
}

/// When the running binary was compiled, baked in by `build.rs`.
///
/// The fact the filesystem cannot supply: a store path's mtime is 1970 by
/// design, and `target/debug`'s mtime is the link time of a binary that may
/// have been relinked without its build script re-running.
const BUILT: &str = env!("NIXDASH_BUILT");

/// `BUILT` as Unix seconds, for comparing against a file mtime.
fn built_at() -> Option<u64> {
    env!("NIXDASH_BUILT_AT").parse().ok()
}

/// Was this binary compiled before the newest source file was edited?
///
/// Pulled out of `sample` so the comparison can be tested with injected
/// times: the one thing it must not depend on is when the process started,
/// and that is not something the real environment can be made to vary.
///
/// Either input missing means *unknowable*, which is reported as not stale
/// here and turned into `Unknown` by `status` - never into "current".
fn staleness(built_at: Option<u64>, newest_source_at: Option<u64>) -> (bool, Option<u64>) {
    match (built_at, newest_source_at) {
        (Some(built), Some(src)) if src > built => (true, Some(src - built)),
        _ => (false, None),
    }
}

/// When this process started.
///
/// The mtime of `/proc/self` is the process's start time - simpler and less
/// brittle than parsing field 22 of `/proc/self/stat` and adding it to the
/// boot time from `/proc/stat`.
fn process_started_at() -> Option<u64> {
    secs(std::fs::metadata("/proc/self").ok()?.modified().ok()?)
}

/// Newest `.rs` anywhere under a directory, with its path relative to the root.
fn newest_source(root: &Path, dir: &Path, best: &mut Option<(u64, String)>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(ft) = entry.file_type() else { continue };
        if ft.is_dir() {
            // target/ is build output, not source, and is enormous.
            let name = entry.file_name();
            if name == "target" || name == ".git" {
                continue;
            }
            newest_source(root, &path, best);
        } else if path.extension().and_then(|e| e.to_str()) == Some("rs") {
            let Some(t) = std::fs::metadata(&path)
                .ok()
                .and_then(|m| m.modified().ok())
            else {
                continue;
            };
            let Some(t) = secs(t) else { continue };
            if best.as_ref().is_none_or(|(b, _)| t > *b) {
                let rel = path
                    .strip_prefix(root)
                    .unwrap_or(&path)
                    .display()
                    .to_string();
                *best = Some((t, rel));
            }
        }
    }
}

#[derive(Debug, Serialize)]
struct BuildReading {
    project_dir: Option<String>,
    /// The binary this engine is running from.
    running_exe: Option<String>,
    /// True when that path is in the Nix store - a deployed build rather than
    /// a `cargo run` from the working tree.
    deployed: bool,
    /// When this binary was compiled, as a string to show someone.
    built: &'static str,
    /// The same moment in Unix seconds - the half of the comparison that the
    /// running process's start time used to stand in for.
    built_at: Option<u64>,
    started_at: Option<u64>,
    newest_source_at: Option<u64>,
    newest_source_file: Option<String>,
    /// Engine source edited after this binary was built.
    stale: bool,
    stale_by_secs: Option<u64>,
}

impl Collector for RustBuildCollector {
    fn meta(&self) -> PanelMeta {
        PanelMeta {
            id: "rust-build",
            title: "Build freshness",
            description: "Whether the running engine was built from the current source",
            interval_secs: 30,
            subject: Subject::Rust,
            info: Info {
                what: "Compares when the running binary was COMPILED against \
                       the newest .rs file under engine/. If a file was \
                       edited after this binary was built, the binary cannot \
                       contain that edit.",
                why: "A rebuild makes a new store path and rewrites the unit, \
                      but user services are not restarted automatically on \
                      this machine - startServices is set to 'suggest', \
                      because auto-restarting takes xfconf down and kills the \
                      Xfce panel. So the previous binary keeps running and \
                      answering perfectly. Nothing looks wrong, and you debug \
                      a change that was never loaded.",
                if_wrong: "Stale means: run home-manager switch, then the \
                           restart it prints. The build date is baked in at \
                           compile time rather than read off the file, \
                           because every mtime in the Nix store is \
                           normalised to 1970 - the binary's file date would \
                           make everything look permanently stale. The \
                           process's start time cannot stand in for it \
                           either: restarting does not rebuild, so a restart \
                           would make any build look current, which is this \
                           panel's whole subject.",
                sections: &[],
            },
            stats: vec![
                StatInfo {
                    key: "stale",
                    info: Info {
                        what: "True when a file under engine/ is newer than \
                               the moment this binary was compiled.",
                        why: "Store paths carry no useful mtime, so the \
                              build moment is embedded at compile time. That \
                              is what makes this survive a restart: \
                              restarting changes when the process began, not \
                              what is in it.",
                        if_wrong: "A false positive is possible if you touch \
                                   a file without changing it - git checkout \
                                   does this. Harmless: a restart costs \
                                   seconds and history is in memory only.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "stale_by_secs",
                    info: Info {
                        what: "How long after this binary was compiled the \
                               newest source edit happened.",
                        why: "Distinguishes 'just saved a file' from 'this \
                              has been running against old code all \
                              afternoon'.",
                        if_wrong: "Null when current, or when either \
                                   timestamp could not be read.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "newest_source_file",
                    info: Info {
                        what: "Most recently modified .rs file under \
                               engine/, shown relative to the project root.",
                        why: "Says which change is not loaded, which is the \
                              difference between a warning and something \
                              actionable.",
                        if_wrong: "Only engine/ is scanned, because only \
                                   those files end up in this binary - a QML \
                                   or UI edit is not this panel's business \
                                   and reporting it here would be a false \
                                   alarm that never clears. target/ and .git \
                                   are skipped too: build output is not \
                                   source and scanning it would be slow and \
                                   always newest.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "deployed",
                    info: Info {
                        what: "Whether the running binary is a Nix store path \
                               rather than a cargo build from the tree.",
                        why: "A dev run from target/debug is expected to be \
                              ahead of or behind source freely. A deployed \
                              store build going stale is the one that \
                              misleads, because it is the one you forget is \
                              running.",
                        if_wrong: "False while you are iterating with cargo \
                                   run - staleness still reports honestly, it \
                                   just matters less.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "running_exe",
                    info: Info {
                        what: "The binary backing this process, from \
                               /proc/self/exe.",
                        why: "The store hash in the path changes on every \
                              rebuild, so comparing it against the unit's \
                              ExecStart shows whether a restart is \
                              outstanding.",
                        if_wrong: "If this differs from `systemctl --user \
                                   show nixdash-engine -p ExecStart`, the \
                                   unit was updated and the process was never \
                                   restarted.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "built",
                    info: Info {
                        what: "When the running binary was compiled, in \
                               local time.",
                        why: "The one identifier that tells two builds \
                              apart here. The version number is 0.1.0 in \
                              every build ever made, so it cannot; a store \
                              hash changes but means nothing to read.",
                        if_wrong: "A date older than your last rebuild means \
                                   the new build was never started - the old \
                                   process is still serving, from a store \
                                   path that still exists.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "built_at",
                    info: Info {
                        what: "The same moment as Unix seconds, which is the \
                               value actually compared against source.",
                        why: "Baked in by the build script rather than read \
                              off the file, because a Nix store path's mtime \
                              is 1970 by design.",
                        if_wrong: "Null would mean the build stamp could not \
                                   be read, and then this panel reports \
                                   unknown rather than guessing - it cannot \
                                   compare against a build date it does not \
                                   have.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "started_at",
                    info: Info {
                        what: "When this process started, from the mtime of \
                               /proc/self.",
                        why: "Shown, but deliberately NOT compared against \
                              anything. It answers how long this has been up, \
                              which is a different question from what is in \
                              it - and conflating the two is what made this \
                              panel call a year-old build current the moment \
                              it was restarted.",
                        if_wrong: "A start time much later than the build \
                                   date is normal and means nothing is \
                                   wrong; it just means you restarted.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "newest_source_at",
                    info: Info {
                        what: "Modification time of the newest .rs file.",
                        why: "The other half of the comparison.",
                        if_wrong: "Null means the project directory could not \
                                   be scanned.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "project_dir",
                    info: Info {
                        what: "The project being compared against.",
                        why: "Set NIXDASH_PROJECT_DIR to point elsewhere.",
                        if_wrong: "Null means no source tree was found, and \
                                   this panel can say nothing - which it \
                                   reports as unknown rather than as \
                                   'current'.",
                        sections: &[],
                    },
                },
            ],
        }
    }

    fn sample(&self) -> Result<Value> {
        let running_exe = std::fs::read_link("/proc/self/exe")
            .ok()
            .map(|p| p.display().to_string());
        let deployed = running_exe
            .as_deref()
            .is_some_and(|p| p.starts_with("/nix/store/"));
        let started_at = process_started_at();
        let built_at = built_at();

        let Some(dir) = project_dir() else {
            return Ok(serde_json::to_value(BuildReading {
                project_dir: None,
                running_exe,
                deployed,
                built: BUILT,
                built_at,
                started_at,
                newest_source_at: None,
                newest_source_file: None,
                stale: false,
                stale_by_secs: None,
            })?);
        };

        // Only the engine crate: those are the files that go into this
        // binary, and they are also exactly the set Cargo watches to decide
        // whether to re-run the build script that stamped it. Scanning the
        // whole tree would report a QML or UI edit - which cannot change this
        // binary - as the engine being out of date, and with a baked stamp
        // that false alarm would never clear.
        let mut best = None;
        newest_source(&dir, &dir.join("engine"), &mut best);
        let newest_source_at = best.as_ref().map(|(t, _)| *t);
        let newest_source_file = best.as_ref().map(|(_, f)| f.clone());

        let (stale, stale_by_secs) = staleness(built_at, newest_source_at);

        Ok(serde_json::to_value(BuildReading {
            project_dir: Some(dir.display().to_string()),
            running_exe,
            deployed,
            built: BUILT,
            built_at,
            started_at,
            newest_source_at,
            newest_source_file,
            stale,
            stale_by_secs,
        })?)
    }

    fn status(&self, v: &Value) -> (Status, String) {
        if v["project_dir"].is_null() {
            return (
                Status::Unknown,
                // As in qt_wasm: name the question, not the absence. There
                // is no source tree on a packaged install by design.
                "no nixdash source tree here - this panel describes a checkout".into(),
            );
        }
        // Both of these are "could not look", and neither is "current".
        // Reporting ok here would be the panel reassuring you about a
        // comparison it never made.
        if v["built_at"].is_null() {
            return (
                Status::Unknown,
                "cannot tell when this build was made".into(),
            );
        }
        if v["newest_source_at"].is_null() {
            return (
                Status::Unknown,
                "no engine source found to compare against".into(),
            );
        }

        let deployed = v["deployed"].as_bool().unwrap_or(false);
        let kind = if deployed { "deployed" } else { "dev build" };
        let built = v["built"].as_str().unwrap_or("an unknown date");

        if v["stale"].as_bool().unwrap_or(false) {
            let mins = v["stale_by_secs"].as_u64().unwrap_or(0) / 60;
            let file = v["newest_source_file"].as_str().unwrap_or("source");
            let ago = if mins >= 120 {
                format!("{} hours", mins / 60)
            } else {
                format!("{mins} min")
            };
            // A restart alone used to be the advice, and it is wrong: the
            // binary has to be rebuilt before there is anything newer to
            // restart into.
            let remedy = if deployed {
                "switch, then the restart it prints"
            } else {
                "rebuild"
            };
            // Warn, not Bad: the running build is fine, it is simply not the
            // one you just wrote. Nothing is broken until you expect
            // otherwise.
            return (
                Status::Warn,
                format!("{kind} from {built} predates {file} by {ago} - {remedy}"),
            );
        }

        (
            Status::Ok,
            format!("{kind} from {built}, current with engine source"),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The bug this panel had: `stale` was computed against the process's
    /// start time, so restarting a stale binary cleared the warning without
    /// rebuilding anything - and the restart after a switch is exactly when
    /// that happened. The comparison must depend on the build and nothing
    /// else.
    #[test]
    fn staleness_compares_the_build_not_the_restart() {
        let built = 1_000_000;
        let edited_after = built + 3_600;

        assert_eq!(
            staleness(Some(built), Some(edited_after)),
            (true, Some(3_600))
        );
        assert_eq!(
            staleness(Some(edited_after + 1), Some(edited_after)),
            (false, None)
        );

        // No restart time appears in the signature at all, which is the
        // property this test is really pinning: there is nothing a restart
        // could change.
        assert_eq!(staleness(None, Some(edited_after)), (false, None));
        assert_eq!(staleness(Some(built), None), (false, None));
    }

    /// "Could not look" must not render as "current". Both unknowable cases
    /// return `stale: false`, so without these guards the headline would have
    /// claimed currency on a comparison that never happened.
    #[test]
    fn an_unmeasurable_comparison_reports_unknown_not_ok() {
        let base = serde_json::json!({
            "project_dir": "/home/someone/Projects/nixdash",
            "deployed": true,
            "built": "2026-01-01 00:00",
            "built_at": 1_000_000,
            "newest_source_at": 999_000,
            "newest_source_file": "engine/src/main.rs",
            "stale": false,
            "stale_by_secs": null,
        });

        let (status, _) = RustBuildCollector.status(&base);
        assert_eq!(status, Status::Ok, "a complete reading is comparable");

        let mut no_stamp = base.clone();
        no_stamp["built_at"] = Value::Null;
        let (status, headline) = RustBuildCollector.status(&no_stamp);
        assert_eq!(status, Status::Unknown, "no build stamp: {headline}");

        let mut no_source = base.clone();
        no_source["newest_source_at"] = Value::Null;
        let (status, headline) = RustBuildCollector.status(&no_source);
        assert_eq!(status, Status::Unknown, "no source to compare: {headline}");
    }

    /// `built_at` is parsed from an env var the build script sets. If that
    /// ever stops being emitted the panel must report unknown, not ok, so the
    /// parse is pinned here rather than discovered through a false "current".
    #[test]
    fn the_build_stamp_is_present_and_parses() {
        assert!(
            built_at().is_some(),
            "NIXDASH_BUILT_AT did not parse - build.rs is not emitting it"
        );
        assert!(!BUILT.is_empty(), "NIXDASH_BUILT is empty");
    }

    /// Only engine/ is scanned. A UI or QML edit cannot change this binary,
    /// and with a baked build stamp a false alarm from one would never clear.
    #[test]
    fn the_scan_covers_only_the_engine_crate() {
        let Some(dir) = project_dir() else { return };
        let mut best = None;
        newest_source(&dir, &dir.join("engine"), &mut best);
        if let Some((_, file)) = best {
            assert!(
                file.starts_with("engine/"),
                "scanned outside the engine crate: {file}"
            );
        }
    }

    #[test]
    fn process_start_time_is_plausible() {
        let started = process_started_at().expect("/proc/self must be readable");
        let now = secs(std::time::SystemTime::now()).unwrap();
        assert!(started <= now, "started in the future: {started} > {now}");
        // A test process is seconds old, not years. Guards against the mtime
        // of /proc/self turning out to mean something else.
        assert!(now - started < 86_400, "start time looks wrong: {started}");
    }

    #[test]
    fn build_output_is_not_mistaken_for_source() {
        let Some(dir) = project_dir() else { return };
        let mut best = None;
        newest_source(&dir, &dir, &mut best);
        if let Some((_, file)) = best {
            assert!(
                !file.starts_with("target/") && !file.contains("/target/"),
                "scanned build output: {file}"
            );
        }
    }

    #[test]
    fn staleness_needs_both_timestamps() {
        let v = RustBuildCollector.sample().unwrap();
        if v["started_at"].is_null() || v["newest_source_at"].is_null() {
            assert_eq!(v["stale"], Value::Bool(false));
            assert!(v["stale_by_secs"].is_null());
        }
    }

    #[test]
    fn a_missing_project_is_unknown_not_current() {
        // The dangerous failure is reporting "current" when nothing was
        // actually compared.
        let v = serde_json::json!({ "project_dir": Value::Null });
        let (status, _) = RustBuildCollector.status(&v);
        assert_eq!(status, Status::Unknown);
    }
}
