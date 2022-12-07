defmodule Membrane.RTP.SSRCRouter.RequireExtensions do
  @moduledoc """
  A struct sent as a message to `Membrane.RTP.SSRCRouter` adding new extensions
  to the lists of required extensions for provided payload type

  This can be used to delay reporting a new rtp stream
  until the packet with all the required extensions appear.
  In particular, simulcast tracks need a RID extension in header in order to be handled.
  """

  alias Membrane.RTP

  @type t() :: %__MODULE__{
          pt_to_ext_id: %{RTP.payload_type_t() => [RTP.Header.Extension.identifier_t()]}
        }
  @enforce_keys [:pt_to_ext_id]
  defstruct @enforce_keys
end
