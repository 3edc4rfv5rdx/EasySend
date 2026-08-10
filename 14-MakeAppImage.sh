#!/usr/bin/env bash
#
# Build the Linux release and pack it into one runnable file:
# build/linux/EasySend-<version>-x86_64.AppImage
#
# A Flutter desktop app cannot be linked statically — the engine is a shared
# library and GTK has to come from the system — so the AppImage carries the
# whole bundle instead.
#
# The version is left alone: 10-MakeRelease.sh owns the build counter.
#
set -e
cd "$(dirname "$0")"

PROJ_NAME="easysend"
PROJ_TITLE="EasySend"
GLOB_FILE="lib/globals.dart"
BUNDLE="build/linux/x64/release/bundle"
APPDIR="build/linux/AppDir"
OUT_DIR="build/linux"

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    sed -n '2,10p' "$0"
    exit 0
fi

# ---------- toolchain ----------
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

# The native-assets step looks for the linker beside clang, not on PATH.
CLANG_DIR=$(dirname "$(readlink -f "$(command -v clang)")")
if [ ! -x "$CLANG_DIR/ld.lld" ] && [ ! -x "$CLANG_DIR/ld" ]; then
    LLVM_VER=$(basename "$(dirname "$CLANG_DIR")" | grep -oP 'llvm-\K[0-9]+' || true)
    echo "No linker in $CLANG_DIR (ld.lld or ld)"
    echo "sudo apt install lld${LLVM_VER:+-$LLVM_VER}"
    exit 1
fi

# appimagetool is a single downloaded file, not a package.
APPIMAGETOOL=$(command -v appimagetool || true)
[ -z "$APPIMAGETOOL" ] && APPIMAGETOOL=$(ls -t "$HOME"/Downloads/appimagetool*.AppImage 2>/dev/null | head -1)
if [ -z "$APPIMAGETOOL" ]; then
    echo "appimagetool not found. Download it once:"
    echo "  wget -O ~/Downloads/appimagetool-x86_64.AppImage \\"
    echo "    https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
    echo "  chmod +x ~/Downloads/appimagetool-x86_64.AppImage"
    exit 1
fi
chmod +x "$APPIMAGETOOL"

flutter config --enable-linux-desktop >/dev/null

# ---------- build ----------
flutter pub get

# Release builds ship without the debug log; restore whatever was there after.
OLD_DEBUG=$(grep -oP 'bool xvDebug\s*=\s*\K[^;]+' "$GLOB_FILE")
sed -i "s/bool xvDebug\s*=\s*[^;]*;/bool xvDebug = false;/" "$GLOB_FILE"
restore_debug() {
    sed -i "s/bool xvDebug\s*=\s*[^;]*;/bool xvDebug = $OLD_DEBUG;/" "$GLOB_FILE"
}
trap restore_debug EXIT

flutter build linux --release

restore_debug
trap - EXIT

# ---------- AppDir ----------
VERSION=$(grep -oP '^version:\s*\K[0-9.]+' pubspec.yaml)
BUILD=$(grep -oP '^version:\s*[0-9.]+\+\K[0-9]+' pubspec.yaml)

rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/256x256/apps"
cp -r "$BUNDLE/." "$APPDIR/usr/bin/"

# The icon has to sit in the AppDir root as well; 256 is what desktops read.
if command -v convert >/dev/null 2>&1; then
    convert assets/icon.png -resize 256x256 "$APPDIR/$PROJ_NAME.png"
else
    cp assets/icon.png "$APPDIR/$PROJ_NAME.png"
fi
cp "$APPDIR/$PROJ_NAME.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/$PROJ_NAME.png"

cat > "$APPDIR/$PROJ_NAME.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=$PROJ_TITLE
Comment=Simple file transfer between devices over a local network
Exec=$PROJ_NAME
Icon=$PROJ_NAME
Categories=Network;FileTransfer;
Terminal=false
DESKTOP
cp "$APPDIR/$PROJ_NAME.desktop" "$APPDIR/usr/share/applications/"

cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/sh
HERE=$(dirname "$(readlink -f "$0")")
exec "$HERE/usr/bin/easysend" "$@"
APPRUN
chmod +x "$APPDIR/AppRun"

# ---------- pack ----------
IMAGE="$OUT_DIR/$PROJ_TITLE-$VERSION-$BUILD-x86_64.AppImage"
rm -f "$IMAGE"
# Extract-and-run: appimagetool is itself an AppImage, and FUSE is not always
# there to mount it.
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 "$APPIMAGETOOL" "$APPDIR" "$IMAGE"

echo
echo "Version: $VERSION+$BUILD"
echo "Image:   $(du -sh "$IMAGE" | cut -f1)  $IMAGE"
echo "Run:     ./$IMAGE"
