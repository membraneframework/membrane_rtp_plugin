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
        assert TWCC.decode(encoded) == {:ok, expected}
        assert TWCC.encode(expected) == encoded
      end)
    end

    test "does not decode malformed feedbacks" do
      encoded_feedbacks = Fixtures.twcc_malformed_feedbacks()

      Enum.each(encoded_feedbacks, fn encoded ->
        assert TWCC.decode(encoded) == {:error, :malformed_packet}
      end)
    end
  end
end
