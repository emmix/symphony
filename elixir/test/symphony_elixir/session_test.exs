defmodule SymphonyElixir.SessionTest do
  use ExUnit.Case

  alias SymphonyElixir.Accounts
  alias SymphonyElixir.Session

  setup do
    unless Process.whereis(Accounts) do
      {:ok, _pid} = Accounts.start_link([])
    end

    :ok
  end

  describe "authenticate/2" do
    test "returns ok with user for correct credentials" do
      assert {:ok, user} = Session.authenticate("admin@symphony.test", "password123")
      assert user.email == "admin@symphony.test"
    end

    test "returns error for wrong password" do
      assert {:error, :unauthorized} = Session.authenticate("admin@symphony.test", "wrong")
    end

    test "returns error for unknown email" do
      assert {:error, :unauthorized} = Session.authenticate("nobody@test.com", "password123")
    end
  end
end
