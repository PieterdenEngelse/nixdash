# Architecture

One Rust engine, two Qt/QML front-ends, one QML tree.

```
                     ┌─ ui/       desktop   (cxx-qt, pure Cargo)
qml/  ──symlinked──→ ┤
                     └─ ui-wasm/  browser   (CMake + corrosion)
                            │
                            ↓  HTTP, loopback only
                     engine/  axum on 127.0.0.1:3100
                            │
                            ↓
                     /proc · systemctl · /nix/var/nix/profiles · statvfs · qmake · rustc
```

```
engine/src/collector.rs    Collector trait, Panel + ring buffer
engine/src/collectors/     one module per panel
engine/src/actions/        one module per action provider
engine/src/actions/runner.rs   execution: argv, pkexec, pipes, timeout
engine/src/registry.rs     panel set, pollers
engine/src/api.rs          routes
qml/                       SHARED by both UIs — symlinked into each crate
ui/                        desktop (cxx-qt, pure Cargo)
ui-wasm/                   WebAssembly (CMake + corrosion)
nix/engine.nix             engine package
nix/ui.nix                 desktop UI package
nix/hm-module.nix          home-manager module
```

## Why the engine is a separate process

The UI could have read `/proc` directly and skipped the HTTP hop. It does not,
for three reasons that all turned out to matter:

- **The wasm build cannot read anything.** A browser has no `/proc`. If
  collection lived in the UI, the wasm front-end would be a different program
  rather than the same one, and the shared QML tree would be a fiction.
- **History survives the window.** The engine samples on its own intervals as
  a user service, so closing the UI does not reset the memory sparkline.
- **Judgement happens once.** Severity and headline come from the engine, so
  the two UIs cannot disagree about what a number means.

