# Claude Agent Support Design

## Summary

Add Claude Code CLI as a selectable coding agent alongside Codex in Symphony. The integration uses a parallel module approach: a new `SymphonyElixir.Claude.Session` module handles Claude Code CLI communication, while existing Codex paths remain untouched. Agent selection is configured via `agent_type` in WORKFLOW.md.

## Decisions

- **Agent role**: Claude runs alongside Codex as a selectable alternative (not a replacement)
- **Interface**: Claude Code CLI as subprocess, similar to how Codex uses `codex app-server`
- **Multi-turn**: Uses `--resume <session-id>` for conversation continuity across turns
- **Model**: Configurable in WORKFLOW.md via `claude.model` field
- **Approvals**: Auto-approve all (run with `--dangerously-skip-permissions`)
- **Dynamic tools**: Not included in V1. Claude Code uses built-in tools. MCP-based `linear_graphql` can be added later.

## Architecture

### Approach: Parallel Module

Create a `SymphonyElixir.Claude` namespace parallel to `SymphonyElixir.Codex`. The agent selection lives in `agent_runner.ex` which dispatches to either `Codex.AppServer` or `Claude.Session` based on `Config.settings!().agent_type`.

Chosen over Generic Agent Behaviour (over-engineered for two agents) and Adapter in AppServer (would make the already-large AppServer unwieldy).

## Components

### 1. Claude Session Module

**File**: `lib/symphony_elixir/claude/session.ex`

