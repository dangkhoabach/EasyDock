#!/usr/bin/env bash
# Builds, signs, DMGs and Sparkle-signs an EasyDock release entirely on this
# Mac (docs/release.md).
#
# Signing uses the Apple Development certificate named in Local.xcconfig.
# macOS keys the Accessibility and Screen Recording grants and the Keychain
# item of the clipboard key on the signing identity, so every release,
# including the ones Sparkle installs, must carry the same Team ID or users
# are asked for both permissions again. No notarization: first launch on
# another Mac needs System Settings › Privacy & Security › Open Anyway.
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="EasyDockApp"
PROJECT="EasyDock.xcodeproj"
APP_NAME="EasyDock"
INFO_PLIST="EasyDockApp/Info.plist"
# Every release so far is signed by this team; a different one would cost
# every user their permissions.
EXPECTED_TEAM="83829K9Z69"
# The Keychain account generate_keys created this app's EdDSA key under.
# Required: without --account, sign_update signs with the default account's
# key, a signature no installed copy accepts.
SPARKLE_ACCOUNT="easydock"
SPARKLE_VERSION="2.10.0"
# SHA-256 of Sparkle-2.10.0.tar.xz as GitHub lists it for the release asset.
# The tools run with access to the signing key, so they are verified first.
SPARKLE_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
SPARKLE_TOOLS_DIR=".sparkle-tools"

[ -f Local.xcconfig ] || { echo "Error: Local.xcconfig is missing. Copy Local.xcconfig.example first." >&2; exit 1; }
IDENTITY=$(sed -nE 's/^CODE_SIGN_IDENTITY *= *(.*)$/\1/p' Local.xcconfig)
[[ "$IDENTITY" == "Apple Development:"* ]] || { echo "Error: a release must be signed with the Apple Development certificate, not \"$IDENTITY\"." >&2; exit 1; }
command -v create-dmg >/dev/null || { echo "Error: create-dmg not found. Run: brew install create-dmg" >&2; exit 1; }

echo "==> Testing EasyDockCore"
(cd EasyDockCore && swift test)

echo "==> Testing EasyDockApp"
xcodebuild test -project "$PROJECT" -scheme "$SCHEME" -destination "platform=macOS" -quiet

# Info.plist is the source of truth for the version. Both fields get the
# same MAJOR.MINOR.PATCH, which is what admin.dangkhoabach.vn writes into
# the appcast.
CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")
SUGGESTED_VERSION=$(awk -F. '{print $1"."$2"."$3+1}' <<< "$CURRENT_VERSION")
read -rp "Current version is $CURRENT_VERSION. New version (e.g. $SUGGESTED_VERSION) [Enter to keep]: " INPUT
VERSION="${INPUT:-$CURRENT_VERSION}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Error: version must be MAJOR.MINOR.PATCH (digits only), got \"$VERSION\"." >&2; exit 1; }

# Sparkle decides "is there an update" by comparing versions, so a lower
# number than the published one leaves every install quietly stuck.
if [ "$VERSION" != "$CURRENT_VERSION" ] &&
   [ "$(printf '%s\n%s\n' "$CURRENT_VERSION" "$VERSION" | sort -V | tail -1)" != "$VERSION" ]; then
  echo "Error: $VERSION is lower than the current $CURRENT_VERSION." >&2
  exit 1
fi

# Info.plist is edited in place before the build, so any failure from here
# on would otherwise leave it bumped to a version that never shipped.
INFO_PLIST_BACKUP=$(mktemp)
cp "$INFO_PLIST" "$INFO_PLIST_BACKUP"

# One handler, installed once: `$?` inside a trap is whatever ran last, so
# chaining two traps would have the second read the first's exit code.
on_exit() {
  local status=$?
  if [ -n "${BUILD_DIR:-}" ]; then
    rm -rf "$BUILD_DIR"
  fi
  if [ "$status" -ne 0 ]; then
    echo "==> Failed (exit $status) — restoring $INFO_PLIST" >&2
    cp "$INFO_PLIST_BACKUP" "$INFO_PLIST"
  fi
  rm -f "$INFO_PLIST_BACKUP"
}
trap on_exit EXIT

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$INFO_PLIST"
echo "==> Releasing version $VERSION"

OUT_DIR="release-output/$VERSION"
mkdir -p "$OUT_DIR"
BUILD_DIR=$(mktemp -d)

echo "==> Building (Release, signed with \"$IDENTITY\", universal arm64+x86_64)"
# Without the generic destination xcodebuild builds for this Mac's own
# architecture only and Intel Macs would be left out.
xcodebuild build \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  -destination "generic/platform=macOS" -quiet

APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[ -d "$APP_PATH" ] || { echo "Error: no app at $APP_PATH — the build produced nothing." >&2; exit 1; }

echo "==> Verifying the built app"
codesign --verify --deep --strict "$APP_PATH" || {
  echo "Error: $APP_PATH failed signature verification." >&2
  exit 1
}
# Into a variable first: `grep -q` closing the pipe early makes codesign
# exit non-zero under pipefail, which read as "no runtime flag".
SIGNATURE=$(codesign -dvv "$APP_PATH" 2>&1)
grep -q 'flags=.*runtime' <<< "$SIGNATURE" || { echo "Error: Hardened Runtime is not set on the Release build." >&2; exit 1; }
grep -q "^TeamIdentifier=$EXPECTED_TEAM\$" <<< "$SIGNATURE" || {
  echo "Error: the app is not signed by team $EXPECTED_TEAM; users would be asked for their permissions again." >&2
  exit 1
}
ARCHS_BUILT=$(lipo -archs "$APP_PATH/Contents/MacOS/$APP_NAME")
for arch in arm64 x86_64; do
  grep -qw "$arch" <<< "$ARCHS_BUILT" || {
    echo "Error: binary is missing $arch (built: $ARCHS_BUILT). Intel or Apple Silicon Macs would be left out." >&2
    exit 1
  }
done
# Exactly the entitlements the app needs and nothing else — in
# particular no get-task-allow, which Xcode injects into Debug builds.
# apple-events lets EasyDock ask Finder to empty a Trash it can't read.
ENTITLEMENTS=$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null | grep -oE '<key>[^<]+</key>' | sort | tr -d '\n')
EXPECTED='<key>com.apple.security.app-sandbox</key><key>com.apple.security.automation.apple-events</key><key>com.apple.security.cs.disable-library-validation</key>'
[ "$ENTITLEMENTS" = "$EXPECTED" ] || { echo "Error: unexpected entitlements: $ENTITLEMENTS" >&2; exit 1; }
echo "    team OK, entitlements OK, hardened runtime OK, architectures: $ARCHS_BUILT"

echo "==> Creating DMG"
DMG_PATH="$OUT_DIR/EasyDock-$VERSION.dmg"
rm -f "$DMG_PATH"
create-dmg \
  --volname "$APP_NAME" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 100 \
  --icon "$APP_NAME.app" 160 185 \
  --hide-extension "$APP_NAME.app" \
  --app-drop-link 460 185 \
  "$DMG_PATH" \
  "$APP_PATH"

echo "==> Signing update with Sparkle"
# Cached per version, verified before anything is extracted.
SPARKLE_TOOLS_DIR="$SPARKLE_TOOLS_DIR/$SPARKLE_VERSION"
if [ ! -x "$SPARKLE_TOOLS_DIR/bin/sign_update" ]; then
  mkdir -p "$SPARKLE_TOOLS_DIR"
  curl -fsSL -o "$SPARKLE_TOOLS_DIR/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
  echo "$SPARKLE_SHA256  $SPARKLE_TOOLS_DIR/sparkle.tar.xz" | shasum -a 256 -c - || {
    echo "Error: Sparkle ${SPARKLE_VERSION} failed checksum verification. Refusing to run its tools." >&2
    rm -f "$SPARKLE_TOOLS_DIR/sparkle.tar.xz"
    exit 1
  }
  tar -xf "$SPARKLE_TOOLS_DIR/sparkle.tar.xz" -C "$SPARKLE_TOOLS_DIR"
fi
# -p prints only the raw EdDSA signature — exactly what the admin panel's
# "Sparkle signature" field expects.
"$SPARKLE_TOOLS_DIR/bin/sign_update" -p --account "$SPARKLE_ACCOUNT" "$DMG_PATH" | tee "$DMG_PATH.sig"
[ -s "$DMG_PATH.sig" ] || { echo "Error: sign_update produced an empty signature." >&2; exit 1; }

# The upload is two separate form fields; printing the installer's checksum
# gives something to compare against after uploading.
DMG_SHA256=$(shasum -a 256 "$DMG_PATH" | cut -d" " -f1)

cp -R "$APP_PATH" "$OUT_DIR/"
echo ""
echo "==> Done. Upload these two files at https://admin.dangkhoabach.vn (app: easydock):"
echo "    Installer:         $DMG_PATH"
echo "    Sparkle signature:  $DMG_PATH.sig"
echo "    Installer SHA-256: $DMG_SHA256"
echo "Install here with: ./scripts/install-local.sh $VERSION"
