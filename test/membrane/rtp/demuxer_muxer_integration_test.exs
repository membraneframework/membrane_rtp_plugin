defmodule Membrane.RTP.DemuxerTest do
  @moduledoc false
  use ExUnit.Case
  import Membrane.Testing.Assertions
  alias Membrane.RTP
  alias Membrane.Testing

  @rtp_input %{
    pcap_path: "test/fixtures/rtp/session/demo_rtp.pcap",
    audio: %{ssrc: 439_017_412, packets: 20},
    video: %{ssrc: 670_572_639, packets: 842}
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

  test "Muxer muxes correct amount of packets" do
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
    reference_buffer_payloads = get_payloads(reference_pipeline, 862)
    subject_buffer_payloads = get_payloads(subject_pipeline, 862)

    assert reference_buffers == subject_buffers

    assert_end_of_stream(reference_pipeline, :sink)
    assert_end_of_stream(subject_pipeline, :sink)
    Testing.Pipeline.terminate(reference_pipeline)
    Testing.Pipeline.terminate(subject_pipeline)
  end

  defp get_payloads(pipeline, buffers_amount) do
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

      sorted_buffer_payloads =
        payload_type_buffers
        |> Enum.sort(&(&1.sequence_number < &2.sequence_number))
        |> Enum.map(& &1.payload)

      {encoding_name, sorted_buffer_payloads}
    end)
  end
end
