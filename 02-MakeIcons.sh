#!/usr/bin/env bash
#
# Bring the launcher resources up to date with the icon masters:
#
#   assets/icon_small.png, assets/icon_fg.png   ->   android/.../res/*
#
# Those two are what pubspec.yaml hands flutter_launcher_icons, and the res/
# files are generated from them. Nothing is regenerated unless it has to be: the
# two sides are compared by modification time, and the generator runs only when
# something under res/ is older — or missing.
#
# The masters themselves are drawn by tools/make_icon.py, which is run by hand
# when the drawing changes. This step does not touch them; it only carries them
# into the resources.
#
# Its own step, and deliberately not part of a build. The release used to run the
# generator itself, which meant a build rewrote tracked files: after an icon
# change the APK carried icons that no commit recorded, and the version bump
# silently stopped folding into the previous commit because the tree was dirty
# for a reason nobody had asked for. 00-MakeAll.sh runs this before it builds, so
# a full run cannot go out with yesterday's icon.
#
# What it rewrites is listed at the end; those files belong in a commit of their
# own. No execute bit, the way 77-MakeMyKey.sh has none:  bash 02-MakeIcons.sh
#
set -e
cd "$(dirname "$0")"

# The masters, as named in pubspec.yaml under flutter_launcher_icons — the newest
# of them decides — and what is generated from them.
MASTERS="assets/icon_small.png assets/icon_fg.png"
GENERATED_ROOT="android/app/src/main/res"

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    sed -n '2,24p' "$0"
    exit 0
fi

# Whether anything generated is older than the masters, or simply not there.
#
# By modification time, which is the only thing to compare without doing the work
# anyway. Git does not preserve mtimes, so a fresh clone can answer yes when the
# content is already right; that costs one regeneration which changes nothing, and
# the listing at the end says so.
needs_rebuild() {
    local newest="" master
    for master in $MASTERS; do
        [ -e "$master" ] || { echo "Missing $master"; return 0; }
        if [ -z "$newest" ] || [ "$master" -nt "$newest" ]; then
            newest="$master"
        fi
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
    echo "Launcher resources are newer than the masters; nothing to do."
    exit 0
fi

echo "=== Generating the launcher icons ==="
dart run flutter_launcher_icons

# What this run rewrote, so it can be committed on purpose rather than swept into
# the next commit by accident. Only inside a git work tree: the script has to keep
# working in a copy that is not one.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    CHANGED=$(git status --porcelain -- "$GENERATED_ROOT")
    echo
    if [ -z "$CHANGED" ]; then
        echo "Nothing changed: the resources already matched the masters."
    else
        echo "Rewritten — commit these on their own:"
        printf '%s\n' "$CHANGED"
    fi
fi
