import QtQuick
import QtQuick.Controls

Panel {
    id: root

    Style { id: style }

    /// [{at, value}] oldest first, for the sparkline. `at` is milliseconds
    /// since the Unix epoch.
    property var history: []

    readonly property real availableGb: value ? value.available_kb / 1048576 : 0
    readonly property real totalGb:     value ? value.total_kb / 1048576 : 0
    readonly property real usedPct:     value ? value.used_fraction * 100 : 0
    readonly property real swapFreeGb:  value ? value.swap_free_kb / 1048576 : 0
    readonly property real pressure60:  value && value.pressure_some_avg60 !== undefined
                                        ? value.pressure_some_avg60 : 0

    // title, subtitle and state_ come from the engine via Panel.

    readonly property int plotHeight: 64
    readonly property int axisHeight: 14
    readonly property int axisFont:   10

    /// Time axis marks: [{x, label}], x in plot pixels. Rebuilt whenever the
    /// samples or the width change, since both move where a tick lands.
    property var ticks: []

    /// Round wall-clock boundaries across the window the samples actually
    /// cover - not a fixed 30 minutes. History starts empty and fills, so
    /// early on this axis is honestly only a few minutes wide.
    function rebuildTicks(w) {
        var n = history.length
        if (n < 2 || w <= 0) {
            ticks = []
            return
        }
        var t0 = history[0].at
        var span = history[n - 1].at - t0
        if (span <= 0) {
            ticks = []
            return
        }

        // Every candidate divides an hour, so flooring against the epoch also
        // lands on the local clock in any whole- or half-hour timezone: the
        // labels read 06:10, 06:20 instead of drifting with the window.
        var steps = [10000, 30000, 60000, 120000, 300000, 600000, 900000, 1800000]
        var want = Math.max(2, Math.floor(w / 90))
        var step = steps[steps.length - 1]
        for (var s = 0; s < steps.length; ++s) {
            if (span / steps[s] <= want) {
                step = steps[s]
                break
            }
        }

        var out = []
        for (var t = Math.ceil(t0 / step) * step; t <= t0 + span; t += step)
            out.push({ x: (t - t0) / span * w,
                       label: root.clockLabel(t, step < 60000) })
        ticks = out
    }

    function clockLabel(ms, withSeconds) {
        function pad(v) { return v < 10 ? "0" + v : "" + v }
        var d = new Date(ms)
        return pad(d.getHours()) + ":" + pad(d.getMinutes())
               + (withSeconds ? ":" + pad(d.getSeconds()) : "")
    }

    // 64px sparkline plus four stat rows does not fit the frame's default
    // 190, which is what clipped "stall 60s" off the bottom. The time axis
    // adds its own row underneath, so this stays content-driven.
    contentHeight: col.implicitHeight

    Column {
        id: col
        width: parent.width
        spacing: 6

        Canvas {
            id: spark
            width: parent.width
            height: root.plotHeight

            property var pts: root.history

            onPtsChanged: { root.rebuildTicks(width); requestPaint() }
            onWidthChanged: { root.rebuildTicks(width); requestPaint() }

            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var n = pts.length
                if (n < 2)
                    return

                // Place samples by their timestamp, not by their index. A
                // missed tick or a restarted service leaves a real gap, and
                // index spacing would quietly slide the trace out of step
                // with the labels underneath it.
                var t0 = pts[0].at
                var span = pts[n - 1].at - t0

                // Fixed 0..100% scale: an autoscaled memory graph always looks
                // dramatic and hides the only thing that matters, which is
                // distance from the ceiling.
                function xy(i) {
                    var v = pts[i].value
                    var used = v.used_fraction !== undefined ? v.used_fraction : 0
                    var x = span > 0 ? (pts[i].at - t0) / span * width
                                     : i / (n - 1) * width
                    return [ x, height - used * height ]
                }

                // Gridlines first, so the trace sits on top of them.
                var tk = root.ticks
                ctx.strokeStyle = style.border
                ctx.lineWidth = 1
                ctx.globalAlpha = 0.5
                for (var g = 0; g < tk.length; ++g) {
                    var gx = Math.round(tk[g].x) + 0.5
                    ctx.beginPath()
                    ctx.moveTo(gx, 0)
                    ctx.lineTo(gx, height)
                    ctx.stroke()
                }
                ctx.globalAlpha = 1

                ctx.beginPath()
                var p0 = xy(0)
                ctx.moveTo(p0[0], p0[1])
                for (var i = 1; i < n; ++i) {
                    var p = xy(i)
                    ctx.lineTo(p[0], p[1])
                }
                ctx.strokeStyle = root.stateColors[root.state_] || style.unknownDot
                ctx.lineWidth = 2
                ctx.stroke()

                ctx.lineTo(width, height)
                ctx.lineTo(0, height)
                ctx.closePath()
                ctx.globalAlpha = 0.12
                ctx.fillStyle = ctx.strokeStyle
                ctx.fill()
            }
        }

        Item {
            id: axis
            width: parent.width
            height: root.axisHeight
            visible: root.ticks.length > 0

            Repeater {
                model: root.ticks

                Text {
                    required property var modelData

                    text: modelData.label
                    color: style.textMuted
                    font.pixelSize: root.axisFont
                    // Centred on its tick, but clamped inside the frame so the
                    // oldest and newest labels cannot hang off the edge.
                    x: Math.max(0, Math.min(axis.width - width,
                                            modelData.x - width / 2))
                }
            }
        }

        StatBlock {
            panel: root
            rows: [
                { label: "available",
                  value: root.value ? root.availableGb.toFixed(1) + " GB of "
                                      + root.totalGb.toFixed(1) : "—",
                  statKey: "available_kb" },
                { label: "used",
                  value: root.value ? root.usedPct.toFixed(0) + "%" : "—",
                  statKey: "used_fraction" },
                { label: "swap free",
                  value: root.value ? root.swapFreeGb.toFixed(1) + " GB" : "—",
                  statKey: "swap_free_kb" },
                { label: "stall 60s",
                  value: root.value ? root.pressure60.toFixed(2) + "%" : "—",
                  statKey: "pressure_some_avg60" }
            ]
        }
    }
}
