defmodule Membrane.RTP.TWCCReceiverTest do
  use ExUnit.Case, async: true
  use Bunch

  require Bitwise
  alias Membrane.RTP.{BufferFactory, Header, TWCCReceiver}

  @default_twcc_id 1
  @sequence_number 12_345

  @feedback_packet_count 100
  @max_feedback_packet_count Bitwise.bsl(1, 8) - 1

  @feedback_sender_ssrc 1_234_567_890
  @media_ssrc 9_876_543_210
  @other_media_ssrc 1_111_111_111

  @default_input_pad {Membrane.Pad, :input, @media_ssrc}
  @default_output_pad {Membrane.Pad, :output, @media_ssrc}
  @other_input_pad {Membrane.Pad, :input, @other_media_ssrc}
  @other_output_pad {Membrane.Pad, :output, @other_media_ssrc}

  @ctx %{
    pads: %{
      @default_input_pad => :ok,
      @default_output_pad => :ok,
      @other_input_pad => :ok,
      @other_output_pad => :ok
    }
  }

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
      feedback_packet_count: @feedback_packet_count,
      buffered_actions: %{}
    }

    [state: state, buffer: buffer]
  end

  describe "When a buffer arrives, TWCC element" do
    test "forwards it via the appropriate output pad", %{state: state, buffer: buffer} do
      assert {{:ok, buffer: {out_pad, _buffer}}, _state} =
               TWCCReceiver.handle_process(@default_input_pad, buffer, @ctx, state)

      assert out_pad == {Membrane.Pad, :output, @media_ssrc}
    end

    test "does not modify anything except its header extension", %{
      state: state,
      buffer: in_buffer
    } do
      assert {{:ok, buffer: {_out_pad, out_buffer}}, _state} =
               TWCCReceiver.handle_process(@default_input_pad, in_buffer, @ctx, state)

      {_twcc, buffer_without_twcc} = Header.Extension.pop(in_buffer, @default_twcc_id)

      assert buffer_without_twcc == out_buffer
    end

    test "extracts appropriate sequence number", %{state: state, buffer: buffer} do
      assert {{:ok, _buffer_action}, state} =
               TWCCReceiver.handle_process(@default_input_pad, buffer, @ctx, state)

      assert [@sequence_number] = Map.keys(state.packet_info_store.seq_to_timestamp)
    end
  end

  describe "When generating an RTCP event, TWCC element" do
    test "uses media SSRC of the first input pad that delivered a buffer", %{
      state: state,
      buffer: buffer
    } do
      assert {{:ok, _buffer_action}, state} =
               TWCCReceiver.handle_process(@default_input_pad, buffer, @ctx, state)

      assert {{:ok, _buffer_action}, state} =
               TWCCReceiver.handle_process(@other_input_pad, buffer, @ctx, state)

      assert {{:ok, event: {@default_input_pad, event}}, _state} =
               TWCCReceiver.handle_tick(:report_timer, @ctx, state)

      assert event.rtcp.media_ssrc == @media_ssrc
    end

    test "uses media SSRC of the next input pad if the previous one has been removed",
         %{
           state: state,
           buffer: buffer
         } do
      assert {{:ok, _buffer_action}, state} =
               TWCCReceiver.handle_process(@default_input_pad, buffer, @ctx, state)

      assert {:ok, state} = TWCCReceiver.handle_pad_removed(@default_input_pad, @ctx, state)

      assert {{:ok, _buffer_action}, state} =
               TWCCReceiver.handle_process(@other_input_pad, buffer, @ctx, state)

      assert {{:ok, event: {@other_input_pad, event}}, _state} =
               TWCCReceiver.handle_tick(:report_timer, @ctx, state)

      assert event.rtcp.media_ssrc == @other_media_ssrc
    end

    test "uses sender SSRC passed in options", %{state: state, buffer: buffer} do
      assert {{:ok, _buffer_action}, state} =
               TWCCReceiver.handle_process(@default_input_pad, buffer, @ctx, state)

      assert {{:ok, event: {_event_pad, event}}, _state} =
               TWCCReceiver.handle_tick(:report_timer, @ctx, state)

      assert event.rtcp.sender_ssrc == @feedback_sender_ssrc
    end

    test "increments its feedback packet count", %{state: state, buffer: buffer} do
      assert {{:ok, _buffer_action}, state} =
               TWCCReceiver.handle_process(@default_input_pad, buffer, @ctx, state)

      assert {{:ok, event: {_event_pad, event}}, state} =
               TWCCReceiver.handle_tick(:report_timer, @ctx, state)

      assert event.rtcp.payload.feedback_packet_count == @feedback_packet_count

      assert {{:ok, _buffer_action}, state} =
               TWCCReceiver.handle_process(@default_input_pad, buffer, @ctx, state)

      assert {{:ok, event: {_event_pad, event}}, _state} =
               TWCCReceiver.handle_tick(:report_timer, @ctx, state)

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
               TWCCReceiver.handle_process(@default_input_pad, in_buffer, @ctx, state)

      assert {{:ok, event: _event_action}, state} =
               TWCCReceiver.handle_tick(:report_timer, @ctx, state)

      assert state.feedback_packet_count == @max_feedback_packet_count

      assert {{:ok, buffer: _buffer_action}, state} =
               TWCCReceiver.handle_process(@default_input_pad, in_buffer, @ctx, state)

      assert {{:ok, event: _event_action}, state} =
               TWCCReceiver.handle_tick(:report_timer, @ctx, state)

      assert state.feedback_packet_count == 0
    end
  end

  describe "When output pad is not connected, TWCC Element" do
    setup %{state: state, buffer: buffer} do
      {_element, ctx} = pop_in(@ctx, [:pads, @default_output_pad])

      buffered_actions = %{
        @default_input_pad => Qex.new(event: {@default_input_pad, :event})
      }

      state = Map.put(state, :buffered_actions, buffered_actions)

      [
        state: state,
        buffer: buffer,
        ctx: ctx
      ]
    end

    test "will not try to execute any action", %{state: state, buffer: buffer, ctx: ctx} do
      assert {:ok, state} = TWCCReceiver.handle_process(@default_input_pad, buffer, ctx, state)

      assert {:ok, state} = TWCCReceiver.handle_caps(@default_input_pad, :caps, ctx, state)

      assert [buffer: {@default_output_pad, _buffer}, caps: _caps] =
               Map.get(state.buffered_actions, @default_output_pad) |> Enum.to_list()
    end

    test "will send buffered actions when the pad connects", %{state: state, ctx: ctx} do
      assert {{:ok, [event: {@default_input_pad, _event}]}, state} =
               TWCCReceiver.handle_pad_added(@default_input_pad, ctx, state)

      refute Map.has_key?(state.buffered_actions, @default_input_pad)
    end
  end
end
