defmodule Membrane.RTP.ParserTest do
  use ExUnit.Case

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.Buffer
  alias Membrane.RTP.{Fixtures, Parser}
  alias Membrane.Testing.{Pipeline, Sink, Source}

  @buffer_receive_timeout 1000

  describe "Parser" do
    test "parses a packet" do
      state = %{secure?: false}
      packet = Fixtures.sample_packet_binary()

      assert Parser.handle_process(:input, %Buffer{payload: packet}, nil, state) ==
               {
                 [
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
                            extensions: [],
                            marker: false,
                            has_padding?: false,
                            total_header_size: 12
                          }
                        },
                        payload: Fixtures.sample_packet_payload()
                      }}
                 ],
                 state
               }
    end

    test "buffers when parsing an RTCP packet" do
      state = %{secure?: false, rtcp_output_pad: :rtcp_output}
      buffer = Fixtures.sample_rtcp_buffer()

      assert Parser.handle_process(:input, buffer, nil, state) ==
               {[buffer: {:rtcp_output, buffer}], state}
    end

    test "works in pipeline" do
      test_data_base = 1..100
      test_data = Fixtures.fake_packet_list(test_data_base)

      {:ok, _supervisor, pipeline} =
        Pipeline.start_link_supervised(
          structure: [
            child(:source, %Source{
              output: test_data,
              stream_format: %Membrane.RemoteStream{
                type: :packetized,
                content_format: Membrane.RTP
              }
            })
            |> child(:parser, Parser)
            |> child(:sink, Sink)
          ]
        )

      Enum.each(test_data_base, fn _test_data ->
        assert_sink_buffer(pipeline, :sink, %Buffer{}, @buffer_receive_timeout)
      end)

      Pipeline.terminate(pipeline, blocking?: true)
    end
  end
end
