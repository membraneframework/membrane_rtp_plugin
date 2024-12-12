defmodule Membrane.RTP.DemuxerTest do
  @moduledoc false
  use ExUnit.Case
  import Membrane.Testing.Assertions
  alias Membrane.Testing

  @rtp_input %{
    pcap_path: "test/fixtures/rtp/session/demo_rtp.pcap",
    audio: %{ssrc: 439_017_412, packets: 20, payload_type: 127},
    video: %{ssrc: 670_572_639, packets: 842, payload_type: 96}
  }

  defmodule UpfrontPayloadTypePipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(_ctx, opts) do
      spec = [
        child(:pcap_source, %Membrane.Pcap.Source{path: opts.pcap_path})
        |> child(:demuxer, Membrane.RTP.Demuxer)
        |> via_out(:output, options: [stream_id: {:payload_type, opts.audio.payload_type}])
        |> child({:sink, opts.audio.ssrc}, Testing.Sink),
        get_child(:demuxer)
        |> via_out(:output, options: [stream_id: {:payload_type, opts.video.payload_type}])
        |> child({:sink, opts.video.ssrc}, Testing.Sink)
      ]

      {[spec: spec], %{}}
    end
  end

  defmodule UpfrontEncodingNamePipeline do
    use Membrane.Pipeline

    @fmt_mapping %{
      96 => %{encoding_name: :Oldman, clock_rate: 90_000},
      127 => %{encoding_name: :Sysy, clock_rate: 48_000}
    }

    @impl true
    def handle_init(_ctx, opts) do
      spec = [
        child(:pcap_source, %Membrane.Pcap.Source{path: opts.pcap_path})
        |> child(:demuxer, %Membrane.RTP.Demuxer{fmt_mapping: @fmt_mapping})
        |> via_out(:output, options: [stream_id: {:encoding_name, :Sysy}])
        |> child({:sink, opts.audio.ssrc}, Testing.Sink),
        get_child(:demuxer)
        |> via_out(:output, options: [stream_id: {:encoding_name, :Oldman}])
        |> child({:sink, opts.video.ssrc}, Testing.Sink)
      ]

      {[spec: spec], %{}}
    end
  end

  defmodule DynamicPipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(_ctx, opts) do
      spec =
        child(:pcap_source, %Membrane.Pcap.Source{path: opts.pcap_path})
        |> child(:demuxer, Membrane.RTP.Demuxer)

      {[spec: spec], %{}}
    end

    @impl true
    def handle_child_notification({:new_rtp_stream, ssrc, pt, _exts}, :demuxer, _ctx, state) do
      spec =
        get_child(:demuxer)
        |> via_out(:output, options: [stream_id: {:payload_type, pt}])
        |> child({:sink, ssrc}, Testing.Sink)

      {[spec: spec], state}
    end
  end

  defp perform_test(pipeline_module) do
    pipeline =
      Testing.Pipeline.start_supervised!(module: pipeline_module, custom_args: @rtp_input)

    %{audio: %{ssrc: audio_ssrc}, video: %{ssrc: video_ssrc}} =
      @rtp_input

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

  describe "Demuxer demuxes correct amount of packets" do
    test "when it's pads were linked upfront based on payload types" do
      perform_test(UpfrontPayloadTypePipeline)
    end

    test "when it's pads were linked upfront based on encoding names" do
      perform_test(UpfrontEncodingNamePipeline)
    end

    test "when it's pads were linked based on notifications received" do
      perform_test(DynamicPipeline)
    end
  end
end
