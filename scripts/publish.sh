#!/bin/zsh
# Publishes the DMG that release.sh built: a GitHub Release (v<version>) holding Compositor.dmg, its SHA-256
# checksum and a software bill of materials, then the Sparkle update feed (appcast.xml, committed to main)
# pointing at it.
#
# Run release.sh first. Needs the Sparkle signing key in the login keychain and `gh` signed in.
# Release notes: RELEASE_NOTES="…" ./scripts/publish.sh
#
# Where it publishes: REPO (owner/name) defaults to the `origin` remote's GitHub repository. Installed copies
# only ever look at the feed URL built into the app (SUFeedURL in Config/Info.plist), so publishing refuses
# unless that URL is this repository's appcast.xml on main, and unless the Sparkle key in the keychain is the
# one the app trusts (SUPublicEDKey). A fork that ships its own builds changes both in Info.plist on purpose;
# see "Releasing" in README.md.
#
# It also refuses unless: the current branch is main, the tree is clean, main matches origin/main, the DMG was
# built by release.sh from exactly this commit with a clean tree, and the CI workflow passed on this commit
# on GitHub. SKIP_HOSTED_CI=1 drops only the last check (for a repository without GitHub Actions).
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP=Compositor
WORK="$HOME/Library/Caches/CompositorRelease"
SPARKLE_BIN="$WORK/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
SIGN_UPDATE="$SPARKLE_BIN/sign_update"
GENERATE_KEYS="$SPARKLE_BIN/generate_keys"
INFO_PLIST="$PROJECT_DIR/Config/Info.plist"
git=(git -C "$PROJECT_DIR")

fail() { print -r -- "publish: $*" >&2; exit 1; }

# owner/name from a GitHub remote URL (https or ssh), or nothing for anything else.
github_repo() {
  print -r -- "$1" | sed -nE 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+/[^/]+)$#\2#p' \
    | sed -E 's#\.git$##'
}

# --- Where to publish -------------------------------------------------------------------------------------

origin_url=$("${git[@]}" remote get-url origin 2>/dev/null || true)
ORIGIN_REPO=$(github_repo "$origin_url")
REPO="${REPO:-$ORIGIN_REPO}"
[[ "$REPO" =~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ]] \
  || fail "can't tell which GitHub repository to publish to (origin is '${origin_url:-unset}'). Set REPO=owner/name."
# The appcast commit is pushed to origin, so origin has to be the repository the feed is read from.
if [[ -n "$ORIGIN_REPO" && "${(L)ORIGIN_REPO}" != "${(L)REPO}" ]]; then
  fail "REPO=$REPO, but the appcast would be pushed to origin ($ORIGIN_REPO)."
fi

FEED_URL="https://raw.githubusercontent.com/$REPO/main/appcast.xml"
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }
check_feed() { # $1: an Info.plist, $2: what it is
  local feed=$(plist_value "$1" SUFeedURL)
  [[ "${(L)feed}" == "${(L)FEED_URL}" ]] && return
  fail "the $2 reads updates from
    ${feed:-(no SUFeedURL)}
  but this would publish to
    $FEED_URL
  Copies already installed would never see this release. Publish from the repository the feed names, or change
  SUFeedURL (and SUPublicEDKey) in Config/Info.plist deliberately, release, then publish. See README.md › Releasing."
}
check_feed "$INFO_PLIST" "app (Config/Info.plist)"

# --- What is being published ------------------------------------------------------------------------------

settings=$(xcodebuild -project "$PROJECT_DIR/$APP.xcodeproj" -scheme "$APP" -configuration Release -showBuildSettings 2>/dev/null)
VERSION=$(print -r -- "$settings" | awk -F' = ' '/ MARKETING_VERSION = /{print $2; exit}')
BUILD=$(print -r -- "$settings" | awk -F' = ' '/ CURRENT_PROJECT_VERSION = /{print $2; exit}')
MINIMUM=$(print -r -- "$settings" | awk -F' = ' '/ MACOSX_DEPLOYMENT_TARGET = /{print $2; exit}')
TAG="v$VERSION"
SOURCE="$PROJECT_DIR/dist/$APP-$VERSION.dmg"
BUILD_INFO="$PROJECT_DIR/dist/$APP-$VERSION.build-info"
EXPORTED_APP="$WORK/export/$APP.app"
[[ -f "$SOURCE" ]] || fail "no $SOURCE — run scripts/release.sh first."
[[ -f "$BUILD_INFO" ]] || fail "no $BUILD_INFO — that DMG didn't come from a finished scripts/release.sh run."
[[ -x "$SIGN_UPDATE" && -x "$GENERATE_KEYS" ]] || fail "Sparkle's tools aren't built — run scripts/release.sh first."
# The app inside the DMG is what users run, so check its feed too, not only the source plist.
if [[ -f "$EXPORTED_APP/Contents/Info.plist" ]]; then
  check_feed "$EXPORTED_APP/Contents/Info.plist" "built app ($EXPORTED_APP)"
