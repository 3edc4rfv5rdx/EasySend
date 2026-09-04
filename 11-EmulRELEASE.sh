#!/bin/sh

# Install the freshest release APK on the emulator.
# Build one first: ./10-MakeRelease.sh

cd "$(dirname "$0")"

# Nothing below is project-specific: the name 10-MakeRelease.sh put in front of
# the version comes from pubspec.yaml. Copy the script to another Flutter
# project as it is.
PROJ_NAME=$(grep -oP '^name:\s*\K\S+' pubspec.yaml) || { echo "No name: in pubspec.yaml" >&2; exit 1; }

APK_DIR="build/app/outputs/flutter-apk"

# Emulator is x86_64 — pick that split, fall back to the universal APK
apk=$(ls -t "$APK_DIR"/*x86_64*.apk 2>/dev/null | head -1)
[ -z "$apk" ] && apk=$(ls -t "$APK_DIR/$PROJ_NAME"-*-universal.apk 2>/dev/null | head -1)
[ -z "$apk" ] && apk=$(ls -t "$APK_DIR"/*.apk 2>/dev/null | head -1)

if [ -z "$apk" ]; then
    echo "No release APK found. Build first: ./10-MakeRelease.sh"
    exit 1
fi

# Nothing to install on is not a failure: 00-MakeAll.sh reads 3 as "no emulator
# was running" and finishes green, while an install that was attempted and went
# wrong keeps its own non-zero code.
if ! adb devices | grep -q '^emulator-5554[[:space:]]*device$'; then
    echo "No emulator at emulator-5554. Start one, or install by hand."
    exit 3
fi

echo ">>> Installing: $(basename "$apk")"
adb -s emulator-5554 install -r "$apk"

sleep 2
