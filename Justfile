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
[group('quality')]
gate:
    cargo fmt --all
    cargo test -p nixdash-engine
    ./qml-check

# Minutes, not seconds: clippy scoped to the engine alone measured 8m45s on
# this laptop for a change that touched nothing but string literals, which is
# why it is separate from `gate` rather than part of it.

# Gate a change to Rust code paths: the above, plus clippy.
[group('quality')]
gate-rust: gate
    cargo clippy -p nixdash-engine --all-targets -- -D warnings

# Inside the dev shell because cxx-qt needs Qt to build, which is exactly why
# `gate` does not run it.

# Gate everything, UI crate included. The slow, thorough one.
[group('quality')]
gate-all:
    nix develop --command bash -c 'cargo fmt --all && cargo test --all'
    ./qml-check

# Incremental, seconds, and the cheapest way to see a qml/ change - never a
# deploy for that.

# Build this window and run it against the engine already on :3100.
[group('window')]
desktop:
    nix develop --command bash -c 'cargo build -p nixdash-ui && ./target/debug/nixdash-ui'

# Rebuilds and relaunches on every change under qml/. Ctrl-C to stop.
#
# It used to only relaunch, on the belief that NIXDASH_QML_DIR made the binary
# read the directory instead of its compiled-in copy. It redirects Main.qml
# alone: every other component resolves to the compiled-in module, so a
# relaunch showed the PREVIOUS build of an edited ConfigSection or DevPage,
# silently and with no error anywhere. The build is not optional, which is
# what makes this ~2 min an iteration rather than a tenth of a second.
#
# Relaunch rather than in-process reload: cxx-qt-lib 0.10 has no
# clearComponentCache binding, and a fresh process cannot leave half a
# reloaded object tree behind. Startup is ~100ms.
#
# Caution, and the reason engine/tests/qml_registered.rs exists: in this mode
# a NEW .qml renders without being in either build.rs list, so the omission
# only bites at the next real build - or in the browser. Run `just gate`.

# Rebuild and relaunch the desktop window whenever qml/ changes. ~2 min each.
[group('window')]
watch-desktop:
    #!/usr/bin/env bash
    set -euo pipefail

    # Refuse to be the second copy of this loop.
    #
    # Two of these watching the same files and writing the same build tree is
    # not a slowdown, it is a race: one rewrites _deps/cxxqt-subbuild while
    # the other is configuring, and CMake fails inside ExternalProject with a
    # "No such file or directory" that looks nothing like its cause. Seen on
    # 2026-10-21 with two loops running, roughly every other build.
    #
    # A pid file rather than pgrep: this script's own `just` parent matches
    # any pattern specific enough to be useful, and `kill -0` distinguishes a
    # live holder from a stale file left by a SIGKILL.
    lock="${XDG_RUNTIME_DIR:-/tmp}/nixdash-watch-desktop.pid"
    if [ -e "$lock" ] && kill -0 "$(cat "$lock" 2>/dev/null)" 2>/dev/null; then
        echo "already running as pid $(cat "$lock")"
        echo "stop that one first:  kill $(cat "$lock")"
        exit 1
    fi
    echo $$ > "$lock"
    trap 'rm -f "$lock"' EXIT
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
            # Rebuild, because NIXDASH_QML_DIR only replaces Main.qml: every
            # other component resolves to the compiled-in module, so a
            # relaunch alone would show the PREVIOUS build of an edited
            # ConfigPage or DevPage, silently and with no error. See the
            # qml_url() comment in ui/src/main.rs.
            echo "building..."
            if ! nix develop --command cargo build -p nixdash-ui; then
                # Keep the running window and say so. Killing it on a failed
                # build would leave nothing on screen and the last good
                # version lost, for a typo.
                echo "build FAILED - the window still shows the last good build"
                sleep 1
                continue
            fi
            if [ -n "$ui" ]; then kill "$ui" 2>/dev/null || true; fi
            ./target/debug/nixdash-ui &
            ui=$!
            echo "reloaded (pid $ui)"
        fi
        sleep 1
    done

