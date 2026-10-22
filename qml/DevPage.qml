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

    /// Per-id run state for the board below: { running, ok, text, up }.
    ///
    /// `up` is only ever set from a probe of the port, never from the fact
    /// that a start was requested - a fork succeeding is not a server
    /// listening, and treating it as one is how a button comes to claim a
    /// start that did not happen.
    property var runState: ({})
    property string runResult: ""
    property bool runResultOk: true

    /// Which row's run the text above describes.
    ///
    /// One result, three tiles: without this every tile would print the
    /// outcome of a button pressed in another one, which reads as three
    /// things having happened.
    property string runResultId: ""

    /// The result text, but only for the tile that owns the id that ran.
    function resultFor(ids) {
        return ids.indexOf(root.runResultId) >= 0 ? root.runResult : ""
    }

    function setRun(id, st) {
        var next = {}
        for (var k in root.runState)
            next[k] = root.runState[k]
        next[id] = st
        root.runState = next
    }

    /// Ask the app to run one of the lines below.
    ///
    /// Posts the row's id and nothing else: what each id executes is fixed
    /// where the ids are defined, so no command travels over this.
    function runBuild(id) {
        root.setRun(id, { running: true, up: root.upNow(id) })
        root.runResult = ""
        var xhr = new XMLHttpRequest()
        xhr.open("POST", root.apiBase + "/api/builds/" + encodeURIComponent(id) + "/run")
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return
            root.applyReply(id, xhr)
        }
        xhr.send()
    }

    function stopBuild(id) {
        root.setRun(id, { running: true, up: root.upNow(id) })
        root.runResult = ""
        var xhr = new XMLHttpRequest()
        xhr.open("POST", root.apiBase + "/api/builds/" + encodeURIComponent(id) + "/stop")
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return
            root.applyReply(id, xhr)
        }
        xhr.send()
    }

    function upNow(id) {
        return root.runState[id] ? !!root.runState[id].up : false
    }

    /// Turn one reply into a sentence and a dot.
    ///
    /// Every branch here reports what was actually learned. A started server
    /// is reported from the probe in the reply, a held port says so rather
    /// than reading as a start, and a command that exited non-zero names its
    /// stderr - "it failed" on its own sends you to look for the reason in
    /// the terminal this was pressed to avoid.
    function applyReply(id, xhr) {
        var ok = false
        var text = ""
        var up = root.upNow(id)
        try {
            var d = JSON.parse(xhr.responseText)
            if (xhr.status === 200) {
                ok = d.ok
                if (d.stopped !== undefined) {
                    text = "stopped (pid " + d.stopped + ")"
                    up = false
                } else if (d.state !== undefined) {
                    // The daemon row. `state` is what the port said, which is
                    // the only thing that can tell a start from a squatter.
                    up = d.state.state === "running"
                    text = d.detail
                    if (d.state.state === "running")
                        text += " - built " + d.state.built
                            + (d.state.ours ? "" : ", started elsewhere")
                    else if (d.state.state === "foreign")
                        text += " - " + d.state.detail
                } else if (d.outcome !== undefined) {
                    var o = d.outcome
                    text = o.error ? o.error
                         : ok ? (o.stdout ? o.stdout : "done")
                         : "exit " + o.exit_code + (o.stderr ? ": " + o.stderr : "")
                } else {
                    // A window: started and let go, so there is a detail line
                    // and no exit code to wait for. A restart may never get
                    // this far - the window reading it is one of the ones it
                    // just closed.
                    text = d.detail ? d.detail : (ok ? "started" : "nothing started")
                }
            } else {
                text = d.error ? d.error : ("HTTP " + xhr.status)
            }
        } catch (e) {
            text = xhr.status === 0 ? "the app's background service is unreachable"
                                    : "HTTP " + xhr.status
        }
        root.setRun(id, { running: false, ok: ok, text: text, up: up })
        root.runResult = text
        root.runResultOk = ok
        root.runResultId = id
        root.ranAction()
    }

    /// What is on the dev engine's port, asked of the port itself.
    ///
    /// Polled rather than remembered: an engine started from a terminal is as
    /// real as one started here, and one this app started outlives this app.
    /// Either way the honest answer comes from the port.
    function refreshBuilds() {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", root.apiBase + "/api/builds")
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE || xhr.status !== 200)
                return
            try {
                var d = JSON.parse(xhr.responseText)
                var prev = root.runState["dev-engine"] ? root.runState["dev-engine"] : {}
                if (prev.running)
                    return
                var st = { running: false, up: d.dev_engine.state === "running" }
                if (prev.text !== undefined) {
                    st.text = prev.text
                    st.ok = prev.ok
                }
                root.setRun("dev-engine", st)
            } catch (e) {
                // A malformed reply leaves the previous state alone rather
                // than reporting the engine as stopped, which would be a
                // reading taken from a parse failure.
            }
        }
        xhr.send()
    }

    Component.onCompleted: root.refreshBuilds()

    Timer {
        interval: 15000
        running: true
        repeat: true
        onTriggered: root.refreshBuilds()
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
                text: "Development"
                font.bold: true
                font.pixelSize: 18
            }

            SelectableText {
                width: parent.width
                wrapMode: TextEdit.Wrap
                font.pixelSize: style.fontBody
                text: "What is compiled, and whether it matches the source "
                    + "on disk. Three programs, not one: this window, the "
                    + "same interface compiled to WebAssembly for a browser "
                    + "tab, and the background service both of them read. "
                    + "Each is built on its own, so any of them can be a "
                    + "different build from the others - which is the usual "
                    + "reason a change you just made does not show up. Drag "
                    + "across the rows to select what you drag, Ctrl+A for a "
                    + "whole section, or Ctrl+Shift+C to copy the section "
                    + "under the pointer as tab-separated text."
            }

            // Which change needs which build, as reference rather than
            // reading: the rows below are static, not measured. They sit
            // ABOVE the measured boards deliberately - "what do I run" is
            // the question you arrive with, and "is it stale" is the one
            // you check afterwards.
            //
            // Ordered the way the builds have to happen: installed, then
            // service, then window. The long form is ~/docs/build2.md.
            //
            // Four columns rather than the three the other grids use, because
            // this grid holds exactly four sections and they are a sequence:
            // 1, 2, 3, 4 read as steps, and at three columns step 4 dropped
            // onto a row of its own, below a wide gap, where it read as an
            // afterthought instead of the fourth of four. The ladder is 4, 2,
            // 1 for the same reason - every rung divides four evenly, so no
            // width leaves a short last row.
            GridLayout {
                width: parent.width
                columns: root.width >= 1500 ? 4 : (root.width >= 900 ? 2 : 1)
                columnSpacing: 14
                rowSpacing: 14

                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "1 · Changes what is installed"
                    what: "<b>Installed means in a generation</b> - a built, \
switched-in copy. An edit to any of these files changes nothing at all until \
a switch makes a new one."
                    why: "<b>Two different commands both say switch.</b> \
<tt>sudo nixos-rebuild switch</tt> reads <tt>/etc/nixos</tt>; \
<tt>home-manager switch</tt> reads your own config and needs no root. \
Neither reports having been the wrong one: it rebuilds, succeeds, and your \
change is still not there."
                    ifWrong: "The rows are keyed by <i>where the file is</i>, \
not by what it configures. If you do not know where a setting lives, the \
Config page prints the file under each reading, on the ↳ line - and that \
file picks the row."
                    rows: [
                        { label: "/etc/nixos", value: "sudo nixos-rebuild switch",
                          source: "the machine itself - needs root",
                          what: "System configuration: the kernel, services, \
users, anything outside your own session.",
                          why: "<tt>home-manager switch</tt> cannot apply it \
and will not say so - it rebuilds, succeeds, and the change is still not \
there.",
                          ifWrong: "nixdash never needs this for itself. It \
appears as the config-drift action when something under /etc/nixos is newer \
than the running system." },
                        { label: "~/.config/home-manager", value: "home-manager switch",
                          source: "your session - no root",
                          what: "Your user environment, declared outside this \
repository: home.nix and the modules it imports.",
                          why: "The half of the machine that is yours - \
packages, user services, the panel. nixdash's own module is imported from \
here, which is why this command installs nixdash too.",
                          ifWrong: "It prints a <tt>systemctl --user \
restart</tt> rather than running it, and a changed service keeps serving the \
old binary until you run it." },
                        { label: "nix/, flake.nix", value: "home-manager switch",
                          source: "nixdash itself - engine, UI, launcher, unit",
                          what: "What installed means for nixdash: the engine \
and UI packages, the launcher, and the service unit.",
                          why: "The same command as the row above, because \
one switch builds both: your config imports this repo's module by path.",
                          ifWrong: "A launcher or menu change also needs \
<tt>xfce4-panel -r</tt>. New entries are not drawn live." },
                        { label: "a devShell", value: "neither",
                          source: "not installed - exit and re-enter nix develop",
                          what: "A package or variable that exists only \
inside <tt>nix develop</tt>: lld, the Qt environment, anything under \
<tt>devShells</tt> in flake.nix.",
                          why: "<b>No switch will ever apply it.</b> This is \
the answer people pay fifteen minutes to learn, by switching for a setting \
that was never installed in the first place.",
                          ifWrong: "Leave the shell and enter it again. If a \
reading still disagrees with the file, the shell you are in predates the \
change." }
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
                        { label: "many qml/ edits", value: "just watch-desktop",
                          source: "rebuilds and relaunches on save - ~2 min each",
                          what: "Watches qml/ and, on every change, rebuilds \
this window and relaunches it.",
                          why: "<b>The rebuild is not optional, which is the \
whole lesson of this row.</b> It used to only relaunch, with the QML read \
from disk - and that reads only Main.qml. Every other component comes from \
the copy compiled into the binary, so editing one and relaunching showed the \
PREVIOUS build, with no error anywhere. Hours went into \"the change is not \
showing\" before that was understood.",
                          ifWrong: "Measured at 2 minutes 15 seconds per save, \
because the whole UI crate relinks - a pane to glance at, not a loop to wait \
on. A failed build leaves the window you have alone and says so, rather than \
killing it for a typo.<br><br>\
A <b>new</b> .qml is the one thing that does load from disk, since the \
compiled module has no name to shadow - so it can render here while missing \
from both build.rs lists. <tt>just gate</tt> checks for that." },
                        { label: "qml/, ui/src/", value: "just desktop",
                          source: "wraps the dev shell, builds, relaunches",
                          what: "Anything this window renders.",
                          why: "QML is compiled INTO the binary, so the edit \
reaches you in two steps: build, then reopen. A window already running \
shows yesterday's UI indefinitely. <tt>just watch-desktop</tt> above is the \
loop that skips both.",
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
                        { label: "the browser UI", value: "just browser",
                          source: "the SAME qml/, a second program",
                          what: "One qml/ directory is compiled into two \
programs: this window and the browser UI. ui-wasm/build.sh builds the \
second.",
                          why: "<b>Nothing else builds it.</b> Not cargo \
build, not a switch. So every QML edit silently leaves the browser version \
behind - it keeps serving whatever was last compiled, which looks identical \
to working.<br><br>\
<tt>just watch-browser</tt> is this on a loop: it rebuilds on every save and \
prints each build in the terminal, and the served page reloads itself when \
one lands. Minutes per build, so it is a pane to glance at rather than wait \
on.",
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
                        { label: "in qml/", value: "just desktop",
                          source: "~1 minute",
                          what: "The chrome: InfoButton content in Main.qml \
and ActionsPanel, the subject headings, Config rows.",
                          why: "<b>The same sentence needs a different build \
depending on which file it lives in.</b> Reword the Rust one, rebuild the \
UI, see no change, and go hunting a bug that is not there." },
                        { label: "comments in qml/", value: "just gate",
                          source: "seven tests read qml/ as data",
                          what: "api, info_length, qml_board_refs, \
qml_colours, qml_command_lines, qml_info and qml_modals all scan the QML \
directory.",
                          why: "A comment can fail a test with no code \
changed, which is surprising the first time.",
                          ifWrong: "<tt>just gate</tt>, not <tt>cargo test \
--all</tt>: that one builds the UI crate, which needs Qt and the dev shell, \
so the slow gate would be running for the cheapest possible change. See \
<tt>just --list</tt>." }
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
            //
            // Titled "Commands" rather than "The lines in full": it stopped
            // being only lines when two of its rows became a recipe name and
            // a launch that builds nothing, and every row now carries a
            // button, so the board is the set of things this page can do.
            // One tile per thing being built, rather than one list of every command.
            //
            // The split is by WHAT IT PRODUCES: a window, a browser tab, or the
            // machine underneath both. That is the question you arrive with - the
            // old single list answered "which commands exist" instead, and the
            // browser build sat between two desktop ones with nothing saying they
            // were different programs.
            //
            // Still not a third of the page each for the long lines: `this window`
            // is 111 characters and `a second engine` 105, and both wrap here. They
            // stay selectable and copy whole, which is what the board is for - the
            // alternative was keeping one column and losing the grouping, and the
            // grouping is what someone arriving at this page actually needs.
            GridLayout {
                width: parent.width
                columns: root.width >= 1500 ? 3 : (root.width >= 900 ? 2 : 1)
                columnSpacing: 14
                rowSpacing: 14

                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "Desktop"
                    what: "The window you are looking at, and the three ways to put \
one on screen: build then launch, launch what is already built, or clear \
the stale ones away first."
                    why: "<b>Which build am I looking at is the expensive question \
here, and only one of these answers it.</b> <i>Run, no build</i> starts \
exactly what is in target/debug, so it reports what you HAVE; the row above \
it rebuilds first, so it cannot."
                    ifWrong: "A window never picks up a new build in place, so after \
any build the one in front of you is the old one - and two windows from \
different builds are identical on screen. That is what <i>fresh window</i> \
is for.<br><br>\
A path here is this machine's, the repository at <tt>~/Projects/nixdash</tt>. \
<tt>just</tt> is not on PATH outside the dev shell, so the one recipe-named \
row needs <tt>nix develop --command just fresh</tt> from an ordinary \
terminal; the rest need nothing but a path."
                    sections: [
                        { title: "What a recipe is", body: "A <b>recipe</b> is a named \
command kept in this project's <tt>Justfile</tt> - the same idea as a target \
in a Makefile, or a script in a package.json.<br><br>\
<tt>just browser</tt> runs the recipe named <tt>browser</tt>, which holds \
<tt>nix develop .#wasm --command bash ui-wasm/build.sh</tt>. \
<tt>just --list</tt> prints every one of them with a line of \
description.<br><br>\
They exist so a long command line lives in exactly one place. That is also \
what lets these boards be checked: a test reads the rows against the \
Justfile, so a line printed here and the recipe it names cannot drift apart. \
The <i>just file</i> link below opens the file itself." }
                    ]
                    runState: root.runState
                    resultText: root.resultFor(["desktop-ui", "open-window", "restart-window"].map(String))
                    resultOk: root.runResultOk
                    onRunRequested: function(id) { root.runBuild(id) }
                    onStopRequested: function(id) { root.stopBuild(id) }
                    onLinkActivated: function(id) { if (id === "justfile") root.showJustfile() }
                    rows: [
                        { label: "this window", value: "cd ~/Projects/nixdash && nix develop --command bash -c 'cargo build -p nixdash-ui && ./target/debug/nixdash-ui'",
                          source: "3 · Draws something (twice) - builds and launches, seconds, against the running engine",
                          buildId: "desktop-ui", runLabel: "Build",
                          what: "Build compiles the window. It does NOT launch it - the \
    line shown ends by starting the binary, and the button stops one step short, \
    leaving you to open it when you want it.",
                          why: "<b>A window is yours to open.</b> Launching it from \
    here would also hold this request until you closed it again, because the app \
    waits for what it starts in order to report how it went.",
                          ifWrong: "Outside the dev shell this build cannot work at \
    all - it dies on \"Could not find Qt\", because QMAKE is only set inside it - \
    which is why the button runs it through <tt>nix develop</tt> rather than \
    bare. Seconds, normally; the first build after a Qt change is not." },
                        { label: "run, no build", buildId: "open-window", runLabel: "Open", value: "cd ~/Projects/nixdash && ./target/debug/nixdash-ui",
                          source: "builds NOTHING - starts whatever is already in target/debug",
                          what: "Starts the binary sitting in target/debug, as it \
    stands. The only line here that compiles nothing, so a stale binary starts \
    stale - which is the point: it shows you what you actually have rather than \
    making a new one.",
                          why: "<b>Which build am I looking at is the expensive \
    question in this project, and nothing else on this page answers it.</b> The \
    panel icon can be pinned to a fixed store path and keep starting one build \
    for ever; the installed window and this one are indistinguishable on screen; \
    and the row at the top rebuilds first, so it cannot tell you what you had. \
    Naming the path leaves nothing to resolve.<br><br>\
    <b>Open</b> starts it from here, which is the one launch this page does. It \
    is let go rather than waited for - a window outlives the request that started \
    it - so the reply says a process started and nothing about what is drawn. \
    Whether a window actually appeared is a reading only you can take.",
                          ifWrong: "<b>No NIXDASH_QML_DIR here, deliberately.</b> \
    It redirects Main.qml and nothing else, so on any other component it shows the \
    previous build with no error anywhere - hours were lost to exactly that. A \
    component edit needs the first row.<br><br>\
    It talks to the app's service on :3100 unless you put <tt>NIXDASH_PORT=</tt> \
    in front, so a build with newer readings than that service can answer will \
    show them as unavailable. The build date in About is how you confirm which \
    one you got.<br><br>\
    <tt>just fresh</tt> is the row below: the same launch, with the stale windows \
    closed first." },
                        { label: "fresh window", buildId: "restart-window", runLabel: "Restart", value: "just fresh",
                          source: "closes every nixdash window, then starts the built one",
                          linkText: "just file", linkId: "justfile",
                          what: "Closes every window it can account for - naming \
    each, including one still running a build that has since been replaced - and \
    then starts the binary in target/debug. It builds nothing, exactly like the \
    row above.",
                          why: "<b>Restart closes the window you pressed it in.</b> \
    So do not wait for a result here: the new window IS the result, and this one \
    will be gone. It starts the new window FIRST and closes the old ones only \
    once it has survived a moment - the other order leaves you with no window at \
    all when the start fails, and no window is also where the error would have \
    been.<br><br>\
    <b>A window cannot pick up a new build in place.</b> \
    So after any build the window in front of you is the old one, and two windows \
    from different builds are indistinguishable on screen - which is how an \
    afternoon goes into reading the wrong one. This is the find-the-pid, kill it, \
    launch again sequence as one line.",
                          ifWrong: "It will <b>not</b> kill a watch loop, whatever \
    holds :3100, or a second engine on :3199. Each of those is something you \
    started deliberately, so they are reported instead.<br><br>\
    This is the one line here that needs <tt>just</tt>, which is why it is shown \
    as a recipe name rather than in full - there is no single line to paste. And \
    <b>just is not on PATH outside the dev shell</b>, so from an ordinary terminal \
    it is <tt>nix develop --command just fresh</tt>. Anywhere inside the \
    repository will do; just finds the Justfile by searching upward.<br><br>\
    The row above needs nothing but the path - verified with the Qt environment \
    stripped, on a display of its own: the binary finds its own plugins, so that \
    line really does work from a bare shell." }
                    ]
                }

                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "Browser"
                    what: "The same <tt>qml/</tt> compiled to WebAssembly and served \
to a browser tab. A second program, built by nothing else."
                    why: "<b>Not <tt>cargo build</tt>, and not a switch.</b> Only this \
builds it, so every QML edit leaves the tab serving whatever was last \
compiled - which looks identical to working. The Qt for WebAssembly board \
above is what tells you, naming the file that is ahead of the bundle."
                    ifWrong: "Minutes, and a separate toolchain. Serving is a separate \
step: <tt>just serve</tt> puts the built bundle on :8099, and \
<tt>just watch-browser</tt> does both on every save."
                    runState: root.runState
                    resultText: root.resultFor(["browser-ui"].map(String))
                    resultOk: root.runResultOk
                    onRunRequested: function(id) { root.runBuild(id) }
                    onStopRequested: function(id) { root.stopBuild(id) }
                    onLinkActivated: function(id) { if (id === "justfile") root.showJustfile() }
                    rows: [
                        { label: "browser UI", value: "cd ~/Projects/nixdash && nix develop .#wasm --command bash ui-wasm/build.sh",
                          source: "3 · Draws something (twice) - then ./ui-wasm/serve.sh, which serves :8099",
                          buildId: "browser-ui", runLabel: "Build",
                          what: "Recompiles the shared QML to WebAssembly. Build does \
    the build only; the serve step the line ends with is not started.",
                          why: "Serving would hold a port and this request with it. \
    The build is the part that goes stale - the browser version keeps serving \
    whatever was last compiled into it, which looks identical to working.",
                          ifWrong: "Several minutes, and a separate toolchain: if \
    it fails at once complaining about a missing wasm toolchain, that dev shell \
    did not activate. Nothing is lost by not running it unless you are using the \
    browser UI today.",
                          sections: [
                              { title: "Building on every save", body: "\
    <tt>just watch-browser</tt> is this same build on a loop: it watches \
    <tt>qml/</tt>, rebuilds whenever you save, prints each build in the terminal, \
    and the served page reloads itself when one lands.<br><br>\
    <b>Saving during a build queues one more build - not one per save.</b> The \
    loop compares only the newest timestamp under <tt>qml/</tt>, so a flurry of \
    edits made while a build is running is rolled together into a single rebuild \
    after it.<br><br>\
    Each build is minutes, so editing steadily gives you a rebuild every few \
    minutes, each carrying everything saved since the last. That is the loop \
    working, not a fault. If you would rather not have builds competing for \
    memory while you work, stop the loop, make the edits, and start it again for \
    one build at the end." }
                          ] }
                    ]
                }

                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "Machine"
                    what: "Everything that is not a frontend: the background service \
these windows read, and the two commands that install things."
                    why: "<b>Two different commands both say switch.</b> \
<tt>home-manager switch</tt> reads your own config and needs no root; \
<tt>sudo nixos-rebuild switch</tt> reads <tt>/etc/nixos</tt> and does. \
Neither reports having been the wrong one."
                    ifWrong: "A switch leaves the OLD service running until the restart \
it prints - it reports active and answers every request from the previous \
build. The second engine is how you test a change without waiting, and it \
never takes :3100 from the service."
                    runState: root.runState
                    resultText: root.resultFor(["dev-engine", "install-user", "install-system"].map(String))
                    resultOk: root.runResultOk
                    onRunRequested: function(id) { root.runBuild(id) }
                    onStopRequested: function(id) { root.stopBuild(id) }
                    onLinkActivated: function(id) { if (id === "justfile") root.showJustfile() }
                    rows: [
                        { label: "a second engine", value: "cd ~/Projects/nixdash && cargo build -p nixdash-engine && NIXDASH_PORT=3199 ./target/debug/nixdash-engine",
                          source: "2 · Measures or decides - no dev shell needed; never takes :3100 from the service",
                          buildId: "dev-engine", runLabel: "Start", stoppable: true,
                          what: "Starts a second engine on :3199 and leaves it \
    running, with its output in a log file the result line names - a process with \
    no terminal has nowhere else to put the reason it died. Start builds nothing: \
    it starts the binary as it stands, so a stale one starts stale.",
                          why: "<b>Started is not listening.</b> Every other button \
    here waits for its command and reports an exit code, but a server that exits \
    has failed. So this one reports what the port answered instead - the only \
    thing that can tell a start apart from a port that was already taken, and the \
    reply says which it was.",
                          ifWrong: "If something already holds :3199 then nothing \
    is started and it says so, naming what answered. Stop appears only while the \
    port is answering, and only this app can stop what it started - one started \
    from a terminal says so, and is stopped there with Ctrl-C.<br><br>\
    Never :3100. A second engine on the service's port makes the real one \
    crash-loop invisibly behind it while health checks keep answering, from the \
    squatter.",
                          sections: [
                              { title: "Why a probe", body: "A fork succeeding \
    means the process started, not that it bound the port. The two come apart \
    constantly here: the binary is missing because nothing built it, or :3199 is \
    still held by the engine you started an hour ago.<br><br>\
    So after starting it, the app asks :3199 what is there and reports that. \
    Three answers rather than two - nothing listening, this app's engine, or \
    something else entirely - because the middle and the last are what you need \
    to tell apart, and a button that reported only success or failure would show \
    the same green tick for both." },
                              { title: "Which build answered", body: "The reply \
    carries the build stamp of whatever is on the port, and the result line \
    prints it. That is the only way to tell two engines apart: the version number \
    is identical in every build ever made, so a stale engine and a fresh one look \
    the same everywhere else.<br><br>\
    It also says whether this app started it. After the background service \
    restarts, an engine you started earlier keeps running and is still reported - \
    honestly, as something this app no longer owns and will not stop." }
                          ] },
                        { label: "install, user", value: "home-manager switch",
                          source: "1 · Changes what is installed - then the systemctl --user restart it prints",
                          buildId: "install-user", runLabel: "Switch",
                          what: "Rebuilds everything home-manager manages and \
    switches to it - not only this project. Switch performs it and stops \
    there.",
                          why: "<b>The restart it prints is deliberately not run.</b> \
    A switch can legitimately fail, and restarting into a build that did not \
    happen is worse than leaving the old one serving. It also takes about fifteen \
    minutes, so it is never the way to see a change - the window build above is.",
                          ifWrong: "It builds your whole user config, so an \
    unrelated half-finished edit elsewhere fails the build - which leaves the \
    current generation untouched rather than breaking anything. A changed \
    background service keeps running the old build until the restart, which the \
    build-freshness board above reports." },
                        { label: "install, system", value: "sudo nixos-rebuild switch",
                          source: "1 · Changes what is installed - /etc/nixos; --flake is implied when its flake.nix exists",
                          buildId: "install-system", runLabel: "Switch",
                          what: "Builds and switches the system configuration from \
    /etc/nixos: the kernel, services, users - everything outside your own \
    session.",
                          why: "<b>This needs root, and the app has none of its \
    own.</b> It asks polkit, which puts a prompt in front of you, and that prompt \
    is the authorisation - not the button. The line shows <tt>sudo</tt> because \
    that is what you would type; sudo itself is never used here, as it wants a \
    terminal this app does not have.",
                          ifWrong: "Dismiss the prompt and it reports not \
    authorised rather than failing silently. With no polkit agent running there \
    is nothing to show a prompt, and it says so instead of waiting forever. \
    nixdash never needs this for itself." }
                    ]
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

    // The Justfile, fetched when asked for rather than compiled in.
    //
    // A recipe named on the Commands board and the recipe that actually runs
    // have to be the same thing, and a copy baked into this page would be one
    // more thing that can drift from it - which is the exact failure the
    // board's own test exists to catch. So this reads the file through the
    // app's service each time it is opened.
    property string justfileText: ""
    property string justfilePath: ""
    property string justfileError: ""

    function showJustfile() {
        root.justfileError = ""
        root.justfileText = ""
        justfileSheet.open()
        var xhr = new XMLHttpRequest()
        xhr.open("GET", root.apiBase + "/api/justfile")
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return
            if (xhr.status === 200) {
                var d = JSON.parse(xhr.responseText)
                root.justfilePath = d.path
                root.justfileText = d.text
            } else {
                // Say which failure it was. An unreadable file and an empty
                // one are different answers, and a blank panel would show
                // them as the same.
                root.justfileError = xhr.status === 0
                    ? "no answer from the app's service"
                    : "could not read it (" + xhr.status + ")"
            }
        }
        xhr.send()
    }

    Popup {
        id: justfileSheet
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(1000, root.width - 80)
        height: Math.min(760, root.height - 80)
        modal: true
        focus: true
        padding: 16

        ColumnLayout {
            anchors.fill: parent
            spacing: 8

            RowLayout {
                Layout.fillWidth: true
                SelectableText {
                    text: "Justfile"
                    font.bold: true
                    font.pixelSize: 15
                }
                Item { Layout.fillWidth: true }
                CloseX { onClicked: justfileSheet.close() }
            }

            // The path, because which file this is matters as much as what
            // is in it - the service resolves it from NIXDASH_REPO or your
            // home directory, and those can disagree with the tree you are
            // editing.
            SelectableText {
                Layout.fillWidth: true
                visible: root.justfilePath !== ""
                text: root.justfilePath
                font.pixelSize: style.fontBody
                color: style.textMuted
                wrapMode: TextEdit.Wrap
            }

            SelectableText {
                Layout.fillWidth: true
                visible: root.justfileError !== ""
                text: "✗ " + root.justfileError
                font.pixelSize: style.fontBody
                color: style.badText
                wrapMode: TextEdit.Wrap
            }

            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true

                SelectableText {
                    width: justfileSheet.availableWidth
                    text: root.justfileText === "" && root.justfileError === ""
                          ? "reading…" : root.justfileText
                    font.family: "monospace"
                    font.pixelSize: style.fontBody
                    wrapMode: TextEdit.Wrap
                }
            }
        }
    }
}
