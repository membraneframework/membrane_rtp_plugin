defmodule Membrane.RTCPEvent do
  @derive Membrane.EventProtocol

  @enforce_keys [:packet]

  defstruct @enforce_keys ++ [ssrcs: []]
end
