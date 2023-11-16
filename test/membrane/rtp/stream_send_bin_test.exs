defmodule Membrane.RTP.StreamSendBinTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions

  alias Membrane.RTP.H264
  alias Membrane.RTP.StreamSendBin
  alias Membrane.Testing

  @frames_count 1038

  defmodule RTCPReceiver do
    use Membrane.Sink

    def_input_pad :input, flow_control: :manual, demand_unit: :buffers, accepted_format: _any

    @impl true
    def handle_init(_ctx, _opts), do: {[], %{}}

    @impl true
    def handle_playing(_ctx, state),
      do: {[demand: :input], state}

    @impl true
    def handle_buffer(_pad, buffer, _context, state) do
      {[notify_parent: {:rtcp_packet, buffer}], state}
    end
  end

  defmodule Limiter do
    # module responsible for passing up to a limit of buffers and
    # then ignores all the buffers

    use Membrane.Filter

    def_options limit: [spec: non_neg_integer() | :infinity]

    def_input_pad :input, accepted_format: _any, flow_control: :auto
    def_output_pad :output, accepted_format: _any, flow_control: :auto

    @impl true
    def handle_init(_ctx, opts) do
      {[], %{buffers: 0, limit: opts.limit}}
    end

    @impl true
    def handle_buffer(:input, buffer, _ctx, %{limit: :infinity} = state) do
      {[buffer: {:output, buffer}], state}
    end

    @impl true
    def handle_buffer(:input, buffer, _ctx, %{buffers: buffers, limit: limit} = state)
        when buffers + 1 <= limit do
      {[buffer: {:output, buffer}], %{state | buffers: buffers + 1}}
    end

    @impl true
    def handle_buffer(:input, _buffer, _ctx, state) do
      {[], state}
    end
  end

  defmodule SenderPipeline do
    use Membrane.Pipeline

    @pcap_file "test/fixtures/rtp/session/demo.pcap"
    @ssrc 790_688_045
    @h264_clock_rate 90_000

    @impl true
    def handle_init(_ctx, opts) do
      structure_prefix =
        case opts.source_type do
          :hackney ->
            child(:hackney, %Membrane.Hackney.Source{
              location:
                "https://raw.githubusercontent.com/membraneframework/static/gh-pages/samples/big-buck-bunny/bun33s_720x480.h264",
              hackney_opts: [follow_redirect: true]
            })
            |> child(:video_parser, %Membrane.H264.Parser{
              generate_best_effort_timestamps: %{framerate: {30, 1}},
              output_alignment: :nalu
            })

          :pcap ->
            child(:pcap, %Membrane.Pcap.Source{path: @pcap_file})
            |> child(:parser, Membrane.RTP.Parser)
        end

      structure = [
        child(:limiter, %Limiter{limit: opts.limit}),
        child(:rtp, %StreamSendBin{
          clock_rate: @h264_clock_rate,
          payloader: Map.get(opts, :payloader, H264.Payloader),
          payload_type: Membrane.RTP.PayloadFormat.get(:H264).payload_type,
          ssrc: @ssrc,
          rtcp_report_interval: Map.get(opts, :rtcp_interval, Membrane.Time.seconds(1))
        }),
        child(:rtp_sink, Testing.Sink),
        structure_prefix
        |> get_child(:limiter)
        |> get_child(:rtp)
        |> get_child(:rtp_sink),
        get_child(:rtp)
        |> via_out(Pad.ref(:rtcp_output, @ssrc))
        |> child(:rtcp_sink, Testing.Sink)
      ]

      {[spec: structure], %{}}
    end
  end

  test "RTCP sender reports are generated properly" do
    pipeline =
      Testing.Pipeline.start_link_supervised!(
        module: SenderPipeline,
        custom_args: %{
          limit: 5,
          source_type: :pcap,
          payloader: nil,
          rtcp_interval: Membrane.Time.microseconds(100)
        }
      )

    assert_start_of_stream(pipeline, :rtp_sink)

    assert_sink_buffer(pipeline, :rtcp_sink, packet)

    %Membrane.Buffer{payload: packet_payload} = packet
    {:ok, [packet]} = Membrane.RTCP.Packet.parse(packet_payload)

    assert %Membrane.RTCP.SenderReportPacket{
             sender_info: %{
               sender_packet_count: 5
             }
           } = packet

    Testing.Pipeline.terminate(pipeline)
  end

  test "Depayloaded RTP stream gets payloaded and passed through bin's output properly" do
    pipeline =
      Testing.Pipeline.start_link_supervised!(
        module: SenderPipeline,
        custom_args: %{
          limit: :infinity,
          source_type: :hackney,
          payloader: H264.Payloader
        }
      )

    assert_start_of_stream(pipeline, :rtp_sink)

    assert_end_of_stream(pipeline, :rtp_sink, :input, 4000)

    Testing.Pipeline.terminate(pipeline)
  end

  test "Payloaded RTP stream passes through bin's output properly" do
    pipeline =
      Testing.Pipeline.start_link_supervised!(
        module: SenderPipeline,
        custom_args: %{
          limit: :infinity,
          source_type: :pcap,
          payloader: nil
        }
      )

    assert_start_of_stream(pipeline, :rtp_sink)

    for _ <- 1..@frames_count do
      assert_pipeline_notified(pipeline, :rtp_sink, {:buffer, _buffer})
    end

    assert_end_of_stream(pipeline, :rtp_sink, :input)

    Testing.Pipeline.terminate(pipeline)
  end
end
