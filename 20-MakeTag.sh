#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

# Stamp the changelog with the current version and create the tag locally.
# Pushing is a separate step: 21-PushTag.sh

PUB_FILE="pubspec.yaml"
CHANGELOG_FILE="CHANGELOG.md"

echo "=== Checking that the working tree is clean ==="

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: You have uncommitted changes."
    echo "Please commit or stash them before running this script."
    exit 1
fi

echo "OK: Working tree is clean."

echo "=== Reading version from $PUB_FILE ==="
FULL_VER=$(grep -oP '^version:\s*\K[0-9.]+\+[0-9]+' "$PUB_FILE")

if [[ -z "$FULL_VER" ]]; then
    echo "ERROR: Could not read version from $PUB_FILE."
    exit 1
fi

# The pubspec spells the build with a +; the tag, like every artifact name here,
# spells it with a dash.
TAG="v${FULL_VER/+/-}"
echo "Tag: $TAG"

if git tag --list "$TAG" | grep -q "^${TAG}$"; then
    echo "Tag $TAG already exists. Nothing to do."
    exit 0
fi

if [[ ! -f "$CHANGELOG_FILE" ]]; then
    echo "ERROR: $CHANGELOG_FILE not found."
    exit 1
fi

if grep -q "^## ${TAG}$" "$CHANGELOG_FILE"; then
    echo "Changelog already has a section for $TAG. Skipping update."
else
    echo "=== Inserting $TAG section right after Unreleased ==="
    UPDATED="$(mktemp /tmp/changelog.XXXXXX.md)"

    # Keep an empty Unreleased on top for the next cycle and put the released
    # notes under the version heading below it.
    awk -v tag="$TAG" '
        /^## Unreleased$/ && !done {
            print $0
            print ""
            print "## " tag
            done=1
            next
        }
        { print }
    ' "$CHANGELOG_FILE" > "$UPDATED"

    if ! grep -q "^## ${TAG}$" "$UPDATED"; then
        echo "ERROR: No '## Unreleased' section found; changelog not stamped."
        rm -f "$UPDATED"
        exit 1
    fi

    mv "$UPDATED" "$CHANGELOG_FILE"

    echo "=== Committing changelog update ==="
    git add "$CHANGELOG_FILE"
    git commit -m "Add release notes for $TAG"
fi

echo "=== Creating tag $TAG ==="
git tag -a "$TAG" -m "Release $FULL_VER"

echo "=== Done: tag $TAG created ==="

sleep 2
