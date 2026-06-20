defmodule SymphonyElixir.Accounts do
  @moduledoc """
  In-memory user store backed by a GenServer.

  Since Symphony does not use a database, this module manages users
  entirely in process memory. Users are seeded on startup.
  """

  use Agent

  @type user :: %{
          id: String.t(),
          email: String.t(),
          password_hash: String.t()
        }

  def start_link(_opts) do
    Agent.start_link(fn -> seed_users() end, name: __MODULE__)
  end

  @spec get_user_by_email(String.t()) :: user() | nil
  def get_user_by_email(email) when is_binary(email) do
    Agent.get(__MODULE__, fn users ->
      Enum.find(users, fn u -> u.email == email end)
    end)
  end

  @spec get_user_by_id(String.t()) :: user() | nil
  def get_user_by_id(id) when is_binary(id) do
    Agent.get(__MODULE__, fn users ->
      Enum.find(users, fn u -> u.id == id end)
    end)
  end

  defp seed_users do
    [
      %{
        id: "user-1",
        email: "admin@symphony.test",
        password_hash: Bcrypt.hash_pwd_salt("password123")
      }
    ]
  end
end
