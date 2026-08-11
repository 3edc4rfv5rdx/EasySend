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
PUB_FILE="pubspec.yaml"
GLOB_FILE="lib/globals.dart"
APK_PATH="build/app/outputs/flutter-apk"

compute_next_version() {
    local current="$1"
    local date_part="$2"
    if [[ ! "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]{6})\+([0-9]+)$ ]]; then
        echo "Malformed version: $current" >&2
        return 1
    fi
    local line="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    local next_build=$((BASH_REMATCH[4] + 1))
    echo "$line.$date_part+$next_build"
}

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    sed -n '2,10p' "$0"
    exit 0
fi

if [ "$1" = "--compute" ]; then
    compute_next_version "$2" "$3"
    exit
fi

# ---------- version ----------
CURRENT_FULL=$(sed -n 's/^version: //p' "$PUB_FILE")
CURRENT_VERSION=${CURRENT_FULL%+*}
CURRENT_BUILD=${CURRENT_FULL##*+}
GLOBAL_VERSION=$(sed -n "s/^const String progVersion = '\([^']*\)';/\1/p" "$GLOB_FILE")
GLOBAL_BUILD=$(sed -n 's/^const int buildNumber = \([0-9]*\);/\1/p' "$GLOB_FILE")
if [ "$CURRENT_VERSION" != "$GLOBAL_VERSION" ] || [ "$CURRENT_BUILD" != "$GLOBAL_BUILD" ]; then
    echo "Version sources disagree: $CURRENT_FULL vs $GLOBAL_VERSION+$GLOBAL_BUILD" >&2
    exit 1
fi
FULL_VER=$(compute_next_version "$CURRENT_FULL" "$(date +%y%m%d)")
VERSION=${FULL_VER%+*}
BUILD=${FULL_VER##*+}

if [ "$1" = "--dry-run" ]; then
    echo "$FULL_VER"
    exit
fi

VERSION_BACKUP=$(mktemp -d)
cp "$PUB_FILE" "$VERSION_BACKUP/pubspec.yaml"
cp "$GLOB_FILE" "$VERSION_BACKUP/globals.dart"
BUILD_SUCCEEDED=false
cleanup_release() {
    if [ "$BUILD_SUCCEEDED" != true ]; then
        cp "$VERSION_BACKUP/pubspec.yaml" "$PUB_FILE"
        cp "$VERSION_BACKUP/globals.dart" "$GLOB_FILE"
    fi
    rm -f "$VERSION_BACKUP/pubspec.yaml" "$VERSION_BACKUP/globals.dart"
    rmdir "$VERSION_BACKUP"
}
trap cleanup_release EXIT

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

# 64-bit only, no armeabi-v7a.
flutter build apk --release --target-platform android-arm64,android-x64
flutter build apk --release --split-per-abi --target-platform android-arm64,android-x64

BUILD_SUCCEEDED=true

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

cleanup_release
trap - EXIT

sleep 2
