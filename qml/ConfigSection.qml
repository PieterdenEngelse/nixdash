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

    /// Which paragraph of the document each row's first line is.
    ///
    /// Not the row index: paragraph 0 is the title, and a row with a
    /// provenance pointer occupies two paragraphs rather than one.
    readonly property var rowParagraph: {
        var out = []
        var p = 1
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
            width: parent.width - root.infoWidth
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
    }

    // The section's own button, on the title line. Paragraph 0 is the title,
    // so it is positioned the same way the rows below are: by asking the
    // document where that paragraph starts, never by predicting it.
    InfoButton {
        x: root.width - col.x - width
        y: {
            var dependency = body.text
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

    // One per row that has something to explain, anchored to the row's own
    // line in the document. A sibling of the Column rather than a child of
    // it: the Column stacks its children, and these have to sit beside the
    // text rather than under it.
    Repeater {
        model: root.rows

        InfoButton {
            x: root.width - col.x - width
            // body.text and body.length are read explicitly so this re-runs
            // when the block relays out - a binding over a function call
            // alone does not notice that the rows moved. A row whose
            // paragraph does not exist yet parks on an estimated pitch
            // instead of asking the document for a position it does not have.
            y: {
                var dependency = body.text
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
