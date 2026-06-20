defmodule SymphonyElixirWeb.SessionController do
  @moduledoc """
  Controller for session management (login/logout).
  """

  use Phoenix.Controller, formats: [:html]

  import Plug.Conn
  import Phoenix.Controller

  alias SymphonyElixir.Session

  @max_age_default 4 * 60 * 60
  @max_age_remember 30 * 24 * 60 * 60

  @doc """
  Renders the login form.
  """
  @spec new(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def new(conn, _params) do
    error = Phoenix.Flash.get(conn.assigns.flash, :error)
    render(conn, :new, error: error)
  end

  @doc """
  Handles login form submission.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"email" => email, "password" => password, "remember_me" => "true"}) do
    do_login(conn, email, password, true)
  end

  def create(conn, %{"email" => email, "password" => password}) do
    do_login(conn, email, password, false)
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Invalid email or password")
    |> redirect(to: "/login")
  end

  @doc """
  Handles logout.
  """
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> put_flash(:info, "Logged out successfully.")
    |> redirect(to: "/login")
  end

  defp do_login(conn, email, password, remember_me) do
    case Session.authenticate(email, password) do
      {:ok, user} ->
        conn
        |> maybe_remember_me(remember_me, user.id)
        |> put_session(:user_id, user.id)
        |> configure_session(renew: true)
        |> put_flash(:info, "Welcome back!")
        |> redirect(to: "/")

      {:error, :unauthorized} ->
        conn
        |> put_flash(:error, "Invalid email or password")
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: "/login")
    end
  end

  defp maybe_remember_me(conn, true, user_id) do
    conn
    |> put_session(:remember_me, true)
    |> put_session(:user_id, user_id)
    |> configure_session(max_age: @max_age_remember)
  end

  defp maybe_remember_me(conn, false, _user_id) do
    conn
    |> delete_session(:remember_me)
    |> configure_session(max_age: @max_age_default)
  end
end
