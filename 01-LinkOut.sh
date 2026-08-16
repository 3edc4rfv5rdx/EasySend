#!/usr/bin/env bash
#
# Put the files of the newest build into OUT/ as links under their own
# names, and sweep everything else out of that folder:
#
#   OUT/EasySend-<version>-<build>-x86_64.AppImage
#   OUT/EasySend-<version>-<build>-arm64-v8a.apk
#   OUT/EasySend-<version>-<build>-armeabi-v7a.apk
#
# One place to copy the build from, instead of paths deep inside build/.
# The links are hard ones: the entry here is the file itself, so copying it
# elsewhere copies a build and not a dangling path, and the pruning of old APKs
# inside build/ leaves it whole. The name carries the version and the build
# number, so the listing says which build it is. Nothing is built here:
# 00-MakeAll.sh runs the same steps after a build, and this is for picking up a
# build that already exists.
#
cd "$(dirname "$0")"

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    sed -n '2,17p' "$0"
    exit 0
fi

MISSING=""
LINKED=""

link_latest() { # link_latest <candidate files...>
    local newest
    newest=$(ls -t "$@" 2>/dev/null | head -1)
    if [ -z "$newest" ] || [ ! -f "$newest" ]; then
        echo ">>> nothing to link into OUT"
        MISSING="yes"
        return 0
    fi
    local name
    name=$(basename "$newest")
    mkdir -p OUT
    ln -f "$newest" "OUT/$name"
    LINKED="$LINKED $name"
    echo "OUT/$name"
}

link_latest build/linux/*-x86_64.AppImage
link_latest build/app/outputs/flutter-apk/*arm64-v8a*.apk
# The 32-bit ARM split, for the TV box.
link_latest build/app/outputs/flutter-apk/*armeabi-v7a*.apk

# Everything else goes: the previous build's names, an ABI no longer built, a
# copy left behind. Only files and links — a directory somebody made here is
# not ours to remove.
if [ -d OUT ]; then
    for entry in OUT/* ; do
        [ -d "$entry" ] && continue
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        case " $LINKED " in
            *" $(basename "$entry") "*) continue ;;
        esac
        rm -f "$entry"
    done
fi

[ -n "$MISSING" ] && exit 1
exit 0
