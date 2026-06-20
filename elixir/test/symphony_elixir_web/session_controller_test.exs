defmodule SymphonyElixirWeb.SessionControllerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.SessionController
  import Plug.Conn
  import Phoenix.ConnTest

  setup do
    endpoint_config =
      Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
      |> Keyword.put(:server, false)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, SymphonyElixirWeb.Endpoint)
    end)

    :ok
  end

  describe "create/2" do
    test "redirects to dashboard on valid credentials" do
      conn =
        Plug.Test.conn(:post, "/login", %{})
        |> Plug.Test.init_test_session(%{})
        |> Phoenix.Controller.fetch_flash()
        |> SessionController.create(%{
          "email" => "admin@symphony.test",
          "password" => "password123"
        })

      assert redirected_to(conn) == "/"
      assert get_session(conn, :user_id) != nil
    end

    test "redirects back to login on invalid credentials" do
      conn =
        Plug.Test.conn(:post, "/login", %{})
        |> Plug.Test.init_test_session(%{})
        |> Phoenix.Controller.fetch_flash()
        |> SessionController.create(%{
          "email" => "admin@symphony.test",
          "password" => "wrong"
        })

      assert redirected_to(conn) == "/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid"
    end

    test "sets remember_me session when checkbox selected" do
      conn =
        Plug.Test.conn(:post, "/login", %{})
        |> Plug.Test.init_test_session(%{})
        |> Phoenix.Controller.fetch_flash()
        |> SessionController.create(%{
          "email" => "admin@symphony.test",
          "password" => "password123",
          "remember_me" => "true"
        })

      assert redirected_to(conn) == "/"
      assert get_session(conn, :remember_me) == true
    end
  end

  describe "delete/2" do
    test "drops session and redirects to login" do
      conn =
        Plug.Test.conn(:delete, "/logout", %{})
        |> Plug.Test.init_test_session(%{user_id: "user-1"})
        |> Phoenix.Controller.fetch_flash()
        |> SessionController.delete(%{})

      assert redirected_to(conn) == "/login"
    end
  end
end
