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

  defmodule SubjectPipeline do
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
    def handle_child_notification(
          {:new_rtp_stream, ssrc, pt, _extensions},
          :rtp_demuxer,
          _ctx,
          state
        ) do
      %{encoding_name: encoding_name, clock_rate: clock_rate} =
        Membrane.RTP.PayloadFormat.get_payload_type_mapping(pt)

      spec =
        get_child(:rtp_demuxer)
        |> via_out(Pad.ref(:output, ssrc))
        |> child({:jitter_buffer, ssrc}, %Membrane.RTP.JitterBuffer{clock_rate: clock_rate})
        |> via_in(:input,
          options: [
            encoding: encoding_name
          ]
        )
        |> get_child(:rtp_muxer)

      {[spec: spec], state}
    end
  end

  test "Demuxed and muxed stream is the same as unchanged one" do
    reference_pipeline =
      Testing.Pipeline.start_supervised!(
        module: ReferencePipeline,
        custom_args: %{input_path: @rtp_input.pcap_path}
      )

    subject_pipeline =
      Testing.Pipeline.start_supervised!(
        module: SubjectPipeline,
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
    |> Map.new(fn {payload_type, payload_type_buffers} ->
      %{encoding_name: encoding_name} = RTP.PayloadFormat.get_payload_type_mapping(payload_type)

      sorted_packets =
        payload_type_buffers
        |> Enum.sort(&(&1.sequence_number < &2.sequence_number))

      %{ssrc: ssrc, sequence_number: first_sequence_number, timestamp: first_timestamp} =
        List.first(sorted_packets)

      normalized_packets =
        sorted_packets
        |> Enum.map(fn packet ->
          packet
          |> Bunch.Struct.update_in(:ssrc, &(&1 - ssrc))
          |> Bunch.Struct.update_in(:sequence_number, &(&1 - first_sequence_number))
          # round to ignore insignificant differences in timestamps
          |> Bunch.Struct.update_in(:timestamp, &round((&1 - first_timestamp) / 10))
        end)

      {encoding_name, normalized_packets}
    end)
  end
end
