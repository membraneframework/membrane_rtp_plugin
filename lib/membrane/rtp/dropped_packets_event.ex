defmodule Membrane.RTP.DroppedPacketsEvent do
  @moduledoc """
  Event carrying information about number of intentionally dropped packets.
  """

  @derive Membrane.EventProtocol

  @enforce_keys [:dropped]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          dropped: non_neg_integer()
        }
end
