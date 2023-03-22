defmodule Membrane.RTP.VadUtils.IsSpeakingEstimatorTest do
  @moduledoc false

  use ExUnit.Case

  # alias Membrane.RTP.VadUtils.IsSpeakingEstimator

  @algorithm_parameters Application.compile_env(:membrane_rtp_plugin, :vad_estimation_parameters)

  describe "estimate is speaking" do
    test "returns :silence when levels length less than target length" do
      # TODO - implement me
    end

    test "returns :silence when digital silence" do
      # TODO - implement me
    end

    test "returns :speech when digital noise" do
      # TODO - implement me
    end

    test "returns :silence for alternating signal" do
      # TODO - implement me
    end

    test "returns :speech for alternating pairs" do
      # TODO - implement me
    end

    test "returns :speech for first half above threshold" do
      # TODO - implement me
    end
  end

  describe "get target levels length" do
    test "returns expected target levels length" do
      # TODO - implement me
    end
  end
end
