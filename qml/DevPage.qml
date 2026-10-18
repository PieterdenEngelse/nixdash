import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Building nixdash itself, as opposed to the machine it watches.
//
// The split against the Config page is "what is this computer" versus "what
// am I compiling": a store path's Qt version belongs there, whether the
// browser UI is older than qml/ belongs here. They were one page, and the
// development half pushed the machine half below the fold on a page that
// already needed scrolling.
//
// The readings here are the ones that go wrong while you work rather than
// while you administer: a build that predates its source, a dev shell missing
// the linker a target needs, a WebAssembly bundle still serving yesterday.
Item {
    id: root

    Style { id: style }

    property var panels: []
    property var actions: []
    property string apiBase: ""

    // A run changes exactly the state these sections read, so the shell
    // re-polls afterwards.
    signal ranAction()

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
                text: "Development"
                font.bold: true
                font.pixelSize: 18
            }

            SelectableText {
                width: parent.width
                wrapMode: TextEdit.Wrap
                font.pixelSize: style.fontBody
                text: "What is compiled, and whether it matches the source on "
                    + "disk. The window and the background service are "
                    + "separate programs and can be different builds - which "
                    + "is the usual reason a change you just made does not "
                    + "show up. Drag across the rows to select what you drag, "
                    + "Ctrl+A for a whole section, or Ctrl+Shift+C to copy "
                    + "the section under the pointer as tab-separated text."
            }

            // Same breakpoints as the Config page, so the two read alike.
            //
            // Sections share a row and every section in a row takes the row's
            // height - see the long note on Layout.fillHeight in
            // SubjectPage.qml. Without it a Qt Quick Layout CENTRES an item
            // that cannot grow, so these three (three rows, six rows, and
            // however many the dev shell has) sat at three different heights
            // with ragged edges. Stacking them one per row fixed the ragged
            // edges by giving up the row, which costs a screenful of
            // scrolling for nothing.
            GridLayout {
                width: parent.width
                columns: root.width >= 1500 ? 3 : (root.width >= 900 ? 2 : 1)
                columnSpacing: 14
                rowSpacing: 14

                // Moved off the Rust section, where it sat among toolchain
                // readings that answer a different question. "Can this
                // machine compile Rust" and "is the thing answering me built
                // from what is on disk" are not neighbours.
                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "Build freshness"
                    rows: [
                        { label: "Running build", value: root.val("rust-build", "deployed") === "yes"
                                                         ? "deployed (store)" : "dev build",
                          source: root.val("rust-build", "running_exe") },
                        // Which build is answering. The version number is the
                        // same in every build ever made, so this is the only
                        // row that can tell two of them apart.
                        { label: "Built", value: root.val("rust-build", "built"),
                          source: "baked in when it was compiled - a store path's own date is 1970" },
                        // Three states, not two: "—" means the comparison
                        // could not be made, and showing that as "yes" would
                        // be the panel reassuring you about something it
                        // never checked.
                        { label: "Current with source", value: root.val("rust-build", "stale") === "—"
                                                                ? "unknown"
                                                                : root.val("rust-build", "stale") === "yes"
                                                                  ? "no" : "yes",
                          source: root.val("rust-build", "newest_source_file") }
                    ]
                }

                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "Qt — WebAssembly"
                    rows: [
                        { label: "Browser UI built", value: root.val("qt-wasm", "built"),
                          source: "ui-wasm/build.sh, inside nix develop .#wasm" },
                        { label: "Up to date with qml/", value: root.val("qt-wasm", "stale") === "yes"
                                                                ? "no" : root.val("qt-wasm", "stale"),
                          source: root.val("qt-wasm", "newest_qml_file") },
                        { label: "Qt for wasm", value: root.val("qt-wasm", "sdk_version"),
                          source: root.val("qt-wasm", "sdk") },
                        { label: "Same Qt as desktop", value: root.val("qt-wasm", "versions_match"),
                          source: "" },
                        { label: "Emscripten expected", value: root.val("qt-wasm", "emcc_recommended"),
                          source: "pinned by this Qt; see ~/Projects/qt6-wasm" },
                        { label: "Host Qt for codegen", value: root.val("qt-wasm", "host_env"),
                          source: "QT_HOST_PATH - moc/rcc that run natively" }
                    ]
                }

                // The one writable section here: this project's shell, not
                // the machine. Same arrangement as elsewhere - a generated
                // file the app owns, never the hand-written one beside it.
                DevShellSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    apiBase: root.apiBase
                    onChanged: root.ranAction()
                }
            }

            // Only the actions these sections can act on - rebuilding the
            // browser UI, and the dev shell's missing pieces. The machine's
            // own actions stay on the Config page, next to what they change.
            ActionsPanel {
                id: devActions
                width: parent.width
                height: devActions.implicitHeight
                visible: root.actions.length > 0
                actions: root.actions
                errors: []
                apiBase: root.apiBase
                onRanAction: root.ranAction()
            }
        }
    }
}
