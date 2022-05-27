defmodule Membrane.RTP.Metrics do
  @moduledoc false

  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics() do
    [
      Telemetry.Metrics.counter(
        "inbound-rtp.keyframe_request_sent",
        event_name: [:RTCP, :fir, :sending]
      ),
      Telemetry.Metrics.counter(
        "inbound-rtp.packets",
        event_name: [:RTP, :packet, :arrival]
      ),
      Telemetry.Metrics.sum(
        "inbound-rtp.bytes_received",
        event_name: [:RTP, :packet, :arrival],
        measurement: :bytes
      ),
      Telemetry.Metrics.last_value(
        "inbound-rtp.encoding",
        event_name: [:RTP, :inbound_track, :new],
        measurement: :encoding
      ),
      Telemetry.Metrics.last_value(
        "inbound-rtp.ssrc",
        event_name: [:RTP, :inbound_track, :new],
        measurement: :ssrc
      )
    ]
  end
end
