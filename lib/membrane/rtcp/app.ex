defmodule Membrane.RTCP.App do
  @moduledoc """
  Parses RTCP APP packets defined in [RFC3550](https://tools.ietf.org/html/rfc3550#section-6.7)
  """
  defstruct [:subtype, :ssrc, :name, :data]

  @type t :: %__MODULE__{
          subtype: non_neg_integer(),
          ssrc: non_neg_integer(),
          name: String.t(),
          data: binary()
        }

  def parse(<<ssrc::32, name::32, data::binary>>, counter) do
    {:ok,
     %__MODULE__{
       subtype: counter,
       ssrc: ssrc,
       name: to_string(name),
       data: data
     }}
  end
end
