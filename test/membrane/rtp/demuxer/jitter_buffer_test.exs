defmodule Membrane.RTP.Demuxer.JitterBufferTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.Demuxer.JitterBuffer

  # Dynamic payload type with no registered clock_rate
  @payload_type 127
  @ssrc 12_345

  defp make_packet(seq_num, timestamp) do
    %ExRTP.Packet{
      payload_type: @payload_type,
      sequence_number: seq_num,
      timestamp: timestamp,
      ssrc: @ssrc,
      payload: <<1, 2, 3>>
    }
  end

  defp make_buffer(packet) do
    %Membrane.Buffer{
      payload: packet.payload,
      metadata: %{rtp: %{packet | payload: <<>>}}
    }
  end

  defp init_state(packet, clock_rate) do
    pad = Membrane.Pad.ref(:output, :test)

    pad_options = %{
      stream_id: {:ssrc, @ssrc},
      clock_rate: clock_rate,
      jitter_buffer_latency: 0
    }

    packet
    |> JitterBuffer.new()
    |> JitterBuffer.initialize(pad, pad_options, %{})
  end

  defp output_buffers(actions) do
    for {:buffer, {_pad, buf}} <- actions, do: buf
  end

  describe "when clock_rate is nil (unresolvable dynamic payload type)" do
    test "buffer is passed through without crashing" do
      packet = make_packet(1, 1000)
      state = init_state(packet, nil)

      state = JitterBuffer.insert_buffer(state, make_buffer(packet))
      {actions, _state} = JitterBuffer.get_output_actions(state)

      assert [_buf] = output_buffers(actions)
    end

    test "buffer pts is not updated and remains nil" do
      packet = make_packet(1, 1000)
      state = init_state(packet, nil)

      state = JitterBuffer.insert_buffer(state, make_buffer(packet))
      {actions, _state} = JitterBuffer.get_output_actions(state)

      assert [%Membrane.Buffer{pts: nil}] = output_buffers(actions)
    end
  end

  describe "when clock_rate is known" do
    test "buffer pts is computed from the rtp timestamp" do
      clock_rate = 90_000
      # first packet establishes timestamp_base = 0; a second packet's pts should be non-zero
      first = make_packet(1, 0)
      state = init_state(first, clock_rate)

      second = make_packet(2, 9000)
      state = JitterBuffer.insert_buffer(state, make_buffer(first))
      state = JitterBuffer.insert_buffer(state, make_buffer(second))
      {actions, _state} = JitterBuffer.get_output_actions(state)

      [first_out, second_out] = output_buffers(actions)
      assert first_out.pts == 0
      assert second_out.pts == Membrane.Time.seconds(1) |> div(10)
    end
  end
end
