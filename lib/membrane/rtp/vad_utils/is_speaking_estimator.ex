defmodule Membrane.RTP.VadUtils.IsSpeakingEstimator do
  @moduledoc """
  Module for estimating if the user is speaking inspired by
  "Dominant Speaker Identification for Multipoint Videoconferencing"
  by Ilana Volfin and Israel Cohen
  Link: https://israelcohen.com/wp-content/uploads/2018/05/IEEEI2012_Volfin.pdf

  The `estimate_is_speaking/2` function takes a list of audio levels in range (0, 127)
  and based on a threshold given as a second input
  computes if the person is speaking.

  The input levels are interpreted on 3 tiers. Each tier consists of intervals specified below:

  +------------+----------------------+---------------------------------+-----------+
  | Name       | Interpretation       | Number of RTP packets (default) | length    |
  +============+======================+=================================+===========+
  | immediate  | smallest sound chunk | 1                               | ~20 [ms]  |
  +------------+----------------------+---------------------------------+-----------+
  | medium     | one word             | 1 * 10 = 10                     | ~200 [ms] |
  +------------+----------------------+---------------------------------+-----------+
  | long       | half/one sentence    | 1 * 10 * 7 = 70                 | ~1.4 [s]  |
  +------------+----------------------+---------------------------------+-----------+

  Each tier interval is computed based on the smaller tier intervals (subunits).
  Immediates are computed based on levels, mediums on top of immediates and long on top of mediums.
  The number of subunits in one interval is given as a module parameter.

  Each interval is a number of active subunits that is intervals that are above a threshold of this tier.

  For example:
    if level_threshold is 90, levels are [80, 90, 100, 90] and there are 2 levels in a immediate,
      then immediates would be equal to [1, 2]
      since subunit of [80, 90] has 1 item above or equal to the threshold and subunit [100, 90] has 2 such items.

    Same goes for mediums. If medium subunit threshold is 2 and number of subunits is 2
      then mediums are equal to [1] since the only subunit [1, 2] had only one element above or equal to the threshold.

  The most recent interval in each tier serves as a basis for computing an activity score.
  The activity score is a logarithm of a quotient of:
    - the probability of k active items in n total items under an assumption that a person is speaking (binomial coefficient)
    - same probability but under an assumption that a person is not speaking (exponential distribution)

  The activity score for each tier is then thresholded again.
  A threshold for every tier is given as a module parameter.
  If all activity scores are over the threshold, the algorithm estimates that it is speech. Otherwise silence.

  A thorough explanation with images can be found in the RTC engine internal documentation.
  Link: https://github.com/jellyfish-dev/membrane_rtc_engine/tree/master/internal_docs
  """

  @default_parameters [
    n1: 1,
    n2: 10,
    n3: 7,
    immediate_score_threshold: 0,
    medium_score_threshold: 20,
    long_score_threshold: 20,
    medium_subunit_threshold: 1,
    long_subunit_threshold: 3
  ]
  @parameters Application.compile_env(
                :membrane_rtp_plugin,
                :vad_estimation_parameters,
                @default_parameters
              )

  # number of levels inside one immediate interval
  @n1 @parameters[:n1]
  # number of immediate intervals inside one medium interval
  @n2 @parameters[:n2]
  # number of medium intervals inside one long interval
  @n3 @parameters[:n3]

  @target_levels_length @n1 * @n2 * @n3

  @immediate_score_threshold @parameters[:immediate_score_threshold]
  @medium_score_threshold @parameters[:medium_score_threshold]
  @long_score_threshold @parameters[:long_score_threshold]

  @medium_subunit_threshold @parameters[:medium_subunit_threshold]
  @long_subunit_threshold @parameters[:long_subunit_threshold]

  @min_activity_score 1.0e-8

  @spec target_levels_length() :: pos_integer
  def target_levels_length(), do: @target_levels_length

  @spec estimate_is_speaking([integer], integer) :: :speech | :silence
  def estimate_is_speaking(levels, _level_threshold) when length(levels) < @target_levels_length,
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
