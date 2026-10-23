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
    property string tab: "monitor"   // "monitor" | "config"
    property string subject: ""      // "" = overview; else nixos|qt|rust

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

    Component.onCompleted: refresh()
    Timer { interval: 2000; running: true; repeat: true; onTriggered: root.refresh() }

    header: ToolBar {
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
                    onClicked: { root.tab = "monitor"; root.subject = "" }
                }
                TabButton {
                    text: "Config"; width: Math.max(90, implicitWidth)
                    font.pixelSize: root.chromeFont
                    onClicked: { root.tab = "config"; root.subject = "" }
                }
                TabButton {
                    text: "Dev"; width: Math.max(90, implicitWidth)
                    font.pixelSize: root.chromeFont
                    onClicked: { root.tab = "dev"; root.subject = "" }
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

            // Where you are, as a trail. The tab bar says which of the two
            // pages you are on, but a subject's panels are a level below it
            // and the only thing naming them was the page's own heading -
            // which scrolls away. The first crumb is also the way back up.
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
                        onClicked: root.subject = ""
                    }
                }

                Label {
                    text: "\u203a"
                    visible: root.subject !== ""
                    font.pixelSize: style.fontBody
                }

                SelectableText {
                    text: root.subjectNames[root.subject] || root.subject
                    visible: root.subject !== ""
                    font.pixelSize: style.fontBody
                    font.bold: true
                }
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
when its <b>build started</b>, and the address it reads the app's background \
service from."
                why: "The build stamp is the only thing that tells two of \
these windows apart - the version number is <tt>0.1.0</tt> in every build \
ever made. It is how you check that the window in front of you contains a \
change you just made, rather than being an older one left open behind it."
                ifWrong: "<b>It is when the build started, not when it \
finished.</b> The stamp is baked in by the build script, which runs before \
anything is compiled - so a build that takes minutes reads minutes earlier \
than the files it produced. The browser UI is where this shows: an emcc link \
of eight minutes leaves a fresh bundle looking eight minutes stale.<br><br>\
A stamp older than your last rebuild by more than that means this window is \
a previous build still running: close it and start it again, because nothing \
in a running window updates itself. The background service is a separate \
program and can be a different build again, which the panel also names - \
that is usually why a change seems not to have taken."
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
                text: "v" + dash.version + " \u00b7 " + dash.built
                font.pixelSize: root.chromeFont
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
                SelectableText { text: "build started"; font.pixelSize: style.fontBody }
                SelectableText {
                    text: dash.built + "  (Amsterdam)"
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
                text: "<b>version</b> is the app's own version. \
<b>build started</b> is when this window's build began, in Amsterdam time - \
the start and not the finish, because the stamp is written before anything \
is compiled. <b>engine</b> is the address this window reads from, marked \
<i>unreachable</i> when nothing answers there."
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
<b>Compare it against when you started the build, not when it finished.</b> \
A desktop build takes seconds and the difference never shows. The browser UI \
links for minutes, so its stamp reads minutes behind the bundle it produced - \
a fresh build looking stale is the expected reading there, not a fault.<br><br>\
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
                       : root.tab === "dev"    ? (root.subject === "qt" ? devQtPage : devPage)
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
