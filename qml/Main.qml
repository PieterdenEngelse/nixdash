import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import nixdash

// Shell: owns the data and the navigation state. The pages below are
// presentational - they receive data as properties and emit navigation
// requests, which keeps fetching in one place instead of three.
ApplicationWindow {
    id: root
    // The size the window returns to when un-maximised, not the size it
    // opens at - see `visibility` below.
    width: 820
    height: 700
    visible: true
    title: "nixdash"

    /// Size for the header's chrome text: the three tabs, the About link
    /// beside them, and the version string at the far end.
    ///
    /// It was `root.font.pixelSize + 6` - the inherited platform font plus an
    /// offset - and that is exactly the thing that cannot be inherited here,
    /// because the browser build has no desktop to inherit from. `Style`
    /// carries the number and the measurements; this name is what the five
    /// use sites below read.
    readonly property int chromeFont: style.fontChrome

    // Every colour in the app comes from here. Not a singleton: cxx-qt 0.10
    // cannot register one, so each component instantiates its own - see
    // Style.qml.
    Style { id: style }

    /// Reach the palette through this inside a Text or a Label.
    ///
    /// Both derive from QQuickText, which carries its OWN `style` property -
    /// the Normal/Outline/Raised enum - and it shadows the id above. Written
    /// inside one, `style.fontBody` resolves to that enum, yields undefined,
    /// and the binding silently keeps its default instead of erroring.
    /// TextEdit and TextInput have no such property, so SelectableText is
    /// unaffected; this is only Text and Label. Enforced by
    /// engine/tests/qml_text_style.rs, because nothing else catches it.
    readonly property var theme: style

    // A dark scheme chosen outright, rather than inherited from the desktop.
    //
    // It used to read the system palette and then paint tiles with
    // light-assuming literals (#fcf8e3, #fdecea), which looked fine only
    // because the session theme happened to be light - under a dark one the
    // app became dark chrome with pale islands in it.
    //
    // Fusion is set in main.rs before the engine starts. It is the built-in
    // style that takes its colours from the palette, so setting it here
    // reaches every button, switch, tab and combo box without styling them
    // one at a time.
    palette.window: style.window
    palette.base: style.surface
    palette.alternateBase: style.surfaceAlt
    palette.text: style.text
    palette.windowText: style.text
    palette.buttonText: style.text
    palette.button: style.surfaceAlt
    palette.mid: style.border
    palette.midlight: style.borderSoft
    palette.dark: style.window
    palette.light: style.surfaceAlt
    palette.highlight: style.link
    palette.highlightedText: style.window
    palette.link: style.link
    palette.linkVisited: style.linkHover
    palette.placeholderText: style.textMuted
    palette.toolTipBase: style.surfaceAlt
    palette.toolTipText: style.text

    // Opens filling the screen.
    //
    // Maximized, NOT FullScreen. True fullscreen drops the title bar and
    // covers the panel, which leaves no visible way to close, move or get
    // past the window - a poor default for something you open to glance at
    // and then leave. F11 below gives you the real thing when you want it,
    // which is the usual place to look for it.
    visibility: Window.Maximized

    Shortcut {
        sequences: [ "F11" ]
        onActivated: root.visibility =
            root.visibility === Window.FullScreen ? Window.Maximized
                                                  : Window.FullScreen
    }
    // Escape only ever leaves fullscreen - it must not close the window, or
    // a stray keypress loses the window you just opened.
    Shortcut {
        sequences: [ "Escape" ]
        enabled: root.visibility === Window.FullScreen
        onActivated: root.visibility = Window.Maximized
    }

    // Ctrl+C and Ctrl+A act on the focused value, explicitly rather than by
    // leaving either to that item's own key handling. Every value here is a
    // READ-ONLY TextEdit, and a read-only TextEdit leaves selectByKeyboard
    // false - the state in which both keys do nothing at all.
    //
    // selectByKeyboard: true would have enabled both natively, at the price
    // of a blinking text cursor sitting in whichever value was last clicked.
    // In a window whose values are all read-only readings, a cursor says
    // "type here", so these two shortcuts buy the same behaviour without it.
    //
    // One Shortcut each for the whole window, not one per panel: two enabled
    // shortcuts on the same sequence are ambiguous and then NEITHER fires,
    // which is the same trap that makes Ctrl+Shift+C scope itself to the
    // pointer instead.

    /// The focused item, when it is a text item with a selection to act on.
    ///
    /// Duck-typed on purpose. activeFocusItem is typed QQuickItem, so qmllint
    /// reports selectedText, copy and selectAll as missing from it - the same
    /// complaint it makes about SelectableText's walk for a Flickable, and
    /// the same answer: QML resolves all three at runtime, a text item
    /// answers and anything else does not. Do not "fix" the warnings by
    /// dropping the probes; the probes are the guard.
    ///
    /// An editable field satisfies it too, so the port spinner keeps behaving
    /// the way its own Ctrl+C and Ctrl+A would.
    function focusedText() {
        var it = root.activeFocusItem
        // qmllint disable missing-property
        // Probing, not accessing: activeFocusItem is a plain Item until it
        // turns out to be a text one, which is the whole question here.
        return it && it.selectedText !== undefined
               && typeof it.copy === "function"
               && typeof it.selectAll === "function" ? it : null
        // qmllint enable missing-property
    }

    Shortcut {
        sequences: [ "Ctrl+C" ]
        onActivated: {
            // The live selection, not a remembered string: this copies what
            // is selected now.
            var t = root.focusedText()
            if (t && t.selectedText.length > 0)
                t.copy()
        }
    }

    // Selects the whole of ONE value - the one last clicked - because that is
    // as far as a selection reaches here: each reading is its own text item.
    // Ctrl+Shift+C remains the gesture for a whole pane.
    //
    // Deliberately does not copy. Dragging copies because releasing a drag is
    // an unambiguous "I want this"; Ctrl+A is the ordinary prelude to Ctrl+C
    // and in every other application leaves the clipboard alone, so making it
    // write would be a surprise that costs you what you had copied.
    Shortcut {
        sequences: [ "Ctrl+A" ]
        onActivated: {
            var t = root.focusedText()
            if (t)
                t.selectAll()
        }
    }

    /// Actions the Dev page owns, by id.
    ///
    /// Split by id rather than by subject: `subject` says which of the three
    /// things an action is ABOUT, which is not the same question as which
    /// page can act on it. Rebuilding the browser UI and filling in the dev
    /// shell belong beside the readings they change; a reboot or a garbage
    /// collection does not, however Rust-flavoured its id looks.
    ///
    /// Listed explicitly so a new action shows up on Config by default. The
    /// wrong page is a nuisance; a new action appearing on NO page would be
    /// invisible, which is worse.
    readonly property var devActionIds: [
        "rebuild-wasm-ui",
        "rust-emscripten-target",
        "rust-lld",
        "rust-src-missing",
        "qt-merged-prefix"
    ]

    function devActions() {
        return root.actions.filter(function(a) {
            return root.devActionIds.indexOf(a.id) !== -1
        })
    }

    function machineActions() {
        return root.actions.filter(function(a) {
            return root.devActionIds.indexOf(a.id) === -1
        })
    }

    // Rust supplies the engine's address; see ui/src/cxxqt_object.rs.
    Dash { id: dash }

    // ---- data ----------------------------------------------------------
    property bool engineUp: false
    property string lastError: ""
    property var panels: []          // raw summaries from the engine
    property var actions: []
    property var actionErrors: []
    property var memoryHistory: []

    // ---- navigation ----------------------------------------------------
    // Two levels is the whole hierarchy: a top tab, and optionally one
    // subject drilled into. A router would be structure for its own sake.
    /// The build stamp actually shown, and whether it is the real thing.
    ///
    /// Three sources, best first:
    ///
    ///   the bundle's Last-Modified   browser, asked of the server
    ///   this binary's own mtime      desktop, read by Rust
    ///   the build script's run       neither was available
    ///
    /// The last is what `build.rs` bakes in, and it is the START of a build:
    /// a build script runs before anything is compiled. For the window that
    /// is about two minutes early; for the browser bundle, six to eight. A
    /// fresh build reading as stale is how this came up.
    /// Bindings, not assignments: `panels` is replaced every two seconds,
    /// so the browser's answer arrives on a later poll than the first paint
    /// and has to be picked up when it does.
    property string builtShown: {
        var served = root.servedBundleBuilt()
        return served !== "" ? served : dash.built
    }
    property bool builtIsExact: dash.builtExact || root.servedBundleBuilt() !== ""

    /// When the bundle being served was built, or "" if that is not known.
    ///
    /// Browser only. The first attempt at this asked the SERVER directly -
    /// a HEAD on `nixdash_ui_wasm_app.wasm`, reading `Last-Modified`. That
    /// works perfectly in the desktop build against the same server, and
    /// did nothing at all in the browser: the stamp stayed at the baked-in
    /// 13:43 for a bundle built at 13:47.
    ///
    /// A relative URL in QML resolves against the QML document's own base,
    /// which in a wasm build is `qrc:/qt/qml/nixdash/` and not the page's
    /// origin - so the request went somewhere that does not exist. The
    /// desktop test passed because it used an absolute URL.
    ///
    /// This asks the app's service instead, which already measures that
    /// file's mtime and which every other reading on screen comes from. No
    /// second mechanism, no URL to resolve, and it is the one request shape
    /// known to work in both halves.
    function servedBundleBuilt() {
        if (!dash.browser)
            return ""
        var m = root.panels.filter(function(x) { return x.id === "qt-wasm" })
        if (m.length === 0 || !m[0].latest)
            return ""
        var at = m[0].latest.value.built_at
        if (!at)
            return ""
        return Qt.formatDateTime(new Date(at * 1000), "yyyy-MM-dd hh:mm")
    }

    property string tab: "monitor"   // "monitor" | "config"
    property string subject: ""      // "" = overview; else nixos|qt|rust

    /// A third level, under a subject. Only Dev > Qt has any.
    ///
    /// The note above used to say two levels were the whole hierarchy and a
    /// router would be structure for its own sake. That held while every
    /// subject was a set of panels. Dev > Qt is a teaching path now - "why
    /// there is no single Qt" is a page, not a panel - and flattening those
    /// into siblings of Qt would have the trail say you are somewhere you
    /// are not.
    ///
    /// Cleared whenever the level above it changes.
    property string topic: ""

    // Display names for the breadcrumb. MonitorPage and SubjectPage each
    // carry their own copy for their own labels; this is the third and the
    // one the header reads.
    readonly property var subjectNames: ({
        "nixos": "NixOS",
        "qt": "Qt",
        "rust": "Rust"
    })

    function panelsFor(subj) {
        return panels.filter(function(p) { return p.subject === subj })
    }
    function actionsFor(subj) {
        return actions.filter(function(a) { return a.subject === subj })
    }
    function actionCount(subj) {
        return actionsFor(subj).length
    }

    function getJson(path, onOk) {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", dash.apiBase + path)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return
            if (xhr.status === 200) {
                root.engineUp = true
                root.lastError = ""
                try { onOk(JSON.parse(xhr.responseText)) }
                catch (e) { root.lastError = "bad response: " + e }
            } else {
                root.engineUp = false
                root.lastError = xhr.status === 0
                    ? "engine unreachable at " + dash.apiBase
                    : "HTTP " + xhr.status
            }
        }
        xhr.send()
    }

    function refresh() {
        getJson("/api/panels", function(d) { root.panels = d.panels })
        getJson("/api/actions", function(d) {
            root.actions = d.actions
            root.actionErrors = d.errors
        })
        // Only needed by the memory panel's sparkline; ~3 minutes at 2s.
        getJson("/api/panels/memory?limit=90", function(d) {
            root.memoryHistory = d.samples
        })
    }

    Component.onCompleted: {
        // One handler, not two: QML allows a property to be assigned once,
        // and a second `Component.onCompleted` is "Property value set
        // multiple times" - a BUILD error from the qml compiler, which the
        // condensed build output then hid behind a successful-looking line.
        refresh()
    }
    Timer { interval: 2000; running: true; repeat: true; onTriggered: root.refresh() }

    /// The subpages of a tab, as { id, name }. `id` is what `subject`
    /// becomes; "" is the tab's own page.
    ///
    /// Only Dev has any. Monitor's three subjects are reached from cards on
    /// its overview, which is a different gesture for a different thing -
    /// those are readings you pick between, and this is one page that sits
    /// under another.
    readonly property var devSubpages: [
        { "id": "", "name": "Overview" },
        { "id": "qt", "name": "Qt" }
    ]

    /// The topics under Dev > Qt. Each is a page of its own.
    readonly property var qtTopics: [
        { "id": "", "name": "Overview" },
        { "id": "prefix", "name": "Why there is no single Qt" },
        { "id": "wasm", "name": "Two Qts, and the Emscripten between them" },
        { "id": "rust", "name": "QML meets Rust" },
        { "id": "symptoms", "name": "When it breaks" }
    ]

    /// A topic's display name, for the trail.
    function topicName(id) {
        var m = root.qtTopics.filter(function(t) { return t.id === id })
        return m.length > 0 ? m[0].name : id
    }

    /// The children of the page you are ON - which is what the strip offers.
    ///
    /// Not "the subpages of the tab": standing on Dev > Qt, the useful list
    /// is Qt's topics. One strip that always shows where you can go from
    /// here beats two, one of which is usually stale.
    function childrenHere() {
        if (root.tab !== "dev")
            return []
        return root.subject === "qt" ? root.qtTopics : root.devSubpages
    }

    function childHere() {
        return root.subject === "qt" ? root.topic : root.subject
    }

    function goChild(id) {
        if (root.subject === "qt")
            root.topic = id
        else {
            root.subject = id
            root.topic = ""
        }
    }

    function subpagesFor(t) {
        return t === "dev" ? root.devSubpages : []
    }

    header: Column {
    ToolBar {
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 6

                // Both header Buttons carry the size explicitly for the reason
                // Style.fontChrome documents: a Control with no font of its own
                // takes the platform's, and the browser build has no platform to
                // take it from - this one rendered at 10px on the desktop and
                // 16px in the tab.
                Button {
                    text: "‹"
                    visible: root.subject !== ""
                    flat: true
                    font.pixelSize: root.chromeFont
                    onClicked: root.subject = ""
                }

                SelectableText {
                    text: "nixdash"
                    font.bold: true
                    font.pixelSize: 15
                }

                // The window's own behaviour, including the two keyboard
                // shortcuts. A shortcut with no visible control is undiscoverable
                // by definition, so this is the affordance F11 would otherwise
                // not have.
                InfoButton {
                    title: "This window"
                    what: "Opens maximised, filling the screen below your panel. \
    <b>F11</b> switches to true fullscreen - no title bar, covering the panel - \
    and F11 or <b>Escape</b> comes back. Closing the window does not stop \
    monitoring.<br><br>\
    Every value in this window is <b>selectable</b>, and selecting <b>copies</b>: \
    letting go of a drag puts that text on the clipboard, so <tt>Ctrl+V</tt> \
    pastes it anywhere. <tt>Ctrl+C</tt> copies the selection again if you would \
    rather use the keystroke. A click selects nothing and deliberately leaves the \
    clipboard alone, so reading a value by tapping it cannot cost you what you \
    had copied. On this desktop a <i>dragged</i> value also lands on the X11 \
    primary selection, so a <b>middle-click</b> pastes it without either.<br><br>\
    <tt>Ctrl+A</tt> selects the whole of the value you last clicked, ready for \
    <tt>Ctrl+C</tt>; unlike dragging, it does not copy on its own.<br><br>\
    A selection cannot cross from one value into the next, so for a whole panel \
    at once, point at it and press <b>Ctrl+Shift+C</b> - that copies the pane \
    under the pointer as tab-separated text."
                    why: "The engine is a separate background service that keeps \
    sampling whether or not a window is open, so closing this loses nothing but \
    the view. Maximised rather than fullscreen by default because fullscreen \
    hides the title bar, leaving no visible way to close or move the window - a \
    poor default for something you open to glance at."
                    ifWrong: "<ul>\
    <li><b>Something you copied here vanished.</b> On this desktop the clipboard \
    is held by the program that filled it, and nothing is running to outlive it - \
    no clipboard manager. Closing this window therefore empties whatever you \
    copied from it, with no error anywhere. Paste it before you close the window; \
    the primary selection goes the same way for the same reason.</li>\
    <li><b>Ctrl+Shift+C did nothing.</b> The pointer was not over a panel. It \
    copies the pane you are pointing at, so there is no ambiguity about which \
    one you meant.</li>\
    <li><b>Ctrl+A or Ctrl+C did nothing.</b> Both act on the value you last \
    clicked, and in a window you have only just opened that is nothing at all. \
    Click a value first - a single click selects nothing and copies nothing, it \
    only decides what the keys apply to.</li>\
    <li><b>A dragged selection stops at the end of a value.</b> Expected. Each \
    reading is its own piece of text - which is what lets each one carry its own \
    info button - and Qt shares a selection only inside one piece. Ctrl+Shift+C \
    is the gesture for more than one.</li>\
    <li><b>Middle-click pastes something older.</b> The primary selection holds \
    whatever was selected <i>last</i>, anywhere on the desktop - selecting in \
    another window replaces it. In the browser build there is no primary \
    selection at all, so there use Ctrl+C or Ctrl+Shift+C.</li>\
    <li><b>F11 does something unexpected.</b> On this machine the key marked \
    PrtScrn reports itself as F11, so pressing it here toggles fullscreen rather \
    than taking a screenshot.</li>\
    <li><b>The window seems stuck covering everything.</b> Press Escape.</li>\
    <li><b>It opens small.</b> You are running an older build - see Refresh \
    &rarr; Deploying.</li></ul>"
                    sections: [
                        { title: "The two windows", body: "\
    This is the <b>desktop</b> build: Rust and Qt/QML compiled natively, talking \
    to the engine over loopback HTTP.<br><br>\
    There is a second one. The same QML is compiled to \
    <a href='https://webassembly.org/'>WebAssembly</a> and runs in a browser, \
    served from another loopback port. Both read the same engine, so they always \
    agree - and they are built from one <tt>qml/</tt> directory, symlinked into \
    each crate rather than copied, so an edit reaches both.<br><br>\
    They differ only in how they are built: the desktop one is pure Cargo, the \
    browser one needs CMake, corrosion, and a Qt cross-compiled for Emscripten. \
    That second toolchain is the reason the Qt and Rust panels exist at all - \
    every trap in getting it working is a value one of them now reports.<br><br>\
    See <a href='https://doc.qt.io/qt-6/'>the Qt 6 documentation</a>." },
                        { title: "Privacy", body: "\
    <ul>\
    <li><b>Loopback only.</b> The engine binds <tt>127.0.0.1</tt> \
    unconditionally - it is not a setting. It has no authentication and no TLS, \
    so it must never be reachable from anywhere else.</li>\
    <li><b>No accounts, no telemetry, no network calls.</b> Every panel reads \
    local state: <tt>/proc</tt>, <tt>systemctl</tt>, \
    <tt>/nix/var/nix/profiles</tt>, <tt>statvfs</tt>, <tt>qmake</tt>, \
    <tt>rustc</tt>. Nothing is sent anywhere and the engine fetches \
    nothing.</li>\
    <li><b>No stored data.</b> History lives in memory and is lost on \
    restart.</li>\
    <li><b>No privilege of its own.</b> It runs as you and reads only what you \
    could already read. It can start a privileged action, but only through a \
    polkit prompt you answer.</li>\
    </ul>\
    Links in these panels are the one exception: following one opens your \
    browser and contacts that site, like any other link." }
                    ]
                }

                TabBar {
                    id: tabs
                    Layout.leftMargin: 10
                    currentIndex: root.tab === "monitor" ? 0
                                : root.tab === "config"  ? 1 : 2
                    // onClicked per button, not onCurrentIndexChanged: clicking
                    // the tab you are already on must still return to its root,
                    // and an index that does not change fires no signal.
                    //
                    // 90 is the width the three have always had, and equal
                    // widths are the point of it - but as a floor now rather than
                    // a ceiling. Pinned, a tab clipped its own label the moment
                    // the text outgrew it: at the browser's 22px header "Monitor"
                    // rendered as "Moni...", in the one place that names what the
                    // tab does.
                    TabButton {
                        text: "Monitor"; width: Math.max(90, implicitWidth)
                        font.pixelSize: root.chromeFont
                        onClicked: { root.tab = "monitor"; root.subject = ""; root.topic = "" }
                    }
                    TabButton {
                        text: "Config"; width: Math.max(90, implicitWidth)
                        font.pixelSize: root.chromeFont
                        onClicked: { root.tab = "config"; root.subject = ""; root.topic = "" }
                    }
                    TabButton {
                        text: "Dev"; width: Math.max(90, implicitWidth)
                        font.pixelSize: root.chromeFont
                        onClicked: { root.tab = "dev"; root.subject = ""; root.topic = "" }
                    }
                }
                // Why there are two pages at all, and why one of them refuses to
                // let you type into it - which is the thing people expect and do
                // not get.
                InfoButton {
                    title: "Monitor and Config"
                    what: "Two questions asked at different times.<br><br>\
    <b>Monitor</b> answers <i>is anything wrong right now</i> - one card per \
    subject, each showing its unhappiest panel.<br>\
    <b>Config</b> answers <i>how is this set up, and what would I change</i> - \
    what is in effect, and which file declares it."
                    why: "A single grid gives every panel equal weight, so \
    <i>Qt prefix complete</i> and <i>disk at 95%</i> look identical until you \
    read both. Monitor exists so that most of the time you can read nothing and \
    move on."
                    ifWrong: "<b>Config is deliberately not a settings form.</b> \
    This machine is configured declaratively, so a field you could type into \
    would either write somewhere Nix later overwrites, or fight Nix outright - \
    either way lying about where configuration lives. It shows values, says which \
    file they come from, and hands you a snippet."
                    sections: [
                        { title: "The three subjects", body: "\
    Monitoring is split by subject because the questions are genuinely \
    different.<br><br>\
    <b>NixOS</b> - is this machine healthy? Memory and stall pressure, failed \
    units in both scopes, generations and whether a reboot is pending, free space \
    on the store's filesystem. Most of the actions live here, and they are the \
    ones that can be run.<br><br>\
    <b>Qt</b> and <b>Rust</b> - <i>will a build work in this environment?</i> \
    Not <i>is it installed</i>. That distinction is the whole point: a Qt prefix \
    can be present, correct and still missing the host tools <tt>cxx-qt</tt> \
    needs, because on NixOS <tt>qmltyperegistrar</tt> and <tt>qmlcachegen</tt> \
    live in qtdeclarative rather than qtbase - and the build fails late, naming \
    the tool rather than the prefix.<br><br>\
    Both describe the <b>engine's</b> environment, which is the background \
    service's - not whichever shell you are sitting in. A devShell with a \
    complete prefix will not change what those panels say. That is a real \
    limitation, stated plainly rather than papered over.<br><br>\
    References: <a href='https://nixos.org/manual/nixos/stable/'>NixOS \
    manual</a> &middot; <a href='https://doc.qt.io/qt-6/'>Qt 6</a> &middot; \
    <a href='https://doc.rust-lang.org/rustc/platform-support.html'>Rust \
    platform support</a>" }
                    ]
                }
                Item { Layout.fillWidth: true }

                // Right-aligned and clipped rather than elided-from-the-left:
                // TextEdit has no elide, and this keeps the tail visible exactly
                // as ElideLeft did, minus the ellipsis. Ctrl+A reaches the part
                // scrolled out of view, so the whole address or error can still
                // be copied.
                SelectableText {
                    text: root.engineUp ? dash.apiBase : root.lastError
                    color: root.engineUp ? palette.text : style.badDot
                    font.pixelSize: style.fontBody
                    horizontalAlignment: TextEdit.AlignRight
                    wrapMode: TextEdit.NoWrap
                    clip: true
                    Layout.maximumWidth: 260
                }

                Button { text: "Refresh"; font.pixelSize: root.chromeFont; onClicked: root.refresh() }
                // The name promises more than it does, so it needs saying: this
                // re-reads the engine, it does not re-measure the machine.
                InfoButton {
                    title: "Refresh"
                    what: "Re-fetches the engine's latest samples immediately. \
    This window already polls every 2 seconds, so mostly it saves you a short \
    wait."
                    why: "It does <b>not</b> make the engine re-measure \
    anything. Each panel is sampled on its own schedule by the background \
    service, and this button shows whatever that schedule last produced. A disk \
    figure can legitimately be half a minute old the instant after you press it."
                    ifWrong: "<ul>\
    <li><b>A value will not move.</b> Check its panel's interval below before \
    suspecting the engine - 60s panels look frozen next to a 2s one.</li>\
    <li><b>The address to the left is red.</b> The window is not reaching the \
    engine at all; nothing will update until it comes back. Check \
    <tt>systemctl --user status nixdash-engine</tt>.</li>\
    <li><b>Everything is stale after a rebuild.</b> A changed service keeps \
    running the old build until restarted - see the Deploying tab.</li></ul>"
                    sections: [
                        { title: "Sampling", body: "\
    Collection happens in the engine, not here. Each panel declares its own \
    interval, chosen against what the measurement costs:<br><br>\
    <ul>\
    <li><b>memory</b>, every 2s - two cheap reads of <tt>/proc</tt>; the only one \
    that moves fast enough to watch</li>\
    <li><b>failed-units</b>, every 15s - shells out to <tt>systemctl</tt> twice, \
    user and system scope</li>\
    <li><b>disk</b>, every 30s - one <tt>statvfs</tt>, but it changes slowly</li>\
    <li><b>generations</b>, every 60s - a directory listing; changes only when \
    you rebuild</li>\
    <li><b>qt</b>, every 60s - runs <tt>qmake -query</tt></li>\
    <li><b>rust</b>, every 60s - runs <tt>rustc</tt> and <tt>cargo</tt></li>\
    </ul><br>\
    History is kept in memory only, and is lost when the engine restarts. \
    Nothing is written to disk and nothing leaves the machine.<br><br>\
    Severity and the one-line headline are also decided in the engine, not in \
    this window - so the desktop and browser builds cannot disagree about what a \
    number means." },
                        { title: "Deploying", body: "\
    Changes to the project do not appear here until they are built and picked \
    up.<br><br>\
    <b>Any file in the repository</b> - <tt>home-manager switch</tt>, then the \
    restart it prints:<br><tt>systemctl --user restart \
    nixdash-engine.service</tt><br>\
    The engine's Nix source is the whole tree, so editing <i>any</i> file \
    rebuilds it to a new store path. Your <tt>home.nix</tt> sets \
    <tt>startServices = \"suggest\"</tt>, which means home-manager prints that \
    command rather than running it - restarting services automatically takes \
    xfconf down and kills the Xfce panel on this machine.<br><br>\
    <b>Changes to this window</b> - also close and reopen it. The UI is an \
    ordinary desktop app, not a service, so a restart command does nothing for \
    it.<br><br>\
    <b>Panel icon or menu entry</b> - also <tt>xfce4-panel -r</tt>. New plugins \
    are not drawn live.<br><br>\
    Until you do those, a changed service keeps running the <i>old</i> build and \
    everything here will look untouched." }
                    ]
                }

                // "About", as a link with the word on it.
                //
                // The version stamp beside it used to BE this control: blue text
                // with a hover tint and nothing else saying so. Nobody read it as
                // clickable - it reads as a label, because it is one - so the
                // gesture went undiscovered while the stamp carried the cost of
                // being two things at once.
                Item {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: aboutText.implicitWidth
                    implicitHeight: aboutText.implicitHeight

                    Text {
                        id: aboutText
                        text: "About"
                        // The header's own colour, not the link blue. Nothing
                        // else up here is blue: the breadcrumb that walks back
                        // out of a subject is ordinary text with a pointing
                        // cursor, and so is the engine address. style.link is
                        // for <a href> inside info panels, and it doubles as
                        // palette.highlight - so a blue word would have sat six
                        // pixels from text that turns the same blue when
                        // selected, meaning two different things at once.
                        //
                        // Text defaults to BLACK rather than to the palette, the
                        // same trap SelectableText documents, so this is set
                        // explicitly rather than left out.
                        color: palette.text
                        // The hover cue the crumbs do without. The word carries
                        // the meaning; this only confirms it is pressable before
                        // you commit to pressing it.
                        font.underline: aboutArea.containsMouse
                        font.pixelSize: root.chromeFont
                    }

                    MouseArea {
                        id: aboutArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: about.open()
                    }
                }

                InfoButton {
                    title: "About"
                    what: "Opens a panel naming this window's <b>version</b>, \
    when it was <b>built</b>, and the address it reads the app's background \
    service from."
                    why: "The build stamp is the only thing that tells two of \
    these windows apart - the version number is <tt>0.1.0</tt> in every build \
    ever made. It is how you check that the window in front of you contains a \
    change you just made, rather than being an older one left open behind it."
                    ifWrong: "<b>The label says which of two things it is.</b> \
    <i>built</i> means something observed the finished article: this window's \
    own file, or the bundle the server is handing out. <i>build started</i> \
    means neither was available and the only stamp left is the one the build \
    script wrote - and a build script runs BEFORE anything is compiled, so it \
    reads early by however long the build took.<br><br>\
    An installed copy is the usual <i>build started</i>: a store path's \
    timestamp is pinned to the epoch by design, so there is no finish time to \
    read.<br><br>\
    A stamp older than your last rebuild means this window is a previous build \
    still running: close it and start it again, because nothing in a running \
    window updates itself. The background service is a separate program and can \
    be a different build again, which the panel also names - that is usually why \
    a change seems not to have taken."
                }

                // Which build this window is - and ordinary selectable text now.
                //
                // The About gesture moved to the link beside it, so this is a
                // plain value: it selects and copies exactly like every other
                // value in the window, with no click to arbitrate against and no
                // threshold deciding which of the two you meant.
                SelectableText {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.rightMargin: 2
                    text: "v" + dash.version + " \u00b7 " + root.builtShown
                    font.pixelSize: root.chromeFont
                }
            }
        }

        // Where you can GO, when the tab you are on has somewhere to go.
        //
        // The Qt page existed for an afternoon before anyone found it: its
        // only way in was a link in the last row of a board about 850px
        // down. A page reachable solely from inside another page is one you
        // have to be told about, which is not navigation.
        ToolBar {
            width: parent.width
            implicitHeight: 30
            visible: root.childrenHere().length > 0

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                spacing: 4

                Repeater {
                    model: root.childrenHere()

                    // Not a TabBar: these are not siblings of the tabs above
                    // and must not look like them. A plain label that bolds
                    // when it is where you are, with a hit area wide enough
                    // for a fingertip - see the touchpad note in CLAUDE.md.
                    Rectangle {
                        Layout.preferredHeight: 24
                        Layout.preferredWidth: subLabel.implicitWidth + 18
                        radius: 4
                        color: root.childHere() === modelData.id
                               ? palette.mid : "transparent"

                        SelectableText {
                            id: subLabel
                            anchors.centerIn: parent
                            text: modelData.name
                            font.pixelSize: root.chromeFont
                            font.bold: root.childHere() === modelData.id
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled: root.childHere() !== modelData.id
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.goChild(modelData.id)
                        }
                    }
                }

                InfoButton {
                    Layout.alignment: Qt.AlignVCenter
                    title: "Subpages"
                    what: "The pages that sit under the tab you are on, and \
the trail below saying which of them you are reading. Only Dev has any \
today."
                    why: "<b>A page reachable only from inside another page \
is one you have to be told about.</b> The Qt page spent its first afternoon \
behind a link in the last row of a board most of a screen down, and was \
reported as not existing. Somewhere that is always in the same place is the \
difference between navigation and a scavenger hunt."
                    ifWrong: "Monitor's three subjects are not here. They are \
reached from cards on its overview, which is a different gesture for a \
different thing: those are readings you pick between, and these are pages \
that sit under another one.<br><br>\
Changing tab clears which subpage you were on, so Dev - Qt does not survive \
a trip to Monitor and back."
                }

                Item { Layout.fillWidth: true }
            }
        }

        // Where you ARE. Moved out of the toolbar above so the two
        // questions - what can I reach, and what am I reading - get a line
        // each instead of sharing one crowded row.
        ToolBar {
            width: parent.width
            implicitHeight: 28

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10

                    Row {
                        id: crumbs
                        spacing: 5
                        Layout.leftMargin: 4
                        Layout.alignment: Qt.AlignVCenter

                        SelectableText {
                            text: root.tab === "monitor" ? "Monitor"
                                : root.tab === "config"  ? "Config" : "Dev"
                            font.pixelSize: style.fontBody
                            // Not dimmed when it is a parent rather than the place
                            // you are - see Style.qml. What is left to say so is the
                            // ordinary breadcrumb cue: the last crumb is where you
                            // are, and only the ones before it answer a click.

                            // No cursor change and no click on the overview, where
                            // this crumb leads nowhere. A pointing hand over a label
                            // that does nothing is a promise the click does not keep.
                            MouseArea {
                                anchors.fill: parent
                                enabled: root.subject !== ""
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { root.subject = ""; root.topic = "" }
                            }
                        }

                        Label {
                            text: "\u203a"
                            visible: root.subject !== ""
                            // Not style.fontBody: inside a Label that is the enum.
                            font.pixelSize: root.theme.fontBody
                        }

                        SelectableText {
                            text: root.subjectNames[root.subject] || root.subject
                            visible: root.subject !== ""
                            font.pixelSize: style.fontBody
                            // Bold only when it is where you are. With a
                            // topic open this is a parent, and a parent that
                            // looked like the destination would make the
                            // trail name two places at once.
                            font.bold: root.topic === ""

                            MouseArea {
                                anchors.fill: parent
                                enabled: root.topic !== ""
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.topic = ""
                            }
                        }

                        Label {
                            text: "\u203a"
                            visible: root.topic !== ""
                            // Not style.fontBody: inside a Label that is the enum.
                            font.pixelSize: root.theme.fontBody
                        }

                        SelectableText {
                            text: root.topicName(root.topic)
                            visible: root.topic !== ""
                            font.pixelSize: style.fontBody
                            font.bold: true
                        }
                    }

                InfoButton {
                    Layout.alignment: Qt.AlignVCenter
                    title: "Where you are"
                    what: "The trail from the tab down to the page you are \
reading. The last crumb is where you are; the ones before it are parents, \
and a click on one goes back up."
                    why: "A page's own heading scrolls away, and the tab bar \
only says which of the three tabs you are on - not which page under it. On \
a long page that leaves nothing on screen saying what you are looking at."
                    ifWrong: "<b>Only a parent answers a click.</b> The last \
crumb is where you already are, so it has no pointing hand and does \
nothing - a cursor change over a label that leads nowhere is a promise the \
click does not keep.<br><br>\
One crumb and no arrow means you are on a tab's own page, which is the \
normal state for Monitor and Config."
                }

                Item { Layout.fillWidth: true }
            }
        }
    }

    // About. The version link in the header opens this; nothing else does.
    Popup {
        id: about
        // On the overlay, like InfoButton's panel, so the header cannot clip
        // it.
        parent: Overlay.overlay
        x: Math.round((parent.width - width) / 2)
        y: Math.round((parent.height - height) / 2)
        width: Math.min(460, parent.width - 60)
        modal: true
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        padding: 16

        contentItem: ColumnLayout {
            spacing: 10

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                SelectableText {
                    Layout.fillWidth: true
                    text: "nixdash"
                    font.bold: true
                    font.pixelSize: 15
                }

                CloseX {
                    Layout.alignment: Qt.AlignTop | Qt.AlignRight
                    onClicked: about.close()
                }
            }

            SelectableText {
                Layout.fillWidth: true
                text: "A local-first dashboard for one NixOS machine: a Rust \
engine reads the system, this window renders it."
                font.pixelSize: style.fontBody
                wrapMode: TextEdit.Wrap
            }

            // Version and stamp describe THIS window, baked in at compile
            // time - see ui/build_date.rs. The engine is a separate binary
            // and can be a different build entirely, which is the usual
            // reason a change does not show up; the address is here so the
            // two can be told apart.
            Grid {
                columns: 2
                columnSpacing: 12
                rowSpacing: 4

                SelectableText { text: "version";  font.pixelSize: style.fontBody }
                SelectableText { text: dash.version; font.pixelSize: style.fontBody }
                // Amsterdam, not UTC - the EU rule is hardcoded in
                // ui/build_date.rs, which is the only zone this shows.
                //
                // "build started", not "built": the stamp comes from the
                // build script, which cargo runs BEFORE compiling, so it
                // records the start and not the finish. Harmless on the
                // desktop side, where the gap is seconds. On the browser
                // side an emcc link runs for minutes and the label read as
                // a bundle that was already out of date the moment it
                // landed - which is the misreading this wording removes.
                SelectableText {
                    // The label is the claim, so it follows the measurement
                    // rather than being written once and hoped for. "built"
                    // only when something actually observed the finished
                    // artefact; "build started" when the baked-in stamp is
                    // all there is.
                    text: root.builtIsExact ? "built" : "build started"
                    font.pixelSize: style.fontBody
                }
                SelectableText {
                    text: root.builtShown + "  (Amsterdam)"
                    font.pixelSize: style.fontBody
                }
                SelectableText { text: "engine";   font.pixelSize: style.fontBody }
                SelectableText {
                    text: root.engineUp ? dash.apiBase
                                        : dash.apiBase + "  (unreachable)"
                    color: root.engineUp ? palette.text : style.badDot
                    font.pixelSize: style.fontBody
                }
            }

            // What the three rows above are. This was the `what` field of
            // the info button that used to sit beside Close; inlining the
            // panel and keeping only its why/if-wrong lost the half that
            // says what you are looking at.
            SelectableText {
                Layout.fillWidth: true
                textFormat: TextEdit.RichText
                wrapMode: TextEdit.Wrap
                font.pixelSize: style.fontBody
                text: "<b>version</b> is the app's own version. The \
row beneath it is this window's build, in Amsterdam time, labelled \
<b>built</b> when the finished article was measured and <b>build started</b> \
when only the build script's own stamp was available. <b>engine</b> is the \
address this window reads from, marked <i>unreachable</i> when nothing \
answers there."
            }

            // Inline, not behind an info button. An About dialog that needs
            // a second modal to explain itself is asking you to open a panel
            // to find out what the panel you are reading says - the same
            // recursion InfoButton.qml is exempted from in qml_info.rs.
            SelectableText {
                Layout.fillWidth: true
                textFormat: TextEdit.RichText
                wrapMode: TextEdit.Wrap
                font.pixelSize: style.fontBody
                text: "<b>Why the stamp is the useful line.</b> There is \
no other way to tell which build this is. A store path's timestamp is pinned \
to the epoch by design, and when a process started says when you opened the \
window - not when its binary was made. So <b>build started</b> is the only \
answer to \"is this the code I just wrote?\", which is the question that \
costs an afternoon when two identical-looking windows are hours apart.<br><br>\
<b>When it reads <i>build started</i>, it is early by however long the \
build took.</b> That is the baked-in stamp, written before compiling begins, \
and it is all an installed copy has - a store path's timestamp is the epoch \
by design. A local build reads <i>built</i> instead, from the file itself, \
and the browser asks the server for its bundle's own timestamp.<br><br>\
The background service shown as <b>engine</b> is a separate binary and can be \
a different build entirely; its address is here so the two can be told apart \
rather than assumed to match."
            }

            SelectableText {
                Layout.fillWidth: true
                textFormat: TextEdit.RichText
                wrapMode: TextEdit.Wrap
                font.pixelSize: style.fontBody
                text: "<b>If it looks wrong</b><ul>\
<li><b>Older than your last build.</b> You are running the installed copy. \
The menu entry and the panel launcher start whichever is newer - a local \
<tt>cargo build</tt> only wins once it is newer than the generation \
<tt>home-manager switch</tt> installed.</li>\
<li><b>Today's date, but your change is missing.</b> This window's QML is \
baked into the binary when it is built, so an edit only arrives with a \
rebuild - and a brand-new QML file has to be listed in both UIs' build files \
or it is simply not in the bundle.</li>\
<li><b>engine marked unreachable.</b> Nothing is listening on that address: \
the background service is stopped, or running on a different port than this \
window was told about.</li></ul>"
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Item { Layout.fillWidth: true }

                // One line so qml_info.rs can exempt this button precisely:
                // its marker is a substring of the declaration line, and a
                // bare `Button {` would exempt Refresh along with it.
                Button { text: "Close"; onClicked: about.close() }
            }
        }
    }

    // One of four views: overview, a subject's panels, config, or dev -
    // and dev has one subject of its own.
    //
    // `subject` is reused rather than given a sibling. The hierarchy is
    // still two levels, the breadcrumb already renders "Dev > Qt" from it,
    // and its back-click already clears it - so a second property would be
    // a second way to say where you are, with two chances to disagree.
    // Switching tabs clears it, which is why Dev > Qt does not survive a
    // trip to Monitor.
    Loader {
        anchors.fill: parent
        sourceComponent: root.tab === "config" ? configPage
                       : root.tab === "dev"    ? root.devComponent()
                       : root.subject === ""   ? monitorPage
                       : subjectPage
    }

    Component {
        id: monitorPage
        MonitorPage {
            panels: root.panels
            actions: root.actions
            onOpenSubject: function(s) { root.subject = s }
        }
    }

    Component {
        id: subjectPage
        SubjectPage {
            subject: root.subject
            panels: root.panelsFor(root.subject)
            actions: root.actionsFor(root.subject)
            actionErrors: root.actionErrors
            memoryHistory: root.memoryHistory
            apiBase: dash.apiBase
            // Without this the panel that triggered the change would keep
            // showing the state that justified the action - a restarted unit
            // still listed as failed.
            onRanAction: root.refresh()
        }
    }

    Component {
        id: configPage
        ConfigPage {
            panels: root.panels
            actions: root.machineActions()
            apiBase: dash.apiBase
            onRanAction: root.refresh()
        }
    }

    /// Which page the Dev tab shows, at whichever depth.
    ///
    /// A function rather than a third nested conditional in the Loader: the
    /// next topic adds a line here instead of another level of brackets to
    /// read past.
    function devComponent() {
        if (root.subject !== "qt")
            return devPage
        if (root.topic === "prefix")
            return qtPrefixPage
        if (root.topic === "wasm")
            return qtWasmPage
        if (root.topic === "rust")
            return qtRustPage
        if (root.topic === "symptoms")
            return qtSymptomsPage
        return devQtPage
    }

    Component {
        id: qtPrefixPage
        QtPrefixPage {
            panels: root.panelsFor("qt")
            apiBase: dash.apiBase
        }
    }

    // The index navigates. Its rows carry a topic id out through
    // openTopic, and setting root.topic here is the whole mechanism - the
    // page holds the destinations, Main holds the navigation, and
    // ConfigSection in between knows about neither.
    Component {
        id: qtSymptomsPage
        QtSymptomsPage {
            panels: root.panelsFor("qt")
            apiBase: dash.apiBase
            onOpenTopic: function(id) { root.topic = id }
        }
    }

    // Handed the bridge's own values, not just panels: this page's board is
    // the Rust/QML boundary itself, and reading them from `dash` here is
    // what makes the board evidence rather than a description.
    Component {
        id: qtRustPage
        QtRustPage {
            panels: root.panelsFor("qt")
            apiBase: dash.apiBase
            appVersion: dash.version
            builtStamp: dash.built
            builtExact: dash.builtExact
            browser: dash.browser
        }
    }

    Component {
        id: qtWasmPage
        QtWasmPage {
            panels: root.panelsFor("qt")
            apiBase: dash.apiBase
        }
    }

    Component {
        id: devQtPage
        DevQtPage {
            panels: root.panelsFor("qt")
            apiBase: dash.apiBase
        }
    }

    Component {
        id: devPage
        DevPage {
            panels: root.panels
            actions: root.devActions()
            apiBase: dash.apiBase
            onRanAction: root.refresh()
            // The page asks to go somewhere; this decides what that means.
            // A page that set root.subject itself would be a second thing
            // navigating, and the breadcrumb reads only this one.
            onOpenQt: root.subject = "qt"
        }
    }
}
