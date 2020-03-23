defmodule Membrane.RTCP.ParsingTest do
  use ExUnit.Case

  alias Membrane.RTCP
  alias Membrane.RTP.SamplePacket

  @sample_ssrc 1_374_823_241

  test "parses compound packets" do
    packet = SamplePacket.sample_rtcp_packet()
    assert {:ok, packets} = RTCP.parse_compound(packet, nil)
    assert %RTCP.Report{reports: [], sender_info: _, ssrc: @sample_ssrc} = hd(packets)
    assert %RTCP.Bye{ssrcs: [@sample_ssrc]} = Enum.at(packets, 1)
  end

  test "parsed packets are equal to constructed packets" do
    packet = SamplePacket.sample_rtcp_packet()
    assert {:ok, packets} = RTCP.parse_compound(packet, nil)
    tb = RTCP.to_binary(packets, nil)
    assert tb == packet
  end
end