# The browser half, and a different shape of loop: the bundle cannot be
# reloaded in place, so each save costs a real emcc build of minutes. This is
# therefore a recipe to leave running in a pane and glance at - it prints when
# a build starts, how long it took, and whether it failed.
#
# The page reloads itself once the build lands: serve.sh injects a poller that
# watches the .wasm's Last-Modified. So the terminal says what happened and the
# tab follows, with nothing to press in either.
#
# It does NOT build on startup - attaching a pane should not cost minutes. The
# first save is the first build.
#
# A save during a build is picked up after it, so a flurry of edits can queue
# one extra rebuild. And it is an emcc build on a 7GB machine: do not leave it
# running while building something else.

# Rebuild the browser UI whenever qml/ changes, reporting each build.
[group('browser')]
watch-browser port="8099":
    #!/usr/bin/env bash
    set -euo pipefail

    # Refuse to be the second copy of this loop.
    #
    # Two of these watching the same files and writing the same build tree is
    # not a slowdown, it is a race: one rewrites _deps/cxxqt-subbuild while
    # the other is configuring, and CMake fails inside ExternalProject with a
    # "No such file or directory" that looks nothing like its cause. Seen on
    # 2026-10-21 with two loops running, roughly every other build.
    #
    # A pid file rather than pgrep: this script's own `just` parent matches
    # any pattern specific enough to be useful, and `kill -0` distinguishes a
    # live holder from a stale file left by a SIGKILL.
    lock="${XDG_RUNTIME_DIR:-/tmp}/nixdash-watch-browser.pid"
    if [ -e "$lock" ] && kill -0 "$(cat "$lock" 2>/dev/null)" 2>/dev/null; then
        echo "already running as pid $(cat "$lock")"
        echo "stop that one first:  kill $(cat "$lock")"
        exit 1
    fi
    echo $$ > "$lock"
    trap 'rm -f "$lock"' EXIT

    # One pane, one command: serve too, unless something already holds the
    # port - in which case leave it alone, since it is probably a server you
    # started deliberately and killing it would close the tab's supply.
    #
    # --quiet because the poller's HEAD every two seconds is the bulk of the
    # access log and would bury the build reports below. Real page and module
    # fetches still print.
    srv=""
    if ss -ltn 2>/dev/null | grep -q ":{{ port }} "; then
        echo "serving already on :{{ port }} - left as it is"
    else
        PORT={{ port }} ./ui-wasm/serve.sh --quiet &
        srv=$!
        echo "serving on :{{ port }} (pid $srv)"
    fi
    # Only the server this recipe started is its to stop.
    trap 'if [ -n "$srv" ]; then kill "$srv" 2>/dev/null || true; fi' EXIT

    echo "watching qml/ - a save rebuilds the browser UI. Ctrl-C to stop."
    last=""
    while true; do
        stamp=$(find qml -name '*.qml' -printf '%T@\n' | sort -n | tail -1)
        if [ "$stamp" != "$last" ]; then
            if [ -n "$last" ]; then
                echo
                echo "$(date +%H:%M:%S) rebuilding the browser UI ..."
                start=$SECONDS
                if nix develop .#wasm --command bash ui-wasm/build.sh; then
                    echo "$(date +%H:%M:%S) built in $((SECONDS - start))s - the open tab reloads itself"
                else
                    echo "$(date +%H:%M:%S) BUILD FAILED - the tab keeps the last good bundle"
                fi
            fi
            last="$stamp"
        fi
        sleep 2
    done

# Never takes :3100: stopping the service blanks the app you are looking at,
# and a dev engine holding that port makes the service crash-loop invisibly
# behind it. No dev shell needed - the engine does not link Qt.

# One line rather than two, so the Dev page can show the same string it runs
# and engine/tests/qml_command_lines.rs can check that it does.

# Run a second engine beside the service, on another port.
[group('engine')]
engine port="3199":
    cargo build -p nixdash-engine && NIXDASH_PORT={{ port }} ./target/debug/nixdash-engine

# A separate toolchain - emcc and a wasm32 Rust target - so its own dev shell,
# and minutes rather than seconds. Nothing else builds it: not `just desktop`, not
# a deploy.

