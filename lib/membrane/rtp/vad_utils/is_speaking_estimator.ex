defmodule Membrane.RTP.VadUtils.IsSpeakingEstimator do
  @moduledoc """
  Module for estimating if the user is speaking based on
  "Dominant Speaker Identification for Multipoint Videoconferencing
  by Ilana Volfin and Israel Cohen"
  """

  @n1 13
  @n2 5
  @n3 10
  @c1 1
  @c2 1
  @c3 1
  @db_threshold 50

  @spec estimate_is_speaking(list(integer)) :: (:speech | :silence)
  def estimate_is_speaking(levels) do
    IO.inspect(levels)
    IO.inspect("#{@n1}, #{@n2}, #{@n3}, #{@c1}, #{@c2}, #{@c3}")
    if :true ,do: :speech, else: :silence
  end

end
