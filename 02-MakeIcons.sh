#!/usr/bin/env bash
#
# Draw the app icon and put it everywhere it belongs:
#
#   tools/make_icon.py          -> assets/icon*.png       (the masters)
#   dart run flutter_launcher_icons -> android/.../res/*  (what the launcher reads)
#
# Its own step, and deliberately not part of a build. The release used to run the
# launcher-icon generator itself, which meant a build rewrote tracked files: after
# an icon change the APK carried icons that no commit recorded, and the version
# bump silently stopped folding into the previous commit because the tree was
# dirty for a reason nobody had asked for.
#
# Run it after changing anything in tools/make_icon.py, then commit what it
# rewrote — the generated files belong in a commit of their own.
#
set -e
cd "$(dirname "$0")"

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    sed -n '2,16p' "$0"
    exit 0
fi

command -v python3 >/dev/null 2>&1 || {
    echo "python3 not found — tools/make_icon.py draws the masters with Pillow." >&2
    exit 1
}

echo "=== Drawing the masters ==="
python3 tools/make_icon.py

echo "=== Generating the launcher icons ==="
dart run flutter_launcher_icons

# What this run rewrote, so it can be committed on purpose rather than swept into
# the next commit by accident. Only inside a git work tree: the script has to keep
# working in a copy that is not one.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    CHANGED=$(git status --porcelain -- assets android/app/src/main/res)
    echo
    if [ -z "$CHANGED" ]; then
        echo "Nothing changed: the icons already matched the drawing."
    else
        echo "Rewritten — commit these on their own:"
        printf '%s\n' "$CHANGED"
    fi
fi
