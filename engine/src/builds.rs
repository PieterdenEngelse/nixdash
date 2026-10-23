//! The Dev page's build lines, as a fixed set of runnable things.
//!
//! Separate from `actions` on purpose, and the reason is `Action::why`: an
//! action states why it is being offered *right now*, and one with no honest
//! answer there should not exist. "You could rebuild the window" is not an
//! answer to why now - it is true every minute of every day. So these are not
//! actions, and the advisory list stays a list of things that need doing.
//!
//! The mechanical consequence matters more. Actions are derived from live
//! state, so `POST /api/actions/{id}/run` legitimately 404s once the condition
//! clears - the unit recovered, the rebuild already happened. The Dev page's
//! "Commands" board is static reference text that is always on screen, so
//! a Run button there wired to an action would fail whenever the system was
//! healthy, which is most of the time and exactly when you are most likely to
//! be building something.
//!
//! What is preserved from the actions API is the part that matters for safety:
//! the caller names an entry from this compile-time list and never a command,
//! so the executable set is fixed when the engine is built. Nothing here is
//! assembled from a request body or from the text the page displays.

use std::{
    io::{Read, Write},
    net::{SocketAddr, TcpStream},
    path::PathBuf,
    time::Duration,
};

use serde::Serialize;

use crate::actions::RunCommand;

