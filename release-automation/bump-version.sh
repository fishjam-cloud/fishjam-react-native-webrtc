#!/bin/bash
set -euo pipefail

# Called by fishjam-cloud/release-automation's create-release-pr.sh during a release.
# Creates a release branch and bumps the npm package version without committing;
# the orchestrator commits, pushes and opens the PR. Must print BRANCH_NAME:<branch>.
#
# Usage: ./bump-version.sh <version>

VERSION="$1"

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version>"
    exit 1
fi

BRANCH_NAME="release-$VERSION"
git checkout -b "$BRANCH_NAME"

npm version "$VERSION" --no-git-tag-version
echo "Updated package.json to $VERSION"

echo "BRANCH_NAME:$BRANCH_NAME"
