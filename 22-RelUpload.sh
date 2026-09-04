#!/usr/bin/env bash
set -e

ROOT="$(git rev-parse --show-toplevel)"

# Nothing below is project-specific: the name the release artifacts carry in
# front of the version comes from pubspec.yaml. Copy the script to another
# Flutter project as it is.
PROJ_NAME=$(grep -oP '^name:\s*\K\S+' "$ROOT/pubspec.yaml") || { echo "No name: in pubspec.yaml" >&2; exit 1; }

APK_DIR="$ROOT/build/app/outputs/flutter-apk"
APPIMAGE_DIR="$ROOT/build/linux"
CHANGELOG_SRC="$ROOT/CHANGELOG.md"
NOTES_FILE="/tmp/release_notes_$$.md"

echo "=== Reading version from pubspec.yaml ==="
FULL_VER=$(grep -oP '^version:\s*\K[0-9.]+\+[0-9]+' "$ROOT/pubspec.yaml")

if [[ -z "$FULL_VER" ]]; then
    echo "ERROR: Could not read version from pubspec.yaml."
    exit 1
fi

# The pubspec spells the build with a +; the tag, the way 20-MakeTag.sh wrote
# it, spells it with a dash.
TAG="v${FULL_VER/+/-}"

if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "ERROR: Tag $TAG not found. Run 21-PushTag.sh first."
    exit 1
fi

echo "Tag: $TAG"

# ------------------------------------------------------------
# Parse tag: v0.7.20260115-26  ->  VERSION=0.7.20260115  BUILD=26
# Matched whole rather than cut at the dash: a tag from the older +build spelling
# would otherwise parse into nonsense instead of stopping here.
# ------------------------------------------------------------
CLEAN_TAG="${TAG#v}"
if [[ "$CLEAN_TAG" =~ ^([0-9]+\.[0-9]+\.[0-9]{6,8})-([0-9]+)$ ]]; then
    VERSION="${BASH_REMATCH[1]}"
    BUILD="${BASH_REMATCH[2]}"
else
    echo "ERROR: Failed to parse tag: $TAG (expected v<major>.<minor>.<date>-<build>)"
    exit 1
fi

echo "Version: $VERSION"
echo "Build:   $BUILD"

# ------------------------------------------------------------
# Function: extract_changelog
# Extract the notes for the given version from CHANGELOG.md:
# everything between "## <tag>" and the next "## " heading.
# ------------------------------------------------------------
extract_changelog() {
    local changelog="$1"
    local tag="$2"
    local out_file="$3"

    awk -v ver="## $tag" '
    $0 == ver { capture=1; next }
    capture && /^## / { capture=0 }
    capture { print }
    ' "$changelog" > "$out_file"
}

# ------------------------------------------------------------
# Build release notes
# ------------------------------------------------------------
echo "=== Extracting release notes from $CHANGELOG_SRC ==="
extract_changelog "$CHANGELOG_SRC" "$TAG" "$NOTES_FILE"

if [[ ! -s "$NOTES_FILE" ]]; then
    echo "ERROR: No CHANGELOG section found for $TAG."
    exit 1
fi

echo "Release notes:"
echo "--------------------------------------------------"
cat "$NOTES_FILE"
echo "--------------------------------------------------"

# ------------------------------------------------------------
# Real APK file names on disk (easysend-*, named by 10-MakeRelease.sh)
# ------------------------------------------------------------
SRC_APK_MAIN="${PROJ_NAME}-${VERSION}-${BUILD}-universal.apk"
SRC_APK_ARM64="${PROJ_NAME}-${VERSION}-${BUILD}-arm64-v8a.apk"
SRC_APK_ARM32="${PROJ_NAME}-${VERSION}-${BUILD}-armeabi-v7a.apk"

# The Linux build of the same number, packed by 14-MakeAppImage.sh.
SRC_APPIMAGE="${PROJ_NAME}-${VERSION}-${BUILD}-x86_64.AppImage"

