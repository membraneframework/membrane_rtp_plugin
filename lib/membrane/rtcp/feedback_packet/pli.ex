defmodule Membrane.RTCP.FeedbackPacket.PLI do
  # TODO: mock module, to be implemented

  @behaviour Membrane.RTCP.FeedbackPacket

  defstruct []

  @impl true
  def decode(_binary) do
    {:ok, %__MODULE__{}}
  end
end
