defmodule Membrane.RTP.StreamSendBinTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions

  alias Membrane.RTP.StreamSendBin
  alias Membrane.RTP.H264
  alias Membrane.Testing

  @frames_count 1038

  defmodule RTCPReceiver do
    use Membrane.Sink

    def_input_pad :input, demand_unit: :buffers, caps: :any

    @impl true
    def handle_init(_opts), do: {:ok, %{}}

    @impl true
    def handle_prepared_to_playing(_ctx, state),
      do: {{:ok, demand: :input}, state}

    @impl true
    def handle_write(_pad, buffer, _context, state) do
      {{:ok, notify: {:rtcp_packet, buffer}}, state}
    end
  end

  defmodule Limiter do
    # module responsible for passing up to a limit of buffers and
    # then ignores all the buffers

    use Membrane.Filter

    def_options limit: [spec: non_neg_integer() | :infinity]

    def_input_pad :input, caps: :any, demand_mode: :auto
    def_output_pad :output, caps: :any, demand_mode: :auto

    @impl true
    def handle_init(opts) do
      {:ok, %{buffers: 0, limit: opts.limit}}
    end

    @impl true
    def handle_process(:input, buffer, _ctx, %{limit: :infinity} = state) do
      {{:ok, buffer: {:output, buffer}}, state}
    end

    @impl true
    def handle_process(:input, buffer, _ctx, %{buffers: buffers, limit: limit} = state)
        when buffers + 1 <= limit do
      {{:ok, buffer: {:output, buffer}}, %{state | buffers: buffers + 1}}
    end

    @impl true
    def handle_process(:input, _buffer, _ctx, state) do
      {:ok, state}
    end
  end

  defmodule SenderPipeline do
    use Membrane.Pipeline

    @pcap_file "test/fixtures/rtp/session/demo.pcap"
    @ssrc 790_688_045
    @h264_clock_rate 90_000

    @impl true
    def handle_init(opts) do
      source_options =
        case opts.source_type do
          :hackney ->
            %{
              children: [
                hackney: %Membrane.Hackney.Source{
                  location:
                    "https://membraneframework.github.io/static/samples/big-buck-bunny/bun33s_720x480.h264",
                  hackney_opts: [follow_redirect: true]
                },
                video_parser: %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}, alignment: :nal}
              ],
              link_builder: link(:hackney) |> to(:video_parser)
            }

          :pcap ->
            %{
              children: [
                pcap: %Membrane.Pcap.Source{path: @pcap_file},
                parser: Membrane.RTP.Parser
              ],
              link_builder: link(:pcap) |> to(:parser)
            }
        end

      spec = %ParentSpec{
        children:
          [
            limiter: %Limiter{limit: opts.limit},
            rtp: %StreamSendBin{
              clock_rate: @h264_clock_rate,
              payloader: Map.get(opts, :payloader, H264.Payloader),
              payload_type: Membrane.RTP.PayloadFormat.get(:H264).payload_type,
              ssrc: @ssrc,
              rtcp_report_interval: Map.get(opts, :rtcp_interval, Membrane.Time.seconds(1))
            },
            rtcp_sink: Testing.Sink,
            rtp_sink: Testing.Sink
          ] ++ source_options.children,
        links: [
          source_options.link_builder
          |> to(:limiter)
          |> to(:rtp)
          |> to(:rtp_sink),
          link(:rtp)
          |> via_out(Pad.ref(:rtcp_output, @ssrc))
          |> to(:rtcp_sink)
        ]
      }

      {{:ok, spec: spec, playback: :playing}, %{}}
    end
  end

  test "RTCP sender reports are generated properly" do
    opts = %Testing.Pipeline.Options{
      module: SenderPipeline,
      custom_args: %{
        limit: 5,
        source_type: :pcap,
        payloader: nil,
        rtcp_interval: Membrane.Time.microseconds(100)
      }
    }

    {:ok, pipeline} = Testing.Pipeline.start_link(opts)

    assert_pipeline_playback_changed(pipeline, _, :playing)
    assert_start_of_stream(pipeline, :rtp_sink)

    assert_sink_buffer(pipeline, :rtcp_sink, packet)

    %Membrane.Buffer{payload: packet_payload} = packet
    {:ok, [packet]} = Membrane.RTCP.Packet.parse(packet_payload)

    assert %Membrane.RTCP.SenderReportPacket{
             sender_info: %{
               sender_packet_count: 5
             }
           } = packet

    Testing.Pipeline.terminate(pipeline, blocking?: true)
  end

  test "Depayloaded RTP stream gets payloaded and passed through bin's output properly" do
    opts = %Testing.Pipeline.Options{
      module: SenderPipeline,
      custom_args: %{
        limit: :infinity,
        source_type: :hackney,
        payloader: H264.Payloader
      }
    }

    {:ok, pipeline} = Testing.Pipeline.start_link(opts)

    assert_pipeline_playback_changed(pipeline, _, :playing)
    assert_start_of_stream(pipeline, :rtp_sink)

    assert_end_of_stream(pipeline, :rtp_sink, :input, 4000)

    Testing.Pipeline.terminate(pipeline, blocking?: true)
  end

  test "Payloaded RTP stream passes through bin's output properly" do
    opts = %Testing.Pipeline.Options{
      module: SenderPipeline,
      custom_args: %{
        limit: :infinity,
        source_type: :pcap,
        payloader: nil
      }
    }

    {:ok, pipeline} = Testing.Pipeline.start_link(opts)

    assert_pipeline_playback_changed(pipeline, _, :playing)
    assert_start_of_stream(pipeline, :rtp_sink)

    for _ <- 1..@frames_count do
      assert_pipeline_notified(pipeline, :rtp_sink, {:buffer, _buffer})
    end

    assert_end_of_stream(pipeline, :rtp_sink, :input)

    Testing.Pipeline.terminate(pipeline, blocking?: true)
  end
end
