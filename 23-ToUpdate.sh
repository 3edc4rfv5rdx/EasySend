#!/usr/bin/env bash
#
# Publish the update manifest for the newest GitHub release, so the app's own
# updater can offer it:
#
#   <release assets>/latest.json
#
# Nothing is built and no APK is uploaded here: run it after 22-RelUpload.sh,
# which puts the APKs of the tag into the release. This step only describes what
# is already there — for every APK asset it names the ABI, the version code read
# out of that APK and its SHA-256.
#
# GitHub serves the newest release under a fixed path, so the app is built once
# with
#
#   https://github.com/<user>/<repo>/releases/latest/download/latest.json
#
# and never learns a tag or a version. The APK urls in the manifest are relative
# to that file, which is exactly where the release keeps its assets.
#
# The same file in every project — copy it as it is. The repository comes from
# the git remote, the release from GitHub, and everything in the manifest is read
# out of the APKs themselves. The version code in particular is read with aapt2
# and per asset: a Flutter build under --split-per-abi can carry abi * 1000 +
# build, so one build is 1148 on armeabi-v7a and 2148 on arm64, and the updater
# compares the manifest against the code inside the installed package.
#
# Exit codes: 0 published, 3 nothing to publish (no release yet), 1 a failure.
#
set -e
cd "$(dirname "$0")"

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    sed -n '2,28p' "$0"
    exit 0
fi

# ------------------------------------------------------------
# Settings. Every one of them can stay as it is in every project.
# ------------------------------------------------------------
# Where the release build leaves its APKs — the local copies of what the release
# carries, which is what the checksums are taken from. Empty means: Kotlin layout
# first, Flutter layout second, whichever exists.
APK_DIR=""

# The splits to recognise in an asset name. An asset naming none of them — an
# AppImage, a .sha256 sidecar — is not an APK this manifest can offer.
ABIS="arm64-v8a armeabi-v7a x86_64 x86 universal"

# ------------------------------------------------------------
if [ -z "$APK_DIR" ]; then
    for candidate in "app/build/outputs/apk/release" "build/app/outputs/flutter-apk"; do
        [ -d "$candidate" ] && { APK_DIR="$candidate"; break; }
    done
fi

if [ -z "$APK_DIR" ] || [ ! -d "$APK_DIR" ]; then
    echo "ERROR: no release output folder. Build a release first."
    exit 1
fi

command -v gh >/dev/null || { echo "ERROR: gh not found"; exit 1; }
command -v aapt2 >/dev/null || { echo "ERROR: aapt2 not found"; exit 1; }

# The ABI as a whole name and not as a substring: "x86" must not match an
# x86_64 asset, and neither must the AppImage of the same build.
matches_abi() {
    local base="$1" abi="$2"
    [[ "$base" =~ (^|[-_])${abi}([-.]|$) ]]
}

# ------------------------------------------------------------
# The release the client will read: GitHub serves /releases/latest, and that is
# the newest published release of this repository, whatever its tag.
# ------------------------------------------------------------
slug=$(gh repo view --json nameWithOwner -q .nameWithOwner)

if ! meta=$(gh release view --json tagName,isPrerelease         -q '.tagName + " " + (.isPrerelease | tostring)' 2>/dev/null); then
    echo "No release in $slug yet — run 20-MakeTag.sh, 21-PushTag.sh and 22-RelUpload.sh first."
    exit 3
fi

tag=${meta% *}
prerelease=${meta##* }

# /releases/latest skips a prerelease, so a manifest published on one would be
# offered to nobody, and the release before it would go on being served.
if [ "$prerelease" = "true" ]; then
    echo "ERROR: $tag is a prerelease; /releases/latest does not serve it."
    exit 1
fi

echo "Release: $slug  $tag"

# ------------------------------------------------------------
# What that release carries, and what each of those APKs says about itself.
# ------------------------------------------------------------
pkg=""
name=""
missing=0
abis=()
names=()
codes=()
sizes=()
shas=()

for asset in $(gh release view "$tag" --json assets -q '.assets[].name'); do
    case "$asset" in *.apk) ;; *) continue ;; esac

    abi=""
    for a in $ABIS; do
        if matches_abi "$asset" "$a"; then
            abi="$a"
            break
        fi
    done
    [ -n "$abi" ] || continue

    # The checksum has to be of the file the release serves, so it is taken from
    # the local copy the upload was made from. A release published from another
    # machine has none here, and a guess is worse than a gap.
    src="$APK_DIR/$asset"
    if [ ! -f "$src" ]; then
        echo "skipped $abi: $asset is in the release but not in $APK_DIR"
        missing=$((missing + 1))
        continue
    fi

    badging=$(aapt2 dump badging "$src")
    p=$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<<"$badging" | head -1)
    c=$(sed -n "s/.*versionCode='\([0-9]*\)'.*/\1/p" <<<"$badging" | head -1)
    n=$(sed -n "s/.*versionName='\([^']*\)'.*/\1/p" <<<"$badging" | head -1)

    if [ -z "$p" ] || [ -z "$c" ] || [ -z "$n" ]; then
        echo "ERROR: could not read package/version out of $asset"
        exit 1
    fi

    # The version code legitimately differs between splits; the package and the
    # version name never do, and if they do these are not one build.
    if [ -n "$pkg" ] && { [ "$p" != "$pkg" ] || [ "$n" != "$name" ]; }; then
        echo "ERROR: $asset is $p $n, the others are $pkg $name"
        exit 1
    fi
    pkg="$p"
    name="$n"

    abis+=("$abi")
    names+=("$asset")
    codes+=("$c")
    sizes+=("$(stat -c%s "$src")")
    shas+=("$(sha256sum "$src" | cut -d' ' -f1)")
done

if [ ${#names[@]} -eq 0 ]; then
    if [ "$missing" -gt 0 ]; then
        # The checksums come from the local copies, so the manifest is written
        # while the build that was uploaded is still in the output folder.
        echo "ERROR: $tag was not built here, or the output folder has been cleaned."
        echo "       Publish the manifest right after 22-RelUpload.sh."
    else
        echo "ERROR: no APK asset in $tag. Run 22-RelUpload.sh first."
    fi
    exit 1
fi

# ------------------------------------------------------------
# The manifest, uploaded under a name that does not move between releases.
# ------------------------------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

{
    echo "{"
    echo "  \"package\": \"$pkg\","
    echo "  \"versionName\": \"$name\","
    echo "  \"builds\": {"
    last=$((${#abis[@]} - 1))
    for i in "${!abis[@]}"; do
        comma=","
        [ "$i" -eq "$last" ] && comma=""
        echo "    \"${abis[$i]}\": {"
        echo "      \"versionCode\": ${codes[$i]},"
        echo "      \"url\": \"${names[$i]}\","
        echo "      \"size\": ${sizes[$i]},"
        echo "      \"sha256\": \"${shas[$i]}\""
        echo "    }$comma"
    done
    echo "  }"
    echo "}"
} > "$tmp/latest.json"

gh release upload "$tag" "$tmp/latest.json" --clobber >/dev/null

echo "published: $pkg  version $name"
for i in "${!abis[@]}"; do
    echo "           ${names[$i]}  build ${codes[$i]}  ${sizes[$i]} bytes"
done
echo "           https://github.com/$slug/releases/latest/download/latest.json"


sleep 3
