#!/bin/sh

# Install the freshest release APK on the emulator.
# Build one first: ./10-MakeRelease.sh

APK_DIR="build/app/outputs/flutter-apk"

# Emulator is x86_64 — pick that split, fall back to the universal APK
apk=$(ls -t "$APK_DIR"/*x86_64*.apk 2>/dev/null | head -1)
[ -z "$apk" ] && apk=$(ls -t "$APK_DIR"/app-release-*.apk 2>/dev/null | head -1)
[ -z "$apk" ] && apk=$(ls -t "$APK_DIR"/*.apk 2>/dev/null | head -1)

if [ -z "$apk" ]; then
    echo "No release APK found. Build first: ./10-MakeRelease.sh"
    exit 1
fi

echo ">>> Installing: $(basename "$apk")"
adb -s emulator-5554 install -r "$apk"

sleep 2
