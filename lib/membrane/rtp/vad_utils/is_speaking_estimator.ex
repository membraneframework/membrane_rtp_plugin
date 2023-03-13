defmodule Membrane.RTP.VadUtils.IsSpeakingEstimator do
  @moduledoc """
  Module for estimating if the user is speaking based on
  "Dominant Speaker Identification for Multipoint Videoconferencing
  by Ilana Volfin and Israel Cohen"
  """

  @n1 4
  @n2 4
  @n3 4
  @c1 1
  @c2 1
  @c3 1

  @min_levels_length @n1*@n2*@n3

  # @max_level 127
  # @min_level 0
  @level_threshold 50
  @medium_threshold 1
  @long_threshold 1

  @min_activity_score 1.0e-8

  defp binomial_coefficient(n, k) when k < 0 or k > n, do: 0
  defp binomial_coefficient(n, k) when k == 0 or n == k , do: 1

  defp binomial_coefficient(n, k) do
    k = min(k, n - k)
    Enum.to_list(1..k) |>
    Enum.reduce(1, fn i, acc -> (div(acc*(n-i+1), i)) end)
  end

  defp compute_activity_score(vl, n_r, lambda) do
    p = 0.5
    score = :math.log(binomial_coefficient(n_r, vl)) +
            vl * :math.log(p) +
            (n_r - vl) * :math.log(1-p) -
            :math.log(lambda) + lambda * vl
    if score > @min_activity_score, do: score, else: @min_activity_score
  end

  defp indicator_func(x, threshold) do
    if x >= threshold, do: 1, else: 0
  end

  defp count_active(data, threshold) do
     Enum.reduce(data, 0,
          fn x, acc -> acc + indicator_func(x, threshold) end)
  end

  defp compute_interval(littles, sub_list_length, threshold) do
    littles |>
    Enum.chunk_every(sub_list_length) |>
    Enum.map(&(count_active(&1, threshold)))
  end

  defp compute_immediates(levels), do: compute_interval(levels, @n1, @level_threshold)
  defp compute_mediums(immediates), do: compute_interval(immediates, @n2, @medium_threshold)
  defp compute_longs(mediums), do: compute_interval(mediums, @n3, @long_threshold)

  def estimate_is_speaking(levels) when length(levels) < @min_levels_length,
    do: :silence

  @spec estimate_is_speaking(list(integer)) :: (:speech | :silence)
  def estimate_is_speaking(levels) do
    immediates = compute_immediates(levels)
    mediums = compute_mediums(immediates)
    longs = compute_longs(mediums)

    immediate_score = immediates |> hd() |> compute_activity_score(@n1, 1)
    medium_score = mediums |> hd() |> compute_activity_score(@n2, 1)
    long_score = longs |> hd() |> compute_activity_score(@n3, 1)

    # if immediate_score > @c1 and medium_score > @c2 and long_score > @c3 ,do: :speech, else: :silence
    :speech
  end



end
