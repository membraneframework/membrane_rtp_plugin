defmodule Membrane.RTP.DemuxerMuxerTest do
  @moduledoc false
  use ExUnit.Case
  import Membrane.Testing.Assertions
  alias Membrane.RTP
  alias Membrane.Testing

  @rtp_input %{
    pcap_path: "test/fixtures/rtp/session/demo_rtp.pcap",
    packets: 862
  }

  @max_sequence_number Bitwise.bsl(1, 16) - 1
  @max_timestamp Bitwise.bsl(1, 32) - 1

  defmodule ReferencePipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(_ctx, opts) do
      spec =
        child(:source, %Membrane.Pcap.Source{path: opts.input_path})
        |> child(:sink, Membrane.Testing.Sink)

      {[spec: spec], %{}}
    end
  end

  defmodule DynamicSubjectPipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(_ctx, opts) do
      spec = [
        child(:source, %Membrane.Pcap.Source{path: opts.input_path})
        |> child(:rtp_demuxer, Membrane.RTP.Demuxer),
        child(:rtp_muxer, Membrane.RTP.Muxer)
        |> child(:sink, Membrane.Testing.Sink)
      ]

      {[spec: spec], %{}}
    end

    @impl true
    def handle_child_notification({:new_rtp_stream, %{ssrc: ssrc}}, :rtp_demuxer, _ctx, state) do
      spec =
        get_child(:rtp_demuxer)
        |> via_out(:output, options: [stream_id: {:ssrc, ssrc}, jitter_buffer_latency: 0])
        |> get_child(:rtp_muxer)

      {[spec: spec], state}
    end
  end

  defmodule UpfrontSubjectPipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(_ctx, opts) do
      spec = [
        child(:source, %Membrane.Pcap.Source{path: opts.input_path})
        |> child(:rtp_demuxer, Membrane.RTP.Demuxer)
        |> via_out(:output, options: [stream_id: {:encoding_name, :H264}])
        |> child(:rtp_muxer, Membrane.RTP.Muxer)
        |> child(:sink, Membrane.Testing.Sink),
        get_child(:rtp_demuxer)
        |> via_out(:output, options: [stream_id: {:encoding_name, :AAC}])
        |> get_child(:rtp_muxer)
      ]

      {[spec: spec], %{}}
    end
  end

  describe "Demuxed and muxed stream is the same as unchanged one" do
    test "when using a dynamically linking pipeline" do
      perform_test(DynamicSubjectPipeline)
    end

    test "when using a pipeline linked upfront" do
      perform_test(UpfrontSubjectPipeline)
    end
  end

  defp perform_test(subject_pipeline_module) do
    reference_pipeline =
      Testing.Pipeline.start_supervised!(
        module: ReferencePipeline,
        custom_args: %{input_path: @rtp_input.pcap_path}
      )

    subject_pipeline =
      Testing.Pipeline.start_supervised!(
        module: subject_pipeline_module,
        custom_args: %{input_path: @rtp_input.pcap_path}
      )

    assert_start_of_stream(reference_pipeline, :sink)
    assert_start_of_stream(subject_pipeline, :sink)

    reference_normalized_packets = get_normalized_packets(reference_pipeline, @rtp_input.packets)
    subject_normalized_packets = get_normalized_packets(subject_pipeline, @rtp_input.packets)

    assert reference_normalized_packets == subject_normalized_packets

    assert_end_of_stream(reference_pipeline, :sink)
    assert_end_of_stream(subject_pipeline, :sink)
    Testing.Pipeline.terminate(reference_pipeline)
    Testing.Pipeline.terminate(subject_pipeline)
  end

  @spec get_normalized_packets(pid(), non_neg_integer()) ::
          %{RTP.encoding_name() => [ExRTP.Packet.t()]}
  defp get_normalized_packets(pipeline, buffers_amount) do
    Enum.map(1..buffers_amount, fn _i ->
      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{
        payload: payload
      })

      {:ok, packet} = ExRTP.Packet.decode(payload)

      packet
    end)
    |> Enum.group_by(& &1.payload_type)
    |> Map.new(fn {payload_type, packets} ->
      %{encoding_name: encoding_name} = RTP.PayloadFormat.get_payload_type_mapping(payload_type)

      %{ssrc: ssrc, sequence_number: first_sequence_number, timestamp: first_timestamp} =
        List.first(packets)

      normalized_packets =
        packets
        |> Enum.map(fn packet ->
          %{
            packet
            | ssrc: packet.ssrc - ssrc,
              # modulo to account for wrapping
              sequence_number:
                Integer.mod(
                  packet.sequence_number - first_sequence_number,
                  @max_sequence_number + 1
                ),
              # round to ignore insignificant differences in timestamps
              timestamp:
                round(Integer.mod(packet.timestamp - first_timestamp, @max_timestamp + 1) / 10)
          }
        end)

      {encoding_name, normalized_packets}
    end)
  end
end
