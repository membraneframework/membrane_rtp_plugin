defmodule Membrane.RTCP.Packet do
  @moduledoc """
  Functions common to all RTCP Packets
  """

  @doc """
  Calculates the value of length field based on body. Includes the size of a header
  in which it should be put.

  To quote the RFC:

  length: 16 bits
      The length of this RTCP packet in 32-bit words minus one,
      including the header and any padding.  (The offset of one makes
      zero a valid length and avoids a possible infinite loop in
      scanning a compound RTCP packet, while counting 32-bit words
      avoids a validity check for a multiple of 4.)
  """
  @spec calc_length(binary()) :: pos_integer()
  def calc_length(body) do
    words = body |> byte_size() |> div(4)

    # Simplified from `words - 1 + 1` to include header
    words
  end

  # TODO: Remove if it won't be used
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

  def to_binary(%packet_module{} = packet) do
    {body, packet_type, packet_specific} = packet_module.encode(packet)
    length = body |> byte_size() |> div(4)

    # `length` is simplified from `length - 1 + 1` to include header size
    header = <<2::2, 0::1, packet_specific::5, packet_type::8, length::16>>
    header <> body
  end

  defdelegate strip_padding(body, present?), to: Membrane.RTP.Packet

  @callback decode(binary(), packet_specific :: non_neg_integer()) ::
              {:ok, struct()} | {:error, atom()}
  @callback encode(struct()) ::
              {body :: binary(), packet_type :: pos_integer(),
               packet_specific :: non_neg_integer()}
end
