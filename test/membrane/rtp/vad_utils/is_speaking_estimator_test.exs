defmodule Membrane.RTP.VadUtils.IsSpeakingEstimatorTest do
  @moduledoc """
  The tests for IsSpeakingEstimator are focused on the estimate_is_speaking function which takes:
     - levels: a list of db values inferred from the RTP Header; the values range from 0 (digital silence) to 127 (digital noise)
     - threshold: a number which indicates how big the level value must be so the interval is counted as active
  For the sake of simplicity in the following tests only 0 and 127 are used as values of the `levels` list and the threshold value is fixed.

  Moreover, the algorithm uses a set of internal parameters. The values are different for the test environment than from other environments. The values set here can be found in the `tests.exs` config file.

  The tests are constructed so the inner workings of the algorithm are checked. They include not only the trivial cases like only silence, only speech or to short input list, but it cover more sophisticated scenarios like:
     - alternation every packet - this can mean the person has been alternating on the edge of the threshold which often means sound from background
     - alternation every medium packet = since wa assume one medium interval is (roughly) one word, this can mean a person is speaking but with long pauses
     - alternation every long packet - we assume a person just finished a sentence, so the algorithm should return speech
     - random packet dropped - "one swallow doesn't make a summer" - one packet doesn't make silence... if surrounded by packets with high dB value, it should be counted as speech
  """

  use ExUnit.Case

  alias Membrane.RTP.VadUtils.IsSpeakingEstimator

  @algorithm_params Application.compile_env(:membrane_rtp_plugin, :vad_estimation_parameters)

  @immediate_subunits @algorithm_params[:immediate][:subunits]
  @medium_subunits @algorithm_params[:medium][:subunits]
  @long_subunits @algorithm_params[:long][:subunits]

  @expected_levels_length @immediate_subunits * @medium_subunits * @long_subunits

  defp silence(n), do: List.duplicate(0, n)
  defp noise(n), do: List.duplicate(127, n)

  defp alternating_signal(n, interval) do
    repeats = div(n, 2 * interval)

    interval
    |> then(&(noise(&1) ++ silence(&1)))
    |> List.duplicate(repeats)
    |> Enum.concat()
  end

  defp noise_with_one_silence(n, low_item_idx) do
    n_left = low_item_idx
    n_right = n - low_item_idx - 1

    noise(n_left) ++ silence(1) ++ noise(n_right)
  end

  describe "estimate is speaking" do
    setup do
      [threshold: 50]
    end

    test "returns :silence when levels length less than target length", %{
      threshold: dummy_threshold
    } do
      levels = noise(4)

      assert IsSpeakingEstimator.estimate_is_speaking(levels, dummy_threshold) == :silence
    end

    test "returns :silence when digital silence", %{threshold: threshold} do
      levels = silence(@expected_levels_length)

      assert IsSpeakingEstimator.estimate_is_speaking(levels, threshold) == :silence
    end

    test "returns :speech when digital noise", %{threshold: threshold} do
      levels = noise(@expected_levels_length)

      assert IsSpeakingEstimator.estimate_is_speaking(levels, threshold) == :speech
    end

    test "returns :silence for alternating signal", %{threshold: threshold} do
      levels = alternating_signal(@expected_levels_length, 1)

      assert IsSpeakingEstimator.estimate_is_speaking(levels, threshold) == :silence
    end

    test "returns :speech for alternating pairs", %{threshold: threshold} do
      levels = alternating_signal(@expected_levels_length, @immediate_subunits)

      assert IsSpeakingEstimator.estimate_is_speaking(levels, threshold) == :speech
    end

    test "returns :speech for first half above threshold", %{threshold: threshold} do
      levels =
        alternating_signal(
          @expected_levels_length,
          @immediate_subunits * @medium_subunits
        )

      assert IsSpeakingEstimator.estimate_is_speaking(levels, threshold) == :speech
    end

    test "returns :speech for noise with one 'silent' packet", %{threshold: threshold} do
      levels = noise_with_one_silence(@expected_levels_length, 5)

      assert IsSpeakingEstimator.estimate_is_speaking(levels, threshold)
    end
  end
end
