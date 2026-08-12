#!/bin/sh

# Install the freshest release APK on the emulator.
# Build one first: ./10-MakeRelease.sh

cd "$(dirname "$0")"

# Nothing below is EasySend-specific: the package name comes from pubspec.yaml,
# the display title from the Android label, and 10-MakeRelease.sh names the APKs
# after the title. Copy the script to another Flutter project as it is.
PROJ_NAME=$(grep -oP '^name:\s*\K\S+' pubspec.yaml) || { echo "No name: in pubspec.yaml" >&2; exit 1; }
PROJ_TITLE=$(grep -oP 'android:label="\K[^"]+' android/app/src/main/AndroidManifest.xml 2>/dev/null || true)
[ -n "$PROJ_TITLE" ] || PROJ_TITLE="$PROJ_NAME"

APK_DIR="build/app/outputs/flutter-apk"

# Emulator is x86_64 — pick that split, fall back to the universal APK
apk=$(ls -t "$APK_DIR"/*x86_64*.apk 2>/dev/null | head -1)
[ -z "$apk" ] && apk=$(ls -t "$APK_DIR/$PROJ_TITLE"-release-*.apk 2>/dev/null | head -1)
[ -z "$apk" ] && apk=$(ls -t "$APK_DIR"/*.apk 2>/dev/null | head -1)

if [ -z "$apk" ]; then
    echo "No release APK found. Build first: ./10-MakeRelease.sh"
    exit 1
fi

echo ">>> Installing: $(basename "$apk")"
adb -s emulator-5554 install -r "$apk"

sleep 2
