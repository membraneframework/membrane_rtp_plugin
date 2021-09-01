defmodule Membrane.RTCP.ReceiverReport.StatsEvent do
  @moduledoc """
  Event carrying jitter buffer statistics.
  """

  @derive Membrane.EventProtocol
  @enforce_keys [:stats]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          stats: Membrane.RTCP.ReceierReport.Stats.t()
        }
end
