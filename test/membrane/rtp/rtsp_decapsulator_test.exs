defmodule Membrane.RTP.RTSPDecapsulatorTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec

  alias Membrane.RTP.RTSP.Depayloader
  alias Membrane.Testing.{Sink, Source, Pipeline}

  @header_length 4

  defp encapsulate_rtp_packets(rtp_packets) do
    Enum.map(rtp_packets, &<<"$", 0, byte_size(&1)::size(16), &1::binary>>)
  end

  defp create_tcp_segments(encapsulated_rtp_packets, tcp_segments_lengths) do
    assert Enum.sum(tcp_segments_lengths) ==
             Enum.sum(Enum.map(encapsulated_rtp_packets, &byte_size(&1)))

    encaplsulated_rtp_packets_binary = Enum.join(encapsulated_rtp_packets)

    {tcp_segments, _length} =
      Enum.map_reduce(tcp_segments_lengths, 0, fn len, pos ->
        {:binary.part(encaplsulated_rtp_packets_binary, pos, len), pos + len}
      end)

    tcp_segments
  end

  defp perform_standard_test(rtp_packets_lengths, tcp_segments_lengths) do
    rtp_packets = Enum.map(rtp_packets_lengths, &<<0::size(&1)-unit(8)>>)

    tcp_segments =
      rtp_packets |> encapsulate_rtp_packets() |> create_tcp_segments(tcp_segments_lengths)

    pipeline =
      Pipeline.start_link_supervised!(
        spec:
          child(:source, %Source{
            output: tcp_segments
          })
          |> child(:depayloader, Depayloader)
          |> child(:sink, Sink)
      )

    Enum.each(rtp_packets, fn packet ->
      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: ^packet})
    end)

    Pipeline.terminate(pipeline)
  end

  describe "RTSP Decapsulator decapsulates correctly" do
    test "when one tcp segment is one rtp packet" do
      rtp_packets_lengths = 10..20
      tcp_segments_lengths = Enum.map(rtp_packets_lengths, &(&1 + @header_length))

      perform_standard_test(rtp_packets_lengths, tcp_segments_lengths)
    end

    test "when there are multiple (3) rtp packets in one tcp segment" do
      rtp_packets_lengths = 10..40

      tcp_segments_lengths =
        rtp_packets_lengths
        |> Enum.chunk_every(3)
        |> Enum.map(&(Enum.sum(&1) + length(&1) * @header_length))

      perform_standard_test(rtp_packets_lengths, tcp_segments_lengths)
    end

    test "when rtp packets are spread across multiple (3) tcp segments" do
      tcp_segments_lengths =
        Enum.flat_map(rtp_packets_lengths, fn len ->
          tcp_segment_base_length = div(len + @header_length, 3)
          [tcp_segment_base_length - 1, tcp_segment_base_length, tcp_segment_base_length + 1]
        end)

      perform_standard_test(rtp_packets_lengths, tcp_segments_lengths)
    end
  end
end
