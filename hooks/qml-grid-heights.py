#!/usr/bin/env python3
"""A GridLayout child that fills width should usually fill height too.

A Qt Quick Layout CENTRES an item that cannot grow, rather than aligning it to
the top of its cell. So in a row of sections with different row counts, the
short ones float in the middle of the row and no edge lines up - on the Qt
page that left two short panels about 60px below the tall one beside them.
`Layout.fillHeight: true` makes every item take its row's height, squaring off
both edges. The long version of this reasoning is in qml/SubjectPage.qml, on
the Loader inside its Repeater.

That comment sat in one file for two days while DevPage.qml was written
without it, and the gate passed. This is the part that was missing: something
that says so at the edit, not at the commit.

ADVISORY ON PURPOSE. It reports and never fails. The check is a heuristic with
real exceptions - an item that should keep its natural height is a legitimate
answer - so the call belongs to whoever is reading the page, not to a build.
That is also why this is not a test: engine/tests/qml_info.rs demands a
60-character written exemption, which is earned for "every control gets an
info button" and is not earned here.

Scoped to GridLayout only. RowLayout has the same centring behaviour, but a
RowLayout here is usually a label beside a control, where filling height is
not wanted - flagging those would be noise that teaches you to ignore it.

Usage:
  PostToolUse hook: payload on stdin, advisory on stdout as additionalContext.
  Verification:     qml-grid-heights.py --check qml/*.qml
"""

import json
import re
import sys

REPO = "/home/pde/Projects/nixdash"

STRING = re.compile(r'"(?:[^"\\]|\\.)*"')
LINE_COMMENT = re.compile(r"//.*$")
CHILD = re.compile(r"^\s*([A-Z][A-Za-z0-9_]*)\s*\{")
PROPERTY = re.compile(r"^\s*((?:readonly\s+|property\s+\w+\s+)?[\w.]+)\s*:")
COLUMNS_ONE = re.compile(r"^\s*columns\s*:\s*1\s*$")


def sanitized(lines):
    """Brace counting has to ignore braces in strings and comments. Strings
    first: a // inside a string ("http://...") is not a comment."""
    return [LINE_COMMENT.sub("", STRING.sub('""', line)) for line in lines]


def block_end(san, start):
    """Index of the line closing the block opened on `start`."""
    depth = 0
    for i in range(start, len(san)):
        depth += san[i].count("{") - san[i].count("}")
        if depth == 0:
            return i
    return len(san) - 1


def children(san, start, end):
    """Direct children of the block [start, end] as (type, from, to).

    Object literals inside an array - the `rows:` lists are full of them -
    move the depth around but never match CHILD, which needs a Type name
    before the brace.
    """
    found = []
    depth = 0
    i = start
    while i <= end:
        match = CHILD.match(san[i])
        if match and depth == 1:
            child_end = block_end(san, i)
            found.append((match.group(1), i, child_end))
            i = child_end + 1  # the child block is balanced, so depth is unchanged
            continue
        depth += san[i].count("{") - san[i].count("}")
        i += 1
    return found


def direct_properties(san, start, end):
    """Property names set on the block itself, not on anything nested in it."""
    names = set()
    depth = 0
    for i in range(start, end + 1):
        if depth == 1:
            match = PROPERTY.match(san[i])
            if match:
                names.add(match.group(1))
        depth += san[i].count("{") - san[i].count("}")
    return names


def offenders(lines):
    """-> [(type, line_number)] for grid children filling width but not height."""
    san = sanitized(lines)
    out = []
    for i, line in enumerate(san):
        if not re.match(r"^\s*GridLayout\s*\{", line):
            continue
        end = block_end(san, i)

        # A single column has no rows to line up, so nothing to fill against.
        if any(COLUMNS_ONE.match(san[n]) for n in range(i, end + 1)):
            continue

        for kind, start, stop in children(san, i, end):
            # A Repeater is not laid out itself; its delegate is the grid item.
            targets = (
                children(san, start, stop) if kind == "Repeater"
                else [(kind, start, stop)]
            )
            for name, first, last in targets:
                props = direct_properties(san, first, last)
                if "Layout.fillWidth" in props and "Layout.fillHeight" not in props:
                    out.append((name, first + 1))
    return out


def report(rel, found):
    heads = ", ".join(f"{name} (line {n})" for name, n in found)
    return (
        f"nixdash: {len(found)} GridLayout child(ren) in {rel} set "
        f"Layout.fillWidth without Layout.fillHeight: {heads}.\n"
        "A Qt Quick Layout centres an item that cannot grow, so in a row of "
        "unequal sections the short ones float mid-row and no edge lines up. "
        "Layout.fillHeight: true gives each item its row's height and squares "
        "off both edges - see the note on the Loader in qml/SubjectPage.qml.\n"
        "Advisory: an item that should keep its natural height is a fine "
        "answer. If that is the case here, say so and move on."
    )


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--check":
        bad = 0
        for path in sys.argv[2:]:
            with open(path) as fh:
                found = offenders(fh.read().split("\n"))
            if found:
                bad += len(found)
                print(report(path, found))
            else:
                print(f"{path}: ok")
        print(f"--- {bad} finding(s); advisory, exit 0 either way")
        return 0

    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    tool_input = payload.get("tool_input") or {}
    response = payload.get("tool_response") or {}
    path = tool_input.get("file_path") or (
        response.get("filePath") if isinstance(response, dict) else None
    )
    if not path or not path.startswith(REPO + "/"):
        return 0

    rel = path[len(REPO) + 1:]
    if not (rel.startswith("qml/") and rel.endswith(".qml")):
        return 0

    try:
        with open(path) as fh:
            found = offenders(fh.read().split("\n"))
    except OSError:
        return 0
    if not found:
        return 0

    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": report(rel, found),
            },
            "suppressOutput": True,
        },
        sys.stdout,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
