defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.Config

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback list_comments(String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback update_comment(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback delete_comment(String.t(), String.t()) :: :ok | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    if workpad_body?(body) do
      create_workpad_comment_guarded(issue_id, body)
    else
      adapter().create_comment(issue_id, body)
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec list_comments(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_comments(issue_id) do
    adapter().list_comments(issue_id)
  end

  @spec update_comment(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def update_comment(issue_id, comment_id, body) do
    adapter().update_comment(issue_id, comment_id, body)
  end

  @spec delete_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_comment(issue_id, comment_id) do
    adapter().delete_comment(issue_id, comment_id)
  end

  @workpad_marker "## Codex Workpad"
  @workpad_marker_html "<h2>Codex Workpad</h2>"

  defp workpad_body?(body) when is_binary(body) do
    String.contains?(body, @workpad_marker) or String.contains?(body, @workpad_marker_html)
  end

  defp workpad_body?(_body), do: false

  defp create_workpad_comment_guarded(issue_id, body) do
    case find_workpad_comment(issue_id) do
      {:ok, %{:id => comment_id}} ->
        update_comment(issue_id, comment_id, body)

      {:ok, nil} ->
        adapter().create_comment(issue_id, body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec find_workpad_comment(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def find_workpad_comment(issue_id) do
    case list_workpad_comments(issue_id) do
      {:ok, []} ->
        {:ok, nil}

      {:ok, [workpad]} ->
        {:ok, workpad}

      {:ok, multiple} ->
        {:ok, dedup_workpad_comments(issue_id, multiple)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec list_workpad_comments(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_workpad_comments(issue_id) do
    case list_comments(issue_id) do
      {:ok, comments} ->
        workpads =
          Enum.filter(comments, fn comment ->
            active = not is_map_key(comment, :resolved) or not comment.resolved
            html = Map.get(comment, :comment_html, "")
            is_workpad = String.contains?(html, @workpad_marker) or String.contains?(html, @workpad_marker_html)
            active and is_workpad
          end)

        {:ok, workpads}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dedup_workpad_comments(issue_id, workpads) do
    sorted =
      workpads
      |> Enum.sort_by(fn comment -> Map.get(comment, :updated_at, "") end, :desc)

    [keep | rest] = sorted

    Enum.each(rest, fn comment ->
      comment_id = Map.get(comment, :id)
      if is_binary(comment_id), do: delete_comment(issue_id, comment_id)
    end)

    keep
  end

  @spec create_or_update_workpad(String.t(), String.t()) :: :ok | {:error, term()}
  def create_or_update_workpad(issue_id, body) do
    case find_workpad_comment(issue_id) do
      {:ok, %{:id => comment_id}} ->
        update_comment(issue_id, comment_id, body)

      {:ok, nil} ->
        create_comment(issue_id, body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.Memory
      "plane" -> SymphonyElixir.Plane.Adapter
      _ -> SymphonyElixir.Linear.Adapter
    end
  end
end
