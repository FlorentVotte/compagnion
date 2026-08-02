#!/bin/zsh
# Produce a distributable Compagnion.dmg: universal binary, Developer ID
# signature, notarized and stapled so it opens without a Gatekeeper warning
# on a Mac that has never seen it. Also emits the Homebrew cask.
#
#   ./release.sh                  full run
#   VERSION=0.3.0 ./release.sh    override the version stamped in Info.plist
#   DRY_RUN=1 ./release.sh        build + sign + package, skip Apple round-trips
#   CASK_ONLY=1 ./release.sh      regenerate dist/compagnion.rb from an existing
#                                 DMG (cask metadata edits, no rebuild)
#
# One-time setup:
#   1. A "Developer ID Application" certificate in the login keychain. Xcode's
#      Settings → Accounts → Manage Certificates only offers to create one for
#      the team's Account Holder; otherwise generate a CSR in Keychain Access
#      and upload it at developer.apple.com → Certificates → +.
#   2. xcrun notarytool store-credentials compagnion \
#          --apple-id <you@example.com> --team-id <TEAMID>
set -e
cd "$(dirname "$0")"

VERSION=${VERSION:-0.2.0}
BUILD=${BUILD:-2}
KEYCHAIN_PROFILE=${KEYCHAIN_PROFILE:-compagnion}
DRY_RUN=${DRY_RUN:-0}
CASK_ONLY=${CASK_ONLY:-0}
# Where the DMG is published; baked into the generated cask's url/homepage.
GITHUB_REPO=${GITHUB_REPO:-FlorentVotte/compagnion}

APP=Compagnion.app
DIST=dist
DMG="$DIST/Compagnion-$VERSION.dmg"
ZIP="$DIST/Compagnion-$VERSION.zip"
CASK="$DIST/compagnion.rb"

# --- Homebrew cask -----------------------------------------------------------

# Generated rather than hand-maintained: the sha256 changes with every build,
# and a stale one in the tap fails only at `brew install` time, on someone
# else's machine.
emit_cask() {
    local sha
    sha=$(shasum -a 256 "$DMG" | cut -d' ' -f1)

    cat > "$CASK" <<EOF
cask "compagnion" do
  version "$VERSION"
  sha256 "$sha"

  url "https://github.com/$GITHUB_REPO/releases/download/v#{version}/Compagnion-#{version}.dmg"
  name "Compagnion"
  desc "Menu-bar companion showing which Claude Code sessions need attention"
  homepage "https://github.com/$GITHUB_REPO"

  livecheck do
    url :url
    strategy :github_latest
  end

  # A bare symbol means "this version or newer". The ">= :sonoma" string form
  # is deprecated and warns on every brew invocation.
  depends_on macos: :sonoma

  app "Compagnion.app"

  uninstall quit: "dev.florent.compagnion"

  # Deliberately not touching ~/.claude/settings.json: those hooks are removed
  # by the in-app integration toggle, and rewriting a user's Claude Code config
  # from an uninstaller risks clobbering unrelated settings.
  zap trash: [
    "~/Library/Application Support/Compagnion",
    "~/Library/Caches/dev.florent.compagnion",
    "~/Library/HTTPStorages/dev.florent.compagnion",
    "~/Library/Preferences/dev.florent.compagnion.plist",
    "~/Library/Saved Application State/dev.florent.compagnion.savedState",
  ]

  caveats <<~CAVEATS
    Compagnion runs in the menu bar and has no Dock icon.

    Before uninstalling, open Settings and disable the Claude Code integration
    so its hooks are removed from ~/.claude/settings.json.

    To start it at login, add it under
    System Settings > General > Login Items.
  CAVEATS
end
EOF
    echo "==> Wrote $CASK (sha256 ${sha:0:16}…)"
}

summary() {
    echo
    echo "Done: $PWD/$DMG"
    echo "      $PWD/$CASK"
    echo
    echo "Publish:"
    echo "  gh release create v$VERSION $DMG --repo $GITHUB_REPO --title v$VERSION"
    echo "  cp $CASK <tap>/Casks/compagnion.rb && git -C <tap> commit -am v$VERSION && git -C <tap> push"
}

