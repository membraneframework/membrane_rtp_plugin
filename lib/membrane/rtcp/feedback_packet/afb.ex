defmodule Membrane.RTCP.FeedbackPacket.AFB do
  @moduledoc """
  TODO: Mock module, for now ignores PSFB=206 & PT=15 packets.
  Should encode and decode [Application Layer Feedback](https://datatracker.ietf.org/doc/html/rfc4585#section-6.4) packets.
  """

  @behaviour Membrane.RTCP.FeedbackPacket

  defstruct []

  @impl true
  def decode(_binary) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def encode(_packet) do
    <<>>
  end
end
