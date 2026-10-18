import QtQuick
import QtQuick.Controls

// Rust, judged by what it can actually build.
//
// The version is the least useful thing here: nixpkgs' rustc and a fenix
// toolchain report similar versions but differ in the one way that decides
// whether a wasm build works. So the panel leads with provenance and the
// targets, and names the failure each absence produces.
Panel {
    id: root

    Style { id: style }

    // Header + verdict + 2 rows + gap + 3 target rows + the hint line.
    // Content-driven: a wrapped toolchain path makes the block taller than
    // a fixed height can allow for.
    contentHeight: col.implicitHeight

    readonly property bool present: value && value.rustc
    readonly property string path: value && value.rustc_path ? value.rustc_path : ""

    // Which toolchain this is, from the store path. Worth surfacing because
    // it is otherwise guesswork, and it is the difference between having the
    // emscripten target and not.
    readonly property string provenance:
        path.indexOf("rust-mixed") >= 0 ? "fenix"
      : path.indexOf("rustc-wrapper") >= 0 ? "nixpkgs"
      : path === "" ? "—" : "other"

    readonly property bool hasEm: value ? value.has_wasm32_emscripten : false
    readonly property bool hasWasm: value ? value.has_wasm32_unknown : false
    readonly property bool hasLld: value ? value.lld_available : false

    /// Whether an absent target is a FAULT here, or merely a fact.
    ///
    /// Both come from the engine, which already decides this to gate the
    /// suggested actions. The panel used to decide separately - colouring
    /// both rows as warnings and offering a fenix hint - so the board said
    /// "problem, here is the fix" while Suggested actions had concluded
    /// there was nothing to do. Two deciders, two answers; this reads the
    /// one that gates the offer.
    readonly property bool emMatters: value ? !value.wasm_bundle_built : false
    readonly property bool lldMatters: value ? value.targets_bare_wasm : false

    Column {
        id: col
        anchors.fill: parent
        spacing: 5

        // The verdict names the TOOLCHAIN it measured, not a capability.
        //
        // It used to read "Cannot build Qt for WebAssembly", which was false
        // on this machine and false in a way the project has a test for. The
        // reading behind it is `rustc --print target-libdir` against the
        // DEFAULT toolchain - nixpkgs' rustc, the one the background service
        // sees. The browser UI is never built with that one: flake.nix pins a
        // separate toolchain carrying the emscripten std and `nix develop
        // .#wasm` is where ui-wasm/build.sh runs. So the panel measured one
        // environment and pronounced on another, while the Suggested action
        // beside it correctly told you to go ahead and build.
        //
        // Same error as "no Qt in this environment" from an app drawn by
        // libQt6Qml - see headlines_claim_only_what_was_measured. That test
        // greps the engine's headlines and cannot see a string composed here.
        SelectableText {
            width: parent.width
            text: !root.present ? "No rustc on PATH"
                : root.hasEm ? "Default toolchain has the emscripten target"
                : "Default toolchain has no emscripten target"
            font.pixelSize: style.fontBody
            font.bold: true
            color: !root.present ? palette.text : root.hasEm ? style.okText : style.warnText
            wrapMode: TextEdit.Wrap
        }

        // One block, so a drag takes the whole toolchain picture rather
        // than one line of it. The blank spacer row that used to separate
        // the version from the targets is gone with the per-row items; the
        // labels carry that distinction on their own.
        StatBlock {
            panel: root
            rows: [
                { label: "rustc",
                  value: root.value && root.value.rustc
                         ? root.value.rustc.split(" ").slice(0, 2).join(" ")
                         : "—",
                  statKey: "rustc" },
                { label: "toolchain", value: root.provenance,
                  statKey: "rustc_path" },
                { label: "wasm32-unknown",
                  value: !root.present ? "—"
                         : root.hasWasm ? "✓ installed" : "✗ absent",
                  color: !root.present ? palette.text
                         : root.hasWasm ? style.okText : style.warnText,
                  statKey: "has_wasm32_unknown" },
                { label: "wasm32-emscripten",
                  value: !root.present ? "—"
                         : root.hasEm ? "✓ installed" : "✗ absent",
                  // Neutral when it does not matter: a browser UI that has
                  // already been built proves the toolchain that counts
                  // resolves, whatever the default one lacks.
                  color: !root.present ? palette.text
                         : root.hasEm ? style.okText
                         : root.emMatters ? style.warnText : palette.text,
                  statKey: "has_wasm32_emscripten" },
                // lld is only actually a problem alongside
                // wasm32-unknown-unknown, which is the target that links
                // with it.
                { label: "lld",
                  value: !root.present ? "—"
                         : root.hasLld ? "✓ present" : "✗ absent",
                  // Keyed on whether anything here BUILDS for the bare wasm
                  // target, not on whether its std happens to be installed.
                  // nixpkgs ships that std with every rustc, so the old test
                  // was red on any NixOS machine for a linker nobody needed.
                  color: !root.present ? palette.text
                         : root.hasLld ? style.okText
                         : root.lldMatters ? style.badText : palette.text,
                  statKey: "lld_available" }
            ]
        }

        SelectableText {
            width: parent.width
            // Only when the matching action is offered. Advice for a
            // problem the engine has decided you do not have is worse than
            // no advice: it cannot be acted on and cannot be cleared.
            visible: root.present && !root.hasEm && root.emMatters
            text: "Add a fenix toolchain to the dev shell for the emscripten target."
            font.pixelSize: style.fontBody
            wrapMode: TextEdit.Wrap
        }
    }
}
