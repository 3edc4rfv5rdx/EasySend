#!/usr/bin/env bash
#
# Everything in one run: build the release APK, install it on the emulator and
# on the phone, then build the Linux release and pack it into an AppImage.
#
# A build that fails stops the run. A device that is not plugged in does not:
# an absent emulator should not cost you the AppImage.
#
# Finally 01-LinkOut.sh puts the AppImage and the arm64-v8a APK into OUT/ as
# links under their own names, and sweeps whatever else was there.
#
# Arguments go to 10-MakeRelease.sh, which takes one: --minor, for the release
# that moves the version line (README, Versions).
#
cd "$(dirname "$0")"

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    sed -n '2,13p' "$0"
    exit 0
fi

SKIPPED=""

run() { # run <script> <fatal|optional> [arguments for the script]
    local script="$1"
    local kind="$2"
    shift 2
    echo
    echo "=== $script ==="
    if [ ! -x "$script" ]; then
        echo ">>> $script is missing or not executable"
        [ "$kind" = "fatal" ] && exit 1
        SKIPPED="$SKIPPED $script"
        return 0
    fi
    if ./"$script" "$@"; then
        return 0
    fi
    echo ">>> $script failed"
    [ "$kind" = "fatal" ] && exit 1
    SKIPPED="$SKIPPED $script"
}

# Only the release step takes arguments; the rest of the run has nothing to
# decide.
run 10-MakeRelease.sh fatal "$@"
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
