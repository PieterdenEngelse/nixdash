use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::UNIX_EPOCH;

use anyhow::Result;
use serde::Serialize;
use serde_json::Value;

use crate::collector::{Collector, Info, PanelMeta, Section, StatInfo, Status, Subject};
use crate::collectors::qt_runtime::{ui_candidates, unwrap_binary, version_from_prefix};

/// The WebAssembly half of the project: is it built, and is it current?
///
/// Both UIs are compiled from one `qml/` directory, symlinked into each crate
/// rather than copied. That is the point of the arrangement - one edit reaches
/// both - but it has a failure mode the desktop build hides completely: QML
/// changes land in the running desktop app as soon as it is rebuilt, while the
/// browser build silently keeps serving whatever was last compiled to wasm.
///
/// So this panel compares timestamps. A browser UI older than the QML it was
/// built from is not broken, it is *stale*, and stale is the one state that
/// looks exactly like working.
pub struct QtWasmCollector;

/// Where the project lives.
///
/// Overridable because hard-coding a path into a monitoring tool is how it
/// silently measures nothing on the next machine. The default matches this
/// install; `NIXDASH_PROJECT_DIR` moves it.
fn project_dir() -> Option<PathBuf> {
    if let Ok(dir) = std::env::var("NIXDASH_PROJECT_DIR") {
        let p = PathBuf::from(dir);
        return p.is_dir().then_some(p);
    }
    let home = std::env::var("HOME").ok()?;
    let p = PathBuf::from(home).join("Projects/nixdash");
    p.is_dir().then_some(p)
}

fn mtime_secs(p: &Path) -> Option<u64> {
    std::fs::metadata(p)
        .ok()?
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|d| d.as_secs())
}

/// Newest mtime under `qml/`, and which file it was.
///
/// The name matters as much as the number: "stale by 2 hours" prompts a
/// rebuild, but "stale, newest is MonitorPage.qml" tells you what you changed.
fn newest_qml(dir: &Path) -> Option<(u64, String)> {
    let mut newest: Option<(u64, String)> = None;
    for entry in std::fs::read_dir(dir.join("qml")).ok()?.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("qml") {
            continue;
        }
        // Follows the symlink deliberately: `qml/` is the real directory here,
        // and it is the file contents' timestamp that matters.
        if let Some(t) = mtime_secs(&path) {
            let name = path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default();
            if newest.as_ref().is_none_or(|(best, _)| t > *best) {
                newest = Some((t, name));
            }
        }
    }
    newest
}

/// Pull a `KEY:TYPE=value` line out of a CMake cache.
///
/// Reading the cache rather than guessing: it records exactly which Qt the
/// wasm build was configured against, which is the only authoritative answer
/// once several Qt prefixes exist in the store.
fn cmake_cache_value(cache: &str, key: &str) -> Option<String> {
    cache.lines().find_map(|line| {
        let line = line.trim();
        if line.starts_with('#') || line.starts_with("//") {
            return None;
        }
        let (lhs, value) = line.split_once('=')?;
        let name = lhs.split(':').next()?;
        (name == key).then(|| value.trim().to_string())
    })
}

/// The emcc version this Qt was built to expect.
///
/// Qt pins a recommended Emscripten and warns loudly when the toolchain does
/// not match. Mismatches here are not cosmetic: they surface as link errors
/// and ABI breakage deep in a build, long after the point that caused them.
fn emcc_recommended(qt6_cmake_dir: &Path) -> Option<String> {
    for name in ["QtPublicWasmToolchainHelpers.cmake", "QtWasmHelpers.cmake"] {
        let Ok(text) = std::fs::read_to_string(qt6_cmake_dir.join(name)) else {
            continue;
        };
        if let Some(idx) = text.find("QT_EMCC_RECOMMENDED_VERSION") {
            let rest = &text[idx..];
            if let Some(open) = rest.find('"') {
                let after = &rest[open + 1..];
                if let Some(close) = after.find('"') {
                    let v = &after[..close];
                    // Skip the generic `"${recommended_version}"` assignment.
                    if v.chars().next().is_some_and(|c| c.is_ascii_digit()) {
                        return Some(v.to_string());
                    }
                }
            }
        }
    }
    None
}

