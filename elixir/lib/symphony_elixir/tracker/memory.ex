defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Issue

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    {:ok, issue_entries()}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    comment_id = generate_id()
    comment = %{id: comment_id, comment_html: body, created_at: now_iso(), updated_at: now_iso(), resolved: false}
    existing = get_comments(issue_id)
    store_all_comments(issue_id, existing ++ [comment])
    send_event({:memory_tracker_comment, issue_id, body})
    :ok
  end

  @spec list_comments(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_comments(issue_id) do
    {:ok, get_comments(issue_id)}
  end

  @spec update_comment(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def update_comment(issue_id, comment_id, body) do
    comments = get_comments(issue_id)

    case Enum.find_index(comments, fn c -> c.id == comment_id end) do
      nil ->
        {:error, :comment_not_found}

      idx ->
        updated = %{Enum.at(comments, idx) | comment_html: body, updated_at: now_iso()}
        store_all_comments(issue_id, List.replace_at(comments, idx, updated))
        send_event({:memory_tracker_comment_update, issue_id, comment_id, body})
        :ok
    end
  end

  @spec delete_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_comment(issue_id, comment_id) do
    comments = get_comments(issue_id)
    filtered = Enum.reject(comments, fn c -> c.id == comment_id end)
    store_all_comments(issue_id, filtered)
    send_event({:memory_tracker_comment_delete, issue_id, comment_id})
    :ok
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    send_event({:memory_tracker_state_update, issue_id, state_name})
    :ok
  end

  @doc """
  Resets all stored comments. Call in test setup.
  """
  @spec reset_comments() :: :ok
  def reset_comments do
    Process.delete({__MODULE__, :comments})
    :ok
  end

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp get_comments(issue_id) do
    Process.get({__MODULE__, :comments}, %{})
    |> Map.get(issue_id, [])
  end

  defp store_all_comments(issue_id, comments) do
    all = Process.get({__MODULE__, :comments}, %{})
    Process.put({__MODULE__, :comments}, Map.put(all, issue_id, comments))
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp now_iso do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
