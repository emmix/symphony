defmodule SymphonyElixir.AccountsTest do
  use ExUnit.Case

  alias SymphonyElixir.Accounts

  setup do
    unless Process.whereis(Accounts) do
      {:ok, _pid} = Accounts.start_link([])
    end

    :ok
  end

  describe "get_user_by_email/1" do
    test "returns seeded admin user by email" do
      user = Accounts.get_user_by_email("admin@symphony.test")
      assert %{} = user
      assert user.email == "admin@symphony.test"
      assert user.id == "user-1"
    end

    test "returns nil for unknown email" do
      assert Accounts.get_user_by_email("nobody@test.com") == nil
    end
  end

  describe "get_user_by_id/1" do
    test "returns seeded admin user by id" do
      user = Accounts.get_user_by_id("user-1")
      assert %{} = user
      assert user.email == "admin@symphony.test"
    end

    test "returns nil for unknown id" do
      assert Accounts.get_user_by_id("nonexistent") == nil
    end
  end
end
