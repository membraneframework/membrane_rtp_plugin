defmodule Membrane.RTP.StreamSendBin do
  @moduledoc """
  Bin payloading and serializing media stream to RTP.
  """
  use Membrane.Bin
  alias Membrane.RTP

  def_input_pad :input, demand_unit: :buffers, caps: :any

  def_output_pad :output, caps: :any, demand_unit: :buffers

  def_options payloader: [spec: module],
              payload_type: [spec: RTP.payload_type_t()],
              ssrc: [spec: RTP.ssrc_t()],
              clock_rate: [spec: RTP.clock_rate_t()]

  @impl true
  def handle_init(opts) do
    children = [
      payloader: opts.payloader,
      serializer: %RTP.Serializer{
        ssrc: opts.ssrc,
        payload_type: opts.payload_type,
        clock_rate: opts.clock_rate
      }
    ]

    links = [link_bin_input() |> to(:payloader) |> to(:serializer) |> to_bin_output()]
    spec = %ParentSpec{children: children, links: links}
    {{:ok, spec: spec}, %{}}
  end

  @impl true
  def handle_other(:send_stats, _ctx, state) do
    {{:ok, forward: {:serializer, :send_stats}}, state}
  end

  @impl true
  def handle_notification({:serializer_stats, stats}, :serializer, _ctx, state) do
    {{:ok, notify: {:serializer_stats, stats}}, state}
  end
end
