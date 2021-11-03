defmodule Membrane.RTP.StreamReceiveBinTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions

  alias Membrane.RTP
  alias Membrane.RTP.StreamReceiveBin
  alias Membrane.RTP.H264
  alias Membrane.Testing

  @pcap_file "test/fixtures/rtp/session/demo.pcap"
  @frames_count 1038
  @ssrc 790_688_045
  @h264_clock_rate 90_000

  defmodule FrameCounter do
    use Membrane.Sink

    def_input_pad :input, demand_unit: :buffers, caps: :any

    @impl true
    def handle_init(_opts), do: {:ok, %{counter: 0}}

    @impl true
    def handle_prepared_to_playing(_ctx, state),
      do: {{:ok, demand: :input}, state}

    @impl true
    def handle_write(_pad, _buff, _context, %{counter: c}),
      do: {{:ok, demand: :input}, %{counter: c + 1}}

    @impl true
    def handle_end_of_stream(_pad, _ctx, %{counter: c} = state),
      do: {{:ok, notify: {:frame_count, c}}, state}
  end

  test "RTP stream passes through bin properly" do
    opts = %Testing.Pipeline.Options{
      elements: [
        pcap: %Membrane.Element.Pcap.Source{path: @pcap_file},
        rtp_parser: RTP.Parser,
        rtp: %StreamReceiveBin{
          clock_rate: @h264_clock_rate,
          depayloader: H264.Depayloader,
          remote_ssrc: @ssrc,
          local_ssrc: 0,
          rtcp_report_interval: Membrane.Time.seconds(5),
          rtcp_fir_interval: nil
        },
        video_parser: %Membrane.H264.FFmpeg.Parser{framerate: {30, 1}},
        frame_counter: FrameCounter
      ]
    }

    {:ok, pipeline} = Testing.Pipeline.start_link(opts)

    Testing.Pipeline.play(pipeline)

    assert_pipeline_playback_changed(pipeline, _, :playing)
    assert_start_of_stream(pipeline, :rtp_parser)
    assert_start_of_stream(pipeline, :frame_counter)
    assert_end_of_stream(pipeline, :rtp_parser, :input, 4000)
    assert_end_of_stream(pipeline, :frame_counter)
    assert_pipeline_notified(pipeline, :frame_counter, {:frame_count, count})
    assert count == @frames_count

    Testing.Pipeline.stop_and_terminate(pipeline, blocking?: true)
  end

  test "RTCP reports are generated properly" do
    pcap_file = "test/fixtures/rtp/session/h264_before_sr.pcap"

    opts = %Testing.Pipeline.Options{
      elements: [
        pcap: %Membrane.Element.Pcap.Source{
          path: pcap_file,
          packet_transformer: fn %ExPcap.Packet{
                                   packet_header: %{ts_sec: sec, ts_usec: usec},
                                   parsed_packet_data: {_, payload}
                                 } ->
            arrival_ts = Membrane.Time.seconds(sec) + Membrane.Time.microseconds(usec)
            %Membrane.Buffer{payload: payload, metadata: %{arrival_ts: arrival_ts}}
          end
        },
        rtp_parser: RTP.Parser,
        rtp: %StreamReceiveBin{
          clock_rate: @h264_clock_rate,
          depayloader: H264.Depayloader,
          local_ssrc: 0,
          remote_ssrc: 4_194_443_425,
          rtcp_report_interval: Membrane.Time.seconds(5),
          rtcp_fir_interval: nil
        },
        sink: Testing.Sink
      ]
    }

    {:ok, pipeline} = Testing.Pipeline.start_link(opts)

    Testing.Pipeline.play(pipeline)

    assert_pipeline_playback_changed(pipeline, _, :playing)
    assert_start_of_stream(pipeline, :rtp_parser)
    assert_start_of_stream(pipeline, :sink)
    assert_end_of_stream(pipeline, :rtp_parser, :input, 4000)
    assert_end_of_stream(pipeline, :sink)
    Testing.Pipeline.stop_and_terminate(pipeline, blocking?: true)
  end
end
