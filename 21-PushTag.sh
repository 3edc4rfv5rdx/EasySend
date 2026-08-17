#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

# Push the branch and the latest tag. Create the tag first: 20-MakeTag.sh

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

echo "=== Detecting latest tag ==="
LAST_TAG=$(git tag --list 'v*' | sort -V | tail -n 1)

if [[ -z "$LAST_TAG" ]]; then
    echo "ERROR: No tags found. Run 20-MakeTag.sh first."
    exit 1
fi

echo "Latest tag: $LAST_TAG"

# Push the branch if it is behind. -u also sets upstream on a new branch.
BRANCH=$(git rev-parse --abbrev-ref HEAD)
git fetch "$REMOTE" "$BRANCH" --quiet 2>/dev/null || true
LOCAL=$(git rev-parse HEAD)
REMOTE_HEAD=$(git rev-parse "$REMOTE/$BRANCH" 2>/dev/null || echo "")

if [[ "$LOCAL" == "$REMOTE_HEAD" ]]; then
    echo "Branch $BRANCH is up to date with $REMOTE."
else
    echo "=== Pushing branch $BRANCH ($DRY) ==="
    git push $DRY -u "$REMOTE" HEAD
fi

# Asked for the one ref by its full name, and answered by whether anything came
# back. The old form grepped the output for the tag as a substring, so a tag that
# happens to be a prefix of another — v0.4.2608 beside v0.4.260817+112 — read as
# "already on the remote" and the real one was never pushed.
if [ -n "$(git ls-remote --tags "$REMOTE" "refs/tags/$LAST_TAG")" ]; then
    echo "Tag $LAST_TAG already exists on $REMOTE."
else
    echo "=== Pushing tag $LAST_TAG ($DRY) ==="
    git push $DRY "$REMOTE" "$LAST_TAG"
fi

echo "=== Done ==="

sleep 2
