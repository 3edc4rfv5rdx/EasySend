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
# Run it by hand after changing anything in tools/make_icon.py, then commit what
# it rewrote — the generated files belong in a commit of their own:
#
#   bash 02-MakeIcons.sh
#   bash 02-MakeIcons.sh --check   # are the icons newer than the drawing?
#
# 00-MakeAll.sh asks --check before it builds, and says so rather than stopping.
#
# It has no execute bit on purpose, the way 77-MakeMyKey.sh has none: the icons
# change a few times in a project's life, and nothing that runs every day should
# be able to pick this up as a step.
#
set -e
cd "$(dirname "$0")"

# What the launcher icons are generated from, newest of these decides.
SOURCES="tools/make_icon.py assets/icon_small.png assets/icon_fg.png"
# What is generated from them: one per density, plus the adaptive foreground.
GENERATED_ROOT="android/app/src/main/res"

# Whether the generated resources are newer than everything they come from.
#
# By modification time, which is the only thing there is to compare without
# regenerating: content equality would mean doing the work anyway. That makes one
# false alarm possible — git does not preserve mtimes, so a fresh clone or a
# branch switch can leave a master looking newer than the icons built from it.
# Hence a sentence and a non-zero status, never a refusal to build.
check_freshness() {
    local newest="" src
    for src in $SOURCES; do
        if [ ! -e "$src" ]; then
            echo "Missing $src — nothing to compare the icons against."
            return 1
        fi
        if [ -z "$newest" ] || [ "$src" -nt "$newest" ]; then newest="$src"; fi
    done

    local generated stale=0 file
    generated=$(find "$GENERATED_ROOT" \
        \( -name 'ic_launcher.png' -o -name 'ic_launcher_foreground.png' \) \
        -type f 2>/dev/null || true)
    if [ -z "$generated" ]; then
        echo "No generated launcher icons under $GENERATED_ROOT."
        echo "Run: bash $(basename "$0")"
        return 1
    fi

    while IFS= read -r file; do
        [ -n "$file" ] || continue
        if [ "$newest" -nt "$file" ]; then
            stale=$((stale + 1))
            echo "Older than $newest: $file"
        fi
    done <<STALE
$generated
STALE

    if [ "$stale" -gt 0 ]; then
        echo "$stale generated icon(s) predate the drawing."
        echo "Run: bash $(basename "$0")"
        return 1
    fi
    echo "Launcher icons are newer than the drawing they come from."
    return 0
}

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    sed -n '2,25p' "$0"
    exit 0
fi

# Asked by 00-MakeAll.sh before it spends five minutes on an APK that would
# otherwise carry yesterday's launcher icon. Draws nothing, writes nothing.
if [ "$1" = "--check" ]; then
    check_freshness
    exit
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
