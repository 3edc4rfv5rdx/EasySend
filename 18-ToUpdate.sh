#!/usr/bin/env bash
#
# Publish the newest release APK to the update server, so the app's own updater
# can offer it:
#
#   $UPDATES_ROOT/<app>/<app>-<version>-<build>-<abi>.apk
#   $UPDATES_ROOT/<app>/<app>-latest.apk   -> the file above
#   $UPDATES_ROOT/<app>/latest.json        -> the manifest the updater reads
#
# Nothing is built here: run it after a release build, on a build that exists.
#
# The same file in every project — copy it as it is. Nothing below is written
# for one app: the folder name gives the app key, the layout of the build output
# says whether this is a Kotlin or a Flutter project, and everything that ends up
# in the manifest is read out of the APK itself.
#
# The version code in particular is read with aapt2 and not from
# build_number.txt or pubspec.yaml: a Flutter build under --split-per-abi can
# carry abi * 1000 + build, and the updater compares the manifest against the
# code inside the installed package, so the manifest has to say what the APK
# actually says.
#
# arm64 only by default: that is what the phones take. The x86_64 split is the
# emulator's and the universal APK belongs to the GitHub release.
#
set -e
cd "$(dirname "$0")"

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    sed -n '2,24p' "$0"
    exit 0
fi

# ------------------------------------------------------------
# Settings. Every one of them can stay as it is in every project.
# ------------------------------------------------------------
UPDATES_ROOT="/var/www/updates"

# The folder served for this app, and the prefix of the published file name.
# Empty means the project folder's own name, lowercased — the same name the
# .apkx in the project root already carries.
APP_KEY=""

# Where the release build leaves its APKs. Empty means: Kotlin layout first,
# Flutter layout second, whichever exists.
APK_DIR=""

# The split to publish. Phones take arm64.
ABI="arm64-v8a"

# How many previous builds to keep in archive/. Nothing else ever empties
# that folder, and at some 20 MB a build a week of testing fills it.
KEEP_ARCHIVE=3

# ------------------------------------------------------------
[ -n "$APP_KEY" ] || APP_KEY=$(basename "$PWD" | tr '[:upper:]' '[:lower:]')

if [ -z "$APK_DIR" ]; then
    for candidate in "app/build/outputs/apk/release" "build/app/outputs/flutter-apk"; do
        [ -d "$candidate" ] && { APK_DIR="$candidate"; break; }
    done
fi

if [ -z "$APK_DIR" ] || [ ! -d "$APK_DIR" ]; then
    echo "ERROR: no release output folder. Build a release first."
    exit 1
fi

command -v aapt2 >/dev/null || { echo "ERROR: aapt2 not found"; exit 1; }

# Debug splits sit in the same folder in Flutter projects, and one of them
# carries the ABI in its name too.
apk=$(ls -t "$APK_DIR"/*"$ABI"*.apk 2>/dev/null | grep -v -- '-debug' | head -1)
if [ -z "$apk" ] || [ ! -f "$apk" ]; then
    echo "ERROR: no $ABI release APK in $APK_DIR. Build a release first."
    exit 1
fi

badging=$(aapt2 dump badging "$apk")
pkg=$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<<"$badging" | head -1)
code=$(sed -n "s/.*versionCode='\([0-9]*\)'.*/\1/p" <<<"$badging" | head -1)
name=$(sed -n "s/.*versionName='\([^']*\)'.*/\1/p" <<<"$badging" | head -1)

if [ -z "$pkg" ] || [ -z "$code" ] || [ -z "$name" ]; then
    echo "ERROR: could not read package/version out of $(basename "$apk")"
    exit 1
fi

DST_DIR="$UPDATES_ROOT/$APP_KEY"
mkdir -p "$DST_DIR/archive"
[ -w "$DST_DIR" ] || { echo "ERROR: $DST_DIR is not writable"; exit 1; }

dst="$APP_KEY-$name-$code-$ABI.apk"

# Whatever was published before moves aside before the new file lands, so the
# folder never shows two builds as if both were current. The manifest is
# rewritten below and points at the new name either way.
for old in "$DST_DIR"/*.apk; do
    [ -e "$old" ] || continue
    # The fixed-name link is not a build to archive; it is rewritten below.
    [ -L "$old" ] && continue
    [ "$(basename "$old")" = "$dst" ] && continue
    mv -f "$old" "$DST_DIR/archive/"
done

# And the archive keeps only the last few. The build just moved in is the
# newest of them, so a KEEP_ARCHIVE of 3 leaves this one and two before it.
# A file that will not delete — one published earlier under another user — is
# reported and stepped over: this runs after the publish, and a folder that
# could not be tidied is not a failed publish.
ls -t "$DST_DIR/archive/"*.apk 2>/dev/null | tail -n +$((KEEP_ARCHIVE + 1)) | while read -r stale; do
    if rm -f "$stale" 2>/dev/null; then
        echo "Removed from archive: $(basename "$stale")"
    else
        echo "Could not remove $(basename "$stale") — not yours to delete."
    fi
done

cp -f "$apk" "$DST_DIR/$dst"

# A name that does not move between builds, for installing by hand or from a
# browser without reading the manifest first.
ln -sfn "$dst" "$DST_DIR/$APP_KEY-latest.apk"

size=$(stat -c%s "$DST_DIR/$dst")
sha=$(sha256sum "$DST_DIR/$dst" | cut -d' ' -f1)

# Written beside the target and moved into place: a client that polls while this
# runs reads either the old manifest or the new one, never half of one.
tmp="$DST_DIR/.latest.json.$$"
cat > "$tmp" <<JSON
{
  "package": "$pkg",
  "versionName": "$name",
  "versionCode": $code,
  "abi": "$ABI",
  "url": "$dst",
  "size": $size,
  "sha256": "$sha"
}
JSON
mv -f "$tmp" "$DST_DIR/latest.json"

echo "published: $dst"
echo "           $pkg  version $name  build $code  $size bytes"
echo "           $DST_DIR/latest.json"


sleep 3
