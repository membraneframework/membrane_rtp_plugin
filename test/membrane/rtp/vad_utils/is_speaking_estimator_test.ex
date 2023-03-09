defmodule Membrane.RTP.VadUtils.IsSpeakingEstimatorTest do
  use ExUnit.Case

  alias Membrane.RTP.VadUtils.IsSpeakingEstimator

  @mock_levels [4, 5, 6, 6]

  describe "find item" do
    test "returns :speech" do
      assert :speech == IsSpeakingEstimator.estimate_is_speaking(@mock_levels)

    end
  end
end
