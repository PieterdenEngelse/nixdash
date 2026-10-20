//! nixdash desktop UI - Qt/QML with a Rust-defined QObject.

pub mod cxxqt_object;

use cxx_qt_lib::{QGuiApplication, QQmlApplicationEngine, QQuickStyle, QString, QUrl};

/// Where `Main.qml` is read from.
///
/// Normally the Qt resource system, compiled in by `build.rs` - which is why
/// a QML edit needs a rebuild and a reopen, as the Dev page says.
///
/// With `NIXDASH_QML_DIR` set, it is read from that directory instead, and
/// then a QML edit needs neither: relaunching the same binary picks up the
/// new file. `just watch` is that loop. The binary is unchanged, so this is
/// not a second build - it is the same build reading its QML from somewhere
/// else.
///
/// `Main.qml` carries `import nixdash`, which is what makes this work: the
/// Rust-defined `Dash` type is registered by cxx-qt at startup rather than
/// living in the resource bundle, so it resolves for a file:// document too.
/// Sibling components resolve twice over - the directory is imported
/// implicitly, and they are module types as well.
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

    let mut app = QGuiApplication::new();
    let mut engine = QQmlApplicationEngine::new();

    if let Some(engine) = engine.as_mut() {
        engine.load(&QUrl::from(qml_url().as_str()));
    }

    if let Some(app) = app.as_mut() {
        app.exec();
    }
}
