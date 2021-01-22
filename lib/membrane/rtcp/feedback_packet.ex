defmodule Membrane.RTCP.FeedbackPacket do
  def decode(body, subtype) do
    {:ok, {206, subtype, body}}
  end
end
