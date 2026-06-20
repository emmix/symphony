defmodule SymphonyElixirWeb.Plugs.FetchSessionUser do
  @moduledoc """
  Plug that loads the current user from the session into assigns.
  """

  import Plug.Conn

  alias SymphonyElixir.Accounts

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    user_id = get_session(conn, :user_id)

    if user_id do
      user = Accounts.get_user(user_id)
      assign(conn, :current_user, user)
    else
      assign(conn, :current_user, nil)
    end
  end
end
