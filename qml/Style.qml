import QtQuick

// Every colour in the app, defined once.
//
// Before this there were 62 hex literals across 13 files and 20 distinct
// shades — three different greens for "good", three reds for "bad", two
// ambers for "pending" — each picked independently while writing the file it
// appeared in. The problem was never which hues; it was that one *role* had
// several values and nothing said which was correct.
//
// **Not a singleton**, which is the one thing that would be natural here.
// cxx-qt 0.10's QmlModule has no way to register one - no qmldir singleton
// marker, no per-file property - so `pragma Singleton` loads as an error.
// Instead this is an ordinary QtObject that each component instantiates:
//
//     Item {
//         Style { id: style }
//         Rectangle { color: style.surface }
//     }
//
// It holds nothing but constants, so an instance per component costs
// essentially nothing.
//
// ---------------------------------------------------------------------------
// The scheme is dark, deliberately and not by inheriting one. Text follows
// the rule from the RERAG repo, moved halfway to white: #e8eaed for anything
// you need to read, #ced1d7 as the floor for secondary text, and never
// darker. Links are blue.
QtObject {
    // ---- surfaces ------------------------------------------------------
    readonly property color window:     "#1b1f24"   // page background
    readonly property color surface:    "#22272e"   // panels and tiles
    readonly property color surfaceAlt: "#2b313a"   // code blocks, insets
    readonly property color border:     "#3a424d"
    readonly property color borderSoft: "#2f3741"

    // ---- text ----------------------------------------------------------
    // Anything the reader needs: #e8eaed. Secondary: #ced1d7, and no darker -
    // the contrast failure is invisible until someone actually reads it on a
    // dark display.
    //
    // Each of these is its RERAG original moved HALF THE REMAINING DISTANCE
    // to white, per channel: #d1d5db -> #e8eaed, #9ca3af -> #ced1d7,
    // #f3f4f6 -> #f9fafa. That formula rather than a multiplier because the
    // originals are already 66-90% of the way there, so "50% brighter" has
    // no meaning that does not clip. It lifts body text from 10.2:1 to
    // 12.5:1 on a panel, and secondary from 5.9:1 to 9.8:1 - the floor moved
    // further than the ceiling, which is the point.
    //
    // The split is NEUTRAL versus HUED, not "text" versus "status". Every
    // grey that carries text moves - including unknownText and
    // shellBadgeText further down. The greens, ambers, reds and blues do
    // not: they are already 8-10:1, and whitening a hue desaturates the one
    // thing it is there to signal.
    readonly property color text:       "#e8eaed"
    readonly property color textMuted:  "#ced1d7"
    readonly property color textStrong: "#f9fafa"

    // **Text is never dimmed with `opacity`.** Hierarchy comes from size,
    // weight and the colours above - not from alpha. Alpha was doing that job
    // in 27 places and it is what put secondary text under the floor: at the
    // pre-brightening values, 0.6 on #d1d5db over #22272e composited to about
    // #8b9096, darker than the #9ca3af that was then the limit, and the label
    // column of every stat row was sitting there. The floor is only a floor
    // if nothing is allowed to multiply its way below it afterwards.
    //
    // screen-scale.nix makes it worse than the numbers suggest: it downscales
    // a 120% framebuffer, so small text renders smaller than its pixelSize
    // and the dimming lands on top of that. MonitorPage's why-strip carries
    // the worked example.
    //
    // Opacity on a *shape* is a different thing and still fine - the disk
    // bar's fill, the info button's hover, the ✓ watermark behind an empty
    // unit list. None of those are read.

    // ---- type ----------------------------------------------------------
    // **13px is the floor for text.** Not a preference: screen-scale.nix runs
    // this desktop at 120% of the panel's native resolution - a 2304x1296
    // framebuffer the GPU downsamples onto 1920x1080 - so every glyph lands
    // at 1/1.2 of its nominal size. `fontBody` is 10.8 real pixels. An 11
    // would have been 9.2 and a 10 would have been 8.3.
    //
    // This is where the rule lives. It was previously stated only in
    // comments in StatBlock.qml and ConfigSection.qml, both of which said
    // "see Style.qml" about a paragraph that did not exist here - and it was
    // under-run in 54 places out of 72 before anyone looked.
    //
    // Sizes ABOVE the floor are still chosen per site: headings at 15 and
    // page titles at 18. The header's size is `fontChrome` below, which used
    // to be the one exception to this scale.
    readonly property int fontBody: 13

    // The header chrome: the three tabs, the About link, the version string
    // beside it - everything Main.qml's `chromeFont` feeds.
    //
    // It lives here because it used to be derived from the inherited platform
    // font instead, `root.font.pixelSize + 6`, and the two builds do not
    // inherit the same font. The desktop gets XSettings' Gtk/FontName, "Sans
    // 8", which resolves to 10px at this display's 96dpi. The browser has no
    // such setting, so Qt for WebAssembly falls back to its own default -
    // DejaVu Sans at the default 12pt, 16px at the same 96dpi. One QML file
    // therefore rendered a 16px header in the window and a 22px one in the
    // tab, 37% larger, where every other string matched to the pixel because
    // every other string is sized from this file.
    //
    // 16 is what the desktop was already showing, so this moves the browser
    // onto the desktop's appearance rather than inventing a third size.
    readonly property int fontChrome: 16

    readonly property color link:       "#60a5fa"
    readonly property color linkHover:  "#93c5fd"

    // ---- status --------------------------------------------------------
    // One scale, four states, each with a dot colour, a readable text colour
    // and a tint for filled panels. Chosen for a dark background: the old
    // values were Material's light-theme shades and turn to mud here.
    readonly property color okDot:      "#4ade80"
    readonly property color okText:     "#86efac"
    readonly property color okTint:     "#16301f"

    readonly property color warnDot:    "#fbbf24"
    readonly property color warnText:   "#fcd34d"
    readonly property color warnTint:   "#33280f"

    readonly property color badDot:     "#f87171"
    readonly property color badText:    "#fca5a5"
    readonly property color badTint:    "#3a1d1e"

    readonly property color unknownDot:  "#9ca3af"
    // Brightened with the other neutral text greys; the dot above is not,
    // because a dot is a shape and is read by colour, not by reading it.
    readonly property color unknownText: "#ced1d7"
    readonly property color unknownTint: "#272c33"

    // Written-but-not-yet-applied, used by all three writable sections. The
    // same family as warn, because it is the same idea: not wrong, not
    // finished.
    readonly property color pendingText: warnText
    readonly property color pendingTint: warnTint

    // ---- badges --------------------------------------------------------
    // "paste into your Nix config" vs "run in a terminal" vs "needs root".
    readonly property color nixBadgeTint:     "#16293d"
    readonly property color nixBadgeText:     "#93c5fd"
    readonly property color shellBadgeTint:   "#2b313a"
    readonly property color shellBadgeText:   "#e2e6ea"   // neutral: brightened
    readonly property color rootBadgeTint:    "#3a2a14"
    readonly property color rootBadgeText:    "#fcd34d"

    // ---- info button ---------------------------------------------------
    // The canonical spec from the RERAG repo, kept identical so the two
    // dashboards read as the same family: a 24px rounded square in the Rust
    // brand colour with a white glyph, not a tinted circle.
    readonly property color infoBg:     "#7C2A02"
    readonly property color infoBorder: "#7C2A02"
    readonly property color infoGlyph:  "#ffffff"
    readonly property int   infoSize:   24

    // ---- spacing -------------------------------------------------------
    readonly property int gapTight:  4
    readonly property int gap:       8
    readonly property int gapWide:   12
    readonly property int pad:       12
    readonly property int radius:    6

    // ---- helpers -------------------------------------------------------
    // Status strings come from the engine as "ok" | "warn" | "bad" |
    // "unknown". Mapping them here means a panel never has to carry its own
    // colour table, which is how the three greens happened.
    function dotFor(status) {
        if (status === "ok")   return okDot
        if (status === "warn") return warnDot
        if (status === "bad")  return badDot
        return unknownDot
    }
    function textFor(status) {
        if (status === "ok")   return okText
        if (status === "warn") return warnText
        if (status === "bad")  return badText
        return unknownText
    }
    function tintFor(status) {
        if (status === "ok")   return okTint
        if (status === "warn") return warnTint
        if (status === "bad")  return badTint
        return unknownTint
    }
}
