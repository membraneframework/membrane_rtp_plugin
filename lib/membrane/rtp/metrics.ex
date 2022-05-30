defmodule Membrane.RTP.Metrics do
  @moduledoc """
  Defines list of metrics, that can be aggregated based on events from membrane_rtp_plugin.
  """

  @doc """
  Returns list of metrics, that can be aggregated based on events from membrane_rtp_plugin.
  """
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics() do
    [
      Telemetry.Metrics.counter(
        "inbound-rtp.keyframe_request_sent",
        event_name: [Membrane.RTP, :RTCP, :fir, :sent]
      ),
      Telemetry.Metrics.counter(
        "inbound-rtp.packets",
        event_name: [Membrane.RTP, :RTP, :packet, :arrival]
      ),
      Telemetry.Metrics.sum(
        "inbound-rtp.bytes_received",
        event_name: [Membrane.RTP, :RTP, :packet, :arrival],
        measurement: :bytes
      ),
      Telemetry.Metrics.last_value(
        "inbound-rtp.encoding",
        event_name: [Membrane.RTP, :RTP, :inbound_track, :new],
        measurement: :encoding
      ),
      Telemetry.Metrics.last_value(
        "inbound-rtp.ssrc",
        event_name: [Membrane.RTP, :RTP, :inbound_track, :new],
        measurement: :ssrc
      )
    ]
  end
end