# ------------------------------------------------------------
# SHA256 files we will generate locally
# ------------------------------------------------------------
SRC_SHA_MAIN="${SRC_APK_MAIN}.sha256"
SRC_SHA_ARM64="${SRC_APK_ARM64}.sha256"

# ------------------------------------------------------------
# Target file names in GitHub Release (easysend-*)
# ------------------------------------------------------------
DST_APK_MAIN="$SRC_APK_MAIN"
DST_SHA_MAIN="$SRC_SHA_MAIN"

DST_APK_ARM64="$SRC_APK_ARM64"
DST_SHA_ARM64="$SRC_SHA_ARM64"

DST_APK_ARM32="$SRC_APK_ARM32"

DST_APPIMAGE="${PROJ_NAME}-${VERSION}-${BUILD}-x86_64.AppImage"

# ------------------------------------------------------------
# Check APK existence
# ------------------------------------------------------------
echo "=== Checking APK files in $APK_DIR ==="

for f in "$SRC_APK_MAIN" "$SRC_APK_ARM64" "$SRC_APK_ARM32"; do
    if [[ ! -f "$APK_DIR/$f" ]]; then
        echo "ERROR: File not found: $APK_DIR/$f"
        exit 1
    fi
    echo "OK: $f"
done

# ------------------------------------------------------------
# Generate SHA256 (disabled)
# ------------------------------------------------------------
# echo "=== Generating SHA256 checksums ==="
#
# (
#     cd "$APK_DIR"
#
#     echo "Generating $SRC_SHA_MAIN"
#     sha256sum "$SRC_APK_MAIN" > "$SRC_SHA_MAIN"
#
#     echo "Generating $SRC_SHA_ARM64"
#     sha256sum "$SRC_APK_ARM64" > "$SRC_SHA_ARM64"
# )

# ------------------------------------------------------------
# Files to upload (full source path#destination name). The AppImage lives in
# another directory than the APKs, so the source side is absolute.
# ------------------------------------------------------------
FILES=(
    "$APK_DIR/$SRC_APK_MAIN#$DST_APK_MAIN"
    "$APK_DIR/$SRC_APK_ARM64#$DST_APK_ARM64"
    "$APK_DIR/$SRC_APK_ARM32#$DST_APK_ARM32"
    "$APPIMAGE_DIR/$SRC_APPIMAGE#$DST_APPIMAGE"
#    "$APK_DIR/$SRC_SHA_MAIN#$DST_SHA_MAIN"
#    "$APK_DIR/$SRC_SHA_ARM64#$DST_SHA_ARM64"
)

echo "=== Verifying generated files ==="

for pair in "${FILES[@]}"; do
    SRC="${pair%%#*}"
    if [[ ! -f "$SRC" ]]; then
        echo "ERROR: File not found: $SRC"
        [[ "$SRC" == *.AppImage ]] && echo "Run ./14-MakeAppImage.sh for build $BUILD first."
        exit 1
    fi
    echo "OK: $(basename "$SRC")"
done

# ------------------------------------------------------------
# Create release if not exists
# ------------------------------------------------------------
echo "=== Checking if GitHub Release exists ==="

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Release already exists."
else
    echo "Creating GitHub Release..."
    gh release create "$TAG" \
        --title "Release $TAG" \
        --notes-file "$NOTES_FILE"
fi

# ------------------------------------------------------------
# Upload files with renaming
# ------------------------------------------------------------
echo "=== Uploading files to Release ==="

for pair in "${FILES[@]}"; do
    SRC="${pair%%#*}"
    DST="${pair##*#}"
    echo "Uploading: $(basename "$SRC") -> $DST"
    gh release upload "$TAG" "$pair" --clobber
done

echo "=== Release upload completed successfully ==="

# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------
rm -f "$NOTES_FILE"
sleep 2