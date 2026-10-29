use std::path::{Path, PathBuf};

use anyhow::Result;
use serde::Serialize;
use serde_json::Value;

use crate::collector::{Collector, Info, PanelMeta, Section, StatInfo, Status, Subject};

/// Which Qt is actually *running*, as opposed to which one could build.
///
/// The build-environment panel next to this one asks whether `qmake` is on
/// PATH. For a background service the answer is permanently no, so that panel
/// reports `unknown` forever and the Qt subject says nothing useful on a
/// perfectly healthy machine.
///
/// This one is always answerable, because it asks a question that does not
/// involve PATH at all: **what does the installed Qt application link
/// against?** On NixOS a binary finds its libraries through RPATH, baked into
/// the executable and pointing straight into the store. PATH is never
/// consulted, which is exactly why "no qmake on PATH" says nothing about
/// whether Qt works here.
///
/// The app it inspects is nixdash's own UI, which makes this honest in a way
/// a general survey would not be: it reports the Qt that is drawing the window
/// you are reading.
pub struct QtRuntimeCollector;

/// Where the desktop UI might be installed, most specific first.
///
/// No PATH lookup on purpose. The engine runs as a service whose PATH is not
/// the one that installed anything, and resolving through it would reintroduce
/// the very confusion this panel exists to dispel.
pub(crate) fn ui_candidates() -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Ok(home) = std::env::var("HOME") {
        out.push(PathBuf::from(&home).join(".nix-profile/bin/nixdash-ui"));
        out.push(PathBuf::from(&home).join(".local/state/nix/profile/bin/nixdash-ui"));
    }
    out.push(PathBuf::from("/run/current-system/sw/bin/nixdash-ui"));

    // Beside this executable, which is where every PACKAGED install puts the
    // UI: /usr/bin for the .deb and .rpm, the install directory for the MSI.
    // Without it this panel reported "the desktop UI is not installed" on a
    // Debian box where the UI was sitting next to the engine that said so -
    // measured, 2026-10-29, with the published 0.1.0 .deb. The three Nix
    // paths above are the only ones it knew, so the panel was NixOS-only by
    // accident rather than by design.
    //
    // Still not a PATH lookup, for the reason given above: a sibling of the
    // running binary is a fact about this installation, where PATH is a fact
    // about whoever started the service.
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            out.push(dir.join(if cfg!(windows) {
                "nixdash-ui.exe"
            } else {
                "nixdash-ui"
            }));
        }
    }
    out
}

/// Resolve a wrapper to the binary that carries the real dependencies.
///
/// `makeWrapper` leaves a small launcher at `bin/foo` and the actual
/// executable beside it as `.foo-wrapped`. Inspecting the launcher finds
/// nothing - it links libc and little else - which looks exactly like "Qt is
/// absent" and is the same false conclusion in a new place.
pub(crate) fn unwrap_binary(path: &Path) -> PathBuf {
    let (Some(dir), Some(name)) = (path.parent(), path.file_name()) else {
        return path.to_path_buf();
    };
    let wrapped = dir.join(format!(".{}-wrapped", name.to_string_lossy()));
    if wrapped.exists() {
        wrapped
    } else {
        path.to_path_buf()
    }
}

/// Qt module shared objects named in the binary's dynamic section.
///
/// Read as plain bytes rather than by parsing ELF or shelling out to `ldd` or
/// `objdump`: DT_NEEDED entries are ordinary NUL-terminated strings in the
/// file, and binutils is not guaranteed to be on a service's PATH. Fewer
/// moving parts, and no dependency that could be missing at the moment the
/// panel is most wanted.
fn needed_qt_modules(bytes: &[u8]) -> Vec<String> {
    let mut found: Vec<String> = Vec::new();
    let needle = b"libQt6";
    let mut i = 0;
    while i + needle.len() < bytes.len() {
        if &bytes[i..i + needle.len()] == needle {
            let end = bytes[i..]
                .iter()
                .position(|b| *b == 0)
                .map(|p| i + p)
                .unwrap_or(bytes.len());
            if let Ok(s) = std::str::from_utf8(&bytes[i..end]) {
                // "libQt6Quick.so.6" -> "Quick"
                if let Some(rest) = s.strip_prefix("libQt6") {
                    let module = rest.split('.').next().unwrap_or("");
                    if !module.is_empty()
                        && module.chars().all(|c| c.is_ascii_alphanumeric())
                        && !found.iter().any(|m| m == module)
                    {
                        found.push(module.to_string());
                    }
                }
            }
            i = end.max(i + 1);
        } else {
            i += 1;
        }
    }
    found.sort();
    found
}

