//! Starting the engine as a child process, for the packaged builds.
//!
//! Under home-manager the engine is a systemd **user service**: the unit in
//! `nix/hm-module.nix` owns its lifetime, and the UI only ever talks HTTP to
//! 127.0.0.1:3100. This module does nothing there, and must not - two engines
//! on one port means the second fails to bind.
//!
//! The .deb and .rpm need it. They *do* ship a systemd user unit, but neither
//! Debian nor Fedora enables a user unit on install, so a fresh install would
//! otherwise put a menu entry on screen that opens a window reaching nothing.
//! The desktop entry passes the flag, and the port check below means enabling
//! the unit later costs nothing: the UI finds the engine already listening and
//! attaches instead of starting a second one.
//!
//! Opt-in by `--spawn-engine` on argv, and only there.
//!
//! Deliberately not keyed off "is there an engine binary next to me", which
//! reads as the more elegant signal and is wrong: under `cargo build` both
//! binaries land in `target/debug`, so every dev run of the UI would start an
//! engine behind the developer's back.

use std::net::{Ipv4Addr, SocketAddrV4, TcpStream};
use std::process::{Child, Command};
use std::time::{Duration, Instant};

/// How long to wait for a spawned engine to accept a connection.
///
/// The window polls the API every two seconds and draws its own error state
/// until one answers, so overshooting this costs nothing but a first frame of
/// red panels. Five seconds is a debug-build engine starting on a cold page
/// cache, measured; a release build is well under one.
const READY_TIMEOUT: Duration = Duration::from_secs(5);

/// A child engine, killed when this is dropped.
///
/// Drop is the whole point: without it, closing the window leaves an engine
/// holding 3100, and the next launch attaches to an orphan it cannot stop.
/// It does not cover the UI being killed by a signal — nothing in-process
/// can — which is why the port check in [`start`] treats an already-bound
/// port as a normal case rather than an error.
pub struct EngineGuard(Option<Child>);

impl Drop for EngineGuard {
    fn drop(&mut self) {
        let Some(child) = self.0.as_mut() else {
            return;
        };
        // kill() then wait(): kill alone leaves a zombie, and this process is
        // about to exit anyway so the wait cannot hang for long.
        let _ = child.kill();
        let _ = child.wait();
    }
}

/// Is something already listening on the engine's port?
fn port_in_use(port: u16) -> bool {
    // A successful connect is the only reliable answer. Binding to test would
    // race the engine we are about to start.
    TcpStream::connect_timeout(
        &SocketAddrV4::new(Ipv4Addr::LOCALHOST, port).into(),
        Duration::from_millis(200),
    )
    .is_ok()
}

/// Start the engine next to this executable, unless one is already running.
///
/// Returns `None` when nothing was spawned — flag absent, an engine already
/// has the port, or the binary is missing. Every one of those is reported on
/// stderr: a UI that silently failed to start its own engine and then drew
/// "could not reach the engine" would be describing a symptom and hiding the
/// cause.
pub fn start() -> Option<EngineGuard> {
    if !std::env::args().any(|a| a == "--spawn-engine") {
        return None;
    }

    let port = std::env::var("NIXDASH_PORT")
        .ok()
        .and_then(|p| p.parse::<u16>().ok())
        .unwrap_or(3100);

    // Attaching to an engine someone else started is correct, not a
    // fallback: someone who installs the .deb and then enables the user unit
    // should get one engine and a working window, not a bind error.
    if port_in_use(port) {
        eprintln!("nixdash-ui: an engine already holds 127.0.0.1:{port}; attaching to it");
        return None;
    }

    // Beside this executable, which is what both packages lay down: /usr/bin
    // for the .deb and .rpm.
    let exe = std::env::current_exe().ok()?;
    let bin = exe.parent()?.join("nixdash-engine");
    if !bin.is_file() {
        eprintln!(
            "nixdash-ui: --spawn-engine, but no engine at {}",
            bin.display()
        );
        return None;
    }

    let child = match Command::new(&bin).spawn() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("nixdash-ui: could not start {}: {e}", bin.display());
            return None;
        }
    };
    let guard = EngineGuard(Some(child));

    // Wait for the port rather than a fixed sleep, so a fast engine costs one
    // poll interval and a slow one is still caught.
    let deadline = Instant::now() + READY_TIMEOUT;
    while Instant::now() < deadline {
        if port_in_use(port) {
            return Some(guard);
        }
        std::thread::sleep(Duration::from_millis(50));
    }

    // Timed out. Keep the guard: the engine may yet come up, and dropping it
    // here would kill a process that is merely slow. The window's own error
    // state covers the interim, and this line says why it is there.
    eprintln!(
        "nixdash-ui: engine did not accept a connection on {port} within {}s; \
         the window will keep retrying",
        READY_TIMEOUT.as_secs()
    );
    Some(guard)
}
