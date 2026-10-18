# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Does

**nixdash** is a local-first config-and-monitoring dashboard for one NixOS
machine: a Rust engine (axum, loopback only) collects system state, and a
Qt/QML UI renders it — compiled twice from one source, once natively and once
to WebAssembly.

**nixdash is also a learning platform.** It monitors three subjects — **NixOS,
Qt and Rust** — and is meant to teach how this machine actually works: why a
store path is read-only, why `PATH` has nothing to do with whether Qt runs,
what polkit is doing when it asks for a password. UI decisions (info panels,
visible stats, declared-vs-effective) exist to serve that: **make the
invisible visible**.

> The three subjects are things being *monitored*, not merely the stack it is
> written in. This was misread once and cost a rewrite.

## Build, Test, and Development Commands

```bash
# Engine dev server
cd engine && RUST_LOG=info cargo run

# Quality gate before committing. Tiered - see Collaboration Style.
cargo fmt --all && cargo test --all        # always
./qml-check                                # when qml/ changed
cargo clippy --all-targets -- -D warnings  # when Rust CODE changed

# Tests
cargo test --all

# Desktop UI
nix develop --command bash -c 'cd ui && cargo build'

# Browser UI (separate toolchain: emcc + wasm32 Rust target)
nix develop .#wasm --command bash ui-wasm/build.sh
./ui-wasm/serve.sh                      # :8099

# Deploy
home-manager switch                     # then the restart it prints
systemctl --user restart nixdash-engine.service
```

## Collaboration Style

