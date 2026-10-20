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

            // Which change needs which build, as reference rather than
            // reading: the rows below are static, not measured. They sit
            // ABOVE the measured boards deliberately - "what do I run" is
            // the question you arrive with, and "is it stale" is the one
            // you check afterwards.
            //
            // Ordered the way the builds have to happen: installed, then
            // service, then window. The long form is ~/docs/build2.md.
            GridLayout {
                width: parent.width
                columns: root.width >= 1500 ? 3 : (root.width >= 900 ? 2 : 1)
                columnSpacing: 14
                rowSpacing: 14

                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "1 · Changes what is installed"
                    what: "Edits that only take effect once something is \
built and installed - and the board that answers which of the two \
<i>switch</i> commands does it."
                    why: "<b>Two different commands both say switch.</b> \
<tt>nixos-rebuild switch</tt> reads <tt>/etc/nixos</tt> and needs root; \
<tt>home-manager switch</tt> reads <tt>~/.config/home-manager</tt> and does \
not. Neither reports that it was the wrong one: it rebuilds, succeeds, and \
your change is still not there."
                    ifWrong: "There is a third answer that is neither. A \
setting that lives in a devShell is not installed at all - it exists only \
inside <tt>nix develop</tt>, and no switch will ever apply it. Fifteen \
minutes is the usual price of guessing instead of reading the ↳ line."
                    rows: [
                        { label: "which switch?", value: "read the ↳ line",
                          source: "Config page names where a setting lives",
                          what: "Every row on the Config page carries a ↳ \
line naming the file that declares it. That file decides the command - you \
do not have to remember which layer a setting belongs to.",
                          why: "<b>Three answers, not two:</b><br>\
<table>\
<tr><td>under <tt>/etc/nixos</tt>&nbsp;&nbsp;</td>\
<td><tt>nixos-rebuild switch</tt> — includes \
<tt>hardware-configuration.nix</tt>, which lives there</td></tr>\
<tr><td><tt>nix/…</tt> or <tt>~/.config/home-manager</tt></td>\
<td><tt>home-manager switch</tt></td></tr>\
<tr><td>\"in the devShell\"</td>\
<td><b>neither</b> — exit and re-enter <tt>nix develop</tt></td></tr>\
</table>",
                          ifWrong: "Only one provenance line spells its \
command out; for the rest you read the path and apply the rule above.<br><br>\
The devShell row is the one people switch for unnecessarily. A setting \
sourced to <tt>pkgs.lld in the devShell</tt> or <tt>pkgs.qt6.env in your \
flake's devShell</tt> is not installed at all - it exists only while you \
are inside that shell, and fifteen minutes of switching will not change \
it." },
                        { label: "/etc/nixos", value: "nixos-rebuild switch",
                          source: "the machine - needs root",
                          what: "System configuration: services, the kernel, \
anything outside your user environment.",
                          why: "<b>home-manager switch will not apply it.</b> \
Two different commands that both say 'switch'. This one reads /etc/nixos \
and needs root; the other reads ~/.config/home-manager and does not. \
Picking wrong costs the wait and changes nothing.",
                          ifWrong: "nixdash never needs this for itself. It \
appears as the config-drift action when something under /etc/nixos is newer \
than the running system." },
                        { label: "nix/, flake.nix (not its devShell)", value: "home-manager switch",
                          source: "then xfce4-panel -r if the icon changed",
                          what: "What 'installed' means for nixdash: the \
engine package, the UI package, the launcher and the service unit.",
                          why: "Only a switch can apply these, by \
definition - they are the definition. Everything else builds on the \
generation they produce, which is why this category is first.",
                          ifWrong: "A launcher or menu change also needs \
xfce4-panel -r. New entries are not drawn live." }
                    ]
                }

                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "2 · Measures or decides"
                    what: "Edits to the background service: what it reads, \
what it concludes, and what it offers to do about it."
                    why: "The service runs an <b>installed</b> binary, not \
your tree, so editing it changes nothing until a switch - and then nothing \
again until the restart. The window you are looking at is a separate \
program, which is why a change here can be invisible while the UI looks \
perfectly current."
                    ifWrong: "Both failures here look like success. An \
un-restarted service reports active and answers every request from the old \
binary; a dev engine left on :3100 answers in the service's place while the \
real one crash-loops behind it. Use another port and nothing is ambiguous."
                    rows: [
                        { label: "engine/src/", value: "home-manager switch",
                          source: "THEN the restart it prints",
                          what: "Collectors, actions, severities, headlines, \
the API - everything the background service computes.",
                          why: "The service runs an <i>installed</i> binary, \
so editing the tree changes nothing and cargo build does not help.",
                          ifWrong: "<b>The restart is not optional.</b> A \
switch installs a new engine and rewrites the unit, but leaves the old \
process serving - and nothing says so. systemctl reports active, /health \
answers, panels update, all from the old binary. Compare the unit's \
ExecStart with /proc/&lt;MainPID&gt;/exe to be sure." },
                        { label: "testing it", value: "NIXDASH_PORT=3199 …",
                          source: "a second engine, beside the service",
                          what: "Run ./target/debug/nixdash-engine on another \
port and query that, instead of waiting fifteen minutes to find out.",
                          why: "Never take :3100 from the service. Stopping \
it blanks the app you are looking at, and a dev engine left holding that \
port makes the service crash-loop invisibly behind it - /health keeps \
answering, from the squatter." },
                    ]
                }

                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "3 · Draws something (twice)"
                    what: "One <tt>qml/</tt> directory, compiled into two \
programs: this window and the browser UI. Twice, because a change to what \
is drawn has to be built into each of them separately."
                    why: "QML is compiled INTO a binary here, not read from \
disk, so nothing picks up an edit by itself - and the two builds are \
unrelated. <tt>cargo build</tt> makes this window; only \
<tt>ui-wasm/build.sh</tt> makes the browser one."
                    ifWrong: "The failure is silence, not an error: each \
program keeps rendering whatever was last compiled into it. A running window \
shows yesterday's UI until reopened, and the browser version serves its last \
build forever. The Qt for WebAssembly board below is what tells you, naming \
the file that is ahead of the bundle."
                    rows: [
                        { label: "qml/, ui/src/", value: "cargo build -p nixdash-ui",
                          source: "inside nix develop, then reopen the window",
                          what: "Anything this window renders.",
                          why: "QML is compiled INTO the binary, so the edit \
reaches you in two steps: build, then reopen. A window already running \
shows yesterday's UI indefinitely.",
                          ifWrong: "Outside the dev shell the build dies on \
'Could not find Qt' - QMAKE is only set inside it." },
                        { label: "a NEW .qml file", value: "+ both build.rs",
                          source: "ui/build.rs and ui-wasm/rust/build.rs",
                          what: "A new QML file must be listed in both \
resource lists, which are separate.",
                          why: "Missing from one, it is simply absent from \
that UI's bundle - and the symptom is a failed import, not a missing \
file.",
                          ifWrong: "The desktop UI can work perfectly while \
the browser one fails to load, from the same edit." },
                        { label: "the browser UI", value: "nix develop .#wasm … build.sh",
                          source: "the SAME qml/, a second program",
                          what: "One qml/ directory is compiled into two \
programs: this window and the browser UI. ui-wasm/build.sh builds the \
second.",
                          why: "<b>Nothing else builds it.</b> Not cargo \
build, not a switch. So every QML edit silently leaves the browser version \
behind - it keeps serving whatever was last compiled, which looks identical \
to working.",
                          ifWrong: "The Qt for WebAssembly board below \
reports this as <tt>stale</tt>, naming the file that is ahead of the build. \
Leaving it stale costs nothing if you are not using the browser UI today; \
not knowing is the part that bites.<br><br>\
Separate toolchain - emcc and a wasm32 Rust target - so it needs its own \
dev shell and takes several minutes." },
                        { label: "after a switch", value: "rebuild to reclaim the icon",
                          source: "the switch built the window too",
                          what: "Build order when a change spans categories: \
switch first, then cargo build.",
                          why: "A switch builds the window from the same \
tree, so building first compiles the same binary twice. It also stamps a \
new generation, and the launcher starts whichever is newer - so the icon \
runs the installed copy until you rebuild." }
                    ]
                }

                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "4 · Just words"
                    rows: [
                        { label: "in engine/src/", value: "home-manager switch",
                          source: "a sentence costs ~15 minutes",
                          what: "Panel and stat explanations, and every \
action's title, why and snippet. They are Rust string literals.",
                          why: "Same recipe as any other engine change, \
because that is where they live - the cost has nothing to do with the size \
of the edit." },
                        { label: "in qml/", value: "cargo build -p nixdash-ui",
                          source: "~1 minute",
                          what: "The chrome: InfoButton content in Main.qml \
and ActionsPanel, the subject headings, Config rows.",
                          why: "<b>The same sentence needs a different build \
depending on which file it lives in.</b> Reword the Rust one, rebuild the \
UI, see no change, and go hunting a bug that is not there." },
                        { label: "comments in qml/", value: "cargo test --all",
                          source: "four tests read qml/ as data",
                          what: "qml_info, qml_modals, info_length and api \
all scan the QML directory.",
                          why: "A comment can fail a test with no code \
changed, which is surprising the first time." }
                    ]
                }
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
                          source: "pinned by this Qt; see ~/Projects/qt6-wasm",
                          what: "The Emscripten version this Qt for \
WebAssembly was built against, read out of Qt's own CMake helpers rather \
than guessed.<br><br>\
<b>Emscripten</b> is the toolchain that compiles C and C++ to WebAssembly - \
<tt>emcc</tt> standing in for <tt>gcc</tt> or <tt>clang</tt>. It does more \
than translate the code: it supplies the things a desktop toolkit assumes \
are there and a browser tab does not have - a filesystem, a main loop, \
threads, and the glue that lets Qt behave as though an operating system \
were underneath it.",
                          why: "Qt for WebAssembly is built against ONE \
Emscripten release and pins it. Use a different one and the build usually \
gets as far as linking before it fails, with an undefined symbol or an ABI \
complaint - an error that names a symbol rather than a version, and sends \
you to read your own code first.<br><br>\
The same 4.0 series is usually tolerated; a different major is not.",
                          ifWrong: "<b>This row is not a comparison and not \
a fault.</b> It states what Qt wants, not what you have - nothing here \
checks your emsdk against it.<br><br>\
If yours differs, pin the nixpkgs carrying the matching emcc rather than \
overriding Qt's check: the warning is load-bearing. <i>Qt for wasm</i> \
above says which Qt this is, and both come from \
<tt>~/Projects/qt6-wasm</tt>." },
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

            // Full width, outside the grid, because the lines are the point
            // and they do not fit a third of the page: the longest is 111
            // characters. Putting them in
            // info panels was the other option and is worse - a command you
            // have to open a dialog to read is a command you retype from
            // memory instead.
            //
            // The boards above decide WHICH build; this one is the literal
            // form of each. They stay short on purpose, so the two are not
            // two copies of the same string.
            ConfigSection {
                id: commandLines
                width: parent.width
                height: commandLines.implicitHeight
                title: "The lines in full"
                what: "Each build above, as a line you can run as printed - \
no assembly from a value and a provenance line."
                why: "<tt>cargo build -p nixdash-ui</tt> alone fails: outside \
the dev shell it dies on \"Could not find Qt\", because QMAKE is only set \
inside it. The engine is the opposite - it needs no shell. That asymmetry is \
not visible in a column that has room for the command but not its \
prerequisite."
                ifWrong: "A path here is this machine's. The repository is at \
<tt>~/Projects/nixdash</tt>, and these assume the engine on :3100 is already \
running - which it is, if the app is drawing this."
                rows: [
                    { label: "this window", value: "cd ~/Projects/nixdash && nix develop --command bash -c 'cargo build -p nixdash-ui && ./target/debug/nixdash-ui'",
                      source: "3 · Draws something (twice) - builds and launches, seconds, against the running engine" },
                    { label: "browser UI", value: "cd ~/Projects/nixdash && nix develop .#wasm --command bash ui-wasm/build.sh",
                      source: "3 · Draws something (twice) - then ./ui-wasm/serve.sh, which serves :8099" },
                    { label: "a second engine", value: "cd ~/Projects/nixdash && cargo build -p nixdash-engine && NIXDASH_PORT=3199 ./target/debug/nixdash-engine",
                      source: "2 · Measures or decides - no dev shell needed; never takes :3100 from the service" },
                    { label: "install, user", value: "home-manager switch",
                      source: "1 · Changes what is installed - then the systemctl --user restart it prints" },
                    { label: "install, system", value: "sudo nixos-rebuild switch",
                      source: "1 · Changes what is installed - /etc/nixos; --flake is implied when its flake.nix exists" }
                ]
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
