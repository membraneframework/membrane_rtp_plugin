defmodule Membrane.RTP.GeneratePaddingPacketEvent do
  @moduledoc """
  Event used for generating RTP padding packet.
  """
  alias Membrane.RTP

  @derive Membrane.EventProtocol

  @enforce_keys [:size, :payload_type, :sequence_number, :timestamp]
  defstruct @enforce_keys ++ [csrcs: [], extensions: [], marker: false]

  @typedoc """
  Type describing `__MODULE__` struct.

  SSRC is meant to be assigned by an element processing
  this event.

  * `size` - padding size including the last byte denoting
  number of zeros.
  """
  @type t :: %__MODULE__{
          size: pos_integer(),
          payload_type: RTP.payload_type_t(),
          sequence_number: RTP.Header.sequence_number_t(),
          timestamp: RTP.Header.timestamp_t(),
          csrcs: [RTP.ssrc_t()],
          extensions: [RTP.Header.Extension.t()],
          marker: RTP.Header.marker()
        }
end
