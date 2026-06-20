defmodule SymphonyElixirWeb.Plugs.RequireAuth do
  @moduledoc """
  Plug that requires an authenticated user. Redirects to login if absent.
  """

  import Plug.Conn

  alias SymphonyElixirWeb.Router.Helpers, as: Routes

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> Phoenix.Controller.redirect(to: Routes.login_path(conn, :index))
      |> halt()
    end
  end
end
