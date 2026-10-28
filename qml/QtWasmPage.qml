import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Why a browser build needs two Qts and one pinned Emscripten.
//
// The second teaching page under Dev > Qt. The prefix page answers "why is
// there no single Qt"; this one answers the question that follows the first
// time you build the same qml/ for a browser - why there are now two of
// them, which is which, and what a version mismatch looks like before you
// know it is one.
//
// Same rule as its sibling: the reading first, prose about the reading
// second. The Emscripten pairing is measured on both halves - what Qt pins,
// and what the SDK was actually built with, the latter read from the
// derivation rather than from PATH. An earlier draft of this page said the
// second half could not be known; it can, and the board answers trap 1
// rather than only describing it. The build recipes stay in ~/docs/qt.md
// Part 2, encoded in ~/Projects/qt6-wasm.
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
    /// Two SDK paths differ only in their hash at a glance, and the name is
    /// what tells the wasm Qt from the host one. The full path stays in the
    /// row above, selectable, for pasting.
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
                text: "Two Qts, and the Emscripten between them"
                font.bold: true
                font.pixelSize: 18
            }

            SelectableText {
                width: parent.width
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.RichText
                font.pixelSize: style.fontBody
                text: "The same <tt>qml/</tt> becomes two programs: the \
window you are reading this in, and a bundle that runs in a browser. The \
desktop half needs one Qt. <b>The browser half needs two at once.</b><br><br>\
A cross build compiles for WebAssembly but has to <i>run</i> its code \
generators - <tt>moc</tt>, <tt>rcc</tt>, <tt>qmltyperegistrar</tt> - on this \
machine, natively. So one Qt supplies the headers and libraries for the \
target, and a second supplies the tools that run here. Point the build at \
one where it wanted the other and it tries to execute wasm binaries on \
x86."
            }

            // The reading first. Someone arriving here has a browser build
            // that failed, or is about to start one; their own paths are
            // more use than a paragraph about paths in general.
            ConfigSection {
                id: yours
                width: parent.width
                height: yours.implicitHeight
                title: "On this machine, right now"
                what: "The two Qts this project's browser build uses, and the \
Emscripten release the wasm one was built against."
                why: "These are the values a cross build is decided by. The \
<b>wasm SDK</b> is the target Qt; <b>host tools</b> is what QT_HOST_PATH \
names, and is a separate store path on purpose. The last three rows are the \
Emscripten pairing trap 1 below is about, answered rather than described."
                ifWrong: "<b>Both Emscripten rows are measured</b>, and \
neither comes from your PATH. <i>Qt wants</i> is read from this Qt's own \
CMake helpers; <i>built with</i> is read from the derivation that produced \
the SDK. A PATH probe was the obvious way and the wrong one - there is no \
emcc on this machine's PATH at all, since the emsdk lives in \
<tt>~/Projects/qt6-wasm</tt>'s dev shell, so it would report either nothing \
or some unrelated system emcc.<br><br>\
<b>Same series</b> compares major.minor, not the whole version, because \
that is what Qt enforces - 4.0.10 against a pinned 4.0.7 warns and builds. \
Blank rather than <i>no</i> whenever a version is unknown: the store path \
outlives its derivation, so after a garbage collection this becomes could \
not look, which is not the same answer as disagree."
                rows: [
                    { label: "wasm SDK", value: root.val("qt-wasm", "sdk"),
                      source: root.storeName(root.val("qt-wasm", "sdk")) },
                    { label: "host tools", value: root.val("qt-wasm", "host_env"),
                      source: "QT_HOST_PATH - the generators that run on x86, not in wasm" },
                    { label: "wasm Qt", value: root.val("qt-wasm", "sdk_version"),
                      source: "the Qt the browser bundle is built against" },
                    { label: "desktop Qt", value: root.val("qt-wasm", "desktop_version"),
                      source: "the Qt this window is built against" },
                    { label: "same version", value: root.val("qt-wasm", "versions_match"),
                      source: "measured - both halves compile the same qml/, so they must agree" },
                    { label: "emcc Qt wants", value: root.val("qt-wasm", "emcc_recommended"),
                      source: "pinned in this Qt's own CMake helpers" },
                    { label: "emcc built with", value: root.val("qt-wasm", "emcc_built_with"),
                      source: "measured - from the derivation that produced the SDK" },
                    { label: "same series", value: root.val("qt-wasm", "emcc_series_match"),
                      source: "measured - major.minor, which is what Qt enforces" }
                ]
            }

            SelectableText {
                width: parent.width
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.RichText
                font.pixelSize: style.fontBody
                text: "<b>Three traps follow</b>, and none of them names \
itself in the error you get. nixpkgs ships no Qt for WebAssembly at all - \
zero <tt>wasm</tt> references in its qt-6 packaging - so this Qt is \
cross-compiled from source, and these are what that costs."
            }

            GridLayout {
                width: parent.width
                columns: root.width >= 1500 ? 3 : (root.width >= 900 ? 2 : 1)
                columnSpacing: 14
                rowSpacing: 14

                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "1 · Emscripten is pinned, per Qt release"
                    what: "Qt names one exact Emscripten version per release, \
in <tt>QtPublicWasmToolchainHelpers.cmake</tt> as \
<tt>QT_EMCC_RECOMMENDED_VERSION</tt>. The board above reads that value."
                    why: "<b>The channel you reach for is usually the wrong \
major.</b> Checked on this machine: the system channel gave 5.0.6 and the \
flake registry's unstable gave 6.0.9, against the 4.0.7 this Qt wants. \
<tt>nixos-25.05</tt> carries 4.0.10 - same 4.0 series, which is what is \
actually required."
                    ifWrong: "<b>A near miss is a warning, not an error</b>, \
and that asymmetry is the trap: 4.0.10 against 4.0.7 builds fine. The \
<tt>FATAL_ERROR</tt> check fires when <i>consuming</i> a prebuilt Qt wasm, \
not when building Qt itself - so the version you got away with while \
building is the one that stops you later."
                    rows: [
                        { label: "symptom", value: "version error on consuming, not building",
                          source: "the build that produced it never complained" },
                        { label: "cause", value: "emcc major differs from Qt's pin",
                          source: "channels move; Qt's pin does not" },
                        { label: "fix", value: "pin nixpkgs nixos-25.05",
                          source: "4.0.10 - the same series, which is close enough" }
                    ]
                }

                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "2 · The emcc cache must be writable"
                    what: "nixpkgs ships Emscripten's prebuilt sysroot inside \
the store, and the store is read-only. <tt>emcc</tt> wants to take a lock \
inside its own cache."
                    why: "<b>Pointing <tt>EM_CACHE</tt> at an empty directory \
makes it worse.</b> That is the obvious fix and it loses the sysroot headers \
with it, turning a lock error into <tt>fatal error: 'bits/stdint.h' file not \
found</tt> - which reads as a broken Emscripten rather than an emptied \
cache. Copy the store cache somewhere writable instead."
                    ifWrong: "<tt>OSError: [Errno 30] Read-only file system</tt> \
on a <tt>.json.lock</tt> under the cache. A filesystem error from a \
compiler, naming a path you did not choose."
                    rows: [
                        { label: "symptom", value: "Errno 30 on a .lock in the cache",
                          source: "emcc fails before compiling anything" },
                        { label: "cause", value: "the sysroot is in the store",
                          source: "immutable by design, and emcc wants to write there" },
                        { label: "fix", value: "cp -r the cache, chmod u+w, EM_CACHE",
                          source: "a copy - not an empty directory, which loses the headers" }
                    ]
                }

                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "3 · Qt expects an emsdk-shaped directory"
                    what: "Qt reads <tt>$EMSDK/.emscripten</tt>, takes \
<tt>EMSCRIPTEN_ROOT</tt> from it as a <i>relative</i> suffix, and then \
expects <tt>$EMSDK/&lt;suffix&gt;/emcc</tt>. nixpkgs lays Emscripten out \
differently and splits the wrapped drivers into <tt>bin/</tt>."
                    why: "<b>Symlink the wrapped binaries, not the raw \
ones.</b> The programs in <tt>share/emscripten</tt> are missing the \
<tt>PYTHON</tt> and <tt>NODE_PATH</tt> exports the wrappers in \
<tt>bin/</tt> add, so a shim built from the obvious directory produces \
drivers that cannot find their own interpreter."
                    ifWrong: "Qt's configure cannot find emcc, while emcc is \
plainly on PATH and runs when you type it. The disagreement is about layout, \
not presence."
                    rows: [
                        { label: "symptom", value: "Qt cannot find an emcc that works",
                          source: "one you can run yourself from the same shell" },
                        { label: "cause", value: "nixpkgs' layout is not emsdk's",
                          source: "Qt resolves a relative path under $EMSDK" },
                        { label: "fix", value: "a shim dir with a relative .emscripten",
                          source: "symlinks to bin/, the wrapped drivers" }
                    ]
                }
            }

            // The fix in one place, same as the prefix page ends: three
            // boards of reasoning still leave you needing something to run.
            ConfigSection {
                id: recipe
                width: parent.width
                height: recipe.implicitHeight
                title: "What this project does"
                what: "None of the three above is solved here, in this \
repository. They are solved once in <tt>~/Projects/qt6-wasm</tt>, whose \
output is the wasm SDK named at the top of this page."
                why: "That flake builds Qt 6.11.2 for WebAssembly from source \
and encodes every workaround on this page - the pinned Emscripten, the \
writable cache copy, the emsdk shim, and the host Qt reused from \
<tt>pkgs.qt6.env</tt>. The result is an SDK path this project consumes like \
any other store path."
                ifWrong: "<b>The first build is roughly 75 minutes</b>, and \
cached after that - so a cold <tt>nix build</tt> there is not hung. The \
host Qt it reuses is the same merged prefix the \"Why there is no single \
Qt\" page describes, which is why that page comes first.<br><br>\
The full recipes, including the configure flags and module order, are \
<tt>~/docs/qt.md</tt> Part 2."
                rows: [
                    { label: "the SDK", value: "cd ~/Projects/qt6-wasm && nix build",
                      source: "outputs qt6-wasm, emsdk and hostQt - ~75 min cold, then cached" },
                    { label: "the shell", value: "nix develop",
                      source: "every variable on this page already exported" },
                    { label: "the host Qt", value: "pkgs.qt6.env",
                      source: "the merged prefix from the prefix page, reused unchanged" },
                    { label: "the bundle", value: "nix develop .#wasm --command bash ui-wasm/build.sh",
                      source: "back in this repository, against that SDK" }
                ]
            }
        }
    }
}
