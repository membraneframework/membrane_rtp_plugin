defmodule Membrane.RTP.Session.ReceiveBinTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions

  alias Membrane.RTP
  alias Membrane.Testing

  @pcap_file "test/fixtures/rtp/session/demo_rtp.pcap"

  @audio_stream %{ssrc: 439_017_412, frames_n: 20}
  @video_stream %{ssrc: 670_572_639, frames_n: 287}

  @fmt_mapping %{96 => :h264, 127 => :mpa}

  defmodule DynamicPipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(%{pcap_file: pcap_file, fmt_mapping: fmt_mapping}) do
      spec = %ParentSpec{
        children: [
          pcap: %Membrane.Element.Pcap.Source{path: pcap_file},
          rtp: %RTP.Session.ReceiveBin{fmt_mapping: fmt_mapping}
        ],
        links: [link(:pcap) |> via_in(:rtp_in) |> to(:rtp)]
      }

      {{:ok, spec: spec}, %{}}
    end

    @impl true
    def handle_notification({:new_rtp_stream, ssrc, _pt}, :rtp, state) do
      spec = %ParentSpec{
        children: [
          {ssrc, Testing.Sink}
        ],
        links: [
          link(:rtp) |> via_out(Pad.ref(:output, ssrc)) |> to(ssrc)
        ]
      }

      {{:ok, spec: spec}, state}
    end

    def handle_notification(_, _, state) do
      {:ok, state}
    end
  end

  test "RTP streams passes through RTP bin properly" do
    {:ok, pipeline} =
      %Testing.Pipeline.Options{
        module: DynamicPipeline,
        custom_args: %{
          pcap_file: @pcap_file,
          fmt_mapping: @fmt_mapping
        }
      }
      |> Testing.Pipeline.start_link()

    Testing.Pipeline.play(pipeline)
    assert_pipeline_playback_changed(pipeline, _, :playing)

    audio_ssrc = @audio_stream.ssrc
    video_ssrc = @video_stream.ssrc

    assert_start_of_stream(pipeline, ^audio_ssrc)
    assert_start_of_stream(pipeline, ^video_ssrc)

    1..@video_stream.frames_n
    |> Enum.each(fn _i ->
      assert_sink_buffer(pipeline, video_ssrc, %Membrane.Buffer{})
    end)

    1..@audio_stream.frames_n
    |> Enum.each(fn _i ->
      assert_sink_buffer(pipeline, audio_ssrc, %Membrane.Buffer{})
    end)

    assert_end_of_stream(pipeline, ^audio_ssrc)
    assert_end_of_stream(pipeline, ^video_ssrc)
  end
end
