# Compagnion — Feature Plan

Current state (v0.1): menu-bar icon + session list, fed by polling
`claude agents --json` every 3 s.

Target architecture once all phases land:

```
Claude Code sessions
  │  hooks (HTTP POST, instant events)          ┐
  │  statusline forwarder (context % + limits)  ├─▶ local listener (127.0.0.1, embedded in app)
  │  `claude agents --json` poll (authority)    ┘        │
  │  transcript JSONL / sessions-index (detail)          ▼
  └────────────────────────────────────▶ SessionStore ─▶ menu-bar UI + macOS notifications
```

Two new ingestion paths get added to the existing poll:

- **Local HTTP listener** — a tiny `Network.framework` server bound to
  `127.0.0.1:<port>` inside the app. Hooks and the statusline forwarder POST
  JSON to it. No polling latency, no extra processes.
- **Setup flow** — a preferences action that installs the required hook +
  statusline entries into `~/.claude/settings.json` (idempotent, clearly
  delimited, removable). The app never edits settings without an explicit
  click, and never reads credentials/Keychain.

---

## Phase 1 — Notifications 🔔

Native macOS notifications the moment a session needs you, instead of
noticing the icon change.

- **Events → notification**
  - `PermissionRequest` → "⚠️ {session} needs permission: {tool}" (actionable)
  - `Notification` (matchers `permission_prompt`, `idle_prompt`, `agent_needs_input`) → same family
  - `Stop` / turn end → "✅ {session} finished its turn" (optional, off by default)
  - `SubagentStop` → subagent finished (optional)
- **Mechanism**: hooks with `type: "http"` POSTing to the local listener;
  payloads carry `session_id`, `cwd`, `tool_name`, `tool_input`.
  App raises `UNUserNotificationCenter` notifications; clicking one opens the
  panel (later: jumps to the hosting app — Phase 3).
- **Also**: hook events update session state instantly (poll becomes the
  fallback/reconciler, can drop to every 10 s).
- **Settings UI**: toggle per notification type; Do-Not-Disturb window.
- ⚠️ Verify at implementation time: exact event names / matcher values against
  `code.claude.com/docs/en/hooks.md` (docs and community posts disagree on
  `Stop` vs `TurnEnd`).

## Phase 2 — Session identity 🏷️

Show *what* each session is about, not just its directory.

- `name` from `claude agents --json` (already parsed) as primary label.
- Enrich from `~/.claude/projects/<slug>/sessions-index.json`:
  `firstPrompt` (subtitle/tooltip), `messageCount`, `gitBranch`, `modified`.
- Match index entries by `sessionId`; treat the file as best-effort
  (undocumented format — never crash on shape changes).
- Row layout: **name** · git branch · first-prompt snippet · elapsed.

## Phase 3 — Jump to the session 🖥️

Click a session → focus the app it lives in (Terminal, iTerm2, VS Code,
Cursor, Warp, Ghostty…).

- Walk the parent-process chain from the session `pid`
  (`claude → zsh → login → Terminal.app`, verified working) and find the
  first ancestor whose executable lives in an `.app` bundle.
- Activate via `NSRunningApplication.activate()`.
- Tab/window-level focus where scriptable: iTerm2 (AppleScript, find tab by
  tty), Terminal (AppleScript), VS Code/Cursor (`open -b <bundle-id> <cwd>`).
  App-level focus is the guaranteed baseline.
- Background (headless) agents have no host window → fall back to current
  behavior: copy `claude attach <id>` (later: open a new terminal running it).
- Cache pid → host-app mapping; refresh on session list change.

## Phase 4 — Context usage per session 📊

Progress bar per session: % of context window used, warning near
auto-compact.

- **Primary source (official)**: statusline JSON. Install a *forwarder*
  statusline command that pipes the stdin JSON to the local listener and
  execs the user's previous statusline script unchanged (chain, don't
  replace). Fields: `context_window.used_percentage`,
  `context_window.context_window_size`, token breakdown.
- **Fallback (reverse-engineered)**: last assistant message in the transcript
  JSONL — `usage.input_tokens + cache_read_input_tokens +
  cache_creation_input_tokens` ÷ model context size.
- UI: thin gauge in each row; turns amber > 70 %, red > 90 %.
- Caveat: statusline only updates while a session is producing turns; show
  staleness (last-updated) per session.

## Phase 5 — Account usage (5 h window + weekly) ⏳

The `/usage` numbers, always visible.

- **Source (official, Pro/Max)**: same statusline JSON —
  `rate_limits.five_hour.used_percentage` / `resets_at`, and
  `rate_limits.seven_day.*`. Account-level, so one active session feeding the
  forwarder keeps it fresh.
- No public HTTP endpoint exists for these quotas; we deliberately do **not**
  scrape OAuth tokens from the Keychain to call private endpoints.
- UI: two gauges in the panel header ("5 h: 45 % · resets 22:35",
  "Week: 62 % · resets Mon"); optional menu-bar warning state when > 90 %.
- Persist last-known values (with timestamp) so they survive app restarts and
  idle periods; mark as stale when no session has reported recently.
- Nice-to-have later: burn-rate estimate ("at this pace you hit the 5 h limit
  at ~16:40"), computed from the used_percentage time series.

---

## Suggested order & rationale

| Phase | Value | Effort | Depends on |
|---|---|---|---|
| 1 Notifications | ★★★ (the point of a companion) | M — listener + hook installer | — |
| 2 Identity | ★★ | S — read one JSON file | — |
| 3 Jump-to-app | ★★★ | S/M — process walk + activate | — |
| 4 Context % | ★★ | M — statusline forwarder (reuses listener) | 1 (listener) |
| 5 Account usage | ★★★ | S once 4 exists | 4 (forwarder) |

Phases 2 and 3 are independent quick wins and can ship in any order.

## Non-goals (for now)

- Controlling sessions remotely (approve/deny from the panel) — hooks can do
  it, but it's a security-sensitive step; revisit deliberately.
- Historical cost analytics (ccusage territory).
- Multi-machine aggregation.
