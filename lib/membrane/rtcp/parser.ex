defmodule Membrane.RTCP.Parser do
  @moduledoc """
  Parses the incoming RTCP packets and sends to a parent using a notification (`t:notification_t/0`)
  """

  use Membrane.Log, tag: :membrane_rtcp_parser
  use Membrane.Sink

  alias Membrane.{Buffer, RemoteStream, RTCP, Time}

  @type notification_t() :: {:received_rtcp, RTCP.Packet.t()}

  def_input_pad :input,
    caps: {RemoteStream, type: :packetized, content_format: one_of([nil, RTCP])},
    demand_unit: :buffers

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, demand: {:input, 1}}, state}
  end

  @impl true
  def handle_write(:input, %Buffer{payload: payload, metadata: metadata}, _ctx, state) do
    arrival_ts = Map.get(metadata, :arrival_ts, Time.vm_time())

    with {:ok, parsed_rtcp} <- RTCP.Packet.parse(payload) do
      {{:ok, notify: {:received_rtcp, parsed_rtcp, arrival_ts}, demand: {:input, 1}}, state}
    else
      {:error, reason} ->
        warn("Received invalid RTCP packet: #{inspect(reason)}")
        {{:ok, demand: {:input, 1}}, state}
    end
  end
end
