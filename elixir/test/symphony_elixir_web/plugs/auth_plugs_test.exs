defmodule SymphonyElixirWeb.Plugs.FetchSessionUserTest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn

  alias SymphonyElixir.Accounts
  alias SymphonyElixirWeb.Plugs.FetchSessionUser

  setup do
    case Accounts.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  test "assigns current_user nil when no user_id in session" do
    conn =
      conn(:get, "/")
      |> init_test_session(%{})
      |> FetchSessionUser.call([])

    assert conn.assigns.current_user == nil
  end

  test "assigns current_user when user_id exists in session" do
    {:ok, user} = Accounts.register_user("session@example.com", "password123")

    conn =
      conn(:get, "/")
      |> init_test_session(%{user_id: user.id})
      |> FetchSessionUser.call([])

    assert conn.assigns.current_user.email == "session@example.com"
  end

  test "assigns nil when user_id not found" do
    conn =
      conn(:get, "/")
      |> init_test_session(%{user_id: Ecto.UUID.generate()})
      |> FetchSessionUser.call([])

    assert conn.assigns.current_user == nil
  end
end

defmodule SymphonyElixirWeb.Plugs.RequireAuthTest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn

  alias SymphonyElixirWeb.Plugs.RequireAuth

  test "allows connection when current_user is assigned" do
    conn =
      conn(:get, "/")
      |> assign(:current_user, %{email: "test@example.com"})
      |> RequireAuth.call([])

    refute conn.halted
  end

  test "redirects and halts when current_user is nil" do
    conn =
      conn(:get, "/")
      |> assign(:current_user, nil)
      |> RequireAuth.call([])

    assert conn.halted
    assert conn.status == 302
  end
end
