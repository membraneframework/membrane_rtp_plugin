defmodule Membrane.RTP.DemuxerTest do
  @moduledoc false
  use ExUnit.Case
  import Membrane.Testing.Assertions
  alias Membrane.Testing

  @rtp_input %{
    pcap_path: "test/fixtures/rtp/session/demo_rtp.pcap",
    audio: %{ssrc: 439_017_412, packets: 20},
    video: %{ssrc: 670_572_639, packets: 842}
  }
  defmodule Pipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(_ctx, opts) do
      spec =
        child(:pcap_source, %Membrane.Pcap.Source{path: opts.pcap_path})
        |> child(:demuxer, Membrane.RTP.Demuxer)

      {[spec: spec], %{}}
    end

    @impl true
    def handle_child_notification(
          {:new_rtp_stream, ssrc, _pt, _extensions},
          :demuxer,
          _ctx,
          state
        ) do
      spec =
        get_child(:demuxer)
        |> via_out(Pad.ref(:output, ssrc))
        |> child({:sink, ssrc}, Testing.Sink)

      {[spec: spec], state}
    end
  end

  test "Demuxer demuxes correct amount of packets" do
    pipeline = Testing.Pipeline.start_supervised!(module: Pipeline, custom_args: @rtp_input)

    %{audio: %{ssrc: audio_ssrc}, video: %{ssrc: video_ssrc}} = @rtp_input

    assert_start_of_stream(pipeline, :demuxer)
    assert_start_of_stream(pipeline, {:sink, ^video_ssrc})
    assert_start_of_stream(pipeline, {:sink, ^audio_ssrc})

    1..@rtp_input.video.packets
    |> Enum.each(fn _i ->
      assert_sink_buffer(pipeline, {:sink, video_ssrc}, %Membrane.Buffer{})
    end)

    1..@rtp_input.audio.packets
    |> Enum.each(fn _i ->
      assert_sink_buffer(pipeline, {:sink, audio_ssrc}, %Membrane.Buffer{})
    end)

    assert_end_of_stream(pipeline, {:sink, ^video_ssrc})
    assert_end_of_stream(pipeline, {:sink, ^audio_ssrc})
    Testing.Pipeline.terminate(pipeline)
  end
end
