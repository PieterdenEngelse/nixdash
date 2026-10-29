# nixdash

Local-first **config and monitoring for one NixOS machine**: a Rust engine with
Qt/QML UIs (desktop, and the same QML compiled to WebAssembly).

Loopback only. No accounts, no telemetry.

## Download

Download one file, run one command, then open **nixdash** from the
application menu. The engine starts with the window and stops with it.

These link to **0.1.1** directly; the
[latest release](https://github.com/PieterdenEngelse/nixdash/releases/latest)
is always current if this table has fallen behind.

| Your system | Download | Then |
|---|---|---|
| Debian 12, Ubuntu 24.04 | [nixdash_0.1.1_debian12_amd64.deb](https://github.com/PieterdenEngelse/nixdash/releases/download/v0.1.1/nixdash_0.1.1_debian12_amd64.deb) | `sudo apt install ./nixdash_0.1.1_debian12_amd64.deb` |
| Debian 13 | [nixdash_0.1.1_debian13_amd64.deb](https://github.com/PieterdenEngelse/nixdash/releases/download/v0.1.1/nixdash_0.1.1_debian13_amd64.deb) | `sudo apt install ./nixdash_0.1.1_debian13_amd64.deb` |
| Fedora 41 | [nixdash-0.1.1-fedora41.x86_64.rpm](https://github.com/PieterdenEngelse/nixdash/releases/download/v0.1.1/nixdash-0.1.1-fedora41.x86_64.rpm) | `sudo dnf install ./nixdash-0.1.1-fedora41.x86_64.rpm` |
| Windows 10+ | [nixdash-0.1.1-x64.msi](https://github.com/PieterdenEngelse/nixdash/releases/download/v0.1.1/nixdash-0.1.1-x64.msi) | double-click it |
| **NixOS** | — | the home-manager module: [Installing](#installing), below |

Windows will say the publisher is unknown, because the MSI is unsigned:
*More info → Run anyway*. It installs per-user and never asks for an
administrator. Took the wrong Linux file? `apt` and `dnf` refuse it rather
than installing something that opens a broken window.

[On a machine without Nix](#on-a-machine-without-nix) has the rest: enabling
the engine at login, which panels can answer off NixOS, and how the packages
are built.

Or from a checkout, which is what [Developing](#developing) is about:

```sh
nix develop
cargo run -p nixdash-engine      # http://127.0.0.1:3100
cargo test
```

## What it does today

Three subjects, each answering the same two questions: *is this healthy right
now*, and *what would I change*.

| | Monitors | Prepares | Runs |
|---|---|---|---|
| **NixOS** | memory and PSI stall pressure · failed units, user **and** system scope · generations and whether a reboot is pending · free space on the store's filesystem | rebuild when `/etc/nixos` is newer than the running system · restart a failed unit · collect garbage · reboot into the current generation · check that escalation works at all | yes — via polkit |
| **Qt** | which `qmake` a build would pick up, its version and prefix, and whether that prefix holds every host tool `cxx-qt` needs | the `pkgs.qt6.env` merged-prefix snippet, and why a `symlinkJoin` fails | no — it's a Nix snippet |
| **Rust** | `rustc` version and path, host triple, which **target** std libraries are installed, whether `lld` is available | the fenix toolchain snippet for `wasm32-unknown-emscripten` · adding `lld` to the devShell | no — it's a Nix snippet |

The Qt and Rust panels answer *"will a build work in this environment?"*, not
*"is it installed"* — which is the question that actually costs an afternoon.
See [docs/panels.md](docs/panels.md) for how each check works and what a wrong
value looks like.

Every panel, every stat and every action carries a what / why / if-wrong
explanation behind an `i` button. A test fails if one is missing.

## Documentation

| | |
|---|---|
| [docs/panels.md](docs/panels.md) | what each panel measures, why that measure and not the obvious one, what a bad value means |
| [docs/actions.md](docs/actions.md) | the action model, and exactly what happens when you press Run |
| [docs/architecture.md](docs/architecture.md) | engine, two UIs from one QML tree, and why the boundaries sit where they do |

## Status

**All 12 phases done.** Six panels across three subjects - NixOS, Qt and
Rust - plus actions you can read, copy, or run, served to a native desktop app
and a WebAssembly build from one QML source, running as a home-manager user
service.

Every panel, stat and action carries a what/why/if-wrong explanation, enforced
by a test, and shown behind the `i` buttons in the UI.
See `~/docs/qt-app-plan.md` for the full plan.

| Phase | |
|---|---|
| 1 engine skeleton | **done** |
| 2 desktop UI (Qt/QML) | **done** |
| 3 wasm UI (shared QML) | **done** |
| 4 action model | **done** |
| 5 packaging (home-manager) | **done** |
| 6 more panels, docs | **done** |
| 7 info model (what/why/if-wrong, enforced) | **done** |
| 8 Monitor + Config pages | **done** |
| 9 info buttons in the UI | **done** |
| 10 Qt and Rust panels in the UI | **done** |
| 11 config actions (Nix snippets) | **done** |
| 11b running actions, via polkit | **done** |
| 12 docs | **done** |

## The rule this is built around

**The engine holds no privilege of its own, and nothing runs without a prompt
you answer.**

`nixos-rebuild`, `nix-collect-garbage -d`, restarting a system unit: all need
root. nixdash can start them, but it cannot authorise them. Root comes from
`pkexec`, which hands the decision to polkit, which asks you. The prompt *is*
the authorisation — the engine is not setuid, holds no credential, and has
nothing to fall back on if you dismiss it.

Three things keep that from becoming a blank cheque:

- **What runs is never what is displayed.** Each action carries an explicit
  program and argument list, separate from its prose. The displayed command is
  multi-line and commented — `nix-collect-garbage`'s leads with a dry-run —
  and executing that text would run the dry-run *and* the deletion, having
  shown you neither. The confirmation dialog shows the argv, not the prose.
- **The caller names an action, never a command.** `POST
  /api/actions/{id}/run` takes no body. There is no field for a program, an
  argument, or a flag. The set of things the engine can ever execute is the
  set of actions its providers offer, fixed at compile time.
- **Nix snippets stay un-runnable.** They are configuration for a file you
  own, not commands. The endpoint refuses them with 422 rather than
  improvising something from the snippet text.

> **This changed in phase 11b, and the change is real.** Until then the engine
> executed nothing at all, which made it auditable in a way it no longer is: a
> loopback port that can start a rebuild is a privileged surface, and the API
> has no authentication. The polkit prompt is the only thing between anything
> that can reach the port and a `nixos-rebuild switch`. CORS is restricted to
> loopback origins so a page in your browser cannot provoke that prompt, but
> an unexpected prompt is still a prompt someone might click through. If you
> want the old property back, run the engine with the UI pointed at it and
> simply never press Run — or drop the `run` field from the providers, which
> is the whole of the feature.

## API

| Route | |
|---|---|
| `GET /health` | `{"status":"ok","version":"..."}` |
| `GET /api/panels` | every panel's metadata + latest sample |
| `GET /api/panels/{id}?limit=N` | history, newest last (default 120, max 1000) |
| `GET /api/actions` | suggested actions; `run` is `null` when not executable |
| `POST /api/actions/{id}/run` | run that action. No body — the id is the whole request. `404` unknown id, `422` nix snippet |

```sh
curl -s localhost:3100/api/panels | jq
curl -s 'localhost:3100/api/panels/memory?limit=5' | jq '.samples[].value.available_kb'
```

## Panels

| id | interval | what |
|---|---|---|
| `memory` | 2s | `MemAvailable`, swap, and PSI stall pressure |
| `failed-units` | 15s | failed systemd units, user **and** system scope |
| `generations` | 60s | system generations, and whether a reboot is pending |
| `disk` | 30s | free space on the filesystem holding the Nix store |
| `qt` | 60s | which Qt a build would use, and whether its prefix is complete |
| `rust` | 60s | toolchain, and the target std libraries it can actually build for |

The Qt and Rust panels answer "will a build work in this environment?" rather
than "is it installed", and both describe the **engine's** environment — the
systemd service's — not whichever shell you are sitting in.

Severity and headline come from the engine, not the UI, so the two front-ends
cannot disagree about what a number means.

**[docs/panels.md](docs/panels.md)** has the rest: what each panel measures,
why that measure rather than the obvious one, the exact thresholds, and what a
wrong-looking value usually means.

## Adding a panel

Implement `Collector` and register it. Nothing else changes — no shared enum,
no router edit, no UI type.

```rust
impl Collector for MyCollector {
    fn meta(&self) -> PanelMeta { /* id, subject, interval_secs, info, stats */ }
    fn sample(&self) -> anyhow::Result<serde_json::Value> { /* ... */ }
    fn status(&self, v: &serde_json::Value) -> (Status, String) { /* ... */ }
}
```

Three conventions worth keeping:

- **Return `Err`, don't panic.** A failing collector marks its own panel
  `error` and leaves the rest of the engine alone.
- **Distinguish "nothing" from "couldn't look."** `failed-units` reports
  `unavailable_scopes` so zero failures is never confused with a broken query.
- **Explain every key you emit.** `meta().stats` needs a `StatInfo` for each
  one, and `every_panel_and_stat_is_explained` fails if it is missing or
  empty. The bar is the mechanism, not the label.

Each panel polls on its own interval. Memory wants 2s; shelling out to
`systemctl` that often would be waste, and later panels (store size) are far
slower still.

## Installing

On NixOS, either route below. On anything else, see [Download](#download).

### As a flake input

```nix
# flake.nix
inputs.nixdash.url = "github:PieterdenEngelse/nixdash";
```

```nix
# home.nix
{ inputs, ... }: {
  imports = [ inputs.nixdash.homeManagerModules.default ];

  services.nixdash = {
    enable = true;
    ui.autostart = true;   # optional: open the dashboard at login
  };
}
```

Or without home-manager at all:

```sh
nix run github:PieterdenEngelse/nixdash           # the engine
nix run github:PieterdenEngelse/nixdash#ui        # the desktop UI
nix profile install github:PieterdenEngelse/nixdash#ui
```

Every input of this flake is a `github:` URL so that these work. The
Qt-for-WebAssembly shell needs a local checkout of its Qt, and a flake
resolves all of its inputs whether or not you use them, so that shell lives
in `ui-wasm/flake.nix` rather than here — `nix develop ./ui-wasm`.

### From a clone

For channel-based home-manager, where there is no flake to add an input to.
The module is importable by path, so no flake plumbing is needed:

```sh
git clone https://github.com/PieterdenEngelse/nixdash ~/src/nixdash
```

```nix
# ~/.config/home-manager/modules/nixdash.nix
{ ... }: {
  imports = [ /home/you/src/nixdash/nix/hm-module.nix ];

  services.nixdash = {
    enable = true;
    ui.autostart = true;
  };
}
```

then add it to the `imports` list in your `home.nix` and switch.

It installs the engine and runs it as a **user** unit, installs the desktop UI
with a menu entry, and optionally autostarts it.

The unit carries **no** sandboxing options — not even the two that look free,
`LockPersonality` and `SystemCallArchitectures`, which are seccomp-based and
so cannot be set in an unprivileged user unit without also setting
`NoNewPrivileges`, which breaks `pkexec`. That is the price of the Run button,
and `nix/hm-module.nix` holds the option-by-option reasoning.

Options: `package`, `port`, `logLevel`, `autoStart`, `ui.enable`,
`ui.package`, `ui.autostart`.

The packages live in `nix/engine.nix` and `nix/ui.nix` and are shared by
`flake.nix` and the module, so `nix build` and the running service cannot
drift.

To try it without installing anything:

```sh
nix run .            # engine
nix run .#ui         # desktop UI
```

### On a machine without Nix

The install itself is the table at [the top of this file](#download) — the
distro is in each filename, and in the command, because downloading two of
them to compare is the obvious thing to do and `./nixdash_*.deb` would then
match both. What follows is everything that table leaves out.

A wrong download costs one legible error rather than an afternoon: there is
one build per Qt release line, because cxx-qt links Qt's private API, and
each package caps the Qt version it will install against. The
[packaging notes](packaging/linux/README.md) have the mechanism.

To keep the engine running in the background from login instead, so it is
collecting before you open the window:

```sh
systemctl --user enable --now nixdash-engine
```

That is the same shape as the home-manager module above, and the window
notices it is already there rather than starting a second one.

On any of these the NixOS panels report *could not look* rather than inventing
a reading: there is no `/etc/nixos` to read. The Qt and Rust panels, which ask
whether a build would work in this environment, are the ones that still
answer.

#### Building them

Not on a NixOS machine, and that is not a limitation of the setup. A native
package cannot reference `/nix/store`, and a build here links against Qt and
glibc 2.42 that no distribution ships; the Windows UI has no cross path at
all, because `pkgsCross.mingwW64.qt6` is unsupported. Each package is built
inside the system it targets by
[CI](.github/workflows/linux-packages.yml). The engine alone cross-compiles:

```sh
just engine-windows   # nixdash-engine.exe, the engine half of the MSI
```

| | Built in | Qt | glibc |
|---|---|---|---|
| `.deb` | `debian:12` | 6.4.2 | 2.36 |
| `.deb` | `debian:13` | 6.8.2 | 2.41 |
| `.rpm` | `fedora:41` | 6.8.3 | 2.40 |
| `.msi` | `windows-latest` | 6.8.3 | — |

## After installing

| | |
|---|---|
| Dashboard | application menu → System → nixdash, or `nixdash-ui` |
| Engine | `systemctl --user status nixdash-engine` |
| API | `http://127.0.0.1:3100` — **unauthenticated, loopback only** |
| Logs | `journalctl --user -u nixdash-engine` |

Nothing is written outside the Nix store and the generated unit; there is no
state directory, because the engine keeps its history in memory and loses it
on restart. That is deliberate — a monitor that accumulates its own data is a
second thing to manage.

### A note on `home-manager switch`

If your switch kills the Xfce panel, that is sd-switch restarting changed user
units - `xfconf.service` goes with them, taking the panel and any
`bwrap --die-with-parent` app. Set:

```nix
systemd.user.startServices = "suggest";
```

and the switch prints the `systemctl` commands for you to run instead. The
cost: a changed service keeps running the OLD version until you do.

## Developing

```sh
nix develop                        # engine + desktop UI
cargo test -p nixdash-engine                      # hermetic tests only
cargo test -p nixdash-engine -- --include-ignored  # + tests needing this host
cargo run  -p nixdash-engine       # :3100
cargo run  -p nixdash-ui           # desktop

nix develop ./ui-wasm                 # Qt-for-WebAssembly toolchain
./ui-wasm/build.sh && ./ui-wasm/serve.sh          # :8099
```

Tests that need a live systemd or `/nix/var/nix/profiles` are `#[ignore]`d so
`nix build` can run the rest in its sandbox. They are not optional — run them
with `--include-ignored` before trusting a change to a collector.

The dev shell sets `QT_FORCE_STDERR_LOGGING=1`. Without it a QML error gives
you a running process, no window and no output, which looks like a hang.

Iterate on the desktop UI: a QML change rebuilds in ~25s there versus ~4min
for wasm.

## Layout

```
engine/src/collector.rs    Collector trait, Panel + ring buffer
engine/src/collectors/     one module per panel
engine/src/actions/        one module per suggested command
engine/src/registry.rs     panel set, pollers
engine/src/api.rs          routes
qml/                       SHARED by both UIs - symlinked into each crate
ui/                        desktop (cxx-qt, pure Cargo)
ui-wasm/                   WebAssembly (CMake + corrosion)
nix/engine.nix             engine package
nix/ui.nix                 desktop UI package
nix/hm-module.nix          home-manager module
```

`qml/` existing once is the point. It is symlinked into `ui/` and
`ui-wasm/rust/` rather than copied, because two copies would make the
both-UIs decision cost double instead of nearly nothing. The symlink is also
required: a `../qml/...` path corrupts the generated Qt resource paths.

**[docs/architecture.md](docs/architecture.md)** covers why the engine is a
separate process, how the two builds differ, why the service is no longer
sandboxed, and the execution details (no shell, pipe draining, the pkexec
wrapper trap).

## Privacy

- **Loopback only.** The engine binds `127.0.0.1` unconditionally - not a
  setting. It has no authentication and no TLS, so it must not be reachable
  from anywhere else.
- **No accounts, no telemetry, no network calls.** Every panel reads local
  state: `/proc`, `systemctl`, `/nix/var/nix/profiles`, `df`. Nothing is sent
  anywhere, and the engine never fetches anything.
- **No privilege of its own.** It runs as you and reads only what you could
  already read. It can *start* a privileged action, but only through `pkexec`,
  and only if you authenticate at the polkit prompt. See
  [the rule this is built around](#the-rule-this-is-built-around) — including
  what that costs.
- **No persistent data.** History lives in memory and is lost on restart.

## License

Dual-licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option.