# Rebuild the browser UI.
[group('browser')]
browser:
    nix develop .#wasm --command bash ui-wasm/build.sh

# Sends Cache-Control: no-cache, so a rebuild shows up on a plain reload
# instead of pairing a new .wasm with cached glue.

# Serve the browser UI on :8099.
[group('browser')]
serve port="8099":
    PORT={{ port }} ./ui-wasm/serve.sh

# ~15 minutes. Never reach for this just to see a change.
#
# All four steps, because a switch on its own finishes none of them. It
# installs a new engine and rewrites the unit while leaving the OLD process
# serving - reporting active the whole time - and it writes a panel launcher
# the panel will not re-read. Each was documented as something to run
# afterwards, in three different places, and a step you have to remember is a
# step that gets skipped.
#
# `&&` in spirit: every line is conditional on the one before, so a failed
# switch cannot restart the service into a build that did not happen. That
# was the argument for not running the restart automatically, and chaining
# satisfies it rather than ignoring it.
#
# nixdash-serve is started only if it exists. It is the browser UI's static
# server and it is optional - absent entirely unless
# services.nixdash.browser.enable is set - so its absence is a configuration,
# not a failure.

# Install, restart, serve, redraw: everything a new build needs.
[group('install')]
deploy:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "== home-manager switch (~15 min)"
    home-manager switch

    # Not optional, and the reason this recipe exists: a changed service keeps
    # running the old binary until restarted, while reporting active.
    echo "== restarting the service"
    systemctl --user restart nixdash-engine.service

    if systemctl --user cat nixdash-serve.service >/dev/null 2>&1; then
        # restart, NOT start: `start` on an already-active unit does nothing,
        # so a switch that changed the unit left the OLD command running
        # while systemd reported active - the same trap this recipe exists to
        # avoid for the engine. Seen on 2026-10-23: the installed ExecStart
        # passed the tree as an argument and the live process had no such
        # argument for fifteen minutes.
        echo "== restarting the browser UI's server"
        systemctl --user restart nixdash-serve.service
    else
        echo "== no nixdash-serve unit - services.nixdash.browser.enable is off"
    fi

    # Xfce COPIES a launcher's desktop file when it is dragged onto the panel,
    # so the panel holds its own copy and will not re-read the installed one
    # without this. The panel disappears and redraws; that is this command
    # working, not it failing.
    #
    # Two things make the obvious `xfce4-panel -r` wrong as the last line of a
    # recipe:
    #
    #   · with a panel running it messages that panel and returns, but with
    #     NO panel running it BECOMES the panel, in the foreground, and never
    #     returns - so the recipe appears to hang on this step. That is the
    #     likely case here, because restarting user services takes xfconf
    #     down and the panel with it on this machine.
    #   · `pgrep -x xfce4-panel` does not find it: the process runs wrapped,
    #     so `comm` is the truncated `.xfce4-panel-wr` and only the full
    #     command line matches.
    #
    # So: detect by command line, and detach either way, which leaves the
    # panel owned by the session rather than by this terminal.
    echo "== redrawing the panel"
    if pgrep -f 'xfce4-panel' >/dev/null 2>&1; then
        setsid --fork xfce4-panel -r >/dev/null 2>&1 </dev/null || true
        echo "   restarted - it blanks and redraws, which is it working"
    else
        echo "   no panel was running (the service restart takes it down) - starting one"
        setsid --fork xfce4-panel >/dev/null 2>&1 </dev/null || true
    fi

# The question behind "my change did not show up": a switch installs a new
# binary and rewrites the unit, but leaves the old process serving.

# The only line on the Dev page's board that is not a build, and it earns its
# place because "which build am I looking at" is the most expensive question in
# this project. The panel icon can be pinned to a store path, the installed
# binary and the tree binary are indistinguishable on screen, and `just
# desktop` rebuilds before you can look - so none of them answer *what do I
# have right now*. This runs exactly what is in target/debug, by path.
#
# Deliberately no NIXDASH_QML_DIR. It redirects Main.qml alone, so for any
# other component it shows the PREVIOUS build with no error of any kind - see
# qml_url() in ui/src/main.rs. Putting it here would enshrine that trap.