fi

# Sparkle rejects an update signed by any key but the app's own, so a mismatch would publish an update
# no one can install.
trusted_key=$(plist_value "$INFO_PLIST" SUPublicEDKey)
keychain_key=$("$GENERATE_KEYS" -p 2>/dev/null | tail -1 | tr -d '[:space:]' || true)
[[ -n "$keychain_key" && "$keychain_key" == "$trusted_key" ]] \
  || fail "the Sparkle key in the keychain (${keychain_key:-none}) isn't the app's SUPublicEDKey ($trusted_key)."

# --- The commit being released ----------------------------------------------------------------------------

branch=$("${git[@]}" symbolic-ref --short -q HEAD || true)
[[ "$branch" == main ]] || fail "publish from main (on '${branch:-a detached HEAD}'): the feed is read from main."
[[ -z "$("${git[@]}" status --porcelain)" ]] || fail "the working tree has uncommitted changes; commit or stash them."
"${git[@]}" fetch -q origin main
HEAD_SHA=$("${git[@]}" rev-parse HEAD)
[[ "$HEAD_SHA" == "$("${git[@]}" rev-parse origin/main)" ]] \
  || fail "main isn't the same as origin/main. Push (or pull) first, so the tag and feed land on what CI tested."

built_commit=$(sed -n 's/^commit=//p' "$BUILD_INFO")
built_dirty=$(sed -n 's/^dirty=//p' "$BUILD_INFO")
built_ci=$(sed -n 's/^ci=//p' "$BUILD_INFO")
[[ "$built_commit" == "$HEAD_SHA" ]] || fail "the DMG was built from $built_commit, not HEAD ($HEAD_SHA). Run scripts/release.sh again."
[[ "$built_dirty" == no ]] || fail "the DMG was built from a working tree with uncommitted changes. Run scripts/release.sh again."
[[ "$built_ci" == passed ]] || echo "==> Note: release.sh skipped scripts/ci.sh (SKIP_CI=1) for this build"

if [[ "${SKIP_HOSTED_CI:-}" != 1 ]]; then
  ci=$(gh run list --repo "$REPO" --workflow ci.yml --branch main --commit "$HEAD_SHA" --limit 20 \
         --json status,conclusion --jq '[.[] | select(.status == "completed")][0].conclusion // ""' 2>/dev/null || true)
  [[ "$ci" == success ]] || fail "the CI workflow hasn't passed on $HEAD_SHA in $REPO (${ci:-no finished run}).
  Wait for it, or SKIP_HOSTED_CI=1 for a repository without GitHub Actions."
fi

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  fail "release $TAG already exists in $REPO. Raise the version (and build number) first."
fi

# --- Publish ----------------------------------------------------------------------------------------------

echo "==> $APP $VERSION ($BUILD) from $HEAD_SHA to $REPO"
# Every release names its files the same way, so …/releases/latest/download/Compositor.dmg always works.
PUBLISH="$WORK/publish"
rm -rf "$PUBLISH"
mkdir -p "$PUBLISH"
DMG="$PUBLISH/$APP.dmg"
cp "$SOURCE" "$DMG"

echo "==> Checksum and bill of materials"
# Verify a download with: shasum -a 256 -c Compositor.dmg.sha256 (from the folder holding both files).
(cd "$PUBLISH" && shasum -a 256 "$APP.dmg" > "$APP.dmg.sha256")
SHA256=$(awk '{print $1}' "$PUBLISH/$APP.dmg.sha256")
echo "    SHA-256 ($APP.dmg): $SHA256"
/usr/bin/python3 -I "$PROJECT_DIR/scripts/sbom.py" --version "$VERSION" --repo "$REPO" --commit "$HEAD_SHA" \
  > "$PUBLISH/$APP.spdx.json"

echo "==> Signing the update for Sparkle"
signature=$("$SIGN_UPDATE" "$DMG")

echo "==> Creating GitHub Release $TAG"
notes="${RELEASE_NOTES:-$APP $VERSION}

SHA-256 ($APP.dmg): \`$SHA256\`"
gh release create "$TAG" "$DMG" "$PUBLISH/$APP.dmg.sha256" "$PUBLISH/$APP.spdx.json" \
  --repo "$REPO" --target "$HEAD_SHA" --title "$APP $VERSION" --notes "$notes"

echo "==> Publishing the update feed"
cat > "$PROJECT_DIR/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP</title>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
      <link>https://github.com/$REPO/releases/tag/$TAG</link>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/$APP.dmg" $signature type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
"${git[@]}" add appcast.xml
"${git[@]}" commit -q -m "Publish update feed for $APP $VERSION"
# --no-verify: the pre-push hook would rebuild and retest the commit release.sh and CI already passed; this
# commit only adds appcast.xml.
"${git[@]}" push -q --no-verify origin HEAD:main
echo "==> Done: https://github.com/$REPO/releases/tag/$TAG"
