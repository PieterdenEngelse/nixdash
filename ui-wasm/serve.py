#!/usr/bin/env python3
"""Static file server for the built browser UI, serving the current working
directory on 127.0.0.1.

Exists only because `python3 -m http.server` cannot send a header, and the one
missing header costs an afternoon. http.server sends `Last-Modified` but no
`ETag` and no `Cache-Control`, so a browser is free to apply heuristic
freshness: with no explicit lifetime it may reuse a cached copy for a while
without asking the server anything at all.

That is a trap for a Qt wasm bundle specifically. The 250K `.js` glue and the
25M `.wasm` are one artifact in two files - the `EM_ASM` table in the glue is
addressed by offsets baked into the module - and the glue keeps the same size
across rebuilds. So a reload can pair yesterday's glue with today's module,
and the browser reports:

    WebAssembly.instantiate(): Import #0 "env": module is not an object or
        function
    ASM_CONSTS[code] is not a function

Neither names a cache, both read as a broken build, and the bundle on disk is
fine. On 2026-10-18 this was diagnosed three times over - a real mid-relink
bundle, then a stale-loader theory that turned out false, then the cache -
before being fixed here.

`no-cache` is the fix and does not mean "do not store": it means revalidate
before reuse. The conditional request still gets a 304 from the
`If-Modified-Since` handling in SimpleHTTPRequestHandler, so an unchanged 25M
`.wasm` is not re-downloaded - it is only re-checked. Which is what makes a
fixed port safe to keep.
"""

import http.server
import sys


class RevalidateHandler(http.server.SimpleHTTPRequestHandler):
    """SimpleHTTPRequestHandler, but every response must be revalidated."""

    def end_headers(self):
        # Belongs on every response, including the 304s.
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()


def main() -> int:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8099

    # Threading, because the page fetches the glue and the module at once and
    # the module is 25M: a single-threaded server makes them queue.
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), RevalidateHandler)
    print(f"http://127.0.0.1:{port}/", flush=True)
    print("(the engine must also be running: cargo run -p nixdash-engine)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
