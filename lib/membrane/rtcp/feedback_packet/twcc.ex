defmodule Membrane.RTCP.FeedbackPacket.TWCC do
  @moduledoc """
  TODO: MOCK MODULE, TO BE IMPLEMENTED

  For now, ignores [Transport-wide congestion control](https://datatracker.ietf.org/doc/html/draft-holmer-rmcat-transport-wide-cc-extensions-01) packets.
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
