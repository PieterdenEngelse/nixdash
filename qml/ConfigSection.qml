import QtQuick
import QtQuick.Controls

// One subject's block on the Config page: a title and rows of
// label / value / where-it-comes-from.
//
// The third column is the point. A value with no provenance tells you what is
// true but not what to edit, which on a declarative system is most of the
// question.
//
// ---------------------------------------------------------------------------
// The rows are ONE rich-text item, and getting there cost three wrong turns
// worth recording, because each one is a thing Qt will do to you again:
//
//   1. A Repeater of per-cell items. Separate text items cannot share a
//      selection, so only one value could ever be highlighted - there was no
//      drag that took a whole row, let alone the section.
//   2. One item holding a rich-text <table>. Qt snaps a selection to WHOLE
//      CELLS as soon as the drag leaves the cell it started in
//      (QTextCursor::hasComplexSelection). Rows are 13px tall, so a drag that
//      wandered a few pixels lit up every cell it had crossed: the tile
//      flashed solid and a single store path could not be lifted out.
//   3. A per-field grid plus a Select all button. Precise, but it put the
//      obvious gesture behind a control you had to find first.
//
// So: one item, rich text, no table. Blocks select by character, which is what
// a drag is supposed to do - anywhere in the tile, across as many rows as you
// like, and Ctrl+A for all of it. Columns are aligned with &nbsp; padding in a
// monospace font rather than cells; HTML collapses ordinary runs of spaces,
// which &nbsp; does not. Per-span colour survives, so the provenance column
// stays muted.
//
// What it costs: a value longer than its column pushes the rest of that line
// right, and a store path wraps mid-path rather than being clipped. Both were
// true of the table as well.
Rectangle {
    id: root

    property string title: ""
    /// [{ label, value, source }], plus optional what/why/ifWrong/sections -
    /// a row carrying any of those grows an info button, and one carrying
    /// none does not (InfoButton hides itself when it has nothing to say).
    ///
    /// A row may also carry `buildId`, which grows a Run button beside its
    /// info button. The id names something the app can run; this component
    /// never holds a command, and the signal below carries the id and nothing
    /// else - see the note on runRequested.
    property var rows: []

    /// Explains the section as a whole, on the title line, for a tile whose
    /// rows each make sense alone while the grouping is the part that needs
    /// saying. Optional in the same way the rows are: set none of these and
    /// the title has no button, exactly as before.
    property string what: ""
    property string why: ""
    property string ifWrong: ""

    /// Reserved for the button column, so no text runs under it.
    readonly property int infoWidth: style.infoSize + 8

    /// Width a Run button takes, reserved only on a section that has one.
    /// Sections without runnable rows keep exactly the text width they had.
    readonly property int runWidth: 54

    readonly property bool hasRuns: {
        for (var i = 0; i < root.rows.length; i++)
            if (root.rows[i].buildId)
                return true
        return false
    }

    /// The last run's outcome in words, set by the page. Empty hides it.
    property string resultText: ""
    property bool resultOk: true

    /// Per-id state supplied by the page: { running, ok, text }.
    ///
    /// Owned by the page rather than by this component, because this one is a
    /// reference board used on several pages and holds no HTTP of its own.
    property var runState: ({})

    /// A row's Run button was pressed. Carries the ROW'S ID, never a command:
    /// what gets executed is fixed where the id is defined, and the page that
    /// handles this signal posts the id alone.
    signal runRequested(string buildId)
    /// A row's Stop button was pressed. Only rows carrying `stoppable` have
    /// one - a command that finishes has nothing to stop.
    signal stopRequested(string buildId)

    /// Bumped whenever the text block relays out, and read by every info
    /// button's `y` so the button follows its row.
    ///
    /// The buttons are positioned by asking the document where a paragraph
    /// starts, and that answer changes with WIDTH: a tile narrow enough to
    /// wrap a provenance line pushes every row below it down a line. The
    /// bindings already re-ran on `text` and `length`, and neither of those
    /// moves when the column width does - so the first evaluation, taken
    /// before the layout had settled on a width, was the one that stuck.
    /// Every button then sat at the unwrapped pitch, drifting further above
    /// its own row with each wrap above it: three columns hid this because
    /// the tiles were wide enough that little wrapped, and four columns made
    /// it obvious.
    ///
    /// A counter rather than reading `contentHeight` inside the binding,
    /// because the binding has to re-run AFTER the relayout and not during
    /// it - the signal is the only thing that orders those correctly.
    property int relayout: 0

    Connections {
        target: body
        function onContentHeightChanged() { root.relayout++ }
        function onWidthChanged() { root.relayout++ }
    }

    /// Which paragraph of the document each row's first line is.
    ///
    /// Not the row index: paragraph 0 is the title, paragraph 1 the blank
    /// line under it, and a row with a provenance pointer occupies two
    /// paragraphs rather than one.
    readonly property var rowParagraph: {
        var out = []
        var p = 2
        for (var i = 0; i < root.rows.length; i++) {
            out.push(p)
            // value, its provenance if any, and the blank line that follows
            // every row but the last - all of which shift the next row down.
            p += 1
            if (root.rows[i].source)
                p += 1
            if (i < root.rows.length - 1)
                p += 1
        }
        return out
    }

    /// Document position where each paragraph begins, read back from the
    /// document rather than predicted from label and value lengths - the
    /// same lesson StatBlock.qml records at length: during a rebuild the
    /// prediction is asked of the previous, shorter document and Qt answers
    /// with a wall of "QTextCursor::setPosition: Position N out of range".
    readonly property var offsets: {
        var len = body.length
        var dependency = body.text   // re-run on markup change, not just length
        var plain = len > 0 ? body.getText(0, len) : ""
        var out = []
        var pos = 0
        var parts = plain.split("\u2029")
        for (var i = 0; i < parts.length; i++) {
            out.push(pos)
            pos += parts[i].length + 1
        }
        return out
    }

    implicitHeight: col.implicitHeight + 24
    radius: 8
    color: palette.base
    border.color: palette.mid

    Style { id: style }

    function pad(n) {
        var s = ""
        for (var i = 0; i < n; i++)
            s += "&nbsp;"
        return s
    }

    /// Width of the label column, in characters: the longest label plus two.
    /// Monospace, so character count is the column.
    readonly property int labelWidth: {
        var w = 0
        for (var i = 0; i < rows.length; i++)
            w = Math.max(w, String(rows[i].label).length)
        return w + 2
    }

    function rowsHtml() {
        // The title is the first line of the same text item, not a heading
        // above it. A drag naturally starts at the top-left of a tile - on
        // the title - and a drag that begins in one item can only select
        // inside that item, so starting there used to get you the title and
        // nothing else. Sans-serif and larger, so it still reads as a
        // heading inside an otherwise monospace block.
        var h = "<div><span style='font-family:sans-serif; font-size:14px; "
              + "font-weight:bold; color:" + style.textStrong + "'>"
              + body.esc(root.title) + "</span></div>"
        // A blank line under the title, and it is load-bearing rather than
        // taste: the info buttons are 24px because a fingertip needs that
        // much, and a line of text is 16-17px. Buttons are centred on their
        // own line, so two on ADJACENT lines cannot both fit - measured at
        // 7px of overlap between the section's button and the first row's,
        // which put the title's hit area on top of the first row's. Rows are
        // three lines apart already (value, provenance, blank), so this was
        // the only colliding pair. It also makes the title separate from the
        // rows the same way the rows separate from each other.
        h += "<div>&nbsp;</div>"
        for (var i = 0; i < root.rows.length; i++) {
            var r = root.rows[i]
            var label = String(r.label)
            h += "<div><span style='color:" + style.textMuted + "'>"
               + body.esc(label) + root.pad(root.labelWidth - label.length)
               + "</span><span style='color:" + style.text + "'>"
               + body.esc(r.value) + "</span></div>"
            // The provenance on its own indented line. Beside the value it
            // was the first thing a long store path pushed off the tile.
            if (r.source)
                h += "<div>" + root.pad(root.labelWidth)
                   + "<span style='color:" + style.textMuted + "'>&#8627; "
                   + body.esc(r.source) + "</span></div>"
            // A blank line between items, so a row and its provenance read as
            // one thing rather than the list reading as one block. Not after
            // the last: that would be padding inside the tile's own margin.
            if (i < root.rows.length - 1)
                h += "<div>&nbsp;</div>"
        }
        return h
    }

    /// The same rows as plain text, for the clipboard. Tabs rather than
    /// padding: this is going into an editor or a terminal, not back into a
    /// fixed-width column.
    function sectionText() {
        var out = root.title + "\n"
        for (var i = 0; i < root.rows.length; i++) {
            var r = root.rows[i]
            out += r.label + "\t" + r.value + "\t" + r.source + "\n"
        }
        return out
    }

    Clipboard { id: clip }

    // Ctrl+Shift+C while the pointer is over this section, the same gesture
    // every panel answers to. It hands back tab-separated text rather than
    // what is on screen: the columns here line up because the labels are
    // padded with non-breaking spaces, and those are not what you want in a
    // paste.
    HoverHandler { id: sectionHover }
    Shortcut {
        sequences: [ "Ctrl+Shift+C" ]
        enabled: sectionHover.hovered
        onActivated: clip.put(root.sectionText())
    }

    Column {
        id: col
        x: 14
        y: 12
        width: parent.width - 28
        spacing: 6


        // Monospace because the columns are padded, not laid out: a
        // proportional font makes &nbsp; padding line up to nothing.
        SelectableText {
            id: body
            width: parent.width - root.infoWidth - (root.hasRuns ? root.runWidth : 0)
            text: root.rowsHtml()
            textFormat: TextEdit.RichText
            font.family: "monospace"
            // The floor, for the same reason the panels use it:
            // screen-scale.nix downscales a 120% framebuffer. See
            // `fontBody` in Style.qml, which is now where that rule lives.
            font.pixelSize: style.fontBody
            color: style.text
            // Word boundaries first, mid-word only when a run has none -
            // which is every store path.
            wrapMode: TextEdit.Wrap
        }

        // What the last run actually did, in full. The dot on the button says
        // only whether it worked; the reason it did not - a held port, a
        // dismissed polkit prompt, the log file to read - needs words, and
        // this is where they go.
        SelectableText {
            visible: root.resultText !== ""
            width: parent.width - root.infoWidth
            text: root.resultText
            wrapMode: TextEdit.Wrap
            font.pixelSize: style.fontBody
            color: root.resultOk ? style.okText : style.badText
        }
    }

    // The section's own button, on the title line. Paragraph 0 is the title,
    // so it is positioned the same way the rows below are: by asking the
    // document where that paragraph starts, never by predicting it.
    InfoButton {
        x: root.width - col.x - width
        y: {
            var dependency = body.text
            var moved = root.relayout
            if (body.length === 0)
                return col.y
            var r = body.positionToRectangle(0)
            return col.y + r.y + Math.max(0, (r.height - height) / 2)
        }
        title: root.title
        what: root.what
        why: root.why
        ifWrong: root.ifWrong
    }

    // One per runnable row, sitting just left of that row's info button and
    // positioned the same way: by asking the document where the row's
    // paragraph starts, never by predicting it.
    //
    // A Repeater of its own rather than an item inside the info Repeater,
    // because most rows have no button and an empty placeholder in every row
    // of every section would still reserve its width.
    Repeater {
        model: root.rows

        Item {
            visible: !!modelData.buildId
            width: root.runWidth
            height: run.height
            x: root.width - col.x - root.infoWidth - width
            // Same dependency reads as the info buttons below: text, relayout
            // and length are touched explicitly so this re-runs when the
            // block reflows, which a binding over a function call alone does
            // not notice.
            y: {
                var dependency = body.text
                var moved = root.relayout
                var len = body.length
                var o = root.offsets[root.rowParagraph[index]]
                if (o === undefined || o > len)
                    return col.y + index * 20
                var r = body.positionToRectangle(o)
                return col.y + r.y + Math.max(0, (r.height - height) / 2)
            }

            readonly property var st: root.runState[modelData.buildId]
                                      ? root.runState[modelData.buildId] : ({})

            Button {
                id: run
                anchors.right: parent.right
                // Full width of the reserved column, so the hit area is the
                // whole of it: a fingertip on a trackpad is the only pointer
                // this machine has, and style.infoSize is 24 for the same
                // reason.
                width: parent.width
                height: style.infoSize
                // "Stop" only where stopping means something, and only once
                // there is something to stop - a button that offers to stop a
                // thing that is not running would be a reading the app never
                // took.
                readonly property bool stopping: modelData.stoppable
                                                 && root.runState[modelData.buildId]
                                                 && root.runState[modelData.buildId].up
                text: parent.st.running ? "…" : (stopping ? "Stop" : "Run")
                enabled: !parent.st.running
                font.pixelSize: style.fontBody
                onClicked: stopping ? root.stopRequested(modelData.buildId)
                                    : root.runRequested(modelData.buildId)

                // The outcome, as a dot rather than a word: there is no room
                // for a sentence here and the sentence belongs in the result
                // line under the board, which says what actually happened.
                Rectangle {
                    visible: parent.parent.st.text !== undefined
                             && !parent.parent.st.running
                    width: 6
                    height: 6
                    radius: 3
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: 4
                    color: parent.parent.st.ok ? style.okDot : style.badDot
                }
            }
        }
    }

    // One per row that has something to explain, anchored to the row's own
    // line in the document. A sibling of the Column rather than a child of
    // it: the Column stacks its children, and these have to sit beside the
    // text rather than under it.
    Repeater {
        model: root.rows

        InfoButton {
            x: root.width - col.x - width
            // body.text, root.relayout and body.length are read explicitly
            // so this re-runs when the block relays out - a binding over a
            // function call alone does not notice that the rows moved, and
            // `text` alone does not notice that the WIDTH moved. A row whose
            // paragraph does not exist yet parks on an estimated pitch
            // instead of asking the document for a position it does not have.
            y: {
                var dependency = body.text
                var moved = root.relayout
                var len = body.length
                var o = root.offsets[root.rowParagraph[index]]
                if (o === undefined || o > len)
                    return col.y + index * 20
                var r = body.positionToRectangle(o)
                return col.y + r.y + Math.max(0, (r.height - height) / 2)
            }
            title: modelData.label
            what: modelData.what ? modelData.what : ""
            why: modelData.why ? modelData.why : ""
            ifWrong: modelData.ifWrong ? modelData.ifWrong : ""
            sections: modelData.sections ? modelData.sections : []
        }
    }
}
