#!/usr/bin/env bash
#
# Build the Linux desktop release into build/linux/x64/release/bundle.
#
# The version is left alone: 10-MakeRelease.sh owns the build counter, and a
# desktop build that ate a number would leave gaps in the APK series. Whatever
# version is in pubspec.yaml right now is what this build reports.
#
# Running it: build/linux/x64/release/bundle/easysend
#
set -e
cd "$(dirname "$0")"

PROJ_NAME="easysend"
GLOB_FILE="lib/globals.dart"
BUNDLE="build/linux/x64/release/bundle"

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    sed -n '2,9p' "$0"
    exit 0
fi

# ---------- toolchain ----------
# Missing one of these ends in a CMake error three screens long; say it here.
MISSING=""
for tool in clang cmake ninja pkg-config; do
    command -v "$tool" >/dev/null 2>&1 || MISSING="$MISSING $tool"
done
pkg-config --exists gtk+-3.0 2>/dev/null || MISSING="$MISSING libgtk-3-dev"
if [ -n "$MISSING" ]; then
    echo "Missing:$MISSING"
    echo "sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev"
    exit 1
fi

# The native-assets step looks for the linker beside clang, not on PATH, so a
# toolchain with clang alone dies deep inside the Dart build.
CLANG_DIR=$(dirname "$(readlink -f "$(command -v clang)")")
if [ ! -x "$CLANG_DIR/ld.lld" ] && [ ! -x "$CLANG_DIR/ld" ]; then
    LLVM_VER=$(basename "$(dirname "$CLANG_DIR")" | grep -oP 'llvm-\K[0-9]+' || true)
    echo "No linker in $CLANG_DIR (ld.lld or ld)"
    echo "sudo apt install lld${LLVM_VER:+-$LLVM_VER}"
    exit 1
fi

flutter config --enable-linux-desktop >/dev/null

# ---------- build ----------
flutter pub get

flutter build linux --release

# ---------- result ----------
VERSION=$(grep -oP '^version:\s*\K\S+' pubspec.yaml)
echo
echo "Version: $VERSION"
echo "Bundle:  $(du -sh "$BUNDLE" | cut -f1)  $BUNDLE"
echo "Run:     ./$BUNDLE/$PROJ_NAME"
