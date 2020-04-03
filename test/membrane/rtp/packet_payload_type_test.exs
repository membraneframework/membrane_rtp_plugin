defmodule Membrane.RTP.Packet.PayloadTypeTest do
  use ExUnit.Case

  alias Membrane.RTP.Packet.PayloadType

  describe "Payload type decoder" do
    test "raises an error when trying to decode non existent payload type" do
      assert_raise FunctionClauseError, fn ->
        PayloadType.get_encoding_name(128)
      end
    end

    # Payload identifiers 96–127 are for dynamic payload types
    test "returns `:dynamic` when in dynamic range" do
      Enum.each(96..127, fn elem ->
        assert PayloadType.get_encoding_name(elem) == :dynamic
      end)
    end

    test "returns atom when in static type range" do
      static_types = [0] ++ Enum.to_list(3..18) ++ [25, 26, 28] ++ Enum.to_list(31..34)

      Enum.each(static_types, fn elem ->
        assert elem
               |> PayloadType.get_encoding_name()
               |> is_atom()
      end)
    end
  end
end
