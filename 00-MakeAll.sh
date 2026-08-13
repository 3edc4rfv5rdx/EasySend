#!/usr/bin/env bash
#
# Everything in one run: build the release APK, install it on the emulator and
# on the phone, then build the Linux release and pack it into an AppImage.
#
# A build that fails stops the run. A device that is not plugged in does not:
# an absent emulator should not cost you the AppImage.
#
# Finally OUT/ gets two fixed-name links to the newest x86_64 AppImage and the
# newest arm64-v8a APK.
#
cd "$(dirname "$0")"

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    sed -n '2,10p' "$0"
    exit 0
fi

SKIPPED=""

run() { # run <script> <fatal|optional>
    echo
    echo "=== $1 ==="
    if [ ! -x "$1" ]; then
        echo ">>> $1 is missing or not executable"
        [ "$2" = "fatal" ] && exit 1
        SKIPPED="$SKIPPED $1"
        return 0
    fi
    if ./"$1"; then
        return 0
    fi
    echo ">>> $1 failed"
    [ "$2" = "fatal" ] && exit 1
    SKIPPED="$SKIPPED $1"
}

run 10-MakeRelease.sh fatal
run 11-EmulRELEASE.sh optional
run 12-PhoneRELEASE.sh optional
# 14 builds the Linux release itself, so 13 would only do the same work twice.
run 14-MakeAppImage.sh fatal

# The real artifacts carry the version and the build number, which change on
# every run, so anything that points straight at one goes stale immediately —
# a launcher entry, a bookmark, an scp line in someone's notes. These two names
# never change. The links are relative, so moving the project keeps them alive,
# and the names come from the project rather than being spelled out here.
PROJ_NAME=$(grep -oP '^name:\s*\K\S+' pubspec.yaml)
PROJ_TITLE=$(grep -oP 'android:label="\K[^"]+' android/app/src/main/AndroidManifest.xml 2>/dev/null || true)
[ -n "$PROJ_TITLE" ] || PROJ_TITLE="$PROJ_NAME"

link_latest() { # link_latest <link name> <candidate files...>
    local name="$1"
    shift
    local newest
    newest=$(ls -t "$@" 2>/dev/null | head -1)
    if [ -z "$newest" ] || [ ! -f "$newest" ]; then
        echo ">>> nothing to link as OUT/$name"
        SKIPPED="$SKIPPED OUT/$name"
        return 0
    fi
    mkdir -p OUT
    ln -sfn "../$newest" "OUT/$name"
    # The target's own name carries the version and the build number, so the
    # line already says which build this link points at.
    echo "OUT/$name -> $(basename "$newest")"
}

echo
echo "=== OUT ==="
link_latest "$PROJ_TITLE-x86_64.AppImage" build/linux/*-x86_64.AppImage
link_latest "$PROJ_TITLE-arm64-v8a.apk" build/app/outputs/flutter-apk/*arm64-v8a*.apk

# OUT/ holds exactly these two entries and nothing else — that is the whole
# point of it: two names to reach for instead of hunting the right file across
# build directories. Anything else here is from an earlier naming, a renamed
# project, an ABI no longer built, or a copy left behind, and it goes. Only
# files and links: a directory somebody made here is not ours to remove.
if [ -d OUT ]; then
    find OUT -maxdepth 1 \( -type f -o -type l \) \
        ! -name "$PROJ_TITLE-x86_64.AppImage" \
        ! -name "$PROJ_TITLE-arm64-v8a.apk" -delete
    find OUT -maxdepth 1 -xtype l -delete
fi

echo
if [ -n "$SKIPPED" ]; then
    echo "Done, without:$SKIPPED"
else
    echo "Done: APK installed on both, AppImage built"
fi
