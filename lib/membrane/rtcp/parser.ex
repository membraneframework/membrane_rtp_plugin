defmodule Membrane.RTCP.Parser do
  @moduledoc """
  Element responsible for receiving raw RTCP packets, parsing them and emitting proper RTCP events.
  """

  use Membrane.Filter

  alias Membrane.Buffer
  alias Membrane.{RTCP, RTCPEvent, RemoteStream}

  require Membrane.Logger

  def_input_pad :input,
    caps: {RemoteStream, type: :packetized, content_format: one_of([nil, RTCP])},
    demand_mode: :auto

  def_output_pad :output, caps: RTCP, demand_mode: :auto

  def_output_pad :receiver_report_output,
    mode: :push,
    caps: {RemoteStream, type: :packetized, content_format: RTCP}

  @impl true
  def handle_init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok,
      caps: {:receiver_report_output, %RemoteStream{type: :packetized, content_format: RTCP}}},
     state}
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
  def handle_event(:output, %RTCPEvent{} = event, _ctx, state) do
    buffer = %Buffer{payload: RTCP.Packet.serialize(event.rtcp)}
    {{:ok, buffer: {:receiver_report_output, buffer}}, state}
  end

  defp process_packets(rtcp, metadata) do
    Enum.flat_map(rtcp, &process_rtcp(&1, metadata))
  end

  defp process_rtcp(%RTCP.FeedbackPacket{payload: %keyframe_request{}} = packet, metadata)
       when keyframe_request in [RTCP.FeedbackPacket.FIR, RTCP.FeedbackPacket.PLI] do
    event = wrap_with_rtcp_event(packet, packet.target_ssrc, metadata)
    [event: {:output, event}]
  end

  defp process_rtcp(
         %RTCP.TransportFeedbackPacket{payload: %RTCP.TransportFeedbackPacket.TWCC{} = feedback},
         _metadata
       ) do
    [notify: {:twcc_feedback, feedback}]
  end

  defp process_rtcp(%RTCP.SenderReportPacket{ssrc: ssrc} = packet, metadata) do
    event = wrap_with_rtcp_event(packet, ssrc, metadata)
    [event: {:output, event}]
  end

  defp process_rtcp(%RTCP.ReceiverReportPacket{reports: reports}, metadata) do
    reports
    |> Enum.map(fn report ->
      event = wrap_with_rtcp_event(report, report.ssrc, metadata)
      {:event, {:output, event}}
    end)
  end

  defp process_rtcp(
         %RTCP.FeedbackPacket{
           payload: %RTCP.FeedbackPacket.AFB{message: "REMB" <> _remb_data}
         },
         _metadata
       ) do
    # maybe TODO: handle REMB extension
    # Even though we do not support REMB and do not advertise such support in SDP,
    # browsers ignore that and send REMB packets for video as part of sender report ¯\_(ツ)_/¯
    []
  end

  defp process_rtcp(%RTCP.ByePacket{ssrcs: ssrcs}, _metadata) do
    Membrane.Logger.debug("SSRCs #{inspect(ssrcs)} are leaving (received RTCP Bye)")
    []
  end

  defp process_rtcp(%RTCP.SdesPacket{}, _metadata) do
    # We don't care about SdesPacket, usually included in compound packet with SenderReportPacket or ReceiverReportPacket
    []
  end

  defp process_rtcp(unknown_packet, metadata) do
    Membrane.Logger.warn("""
    Unhandled RTCP packet
    #{inspect(unknown_packet, pretty: true, limit: :infinity)}
    #{inspect(metadata, pretty: true)}
    """)

    []
  end

  defp wrap_with_rtcp_event(rtcp_packet, ssrc, metadata) do
    %RTCPEvent{
      rtcp: rtcp_packet,
      ssrcs: [ssrc],
      arrival_timestamp: Map.get(metadata, :arrival_ts, Membrane.Time.vm_time())
    }
  end
end
