defmodule Membrane.RTP.SSRCRouterTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.Buffer
  alias Membrane.RTP.Header.Extension
  alias Membrane.RTP.SSRCRouter
  alias Membrane.RTP.Support.TestSource
  alias Membrane.Testing.Pipeline

  @rtp_metadata_template %{
    csrcs: [],
    extensions: [],
    marker: false,
    padding_size: 0,
    payload_type: 96,
    sequence_number: 1,
    ssrc: 1,
    timestamp: 0,
    total_header_size: 20
  }

  test "New RTP stream" do
    metadata = %{
      @rtp_metadata_template
      | extensions: [%Extension{identifier: 4, data: <<0, 2>>}]
    }

    pipeline = init_pipeline()
    src_send_meta_buffer(pipeline, metadata)

    assert_pipeline_notified(pipeline, :ssrc_router, {:new_rtp_stream, 1, pt, extensions})
    assert pt == metadata.payload_type
    assert extensions == metadata.extensions
    Pipeline.terminate(pipeline, blocking?: true)
  end

  test "Wait for required extensions" do
    payload_type = 96

    metadata = %{
      @rtp_metadata_template
      | payload_type: payload_type,
        extensions: [
          %Extension{identifier: 4, data: <<0, 2>>},
          %Extension{identifier: 9, data: "0"}
        ]
    }

    pipeline = init_pipeline()

    send_router_message(pipeline, %SSRCRouter.RequireExtensions{
      pt_to_ext_id: %{payload_type => [9, 10]}
    })

    src_send_meta_buffer(pipeline, metadata)

    metadata = %{
      metadata
      | ssrc: 2,
        extensions: [
          %Extension{identifier: 4, data: <<0, 3>>},
          %Extension{identifier: 9, data: "0"},
          %Extension{identifier: 10, data: "l"}
        ]
    }

    src_send_meta_buffer(pipeline, metadata)

    assert_pipeline_notified(
      pipeline,
      :ssrc_router,
      {:new_rtp_stream, 2, ^payload_type, extensions}
    )

    assert extensions == metadata.extensions

    # Ensure the first package was dropped
    refute_pipeline_notified(pipeline, :ssrc_router, {:new_rtp_stream, 1, _pt, _extensions}, 200)

    Pipeline.terminate(pipeline, blocking?: true)
  end

  defp init_pipeline() do
    pipeline =
      Pipeline.start_link_supervised!(
        structure:
          child(:source, %TestSource{output: [], stream_format: %Membrane.RTP{}})
          |> child(:ssrc_router, SSRCRouter)
      )

    assert_pipeline_play(pipeline)
    pipeline
  end

  defp src_send_meta_buffer(pipeline, metadata) do
    buffer = %Buffer{payload: "", metadata: %{rtp: metadata}}

    Pipeline.execute_actions(pipeline,
      notify_child: {:source, {:execute_actions, [buffer: {:output, buffer}]}}
    )
  end

  defp send_router_message(pipeline, msg) do
    Pipeline.execute_actions(pipeline, notify_child: {:ssrc_router, msg})
  end
end
