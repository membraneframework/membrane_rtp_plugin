defmodule Membrane.RTP.StreamReceiveBinTest do
  use ExUnit.Case

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.RTCP.FeedbackPacket
  alias Membrane.RTP
  alias Membrane.RTP.H264
  alias Membrane.RTP.StreamReceiveBin
  alias Membrane.Testing

  @pcap_file "test/fixtures/rtp/session/demo.pcap"
  @frames_count 1038
  @ssrc 790_688_045
  @h264_clock_rate 90_000
  @fir_throttle_duration_ms Application.compile_env!(
                              :membrane_rtp_plugin,
                              :fir_throttle_duration_ms
                            )

  defmodule FrameCounter do
    use Membrane.Sink

    def_input_pad :input, flow_control: :manual, demand_unit: :buffers, accepted_format: _any

    @impl true
    def handle_init(_ctx, _opts), do: {[], %{counter: 0}}

    @impl true
    def handle_playing(_ctx, state),
      do: {[demand: :input], state}

    @impl true
    def handle_buffer(_pad, _buff, _context, %{counter: c}),
      do: {[demand: :input], %{counter: c + 1}}

    @impl true
    def handle_end_of_stream(_pad, _ctx, %{counter: c} = state),
      do: {[notify_parent: {:frame_count, c}], state}
  end

  test "RTP stream passes through bin properly" do
    structure =
      child(:pcap, %Membrane.Pcap.Source{path: @pcap_file})
      |> child(:rtp_parser, RTP.Parser)
      |> child(:rtp, %StreamReceiveBin{
        clock_rate: @h264_clock_rate,
        depayloader: H264.Depayloader,
        remote_ssrc: @ssrc,
        local_ssrc: 0,
        rtcp_report_interval: Membrane.Time.seconds(5)
      })
      |> child(:video_parser, %Membrane.H264.Parser{
        generate_best_effort_timestamps: %{framerate: {30, 1}}
      })
      |> child(:frame_counter, FrameCounter)

    pipeline = Testing.Pipeline.start_link_supervised!(spec: structure)

    assert_start_of_stream(pipeline, :rtp_parser)
    assert_start_of_stream(pipeline, :frame_counter)
    assert_end_of_stream(pipeline, :rtp_parser, :input, 4000)
    assert_end_of_stream(pipeline, :frame_counter)
    assert_pipeline_notified(pipeline, :frame_counter, {:frame_count, count})
    assert count == @frames_count

    Testing.Pipeline.terminate(pipeline)
  end

  test "RTCP reports are generated properly" do
    pcap_file = "test/fixtures/rtp/session/h264_before_sr.pcap"

    structure =
      child(:pcap, %Membrane.Pcap.Source{
        path: pcap_file,
        packet_transformer: fn %ExPcap.Packet{
                                 packet_header: %{ts_sec: sec, ts_usec: usec},
                                 parsed_packet_data: {_, payload}
                               } ->
          arrival_ts = Membrane.Time.seconds(sec) + Membrane.Time.microseconds(usec)
          %Membrane.Buffer{payload: payload, metadata: %{arrival_ts: arrival_ts}}
        end
      })
      |> child(:rtp_parser, RTP.Parser)
      |> child(:rtp, %StreamReceiveBin{
        clock_rate: @h264_clock_rate,
        depayloader: H264.Depayloader,
        local_ssrc: 0,
        remote_ssrc: 4_194_443_425,
        rtcp_report_interval: Membrane.Time.seconds(5)
      })
      |> child(:sink, Testing.Sink)

    pipeline = Testing.Pipeline.start_link_supervised!(spec: structure)

    assert_start_of_stream(pipeline, :rtp_parser)
    assert_start_of_stream(pipeline, :sink)
    assert_end_of_stream(pipeline, :rtp_parser, :input, 4000)
    assert_end_of_stream(pipeline, :sink)
    Testing.Pipeline.terminate(pipeline)
  end

  defmodule NoopSource do
    use Membrane.Source

    def_output_pad :output, flow_control: :push, accepted_format: _any

    @impl true
    def handle_event(:output, event, _ctx, state) do
      {[notify_parent: event], state}
    end
  end

  defmodule KeyframeRequester do
    use Membrane.Sink

    def_input_pad :input, flow_control: :auto, accepted_format: _any

    def_options delay: [spec: integer()]

    @impl true
    def handle_init(_ctx, %{delay: delay}) do
      {[], delay}
    end

    @impl true
    def handle_playing(_ctx, delay) do
      keyframe_request = {:event, {:input, %Membrane.KeyframeRequestEvent{}}}
      Process.send_after(self(), keyframe_request, delay)
      {[keyframe_request, keyframe_request], delay}
    end

    @impl true
    def handle_info(keyframe_request, _ctx, delay) do
      {[keyframe_request, keyframe_request], delay}
    end
  end

  test "FIRs are sent and throttled" do
    remote_ssrc = 4_194_443_425
    half_throttle_duration = div(@fir_throttle_duration_ms, 2)
    delta = div(@fir_throttle_duration_ms, 10)

    structure =
      child(:src, NoopSource)
      |> child(:rtp, %StreamReceiveBin{
        clock_rate: @h264_clock_rate,
        depayloader: H264.Depayloader,
        local_ssrc: 0,
        remote_ssrc: remote_ssrc,
        rtcp_report_interval: nil
      })
      |> child(:sink, %KeyframeRequester{delay: @fir_throttle_duration_ms + delta})

    pipeline = Testing.Pipeline.start_link_supervised!(spec: structure)

    assert_pipeline_notified(pipeline, :src, %Membrane.RTCPEvent{rtcp: rtcp})
    assert %FeedbackPacket{payload: fir} = rtcp
    assert fir == %FeedbackPacket.FIR{target_ssrc: remote_ssrc, seq_num: 0}

    # Ensure we're not getting it twice before throttle duration passes
    refute_pipeline_notified(pipeline, :src, %Membrane.RTCPEvent{}, half_throttle_duration)

    # Then ensure we get the next one
    assert_pipeline_notified(
      pipeline,
      :src,
      %Membrane.RTCPEvent{rtcp: rtcp},
      half_throttle_duration + delta
    )

    assert %FeedbackPacket{payload: fir} = rtcp
    assert fir == %FeedbackPacket.FIR{target_ssrc: remote_ssrc, seq_num: 1}

    # ... and only one
    refute_pipeline_notified(pipeline, :src, %Membrane.RTCPEvent{}, half_throttle_duration)
    Testing.Pipeline.terminate(pipeline)
  end
end
