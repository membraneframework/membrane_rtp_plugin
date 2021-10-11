defmodule Membrane.RTP.StreamSendBin do
  @moduledoc """
  Bin payloading and serializing media stream to RTP.
  """
  use Membrane.Bin
  alias Membrane.RTP

  def_input_pad :input, demand_unit: :buffers, caps: :any

  def_output_pad :output, caps: :any, demand_unit: :buffers

  def_options payloader: [default: nil, spec: module],
              payload_type: [spec: RTP.payload_type_t()],
              ssrc: [spec: RTP.ssrc_t()],
              clock_rate: [spec: RTP.clock_rate_t()]

  @impl true
  def handle_init(opts) do
    use_payloader = !is_nil(opts.payloader)

    maybe_link_payloader_bin =
      &to(&1, :payloader, %RTP.PayloaderBin{
        payloader: opts.payloader,
        ssrc: opts.ssrc,
        clock_rate: opts.clock_rate,
        payload_type: opts.payload_type
      })

    links = [
      link_bin_input()
      |> then(if use_payloader, do: maybe_link_payloader_bin, else: & &1)
      |> to(:packet_tracker, %RTP.OutboundPacketTracker{
        serialize_packets?: not use_payloader,
        ssrc: opts.ssrc,
        payload_type: opts.payload_type,
        clock_rate: opts.clock_rate
      })
      |> to_bin_output()
    ]

    spec = %ParentSpec{links: links}
    {{:ok, spec: spec}, %{}}
  end

  @impl true
  def handle_other(:send_stats, _ctx, state) do
    {{:ok, forward: {:packet_tracker, :send_stats}}, state}
  end

  @impl true
  def handle_notification({:outbound_stats, stats}, :packet_tracker, _ctx, state) do
    {{:ok, notify: {:outbound_stats, stats}}, state}
  end
end