/// The Emscripten the wasm Qt was ACTUALLY built against, from the store graph.
///
/// This is the half the panel could not previously see. `emcc_recommended` is
/// what Qt asks for; this is what it got, and the pair is the only thing worth
/// comparing.
///
/// Read from Nix's own record rather than from PATH, which was the obvious
/// approach and the wrong one. There is no emcc on this machine's PATH at
/// all (the emsdk lives in `~/Projects/qt6-wasm`'s dev shell), so a PATH
/// probe reports either nothing or some unrelated system emcc. That second
/// case is
/// exactly the false alarm `rust-emscripten-target` was fixed for: a toolchain
/// the build never uses, reported as the toolchain the build uses.
///
/// The derivation names it. `<sdk>.drv` pulls in `qtbase-wasm-*.drv`, which
/// pulls in `emscripten-<version>.drv`, so two bounded lookups find it. Only
/// `-wasm-` inputs are followed, which keeps this to a handful of queries on a
/// 30s interval.
///
/// Returns None when the derivations have been garbage collected - the store
/// path outlives its .drv. That is "could not look", not "they disagree", and
/// the panel must render it as such.
fn emcc_built_with(sdk: &str) -> Option<String> {
    fn query(args: &[&str]) -> Vec<String> {
        let Ok(out) = Command::new("nix-store").args(args).output() else {
            return Vec::new();
        };
        if !out.status.success() {
            return Vec::new();
        }
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty())
            .collect()
    }

    /// `/nix/store/<hash>-emscripten-4.0.10.drv` -> `4.0.10`.
    fn emscripten_version(path: &str) -> Option<String> {
        let name = path.rsplit('/').next()?;
        let rest = name.strip_prefix(|_c: char| true).and(Some(name))?;
        let idx = rest.find("-emscripten-")?;
        let v = &rest[idx + "-emscripten-".len()..];
        let v = v.strip_suffix(".drv").unwrap_or(v);
        v.chars()
            .next()
            .is_some_and(|c| c.is_ascii_digit())
            .then(|| v.to_string())
    }

    let drv = query(&["-q", "--deriver", sdk]).into_iter().next()?;
    let inputs = query(&["-q", "--references", &drv]);
    if let Some(v) = inputs.iter().find_map(|p| emscripten_version(p)) {
        return Some(v);
    }
    // One level deeper, through the cross-compiled Qt modules only.
    inputs
        .iter()
        .filter(|p| p.contains("-wasm-"))
        .find_map(|p| {
            query(&["-q", "--references", p])
                .iter()
                .find_map(|q| emscripten_version(q))
        })
}

/// Do two Emscripten versions agree closely enough for Qt?
///
/// On major.minor, not exactly. qt.md records the measurement: 4.0.10 against
/// a pinned 4.0.7 produces a warning and builds; a different major does not.
/// Comparing exact strings would paint a working pairing as broken, which is
/// the failure this panel exists to avoid.
fn emcc_series_match(wanted: &str, got: &str) -> bool {
    fn series(v: &str) -> (&str, &str) {
        let mut it = v.split('.');
        (it.next().unwrap_or(""), it.next().unwrap_or(""))
    }
    series(wanted) == series(got)
}

/// Qt version of the installed desktop app, for comparison.
fn desktop_qt_version() -> Option<String> {
    let app = ui_candidates().into_iter().find(|p| p.exists())?;
    let bytes = std::fs::read(unwrap_binary(&app)).ok()?;
    crate::collectors::qt_runtime::qt_store_paths(&bytes)
        .into_iter()
        .find_map(|p| version_from_prefix(&p))
}

