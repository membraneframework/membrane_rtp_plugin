defmodule Membrane.RTP.Utils do
  @moduledoc false

  @spec strip_padding(binary, padding_present? :: boolean) ::
          {:ok, {binary, padding_size :: non_neg_integer()}} | :error
  def strip_padding(binary, padding_present?)
  def strip_padding(binary, false), do: {:ok, {binary, 0}}

  def strip_padding(binary, true) do
    with size when size > 0 <- byte_size(binary),
         padding_size = :binary.last(binary),
         payload_size = byte_size(binary) - padding_size,
         <<stripped_payload::binary-size(payload_size), _::binary-size(padding_size)>> <- binary do
      {:ok, {stripped_payload, padding_size}}
    else
      _error -> :error
    end
  end

  @spec align(payload :: binary, align_to :: pos_integer()) ::
          {binary, padding_size :: non_neg_integer()}
  def align(payload, align_to) do
    case rem(byte_size(payload), align_to) do
      0 ->
        {payload, 0}

      padding_size ->
        zeros_no = padding_size - 1
        {<<payload::binary, 0::size(zeros_no)-unit(8), padding_size>>, padding_size}
    end
  end
end
