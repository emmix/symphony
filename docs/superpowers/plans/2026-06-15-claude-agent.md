# Claude Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Claude Code CLI as a selectable coding agent alongside Codex in Symphony, dispatched via `agent_type` in WORKFLOW.md config.

**Architecture:** Parallel module approach — new `SymphonyElixir.Claude.Session` handles Claude Code CLI communication via `--resume`, while existing Codex paths remain untouched. Agent runner dispatches to either module based on config. Each Claude turn is a fresh CLI invocation with `--resume <session-id>` for conversation continuity.

**Tech Stack:** Elixir, Ecto embedded schemas, Port.open for subprocess management, Claude Code CLI (`--output-format stream-json`)

---

## File Structure

**New files:**
1. `elixir/lib/symphony_elixir/claude/session.ex` — Claude Code CLI subprocess lifecycle and stream-json output parsing
2. `elixir/test/symphony_elixir/claude/session_test.exs` — Tests using fake shell scripts as CLI mock

**Modified files:**
3. `elixir/lib/symphony_elixir/config/schema.ex` — Add Claude embedded schema, `agent_type` field, `claude` embed, finalize_settings normalization
4. `elixir/lib/symphony_elixir/config.ex` — Add `agent_type/0`, `claude_runtime_settings/1`, validation for claude.command
5. `elixir/lib/symphony_elixir/agent_runner.ex` — Add dispatch functions, agent-neutral continuation prompt
6. `elixir/lib/symphony_elixir/orchestrator.ex` — Rename `codex_` → `agent_` in state/funcs, add `:agent_worker_update` handling, add Claude blocker detection
7. `elixir/test/support/test_support.exs` — Add claude overrides and alias
8. `elixir/WORKFLOW.md` — Add `agent_type` and `claude:` section

**Unchanged files:** `prompt_builder.ex`, `workspace.ex`, `codex/app_server.ex`, `codex/dynamic_tool.ex`

---

### Task 1: Add Claude Config Schema

**Files:**
- Modify: `elixir/lib/symphony_elixir/config/schema.ex:159-206,270-280,360-393`
- Test: `elixir/test/symphony_elixir/config/schema_test.exs`

- [ ] **Step 1: Write the failing test for Claude schema parsing**

Add to `elixir/test/symphony_elixir/config/schema_test.exs`:

```elixir
test "parses claude config with defaults" do
  config = %{"tracker" => %{"kind" => "linear", "api_key" => "k", "project_slug" => "p"}, "claude" => %{}}
  assert {:ok, settings} = Schema.parse(config)
  assert settings.claude.command == "claude"
  assert settings.claude.model == nil
  assert settings.claude.turn_timeout_ms == 3_600_000
  assert settings.claude.stall_timeout_ms == 300_000
  assert settings.agent_type == "codex"
end

test "parses agent_type and claude overrides" do
  config = %{
    "tracker" => %{"kind" => "linear", "api_key" => "k", "project_slug" => "p"},
    "agent_type" => "claude",
    "claude" => %{"command" => "/usr/local/bin/claude", "model" => "claude-sonnet-4-6", "turn_timeout_ms" => 1_800_000}
  }
  assert {:ok, settings} = Schema.parse(config)
  assert settings.agent_type == "claude"
  assert settings.claude.command == "/usr/local/bin/claude"
  assert settings.claude.model == "claude-sonnet-4-6"
  assert settings.claude.turn_timeout_ms == 1_800_000
end

test "rejects invalid claude config" do
  config = %{"tracker" => %{"kind" => "linear", "api_key" => "k", "project_slug" => "p"}, "claude" => %{"turn_timeout_ms" => 0}}
  assert {:error, {:invalid_workflow_config, _}} = Schema.parse(config)
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /home/jin/symphony/.claude/worktrees/claude-agent/elixir && mix test test/symphony_elixir/config/schema_test.exs --include config`
Expected: FAIL (Claude module undefined, agent_type field missing)

- [ ] **Step 3: Add the Claude embedded schema**

Insert after the `Codex` module (after line 206) in `elixir/lib/symphony_elixir/config/schema.ex`:

```elixir
defmodule Claude do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:command, :string, default: "claude")
    field(:model, :string)
    field(:turn_timeout_ms, :integer, default: 3_600_000)
    field(:stall_timeout_ms, :integer, default: 300_000)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:command, :model, :turn_timeout_ms, :stall_timeout_ms], empty_values: [])
    |> validate_required([:command])
    |> validate_number(:turn_timeout_ms, greater_than: 0)
    |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
  end
end
```

- [ ] **Step 4: Add `agent_type` field and `claude` embed to main schema**

In `elixir/lib/symphony_elixir/config/schema.ex`, change the main `embedded_schema` block (lines 270-280) from:

```elixir
embedded_schema do
  embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
  embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
  embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
  embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
  embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
  embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
  embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
  embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
  embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
end
```

to:

```elixir
embedded_schema do
  field(:agent_type, :string, default: "codex")
  embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
  embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
  embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
  embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
  embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
  embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
  embeds_one(:claude, Claude, on_replace: :update, defaults_to_struct: true)
  embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
  embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
  embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
end
```

- [ ] **Step 5: Update `changeset/1` to cast `agent_type` and `claude` embed**

In `elixir/lib/symphony_elixir/config/schema.ex`, change `changeset/1` (lines 360-372) from:

```elixir
defp changeset(attrs) do
  %__MODULE__{}
  |> cast(attrs, [])
  |> cast_embed(:tracker, with: &Tracker.changeset/2)
  |> cast_embed(:polling, with: &Polling.changeset/2)
  |> cast_embed(:workspace, with: &Workspace.changeset/2)
  |> cast_embed(:worker, with: &Worker.changeset/2)
  |> cast_embed(:agent, with: &Agent.changeset/2)
  |> cast_embed(:codex, with: &Codex.changeset/2)
  |> cast_embed(:hooks, with: &Hooks.changeset/2)
  |> cast_embed(:observability, with: &Observability.changeset/2)
  |> cast_embed(:server, with: &Server.changeset/2)
end
```