# Run the window that is already built, and build nothing.
[group('window')]
run:
    ./target/debug/nixdash-ui

# The convenience form of `run`, written after an afternoon of reading the
# wrong window: three were open at once - the installed build the panel icon
# had pinned to a store path, a dev build, and a browser tab - and nothing on
# screen said which was which. This closes every nixdash window it can
# account for, names each one, and starts exactly one.
#
# What it will NOT kill, deliberately:
#
#   · a watch loop. It is deliberate, and it owns a window it will relaunch.
#   · whatever holds :3100. That is the service this window talks to.
#   · a dev engine on :3199. You started it to compare against something.
#
# Those are reported instead - the same stance as
# hooks/nixdash-stray-check.sh, which says in its own comments that a check
# firing on normal work is a check that gets ignored.
#
# Windows are matched by resolving /proc/PID/exe, not by name: the installed
# binary runs as `.nixdash-ui-wrapped`, comm is truncated to 15 characters,
# and a pattern loose enough to catch both also catches this script.

# One window, this build, nothing else of mine in the way.
[group('window')]
fresh:
    #!/usr/bin/env bash
    set -uo pipefail

    closed=0
    for pid in $(pgrep -f nixdash-ui 2>/dev/null); do
        exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null) || continue
        # readlink appends " (deleted)" when the binary has been replaced
        # underneath a running process - which is the commonest stale window
        # of all: you rebuilt, and that window is still showing the build
        # that no longer exists on disk. Stripping it is load-bearing, not
        # tidiness; without it the one window you most want closed is the one
        # that gets skipped.
        stale=""
        case "$exe" in
            *" (deleted)") exe="${exe% (deleted)}"; stale=" - running a build since replaced" ;;
        esac
        case "$exe" in
            */target/debug/nixdash-ui|*/bin/.nixdash-ui-wrapped|*/bin/nixdash-ui) ;;
            *) continue ;;
        esac
        echo "closing window pid $pid  ($exe)$stale"
        kill "$pid" 2>/dev/null && closed=$((closed + 1))
    done
    [ "$closed" -eq 0 ] && echo "no windows were open"

    # Reported, never killed. Each of these is something you meant to start.
    for loop in watch-desktop watch-browser; do
        lock="${XDG_RUNTIME_DIR:-/tmp}/nixdash-$loop.pid"
        if [ -e "$lock" ] && kill -0 "$(cat "$lock" 2>/dev/null)" 2>/dev/null; then
            echo "note: $loop is running as pid $(cat "$lock") - it will relaunch its own window"
        fi
    done
    if curl -sf --max-time 1 http://127.0.0.1:3199/health >/dev/null 2>&1; then
        echo "note: a second engine is answering on :3199"
    fi

    # The build is not this recipe's job - `just desktop` builds and launches,
    # and conflating the two is how you end up unsure whether what you are
    # looking at was just compiled.
    echo "starting ./target/debug/nixdash-ui (built $(date -r ./target/debug/nixdash-ui +%H:%M))"
    exec ./target/debug/nixdash-ui

