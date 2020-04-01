defmodule Membrane.RTCP.CompoundPacket do
  @moduledoc """
  Parses compound RTCP packets into a list of subpackets.
  """

  # parse - authenticates/decryptes an entire compound packet
  # do_parse - removes padding from compound packet
  # parse_subpacket - parses an extracted binary into a single subpacket (single SR/RR/BYE/etc)

  alias Membrane.RTCP.{
    Packet,
    AppPacket,
    ByePacket,
    ReportPacket,
    SdesPacket
  }

  defstruct [:subpackets, :srtcp_index]

  @type subpacket_t :: AppPacket.t() | ByePacket.t() | ReportPacket.t() | SdesPacket.t()

  @type t :: %__MODULE__{
          subpackets: [subpacket_t()],
          srtcp_index: non_neg_integer() | nil
        }

  @spec to_binary([subpacket_t()], Context.t()) :: binary()
  def to_binary(packets, _context) do
    # TODO handle SRTCP context
    packets
    |> Enum.map(& &1.__struct__.to_binary(&1))
    |> Enum.join()
  end

  @spec parse(
          binary(),
          Context.t() | nil
        ) ::
          {:ok, [subpacket_t()]} | {:error, any()}
  def parse(compound_packet, context \\ nil) do
    with {:ok, unsecured_compound} <- unsecure(compound_packet, context),
         {:ok, subpackets} <- do_parse(unsecured_compound, []) do
      {:ok, subpackets}
    end
  end

  defp unsecure(compound_packet, nil), do: {:ok, compound_packet}

  defp unsecure(compound_packet, context) do
    %{
      mki_size: mki_size,
      auth_tag_size: auth_tag_size
    } = context

    packet_size = byte_size(compound_packet) - div(mki_size + auth_tag_size + 32, 8)

    <<packets::binary-size(packet_size), _is_encrypted::1, _srtcp_index::31,
      _auth_tag::binary-size(auth_tag_size), _mki::size(mki_size)>> = compound_packet

    # TODO check auth and decrypt if necessary

    {:ok, packets}
  end

  defp do_parse(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp do_parse(
         <<2::2, p::1, count::5, pt::8, length::16, body_and_rest::binary>>,
         packets
       ) do
    body_size = 4 * length
    <<body::binary-size(body_size), rest::binary>> = body_and_rest

    body = Packet.ignore_padding(body, p == 1)

    with {:ok, packet} <- parse_subpacket(body, count, pt) do
      do_parse(rest, [packet | packets])
    end
  end

  defp parse_subpacket(packet, _count, pt) when pt in [200, 201],
    do: ReportPacket.parse(packet, pt == 200)

  defp parse_subpacket(packet, _count, 202), do: SdesPacket.parse(packet)
  defp parse_subpacket(packet, count, 203), do: ByePacket.parse(packet, count)
  defp parse_subpacket(packet, count, 204), do: AppPacket.parse(packet, count)
  defp parse_subpacket(_packet, _count, _pt), do: {:error, :unknown_pt}
end
