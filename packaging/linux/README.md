# The Linux packages

A `.deb` and an `.rpm`, both built by
[`.github/workflows/linux-packages.yml`](../../.github/workflows/linux-packages.yml).
The packaging itself is declared in `[package.metadata.deb]` and
`[package.metadata.generate-rpm]` in [`ui/Cargo.toml`](../../ui/Cargo.toml).

On NixOS, use the home-manager module instead — see the project README.
These are for machines without Nix.

## Why they cannot be built here

Not for want of tooling: `cargo-deb`, `dpkg` and `rpm` are all in nixpkgs and
run on this machine. The problem is what they would package. A build on NixOS
links against Qt and glibc in `/nix/store`, and a native package cannot
reference `/nix/store` at all — the dependency would be unsatisfiable, and the
binary would look for a glibc 2.42 that the target does not have. Each package
is therefore built inside the distribution it targets.

## What was tested on the development machine anyway

More than the "needs CI" framing suggests. Container images unpacked with
`skopeo` and entered with `bwrap` give a real Debian and a real Fedora
without a container daemon or root, and that covers everything except
compiling against the distro's Qt:

- **Both packages were generated here** against real release binaries.
  `cargo-deb` produced a `.deb` whose layout, permissions and generated
  `copyright` are correct; `cargo generate-rpm` produced an `.rpm` with the
  right eight paths, which also confirmed the asset-path convention noted in
  `ui/Cargo.toml`.
- **The `.deb` installs on Debian 12.** `apt` resolved every hand-written QML
  dependency and pulled all five in at 6.4.2, and each file landed where the
  table above says. The package ends up `iU` rather than `ii`, but that is the
  sandbox: `dpkg --configure nixdash` reports "dependency problems", and the
  packages actually failing are `dbus` and `fontconfig`, whose postinst
  scripts cannot run in a user namespace. nixdash ships no maintainer scripts
  of its own.
- **`auto-req` works.** The generated `.rpm` requires every `libQt6*` soname
  without any of them being listed by hand, which is the claim that the
  dependency list is small on purpose rather than incomplete.
- **The Nix-built payload is confirmed useless off NixOS**, which is the whole
  reason for CI. On Debian the engine fails with `cannot execute: required
  file not found` — it asks for the interpreter
  `/nix/store/…-glibc-2.42-84/lib/ld-linux-x86-64.so.2`. On Fedora, `dnf`
  rejects the `.rpm` for `libQt6Core.so.6(Qt_6.11)`, `libicudata.so.76` and
  `libvulkan.so()`: Nix sonames that Fedora has no provider for.

Two things still only CI can do: compile against the distribution's own Qt,
and configure the package as real root.

One wrinkle worth keeping if you reproduce this: `apt` inside `bwrap` needs
`-o APT::Sandbox::User=root`, because it otherwise drops privileges to the
`_apt` user, which has no mapping in the namespace and dies with
`Method http has died unexpectedly! … error code (112)`.

## What each targets

| | Built in | Qt | glibc | Runs on |
|---|---|---|---|---|
| `.deb` | `debian:12` | 6.4.2 | 2.36 | Debian 12, Ubuntu 24.04 |
| `.deb` | `debian:13` | 6.8 | 2.41 | Debian 13 |
| `.rpm` | `fedora:41` | 6.8 | 2.40 | Fedora 41 |

Every figure in that table was measured by running the distro, not read off a
wiki: Debian 12.15 reports glibc 2.36 and `qml6-module-qtquick` 6.4.2+dfsg-1;
Ubuntu 24.04.5 reports glibc 2.39 and the same Qt 6.4.2, which is why one
`.deb` serves both; Fedora 41 reports glibc 2.40 and `qt6-qtdeclarative`
6.8.3.

## One build per Qt minor, not per glibc floor

This is the constraint that decides how many packages there are, and it is
not the glibc floor.

**cxx-qt links Qt's private API.** `readelf -V` on `nixdash-ui` shows it
requiring three version tags:

```
Qt_6
Qt_6.11
Qt_6_PRIVATE_API
```

`Qt_6_PRIVATE_API` carries no version, and Qt does not promise that its
private API is stable across minor releases. So a binary built against Qt
6.4.2 can fail at runtime on 6.8 while the `libqt6qml6 (>= 6.4.2)` dependency
`$auto` generated for it is perfectly satisfied — the package manager has
nothing to object to. That is why `debian:13` is a separate build rather than
being covered by the `debian:12` one, even though its glibc is higher and
would otherwise be the only thing that mattered.

The engine has none of those tags, because `nix/engine.nix` keeps it
Qt-free — which is also why it is the half that cross-compiles to Windows.

### Taking the wrong file is refused, not tolerated

