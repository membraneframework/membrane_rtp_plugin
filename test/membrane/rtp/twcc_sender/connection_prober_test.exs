defmodule Membrane.RTP.TWCCSender.ConnectionProberTest do
  use ExUnit.Case, async: true

  import Membrane.Testing.Assertions

  alias Membrane.{Buffer, ParentSpec}
  alias Membrane.Testing.{Pipeline, Source, Sink}
  alias Membrane.RTP.TWCCSender.ConnectionProber

  @base_state %{
    last_timestamp: 0,
    last_seq_num: 0,
    offset: 0,
    seq_num_mapping: %{}
  }

  describe "ConnectionProber" do
    test "doesn't modify sequence numbers stored in sequence number mapping" do
      state = %{@base_state | seq_num_mapping: %{2 => 3}}

      input_buffer = %Buffer{
        payload: <<>>,
        metadata: %{
          rtp: %{
            timestamp: 10,
            sequence_number: 2
          }
        }
      }

      assert {{:ok, forward: %Buffer{metadata: %{rtp: %{sequence_number: 3}}}}, _new_state} =
               ConnectionProber.handle_process(:input, input_buffer, nil, state)
    end

    test "increments the timestamp by offset when there isn't a sequence mapping entry" do
      state = %{@base_state | offset: 1}

      input_buffer = %Buffer{
        payload: <<>>,
        metadata: %{
          rtp: %{
            timestamp: 10,
            sequence_number: 1
          }
        }
      }

      assert {{:ok, forward: %Buffer{metadata: %{rtp: %{sequence_number: 2}}}}, _new_state} =
               ConnectionProber.handle_process(:input, input_buffer, nil, state)
    end

    test "applies the rollover when adding offset" do
      state = %{@base_state | offset: 2}

      input_buffer = %Buffer{
        payload: <<>>,
        metadata: %{
          rtp: %{
            timestamp: 10,
            sequence_number: 2 ** 16 - 1
          }
        }
      }

      assert {{:ok, forward: %Buffer{metadata: %{rtp: %{sequence_number: 1}}}}, _new_state} =
               ConnectionProber.handle_process(:input, input_buffer, nil, state)
    end

    test "doesn't produce duplicates under normal operation" do
      generate_buffer = fn
        65_536, _size ->
          {[end_of_stream: :output], 65_536}

        i, _size ->
          buffer = %Buffer{
            payload: "test",
            metadata: %{
              rtp: %{
                timestamp: 250 * i,
                sequence_number: rem(i, 2 ** 16)
              }
            }
          }

          {[buffer: {:output, buffer}, redemand: :output], i + 1}
      end

      children = [
        source: %Source{
          output: {65_500, generate_buffer},
          caps: %Membrane.RemoteStream{content_format: Membrane.RTP}
        },
        prober: %ConnectionProber{
          ssrc: 0,
          payload_type: 0
        },
        sink: Sink
      ]

      {:ok, pipeline} = Pipeline.start_link(links: ParentSpec.link_linear(children))
      on_exit(fn -> Pipeline.terminate(pipeline, blocking?: true) end)

      expected_no_of_buffers = 46

      expected_seq_nums =
        Enum.concat([
          65_500..65_535,
          0..9
        ])

      assert_end_of_stream(pipeline, :sink)

      seq_nums =
        for _i <- 1..expected_no_of_buffers do
          assert_sink_buffer(pipeline, :sink, %Buffer{
            metadata: %{rtp: %{sequence_number: seq_num}}
          })

          seq_num
        end

      refute_sink_buffer(pipeline, :sink, _buffer)

      assert seq_nums == expected_seq_nums
    end
  end
end
