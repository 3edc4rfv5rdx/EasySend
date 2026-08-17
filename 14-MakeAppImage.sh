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

# Nothing below is EasySend-specific: the package name comes from pubspec.yaml,
# the display title from the Android label. Copy the script to another Flutter
# project as it is.
PROJ_NAME=$(grep -oP '^name:\s*\K\S+' pubspec.yaml) || { echo "No name: in pubspec.yaml" >&2; exit 1; }
PROJ_TITLE=$(grep -oP 'android:label="\K[^"]+' android/app/src/main/AndroidManifest.xml 2>/dev/null || true)
[ -n "$PROJ_TITLE" ] || PROJ_TITLE="$PROJ_NAME"

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
# Only when it needs it, and only as far as we are allowed. A freshly downloaded
# AppImage comes without the bit and has to be given it; one installed by a
# package manager already has it and is not ours to chmod — that attempt failed
# with EPERM and, under set -e, ended the build before it started, with a message
# about permissions that said nothing about AppImages.
if [ ! -x "$APPIMAGETOOL" ]; then
    chmod +x "$APPIMAGETOOL" 2>/dev/null || true
fi
if [ ! -x "$APPIMAGETOOL" ]; then
    echo "Cannot run $APPIMAGETOOL: no execute bit, and setting it was refused."
    echo "  chmod +x $APPIMAGETOOL"
    exit 1
fi

flutter config --enable-linux-desktop >/dev/null

# ---------- build ----------
flutter pub get

flutter build linux --release

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

cat > "$APPDIR/AppRun" <<APPRUN
#!/bin/sh
HERE=\$(dirname "\$(readlink -f "\$0")")
exec "\$HERE/usr/bin/$PROJ_NAME" "\$@"
APPRUN
chmod +x "$APPDIR/AppRun"

# ---------- pack ----------
IMAGE="$OUT_DIR/$PROJ_TITLE-$VERSION-$BUILD-x86_64.AppImage"
rm -f "$IMAGE"
# Extract-and-run: appimagetool is itself an AppImage, and FUSE is not always
# there to mount it.
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 "$APPIMAGETOOL" "$APPDIR" "$IMAGE"

# Three images are enough to fall back on; each one is some 40 MB.
KEEP=3
ls -t "$OUT_DIR/$PROJ_TITLE"-*-x86_64.AppImage 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
    echo "Removing older image: $(basename "$old")"
    rm -f "$old"
done

echo
echo "Version: $VERSION+$BUILD"
echo "Image:   $(du -sh "$IMAGE" | cut -f1)  $IMAGE"
echo "Run:     ./$IMAGE"
echo "Kept:"
ls -1t "$OUT_DIR/$PROJ_TITLE"-*-x86_64.AppImage 2>/dev/null | sed 's/^/  /'
