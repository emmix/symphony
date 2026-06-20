defmodule SymphonyElixir.Accounts.User do
  @moduledoc """
  User struct with Ecto embedded schema for validation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: String.t(),
          email: String.t(),
          password_hash: String.t()
        }

  @primary_key {:id, :binary_id, autogenerate: false}
  embedded_schema do
    field(:email, :string)
    field(:password_hash, :string)
    field(:password, :string, virtual: true)
  end

  @spec registration_changeset(t(), map()) :: Ecto.Changeset.t()
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password])
    |> validate_required([:email, :password])
    |> validate_format(:email, ~r/^[^\\s]+@[^\\s]+$/, message: "must be a valid email")
    |> validate_length(:password, min: 6, message: "must be at least 6 characters")
  end
end
