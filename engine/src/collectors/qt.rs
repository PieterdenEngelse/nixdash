use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::Result;
use serde::Serialize;
use serde_json::Value;

use crate::collector::{Collector, Info, PanelMeta, Section, StatInfo, Status, Subject};

/// The Qt development setup, judged by whether it will actually work.
///
/// Not "is Qt installed" - that is easy and uninteresting. The question that
/// costs hours on NixOS is whether the qmake you are pointed at reports a
/// *complete* prefix. cxx-qt interrogates one qmake for headers, libs AND host
/// tools, but nixpkgs splits those across store paths: qmltyperegistrar and
/// qmlcachegen ship in qtdeclarative, not qtbase. A prefix missing them builds
/// fine right up until it does not.
///
/// This panel answers that question directly instead of leaving you to
/// discover it from a link error.
pub struct QtCollector;

/// Host tools cxx-qt needs. Absence of any one of these means the prefix is
/// split and a cxx-qt build will fail - see ~/docs/qt.md, Part 1.
const REQUIRED_TOOLS: &[&str] = &["moc", "rcc", "qmltyperegistrar", "qmlcachegen"];

#[derive(Debug, Serialize)]
struct QtReading {
    /// Where the qmake came from: the QMAKE env var, or PATH.
    source: &'static str,
    qmake: Option<String>,
    version: Option<String>,
    prefix: Option<String>,
    host_libexecs: Option<String>,
    /// e.g. "linux-g++" or "wasm-emscripten"
    target_spec: Option<String>,
    /// Host tools present in QT_HOST_LIBEXECS.
    tools_found: Vec<String>,
    /// Host tools that are missing - the ones that break cxx-qt.
    tools_missing: Vec<String>,
    /// True when every required tool resolves from this one prefix.
    prefix_complete: bool,
}

fn qmake_query(qmake: &Path, key: &str) -> Option<String> {
    let out = Command::new(qmake).args(["-query", key]).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if s.is_empty() || s == "**Unknown**" {
        None
    } else {
        Some(s)
    }
}

/// Prefer an explicit QMAKE over PATH: that is the one a build will use, and
/// reporting on a different qmake than the build uses would be worse than
/// reporting nothing.
fn find_qmake() -> Option<(&'static str, PathBuf)> {
    if let Ok(q) = std::env::var("QMAKE") {
        let p = PathBuf::from(q);
        if p.is_file() {
            return Some(("QMAKE env var", p));
        }
    }
    if let Ok(path) = std::env::var("PATH") {
        for dir in path.split(':') {
            for name in ["qmake6", "qmake"] {
                let p = Path::new(dir).join(name);
                if p.is_file() {
                    return Some(("PATH", p));
                }
            }
        }
    }
    qmake_in_ui_closure()
}

/// Last resort: a qmake inside the prefix the installed UI links against.
///
/// Not a PATH lookup - see `qt_runtime` for why PATH is the wrong question on
/// NixOS. The UI's own closure is a real prefix on this machine, and if it
/// carries a qmake this panel can report a *measured* version and tool set
/// instead of shrugging.
///
/// It exists because the shrug was dishonest. The headline used to read "no
/// qmake on PATH - cannot tell whether a Qt build would work" while the panel
/// beside it displayed a merged prefix whose qmake answers `-query` and whose
/// libexec holds all four host tools. "Cannot tell" was an inference, and a
/// false one.
///
/// It must stay LAST. What a build *in this environment* would use is QMAKE or
/// PATH; reporting on a different qmake than the build uses would be worse
/// than reporting nothing, which is why the source is named in the reading and
/// the headline says where it came from.
fn qmake_in_ui_closure() -> Option<(&'static str, PathBuf)> {
    use crate::collectors::qt_runtime::{qt_store_paths, ui_candidates, unwrap_binary};

    let app = ui_candidates().into_iter().find(|p| p.exists())?;
    let bytes = std::fs::read(unwrap_binary(&app)).ok()?;
    for prefix in qt_store_paths(&bytes) {
        for name in ["qmake6", "qmake"] {
            let p = Path::new(&prefix).join("bin").join(name);
            if p.is_file() {
                return Some((UI_CLOSURE, p));
            }
        }
    }
    None
}

