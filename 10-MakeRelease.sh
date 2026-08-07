#!/usr/bin/env bash
#
# Build a release APK. The build number grows on every run, so each build on
# the device is distinguishable.
#
# A dirty working tree is fine: the version bump is folded into the previous
# commit only when that is safe, otherwise it is simply left uncommitted.
#
# Installing is a separate step: 11-EmulRELEASE.sh, 12-PhoneRELEASE.sh
#
set -e
cd "$(dirname "$0")"

PROJ_NAME="easysend"
PROJ_TITLE="EasySend"
GLOBVERS="0.1"

PUB_FILE="pubspec.yaml"
GLOB_FILE="lib/globals.dart"
APK_PATH="build/app/outputs/flutter-apk"

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    sed -n '2,10p' "$0"
    exit 0
fi

# ---------- version ----------
OLD_CODE=$(grep -oP '^version:\s*[0-9.]+\+\K[0-9]+' "$PUB_FILE")
BUILD=$(( ${OLD_CODE:-0} + 1 ))
VERSION="${GLOBVERS}.$(date +%y%m%d)"
FULL_VER="${VERSION}+${BUILD}"

# The number lives in two places that must not drift apart: pubspec.yaml feeds
# the APK, globals.dart feeds the About screen.
sed -i "s/^version: .*$/version: $FULL_VER/" "$PUB_FILE"
sed -i "s/const String progVersion = '[0-9.]\+';/const String progVersion = '$VERSION';/" "$GLOB_FILE"
sed -i "s/const int buildNumber = [0-9]\+;/const int buildNumber = $BUILD;/" "$GLOB_FILE"

echo "Version: $VERSION"
echo ">>> Build: $BUILD <<<"

# ---------- build ----------
flutter pub get
dart run flutter_launcher_icons

# Release builds ship without the debug log; restore whatever was there after.
OLD_DEBUG=$(grep -oP 'bool xvDebug\s*=\s*\K[^;]+' "$GLOB_FILE")
sed -i "s/bool xvDebug\s*=\s*[^;]*;/bool xvDebug = false;/" "$GLOB_FILE"
restore_debug() {
    sed -i "s/bool xvDebug\s*=\s*[^;]*;/bool xvDebug = $OLD_DEBUG;/" "$GLOB_FILE"
}
trap restore_debug EXIT

# 64-bit only, no armeabi-v7a.
flutter build apk --release --target-platform android-arm64,android-x64
flutter build apk --release --split-per-abi --target-platform android-arm64,android-x64

restore_debug
trap - EXIT

# ---------- collect ----------
for abi in "" "-arm64-v8a" "-x86_64"; do
    SRC="$APK_PATH/app${abi}-release.apk"
    [ -f "$SRC" ] && mv "$SRC" "$APK_PATH/app${abi}-release-$VERSION-$BUILD.apk"
done
rm -f "$APK_PATH/"*.sha1

echo
echo "Release APKs:"
ls -1 "$APK_PATH"/*-"$VERSION"-"$BUILD".apk 2>/dev/null

# ---------- version bump in git ----------
# Fold the bump into the previous commit when that is safe. Safe = HEAD is not
# on any remote branch yet AND the version files are the only thing modified.
if git rev-parse --verify HEAD >/dev/null 2>&1; then
    DIRTY=$(git status --porcelain | awk '{print $2}' | sort | tr '\n' ' ')
    if [[ "$DIRTY" == "$GLOB_FILE $PUB_FILE " ]]; then
        if [[ -z "$(git branch -r --contains HEAD 2>/dev/null)" ]]; then
            git add "$PUB_FILE" "$GLOB_FILE"
            git commit --amend --no-edit >/dev/null
            echo ">>> Folded version bump into $(git log -1 --pretty=format:'%h %s')"
        else
            echo ">>> HEAD already pushed; version bump left uncommitted."
        fi
    else
        echo ">>> Other changes present; version bump left uncommitted."
    fi
fi

sleep 2
