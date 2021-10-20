defmodule Membrane.RTP.StreamSendBin do
  @moduledoc """
  Bin payloading and serializing media stream to RTP.
  """
  use Membrane.Bin
  alias Membrane.RTP

  def_input_pad :input, demand_unit: :buffers, caps: :any
  def_input_pad :rtcp_input, availability: :on_request, demand_unit: :buffers, caps: :any

  def_output_pad :output, caps: :any, demand_unit: :buffers
  def_output_pad :rtcp_output, availability: :on_request, caps: :any, demand_unit: :buffers

  def_options payloader: [spec: module],
              payload_type: [spec: RTP.payload_type_t()],
              ssrc: [spec: RTP.ssrc_t()],
              clock_rate: [spec: RTP.clock_rate_t()],
              rtcp_report_interval: [spec: Membrane.Time.t() | nil]

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

    links = [
      link_bin_input()
      |> to(:payloader)
      |> to(:serializer)
      |> to_bin_output()
    ]

    spec = %ParentSpec{children: children, links: links}
    {{:ok, spec: spec}, %{ssrc: opts.ssrc, rtcp_report_interval: opts.rtcp_report_interval}}
  end

  @impl true
  def handle_prepared_to_playing(_context, %{rtcp_report_interval: nil} = state), do: {:ok, state}

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, start_timer: {:report_timer, state.rtcp_report_interval}}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:rtcp_output, _id) = pad, _ctx, state) do
    links = [
      link(:serializer)
      |> via_out(Pad.ref(:rtcp_output, make_ref()))
      |> to_bin_output(pad)
    ]

    spec = %ParentSpec{links: links}
    {{:ok, spec: spec}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:rtcp_input, _id) = pad, _ctx, state) do
    links = [
      link_bin_input(pad)
      |> via_in(:rtcp_input)
      |> to(:serializer)
    ]

    spec = %ParentSpec{links: links}

    {{:ok, spec: spec}, state}
  end

  @impl true
  def handle_tick(:report_timer, _ctx, state) do
    {{:ok, forward: {:serializer, :send_stats}}, state}
  end
end
