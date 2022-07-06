defmodule Membrane.RTCP.FeedbackPacket.AFBTest do
  use ExUnit.Case, async: true

  alias Membrane.RTCP.{Packet, FeedbackPacket, SdesPacket, SenderReportPacket}

  # Real, compound, RTCP packet from browser containing SR, Sdes & REMB
  @remb_rtcp_packet <<128, 200, 0, 6, 120, 61, 239, 185, 230, 110, 197, 157, 82, 42, 144, 205,
                      172, 85, 146, 216, 0, 0, 3, 121, 0, 14, 109, 134, 129, 202, 0, 6, 120, 61,
                      239, 185, 1, 16, 116, 79, 97, 68, 55, 57, 102, 72, 120, 105, 119, 102, 110,
                      56, 120, 85, 0, 0, 143, 206, 0, 5, 120, 61, 239, 185, 0, 0, 0, 0, 82, 69,
                      77, 66, 1, 15, 36, 147, 224, 97, 78, 29>>

  test "AFB Packet can be parsed" do
    assert {:ok, [%SenderReportPacket{}, %SdesPacket{}, %FeedbackPacket{payload: fb_payload}]} =
             Packet.parse(@remb_rtcp_packet)

    assert %FeedbackPacket.AFB{message: binary} = fb_payload
    assert "REMB" <> _rest = binary
  end
end
