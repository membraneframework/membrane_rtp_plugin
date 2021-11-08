defmodule Membrane.RTCP.TransportFeedbackPacket.TWCC do
  @moduledoc """
  Serializes [Transport-wide congestion control](https://datatracker.ietf.org/doc/html/draft-holmer-rmcat-transport-wide-cc-extensions-01)
  feedback packets.
  """
  @behaviour Membrane.RTCP.TransportFeedbackPacket

  alias Membrane.Time

  require Bitwise
  require Membrane.Logger

  defmodule RunLength do
    @moduledoc false

    defstruct [
      :packet_status,
      :packet_count
    ]
  end

  defmodule StatusVector do
    @moduledoc false

    defstruct [
      :vector,
      :packet_count
    ]
  end

  defstruct [
    :base_seq_num,
    :max_seq_num,
    :seq_to_timestamp,
    :feedback_packet_count
  ]

  @max_u8_val Bitwise.bsl(1, 8) - 1
  @max_u13_val Bitwise.bsl(1, 13) - 1
  @max_s16_val Bitwise.bsl(1, 15) - 1
  @min_s16_val Bitwise.bsl(-1, 15)

  @small_delta_range 0..@max_u8_val

  @run_length_id 0
  @run_length_capacity @max_u13_val

  @status_vector_id 1
  @status_vector_symbol_2_bit_id 1
  @status_vector_capacity 7

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
       max_seq_num: base_seq_num + packet_status_count - 1,
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
    packet_status_chunks = make_packet_status_chunks(reversed_receive_deltas)

    <<base_seq_num::16, packet_status_count::16, reference_time::24, feedback_packet_count::8>> <>
      encode_packet_status(packet_status_chunks) <> encode_receive_deltas(reversed_receive_deltas)
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
    |> Enum.reduce({[], reference_time}, fn seq_num, {deltas, previous_timestamp} ->
      case Map.get(seq_to_timestamp, seq_num) do
        nil ->
          {[nil | deltas], previous_timestamp}

        timestamp ->
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

  defp make_packet_status_chunks(reversed_receive_deltas) do
    reversed_receive_deltas
    |> Enum.map(&delta_to_packet_status/1)
    |> Enum.reduce([], fn status, acc ->
      case acc do
        [%RunLength{packet_count: @run_length_capacity} | _rest] ->
          [%RunLength{packet_status: status, packet_count: 1} | acc]

        [%RunLength{packet_status: ^status, packet_count: count} | rest] ->
          [%RunLength{packet_status: status, packet_count: count + 1} | rest]

        # Got a differrent packet status and the current chunk is of run length type.
        # If the condition is fulfilled, it's viable to convert it to a status vector.
        [%RunLength{packet_count: count} | rest] when count < @status_vector_capacity ->
          %StatusVector{vector: vector} = acc |> hd() |> run_length_to_status_vector()
          [%StatusVector{vector: [status | vector], packet_count: count + 1} | rest]

        [%StatusVector{vector: vector, packet_count: count} | rest]
        when count < @status_vector_capacity ->
          [%StatusVector{vector: [status | vector], packet_count: count + 1} | rest]

        _acc_empty_or_status_vector_full_or_conversion_not_viable ->
          [%RunLength{packet_status: status, packet_count: 1} | acc]
      end
    end)
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

  defp encode_packet_status(packet_status_chunks) do
    packet_status_chunks
    |> Enum.map(fn chunk ->
      case chunk do
        %RunLength{} ->
          encode_run_length(chunk)

        %StatusVector{packet_count: @status_vector_capacity} ->
          encode_status_vector(chunk)

        %StatusVector{packet_count: count} when count < @status_vector_capacity ->
          chunk
          |> status_vector_to_run_length()
          |> Enum.map(&encode_run_length/1)
          |> Enum.join()
      end
    end)
    |> Enum.join()
  end

  defp encode_run_length(%RunLength{packet_status: status, packet_count: count}),
    do: <<@run_length_id::1, @packet_status_code[status]::2, count::13>>

  defp encode_status_vector(%StatusVector{vector: vector, packet_count: @status_vector_capacity}) do
    symbol_list =
      Enum.reduce(vector, <<>>, fn status, acc ->
        <<acc::bitstring, @packet_status_code[status]::2>>
      end)

    <<(<<@status_vector_id::1, @status_vector_symbol_2_bit_id::1>>)::bitstring,
      symbol_list::bitstring>>
  end

  defp run_length_to_status_vector(%RunLength{packet_status: status, packet_count: count}),
    do: %StatusVector{vector: Enum.map(1..count, fn _i -> status end), packet_count: count}

  defp status_vector_to_run_length(%StatusVector{vector: vector, packet_count: _count}) do
    vector
    |> Enum.reduce([], fn status, acc ->
      case acc do
        [%RunLength{packet_status: ^status, packet_count: count} | rest] ->
          [%RunLength{packet_status: status, packet_count: count + 1} | rest]

        _empty_acc_or_other_status ->
          [%RunLength{packet_status: status, packet_count: 1} | acc]
      end
    end)
    |> Enum.reverse()
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