- **Check your work, off the user's screen — but the machine is shared.**
  Build it, lint it, test it, curl it: that costs the user no attention. It
  does cost them a laptop with **7 GB of RAM and about 2 free**, where a
  parallel `cargo` build alongside everything else is what gets things
  OOM-killed (Chrome's GPU process is the usual casualty). An earlier draft
  of this line said the cost "is yours to spend, not theirs". That is true of
  their attention and false of their hardware — there is one machine and both
  of us are on it.

  So prefer the cheap form:

  | instead of | use | when |
  |---|---|---|
  | `cargo build` | `cargo check` | you only need to know it compiles |
  | `cargo clippy --all-targets` | `cargo clippy -p <crate>` | one crate moved |
  | the gate after every edit | the gate **once**, before a commit | always |

  **The gate is tiered, because clippy on this machine is not cheap.**
  Measured on 2026-10-17: the full gate hit a ten-minute cap twice, and
  clippy scoped to the engine alone still took **8m45s** for a change that
  touched nothing but string literals. That is the laptop, not the work.

  | changed | run |
  |---|---|
  | anything | `cargo fmt --all` and `cargo test --all` |
  | `qml/` | also `./qml-check` |
  | Rust **code paths** | also `cargo clippy --all-targets -- -D warnings` |
  | only Rust strings, comments or docs | **skip clippy** — `cargo check` instead |

  The last row is the loosening and it is deliberate: clippy lints code, and
  a reworded `&'static str` has no code for it to lint. `cargo test --all`
  still builds everything, so a change that does not compile is still caught
  before a commit. If in doubt, run clippy — the rule exists to stop nine
  minutes being spent proving a sentence is still a sentence, not to make
  skipping it a habit.

  What is genuinely expensive is a `home-manager switch` (~15 min), so never
  reach for one just to see a change.
- **Never put the UI on the user's screen.** No launching it into their
  session, no `xdotool`, no `windowactivate`, no screenshots of their
  display. They run it and report what they see. Stealing focus while they
  are working is the thing this forbids, and an authorisation to look once
  is not a standing one.

  **Offscreen is allowed, but it is only a smoke test:**

  ```bash
  QT_QPA_PLATFORM=offscreen ./target/debug/nixdash-ui
  ```

  Starts the real app with no window and nothing on the user's display —
  verified. What it tells you is that the binary runs and stays up.

  It does **not** report QML errors. A deliberate `ReferenceError` in
  `Main.qml`'s `Component.onCompleted` produced zero bytes on stdout and
  stderr, with and without `QT_LOGGING_RULES='*.debug=true'`. Why was not
  chased. Do not treat silence here as evidence that a binding resolved.

  `./qml-check` is the tool that actually finds those, and it needs no app
  at all. Neither can answer *does it look right*: that judgement is the
  user's, always, and is what the screenshots were really being used for.

- **Do not take the engine's port.** To exercise engine changes, run a second
  one beside the service rather than stopping it:

  ```bash
  NIXDASH_PORT=3199 ./target/debug/nixdash-engine
  ```

  Stopping `nixdash-engine.service` blanks the app the user is looking at.
- **Confirmation threshold**: don't ask before small or single-file edits.
  Only ask before major or multi-file changes. Ending every message with
  "shall I continue?" is noise.
- **Commit directly to main.** Solo project, self-reviewed. No feature
  branches or PRs by default. Commit phase work straight to main; tag a
  release when a phase ships.
- **Report exit codes from the command itself**, never from a trailing `grep`
  in the same pipeline. `home-manager switch | grep …` reports grep's status,
  which has already been mistaken for a successful deploy once.

## Architecture

```
[desktop UI (cxx-qt)]   [browser UI (wasm)]
            │                   │
            └────── HTTP ───────┘   loopback only, :3100
                    │
            [engine (axum)]
                    │
  /proc · systemctl · /nix/var/nix/profiles · statvfs · qmake · rustc
```

One `qml/` directory, symlinked into `ui/qml` and `ui-wasm/rust/qml`. The
symlink is load-bearing: a `../qml/...` path corrupts the generated Qt
resource aliases. A new QML file must also be listed in **both**
`ui/build.rs` and `ui-wasm/rust/build.rs` or it will not be in the resource
bundle.

## Key Files

| File | Purpose |
|------|---------|
| `engine/src/collector.rs` | `Collector` trait, `Info`/`StatInfo`, `Panel` + ring buffer |
| `engine/src/collectors/` | one module per panel |
| `engine/src/actions/` | one module per action provider |
| `engine/src/actions/runner.rs` | execution: argv, pkexec, pipe draining, timeout |
| `engine/src/settings.rs` | the one place the engine writes a file |
| `engine/src/api.rs` | route registry |
| `qml/InfoButton.qml` | the explanation mechanism: tabs, rich text, links |
| `qml-check` | qmllint over `qml/`, with the import paths it needs |
| `nix/hm-module.nix` | home-manager module — read the sandbox comment before editing |

## Coding Conventions

- **Indentation**: 4 spaces everywhere; tabs only in Makefiles
- **Rust naming**: `snake_case` modules/functions, `SCREAMING_SNAKE_CASE`
  constants, `UpperCamelCase` types
- **QML components**: `UpperCamelCase.qml` in `qml/`
- **Linting**: `cargo fmt --all` + `cargo clippy --all-targets -- -D warnings`
  must pass before a commit
- **Commits**: conventional form — `type(scope): lowercase description`, e.g.
  `fix(engine): read symlink mtime, not its target`

## The Only Pointing Device Is A Touchpad

**There is no mouse. There has never been a mouse.** The machine has exactly
one pointer: `ETD2204:00 04F3:31DC Touchpad`. Every gesture this UI asks for
is performed on a trackpad, and that is not a detail to design around later —
it is the input model.

What the pad is actually configured as, read from `xinput list-props`:

| setting | value | meaning |
|---|---|---|
| Tapping Enabled | 1 (default 0) | tap-to-click, turned on deliberately |
| Tapping Drag Enabled | 1 | tap-tap-hold to start a drag |
| Tapping Drag Lock Enabled | 1 (default 0) | a drag survives lifting the finger |
| Tapping Button Mapping | lrm | **middle click is a THREE-FINGER TAP** |

Three rules follow, and all three have already been violated in this repo:

- **A drag is the most expensive gesture available.** It is tap-tap-hold-move,
  and a long one — a store path is 70+ characters — runs out of pad and needs
  drag lock, which is why drag lock is switched on. So a drag may never be the
  ONLY way to reach something. Anything selectable by dragging must also be
  reachable by click or Ctrl+A. This is why "Ctrl+A selects the value you
  clicked" exists; treat it as the primary path and the drag as the refinement.

- **Middle-click paste is not a fallback.** The X11 primary selection is a
  three-finger tap away. Code comments in `SelectableText.qml` and
  `StatBlock.qml` have reasoned about primary selection as though it were an
  equal second route to the clipboard. It is not. The ordinary clipboard is
  the route; primary selection is a bonus for someone who knows the gesture.

- **Do not shrink a target.** `style.infoSize` is 24px because a fingertip on
  a trackpad is not a mouse on a desk. The pointer itself is deliberately
  enlarged for the same reason (see `xfce-appearance.nix`, which says so).
  Hover-only affordances are equally suspect: hover costs a deliberate park of
  the cursor here, so nothing may be discoverable by hover alone.

## Info Buttons

**Every control and every stat gets one.** Adding a control, a stat or an
automation step means adding its info panel *in the same change*, not as a
follow-up. Default to adding one; err towards too many.

This is enforced: `engine/tests/qml_info.rs` scans `qml/` for `Button`,
`TabButton` and `MouseArea` declarations and fails if one has no `InfoButton`
within 60 lines. Exemptions need a written reason, and a second test fails if
the reason is under 60 characters.

**Three questions, always**: what it is · why it matters · what a wrong value
looks like.

**A floor, not a template.** The three have to be *answered* somewhere in the
panel; they do not have to be its shape, and nothing says a panel may contain
only them. Open with prose if prose is what helps. Lead with the reading
itself. Put a table where a table is clearer — which package ships which
tool, the three places qmake is looked for. The About dialog describes its
own rows before explaining them, and that ordering is right for it.

What the rule is actually against is a panel that answers *fewer* than three
— the one that says what a thing is and leaves you to guess why it matters or
what a wrong value looks like.

Bodies are rich text — `<b>`, `<tt>` for commands and paths, `<ul>`,
`<table>`, and `<a href>` links that open in a browser. Long panels split
into tabs via `sections: [{ title, body }]`.

**When a body needs more room, it gets a tab or a link — never more
characters.** `engine/tests/info_length.rs` caps one body at 1800 characters,
and that cap is a tripwire for "this should have been split", not a budget to
write up to. The corpus it was calibrated against has a median of ~110; a body
approaching the limit is an outlier by a factor of fifteen, so the question to
ask at that point is which tab it belongs in, not whether it still fits.

The two escape hatches are not interchangeable:

- **A tab** is for the app's own explanation — the mechanism, the trap, the
  worked example. It keeps the material one click away, in the panel, where
  someone learning this machine will actually meet it.
- **A link** is for authority that is not ours to hold: the Qt docs, the NixOS
  manual, polkit, `rustc`'s platform support table. Every link in the app
  today points upstream, and that is the pattern — a link must never be a
  way to put *our* explanation somewhere else, which is just scrolling with
  extra steps and no offline copy.

**Explain the mechanism, not the label.** "Shows memory usage" is a wasted
panel. "Most of 'used' is reclaimable cache, so this number looks alarming and
means little" is the one worth having.

## Modals

**Every modal carries a visible way out, top right.** A `Popup` or a `Dialog`
covers the window, and both already close on Escape and on a click outside —
but neither of those can be *seen*. A panel with no visible exit reads as a
hang, and "press Escape" is only obvious to someone who already knows it,
which is the wrong assumption in an app built for someone still learning the
machine.

Use the shared `qml/CloseX.qml`, never a hand-rolled button, so the glyph,
the size and the hit area cannot drift between panels:

```qml
CloseX { onClicked: thatPopup.close() }
```

For a confirmation, close through the path the buttons use — `reject()`, not
`close()` — so dismissing it cannot skip a signal that Cancel would emit.

A bottom `Close` button can stay alongside it. They answer different moments:
the bottom one is reached after reading, the X when the panel was opened by
accident.

This is enforced: `engine/tests/qml_modals.rs` counts `Popup {` and
`Dialog {` declarations per file and fails if the file has fewer `CloseX`
than modals. Exemptions need a written reason over 60 characters, and the
list is currently empty — keep it that way.

`CloseX` is itself exempt from the info-button rule: its mechanism is its
label, and an info button on the close control of an info panel would be a
panel explaining how to leave itself.

## Panel Layout

**A `GridLayout` child that fills width fills height too.** A Qt Quick Layout
*centres* an item that cannot grow rather than aligning it to the top of its
cell, so in a row of sections with different row counts the short ones float
mid-row and no edge lines up. `Layout.fillHeight: true` gives each item its
row's height and squares off both edges — better than
`Layout.alignment: Qt.AlignTop`, which lines the tops up and leaves the
bottoms ragged. The reasoning in full is on the `Loader` in
`qml/SubjectPage.qml`.

There is no risk of stretching the grid itself: these grids sit in a `Column`
or `ColumnLayout` sized to `implicitHeight`, so no row has spare vertical
space to absorb and filling only redistributes height *within* a row.

Ragged edges are never a reason to drop to one column. That trades a
screenful of scrolling for something one property fixes, and the whole point
of two and three columns is to read what fits beside what is already there.

`hooks/qml-grid-heights.py` says so at the edit — a `PostToolUse` hook, and
**advisory**: an item that should keep its natural height is a legitimate
answer, which is why this is not a test like `qml_info.rs`. Run it over
everything with `python3 hooks/qml-grid-heights.py --check qml/*.qml`.

This rule lived only as a comment in `SubjectPage.qml` for two days, during
which `DevPage.qml` was written without it and the gate passed — and
`ConfigPage.qml` had copied the breakpoints from that same file without the
height fix. A convention in one file's comments is not a convention.

## Info Panel Voice

Info panels are written from the perspective of someone using the app. To
them there is only **the app** — they do not know or care that it has an
engine and a UI talking over HTTP.

- ✅ user-visible technical terms: store paths, `PATH`, polkit, generations,
  ports, `home-manager switch`
- ❌ source-code architecture terms: "the engine", "the backend", "a
  collector", `spawn_blocking`, "DT_NEEDED", "the axum handler"

Where the distinction genuinely matters to the reader — the app's background
service has a different environment from their shell, which is why `qmake`
is not on its `PATH` — say *that*, in those words, rather than naming the
internal component.

## Honesty Rules

These are product requirements, not style preferences. Each one exists
because violating it shipped a bug.

- **A headline claims only what was measured.** "no qmake on PATH" — never
  "no Qt in this environment", from an app drawing its own window with
  libQt6Qml. Enforced by `headlines_claim_only_what_was_measured`.
- **"Nothing found" and "could not look" are different answers.** Report
  `unknown`, never `ok`, when a probe failed. A monitor that reassures you
  about something it never checked is worse than no monitor.
- **Never raise a false alarm.** A check probing for a binary named `clippy`
  reported a working toolchain as broken — there is no such binary, the
  package installs `cargo-clippy`.
- **Declared ≠ in effect.** On a declarative system these are two facts.
  Show both and let them disagree; never pretend a setting applied when it
  only wrote Nix source.
- **Displayed command ≠ executed command.** `command` is prose for a human
  and may lead with a dry-run. `run` is an explicit program + argv. Never
  derive one from the other.

## Privileges

The app holds no privilege of its own. Anything needing root goes through
`pkexec` → polkit → a prompt the user answers. **The prompt is the
authorisation.**

Two NixOS traps, both already paid for:

- `/run/current-system/sw/bin/pkexec` is **not setuid**; only
  `/run/wrappers/bin/pkexec` is. Search `/run/wrappers/bin` first.
- Seccomp-based systemd options (`SystemCallFilter`,
  `SystemCallArchitectures`, `LockPersonality`, `MemoryDenyWriteExecute`,
  `RestrictRealtime`, `RestrictSUIDSGID`) **imply `NoNewPrivileges`** in an
  unprivileged user unit, which makes setuid a no-op. `systemctl --user show`
  reports `NoNewPrivileges=no` while the kernel says `1`. Trust
  `/proc/<pid>/status`, not systemctl.

## Deploying

`nix/engine.nix` takes the **whole tree** as `src`, so *any* file change
rebuilds the engine to a new store path.

| Changed | To take effect |
|---|---|
| anything in the repo | `home-manager switch` + the printed `systemctl --user restart nixdash-engine.service` |
| `qml/`, `ui/` as well | close and reopen the window |
| panel icon / menu entry | `xfce4-panel -r` |

For UI work there is a cheaper loop than a switch, and the panel icon follows
it:

```bash
nix develop --command bash -c 'cargo build -p nixdash-ui && ./target/debug/nixdash-ui'
```

The menu entry and the panel launcher run a wrapper that starts **whichever
build is newer** — the local `target/debug/nixdash-ui` when its mtime beats the
generation symlink, the installed binary otherwise (`services.nixdash.ui.devBuild`,
null to always use the installed one). Store paths all share one epoch mtime,
which is why the comparison is against the generation link rather than the
store path. Without this the icon kept launching the last switched-in build
while a fresh one sat in the tree, and the two windows are indistinguishable.

`home.nix` sets `systemd.user.startServices = "suggest"`, so home-manager
prints the restart rather than running it — restarting user services
automatically takes xfconf down and kills the Xfce panel on this machine.
A changed service keeps running the **old** build until restarted, which the
`rust-build` panel reports.

## Security Notes

- The API is **unauthenticated** and bound to `127.0.0.1` unconditionally —
  not a setting. It must never be reachable from elsewhere.
- CORS is restricted to loopback origins. It was `permissive`, which was fine
  while every route was a read and is not fine now that a POST can raise a
  polkit prompt.
- `POST /api/actions/{id}/run` takes **no body**: the caller names an action,
  never a command, so the executable set is fixed at compile time.
- `POST /api/settings` does take a body, but only a key from a fixed list and
  a range- or enum-checked value. It writes exactly one generated file and
  rewrites it whole — it never parses or patches hand-written Nix.
