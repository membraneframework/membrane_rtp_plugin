defmodule Membrane.RTP.TWCCSender.ReceiverRate do
  @moduledoc false
  # module responsible for calculating bitrate
  # received by a receiver in last `window` time

  alias Membrane.Time

  @type t() :: %__MODULE__{
          value: float() | nil,
          # time window for measuring the received bitrate, between [0.5, 1]s (reffered to as "T" in the RFC)
          window: Time.t(),
          # accumulator for packets and their timestamps that have been received through target_receive_interval
          packets_received: [{Time.t(), pos_integer()}]
        }

  @enforce_keys [:window]
  defstruct @enforce_keys ++ [:value, packets_received: []]

  @spec new(Time.t()) :: t()
  def new(window), do: %__MODULE__{window: window}

  @spec update(t(), Time.t(), [Time.t() | :not_received], [pos_integer()]) :: t()
  def update(%__MODULE__{value: nil} = rr, reference_time, receive_deltas, packet_sizes) do
    packets_received = resolve_receive_deltas(receive_deltas, reference_time, packet_sizes)

    packets_received = rr.packets_received ++ packets_received

    {first_packet_timestamp, _first_packet_size} = List.first(packets_received)
    {last_packet_timestamp, _last_packet_size} = List.last(packets_received)

    if last_packet_timestamp - first_packet_timestamp >= rr.window do
      rr = %__MODULE__{rr | value: 0.0}
      update(rr, reference_time, receive_deltas, packet_sizes)
    else
      %__MODULE__{rr | packets_received: packets_received}
    end
  end

  def update(%__MODULE__{} = rr, reference_time, receive_deltas, packet_sizes) do
    packets_received = resolve_receive_deltas(receive_deltas, reference_time, packet_sizes)

    {last_packet_timestamp, _last_packet_size} = List.last(packets_received)

    treshold = last_packet_timestamp - rr.window

    packets_received =
      (rr.packets_received ++ packets_received)
      |> Enum.drop_while(fn {timestamp, _size} -> timestamp < treshold end)

    packet_received_sizes = Enum.map(packets_received, fn {_timestamp, size} -> size end)

    value = 1 / (Time.as_milliseconds(rr.window) / 1000) * Enum.sum(packet_received_sizes)

    %__MODULE__{rr | value: value, packets_received: packets_received}
  end

  defp resolve_receive_deltas(receive_deltas, reference_time, packet_sizes) do
    receive_deltas
    |> Enum.zip(packet_sizes)
    |> Enum.filter(fn {delta, _size} -> delta != :not_received end)
    |> Enum.scan({reference_time, List.first(packet_sizes)}, fn {recv_delta, size},
                                                                {prev_timestamp, _prev_size} ->
      {prev_timestamp + recv_delta, size}
    end)
  end
end
