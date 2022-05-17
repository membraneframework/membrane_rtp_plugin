defmodule Membrane.RTP.Metrics do
  @moduledoc false

  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics() do
    [
      Telemetry.Metrics.counter(
        "inbound-rtp.keyframe_request_sent",
        event_name: [:sending_fir, :rtcp]
      ),
      Telemetry.Metrics.counter(
        "inbound-rtp.packets",
        event_name: [:packet_arrival, :rtp]
      ),
      Telemetry.Metrics.sum(
        "inbound-rtp.bytes_received",
        event_name: [:packet_arrival, :rtp],
        measurement: :bytes
      ),
      Telemetry.Metrics.last_value(
        "inbound-rtp.encoding",
        event_name: [:packet_arrival, :rtp],
        measurement: :encoding
      ),
      Telemetry.Metrics.last_value(
        "inbound-rtp.ssrc",
        event_name: [:packet_arrival, :rtp],
        measurement: :ssrc
      )
    ]
  end
end