/// Source label for the closure fallback. A constant because the headline
/// has to recognise it, and a typo would silently change the claim.
pub(crate) const UI_CLOSURE: &str = "the Qt this app runs against";

impl Collector for QtCollector {
    fn meta(&self) -> PanelMeta {
        PanelMeta {
            id: "qt",
            title: "Qt",
            description: "Which Qt a build would use, and whether its prefix is complete",
            // Only changes when you enter a different shell.
            interval_secs: 60,
            subject: Subject::Qt,
            info: Info {
                what: "The qmake a build would use, and whether the prefix it \
                       reports contains every host tool cxx-qt needs. This is \
                       about BUILDING Qt software - it says nothing about \
                       whether Qt is installed or running.\n\n\
                       Three places are searched, in the order that decides \
                       what a build actually uses: the QMAKE variable, then \
                       PATH, then - only to have something measured rather \
                       than nothing - the Qt prefix this app's own window is \
                       drawn with. A qmake found in that last place is \
                       reported, never counted as a working build setup.",
                why: "cxx-qt interrogates ONE qmake for headers, libraries and \
                      host tools. nixpkgs splits those across store paths - \
                      qmltyperegistrar and qmlcachegen ship in qtdeclarative, \
                      not qtbase - so a qtbase-only prefix looks fine and then \
                      fails.",
                if_wrong: "'No qmake on PATH' does NOT mean Qt is absent. \
                           nixdash itself is a Qt program and is drawing this \
                           text with libQt6Qml right now: runtime libraries \
                           come from the binary's own Nix closure, found by \
                           RPATH, never from PATH. qmake is a development \
                           tool, which on NixOS normally exists only inside a \
                           devShell - so this panel reads 'unknown' on a \
                           perfectly healthy machine, and that is correct. \
                           An incomplete prefix, by contrast, fails late \
                           during code generation with an error naming the \
                           missing tool rather than the real cause: use \
                           pkgs.qt6.env for a merged prefix, since a plain \
                           symlinkJoin is ignored - nixpkgs' qmake has its \
                           prefix baked in.\n\n\
                           When the headline names a version 'in this app's \
                           own closure', nothing here points a build at it: \
                           that qmake was found inside the store path this \
                           app's Qt comes from. It is a real prefix and the \
                           tool list beside it was measured from it - but to \
                           build against it you still have to point a build \
                           there, which is what the development shell's QMAKE \
                           does.",
                sections: &[
                    Section {
                        title: "Where qmake is looked for",
                        body: "Three places, in the order that decides what a \
build actually uses. The first hit wins, and the panel says which one it \
was.<br><br>\
<table>\
<tr><td><b><tt>QMAKE</tt></b>&nbsp;&nbsp;</td><td>An explicit path you set. \
This is the one to use on NixOS: it names a prefix rather than hoping the \
right one is first on <tt>PATH</tt>.</td></tr>\
<tr><td><b><tt>PATH</tt></b></td><td>The usual lookup. Inside a devShell this \
is normally the right answer; outside one there is usually no qmake at all, \
which is not a fault.</td></tr>\
<tr><td><b>this app's own Qt</b></td><td>Last resort, so that something is \
measured rather than nothing. A qmake found here is <i>reported</i> and never \
counted as a working build setup - no build is pointed at it.</td></tr>\
</table><br>\
Remember whose environment is being searched: the app's background service, \
not the shell you are sitting in. Entering a devShell in a terminal will not \
change what this panel says.",
                    },
                    Section {
                        title: "Why one prefix is not enough",
                        body: "cxx-qt interrogates a single qmake and takes \
its answer as the whole truth - headers, libraries and the host tools that \
generate code. nixpkgs does not ship Qt that way. Each Qt module is its own \
store path, and the tools are spread across them:<br><br>\
<table>\
<tr><td><b>qtbase</b>&nbsp;&nbsp;</td><td><tt>moc</tt>, <tt>rcc</tt>, \
<tt>uic</tt>, <tt>qmake</tt></td></tr>\
<tr><td><b>qtdeclarative</b></td><td><tt>qmltyperegistrar</tt>, \
<tt>qmlcachegen</tt></td></tr>\
</table><br>\
So a qtbase-only prefix is complete by its own lights and still cannot build \
QML. The failure arrives late, during code generation, naming the missing \
tool rather than the prefix that lacks it.<br><br>\
<b>The fix is <tt>pkgs.qt6.env</tt></b>, which produces one prefix carrying \
all of them. A plain <tt>symlinkJoin</tt> does not work here: nixpkgs' qmake \
has its own prefix compiled in, so it reports where it was built rather than \
where you linked it.",
                    },
                    Section {
                        title: "Build time is not run time",
                        body: "These are two unrelated questions, and treating \
them as one is the most common misreading of how Nix works.<br><br>\
<b>Running</b> a Qt program needs libraries, which the executable finds \
through <tt>RPATH</tt> - a list of store paths baked into the binary when it \
was linked. <tt>PATH</tt> plays no part whatsoever.<br><br>\
<b>Building</b> Qt software needs development tools, which are found through \
<tt>PATH</tt> or <tt>QMAKE</tt> and on NixOS usually exist only inside a \
devShell.<br><br>\
That is why this panel can honestly report no qmake while the window you are \
reading it in is drawn by Qt. The Qt runtime panel answers the other \
question.",
                    },
                    Section {
                        title: "References",
                        body: "<a href='https://doc.qt.io/qt-6/qmake-manual.html'>\
qmake manual</a> &middot; \
<a href='https://doc.qt.io/qt-6/'>Qt 6 documentation</a> &middot; \
<a href='https://nixos.org/manual/nixpkgs/stable/'>nixpkgs manual</a>, whose \
Qt section covers the wrapper hooks and why Qt packages are split &middot; \
<a href='https://github.com/KDAB/cxx-qt'>cxx-qt</a>, which is what asks qmake \
these questions during this project's own build.",
                    },
                ],
            },
            stats: vec![
                StatInfo {
                    key: "source",
                    info: Info {
                        what: "Where the qmake was found: the QMAKE \
                               environment variable, PATH, or - last - the Qt \
                               prefix this app itself runs against.",
                        why: "QMAKE wins if set, and that is what a build \
                              uses. Reporting on a different qmake than the \
                              build uses would be worse than reporting \
                              nothing.",
                        if_wrong: "\"not found\" means no Qt build could run \
                                   here - it does not mean Qt is absent. \
                                   Installed Qt programs keep working, \
                                   including this one: they load their \
                                   libraries by RPATH from their own closure, \
                                   not from PATH. If the source reads 'the Qt \
                                   this app runs against', no build here would \
                                   use that qmake either - it is reported \
                                   because it is the one thing about a build \
                                   prefix this machine can actually show you.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "qmake",
                    info: Info {
                        what: "Full path to the qmake being queried.",
                        why: "A store path tells you which derivation provided \
                              it - a merged env, plain qtbase, or a cross \
                              build.",
                        if_wrong: "If this points at qtbase alone, expect the \
                                   missing-tools problem below.",
                        sections: &[Section {
                            title: "Reading a store path",
                            body: "A path like \
<tt>/nix/store/<i>hash</i>-qtbase-6.11.2-dev/bin/qmake</tt> answers more than \
'where is qmake'.<br><br>\
<ul>\
<li>The <b>hash</b> is computed from every input that built it - sources, \
compiler, flags, dependencies. Two Qts with the same version but different \
hashes are genuinely different builds, and that is why a version number \
alone cannot tell you whether a prefix is coherent.</li>\
<li>The <b>name</b> says which package provided it. <tt>qtbase</tt> here is \
the warning sign this panel exists for: qtbase alone cannot build QML.</li>\
<li>The <b><tt>-dev</tt></b> suffix is a separate output of the same \
package, holding headers and development tools. The libraries a running \
program loads live in the output without it - which is why running Qt and \
building Qt reach for different store paths.</li>\
</ul>\
A path outside <tt>/nix/store</tt> means something is supplying qmake from \
elsewhere, and whatever it reports cannot be trusted to match what a Nix \
build would use.",
                        }],
                    },
                },
                StatInfo {
                    key: "version",
                    info: Info {
                        what: "QT_VERSION as that qmake reports it.",
                        why: "Host and target Qt must match exactly when \
                              cross-compiling, and each Qt release pins a \
                              specific Emscripten version for WebAssembly.",
                        if_wrong: "A mismatch between host and target Qt fails \
                                   the cross build immediately.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "prefix",
                    info: Info {
                        what: "QT_INSTALL_PREFIX - the root this qmake reports \
                               for headers and libraries.",
                        why: "On NixOS this is the single most informative \
                              value: it reveals whether you have one coherent \
                              Qt or several.",
                        if_wrong: "A prefix that is a bare qtbase store path \
                                   cannot satisfy a QML build.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "host_libexecs",
                    info: Info {
                        what: "QT_HOST_LIBEXECS - where moc, rcc and friends \
                               live.",
                        why: "This is the directory actually checked for the \
                              required tools.",
                        if_wrong: "Null means qmake could not say, and no tool \
                                   check was possible.",
                        sections: &[Section {
                            title: "Why libexec, not bin",
                            body: "Qt 6 moved its \
code-generation tools out of <tt>bin</tt> and into <tt>libexec</tt>, which is \
why this row exists separately from the prefix.<br><br>\
They are not commands you are expected to run. <tt>moc</tt>, <tt>rcc</tt>, \
<tt>uic</tt>, <tt>qmltyperegistrar</tt> and <tt>qmlcachegen</tt> are invoked \
by the build system with arguments it computes, and putting them on \
<tt>PATH</tt> would offer you tools you have no reason to call by \
hand.<br><br>\
The practical consequence: looking for <tt>moc</tt> on your <tt>PATH</tt> and \
not finding it proves nothing either way. This directory is the one that \
decides, and it is the one checked.",
                        }],
                    },
                },
                StatInfo {
                    key: "target_spec",
                    info: Info {
                        what: "QMAKE_XSPEC - the platform this Qt builds for.",
                        why: "Distinguishes a host Qt (linux-g++) from a \
                              cross-compiled one (wasm-emscripten).",
                        if_wrong: "Seeing wasm-emscripten when you meant to \
                                   build a desktop app means QMAKE points at \
                                   the wasm SDK.",
                        sections: &[Section {
                            title: "mkspecs",
                            body: "<tt>QMAKE_XSPEC</tt> names the platform \
this Qt produces output for. It is how a host Qt and a cross-compiling Qt are \
told apart, since both answer every other question identically.<br><br>\
<table>\
<tr><td><b><tt>linux-g++</tt></b>&nbsp;&nbsp;</td><td>an ordinary native Qt, \
GCC - what this machine expects</td></tr>\
<tr><td><b><tt>linux-clang</tt></b></td><td>native, Clang instead</td></tr>\
<tr><td><b><tt>wasm-emscripten</tt></b></td><td>Qt for WebAssembly - see that \
panel, not this one</td></tr>\
<tr><td><b><tt>macx-clang</tt></b>, <b><tt>win32-g++</tt></b></td><td>other \
host platforms</td></tr>\
</table><br>\
A surprise here is worth taking seriously: a wasm spec on this panel means \
<tt>QMAKE</tt> is pointing at the cross Qt, and an ordinary desktop build \
would produce WebAssembly or fail in ways that make no sense until you look \
at this row.",
                        }],
                    },
                },
                StatInfo {
                    key: "tools_found",
                    info: Info {
                        what: "Required host tools present in this prefix.",
                        why: "moc and rcc come with qtbase; qmltyperegistrar \
                              and qmlcachegen only with qtdeclarative.",
                        if_wrong: "Two of four is the classic split-prefix \
                                   signature.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "tools_missing",
                    info: Info {
                        what: "Required host tools this prefix does not have.",
                        why: "Each one here is a build failure waiting to \
                              happen.",
                        if_wrong: "Non-empty means a cxx-qt QML build will \
                                   fail. Merge the prefix rather than adding \
                                   more entries to buildInputs.",
                        sections: &[Section {
                            title: "What each tool does",
                            body: "All four run during a \
build and all four must come from one prefix.<br><br>\
<table>\
<tr><td><b><tt>moc</tt></b>&nbsp;&nbsp;</td><td>qtbase&nbsp;&nbsp;</td>\
<td>reads headers and generates the code behind signals and slots</td></tr>\
<tr><td><b><tt>rcc</tt></b></td><td>qtbase</td><td>compiles QML and assets \
into the binary as a resource bundle</td></tr>\
<tr><td><b><tt>qmltyperegistrar</tt></b></td><td>qtdeclarative</td>\
<td>registers C++ types so QML can name them</td></tr>\
<tr><td><b><tt>qmlcachegen</tt></b></td><td>qtdeclarative</td><td>precompiles \
QML so it is not parsed at startup</td></tr>\
</table><br>\
The split down the middle is the whole problem: the first two come with \
qtbase, so a qtbase-only prefix passes a casual check and then fails on the \
second two.<br><br>\
<b>Do not fix this by adding packages to <tt>buildInputs</tt>.</b> The \
build asks <i>one</i> qmake where the tools are, and a second package in the \
build inputs does not change that answer. Give it a merged prefix \
instead.",
                        }],
                    },
                },
                StatInfo {
                    key: "prefix_complete",
                    info: Info {
                        what: "True when all four required tools resolve from \
                               this one prefix.",
                        why: "The verdict the whole panel exists for: will a \
                              cxx-qt build work here?",
                        if_wrong: "False is not a warning, it is a prediction \
                                   of failure.",
                        sections: &[Section {
                            title: "What is actually tested",
                            body: "Not 'is \
qtdeclarative installed' - that question has misled people here before. Each \
of the four tools is resolved <b>from the prefix this qmake reports</b>, and \
the row is true only when all four resolve from that one place.<br><br>\
That is deliberately the same thing the build will do, so a true here means \
a build gets the same answer. A false names which tools are absent in the \
<tt>tools_missing</tt> row rather than leaving you to guess.<br><br>\
<b>Unknown is not false.</b> If no qmake was found at all there is nothing to \
test, and the panel says so rather than reporting a failure it never \
measured - a monitor that reassures or alarms you about a check it could not \
run is worse than no monitor.",
                        }],
                    },
                },
            ],
        }
    }

    fn sample(&self) -> Result<Value> {
        let Some((source, qmake)) = find_qmake() else {
            return Ok(serde_json::to_value(QtReading {
                source: "not found",
                qmake: None,
                version: None,
                prefix: None,
                host_libexecs: None,
                target_spec: None,
                tools_found: Vec::new(),
                tools_missing: REQUIRED_TOOLS.iter().map(|s| s.to_string()).collect(),
                prefix_complete: false,
            })?);
        };

        let version = qmake_query(&qmake, "QT_VERSION");
        let prefix = qmake_query(&qmake, "QT_INSTALL_PREFIX");
        let host_libexecs = qmake_query(&qmake, "QT_HOST_LIBEXECS");
        let target_spec = qmake_query(&qmake, "QMAKE_XSPEC");

        let (found, missing): (Vec<String>, Vec<String>) = match &host_libexecs {
            Some(dir) => REQUIRED_TOOLS
                .iter()
                .map(|t| (t.to_string(), Path::new(dir).join(t).exists()))
                .fold((vec![], vec![]), |(mut f, mut m), (t, exists)| {
                    if exists {
                        f.push(t)
                    } else {
                        m.push(t)
                    }
                    (f, m)
                }),
            None => (
                Vec::new(),
                REQUIRED_TOOLS.iter().map(|s| s.to_string()).collect(),
            ),
        };

        Ok(serde_json::to_value(QtReading {
            source,
            qmake: Some(qmake.display().to_string()),
            version,
            prefix,
            host_libexecs,
            target_spec,
            prefix_complete: missing.is_empty(),
            tools_found: found,
            tools_missing: missing,
        })?)
    }

    fn status(&self, v: &Value) -> (Status, String) {
        let complete = v["prefix_complete"].as_bool().unwrap_or(false);
        let version = v["version"].as_str();

        // No qmake here is not a fault - most shells have none, and flagging
        // it red would make the panel cry wolf everywhere except a Qt dev
        // shell. It is only Bad when a qmake exists but its prefix cannot
        // satisfy a build, because that is the case that fails late and
        // confusingly.
        //
        // The headline says *qmake*, deliberately, and not "no Qt". This
        // panel is about whether you could BUILD Qt software here, and the
        // only thing it looked for is the build tool. Qt's runtime libraries
        // are a separate question it never asked - and the answer is plainly
        // yes, since the app asking it is itself a Qt program. Saying "no Qt
        // in this environment" while rendering through libQt6Qml was simply
        // false, and the kind of false that teaches someone the wrong model.
        // A qmake found in the app's own closure is NOT the one a build here
        // would use, so it never makes this panel Ok. It does replace a shrug
        // with two measurements: nothing on PATH, and a prefix on this machine
        // that either is or is not complete. "Cannot tell whether a Qt build
        // would work" was an inference, and the Qt runtime panel beside this
        // one was already contradicting it.
        let from_closure = v["source"].as_str() == Some(UI_CLOSURE);

        match (version, complete, from_closure) {
            (Some(ver), true, false) => (Status::Ok, format!("{ver}, prefix complete")),
            (Some(ver), false, false) => {
                let missing = v["tools_missing"].as_array().map_or(0, |a| a.len());
                (
                    Status::Bad,
                    format!("{ver}, {missing} host tool(s) missing"),
                )
            }
            (Some(ver), true, true) => (
                Status::Unknown,
                format!(
                    "no qmake on PATH - {ver} with a complete prefix in this app's own closure"
                ),
            ),
            (Some(ver), false, true) => {
                let missing = v["tools_missing"].as_array().map_or(0, |a| a.len());
                (
                    Status::Unknown,
                    // "own closure", like the three branches around it, and
                    // not "own prefix": this one said the latter, so a
                    // closure-sourced qmake with an INCOMPLETE prefix was the
                    // single state whose headline never named where the
                    // version came from. The test for that has always been
                    // here; nothing reached this branch until a UI rebuilt
                    // against the merged Qt env made the closure the source.
                    format!(
                        "no qmake on PATH - {ver} in this app's own closure, \
                         missing {missing} host tool(s)"
                    ),
                )
            }
            (None, _, _) => (
                Status::Unknown,
                "no qmake on PATH, and none in this app's own closure".into(),
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reports_absence_without_failing() {
        // No Qt is a legitimate state, not an error: most shells have none.
        // The panel must say so rather than erroring, or it is noise on every
        // machine that is not mid-Qt-build.
        let v = QtCollector.sample().expect("absence is not an error");
        assert!(v["prefix_complete"].as_bool().is_some());
        assert!(v["tools_missing"].is_array());
    }

    #[test]
    fn headline_states_measurements_not_inferences() {
        // The headline used to read "no qmake on PATH - cannot tell whether a
        // Qt build would work" while the runtime panel beside it displayed a
        // merged prefix with all four host tools. Whatever this machine's
        // state, the headline must describe what was looked at.
        let v = QtCollector.sample().unwrap();
        let (_, headline) = QtCollector.status(&v);
        assert!(
            !headline.contains("cannot tell"),
            "headline {headline:?} shrugs instead of reporting a measurement"
        );
        if v["source"].as_str() == Some(UI_CLOSURE) {
            assert!(
                headline.contains("own closure") && headline.contains("no qmake on PATH"),
                "a closure-sourced qmake must say both where it was found and \
                 that PATH had none: {headline:?}"
            );
        }
    }

    #[test]
    fn closure_qmake_never_reads_as_a_working_build_setup() {
        // Found-in-our-own-closure is a measurement, not a green light: a
        // build here would use QMAKE or PATH, neither of which has one.
        let v = QtCollector.sample().unwrap();
        if v["source"].as_str() == Some(UI_CLOSURE) {
            let (status, _) = QtCollector.status(&v);
            assert_eq!(status, Status::Unknown);
        }
    }

    #[test]
    fn missing_tools_mean_incomplete() {
        // The invariant the panel exists for.
        let v = QtCollector.sample().unwrap();
        let missing = v["tools_missing"].as_array().unwrap().len();
        let complete = v["prefix_complete"].as_bool().unwrap();
        assert_eq!(complete, missing == 0);
    }
}
