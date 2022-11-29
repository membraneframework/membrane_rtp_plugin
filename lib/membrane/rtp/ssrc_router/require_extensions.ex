defmodule Membrane.RTP.SSRCRouter.RequireExtensions do
  @moduledoc """
  A struct instructing SSRCRouter to delay reporting new rtp stream
  until the packet with all the required extensions appear.
  """

  alias Membrane.RTP

  @type t() :: %__MODULE__{
          pt_to_ext_id: %{RTP.payload_type_t() => [RTP.Header.Extension.identifier_t()]}
        }
  @enforce_keys [:pt_to_ext_id]
  defstruct @enforce_keys
end
