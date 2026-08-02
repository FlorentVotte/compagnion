# Compagnion — Implementation Plan

Self-contained plan to implement the features in `FEATURES.md` and the visual
design in `.stitch/designs/menu-bar-panel.html` (+ `.png` screenshot).
Written for an implementing agent with no prior context. Work through phases
in order; each phase ends with a verification step. Do not start a phase
before the previous one builds and runs.

## Current state (v0.1 — already built and working)

Swift Package Manager project, macOS 14+, SwiftUI `MenuBarExtra` app:

- `Package.swift` — single executable target `Compagnion`.
- `Sources/Compagnion/CompagnionApp.swift` — `@main` App, `MenuBarExtra`
  (`.window` style), `MenuBarLabel` (icon reflects aggregate state),
  `AppDelegate` sets `.accessory` activation policy (no Dock icon).
- `Sources/Compagnion/SessionMonitor.swift` — `ClaudeSession` model +
  `SessionMonitor` (`@MainActor ObservableObject`) polling
  `claude agents --json` every 3 s via `Process`. Claude binary resolved from
  `~/.local/bin/claude` (this machine), `~/.claude/local`, `/opt/homebrew/bin`,
  `/usr/local/bin`. PATH is augmented for Finder-launched apps.
- `Sources/Compagnion/ContentView.swift` — panel UI: header with
  waiting/busy counts, session rows (status dot, name, status, folder,
  elapsed, hover copy-resume-command button), footer (refresh/quit).
- `make-app.sh` — release build → `Compagnion.app` (LSUIElement, ad-hoc
  signed). `README.md`, `FEATURES.md`.

Build: `swift build`. Package app: `./make-app.sh && open Compagnion.app`.
Dev loop: `swift run` (quit first any running instance: `pkill -x Compagnion`).

### Verified data sources (tested on this machine)

**`claude agents --json`** — authoritative session list. Interactive session
sample:

```json
[{ "pid": 56235, "cwd": "/Users/florent/dev/compagnion", "kind": "interactive",
   "startedAt": 1785652359726, "sessionId": "55310ca8-...", "name": "compagnion-08",
   "status": "busy" }]
```

Background agents additionally expose `id` (short id), `state`
(`working|blocked|done|failed|stopped`) and `waitingFor` (e.g. `"permission
prompt"`). Treat every field as optional (already done in `ClaudeSession`).

**`~/.claude/projects/<slug>/sessions-index.json`** — per-project session
metadata (`slug` = cwd with non-alphanumerics → `-`). Format (version 1,
undocumented, parse defensively):

```json
{ "version": 1, "entries": [ { "sessionId": "941e3865-...", "fullPath": "...jsonl",
  "fileMtime": 1766679695783, "firstPrompt": "I have no more space...",
  "messageCount": 9, "created": "2025-12-25T16:17:00.516Z",
  "modified": "...", "gitBranch": "", "projectPath": "/Users/florent",
  "isSidechain": false } ] }
```
Note: the file does not exist for every project.

**Transcript JSONL** — `~/.claude/projects/<slug>/<sessionId>.jsonl`;
assistant lines contain `message.usage = { input_tokens,
cache_creation_input_tokens, cache_read_input_tokens, output_tokens }`.
Context fill ≈ (input + cache_creation + cache_read) / context_window_size.

**Statusline stdin JSON** (official; Claude Code invokes the configured
statusline command each turn, piping JSON to stdin). Relevant fields:
`context_window.used_percentage`, `context_window.context_window_size`,
`context_window.total_input_tokens`, and — Pro/Max accounts —
`rate_limits.five_hour.used_percentage`, `rate_limits.five_hour.resets_at`,
`rate_limits.seven_day.used_percentage`, `rate_limits.seven_day.resets_at`.
Docs: https://code.claude.com/docs/en/statusline

