use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::Result;
use serde::Serialize;
use serde_json::Value;

use crate::collector::{Collector, Info, PanelMeta, StatInfo, Status, Subject};

/// The Rust toolchain, judged by what it can actually build.
///
/// A version number alone does not tell you whether `cargo build --target
/// wasm32-unknown-emscripten` will work. nixpkgs' rustc ships std for the host
/// only, so a cross target fails with "can't find crate for `std`" - and the
/// fix (a fenix toolchain) is invisible from `rustc --version`. This panel
/// reports the installed target std libraries instead, which is the thing that
/// decides.
///
/// It also notes `lld`, because wasm32-unknown-unknown needs it and its
/// absence surfaces as `linker 'lld' not found` rather than anything about
/// targets.
pub struct RustCollector;

/// Where the standard library *sources* live, if they are installed at all.
///
/// rust-analyzer resolves `std` by reading these sources. Without them every
/// `Vec`, `String` and `Option` is unresolved in the editor - which reads as
/// "rust-analyzer is broken" rather than "a component is missing", because
/// rust-analyzer itself starts and runs perfectly.
///
/// On NixOS this is its own package (`rustPlatform.rustLibSrc`, or the
/// `rust-src` component of a fenix toolchain). Installing `rustc` does not
/// bring it. `RUST_SRC_PATH` is the override; otherwise it sits under the
/// toolchain's own sysroot.
pub(crate) fn rust_src() -> Option<String> {
    if let Ok(p) = std::env::var("RUST_SRC_PATH") {
        if Path::new(&p).is_dir() {
            return Some(p);
        }
    }
    // rustc --print sysroot, then the conventional path beneath it.
    let sysroot = first_line("rustc", &["--print", "sysroot"])?;
    let candidate = Path::new(sysroot.trim()).join("lib/rustlib/src/rust/library");
    candidate.is_dir().then(|| candidate.display().to_string())
}

#[derive(Debug, Serialize)]
struct RustReading {
    rustc: Option<String>,
    cargo: Option<String>,
    /// Resolved rustc path - distinguishes a nixpkgs toolchain from a fenix
    /// one, which is otherwise guesswork.
    rustc_path: Option<String>,
    /// Target std libraries actually installed.
    targets: Vec<String>,
    host_target: Option<String>,
    /// wasm32-unknown-unknown needs lld; absent, the error names the linker
    /// rather than the target.
    lld_available: bool,
    /// The C compiler rustc shells out to for the final link step. Its
    /// absence is the single most common first failure on a fresh NixOS
    /// shell, and the error names `cc`, not Rust.
    cc_available: bool,
    cc_path: Option<String>,
    /// pkg-config, through which every `-sys` crate locates its C library.
    pkg_config_available: bool,
    /// Standard library *sources*, which rust-analyzer needs to resolve
    /// std. Shipped as the `rust-src` component, which is not installed by
    /// adding `rustc` to a package list.
    rust_src_available: bool,
    rust_src_path: Option<String>,
    /// Toolchain components that are separate packages on NixOS: cargo does
    /// not vendor these, so `cargo clippy` fails without them on PATH.
    components_found: Vec<String>,
    components_missing: Vec<String>,
    /// Cargo's environment as the engine sees it. All normally unset; each
    /// one silently changes where builds read and write.
    cargo_home: Option<String>,
    cargo_target_dir: Option<String>,
    rustflags: Option<String>,
    /// Cargo config files that would override the above.
    cargo_config_files: Vec<String>,
    /// Convenience flags for the two wasm targets, since those are the ones
    /// that differ between a nixpkgs and a fenix toolchain.
    has_wasm32_unknown: bool,
    has_wasm32_emscripten: bool,
    /// Whether a browser-UI bundle exists in the tree, and whether anything
    /// here names the bare wasm target. Both come from the action gates, so
    /// the panel and the offers cannot disagree about whether an absent
    /// target is a problem - which they did.
    wasm_bundle_built: bool,
    targets_bare_wasm: bool,
}

fn first_line(cmd: &str, args: &[&str]) -> Option<String> {
    let out = Command::new(cmd).args(args).output().ok()?;
    if !out.status.success() {
        return None;
    }
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .next()
        .map(|s| s.trim().to_string())
}

pub(crate) fn which(bin: &str) -> Option<PathBuf> {
    let path = std::env::var("PATH").ok()?;
    path.split(':')
        .map(|d| Path::new(d).join(bin))
        .find(|p| p.is_file())
}

