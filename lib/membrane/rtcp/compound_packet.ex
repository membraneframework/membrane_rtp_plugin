defmodule Membrane.RTCP.CompoundPacket do
  @moduledoc """
  Parses compound RTCP packets into a list of subpackets.
  """

  alias Membrane.RTCP.{
    Packet,
    AppPacket,
    ByePacket,
    SenderReportPacket,
    ReceiverReportPacket,
    SdesPacket
  }

  @type subpacket_t :: AppPacket.t() | ByePacket.t() | ReportPacket.t() | SdesPacket.t()

  @type t :: [subpacket_t()]

  @spec to_binary(t()) :: binary()
  def to_binary(packets) do
    packets
    |> Enum.map(&Packet.to_binary/1)
    |> Enum.join()
  end

  @spec parse(binary()) :: {:ok, t()} | {:error, any()}
  def parse(compound_packet) do
    do_parse(compound_packet, [])
  end

  defp do_parse(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp do_parse(<<raw_header::binary-size(4), body_and_rest::binary>>, packets) do
    header = Packet.Header.parse!(raw_header)
    # length includes raw_header size
    body_size = header.length - 4
    <<body::binary-size(body_size), rest::binary>> = body_and_rest

    body = Packet.strip_padding(body, header.padding?)

    with {:ok, packet} <- parse_subpacket(body, header) do
      do_parse(rest, [packet | packets])
    end
  end

  defp parse_subpacket(packet, %{packet_type: pt, packet_specific: packet_specific}) do
    with {:ok, packet_module} <- decode_packet_type(pt) do
      packet_module.decode(packet, packet_specific)
    end
  end

  defp decode_packet_type(200), do: {:ok, SenderReportPacket}
  defp decode_packet_type(201), do: {:ok, ReceiverReportPacket}
  defp decode_packet_type(202), do: {:ok, SdesPacket}
  defp decode_packet_type(203), do: {:ok, ByePacket}
  defp decode_packet_type(204), do: {:ok, AppPacket}
  defp decode_packet_type(_pt), do: {:error, :unknown_pt}
end
