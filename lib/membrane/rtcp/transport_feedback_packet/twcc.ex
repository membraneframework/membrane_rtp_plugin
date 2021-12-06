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
    defstruct [:packet_status, :packet_count]
  end

  defmodule StatusVector do
    @moduledoc false
    defstruct [:vector, :packet_count]
  end

  @enforce_keys [
    :base_seq_num,
    :reference_time,
    :packet_status_count,
    :receive_deltas,
    :feedback_packet_count
  ]

  defstruct @enforce_keys

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
    <<base_seq_num::16, packet_status_count::16, reference_time::24, feedback_packet_count::8,
      _rest::binary>> = binary

    {:ok,
     %__MODULE__{
       base_seq_num: base_seq_num,
       reference_time: reference_time * Time.milliseconds(64),
       packet_status_count: packet_status_count,
       receive_deltas: [],
       feedback_packet_count: feedback_packet_count
     }}
  end

  @impl true
  def encode(%__MODULE__{} = stats) do
    %{
      base_seq_num: base_seq_num,
      reference_time: reference_time,
      packet_status_count: packet_status_count,
      receive_deltas: receive_deltas,
      feedback_packet_count: feedback_packet_count
    } = stats

    scaled_receive_deltas = Enum.map(receive_deltas, &scale_delta/1)
    packet_status_chunks = make_packet_status_chunks(scaled_receive_deltas)

    # reference time has to be in 64ms resolution
    # https://datatracker.ietf.org/doc/html/draft-holmer-rmcat-transport-wide-cc-extensions-01#section-3.1
    reference_time = div(reference_time, Time.milliseconds(64))

    payload =
      <<base_seq_num::16, packet_status_count::16, reference_time::24, feedback_packet_count::8>> <>
        encode_packet_status(packet_status_chunks) <> encode_receive_deltas(scaled_receive_deltas)

    maybe_add_padding(payload)
  end

  defp make_packet_status_chunks(scaled_receive_deltas) do
    scaled_receive_deltas
    |> Enum.map(&delta_to_packet_status/1)
    |> Enum.reverse()
    |> Enum.reduce([], fn status, acc ->
      case acc do
        [%RunLength{packet_count: @run_length_capacity} | _rest] ->
          [%RunLength{packet_status: status, packet_count: 1} | acc]

        [%RunLength{packet_status: ^status, packet_count: count} | rest] ->
          [%RunLength{packet_status: status, packet_count: count + 1} | rest]

        # Got a different packet status and the current chunk is of run length type.
        # If the condition is fulfilled, it's viable to convert it to a status vector.
        [%RunLength{packet_count: count} = run_length | rest] when count < @status_vector_capacity ->
          %StatusVector{vector: vector} = run_length_to_status_vector(run_length)
          [%StatusVector{vector: [status | vector], packet_count: count + 1} | rest]

        [%StatusVector{vector: vector, packet_count: count} | rest]
        when count < @status_vector_capacity ->
          [%StatusVector{vector: [status | vector], packet_count: count + 1} | rest]

        _acc_empty_or_status_vector_full_or_conversion_not_viable ->
          [%RunLength{packet_status: status, packet_count: 1} | acc]
      end
    end)
  end

  defp encode_receive_deltas(scaled_receive_deltas) do
    Enum.map_join(scaled_receive_deltas, fn delta ->
      case delta_to_packet_status(delta) do
        :not_received ->
          <<>>

        :small_delta ->
          <<delta::8>>

        :large_or_negative_delta ->
          Membrane.Logger.warn(
            "Reporting a packet with large or negative delta: (#{inspect(delta / 4)}ms)"
          )

          <<cap_delta(delta)::16>>
      end
    end)
  end

  defp encode_packet_status(packet_status_chunks) do
    Enum.map_join(packet_status_chunks, fn chunk ->
      case chunk do
        %RunLength{} ->
          encode_run_length(chunk)

        %StatusVector{packet_count: @status_vector_capacity} ->
          encode_status_vector(chunk)

        %StatusVector{} ->
          chunk
          |> status_vector_to_run_length()
          |> Enum.map_join(&encode_run_length/1)
      end
    end)
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

  defp status_vector_to_run_length(%StatusVector{vector: vector}) do
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

  defp scale_delta(:not_received), do: :not_received

  defp scale_delta(delta) do
    # Deltas are represented as multiples of 250μs
    # https://datatracker.ietf.org/doc/html/draft-holmer-rmcat-transport-wide-cc-extensions-01#section-3.1.5
    delta |> Time.to_microseconds() |> div(250)
  end

  defp delta_to_packet_status(scaled_delta) do
    cond do
      scaled_delta == :not_received -> :not_received
      scaled_delta in @small_delta_range -> :small_delta
      true -> :large_or_negative_delta
    end
  end

  defp cap_delta(scaled_delta) do
    cond do
      scaled_delta < @min_s16_val -> @min_s16_val
      scaled_delta > @max_s16_val -> @max_s16_val
      true -> scaled_delta
    end
  end

  defp maybe_add_padding(payload) do
    bits_remaining = rem(bit_size(payload), 32)

    if bits_remaining > 0 do
      padding_size = 32 - bits_remaining
      <<payload::bitstring, 0::size(padding_size)>>
    else
      payload
    end
  end
end
