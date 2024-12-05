defmodule Membrane.RTP.DemuxerTest do
  @moduledoc false
  use ExUnit.Case
  import Membrane.Testing.Assertions
  alias Membrane.Testing

  @rtp_output %{
    video: %{payload_type: 96, packets: 1054},
    audio: %{payload_type: 127, packets: 431}
  }

  defmodule Pipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(_ctx, opts) do
      spec = [
        # child(:hackney_source, %Membrane.Hackney.Source{
        # location:
        # "https://raw.githubusercontent.com/membraneframework/static/gh-pages/samples/big-buck-bunny/bun33s.mp4",
        # hackney_opts: [follow_redirect: true]
        # })
        child(:file_source, %Membrane.File.Source{location: "aaa.mp4"})
        |> child(:mp4_demuxer, Membrane.MP4.Demuxer.ISOM)
        |> via_out(:output, options: [kind: :video])
        |> child(:h264_parser, %Membrane.H264.Parser{
          output_stream_structure: :annexb,
          output_alignment: :nalu
        })
        |> child(:h264_payloader, Membrane.RTP.H264.Payloader)
        |> via_in(:input, options: [encoding: :H264])
        |> child(:rtp_muxer, Membrane.RTP.Muxer)
        |> child(:rtp_demuxer, Membrane.RTP.Demuxer),
        get_child(:mp4_demuxer)
        |> via_out(:output, options: [kind: :audio])
        |> child(:aac_parser, %Membrane.AAC.Parser{out_encapsulation: :none})
        |> child(:aac_payloader, %Membrane.RTP.AAC.Payloader{mode: :hbr, frames_per_packet: 1})
        |> via_in(:input, options: [encoding: :AAC])
        |> get_child(:rtp_muxer),
        child(:mp4_muxer, Membrane.MP4.Muxer.ISOM)
        |> child(:file_sink, %Membrane.File.Sink{location: opts.output_path})
      ]

      {[spec: spec], %{}}
    end

    @impl true
    def handle_child_notification(
          {:new_rtp_stream, ssrc, pt, _extensions},
          :rtp_demuxer,
          _ctx,
          state
        ) do
      {jitter_buffer, depayloader, parser} =
        case Membrane.RTP.PayloadFormat.get_payload_type_mapping(pt) do
          %{encoding_name: :H264, clock_rate: clock_rate} ->
            {%Membrane.RTP.JitterBuffer{clock_rate: clock_rate}, Membrane.RTP.H264.Depayloader,
             %Membrane.H264.Parser{output_stream_structure: :avc1}}

          %{encoding_name: :AAC, clock_rate: clock_rate} ->
            {%Membrane.RTP.JitterBuffer{clock_rate: clock_rate},
             %Membrane.RTP.AAC.Depayloader{mode: :hbr},
             %Membrane.AAC.Parser{
               output_config: :esds,
               audio_specific_config: Base.decode16!("1210")
             }}
        end

      spec =
        get_child(:rtp_demuxer)
        |> via_out(Pad.ref(:output, ssrc))
        |> child({:jitter_buffer, ssrc}, jitter_buffer)
        |> child({:depayloader, ssrc}, depayloader)
        |> child({:parser, ssrc}, parser)
        |> get_child(:mp4_muxer)

      {[spec: spec], state}
    end
  end

  test "Muxer muxes correct amount of packets" do
    pipeline =
      Testing.Pipeline.start_supervised!(module: Pipeline, custom_args: %{output_path: "bbb.mp4"})

    # %{audio: %{payload_type: audio_payload_type}, video: %{payload_type: video_payload_type}} =
    # @rtp_output

    assert_start_of_stream(pipeline, :file_sink)

    # 1..@rtp_output.video.packets
    # |> Enum.each(fn _i ->
    # assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{
    # metadata: %{rtp: %ExRTP.Packet{payload_type: ^video_payload_type}}
    # })
    # end)

    # 1..@rtp_output.audio.packets
    # |> Enum.each(fn _i ->
    # assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{
    # metadata: %{rtp: %ExRTP.Packet{payload_type: ^audio_payload_type}}
    # })
    # end)

    assert_end_of_stream(pipeline, :file_sink)
    Testing.Pipeline.terminate(pipeline)
  end
end
