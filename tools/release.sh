#!/bin/zsh
# Cuts a release: checks that everything agrees, tags it, and publishes it on GitHub with the notes
# from CHANGELOG.md. Run it on an up-to-date main, after the release pull request is merged.
#
#   tools/release.sh            release the version in VERSION
#   tools/release.sh --dry-run  check everything and print the notes, change nothing
set -euo pipefail
cd "$(dirname "$0")/.."

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1
VERSION="$(cat VERSION)"
TAG="v$VERSION"
fail() { print -P "%F{red}%B$1%b%f" >&2; exit 1; }

[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "VERSION must look like 1.2.3, got: $VERSION"
grep -q "^## \[$VERSION\]" CHANGELOG.md || fail "CHANGELOG.md has no section for $VERSION. Move the notes out of Unreleased first."

# The notes are the changelog section for this version, without its heading.
NOTES="$(awk -v v="$VERSION" '
  $0 ~ "^## \\[" v "\\]" { on = 1; next }
  on && /^## \[/ { exit }
  on && /^\[[^]]+\]: / { next }
  on { print }' CHANGELOG.md)"
[[ -n "${NOTES//[[:space:]]/}" ]] || fail "The CHANGELOG.md section for $VERSION is empty."
grep -q "Tynda-$VERSION.dmg" docs/index.html || fail "The landing page (docs/index.html) does not offer Tynda-$VERSION.dmg."
grep -q "Tynda-$VERSION.dmg" README.md || fail "README.md does not offer Tynda-$VERSION.dmg."

if (( DRY )); then
  echo "Would release $TAG with these notes:"; echo; echo "$NOTES"
  exit 0
fi

[[ "$(git branch --show-current)" == "main" ]] || fail "Releases are cut from main."
[[ -z "$(git status --porcelain)" ]] || fail "The working tree is not clean."
git fetch --quiet origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main is not in step with origin/main. Pull or push first."
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "Tag $TAG already exists."

tools/make_dmg.sh >/dev/null   # a release that does not build is not a release
DMG="dist/Tynda-$VERSION.dmg"

git tag -a "$TAG" -m "Tynda $VERSION"
git push origin "$TAG"
PRERELEASE=()
[[ "$VERSION" == 0.* ]] && PRERELEASE=(--prerelease)
gh release create "$TAG" "$DMG" --title "Tynda $VERSION" --notes "$NOTES

**Install:** download \`Tynda-$VERSION.dmg\` below, open it and drag Tynda into Applications. The first time, macOS wants a click on Open Anyway in System Settings → Privacy & Security.
**From source:** \`git clone --branch $TAG https://github.com/Markerloop-Team/tynda.git && cd tynda && ./install.sh\`
Needs a Mac with Apple silicon and macOS 14 or newer. More on [tynda.markerloop.com](https://tynda.markerloop.com)." --verify-tag "${PRERELEASE[@]}"
echo "Released $TAG"