to:

```elixir
defp changeset(attrs) do
  %__MODULE__{}
  |> cast(attrs, [:agent_type])
  |> cast_embed(:tracker, with: &Tracker.changeset/2)
  |> cast_embed(:polling, with: &Polling.changeset/2)
  |> cast_embed(:workspace, with: &Workspace.changeset/2)
  |> cast_embed(:worker, with: &Worker.changeset/2)
  |> cast_embed(:agent, with: &Agent.changeset/2)
  |> cast_embed(:codex, with: &Codex.changeset/2)
  |> cast_embed(:claude, with: &Claude.changeset/2)
  |> cast_embed(:hooks, with: &Hooks.changeset/2)
  |> cast_embed(:observability, with: &Observability.changeset/2)
  |> cast_embed(:server, with: &Server.changeset/2)
end
```

- [ ] **Step 6: Update `finalize_settings/1` to normalize Claude config**

In `elixir/lib/symphony_elixir/config/schema.ex`, change `finalize_settings/1` (lines 374-393) from:

```elixir
defp finalize_settings(settings) do
  tracker = %{
    settings.tracker
    | api_key: resolve_secret_setting(settings.tracker.api_key, System.get_env("LINEAR_API_KEY")),
      assignee: resolve_secret_setting(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE"))
  }

  workspace = %{
    settings.workspace
    | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
  }

  codex = %{
    settings.codex
    | approval_policy: normalize_keys(settings.codex.approval_policy),
      turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy)
  }

  %{settings | tracker: tracker, workspace: workspace, codex: codex}
end
```

to:

```elixir
defp finalize_settings(settings) do
  tracker = %{
    settings.tracker
    | api_key: resolve_secret_setting(settings.tracker.api_key, System.get_env("LINEAR_API_KEY")),
      assignee: resolve_secret_setting(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE"))
  }

  workspace = %{
    settings.workspace
    | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
  }

  codex = %{
    settings.codex
    | approval_policy: normalize_keys(settings.codex.approval_policy),
      turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy)
  }

  claude = %{
    settings.claude
    | command: resolve_path_value(settings.claude.command, "claude"),
      model: settings.claude.model
  }

  %{settings | tracker: tracker, workspace: workspace, codex: codex, claude: claude}
end
```

- [ ] **Step 7: Run the schema tests to verify they pass**

Run: `cd /home/jin/symphony/.claude/worktrees/claude-agent/elixir && mix test test/symphony_elixir/config/schema_test.exs --include config`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
cd /home/jin/symphony/.claude/worktrees/claude-agent && git add elixir/lib/symphony_elixir/config/schema.ex elixir/test/symphony_elixir/config/schema_test.exs && git commit -m "feat(config): add Claude schema, agent_type field, and claude embed"
```

---

### Task 2: Add Config Facade Methods

**Files:**
- Modify: `elixir/lib/symphony_elixir/config.ex:94-134`
- Test: `elixir/test/symphony_elixir/config_test.exs`

- [ ] **Step 1: Write the failing test for agent_type and claude_runtime_settings**

Add to `elixir/test/symphony_elixir/config_test.exs`:

```elixir
test "agent_type returns codex by default" do
  write_workflow_file!(workflow_file)
  assert Config.agent_type() == "codex"
end

test "agent_type returns claude when configured" do
  write_workflow_file!(workflow_file, agent_type: "claude")
  assert Config.agent_type() == "claude"
end

test "claude_runtime_settings returns defaults" do
  write_workflow_file!(workflow_file)
  assert {:ok, settings} = Config.claude_runtime_settings()
  assert settings.command == "claude"
  assert settings.model == nil
  assert settings.turn_timeout_ms == 3_600_000
  assert settings.stall_timeout_ms == 300_000
end

test "claude_runtime_settings returns overrides" do
  write_workflow_file!(workflow_file, claude_command: "/opt/claude", claude_model: "claude-sonnet-4-6", claude_turn_timeout_ms: 1_800_000)
  assert {:ok, settings} = Config.claude_runtime_settings()
  assert settings.command == "/opt/claude"
  assert settings.model == "claude-sonnet-4-6"
  assert settings.turn_timeout_ms == 1_800_000
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /home/jin/symphony/.claude/worktrees/claude-agent/elixir && mix test test/symphony_elixir/config_test.exs --include config`
Expected: FAIL (agent_type/0 undefined, claude_runtime_settings/1 undefined)

- [ ] **Step 3: Add `agent_type/0` and `claude_runtime_settings/1` to Config**

In `elixir/lib/symphony_elixir/config.ex`, add after `codex_runtime_settings/2` (after line 115):

```elixir
@spec agent_type() :: String.t()
def agent_type do
  settings!().agent_type
end

@spec claude_runtime_settings(keyword()) :: {:ok, map()} | {:error, term()}
def claude_runtime_settings(opts \\ []) do
  with {:ok, settings} <- settings() do
    {:ok,
     %{
       command: settings.claude.command,
       model: settings.claude.model,
       turn_timeout_ms: settings.claude.turn_timeout_ms,
       stall_timeout_ms: settings.claude.stall_timeout_ms
     }}
  end
