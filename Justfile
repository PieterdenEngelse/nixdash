# The one definition of every command this project needs.
#
# Phase 13f of docs/layout-plan.md, and its argument is the reason this file
# exists: "prose in two files is how the quality gate went unrun for a whole
# session." CLAUDE.md had eleven command lines and two of them were the same
# build spelled differently - `cd ui && cargo build` in one block,
# `cargo build -p nixdash-ui` in another. A recipe cannot drift from itself.
#
# `just` lives in the dev shell, so from outside it:
#
#     nix develop --command just <recipe>
#
# The recipes wrap `nix develop` themselves where a command needs it, so each
# one works from either side. A nested dev shell is harmless.
#
# What is deliberately NOT hidden: which commands need the dev shell. `ui`
# needs it because QMAKE is only set inside - without it the build dies on
# "Could not find Qt" - and `engine` does not need it at all. A recipe that
# wrapped everything in `nix develop` uniformly would erase that difference,
# which the Dev page exists to teach.
#
# Note on comments: `just --list` shows the LAST comment line above a recipe,
# so each one keeps a single-line summary adjacent and its reasoning above a
# blank line.

# Show the recipes.
default:
    @just --list

# Not `cargo test --all`: that builds the UI crate, which needs Qt. See
# `gate-all`.

# Gate a change to qml/, docs, or Rust strings. Seconds.
gate:
    cargo fmt --all
    cargo test -p nixdash-engine
    ./qml-check

# Minutes, not seconds: clippy scoped to the engine alone measured 8m45s on
# this laptop for a change that touched nothing but string literals, which is
# why it is separate from `gate` rather than part of it.

# Gate a change to Rust code paths: the above, plus clippy.
gate-rust: gate
    cargo clippy -p nixdash-engine --all-targets -- -D warnings

# Inside the dev shell because cxx-qt needs Qt to build, which is exactly why
# `gate` does not run it.

# Gate everything, UI crate included. The slow, thorough one.
gate-all:
    nix develop --command bash -c 'cargo fmt --all && cargo test --all'
    ./qml-check

# Incremental, seconds, and the cheapest way to see a qml/ change - never a
# deploy for that.

# Build this window and run it against the engine already on :3100.
desktop:
    nix develop --command bash -c 'cargo build -p nixdash-ui && ./target/debug/nixdash-ui'

# Builds once, then relaunches on every change under qml/ - no rebuild per
# edit, because NIXDASH_QML_DIR makes the binary read the directory instead of
# its compiled-in copy. Ctrl-C to stop.
#
# Relaunch rather than in-process reload: cxx-qt-lib 0.10 has no
# clearComponentCache binding, and a fresh process cannot leave half a
# reloaded object tree behind. Startup is ~100ms.
#
# Caution, and the reason engine/tests/qml_registered.rs exists: in this mode
# a NEW .qml renders without being in either build.rs list, so the omission
# only bites at the next real build - or in the browser. Run `just gate`.

# Relaunch the desktop window whenever qml/ changes.
watch:
    #!/usr/bin/env bash
    set -euo pipefail
    nix develop --command cargo build -p nixdash-ui
    echo "watching qml/ - Ctrl-C to stop"
    # Kill the window we started, by pid - not pkill by pattern, which would
    # also take a window you had opened yourself.
    ui=""
    trap 'if [ -n "$ui" ]; then kill "$ui" 2>/dev/null || true; fi' EXIT

    last=""
    while true; do
        # Newest mtime under qml/, as the whole change signal. Cheap, and it
        # notices deletions and renames as well as edits.
        stamp=$(find qml -name '*.qml' -printf '%T@\n' | sort -n | tail -1)
        if [ "$stamp" != "$last" ]; then
            last="$stamp"
            if [ -n "$ui" ]; then kill "$ui" 2>/dev/null || true; fi
            NIXDASH_QML_DIR="$PWD/qml" ./target/debug/nixdash-ui &
            ui=$!
            echo "reloaded (pid $ui)"
        fi
        sleep 1
    done

# Never takes :3100: stopping the service blanks the app you are looking at,
# and a dev engine holding that port makes the service crash-loop invisibly
# behind it. No dev shell needed - the engine does not link Qt.

# One line rather than two, so the Dev page can show the same string it runs
# and engine/tests/qml_command_lines.rs can check that it does.

# Run a second engine beside the service, on another port.
engine port="3199":
    cargo build -p nixdash-engine && NIXDASH_PORT={{ port }} ./target/debug/nixdash-engine

# A separate toolchain - emcc and a wasm32 Rust target - so its own dev shell,
# and minutes rather than seconds. Nothing else builds it: not `just desktop`, not
# a deploy.

# Rebuild the browser UI.
browser:
    nix develop .#wasm --command bash ui-wasm/build.sh

# Sends Cache-Control: no-cache, so a rebuild shows up on a plain reload
# instead of pairing a new .wasm with cached glue.

# Serve the browser UI on :8099.
serve port="8099":
    PORT={{ port }} ./ui-wasm/serve.sh

# ~15 minutes, and it prints a `systemctl --user restart` that is not
# optional - a changed service keeps running the old binary until restarted,
# while reporting active. Never reach for this just to see a change.

# Install, so the service and the launcher run the new build.
deploy:
    home-manager switch

# The question behind "my change did not show up": a switch installs a new
# binary and rewrites the unit, but leaves the old process serving.

# Show which binary the service is actually running.
which:
    @echo "unit ExecStart:"
    @systemctl --user show -p ExecStart --value nixdash-engine.service
    @echo "process serving:"
    @readlink /proc/$(systemctl --user show -p MainPID --value nixdash-engine.service)/exe
