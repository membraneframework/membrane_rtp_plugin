defmodule Membrane.RTP.TWCCTest do
  use ExUnit.Case, async: true
  use Bunch

  alias Membrane.RTP.{BufferFactory, Header, TWCC}
  alias Membrane.RTP.TWCC.State

  @sdp_extension_id 3
  @remote_seq_number 12_345

  @local_seq_number 1000
  @feedback_packet_count 100
  @max_seq_number 65_535
  @max_feedback_packet_count 255

  @sender_ssrc 1_234_567_890
  @media_ssrc 9_876_543_210
  @other_media_ssrc 1_111_111_111

  setup_all do
    extension = make_extension(@sdp_extension_id, @remote_seq_number)

    buffer =
      BufferFactory.sample_buffer(10)
      |> Bunch.Struct.put_in([:metadata, :rtp, :extension], extension)

    state = %State{
      sender_ssrc: @sender_ssrc,
      report_interval: nil,
      local_seq_num: @local_seq_number,
      feedback_packet_count: @feedback_packet_count
    }

    [state: state, buffer: buffer]
  end

  describe "When a buffer arrives, TWCC element" do
    test "forwards it via the appropriate output pad", %{state: state, buffer: buffer} do
      assert {{:ok, buffer: {out_pad, _buffer}}, _state} =
               TWCC.handle_process({Membrane.Pad, :input, @media_ssrc}, buffer, nil, state)

      assert out_pad == {Membrane.Pad, :output, @media_ssrc}
    end

    test "does not modify anything but the header extension", %{state: state, buffer: in_buffer} do
      assert {{:ok, buffer: {_out_pad, out_buffer}}, _state} =
               TWCC.handle_process({Membrane.Pad, :input, @media_ssrc}, in_buffer, nil, state)

      {_extension, buffer_without_extension} =
        Bunch.Struct.pop_in(in_buffer, [:metadata, :rtp, :extension])

      assert {_extension, ^buffer_without_extension} =
               Bunch.Struct.pop_in(out_buffer, [:metadata, :rtp, :extension])
    end

    test "extracts appropriate sequence number", %{state: state, buffer: buffer} do
      assert {{:ok, _buffer_action}, state} =
               TWCC.handle_process({Membrane.Pad, :input, @media_ssrc}, buffer, nil, state)

      assert [@remote_seq_number] = Map.keys(state.packet_info_store.seq_to_timestamp)
    end

    test "replaces TWCC header extension with its own", %{state: state, buffer: buffer} do
      assert {{:ok, buffer: {_out_pad, out_buffer}}, _state} =
               TWCC.handle_process({Membrane.Pad, :input, @media_ssrc}, buffer, nil, state)

      assert out_buffer.metadata.rtp.extension ==
               make_extension(@sdp_extension_id, @local_seq_number)
    end
  end

  describe "When generating an RTCP event, TWCC element" do
    test "uses media SSRC of the first input pad that delivered a buffer", %{
      state: state,
      buffer: buffer
    } do
      assert {{:ok, _buffer_action}, state} =
               TWCC.handle_process({Membrane.Pad, :input, @media_ssrc}, buffer, nil, state)

      assert {{:ok, _buffer_action}, state} =
               TWCC.handle_process({Membrane.Pad, :input, @other_media_ssrc}, buffer, nil, state)

      assert {{:ok, event: {{Membrane.Pad, :input, @media_ssrc}, event}}, _state} =
               TWCC.handle_tick(:report_timer, nil, state)

      assert event.rtcp.media_ssrc == @media_ssrc
    end

    test "uses media SSRC of the next input pad if the previous one has been removed",
         %{
           state: state,
           buffer: buffer
         } do
      assert {{:ok, _buffer_action}, state} =
               TWCC.handle_process({Membrane.Pad, :input, @media_ssrc}, buffer, nil, state)

      assert {:ok, state} =
               TWCC.handle_pad_removed({Membrane.Pad, :input, @media_ssrc}, nil, state)

      assert {{:ok, _buffer_action}, state} =
               TWCC.handle_process({Membrane.Pad, :input, @other_media_ssrc}, buffer, nil, state)

      assert {{:ok, event: {{Membrane.Pad, :input, @other_media_ssrc}, event}}, _state} =
               TWCC.handle_tick(:report_timer, nil, state)

      assert event.rtcp.media_ssrc == @other_media_ssrc
    end

    test "uses sender SSRC passed in options", %{state: state, buffer: buffer} do
      assert {{:ok, _buffer_action}, state} =
               TWCC.handle_process({Membrane.Pad, :input, @media_ssrc}, buffer, nil, state)

      assert {{:ok, event: {_event_pad, event}}, _state} =
               TWCC.handle_tick(:report_timer, nil, state)

      assert event.rtcp.sender_ssrc == @sender_ssrc
    end

    test "increments its feedback packet count", %{state: state, buffer: buffer} do
      assert {{:ok, _buffer_action}, state} =
               TWCC.handle_process({Membrane.Pad, :input, @media_ssrc}, buffer, nil, state)

      assert {{:ok, event: {_event_pad, event}}, state} =
               TWCC.handle_tick(:report_timer, nil, state)

      assert event.rtcp.payload.feedback_packet_count == @feedback_packet_count

      assert {{:ok, _buffer_action}, state} =
               TWCC.handle_process({Membrane.Pad, :input, @media_ssrc}, buffer, nil, state)

      assert {{:ok, event: {_event_pad, event}}, _state} =
               TWCC.handle_tick(:report_timer, nil, state)

      assert event.rtcp.payload.feedback_packet_count == @feedback_packet_count + 1
    end
  end

  describe "When local counters reach their limits, TWCC element" do
    setup %{state: state, buffer: buffer} do
      [
        state: %State{
          state
          | local_seq_num: @max_seq_number - 1,
            feedback_packet_count: @max_feedback_packet_count - 1
        },
        buffer: buffer
      ]
    end

    test "performs a rollover", %{state: state, buffer: in_buffer} do
      assert {{:ok, buffer: _buffer_action}, state} =
               TWCC.handle_process({Membrane.Pad, :input, @media_ssrc}, in_buffer, nil, state)

      assert state.local_seq_num == @max_seq_number

      assert {{:ok, event: _event_action}, state} = TWCC.handle_tick(:report_timer, nil, state)

      assert state.feedback_packet_count == @max_feedback_packet_count

      assert {{:ok, buffer: _buffer_action}, state} =
               TWCC.handle_process({Membrane.Pad, :input, @media_ssrc}, in_buffer, nil, state)

      assert state.local_seq_num == 0

      assert {{:ok, event: _event_action}, state} = TWCC.handle_tick(:report_timer, nil, state)

      assert state.feedback_packet_count == 0
    end
  end

  defp make_extension(id, seq_num) do
    # https://datatracker.ietf.org/doc/html/draft-holmer-rmcat-transport-wide-cc-extensions-01#section-2.2
    %Header.Extension{
      profile_specific: <<0xBE, 0xDE, 1>>,
      data: <<id::4, 1::4, seq_num::16, 0::8>>
    }
  end
end
