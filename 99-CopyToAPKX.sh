#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

# Expose the newest arm64 release APK under an .apkx name in the project root, so
# it can be sent over Viber and the like without the messenger mangling an .apk
# attachment.
#
# The name is the APK's own, with the extension changed — nothing is composed out
# of pubspec.yaml. It used to be, and the two could disagree: the build number
# came from the version file while the file came from the directory listing, so a
# stale APK went out under the current build's name.

APK_DIR="build/app/outputs/flutter-apk"

apk=$(ls -t "$APK_DIR"/*arm64-v8a*.apk 2>/dev/null | head -1)

if [[ -z "$apk" || ! -f "$apk" ]]; then
    echo "ERROR: Release arm64 APK not found. Build first: ./10-MakeRelease.sh"
    exit 1
fi

dst="$(basename "${apk%.apk}").apkx"

# Only the current build keeps a link: the earlier ones are stale the moment this
# one is made, and dead ones point at APKs that were cleaned away. Plain .apkx
# files are left alone, they are copies someone made on purpose.
find . -maxdepth 1 -name '*.apkx' -type l ! -name "$dst" -delete

ln -sf "$apk" "$dst" 2>/dev/null || cp "$apk" "$dst"

echo "$(basename "$apk") -> $dst"
