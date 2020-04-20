defmodule Membrane.RTCP.Packet do
  @moduledoc """
  Functions common to all RTCP Packets
  """

  alias Membrane.RTCP.{
    AppPacket,
    ByePacket,
    Pakcet.Header,
    ReceiverReportPacket,
    SdesPacket,
    SenderReportPacket
  }

  @type t ::
          AppPacket.t()
          | ByePacket.t()
          | ReceiverReportPacket.t()
          | SenderReportPacket.t()
          | SdesPacket.t()

  # TODO: Remove if it won't be used by SRTCP
  # @doc """
  # Adds a padding to align body to a 32 bit boundary
  # """
  # @spec align(binary()) :: binary()
  # def align(body) do
  #   case body |> bit_size |> rem(32) do
  #     0 ->
  #       body

  #     unaligned_bits ->
  #       pad_bits = 32 - unaligned_bits
  #       end_pad = <<0::size(pad_bits)>>
  #       body <> end_pad
  #   end
  # end
  #

  @doc """
  Converts packet structure into binary
  """
  @spec to_binary(t()) :: binary()
  def to_binary(%packet_module{} = packet) do
    {body, packet_type, packet_specific} = packet_module.encode(packet)
    length = body |> byte_size() |> div(4)

    # `length` is simplified from `length - 1 + 1` to include header size
    header = <<2::2, 0::1, packet_specific::5, packet_type::8, length::16>>
    header <> body
  end

  @doc """
  Parses packet body using data from parsed header
  """
  @spec parse_body(binary(), Header.t()) :: {:ok, t()} | {:error, reason :: atom()}
  def parse_body(packet, %{packet_type: pt, packet_specific: packet_specific}) do
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

  defdelegate strip_padding(body, present?), to: Membrane.RTP.Packet

  @doc """
  Decodes binary with packet body (without header) into packet struct. Used by `parse/1`
  """
  @callback decode(binary(), packet_specific :: Header.packet_specific_t()) ::
              {:ok, struct()} | {:error, atom()}

  @doc """
  Encodes packet struct into the tuple used by `to_binary/1`
  """
  @callback encode(struct()) ::
              {body :: binary(), packet_type :: Header.packet_type_t(),
               packet_specific :: Header.packet_specific_t()}
end
