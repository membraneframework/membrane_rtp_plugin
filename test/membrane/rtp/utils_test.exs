defmodule Membrane.RTP.UtilsTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.Utils

  test "Utils.generate_padding/1" do
    assert <<>> = Utils.generate_padding(0)
    assert <<1>> = Utils.generate_padding(1)
    assert <<0::size(99)-unit(8), 100>> = Utils.generate_padding(100)
    assert <<0::size(254)-unit(8), 255>> = Utils.generate_padding(255)
    assert_raise FunctionClauseError, fn -> Utils.generate_padding(-1) end
    assert_raise FunctionClauseError, fn -> Utils.generate_padding(256) end
  end
end
