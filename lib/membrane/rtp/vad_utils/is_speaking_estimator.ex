defmodule Membrane.RTP.VadUtils.IsSpeakingEstimator do
  @moduledoc """
  Module for estimating if the user is speaking based on
  "Dominant Speaker Identification for Multipoint Videoconferencing
  by Ilana Volfin and Israel Cohen"
  """

  # number of levels inside one immediate interval
  @n1 1
  # number of immediate intervals inside one medium interval
  @n2 10
  # number of medium intervals inside one long interval
  @n3 7

  @immediate_score_threshold 0
  @medium_score_threshold 20
  @long_score_threshold 20

  @min_levels_length @n1 * @n2 * @n3

  @medium_subunit_threshold 1
  @long_subunit_threshold 3

  @min_activity_score 1.0e-8

  @spec get_min_levels_length() :: integer
  def get_min_levels_length(), do: @min_levels_length

  @spec estimate_is_speaking(list(integer), integer) :: :speech | :silence
  def estimate_is_speaking(levels, _level_threshold) when length(levels) < @min_levels_length,
    do: :silence

  def estimate_is_speaking(levels, level_threshold) do
    immediates = compute_immediates(levels, level_threshold)
    mediums = compute_mediums(immediates)
    longs = compute_longs(mediums)

    immediate_score = immediates |> hd() |> compute_activity_score(@n1, 1)
    medium_score = mediums |> hd() |> compute_activity_score(@n2, 24)
    long_score = longs |> hd() |> compute_activity_score(@n3, 47)

    above_threshold? = scores_above_threshold?(immediate_score, medium_score, long_score)

    if above_threshold?,
      do: :speech,
      else: :silence
  end

  defp scores_above_threshold?(immediate_score, medium_score, long_score) do
    immediate_score > @immediate_score_threshold and
      medium_score > @medium_score_threshold and
      long_score > @long_score_threshold
  end

  defp compute_immediates(levels, level_threshold),
    do: compute_interval(levels, @n1, level_threshold)

  defp compute_mediums(immediates),
    do: compute_interval(immediates, @n2, @medium_subunit_threshold)

  defp compute_longs(mediums), do: compute_interval(mediums, @n3, @long_subunit_threshold)

  defp compute_interval(littles, sub_list_length, threshold) do
    littles
    |> Enum.chunk_every(sub_list_length)
    |> Enum.map(&count_active(&1, threshold))
  end

  defp count_active(data, threshold) do
    Enum.count(data, &(&1 >= threshold))
  end

  defp compute_activity_score(vl, n_r, lambda) do
    p = 0.5

    score =
      :math.log(binomial_coefficient(n_r, vl)) +
        vl * :math.log(p) +
        (n_r - vl) * :math.log(1 - p) -
        :math.log(lambda) + lambda * vl

    max(score, @min_activity_score)
  end

  defp binomial_coefficient(n, k) when k < 0 or k > n, do: 0
  defp binomial_coefficient(n, k) when k == 0 or n == k, do: 1

  defp binomial_coefficient(n, k) do
    k = min(k, n - k)

    Enum.reduce(1..k, 1, fn i, acc -> div(acc * (n - i + 1), i) end)
  end
end