/// Where the repository is, for the entries that build it.
///
/// `cwd` is not optional for these: the service's own working directory is not
/// a meaningful place to run `cargo`, and a build that silently ran in the
/// wrong tree would be worse than one that failed to start.
/// Where a build's live output is written while it runs.
///
/// One file per build id, in the runtime directory rather than the repo:
/// it is the current run's scratch, not something to keep, and it must not
/// turn up in `git status` after pressing a button.
pub fn log_path(id: &str) -> PathBuf {
    let base = std::env::var("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| std::env::temp_dir());
    base.join(format!("nixdash-build-{id}.log"))
}

pub(crate) fn repo() -> PathBuf {
    match std::env::var("NIXDASH_REPO") {
        Ok(p) => PathBuf::from(p),
        Err(_) => match std::env::var("HOME") {
            Ok(h) => PathBuf::from(h).join("Projects/nixdash"),
            Err(_) => PathBuf::from("/"),
        },
    }
}

/// The port a second, hand-started engine listens on.
///
/// Never 3100. Taking the service's port blanks the window you are looking at,
/// and a dev engine left holding it makes the service crash-loop invisibly
/// behind it while `/health` keeps answering - from the squatter.
pub const DEV_PORT: u16 = 3199;

/// How a build line is executed.
pub enum Execution {
    /// Run it, wait for it, report how it went.
    Wait(RunCommand),
    /// Start it and leave it running, because it is a server and exiting would
    /// be the failure. Reported on by probing the port, never by waiting.
    Daemon(RunCommand),
    /// Start a window and let go. Like Daemon in that waiting would hold the
    /// request for as long as the thing lives, but there is no port to probe:
    /// a window either appears on the screen in front of you or it does not,
    /// and that is a reading only you can take. So this reports the pid and
    /// the log, and claims nothing about what is drawn.
    Detach(RunCommand),
    /// Start a window, then close the ones that were already open.
    ///
    /// That ORDER is the whole of it. Closing first and starting second
    /// leaves you with no window at all when the start fails, and no window
    /// is also where the error message would have been. Starting first costs
    /// a moment with two windows open and cannot strand you.
    Replace(RunCommand),
}

pub struct Build {
    pub id: &'static str,
    /// Matches the row's label on the Dev page, so the two are traceably the
    /// same thing.
    pub label: &'static str,
    pub execution: Execution,
}

/// Everything the Dev page can run, keyed by the id its rows carry.
///
/// Four of the five wait. The fifth is a server.
pub fn all() -> Vec<Build> {
    let dir = repo().display().to_string();
    vec![
        // The displayed line ends by launching the window. Only the build is
        // run - the same split `rebuild-wasm-ui` makes for `serve.sh`, and for
        // the same reason: a launch would hold this request until the window
        // was closed, and a window is the user's to open.
        // Both UIs, in one press. `just both`, not the two command lines:
        // the recipe is the one definition of what "both" means, and a copy
        // here would be a second one to keep in step.
        Build {
            id: "both-uis",
            label: "both UIs",
            execution: Execution::Wait(RunCommand {
                program: "nix".into(),
                args: vec![
                    "develop".into(),
                    "--command".into(),
                    "just".into(),
                    "both".into(),
                ],
                elevate: false,
                cwd: Some(dir.clone()),
            }),
        },
        Build {
            id: "desktop-ui",
            label: "this window",
            execution: Execution::Wait(RunCommand {
                program: "nix".into(),
                args: vec![
                    "develop".into(),
                    "--command".into(),
                    "cargo".into(),
                    "build".into(),
                    "-p".into(),
                    "nixdash-ui".into(),
                ],
                elevate: false,
                cwd: Some(dir.clone()),
            }),
        },
        // Identical argv to the `rebuild-wasm-ui` action, deliberately not a
        // call into it: that action exists only while the bundle is stale, and
        // this row is on screen always.
        Build {
            id: "browser-ui",
            label: "browser UI",
            execution: Execution::Wait(RunCommand {
                program: "nix".into(),
                args: vec![
                    "develop".into(),
                    ".#wasm".into(),
                    "--command".into(),
                    "bash".into(),
                    "ui-wasm/build.sh".into(),
                ],
                elevate: false,
                cwd: Some(dir.clone()),
            }),
        },
        // The one server. `cargo build` first would make this a build AND a
        // launch, and then a failed build would look like a failed start, so
        // the binary is run as it stands and a missing one is reported as
        // such.
        Build {
            id: "dev-engine",
            label: "a second engine",
            execution: Execution::Daemon(RunCommand {
                program: "./target/debug/nixdash-engine".into(),
                args: vec![],
                elevate: false,
                cwd: Some(dir.clone()),
            }),
        },
        // The window, opened without building anything. No probe: Qt may
        // still be deciding whether it can draw long after the fork
        // succeeded, so "it started" is all this can honestly report.
        Build {
            id: "open-window",
            label: "run, no build",
            execution: Execution::Detach(RunCommand {
                program: "./target/debug/nixdash-ui".into(),
                args: vec![],
                elevate: false,
                cwd: Some(dir.clone()),
            }),
        },
        Build {
            id: "restart-window",
            label: "fresh window",
            execution: Execution::Replace(RunCommand {
                program: "./target/debug/nixdash-ui".into(),
                args: vec![],
                elevate: false,
                cwd: Some(dir.clone()),
            }),
        },
        Build {
            id: "install-user",
            label: "install, user",
            // `just deploy`, not `home-manager switch`, because a switch on
            // its own finishes none of what it starts: the old service keeps
            // serving until restarted, and the panel keeps its own copy of
            // the launcher. The recipe is the one definition of those four
            // steps - running the first of them here and leaving the rest to
            // a provenance line is how three of them came to be documented in
            // three places and run in none.
            //
            // The repo, not HOME: `just` is found by its Justfile. The switch
            // itself does not care - there is no flake in
            // ~/.config/home-manager, so its config is read from a fixed path
            // either way.
            execution: Execution::Wait(RunCommand {
                program: "nix".into(),
                args: vec![
                    "develop".into(),
                    "--command".into(),
                    "just".into(),
                    "deploy".into(),
                ],
                elevate: false,
                cwd: Some(dir.clone()),
            }),
        },
        // Root, so pkexec and a polkit prompt. The displayed line says `sudo`
        // because that is what you would type; sudo itself is never used here
        // - it wants a terminal the service does not have.
        Build {
            id: "install-system",
            label: "install, system",
            execution: Execution::Wait(RunCommand {
                program: "nixos-rebuild".into(),
                args: vec!["switch".into()],
                elevate: true,
                cwd: None,
            }),
        },
    ]
}

pub fn find(id: &str) -> Option<Build> {
    all().into_iter().find(|b| b.id == id)
}

/// What a probe of the dev engine's port found.
///
/// Three answers, not two, and the middle one is the whole reason this is a
/// probe rather than a return code. Starting a process tells you a fork
/// succeeded; it does not tell you the port was free.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(tag = "state", rename_all = "kebab-case")]
pub enum DevEngine {
    /// Nothing is listening.
    Stopped,
    /// Something answered. `built` is its compile-time stamp, which is the
    /// only thing that distinguishes one build from another - the version
    /// number is identical in every build ever made.
    Running {
        built: String,
        version: String,
        /// Whether this engine started it. False after the service restarts,
        /// or when the port was already occupied - and then we cannot stop
        /// what we did not start.
        ours: bool,
    },
    /// The port answered but not with an engine, so something unrelated holds
    /// it. Reported rather than smoothed over: a start that lands here has
    /// failed, however healthy the reply looked.
    Foreign { detail: String },
}

/// Ask the dev port what is there.
///
/// A hand-rolled HTTP/1.1 request over a socket rather than an HTTP client
/// crate. The engine has no client dependency and this is not worth acquiring
/// one for: a loopback GET of a single small JSON object, with no TLS, no
/// redirects and no retries. `Connection: close` makes the server end the
/// stream, so reading to EOF is the whole response.
///
/// Short timeouts throughout: this talks to a process that either answers
/// immediately or is not running, and a generous timeout would make a stopped
/// engine look like a slow one.
pub fn probe(ours: bool) -> DevEngine {
    let addr = SocketAddr::from(([127, 0, 0, 1], DEV_PORT));
    let mut stream = match TcpStream::connect_timeout(&addr, Duration::from_millis(300)) {
        Ok(s) => s,
        // Refused is the ordinary case, not an error worth reporting: it is
        // what "not running" looks like.
        Err(_) => return DevEngine::Stopped,
    };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(300)));

    let req =
        format!("GET /health HTTP/1.1\r\nHost: 127.0.0.1:{DEV_PORT}\r\nConnection: close\r\n\r\n");
    if let Err(e) = stream.write_all(req.as_bytes()) {
        return DevEngine::Foreign {
            detail: format!("accepted a connection then refused the request: {e}"),
        };
    }

    let mut raw = String::new();
    if let Err(e) = stream.read_to_string(&mut raw) {
        return DevEngine::Foreign {
            detail: format!("answered but could not be read: {e}"),
        };
    }

    // Something listening that is not an HTTP server, or an HTTP server that
    // does not have /health, is a foreign occupant - which is the answer that
    // matters, so it is never folded into Stopped.
    let Some((head, body)) = raw.split_once("\r\n\r\n") else {
        return DevEngine::Foreign {
            detail: "replied with something that is not an HTTP response".into(),
        };
    };
    if !head.starts_with("HTTP/1.1 200") && !head.starts_with("HTTP/1.0 200") {
        let status = head
            .lines()
            .next()
            .unwrap_or("(no status line)")
            .to_string();
        return DevEngine::Foreign {
            detail: format!("something is listening on {DEV_PORT} and answered: {status}"),
        };
    }

    match serde_json::from_str::<serde_json::Value>(body.trim()) {
        Ok(v) if v.get("status").and_then(|s| s.as_str()) == Some("ok") => DevEngine::Running {
            built: v
                .get("built")
                .and_then(|s| s.as_str())
                .unwrap_or("unknown")
                .to_string(),
            version: v
                .get("version")
                .and_then(|s| s.as_str())
                .unwrap_or("unknown")
                .to_string(),
            ours,
        },
        _ => DevEngine::Foreign {
            detail: format!("something is listening on {DEV_PORT} and it is not this app's engine"),
        },
    }
}

