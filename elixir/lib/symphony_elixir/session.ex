defmodule SymphonyElixir.Session do
  @moduledoc """
  Authentication helpers for user login and session management.
  """

  alias SymphonyElixir.Accounts

  @doc """
  Authenticates a user by email and password.

  Returns `{:ok, user}` on success or `{:error, :unauthorized}` on failure.
  """
  @spec authenticate(String.t(), String.t()) :: {:ok, Accounts.user()} | {:error, :unauthorized}
  def authenticate(email, password) when is_binary(email) and is_binary(password) do
    case Accounts.get_user_by_email(email) do
      nil ->
        Bcrypt.no_user_verify()
        {:error, :unauthorized}

      user ->
        if Bcrypt.verify_pass(password, user.password_hash) do
          {:ok, user}
        else
          {:error, :unauthorized}
        end
    end
  end
end
