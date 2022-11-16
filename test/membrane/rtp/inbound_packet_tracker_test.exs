defmodule Membrane.RTP.InboundPacketTrackerTest do
  use ExUnit.Case, async: true
  use Bunch

  import Membrane.Testing.Assertions

  alias Membrane.{Buffer, ParentSpec}
  alias Membrane.RTP.InboundPacketTracker
  alias Membrane.RTP.BufferFactory
  alias Membrane.Testing.{Source, Sink, Pipeline}

  require Bitwise

  @max_seq_number Bitwise.bsl(1, 16) - 1
  @base_seq_number BufferFactory.base_seq_number()

  describe "InboundPacketTracker should" do
    setup do
      buffer = BufferFactory.sample_buffer(@base_seq_number)

      state = %InboundPacketTracker.State{
        clock_rate: BufferFactory.clock_rate(),
        repair_sequence_numbers?: true
      }

      [state: state, buffer: buffer]
    end

    test "update stats accordingly when receiving new buffers", %{state: state, buffer: buffer} do
      ts = ~U[2020-06-19 19:06:00Z] |> DateTime.to_unix() |> Membrane.Time.seconds()

      timestamped_buf = put_in(buffer.metadata[:arrival_ts], ts)

      assert {{:ok, _actions}, state} =
               InboundPacketTracker.handle_process(:input, timestamped_buf, nil, state)

      assert state.jitter == 0.0

      assert state.transit ==
               Membrane.Time.to_seconds(ts) * state.clock_rate -
                 timestamped_buf.metadata.rtp.timestamp

      buffer = BufferFactory.sample_buffer(@base_seq_number + 1)

      arrival_ts_increment =
        div(BufferFactory.timestamp_increment(), state.clock_rate) |> Membrane.Time.seconds()

      packet_delay = 1 |> Membrane.Time.seconds()

      timestamped_buf =
        put_in(buffer.metadata[:arrival_ts], ts + arrival_ts_increment + packet_delay)

      assert {{:ok, _actions}, state} =
               InboundPacketTracker.handle_process(:input, timestamped_buf, nil, state)

      # 16 is defined by RFC
      assert state.jitter ==
               Membrane.Time.to_seconds(packet_delay) * state.clock_rate / 16

      assert state.transit ==
               Membrane.Time.to_seconds(ts + arrival_ts_increment + packet_delay) *
                 state.clock_rate -
                 timestamped_buf.metadata.rtp.timestamp
    end

    test "update packet's sequence number if there have been discarded packets", %{state: state} do
      state = %InboundPacketTracker.State{state | discarded: 10}

      # in sequence number range
      buffer = BufferFactory.sample_buffer(100)

      assert {{:ok, [buffer: {:output, buffer}]}, state} =
               InboundPacketTracker.handle_process(:input, buffer, nil, state)

      assert buffer.metadata.rtp.sequence_number == 90

      # border case where sequence number over rolled
      buffer = BufferFactory.sample_buffer(5)

      assert {{:ok, [buffer: {:output, buffer}]}, state} =
               InboundPacketTracker.handle_process(:input, buffer, nil, state)

      assert buffer.metadata.rtp.sequence_number == @max_seq_number - 5 + 1

      state = %InboundPacketTracker.State{state | repair_sequence_numbers?: false}
      buffer = BufferFactory.sample_buffer(100)

      assert {{:ok, [buffer: {:output, buffer}]}, _state} =
               InboundPacketTracker.handle_process(:input, buffer, nil, state)

      assert buffer.metadata.rtp.sequence_number == 100
    end
  end

  @max_seq_number 0xFFFF

  test "sends RetransmissionRequest when there are missing packets" do
    buffers =
      [
        -100..100,
        110..130,
        100..110
      ]
      |> Enum.flat_map(&Enum.to_list/1)
      |> Enum.map(fn i ->
        seq_num = rem(@max_seq_number + i, @max_seq_number)
        timestamp = 10 * seq_num

        %Buffer{
          metadata: %{
            rtp: %{
              sequence_number: seq_num,
              timestamp: timestamp,
              ssrc: 0,
              cssrc: [],
              extensions: [],
              marker: false
            }
          },
          pts: timestamp,
          dts: timestamp,
          payload: <<"BUFFER", seq_num::16-unsigned>>
        }
      end)

    generator_fun = fn state, size ->
      {buffers, state} = Enum.split(state, size)

      eos_actions = if state == [], do: [end_of_stream: :output], else: []

      {[buffer: {:output, buffers}] ++ eos_actions, state}
    end

    children = [
      source: %Source{output: {buffers, generator_fun}, caps: %Membrane.RTP{}},
      tracker: %InboundPacketTracker{clock_rate: 90_000},
      sink: Sink
    ]

    {:ok, pipeline} = Pipeline.start_link(links: ParentSpec.link_linear(children))
    on_exit(fn -> Pipeline.terminate(pipeline, blocking?: true) end)
    Pipeline.execute_actions(pipeline, playback: :playing)
    assert_pipeline_playback_changed(pipeline, :prepared, :playing)
    assert_end_of_stream(pipeline, :sink)

    for buffer <- buffers do
      assert_sink_buffer(pipeline, :sink, ^buffer)
    end
  end
end
