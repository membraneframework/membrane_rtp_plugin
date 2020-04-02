defmodule Membrane.RTCP.Packet do
  @moduledoc """
  Functions common to all RTCP Packets
  """

  # TODO: Add a behaviour for packets

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
  #   pad_bits = body |> bit_size |> rem(32)
  #   end_pad = <<0::size(pad_bits)>>
  #   body <> end_pad
  # end

  defdelegate ignore_padding(body, present?), to: Membrane.RTP.Packet
end
