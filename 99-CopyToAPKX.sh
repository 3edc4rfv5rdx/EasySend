#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

# Expose the latest arm64 release APK under a short .apkx name in the project
# root, so it can be sent over Viber and the like without the messenger
# mangling an .apk attachment.

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

dst="EasySend-${BUILD}.apkx"

# Only the current build keeps a link: the earlier ones are stale the moment
# this one is made, and dead ones point at APKs that were cleaned away. Plain
# .apkx files are left alone, they are copies someone made on purpose.
find . -maxdepth 1 -name '*.apkx' -type l ! -name "$dst" -delete

ln -sf "$apk" "$dst" 2>/dev/null || cp "$apk" "$dst"

echo "$(basename "$apk") -> $dst"

sleep 2
