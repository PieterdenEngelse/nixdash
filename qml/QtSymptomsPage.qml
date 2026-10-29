import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// What you saw, and which page explains it.
//
// Phase 5 of ~/docs/qt-dev-2.md, and the one that could only be written
// once the others existed to point at. Every other page here is organised
// by cause, because that is how the material makes sense once you
// understand it. Nobody arrives understanding it. They arrive with a line
// of output.
//
// So this page is indexed the other way round: symptom first, in the words
// the tool actually used, grouped by WHEN you see it rather than by what is
// wrong. The cause is one line and the link goes to the page that argues it
// properly.
//
// Rows link by emitting openTopic with a topic id; Main.qml turns that into
// navigation. ConfigSection knows nothing about destinations - it hands the
// href straight back out - so what a link MEANS stays here.
//
// Every row has a destination. One did not when this was written -
// `qResourceFeatureZstd`, which no page covered - and writing the index is
// what found that. Phase 6 gave it blocker D on the wasm page.
//
// Labels are the distinctive TOKEN of the error, not the whole line, and
// that is a layout constraint as much as a reading one. ConfigSection sizes
// its label column to the longest label plus two, in monospace characters -
// so a 48-character label like "Qt module mismatch between cxx-qt-build and
// CMake" produced a 50-character column, and at the window's restore width
// of 820 the label and value columns wrapped into each other. Seen on
// Xvfb; it reads fine maximised, which is how it got written. It also reads
// better this way: you scan for the fragment you can see in your own error.
Item {
    id: root

    Style { id: style }

    property var panels: []
    property string apiBase: ""

    /// A topic id from Main.qml's qtTopics; "" is the Qt overview.
    signal openTopic(string id)

    /// Rows link with "overview", not with the overview's real id.
    ///
    /// Its id is the empty string, and an empty string is not a usable
    /// href - `<a href=''>` is not reliably a link at all, so those rows
    /// would simply render as dead text. The rows carry a sentinel and it
    /// is translated here, which keeps the destinations on this page.
    function topicFor(linkId) {
        return linkId === "overview" ? "" : linkId
    }

    function panel(id) {
        var m = panels.filter(function(p) { return p.id === id })
        return m.length > 0 ? m[0] : null
    }

    function val(id, key) {
        var p = panel(id)
        if (!p || !p.latest || p.latest.value[key] === undefined || p.latest.value[key] === null)
            return "—"
        var v = p.latest.value[key]
        if (Array.isArray(v)) return v.length === 0 ? "none" : v.join(", ")
        if (typeof v === "boolean") return v ? "yes" : "no"
        return String(v)
    }

    ScrollView {
        anchors.fill: parent
        anchors.margins: 14
        contentWidth: availableWidth
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        Column {
            width: parent.width
            spacing: 14

            SelectableText {
                text: "When it breaks"
                font.bold: true
                font.pixelSize: 18
            }

            SelectableText {
                width: parent.width
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.RichText
                font.pixelSize: style.fontBody
                text: "The other pages here are arranged by cause, which is \
how this material makes sense <i>after</i> you understand it. You are \
probably not reading this after. <b>Start from the line you got.</b><br><br>\
Grouped by when it appears, because that narrows it faster than anything \
else: almost nothing on this page can happen at two different stages, and \
the two that can are marked. Each row names its cause in one line and links \
to the page that argues it."
            }

            ConfigSection {
                id: building
                width: parent.width
                height: building.implicitHeight
                title: "While building for the desktop"
                what: "Errors from a normal <tt>cargo build</tt> or \
<tt>nix build</tt> of the desktop app."
                why: "Three of these four are the same underlying fact in \
different costumes: <b>cxx-qt asks one qmake for everything</b>, and on \
NixOS no single Qt prefix has everything."
                ifWrong: "If your error is here but the fix does not apply, \
check which qmake answered - it is the first row on the Qt page, and a \
runtime copy answering instead of your dev shell's is the usual reason a \
correct fix appears not to work."
                onLinkActivated: function(id) { root.openTopic(root.topicFor(id)) }
                rows: [
                    { label: "codegen fails",
                      value: "builds a long way, then the prefix is missing qmltyperegistrar",
                      source: "tools absent here: " + root.val("qt", "tools_missing"),
                      linkText: "why there is no single Qt →", linkId: "prefix" },
                    { label: "-lGLX",
                      value: "cannot find -lGLX: libglvnd is not in buildInputs",
                      source: "packages is not enough - only buildInputs reaches the linker",
                      linkText: "trap 2 →", linkId: "prefix" },
                    { label: "no prl path",
                      value: "QuickControls2: a setup hook re-exported QMAKE, under nix build only",
                      source: "never in the dev shell, which is why it appears at packaging time",
                      linkText: "trap 3 →", linkId: "prefix" },
                    { label: "module mismatch",
                      value: "a .qt_module in build.rs with no Qt:: in CMake",
                      source: "the one error here that names what to do",
                      linkText: "QML meets Rust →", linkId: "rust" }
                ]
            }

            ConfigSection {
                id: browser
                width: parent.width
                height: browser.implicitHeight
                title: "While building for the browser"
                what: "Errors from a WebAssembly build - <tt>nix develop \
./ui-wasm</tt> and <tt>ui-wasm/build.sh</tt>."
                why: "A cross build runs two Qts and one Emscripten at once, \
so the question behind most of these is <i>which half answered</i>."
                ifWrong: "<b>Two of these share their wording with a desktop \
error and do not share its cause.</b> A missing prl path for <i>Gui</i> in a \
wasm build is a relative qt.conf, not the setup hook; an undefined symbol at \
link is the Emscripten pairing, not a missing library."
                onLinkActivated: function(id) { root.openTopic(root.topicFor(id)) }
                rows: [
                    { label: "Qt6Qml",
                      value: "could NOT find it: qt.toolchain.cmake reset CMAKE_PREFIX_PATH",
                      source: "use QT_ADDITIONAL_PACKAGES_PREFIX_PATH, which survives it",
                      linkText: "blocker C →", linkId: "wasm" },
                    { label: "ia32_pause",
                      value: "undeclared identifier: the HOST qmake answered a wasm build",
                      source: "an x86 intrinsic, reached while compiling for WebAssembly",
                      linkText: "blocker A →", linkId: "wasm" },
                    { label: "no prl path",
                      value: "Gui: the cross qmake's qt.conf uses relative paths",
                      source: "same wording as the desktop row above, different cause",
                      linkText: "blocker B →", linkId: "wasm" },
                    { label: "Threads",
                      value: "could NOT find it: EM_CACHE is read-only or empty",
                      source: "it must be a writable COPY, not an empty directory",
                      linkText: "trap 2 →", linkId: "wasm" },
                    { label: "undefined symbol",
                      value: "at link: the Emscripten major differs from Qt's pin",
                      source: "same series here: " + root.val("qt-wasm", "emcc_series_match")
                              + " (wants " + root.val("qt-wasm", "emcc_recommended")
                              + ", built with " + root.val("qt-wasm", "emcc_built_with") + ")",
                      linkText: "trap 1 →", linkId: "wasm" },
                    { label: "qResourceFeatureZstd",
                      value: "rcc ran from the host Qt, which has zstd; the wasm Qt does not",
                      source: "CXX_QT_AUTORCC_OPTIONS = \"--no-zstd\", then touch build.rs",
                      linkText: "blocker D →", linkId: "wasm" },
                    { label: "instant rebuild",
                      value: "the identical error after a correct fix - a stale qrc object",
                      source: "touch the crate's build.rs; a suspiciously fast build is the tell",
                      linkText: "QML meets Rust →", linkId: "rust" }
                ]
            }

            ConfigSection {
                id: running
                width: parent.width
                height: running.implicitHeight
                title: "After it built, while it runs"
                what: "The build succeeded. Something is still wrong, and \
nothing printed an error."
                why: "<b>This group is the dangerous one.</b> Every entry \
here is a success as far as every tool involved is concerned - a failed QML \
import is not an error at any level that reports, and an undefined property \
has a string form, so it travels before it fails."
                ifWrong: "A blank window with no output is almost always the \
module URI or the resource lists. <tt>./qml-check</tt> finds binding \
mistakes without running anything; it does <b>not</b> find these."
                onLinkActivated: function(id) { root.openTopic(root.topicFor(id)) }
                rows: [
                    { label: "blank window",
                      value: "no error at all: the module URI disagrees in one of four places",
                      source: "or NIXDASH_QML_DIR, which redirects Main.qml alone",
                      linkText: "the Qt overview →", linkId: "overview" },
                    { label: "No such file",
                      value: "for a file that exists: a ../ path in qml_files ate the module name",
                      source: "the shared qml/ is reached by symlink, never by ..",
                      linkText: "the Qt overview →", linkId: "overview" },
                    { label: "local file GET",
                      value: "disabled by default: a Rust api_base never became apiBase in QML",
                      source: "undefined stringified into the URL and made it a path",
                      linkText: "QML meets Rust →", linkId: "rust" },
                    { label: "QObject warning",
                      value: "qmltyperegistrar cannot find it - upstream cxx-qt, not your setup",
                      source: "every build, harmless at runtime - bumping cxx-qt will not fix it",
                      linkText: "QML meets Rust →", linkId: "rust" }
                ]
            }

            SelectableText {
                width: parent.width
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.RichText
                font.pixelSize: style.fontBody
                text: "<b>Every row above was paid for on this machine.</b> \
None is taken from documentation, which is why several of them say the \
message is misleading - that judgement needs someone who followed it \
somewhere wrong first.<br><br>\
One row has no page behind it yet: <tt>qResourceFeatureZstd</tt>, whose fix \
is a single line and whose nastiness is its delayed onset - rcc only \
compresses once the payload is worth it, so a project with one small QML \
file links fine and the same setup breaks when a few more are added. It \
looks like the new file broke the build. It did not. Assume it is latent in \
any Qt-wasm project with a small <tt>.qrc</tt>."
            }
        }
    }
}
