# Claude Code hooks & statusline — ground-truth reference for Compagnion

Installed version verified against: **2.1.220** (`~/.local/bin/claude` → `~/.local/share/claude/versions/2.1.220`, a Bun-compiled single-file executable).

Method: (a) fetched https://code.claude.com/docs/en/hooks and https://code.claude.com/docs/en/statusline live; (b) `strings -a` on the installed 2.1.220 binary to grep for hook event name literals, config-key literals, and an embedded verbatim JSON-schema doc comment (the system prompt of the built-in `statusline-setup` subagent contains the exact stdin schema, byte-for-byte, used to teach that agent how to write `jq` expressions); (c) a **live captured sample**: temporarily pointed `statusLine.command` at `cat > /tmp/.../statusline_capture.json`, drove a real interactive session via a PTY, captured one real stdin payload, then restored the original `~/.claude/settings.json` from a backup (verified byte-identical afterward). Local evidence is called out as **verified-locally** below; it is reported wherever it conflicts with or extends the docs.

Confidence legend: **verified-locally** (found literally in the 2.1.220 binary or in the live-captured sample) / **documented** (live docs page only, not independently confirmed in the binary) / **uncertain**.

---

## 1. Hook event names (2.1.220)

**verified-locally** — every one of these string literals is present in the 2.1.220 binary (grepped directly):

```
SessionStart, Setup, SessionEnd, UserPromptSubmit, UserPromptExpansion,
Stop, StopFailure, PreToolUse, PermissionRequest, PermissionDenied,
PostToolUse, PostToolUseFailure, PostToolBatch, SubagentStart, SubagentStop,
TaskCreated, TaskCompleted, TeammateIdle, InstructionsLoaded, ConfigChange,
CwdChanged, FileChanged, PreCompact, PostCompact, WorktreeCreate, WorktreeRemove,
Elicitation, ElicitationResult, Notification, MessageDisplay
```

**`TurnEnd` was searched for and does NOT exist** — not in the binary, not in the docs. Use `Stop` (verified-locally, exists) for "assistant finished responding." There's also `StopFailure` (turn ended due to an API error) which is easy to miss if you only listen for `Stop`.

**`PermissionRequest` DOES exist as its own event name** (verified-locally) — it is not merely surfaced via `Notification`. It fires when a tool call needs a permission decision, before the decision is made, and it is itself blocking/decidable (see below). `Notification` (matcher `permission_prompt`) additionally fires as a *side-effect-only* announcement — the two are related but distinct: `PermissionRequest` is the decision point, `Notification`/`permission_prompt` is closer to "please look at the terminal, something needs your attention" (also fired for other prompts).

**`SubagentStart` DOES exist** (verified-locally), in addition to `SubagentStop`. Fires when a subagent is spawned; matches on agent type (regex; supports plugin-scoped names like `^my-plugin:reviewer$`).

### Event reference table

