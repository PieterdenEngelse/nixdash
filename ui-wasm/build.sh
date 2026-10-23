#!/usr/bin/env bash
# Build the wasm UI. Run inside:  nix develop .#wasm
set -euo pipefail
cd "$(dirname "$0")"
: "${QT_WASM_TOOLCHAIN:?not in the wasm dev shell - run: nix develop .#wasm}"

# One build at a time, whatever started it.
#
# Two builds sharing build/ do not just contend, they interleave: one wrote
# the glue and the other the module, and the pair that resulted failed to
# instantiate with `Import #0 "env": module is not an object or function` -
# which reads as a broken build rather than two halves of different ones.
# Seen on 2026-10-22 with a .js and a .wasm eleven minutes apart.
#
# The lock is here rather than in the Justfile because the recipes are not the
# only writers: `just browser`, `just watch-browser` and a cmake build run by
# hand all land in the same directory, and only this script is common to all
# of them.
exec 9>".build.lock"
if ! flock -n 9; then
    echo "another build holds the lock - waiting for it"
    flock 9
fi

cmake -G Ninja -B build \
  -DCMAKE_TOOLCHAIN_FILE="$QT_WASM_TOOLCHAIN" \
  -DQT_ADDITIONAL_PACKAGES_PREFIX_PATH="$QT_ADDITIONAL_PACKAGES_PREFIX_PATH" \
  -DQT_HOST_PATH="$QT_HOST_PATH" \
  -DCXXQT_QMAKE="$CXXQT_QMAKE" \
  -DCMAKE_BUILD_TYPE=Release \
  .

cmake --build build --parallel "${JOBS:-2}"

# Publish the three files as a set, and only now that the build has
# succeeded.
#
# build/ is a work area: during a link, and after an interrupted one, its
# files are a mixture of two builds. Serving it directly is what made that
# mixture the browser's problem. So the served tree is a separate directory
# swapped in by renaming a symlink, which is atomic - the tab either sees the
# previous build entire or this one entire, never half of each.
#
# `ln -s` then `mv -T`, not `ln -sfn`: the latter unlinks before it links, so
# there is a moment with no symlink at all, and a request arriving then 404s.
stamp=$(date +%Y%m%d-%H%M%S)
rel="releases/$stamp"
mkdir -p "$rel"
# The RUNTIME set, which is five files and not three. The page loads
# qtloader.js - that is what turns "Loading..." into the app - and qtlogo.svg
# while it waits. Publishing only the app's own three worked by accident for
# as long as build/ was served directly, because these sat beside them there;
# in a published tree they 404 and the page says Loading for ever, with no
# error anywhere.
for f in nixdash_ui_wasm_app.html nixdash_ui_wasm_app.js nixdash_ui_wasm_app.wasm \
         qtloader.js qtlogo.svg; do
    cp "build/$f" "$rel/"
done

# And check the page can resolve everything it asks for, rather than trusting
# the list above to stay complete: a Qt upgrade that adds a file would
# otherwise reappear as a permanent "Loading...". Fail here, where the message
# can be read, instead of in a browser console that says nothing.
missing=""
for ref in $(grep -oE '(src|href)="[^"]+"' "$rel/nixdash_ui_wasm_app.html" \
             | sed 's/.*="//; s/"$//'); do
    case "$ref" in http*|data:*|"") continue ;; esac
    [ -e "$rel/$ref" ] || missing="$missing $ref"
done
if [ -n "$missing" ]; then
    echo "the published tree would be missing:$missing" >&2
    echo "add it to the runtime set in $0" >&2
    rm -rf "$rel"
    exit 1
fi
# The root path serves this; see the note in serve.sh.
ln -sfn nixdash_ui_wasm_app.html "$rel/index.html"
# -f on the temp link, because an interrupted run can leave one behind and a
# plain `ln -s` would then fail the script. The temp name is ours, so forcing
# it is safe; `current` itself is only ever replaced by the rename below.
ln -sfn "$rel" current.tmp
mv -Tf current.tmp current

# Keep a few, so a bad build can be stepped back to by hand, and the tree
# does not grow by 13 MB a save.
ls -1dt releases/*/ 2>/dev/null | tail -n +4 | xargs -r rm -rf

echo
ls -la current/nixdash_ui_wasm_app.{html,js,wasm}
