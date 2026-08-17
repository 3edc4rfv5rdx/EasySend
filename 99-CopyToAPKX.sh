#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

# Expose the arm64 release APK under an .apkx name in the project root, so it can
# be sent over Viber and the like without the messenger mangling an .apk
# attachment.
#
# Taken straight out of OUT/, where 19-LinkOut.sh has already put the newest
# build under its own name — so there is nothing here to pick or compose. The
# link keeps that name and changes only the extension.

OUT_DIR="OUT"

apk=$(ls -t "$OUT_DIR"/*arm64-v8a*.apk 2>/dev/null | head -1)

if [[ -z "$apk" || ! -f "$apk" ]]; then
    echo "ERROR: No arm64 APK in $OUT_DIR. Run ./19-LinkOut.sh first."
    exit 1
fi

dst="$(basename "${apk%.apk}").apkx"

# Only the current build keeps a link: the earlier ones are stale the moment this
# one is made, and dead ones point at APKs that were cleaned away. Plain .apkx
# files are left alone, they are copies someone made on purpose.
find . -maxdepth 1 -name '*.apkx' -type l ! -name "$dst" -delete

ln -sf "$apk" "$dst" 2>/dev/null || cp "$apk" "$dst"

echo "$(basename "$apk") -> $dst"
