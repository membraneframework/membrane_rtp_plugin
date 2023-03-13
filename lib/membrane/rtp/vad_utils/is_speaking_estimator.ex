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

  # @max_level 127
  # @min_level 0

  @min_activity_score 1.0e-8

  defp binomial_coefficient(n, k) when k < 0 or k > n, do: 0
  defp binomial_coefficient(n, k) when k == 0 or n == k , do: 1

  defp binomial_coefficient(n, k) do
    k = min(k, n - k)
    Enum.to_list(1..k) |>
    Enum.reduce(1, fn i, acc -> (div(acc*(n-i+1), i)) end)
  end

  defp compute_activity_score(n_r, vl, lambda) do
    p = 0.5
    score = :math.log(binomial_coefficient(n_r, vl)) +
            vl * :math.log(p) +
            (n_r - vl) * :math.log(1-p) -
            :math.log(lambda) + lambda * vl
    if score > @min_activity_score, do: score, else: @min_activity_score
  end

  @spec estimate_is_speaking(list(integer)) :: (:speech | :silence)
  def estimate_is_speaking(levels) do
    IO.inspect(binomial_coefficient(5, 5))
    IO.inspect(compute_activity_score(100, 85, 0.78))
    IO.inspect(levels)
    IO.inspect("#{@n1}, #{@n2}, #{@n3}, #{@c1}, #{@c2}, #{@c3}")
    if :true ,do: :speech, else: :silence
  end

end
