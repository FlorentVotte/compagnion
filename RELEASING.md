# Releasing Compagnion

Maintainer notes — users install via Homebrew or the DMG (see README).

## Pipeline

```sh
VERSION=x.y.z BUILD=n ./release.sh   # universal, Developer ID signed, notarized, stapled DMG
DRY_RUN=1 ./release.sh               # everything except the Apple round-trips
CASK_ONLY=1 ./release.sh             # regenerate dist/compagnion.rb from an existing DMG
```

Output lands in `dist/Compagnion-<version>.dmg` plus `dist/compagnion.rb`,
the Homebrew cask with the version and sha256 already filled in. Both the app
and the DMG are notarized and stapled, so the app validates offline once
dragged out of the image.

## Publishing

```sh
gh release create v<version> dist/Compagnion-<version>.dmg --title v<version>
cp dist/compagnion.rb ../homebrew-tap/Casks/compagnion.rb   # then commit + push
```

The tap lives at [FlorentVotte/homebrew-tap](https://github.com/FlorentVotte/homebrew-tap).

## One-time setup

Paid Apple Developer membership required.

1. A **Developer ID Application** certificate in the login keychain — Xcode →
   Settings → Accounts → Manage Certificates → + . An "Apple Development"
   certificate cannot sign for distribution.
2. Notary credentials, using an [app-specific
   password](https://account.apple.com):

   ```sh
   xcrun notarytool store-credentials compagnion \
       --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
   ```

## Notes

- Release builds run under the hardened runtime, which blocks Apple Events
  unless `Resources/Compagnion.entitlements` grants them — without that,
  focusing a terminal tab fails in release builds only. `make-app.sh` applies
  the same runtime and entitlements to local ad-hoc builds so the two behave
  alike.
- The bundle icon is checked in at `Resources/Compagnion.icns`; regenerate it
  with `swift Resources/make-icon.swift` after changing the design. The
  asterisk is drawn by hand on purpose — Apple's license forbids rendering
  SF Symbols into app icons.
- UI iteration without clicking the status item: `COMPAGNION_PREVIEW=1
  .build/release/Compagnion` opens the panel in a regular window
  (`=settings` for the settings form).
