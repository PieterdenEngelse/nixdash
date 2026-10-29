# Actions

An action is something nixdash noticed you might want to do, with enough
context to decide whether you actually want to. It is offered only when live
state justifies it — there is no static list of "things you could do".

```
GET  /api/actions            what is currently worth doing
POST /api/actions/{id}/run   do it
```

## The shape of one

```rust
pub struct Action {
    pub id: String,
    pub title: String,
    pub subject: Subject,        // nixos | qt | rust
    pub kind: ActionKind,        // shell | nix
    pub why: String,             // runtime: what triggered it, now
    pub info: ActionInfo,        // static: mechanism, and risk
    pub command: String,         // for reading
    pub run: Option<RunCommand>, // for executing — not the same thing
    pub effects: Vec<String>,
    pub needs_root: bool,
    pub urgency: Urgency,        // routine | advised | needed
}
```

`why` and `info` are split because they answer different questions. `why` is
runtime and specific — *"something under /etc/nixos was edited 14 minutes ago,
after the current generation was built"*. `info` is static and explains the
mechanism and the risk, which a command line never tells you. An action with
no honest `why` should not exist.

## `command` is not `run`

This is the one thing worth understanding about this module.

`command` is **prose**. It is multi-line, it carries comments, and it often
leads with an inspection or dry-run step. `gc-store`'s is:

```sh
nix-collect-garbage --dry-run
# then, to actually delete:
sudo nix-collect-garbage -d
```

Execute that text verbatim and you run the survey **and** the deletion, having
shown nobody the survey — and the embedded `sudo` wants a tty that a
background service does not have. `restart-system-foo.service`'s display text
has the same shape: a `systemctl status` to read first, then the restart.

So execution uses a separate, explicit spec:

```rust
pub struct RunCommand {
    pub program: String,
    pub args: Vec<String>,
    pub elevate: bool,
}
```

`gc-store`'s is `nix-collect-garbage` `["-d"]` `elevate: true`. The
confirmation dialog shows **that**, not the block above it, and says so when
the two differ.

A test (`executable_commands_are_explicit_never_parsed_from_display_text`)
fails if any `program` ever contains a space, newline, `;`, `|`, `&` or `#` —
a later "simplification" that parses `command` cannot land quietly.

## What happens when you press Run

1. The UI `POST`s to `/api/actions/{id}/run`. **No body.** The caller names an
   action and nothing else — there is no field for a program, an argument or a
   flag, so the set of things the engine can ever execute is the set its
   providers offer, fixed at compile time.
2. The engine looks the action up in a freshly computed report. An id that is
   no longer offered is a `404`, not an error — actions come from live state,
   so one can legitimately disappear between listing and running because the
   unit recovered or the rebuild already happened.
3. `run: None` ⇒ `422`. Nix snippets are configuration for a file you own; no
   button can decide which file that is.
4. `argv` is assembled — `pkexec --disable-internal-agent` in front when
   `elevate` — and handed **straight to exec**. No shell. Nothing is
   word-split, glob-expanded or interpreted, which matters because an
   argument like a unit name comes from system state.
5. It runs under `spawn_blocking`, with both pipes drained on their own
   threads, and a 30-minute ceiling.
6. You get back the exact `argv`, the exit code, stdout, stderr, and an
   `error` string when it could not start at all.

### Where root comes from

`pkexec`, never `sudo`. sudo wants a terminal and a password on stdin; a
background service has neither and would hang or fail silently. pkexec raises
a desktop prompt — **the prompt is the authorisation**. The engine is not
setuid and holds no credential; dismiss the prompt and nothing happens.

`--disable-internal-agent` makes it fail cleanly when no polkit agent is
running, rather than blocking on a prompt nobody can see. Two exit codes are
translated because they are otherwise indistinguishable from the command's
own: `126` is *not authorised or dismissed*, `127` is *could not run at all*.

## What this costs

Stated plainly, because it is a real trade and it replaced a stronger
property:

- The API is **unauthenticated** and bound to loopback. Anything that can
  reach `:3100` can ask the engine to start a privileged action. The polkit
  prompt is the only thing between that and a rebuild.
- CORS is restricted to loopback origins for exactly this reason — it was
  `permissive`, which is fine for a read-only API and not fine for this. A
  page on the open web cannot provoke a prompt you did not go looking for.
  A page served from another loopback port still can, because the wasm UI is
  one.
