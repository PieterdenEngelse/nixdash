import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Developing Qt here, as opposed to whether Qt is healthy here.
//
// The split against Monitor's Qt subject is the same one the Dev page makes
// against Config: that page asks "is this machine's Qt well", this one asks
// "what does a build of mine actually use". They read the same panels and
// answer different questions, so the readings are arranged by what a build
// consumes rather than by what a monitor would report.
//
// The organising fact, and the one that has cost the most time in this
// project: on NixOS there is no single Qt. qtbase, qtdeclarative and the
// host tools are separate store paths, and which of them a given qmake can
// see decides whether a cxx-qt build works. Three of the four boards below
// are different views of that one question.
Item {
    id: root

    Style { id: style }

    property var panels: []
    property string apiBase: ""

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

    /// A store path's name, without the hash or the /nix/store prefix.
    ///
    /// The hashes are what make two of these look identical at a glance, and
    /// the name is what tells qtbase from a merged env. The full path is
    /// still in the row above, selectable, for pasting.
    function storeName(p) {
        if (!p || p === "—") return "—"
        var parts = String(p).split("/")
        var last = parts[parts.length - 1]
        var dash = last.indexOf("-")
        return dash > 0 ? last.substring(dash + 1) : last
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
                text: "Qt development"
                font.bold: true
                font.pixelSize: 18
            }

            SelectableText {
                width: parent.width
                wrapMode: TextEdit.Wrap
                font.pixelSize: style.fontBody
                text: "Which Qt a build of yours actually uses, and why that "
                    + "is a different question from whether Qt works. On "
                    + "NixOS there is no single Qt: qtbase, qtdeclarative and "
                    + "the host tools are separate store paths, and cxx-qt "
                    + "asks ONE qmake for all of them. Most of what goes "
                    + "wrong here is that question answered with the wrong "
                    + "prefix."
            }

            GridLayout {
                width: parent.width
                columns: root.width >= 1500 ? 2 : 1
                columnSpacing: 14
                rowSpacing: 14

                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "Which qmake answered"
                    what: "The qmake this app found, and where it came from. \
cxx-qt interrogates one qmake for headers, libraries AND the host tools that \
generate code, so this single answer decides whether a build works."
                    why: "<b>There are three places it can come from, and \
they are not interchangeable.</b> <tt>QMAKE</tt> in the environment is what \
a build uses; one on <tt>PATH</tt> is what you would get by typing it; and \
the one inside this app's own files is neither - it is simply the Qt this \
window is drawing with.<br><br>\
The app's background service has its own environment, which is not your \
shell's. It has no dev shell, so it usually finds only the third."
                    ifWrong: "<b>A prefix found in this app's own files says \
nothing about a build.</b> It is a runtime copy: the host tools are absent \
from it on purpose, because nothing needs them to draw a window. Reading \
that as a broken build setup is a mistake this app itself made until \
2026-10-23, when it advised adding a merged prefix to a project that had \
had one for weeks."
                    rows: [
                        { label: "found via", value: root.val("qt", "source"),
                          source: "QMAKE, then PATH, then this app's own files" },
                        { label: "qmake", value: root.val("qt", "qmake"),
                          source: "the one binary everything below is read from" },
                        { label: "prefix", value: root.val("qt", "prefix"),
                          source: root.storeName(root.val("qt", "prefix")) },
                        { label: "version", value: root.val("qt", "version"),
                          source: "what that qmake reports, not what is installed elsewhere" },
                        { label: "target", value: root.val("qt", "target_spec"),
                          source: "the platform it builds for - linux-g++ natively, wasm when cross-building" }
                    ]
                }

                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "The merged prefix"
                    what: "Whether that one prefix contains every host tool \
cxx-qt needs. <tt>moc</tt> and <tt>rcc</tt> live in qtbase; \
<tt>qmltyperegistrar</tt> and <tt>qmlcachegen</tt> live in qtdeclarative, \
which is a different store path."
                    why: "<b>This is the Qt-on-NixOS problem in one \
reading.</b> A build with an incomplete prefix does not fail at configure \
time - it gets as far as code generation and then cannot find a tool, with \
an error naming the tool rather than the split that caused it.<br><br>\
<tt>pkgs.qt6.env</tt> is the fix: it merges the outputs and copies a real \
qmake next to a generated <tt>qt.conf</tt>, so the merged prefix is what \
qmake reports. A plain <tt>symlinkJoin</tt> does not work - nixpkgs' qmake \
has its prefix compiled in."
                    ifWrong: "Adding more entries to <tt>buildInputs</tt> \
does not help: qmake still reports one prefix. The merge is the fix, not \
more inputs.<br><br>\
Incomplete here while your builds succeed is the expected reading, not a \
fault - see the board beside this one. It means the qmake being reported is \
the runtime one, and your dev shell's <tt>QMAKE</tt> is something this app \
cannot see."
                    rows: [
                        { label: "complete", value: root.val("qt", "prefix_complete"),
                          source: "every tool cxx-qt needs, in the one prefix above" },
                        { label: "found", value: root.val("qt", "tools_found"),
                          source: "present where qmake says to look" },
                        { label: "missing", value: root.val("qt", "tools_missing"),
                          source: "absent from that prefix - qtdeclarative's, usually" },
                        { label: "tools dir", value: root.val("qt", "host_libexecs"),
                          source: "where qmake says the generators are" }
                    ]
                }

                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "What this window links against"
                    what: "The Qt this running window actually uses, read \
from the binary rather than from a build file. A separate fact from \
everything above, which describes a build."
                    why: "<b>Running and building are two different Qts, and \
confusing them is the single most expensive mistake on this page.</b> A \
window draws perfectly against a prefix with no host tools in it, because \
drawing needs none. The same prefix would fail a build at code \
generation.<br><br>\
So \"Qt works here\" and \"a Qt build works here\" are independent, and only \
one of them is visible by looking at the screen."
                    ifWrong: "<b>wrapped</b> says whether the binary goes \
through a wrapper that sets Qt's environment. An unwrapped one finds its \
plugins by the paths compiled into it, which is why a store-path binary \
keeps working when nothing in your shell points at Qt at all.<br><br>\
A version here differing from the board above is not a fault: it means you \
are running one build and would compile against another, which is exactly \
what happens between a switch and a rebuild."
                    rows: [
                        { label: "binary", value: root.val("qt-runtime", "inspected"),
                          source: "the file these readings were taken from" },
                        { label: "Qt version", value: root.val("qt-runtime", "version"),
                          source: "what it links against, not what qmake reports" },
                        { label: "prefix", value: root.val("qt-runtime", "prefix"),
                          source: root.storeName(root.val("qt-runtime", "prefix")) },
                        { label: "modules", value: root.val("qt-runtime", "modules"),
                          source: "the Qt libraries it pulls in" },
                        { label: "wrapped", value: root.val("qt-runtime", "wrapped"),
                          source: "whether a wrapper sets its Qt environment" },
                        { label: "merged env", value: root.val("qt-runtime", "merged_env"),
                          source: "whether that prefix is a merged one" }
                    ]
                }

                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "The WebAssembly toolchain"
                    what: "The second Qt: a cross-compiling SDK that builds \
the same qml/ into a browser bundle. Not the one above, and not \
interchangeable with it."
                    why: "<b>A cross build needs two Qts at once.</b> The \
wasm SDK supplies the headers and libraries for the target, while the code \
generators have to run on THIS machine - so a native Qt is needed as well, \
named by <tt>QT_HOST_PATH</tt>. Point that at the wasm one and the build \
tries to execute wasm binaries.<br><br>\
Qt for WebAssembly is built against one Emscripten release and pins it. The \
same 4.0 series is usually tolerated; a different major is not."
                    ifWrong: "<b>Emscripten expected is not a comparison.</b> \
It states what this Qt wants; nothing here checks your emsdk against it. If \
yours differs, pin the nixpkgs carrying the matching emcc rather than \
overriding Qt's check.<br><br>\
Versions matching matters because both halves compile the same QML. A \
mismatch produces errors about generated code, which read as a bug in \
qml/ rather than a toolchain pairing."
                    rows: [
                        { label: "wasm SDK", value: root.val("qt-wasm", "sdk"),
                          source: root.storeName(root.val("qt-wasm", "sdk")) },
                        { label: "wasm Qt", value: root.val("qt-wasm", "sdk_version"),
                          source: "the Qt the browser bundle is built against" },
                        { label: "desktop Qt", value: root.val("qt-wasm", "desktop_version"),
                          source: "the one the window above is built against" },
                        { label: "same version", value: root.val("qt-wasm", "versions_match"),
                          source: "both halves compile the same qml/, so they must agree" },
                        { label: "host tools", value: root.val("qt-wasm", "host_env"),
                          source: "QT_HOST_PATH - generators that run natively, not in wasm" },
                        { label: "emcc wanted", value: root.val("qt-wasm", "emcc_recommended"),
                          source: "pinned by this Qt; see ~/Projects/qt6-wasm" }
                    ]
                }
            }

            // Static, like the Dev page's numbered boards: these are rules of
            // the build rather than readings of it, and nothing measures
            // them. They sit at the bottom because they are reference you
            // come back to, not a state you check.
            ConfigSection {
                id: moduleRules
                width: parent.width
                height: moduleRules.implicitHeight
                title: "The QML module"
                what: "How qml/ becomes something the two programs can \
import, and the four places that have to agree for it to work."
                why: "<b>Every one of these fails silently.</b> A mismatched \
URI builds cleanly and then shows an empty window; a file missing from a \
resource list is simply absent, and the error names a failed import rather \
than a missing entry. None of them is a compile error."
                ifWrong: "A blank window with no error is almost always this \
board. <tt>./qml-check</tt> finds the binding mistakes that are visible \
without running anything; <tt>just gate</tt> runs the tests that check the \
lists."
                rows: [
                    { label: "the URI", value: "nixdash",
                      source: "must match in FOUR places or the window is blank",
                      what: "The module name QML imports. It appears in \
rust/build.rs, CMakeLists.txt's cxx_qt_import_qml_module, the qrc path in \
main.rs, and the import line in Main.qml.",
                      why: "Nothing checks that the four agree. Three of them \
matching produces a build that succeeds and a window that draws nothing, \
because the import resolves to a module that was registered under another \
name.",
                      ifWrong: "An empty window with no console output. The \
import failed, and a failed import is not an error at the level anything \
reports." },
                    { label: "resource lists", value: "ui/build.rs + ui-wasm/rust/build.rs",
                      source: "two lists, and a new .qml must be in both",
                      what: "Each UI compiles qml/ into its own resource \
bundle from its own list of files.",
                      why: "They are separate lists for one directory, so a \
new file added to one is missing from the other - and the half that is \
missing it fails only when that component is first used.",
                      ifWrong: "The desktop UI works and the browser one does \
not, from the same edit. engine/tests/qml_registered.rs fails on a file \
missing from either list, and on a list entry whose file is gone - what a \
rename leaves behind." },
                    { label: "the symlink", value: "ui/qml -> ../qml",
                      source: "a symlink, never a ../qml path",
                      what: "Each crate reaches the shared qml/ through a \
symlink inside itself.",
                      why: "cxx-qt copies the given path into the resource \
alias verbatim. <tt>../qml/Main.qml</tt> under the module prefix normalises \
to a path with the module name eaten, and every sibling component then \
fails to resolve.",
                      ifWrong: "\"No such file or directory\" for components \
that plainly exist. Upstream's own examples symlink for this reason." },
                    { label: "reading from disk", value: "NIXDASH_QML_DIR",
                      source: "redirects Main.qml, and nothing else that exists",
                      what: "Points the app at a qml/ directory instead of \
its compiled-in copy.",
                      why: "<b>It redirects Main.qml alone.</b> Main.qml \
carries <tt>import nixdash</tt>, and that module shadows the directory for \
every name in it, so an edited ConfigSection or DevPage still comes from \
the bundle.",
                      ifWrong: "An edit that does not appear, with no error \
anywhere - the binary renders its own copy, correctly. A brand-new file is \
the one exception: nothing in the module shadows it, so it renders from the \
directory while absent from both build.rs lists." }
                ]
            }
        }
    }
}
