#!/bin/sh
set -e

# Install the freshest release APK on a physical phone.
# Build one first: ./10-MakeRelease.sh

cd "$(dirname "$0")"

# Nothing below is project-specific: the name 10-MakeRelease.sh put in front of
# the version comes from pubspec.yaml. Copy the script to another Flutter
# project as it is.
PROJ_NAME=$(grep -oP '^name:\s*\K\S+' pubspec.yaml) || { echo "No name: in pubspec.yaml" >&2; exit 1; }

APK_DIR="build/app/outputs/flutter-apk"

# Phones are arm64-v8a — pick that split, fall back to the universal APK
apk=$(ls -t "$APK_DIR"/*arm64-v8a*.apk 2>/dev/null | head -1)
[ -z "$apk" ] && apk=$(ls -t "$APK_DIR/$PROJ_NAME"-*-universal.apk 2>/dev/null | head -1)
[ -z "$apk" ] && apk=$(ls -t "$APK_DIR"/*.apk 2>/dev/null | head -1)

if [ -z "$apk" ]; then
    echo "No release APK found. Build first: ./10-MakeRelease.sh"
    exit 1
fi

echo ">>> Installing: $(basename "$apk")"

# Pick the target device. Accept an explicit serial as $1; otherwise use the single connected
# physical device (the emulator is excluded). Fail clearly on none; warn and pick first on many.
if [ -n "$1" ]; then
    TEL="$1"
else
    DEVICES=$(adb devices | awk '/device$/ && !/emulator/{print $1}')
    COUNT=$(printf '%s\n' "$DEVICES" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    if [ "$COUNT" -eq 0 ]; then
        echo "No physical device connected. Connect one or pass a serial: $0 <serial>"
        # 3, not 1: nothing was attempted. 00-MakeAll.sh takes that as "there was
        # nothing to install on" and finishes green, while a real install failure
        # keeps its own non-zero code and makes the whole run non-zero.
        exit 3
    fi
    TEL=$(printf '%s\n' "$DEVICES" | head -1)
    if [ "$COUNT" -gt 1 ]; then
        echo "WARNING: $COUNT devices connected, using $TEL. Pass a serial to choose: $0 <serial>"
    fi
fi

echo ">>>>>>>: $TEL"
adb -s "$TEL" install -r "$apk"
sleep 3