#[derive(Debug, Serialize)]
struct WasmReading {
    project_dir: Option<String>,
    /// Whether a compiled .wasm exists at all.
    built: bool,
    wasm_bytes: Option<u64>,
    built_at: Option<u64>,
    /// Newest QML mtime, and the file it belongs to.
    newest_qml_at: Option<u64>,
    newest_qml_file: Option<String>,
    /// Built before the newest QML change: the browser UI is out of date.
    stale: bool,
    stale_by_secs: Option<u64>,
    /// Qt-for-wasm prefix the build was configured against.
    sdk: Option<String>,
    sdk_version: Option<String>,
    /// Host Qt used for the build's code generators.
    host_env: Option<String>,
    /// Qt version the installed desktop app links, for comparison.
    desktop_version: Option<String>,
    versions_match: Option<bool>,
    /// Emscripten version this Qt expects.
    emcc_recommended: Option<String>,
    /// Emscripten version it was actually built against, from the store graph.
    emcc_built_with: Option<String>,
    /// Whether those two agree on major.minor. None means one of them is
    /// unknown - never rendered as agreement.
    emcc_series_match: Option<bool>,
}

/// The bundle that is actually SERVED, not the one being linked.
///
/// `ui-wasm/build` holds a mixture of two builds during a link, and keeps
/// the newer mtime even when the link then fails - `build.sh` flips the
/// `current` symlink only on success. Measuring `build` therefore reports
/// "up to date" the moment a build starts and keeps reporting it after one
/// fails, while the tab goes on serving the old bundle. Measured here on
/// 2026-10-23: build/ 09:34, current/ 07:36, newest qml 08:50 - the reading
/// said fresh and the served bundle was two hours behind.
const WASM_APP: &str = "ui-wasm/current/nixdash_ui_wasm_app.wasm";