- The systemd sandbox had to go. See
  [architecture.md](architecture.md#why-the-service-is-not-sandboxed).

If you want the old read-only property back: drop the `run` field from the
providers. That is the whole of the feature.

## Providers

| id | fires when | runs |
|---|---|---|
| `reboot-needed` | `/run/booted-system` ≠ `/run/current-system` | `systemctl reboot`, elevated |
| `config-drift` | newest mtime under `/etc/nixos` is after the current generation's | `nixos-rebuild switch`, elevated |
| `restart-{scope}-{unit}` | a unit is failed | `systemctl [--user] restart UNIT`; elevated only for system scope |
| `gc-store` | always, at `routine` urgency | `nix-collect-garbage -d`, elevated |
| `check-escalation` | always, when `pkexec` exists | `true`, elevated — **nothing**, on purpose |
| `apply-nixdash-settings` | a declared setting differs from the running one | `home-manager switch`, unelevated |
| `install-system-config` | the staged system file differs from the installed one | `install -m 0644 STAGED INSTALLED`, elevated |
| `qt-merged-prefix` | the Qt prefix is missing host tools | nothing — Nix snippet |
| `rebuild-wasm-ui` | the compiled `.wasm` is older than a file in `qml/` | `nix develop ./ui-wasm --command bash ui-wasm/build.sh` |
| `rust-emscripten-target` | the rustc **on PATH** has no `wasm32-unknown-emscripten` std | nothing — Nix snippet |
| `rust-lld` | `wasm32-unknown-unknown` is installed and `lld` is not on PATH | nothing — Nix snippet |
| `rust-src-missing` | `rust-analyzer` is installed but the std sources are not | nothing — Nix snippet |

Two of these are worth reading twice, because each states the scope of its
own probe rather than a conclusion about the machine.

`rust-emscripten-target` says *the rustc on PATH*, not "no Emscripten
target". It once said a Qt for WebAssembly build "cannot compile", which is a
claim about every environment here drawn from one — and false on this machine,
where the browser UI builds in `nix develop ./ui-wasm` against a toolchain that
carries exactly that target. Same failure as the Qt panel's old "no Qt in this
environment": a missing tool in the environment you looked at is not a missing
technology. The row still fires, because the rustc on PATH genuinely lacks the
target; what changed is that it no longer generalises.

`rust-lld` is gated on the target that needs it being installed, because `lld`
alone is not a problem. Its snippet quotes the real error text,
``error: linker `lld` not found`` — verified by compiling for the target rather
than guessed, which is how a probe for a binary named `clippy` once reported a
working toolchain as broken.

Note the asymmetry `restart-*` makes visible: a **user** unit is yours to
restart, a **system** unit prompts. `needs_root` mirrors `run.elevate`, and a
test fails if they ever disagree — a UI that said "needs root" and then
silently did not prompt would be lying about what just happened.

### `check-escalation`, and why a no-op action earns its row

Every other elevated action changes the machine, which makes *"does the Run
button actually work here?"* a question you can only answer by accepting a
consequence. That is a bad moment to discover that no polkit agent is running,
or that the unit was hardened in a way that blocks pkexec — the day you need
`nixos-rebuild switch` is not the day to find out.

So there is one action whose entire effect is the prompt. It elevates and runs
`true`. Success means escalation works end to end. The failure modes are the
useful part, and `runner` translates them: *not authorised* means the prompt
was dismissed or no agent is running to show it; *pkexec could not run the
command* usually means the service is still sandboxed, in which case nothing
else will escalate either.

It is the same question the Qt and Rust panels ask — *will this work in this
environment?* — applied to the engine's own ability to act. A test pins its
argument list as empty, so it cannot quietly grow an effect.

`gc-store` deliberately does **not** compute the reclaimable size.
`nix-collect-garbage --dry-run` walks the whole store and takes seconds to
minutes; doing that on every `GET /api/actions` would make a monitoring tool a
source of load. The dry-run is part of the text you can copy, so you see the
estimate at the moment you are deciding.

## Adding one

Implement `ActionProvider` and register it in `Actions::with_defaults`.

```rust
pub trait ActionProvider: Send + Sync + 'static {
    fn id(&self) -> &'static str;
    fn actions(&self) -> anyhow::Result<Vec<Action>>;
}
```

Providers must be **cheap and read-only** — they run on every
`GET /api/actions`. Anything slow (store size, network) belongs behind a
cached collector instead.

A provider that fails does not silently shorten the list: its error is
reported in `ActionsReport.errors` and shown in the UI, because a broken probe
that looks like "nothing to do" is the worst failure mode available.
