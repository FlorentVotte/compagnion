# Compagnion

macOS menu-bar companion for Claude Code: see at a glance which of your
sessions are working, idle, or waiting for your input.

## How it works

Polls `claude agents --json` every 3 seconds and aggregates the state of all
interactive and background Claude Code sessions on this machine.

Menu-bar icon:

| Icon | Meaning |
|---|---|
| `!` + count (orange) | One or more sessions are **waiting for you** (permission prompt, question…) |
| `✱` filled | At least one session is actively working |
| `✱` outline | Sessions exist, all idle |
| `✱` dimmed | No active session |

Click the icon for the session list: name, status, working directory, elapsed
time. Hover a row to copy the command that jumps back into that session
(`claude --resume <id>` or `claude attach <id>` for background agents).

## Run

```sh
swift run            # quick start, runs from the terminal
```

## Install

```sh
brew install --cask florentvotte/tap/compagnion
```

Or grab the DMG from [Releases](https://github.com/FlorentVotte/compagnion/releases)
and drag Compagnion into Applications. Both are universal, Developer ID signed
and notarized, so no Gatekeeper prompt.

## Build it yourself

```sh
./make-app.sh        # builds release + Compagnion.app
open Compagnion.app
```

Add `Compagnion.app` to **System Settings → General → Login Items** to start
it automatically.

The bundle icon is checked in at `Resources/Compagnion.icns`; regenerate it
with `swift Resources/make-icon.swift` after changing the design.

## Distribution

```sh
./release.sh         # universal, Developer ID signed, notarized, stapled DMG
DRY_RUN=1 ./release.sh   # everything except the Apple round-trips
```

Output lands in `dist/Compagnion-<version>.dmg` plus `dist/compagnion.rb`, the
Homebrew cask with the version and sha256 already filled in. Both the app and
the DMG are notarized and stapled, so the app validates offline once dragged
out of the image.

Publishing a release:

```sh
gh release create v<version> dist/Compagnion-<version>.dmg --title v<version>
cp dist/compagnion.rb ../homebrew-tap/Casks/compagnion.rb   # then commit + push
```

The tap lives at [FlorentVotte/homebrew-tap](https://github.com/FlorentVotte/homebrew-tap).
`CASK_ONLY=1 ./release.sh` regenerates the cask from an existing DMG when only
its metadata changed, without rebuilding or re-notarizing.

One-time setup (paid Apple Developer membership required):

1. A **Developer ID Application** certificate in the login keychain — Xcode →
   Settings → Accounts → Manage Certificates → + . An "Apple Development"
   certificate cannot sign for distribution.
2. Notary credentials, using an [app-specific
   password](https://account.apple.com):

   ```sh
   xcrun notarytool store-credentials compagnion \
       --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
   ```

Release builds run under the hardened runtime, which blocks Apple Events
unless `Resources/Compagnion.entitlements` grants them — without that, focusing
a terminal tab fails in release builds only. `make-app.sh` applies the same
runtime and entitlements to local ad-hoc builds so the two behave alike.

## Requirements

- macOS 14+
- Claude Code CLI installed (looked up in `~/.local/bin`, `~/.claude/local`,
  `/opt/homebrew/bin`, `/usr/local/bin`)

## Privacy

Everything stays on your machine: Compagnion reads local Claude Code state
(`claude agents --json`, `~/.claude` transcripts and settings) and listens
only on `127.0.0.1`. It sends no telemetry and makes no network requests.

## License

[MIT](LICENSE).

Compagnion is an independent open-source project. It is not affiliated with,
endorsed by, or sponsored by Anthropic. Claude is a trademark of Anthropic,
PBC.
