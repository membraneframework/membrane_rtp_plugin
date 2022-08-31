defmodule Membrane.RTP.RetransmissionRequest do
  @moduledoc false

  @derive Membrane.EventProtocol
  @enforce_keys [:sequence_numbers]
  defstruct @enforce_keys
end
