#!/usr/bin/env bash
# Qt wasm must be served over http:// - file:// is blocked by CORS.
set -euo pipefail
cd "$(dirname "$0")"
HERE="$PWD"
command -v python3 >/dev/null || { echo "run inside: nix develop .#wasm" >&2; exit 1; }
# Serve the PUBLISHED tree, not the work area.
#
# build/ holds a mixture of two builds during a link and after an interrupted
# one, and serving it made that mixture the browser's problem: a glue and a
# module from different builds fail to instantiate with a message that reads
# as a broken build. build.sh now copies the three files into releases/<stamp>
# and flips `current` at it by renaming, so this only ever sees one build.
#
# build/ remains the fallback for a tree built before that change, or by
# running cmake by hand - with a warning, because that is the arrangement the
# mixing came from.
if [ -L current ] && [ -f current/nixdash_ui_wasm_app.html ]; then
    root=current
elif [ -f build/nixdash_ui_wasm_app.html ]; then
    echo "warning: serving build/ directly - nothing published yet." >&2
    echo "         a build landing while a tab loads can mix two builds;" >&2
    echo "         run ./build.sh to publish and serve that instead." >&2
    root=build
else
    echo "run ./build.sh first" >&2
    exit 1
fi
cd "$root"
PORT="${PORT:-8099}"

# Who already has the port, and is it serving the right thing?
#
# This used to exec straight into python and let bind(2) fail, which prints a
# twelve-line traceback ending in "Address already in use" - true, and silent
# about the two facts that matter: which process, and what it is serving. The
# holder today was a server from the day before whose working directory was
# build/, so it was quietly serving a half-written bundle while a freshly
# published one sat beside it.
#
# Three answers, because they need three different actions: it is us and
# correct (nothing to do), it is us and serving the wrong tree (replace it),
# or it is not ours at all (your call, and we will not touch it).
holder=$(ss -ltnp 2>/dev/null | grep ":$PORT " | grep -oP 'pid=\K[0-9]+' | head -1)
if [ -n "$holder" ]; then
    hcwd=$(readlink "/proc/$holder/cwd" 2>/dev/null || true)
    hcmd=$(tr '\0' ' ' < "/proc/$holder/cmdline" 2>/dev/null || true)
    case "$hcmd" in
        *serve.py*)
            if [ "$hcwd" = "$PWD" ]; then
                echo "already serving $root on :$PORT (pid $holder) - nothing to do"
                exit 0
            fi
            echo "a nixdash server already holds :$PORT (pid $holder)," >&2
            echo "  serving: $hcwd" >&2
            echo "  wanted:  $PWD" >&2
            echo "It is serving a different tree, so a reload would get that one." >&2
            echo "Replace it:  kill $holder && $0 $*" >&2
            exit 1
            ;;
        *)
            echo ":$PORT is held by pid $holder, which is not a nixdash server:" >&2
            echo "  $hcmd" >&2
            echo "Pick another port:  PORT=8098 $0 $*" >&2
            exit 1
            ;;
    esac
fi

# Serve the app at / as well as under its Qt-generated name. Without this the
# root path is a directory listing of the build tree, which reads as "nothing
# is here" and is the wrong first impression of a working build. http.server
# serves index.html for a directory, and follows the symlink.
#
# build.sh makes this in a published tree; doing it here too covers the
# build/ fallback above.
ln -sfn nixdash_ui_wasm_app.html index.html

# serve.py rather than `python3 -m http.server`, for one header: without
# Cache-Control the browser may reuse the cached .js glue against a freshly
# built .wasm, which fails as though the build were broken. The port stays
# fixed because of that file; see its docstring.
# "$@" so `--quiet` reaches it; see serve.py. `just watch-browser` passes it,
# because it shares a pane with its own build reports.
exec python3 "$HERE/serve.py" "$PORT" "$@"
