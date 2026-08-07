#!/usr/bin/env bash
set -e

REMOTE="origin"

# ===== dry-run switch =====
#DRY="--dry-run"
DRY=""
# ==========================

echo "=== Checking that the working tree is clean ==="

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: You have uncommitted changes."
    echo "Please commit or stash them before running this script."
    exit 1
fi

echo "OK: Working tree is clean."

echo "=== Reading version from pubspec.yaml ==="
ROOT="$(git rev-parse --show-toplevel)"
FULL_VER=$(grep -oP '^version:\s*\K[0-9.]+\+[0-9]+' "$ROOT/pubspec.yaml")

if [[ -z "$FULL_VER" ]]; then
    echo "ERROR: Could not read version from pubspec.yaml."
    exit 1
fi

LAST_TAG="v$FULL_VER"
TAG_MSG="Release $FULL_VER"

echo "Version: $FULL_VER"
echo "Tag: $LAST_TAG"

echo "=== Stamping CHANGELOG.md ==="
CHANGELOG_FILE="$ROOT/CHANGELOG.md"

if [[ ! -f "$CHANGELOG_FILE" ]]; then
    echo "ERROR: File $CHANGELOG_FILE not found."
    exit 1
fi

# Rename the topmost "## Unreleased" working section to the release version and
# open a fresh empty "## Unreleased" above it for the next cycle.
if grep -qF "## $LAST_TAG" "$CHANGELOG_FILE"; then
    echo "CHANGELOG already stamped for $LAST_TAG."
else
    TMP_FILE="$(mktemp)"

    awk -v ver="## $LAST_TAG" '
    !stamped && /^## Unreleased[[:space:]]*$/ {
        print "## Unreleased"
        print ""
        print ver
        stamped = 1
        next
    }
    {
        print
    }
    ' "$CHANGELOG_FILE" > "$TMP_FILE"

    mv "$TMP_FILE" "$CHANGELOG_FILE"

    # Commit the stamp so the tag points at a CHANGELOG that shows the version
    if git diff --quiet -- "$CHANGELOG_FILE"; then
        echo "WARNING: No '## Unreleased' section found; CHANGELOG not stamped."
    else
        echo "=== Committing CHANGELOG stamp ==="
        git add "$CHANGELOG_FILE"
        git commit -m "Stamp CHANGELOG for $LAST_TAG"
    fi
fi

echo "=== Creating tag (if it does not exist) ==="
if git rev-parse -q --verify "refs/tags/$LAST_TAG" >/dev/null; then
    echo "Tag $LAST_TAG already exists, reusing it."
else
    git tag -a "$LAST_TAG" -m "$TAG_MSG"
    echo "Created tag $LAST_TAG."
fi

echo "=== Pushing current branch ($DRY) ==="
# -u HEAD also sets the upstream on first push of a new branch
git push $DRY -u "$REMOTE" HEAD

echo "=== Pushing tag ($DRY) ==="
git push $DRY "$REMOTE" "$LAST_TAG"

echo "=== Done ==="
sleep 2