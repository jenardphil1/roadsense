"""Replace the region of a source file between two anchor lines.

Usage:
    python3 splice.py TARGET START_ANCHOR END_ANCHOR NEW_CODE_FILE

Replaces [START_ANCHOR, END_ANCHOR) with the contents of NEW_CODE_FILE.
Both anchors must occur exactly once and START must precede END, or the script
exits non-zero without writing anything.
"""

import io
import sys


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__)
        return 2

    target, start, end, new_file = sys.argv[1:5]

    src = io.open(target, encoding="utf-8").read()
    new = io.open(new_file, encoding="utf-8").read()

    for name, anchor in (("start", start), ("end", end)):
        n = src.count(anchor)
        if n != 1:
            print("ERROR: %s anchor found %d times: %r" % (name, n, anchor))
            return 1

    i, j = src.index(start), src.index(end)
    if i >= j:
        print("ERROR: start anchor is not before end anchor")
        return 1

    out = src[:i] + new + src[j:]
    io.open(target, "w", encoding="utf-8").write(out)

    print(
        "OK %s: replaced %d lines with %d (file now %d lines)"
        % (target, src[i:j].count("\n"), new.count("\n"), out.count("\n"))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
