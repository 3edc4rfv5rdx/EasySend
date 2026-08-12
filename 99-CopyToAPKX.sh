#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

# Expose the latest arm64 release APK under a short .apkx name in the project
# root, so it can be sent over Viber and the like without the messenger
# mangling an .apk attachment.

# Nothing below is EasySend-specific: the package name comes from pubspec.yaml,
# the display title from the Android label. Copy the script to another Flutter
# project as it is.
PROJ_NAME=$(grep -oP '^name:\s*\K\S+' pubspec.yaml) || { echo "No name: in pubspec.yaml" >&2; exit 1; }
PROJ_TITLE=$(grep -oP 'android:label="\K[^"]+' android/app/src/main/AndroidManifest.xml 2>/dev/null || true)
[ -n "$PROJ_TITLE" ] || PROJ_TITLE="$PROJ_NAME"

PUB_FILE="pubspec.yaml"
APK_DIR="build/app/outputs/flutter-apk"

BUILD=$(grep -oP '^version:\s*[0-9.]+\+\K[0-9]+' "$PUB_FILE")

if [[ -z "$BUILD" ]]; then
    echo "ERROR: Failed to read the build number from $PUB_FILE"
    exit 1
fi

apk=$(ls -t "$APK_DIR"/*arm64-v8a*.apk 2>/dev/null | head -1)

if [[ -z "$apk" || ! -f "$apk" ]]; then
    echo "ERROR: Release arm64 APK not found. Build first: ./10-MakeRelease.sh"
    exit 1
fi

dst="${PROJ_TITLE}-${BUILD}.apkx"

# Only the current build keeps a link: the earlier ones are stale the moment
# this one is made, and dead ones point at APKs that were cleaned away. Plain
# .apkx files are left alone, they are copies someone made on purpose.
find . -maxdepth 1 -name '*.apkx' -type l ! -name "$dst" -delete

ln -sf "$apk" "$dst" 2>/dev/null || cp "$apk" "$dst"

echo "$(basename "$apk") -> $dst"

sleep 2
