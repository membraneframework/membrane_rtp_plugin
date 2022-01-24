defmodule Membrane.RTP.TWCCReceiverTest do
  use ExUnit.Case, async: true
  use Bunch

  alias Membrane.RTP.{BufferFactory, Header, TWCCReceiver}

  require Bitwise

  @default_twcc_id 1
  @sequence_number 12_345

  @feedback_packet_count 100
  @max_feedback_packet_count Bitwise.bsl(1, 8) - 1

  @feedback_sender_ssrc 1_234_567_890
  @media_ssrc 9_876_543_210
  @other_media_ssrc 1_111_111_111

  @default_input_pad {Membrane.Pad, :input, @media_ssrc}
  @other_input_pad {Membrane.Pad, :input, @other_media_ssrc}

  setup_all do
    twcc_extension = %Header.Extension{
      identifier: @default_twcc_id,
      data: <<@sequence_number::16>>
    }

    buffer =
      BufferFactory.sample_buffer(10)
      |> Bunch.Struct.put_in([:metadata, :rtp, :extensions], [twcc_extension])

    state = %TWCCReceiver.State{
      twcc_id: @default_twcc_id,
      feedback_sender_ssrc: @feedback_sender_ssrc,
      report_interval: nil,
      feedback_packet_count: @feedback_packet_count
    }

    [state: state, buffer: buffer]
  end

  describe "When a buffer arrives, TWCC element" do
    test "forwards it via the appropriate output pad", %{state: state, buffer: buffer} do
      assert {{:ok, buffer: {out_pad, _buffer}}, _state} =
               TWCCReceiver.handle_process(@default_input_pad, buffer, nil, state)

      assert out_pad == {Membrane.Pad, :output, @media_ssrc}
    end

    test "does not modify anything except its header extension", %{
      state: state,
      buffer: in_buffer
    } do
      assert {{:ok, buffer: {_out_pad, out_buffer}}, _state} =
               TWCCReceiver.handle_process(@default_input_pad, in_buffer, nil, state)

      {_twcc, buffer_without_twcc} = Header.Extension.pop(in_buffer, @default_twcc_id)

      assert buffer_without_twcc == out_buffer
    end

    test "extracts appropriate sequence number", %{state: state, buffer: buffer} do
      assert {{:ok, _buffer_action}, state} =
               TWCCReceiver.handle_process(@default_input_pad, buffer, nil, state)

      assert [@sequence_number] = Map.keys(state.packet_info_store.seq_to_timestamp)
    end
  end

  describe "When generating an RTCP event, TWCC element" do
    test "uses media SSRC of the first input pad that delivered a buffer", %{
      state: state,
      buffer: buffer
    } do
      assert {{:ok, _buffer_action}, state} =
               TWCCReceiver.handle_process(@default_input_pad, buffer, nil, state)

      assert {{:ok, _buffer_action}, state} =
               TWCCReceiver.handle_process(@other_input_pad, buffer, nil, state)

      assert {{:ok, event: {@default_input_pad, event}}, _state} =
               TWCCReceiver.handle_tick(:report_timer, nil, state)

      assert event.rtcp.media_ssrc == @media_ssrc
    end

    test "uses media SSRC of the next input pad if the previous one has been removed",
         %{
           state: state,
           buffer: buffer
         } do
      assert {{:ok, _buffer_action}, state} =
               TWCCReceiver.handle_process(@default_input_pad, buffer, nil, state)

      assert {:ok, state} = TWCCReceiver.handle_pad_removed(@default_input_pad, nil, state)

      assert {{:ok, _buffer_action}, state} =
               TWCCReceiver.handle_process(@other_input_pad, buffer, nil, state)

      assert {{:ok, event: {@other_input_pad, event}}, _state} =
               TWCCReceiver.handle_tick(:report_timer, nil, state)

      assert event.rtcp.media_ssrc == @other_media_ssrc
    end

    test "uses sender SSRC passed in options", %{state: state, buffer: buffer} do
      assert {{:ok, _buffer_action}, state} =
               TWCCReceiver.handle_process(@default_input_pad, buffer, nil, state)

      assert {{:ok, event: {_event_pad, event}}, _state} =
               TWCCReceiver.handle_tick(:report_timer, nil, state)

      assert event.rtcp.sender_ssrc == @feedback_sender_ssrc
    end

    test "increments its feedback packet count", %{state: state, buffer: buffer} do
      assert {{:ok, _buffer_action}, state} =
               TWCCReceiver.handle_process(@default_input_pad, buffer, nil, state)

      assert {{:ok, event: {_event_pad, event}}, state} =
               TWCCReceiver.handle_tick(:report_timer, nil, state)

      assert event.rtcp.payload.feedback_packet_count == @feedback_packet_count

      assert {{:ok, _buffer_action}, state} =
               TWCCReceiver.handle_process(@default_input_pad, buffer, nil, state)

      assert {{:ok, event: {_event_pad, event}}, _state} =
               TWCCReceiver.handle_tick(:report_timer, nil, state)

      assert event.rtcp.payload.feedback_packet_count == @feedback_packet_count + 1
    end
  end

  describe "When feedback packet count reaches its limit, TWCC element" do
    setup %{state: state, buffer: buffer} do
      [
        state: %{state | feedback_packet_count: @max_feedback_packet_count - 1},
        buffer: buffer
      ]
    end

    test "performs a rollover", %{state: state, buffer: in_buffer} do
      assert {{:ok, buffer: _buffer_action}, state} =
               TWCCReceiver.handle_process(@default_input_pad, in_buffer, nil, state)

      assert {{:ok, event: _event_action}, state} =
               TWCCReceiver.handle_tick(:report_timer, nil, state)

      assert state.feedback_packet_count == @max_feedback_packet_count

      assert {{:ok, buffer: _buffer_action}, state} =
               TWCCReceiver.handle_process(@default_input_pad, in_buffer, nil, state)

      assert {{:ok, event: _event_action}, state} =
               TWCCReceiver.handle_tick(:report_timer, nil, state)

      assert state.feedback_packet_count == 0
    end
  end
end
