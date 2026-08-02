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

## Install as an app

```sh
./make-app.sh        # builds release + Compagnion.app
open Compagnion.app
```

Add `Compagnion.app` to **System Settings → General → Login Items** to start
it automatically.

## Requirements

- macOS 14+
- Claude Code CLI installed (looked up in `~/.local/bin`, `~/.claude/local`,
  `/opt/homebrew/bin`, `/usr/local/bin`)
