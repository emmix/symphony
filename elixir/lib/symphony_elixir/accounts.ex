defmodule SymphonyElixir.Accounts do
  @moduledoc """
  In-memory user account management.

  Provides user registration, authentication, and lookup. Backed by a
  GenServer-stored map since Symphony does not use a database.
  """

  use GenServer

  alias SymphonyElixir.Accounts.User

  @type authenticate_result :: {:ok, User.t()} | {:error, :invalid_credentials}

  @doc """
  Starts the Accounts GenServer and seeds the default admin user.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a new user with the given email and password.

  Returns `{:ok, user}` on success or `{:error, changeset}` on validation failure.
  """
  @spec register_user(String.t(), String.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register_user(email, password) do
    GenServer.call(__MODULE__, {:register, email, password})
  end

  @doc """
  Authenticates a user by email and password.

  Returns `{:ok, user}` when credentials are valid, or `{:error, :invalid_credentials}`.
  """
  @spec authenticate_user(String.t(), String.t()) :: authenticate_result()
  def authenticate_user(email, password) do
    GenServer.call(__MODULE__, {:authenticate, email, password})
  end

  @doc """
  Retrieves a user by id. Returns `nil` if not found.
  """
  @spec get_user(String.t()) :: User.t() | nil
  def get_user(id) do
    GenServer.call(__MODULE__, {:get, id})
  end

  @doc """
  Retrieves a user by email. Returns `nil` if not found.
  """
  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) do
    GenServer.call(__MODULE__, {:get_by_email, email})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    users = %{}

    {:ok, admin} = build_user("admin@symphony.local", "password123")
    state = Map.put(users, admin.id, admin)
    {:ok, state}
  end

  @impl true
  def handle_call({:register, email, password}, _from, state) do
    existing = Enum.find_value(state, fn {_id, u} -> u.email == email and u end)

    if existing do
      changeset = User.registration_changeset(%User{}, %{email: email, password: password})
      error_changeset = Ecto.Changeset.add_error(changeset, :email, "already taken")
      {:reply, {:error, error_changeset}, state}
    else
      case build_user(email, password) do
        {:ok, user} ->
          {:reply, {:ok, user}, Map.put(state, user.id, user)}

        {:error, changeset} ->
          {:reply, {:error, changeset}, state}
      end
    end
  end

  @impl true
  def handle_call({:authenticate, email, password}, _from, state) do
    user = Enum.find_value(state, fn {_id, u} -> u.email == email and u end)

    cond do
      is_nil(user) ->
        {:reply, {:error, :invalid_credentials}, state}

      Bcrypt.verify_pass(password, user.password_hash) ->
        {:reply, {:ok, user}, state}

      true ->
        {:reply, {:error, :invalid_credentials}, state}
    end
  end

  @impl true
  def handle_call({:get, id}, _from, state) do
    {:reply, Map.get(state, id), state}
  end

  @impl true
  def handle_call({:get_by_email, email}, _from, state) do
    user = Enum.find_value(state, fn {_id, u} -> u.email == email and u end)
    {:reply, user, state}
  end

  defp build_user(email, password) do
    changeset = User.registration_changeset(%User{}, %{email: email, password: password})

    if changeset.valid? do
      password_hash = Bcrypt.hash_pwd_salt(password)
      id = Ecto.UUID.generate()
      user = %User{id: id, email: email, password_hash: password_hash}
      {:ok, user}
    else
      {:error, changeset}
    end
  end
end