# What of mine is running: the service, loops, server, engines, windows, launchers.
[group('inspect')]
which:
    #!/usr/bin/env bash
    set -uo pipefail
    echo "unit ExecStart:"
    systemctl --user show -p ExecStart --value nixdash-engine.service
    echo "process serving:"
    readlink /proc/$(systemctl --user show -p MainPID --value nixdash-engine.service)/exe

    # The same question for the window, which has its own way of answering
    # wrong. Xfce COPIES a .desktop into ~/.config/xfce4/panel/launcher-N/
    # when you drag one onto the panel, freezing that moment's Exec. A store
    # path frozen there pins one build for ever and the newer-wins wrapper is
    # never consulted - so the icon kept starting a build from hours earlier
    # while every rebuild landed in target/debug, with the two windows
    # indistinguishable. Printed here because nothing else shows it: the
    # module's own entry is correct, and the panel's copy is outside Nix.
    #
    # *.desktop does not match a .desktop.bak-NNN, so backups are skipped by
    # the glob rather than by filtering.
    # Everything of yours that outlives a command, in one place.
    #
    # Reconstructing this by hand with ss and /proc is what most of
    # 2026-10-21 went into: a window from a store path the panel had pinned, a
    # server from the previous day serving a half-written bundle, two watch
    # loops racing, and an orphaned dev engine. Each was invisible, and each
    # looked exactly like the thing it was not.
    echo
    echo "watch loops:"
    any=""
    for loop in watch-desktop watch-browser; do
        lock="${XDG_RUNTIME_DIR:-/tmp}/nixdash-$loop.pid"
        locked=""
        if [ -e "$lock" ] && kill -0 "$(cat "$lock" 2>/dev/null)" 2>/dev/null; then
            locked=$(cat "$lock")
            echo "  $loop: pid $locked"
            any=yes
        fi
        # Looked for by process as WELL as by lock, because the lock only
        # exists for a loop started after the single-instance guard was
        # added. The first version of this check asked the lock alone and
        # reported "none" while two loops were running - a monitor
        # reassuring you about something it never looked at, which is the one
        # failure this project treats as worse than no monitor at all.
        for pid in $(ps -eo pid=,args= | grep -E "^[[:space:]]*[0-9]+ just $loop([[:space:]]|\$)" | awk '{print $1}'); do
            [ "$pid" = "$locked" ] && continue
            echo "  $loop: pid $pid  (no lock - predates the single-instance guard)"
            any=yes
        done
    done
    [ -n "$any" ] || echo "  none"

    echo "browser UI server:"
    srv=$(ss -ltnp 2>/dev/null | grep ':8099 ' | grep -oP 'pid=\K[0-9]+' | head -1)
    if [ -n "$srv" ]; then
        # The served tree comes from the ARGUMENT when there is one, and only
        # from cwd when there is not.
        #
        # Reading cwd alone was wrong the moment the unit started passing the
        # tree as an argument: systemd resolves a symlinked WorkingDirectory
        # once, so the unit's cwd is a release directory that no longer
        # decides anything, and this reported the right setup as broken.
        tree=$(tr '\0' '\n' < "/proc/$srv/cmdline" 2>/dev/null \
               | grep -v '^--' | grep '/' | tail -1)
        case "$tree" in
            */serve.py|"") tree=$(readlink "/proc/$srv/cwd" 2>/dev/null); from="cwd" ;;
            *) from="argument" ;;
        esac
        echo "  pid $srv serving $tree  (from its $from)"
        case "$tree" in
            */ui-wasm/current) ;;
            *) echo "  ^ not the published tree - a reload gets whatever is in there" ;;
        esac
        # Supervised or not changes how you replace it, so say which.
        if grep -qs 'nixdash-serve' "/proc/$srv/cgroup"; then
            echo "  owned by nixdash-serve.service - use systemctl, not kill"
        fi
    else
        echo "  none on :8099"
    fi

    echo "second engine:"
    if curl -sf --max-time 1 http://127.0.0.1:3199/health >/dev/null 2>&1; then
        echo "  answering on :3199"
    else
        echo "  none on :3199"
    fi

    echo "windows:"
    seen=""
    for pid in $(pgrep -f nixdash-ui 2>/dev/null); do
        exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || continue
        stale=""
        case "$exe" in
            *" (deleted)") exe="${exe% (deleted)}"; stale="  (build since replaced)" ;;
        esac
        case "$exe" in
            */target/debug/nixdash-ui) echo "  pid $pid  dev build$stale"; seen=yes ;;
            */bin/.nixdash-ui-wrapped|*/bin/nixdash-ui) echo "  pid $pid  installed$stale"; seen=yes ;;
        esac
    done
    [ -n "$seen" ] || echo "  none"

    echo
    echo "panel launchers pinned to a store path:"
    pinned=$(grep -s -l '^Exec=.*/nix/store/' ~/.config/xfce4/panel/launcher-*/*.desktop)
    if [ -n "$pinned" ]; then
        echo "$pinned" | sed 's|^|  |'
        echo "  ^ repoint Exec at ~/.nix-profile/bin/nixdash-ui-launch , then: xfce4-panel -r"
    else
        echo "  none - every launcher goes through a stable path"
    fi
