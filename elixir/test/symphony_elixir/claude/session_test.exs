defmodule SymphonyElixir.Claude.SessionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Claude.Session
  alias SymphonyElixir.Config
  alias SymphonyElixir.Workflow

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

      init_file = Path.join(script_dir, "init.json")
      result_file = Path.join(script_dir, "result.json")
      File.write!(init_file, init_json <> "\n")
      File.write!(result_file, result_json <> "\n")

      escaped_init_file = String.replace(init_file, "'", "'\\''")
      escaped_result_file = String.replace(result_file, "'", "'\\''")

      File.write!(fake_claude, """
      #!/bin/bash
      cat '#{escaped_init_file}'
      cat '#{escaped_result_file}'
      exit 0
      """)

      File.chmod!(fake_claude, 0o755)

      try do
        write_workflow_file!(Workflow.workflow_file_path(), agent_type: "claude", claude_command: fake_claude)

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
        write_workflow_file!(Workflow.workflow_file_path(), agent_type: "claude", claude_command: fake_claude)

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
          duration_ms: 10_000,
          cost_usd: 0.02
        })

      text_file = Path.join(script_dir, "text.json")
      result_file = Path.join(script_dir, "result.json")
      File.write!(text_file, text_json <> "\n")
      File.write!(result_file, result_json <> "\n")

      escaped_text_file = String.replace(text_file, "'", "'\\''")
      escaped_result_file = String.replace(result_file, "'", "'\\''")

      File.write!(fake_claude, """
      #!/bin/bash
      cat '#{escaped_text_file}'
      cat '#{escaped_result_file}'
      exit 0
      """)

      File.chmod!(fake_claude, 0o755)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          agent_type: "claude",
          claude_command: fake_claude,
          claude_turn_timeout_ms: 60_000,
          claude_stall_timeout_ms: 30_000
        )

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

      File.write!(fake_claude, """
      #!/bin/bash
      sleep 300
      """)

      File.chmod!(fake_claude, 0o755)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          agent_type: "claude",
          claude_command: fake_claude,
          claude_turn_timeout_ms: 100,
          claude_stall_timeout_ms: 50
        )

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

      max_turns_file = Path.join(script_dir, "max_turns.json")
      File.write!(max_turns_file, max_turns_json <> "\n")

      escaped_max_turns_file = String.replace(max_turns_file, "'", "'\\''")

      File.write!(fake_claude, """
      #!/bin/bash
      cat '#{escaped_max_turns_file}'
      exit 0
      """)

      File.chmod!(fake_claude, 0o755)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          agent_type: "claude",
          claude_command: fake_claude,
          claude_turn_timeout_ms: 60_000,
          claude_stall_timeout_ms: 30_000
        )

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
