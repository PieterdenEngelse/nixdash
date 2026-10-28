# Dev › Qt as a path, not a board — plan

## Status: complete

| phase | landed | note |
|---|---|---|
| 1 Third level, and the prefix page | `c45e4ef`, 2026-10-18 | Navigation gained `tab / subject / topic`. `QtPrefixPage.qml` is "Why there is no single Qt" — qt.md Part 1's three NixOS traps, each as symptom → cause → fix, over a live board of the prefix that answered. |
| 2 The Emscripten pairing | `6280e9a`, 2026-10-28 | `QtWasmPage.qml` — why a cross build needs two Qts and one pinned Emscripten. The second topic, and the first use of the affordance phase 1 built. |
| 3 What is measured vs what is declared | `b845cf8`, 2026-10-28 | **Closed, by a different mechanism than proposed.** `emcc_built_with` and `emcc_series_match` in `qt_wasm.rs`, read from the store graph. The gap was real and the planned fix was wrong — see below. |
| 4 Something fails if this regresses | `3cb728e`, 2026-10-28 | `engine/tests/qml_topics.rs`. Four tests: every `qtTopics` id is routed, every routed component has a file, every QML file is in **both** bundles, and the parsers catch their own shapes. |

## Why this exists

The Qt page was built boards-first: five readings arranged by what a build
consumes. That is the right content for someone who already knows there is a
problem and roughly where it lives. It is the wrong shape for the person the
app is for — someone meeting "there is no single Qt on NixOS" for the first
time, with a build that failed and an error message filed under its cause
rather than its symptom.

So the subject grows topics underneath it. A board answers *what is it now*;
a topic answers *why is it like this, and what do I type*.

## The organising rule

**The app teaches what it can show you live; `~/docs/qt.md` keeps what it
cannot.**

"Prefixes can be incomplete" is worth little from a document. "This prefix,
measured a second ago, is missing `qmltyperegistrar` and `qmlcachegen`" is
worth the page. The reading comes first and the prose explains the reading,
rather than standing in for it.

This is also the admission test for a proposed topic. Every Qt reading the
engine produces is already on one of the two pages — the only orphan is
`wasm_bytes` — so a new *board* needs a new collector, while a new *topic*
needs only an existing reading that nobody has explained yet.

What that rules out, and why:

| qt.md section | live reading? | verdict |
|---|---|---|
| Part 1 · Three NixOS traps | prefix, tools_missing, source | **shipped**, phase 1 |
| Part 2 · Emscripten must match Qt | emcc_recommended, sdk_version, versions_match, host_env | **phase 2** |
| Part 1 · Two more cxx-qt traps | none | stays in qt.md — build-time code, nothing measures it |
| Part 1 · Signals and slots | none | stays in qt.md — API usage, not machine state |
| Part 2 · EM_CACHE, emsdk shim | none | stays in qt.md — recipe steps, encoded in `~/Projects/qt6-wasm` |
| Part 3 · cxx-qt → wasm blockers | `built`, `stale` only, and those are freshness | stays in qt.md unless a collector earns it |

## The honest gap — closed in phase 3

Through phases 1 and 2 the Qt page said this out loud, and was right to:

> **Emscripten expected is not a comparison.** It states what this Qt wants;
> nothing here checks your emsdk against it.

`emcc_recommended` is read from the Qt source, and the other half of the
pairing was never looked at. Under the house rule that *"nothing found" and
"could not look" are different answers*, a page may not imply a verdict it
did not measure — so both pages stated the limit rather than hiding it, and
phase 2 shipped with the gap intact and declared.

It is now measured. What follows is how, and why the mechanism this plan
originally proposed was the wrong one.

### How phase 3 closed it

The gap is closed, but **not** the way this plan proposed. The proposal was
to run the emcc on PATH and compare. That is the obvious approach and it is
wrong twice over:

- **There is no emcc on PATH.** Verified: `command -v emcc` finds nothing.
  The emsdk lives in `~/Projects/qt6-wasm`'s dev shell, which the app never
  enters, so the probe reports `unknown` always and the row stays as
  uninformative as before.
- **When it did find one, it would be the wrong one.** A system emcc has no
  bearing on a build that uses the flake's. Reporting it as *the* emcc is
  precisely the false alarm `rust-emscripten-target` was fixed for — a
  toolchain the build never touches, reported as the toolchain the build
  uses. The rule it breaks is *never raise a false alarm*, and this
  repository has paid for that one twice.

The CMake cache was checked next and does not record the compiler path.

What does record it is Nix. `<sdk>.drv` pulls in `qtbase-wasm-*.drv`, which
pulls in `emscripten-4.0.10.drv` — so two bounded `nix-store -q` lookups name
the Emscripten the wasm Qt was *actually built with*, which is the only half
worth comparing against what Qt pins. Measured on this machine: Qt wants
**4.0.7**, it was built with **4.0.10**, and those agree on major.minor,
which is the comparison Qt itself enforces.

Three properties this keeps:

- **Series, not string.** 4.0.10 against 4.0.7 warns and builds; an exact
  comparison would paint a working pairing as broken.
- **Blank, not `no`.** A store path outlives its `.drv`, so after a garbage
  collection the reading is *could not look*, which is a different answer
  from *they disagree*.
- **Panel status is untouched.** A real mismatch is worth flagging, but that
  state cannot be produced on this machine to test against, and a status rule
  that has never been seen fire is how the last two false alarms shipped.
  Left as a reading.

Both pages that stated the gap have been corrected — they previously said in
so many words that nothing checked this, which is now false.

## Verification

Phases 1 and 2 are both verified by clicking all three levels and back up the
trail, which is currently the only way: `qml-check` cannot see a strip that
sets a property nothing routes on, and an offscreen run reports no QML errors.

That gap is now closed by `engine/tests/qml_topics.rs`, in the shape of
`qml_info.rs` and `qml_text_style.rs`. Both failure modes were live when it
was written, and both were confirmed to fail the test before being restored:

- deleting the `wasm` branch from `devComponent()` →
  *qtTopics offers ["wasm"], which devComponent() never tests for*
- deleting `qml/QtWasmPage.qml` from `ui-wasm/rust/build.rs` →
  *QtWasmPage.qml: missing from ui-wasm/rust/build.rs*

Clicking is still the only way to judge whether a page *reads* right. What it
is no longer the only way to catch is a page that cannot be reached at all.

## Adding a topic

1. `qml/<Name>Page.qml`, built like `QtPrefixPage.qml` — reading first, then
   the explanation of that reading.
2. An entry in `Main.qml`'s `qtTopics`, which is what the subpage strip and
   the breadcrumb both read.
3. A branch in `Main.qml`'s `devComponent()` and its `Component` wrapper.
4. **Both** `ui/build.rs` and `ui-wasm/rust/build.rs` — a QML file missing
   from either is absent from that resource bundle, and the desktop build
   will not tell you the browser one is broken.
