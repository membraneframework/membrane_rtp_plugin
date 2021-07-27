defmodule Membrane.RTP.DiscardedPacket do
  @derive Membrane.EventProtocol

  alias Membrane.RTP.Header

  @type t :: %__MODULE__{
          header: Header.t()
        }

  @enforce_keys [:header]
  defstruct @enforce_keys
end