/// Installed target std libraries, from `<sysroot>/lib/rustlib/`.
///
/// Read from disk rather than `rustc --print target-list`, which lists every
/// target rustc *knows about* - thousands - not the ones it can link.
fn installed_targets() -> (Vec<String>, Option<PathBuf>) {
    let Some(sysroot) = first_line("rustc", &["--print", "sysroot"]).map(PathBuf::from) else {
        return (Vec::new(), None);
    };
    let rustlib = sysroot.join("lib/rustlib");
    let Ok(entries) = std::fs::read_dir(&rustlib) else {
        return (Vec::new(), Some(sysroot));
    };

    let mut targets: Vec<String> = entries
        .filter_map(|e| e.ok())
        .filter(|e| e.path().join("lib").is_dir())
        .filter_map(|e| e.file_name().into_string().ok())
        .collect();
    targets.sort();
    (targets, Some(sysroot))
}

impl Collector for RustCollector {
    fn meta(&self) -> PanelMeta {
        PanelMeta {
            id: "rust",
            title: "Rust",
            description: "Toolchain and the target std libraries it can actually build for",
            interval_secs: 60,
            subject: Subject::Rust,
            info: Info {
                what: "The rustc and cargo on PATH, where they came from, and \
                       which target standard libraries are actually installed.",
                why: "A version number does not tell you what you can build. \
                      nixpkgs' rustc ships std for the host only, so a cross \
                      target fails with \"can't find crate for std\" - and the \
                      fix is invisible from `rustc --version`.",
                if_wrong: "If a target you need is absent, add it with a fenix \
                           toolchain in the dev shell rather than reaching for \
                           rustup, which fights Nix.",
                sections: &[],
            },
            stats: vec![
                StatInfo {
                    key: "rustc",
                    info: Info {
                        what: "`rustc --version`.",
                        why: "Edition and feature availability follow from it.",
                        if_wrong: "A surprising version usually means a dev \
                                   shell is or is not active.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "cargo",
                    info: Info {
                        what: "`cargo --version`.",
                        why: "Normally tracks rustc; a mismatch suggests two \
                              toolchains are mixed on PATH.",
                        if_wrong: "Differing major versions between rustc and \
                                   cargo is worth untangling before trusting \
                                   a build.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "rustc_path",
                    info: Info {
                        what: "The resolved store path of rustc.",
                        why: "This is how you tell a nixpkgs toolchain \
                              (…-rustc-wrapper-…) from a fenix one \
                              (…-rust-mixed…) - otherwise guesswork.",
                        if_wrong: "If you expected fenix and see the nixpkgs \
                                   wrapper, the dev shell is not active.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "host_target",
                    info: Info {
                        what: "The triple rustc builds for by default.",
                        why: "Everything else is a cross compile.",
                        if_wrong: "Rarely wrong; informative when comparing \
                                   against the installed target list.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "targets",
                    info: Info {
                        what: "Target std libraries actually installed, read \
                               from <sysroot>/lib/rustlib.",
                        why: "Read from disk rather than `rustc --print \
                              target-list`, which lists every target rustc \
                              knows about - thousands - not the ones it can \
                              link.",
                        if_wrong: "A short list is normal. The question is \
                                   only whether the target you need is in it.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "lld_available",
                    info: Info {
                        what: "Whether an lld linker is on PATH.",
                        why: "wasm32-unknown-unknown links with lld; without \
                              it the build fails naming the linker, not the \
                              target, which sends you looking in the wrong \
                              place.",
                        if_wrong: "False plus a wasm32-unknown-unknown build \
                                   means adding `lld` to the dev shell - one \
                                   package, not a toolchain change.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "cc_available",
                    info: Info {
                        what: "Whether a C compiler is on PATH as `cc`.",
                        why: "rustc shells out to `cc` for the final link \
                              step of every binary - not just for -sys \
                              crates. Nothing in a plain `rustc` package puts \
                              one there.",
                        if_wrong: "Without it every build fails at link with \
                                   \"linker `cc` not found\", which reads as \
                                   a Rust problem and is not one. Add gcc to \
                                   the same package list as rustc.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "cc_path",
                    info: Info {
                        what: "The resolved path of that C compiler.",
                        why: "Shows which one a build would actually use when \
                              several are in play - a devShell's stdenv \
                              compiler shadows the system one.",
                        if_wrong: "A path outside the store would be \
                                   surprising on NixOS and worth \
                                   investigating.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "pkg_config_available",
                    info: Info {
                        what: "Whether pkg-config is on PATH.",
                        why: "Every `-sys` crate - openssl-sys, libgit2-sys, \
                              alsa-sys - locates its C library through \
                              pkg-config at build time. It is the companion \
                              to the C compiler, not an optional extra.",
                        if_wrong: "Its absence surfaces inside a build script \
                                   as \"could not find system library\", \
                                   naming the library rather than the missing \
                                   tool.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "rust_src_available",
                    info: Info {
                        what: "Whether the standard library SOURCES are \
                               installed - the rust-src component, not the \
                               compiled std.",
                        why: "rust-analyzer resolves std by reading these \
                              sources. Installing `rustc` does not bring \
                              them: on NixOS this is a separate package \
                              (rustPlatform.rustLibSrc, or the rust-src \
                              component of a fenix toolchain).",
                        if_wrong: "Without it rust-analyzer starts, runs, and \
                                   reports every Vec, String and Option as \
                                   unresolved. It reads as a broken LSP \
                                   rather than a missing component, which is \
                                   why it can go unnoticed for a long time.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "rust_src_path",
                    info: Info {
                        what: "Where those sources were found - RUST_SRC_PATH \
                               if set, otherwise under rustc's own sysroot.",
                        why: "rust-analyzer checks RUST_SRC_PATH first. \
                              Setting it is the usual fix when the sources \
                              exist but live somewhere the toolchain does not \
                              point at.",
                        if_wrong: "Null while rust-analyzer is installed is \
                                   the combination worth acting on.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "components_found",
                    info: Info {
                        what: "Toolchain components present on PATH: clippy, \
                               rustfmt, rust-analyzer. Each is detected by \
                               the binary cargo actually invokes, which is \
                               not the component's name - clippy installs \
                               `cargo-clippy` and `clippy-driver`, and no \
                               executable called `clippy` exists at all.",
                        why: "cargo does not vendor these. `cargo clippy` and \
                              `cargo fmt` resolve to separate binaries, which \
                              on NixOS are separate packages.",
                        if_wrong: "A missing one fails only when you invoke \
                                   it, so this can stay broken for weeks \
                                   without a build ever noticing.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "components_missing",
                    info: Info {
                        what: "Which of those are absent.",
                        why: "Listed separately so the gap is the thing you \
                              read, rather than something you infer by \
                              comparing two lists.",
                        if_wrong: "Add them beside rustc in the same package \
                                   list; they are independent packages.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "cargo_home",
                    info: Info {
                        what: "CARGO_HOME, if set - where cargo keeps its \
                               registry cache and credentials.",
                        why: "Normally unset, defaulting to ~/.cargo. A value \
                              here redirects every download and cached crate, \
                              which matters when a build behaves differently \
                              from the same build in another shell.",
                        if_wrong: "Pointing it into the Nix store would make \
                                   cargo try to write to a read-only path.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "cargo_target_dir",
                    info: Info {
                        what: "CARGO_TARGET_DIR, if set - where build \
                               artefacts are written.",
                        why: "Normally unset, meaning ./target per project. \
                              A shared value speeds up rebuilds across \
                              projects but means two projects can invalidate \
                              each other's cache.",
                        if_wrong: "If builds seem to recompile everything for \
                                   no reason, a shared target dir being \
                                   fought over by two toolchains is a common \
                                   cause.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "rustflags",
                    info: Info {
                        what: "RUSTFLAGS, if set - extra flags passed to \
                               every rustc invocation.",
                        why: "Invisible in Cargo.toml and silently \
                              invalidates the build cache when it changes, \
                              because it is part of the fingerprint.",
                        if_wrong: "An unexpected value here explains both \
                                   mysterious full rebuilds and behaviour \
                                   that differs between shells.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "cargo_config_files",
                    info: Info {
                        what: "Cargo config files found that would override \
                               the settings above.",
                        why: "~/.cargo/config.toml can set a linker, a \
                              registry mirror or rustflags for every project \
                              on the machine, from a file no project \
                              contains.",
                        if_wrong: "Empty is the clean case. A file here is \
                                   worth reading before debugging why one \
                                   machine builds differently from another.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "has_wasm32_unknown",
                    info: Info {
                        what: "Whether wasm32-unknown-unknown std is \
                               installed.",
                        why: "The target for browser WebAssembly that does not \
                              need Emscripten - Slint and wasm-bindgen use it.",
                        if_wrong: "Present in nixpkgs' rustc, so absence \
                                   suggests a minimal or custom toolchain.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "wasm_bundle_built",
                    info: Info {
                        what: "Whether a compiled browser-UI bundle exists in \
                               the tree.",
                        why: "It decides whether a missing Emscripten target \
                              is a problem or merely a fact. Nothing builds \
                              for Emscripten outside the wasm dev shell, \
                              which brings its own toolchain - so a bundle \
                              that exists is proof the toolchain that matters \
                              resolves, whatever the default one lacks.",
                        if_wrong: "False on a tree that has never built the \
                                   browser UI, which is when an offer to \
                                   install a toolchain is genuinely useful. \
                                   It is not a fault either way.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "targets_bare_wasm",
                    info: Info {
                        what: "Whether anything here names \
                               wasm32-unknown-unknown - read from flake.nix, \
                               .cargo/config.toml and ui-wasm/build.sh.",
                        why: "That target's std ships with every nixpkgs \
                              rustc, so having it says nothing about intent. \
                              This says whether it is actually built for, and \
                              therefore whether a missing lld matters.",
                        if_wrong: "False here is normal: this project's \
                                   browser UI goes through Emscripten, which \
                                   links with emcc and never calls lld.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "has_wasm32_emscripten",
                    info: Info {
                        what: "Whether wasm32-unknown-emscripten std is \
                               installed.",
                        why: "The target Qt for WebAssembly requires. nixpkgs \
                              does NOT ship it; fenix does.",
                        if_wrong: "False means a Qt-wasm build fails with \
                                   \"can't find crate for std\" before it \
                                   compiles a line of your code.",
                        sections: &[],
                    },
                },
            ],
        }
    }

    fn sample(&self) -> Result<Value> {
        let (targets, _sysroot) = installed_targets();
        let host_target = first_line("rustc", &["-vV"]).and_then(|_| {
            Command::new("rustc")
                .arg("-vV")
                .output()
                .ok()
                .and_then(|o| {
                    String::from_utf8_lossy(&o.stdout)
                        .lines()
                        .find_map(|l| l.strip_prefix("host: ").map(str::to_string))
                })
        });

        // Separate packages on NixOS, every one of them. Adding `rustc` to a
        // package list gets you none of these, and each failure names the
        // missing tool rather than saying the toolchain is incomplete.
        //
        // Each is probed by the binary cargo ACTUALLY invokes, which is not
        // the component's name. There is no executable called `clippy`: the
        // package installs `cargo-clippy` and `clippy-driver`, and
        // `cargo clippy` dispatches to the former. Probing for "clippy"
        // reports it missing on a machine where it is installed and working -
        // a false alarm, which is worse than silence in a monitor.
        const COMPONENTS: &[(&str, &[&str])] = &[
            ("clippy", &["cargo-clippy", "clippy-driver"]),
            ("rustfmt", &["rustfmt", "cargo-fmt"]),
            ("rust-analyzer", &["rust-analyzer"]),
        ];
        let mut components_found = Vec::new();
        let mut components_missing = Vec::new();
        for (name, binaries) in COMPONENTS {
            if binaries.iter().any(|b| which(b).is_some()) {
                components_found.push(name.to_string());
            } else {
                components_missing.push(name.to_string());
            }
        }

        let rust_src_path = rust_src();
        let cc = which("cc");

        let mut cargo_config_files = Vec::new();
        if let Ok(home) = std::env::var("HOME") {
            let p = Path::new(&home).join(".cargo/config.toml");
            if p.exists() {
                cargo_config_files.push(p.display().to_string());
            }
        }

        Ok(serde_json::to_value(RustReading {
            rustc: first_line("rustc", &["--version"]),
            cargo: first_line("cargo", &["--version"]),
            rustc_path: which("rustc")
                .map(|p| std::fs::canonicalize(&p).unwrap_or(p).display().to_string()),
            lld_available: which("lld").is_some() || which("rust-lld").is_some(),
            cc_available: cc.is_some(),
            cc_path: cc.map(|p| p.display().to_string()),
            pkg_config_available: which("pkg-config").is_some(),
            rust_src_available: rust_src_path.is_some(),
            rust_src_path,
            components_found,
            components_missing,
            cargo_home: std::env::var("CARGO_HOME").ok(),
            cargo_target_dir: std::env::var("CARGO_TARGET_DIR").ok(),
            rustflags: std::env::var("RUSTFLAGS").ok(),
            cargo_config_files,
            has_wasm32_unknown: targets.iter().any(|t| t == "wasm32-unknown-unknown"),
            has_wasm32_emscripten: targets.iter().any(|t| t == "wasm32-unknown-emscripten"),
            wasm_bundle_built: crate::actions::rust::wasm_bundle_built(),
            targets_bare_wasm: crate::actions::rust::project_targets_bare_wasm(),
            host_target,
            targets,
        })?)
    }

    fn status(&self, v: &Value) -> (Status, String) {
        let Some(rustc) = v["rustc"].as_str() else {
            // Says *rustc*, not "no Rust", for the same reason the Qt panel
            // says qmake: this measures whether you could BUILD here. The
            // engine reporting it is itself a compiled Rust program, so "no
            // Rust in this environment" would be self-evidently false.
            return (
                Status::Unknown,
                "no rustc on PATH - cannot tell whether a Rust build would work".into(),
            );
        };
        let ver = rustc.split_whitespace().nth(1).unwrap_or(rustc);
        let em = v["has_wasm32_emscripten"].as_bool().unwrap_or(false);
        let wasm = v["has_wasm32_unknown"].as_bool().unwrap_or(false);
        let lld = v["lld_available"].as_bool().unwrap_or(false);
        let cc = v["cc_available"].as_bool().unwrap_or(false);
        let rust_src = v["rust_src_available"].as_bool().unwrap_or(false);
        let has_ra = v["components_found"]
            .as_array()
            .is_some_and(|a| a.iter().any(|c| c.as_str() == Some("rust-analyzer")));

        // No C compiler outranks everything else here. Without `cc` nothing
        // links at all - not a cross build, not a hello world - so leading
        // with a wasm target would be reporting the second problem.
        if !cc {
            return (
                Status::Bad,
                format!("{ver} · no C compiler - every link will fail"),
            );
        }

        // rust-analyzer installed but unable to resolve std. Worth saying out
        // loud because nothing else ever reports it: the editor starts, runs,
        // and silently marks every std type unresolved.
        if has_ra && !rust_src {
            return (
                Status::Warn,
                format!("{ver} · rust-analyzer cannot resolve std (no rust-src)"),
            );
        }

        // A toolchain lacking a target is not broken - it is simply not the
        // one for that target, so Warn rather than Bad. wasm32-unknown-unknown
        // without lld IS broken: it will fail at link, naming the linker.
        // Two different reasons, the same verdict - so they collapse into one
        // condition rather than two arms that look like a copy-paste slip.
        //
        //   wasm && !lld   the target is installed but cannot link
        //   !em && !wasm   neither wasm target is present at all
        //
        // Warn in both cases: a toolchain missing a target is not broken, it
        // is simply not the toolchain for that target.
        let cannot_build_wasm = (wasm && !lld) || (!em && !wasm);
        let status = if cannot_build_wasm {
            Status::Warn
        } else {
            Status::Ok
        };

        let head = if em {
            format!("{ver} · emscripten target")
        } else {
            format!("{ver} · no emscripten target")
        };
        (status, head)
    }
}

#[cfg(test)]
mod tests {
    /// A component must never be reported missing while the thing it provides
    /// works.
    ///
    /// This shipped briefly as a false positive: the probe looked for a binary
    /// called `clippy`, which does not exist on any machine. The package
    /// installs `cargo-clippy` and `clippy-driver`, so a working installation
    /// was reported as missing - and a monitor raising an alarm about a
    /// healthy system is worse than one that says nothing.
    #[test]
    fn components_are_probed_by_the_binary_cargo_invokes() {
        let v = super::RustCollector.sample().unwrap();
        let missing: Vec<String> = v["components_missing"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c.as_str().unwrap_or_default().to_string())
            .collect();

        // If cargo-clippy is on PATH, clippy is installed - whatever the
        // component is called.
        if super::which("cargo-clippy").is_some() {
            assert!(
                !missing.iter().any(|m| m == "clippy"),
                "clippy reported missing while cargo-clippy is on PATH: {missing:?}"
            );
        }
        if super::which("rustfmt").is_some() {
            assert!(!missing.iter().any(|m| m == "rustfmt"), "{missing:?}");
        }
    }

    use super::*;

    #[test]
    fn reports_absence_without_failing() {
        // No Rust is a legitimate state; the panel says so rather than erroring.
        let v = RustCollector.sample().expect("absence is not an error");
        assert!(v["targets"].is_array());
        assert!(v["lld_available"].as_bool().is_some());
    }

    #[test]
    fn target_flags_agree_with_the_list() {
        let v = RustCollector.sample().unwrap();
        let targets: Vec<&str> = v["targets"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t.as_str().unwrap())
            .collect();
        assert_eq!(
            v["has_wasm32_emscripten"].as_bool().unwrap(),
            targets.contains(&"wasm32-unknown-emscripten")
        );
    }

    #[test]
    fn lists_only_targets_with_a_lib_dir() {
        // `rustc --print target-list` would give thousands; this must reflect
        // what is installed, which is a far shorter list.
        let (targets, _) = installed_targets();
        assert!(
            targets.len() < 50,
            "got {} targets - reading the wrong thing",
            targets.len()
        );
    }
}
