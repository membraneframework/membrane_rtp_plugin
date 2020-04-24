defmodule Membrane.RTCP.Parser do
  @moduledoc """
  Parses the incoming RTCP packets and sends to a parent using a notification (`t:notification_t/0`)
  """

  use Membrane.Log, tag: :membrane_rtcp_parser
  use Membrane.Filter

  alias Membrane.Buffer
  alias Membrane.RTCP

  @type notification_t() :: {:received_rtcp, RTCP.CompoundPacket.t()}

  def_input_pad :input, caps: :any, demand_unit: :buffers

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, demand: {:input, 1}}, state}
  end

  @impl true
  def handle_process(:input, %Buffer{payload: payload}, _ctx, state) do
    with {:ok, parsed_rtcp} <- RTCP.CompoundPacket.parse(payload) do
      {{:ok, notify: {:received_rtcp, parsed_rtcp}, demand: {:input, 1}}, state}
    else
      {:error, reason} ->
        warn("Received invalid RTCP packet: #{inspect(reason)}")
        {{:ok, demand: {:input, 1}}, state}
    end
  end
end
