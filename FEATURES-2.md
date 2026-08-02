# Compagnion v2 — available data, possible interactions, feature candidates

Everything below is grounded in verified sources: `.stitch/hooks-reference.md`
(hook events + statusline schema, checked against the 2.1.220 binary), the
live-captured statusline payload, and the CLI (`claude agents --json`,
`claude attach/logs/stop <id>` — all confirmed present, though hidden from
`claude --help`).

## A. Data we already receive but throw away

The statusline payload arriving at the listener carries far more than
context % and rate limits. Currently discarded:

| Field | What it gives us |
|---|---|
| `model.display_name` / id | Which model each session runs (badge per card) |
| `cost.total_cost_usd` | Real cost of the session so far |
| `cost.total_duration_ms` / `total_api_duration_ms` | Wall time vs API time |
| `cost.total_lines_added/removed` | Code-change footprint of the session |
| `exceeds_200k_tokens`, `context_window.total_output_tokens`, `current_usage.*` | Richer context diagnostics |
| `fast_mode`, `thinking.enabled`, `effort` | Session mode badges |
| `session_name` | The `/rename` name (better than agents-json fallback) |
| `pr.{number,url,review_state}` | PR chip → click opens the PR |
| `worktree.{name,branch}`, `workspace.repo.{owner,name}` | Repo/worktree identity |
| `vim.mode`, `agent.{name,type}` | Niche, but free |

Hook events not yet installed (all verified to exist):

| Event | What it enables |
|---|---|
| `PreToolUse` / `PostToolUse` | Live activity line: "running `Bash`: npm test · 12s" |
| `TaskCreated` / `TaskCompleted` | Todo progress per session: "3/7 tasks" |
| `Elicitation` / `ElicitationResult` | "Asking you: *Which auth method?*" — show the actual question in the waiting card/notification |
| `PreCompact` / `PostCompact` | "Context about to compact" warning before it happens |
| `StopFailure` | Distinguish "finished" from "died on an API error" (red card + notification) |
| `PermissionDenied` | Surface auto-mode classifier denials (with `retry` capability) |
| `WorktreeCreate/Remove`, `CwdChanged`, `FileChanged`, `ConfigChange` | Housekeeping signals (low value for now) |

Other untapped sources:

- `Stop` payload includes `last_assistant_message` → notification preview of
  what the session just said ("✓ finished: *All 34 tests pass…*").
- `PermissionRequest` payload includes full `tool_input` → show the actual
  command awaiting approval, not just "Bash".
- `SubagentStart` carries `agent_type` → named subagent chips, live tree.
- `claude agents --json --all` → completed background sessions (history).
- `claude logs <id>` → recent output of a background agent, viewable in-panel.
- Transcript JSONL → per-turn cost/token time series (analytics, burn rate).

## B. Interactions we can add

1. **Approve / deny from Compagnion** ⭐ — the biggest unlock. A
   `PermissionRequest` HTTP hook's 2xx response may return
   `hookSpecificOutput.decision.behavior: allow|deny`. Today the listener
   deliberately answers inert `{}`; a *deliberate, opt-in* "remote approval"
   mode can put Allow/Deny buttons on the notification and the waiting card.
   Guardrails required: off by default; per-tool-type opt-in (e.g. never
   auto-offer for `Bash rm`/`git push`); the hook must time out to the normal
   terminal prompt when the user doesn't react; every remote decision logged.
   Design consequence: the listener response becomes decision-capable, so the
   inert-response invariant in `IntegrationInstaller`'s header comment must be
   re-worked, not just deleted.
2. **Retry a classifier denial** — `PermissionDenied` responses may return
   `retry: true`; a "Retry" button on those events.
3. **Stop a background agent** — `claude stop <id>` from the context menu
   (confirmed to exist; keeps the conversation resumable).
4. **View background agent output** — `claude logs <id>` in a detail popover.
5. **Dispatch a new agent from the panel** — agent view dispatches sessions;
   programmatic path needs investigation (`claude -p` in a chosen cwd as
   fallback). "New agent in this project…" with a prompt field.
6. **Inject context at session start** — `SessionStart` hooks can return
   `additionalContext`; e.g. a user-configured note per project. Powerful but
   invasive; opt-in, probably later.
7. Menu-bar quick gestures — click the orange segment → jump straight to the
   first waiting session, without opening the panel.

Not possible externally today (for honesty): typing a prompt into a *running
interactive* session, answering an Elicitation question remotely, renaming a
session from outside.

## C. Feature candidates, prioritized

| # | Feature | Value | Effort | Builds on |
|---|---|---|---|---|
| 1 | Remote Allow/Deny (opt-in, guarded) | ★★★ | M/L | B1 |
| 2 | Live activity line ("running npm test · 12s") | ★★★ | M | PreToolUse/PostToolUse |
| 3 | Richer notifications: last-message preview, the Elicitation question, StopFailure errors | ★★★ | S/M | A |
| 4 | Session card v2: model badge, cost, task progress 3/7, PR chip, pending-command preview | ★★ | M | A (data already arrives) |
| 5 | Burn-rate ETA on quota gauges ("hits 100% ~16:40") + usage sparkline | ★★ | S/M | stored time series |
| 6 | Compaction warning (PreCompact) | ★★ | S | A |
| 7 | Background-agent control: stop / logs / (dispatch?) | ★★ | M | B3–B5 |
| 8 | Session detail popover: transcript tail, subagent tree, token breakdown | ★★ | M | transcripts |
| 9 | Daily/weekly cost & time rollup (ccusage-lite history view) | ★ | M/L | transcripts, `--all` |
| 10 | DND windows, per-project notification rules | ★ | S | Notifier |

Suggested next slice: **3 + 4 + 6** (pure consumption of data we already
receive — no new permissions surface), then **2**, then design review for
**1** (remote approval), which deserves its own security discussion before
any code.
