defmodule Membrane.RTP.SeqNumTracker do
  @moduledoc false
  # FIXME docs

  alias Membrane.RTP.Utils

  require Bitwise

  @seq_num_bits 16
  @rollover_modulus Bitwise.bsl(1, @seq_num_bits)

  defstruct highest_seen_index: nil

  def new(), do: %__MODULE__{}

  def track(%__MODULE__{highest_seen_index: nil} = tracker, 0) do
    {:fresh, @rollover_modulus, %__MODULE__{highest_seen_index: @rollover_modulus}}
  end

  def track(%__MODULE__{highest_seen_index: nil} = tracker, seq_num) do
    {:fresh, seq_num, %__MODULE__{tracker | highest_seen_index: seq_num}}
  end

  def track(%__MODULE__{highest_seen_index: reference_index} = tracker, seq_num) do
    reference_seq_num = rem(reference_index, @rollover_modulus)
    reference_roc = div(reference_index, @rollover_modulus)

    incoming_roc =
      case Utils.from_which_rollover(reference_seq_num, seq_num, @rollover_modulus) do
        :current -> reference_roc
        :previous -> reference_roc - 1
        :next -> reference_roc + 1
      end

    incoming_index = seq_num + Bitwise.bsl(incoming_roc, @seq_num_bits)

    diff = incoming_index - tracker.highest_seen_index

    tracker =
      if diff > 0 do
        %__MODULE__{tracker | highest_seen_index: incoming_index}
      else
        tracker
      end

    # FIXME: Unify returned types
    {diff, incoming_index, tracker}
  end

  def skip(%__MODULE__{highest_seen_index: index} = tracker, number)
      when is_integer(number) and number >= 0 do
    %__MODULE__{tracker | highest_seen_index: index + number}
  end
end