/// Store paths referenced by the binary that look like they carry Qt.
///
/// Nix computes a derivation's references exactly this way - by scanning
/// output for store-path strings - so this is not a heuristic standing in for
/// something better, it is the mechanism.
pub(crate) fn qt_store_paths(bytes: &[u8]) -> Vec<String> {
    const PREFIX: &[u8] = b"/nix/store/";
    let mut out: Vec<String> = Vec::new();
    let mut i = 0;
    while i + PREFIX.len() < bytes.len() {
        if &bytes[i..i + PREFIX.len()] == PREFIX {
            let start = i;
            let mut j = i + PREFIX.len();
            while j < bytes.len() {
                let c = bytes[j];
                let ok =
                    c.is_ascii_alphanumeric() || c == b'-' || c == b'.' || c == b'_' || c == b'+';
                if !ok {
                    break;
                }
                j += 1;
            }
            if let Ok(s) = std::str::from_utf8(&bytes[start..j]) {
                let lower = s.to_lowercase();
                if (lower.contains("qt") || lower.contains("-qt-env"))
                    && !out.iter().any(|p| p == s)
                {
                    out.push(s.to_string());
                }
            }
            i = j.max(i + 1);
        } else {
            i += 1;
        }
    }
    out
}

/// Read the Qt version out of a prefix by looking at the soname of QtCore.
///
/// The store path's own name is not reliable: a merged environment built with
/// `pkgs.qt6.env` is called something like `nixdash-qt-env` and carries no
/// version at all. The library file does: `libQt6Core.so.6.11.2`.
pub(crate) fn version_from_prefix(prefix: &str) -> Option<String> {
    let lib = Path::new(prefix).join("lib");
    let entries = std::fs::read_dir(lib).ok()?;
    for e in entries.flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        if let Some(rest) = name.strip_prefix("libQt6Core.so.") {
            // "6.11.2" - but skip the bare soname "6".
            if rest.matches('.').count() >= 1 {
                return Some(rest.to_string());
            }
        }
    }
    None
}

#[derive(Debug, Serialize)]
struct RuntimeReading {
    /// The application inspected, or null if none is installed.
    app: Option<String>,
    /// The binary actually read, after unwrapping a makeWrapper launcher.
    inspected: Option<String>,
    /// Qt version the application links, from QtCore's filename.
    version: Option<String>,
    /// The store prefix the Qt libraries come from.
    prefix: Option<String>,
    /// True when that prefix is a merged environment rather than a bare
    /// qtbase - what `pkgs.qt6.env` produces.
    merged_env: bool,
    /// Qt modules named in the binary's dynamic section.
    modules: Vec<String>,
    /// Whether the installed entry point is a makeWrapper launcher.
    wrapped: bool,
}

