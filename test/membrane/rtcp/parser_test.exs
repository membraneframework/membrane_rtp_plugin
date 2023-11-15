defmodule Membrane.RTCP.ParserTest do
  use ExUnit.Case, async: true

  alias Membrane.RTCP.{FeedbackPacket, Fixtures, Parser, SenderReportPacket}
  alias Membrane.{Buffer, RTCPEvent}

  test "Handles SR with REMB" do
    buffer = %Buffer{payload: Fixtures.compound_sr_sdes_remb(), metadata: %{arrival_ts: 2137}}
    state = %{}
    assert {events, ^state} = Parser.handle_buffer(:input, buffer, %{}, state)
    assert [event: {:output, %RTCPEvent{} = rtcp_event}] = events
    assert rtcp_event.arrival_timestamp == 2137
    assert %SenderReportPacket{} = rtcp_event.rtcp
  end

  test "Handles PLI" do
    buffer = %Buffer{payload: Fixtures.pli_packet(), metadata: %{arrival_ts: 2137}}
    state = %{}
    assert {events, ^state} = Parser.handle_buffer(:input, buffer, %{}, state)
    assert [event: {:output, %RTCPEvent{} = rtcp_event}] = events
    assert rtcp_event.arrival_timestamp == 2137
    assert %{rtcp: %FeedbackPacket{} = feedback} = rtcp_event

    fixture_contents = Fixtures.pli_contents()
    assert feedback.target_ssrc == fixture_contents.target_ssrc
    assert feedback.origin_ssrc == fixture_contents.origin_ssrc
    assert feedback.payload == %FeedbackPacket.PLI{}
  end
end
