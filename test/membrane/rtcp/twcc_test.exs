defmodule Membrane.RTCP.TWCCTest do
  use ExUnit.Case, async: true

  alias Membrane.RTCP.Fixtures
  alias Membrane.RTCP.TransportFeedbackPacket.TWCC

  describe "TWCC module" do
    test "encodes and decodes valid feedbacks" do
      encoded_feedbacks = Fixtures.twcc_feedbacks()
      expected_feedbacks = Fixtures.twcc_feedbacks_contents()

      encoded_feedbacks
      |> Enum.zip(expected_feedbacks)
      |> Enum.each(fn {encoded, expected} ->
        assert {:ok, expected} == TWCC.decode(encoded)
        assert encoded == TWCC.encode(expected)
      end)
    end

    test "does not decode malformed feedbacks" do
      encoded_feedbacks = Fixtures.twcc_malformed_feedbacks()

      Enum.each(encoded_feedbacks, fn encoded ->
        assert {:error, :malformed_packet} == TWCC.decode(encoded)
      end)
    end
  end
end
