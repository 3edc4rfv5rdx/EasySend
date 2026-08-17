#!/usr/bin/env bash
#
# Everything in one run: build the release APK, install it on the emulator and
# on the phone, then build the Linux release and pack it into an AppImage.
#
# A build that fails stops the run. A device that is not plugged in does not:
# an absent emulator should not cost you the AppImage.
#
# Finally 01-LinkOut.sh puts the AppImage and the two ARM APKs into OUT/ as
# links under their own names, and sweeps whatever else was there.
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

# The icons come first, and only redraw themselves when they are older than the
# drawing — otherwise the build would spend its five minutes on an APK carrying
# yesterday's launcher icon. Run through bash: that step has no execute bit.
echo
echo "=== 02-MakeIcons.sh ==="
bash 02-MakeIcons.sh

run 10-MakeRelease.sh fatal
run 11-EmulRELEASE.sh optional
run 12-PhoneRELEASE.sh optional
# 14 builds the Linux release itself, so 13 would only do the same work twice.
run 14-MakeAppImage.sh fatal
# The two files of this build, linked into OUT/ under their own names. Its own
# script, so the same step also works on a build that already exists.
run 01-LinkOut.sh optional

echo
if [ -n "$SKIPPED" ]; then
    echo "Done, without:$SKIPPED"
else
    echo "Done: APK installed on both, AppImage built"
fi