The cost is an unauthenticated loopback port, which was cheap when every route
was a read and is not cheap now. See [actions.md](actions.md#what-this-costs).

## One QML tree, two builds

`qml/` exists once. `ui/qml` and `ui-wasm/rust/qml` are **directory symlinks**
to it, so an edit reaches both front-ends with no copying and no sync step.

The symlink is not just tidiness — it is required. A `../qml/...` path in
`qml_files` corrupts the generated Qt resource aliases, so the files have to
appear *inside* each crate.

The two builds differ in ways that are worth knowing before touching them:

| | desktop | wasm |
|---|---|---|
| build | pure Cargo | CMake + corrosion |
| toolchain | nixpkgs rustc | fenix (nixpkgs has no `wasm32-unknown-emscripten` std) |
| Qt | `pkgs.qt6.env` | `~/Projects/qt6-wasm` — Qt 6.11.2 cross-built from nixpkgs sources |
| shell | `nix develop` | `nix develop ./ui-wasm` |

`QT_MODULES` in the CMake side must match `build.rs`, or cxx-qt fails with
*"Qt module mismatch between cxx-qt-build and CMake!"*. Build traps for both
are indexed by their error message in `~/docs/qt.md`.

## Pages, and why there are only two levels

`Main.qml` is the shell: it owns the data and the navigation state, and the
pages below are presentational — they take properties and emit signals. That
keeps fetching in one place instead of three.

Navigation is a top tab (Monitor | Config) and optionally one subject drilled
into. That is the whole hierarchy; a router would be structure for its own
sake.

**The Monitor page exists so that most of the time you read nothing.** A grid
of every panel gives them all equal weight, so "Qt prefix complete" and "disk
at 95%" look identical until you read both. Instead: one card per subject
showing its *worst* panel, with anything `needed` promoted above the cards.

**The Config page is not a settings form.** This machine is configured
declaratively; input fields would either write somewhere Nix later overwrites
or fight Nix outright, and either way would lie about where configuration
lives. So each subject answers three questions — what is in effect, where it
is declared, what to change it to — and the third is a snippet you copy.

## Why the service is not sandboxed

The user unit used to carry `NoNewPrivileges`, `ProtectSystem=strict`,
`ProtectHome`, `PrivateTmp`, `RestrictNamespaces`, `MemoryDenyWriteExecute`
and a restricted address-family set. All of that is gone, and it is a
consequence of the Run button rather than an oversight.

**`pkexec` is setuid and execs its target in place** — same cgroup, same
namespaces, same mount view. Whatever restricts the unit restricts
`nixos-rebuild switch` too:

| setting | what it would break |
|---|---|
| `NoNewPrivileges` | setuid cannot take effect; pkexec simply fails |
| `ProtectSystem=strict` | `/nix/store` read-only — no build can finish |
| `RestrictNamespaces` | removes the namespaces Nix sandboxes builds in |
| `ProtectKernelTunables` / `ProtectControlGroups` | activation sets sysctls; systemd writes cgroups |
| `ProtectHome` | `nix` as root wants a writable `/root` |
| `PrivateTmp` | builds use `/tmp` and would not see the real one |
| `MemoryDenyWriteExecute` | gratuitous breakage for anything with a JIT |

These would not merely have failed to help — they would have broken the
feature in ways that are miserable to diagnose, because the failure surfaces
as a confusing Nix error rather than "the sandbox stopped you".

**Nothing is left, and the last two are the interesting ones.**
`LockPersonality` and `SystemCallArchitectures=native` look free — no
filesystem effect, no namespace effect — and were kept on exactly that
reasoning. They are implemented with **seccomp**, and systemd cannot install a
seccomp filter in an unprivileged user unit without also setting
`NoNewPrivileges`. So they silently re-enable the one setting that makes
setuid a no-op, while the unit goes on claiming otherwise:

```
systemctl --user show nixdash-engine -p NoNewPrivileges   →  no
grep NoNewPrivs /proc/$(pidof nixdash-engine)/status      →  1
```

pkexec then fails with `pkexec must be setuid root`, which sounds like a
broken polkit install rather than a sandbox option you chose. Two things make
it worse: `NoNewPrivs` is **inherited and can never be cleared**, so a stale
process keeps it across a config change until genuinely restarted; and the
`systemctl show` output actively misleads you, so `/proc/<pid>/status` is the
only honest source.

Adding **any** seccomp-based option here — `SystemCallFilter`,
`SystemCallArchitectures`, `LockPersonality`, `MemoryDenyWriteExecute`,
`RestrictRealtime`, `RestrictSUIDSGID` — stops privileged actions working, and
the error will not point at this file.

### The related NixOS trap

`/run/current-system/sw/bin/pkexec` exists and is mode `r-xr-xr-x` — **not
setuid**. The setuid copy is a separate wrapper at `/run/wrappers/bin/pkexec`.
Exec the system-profile one and pkexec refuses immediately, complaining it is
not setuid root — which reads like a broken polkit install rather than the
wrong path to the right program.

`runner::resolve_program` therefore searches `/run/wrappers/bin` **before**
`/run/current-system/sw/bin`. Resolving to an absolute path matters at all
because pkexec discards the caller's environment and substitutes
`PATH=/usr/sbin:/usr/bin:/sbin:/bin`, which on NixOS is very nearly empty.

## Execution details worth not re-deriving

- **No shell.** argv goes straight to exec, so a unit name from system state
  cannot become command injection.
- **Both pipes are drained on their own threads.** A pipe holds ~64K and
  `nixos-rebuild switch` emits far more. Polling `try_wait()` without reading
  would block the child on a full pipe while the engine waited for it to
  exit — a deadlock that only ends at the 30-minute timeout and looks exactly
  like a slow rebuild.
- **`spawn_blocking`.** A rebuild takes minutes; on a tokio worker it would
  stall every other request, including the polling the UI does to stay
  current.

## Testing

`cargo test` — 38 tests. The ones that encode decisions rather than behaviour:

| test | pins |
|---|---|
| `every_panel_and_stat_is_explained` | no stat ships without what/why/if-wrong |
| `executable_commands_are_explicit_never_parsed_from_display_text` | `run.program` is one executable, never a shell line |
| `the_run_endpoint_takes_no_command_from_the_caller` | the executable set stays fixed at compile time |
| `nix_snippets_are_offered_but_not_runnable` | `kind: nix` ⇒ 422 |
| `arguments_are_not_shell_interpreted` | a `;` in an argument stays literal |
| `pkexec_resolves_to_the_setuid_wrapper` | the wrappers trap above |
| generations mtime assertion | `symlink_metadata`, not `metadata` |

Integration tests never POST to an action that would actually execute
something — they run on a real machine, and a suite that collects garbage or
starts a rebuild would be a hazard rather than a test.
