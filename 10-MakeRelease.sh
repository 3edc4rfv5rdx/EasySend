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
# The major.minor line moves by itself when CHANGELOG has an N: entry waiting
# since the last tag; there is nothing to pass and nothing to remember.
#
set -e
cd "$(dirname "$0")"

# Nothing below is EasySend-specific: the package name comes from pubspec.yaml,
# the display title from the Android label. Copy the script to another Flutter
# project as it is.
PROJ_NAME=$(grep -oP '^name:\s*\K\S+' pubspec.yaml) || { echo "No name: in pubspec.yaml" >&2; exit 1; }
PROJ_TITLE=$(grep -oP 'android:label="\K[^"]+' android/app/src/main/AndroidManifest.xml 2>/dev/null || true)
[ -n "$PROJ_TITLE" ] || PROJ_TITLE="$PROJ_NAME"

PUB_FILE="pubspec.yaml"
GLOB_FILE="lib/globals.dart"
APK_PATH="build/app/outputs/flutter-apk"

# The line — major.minor — is carried over verbatim unless the caller asks for
# a bump; who asks, and on what grounds, is decided further down.
compute_next_version() {
    local current="$1"
    local date_part="$2"
    local bump="${3:-}"
    if [[ ! "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]{6})\+([0-9]+)$ ]]; then
        echo "Malformed version: $current" >&2
        return 1
    fi
    local major="${BASH_REMATCH[1]}"
    local minor="${BASH_REMATCH[2]}"
    [ "$bump" = "minor" ] && minor=$((minor + 1))
    local next_build=$((BASH_REMATCH[4] + 1))
    echo "$major.$minor.$date_part+$next_build"
}

# Whether anything waiting for release is a new feature. The changelog already
# says so itself: N is a feature, everything else is a fix, a tweak or plumbing.
# 20-MakeTag.sh empties Unreleased when it stamps a version, so this reads
# exactly what has landed since the last tag.
unreleased_has_feature() {
    awk '
        /^## Unreleased$/ { inside = 1; next }
        /^## / { inside = 0 }
        inside && /^- N:/ { found = 1 }
        END { exit !found }
    ' CHANGELOG.md
}

# The line the last release went out on, so the rule fires once per feature and
# not on every build after it.
# Silence rather than failure when there is no tag yet, or none that parses: an
# assignment from a function that returns non-zero ends the script under set -e,
# and a project without releases is not an error.
released_line() {
    local tag
    tag=$(git tag --sort=-v:refname 2>/dev/null | head -1) || true
    if [[ "$tag" =~ ^v([0-9]+\.[0-9]+)\. ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
    return 0
}

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    sed -n '2,13p' "$0"
    exit 0
fi

if [ "$1" = "--compute" ]; then
    compute_next_version "$2" "$3" "${4:-}"
    exit
fi

# ---------- version ----------
CURRENT_FULL=$(sed -n 's/^version: //p' "$PUB_FILE")
CURRENT_VERSION=${CURRENT_FULL%+*}
CURRENT_BUILD=${CURRENT_FULL##*+}
# major.minor on its own: the date is the rest of it.
CURRENT_VERSION_LINE=${CURRENT_VERSION%.*}
GLOBAL_VERSION=$(sed -n "s/^const String progVersion = '\([^']*\)';/\1/p" "$GLOB_FILE")
GLOBAL_BUILD=$(sed -n 's/^const int buildNumber = \([0-9]*\);/\1/p' "$GLOB_FILE")
if [ "$CURRENT_VERSION" != "$GLOBAL_VERSION" ] || [ "$CURRENT_BUILD" != "$GLOBAL_BUILD" ]; then
    echo "Version sources disagree: $CURRENT_FULL vs $GLOBAL_VERSION+$GLOBAL_BUILD" >&2
    exit 1
fi
# The line moves by itself when the changelog says a feature is waiting and the
# last release went out on this same line. Nothing to pass and nothing to
# remember: the decision was made when the entry was written as N: rather than
# E:. Asked once here, so --dry-run answers exactly what a build would produce.
RELEASED_LINE=$(released_line)
BUMP=""
if [ -n "$RELEASED_LINE" ] &&
   [ "$RELEASED_LINE" = "$CURRENT_VERSION_LINE" ] &&
   unreleased_has_feature; then
    BUMP=minor
fi
FULL_VER=$(compute_next_version "$CURRENT_FULL" "$(date +%y%m%d)" "$BUMP")
VERSION=${FULL_VER%+*}
BUILD=${FULL_VER##*+}

if [ "$1" = "--dry-run" ]; then
    echo "$FULL_VER"
    exit
fi

if [ "$BUMP" = minor ]; then
    echo ">>> A feature is waiting in CHANGELOG, so the line moves to ${VERSION%.*}"
fi

VERSION_BACKUP=$(mktemp -d)
cp "$PUB_FILE" "$VERSION_BACKUP/pubspec.yaml"
cp "$GLOB_FILE" "$VERSION_BACKUP/globals.dart"
RELEASE_COMMITTED=false
COLLECT_DIR=""
SOURCE_ARTIFACTS=()
FINAL_ARTIFACTS=()
cleanup_release() {
    if [ "$RELEASE_COMMITTED" != true ]; then
        cp "$VERSION_BACKUP/pubspec.yaml" "$PUB_FILE"
        cp "$VERSION_BACKUP/globals.dart" "$GLOB_FILE"
        # Collection moves build outputs through a private staging directory.
        # Put every one back if publishing or verification stopped halfway.
        for i in "${!SOURCE_ARTIFACTS[@]}"; do
            SRC="${SOURCE_ARTIFACTS[$i]}"
            FINAL="${FINAL_ARTIFACTS[$i]}"
            STAGED=""
            [ -z "$COLLECT_DIR" ] || STAGED="$COLLECT_DIR/$(basename "$FINAL")"
            if [ -f "$FINAL" ] && [ ! -e "$SRC" ]; then
                mv "$FINAL" "$SRC" || true
            elif [ -n "$STAGED" ] && [ -f "$STAGED" ] && [ ! -e "$SRC" ]; then
                mv "$STAGED" "$SRC" || true
            fi
        done
    fi
    [ -z "$COLLECT_DIR" ] || rmdir "$COLLECT_DIR" 2>/dev/null || true
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

# ---------- collect ----------
# Flutter always writes app-<abi>-release.apk; rename to
# <title>-<version>-<build>-<arch>.apk, the same shape the AppImage already has,
# so every artifact of this project sorts and reads alike once it leaves the
# build directory. The fat APK carries both ABIs and so is named for that rather
# than for one of them. Everything here is a release build, which is why the
# word is not in the name.
for abi in "" "-arm64-v8a" "-x86_64"; do
    SOURCE_ARTIFACTS+=("$APK_PATH/app${abi}-release.apk")
    FINAL_ARTIFACTS+=("$APK_PATH/$PROJ_TITLE-$VERSION-$BUILD${abi:--universal}.apk")
done

# Refuse a partial set and never replace an artifact from an earlier run.
for i in "${!SOURCE_ARTIFACTS[@]}"; do
    [ -s "${SOURCE_ARTIFACTS[$i]}" ] || {
        echo "Missing or empty release artifact: ${SOURCE_ARTIFACTS[$i]}" >&2
        exit 1
    }
    [ ! -e "${FINAL_ARTIFACTS[$i]}" ] || {
        echo "Release artifact already exists: ${FINAL_ARTIFACTS[$i]}" >&2
        exit 1
    }
done

COLLECT_DIR=$(mktemp -d "$APK_PATH/.release-collect.XXXXXX")
for i in "${!SOURCE_ARTIFACTS[@]}"; do
    mv "${SOURCE_ARTIFACTS[$i]}" "$COLLECT_DIR/$(basename "${FINAL_ARTIFACTS[$i]}")"
done
for i in "${!FINAL_ARTIFACTS[@]}"; do
    mv "$COLLECT_DIR/$(basename "${FINAL_ARTIFACTS[$i]}")" "${FINAL_ARTIFACTS[$i]}"
done

for artifact in "${FINAL_ARTIFACTS[@]}"; do
    [ -s "$artifact" ] || {
        echo "Release artifact verification failed: $artifact" >&2
        exit 1
    }
done

echo
echo "Release APKs:"
ls -1 "${FINAL_ARTIFACTS[@]}"

# This is the transaction commit point: all requested deliverables now exist
# under final names and both version sources still agree. Later pruning and the
# optional git amend are maintenance around a release that already completed.
RELEASE_COMMITTED=true
rm -f "$APK_PATH/"*.sha1

# ---------- prune ----------
# Three builds back is enough to fall back on; each one is some 75 MB across
# the three APKs. The app-* files from before the rename go with them.
KEEP=3
rm -f "$APK_PATH/"app-*.apk
# Artifacts from the previous naming (<title>-<abi>-release-<version>-<build>)
# match none of the patterns below, so they would never be pruned and would sit
# here for good.
rm -f "$APK_PATH/$PROJ_TITLE"*-release-*.apk
for abi in "-universal" "-arm64-v8a" "-x86_64"; do
    ls -t "$APK_PATH/$PROJ_TITLE-"*"$abi.apk" 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
        echo "Removing older APK: $(basename "$old")"
        rm -f "$old"
    done
done

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