Public API (matching Codex.AppServer's contract):

- `run(workspace, prompt, issue, opts)` - convenience wrapper
- `start_session(workspace, opts)` - spawns Claude Code CLI, returns session struct
- `run_turn(session, prompt, issue, opts)` - sends prompt via `--resume`, awaits completion
- `stop_session(session)` - kills port process if still alive

Session struct:

```elixir
%{
  port: port(),
  metadata: map(),
  session_id: String.t(),
  workspace: Path.t(),
  worker_host: String.t() | nil,
  model: String.t() | nil
}
```

**How it works**:

1. `start_session`: Spawns `claude -p "You are an autonomous coding agent. Await task instructions." --output-format stream-json --dangerously-skip-permissions` via `Port.open`. This minimal prompt establishes the session without issue-specific context. Parses the `system/init` JSON event to extract `session_id` and `model`. The actual issue prompt is sent in `run_turn`.
2. `run_turn`: Spawns `claude -p "prompt" --resume <session_id> --output-format stream-json --dangerously-skip-permissions --model <model>` for each turn. Each invocation is a fresh subprocess.
3. Output parsing: Stream JSON lines from the port. Key event types:
   - `system/init` - session metadata (session_id, model)
   - `assistant/text` - Claude text output (emit as progress messages)
   - `assistant/tool_use` - Claude using a tool (handled internally by Claude Code)
   - `result/success` - turn completed, contains usage stats (tokens, cost, duration)
   - `result/error` - turn failed
   - `result/error_max_turns` - hit max turns limit
4. `stop_session`: No persistent connection to close. Clean up port if still alive.

**Key difference from Codex**: No JSON-RPC protocol. No dynamic tool calls (V1). No approval handling (Claude Code manages internally with `--dangerously-skip-permissions`). Each turn is a fresh CLI invocation with `--resume` for state continuity.

**Remote worker support**: Same SSH pattern as Codex. `start_port(workspace, worker_host)` launches `claude` on remote host via SSH when `worker_host` is set.

### 2. Config Schema

**File**: `lib/symphony_elixir/config/schema.ex`

New embedded schema `Claude`:

```elixir
defmodule Claude do
  embedded_schema do
    field(:command, :string, default: "claude")
    field(:model, :string)
    field(:session_id, :string)
    field(:turn_timeout_ms, :integer, default: 3_600_000)
    field(:stall_timeout_ms, :integer, default: 300_000)
  end
end
```

Main schema additions:

- `field(:agent_type, :string, default: "codex")` - top-level field, values: "codex" or "claude"
- `embeds_one(:claude, Claude, on_replace: :update, defaults_to_struct: true)` - alongside existing `codex` embed
- `finalize_settings/1` resolves `claude.model` and `claude.command`

**Config.ex additions**:

- `agent_type/0` - returns `settings!().agent_type`
- `claude_runtime_settings/1` - returns `%{command, model, turn_timeout_ms, stall_timeout_ms}`
- `validate!/1` - add validation: if `agent_type == "claude"`, require `claude.command` to be present

**WORKFLOW.md format**:

```yaml
agent_type: claude

claude:
  command: claude
  model: claude-sonnet-4-6
  turn_timeout_ms: 3600000
  stall_timeout_ms: 300000
```

Default `agent_type` is "codex" so existing WORKFLOW.md files work unchanged.

### 3. Agent Runner Dispatch

**File**: `lib/symphony_elixir/agent_runner.ex`

Add dispatch layer:

```elixir
alias SymphonyElixir.{Claude.Session, Codex.AppServer}

defp start_agent_session(workspace, opts) do
  case Config.agent_type() do
    "claude" -> Session.start_session(workspace, opts)
    _ -> AppServer.start_session(workspace, opts)
  end
end

defp run_agent_turn(session, prompt, issue, opts) do
  case Config.agent_type() do
    "claude" -> Session.run_turn(session, prompt, issue, opts)
    _ -> AppServer.run_turn(session, prompt, issue, opts)
  end
end

defp stop_agent_session(session) do
  case Config.agent_type() do
    "claude" -> Session.stop_session(session)
    _ -> AppServer.stop_session(session)
  end
end
```

Update `run_codex_turns/5` to use `start_agent_session`, `run_agent_turn`, `stop_agent_session` instead of direct `AppServer` calls.

Continuation prompt text: Replace "previous Codex turn" with "previous agent turn" for agent neutrality.

### 4. Orchestrator Updates

**File**: `lib/symphony_elixir/orchestrator.ex`

Internal renames (no external API changes):

- `codex_totals` -> `agent_totals`
- `codex_rate_limits` -> `agent_rate_limits`
- `codex_app_server_pid` -> `agent_session_pid`
- `codex_input_tokens` -> `agent_input_tokens`
- `codex_output_tokens` -> `agent_output_tokens`
- `codex_total_tokens` -> `agent_total_tokens`
- `codex_last_reported_*_tokens` -> `agent_last_reported_*_tokens`
- `integrate_codex_update/2` -> `integrate_agent_update/2`

Message format backward compatibility:

- `{:codex_worker_update, issue_id, message}` stays unchanged (existing consumers may depend on it)
- Add `{:agent_worker_update, issue_id, message}` as the canonical name; both are handled identically
- `send_codex_update` renamed to `send_agent_update` internally

`input_required_blocker?/1`: Add Claude-specific blocker detection alongside existing Codex ones.

### 5. Tests

**File**: `test/symphony_elixir/claude/session_test.exs`

Test cases:
- `start_session` returns session struct with session_id
- `start_session` validates workspace path (same safety checks as Codex)
- `run_turn` sends prompt and returns result on success
- `run_turn` returns error on CLI failure
- `run_turn` returns error on timeout
- `run_turn` returns error on stall
- `stop_session` cleans up port
- Output parsing: correctly extracts session_id from system/init event
- Output parsing: correctly identifies result/success as completion
- Output parsing: correctly identifies result/error as failure
- Output parsing: correctly maps usage stats to expected format

## File Inventory

**New files**:
1. `lib/symphony_elixir/claude/session.ex`
2. `test/symphony_elixir/claude/session_test.exs`

**Modified files**:
3. `lib/symphony_elixir/config/schema.ex` - Add Claude schema, agent_type field, claude embed
4. `lib/symphony_elixir/config.ex` - Add agent_type/0, claude_runtime_settings/1
5. `lib/symphony_elixir/agent_runner.ex` - Add dispatch functions, agent-neutral prompts
6. `lib/symphony_elixir/orchestrator.ex` - Rename codex_ -> agent_, add Claude blocker detection
7. `WORKFLOW.md` - Add agent_type and claude: section

**Unchanged files**:
- `prompt_builder.ex` - Already agent-agnostic
- `workspace.ex` - Already agent-agnostic
- `codex/app_server.ex` - No changes (parallel module approach)
- `codex/dynamic_tool.ex` - No changes (not used by Claude V1)

## Out of Scope (V1)

- Dynamic tools / MCP server for `linear_graphql` - add in V2
- Agent Behaviour abstraction - premature for two agents
- Claude API (HTTP) integration - CLI approach is simpler and sufficient
- Mixed-agent dispatch (different agents per issue) - single agent_type per deployment
- Web dashboard changes for Claude-specific metrics - same format as Codex metrics
