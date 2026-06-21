defmodule SymphonyElixir.Tracker.WorkpadTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{Tracker, Workflow}
  alias SymphonyElixir.Tracker.Memory

  setup do
    Memory.reset_comments()

    issue = %Issue{id: "issue-wp-1", identifier: "WP-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Memory.reset_comments()
    end)

    :ok
  end

  describe "find_workpad_comment/1" do
    test "returns nil when no workpad comment exists" do
      assert {:ok, nil} = Tracker.find_workpad_comment("issue-wp-1")
    end

    test "returns the workpad comment when exactly one exists" do
      :ok = Tracker.create_comment("issue-wp-1", "## Codex Workpad\nPlan: do stuff")

      assert {:ok, workpad} = Tracker.find_workpad_comment("issue-wp-1")
      assert String.contains?(workpad.comment_html, "## Codex Workpad")
    end

    test "returns the most recently updated workpad when multiple exist" do
      # Create workpads directly via adapter to bypass the create_comment guard
      :ok = Memory.create_comment("issue-wp-1", "## Codex Workpad\nFirst workpad")

      # Small delay to ensure different timestamps
      Process.sleep(10)
      :ok = Memory.create_comment("issue-wp-1", "## Codex Workpad\nSecond workpad")

      assert {:ok, workpad} = Tracker.find_workpad_comment("issue-wp-1")
      assert String.contains?(workpad.comment_html, "Second workpad")
    end

    test "deduplicates by deleting older workpad comments" do
      # Create multiple workpads directly via adapter to bypass the create_comment guard
      :ok = Memory.create_comment("issue-wp-1", "## Codex Workpad\nFirst workpad")
      Process.sleep(10)
      :ok = Memory.create_comment("issue-wp-1", "## Codex Workpad\nSecond workpad")

      # Call find_workpad_comment which triggers dedup
      assert {:ok, _workpad} = Tracker.find_workpad_comment("issue-wp-1")

      # After dedup, only one workpad comment should remain
      assert {:ok, [remaining]} = Tracker.list_workpad_comments("issue-wp-1")
      assert String.contains?(remaining.comment_html, "Second workpad")
    end

    test "ignores non-workpad comments" do
      :ok = Tracker.create_comment("issue-wp-1", "Just a regular comment")
      :ok = Tracker.create_comment("issue-wp-1", "## Codex Workpad\nThe workpad")

      assert {:ok, workpad} = Tracker.find_workpad_comment("issue-wp-1")
      assert String.contains?(workpad.comment_html, "## Codex Workpad")
    end

    test "ignores resolved workpad comments" do
      :ok = Tracker.create_comment("issue-wp-1", "## Codex Workpad\nOld workpad")

      # Manually mark as resolved
      {:ok, comments} = Memory.list_comments("issue-wp-1")
      old_comment = hd(comments)
      Memory.update_comment("issue-wp-1", old_comment.id, "## Codex Workpad\nOld workpad")

      # Override to mark as resolved
      resolved = %{old_comment | resolved: true}
      Process.put({Memory, :comments}, %{"issue-wp-1" => [resolved]})

      assert {:ok, nil} = Tracker.find_workpad_comment("issue-wp-1")
    end

    test "finds workpad when comment_html contains HTML heading marker" do
      :ok = Tracker.create_comment("issue-wp-1", "<h2>Codex Workpad</h2><p>Plan content</p>")

      assert {:ok, workpad} = Tracker.find_workpad_comment("issue-wp-1")
      assert String.contains?(workpad.comment_html, "Codex Workpad")
    end
  end

  describe "list_workpad_comments/1" do
    test "returns empty list when no comments exist" do
      assert {:ok, []} = Tracker.list_workpad_comments("issue-wp-1")
    end

    test "returns only workpad comments, not regular comments" do
      :ok = Tracker.create_comment("issue-wp-1", "Regular comment")
      :ok = Tracker.create_comment("issue-wp-1", "## Codex Workpad\nThe workpad")
      :ok = Tracker.create_comment("issue-wp-1", "Another regular comment")

      assert {:ok, [workpad]} = Tracker.list_workpad_comments("issue-wp-1")
      assert String.contains?(workpad.comment_html, "## Codex Workpad")
    end

    test "create_comment guard prevents duplicate workpad comments" do
      :ok = Tracker.create_comment("issue-wp-1", "## Codex Workpad\nFirst")
      # Second create_comment with workpad body should update, not create new
      :ok = Tracker.create_comment("issue-wp-1", "## Codex Workpad\nSecond")

      # Only one workpad should exist because the guard auto-deduped
      assert {:ok, workpads} = Tracker.list_workpad_comments("issue-wp-1")
      assert length(workpads) == 1
      assert String.contains?(hd(workpads).comment_html, "Second")
    end
  end

  describe "create_or_update_workpad/2" do
    test "creates a new workpad when none exists" do
      assert :ok = Tracker.create_or_update_workpad("issue-wp-1", "## Codex Workpad\nNew plan")

      assert {:ok, workpad} = Tracker.find_workpad_comment("issue-wp-1")
      assert String.contains?(workpad.comment_html, "New plan")
    end

    test "updates existing workpad instead of creating a new one" do
      :ok = Tracker.create_or_update_workpad("issue-wp-1", "## Codex Workpad\nInitial plan")

      # Should update, not create
      :ok = Tracker.create_or_update_workpad("issue-wp-1", "## Codex Workpad\nUpdated plan")

      # Only one workpad should exist
      assert {:ok, workpad} = Tracker.find_workpad_comment("issue-wp-1")
      assert String.contains?(workpad.comment_html, "Updated plan")

      {:ok, workpads} = Tracker.list_workpad_comments("issue-wp-1")
      assert length(workpads) == 1
    end
  end

  describe "delete_comment/2" do
    test "deletes a specific comment" do
      :ok = Tracker.create_comment("issue-wp-1", "## Codex Workpad\nTo delete")

      {:ok, [comment]} = Tracker.list_comments("issue-wp-1")
      assert :ok = Tracker.delete_comment("issue-wp-1", comment.id)

      {:ok, comments} = Tracker.list_comments("issue-wp-1")
      assert comments == []
    end
  end
end
