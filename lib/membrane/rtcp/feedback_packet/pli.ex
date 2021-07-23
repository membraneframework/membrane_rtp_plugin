defmodule Membrane.RTCP.FeedbackPacket.PLI do
  @moduledoc """
  TODO: MOCK MODULE, TO BE IMPLEMENTED

  For now, ignores [Picture Loss Indication](https://datatracker.ietf.org/doc/html/rfc4585#section-6.3.1) packets.
  """

  # TODO: mock module, to be implemented

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
