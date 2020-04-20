defmodule Membrane.RTCP.ParsingTest do
  use ExUnit.Case

  alias Membrane.RTCP
  alias Membrane.RTP.SamplePacket

  @sample_ssrc 1_374_823_241

  test "parses compound packets" do
    packet = SamplePacket.sample_rtcp_packet()
    assert {:ok, packets} = RTCP.CompoundPacket.parse(packet)

    assert %RTCP.SenderReportPacket{reports: [], sender_info: %{}, ssrc: @sample_ssrc} =
             hd(packets)

    assert %RTCP.ByePacket{ssrcs: [@sample_ssrc]} = Enum.at(packets, 1)
  end

  test "parsed packets are equal to constructed packets" do
    packet = SamplePacket.sample_rtcp_packet()
    assert {:ok, packets} = RTCP.CompoundPacket.parse(packet)
    assert RTCP.CompoundPacket.to_binary(packets) == packet
  end
end
