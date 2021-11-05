defmodule Membrane.RTCP.TransportFeedbackPacket.TWCC do
  @moduledoc """
  Serializes [Transport-wide congestion control](https://datatracker.ietf.org/doc/html/draft-holmer-rmcat-transport-wide-cc-extensions-01)
  packets using run-length or status vector packet status chunks.
  """
  @behaviour Membrane.RTCP.TransportFeedbackPacket

  alias Membrane.Time

  require Membrane.Logger

  @enforce_keys [
    :base_seq_num,
    :max_seq_num,
    :seq_to_timestamp,
    :feedback_packet_count
  ]

  defstruct @enforce_keys

  @compression_method :run_length

  @small_delta_range 0..255

  @max_s16_val 32_767
  @min_s16_val -32_768
  @max_u13_val 8191

  @packet_status_code %{
    not_received: 0,
    small_delta: 1,
    large_or_negative_delta: 2,
    reserved: 3
  }

  @impl true
  def decode(binary) do
    <<base_seq_num::16, packet_status_count::16, _reference_time::24, feedback_packet_count::8,
      _rest::binary>> = binary

    {:ok,
     %__MODULE__{
       base_seq_num: base_seq_num,
       max_seq_num: base_seq_num + packet_status_count,
       seq_to_timestamp: %{},
       feedback_packet_count: feedback_packet_count
     }}
  end

  @impl true
  def encode(%__MODULE__{} = stats) do
    %{
      base_seq_num: base_seq_num,
      max_seq_num: max_seq_num,
      seq_to_timestamp: seq_to_timestamp,
      feedback_packet_count: feedback_packet_count
    } = stats

    packet_status_count = max_seq_num - base_seq_num + 1

    # https://datatracker.ietf.org/doc/html/draft-holmer-rmcat-transport-wide-cc-extensions-01#section-3.1
    reference_time =
      seq_to_timestamp
      |> Map.fetch!(base_seq_num)
      |> Time.as_milliseconds()
      |> Ratio.div(64)
      |> Ratio.floor()

    reversed_receive_deltas = make_reversed_receive_deltas(stats, reference_time)
    encoded_packet_status = encode_packet_status(reversed_receive_deltas)
    encoded_receive_deltas = encode_receive_deltas(reversed_receive_deltas)

    <<base_seq_num::16, packet_status_count::16, reference_time::24, feedback_packet_count::8>> <>
      encoded_packet_status <> encoded_receive_deltas
  end

  defp make_reversed_receive_deltas(stats, reference_time) do
    %{
      base_seq_num: base_seq_num,
      max_seq_num: max_seq_num,
      seq_to_timestamp: seq_to_timestamp
    } = stats

    # If reference time in ms was not divisible by 64, it had to be rounded down.
    # In this case, the first delta will be equal to this rounding difference.
    reference_time = Time.milliseconds(reference_time * 64)

    base_seq_num..max_seq_num
    |> Enum.map(&Map.get(seq_to_timestamp, &1))
    |> Enum.reduce({[], reference_time}, fn timestamp, {deltas, previous_timestamp} ->
      if is_nil(timestamp) do
        {[nil | deltas], previous_timestamp}
      else
        # https://datatracker.ietf.org/doc/html/draft-holmer-rmcat-transport-wide-cc-extensions-01#section-3.1.5
        delta =
          ((timestamp - previous_timestamp) * 4)
          |> Time.as_milliseconds()
          |> Ratio.floor()

        {[delta | deltas], timestamp}
      end
    end)
    |> elem(0)
  end

  defp encode_packet_status(reversed_receive_deltas) do
    reversed_receive_deltas
    |> Enum.map(&delta_to_packet_status/1)
    |> then(
      &case @compression_method do
        :run_length -> encode_run_length(&1)
        :status_vector -> encode_status_vector(&1)
      end
    )
  end

  defp encode_run_length(reversed_packet_status) do
    reversed_packet_status
    |> Enum.reduce([], fn status, acc ->
      case acc do
        [%{packet_status: _status, packet_count: @max_u13_val} | _rest] ->
          [%{packet_status: status, packet_count: 1} | acc]

        [%{packet_status: ^status, packet_count: packet_count} | rest] ->
          [%{packet_status: status, packet_count: packet_count + 1} | rest]

        _other_status ->
          [%{packet_status: status, packet_count: 1} | acc]
      end
    end)
    |> Enum.map(&<<0::1, @packet_status_code[&1.packet_status]::2, &1.packet_count::13>>)
    |> Enum.join()
  end

  defp encode_status_vector(reversed_packet_status) do
    reversed_packet_status
    |> Enum.reverse()
    |> Enum.chunk_every(7, 7, Stream.repeatedly(fn -> :not_received end))
    |> Enum.map(fn chunk ->
      symbol_list =
        Enum.reduce(chunk, <<>>, fn status, acc ->
          <<acc::bitstring, @packet_status_code[status]::2>>
        end)

      <<(<<1::1, 1::1>>)::bitstring, symbol_list::bitstring>>
    end)
    |> Enum.join()
  end

  defp encode_receive_deltas(reversed_receive_deltas) do
    reversed_receive_deltas
    |> Enum.reduce([], fn delta, prev_deltas ->
      case delta_to_packet_status(delta) do
        :not_received ->
          prev_deltas

        :small_delta ->
          [<<delta::8>> | prev_deltas]

        :large_or_negative_delta ->
          Membrane.Logger.warn(
            "Reporting a packet with large or negative delta: (#{inspect(div(delta, 4))}ms)"
          )

          [<<cap_delta(delta)::16>> | prev_deltas]
      end
    end)
    |> Enum.join()
  end

  defp delta_to_packet_status(delta) do
    cond do
      delta == nil -> :not_received
      delta in @small_delta_range -> :small_delta
      true -> :large_or_negative_delta
    end
  end

  defp cap_delta(delta) do
    cond do
      delta < @min_s16_val -> @min_s16_val
      delta > @max_s16_val -> @max_s16_val
      true -> delta
    end
  end
end
