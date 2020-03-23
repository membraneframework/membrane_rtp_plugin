defmodule Membrane.RTP.Packet do
  @moduledoc """
  Describes an RTP packet.
  """

  alias Membrane.RTP.Header

  @type t :: %__MODULE__{
          header: Header.t(),
          payload: binary()
        }

  defstruct [
    :header,
    :payload
  ]
end
