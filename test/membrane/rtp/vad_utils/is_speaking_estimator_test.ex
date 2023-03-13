defmodule Membrane.RTP.VadUtils.IsSpeakingEstimatorTest do
  use ExUnit.Case

  alias Membrane.RTP.VadUtils.IsSpeakingEstimator

  @mock_levels 40..60

  describe "find speech" do
    test "returns :speech" do
      assert :speech == IsSpeakingEstimator.estimate_is_speaking(@mock_levels)

    end
  end
end
