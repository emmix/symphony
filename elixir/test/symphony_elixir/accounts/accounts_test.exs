defmodule SymphonyElixir.AccountsTest do
  use ExUnit.Case

  alias SymphonyElixir.Accounts
  alias SymphonyElixir.Accounts.User

  setup do
    if pid = Process.whereis(Accounts) do
      GenServer.stop(pid, :normal)
    end

    {:ok, _pid} = Accounts.start_link()

    on_exit(fn ->
      if pid = Process.whereis(Accounts) do
        GenServer.stop(pid, :normal)
      end
    end)

    :ok
  end

  describe "register_user/2" do
    test "registers a new user with valid credentials" do
      assert {:ok, %User{} = user} = Accounts.register_user("test@example.com", "secret123")
      assert user.email == "test@example.com"
      assert is_binary(user.password_hash)
      assert is_binary(user.id)
    end

    test "rejects duplicate email" do
      assert {:ok, _} = Accounts.register_user("dup@example.com", "password123")
      assert {:error, changeset} = Accounts.register_user("dup@example.com", "password123")
      assert "already taken" in errors_on(changeset).email
    end

    test "rejects invalid email" do
      assert {:error, changeset} = Accounts.register_user("not-an-email", "password123")
      assert "must be a valid email" in errors_on(changeset).email
    end

    test "rejects short password" do
      assert {:error, changeset} = Accounts.register_user("valid@example.com", "short")
      assert "must be at least 6 characters" in errors_on(changeset).password
    end
  end

  describe "authenticate_user/2" do
    test "authenticates with correct credentials" do
      {:ok, _} = Accounts.register_user("auth@example.com", "password123")
      assert {:ok, %User{email: "auth@example.com"}} = Accounts.authenticate_user("auth@example.com", "password123")
    end

    test "rejects wrong password" do
      {:ok, _} = Accounts.register_user("auth2@example.com", "password123")
      assert {:error, :invalid_credentials} = Accounts.authenticate_user("auth2@example.com", "wrongpass")
    end

    test "rejects unknown email" do
      assert {:error, :invalid_credentials} = Accounts.authenticate_user("nobody@example.com", "password123")
    end

    test "authenticates the default admin user" do
      assert {:ok, %User{email: "admin@symphony.local"}} = Accounts.authenticate_user("admin@symphony.local", "password123")
    end
  end

  describe "get_user/1 and get_user_by_email/1" do
    test "retrieves a user by id" do
      {:ok, user} = Accounts.register_user("lookup@example.com", "password123")
      assert %User{email: "lookup@example.com"} = Accounts.get_user(user.id)
    end

    test "returns nil for unknown id" do
      assert nil == Accounts.get_user(Ecto.UUID.generate())
    end

    test "retrieves a user by email" do
      {:ok, _user} = Accounts.register_user("byemail@example.com", "password123")
      assert %User{email: "byemail@example.com"} = Accounts.get_user_by_email("byemail@example.com")
    end

    test "returns nil for unknown email" do
      assert nil == Accounts.get_user_by_email("unknown@example.com")
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r/%{(\\w+)}/, msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
