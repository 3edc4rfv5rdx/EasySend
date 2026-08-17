#!/usr/bin/env bash
#
# Keep the launcher icons in step with the drawing they come from:
#
#   tools/make_icon.py              -> assets/icon*.png   (the masters)
#   dart run flutter_launcher_icons -> android/.../res/*  (what the launcher reads)
#
# Nothing is redrawn unless it has to be: the generated icons are compared with
# the drawing by modification time, and only when they are older — or missing —
# are the two generators run.
#
# Its own step, and deliberately not part of a build. The release used to run the
# launcher-icon generator itself, which meant a build rewrote tracked files: after
# an icon change the APK carried icons that no commit recorded, and the version
# bump silently stopped folding into the previous commit because the tree was
# dirty for a reason nobody had asked for. 00-MakeAll.sh runs this before it
# builds, so a full run cannot go out with yesterday's icon.
#
# What it rewrites is listed at the end; those files belong in a commit of their
# own. No execute bit, the way 77-MakeMyKey.sh has none:  bash 02-MakeIcons.sh
#
set -e
cd "$(dirname "$0")"

# What the icons come from — the newest of these decides — and what comes out.
SOURCES="tools/make_icon.py assets/icon_small.png assets/icon_fg.png"
GENERATED_ROOT="android/app/src/main/res"

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    sed -n '2,20p' "$0"
    exit 0
fi

# Whether anything generated is older than the drawing, or simply not there.
#
# By modification time, which is the only thing to compare without doing the work
# anyway. Git does not preserve mtimes, so a fresh clone can answer yes when the
# content is already right; that costs one redraw which changes nothing, and the
# listing at the end says so.
needs_rebuild() {
    local newest="" src
    for src in $SOURCES; do
        [ -e "$src" ] || { echo "Missing $src"; return 0; }
        if [ -z "$newest" ] || [ "$src" -nt "$newest" ]; then newest="$src"; fi
    done

    local generated file
    generated=$(find "$GENERATED_ROOT" \
        \( -name 'ic_launcher.png' -o -name 'ic_launcher_foreground.png' \) \
        -type f 2>/dev/null || true)
    if [ -z "$generated" ]; then
        echo "No generated launcher icons under $GENERATED_ROOT"
        return 0
    fi

    while IFS= read -r file; do
        [ -n "$file" ] || continue
        if [ "$newest" -nt "$file" ]; then
            echo "Older than $newest: $file"
            return 0
        fi
    done <<STALE
$generated
STALE
    return 1
}

if ! needs_rebuild; then
    echo "Launcher icons are newer than the drawing; nothing to do."
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
    CHANGED=$(git status --porcelain -- assets "$GENERATED_ROOT")
    echo
    if [ -z "$CHANGED" ]; then
        echo "Nothing changed: the icons already matched the drawing."
    else
        echo "Rewritten — commit these on their own:"
        printf '%s\n' "$CHANGED"
    fi
fi
