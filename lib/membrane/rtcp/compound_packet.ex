defmodule Membrane.RTCP.CompoundPacket do
  @moduledoc """
  Parses compound RTCP packets into a list of subpackets.
  """

  alias Membrane.RTCP.{Header, Packet}
  alias Membrane.RTP.Utils

  defstruct [:packets]

  @type t :: %__MODULE__{packets: [Packet.t()]}

  @spec serialize(t()) :: binary()
  def serialize(%__MODULE__{packets: packets}) do
    Enum.map_join(packets, &Packet.serialize/1)
  end

  @spec parse(binary()) :: {:ok, t()} | {:error, any()}
  def parse(compound_packet) do
    with {:ok, packets} <- do_parse(compound_packet, []) do
      {:ok, %__MODULE__{packets: packets}}
    end
  end

  defp do_parse(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp do_parse(<<raw_header::binary-size(4), body_and_rest::binary>>, acc) do
    with {:ok, result} <- Header.parse(raw_header),
         # length includes raw_header size
         body_size = result.length - 4,
         <<body::binary-size(body_size), rest::binary>> <- body_and_rest,
         {:ok, {body, _padding}} <- Utils.strip_padding(body, result.padding?),
         {:ok, packet} <- Packet.parse_body(body, result.header) do
      do_parse(rest, [packet | acc])
    else
      {:error, reason} -> {:error, reason}
      _error -> {:error, :malformed_packet}
    end
  end

  defp do_parse(_binary, _acc), do: {:error, :malformed_packet}
end
