defmodule Membrane.RTCP.Parser do
  @moduledoc """
  Element responsible for receiving raw RTCP packets, parsing them and emitting proper RTCP events.
  """

  use Membrane.Filter

  alias Membrane.Buffer
  alias Membrane.{RTCP, RTCPEvent, RTP, RemoteStream}

  require Membrane.Logger

  def_input_pad :input,
    caps: {RemoteStream, type: :packetized, content_format: one_of([nil, RTP])},
    demand_unit: :buffers

  def_output_pad :output, caps: RTCP
  def_output_pad :rtcp_output, mode: :push, caps: :any

  @impl true
  def handle_init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state) do
    {{:ok, caps: {:output, %RTCP{}}}, state}
  end

  @impl true
  def handle_process(:input, %Buffer{payload: payload, metadata: metadata}, _ctx, state) do
    payload
    |> RTCP.Packet.parse()
    |> case do
      {:ok, packets} ->
        actions = process_packets(packets, metadata)
        {{:ok, actions}, state}

      {:error, reason} ->
        Membrane.Logger.warn("""
        Couldn't parse rtcp packet:
        #{inspect(payload, limit: :infinity)}
        Reason: #{inspect(reason)}. Ignoring packet.
        """)

        {:ok, state}
    end
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_event(:input, %RTCPEvent{} = event, _ctx, state) do
    buffer = %Buffer{payload: RTCP.Packet.serialize(event.rtcp)}
    {{:ok, buffer: {:rtcp_output, buffer}}, state}
  end

  @impl true
  def handle_event(pad, event, ctx, state), do: super(pad, event, ctx, state)

  defp process_packets(rtcp, metadata) do
    Enum.flat_map(rtcp, &process_rtcp(&1, metadata)) ++ [redemand: :output]
  end

  defp process_rtcp(%RTCP.FeedbackPacket{payload: %RTCP.FeedbackPacket.PLI{}}, _metadata) do
    Membrane.Logger.warn("Received packet loss indicator RTCP packet")
    []
  end

  defp process_rtcp(%RTCP.SenderReportPacket{ssrc: ssrc} = packet, metadata) do
    event = %RTCPEvent{
      rtcp: %{packet | reports: []},
      ssrcs: [ssrc],
      arrival_timestamp: Map.get(metadata, :arrival_ts, Membrane.Time.vm_time())
    }

    [event: {:output, event}]
  end

  defp process_rtcp(_unknown_rtcp_packet, _metadata) do
    []
  end
end
