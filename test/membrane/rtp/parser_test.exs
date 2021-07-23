defmodule Membrane.RTP.ParserTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions

  alias Membrane.Buffer
  alias Membrane.RTP.{Fixtures, Parser}
  alias Membrane.Testing.{Pipeline, Sink, Source}

  @buffer_receive_timeout 1000

  describe "Parser" do
    test "parse a packet" do
      state = %{}
      packet = Fixtures.sample_packet_binary()

      assert Parser.handle_process(:input, %Buffer{payload: packet}, nil, state) ==
               {{:ok,
                 buffer:
                   {:output,
                    %Membrane.Buffer{
                      metadata: %{
                        rtp: %{
                          sequence_number: 3983,
                          timestamp: 1_653_702_647,
                          payload_type: 14,
                          ssrc: 3_919_876_492,
                          csrcs: [],
                          extension: nil,
                          marker: false
                        }
                      },
                      payload: Fixtures.sample_packet_payload()
                    }}}, %{}}
    end

    test "works in pipeline" do
      test_data_base = 1..100
      test_data = Fixtures.fake_packet_list(test_data_base)

      {:ok, pipeline} =
        Pipeline.start_link(%Pipeline.Options{
          elements: [
            source: %Source{
              output: test_data,
              caps: %Membrane.RemoteStream{type: :packetized, content_format: Membrane.RTP}
            },
            parser: Parser,
            sink: %Sink{}
          ]
        })

      Pipeline.play(pipeline)

      Enum.each(test_data_base, fn _test_data ->
        assert_sink_buffer(pipeline, :sink, %Buffer{}, @buffer_receive_timeout)
      end)

      Pipeline.stop_and_terminate(pipeline, blocking?: true)
    end
  end
end
