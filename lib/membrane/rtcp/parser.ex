defmodule Membrane.RTCP.Parser do
  @moduledoc """
  Element responsible for receiving raw RTCP packets, parsing them and emitting proper RTCP events.
  """

  use Membrane.Filter

  require Membrane.Logger
  require Membrane.TelemetryMetrics
  alias Membrane.Buffer
  alias Membrane.{RemoteStream, RTCP, RTCPEvent}

  def_input_pad :input,
    accepted_format: %RemoteStream{type: :packetized, content_format: cf} when cf in [nil, RTCP],
    demand_mode: :auto,
    options: [
      telemetry_label: [
        spec: Membrane.TelemetryMetrics.label(),
        default: []
      ]
    ]

  def_output_pad :output, accepted_format: RTCP, demand_mode: :auto

  def_output_pad :receiver_report_output,
    mode: :push,
    accepted_format: %RemoteStream{type: :packetized, content_format: RTCP}

  def_options telemetry_label: [spec: Membrane.TelemetryMetrics.label(), default: []]

  @rtcp_received_telemetry_event [Membrane.RTP, :inbound, :rtcp, :arrival]
  @rtcp_sent_telemetry_event [Membrane.RTP, :inbound, :rtcp, :sent]

  @impl true
  def handle_init(_ctx, opts) do
    Membrane.TelemetryMetrics.register(@rtcp_received_telemetry_event, opts.telemetry_label)
    Membrane.TelemetryMetrics.register(@rtcp_sent_telemetry_event, opts.telemetry_label)

    {[], Map.from_struct(opts)}
  end

  @impl true
  def handle_playing(_ctx, state) do
    stream_format = %RemoteStream{type: :packetized, content_format: RTCP}
    {[stream_format: {:receiver_report_output, stream_format}], state}
  end

  @impl true
  def handle_stream_format(:input, _stream_format, _ctx, state) do
    {[stream_format: {:output, %RTCP{}}], state}
  end

  @impl true
  def handle_process(:input, %Buffer{payload: payload, metadata: metadata}, _ctx, state) do
    Membrane.TelemetryMetrics.execute(
      @rtcp_received_telemetry_event,
      %{bytes: byte_size(payload)},
      %{},
      state.telemetry_label
    )

    payload
    |> RTCP.Packet.parse()
    |> case do
      {:ok, packets} ->
        actions = process_packets(packets, metadata)
        {actions, state}

      {:error, reason} ->
        Membrane.Logger.warn("""
        Couldn't parse rtcp packet:
        #{inspect(payload, limit: :infinity)}
        Reason: #{inspect(reason)}. Ignoring packet.
        """)

        {[], state}
    end
  end

  @impl true
  def handle_event(:output, %RTCPEvent{} = event, _ctx, state) do
    buffer = %Buffer{payload: RTCP.Packet.serialize(event.rtcp)}

    Membrane.TelemetryMetrics.execute(
      @rtcp_sent_telemetry_event,
      %{bytes: byte_size(buffer.payload)},
      %{},
      state.telemetry_label
    )

    {[buffer: {:receiver_report_output, buffer}], state}
  end

  @impl true
  def handle_event(pad, event, ctx, state), do: super(pad, event, ctx, state)

  defp process_packets(rtcp, metadata) do
    Enum.flat_map(rtcp, &process_rtcp(&1, metadata))
  end

  defp process_rtcp(%RTCP.FeedbackPacket{payload: %keyframe_request{}} = packet, metadata)
       when keyframe_request in [RTCP.FeedbackPacket.FIR, RTCP.FeedbackPacket.PLI] do
    event = to_rtcp_event(packet, packet.target_ssrc, metadata)
    [event: {:output, event}]
  end

  defp process_rtcp(
         %RTCP.TransportFeedbackPacket{
           media_ssrc: ssrc,
           payload: %RTCP.TransportFeedbackPacket.NACK{lost_packet_ids: lost_packets}
         },
         _metadata
       ) do
    Membrane.Logger.debug(
      "SSRC #{ssrc} reported loss of #{length(lost_packets)} packet(s): #{inspect(lost_packets)}"
    )

    []
  end

  defp process_rtcp(
         %RTCP.TransportFeedbackPacket{payload: %RTCP.TransportFeedbackPacket.TWCC{} = feedback},
         _metadata
       ) do
    [notify_parent: {:twcc_feedback, feedback}]
  end

  defp process_rtcp(%RTCP.SenderReportPacket{ssrc: ssrc} = packet, metadata) do
    event = to_rtcp_event(packet, ssrc, metadata)
    [event: {:output, event}]
  end

  defp process_rtcp(%RTCP.ReceiverReportPacket{reports: reports}, metadata) do
    reports
    |> Enum.map(fn report ->
      event = to_rtcp_event(report, report.ssrc, metadata)
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

  defp to_rtcp_event(rtcp_packet, ssrc, metadata) do
    %RTCPEvent{
      rtcp: rtcp_packet,
      ssrcs: [ssrc],
      arrival_timestamp: Map.get(metadata, :arrival_ts, Membrane.Time.vm_time())
    }
  end
end
