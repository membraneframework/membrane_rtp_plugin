defmodule Membrane.RTCP.Parser do
  @moduledoc """
  Parses the incoming RTCP packets
  """

  use Membrane.Filter

  alias Membrane.RTCP

  def_input_pad :input, caps: RTCP, demand_unit: :buffers

  # TODO: implement the element
end
