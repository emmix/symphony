defmodule SymphonyElixir.Plane.ClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Plane.Client

  describe "normalize_issue/4" do
    test "maps Plane JSON fields to Issue struct" do
      plane_issue = %{
        "id" => "uuid-123",
        "name" => "Fix login bug",
        "description_html" => "<p>Login crashes on Firefox</p>",
        "priority" => "high",
        "state" => "state-uuid-todo",
        "sequence_id" => 42,
        "assignees" => ["user-uuid-1"],
        "labels" => ["label-uuid-bug"],
        "created_at" => "2026-06-20T07:00:00.000000Z",
        "updated_at" => "2026-06-20T08:00:00.000000Z",
        "project" => "proj-uuid"
      }

      state_map = %{"state-uuid-todo" => "Todo"}
      label_map = %{"label-uuid-bug" => "bug"}
      project_identifier = "DEV"

      issue = Client.normalize_issue_for_test(plane_issue, project_identifier, state_map, label_map)

      assert %Issue{} = issue
      assert issue.id == "uuid-123"
      assert issue.identifier == "DEV-42"
      assert issue.title == "Fix login bug"
      assert issue.description == "Login crashes on Firefox"
      assert issue.priority == 2
      assert issue.state == "Todo"
      assert issue.labels == ["bug"]
      assert issue.assignee_id == "user-uuid-1"
      assert issue.branch_name == nil
      assert issue.blocked_by == []
      assert issue.assigned_to_worker == true
    end

    test "handles missing optional fields" do
      plane_issue = %{
        "id" => "uuid-456",
        "name" => "No details",
        "description_html" => nil,
        "priority" => "none",
        "state" => nil,
        "sequence_id" => 7,
        "assignees" => [],
        "labels" => [],
        "created_at" => nil,
        "updated_at" => nil
      }

      issue = Client.normalize_issue_for_test(plane_issue, "PROJ", %{}, %{})

      assert issue.id == "uuid-456"
      assert issue.identifier == "PROJ-7"
      assert issue.description == nil
      assert issue.priority == nil
      assert issue.state == ""
      assert issue.labels == []
      assert issue.assignee_id == nil
    end

    test "priority enum mapping" do
      base = fn p ->
        Client.normalize_issue_for_test(
          %{"id" => "x", "name" => "t", "priority" => p, "sequence_id" => 1},
          "P",
          %{},
          %{}
        ).priority
      end

      assert base.("urgent") == 1
      assert base.("high") == 2
      assert base.("medium") == 3
      assert base.("low") == 4
      assert base.("none") == nil
      assert base.("unknown") == nil
    end

    test "strips HTML from description_html" do
      plane_issue = %{
        "id" => "uuid",
        "name" => "t",
        "description_html" => "<h1>Title</h1><p>Body &amp; more</p>",
        "priority" => "none",
        "sequence_id" => 1
      }

      issue = Client.normalize_issue_for_test(plane_issue, "P", %{}, %{})
      assert issue.description == "TitleBody & more"
    end

    test "label resolution from label_map" do
      plane_issue = %{
        "id" => "uuid",
        "name" => "t",
        "priority" => "none",
        "sequence_id" => 1,
        "labels" => ["uuid-a", "uuid-b", "uuid-unknown"]
      }

      label_map = %{"uuid-a" => "Feature", "uuid-b" => "  HIGH PRIORITY  "}
      issue = Client.normalize_issue_for_test(plane_issue, "P", %{}, label_map)
      assert issue.labels == ["feature", "high priority"]
    end

    test "label detail objects in labels array" do
      plane_issue = %{
        "id" => "uuid",
        "name" => "t",
        "priority" => "none",
        "sequence_id" => 1,
        "labels" => [%{"name" => "Bug"}, %{"name" => "  UI  "}]
      }

      issue = Client.normalize_issue_for_test(plane_issue, "P", %{}, %{})
      assert issue.labels == ["bug", "ui"]
    end

    test "nil issue returns nil" do
      assert Client.normalize_issue_for_test(nil, "P", %{}, %{}) == nil
    end

    test "non-map issue returns nil" do
      assert Client.normalize_issue_for_test("not a map", "P", %{}, %{}) == nil
    end
  end
end
