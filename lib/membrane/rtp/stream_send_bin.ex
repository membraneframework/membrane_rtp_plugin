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
    maybe_link_payloader = &to(&1, :payloader, opts.payloader)

    links = [
      link_bin_input()
      |> then(if opts.payloader != nil, do: maybe_link_payloader, else: & &1)
      # TODO: do we event need the serializer in case we don't provide the payloader?
      # its main responsibility previously was to rewrite sequence numbers to match the outgoing packets
      # and to generate some stats
      |> to(:serializer, %RTP.Serializer{
        ssrc: opts.ssrc,
        payload_type: opts.payload_type,
        clock_rate: opts.clock_rate,
        generate_seq_num_and_timestamp?: opts.payloader != nil
      })
      |> to_bin_output()
    ]

    spec = %ParentSpec{links: links}
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