| Event | Fires | Matcher | Can block/decide? |
|---|---|---|---|
| `SessionStart` | Session begins/resumes | `startup\|resume\|clear\|compact\|fork` | No — context injection only |
| `Setup` | Started with `--init-only`/`--init`/`--maintenance` | — | — |
| `UserPromptSubmit` | User submits prompt, before processing | none (always) | Yes — `decision:"block"` |
| `UserPromptExpansion` | User command expands into a prompt | — | — |
| `PreToolUse` | Before tool executes | tool name (`Bash`, `Edit\|Write`, `mcp__.*`) | Yes — `hookSpecificOutput.permissionDecision: allow\|deny\|ask\|defer` |
| `PermissionRequest` | Tool call needs a permission decision | tool name | Yes — `hookSpecificOutput.decision.behavior: allow\|deny` |
| `PermissionDenied` | Tool denied by the auto-mode classifier | tool name | Can request `retry: true` |
| `PostToolUse` | After tool succeeds | tool name | Yes — `decision:"block"`, or `updatedToolOutput` |
| `PostToolUseFailure` | After tool fails | tool name | `decision:"block"` |
| `PostToolBatch` | After a batch of parallel tool calls resolves, before next model call | none | `decision:"block"` stops the loop |
| `Stop` | Claude finishes responding | none | `decision:"block"` continues the conversation |
| `StopFailure` | Turn ends due to an API error | none | — |
| `SubagentStart` | Subagent spawned | agent type | Context only |
| `SubagentStop` | Subagent finishes | agent type | `decision:"block"` prevents stopping |
| `SessionEnd` | Session terminates | `clear\|resume\|logout\|prompt_input_exit\|bypass_permissions_disabled\|other` | No (cleanup/logging only) |
| `Notification` | Claude Code emits a UI notification | see §2 | No (side effects only) |
| `PreCompact` | Before context compaction | `manual\|auto` | Exit code 2 blocks compaction |
| `PostCompact` | After compaction | — | — |
| `FileChanged` | Watched file changes on disk | literal filenames, `\|`-separated (no regex), e.g. `.envrc\|.env` | — |
| `WorktreeCreate` / `WorktreeRemove` | Worktree created/removed | — | Command hook prints path on stdout; HTTP returns `hookSpecificOutput.worktreePath` |
| `TaskCreated` / `TaskCompleted` | `TaskCreate` tool lifecycle | — | — |
| `TeammateIdle` | Agent-team teammate about to go idle | — | — |
| `InstructionsLoaded` | CLAUDE.md / `.claude/rules/*.md` loaded | — | — |
| `ConfigChange` / `CwdChanged` | Config file or cwd changes mid-session | — | — |
| `Elicitation` / `ElicitationResult` | MCP server requests/receives user input | — | — |
| `MessageDisplay` | While assistant message text is displayed | — | Display-only |

