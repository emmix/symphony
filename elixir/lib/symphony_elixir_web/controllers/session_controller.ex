defmodule SymphonyElixirWeb.SessionController do
  @moduledoc """
  Controller for session management (login, logout).
  """

  use Phoenix.Controller, formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON]

  alias SymphonyElixir.Accounts
  alias SymphonyElixirWeb.Router.Helpers, as: Routes

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"email" => email, "password" => password} = params) do
    remember_me = params["remember_me"] == "true"

    case Accounts.authenticate_user(email, password) do
      {:ok, user} ->
        conn
        |> put_session(:user_id, user.id)
        |> put_session(:remember_me, remember_me)
        |> configure_session(renew: true)
        |> redirect(to: "/")

      {:error, :invalid_credentials} ->
        conn
        |> put_session(:login_error, "Invalid email or password.")
        |> redirect(to: Routes.login_path(conn, :index))
    end
  end

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    conn
    |> put_session(:login_error, "Invalid email or password.")
    |> redirect(to: Routes.login_path(conn, :index))
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: Routes.login_path(conn, :index))
  end
end