impl Collector for QtWasmCollector {
    fn meta(&self) -> PanelMeta {
        PanelMeta {
            id: "qt-wasm",
            title: "Qt for WebAssembly",
            description: "Whether the browser UI is built, current, and on the same Qt",
            // Changes only when you rebuild; a cheap stat either way.
            interval_secs: 30,
            subject: Subject::Qt,
            info: Info {
                what: "The state of the WebAssembly build of this same UI: \
                       whether it has been compiled, which Qt-for-wasm it was \
                       configured against, and whether it is older than the \
                       QML it is built from.",
                why: "Both UIs compile from one qml/ directory, symlinked \
                      into each crate. That means an edit reaches both - but \
                      only the desktop build gets recompiled routinely. The \
                      browser build keeps serving whatever was last compiled, \
                      which looks identical to working until you notice a \
                      change you made is missing.",
                if_wrong: "'Stale' is not an error - it means run \
                           ui-wasm/build.sh. A Qt version here that differs \
                           from the Qt runtime panel means the two UIs are \
                           built against different Qt releases, which is \
                           tolerable but makes a bug reproducible in only one \
                           of them. An emcc mismatch is the serious one: it \
                           fails deep in a link step, naming a symbol rather \
                           than the version.",
                sections: &[
                    Section {
                        title: "Why this needs two Qts",
                        body: "Every other platform Qt supports builds with \
one Qt. WebAssembly needs two at once, and that is the single fact most of \
this panel exists to report.<br><br>\
A Qt built <i>for</i> WebAssembly is made of wasm. The tools that run during \
a build - <tt>moc</tt>, <tt>rcc</tt>, <tt>qmltyperegistrar</tt>, \
<tt>qmlcachegen</tt> - cannot execute on your machine in that form. So a \
second, ordinary Qt of the <b>same version</b> has to be present to supply \
them.<br><br>\
<table>\
<tr><td><b><tt>sdk</tt></b>&nbsp;&nbsp;</td><td>the Qt compiled to wasm, \
which the browser UI links against</td></tr>\
<tr><td><b><tt>host_env</tt></b></td><td>the native Qt of the same version, \
which supplies the tools that run during the build</td></tr>\
<tr><td><b><tt>versions_match</tt></b></td><td>whether those two agree - the \
check that exists because mismatching them fails confusingly</td></tr>\
</table><br>\
WebAssembly is one of Qt's platform ports, alongside Windows, macOS, Android \
and the rest - the same API with a different backend. It is simply the port \
with the most setup around it.",
                    },
                    Section {
                        title: "The Emscripten pin",
                        body: "Each Qt release is built against one specific \
Emscripten version, and it is not advisory. <tt>emcc_recommended</tt> is read \
out of the Qt-for-wasm build itself rather than guessed.<br><br>\
Use a different one and the build usually reaches the link step before \
failing, reporting an undefined symbol or an ABI complaint - an error that \
names a symbol, not a version, and so sends you looking at your own code \
first. This is the mismatch worth checking before anything else.<br><br>\
<tt>wasm_bytes</tt> is the size of the compiled output. It is large by web \
standards because a Qt application ships its own toolkit; that is expected, \
not a fault.",
                    },
                    Section {
                        title: "Stale is not broken",
                        body: "Both user interfaces compile from one \
<tt>qml/</tt> directory, symlinked into each build. An edit therefore reaches \
both - but only the desktop one is rebuilt in the ordinary course of \
work.<br><br>\
So the browser build keeps serving whatever was last compiled, which looks \
<i>identical to working</i>. <tt>stale</tt>, <tt>stale_by_secs</tt> and \
<tt>newest_qml_file</tt> exist to make that visible: the last names the file \
that is ahead of the build, which is usually the one you just \
edited.<br><br>\
Rebuilding it is a listed action under Suggested actions, and takes several \
minutes. Nothing is lost by not doing it - only the browser UI is affected, \
and it writes only into a disposable build directory.",
                    },
                    Section {
                        title: "References",
                        body: "<a href='https://doc.qt.io/qt-6/wasm.html'>Qt \
for WebAssembly</a> &middot; \
<a href='https://emscripten.org/'>Emscripten</a> &middot; \
<a href='https://webassembly.org/'>WebAssembly</a> &middot; \
<a href='https://doc.qt.io/qt-6/'>Qt 6 documentation</a>.",
                    },
                ],
            },
            stats: vec![
                StatInfo {
                    key: "built",
                    info: Info {
                        what: "Whether a compiled .wasm exists in \
                               ui-wasm/build.",
                        why: "The browser UI is not built as part of the \
                              normal cargo build - it needs a separate \
                              toolchain and an explicit ui-wasm/build.sh.",
                        if_wrong: "False simply means you have never built \
                                   it, or the build directory was cleaned. It \
                                   is not a fault.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "stale",
                    info: Info {
                        what: "True when the compiled wasm is older than the \
                               newest file in qml/.",
                        why: "This is the failure the shared-QML arrangement \
                              invites. The desktop app shows your change \
                              immediately after a rebuild; the browser one \
                              shows the previous build with no indication \
                              anything is missing.",
                        if_wrong: "Run ui-wasm/build.sh inside \
                                   `nix develop ./ui-wasm`. The wasm toolchain \
                                   is a separate dev shell - the default one \
                                   has no emcc and no wasm32 Rust target.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "stale_by_secs",
                    info: Info {
                        what: "How far behind the wasm build is, in seconds.",
                        why: "Distinguishes 'edited a minute ago, about to \
                              rebuild anyway' from 'this has been out of date \
                              for days'.",
                        if_wrong: "Null when the build is current or absent.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "newest_qml_file",
                    info: Info {
                        what: "The most recently modified file in qml/.",
                        why: "Names what you changed, so the staleness is \
                              actionable rather than just a flag.",
                        if_wrong: "If this is a file you do not recognise \
                                   editing, something else rewrote it - a \
                                   formatter, or a checkout.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "sdk",
                    info: Info {
                        what: "The Qt-for-wasm prefix the build was \
                               configured against, read from the build's \
                               CMakeCache.",
                        why: "Read from the cache rather than inferred, \
                              because once several Qt prefixes exist in the \
                              store only the cache records which one this \
                              build actually used.",
                        if_wrong: "A path that no longer exists means the \
                                   store was garbage collected under the \
                                   build. Re-run cmake; the build directory \
                                   is disposable.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "sdk_version",
                    info: Info {
                        what: "Qt version of that wasm prefix.",
                        why: "Cross-compiled Qt is built from the same \
                              nixpkgs sources as the desktop one, so these \
                              normally match. They drift when one side is \
                              pinned to a different nixpkgs.",
                        if_wrong: "Compare against the Qt runtime panel. A \
                                   difference is worth knowing before \
                                   debugging a bug that reproduces in only \
                                   one UI.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "desktop_version",
                    info: Info {
                        what: "Qt version the installed desktop UI links, \
                               read the same way the Qt runtime panel reads \
                               it.",
                        why: "Carried here so the comparison with the wasm \
                              Qt is made by the engine rather than left to \
                              you to do by eye across two panels.",
                        if_wrong: "Null means the desktop UI is not \
                                   installed, so there is nothing to compare \
                                   against and versions_match is also null.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "versions_match",
                    info: Info {
                        what: "Whether the wasm Qt and the desktop Qt are the \
                               same version.",
                        why: "The whole claim of this project is that one QML \
                              source runs in both places. That claim is \
                              weaker when the two are built against different \
                              Qt releases.",
                        if_wrong: "Null means one side could not be \
                                   determined - usually the desktop UI is not \
                                   installed.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "host_env",
                    info: Info {
                        what: "The host Qt supplying moc, rcc and \
                               qmltyperegistrar for the cross build.",
                        why: "A cross build needs code generators that run on \
                              THIS machine, not wasm binaries. That is what \
                              QT_HOST_PATH provides, and a cross build cannot \
                              proceed without it.",
                        if_wrong: "Missing QT_HOST_PATH is one of the first \
                                   errors a Qt cross build gives, and it says \
                                   so plainly.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "emcc_recommended",
                    info: Info {
                        what: "The Emscripten version this Qt was built to \
                               expect, read from its own CMake helpers.",
                        why: "Qt pins a recommended emcc and warns when the \
                              toolchain differs. The same 4.0 series is \
                              usually accepted; a different major is not. \
                              Mismatches surface as link errors naming a \
                              symbol, far from the real cause.",
                        if_wrong: "If your emcc is from a different nixpkgs \
                                   than this Qt, pin the nixpkgs that carries \
                                   the matching version rather than \
                                   overriding the check.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "emcc_built_with",
                    info: Info {
                        what: "The Emscripten this Qt was actually compiled \
                               with, read from the derivation that built it.",
                        why: "This is the other half of the pairing, and \
                              until it existed the panel could state what Qt \
                              wanted and nothing more. Nix records which \
                              Emscripten went into the wasm Qt, so the \
                              question is answerable without guessing.",
                        if_wrong: "Blank means the derivations were garbage \
                                   collected - a store path outlives its \
                                   .drv. That is 'could not look', not 'they \
                                   agree'. It is NOT read from PATH, \
                                   deliberately: there is no emcc there, and \
                                   an unrelated system one would be a false \
                                   alarm about a toolchain no build uses.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "emcc_series_match",
                    info: Info {
                        what: "Whether the Emscripten Qt asked for and the \
                               one it got agree on major.minor.",
                        why: "Compared on the series rather than exactly, \
                              because that is what Qt enforces: 4.0.10 \
                              against a pinned 4.0.7 warns and builds. An \
                              exact comparison would call a working pairing \
                              broken.",
                        if_wrong: "Blank whenever either version is unknown, \
                                   never 'yes'. A no means a different major \
                                   or minor, which surfaces later as link \
                                   errors naming a symbol rather than a \
                                   toolchain.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "wasm_bytes",
                    info: Info {
                        what: "Size of the compiled .wasm.",
                        why: "A Qt wasm binary is tens of megabytes - that is \
                              normal, and most of it is Qt itself. Worth \
                              knowing before serving it over anything slow.",
                        if_wrong: "A sudden drop usually means a build \
                                   failed partway and left a truncated file.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "built_at",
                    info: Info {
                        what: "When the wasm was last compiled, as a Unix \
                               timestamp.",
                        why: "The other half of the staleness comparison.",
                        if_wrong: "A timestamp of 0 or 1970 would mean the \
                                   file came from the Nix store, where mtimes \
                                   are normalised - not the case for a local \
                                   build directory.",
                        sections: &[Section {
                            title: "Why these are raw epoch seconds",
                            body: "Both \
timestamps are seconds since 1970 rather than dates, and the staleness check \
compares them directly. There is a reason it is not done the obvious \
way.<br><br>\
<b>Every file in the Nix store has the same modification time</b> - the \
epoch - because reproducible builds cannot embed the moment they ran. So the \
installed copy of anything is timestamped 1970, and any comparison against \
it is meaningless.<br><br>\
What is compared instead: <tt>built_at</tt> comes from the build output in \
the working tree, which is an ordinary directory with real times, and \
<tt>newest_qml_at</tt> from the newest source file. The same trap is why the \
menu entry compares against a generation symlink rather than a store \
path.<br><br>\
A <tt>built_at</tt> at or near zero means the build output being looked at \
came from the store, and the staleness answer should not be trusted.",
                        }],
                    },
                },
                StatInfo {
                    key: "newest_qml_at",
                    info: Info {
                        what: "Newest mtime in qml/, as a Unix timestamp.",
                        why: "Compared against built_at to decide staleness.",
                        if_wrong: "Null means qml/ could not be read, which \
                                   would mean the project directory is not \
                                   where this panel thinks it is.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "project_dir",
                    info: Info {
                        what: "The project directory being inspected.",
                        why: "Set NIXDASH_PROJECT_DIR to point this \
                              elsewhere. Hard-coding it would make the panel \
                              silently measure nothing on another machine.",
                        if_wrong: "Null means neither the environment \
                                   variable nor the default path resolved to \
                                   a directory, and this panel can say \
                                   nothing.",
                        sections: &[],
                    },
                },
            ],
        }
    }

    fn sample(&self) -> Result<Value> {
        let Some(dir) = project_dir() else {
            return Ok(serde_json::to_value(WasmReading {
                project_dir: None,
                built: false,
                wasm_bytes: None,
                built_at: None,
                newest_qml_at: None,
                newest_qml_file: None,
                stale: false,
                stale_by_secs: None,
                sdk: None,
                sdk_version: None,
                host_env: None,
                desktop_version: None,
                versions_match: None,
                emcc_recommended: None,
                emcc_built_with: None,
                emcc_series_match: None,
            })?);
        };

        let wasm = dir.join(WASM_APP);
        let built = wasm.exists();
        let built_at = mtime_secs(&wasm);
        let wasm_bytes = std::fs::metadata(&wasm).ok().map(|m| m.len());

        let newest = newest_qml(&dir);
        let newest_qml_at = newest.as_ref().map(|(t, _)| *t);
        let newest_qml_file = newest.as_ref().map(|(_, n)| n.clone());

        let (stale, stale_by_secs) = match (built_at, newest_qml_at) {
            (Some(b), Some(q)) if q > b => (true, Some(q - b)),
            _ => (false, None),
        };

        // The CMake cache is the authority on what this build used.
        let cache = std::fs::read_to_string(dir.join("ui-wasm/build/CMakeCache.txt")).ok();
        let qt6_dir = cache
            .as_deref()
            .and_then(|c| cmake_cache_value(c, "Qt6_DIR"));
        let host_env = cache
            .as_deref()
            .and_then(|c| cmake_cache_value(c, "QT_HOST_PATH"));

        // Qt6_DIR points at <prefix>/lib/cmake/Qt6; the prefix is three up.
        let sdk = qt6_dir.as_deref().and_then(|d| {
            Path::new(d)
                .ancestors()
                .nth(3)
                .map(|p| p.display().to_string())
        });
        let sdk_version = sdk.as_deref().and_then(version_from_prefix).or_else(|| {
            // Static wasm builds ship .a files, not .so - fall back to the
            // version in the store path's own name.
            sdk.as_deref()
                .and_then(|p| p.rsplit('-').next())
                .filter(|v| v.chars().next().is_some_and(|c| c.is_ascii_digit()))
                .map(|v| v.to_string())
        });

        let emcc_recommended = qt6_dir
            .as_deref()
            .and_then(|d| emcc_recommended(Path::new(d)));

        let emcc_built_with = sdk.as_deref().and_then(emcc_built_with);
        let emcc_series_match = match (&emcc_recommended, &emcc_built_with) {
            (Some(w), Some(g)) => Some(emcc_series_match(w, g)),
            _ => None,
        };

        let desktop_version = desktop_qt_version();
        let versions_match = match (&sdk_version, &desktop_version) {
            (Some(a), Some(b)) => Some(a == b),
            _ => None,
        };

        Ok(serde_json::to_value(WasmReading {
            project_dir: Some(dir.display().to_string()),
            built,
            wasm_bytes,
            built_at,
            newest_qml_at,
            newest_qml_file,
            stale,
            stale_by_secs,
            sdk,
            sdk_version,
            host_env,
            desktop_version,
            versions_match,
            emcc_recommended,
            emcc_built_with,
            emcc_series_match,
        })?)
    }

    fn status(&self, v: &Value) -> (Status, String) {
        if v["project_dir"].is_null() {
            return (Status::Unknown, "project directory not found".into());
        }
        if !v["built"].as_bool().unwrap_or(false) {
            // Never built is a legitimate state, not a fault: the wasm build
            // is opt-in and needs its own dev shell.
            return (Status::Unknown, "browser UI not built".into());
        }

        let version = v["sdk_version"].as_str().unwrap_or("unknown Qt");

        if v["stale"].as_bool().unwrap_or(false) {
            let mins = v["stale_by_secs"].as_u64().unwrap_or(0) / 60;
            let file = v["newest_qml_file"].as_str().unwrap_or("qml/");
            let ago = if mins >= 120 {
                format!("{} hours", mins / 60)
            } else {
                format!("{mins} min")
            };
            return (
                Status::Warn,
                format!("browser UI is {ago} behind {file} - rebuild it"),
            );
        }

        if v["versions_match"] == Value::Bool(false) {
            let desktop = v["desktop_version"].as_str().unwrap_or("?");
            return (
                Status::Warn,
                format!("built, but on Qt {version} while the desktop runs {desktop}"),
            );
        }

        (Status::Ok, format!("built and current · Qt {version}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cmake_cache_values_are_parsed_past_their_type_tag() {
        let cache = "\
// a comment
#another
CMAKE_TOOLCHAIN_FILE:UNINITIALIZED=/nix/store/aaa-qtbase-wasm/lib/cmake/Qt6/qt.toolchain.cmake
Qt6_DIR:PATH=/nix/store/bbb-qt6-wasm-6.11.2/lib/cmake/Qt6
";
        assert_eq!(
            cmake_cache_value(cache, "Qt6_DIR").as_deref(),
            Some("/nix/store/bbb-qt6-wasm-6.11.2/lib/cmake/Qt6")
        );
        assert!(cmake_cache_value(cache, "NOT_PRESENT").is_none());
    }

    #[test]
    fn comments_are_not_mistaken_for_entries() {
        // CMake caches put help text in `//` lines containing '='.
        let cache = "// Qt6_DIR:PATH=/wrong/path\nQt6_DIR:PATH=/right/path\n";
        assert_eq!(
            cmake_cache_value(cache, "Qt6_DIR").as_deref(),
            Some("/right/path")
        );
    }

    #[test]
    fn absence_is_a_reading_not_an_error() {
        let v = QtWasmCollector.sample().expect("absence must not error");
        let (_status, headline) = QtWasmCollector.status(&v);
        assert!(!headline.is_empty());
        assert!(!headline.to_lowercase().contains("no qt in"));
    }

    #[test]
    fn staleness_needs_both_timestamps() {
        // Guards the comparison itself: a missing build must not read as
        // "current" through an unwrap_or(0) on the other side.
        let v = QtWasmCollector.sample().unwrap();
        if v["built_at"].is_null() || v["newest_qml_at"].is_null() {
            assert_eq!(v["stale"], Value::Bool(false));
            assert!(v["stale_by_secs"].is_null());
        }
    }
}
