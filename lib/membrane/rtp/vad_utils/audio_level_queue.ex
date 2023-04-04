defmodule Membrane.RTP.VadUtils.AudioLevelQueue do
  @moduledoc """
  The queue contains audio levels for VAD implementation. It is used as an input of IsSpeakingEstimator.estimate_is_speaking.
  This structure builds on top of a simple FIFO erlang queue by having a fixed max number of elements.

  The newest element in always appended to the rear, so to_list/1 always returns the most recent element as the head of a list.
  The length of a list can be obtained in O(1) time.
  """
  alias Membrane.RTP.VadUtils.AudioLevelQueue

  @vad_params Application.compile_env(
                :membrane_rtp_plugin,
                :vad_estimation_parameters
              )

  @target_audio_level_length @vad_params[:immediate][:subunits] * @vad_params[:medium][:subunits] *
                               @vad_params[:long][:subunits]

  @enforce_keys [:levels, :length]
  defstruct [:levels, :length]

  @typedoc """
  A type for storing information about a fixed number of recent audio levels.

  :levels - erlang queue which stores at most @target_audio_level_length elements
  :length - number of elements
  """

  @type t() :: %__MODULE__{
          levels: :queue.queue(non_neg_integer()),
          length: non_neg_integer()
        }

  @doc """
  Creates new AudioLevelQueue and returns it.
  """
  @spec new :: t()
  def new(), do: %AudioLevelQueue{levels: :queue.new(), length: 0}

  @doc """
  Given a AudioLevelQueue and level value it returns a queue with the level value on front

  The function also reduces the size of the queue if the maximum size has been reached.
  It does so by dropping the element on the front (the oldest level)
  """
  @spec add(t(), non_neg_integer) :: t()
  def add(%{length: @target_audio_level_length} = old_queue, level) do
    trimmed_queue = trim_queue(old_queue)

    add(trimmed_queue, level)
  end

  def add(%{levels: old_levels, length: length}, level) do
    %AudioLevelQueue{levels: :queue.in_r(level, old_levels), length: length + 1}
  end

  @doc """
  Given an AudioLevelQueue it returns a list in amortized O(1) time.
  """
  @spec to_list(t()) :: [non_neg_integer()]
  def to_list(%{levels: levels}), do: :queue.to_list(levels)

  @doc """
  Given a list it returns an AudioLevelQueue in amortized O(@target_levels_length) time.
  """
  @spec from_list([non_neg_integer()]) :: t()
  def from_list(levels) when is_list(levels) do
    list_len = length(levels)

    levels =
      if list_len > @target_audio_level_length,
        do: Enum.take(levels, @target_audio_level_length),
        else: levels

    %AudioLevelQueue{levels: :queue.from_list(levels), length: list_len}
  end

  @spec len(t()) :: non_neg_integer()
  def len(%AudioLevelQueue{length: len}), do: len

  # Removes the last element (the one on the front) in the queue
  defp trim_queue(%{levels: old_levels, length: old_length}),
    do: %AudioLevelQueue{levels: :queue.drop_r(old_levels), length: old_length - 1}
end
