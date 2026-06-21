defmodule SymphonyElixir.Plane.Client do
  @moduledoc """
  Thin Plane REST client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @issue_page_size 50
  @max_error_body_log_bytes 1_000

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_plane_api_token}

      is_nil(tracker.host) ->
        {:error, :missing_plane_host}

      is_nil(tracker.workspace_slug) ->
        {:error, :missing_plane_workspace_slug}

      is_nil(tracker.project_id) ->
        {:error, :missing_plane_project_id}

      true ->
        with {:ok, project_identifier} <- fetch_project_identifier(tracker),
             {:ok, state_map} <- fetch_state_map(tracker),
             {:ok, label_map} <- fetch_label_map(tracker),
             active_state_ids <- state_names_to_ids(tracker.active_states, state_map),
             _assignee_filter <- routing_assignee_filter() do
          do_fetch_by_states(tracker, active_state_ids, project_identifier, state_map, label_map, nil, [])
        end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker

      cond do
        is_nil(tracker.api_key) ->
          {:error, :missing_plane_api_token}

        is_nil(tracker.host) ->
          {:error, :missing_plane_host}

        is_nil(tracker.workspace_slug) ->
          {:error, :missing_plane_workspace_slug}

        is_nil(tracker.project_id) ->
          {:error, :missing_plane_project_id}

        true ->
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          with {:ok, project_identifier} <- fetch_project_identifier(tracker),
               {:ok, state_map} <- fetch_state_map(tracker),
               {:ok, label_map} <- fetch_label_map(tracker),
               state_ids <- state_names_to_ids(normalized_states, state_map) do
            do_fetch_by_states(tracker, state_ids, project_identifier, state_map, label_map, nil, [])
          end
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        tracker = Config.settings!().tracker

        with {:ok, project_identifier} <- fetch_project_identifier(tracker),
             {:ok, state_map} <- fetch_state_map(tracker),
             {:ok, label_map} <- fetch_label_map(tracker) do
          do_fetch_issue_states(tracker, ids, project_identifier, state_map, label_map)
        end
    end
  end

  @spec api_request(atom(), String.t(), map() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def api_request(method, path, body \\ nil, query \\ [])
      when is_atom(method) and is_binary(path) and is_list(query) do
    tracker = Config.settings!().tracker
    url = build_url(tracker, path)

    headers = [
      {"x-api-key", tracker.api_key},
      {"Content-Type", "application/json"}
    ]

    request_fun = Application.get_env(:symphony_elixir, :plane_request_fun, &do_request/1)

    req = %{
      method: method,
      url: url,
      headers: headers,
      body: body,
      query: query,
      timeout: tracker.request_timeout_ms
    }

    case request_fun.(req) do
      {:ok, %{status: 200, body: resp_body}} when is_map(resp_body) ->
        {:ok, resp_body}

      {:ok, %{status: status, body: resp_body}} ->
        Logger.error("Plane API request failed status=#{status}" <> plane_error_context(req, resp_body))
        {:error, {:plane_api_status, status}}

      {:error, reason} ->
        Logger.error("Plane API request failed: #{inspect(reason)}")
        {:error, {:plane_api_request, reason}}
    end
  end

  defp do_request(%{method: method, url: url, headers: headers, body: body, query: query, timeout: timeout}) do
    opts = [
      headers: headers,
      connect_options: [timeout: timeout],
      receive_timeout: timeout
    ]

    opts =
      case body do
        nil -> opts
        map -> Keyword.put(opts, :json, map)
      end

    opts =
      case query do
        [] -> opts
        _ -> Keyword.put(opts, :params, query)
      end

    Req.request([method: method, url: url] ++ opts)
  end

  defp build_url(tracker, path) do
    host = String.trim_trailing(tracker.host, "/")
    "#{host}/api/v1/workspaces/#{tracker.workspace_slug}/projects/#{tracker.project_id}/#{path}"
  end

  defp fetch_project_identifier(tracker) do
    host = String.trim_trailing(tracker.host, "/")
    url = "#{host}/api/v1/workspaces/#{tracker.workspace_slug}/projects/#{tracker.project_id}/"

    headers = [
      {"x-api-key", tracker.api_key},
      {"Content-Type", "application/json"}
    ]

    request_fun = Application.get_env(:symphony_elixir, :plane_request_fun, &do_request/1)

    req = %{
      method: :get,
      url: url,
      headers: headers,
      body: nil,
      query: [],
      timeout: tracker.request_timeout_ms
    }

    case request_fun.(req) do
      {:ok, %{status: 200, body: %{"identifier" => identifier}}} when is_binary(identifier) ->
        {:ok, identifier}

      {:ok, %{status: 200, body: _}} ->
        {:ok, "PLANE"}

      {:ok, %{status: status}} ->
        {:error, {:plane_api_status, status}}

      {:error, reason} ->
        {:error, {:plane_api_request, reason}}
    end
  end

  defp fetch_state_map(_tracker) do
    case api_request(:get, "states/", nil, []) do
      {:ok, %{"results" => results}} when is_list(results) ->
        state_map =
          results
          |> Enum.filter(&is_map/1)
          |> Enum.into(%{}, fn state ->
            {state["id"], state["name"] || ""}
          end)

        {:ok, state_map}

      {:ok, _} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_label_map(_tracker) do
    case api_request(:get, "labels/", nil, []) do
      {:ok, %{"results" => results}} when is_list(results) ->
        label_map =
          results
          |> Enum.filter(&is_map/1)
          |> Enum.into(%{}, fn label ->
            {label["id"], label["name"] || ""}
          end)

        {:ok, label_map}

      {:ok, _} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp state_names_to_ids(state_names, state_map) do
    name_to_id =
      state_map
      |> Enum.into(%{}, fn {id, name} ->
        {String.downcase(String.trim(name)), id}
      end)

    state_names
    |> Enum.map(&String.downcase(String.trim(to_string(&1))))
    |> Enum.flat_map(fn name ->
      case Map.get(name_to_id, name) do
        nil -> []
        id -> [id]
      end
    end)
    |> Enum.uniq()
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp do_fetch_by_states(tracker, state_ids, project_identifier, state_map, label_map, cursor, acc_issues) do
    query =
      case cursor do
        nil -> [page_size: @issue_page_size]
        c -> [page_size: @issue_page_size, cursor: c]
      end

    query =
      case state_ids do
        [] -> query
        _ -> Keyword.put(query, :state, Enum.join(state_ids, ","))
      end

    case api_request(:get, "issues/", nil, query) do
      {:ok, %{"results" => results, "next_page_results" => next_page?, "next_cursor" => next_cursor}}
      when is_list(results) ->
        issues =
          results
          |> Enum.map(&normalize_issue(&1, project_identifier, state_map, label_map))
          |> Enum.reject(&is_nil/1)

        updated_acc = prepend_page_issues(issues, acc_issues)

        if next_page? == true and is_binary(next_cursor) and byte_size(next_cursor) > 0 do
          do_fetch_by_states(tracker, state_ids, project_identifier, state_map, label_map, next_cursor, updated_acc)
        else
          {:ok, finalize_paginated_issues(updated_acc)}
        end

      {:ok, %{"results" => results, "next_page_results" => next_page?}}
      when is_list(results) ->
        issues =
          results
          |> Enum.map(&normalize_issue(&1, project_identifier, state_map, label_map))
          |> Enum.reject(&is_nil/1)

        updated_acc = prepend_page_issues(issues, acc_issues)

        if next_page? == true do
          # If no next_cursor was provided in the response, we cannot advance
          # pagination. Re-fetching with the same cursor would produce duplicates,
          # so stop and return what we have.
          {:ok, finalize_paginated_issues(updated_acc)}
        else
          {:ok, finalize_paginated_issues(updated_acc)}
        end

      {:ok, %{"results" => results}} when is_list(results) ->
        issues =
          results
          |> Enum.map(&normalize_issue(&1, project_identifier, state_map, label_map))
          |> Enum.reject(&is_nil/1)

        {:ok, finalize_paginated_issues(prepend_page_issues(issues, acc_issues))}

      {:ok, _} ->
        {:error, :plane_unknown_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_fetch_issue_states(tracker, issue_ids, project_identifier, state_map, label_map) do
    issue_order_index = issue_order_index(issue_ids)
    do_fetch_issue_states_page(tracker, issue_ids, project_identifier, state_map, label_map, [], issue_order_index)
  end

  defp do_fetch_issue_states_page(_tracker, [], _project_identifier, _state_map, _label_map, acc_issues, issue_order_index) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(tracker, issue_ids, project_identifier, state_map, label_map, acc_issues, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(issue_ids, @issue_page_size)

    issues =
      batch_ids
      |> Enum.flat_map(fn issue_id ->
        case api_request(:get, "issues/#{issue_id}/") do
          {:ok, %{} = issue_data} ->
            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
            case normalize_issue(issue_data, project_identifier, state_map, label_map) do
              nil -> []
              issue -> [issue]
            end

          _ ->
            []
        end
      end)

    updated_acc = prepend_page_issues(issues, acc_issues)

    do_fetch_issue_states_page(
      tracker,
      rest_ids,
      project_identifier,
      state_map,
      label_map,
      updated_acc,
      issue_order_index
    )
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues) do
    acc_issues
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.id)
  end

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp normalize_issue(issue, project_identifier, state_map, label_map) when is_map(issue) do
    state_uuid = issue["state"]
    state_name = Map.get(state_map, state_uuid, state_uuid || "")

    label_names =
      (issue["labels"] || [])
      |> Enum.flat_map(fn
        label_uuid when is_binary(label_uuid) ->
          case Map.get(label_map, label_uuid) do
            nil -> []
            name -> [String.downcase(String.trim(name))]
          end

        %{"name" => name} when is_binary(name) ->
          [String.downcase(String.trim(name))]

        _ ->
          []
      end)
      |> Enum.uniq()

    assignees = issue["assignees"] || []
    first_assignee = List.first(assignees)

    sequence_id = issue["sequence_id"]
    identifier = if sequence_id, do: "#{project_identifier}-#{sequence_id}", else: nil

    workspace_slug = Config.settings!().tracker.workspace_slug
    project_id = Config.settings!().tracker.project_id
    host = (Config.settings!().tracker.host || "") |> String.trim_trailing("/")

    url =
      if identifier && workspace_slug && project_id do
        "#{host}/#{workspace_slug}/projects/#{project_id}/issues/#{identifier}"
      else
        nil
      end

    %Issue{
      id: issue["id"],
      identifier: identifier,
      title: issue["name"],
      description: strip_html(issue["description_html"]),
      priority: parse_priority(issue["priority"]),
      state: state_name,
      branch_name: nil,
      url: url,
      assignee_id: first_assignee,
      blocked_by: [],
      labels: label_names,
      assigned_to_worker: true,
      created_at: parse_datetime(issue["created_at"]),
      updated_at: parse_datetime(issue["updated_at"])
    }
  end

  defp normalize_issue(_issue, _project_identifier, _state_map, _label_map), do: nil

  defp strip_html(nil), do: nil

  defp strip_html(html) when is_binary(html) do
    html
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp parse_priority("urgent"), do: 1
  defp parse_priority("high"), do: 2
  defp parse_priority("medium"), do: 3
  defp parse_priority("low"), do: 4
  defp parse_priority("none"), do: nil
  defp parse_priority(priority) when is_binary(priority), do: nil
  defp parse_priority(_), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil -> {:ok, nil}
      _assignee -> {:ok, nil}
    end
  end

  defp plane_error_context(_req, resp_body) when is_map(resp_body) do
    body =
      resp_body
      |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)

    " body=" <> body
  end

  defp plane_error_context(_req, resp_body) when is_binary(resp_body) do
    body =
      resp_body
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> String.slice(0, @max_error_body_log_bytes)
      |> inspect()

    " body=" <> body
  end

  defp plane_error_context(_req, _resp_body), do: ""

  @doc false
  @spec normalize_issue_for_test(term(), String.t(), map(), map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue, project_identifier, state_map, label_map)
      when is_map(issue) and is_binary(project_identifier) and is_map(state_map) and
             is_map(label_map) do
    normalize_issue(issue, project_identifier, state_map, label_map)
  end

  def normalize_issue_for_test(_issue, _project_identifier, _state_map, _label_map), do: nil
end
