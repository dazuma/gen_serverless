defmodule GenServerlessTest do
  use ExUnit.Case
  doctest GenServerless

  test "greets the world" do
    assert GenServerless.hello() == :world
  end
end
