#!/usr/bin/env bash
# Build, gate, and package a release of Watchtower, then tag it.
#
# The GitHub release itself is NOT created here, deliberately, and neither is
# notarization. Read the boundary below before assuming either is an oversight.
#
# ---------------------------------------------------------------------------
# What this can and cannot produce
#
# This app is ad-hoc signed (`codesign -s -`). It is not signed with a Developer
# ID certificate and it is not notarized, so on any Mac other than the one that
# built it, Gatekeeper refuses it on first open. That is not a defect in the
# build; it is what an unnotarized app is.
#
# Notarizing would need a Developer ID Application certificate and a notarytool
# credential. No App Store Connect API key has ever been created for this
# account -- the same wall documented in greyscale's release script -- so
# notarytool cannot authenticate. Until that exists, the honest thing is to ship
# a zip that says plainly what it is rather than one that looks distributable
# and dies at Gatekeeper with a message about being damaged.
#
# So the release notes tell people how to open it, and say why they have to.
# ---------------------------------------------------------------------------
#
# Usage:  scripts/release.sh          # build, gate, package, tag
#         scripts/release.sh --no-tag # everything except the tag

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v${VERSION}"
APP="$ROOT/dist/Watchtower.app"
ZIP="$ROOT/dist/Watchtower-${VERSION}.zip"

echo "==> Watchtower ${VERSION}"

# A release built from a dirty tree is a release nobody can reproduce.
if [ -n "$(git status --porcelain)" ]; then
    echo "!! Working tree is dirty. Commit or stash first." >&2
    git status --short >&2
    exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "!! Tag $TAG already exists. Bump VERSION." >&2
    exit 1
fi

echo "==> Building"
scripts/make-app.sh >/dev/null
[ -d "$APP" ] || { echo "!! no app at $APP" >&2; exit 1; }

echo "==> Gate: the bundle reports the version it claims"
BUILT=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)
[ "$BUILT" = "$VERSION" ] || {
    echo "!! Bundle says $BUILT, VERSION says $VERSION" >&2; exit 1; }
echo "    $BUILT"

echo "==> Gate: signature verifies"
codesign --verify --deep --strict "$APP" 2>&1 | sed 's/^/    /' || {
    echo "!! signature does not verify" >&2; exit 1; }
echo "    ok (ad-hoc)"

echo "==> Gate: it runs offline"
# --login-item status is the one entry point that needs no AWS, no network and
# no credentials, and it exercises bundle loading and the ServiceManagement
# path. --selftest would be a better gate and cannot be used: it needs live
# credentials, so it would make releasing depend on the network being up and on
# an AWS account existing at all.
"$APP/Contents/MacOS/Watchtower" --login-item status >/dev/null || {
    echo "!! the binary does not run" >&2; exit 1; }
echo "    ok"

echo "==> Packaging"
rm -f "$ZIP"
# ditto, not zip: it preserves the bundle's symlinks and extended attributes, and
# a .app rebuilt from a plain `zip` can arrive with a broken signature.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "    $ZIP ($(du -h "$ZIP" | cut -f1))"

if [ "${1:-}" = "--no-tag" ]; then
    echo
    echo "Skipped tagging (--no-tag)."
    exit 0
fi

echo "==> Tagging $TAG"
git tag -a "$TAG" -m "Watchtower $VERSION"

echo
echo "Built and tagged. Not yet published. To publish:"
echo "    git push origin main $TAG"
echo "    gh release create $TAG '$ZIP' --title 'Watchtower $VERSION' --notes-file docs/release-notes-${VERSION}.md"
echo
echo "The zip is ad-hoc signed and NOT notarized. Anyone downloading it needs to"
echo "right-click ▸ Open the first time, or clear the quarantine flag:"
echo "    xattr -d com.apple.quarantine /Applications/Watchtower.app"
echo "Say so in the release notes. A download that dies at Gatekeeper with no"
echo "explanation reads as a broken build."
