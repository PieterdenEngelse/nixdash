/// The Rust side of the UI.
///
/// Deliberately thin: the engine is authoritative and the QML talks to it over
/// HTTP, so this exists to supply what QML cannot work out for itself - where
/// the engine is listening. Keeping data access in QML is what lets the same
/// QML build unchanged for WebAssembly in phase 3.
#[cxx_qt::bridge]
pub mod qobject {
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        /// An alias to the QString type
        type QString = cxx_qt_lib::QString;
    }

    // cxx-qt >=0.7 does NOT case-convert automatically: a Rust `api_base`
    // stays `api_base` in QML unless told otherwise, and `dash.apiBase` then
    // silently reads as undefined. #[auto_cxx_name] applies camelCase to the
    // whole block, so Rust stays snake_case and QML gets what it expects
    // without per-item annotations as this grows.
    #[auto_cxx_name]
    extern "RustQt" {
        /// Application-level state exposed to QML.
        #[qobject]
        #[qml_element]
        #[qproperty(QString, api_base)]
        #[qproperty(QString, version)]
        #[qproperty(QString, built)]
        /// Whether `built` is the link time or the build-script stamp. The
        /// header labels itself from this, because the two are different
        /// claims and only one of them is "when it was built".
        #[qproperty(bool, built_exact)]
        /// Which of the two programs this is. The browser half has no
        /// filesystem to read its own mtime from and has to ask the server
        /// instead, so QML needs to know which it is talking to.
        #[qproperty(bool, browser)]
        type Dash = super::DashRust;
    }
}

use cxx_qt_lib::QString;

pub struct DashRust {
    api_base: QString,
    version: QString,
    built: QString,
    built_exact: bool,
    browser: bool,
}

// The formatter the build script uses, so a time computed here is printed
// the same way as one baked in. Shared file, not a second copy.
include!("../build_date.rs");

/// When this binary was LINKED, from its own mtime.
///
/// Always `None` in the browser build. This file is ONE file - the wasm
/// crate reaches it through a symlink - so the halves differ by cfg rather
/// than by having two copies to keep in step. A wasm build has no
/// filesystem and no binary to stat; the page asks the server for its
/// bundle's Last-Modified instead, which is the only place that time
/// exists.
///
/// `None` when that cannot mean anything. A store path's mtime is pinned to
/// the epoch by design, so an installed build has no link time to read and
/// the compiled-in stamp is the best there is - which is why this returns an
/// option rather than a number with a special value in it.
#[cfg(target_arch = "wasm32")]
fn exe_built_at() -> Option<i64> {
    None
}

#[cfg(not(target_arch = "wasm32"))]
fn exe_built_at() -> Option<i64> {
    let exe = std::env::current_exe().ok()?;
    let secs = std::fs::metadata(&exe)
        .ok()?
        .modified()
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs() as i64;
    // Anything at or before the build script's own run is either the epoch
    // of a store path or a clock that cannot be trusted to order the two.
    // Either way it is not a link time.
    if secs > BUILT_AT {
        Some(secs)
    } else {
        None
    }
}

/// What the header shows: the link time when there is one, else the stamp.
fn built_stamp() -> String {
    match exe_built_at() {
        Some(secs) => build_stamp(secs),
        None => env!("NIXDASH_BUILT").to_string(),
    }
}

const BUILT_AT: i64 = {
    // env! gives a &str; this is the parse, at compile time.
    let bytes = env!("NIXDASH_BUILT_AT").as_bytes();
    let mut acc: i64 = 0;
    let mut i = 0;
    while i < bytes.len() {
        acc = acc * 10 + (bytes[i] - b'0') as i64;
        i += 1;
    }
    acc
};

impl Default for DashRust {
    /// NIXDASH_PORT is read here rather than hardcoded in QML so the desktop
    /// UI follows the engine when it is moved off the default port. Loopback
    /// is not configurable - the engine only ever binds 127.0.0.1.
    ///
    /// The version and build date join it for the same reason: QML cannot
    /// work either out for itself.
    fn default() -> Self {
        let port = std::env::var("NIXDASH_PORT")
            .ok()
            .and_then(|p| p.parse::<u16>().ok())
            .unwrap_or(3100);
        Self {
            api_base: QString::from(&format!("http://127.0.0.1:{port}")),
            // Both are compile-time constants, which is the point: they
            // describe the binary you are looking at, so neither can be
            // fetched from the engine - that is a different build with its
            // own version, and asking it would answer the wrong question.
            version: QString::from(env!("CARGO_PKG_VERSION")),
            built: QString::from(&built_stamp()),
            built_exact: exe_built_at().is_some(),
            browser: cfg!(target_arch = "wasm32"),
        }
    }
}
