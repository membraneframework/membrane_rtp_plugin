defmodule Membrane.RTP.RetransmissionRequest do
  @derive Membrane.EventProtocol
  @enforce_keys [:sequence_numbers]
  defstruct @enforce_keys
end
