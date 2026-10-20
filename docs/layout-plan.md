# Layout and style alignment — plan

## Status: complete

| phase | landed | note |
|---|---|---|
| 13a Style singleton | `7310c30`, 2026-10-10 | **not** a singleton — cxx-qt 0.10's `QmlModule` cannot register one, so `pragma Singleton` loads as an error. It is a plain `QtObject` each component instantiates, which costs nothing for constants. The phase text below still prescribes the approach that failed. |
| 13b Info button spec | `7310c30` | `qml/InfoButton.qml:93` keeps the spec identical to RERAG's. |
| 13c Consolidate roles | `7310c30` | `Style.qml` holds roles, not colours. Duplicate hex values remain and are fine — they are distinct roles sharing a shade, `infoBg`/`infoBorder` being the spec itself. |
| 13d Theme decision | `7310c30` | **Option A, dark.** The blocking call was made. |
| 13e Control rhythm | the writable sections, then 2026-10-20 | `[label] [control] [info]` and "never greyed out to mean busy" were already in all three writable sections; `ActionsPanel`'s Run button was the last control disabled to mean working, and now refuses the second press in its handler instead. |
| 13f Justfile | 2026-10-20 | `Justfile` at the repo root, `just` in the devShell. `CLAUDE.md` cites recipes rather than carrying command lines — it had eleven, two of which were the same build spelled differently. The two UI recipes are named `desktop` and `browser`, not the `ui` and `wasm` proposed below: one `qml/` builds two UIs, and `just ui` reads as unambiguous only to someone who already knows the crate is `nixdash-ui` — which is the knowledge the Dev page exists to not require. |

Two "done when" criteria went unmet for ten days after the work itself
landed, both of them tests: 13a asked for one enforcing that no colour is
defined outside `Style.qml` (`engine/tests/qml_colours.rs`, 2026-10-20), and
13f's argument — *prose in two files is how the quality gate went unrun* — was
itself the thing left undone. A phase is not finished when the code is
written; it is finished when something fails if the code regresses.

Bringing nixdash's UI into line with the conventions in the RERAG repo. The
repository layout already matches (README, CLAUDE.md, docs/); the gap is
almost entirely in the interface.

## Where it stands

| | RERAG | nixdash |
|---|---|---|
| Colour definitions | Tailwind classes + a documented hex table | **62 literals, 20 shades, 13 files, no central definition** |
| Info button | canonical spec: `#7C2A02` square, white 5×5 SVG, named constants | 16px circle, serif "i", palette colours |
| Theme | dark, committed to | inherits the system palette, but mixes in light-assuming literals |
| Control rhythm | `[control] [info]` | `[label] [info] [control] [status]` |
| Disabled controls | *"Never use the `disabled` attribute… reject the click in the handler"* | `enabled: !busy` on every Switch |
| Task runner | `Justfile` | none — commands live in prose |

### The one that is a bug, not a preference

nixdash reads `palette.base` and `palette.text` — so it follows the system
theme — but then paints tiles with `#fcf8e3`, `#fdecea`, `#e8f5e9` and text
with `#5f2120`, `#8a6d3b`. Those assume a light background. Under a dark Qt
theme the app becomes dark chrome with pale islands in it.

Nothing is "wrong" today only because the system theme happens to be light.

## Phases

### 13a — Style singleton *(enabling step; everything else depends on it)*

One `qml/Style.qml` (`pragma Singleton`) holding every colour, the spacing
scale, and the info-button geometry. Replace all 62 literals.

Registered in `ui/build.rs` **and** `ui-wasm/rust/build.rs`, plus a
`qmldir` entry — a singleton needs that, unlike an ordinary component.

*Done when:* `grep -c '#[0-9a-f]\{6\}' qml/*.qml` returns 0 outside
`Style.qml`, and a test enforces it the way `qml_info.rs` enforces info
buttons.

### 13b — Info button to the canonical spec

Adopt RERAG's spec exactly, because it is already written down and an
unexplained second style is worse than either:

- 24×24 rounded square, `background #7C2A02`, `border 1px #7C2A02`
- white icon: circle `r=9`, line `y1=8 y2=14` stroke-width 1.5,
  dot `cy=6.3 r=1` filled
- hover: 80% opacity

Drawn as a QML `Canvas` or `Shape` rather than an SVG file, so it stays one
component with no asset to keep in sync.

*Done when:* every `i` in the app is that button, defined once.

### 13c — Consolidate the roles

The problem is not which hues are used, it is that the same role is painted
a different shade in each file. Three greens for "good" (`#4caf50`,
`#2e7d32`, `#1b5e20`), three reds for "bad" (`#f44336`, `#c62828`,
`#b71c1c`), two ambers for "pending" — all chosen independently.

| Role | Now | After |
|---|---|---|
| status ok / warn / bad / unknown | `#4caf50` `#ff9800` `#f44336` `#9e9e9e`, plus deeper variants | one named scale, with its own text and tint shades |
| pending / not-yet-applied | `#fcf8e3` tile, `#8a6d3b` text, also `#ffecb3` | one named pending pair |
| result panes | `#e8f5e9` / `#fdecea` | tints derived from the status scale |
| links | plain text today — nothing is clickable-looking | blue `#60a5fa`, hover `#93c5fd` |

Links are the one genuine addition: the info panels now carry `<a href>`
links and render them in whatever `palette.link` happens to be, which is not
a decision anyone made.

*Done when:* each role has exactly one definition.

### 13d — Theme decision **(blocking — needs a call)**

Two coherent endpoints. Today's mix is neither.

**Option A — commit to dark.** Matches RERAG, makes its hex table directly
applicable, and the two dashboards look like siblings. Costs: the Qt panels
stop following the system theme, so nixdash is dark even in a light session.

**Option B — genuinely adaptive.** Derive every tint from `palette`, no
literal backgrounds at all. Costs: RERAG's hex rules cannot be applied
literally, and the status scale needs two variants to stay legible.

Recommendation: **A**. The rules being adopted were written for dark, and
half-adapting is what produced the current inconsistency.

### 13e — Control rhythm and disabled states

Settle on `[label] [control] [info]`, matching RERAG's `[control] [info]`
ordering, and apply it to all three writable sections.

Drop `enabled: !busy` from every Switch. RERAG bans the equivalent for a
reason that applies identically in Qt: a disabled control renders greyed and
reads as *broken* rather than *busy*. Reject in the handler instead, and say
why in a sibling label.

*Done when:* no control is ever disabled to indicate "working".

### 13f — Justfile

The commands from `CLAUDE.md` as recipes: `just gate`, `just engine`,
`just ui`, `just wasm`, `just deploy`. Prose in two files is how the quality
gate went unrun for a whole session.

## Order

13a first — everything else edits colours, and doing that before they are
centralised means touching the same lines twice. Then 13d, because the theme
decision changes what values 13b and 13c take. Then 13b, 13c, 13e, 13f in
any order.

## Not in scope

- Rewriting the page structure. Monitor/Config and the subject drill-down
  already match RERAG's shape (overview → detail, config separate).
- Tailwind-style utility classes. QML has property bindings; a singleton is
  the idiomatic equivalent and a class-name system would be cargo cult.
