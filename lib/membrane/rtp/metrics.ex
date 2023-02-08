defmodule Membrane.RTP.Metrics do
  @moduledoc """
  Defines list of metrics, that can be aggregated based on events from membrane_rtp_plugin.
  """

  alias Telemetry.Metrics

  @doc """
  Returns list of metrics, that can be aggregated based on events from membrane_rtp_plugin.
  """
  @spec metrics() :: [Metrics.t()]
  def metrics() do
    [
      Metrics.counter(
        "inbound-rtp.keyframe_request_sent",
        event_name: [Membrane.RTP, :rtcp, :fir, :sent]
      ),
      Metrics.counter(
        "inbound-rtp.packets",
        event_name: [Membrane.RTP, :packet, :arrival]
      ),
      Metrics.sum(
        "inbound-rtp.bytes_received",
        event_name: [Membrane.RTP, :packet, :arrival],
        measurement: :bytes
      ),
      Metrics.last_value(
        "inbound-rtp.encoding",
        event_name: [Membrane.RTP, :inbound_track, :new],
        measurement: :encoding
      ),
      Metrics.last_value(
        "inbound-rtp.ssrc",
        event_name: [Membrane.RTP, :inbound_track, :new],
        measurement: :ssrc
      ),
      Metrics.counter(
        "inbound-rtp.nack",
        event_name: [Membrane.RTP, :rtcp, :nack, :sent]
      ),
      Metrics.counter(
        "inbound-rtcp.packets",
        event_name: [Membrane.RTP, :rtcp, :arrival]
      ),
      Metrics.sum(
        "inbound-rtcp.bytes_received",
        event_name: [Membrane.RTP, :rtcp, :arrival],
        measurement: :bytes
      ),
      Metrics.counter(
        "outbound-rtcp.packets",
        event_name: [Membrane.RTP, :rtcp, :sent]
      ),
      Metrics.sum(
        "outbound-rtcp.bytes_sent",
        event_name: [Membrane.RTP, :rtcp, :sent],
        measurement: :bytes
      ),
      Metrics.counter(
        "outbound-rtp.frames",
        event_name: [Membrane.RTP, :rtp, :frame_sent]
      ),
      Metrics.counter(
        "inbound-rtp.frames",
        event_name: [Membrane.RTP, :rtp, :frame_received]
      )
    ]
  end
end
