defmodule Membrane.RTP.PacketsDroppedEvent do
  @moduledoc """
  Event carrying information about how many packets has been dropped by some element.
  """
  @derive Membrane.EventProtocol

  defstruct dropped: 0

  @type t :: %__MODULE__{
          dropped: non_neg_integer()
        }
end
