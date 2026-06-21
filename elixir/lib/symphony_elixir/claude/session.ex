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
        _issue,
        opts \\ []
      ) do
    runtime = Config.claude_runtime_settings!()
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
    turn_timeout_ms = Keyword.get(opts, :turn_timeout_ms, runtime.turn_timeout_ms)
    stall_timeout_ms = Keyword.get(opts, :stall_timeout_ms, runtime.stall_timeout_ms)

    with {:ok, port} <- start_resume_port(workspace, worker_host, runtime, session_id, prompt, model) do
      try do
        emit_message(on_message, :session_started, %{
          session_id: session_id
        })

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

  defp start_resume_port(_workspace, worker_host, _runtime, _session_id, _prompt, _model)
       when is_binary(worker_host) do
    {:error, :remote_claude_resume_not_supported}
  end

  defp build_init_command(runtime) do
    parts = ["exec #{shell_escape(runtime.command)}"]
    parts = if runtime.model, do: parts ++ ["--model", shell_escape(runtime.model)], else: parts
    parts = parts ++ ["-p", shell_escape("You are an autonomous coding agent. Await task instructions."), "--output-format", "stream-json", "--verbose", "--dangerously-skip-permissions"]
    Enum.join(parts, " ")
  end

  defp build_resume_command(runtime, session_id, prompt, model) do
    resolved_model = model || runtime.model
    parts = ["exec #{shell_escape(runtime.command)}"]
    parts = if resolved_model, do: parts ++ ["--model", shell_escape(resolved_model)], else: parts
    parts = parts ++ ["--resume", shell_escape(session_id), "-p", shell_escape(prompt), "--output-format", "stream-json", "--verbose", "--dangerously-skip-permissions"]
    Enum.join(parts, " ")
  end

  defp await_session_init(port) do
    await_session_init(port, "")
  end

  defp await_session_init(port, buffer) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        full_line = buffer <> line

        case parse_json_line(full_line) do
          %{"type" => "system", "subtype" => "init", "session_id" => session_id} = event ->
            model = Map.get(event, "model")
            {:ok, %{session_id: session_id, model: model}}

          _ ->
            await_session_init(port, "")
        end

      {^port, {:data, {:noeol, partial}}} ->
        await_session_init(port, buffer <> partial)

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
    await_turn_loop(port, on_message, nil, cutoff, stall_timeout_ms, "")
  end

  defp await_turn_loop(port, on_message, last_activity, cutoff, stall_timeout_ms, buffer) do
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
          await_turn_loop(port, on_message, last_activity, cutoff, stall_timeout_ms, buffer)
      end
    else
      receive do
        {^port, {:data, {:eol, line}}} ->
          full_line = buffer <> line
          handle_stream_line(full_line, port, on_message, cutoff, stall_timeout_ms)

        {^port, {:data, {:noeol, partial}}} ->
          await_turn_loop(port, on_message, now, cutoff, stall_timeout_ms, buffer <> partial)

        {^port, {:exit_status, 0}} ->
          if buffer != "" do
            handle_stream_line(buffer, port, on_message, cutoff, stall_timeout_ms)
          else
            {:ok, %{}}
          end

        {^port, {:exit_status, status}} ->
          {:error, {:cli_exit_with_status, status}}
      after
        timeout ->
          now2 = System.monotonic_time(:millisecond)

          cond do
            now2 >= cutoff -> {:error, :turn_timeout}
            is_integer(stall_deadline) and now2 >= stall_deadline -> {:error, :turn_stalled}
            true -> await_turn_loop(port, on_message, last_activity, cutoff, stall_timeout_ms, buffer)
          end
      end
    end
  end

  defp handle_stream_line(line, port, on_message, cutoff, stall_timeout_ms) do
    now = System.monotonic_time(:millisecond)

    case parse_json_line(line) do
      %{"type" => "result", "subtype" => "success", "is_error" => true} = event ->
        message = Map.get(event, "result", Map.get(event, "message", "unknown error"))
        {:error, {:cli_error, message}}

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
        await_turn_loop(port, on_message, now, cutoff, stall_timeout_ms, "")

      %{"type" => "assistant", "subtype" => "tool_use"} = event ->
        tool_name = Map.get(event, "tool_name", "unknown")
        emit_message(on_message, :turn_progress, %{tool_use: tool_name})
        await_turn_loop(port, on_message, now, cutoff, stall_timeout_ms, "")

      _ ->
        await_turn_loop(port, on_message, now, cutoff, stall_timeout_ms, "")
    end
  end

  defp extract_usage(event) do
    usage = Map.get(event, "usage", %{})
    input_tokens = Map.get(usage, "input_tokens", 0)
    output_tokens = Map.get(usage, "output_tokens", 0)

    %{
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: Map.get(usage, "total_tokens", input_tokens + output_tokens),
      duration_ms: Map.get(event, "duration_ms", 0),
      cost_usd: Map.get(event, "total_cost_usd", 0.0)
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
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp stop_port(_port), do: :ok

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
