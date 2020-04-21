defmodule Membrane.RTCP.ParsingTest do
  use ExUnit.Case

  alias Membrane.RTCP
  alias Membrane.RTP.SamplePacket

  @sample_ssrc 1_374_823_241

  test "parses compound packets" do
    packet = SamplePacket.sample_rtcp_packet()
    assert {:ok, %RTCP.CompoundPacket{packets: packets}} = RTCP.CompoundPacket.parse(packet)

    assert %RTCP.SenderReportPacket{reports: [], sender_info: %{}, ssrc: @sample_ssrc} =
             hd(packets)

    assert %RTCP.ByePacket{ssrcs: [@sample_ssrc]} = Enum.at(packets, 1)
  end

  test "parsed packets are equal to constructed packets" do
    packet = SamplePacket.sample_rtcp_packet()
    assert {:ok, packets} = RTCP.CompoundPacket.parse(packet)
    regenerated_packet = RTCP.CompoundPacket.to_binary(packets)

    <<head::binary-size(12), ref_ntp_lsw::32, tail::binary>> = packet

    assert <<^head::binary-size(12), ntp_lsw::32, ^tail::binary>> = regenerated_packet

    # The least significant word of NTP timestamp (fractional part) might differ due to rounding errors
    assert_in_delta ntp_lsw, ref_ntp_lsw, 10
  end
end
