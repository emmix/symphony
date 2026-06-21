defmodule SymphonyElixir.Plane.Adapter do
  @moduledoc """
  Plane-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Plane.Client

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    case client_module().api_request(:post, "issues/#{issue_id}/comments/", %{comment_html: "<p>#{escape_html(body)}</p>"}) do
      {:ok, _response} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec list_comments(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_comments(issue_id) when is_binary(issue_id) do
    case client_module().api_request(:get, "issues/#{issue_id}/comments/") do
      {:ok, %{"results" => results}} when is_list(results) ->
        comments =
          Enum.map(results, fn comment ->
            %{
              id: comment["id"],
              comment_html: comment["comment_html"] || "",
              created_at: comment["created_at"],
              updated_at: comment["updated_at"],
              actor: comment["actor"],
              resolved: not is_nil(comment["deleted_at"])
            }
          end)

        {:ok, comments}

      {:ok, _} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec update_comment(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def update_comment(issue_id, comment_id, body)
      when is_binary(issue_id) and is_binary(comment_id) and is_binary(body) do
    case client_module().api_request(
           :patch,
           "issues/#{issue_id}/comments/#{comment_id}/",
           %{comment_html: "<p>#{escape_html(body)}</p>"}
         ) do
      {:ok, _response} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec delete_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_comment(issue_id, comment_id)
      when is_binary(issue_id) and is_binary(comment_id) do
    case client_module().api_request(:delete, "issues/#{issue_id}/comments/#{comment_id}/") do
      {:ok, _response} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(state_name),
         {:ok, _response} <-
           client_module().api_request(:patch, "issues/#{issue_id}/", %{state: state_id}) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :plane_client_module, Client)
  end

  defp resolve_state_id(state_name) do
    case client_module().api_request(:get, "states/") do
      {:ok, %{"results" => results}} when is_list(results) ->
        normalized = String.downcase(String.trim(state_name))

        # credo:disable-for-next-line Credo.Check.Refactor.Nesting
        case Enum.find(results, fn state ->
               is_map(state) and String.downcase(String.trim(state["name"] || "")) == normalized
             end) do
          %{"id" => id} when is_binary(id) -> {:ok, id}
          _ -> {:error, :state_not_found}
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :state_not_found}
    end
  end

  defp escape_html(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
