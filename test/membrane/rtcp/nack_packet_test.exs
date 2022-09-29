defmodule Membrane.RTCP.TransportFeedbackPacket.NACKTest do
  use ExUnit.Case, async: true

  alias Membrane.RTCP.TransportFeedbackPacket.NACK

  @examples %{
    # BLP == 0, only sequence number passed via PID lost
    "one ID lost" => {<<2137::16, 0::16>>, [2137]},
    # All bits of BLP set to 1, lost packets from PID to PID+16
    "17 consecutive IDs lost" => {<<2137::16, 0xFFFF::16>>, 2137..(2137 + 16)//1},
    # Two least significant bits of BLP set to 1, lost packets from PID to PID+2
    "3 consecutive IDs lost" => {<<2137::16, 0::14, 0b11::2>>, 2137..(2137 + 2)//1},
    # PID, PID + 2 and PID + 4 missing
    "3 IDs with step 2 lost" => {<<2137::16, 0::12, 1::1, 0::1, 1::1, 0::1>>, [2137, 2139, 2141]},
    # Two FCIs combined to report 18 packets lost
    "18 consecutive IDs lost" =>
      {<<2137::16, 0xFFFF::16, 2137 + 17::16, 0::16>>, 2137..(2137 + 17)//1}
  }

  describe "NACK.decode/1 decodes" do
    for name <- Map.keys(@examples) do
      test name do
        {binary, expected_ids} = Map.fetch!(@examples, unquote(name))
        assert {:ok, %NACK{lost_packet_ids: ids}} = NACK.decode(binary)
        assert ids == Enum.to_list(expected_ids)
      end
    end

    test "wrapping up ids" do
      assert {:ok, %NACK{lost_packet_ids: ids}} = NACK.decode(<<65_535::16, 0xFFFF::16>>)
      assert ids == [65_535 | Enum.to_list(0..15//1)]
    end
  end

  describe "NACK.encode/1 encodes" do
    for name <- Map.keys(@examples) do
      test name do
        {expected_binary, ids} = Map.fetch!(@examples, unquote(name))
        assert NACK.encode(%NACK{lost_packet_ids: ids}) == expected_binary
      end
    end

    test "wrapping up ids" do
      lost_ids = [65_535 | Enum.to_list(0..15//1)]
      # Current implementation splits ids into two FCIs on sequence number wrap
      # expected_binary = <<0::16, 0b0111::4, 0xFFF::12>> <> <<0xFFFF::16, 0::16>>

      assert {:ok, %NACK{lost_packet_ids: reported_lost}} =
               NACK.encode(%NACK{lost_packet_ids: lost_ids}) |> NACK.decode()

      assert MapSet.equal?(MapSet.new(lost_ids), MapSet.new(reported_lost))
    end
  end
end
