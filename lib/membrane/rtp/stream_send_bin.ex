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

  def_options payloader: [default: nil, spec: module],
              payload_type: [spec: RTP.payload_type_t()],
              ssrc: [spec: RTP.ssrc_t()],
              clock_rate: [spec: RTP.clock_rate_t()],
              rtcp_report_interval: [spec: Membrane.Time.t() | nil],
              rtp_extension_mapping: [
                default: nil,
                spec: RTP.SessionBin.rtp_extension_mapping_t()
              ],
              twcc_probing?: [
                spec: boolean(),
                default: false
              ]

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

    maybe_link_connection_prober =
      &to(&1, :twcc_connection_prober, %RTP.TWCCSender.ConnectionProber{
        ssrc: opts.ssrc,
        payload_type: opts.payload_type
      })

    links = [
      link_bin_input()
      |> then(if use_payloader, do: maybe_link_payloader_bin, else: & &1)
      |> then(if opts.twcc_probing?, do: maybe_link_connection_prober, else: & &1)
      |> to(:packet_tracker, %RTP.OutboundPacketTracker{
        ssrc: opts.ssrc,
        payload_type: opts.payload_type,
        clock_rate: opts.clock_rate,
        extension_mapping: opts.rtp_extension_mapping || %{}
      })
      |> to_bin_output()
    ]

    spec = %ParentSpec{links: links}
    {{:ok, spec: spec}, %{ssrc: opts.ssrc, rtcp_report_interval: opts.rtcp_report_interval}}
  end

  @impl true
  def handle_prepared_to_playing(_context, %{rtcp_report_interval: nil} = state), do: {:ok, state}

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, start_timer: {:report_timer, state.rtcp_report_interval}}, state}
  end

  @impl true
  def handle_playing_to_prepared(_context, %{rtcp_report_interval: nil} = state), do: {:ok, state}

  @impl true
  def handle_playing_to_prepared(_context, state) do
    {{:ok, stop_timer: :report_timer}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:rtcp_output, _id) = pad, _ctx, state) do
    links = [
      link(:packet_tracker)
      |> via_out(:rtcp_output)
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
      |> to(:packet_tracker)
    ]

    spec = %ParentSpec{links: links}

    {{:ok, spec: spec}, state}
  end

  @impl true
  def handle_tick(:report_timer, _ctx, state) do
    {{:ok, forward: {:packet_tracker, :send_stats}}, state}
  end
end
