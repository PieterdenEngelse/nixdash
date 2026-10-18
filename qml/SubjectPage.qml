import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// One subject's panels, plus its actions.
//
// Panel components are chosen by id where a bespoke visual earns its place,
// and fall back to GenericPanel otherwise - so a panel added to the engine
// shows up here without a UI change, just without a chart.
Item {
    id: root

    property string subject: ""
    property var panels: []

    /// The ids of the panels on show, reassigned only when that SET changes.
    ///
    /// The Repeater below must not be handed a new array every poll. Main
    /// refreshes every 2 seconds and assigns a fresh `panels`; a Repeater
    /// with an array model tears down and rebuilds every delegate whenever
    /// the model is reassigned - which destroys the InfoButton you just
    /// clicked, and the Popup that button owns. An info panel opened on a
    /// subject page closed itself within two seconds, with no error.
    ///
    /// DiskPanel.qml already documents this teardown, as the reason its
    /// progress bar must not animate. The connection to modals was missed:
    /// the same rebuild that restarts an animation also deletes an open
    /// dialog. The Monitor overview was never affected because its model is
    /// a literal three-element list that is evaluated once.
    ///
    /// Keying on the id list keeps delegates alive across a poll, and the
    /// readings still update - `summaryFor` reads `panels`, so the binding
    /// re-evaluates without anything being destroyed.
    /// Written by the handler below, never bound. A binding that both reads
    /// and assigns this would be self-referential - the obvious way to write
    /// it, and a loop.
    property var panelIds: []

    onPanelsChanged: {
        var ids = []
        for (var i = 0; i < root.panels.length; i++)
            ids.push(root.panels[i].id)
        // Only assign when the set actually differs. Handing over a fresh
        // array with equal contents is still a reassignment, and the
        // Repeater rebuilds on that alone.
        if (ids.join("\u0000") !== root.panelIds.join("\u0000"))
            root.panelIds = ids
    }

    function summaryFor(id) {
        for (var i = 0; i < root.panels.length; i++)
            if (root.panels[i].id === id)
                return root.panels[i]
        return null
    }
    property var actions: []
    property var actionErrors: []
    property var memoryHistory: []
    property string apiBase: ""

    // A run changes exactly the state the panels show, so the shell re-polls.
    signal ranAction()

    readonly property var titles: ({
        "nixos": "NixOS",
        "qt": "Qt",
        "rust": "Rust"
    })

    // The page heading explains the page. Each subject answers a different
    // question, and which question it is turns out to be the thing people get
    // wrong - "Qt" reads as "is Qt installed" until you are told otherwise.
    readonly property var subjectWhat: ({
        "nixos": "The health of this machine right now: free space on the \
store's filesystem, memory and stall pressure, systemd units that failed in \
either scope, and the generations you could roll back to.",
        "qt": "Whether Qt software would BUILD here, which Qt an installed Qt \
program actually runs, and whether the WebAssembly build of this same \
interface is current. Three different questions that are easy to conflate.",
        "rust": "Whether a Rust build would work in this environment - the \
toolchain, and which compilation targets have a standard library - and \
whether what is deployed was built from the source now on disk."
    })
    readonly property var subjectWhy: ({
        "nixos": "These are the readings that decide whether to act, and the \
ones with a repair worth offering. Suggested actions below are the repairs.",
        "qt": "On NixOS, <i>installed</i> and <i>usable for a build</i> come \
apart. Qt is split across store paths, so a prefix can be present, correct, \
and still missing the host tools a QML build needs - and the failure arrives \
late, naming a tool rather than the prefix that lacks it.",
        "rust": "A missing target standard library and a missing linker both \
fail at the END of a build, with an error naming a crate or a symbol rather \
than the thing that is actually absent. Reading it here costs seconds; \
discovering it at link time costs a build."
    })
    readonly property var subjectIfWrong: ({
        "nixos": "A panel reading <b>unknown</b> means the measurement could \
not be taken, which is not the same as nothing being wrong - it is the app \
declining to reassure you about something it never checked.",
        "qt": "<b>No qmake on PATH is not an error.</b> qmake is a \
development tool and on NixOS normally exists only inside a devShell, so a \
perfectly healthy machine reads unknown here.",
        "rust": "<b>Stale is not broken.</b> It means the running build \
predates the source on disk, which is the usual reason a change you made \
appears to have done nothing."
    })

    // Same tab on all three subjects, because the answer is the same.
    //
    // It names the engine, which the info-panel voice in CLAUDE.md otherwise
    // forbids - panels are written as though there is only "the app". The
    // exception is deliberate and narrow: this project exists to make the
    // invisible visible, and here the internal structure IS the subject. The
    // rest of the panels still say "the app's background service".
    readonly property var pageSections: [{
        title: "engine",
        body: "Everything on this page was measured somewhere else. \
<b>nixdash is two programs</b>: this window, and a Rust program called the \
<b>engine</b> that runs as a background service and answers over HTTP on \
<tt>127.0.0.1:3100</tt>. The window polls it every two seconds and draws \
whatever comes back.<br><br>\
<b>Why it is separate.</b> Not layering for its own sake. There are two \
interfaces - this desktop one and a WebAssembly one that runs in a browser - \
compiled from a single <tt>qml/</tt> directory. If each worked out for itself \
whether 46% disk use was worth a warning, the two could disagree about the \
same machine. Putting the measuring <i>and the judging</i> in one place makes \
that impossible rather than merely unlikely."
    }, {
        title: "what it decides",
        body: "More than you might expect:<br>\
<ul>\
<li><b>The readings</b> - <tt>/proc</tt>, <tt>systemctl</tt>, the profile \
directory, <tt>statvfs</tt>, <tt>qmake -query</tt>, <tt>rustc</tt>. Each \
panel is sampled on its own schedule, chosen against what the measurement \
costs: memory every 2 seconds, <tt>qmake</tt> every 60.</li>\
<li><b>The severity and the one-line headline</b> - the coloured dot and the \
sentence beside each title are its verdict, not this window's.</li>\
<li><b>These explanations.</b> The text you are reading is written next to \
the code that produces the number, by whoever knows why it is computed that \
way.</li>\
<li><b>What a Run button runs.</b> Pressing one sends an action's \
<i>name</i> and nothing else - never a command - so the set of programs that \
can be started is fixed when the app is built.</li>\
</ul>\
<b>And what it deliberately is not.</b> No database: history lives in memory \
and is lost when it restarts. No privilege of its own - anything needing root \
goes through a polkit prompt you answer, and that prompt is the \
authorisation. One generated file it ever writes. Nothing leaves the machine, \
and the loopback address is compiled in rather than configured."
    }, {
        title: "what catches people out",
        body: "<b>Its environment is not your shell.</b> The background \
service has its own <tt>PATH</tt>. That is why the Qt page can honestly \
report no qmake while you are sitting in a devShell that has one - entering \
that shell changes nothing about what these panels say, and that is a real \
limitation rather than a bug.<br><br>\
<b>Rebuilding is not restarting.</b> A changed file produces a new build, but \
the service keeps serving the old one until it is restarted - which is the \
usual reason a change appears to have had no effect. The Rust page's \
build-freshness panel exists to make exactly that visible."
    }]

    ScrollView {
        id: scroller
        anchors.fill: parent
        anchors.margins: 14
        contentWidth: availableWidth

        // Wrapped rather than being the ScrollView's content item directly.
        // ScrollView sizes its content item, which fights a Layout that also
        // assigns its own `width`: the cap stopped applying and panels ran
        // off the right edge. A plain Item absorbs the sizing instead.
        Item {
            width: scroller.availableWidth
            implicitHeight: colLayout.implicitHeight

            ColumnLayout {
                id: colLayout
                // Full width. Was capped at 1700; extra width here becomes
                // another column of panels rather than longer lines, so the
                // grid absorbs it rather than stretching.
                width: parent.width
                spacing: 12

                // The heading, and the only explanation of the page as a
                // whole - every other info button on it belongs to one panel
                // or one reading.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    SelectableText {
                        text: root.titles[root.subject] || root.subject
                        font.bold: true
                        font.pixelSize: 18
                    }

                    InfoButton {
                        Layout.alignment: Qt.AlignVCenter
                        title: root.titles[root.subject] || root.subject
                        what: root.subjectWhat[root.subject] || ""
                        why: root.subjectWhy[root.subject] || ""
                        ifWrong: root.subjectIfWrong[root.subject] || ""
                        sections: root.pageSections
                    }

                    Item { Layout.fillWidth: true }
                }

                GridLayout {
                    Layout.fillWidth: true
                    // A third column once there is room for one at a readable
                    // width. Panels hold label/value rows, so widening them past
                    // ~550px just pushes the value away from its label.
                    columns: root.width < 640 ? 1 : (root.width >= 1500 ? 3 : 2)
                    columnSpacing: 12
                    rowSpacing: 12

                    Repeater {
                        model: root.panelIds

                        Loader {
                            Layout.fillWidth: true
                            // qmllint disable missing-property
                            // Loader.item is typed QtObject; every component
                            // below is an Item and has implicitHeight.
                            Layout.preferredHeight: item ? item.implicitHeight : 200
                            // qmllint enable missing-property
                            // Every panel in a row takes the row's height, so
                            // their top edges line up.
                            //
                            // Without this they do not: a Qt Quick Layout
                            // CENTRES an item that cannot grow, rather than
                            // aligning it to the top of its cell. On the Qt
                            // page that put the two short panels about 60px
                            // below the tall one beside them - read as
                            // "the boards do not line up", which is exactly
                            // what it was. Filling is better than
                            // Layout.alignment: Qt.AlignTop here: that would
                            // align the tops and leave the bottoms ragged,
                            // where equal-height cards square off both edges.
                            //
                            // No risk of stretching the grid itself. Its own
                            // height comes from the ColumnLayout above, which
                            // is sized to implicitHeight, so there is never
                            // spare vertical space for a row to absorb - this
                            // only redistributes height WITHIN a row.
                            Layout.fillHeight: true

                            // modelData is the panel's id now, not the
                            // summary - see panelIds above.
                            property var summary: root.summaryFor(modelData)

                            sourceComponent: {
                                switch (modelData) {
                                case "memory":       return memoryComp
                                case "failed-units": return unitsComp
                                case "generations":  return gensComp
                                case "disk":         return diskComp
                                case "qt":           return qtComp
                                case "rust":         return rustComp
                                default:             return genericComp
                                }
                            }
                        }
                    }
                }

                // Actions belonging to this subject. Same component the Config
                // page uses, so running works identically in both places.
                ActionsPanel {
                    id: actionsPanel
                    Layout.fillWidth: true
                    // Sizes to its content: the page already scrolls, so a fixed
                    // 300 only buys a second scrollbar and a clipped last action.
                    Layout.preferredHeight: actionsPanel.implicitHeight
                    visible: root.actions.length > 0 || root.actionErrors.length > 0
                    actions: root.actions
                    errors: root.actionErrors
                    apiBase: root.apiBase
                    onRanAction: root.ranAction()
                }
            }
        }
    }

    // Every panel now takes the whole summary: the engine supplies title,
    // headline, severity and the explanations, so the UI stops duplicating
    // judgement it has no business making.
    // qmllint disable missing-property
    // `parent` inside a Component is the Loader that instantiates it, typed
    // QQuickItem - the `summary` property it carries is set in SubjectPage's
    // Repeater above. qmllint cannot follow that and is right not to try.
    Component {
        id: memoryComp
        MemoryPanel { summary: parent.summary; history: root.memoryHistory }
    }
    Component {
        id: unitsComp
        FailedUnitsPanel { summary: parent.summary }
    }
    Component {
        id: gensComp
        GenerationsPanel { summary: parent.summary }
    }
    Component {
        id: diskComp
        DiskPanel { summary: parent.summary }
    }
    Component {
        id: qtComp
        QtPanel { summary: parent.summary }
    }
    Component {
        id: rustComp
        RustPanel { summary: parent.summary }
    }
    Component {
        id: genericComp
        GenericPanel { summary: parent.summary }
    }
    // qmllint enable missing-property
}
