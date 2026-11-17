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

  defmodule Reorderer do
    use Membrane.Filter

    def_input_pad :input, accepted_format: _any
    def_output_pad :output, accepted_format: _any

    @impl true
    def handle_init(_ctx, _opts) do
      {[], %{buffers: []}}
    end

    @impl true
    def handle_buffer(:input, buffer, _ctx, state) do
      case state.buffers do
        [first_buffer, second_buffer] ->
          {[buffer: {:output, [first_buffer, buffer, second_buffer]}], %{buffers: []}}

        buffer_list ->
          {[], %{state | buffers: buffer_list ++ [buffer]}}
      end
    end

    @impl true
    def handle_end_of_stream(:input, _ctx, state) do
      {[buffer: {:output, state.buffers}, end_of_stream: :output], state}
    end
  end

  defmodule UpfrontPayloadTypePipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(_ctx, opts) do
      spec = [
        child(:pcap_source, %Membrane.Pcap.Source{path: opts.pcap_path})
        |> then(&if opts.reorder_packets, do: child(&1, Reorderer), else: &1)
        |> child(:demuxer, Membrane.RTP.Demuxer)
        |> via_out(:output,
          options: [
            stream_id: {:payload_type, opts.audio.payload_type},
            jitter_buffer_latency: Membrane.Time.milliseconds(5)
          ]
        )
        |> child({:sink, opts.audio.ssrc}, Testing.Sink),
        get_child(:demuxer)
        |> via_out(:output,
          options: [
            stream_id: {:payload_type, opts.video.payload_type},
            jitter_buffer_latency: Membrane.Time.milliseconds(5)
          ]
        )
        |> child({:sink, opts.video.ssrc}, Testing.Sink)
      ]

      {[spec: spec], %{}}
    end
  end

  defmodule UpfrontEncodingNamePipeline do
    use Membrane.Pipeline

    @payload_type_mapping %{
      96 => %{encoding_name: :Oldman, clock_rate: 90_000},
      127 => %{encoding_name: :Sysy, clock_rate: 48_000}
    }

    @impl true
    def handle_init(_ctx, opts) do
      spec = [
        child(:pcap_source, %Membrane.Pcap.Source{path: opts.pcap_path})
        |> child(:demuxer, %Membrane.RTP.Demuxer{payload_type_mapping: @payload_type_mapping})
        |> via_out(:output,
          options: [
            stream_id: {:encoding_name, :Sysy},
            jitter_buffer_latency: Membrane.Time.milliseconds(5)
          ]
        )
        |> child({:sink, opts.audio.ssrc}, Testing.Sink),
        get_child(:demuxer)
        |> via_out(:output,
          options: [
            stream_id: {:encoding_name, :Oldman},
            jitter_buffer_latency: Membrane.Time.milliseconds(5)
          ]
        )
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
        |> then(&if opts.reorder_packets, do: child(&1, Reorderer), else: &1)
        |> child(:demuxer, Membrane.RTP.Demuxer)

      {[spec: spec], %{}}
    end

    @impl true
    def handle_child_notification({:new_rtp_stream, %{ssrc: ssrc}}, :demuxer, _ctx, state) do
      spec =
        get_child(:demuxer)
        |> via_out(:output,
          options: [
            stream_id: {:ssrc, ssrc},
            jitter_buffer_latency: Membrane.Time.milliseconds(5)
          ]
        )
        |> child({:sink, ssrc}, Testing.Sink)

      {[spec: spec], state}
    end
  end

  defp perform_test(pipeline_module, reorder_packets \\ false) do
    pipeline =
      Testing.Pipeline.start_supervised!(
        module: pipeline_module,
        custom_args: Map.put(@rtp_input, :reorder_packets, reorder_packets)
      )

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

    test "when packets are reordered in a pipeline linked upfront" do
      perform_test(UpfrontPayloadTypePipeline, true)
    end

    test "when packets are reordered in a dynamic pipeline" do
      perform_test(DynamicPipeline, true)
    end
  end

  describe "Demuxer drops packets that cannot be parsed" do
    # libavformat and gortsplib drop such packets and carry on; one of them used to
    # take the whole pipeline down.
    test "and keeps demuxing the stream" do
      import Membrane.ChildrenSpec

      packet = fn sequence_number ->
        ExRTP.Packet.new(<<sequence_number>>,
          payload_type: 96,
          sequence_number: sequence_number,
          timestamp: sequence_number * 3000,
          ssrc: 0x1234
        )
        |> ExRTP.Packet.encode()
      end

      <<truncated_header::binary-size(7), _rest::binary>> = packet.(2)
      # the padding bit is set, but the last byte claims more padding than there is data
      bad_padding = <<2::2, 1::1, 0::5, 96, 3::16, 9000::32, 0x1234::32, 200>>

      payloads = [packet.(1), <<>>, <<0x80>>, truncated_header, bad_padding, packet.(4)]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          pipeline =
            Testing.Pipeline.start_link_supervised!(
              spec:
                child(:source, %Testing.Source{
                  output: payloads,
                  stream_format: %Membrane.RemoteStream{
                    type: :packetized,
                    content_format: Membrane.RTP
                  }
                })
                |> child(:demuxer, Membrane.RTP.Demuxer)
                |> via_out(:output,
                  options: [
                    stream_id: {:payload_type, 96},
                    clock_rate: 90_000,
                    jitter_buffer_latency: 0
                  ]
                )
                |> child(:sink, Testing.Sink)
            )

          assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: <<1>>})
          assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: <<4>>})
          assert_end_of_stream(pipeline, :sink)
          Testing.Pipeline.terminate(pipeline)
        end)

      # all four are reported, and only the first with the warning that announces the rest
      assert [_first, _second, _third, _fourth, _rest] =
               String.split(log, "Dropping a malformed RTP packet")

      assert [_before, _after] =
               String.split(log, "Further ones will be logged at the debug level")
    end
  end
end
