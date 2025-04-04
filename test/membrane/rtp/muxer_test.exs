defmodule Membrane.RTP.MuxerTest do
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
        child(:hackney_source, %Membrane.Hackney.Source{
          location:
            "https://raw.githubusercontent.com/membraneframework/static/gh-pages/samples/big-buck-bunny/bun10s.mp4",
          hackney_opts: [follow_redirect: true]
        })
        |> child(:mp4_demuxer, Membrane.MP4.Demuxer.ISOM)
        |> via_out(:output, options: [kind: :video])
        |> child(:h264_parser, %Membrane.H264.Parser{
          output_stream_structure: :annexb,
          output_alignment: :nalu
        })
        |> child(:h264_payloader, Membrane.RTP.H264.Payloader)
        |> child(:rtp_muxer, %Membrane.RTP.Muxer{srtp: opts.srtp})
        |> child(:sink, Membrane.Testing.Sink),
        get_child(:mp4_demuxer)
        |> via_out(:output, options: [kind: :audio])
        |> child(:aac_parser, %Membrane.AAC.Parser{out_encapsulation: :none})
        |> child(:aac_payloader, %Membrane.RTP.AAC.Payloader{mode: :hbr, frames_per_packet: 1})
        |> get_child(:rtp_muxer)
      ]

      {[spec: spec], %{}}
    end
  end

  describe "Muxer muxes correct amount of packets" do
    test "when encrypting the stream with SRTP" do
      policy = %ExLibSRTP.Policy{ssrc: :any_inbound, key: String.duplicate("b", 30)}
      perform_test([policy])
    end

    test "when not encrypting the stream with SRTP" do
      perform_test(false)
    end
  end

  defp perform_test(srtp) do
    pipeline =
      Testing.Pipeline.start_supervised!(module: Pipeline, custom_args: %{srtp: srtp})

    %{audio: %{payload_type: audio_payload_type}, video: %{payload_type: video_payload_type}} =
      @rtp_output

    assert_start_of_stream(pipeline, :sink)

    1..@rtp_output.video.packets
    |> Enum.each(fn _i ->
      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{
        metadata: %{rtp: %ExRTP.Packet{payload_type: ^video_payload_type}}
      })
    end)

    1..@rtp_output.audio.packets
    |> Enum.each(fn _i ->
      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{
        metadata: %{rtp: %ExRTP.Packet{payload_type: ^audio_payload_type}}
      })
    end)

    assert_end_of_stream(pipeline, :sink)
    Testing.Pipeline.terminate(pipeline)
  end
end
