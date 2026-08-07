#!/bin/bash


COMMENT="build"
#
GLOBVERS='0.1'
VER=''
VER_CODE=''
#
#
PROJ_NAME="easysend"
PROJ_TITLE="EasySend"
# Project paths
OUT_PATH="$HOME"
# Project root = current dir (the script already uses relative ./lib, pubspec.yaml,
# so it must be run from the project root). Avoids a hardcoded $HOME/<dir> path.
PROJ_PATH="$(pwd)"
APK_PATH="$PROJ_PATH/build/app/outputs/flutter-apk"
# Archive directory structure
ZIP_DIR="$OUT_PATH/ZIP"
PROJ_ZIP_DIR="$ZIP_DIR/$PROJ_NAME"
# Path to files
PUB_FILE="pubspec.yaml"
GLOB_FILE="./lib/globals.dart"
# Version and tags
FULL_VER="$VER+$VER_CODE"
# Get current date
DATE=$(date +"%Y%m%d")
DATE_SHORT=$(date +"%y%m%d")
# Archive settings
TEMP_DIR="/tmp"
# Debug control
OLD_DEBUG_VALUE=""

# ============ FUNCTIONS ============
auto_increment_version() {
    echo "===== AUTO INCREMENT VERSION ====="

    # Set global version if not specified
    if [ -z "$VER" ]; then
        # Get current date in YYMMDD format
        DATE_SHORT=$(date +"%y%m%d")
        VER="${GLOBVERS}.${DATE_SHORT}"
        echo "✓ Version set to $VER based on current date"
    fi

    # Auto-increment version code if not specified
    if [ -z "$VER_CODE" ]; then
        # Extract the current version code from pubspec.yaml
        CURRENT_VERSION=$(grep -o "version: [0-9]\+\.[0-9]\+\.[0-9]\+\+[0-9]\+" "$PUB_FILE" | grep -o "\+[0-9]\+")

        if [ -z "$CURRENT_VERSION" ]; then
            # If version with + not found, try another format
            CURRENT_VERSION=$(grep -o "version: [0-9]\+\.[0-9]\+\.[0-9]\+.*" "$PUB_FILE" | grep -o "\+[0-9]\+")
        fi

        if [ -n "$CURRENT_VERSION" ]; then
            # Extract number after + and increment
            CURRENT_CODE=${CURRENT_VERSION#+}
            VER_CODE=$((CURRENT_CODE + 1))
            echo "✓ Version code incremented from $CURRENT_CODE to $VER_CODE"
        else
            # If no version code found, set to 1
            VER_CODE=1
            echo "✓ Version code set to $VER_CODE (no previous version found)"
        fi
    fi

    # Update FULL_VER with new values
    FULL_VER="$VER+$VER_CODE"
    echo "✓ Full version: $FULL_VER"
}

update_version() {
    echo "===== UPDATING VERSION INFORMATION ====="

    # Replace version in pubspec.yaml
    sed -i "s/version: [0-9]\+\.[0-9]\+\.[0-9]\+.*$/version: $FULL_VER/g" "$PUB_FILE"
    if [ $? -eq 0 ]; then
        echo "✓ Version successfully updated to $FULL_VER in $PUB_FILE"
    else
        echo "✗ Error updating version in $PUB_FILE"
        exit 1
    fi

    # Replace version in globals.dart
    sed -i "s/const String progVersion = '[0-9]\+\.[0-9]\+\.[0-9]\+';/const String progVersion = '$VER';/g" "$GLOB_FILE"
    if [ $? -eq 0 ]; then
        echo "✓ Version successfully updated to $VER in $GLOB_FILE"
    else
        echo "✗ Error updating version in $GLOB_FILE"
        exit 1
    fi

    # Replace build number in globals.dart
    sed -i "s/const int buildNumber = [0-9]\+;/const int buildNumber = $VER_CODE;/g" "$GLOB_FILE"
    if [ $? -eq 0 ]; then
        echo "✓ Build number successfully updated to $VER_CODE in $GLOB_FILE"
    else
        echo "✗ Error updating build number in $GLOB_FILE"
        exit 1
    fi

    # Create Git commit for the version bump. Tagging is done by 01-PushTag.sh,
    # not on every build.
    if [ -d ".git" ] || git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        # Commit the version changes
        git add "$PUB_FILE" "$GLOB_FILE" "00-Make.sh"
        git commit -m "Version bump to $FULL_VER: $COMMENT"

        if [ $? -eq 0 ]; then
            echo "✓ Git commit successfully created for version $FULL_VER"
        else
            echo "✗ Error creating Git commit"
        fi
    else
        echo "! Warning: Current directory is not a Git repository. Commit was not created."
    fi
}

create_archive() {
    echo "===== CREATING PROJECT ARCHIVE ====="
    # Create archive directory structure if it doesn't exist
    mkdir -p "$PROJ_ZIP_DIR"
    # Create temporary file with list of files to archive
    FILE_LIST="$TEMP_DIR/zip-temp.txt"
    SELF_NAME=$(basename "$0")
    # Add directories
    find lib -type f > "$FILE_LIST"
    find assets -type f 2>/dev/null >> "$FILE_LIST"
    find android -type f ! -name "*.apk" >> "$FILE_LIST"
    find linux -type f >> "$FILE_LIST"
    find windows -type f >> "$FILE_LIST"
    find .git -type f >> "$FILE_LIST"
    # Add specific files
    [ -f "$PUB_FILE" ] && echo "$PUB_FILE" >> "$FILE_LIST"
    [ -f ".gitignore" ] && echo ".gitignore" >> "$FILE_LIST"
    echo "$SELF_NAME" >> "$FILE_LIST"
    # Create archive using the file list
    (cd "$PROJ_PATH" && zip -9 -@ "$ZIP_NAME" < "$FILE_LIST")
    # Remove temporary file list
    rm "$FILE_LIST"
    echo "✓ Archive created: $ZIP_NAME"
}

disable_debug() {
    echo "===== DISABLING DEBUG MODE ====="

    # Extract current debug value
    OLD_DEBUG_VALUE=$(grep -oP 'bool xvDebug\s*=\s*\K[^;]+' "$GLOB_FILE")
    if [ -z "$OLD_DEBUG_VALUE" ]; then
        echo "! Warning: Could not find xvDebug value in $GLOB_FILE"
        return 1
    fi

    echo "Current debug value: $OLD_DEBUG_VALUE"

    # Set debug to false
    sed -i "s/bool xvDebug\s*=\s*[^;]*;/bool xvDebug = false;/g" "$GLOB_FILE"
    if [ $? -eq 0 ]; then
        echo "✓ Debug mode disabled (xvDebug set to false)"
    else
        echo "✗ Error disabling debug mode"
        exit 1
    fi
}

restore_debug() {
    echo "===== RESTORING DEBUG MODE ====="

    # Restore original debug value
    sed -i "s/bool xvDebug\s*=\s*[^;]*;/bool xvDebug = $OLD_DEBUG_VALUE;/g" "$GLOB_FILE"
    if [ $? -eq 0 ]; then
        echo "✓ Debug mode restored (xvDebug set to $OLD_DEBUG_VALUE)"
    else
        echo "✗ Error restoring debug mode"
        exit 1
    fi
}

build_app() {
    echo "===== BUILDING APPLICATION ====="
    echo "Building project $PROJ_NAME version $VER+$VER_CODE"

    # Run Flutter commands
    echo "Installing dependencies..."
    flutter pub get

    echo "Generating icons..."
    dart run flutter_launcher_icons

    echo "Building universal APK..."
    flutter build apk --release

    echo "Building APK for different architectures..."
    flutter build apk --release --split-per-abi

    # Rename APK files
    echo "Renaming APK files..."

    # Universal APK
    if [ -f "$APK_PATH/app-release.apk" ]; then
        NEW_NAME="$APK_PATH/app-release-$VER-$VER_CODE.apk"
        mv "$APK_PATH/app-release.apk" "$NEW_NAME"
        echo "✓ Created: $NEW_NAME"
    fi

    # APK for arm64-v8a
    if [ -f "$APK_PATH/app-arm64-v8a-release.apk" ]; then
        NEW_NAME="$APK_PATH/app-arm64-v8a-release-$VER-$VER_CODE.apk"
        mv "$APK_PATH/app-arm64-v8a-release.apk" "$NEW_NAME"
        echo "✓ Created: $NEW_NAME"
    fi

    # APK for armeabi-v7a
    if [ -f "$APK_PATH/app-armeabi-v7a-release.apk" ]; then
        NEW_NAME="$APK_PATH/app-armeabi-v7a-release-$VER-$VER_CODE.apk"
        mv "$APK_PATH/app-armeabi-v7a-release.apk" "$NEW_NAME"
        echo "✓ Created: $NEW_NAME"
    fi

    # APK for x86_64
    if [ -f "$APK_PATH/app-x86_64-release.apk" ]; then
        NEW_NAME="$APK_PATH/app-x86_64-release-$VER-$VER_CODE.apk"
        mv "$APK_PATH/app-x86_64-release.apk" "$NEW_NAME"
        echo "✓ Created: $NEW_NAME"
    fi

    echo "✓ Build completed. APK files available in: $APK_PATH"
}

# Desktop build, run with: ./00-Make.sh linux
build_linux() {
    echo "===== BUILDING LINUX BUNDLE ====="
    flutter build linux --release

    BUNDLE="$PROJ_PATH/build/linux/x64/release/bundle"
    if [ ! -d "$BUNDLE" ]; then
        echo "✗ Linux bundle not found: $BUNDLE"
        return 1
    fi

    mkdir -p "$PROJ_ZIP_DIR"
    ARCHIVE="$PROJ_ZIP_DIR/$PROJ_TITLE-linux-x64-$VER-$VER_CODE.tar.gz"
    tar -czf "$ARCHIVE" -C "$(dirname "$BUNDLE")" "$(basename "$BUNDLE")"
    echo "✓ Linux bundle archived: $ARCHIVE"
}

clean_output() {
    echo "===== CLEANING OLD APK FILES ====="

    OUT_DIR="$PROJ_PATH/build/app/outputs"

    # Clean debug APKs
    if [ -d "$OUT_DIR/apk/debug" ]; then
        rm -f "$OUT_DIR/apk/debug/"*.apk
        echo "✓ Cleaned debug APKs"
    fi

    # Clean release APKs
    if [ -d "$OUT_DIR/apk/release" ]; then
        rm -f "$OUT_DIR/apk/release/"*.apk
        echo "✓ Cleaned release APKs"
    fi

    # Clean specific architecture APKs
    if [ -d "$OUT_DIR/flutter-apk" ]; then
        rm -f "$OUT_DIR/flutter-apk/"*v7a*.*
        rm -f "$OUT_DIR/flutter-apk/"*x86*.*
        rm -f "$OUT_DIR/flutter-apk/"*debug*.*
        rm -f "$OUT_DIR/flutter-apk/"*.sha1
        echo "✓ Cleaned architecture-specific APKs"
    fi
}

copy_final_apk() {
    echo "===== COPYING FINAL APK ====="

    # Find specific file for current version instead of all files
    SRC=$(ls $APK_PATH/app-arm64-v8a-release-$VER-$VER_CODE.apk 2>/dev/null)

    if [ -z "$SRC" ]; then
        echo "✗ No arm64 APK found to copy for version $VER-$VER_CODE"
        return 1
    fi

    # Extract version from filename
    VERS=$VER_CODE

    # Copy with new name
    DEST="$PROJ_PATH/$PROJ_TITLE-$VERS.apkx"
    cp -f "$SRC" "$DEST"

    # Also copy to archive directory
    APK_ARCHIVE="$PROJ_ZIP_DIR/$PROJ_TITLE-$VER-$VER_CODE-$DATE.apk"
    cp -f "$SRC" "$APK_ARCHIVE"

    echo "✓ Copied final APK to: $DEST"
    echo "✓ Archived APK to: $APK_ARCHIVE"
}

# ============ MAIN EXECUTION ============
echo "========== STARTING BUILD PROCESS =========="
echo "Project: $PROJ_NAME"

# Refuse to build on a dirty tree: the tagged release must match the built code.
# Commit your code (with CHANGELOG.md) first; this script only adds the version bump.
echo "===== CHECKING WORKING TREE IS CLEAN ====="
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "✗ ERROR: You have uncommitted changes."
    echo "  Commit your code (with CHANGELOG.md) before building."
    exit 1
fi
echo "✓ Working tree is clean"

auto_increment_version

ZIP_NAME="${PROJ_ZIP_DIR}/${PROJ_NAME}-${VER}-${VER_CODE}-${DATE}.zip"

echo "Version: $FULL_VER"
echo "Date: $DATE"
echo "=========================================="

# Create archive directories if they don't exist
mkdir -p "$PROJ_ZIP_DIR"

# Execute each step
update_version
############ create_archive
# Disable debug, store value in global variable
disable_debug
# Build the app with debug disabled
build_app
# Optional desktop bundle: ./00-Make.sh linux
if [ "$1" = "linux" ]; then
    build_linux
fi
# Restore debug to original value
restore_debug
# Continue with remaining steps
clean_output
copy_final_apk

echo "========== BUILD PROCESS COMPLETED =========="
#######echo "Project archive: $ZIP_NAME"
echo "APK archive: $APK_ARCHIVE"
echo "Final APK: $PROJ_PATH/$PROJ_TITLE-$VERS.apkx"
sleep 2