impl Collector for QtRuntimeCollector {
    fn meta(&self) -> PanelMeta {
        PanelMeta {
            id: "qt-runtime",
            title: "Qt runtime",
            description: "The Qt an installed Qt application actually links",
            // Only changes when the UI is rebuilt and reinstalled.
            interval_secs: 60,
            subject: Subject::Qt,
            info: Info {
                what: "The Qt version and store prefix that nixdash's own \
                       desktop UI links against, read from the installed \
                       binary. This is the Qt that is drawing the window - not \
                       a survey of what is installed somewhere.",
                why: "On NixOS a program finds its libraries through RPATH, \
                      baked into the executable and pointing into the store. \
                      PATH plays no part. That is why the build-environment \
                      panel can honestly say 'no qmake on PATH' while Qt \
                      applications run perfectly well - they are two unrelated \
                      questions, and conflating them is the most common \
                      misreading of how Nix works.",
                if_wrong: "If this says 'no Qt application installed', the \
                           desktop UI is not in your profile - the engine runs \
                           headless and is not itself a Qt program. If the \
                           version here differs from the build-environment \
                           panel's, you are building against a different Qt \
                           than you are running, which is a real problem and \
                           usually means a stale devShell.",
                sections: &[
                    Section {
                        title: "How a program finds its Qt",
                        body: "Not through <tt>PATH</tt>, and not through \
<tt>LD_LIBRARY_PATH</tt>. When the binary was linked, the exact store paths \
of every library it needs were written into it as <tt>RPATH</tt>. At startup \
the loader reads that list and nothing else.<br><br>\
Three consequences worth holding on to:<br>\
<ul>\
<li><b>Nothing you do to your shell changes it.</b> Entering a devShell with \
a different Qt does not affect an already-installed program - its Qt was \
decided at link time.</li>\
<li><b>Two programs can use different Qts at once</b>, with no conflict and \
no global version. That is the whole point of the store.</li>\
<li><b>'No qmake on PATH' is compatible with Qt running fine.</b> The other \
Qt panel answers a build-time question; this one answers a run-time \
question.</li>\
</ul>\
The version here is read back out of the installed executable, so it is what \
is actually loaded - not what a package list claims.",
                    },
                    Section {
                        title: "Why the inspected path has a dot in it",
                        body: "The <tt>app</tt> row usually names something \
like <tt>bin/nixdash-ui</tt> while <tt>inspected</tt> names \
<tt>bin/.nixdash-ui-wrapped</tt>. Nothing is wrong: that is how Qt programs \
are packaged on NixOS.<br><br>\
A Qt application needs to find more than libraries - it loads platform \
plugins and QML modules at run time, from directories no <tt>RPATH</tt> can \
express. So the build renames the real executable with a leading dot and puts \
a small script in its place, which sets <tt>QT_PLUGIN_PATH</tt> and \
<tt>QML2_IMPORT_PATH</tt> and then runs it.<br><br>\
The library versions have to be read from the real binary, so the dotted path \
is the one examined. <tt>wrapped</tt> says whether that indirection is \
present; a Qt program showing <tt>no</tt> there is the surprising case, and \
usually means a binary built outside the normal packaging - like a \
<tt>cargo build</tt> straight out of a devShell.",
                    },
                    Section {
                        title: "References",
                        body: "<a href='https://doc.qt.io/qt-6/'>Qt 6 \
documentation</a> &middot; \
<a href='https://nixos.org/manual/nixpkgs/stable/'>nixpkgs manual</a>, whose \
Qt section documents the wrapper this panel sees through &middot; \
<a href='https://nixos.org/manual/nixos/stable/'>NixOS manual</a>.",
                    },
                ],
            },
            stats: vec![
                StatInfo {
                    key: "version",
                    info: Info {
                        what: "Qt version, taken from the filename of \
                               libQt6Core.so in the prefix the binary links.",
                        why: "Read from the library rather than the store \
                              path's name, because a merged environment built \
                              with pkgs.qt6.env is named for your project and \
                              carries no version at all.",
                        if_wrong: "A version you did not expect means the \
                                   binary was built in a different shell than \
                                   you think. Rebuild and reinstall, then \
                                   check again.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "prefix",
                    info: Info {
                        what: "The store path the Qt libraries are loaded \
                               from.",
                        why: "This is what RPATH points at. It cannot be \
                              changed by editing PATH or entering a different \
                              shell - the only way to change it is to rebuild \
                              the application.",
                        if_wrong: "A path under /usr or /lib would mean \
                                   something is loading libraries from \
                                   outside the store, which on NixOS should \
                                   not happen.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "merged_env",
                    info: Info {
                        what: "Whether the Qt prefix is a merged environment \
                               rather than a single package output.",
                        why: "pkgs.qt6.env produces one prefix containing \
                              qtbase, qtdeclarative and their host tools \
                              together. That is what makes a cxx-qt build \
                              work: cxx-qt asks ONE qmake for everything, and \
                              nixpkgs splits Qt across several outputs.",
                        if_wrong: "Linking a bare qtbase is fine for a plain \
                                   widgets app, but a QML or cxx-qt build \
                                   needs the merged prefix - a symlinkJoin \
                                   will not do, because nixpkgs' qmake has its \
                                   prefix compiled in.",
                        sections: &[Section {
                            title: "What a merged prefix is",
                            body: "<tt>pkgs.qt6.env</tt> \
builds one store path containing every Qt module you name, so a single \
prefix can answer for all of them.<br><br>\
The reason it has to be a real build rather than a pile of symlinks: \
nixpkgs' qmake has its own installation prefix <b>compiled into it</b>. Link \
it into a combined directory with <tt>symlinkJoin</tt> and it keeps \
reporting the path it was built with, so the merge is invisible to exactly \
the tool that needed to see it.<br><br>\
Recognising one by sight: a merged prefix is usually named for the \
environment rather than a module - <tt>…-qt6-env</tt> rather than \
<tt>…-qtbase-6.11.2</tt>. A bare module name here means whatever is being \
reported can speak only for that module.",
                        }],
                    },
                },
                StatInfo {
                    key: "modules",
                    info: Info {
                        what: "Qt modules named in the binary's dynamic \
                               section - Core, Gui, Qml, Quick, Network and so \
                               on.",
                        why: "Shows what the application actually pulls in. A \
                              QML application that links Qml and Quick but not \
                              QuickControls2 will fail at runtime when a \
                              control it imports is missing.",
                        if_wrong: "Missing modules usually surface as a QML \
                                   import error at startup rather than a link \
                                   error, because QML plugins are loaded on \
                                   demand.",
                        sections: &[Section {
                            title: "Reading the module list",
                            body: "These names are \
read out of the executable's dynamic section - the record of which shared \
libraries it needs - so this is what the program genuinely loads, not what a \
package description claims.<br><br>\
<table>\
<tr><td><b>Core</b>&nbsp;&nbsp;</td><td>objects, strings, event loop; present \
in every Qt program</td></tr>\
<tr><td><b>Gui</b></td><td>windows, images, fonts, the platform \
integration</td></tr>\
<tr><td><b>Qml</b></td><td>the QML engine</td></tr>\
<tr><td><b>Quick</b></td><td>the scene graph that draws QML</td></tr>\
<tr><td><b>QuickControls2</b></td><td>buttons, tabs and the rest of the \
widget set</td></tr>\
<tr><td><b>Network</b></td><td>sockets and HTTP</td></tr>\
</table><br>\
A Qml entry without Quick, or Quick without Gui, would be strange enough to \
be worth investigating - the upper layers depend on the lower ones, so they \
normally appear together.",
                        }],
                    },
                },
                StatInfo {
                    key: "app",
                    info: Info {
                        what: "The installed application this panel inspected.",
                        why: "Deliberately a real installed artefact rather \
                              than a guess at what Qt is 'available'. If it is \
                              null the panel says so instead of inventing an \
                              answer.",
                        if_wrong: "Null means nixdash's desktop UI is not \
                                   installed in your profile. Enable \
                                   services.nixdash.ui to install it.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "inspected",
                    info: Info {
                        what: "The file actually read - normally \
                               .nixdash-ui-wrapped rather than nixdash-ui.",
                        why: "makeWrapper leaves a small launcher at the \
                              visible name and the real executable beside it, \
                              hidden. Reading the launcher finds only libc, \
                              which looks exactly like 'Qt is absent'.",
                        if_wrong: "If this equals the app path, no wrapper was \
                                   found and the binary was read directly - \
                                   which is normal for an unwrapped build.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "wrapped",
                    info: Info {
                        what: "Whether the installed entry point is a \
                               makeWrapper launcher.",
                        why: "Qt applications on NixOS are usually wrapped to \
                              set QT_PLUGIN_PATH and QML2_IMPORT_PATH. Without \
                              that wrapping a Qt app often starts and then \
                              fails to find its platform plugin.",
                        if_wrong: "An unwrapped Qt app that cannot find \
                                   'xcb' is missing exactly this wrapping.",
                        sections: &[],
                    },
                },
            ],
        }
    }

    fn sample(&self) -> Result<Value> {
        let app = ui_candidates().into_iter().find(|p| p.exists());

        let Some(app_path) = app else {
            return Ok(serde_json::to_value(RuntimeReading {
                app: None,
                inspected: None,
                version: None,
                prefix: None,
                merged_env: false,
                modules: Vec::new(),
                wrapped: false,
            })?);
        };

        let inspected = unwrap_binary(&app_path);
        let wrapped = inspected != app_path;
        // Absence of Qt is a legitimate reading; an unreadable file is not,
        // and gets reported as a panel error rather than silently as "none".
        let bytes = std::fs::read(&inspected)?;

        let modules = needed_qt_modules(&bytes);
        let prefix = qt_store_paths(&bytes)
            .into_iter()
            .find(|p| version_from_prefix(p).is_some());
        let version = prefix.as_deref().and_then(version_from_prefix);
        let merged_env = prefix
            .as_deref()
            .map(|p| p.contains("-qt-env") || p.contains("qt6-env"))
            .unwrap_or(false);

        Ok(serde_json::to_value(RuntimeReading {
            app: Some(app_path.display().to_string()),
            inspected: Some(inspected.display().to_string()),
            version,
            prefix,
            merged_env,
            modules,
            wrapped,
        })?)
    }

    fn status(&self, v: &Value) -> (Status, String) {
        let Some(version) = v["version"].as_str() else {
            if v["app"].is_null() {
                // Names the missing *artefact*, not the technology. An
                // earlier wording here was "no Qt application installed to
                // inspect" - accurate, but close enough to "no Qt" that the
                // headline guard rejected it, and the guard was right to:
                // a glance at that line reads as Qt being absent.
                return (
                    Status::Unknown,
                    "the desktop UI is not installed - nothing to inspect".into(),
                );
            }
            return (
                Status::Unknown,
                "installed, but its Qt prefix could not be read".into(),
            );
        };

        let n = v["modules"].as_array().map_or(0, |a| a.len());
        let merged = v["merged_env"].as_bool().unwrap_or(false);
        // Not a fault either way - a merged prefix is what a QML build needs,
        // but plenty of Qt applications legitimately link a single output.
        let how = if merged {
            "merged prefix"
        } else {
            "single prefix"
        };
        (
            Status::Ok,
            format!("{version} running · {n} modules · {how}"),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn module_names_come_out_of_raw_bytes() {
        let bytes = b"\0libQt6Core.so.6\0libQt6Quick.so.6\0libQt6Core.so.6\0";
        assert_eq!(needed_qt_modules(bytes), vec!["Core", "Quick"]);
    }

    #[test]
    fn non_qt_libraries_are_ignored() {
        let bytes = b"\0libc.so.6\0libstdc++.so.6\0";
        assert!(needed_qt_modules(bytes).is_empty());
    }

    #[test]
    fn store_paths_are_scanned_the_way_nix_does() {
        let bytes = b"\0/nix/store/aaaa1111bbbb2222cccc3333dddd4444-nixdash-qt-env/lib\0\
                      /nix/store/eeee5555ffff6666gggg7777hhhh8888-glibc-2.42/lib\0";
        let paths = qt_store_paths(bytes);
        assert_eq!(paths.len(), 1, "{paths:?}");
        assert!(paths[0].ends_with("-nixdash-qt-env"));
    }

    #[test]
    fn a_wrapper_resolves_to_the_binary_beside_it() {
        let dir = std::env::temp_dir().join(format!("nixdash-wrap-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let visible = dir.join("app");
        let hidden = dir.join(".app-wrapped");
        std::fs::write(&visible, b"launcher").unwrap();
        std::fs::write(&hidden, b"real").unwrap();

        assert_eq!(unwrap_binary(&visible), hidden);
        // Without the hidden file it must return the path unchanged rather
        // than a path that does not exist.
        std::fs::remove_file(&hidden).unwrap();
        assert_eq!(unwrap_binary(&visible), visible);
        std::fs::remove_dir_all(&dir).ok();
    }

    /// The absence headlines, checked directly.
    ///
    /// These branches cannot be reached on a machine that has the UI
    /// installed - which is every machine this suite normally runs on, and
    /// also the Nix build sandbox, where nothing is installed and the OTHER
    /// branch is the only reachable one. Between them the suite exercises one
    /// case at a time and silently skips the other, so both are asserted here
    /// against synthetic readings instead.
    #[test]
    fn absence_headlines_name_the_artefact_not_the_technology() {
        for value in [
            serde_json::json!({ "app": Value::Null, "version": Value::Null }),
            serde_json::json!({ "app": "/somewhere/nixdash-ui", "version": Value::Null }),
        ] {
            let (status, headline) = QtRuntimeCollector.status(&value);
            assert_eq!(status, Status::Unknown, "{headline}");

            let lower = headline.to_lowercase();
            for claim in ["no qt ", "no qt.", "no qt-"] {
                assert!(
                    !lower.contains(claim),
                    "headline {headline:?} reads as Qt being absent; name what \
                     is actually missing"
                );
            }
            assert!(!lower.ends_with("no qt"), "headline {headline:?}");
        }
    }

    #[test]
    fn absence_is_a_reading_not_an_error() {
        let v = QtRuntimeCollector.sample().expect("absence must not error");
        let (status, headline) = QtRuntimeCollector.status(&v);
        if v["app"].is_null() {
            assert_eq!(status, Status::Unknown);
        } else {
            assert!(!headline.is_empty());
        }
        // Whatever the machine looks like, the headline must never claim Qt
        // itself is missing - see headlines_claim_only_what_was_measured.
        assert!(!headline.to_lowercase().contains("no qt in"));
    }
}
