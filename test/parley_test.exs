defmodule ParleyTest do
  use ExUnit.Case
  doctest Parley

  test "greets the world" do
    assert Parley.hello() == :world
  end
end
