defmodule Membrane.RTCP.TransportFeedbackPacket.NACKTest do
  use ExUnit.Case, async: true

  alias Membrane.RTCP.TransportFeedbackPacket.NACK

  @examples %{
    # BLP == 0, only sequence number passed via PID lost
    "pid_only" => {<<2137::16, 0::16>>, [2137]},
    # All bits of BLP set to 1, lost packets from PID to PID+16
    "all lost" => {<<2137::16, 0xFFFF::16>>, 2137..(2137 + 16)//1},
    # Two least significant bits of BLP set to 1, lost packets from PID to PID+2
    "3 consecutive lost" => {<<2137::16, 0::14, 0b11::2>>, 2137..(2137 + 2)//1},
    # PID, PID + 2 and PID + 4 missing
    "3 with step 2 lost" => {<<2137::16, 0::12, 1::1, 0::1, 1::1, 0::1>>, [2137, 2139, 2141]},
    # Two FCI combined to report 18 packets lost
    "18 consecutive" => {<<2137::16, 0xFFFF::16, 2137 + 17::16, 0::16>>, 2137..(2137 + 17)//1}
  }
  describe "decoding NACKs FCI" do
    for name <- Map.keys(@examples) do
      test name do
        {binary, expected_ids} = Map.fetch!(@examples, unquote(name))
        assert {:ok, %NACK{lost_packet_ids: ids}} = NACK.decode(binary)
        assert ids == Enum.to_list(expected_ids)
      end
    end

    test "with rollover" do
      assert {:ok, %NACK{lost_packet_ids: [65535, 0]}} = NACK.decode(<<65535::16, 1::16>>)
    end
  end

  describe "encoding NACKs FCI" do
    for name <- Map.keys(@examples) do
      test name do
        {expected_binary, ids} = Map.fetch!(@examples, unquote(name))
        assert NACK.encode(%NACK{lost_packet_ids: ids}) == expected_binary
      end
    end

    test "with rollover" do
      assert NACK.encode(%NACK{lost_packet_ids: [65535, 0]}) == <<0::16, 0::16, 65535::16, 0::16>>
    end
  end
end
