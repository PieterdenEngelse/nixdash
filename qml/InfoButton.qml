import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The main vehicle for explaining things, after `rn`'s InfoButton.
//
// A **panel**, not a tooltip: there is room for real prose, and the three
// questions worth answering are what it is, why it matters, and what a wrong
// value looks like. A `title=` style hover hint cannot carry that, and the
// explanation is the product rather than decoration.
//
// Default to adding one. If someone could plausibly ask "what is this?",
// "where did that number come from?" or "what happens if it is wrong?", the
// stat or control gets a button. Err towards too many.
//
// ---------------------------------------------------------------------------
// Writing content for one
//
// Bodies are **rich text**. That buys three things worth using:
//
//   <b>…</b> <i>…</i> <tt>…</tt>     emphasis, and <tt> for commands/paths
//   <ul><li>…</li></ul>              lists, for failure modes and steps
//   <a href="https://…">…</a>        links, opened in a real browser
//
// Length is not a virtue, but neither is brevity: say what is actually needed.
// When one panel has more than about three screens of prose, split it with
// `sections` rather than making people scroll past what they did not want.
// So more room is always a tab or a link, never a longer body: a tab for our
// own explanation, a link for what is upstream's to hold. A body that has run
// out of room has answered the wrong question - which tab is this?
//
//   InfoButton {
//       title: "Run"
//       what: "…"; why: "…"; ifWrong: "…"
//       sections: [
//           { title: "Privileges", body: "…" },
//           { title: "Troubleshooting", body: "…" }
//       ]
//   }
//
// With no `sections` the panel is a single scrolling column, as before. With
// them it grows a tab bar: the three standard questions become "Overview" and
// each section gets its own tab.
Item {
    id: root

    property string title: ""
    property string what: ""
    property string why: ""
    property string ifWrong: ""

    // Extra tabs: [{ title: string, body: richtext }]. See the note above.
    property var sections: []

    // Nothing to say means no button, rather than an empty panel.
    readonly property bool hasContent:
        what !== "" || why !== "" || ifWrong !== "" || sections.length > 0

    Style { id: style }

    /// Body text in a panel, and the links inside it - which are four
    /// pixels larger, so they stand out of a paragraph rather than being
    /// found by colour alone.
    readonly property int proseFont: style.fontBody
    readonly property int linkFont: proseFont + 4

    /// Prose bodies are rendered by a TextEdit so they can be selected and
    /// copied - info panels are full of commands and paths, and reading one
    /// off the screen by hand is not a feature. TextEdit has neither
    /// `linkColor` nor `lineHeight` (checked against Qt 6.11's own type
    /// info), so both move into the markup here: anchors get an inline
    /// colour, and the body is wrapped in a div carrying the line spacing.
    /// Qt ignores CSS it does not implement rather than erroring, so the
    /// worst case is tighter lines, not a broken panel.
    ///
    /// The link size rides along on that same anchor rewrite. It cannot be a
    /// stylesheet: QTextDocument drops a <style> block inside the fragment
    /// it is handed, and TextEdit has no `defaultStyleSheet` to set one
    /// through. Rewriting at render time rather than in the forty-odd markup
    /// strings keeps the number in one place.
    function proseHtml(body) {
        return "<div style='line-height:130%'>"
             + String(body).replace(/<a /g,
                   "<a style='color:" + style.link
                 + ";font-size:" + root.linkFont + "px' ")
             + "</div>"
    }

    implicitWidth: style.infoSize
    implicitHeight: style.infoSize
    visible: hasContent

    // The canonical spec, kept identical to the RERAG repo's so the two
    // dashboards read as the same family: a rounded square in the Rust brand
    // colour with a white glyph. It used to be a faint bordered circle that
    // took its colour from the palette, which made the single most important
    // affordance in the app the least visible thing on the row.
    Rectangle {
        id: dot
        anchors.fill: parent
        radius: 4
        color: style.infoBg
        border.color: style.infoBorder
        border.width: 1
        opacity: hover.hovered ? 0.8 : 1.0

        // Drawn rather than loaded: an SVG asset would be a second file to
        // keep in sync across two build systems for twelve lines of geometry.
        // Proportions follow the spec - circle r=9, stem from y=8 to y=14,
        // dot at cy=6.3 r=1, on a 24-unit grid.
        Canvas {
            anchors.fill: parent
            onPaint: {
                var ctx = getContext("2d")
                var s = width / 24
                ctx.reset()
                ctx.strokeStyle = style.infoGlyph
                ctx.fillStyle = style.infoGlyph
                ctx.lineWidth = 1.5 * s
                ctx.lineCap = "round"

                ctx.beginPath()
                ctx.arc(12 * s, 12 * s, 9 * s, 0, 2 * Math.PI)
                ctx.stroke()

                ctx.beginPath()
                ctx.moveTo(12 * s, 10 * s)
                ctx.lineTo(12 * s, 16.5 * s)
                ctx.stroke()

                ctx.beginPath()
                ctx.arc(12 * s, 7.8 * s, 1.1 * s, 0, 2 * Math.PI)
                ctx.fill()
            }
        }

        // MouseArea, not TapHandler + HoverHandler: TapHandler ignores
        // synthetic clicks (xdotool, and anything else driving the app
        // programmatically), which makes the UI untestable without a human.
        MouseArea {
            id: hover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: panel.open()
            property bool hovered: containsMouse
        }
    }

    // One body of rich text, scrollable, with working links.
    component Prose: ScrollView {
        id: prose
        property string body: ""
        /// Passed in rather than read off the InfoButton around it. An
        /// inline component does not share scope with the file it is
        /// declared in, so neither `root.proseFont` nor `style.fontBody`
        /// resolves here - and a failed lookup in a binding is silent, which
        /// is the part that makes it worth a line of comment. The literal is
        /// Style.qml's floor; the call site passes the real one.
        property int bodyFont: 13
        /// The height this tab needs to show everything at once, so the
        /// panel can size itself to its tallest tab instead of scrolling.
        /// Safe to read from a binding: it depends on the text and the
        /// available WIDTH, never on the height it is being used to compute.
        readonly property int naturalHeight: proseText.implicitHeight
        clip: true
        contentWidth: availableWidth

        SelectableText {
            id: proseText
            width: prose.availableWidth
            text: prose.body
            font.pixelSize: prose.bodyFont
            wrapMode: TextEdit.Wrap
            // RichText rather than StyledText: StyledText has no lists, and
            // failure modes read far better as a list than as a paragraph.
            textFormat: TextEdit.RichText
            // Opened in the user's browser rather than rendered in-app. The
            // wasm build has no business navigating its own canvas away, and
            // a dashboard is not a web browser.
            onLinkActivated: function(url) { Qt.openUrlExternally(url) }

            // Hover feedback for links without swallowing their clicks:
            // NoButton means this area tracks the pointer and nothing else.
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.NoButton
                cursorShape: parent.hoveredLink !== ""
                             ? Qt.PointingHandCursor : Qt.ArrowCursor
            }
        }
    }

    Popup {
        id: panel
        // Parented to the overlay so the panel is never clipped by the
        // card it belongs to.
        parent: Overlay.overlay
        x: Math.round((parent.width - width) / 2)
        y: Math.round((parent.height - height) / 2)
        // Wider and taller than the original 460px box: these carry real
        // prose now, and a narrow column of it is harder to read, not easier.
        width: Math.min(720, parent.width - 60)
        height: Math.min(contentColumn.wanted, parent.height - 80)
        modal: true
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        padding: 16

        onOpened: bar.currentIndex = 0

        contentItem: ColumnLayout {
            id: contentColumn
            spacing: 10

            // Sized to the TALLEST tab, so switching tabs never resizes the
            // panel and no tab has to scroll while the screen still has room.
            //
            // This was a flat 560 whenever there were sections, which is why
            // long tabs scrolled even on a 1245px-high window with 1165
            // available: the cap had nothing to do with the content. The
            // Popup's own `Math.min(..., parent.height - 80)` is the real
            // limit, and prose longer than a screenful still scrolls - which
            // is the point at which the header's advice applies and the
            // section should be split instead.
            //
            // StackLayout instantiates every tab, not just the visible one,
            // so all of their heights are known up front. Reading them in a
            // binding is loop-free: a tab's implicitHeight follows from its
            // text and the panel's fixed WIDTH, never from the height being
            // computed here.
            readonly property int tallest: {
                var h = overviewColumn.implicitHeight
                for (var i = 0; i < stack.children.length; i++) {
                    var c = stack.children[i]
                    if (c.naturalHeight !== undefined)
                        h = Math.max(h, c.naturalHeight)
                }
                return h
            }
            // Title, tab bar, Close, three row spacings, the Popup's own
            // padding - and the ScrollView's, which is NOT in the text's
            // implicitHeight and cost a clipped final line at the first
            // attempt. Measured against the longest tab in the app rather
            // than derived, so treat it as slack: too much shows as a little
            // space under short prose, too little eats a line.
            // The 8 is the title row growing to the close button's 28px
            // height from the title's own ~20. Erring high on purpose: the
            // note above says too much chrome shows as a little space under
            // short prose, while too little eats a line of it.
            readonly property int chrome: bar.visible ? 160 : 136
            readonly property int wanted: contentColumn.tallest
                                        + contentColumn.chrome

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                SelectableText {
                    Layout.fillWidth: true
                    text: root.title
                    font.bold: true
                    font.pixelSize: 15
                    wrapMode: TextEdit.Wrap
                }

                // Top right, where a close control is looked for first. The
                // Close button at the bottom stays: it is the one you reach
                // after READING, and this is the one you reach when the panel
                // was opened by accident.
                CloseX {
                    Layout.alignment: Qt.AlignTop | Qt.AlignRight
                    onClicked: panel.close()
                }
            }

            // Tabs only when there is something to tab between. One tab is
            // just a label taking up room.
            TabBar {
                id: bar
                Layout.fillWidth: true
                visible: root.sections.length > 0
                TabButton { text: "Overview"; width: implicitWidth }
                Repeater {
                    model: root.sections
                    TabButton { text: modelData.title; width: implicitWidth }
                }
            }

            StackLayout {
                id: stack
                Layout.fillWidth: true
                Layout.fillHeight: true
                currentIndex: bar.visible ? bar.currentIndex : 0

                // Overview: the three standard questions, stacked.
                ScrollView {
                    id: overview
                    clip: true
                    contentWidth: availableWidth

                    Column {
                        id: overviewColumn
                        width: overview.availableWidth
                        spacing: 12

                        Repeater {
                            model: [
                                { heading: "What it is",        body: root.what },
                                { heading: "Why it matters",    body: root.why },
                                { heading: "If it looks wrong", body: root.ifWrong }
                            ]

                            Column {
                                width: parent.width
                                spacing: 3
                                visible: modelData.body !== ""

                                SelectableText {
                                    text: modelData.heading
                                    font.pixelSize: style.fontBody
                                    font.bold: true
                                }
                                SelectableText {
                                    width: parent.width
                                    text: root.proseHtml(modelData.body)
                                    font.pixelSize: root.proseFont
                                    wrapMode: TextEdit.Wrap
                                    textFormat: TextEdit.RichText
                                    onLinkActivated: function(url) {
                                        Qt.openUrlExternally(url)
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        acceptedButtons: Qt.NoButton
                                        cursorShape: parent.hoveredLink !== ""
                                                     ? Qt.PointingHandCursor
                                                     : Qt.ArrowCursor
                                    }
                                }
                            }
                        }
                    }
                }

                Repeater {
                    model: root.sections
                    Prose {
                        body: root.proseHtml(modelData.body)
                        bodyFont: root.proseFont
                    }
                }
            }

            Button {
                Layout.alignment: Qt.AlignRight
                text: "Close"
                onClicked: panel.close()
            }
        }
    }
}
