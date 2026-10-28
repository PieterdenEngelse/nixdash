# The Windows installer

`nixdash.wxs` builds a per-user MSI with WiX v5. The payload is a
`windeployqt` staging directory; the build that produces it is
[`.github/workflows/windows-msi.yml`](../../.github/workflows/windows-msi.yml).

## Why this cannot be built on the development machine

Two independent walls, both measured on 2026-10-28:

**The Qt UI has no cross path.** `pkgsCross.mingwW64.qt6.qtdeclarative` is
marked unsupported and does not evaluate, let alone build. The *engine* is
fine — it is pure Rust with no `std::os::unix` anywhere, so
`just engine-windows` produces a real PE binary (verified: magic `4d5a`, imports
only `kernel32`/`ws2_32`/`bcryptprimitives`/`msvcrt`/`ntdll`/`userenv`, no
mingw runtime DLLs to ship, and it serves `/health` under Wine). But cxx-qt
links against Qt, and there is no Qt here to link against.

**WiX cannot write an MSI on Linux.** `wix build` installs and runs via
`dotnet`, warns `WIX0000: The WiX Toolset only supports Windows … All
behavior after this point is undefined`, and the wall it eventually hits is
not subtle:

```
error WIX0001: System.DllNotFoundException: Unable to load shared library 'msi.dll'
```

Building the MSI database needs the Windows Installer library itself. Nothing
works around that.

### How much of this file was validated anyway

More than that error suggests. Driving `wix build` on Linux against a probe
copy of `nixdash.wxs` — the directory nesting flattened and the wildcard
separator switched to `/` — got all the way through parsing, compilation and
file harvesting to the `msi.dll` failure in the bind phase. So
`MajorUpgrade`, `MediaTemplate`, `Icon`, `ARPPRODUCTICON`, the `Files`
harvesting of the staged payload, the `Shortcut` with its `--spawn-engine`
argument, the `RegistryValue` key path and the `RemoveFolder` all passed
WiX's own validation. It also caught a real bug: XML comments may not contain
`--`, which the flag name had put in two of them.

Two things the probe had to change, and why the shipped file keeps them as
they are:

- **`Directory/@Name`.** WiX on Linux rejects `Name="Programs"` with
  `WIX0389: not a relative path`. A canonical four-line `.wxs` fails
  identically, so it is the tool, not this project.
- **`$(var.StageDir)\**`.** The backslash wildcard makes
  `HarvestFilesCommand.GetWildcardFiles` throw on Linux; `/` harvests fine.
  The shipped file keeps the backslash because that is the documented WiX
  idiom and certain on Windows, and swapping a certainty for a local
  convenience is the wrong trade for the artifact that actually ships.

## Building it

Push a `v*` tag, or run the workflow by hand from the Actions tab. To build
on a Windows machine directly:

```powershell
cargo build --release -p nixdash-engine
cargo build --release -p nixdash-ui          # needs CXXQT_QMAKE set to Qt's qmake.exe
mkdir stage
copy target\release\nixdash-ui.exe stage\
copy target\release\nixdash-engine.exe stage\
copy assets\nixdash.ico stage\
windeployqt --qmldir qml --release stage\nixdash-ui.exe
dotnet tool install --global wix --version 5.*
wix build packaging\wix\nixdash.wxs -arch x64 -d Version=0.1.0 -d StageDir=stage -o nixdash.msi
```

## What it installs, and what it deliberately does not

- Into `%LOCALAPPDATA%\Programs\nixdash`, **per user**, so there is no UAC
  prompt and the engine runs as the person who reads its output.
- A Start Menu shortcut that passes `--spawn-engine`, because there is no
  service: the UI starts the engine and kills it on exit
  (`ui/src/engine_proc.rs`).
- **No Windows Service**, which is the one thing MSI can do that NSIS cannot,
  and the reason is not laziness. A service runs in session 0 as SYSTEM with
  no user context, and every question the engine answers is about the current
  user's environment.
- **No firewall rule.** The engine binds 127.0.0.1 only, and Windows neither
  prompts for nor filters purely loopback listeners.
- **No installer dialogs** beyond the standard progress window. `WixUI_Minimal`
  would add a welcome and licence page, but it requires a licence in RTF, and
  nixdash is dual MIT-or-Apache-2.0 — one RTF cannot honestly present a
  choice of two. Left out rather than misrepresented.
- **Unsigned.** SmartScreen will warn on first run until the MSI is signed
  with a code-signing certificate.

## What the app can actually tell you on Windows

Less than on NixOS, and it says so rather than guessing. There is no
`/etc/nixos`, no Nix store, no `systemctl`, so the NixOS subject's panels all
report *could not look* — `Status::Unknown`, never `ok`. That is the honesty
rule in `CLAUDE.md` holding by construction: `Collector::sample` returns a
`Result`, and a failed probe degrades its own panel instead of inventing a
reading. Confirmed under Wine, where the engine logged
`collector failed panel="failed-units" error=systemctl unavailable for both scopes`.

The Qt and Rust subjects are the ones that still answer something, and they
are the reason a Windows build is interesting at all: they ask *will a build
work in this environment*, which is as real a question on Windows as here.