/// Pids of every window this app can account for.
///
/// By resolving /proc/<pid>/exe rather than by name: the installed binary
/// runs as `.nixdash-ui-wrapped`, and `comm` is truncated to fifteen
/// characters, so neither is a reliable match.
///
/// " (deleted)" is stripped because the kernel appends it once the binary has
/// been replaced underneath a running process - which is the commonest window
/// to want closed, since it is the one showing a build that no longer exists.
pub fn window_pids() -> Vec<u32> {
    let mut found = Vec::new();
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return found;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(pid) = name.to_str().and_then(|n| n.parse::<u32>().ok()) else {
            continue;
        };
        let Ok(exe) = std::fs::read_link(format!("/proc/{pid}/exe")) else {
            continue;
        };
        // A zombie keeps its /proc entry and its exe link, so without this
        // a reaped-but-not-yet-collected process counts as a window: the
        // replace path reported closing two of those while the new window
        // had never started.
        if process_state(pid) == Some('Z') {
            continue;
        }
        let exe = exe.to_string_lossy();
        let exe = exe.strip_suffix(" (deleted)").unwrap_or(&exe);
        if exe.ends_with("/target/debug/nixdash-ui")
            || exe.ends_with("/bin/.nixdash-ui-wrapped")
            || exe.ends_with("/bin/nixdash-ui")
        {
            found.push(pid);
        }
    }
    found
}

/// The single-letter state from /proc/<pid>/stat, or None.
///
/// Parsed from after the LAST ')': the second field is the executable name in
/// parentheses and may itself contain parentheses or spaces, so splitting on
/// whitespace from the left is wrong on exactly the processes worth getting
/// right.
fn process_state(pid: u32) -> Option<char> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let tail = &stat[stat.rfind(')')? + 1..];
    tail.split_whitespace().next()?.chars().next()
}

/// Send TERM and report only the ones that actually went.
///
/// `kill` succeeding is not a window closing - it returns 0 for a zombie,
/// and a count built on that claimed two closures that never happened.
pub fn close_windows(pids: &[u32]) -> usize {
    for pid in pids {
        let _ = crate::actions::runner::stop(*pid);
    }
    let deadline = std::time::Instant::now() + Duration::from_millis(1500);
    loop {
        let left: Vec<u32> = pids
            .iter()
            .copied()
            .filter(|p| {
                std::path::Path::new(&format!("/proc/{p}")).exists()
                    && process_state(*p) != Some('Z')
            })
            .collect();
        if left.is_empty() || std::time::Instant::now() > deadline {
            return pids.len() - left.len();
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}
