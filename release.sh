#!/usr/bin/env bash
# release.sh — bump, commit, tag, push, publish. One command.
#
#   1. Edit the VERSION file (e.g. change `1.0` to `1.1`).
#   2. Run:  ./release.sh "what changed in this release"
#
# It stages ALL your changes, commits them with that message, tags the commit
# v<VERSION>, and pushes the branch + tag. The pushed tag fires the GitHub release
# workflow, which builds the signed app and publishes the release.
#
# The only thing it refuses: reusing a version that's already been released (the
# tag exists). Bump VERSION and run again. That guard is what stops tag/version
# drift — there's no other prompt.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

err() { printf '\nrelease.sh: %s\n' "$*" >&2; exit 1; }

MESSAGE="$*"   # everything after the script name is the commit message

[ -f VERSION ] || err "no VERSION file at repo root"
VERSION="$(tr -d '[:space:]' < VERSION)"
[ -n "$VERSION" ] || err "VERSION file is empty"

# Marketing-version shape only (1.0, 1.2, 1.2.3) — keeps the tag and CFBundle
# value sane and matches the v<X> tag the release workflow expects.
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
  || err "VERSION '$VERSION' is not N.N or N.N.N"

TAG="v$VERSION"

# The one guard: don't reuse a released version.
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  err "tag $TAG already exists locally — bump VERSION before releasing"
fi
if git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
  err "tag $TAG already exists on origin — bump VERSION before releasing"
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || echo "release.sh: warning — releasing from '$BRANCH', not main"

# Stage and commit everything in the working tree under the given message. If the
# tree is already clean we just tag the current HEAD (no message needed).
if [ -n "$(git status --porcelain)" ]; then
  [ -n "$MESSAGE" ] || err 'working tree has changes — pass a commit message: ./release.sh "your message"'
  git add -A
  git commit -m "$MESSAGE"
  echo "release.sh: committed all changes → $TAG ($MESSAGE)"
else
  echo "release.sh: working tree clean; tagging current HEAD as $TAG"
fi

git tag -a "$TAG" -m "HeldByTime $TAG"
git push origin "$BRANCH"
git push origin "$TAG"

cat <<EOF

✓ Pushed $BRANCH + $TAG. The GitHub release workflow is now building the signed
app and will publish the $TAG release. Watch it under the repo's Actions tab.
EOF
