//! nixdash desktop UI - Qt/QML with a Rust-defined QObject.

pub mod cxxqt_object;
pub mod engine_proc;

use cxx_qt_lib::{QGuiApplication, QQmlApplicationEngine, QQuickStyle, QString, QUrl};

/// Where `Main.qml` is read from.
///
/// Normally the Qt resource system, compiled in by `build.rs` - which is why
/// a QML edit needs a rebuild and a reopen, as the Dev page says.
///
/// With `NIXDASH_QML_DIR` set, **`Main.qml` alone** is read from that
/// directory instead. An edit to that one file then needs no rebuild:
/// relaunching the same binary picks it up.
///
/// It does NOT extend to the other components, and this is the trap. Qt gives
/// an explicit module import precedence over the implicit same-directory one,
/// and `Main.qml` carries `import nixdash` - so `DevPage`, `ConfigSection`
/// and every other sibling resolve to the **compiled-in** module types, not
/// to the files next to the `Main.qml` that was just loaded. Editing one of
/// them and relaunching shows you the previous build with no error of any
/// kind, which is indistinguishable from an edit that did nothing.
///
/// Verified twice over, because the mechanism is not guessable from the code:
/// a marker string planted in three files showed up only for `Main.qml`, and
/// separately, `ConfigSection.qml` made syntactically invalid in the override
/// directory did not stop the app starting - it was never parsed.
///
/// One exception, and it is the useful one: a **new** `.qml` not in the
/// bundle DOES load from the directory, because the module has no name there
/// to shadow. CLAUDE.md tabulates all three cases.
///
/// So `import nixdash` is what makes the file:// document work at all - the
/// Rust-defined `Dash` type is registered by cxx-qt at startup rather than
/// living in the bundle - and is also why the override stops at one file.
/// An earlier version of this comment said siblings "resolve twice over",
/// which is true and useless: it does not say which resolution wins.
///
/// A component edit needs `cargo build -p nixdash-ui` - 2m 15s, measured.
/// `just watch-desktop` runs that build on every change for this reason.
///
/// Not in-process reload: `cxx-qt-lib` 0.10 exposes `load` and `loadData` and
/// no `clearComponentCache`, so re-reading QML inside a running engine would
/// need a C++ shim. Relaunching is a hundred milliseconds and cannot leave a
/// half-reloaded object tree behind.
fn qml_url() -> String {
    const BUNDLED: &str = "qrc:/qt/qml/nixdash/qml/Main.qml";

    let Ok(dir) = std::env::var("NIXDASH_QML_DIR") else {
        return BUNDLED.to_string();
    };
    if dir.is_empty() {
        return BUNDLED.to_string();
    }

    // Absolute, because file:// has no notion of the working directory. A
    // path that cannot be resolved is reported rather than silently falling
    // back to the bundle: asking for the directory and quietly getting the
    // compiled copy is the confusing outcome, not the error.
    let path = match std::fs::canonicalize(&dir) {
        Ok(p) => p.join("Main.qml"),
        Err(e) => {
            eprintln!("nixdash-ui: NIXDASH_QML_DIR={dir} cannot be resolved: {e}");
            std::process::exit(2);
        }
    };
    if !path.is_file() {
        eprintln!("nixdash-ui: no Main.qml in {}", path.display());
        std::process::exit(2);
    }

    eprintln!(
        "nixdash-ui: reading QML from {} (NIXDASH_QML_DIR)",
        path.display()
    );
    format!("file://{}", path.display())
}

fn main() {
    // Fusion, before anything imports Qt Quick Controls - the style cannot be
    // changed once the QML types are registered.
    //
    // Fusion is the one built-in style that takes its colours from the
    // palette, so the dark palette set on the window in Main.qml reaches
    // every button, switch and combo box. Basic hardcodes most of its own
    // colours, which would leave light controls sitting in dark panels.
    QQuickStyle::set_style(&QString::from("Fusion"));

    // Held for the whole run, because dropping it kills the engine it
    // started. `--spawn-engine` is passed by the packages' desktop entry and
    // Start Menu shortcut; without it this is None and nothing starts, which
    // is what keeps the systemd-user-service path untouched. Qt leaves argv
    // it does not recognise alone, so the flag reaching QGuiApplication below
    // is harmless.
    let _engine = engine_proc::start();

    let mut app = QGuiApplication::new();
    let mut engine = QQmlApplicationEngine::new();

    if let Some(engine) = engine.as_mut() {
        engine.load(&QUrl::from(qml_url().as_str()));
    }

    if let Some(app) = app.as_mut() {
        app.exec();
    }
}
