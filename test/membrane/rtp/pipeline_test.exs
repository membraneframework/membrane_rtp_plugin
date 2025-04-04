defmodule Membrane.RTP.PipelineTest do
  use ExUnit.Case

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.Buffer
  alias Membrane.RemoteStream
  alias Membrane.RemoteStream
  alias Membrane.RTP
  alias Membrane.RTP.{Fixtures, Parser}
  alias Membrane.Testing.{Pipeline, Sink, Source}

  @buffer_receive_timeout 1000

  test "Pipeline decodes set of RTP packets" do
    test_data_base = 1..100
    test_data = Fixtures.fake_packet_list(test_data_base)

    pipeline =
      Pipeline.start_link_supervised!(
        spec:
          child(:source, %Source{
            output: test_data,
            stream_format: %RemoteStream{type: :packetized, content_format: RTP}
          })
          |> child(:parser, Parser)
          |> child(:sink, Sink)
      )

    Enum.each(test_data_base, fn _test_data ->
      assert_sink_buffer(pipeline, :sink, %Buffer{}, @buffer_receive_timeout)
    end)

    Pipeline.terminate(pipeline)
  end
end
