defmodule Membrane.RTCP.FeedbackPacket.AFBTest do
  use ExUnit.Case, async: true

  alias Membrane.RTCP.{FeedbackPacket, Fixtures, Packet, SdesPacket, SenderReportPacket}

  test "AFB Packet can be parsed" do
    assert {:ok, [%SenderReportPacket{}, %SdesPacket{}, %FeedbackPacket{payload: fb_payload}]} =
             Packet.parse(Fixtures.compound_sr_sdes_remb())

    assert %FeedbackPacket.AFB{message: binary} = fb_payload
    assert "REMB" <> _rest = binary
  end
end