The version tags give no protection by themselves: `Qt_6_PRIVATE_API` is
provided by every Qt 6, and the versioned tags are forward-compatible, so a
6.4-built binary satisfies a 6.8 system. `dpkg-shlibdeps` likewise produces
only a *lower* bound (`libqt6qml6 >= 6.4.2`). Left at that, a user who
downloads the wrong `.deb` gets a successful install and a broken window.

So each build caps the upper bound too:

- **Debian** — `cargo deb --variant debian12` (or `debian13`) adds
  `libqt6qml6 (<< 6.5)` / `(<< 6.9)`. `libQt6Qml` is the library whose
  private API the UI links, so capping it is the targeted fix.
- **Fedora** — an rpm *rich* dependency,
  `(qt6-qtdeclarative >= 6.8 with qt6-qtdeclarative < 6.9)`. A plain map
  cannot express a range, TOML having no duplicate keys, and putting rpm's
  boolean syntax in the dependency name is the way round it.

Both were tested. Installing the `debian:12` package on Debian 13 is refused:

```
Unable to satisfy dependencies. Reached two conflicting decisions:
 1. nixdash:amd64=0.1.0-1 is selected for install
 2. nixdash:amd64 Depends libqt6qml6 (< 6.5)
    but none of the choices are installable
```

and the Fedora rich dependency resolves cleanly against Fedora 41's 6.8.3.
A wrong download now costs the user one legible error instead of an
afternoon.

Containers rather than runner images, because the glibc floor is the single
most important property of these artifacts and a container tag pins it, where
`ubuntu-22.04` is retired on GitHub's schedule, not ours.

The floor is the cost of this format. Ubuntu 22.04 (glibc 2.35) is below it.
Dropping to a `debian:11` build would reach further back and there is no Qt 6
in bullseye, so that is not a trade available — it would mean building Qt too.

## What gets installed

| Path | |
|---|---|
| `/usr/bin/nixdash-ui`, `/usr/bin/nixdash-engine` | both halves, side by side |
| `/usr/lib/systemd/user/nixdash-engine.service` | the engine as a **user** unit, not enabled |
| `/usr/share/applications/nixdash.desktop` | menu entry |
| `/usr/share/icons/hicolor/scalable/apps/nixdash.svg` | themed icon |

The unit is **not enabled on install**. Neither Debian nor Fedora enables user
units from a package, and deciding that every user on a machine gets a
background service is not the packager's call:

```sh
systemctl --user enable --now nixdash-engine
```

Until then the menu entry still works — it passes `--spawn-engine` and the UI
starts its own engine, killing it when the window closes. Enabling the unit
later costs nothing: the UI finds the port already answering and attaches
instead of starting a second engine. That logic is in
[`ui/src/engine_proc.rs`](../../ui/src/engine_proc.rs).

## The dependency that has to be named by hand

`$auto` on Debian and `auto-req = "auto"` on Fedora both read the ELF and
derive a dependency per linked library, so the `libQt6*` list never needs
maintaining. **QML modules are invisible to both**: they are loaded by name at
runtime through the QML engine rather than linked, so the binary carries no
trace of them, and a missing one is not a link error but a blank window at
first launch.

`qml/*.qml` imports exactly `QtQuick`, `QtQuick.Controls` and
`QtQuick.Layouts`, and `ui/src/main.rs` sets the Fusion style, which Controls
loads at runtime. Those are listed explicitly in `ui/Cargo.toml`. **Adding a
QML import means adding a package dependency there**, and nothing in the build
will remind you.

Both CI jobs install the package they just built with `apt`/`dnf` rather than
`dpkg -i`, so a dependency named *wrongly* fails the build instead of reaching
a user. A dependency that is merely *missing* needs more than that, because
nothing objects to it: the jobs also launch the installed UI under `xvfb-run`
and fail if its log mentions QML. That step doubles as the only test of the
sibling lookup in `ui/src/engine_proc.rs` — the engine answering on 3100
proves the UI found `nixdash-engine` beside itself and started it. It cannot
be run on the development machine, where `CLAUDE.md` forbids putting the
window on the author's screen.

## What the app can tell you on Debian or Fedora

Less than on NixOS, and it says so. There is no `/etc/nixos`, no Nix store and
no `nixos-rebuild`, so the NixOS subject's panels report *could not look* —
`Status::Unknown`, never `ok`. That is the honesty rule in `CLAUDE.md` holding
by construction: `Collector::sample` returns a `Result`, and a failed probe
degrades its own panel rather than inventing a reading.

The Qt and Rust subjects are what still answer, and they are the reason this
package is worth shipping: they ask *will a build work in this environment*,
which is as real a question on Fedora as here.
