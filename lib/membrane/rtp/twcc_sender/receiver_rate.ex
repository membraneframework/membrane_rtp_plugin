defmodule Membrane.RTP.TWCCSender.ReceiverRate do
  @moduledoc false
  # module responsible for calculating bitrate
  # received by a receiver in last `window` time
  # (referred to as R_hat in the GCC draft, sec. 5.5)

  alias Membrane.Time

  @type t() :: %__MODULE__{
          value: float() | nil,
          # time window for measuring the received bitrate, between [0.5, 1]s (reffered to as "T" in the draft)
          window: Time.t(),
          # accumulator for packets and their timestamps that have been received in last `window` time
          packets_received: :queue.queue({Time.t(), pos_integer()})
        }

  @enforce_keys [:window]
  defstruct @enforce_keys ++ [:value, packets_received: :queue.new()]

  @spec new(Time.t()) :: t()
  def new(window), do: %__MODULE__{window: window}

  @spec update(t(), Time.t(), [Time.t() | :not_received], [pos_integer()]) :: t()
  def update(%__MODULE__{value: nil} = rr, reference_time, receive_deltas, packet_sizes) do
    packets_received = resolve_receive_deltas(receive_deltas, reference_time, packet_sizes)

    packets_received = :queue.join(rr.packets_received, packets_received)

    {first_packet_timestamp, _first_packet_size} = :queue.get(packets_received)
    {last_packet_timestamp, _last_packet_size} = :queue.get_r(packets_received)

    if last_packet_timestamp - first_packet_timestamp >= rr.window do
      rr = %__MODULE__{rr | value: 0.0}
      update(rr, reference_time, receive_deltas, packet_sizes)
    else
      %__MODULE__{rr | packets_received: packets_received}
    end
  end

  def update(%__MODULE__{} = rr, reference_time, receive_deltas, packet_sizes) do
    packets_received = resolve_receive_deltas(receive_deltas, reference_time, packet_sizes)

    {last_packet_timestamp, _last_packet_size} = :queue.get_r(packets_received)

    treshold = last_packet_timestamp - rr.window

    packets_received = :queue.join(rr.packets_received, packets_received)

    packets_received =
      :queue.filter(fn {timestamp, _size} -> timestamp > treshold end, packets_received)

    sum = :queue.fold(fn {_timestamp, size}, size_sum -> size + size_sum end, 0, packets_received)

    value = 1 / (Time.as_milliseconds(rr.window) / 1000) * sum

    %__MODULE__{rr | value: value, packets_received: packets_received}
  end

  defp resolve_receive_deltas(receive_deltas, reference_time, packet_sizes) do
    receive_deltas
    |> Enum.zip(packet_sizes)
    |> Enum.filter(fn {delta, _size} -> delta != :not_received end)
    |> Enum.reduce({reference_time, :queue.new()}, fn {recv_delta, size},
                                                      {prev_timestamp, packets_received} ->
      receive_timestamp = prev_timestamp + recv_delta
      {receive_timestamp, :queue.in({receive_timestamp, size}, packets_received)}
    end)
    # take the packets_received
    |> elem(1)
  end
end
