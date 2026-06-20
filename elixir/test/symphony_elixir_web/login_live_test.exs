defmodule SymphonyElixirWeb.LoginLiveTest do
  use ExUnit.Case

  test "LoginLive module is compiled and exported" do
    assert Code.ensure_loaded?(SymphonyElixirWeb.LoginLive)
    assert function_exported?(SymphonyElixirWeb.LoginLive, :mount, 3)
    assert function_exported?(SymphonyElixirWeb.LoginLive, :render, 1)
  end
end