**Hooks** (official) — configured in `~/.claude/settings.json`, support
`"type": "http"` entries that POST the event JSON to a URL. Common payload
fields: `session_id`, `transcript_path`, `cwd`, `hook_event_name`, plus
event-specific fields (`tool_name`, `tool_input` for permission events).
Docs: https://code.claude.com/docs/en/hooks
⚠️ Before implementing Phase 2, fetch that page and verify the exact event
names available in the installed version (`claude --version`); sources
disagree on `Stop` vs `TurnEnd`, and on `Notification` matcher values
(`permission_prompt`, `idle_prompt`, `agent_needs_input`). Use what the live
docs say; the plan below uses the names as placeholders.

**Process tree → hosting app** (verified): walk `ps -o ppid=,comm= -p <pid>`
from the session pid upward; an ancestor's `comm` contains the `.app` bundle
path, e.g. `/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal`.

### Hard constraints

- Never read Keychain items or `~/.claude/.credentials.json`; never call
  private/undocumented Anthropic endpoints. Account usage comes only from
  statusline-forwarded data.
- Never modify `~/.claude/settings.json` without an explicit user action in
  the app (a "Set up integration" button). Edits must be idempotent,
  additive, clearly identifiable (see Phase 2), and reversible.
- All parsing of undocumented files (sessions-index.json, transcript JSONL)
  must be failure-tolerant: on any decode error, degrade gracefully, never
  crash, never block the session list.
- Local listener binds 127.0.0.1 only.

---

## Phase 0 — Design system + UI restyle

Recreate the Stitch design (`.stitch/designs/menu-bar-panel.html`, screenshot
`.png` alongside) in SwiftUI. Look at both files before starting.

### Tokens → `Sources/Compagnion/Theme.swift`

Colors (light theme; from the HTML tailwind config):

| Token | Hex | Use |
|---|---|---|
| `surface` / `background` | `#FCF9F8` | panel background (with translucency, see below) |
| `onSurface` | `#1C1B1B` | primary text |
| `onSurfaceVariant` | `#414755` | secondary text |
| `outline` | `#717786` | idle badge text, tertiary text |
| `outlineVariant` | `#C1C6D7` | separators (30–50% opacity) |
| `surfaceContainer` | `#F0EDED` | gauge/progress tracks |
| `secondaryContainer` | `#DFDFE4` | hover backgrounds (50% opacity) |
| `primary` | `#0058BC` | working state, accents, links |
| `error` | `#BA1A1A` | critical context (>90%), quit hover |
| `errorContainer` | `#FFDAD6` | critical backgrounds |
| waiting accent | orange family | use system `.orange`: card bg `orange.opacity(0.08)`, border `orange.opacity(0.25)`, badge text `#EA580C`-ish, bar `orange` |

Geometry & type:

