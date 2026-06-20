defmodule SymphonyElixirWeb.Plugs.RequireAuth do
  @moduledoc """
  Plug that requires an authenticated user session.

  Redirects unauthenticated requests to the login page.
  """

  import Phoenix.Controller
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if get_session(conn, :user_id) do
      conn
    else
      conn
      |> put_flash(:error, "You must be logged in to access this page.")
      |> redirect(to: "/login")
      |> halt()
    end
  end
end

defmodule SymphonyElixirWeb.Plugs.RedirectIfAuthenticated do
  @moduledoc """
  Plug that redirects authenticated users away from auth pages.

  Useful for the login page — sends already-logged-in users to the dashboard.
  """

  import Phoenix.Controller
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if get_session(conn, :user_id) do
      conn
      |> redirect(to: "/")
      |> halt()
    else
      conn
    end
  end
end
