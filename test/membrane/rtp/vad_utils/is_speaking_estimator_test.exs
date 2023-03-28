defmodule Membrane.RTP.VadUtils.IsSpeakingEstimatorTest do
  @moduledoc false

  use ExUnit.Case

  alias Membrane.RTP.VadUtils.IsSpeakingEstimator

  @algorithm_parameters Application.compile_env(:membrane_rtp_plugin, :vad_estimation_parameters)
  @expected_levels_length @algorithm_parameters[:n1] * @algorithm_parameters[:n2] *
                            @algorithm_parameters[:n3]

  describe "estimate is speaking" do
    test "returns :silence when levels length less than target length" do
      levels = [100, 100, 100, 100, 100, 100]
      dummy_threshold = 50

      assert IsSpeakingEstimator.estimate_is_speaking(levels, dummy_threshold) == :silence
    end

    test "returns :silence when digital silence" do
      levels = [0, 0, 0, 0, 0, 0, 0, 0]
      threshold = 50

      assert IsSpeakingEstimator.estimate_is_speaking(levels, threshold) == :silence
    end

    test "returns :speech when digital noise" do
      levels = [100, 100, 100, 100, 100, 100, 100, 100]
      threshold = 50

      assert IsSpeakingEstimator.estimate_is_speaking(levels, threshold) == :speech
    end

    test "returns :silence for alternating signal" do
      levels = [100, 0, 100, 0, 100, 0, 100, 0]
      threshold = 50

      assert IsSpeakingEstimator.estimate_is_speaking(levels, threshold) == :silence
    end

    test "returns :speech for alternating pairs" do
      levels = [100, 100, 0, 0, 100, 100, 0, 0]
      threshold = 50

      assert IsSpeakingEstimator.estimate_is_speaking(levels, threshold) == :speech
    end

    test "returns :speech for first half above threshold" do
      levels = [100, 100, 100, 100, 0, 0, 0, 0]
      threshold = 50

      assert IsSpeakingEstimator.estimate_is_speaking(levels, threshold) == :speech
    end
  end

  describe "get target levels length" do
    test "returns expected target levels length" do
      assert IsSpeakingEstimator.get_target_levels_length() == @expected_levels_length
    end
  end
end
