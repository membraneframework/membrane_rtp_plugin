defmodule Membrane.RTCP.TransportFeedbackPacket.NACK do
  @moduledoc """
  Generic Negative Acknowledgment packet
  """

  @behaviour Membrane.RTCP.TransportFeedbackPacket

  defstruct lost_packet_ids: []

  @impl true
  def decode(nack_fci) do
    for <<packet_id::unsigned-size(16), bit_mask::16-bits <- nack_fci>> do
      next_lost_packets =
        for(<<bit::1 <- bit_mask>>, do: bit)
        |> Enum.reverse()
        |> Enum.with_index(1)
        |> Enum.map(fn
          {1, position} -> position + packet_id
          {0, _position} -> nil
        end)

      [packet_id | next_lost_packets]
      |> Enum.reject(&(&1 === nil))
    end
    |> then(&{:ok, %__MODULE__{lost_packet_ids: List.flatten(&1)}})
  end

  @impl true
  def encode(%__MODULE__{lost_packet_ids: [reference_packet_id | _rest]}) do
    # FIXME: Encode bit mask
    <<reference_packet_id::unsigned-size(16), 0::unsigned-size(16)>>
  end
end
