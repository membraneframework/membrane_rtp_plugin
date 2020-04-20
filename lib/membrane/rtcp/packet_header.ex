defmodule Membrane.RTCP.Packet.Header do
  @moduledoc """
  Struct describing 32-bit header common to all RTCP packets
  """

  @enforce_keys [:packet_type, :length, :packet_specific]
  defstruct @enforce_keys ++ [padding?: false]

  @type t :: %__MODULE__{
          padding?: boolean(),
          packet_specific: non_neg_integer(),
          packet_type: pos_integer(),
          length: pos_integer()
        }

  @spec parse!(binary()) :: t()
  def parse!(<<2::2, padding?::1, packet_specific::5, pt::8, length::16>>) do
    %__MODULE__{
      padding?: padding? == 1,
      packet_specific: packet_specific,
      packet_type: pt,
      length: (length + 1) * 4
    }
  end

  @spec to_binary(t()) :: binary()
  def to_binary(%__MODULE__{} = header) do
    padding? = if header.padding?, do: 1, else: 0
    length = div(header.length, 4) - 1
    <<2::2, padding?::1, header.packet_specific::5, header.packet_type::8, length::16>>
  end
end
