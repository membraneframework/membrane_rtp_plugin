defmodule Membrane.RTP.StreamReceiveBin do
  @moduledoc """
  This bin gets a parsed RTP stream on input and outputs raw media stream.
  Its responsibility is to depayload the RTP stream and compensate the
  jitter.
  """

  use Membrane.Bin

  alias Membrane.ParentSpec

  def_options clock_rate: [type: :integer, spec: Membrane.RTP.clock_rate_t()],
              srtp_policies: [
                spec: [ExLibSRTP.Policy.t()] | nil,
                default: nil
              ],
              filters: [
                spec: {atom(), :struct | :module},
                default: []
              ],
              depayloader: [type: :module],
              local_ssrc: [spec: Membrane.RTP.ssrc_t()],
              remote_ssrc: [spec: Membrane.RTP.ssrc_t()],
              rtcp_interval: [spec: Membrane.Time.t()]

  # FIXME: input caps should be specified I guess
  def_input_pad :input, demand_unit: :buffers, caps: :any
  def_output_pad :output, caps: :any, demand_unit: :buffers

  @impl true
  def handle_init(opts) do
    children = %{
      rtcp_receiver: %Membrane.RTCP.Receiver{
        local_ssrc: opts.local_ssrc,
        remote_ssrc: opts.remote_ssrc,
        report_interval: opts.rtcp_interval
      },
      jitter_buffer: %Membrane.RTP.JitterBuffer{clock_rate: opts.clock_rate},
      depayloader: opts.depayloader
    }

    maybe_link_decryptor =
      &to(&1, :decryptor, %Membrane.SRTP.Decryptor{policies: opts.srtp_policies})

    links = [
      link_bin_input()
      |> to_filters(opts.filters)
      |> then(if opts.srtp_policies != nil, do: maybe_link_decryptor, else: & &1)
      |> to(:rtcp_receiver)
      |> to(:jitter_buffer)
      |> to(:depayloader)
      |> to_bin_output()
    ]

    spec = %ParentSpec{
      children: children,
      links: links
    }

    {{:ok, spec: spec}, %{}}
  end

  @impl true
  def handle_other(:send_stats, _ctx, state) do
    {{:ok, forward: {:jitter_buffer, :send_stats}}, state}
  end

  @impl true
  def handle_notification({:jitter_buffer_stats, stats}, :jitter_buffer, _ctx, state) do
    {{:ok, notify: {:jitter_buffer_stats, stats}}, state}
  end

  defp to_filters(link_builder, filters) do
    Enum.reduce(filters, link_builder, fn {filter_name, filter}, builder ->
      builder |> to(filter_name, filter)
    end)
  end
end