Source: **documented** (https://code.claude.com/docs/en/hooks) for firing semantics and payload shapes; event-name existence and the config-key literals in §3/§5 are **verified-locally**.

### Common fields on every hook payload (documented)
```json
{
  "session_id": "string",
  "prompt_id": "string (absent until first user input)",
  "transcript_path": "string",
  "cwd": "string",
  "permission_mode": "default|plan|acceptEdits|auto|dontAsk|bypassPermissions",
  "effort": { "level": "low|medium|high|xhigh|max" },
  "hook_event_name": "string"
}
```
`permission_mode` values confirmed **verified-locally** in the binary: `default`, `plan`, `acceptEdits`, `auto`, `dontAsk`, `bypassPermissions`.

Subagent-context payloads additionally carry `agent_id`, `agent_type`.

Per-event extra fields (**documented**, not independently re-verified field-by-field beyond the event-name check above):
- `PreToolUse` / `PermissionRequest` / `PermissionDenied` / `PostToolUse`(+Failure): `tool_name`, `tool_input`, `tool_use_id`; `PostToolUse` adds `tool_result`, `PostToolUseFailure` adds `tool_error`.
- `PostToolBatch`: `tool_calls: [{tool_name, tool_input, tool_use_id, tool_result, tool_error?}]`.
- `Stop` / `SubagentStop`: `last_assistant_message`.
- `UserPromptSubmit`: `prompt`.
- `SessionStart`: `source`, optional `model`.
- `SessionEnd`: `source`.
- `FileChanged`: `file_path`.

---

## 2. `Notification` event — matcher applicability and payload

**The matcher field IS applicable to `Notification`** (documented + verified-locally: all the value literals below exist in the binary) — matching is not restricted to tool-based events. For `Notification`, the matcher matches against `notification_type`.

Valid `notification_type` / matcher values (**verified-locally**, all found as literal strings in the binary):
```
permission_prompt, idle_prompt, auth_success,
elicitation_dialog, elicitation_complete, elicitation_response,
agent_needs_input, agent_completed
```

Payload (**documented**):
```json
{
  "session_id": "string",
  "cwd": "string",
  "hook_event_name": "Notification",
  "notification_type": "string",
  "message": "string"
}
```
(The field name `notification_type` is itself **verified-locally**.)

**How to distinguish "waiting on a permission decision" from "idle reminder" from a `Notification` hook alone:** filter on `notification_type == "permission_prompt"` vs `"idle_prompt"`. But note `Notification` carries no decision-making power (no blocking/allow) — if Compagnion needs to actually *see the tool being asked about* or *respond to the request*, hook on `PermissionRequest` instead (or in addition), which has `tool_name`/`tool_input`/`tool_use_id` and is the actual decision point. `agent_needs_input` / `agent_completed` are for background/teammate agents, not the interactive permission flow.

Recommendation for Compagnion's menu-bar "waiting" indicator: register **both** `Notification` (matcher `permission_prompt|idle_prompt`) for the human-readable message, and `PermissionRequest` (no matcher, or `*`) if you want the specific `tool_name`/`tool_input` that's pending.

---

## 3. HTTP hooks — exact shape, response handling, blocking behavior

**verified-locally**: the binary contains a `HttpHookSchema` with fields `url`, `timeout`, `headers`, `allowedEnvVars`, and the literal doc-strings:
- `"URL to POST the hook input JSON to"`
- `"Timeout in seconds for this specific request"` — **timeout unit is SECONDS**, not milliseconds (same unit applies to `command`/`prompt`/`mcp_tool`/`agent` hook types too — each has its own "Timeout in seconds..." string).
- `"Additional headers to include in the request. Values may reference environment variables using $VAR_NAME or ${VAR_NAME} syntax... Only variables listed in allowedEnvVars will be interpolated."`
- `"Explicit list of environment variable names that may be interpolated in header values."`

So the exact shape is:
```json
{
  "type": "http",
  "url": "http://127.0.0.1:48765/event",
  "timeout": 5,
  "headers": {
    "Authorization": "Bearer $COMPAGNION_TOKEN"
  },
  "allowedEnvVars": ["COMPAGNION_TOKEN"]
}
```
`headers`/`allowedEnvVars` are optional — omit entirely for a no-auth local listener.

Also confirmed **verified-locally**: hook `type` values that exist are `command`, `http`, `mcp_tool`, `prompt`, `agent` — and error-message strings reference `"sse"` / `"ws"` as additional recognized `type` values in at least one code path (MCP-server-style entries), but these did not appear as a listed *hook* type doc-string alongside the five above — treat `sse`/`ws` as **uncertain** for hook entries specifically (they clearly exist somewhere in the config-type union, most likely for MCP server definitions, not hook definitions).

Every hook-type schema (**verified-locally** doc-strings): `command` also supports `args` (exec-form argv, `${CLAUDE_PLUGIN_ROOT}` substituted per-element, bypasses shell parsing), `shell` (`bash`/`powershell`), `statusMessage`, `once` (bool — removed after one run), `async` (bool — runs without blocking), `asyncRewake` (bool — runs in background, wakes the model on exit code 2).

**Response handling** (documented, consistent with the HTTP-hook-type strings found locally):
- **2xx + empty body** → success, no output.
- **2xx + plain text** → treated as success, text is added as context.
- **2xx + JSON body** → parsed with the *same* JSON output schema as `command` hooks (`decision`, `hookSpecificOutput`, etc.) — **so yes, an HTTP hook response CAN block or allow a tool call**: return 2xx with `{"decision":"block", "reason":"..."}` or, for `PreToolUse`/`PermissionRequest`, `{"hookSpecificOutput":{"permissionDecision":"deny", ...}}`.
- **Non-2xx status or timeout** → treated as a non-blocking error; execution continues (fails open).

**Does a slow/failed HTTP hook stall the session?** For a *blocking* event (`PreToolUse`, `PermissionRequest`, `UserPromptSubmit`, `Stop`, etc.) the session does wait up to `timeout` seconds for the HTTP response before proceeding — so a slow listener can add real latency to every tool call up to the configured timeout, and a hung listener stalls the session until timeout, then fails open (execution continues, non-blocking error). For Compagnion's read-only "watch/forward" use case, keep `timeout` low (e.g. 3–5s) and design the listener to always return fast — a local unresponsive listener should not be allowed to add multi-second latency to every tool call in the user's real sessions. Consider `async: true` (documented as available on `command` hooks; whether it's honored for `type: "http"` specifically is **uncertain** — not directly confirmed) if you don't need to affect the decision at all, only observe.

### Recommended settings.json fragment for Compagnion

```json
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:48765/event", "timeout": 5 }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:48765/event", "timeout": 5 }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:48765/event", "timeout": 5 }] }],
    "PreToolUse":       [{ "matcher": "*", "hooks": [{ "type": "http", "url": "http://127.0.0.1:48765/event", "timeout": 5 }] }],
    "PermissionRequest":[{ "matcher": "*", "hooks": [{ "type": "http", "url": "http://127.0.0.1:48765/event", "timeout": 5 }] }],
    "PostToolUse":      [{ "matcher": "*", "hooks": [{ "type": "http", "url": "http://127.0.0.1:48765/event", "timeout": 5 }] }],
    "Notification":     [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:48765/event", "timeout": 5 }] }],
    "Stop":             [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:48765/event", "timeout": 5 }] }],
    "SubagentStart":    [{ "matcher": "*", "hooks": [{ "type": "http", "url": "http://127.0.0.1:48765/event", "timeout": 5 }] }],
    "SubagentStop":     [{ "matcher": "*", "hooks": [{ "type": "http", "url": "http://127.0.0.1:48765/event", "timeout": 5 }] }]
  }
}
```
Note: for events with a `matcher` field (`PreToolUse`, `PermissionRequest`, `PostToolUse`, `SubagentStart`, `SubagentStop`, `Notification`), leaving `matcher` out entirely (or `"*"` — confirm against your installed version's exact wildcard convention before shipping, docs consistently show plain omission or `"*"` both working) matches everything, since Compagnion wants every event, not a subset. Since **hooks merge across settings files, not replace** (documented), only ADD this block — don't clobber an existing `hooks` key the user may already have.

---

## 4. Statusline

### Settings key shape (documented + verified-locally in the embedded `statusline-setup` agent prompt)
```json
{
  "statusLine": {
    "type": "command",
    "command": "your_command_here"
  }
}
```
No `padding` key was found anywhere in the fetched docs page content nor in the embedded schema string in the binary — **uncertain / likely does not exist in 2.1.220** as documented in your PLAN.md; do not rely on it. (The docs page does separately mention a `footerLinksRegexes` setting for footer link badges, which is unrelated.)

### Exact stdin schema — CONFIRMED via a real live-captured sample

I temporarily set `statusLine.command` to `cat > /tmp/.../statusline_capture.json`, drove one real interactive turn via a PTY-attached `claude` process in `/Users/florent/dev/compagnion`, captured the payload, then restored `~/.claude/settings.json` from a pre-change backup (diffed identical afterward — no residual changes).

**Actual captured payload (verified-locally, real sample, 2.1.220):**
```json
{
  "session_id": "b2035ab0-ada7-457d-a09e-e4fab9a6a3b5",
  "transcript_path": "/Users/florent/.claude/projects/-Users-florent-dev-compagnion/b2035ab0-ada7-457d-a09e-e4fab9a6a3b5.jsonl",
  "cwd": "/Users/florent/dev/compagnion",
  "effort": { "level": "high" },
  "model": { "id": "claude-opus-5[1m]", "display_name": "Opus 5 (1M context)" },
  "workspace": {
    "current_dir": "/Users/florent/dev/compagnion",
    "project_dir": "/Users/florent/dev/compagnion",
    "added_dirs": []
  },
  "version": "2.1.220",
  "output_style": { "name": "default" },
  "cost": {
    "total_cost_usd": 0,
    "total_duration_ms": 1077,
    "total_api_duration_ms": 0,
    "total_lines_added": 0,
    "total_lines_removed": 0
  },
  "context_window": {
    "total_input_tokens": 0,
    "total_output_tokens": 0,
    "context_window_size": 1000000,
    "current_usage": null,
    "used_percentage": null,
    "remaining_percentage": null
  },
  "exceeds_200k_tokens": false,
  "fast_mode": false,
  "thinking": { "enabled": true }
}
```

**Key findings for your specific questions:**
- **`session_id` is TOP-LEVEL**, a sibling of `cwd`/`model`/`workspace` — NOT nested under a `session` object. Confirmed both by the live sample and by the embedded schema doc-string.
- **`context_window`** is present with exactly the key names you asked about: `used_percentage`, `context_window_size`, `total_input_tokens` — all confirmed, both in the live sample and in the embedded schema comment (which also documents `total_output_tokens`, `current_usage {input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens}`, and `remaining_percentage`). `used_percentage`/`remaining_percentage` are `null` until the first API response of the session (as seen live — this sample was captured on session start before any assistant turn completed).
- **`rate_limits`** did **not** appear in this particular live sample — consistent with the embedded doc-string's own caveat: `"Optional: Claude.ai subscription usage limits. Only present for subscribers after first API response."` This session hadn't completed an API turn yet. The schema (from the embedded doc, **verified-locally as a string literal, not independently reproduced in a live sample with data present**) is:
  ```json
  "rate_limits": {
    "five_hour": { "used_percentage": 0, "resets_at": 0 },
    "seven_day": { "used_percentage": 0, "resets_at": 0 }
  }
  ```
  Field names `rate_limits`, `five_hour`, `seven_day`, `used_percentage`, `resets_at` are all **verified-locally** as literal strings in the binary (exact key names, exact nesting `rate_limits.five_hour.used_percentage` / `rate_limits.five_hour.resets_at` / `rate_limits.seven_day.*`, matching your question exactly). `resets_at` is Unix epoch **seconds**. Both `five_hour` and `seven_day` are independently optional ("may be absent"). Get a full sample with rate limits populated by letting a real session complete at least one API turn under a Claude.ai subscription plan (not applicable to API-key-only usage — the doc-string specifically scopes this to "Claude.ai subscription usage limits").
- Fields present in the live sample but **not** mentioned in the embedded schema doc-string excerpt: `cost` (`total_cost_usd`, `total_duration_ms`, `total_api_duration_ms`, `total_lines_added`, `total_lines_removed`), `exceeds_200k_tokens` (bool), `fast_mode` (bool). These are real, verified-locally (present in the actual captured JSON) but are additive/undocumented relative to the doc-string block I found — likely because the embedded prompt only shows a curated subset relevant to writing jq snippets, not the full internal type. Treat these three as **verified-locally (undocumented)**.
- Full documented (**embedded schema doc-string, verified-locally**) optional top-level keys beyond the above: `session_name` (set via `/rename`), `prompt_id`, `vim.mode`, `agent.{name,type}` (when started with `--agent`), `pr.{number,url,review_state}`, `worktree.{name,path,branch,original_cwd,original_branch}`, `workspace.git_worktree`, `workspace.repo.{host,owner,name}`.

### Statusline JSON fragment
```json
{
  "statusLine": {
    "type": "command",
    "command": "/path/to/compagnion-statusline-forwarder.sh"
  }
}
```
Design the forwarder to read stdin once, POST it to `http://127.0.0.1:48765/event` (or a distinct `/statusline` path so your listener can tell hook events from statusline pushes apart — statusline pushes have no `hook_event_name` field at all, which is itself a reliable discriminator), and still print *something* to stdout (even if empty) since Claude Code renders whatever the command prints as the status line text.

---

## 5. Things that would break an installer

**Settings precedence** (documented, `disableAllHooks`/`allowManagedHooksOnly` keys **verified-locally** as literal strings in the binary, with matching error/log messages):

| Location | Scope | Precedence |
|---|---|---|
| Managed policy settings (enterprise) | Org-wide | Highest |
| `.claude/settings.local.json` | Single project, gitignored | High |
| `.claude/settings.json` | Single project, shareable | Medium |
| `~/.claude/settings.json` | All projects (user) | Lowest |
| Plugin `hooks/hooks.json` | While plugin enabled | Plugin-level |
| Skill/agent frontmatter | While component active | Component-level |

**Hooks merge across levels, they do not replace** — a project-level `hooks` block adds to, not overrides, the user-level one. This matters for Compagnion: writing your HTTP hook config to `~/.claude/settings.json` will apply on top of whatever project-level hooks a repo already defines; you should merge into the existing `hooks` key (per event, append to the array) rather than overwrite it.

**Hooks live under a top-level `"hooks"` key**, keyed by event name, each event value an array of `{ "matcher"?: string, "hooks": [ {type, ...} ] }` groups (confirmed by the docs and consistent with the binary's `"must be an object mapping hook event names to matcher arrays"` validation-error string, **verified-locally**). Some events (`UserPromptSubmit`, `Stop`, `PostToolBatch`, `SessionEnd`) have no matcher concept — their entries can omit `matcher` or use a group with only `hooks`.

**No restart needed** — the docs state a file watcher picks up settings changes automatically (**documented**). This is corroborated indirectly: `ConfigChange` exists as its own hook event (**verified-locally** in the binary), implying live config-change detection is a first-class, instrumented code path, not something requiring a relaunch.

**Escape hatches an installer must respect / detect** (**verified-locally**, all found as literal strings alongside matching log/error messages in the binary):
- `disableAllHooks: true` — disables all hooks except managed ones. Log line found: `"Status line is configured but disableAllHooks is true"` and `"To re-enable hooks, remove \"disableAllHooks\" from settings.json or ask Claude."` — if Compagnion's installer finds this set, it should warn the user rather than silently installing inert hooks.
- `allowManagedHooksOnly` — blocks user/project/plugin hooks, only managed (enterprise-policy) hooks run. Log line found: `"Skipping plugin hooks - allowManagedHooksOnly is enabled and no managed plugins"`.
- Both can also be set by org policy, not just local settings — an installer should surface a clear error if hooks silently don't fire because of either.

**`/hooks` slash command** — confirmed by docs (not independently verified in the binary beyond the general presence of hook-listing code paths already seen). Opens a **read-only** browser inside a session showing every configured hook grouped by event, its matcher, full handler detail (command/URL/prompt), and which settings file it came from (User/Project/Local/Plugin/Built-in). It is view-only — you still edit settings.json directly to change anything; this is the tool to tell the user "run `/hooks` to confirm Compagnion's HTTP hooks registered correctly" as a post-install sanity check.

**`claude doctor`** also exists as a CLI subcommand (confirmed live from `claude --help`) — "Check the health of your Claude Code installation. Reads settings files in the current directory without a trust prompt." Useful as an installer pre-flight check (e.g., confirm settings.json parses) alongside/instead of `/doctor` in-session.

**JSONC / formatting concerns**: the binary contains logic for parsing/patching settings.json as JSONC (`Failed to set JSONC property`, insertion-preserving formatting with `insertSpaces`/`tabSize`) — **verified-locally**. This suggests Claude Code itself tolerates comments/trailing commas in settings.json and does in-place structural edits (e.g., via the statusline-setup agent) rather than a full parse+rewrite; Compagnion's installer should do the same (preserve unknown keys, don't reformat/reserialize the whole file) to avoid clobbering user comments or unrelated formatting on files Claude Code itself may also touch.

**`-p`/non-interactive mode caveat** (documented, from `claude --help`): "Settings files that fail validation are silently ignored in this mode (no error dialog is shown)." If Compagnion tests its hook installation using `claude -p`, a malformed settings.json will fail silently rather than error — validate JSON structure yourself before/independent of relying on a `-p` smoke test.

---

## Appendix: verification commands used

```bash
# Resolve installed binary
readlink -f ~/.local/bin/claude
# -> /Users/florent/.local/share/claude/versions/2.1.220

# Confirm event name literals
strings -a "$FILE" | grep -oE '"(PreToolUse|PostToolUse|PostToolUseFailure|PostToolBatch|Notification|Stop|StopFailure|SubagentStop|SubagentStart|SessionStart|SessionEnd|Setup|TurnEnd|PermissionRequest|PermissionDenied|UserPromptSubmit|UserPromptExpansion|PreCompact|PostCompact|WorktreeCreate|WorktreeRemove|FileChanged|CwdChanged|ConfigChange|InstructionsLoaded|TaskCreated|TaskCompleted|TeammateIdle|Elicitation|ElicitationResult|MessageDisplay)"' | sort -u

# Confirm Notification matcher/type values
strings -a "$FILE" | grep -oE '"(permission_prompt|idle_prompt|auth_success|elicitation_dialog|elicitation_complete|elicitation_response|agent_needs_input|agent_completed)"' | sort -u

# Confirm statusline schema fields
strings -a "$FILE" | grep -oE '"(context_window|used_percentage|context_window_size|total_input_tokens|rate_limits|five_hour|seven_day|resets_at|session_id)"' | sort -u

# Extract the embedded full statusline stdin schema doc-string
strings -a "$FILE" | grep -n -B3 -A15 '"context_window_size"'

# Confirm HTTP hook schema fields (url, timeout in seconds, headers, allowedEnvVars)
strings -a "$FILE" | sed -n '318170,318260p'

# Live capture: backed up ~/.claude/settings.json, set statusLine.command to
# `cat > /tmp/.../statusline_capture.json`, drove one turn via a PTY-attached
# `claude` process, captured the real payload, restored settings.json from backup
# (diffed identical after restore).
```