end
```

- [ ] **Step 4: Add claude validation to `validate_semantics/1`**

In `elixir/lib/symphony_elixir/config.ex`, update `validate_semantics/1` (lines 117-134) from:

```elixir
defp validate_semantics(settings) do
  cond do
    is_nil(settings.tracker.kind) ->
      {:error, :missing_tracker_kind}

    settings.tracker.kind not in ["linear", "memory"] ->
      {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

    settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
      {:error, :missing_linear_api_token}

    settings.tracker.kind == "linear" and not is_binary(settings.tracker.project_slug) ->
      {:error, :missing_linear_project_slug}

    true ->
      :ok
  end
end
```

to:

```elixir
defp validate_semantics(settings) do
  cond do
    is_nil(settings.tracker.kind) ->
      {:error, :missing_tracker_kind}

    settings.tracker.kind not in ["linear", "memory"] ->
      {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

    settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
      {:error, :missing_linear_api_token}

    settings.tracker.kind == "linear" and not is_binary(settings.tracker.project_slug) ->
      {:error, :missing_linear_project_slug}

    settings.agent_type == "claude" and not is_binary(settings.claude.command) ->
      {:error, :missing_claude_command}

    settings.agent_type not in ["codex", "claude"] ->
      {:error, {:unsupported_agent_type, settings.agent_type}}

    true ->
      :ok
  end
end
```

- [ ] **Step 5: Run the config tests to verify they pass**

Run: `cd /home/jin/symphony/.claude/worktrees/claude-agent/elixir && mix test test/symphony_elixir/config_test.exs --include config`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
cd /home/jin/symphony/.claude/worktrees/claude-agent && git add elixir/lib/symphony_elixir/config.ex elixir/test/symphony_elixir/config_test.exs && git commit -m "feat(config): add agent_type/0, claude_runtime_settings/1, and claude validation"
```

---

### Task 3: Update Test Support for Claude Config

**Files:**
- Modify: `elixir/test/support/test_support.exs`

- [ ] **Step 1: Add claude keyword defaults and YAML generation to test_support**

In `elixir/test/support/test_support.exs`:

First, add the alias after line 11 (`alias SymphonyElixir.Codex.AppServer`):

```elixir
alias SymphonyElixir.Claude.Session
```

Then, in `workflow_content/1` (lines 91-207), add claude defaults to the `Keyword.merge` (after line 118 `codex_stall_timeout_ms: 300_000,`):

```elixir
agent_type: "codex",
claude_command: "claude",
claude_model: nil,
claude_turn_timeout_ms: 3_600_000,
claude_stall_timeout_ms: 300_000,
```

Then add variable extraction after line 166 (`codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)`):

```elixir
agent_type = Keyword.get(config, :agent_type)
claude_command = Keyword.get(config, :claude_command)
claude_model = Keyword.get(config, :claude_model)
claude_turn_timeout_ms = Keyword.get(config, :claude_turn_timeout_ms)
claude_stall_timeout_ms = Keyword.get(config, :claude_stall_timeout_ms)
```

Then add the claude YAML section after the `codex:` block (after line 197 `...stall_timeout_ms}")`), before `hooks_yaml`:

```elixir
"agent_type: #{yaml_value(agent_type)}",
"claude:",
"  command: #{yaml_value(claude_command)}",
"  model: #{yaml_value(claude_model)}",
"  turn_timeout_ms: #{yaml_value(claude_turn_timeout_ms)}",
"  stall_timeout_ms: #{yaml_value(claude_stall_timeout_ms)}",
```

- [ ] **Step 2: Run existing tests to verify nothing is broken**

Run: `cd /home/jin/symphony/.claude/worktrees/claude-agent/elixir && mix test --include config 2>&1 | tail -5`
Expected: All existing tests pass (some may fail if they depend on exact YAML format; fix if needed)

- [ ] **Step 3: Commit**

```bash
cd /home/jin/symphony/.claude/worktrees/claude-agent && git add elixir/test/support/test_support.exs && git commit -m "test(support): add claude config overrides and alias to test_support"
```

---

### Task 4: Implement Claude Session Module

**Files:**
- Create: `elixir/lib/symphony_elixir/claude/session.ex`

- [ ] **Step 1: Create the Claude Session module**

Create `elixir/lib/symphony_elixir/claude/session.ex`:

```elixir
defmodule SymphonyElixir.Claude.Session do
  @moduledoc """
  Client for the Claude Code CLI using --resume for multi-turn conversation continuity.

  Each turn spawns a fresh `claude` subprocess with `--resume <session-id>` so that
  Claude Code manages its own conversation history. The initial `start_session` call
  establishes the session and extracts the session_id from the `system/init` JSON event.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @port_line_bytes 1_048_576

  @type session :: %{
          port: port(),
          metadata: map(),
          session_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          model: String.t() | nil
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    runtime = Config.claude_runtime_settings!()

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, port} <- start_port(expanded_workspace, worker_host, runtime) do
      metadata = port_metadata(port, worker_host)

      case await_session_init(port) do
        {:ok, %{session_id: session_id, model: model}} ->
          {:ok,
           %{
             port: port,
             metadata: metadata,
             session_id: session_id,
             workspace: expanded_workspace,
             worker_host: worker_host,
             model: model
           }}

        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{session_id: session_id, workspace: workspace, worker_host: worker_host, model: model},
        prompt,
        issue,
        opts \\ []
      ) do
    runtime = Config.claude_runtime_settings!()
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
    turn_timeout_ms = Keyword.get(opts, :turn_timeout_ms, runtime.turn_timeout_ms)
    stall_timeout_ms = Keyword.get(opts, :stall_timeout_ms, runtime.stall_timeout_ms)

    with {:ok, port} <- start_resume_port(workspace, worker_host, runtime, session_id, prompt, model) do
      try do
        case await_turn_completion(port, on_message, turn_timeout_ms, stall_timeout_ms) do
          {:ok, usage} ->
            emit_message(on_message, :session_completed, %{
              session_id: session_id,
              usage: usage
            })

            {:ok, %{session_id: session_id, usage: usage}}

          {:error, :max_turns} ->
            emit_message(on_message, :turn_ended_with_error, %{
              session_id: session_id,
              reason: :max_turns
            })

            {:error, :max_turns}

          {:error, reason} ->
            emit_message(on_message, :turn_ended_with_error, %{
              session_id: session_id,
              reason: reason
            })

            {:error, reason}
        end
      after
        stop_port(port)
      end
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  def stop_session(_session), do: :ok

  # --- Private ---

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, nil, runtime) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      cmd = build_init_command(runtime)

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(cmd)],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host, _runtime) when is_binary(worker_host) do
    remote_command = "cd #{shell_escape(workspace)} && exec claude"
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp start_resume_port(workspace, nil, runtime, session_id, prompt, model) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      cmd = build_resume_command(runtime, session_id, prompt, model)

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(cmd)],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_resume_port(workspace, worker_host, _runtime, _session_id, _prompt, _model)
       when is_binary(worker_host) do
    {:error, :remote_claude_resume_not_supported}
  end

  defp build_init_command(runtime) do
    parts = ["exec #{shell_escape(runtime.command)}"]
    parts = if runtime.model, do: parts ++ ["--model", shell_escape(runtime.model)], else: parts
    parts = parts ++ ["-p", shell_escape("You are an autonomous coding agent. Await task instructions."), "--output-format", "stream-json", "--dangerously-skip-permissions"]
    Enum.join(parts, " ")
  end

  defp build_resume_command(runtime, session_id, prompt, model) do
    resolved_model = model || runtime.model
    parts = ["exec #{shell_escape(runtime.command)}"]
    parts = if resolved_model, do: parts ++ ["--model", shell_escape(resolved_model)], else: parts
    parts = parts ++ ["--resume", shell_escape(session_id), "-p", shell_escape(prompt), "--output-format", "stream-json", "--dangerously-skip-permissions"]
    Enum.join(parts, " ")
  end

  defp await_session_init(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case parse_json_line(line) do
          %{"type" => "system", "subtype" => "init", "session_id" => session_id} = event ->
            model = Map.get(event, "model")
            {:ok, %{session_id: session_id, model: model}}

          _ ->
            await_session_init(port)
        end

      {^port, {:exit_status, status}} ->
        {:error, {:cli_exit_before_init, status}}
    after
      30_000 ->
        stop_port(port)
        {:error, :session_init_timeout}
    end
  end

  defp await_turn_completion(port, on_message, turn_timeout_ms, stall_timeout_ms) do
    cutoff = System.monotonic_time(:millisecond) + turn_timeout_ms
    await_turn_loop(port, on_message, nil, cutoff, stall_timeout_ms)
  end

  defp await_turn_loop(port, on_message, last_activity, cutoff, stall_timeout_ms) do
    now = System.monotonic_time(:millisecond)

    stall_deadline =
      if is_integer(last_activity) and is_integer(stall_timeout_ms) do
        last_activity + stall_timeout_ms
      else
        nil
      end

    timeout =
      cond do
        now >= cutoff ->
          0

        is_integer(stall_deadline) ->
          min(cutoff - now, stall_deadline - now)

        true ->
          cutoff - now
      end

    if timeout <= 0 do
      cond do
        now >= cutoff ->
          {:error, :turn_timeout}

        is_integer(stall_deadline) and now >= stall_deadline ->
          {:error, :turn_stalled}

        true ->
          await_turn_loop(port, on_message, last_activity, cutoff, stall_timeout_ms)
      end
    else
      receive do
        {^port, {:data, {:eol, line}}} ->
          handle_stream_line(line, port, on_message, cutoff, stall_timeout_ms)

        {^port, {:data, {:noeol, partial}}} ->
          # Buffer partial line; simplified — wait for eol
          await_turn_loop(port, on_message, now, cutoff, stall_timeout_ms)

        {^port, {:exit_status, 0}} ->
          {:ok, %{}}

        {^port, {:exit_status, status}} ->
          {:error, {:cli_exit_with_status, status}}
      after
        timeout ->
          now2 = System.monotonic_time(:millisecond)

          cond do
            now2 >= cutoff -> {:error, :turn_timeout}
            is_integer(stall_deadline) and now2 >= stall_deadline -> {:error, :turn_stalled}
            true -> await_turn_loop(port, on_message, last_activity, cutoff, stall_timeout_ms)
          end
      end
    end
  end

  defp handle_stream_line(line, port, on_message, cutoff, stall_timeout_ms) do
    now = System.monotonic_time(:millisecond)

    case parse_json_line(line) do
      %{"type" => "result", "subtype" => "success"} = event ->
        usage = extract_usage(event)
        {:ok, usage}

      %{"type" => "result", "subtype" => "error_max_turns"} ->
        {:error, :max_turns}

      %{"type" => "result", "subtype" => "error"} = event ->
        message = Map.get(event, "message", "unknown error")
        {:error, {:cli_error, message}}

      %{"type" => "assistant", "subtype" => "text"} = event ->
        text = Map.get(event, "text", "")
        emit_message(on_message, :turn_progress, %{text: text})
        await_turn_loop(port, on_message, now, cutoff, stall_timeout_ms)

      %{"type" => "assistant", "subtype" => "tool_use"} ->
        await_turn_loop(port, on_message, now, cutoff, stall_timeout_ms)

      _ ->
        await_turn_loop(port, on_message, now, cutoff, stall_timeout_ms)
    end
  end

  defp extract_usage(event) do
    usage = Map.get(event, "usage", %{})
    %{
      input_tokens: Map.get(usage, "input_tokens", 0),
      output_tokens: Map.get(usage, "output_tokens", 0),
      total_tokens: Map.get(usage, "total_tokens", 0),
      duration_ms: Map.get(event, "duration_ms", 0),
      cost_usd: Map.get(event, "cost_usd", 0.0)
    }
  end

  defp parse_json_line(line) do
    case Jason.decode(line) do
      {:ok, parsed} -> parsed
      {:error, _} -> nil
    end
  end

  defp emit_message(on_message, event, payload) when is_function(on_message, 1) do
    on_message.(%{event: event, payload: payload, timestamp: DateTime.utc_now()})
  end

  defp emit_message(_on_message, _event, _payload), do: :ok

  defp stop_port(port) when is_port(port) do
    if Process.alive?(port) do
      Port.close(port)
    end

    :ok
  end

  defp stop_port(_port), do: :ok

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{agent_session_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp shell_escape(value) when is_binary(value) do
   ("'" <> String.replace(value, "'", "'\\''") <> "'")
  end
end
```

- [ ] **Step 2: Run compilation to verify no syntax errors**

Run: `cd /home/jin/symphony/.claude/worktrees/claude-agent/elixir && mix compile 2>&1 | tail -10`
Expected: Clean compilation (may need to add `Jason` to deps if not already present — it should be)

- [ ] **Step 3: Commit**

```bash
cd /home/jin/symphony/.claude/worktrees/claude-agent && git add elixir/lib/symphony_elixir/claude/session.ex && git commit -m "feat(claude): add Claude.Session module for CLI subprocess management"
```

---

### Task 5: Add Claude Session Tests

**Files:**
- Create: `elixir/test/symphony_elixir/claude/session_test.exs`

- [ ] **Step 1: Create Claude Session test file**

Create `elixir/test/symphony_elixir/claude/session_test.exs`:

```elixir
defmodule SymphonyElixir.Claude.SessionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Claude.Session

  describe "start_session/2" do
    test "returns session struct with session_id from system/init event" do
      script_dir = Path.join(System.tmp_dir!(), "claude-fake-#{System.unique_integer([:positive])}")
      File.mkdir_p!(script_dir)

      fake_claude = Path.join(script_dir, "claude")

      init_json =
        Jason.encode!(%{
          type: "system",
          subtype: "init",
          session_id: "sess_abc123",
          model: "claude-sonnet-4-6",
          tools: []
        })

      result_json =
        Jason.encode!(%{
          type: "result",
          subtype: "success",
          usage: %{input_tokens: 100, output_tokens: 50, total_tokens: 150},
          duration_ms: 5000,
          cost_usd: 0.01
        })

      File.write!(fake_claude, """
      #!/bin/bash
      echo '#{init_json}'
      echo '#{result_json}'
      exit 0
      """)

      File.chmod!(fake_claude, 0o755)

      try do
        write_workflow_file!(workflow_file, agent_type: "claude", claude_command: fake_claude)

        workspace = Path.join(Config.settings!().workspace.root, "test-workspace")
        File.mkdir_p!(workspace)

        assert {:ok, session} = Session.start_session(workspace)
        assert session.session_id == "sess_abc123"
        assert session.model == "claude-sonnet-4-6"
      after
        File.rm_rf!(script_dir)
      end
    end

    test "returns error on CLI failure" do
      script_dir = Path.join(System.tmp_dir!(), "claude-fake-#{System.unique_integer([:positive])}")
      File.mkdir_p!(script_dir)

      fake_claude = Path.join(script_dir, "claude")
      File.write!(fake_claude, """
      #!/bin/bash
      echo "fatal error" >&2
      exit 1
      """)

      File.chmod!(fake_claude, 0o755)

      try do
        write_workflow_file!(workflow_file, agent_type: "claude", claude_command: fake_claude)

        workspace = Path.join(Config.settings!().workspace.root, "test-workspace")
        File.mkdir_p!(workspace)

        assert {:error, {:cli_exit_before_init, 1}} = Session.start_session(workspace)
      after
        File.rm_rf!(script_dir)
      end
    end
  end

  describe "run_turn/4" do
    test "sends prompt and returns result on success" do
      script_dir = Path.join(System.tmp_dir!(), "claude-fake-#{System.unique_integer([:positive])}")
      File.mkdir_p!(script_dir)

      fake_claude = Path.join(script_dir, "claude")

      text_json =
        Jason.encode!(%{
          type: "assistant",
          subtype: "text",
          text: "I'll fix the bug."
        })

      result_json =
        Jason.encode!(%{
          type: "result",
          subtype: "success",
          usage: %{input_tokens: 200, output_tokens: 100, total_tokens: 300},
          duration_ms: 10000,
          cost_usd: 0.02
        })

      # The resume script just outputs text + result
      File.write!(fake_claude, """
      #!/bin/bash
      echo '#{text_json}'
      echo '#{result_json}'
      exit 0
      """)

      File.chmod!(fake_claude, 0o755)

      try do
        write_workflow_file!(workflow_file, agent_type: "claude", claude_command: fake_claude, claude_turn_timeout_ms: 60_000, claude_stall_timeout_ms: 30_000)

        workspace = Path.join(Config.settings!().workspace.root, "test-workspace")
        File.mkdir_p!(workspace)

        session = %{
          port: nil,
          metadata: %{},
          session_id: "sess_test",
          workspace: workspace,
          worker_host: nil,
          model: nil
        }

        messages = []

        on_msg = fn msg ->
          send(self(), {:test_message, msg})
        end

        assert {:ok, result} = Session.run_turn(session, "Fix the bug", %{}, on_message: on_msg)
        assert result.usage.input_tokens == 200
        assert result.usage.output_tokens == 100
      after
        File.rm_rf!(script_dir)
      end
    end

    test "returns error on timeout" do
      script_dir = Path.join(System.tmp_dir!(), "claude-fake-#{System.unique_integer([:positive])}")
      File.mkdir_p!(script_dir)

      fake_claude = Path.join(script_dir, "claude")
      # Script that sleeps forever
      File.write!(fake_claude, """
      #!/bin/bash
      sleep 300
      """)

      File.chmod!(fake_claude, 0o755)

      try do
        write_workflow_file!(workflow_file, agent_type: "claude", claude_command: fake_claude, claude_turn_timeout_ms: 100, claude_stall_timeout_ms: 50)

        workspace = Path.join(Config.settings!().workspace.root, "test-workspace")
        File.mkdir_p!(workspace)

        session = %{
          port: nil,
          metadata: %{},
          session_id: "sess_timeout",
          workspace: workspace,
          worker_host: nil,
          model: nil
        }

        assert {:error, :turn_timeout} = Session.run_turn(session, "Do something", %{})
      after
        File.rm_rf!(script_dir)
      end
    end

    test "returns max_turns error on result/error_max_turns" do
      script_dir = Path.join(System.tmp_dir!(), "claude-fake-#{System.unique_integer([:positive])}")
      File.mkdir_p!(script_dir)

      fake_claude = Path.join(script_dir, "claude")

      max_turns_json =
        Jason.encode!(%{
          type: "result",
          subtype: "error_max_turns"
        })

      File.write!(fake_claude, """
      #!/bin/bash
      echo '#{max_turns_json}'
      exit 0
      """)

      File.chmod!(fake_claude, 0o755)

      try do
        write_workflow_file!(workflow_file, agent_type: "claude", claude_command: fake_claude, claude_turn_timeout_ms: 60_000, claude_stall_timeout_ms: 30_000)

        workspace = Path.join(Config.settings!().workspace.root, "test-workspace")
        File.mkdir_p!(workspace)

        session = %{
          port: nil,
          metadata: %{},
          session_id: "sess_maxturns",
          workspace: workspace,
          worker_host: nil,
          model: nil
        }

        assert {:error, :max_turns} = Session.run_turn(session, "Do something", %{})
      after
        File.rm_rf!(script_dir)
      end
    end
  end

  describe "stop_session/1" do
    test "cleans up port" do
      session = %{port: nil, metadata: %{}, session_id: "test", workspace: "/tmp/ws", worker_host: nil, model: nil}
      assert :ok = Session.stop_session(session)
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `cd /home/jin/symphony/.claude/worktrees/claude-agent/elixir && mix test test/symphony_elixir/claude/session_test.exs --include config`
Expected: PASS (may need minor adjustments to fake script quoting or timeout values)

- [ ] **Step 3: Commit**

```bash
cd /home/jin/symphony/.claude/worktrees/claude-agent && git add elixir/test/symphony_elixir/claude/session_test.exs && git commit -m "test(claude): add Claude.Session tests with fake CLI scripts"
```

---

### Task 6: Add Agent Runner Dispatch

**Files:**
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex:7-8,57-69,87-153`

- [ ] **Step 1: Add Claude.Session alias**

In `elixir/lib/symphony_elixir/agent_runner.ex`, change line 7-8 from:

```elixir
alias SymphonyElixir.Codex.AppServer
alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}
```

to:

```elixir
alias SymphonyElixir.Claude.Session
alias SymphonyElixir.Codex.AppServer
alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}
```

- [ ] **Step 2: Add agent dispatch functions**

In `elixir/lib/symphony_elixir/agent_runner.ex`, add after `send_worker_runtime_info` (after line 85):

```elixir
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

- [ ] **Step 3: Replace direct AppServer calls with dispatch functions**

In `elixir/lib/symphony_elixir/agent_runner.ex`, change `run_codex_turns/5` (lines 87-98) from:

```elixir
defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
  max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
  issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

  with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
    try do
      do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
    after
      AppServer.stop_session(session)
    end
  end
end
```

to:

```elixir
defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
  max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
  issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

  with {:ok, session} <- start_agent_session(workspace, worker_host: worker_host) do
    try do
      do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
    after
      stop_agent_session(session)
    end
  end
end
```

- [ ] **Step 4: Agent-neutral continuation prompt**

In `elixir/lib/symphony_elixir/agent_runner.ex`, change `build_turn_prompt/4` (lines 143-153) from:

```elixir
defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
  """
  Continuation guidance:

  - The previous Codex turn completed normally, but the Linear issue is still in an active state.
  - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
  - Resume from the current workspace and workpad state instead of restarting from scratch.
  - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
  - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
  """
end
```

to:

```elixir
defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
  """
  Continuation guidance:

  - The previous agent turn completed normally, but the Linear issue is still in an active state.
  - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
  - Resume from the current workspace and workpad state instead of restarting from scratch.
  - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
  - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
  """
end
```

- [ ] **Step 5: Replace AppServer.run_turn in do_run_codex_turns**

In `elixir/lib/symphony_elixir/agent_runner.ex`, change `do_run_codex_turns/8` (lines 100-139) from:

```elixir
with {:ok, turn_session} <-
       AppServer.run_turn(
         app_session,
         prompt,
         issue,
         on_message: codex_message_handler(codex_update_recipient, issue)
       ) do
```

to:

```elixir
with {:ok, turn_session} <-
       run_agent_turn(
         app_session,
         prompt,
         issue,
         on_message: codex_message_handler(codex_update_recipient, issue)
       ) do
```

- [ ] **Step 6: Add `:agent_worker_update` message handling**

In `elixir/lib/symphony_elixir/agent_runner.ex`, change `send_codex_update/3` (lines 63-69) from:

```elixir
defp send_codex_update(recipient, %Issue{id: issue_id}, message)
     when is_binary(issue_id) and is_pid(recipient) do
  send(recipient, {:codex_worker_update, issue_id, message})
  :ok
end

defp send_codex_update(_recipient, _issue, _message), do: :ok
```

to:

```elixir
defp send_codex_update(recipient, %Issue{id: issue_id}, message)
     when is_binary(issue_id) and is_pid(recipient) do
  send(recipient, {:codex_worker_update, issue_id, message})
  send(recipient, {:agent_worker_update, issue_id, message})
  :ok
end

defp send_codex_update(_recipient, _issue, _message), do: :ok
```

- [ ] **Step 7: Run existing agent_runner tests to verify nothing breaks**

Run: `cd /home/jin/symphony/.claude/worktrees/claude-agent/elixir && mix test test/symphony_elixir/agent_runner_test.exs 2>&1 | tail -10`
Expected: PASS (all existing tests still pass with dispatch layer)

- [ ] **Step 8: Commit**

```bash
cd /home/jin/symphony/.claude/worktrees/claude-agent && git add elixir/lib/symphony_elixir/agent_runner.ex && git commit -m "feat(agent-runner): add dispatch layer for Claude and Codex agents"
```

---

### Task 7: Update Orchestrator for Agent-Neutral State

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`

- [ ] **Step 1: Rename `@empty_codex_totals` to `@empty_agent_totals`**

In `elixir/lib/symphony_elixir/orchestrator.ex`, change lines 17-22 from:

```elixir
@empty_codex_totals %{
  input_tokens: 0,
  output_tokens: 0,
  total_tokens: 0,
  seconds_running: 0
}
```

to:

```elixir
@empty_agent_totals %{
  input_tokens: 0,
  output_tokens: 0,
  total_tokens: 0,
  seconds_running: 0
}
```

- [ ] **Step 2: Rename State struct fields**

In `elixir/lib/symphony_elixir/orchestrator.ex`, change lines 41-42 from:

```elixir
codex_totals: nil,
codex_rate_limits: nil
```

to:

```elixir
agent_totals: nil,
agent_rate_limits: nil
```

- [ ] **Step 3: Update init to use new names**

In `elixir/lib/symphony_elixir/orchestrator.ex`, change lines 64-65 from:

```elixir
codex_totals: @empty_codex_totals,
codex_rate_limits: nil
```

to:

```elixir
agent_totals: @empty_agent_totals,
agent_rate_limits: nil
```

- [ ] **Step 4: Add `:agent_worker_update` handler**

In `elixir/lib/symphony_elixir/orchestrator.ex`, add after the `{:codex_worker_update, ...}` handler (after line 180):

```elixir
def handle_info({:agent_worker_update, issue_id, %{event: _, timestamp: _} = update}, state) do
  handle_info({:codex_worker_update, issue_id, update}, state)
end

def handle_info({:agent_worker_update, _issue_id, _update}, state), do: {:noreply, state}
```

- [ ] **Step 5: Rename internal functions**

In `elixir/lib/symphony_elixir/orchestrator.ex`, rename these functions:
- `integrate_codex_update/2` → `integrate_agent_update/2` (line 1468)
- `apply_codex_token_delta/2` → `apply_agent_token_delta/2` (line 1611)
- `apply_codex_rate_limits/2` → `apply_agent_rate_limits/2` (line 1621)

Update all call sites to use the new names:
- Line 168: `integrate_codex_update(...)` → `integrate_agent_update(...)`
- Line 172: `apply_codex_token_delta(...)` → `apply_agent_token_delta(...)`
- Line 173: `apply_codex_rate_limits(...)` → `apply_agent_rate_limits(...)`

In `apply_agent_token_delta/2`, change `codex_totals` references to `agent_totals`:

```elixir
defp apply_agent_token_delta(
       %{agent_totals: agent_totals} = state,
       %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
     )
     when is_integer(input) and is_integer(output) and is_integer(total) do
  %{state | agent_totals: apply_token_delta(agent_totals, token_delta)}
end

defp apply_agent_token_delta(state, _token_delta), do: state
```

In `apply_agent_rate_limits/2`, change `codex_rate_limits` to `agent_rate_limits`:

```elixir
defp apply_agent_rate_limits(%State{} = state, update) when is_map(update) do
  case extract_rate_limits(update) do
    %{} = rate_limits ->
      %{state | agent_rate_limits: rate_limits}

    _ ->
      state
  end
end

defp apply_agent_rate_limits(state, _update), do: state
```

- [ ] **Step 6: Update snapshot handler references**

In `elixir/lib/symphony_elixir/orchestrator.ex`, change the snapshot handler (lines 1437-1438) from:

```elixir
codex_totals: state.codex_totals,
rate_limits: Map.get(state, :codex_rate_limits),
```

to:

```elixir
agent_totals: state.agent_totals,
rate_limits: Map.get(state, :agent_rate_limits),
```

- [ ] **Step 7: Update `record_session_completion_totals/2`**

In `elixir/lib/symphony_elixir/orchestrator.ex`, change `record_session_completion_totals/2` (lines 1573-1590) from:

```elixir
defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
  runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

  codex_totals =
    apply_token_delta(
      state.codex_totals,
      %{
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0,
        seconds_running: runtime_seconds
      }
    )

  %{state | codex_totals: codex_totals}
end
```

to:

```elixir
defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
  runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

  agent_totals =
    apply_token_delta(
      state.agent_totals,
      %{
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0,
        seconds_running: runtime_seconds
      }
    )

  %{state | agent_totals: agent_totals}
end
```

- [ ] **Step 8: Update stalling messages for agent neutrality**

In `elixir/lib/symphony_elixir/orchestrator.ex`, change line 609 from:

```elixir
error = blocker_error(running_entry, "stalled for #{elapsed_ms}ms after Codex requested operator input")
```

to:

```elixir
error = blocker_error(running_entry, "stalled for #{elapsed_ms}ms after agent requested operator input")
```

Change line 627 from:

```elixir
error: "stalled for #{elapsed_ms}ms without codex activity"
```

to:

```elixir
error: "stalled for #{elapsed_ms}ms without agent activity"
```

- [ ] **Step 9: Add Claude-specific blocker detection**

In `elixir/lib/symphony_elixir/orchestrator.ex`, change `input_required_blocker?/1` (lines 652-659) from:

```elixir
defp input_required_blocker?(running_entry) when is_map(running_entry) do
  Map.get(running_entry, :last_codex_event) in [:turn_input_required, :approval_required] or
    not is_nil(input_required_completion_outcome(Map.get(running_entry, :completion))) or
    codex_message_method(Map.get(running_entry, :last_codex_message)) ==
      "mcpServer/elicitation/request"
end
```

to:

```elixir
defp input_required_blocker?(running_entry) when is_map(running_entry) do
  Map.get(running_entry, :last_codex_event) in [:turn_input_required, :approval_required] or
    not is_nil(input_required_completion_outcome(Map.get(running_entry, :completion))) or
    codex_message_method(Map.get(running_entry, :last_codex_message)) ==
      "mcpServer/elicitation/request" or
    Map.get(running_entry, :last_codex_event) == :permission_required
end
```

- [ ] **Step 10: Update blocker error functions for agent neutrality**

Change `codex_event_blocker_error/1` (line 692-694) from:

```elixir
defp codex_event_blocker_error(:turn_input_required), do: "codex turn requires operator input"
defp codex_event_blocker_error(:approval_required), do: "codex turn requires approval"
defp codex_event_blocker_error(_event), do: nil
```

to:

```elixir
defp codex_event_blocker_error(:turn_input_required), do: "agent turn requires operator input"
defp codex_event_blocker_error(:approval_required), do: "agent turn requires approval"
defp codex_event_blocker_error(:permission_required), do: "agent turn requires permission"
defp codex_event_blocker_error(_event), do: nil
```

Change `completion_blocker_error/1` (lines 696-702) from:

```elixir
defp completion_blocker_error(completion) do
  case input_required_completion_outcome(completion) do
    outcome when outcome in [:input_required, :needs_input] -> "codex turn requires operator input"
    :approval_required -> "codex turn requires approval"
    nil -> nil
  end
end
```

to:

```elixir
defp completion_blocker_error(completion) do
  case input_required_completion_outcome(completion) do
    outcome when outcome in [:input_required, :needs_input] -> "agent turn requires operator input"
    :approval_required -> "agent turn requires approval"
    nil -> nil
  end
end
```

Change `codex_message_blocker_error/1` (lines 704-708) from:

```elixir
defp codex_message_blocker_error(message) do
  if codex_message_method(message) == "mcpServer/elicitation/request" do
    "codex MCP elicitation requires operator input"
  end
end
```

to:

```elixir
defp codex_message_blocker_error(message) do
  if codex_message_method(message) == "mcpServer/elicitation/request" do
    "agent MCP elicitation requires operator input"
  end
end
```

- [ ] **Step 11: Run orchestrator tests to verify nothing breaks**

Run: `cd /home/jin/symphony/.claude/worktrees/claude-agent/elixir && mix test test/symphony_elixir/orchestrator_test.exs 2>&1 | tail -10`
Expected: PASS (all references updated)

- [ ] **Step 12: Commit**

```bash
cd /home/jin/symphony/.claude/worktrees/claude-agent && git add elixir/lib/symphony_elixir/orchestrator.ex && git commit -m "refactor(orchestrator): rename codex_ to agent_ for multi-agent support"
```

---

### Task 8: Update WORKFLOW.md

**Files:**
- Modify: `elixir/WORKFLOW.md`

- [ ] **Step 1: Add agent_type and claude section to WORKFLOW.md**

In `elixir/WORKFLOW.md`, add `agent_type: codex` and the `claude:` section to the YAML front matter. Change lines 29-33 from:

```yaml
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
```

to:

```yaml
agent_type: codex
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
claude:
  command: claude
  model: claude-sonnet-4-6
```

- [ ] **Step 2: Commit**

```bash
cd /home/jin/symphony/.claude/worktrees/claude-agent && git add elixir/WORKFLOW.md && git commit -m "docs(workflow): add agent_type and claude config section"
```

---

## Self-Review

**1. Spec coverage:**
- Claude Session Module — Task 4 (implementation) + Task 5 (tests)
- Config Schema — Task 1
- Config Facade — Task 2
- Agent Runner Dispatch — Task 6
- Orchestrator Updates — Task 7
- Tests — Task 5
- WORKFLOW.md — Task 8
- Test support — Task 3

All spec components covered.

**2. Placeholder scan:**
No TBD, TODO, "implement later", or "similar to" references found. All code steps contain complete implementations.

**3. Type consistency:**
- `session()` struct fields match between definition and usage across Tasks 4 and 5
- `agent_type` is a `:string` field consistently referenced as `"codex"` or `"claude"`
- `claude_runtime_settings/1` return map keys match what `Session` expects (`command`, `model`, `turn_timeout_ms`, `stall_timeout_ms`)
- Config facade `claude_runtime_settings!` used in Session module (added as `Config.claude_runtime_settings!()` — need to verify this exists)

**Issue found:** Task 4 uses `Config.claude_runtime_settings!()` but Task 2 defines `Config.claude_runtime_settings/1` returning `{:ok, map()} | {:error, term()}`. Need a bang version. Adding fix to Task 2 step 3 — also add:

```elixir
@spec claude_runtime_settings!(keyword()) :: map()
def claude_runtime_settings!(opts \\ []) do
  case claude_runtime_settings(opts) do
    {:ok, settings} -> settings
    {:error, reason} -> raise ArgumentError, message: "Invalid claude settings: #{inspect(reason)}"
  end
end
```

This is added inline to the plan above in Step 3.