- Panel: width 400 pt, max content height ~600 pt, corner radius 12 (the
  MenuBarExtra window already provides rounded chrome — don't double-round).
- Background: translucent "glass" — embed an `NSVisualEffectView`
  (`.popover` or `.hudWindow` material, `blendingMode: .behindWindow`) via
  `NSViewRepresentable`, tinted with `surface` at ~75% opacity.
- Cards: corner radius 12 (`rounded-xl`), padding 12; hover =
  `secondaryContainer.opacity(0.5)`; pressed = scale 0.98.
- Fonts: map Inter → system font (SF Pro), JetBrains Mono → 
  `.monospaced` system font. Sizes: headline 15 semibold (session names,
  app title), body 13, label 12 medium, mono/meta 11 monospaced, badges 10
  bold uppercase, gauge captions 9.
- Icons: Material Symbols → SF Symbols: `notifications`→`bell.fill`,
  `hub`→`point.3.connected.trianglepath.dotted`, `terminal`→`terminal`,
  `play_circle`→`play.circle.fill`, `refresh`→`arrow.clockwise`,
  `settings`→`gearshape`, `power_settings_new`→`power`.

### Layout (match the HTML structure)

1. **Header** (pinned): left — title "Compagnion" (15 semibold) with, under
   it, a tiny `bell` + "Alerts ON/OFF" caption (10pt, primary-colored icon).
   Right — two circular ring gauges Ø32 pt, stroke 2 (track `#E5E5EA`, fill
   `primary`), centered percentage (8–9 pt mono), caption below
   ("5h Rem." / "Week", 9 pt). Until Phase 5 lands, show them in a
   placeholder "–" state.
2. **Session list** (scrollable, thin scrollbar): cards per session:
   - Row 1: name (15 semibold; 60% opacity when idle) + status badge on the
     right (10 pt bold uppercase: WAITING FOR YOU = orange text on orange-100
     chip; WORKING = primary text, no chip; IDLE = outline color), elapsed
     under the badge (11 mono, `onSurfaceVariant`).
   - For working sessions: small pulsing `play.circle.fill` next to the name
     (2 s opacity/scale pulse).
   - Row 2 (under name): `folder / git-branch` in 11 pt mono,
     `onSurfaceVariant`, separator slash in `outlineVariant`.
   - Row 3: context bar — 96×6 pt rounded capsule, track `surfaceContainer`,
     fill `primary` (<70%) / orange (70–90%) / `error` (>90%) — plus
     "NN% Context" 11 mono; right-aligned: sub-agent pill when applicable
     (`hub` icon + "N sub-agent", primary text, `primary.opacity(0.1)`
     capsule). Until Phase 4, hide the bar (or show it dimmed at 0) rather
     than invent numbers.
   - Waiting cards: whole card tinted orange (bg orange 8%, 1 pt orange 25%
     border); others transparent with hover tint.
   - Hover: `terminal` SF Symbol appears bottom-right (jump affordance,
     wired in Phase 3; until then keep the existing copy-command action).
   - Hairline inset divider (0.5 pt, `#E5E5EA`, 12 pt side margins) after the
     waiting group.
3. **Footer** (pinned, top hairline border): left "Last refresh: Just now /
   Nm ago"; right three 28 pt icon buttons (refresh, settings, power) —
   hover: `secondaryContainer` rounded-lg bg, power turns `error`.
   Settings opens the Phase 2 settings window (placeholder popover until then).

Keep `MenuBarLabel` behavior (menu-bar icon states) unchanged.

Structure: add `Theme.swift` (colors, fonts, metrics), `Components/`
(RingGauge, ContextBar, StatusBadge, VisualEffectBackground) — small files,
one view each. Sorting already exists in `SessionMonitor` (waiting → busy →
idle) and matches the design.

**Verify:** `swift build && swift run` with real sessions running; compare
against `.stitch/designs/menu-bar-panel.png`. Check hover states, empty
state, 1-session and 6-session cases (scrolling), light *and* dark menu bar
(panel stays light by design — ensure text remains readable on the glass
material; if not, pin `colorScheme(.light)` on the panel).

---

## Phase 1 — Local event listener (foundation for notifications & usage)

New file `Sources/Compagnion/EventListener.swift`:

- `NWListener` (Network.framework) on `127.0.0.1`, fixed default port
  `48765` (configurable later). HTTP/1.1, only `POST /event`, tiny
  hand-rolled request parser is acceptable (headers + Content-Length body) —
  no third-party deps.
- Body = hook or statusline JSON. Decode into an
  `enum CompagnionEvent { case hook(HookEvent), statusline(StatuslineUpdate) }`
  by sniffing discriminating fields (`hook_event_name` present → hook;
  `context_window` present → statusline).
- Publish events on the main actor to `SessionMonitor` (inject a callback or
  make the listener an `ObservableObject` the monitor subscribes to).
- Respond `200` with empty JSON `{}` fast; never block.
- On hook event: mark the matching `session_id` state immediately
  (e.g. PermissionRequest → needsAttention) and trigger a `refresh()` to
  reconcile with `claude agents --json`. With the listener active, drop the
  poll interval to 10 s (poll remains the source of truth; events are the
  low-latency edge).

**Verify:** run app, then
`curl -s -X POST localhost:48765/event -d '{"hook_event_name":"PermissionRequest","session_id":"test","cwd":"/tmp","tool_name":"Bash"}'`
→ 200 and visible state change / log line.

## Phase 2 — Integration installer + notifications 🔔

**Installer** — `Sources/Compagnion/IntegrationInstaller.swift` + a Settings
window (`Settings` scene or dedicated `Window`; opened from footer gear):

- Reads `~/.claude/settings.json` (create `{}` if absent). All Compagnion
  entries are tagged: HTTP hook URLs point at
  `http://127.0.0.1:48765/event` — that URL itself is the marker; install =
  add missing entries, uninstall = remove exactly those, never touching
  anything else. Always keep a timestamped backup
  (`settings.json.compagnion-backup-<ISO date>`) before writing.
- Hooks to install (verify names against live docs first — see caveat above):
  `PermissionRequest` (matcher `*`), `Notification` (matchers for
  permission/idle/needs-input), `Stop`/`TurnEnd`, `SubagentStart`,
  `SubagentStop`, `SessionStart`, `SessionEnd` — each as
  `{ "type": "http", "url": "http://127.0.0.1:48765/event", "timeout": 5 }`.
- Settings UI: status ("Integration installed ✓ / not installed"),
  Install / Remove buttons, per-notification-type toggles
  (waiting-for-you ON by default; turn-finished OFF; subagent-finished OFF),
  launch-at-login toggle (`SMAppService.mainApp`).

**Notifications** — `Sources/Compagnion/Notifier.swift`:

- `UNUserNotificationCenter`, request authorization on first enable.
- PermissionRequest/needs-input → "⟡ {session name} needs you" body:
  tool + folder. Stop → "✓ {session name} finished". Subagent → optional.
- De-duplicate: one notification per session per waiting-episode (clear when
  the session leaves waiting state).
- Notification click → activate app and open the panel is NOT reliably
  possible with MenuBarExtra; acceptable v1: clicking focuses nothing but
  the menu-bar icon already shows the orange badge. (Phase 3 improves this:
  the notification can jump straight to the hosting app via its action.)

**Verify:** install integration; in a test Claude session trigger a
permission prompt (e.g. ask it to run a non-allowlisted command) → macOS
notification within ~1 s and instant orange state in the panel. Uninstall →
settings.json returns to its previous state (diff against backup).

## Phase 3 — Session identity 🏷️

In `SessionMonitor` (or a new `SessionEnricher`):

- Map session `cwd` → project slug (replace every non-alphanumeric char with
  `-`), read `~/.claude/projects/<slug>/sessions-index.json` if present,
  match entry by `sessionId`.
- Expose `firstPrompt` (trim to ~80 chars), `gitBranch`, `messageCount`.
- UI: git branch goes in the mono `folder / branch` line (fallback: hide
  slash+branch when empty); `firstPrompt` becomes tooltip and/or a second
  subtitle line; keep the `name` from `claude agents --json` as the title.
- Cache reads keyed by file mtime; re-read at most once per poll cycle.

**Verify:** sessions with a named branch show `folder / branch`; hovering
shows the first prompt; a project without sessions-index.json degrades to
v0.1 display.

## Phase 4 — Jump to the hosting app 🖥️

New `Sources/Compagnion/HostAppResolver.swift`:

- For each session pid, walk parents via `sysctl`/`proc_pidinfo` (or spawn
  `ps -o ppid=,comm= -p <pid>` — simpler and fine at this scale) until a
  command path contains `.app/`; extract the bundle path and get its
  `NSRunningApplication` (match by pid of that ancestor).
- Cache pid → (bundle id, host pid); invalidate when the session disappears.
- Row click → `NSRunningApplication.activate()`. Tab-level focus
  (best-effort, feature-flagged): iTerm2/Terminal via AppleScript
  (`NSAppleScript`, find tab whose tty matches the session's tty from
  `ps -o tty= -p <pid>`); VS Code/Cursor via `open -b <bundleid> <cwd>`.
  App activation alone is the acceptance bar; tab focus is bonus.
- Background sessions (no host window): keep the copy `claude attach <id>`
  action; move it into a right-click context menu (also add "Copy resume
  command" and "Reveal folder in Finder" for all sessions).
- Notification actions (Phase 2) gain "Open" → same activation path.

**Verify:** click a Terminal-hosted session → Terminal comes to front; a
VS Code-terminal session → VS Code front; background agent → context menu
copy still works.

## Phase 5 — Context usage per session 📊

**Statusline forwarder (primary source):**

- Ship a script at `~/Library/Application Support/Compagnion/statusline-forward.sh`
  (installed by the Phase 2 installer):

  ```sh
  #!/bin/sh
  # Forward Claude Code statusline JSON to Compagnion, then chain to the
  # user's original statusline (kept verbatim in ORIGINAL_CMD at install).
  INPUT=$(cat)
  printf '%s' "$INPUT" | curl -s -m 1 -X POST http://127.0.0.1:48765/event \
      -H 'Content-Type: application/json' -d @- >/dev/null 2>&1 &
  ORIGINAL_CMD='__ORIGINAL__'   # empty if none
  if [ -n "$ORIGINAL_CMD" ]; then printf '%s' "$INPUT" | eval "$ORIGINAL_CMD"; fi
  ```

- Installer sets `statusLine` in `~/.claude/settings.json` to this script,
  preserving any existing command inside it (and restoring it on uninstall).
- Listener: `StatuslineUpdate` carries `session_id` +
  `context_window.used_percentage` (+ token counts). Store per session with
  a timestamp.

**Transcript fallback:** when no statusline data for a session (or stale
> 2 min): read the *last* ~50 lines of its transcript JSONL (seek from EOF,
don't parse the whole file), find the latest `message.usage`, compute
(input + cache_creation + cache_read) / context_window_size (default
200 000 if unknown). Refresh lazily per poll only for visible sessions.

**UI:** wire the Phase 0 context bar + "NN% Context" label; amber ≥ 70%,
red ≥ 90%; show a small staleness dot/tooltip when the value is older than
2 min. Sub-agent pill: count from `SubagentStart`/`SubagentStop` events
(Phase 2 listener) — show only when > 0.

**Verify:** with an active session, the bar moves after each turn; kill the
listener → fallback numbers still appear; values plausible vs `/context` in
the session.

## Phase 6 — Account usage (5 h + weekly) ⏳

- Source: `rate_limits` from the forwarded statusline JSON (Phase 5). Fields:
  `five_hour.used_percentage`, `five_hour.resets_at` (ISO date),
  `seven_day.*`. Account-level → any active session updates it.
- Store last-known values + timestamp in `UserDefaults`; restore on launch;
  mark stale (dimmed gauge + tooltip "last seen 2 h ago") when > 30 min old.
- UI: wire the two header ring gauges: percentage inside, caption below;
  tooltip with reset time ("resets 22:35" / "resets Monday"). Gauge stroke
  turns orange ≥ 75%, red ≥ 90%. When ≥ 90%, menu-bar icon may add a warning
  state (only if no session is waiting — waiting keeps priority).
- If `rate_limits` never appears (API-key users): show "–" gauges with
  tooltip "Available with Pro/Max subscription".
- Nice-to-have (only if trivial): linear burn-rate ETA in the tooltip from
  the stored time series (keep last ~24 h of points).

**Verify:** run a few turns → gauges match `/usage` inside Claude Code;
restart app → values persist and show staleness correctly.

---

## Cross-cutting

- **Dependencies:** none. Foundation + SwiftUI + Network + UserNotifications
  + ServiceManagement only.
- **Concurrency:** keep the v0.1 pattern — UI state on `@MainActor`,
  Process/file work in `Task.detached`; guard against overlapping refreshes.
- **Code style:** match existing files (4-space indent, doc comments only
  for non-obvious constraints, small focused files).
- **After each phase:** `swift build` must pass; run `./make-app.sh` and do a
  manual smoke test from `Compagnion.app` (Finder-launch PATH differs from
  terminal — this bites Process-spawning code).
- **Suggested commit granularity:** one commit per phase (repo is not yet a
  git repo — `git init` first, commit v0.1 as baseline).

## Milestone acceptance

Done when: panel matches the Stitch design; a permission prompt in any
session produces a macOS notification and an orange card within ~1 s;
clicking a session focuses its hosting app; every active session shows a
live context gauge; the header shows 5 h/weekly usage matching `/usage`; and
removing the integration from Settings restores `~/.claude/settings.json`.
