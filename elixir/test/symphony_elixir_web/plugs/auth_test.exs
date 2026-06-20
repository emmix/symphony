defmodule SymphonyElixirWeb.Plugs.AuthTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias SymphonyElixirWeb.Plugs.{RequireAuth, RedirectIfAuthenticated}

  describe "RequireAuth" do
    test "passes through when user_id in session" do
      conn =
        conn(:get, "/")
        |> init_test_session(%{user_id: "user-1"})
        |> RequireAuth.call(RequireAuth.init([]))

      refute conn.halted
    end

    test "halts and redirects when no user_id in session" do
      conn =
        conn(:get, "/")
        |> init_test_session(%{})
        |> Phoenix.Controller.fetch_flash()
        |> RequireAuth.call(RequireAuth.init([]))

      assert conn.halted
      assert conn.status == 302
    end
  end

  describe "RedirectIfAuthenticated" do
    test "passes through when no user_id in session" do
      conn =
        conn(:get, "/login")
        |> init_test_session(%{})
        |> RedirectIfAuthenticated.call(RedirectIfAuthenticated.init([]))

      refute conn.halted
    end

    test "halts and redirects when user_id in session" do
      conn =
        conn(:get, "/login")
        |> init_test_session(%{user_id: "user-1"})
        |> RedirectIfAuthenticated.call(RedirectIfAuthenticated.init([]))

      assert conn.halted
      assert conn.status == 302
    end
  end
end