if [ "$CASK_ONLY" = "1" ]; then
    [ -f "$DMG" ] || { echo "error: $DMG not found; run a full release first" >&2; exit 1; }
    emit_cask
    summary
    exit 0
fi

# --- Preflight ---------------------------------------------------------------

if [ -z "$SIGN_IDENTITY" ]; then
    # Match the certificate by prefix so the run does not break when the
    # trailing team ID or the certificate itself is rotated.
    SIGN_IDENTITY=$(security find-identity -v -p codesigning \
        | grep "Developer ID Application" \
        | head -1 \
        | sed -E 's/.*"(.*)"/\1/')
fi

if [ -z "$SIGN_IDENTITY" ]; then
    cat >&2 <<'EOF'
error: no "Developer ID Application" certificate in the keychain.

An "Apple Development" certificate is not enough — it cannot sign for
distribution and Apple will not notarize anything signed with it.

Create one (paid membership required; only the team's Account Holder can):
  Keychain Access → Certificate Assistant → Request a Certificate…
  then upload the CSR at developer.apple.com/account/resources/certificates/add

Then re-run. Override detection with SIGN_IDENTITY="Developer ID Application: …"
EOF
    exit 1
fi

if [ "$DRY_RUN" != "1" ] \
   && ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
    cat >&2 <<EOF
error: no notarytool credentials stored under profile "$KEYCHAIN_PROFILE".

Create an app-specific password at https://account.apple.com → Sign-In and
Security → App-Specific Passwords, then:

  xcrun notarytool store-credentials $KEYCHAIN_PROFILE \\
      --apple-id <your-apple-id> --team-id <your-team-id>
EOF
    exit 1
fi

echo "==> Signing identity: $SIGN_IDENTITY"

# --- Build -------------------------------------------------------------------

echo "==> Building universal $VERSION (build $BUILD)"
VERSION="$VERSION" BUILD="$BUILD" UNIVERSAL=1 SIGN_IDENTITY="$SIGN_IDENTITY" ./make-app.sh

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP"
# Notarization rejects a bundle without the hardened runtime, but only after a
# multi-minute round-trip — so fail here instead.
if ! codesign -d --verbose=2 "$APP" 2>&1 | grep -q 'flags=.*runtime'; then
    echo "error: hardened runtime missing from the signature" >&2
    exit 1
fi
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p -

rm -rf "$DIST"
mkdir -p "$DIST"

if [ "$DRY_RUN" = "1" ]; then
    echo "==> DRY_RUN: skipping notarization"
fi

# --- Notarize the app --------------------------------------------------------

# The app is notarized and stapled on its own first, so the copy a user drags
# out of the DMG carries its own ticket and validates offline. Stapling only
# the DMG would leave the extracted app dependent on a Gatekeeper network
# check.
notarize() {
    local target=$1
    if [ "$DRY_RUN" = "1" ]; then
        echo "==> DRY_RUN: would notarize $target"
        return
    fi
    echo "==> Notarizing $target (this takes a few minutes)"
    xcrun notarytool submit "$target" --keychain-profile "$KEYCHAIN_PROFILE" --wait
}

# notarytool takes an archive, not a bundle; ditto preserves the signature in a
# way `zip` does not.
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"

if [ "$DRY_RUN" != "1" ]; then
    echo "==> Stapling $APP"
    xcrun stapler staple "$APP"
fi

# --- Package and notarize the DMG --------------------------------------------

echo "==> Building $DMG"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto "$APP" "$STAGE/$APP"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname Compagnion -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# The DMG is signed and notarized too, so the disk image itself opens cleanly.
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
notarize "$DMG"

if [ "$DRY_RUN" != "1" ]; then
    echo "==> Stapling $DMG"
    xcrun stapler staple "$DMG"

    echo "==> Gatekeeper assessment"
    # -t open is the check that matters for a DMG a user downloads.
    spctl --assess --type open --context context:primary-signature -vv "$DMG"
    spctl --assess --type execute -vv "$APP"
    xcrun stapler validate "$DMG"
fi

rm -f "$ZIP"

emit_cask
summary
