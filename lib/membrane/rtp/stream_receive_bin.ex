defmodule Membrane.RTP.StreamReceiveBin do
  @moduledoc """
  This bin gets a parsed RTP stream on input and outputs raw media stream.

  Its responsibility is to depayload the RTP stream and compensate the
  jitter.
  """

  use Membrane.Bin

  alias Membrane.ParentSpec

  def_options srtp_policies: [
                spec: [ExLibSRTP.Policy.t()],
                default: []
              ],
              secure?: [
                type: :boolean,
                default: false
              ],
              filters: [
                spec: [Membrane.RTP.SessionBin.packet_filter_t()],
                default: []
              ],
              clock_rate: [
                type: :integer,
                spec: RTP.clock_rate_t()
              ],
              depayloader: [spec: module() | nil],
              local_ssrc: [spec: Membrane.RTP.ssrc_t()],
              remote_ssrc: [spec: Membrane.RTP.ssrc_t()],
              rtcp_report_interval: [spec: Membrane.Time.t() | nil],
              rtcp_fir_interval: [spec: Membrane.Time.t() | nil]

  def_input_pad :input, demand_unit: :buffers, caps: :any
  def_output_pad :output, caps: :any, demand_unit: :buffers

  @impl true
  def handle_init(opts) do
    maybe_link_decryptor =
      &to(&1, :decryptor, %Membrane.SRTP.Decryptor{policies: opts.srtp_policies})

    maybe_link_depayloader_bin =
      &to(&1, :depayloader, %Membrane.RTP.DepayloaderBin{
        depayloader: opts.depayloader,
        clock_rate: opts.clock_rate
      })

    links = [
      link_bin_input()
      |> to_filters(opts.filters)
      |> to(:rtcp_receiver, %Membrane.RTCP.Receiver{
        local_ssrc: opts.local_ssrc,
        remote_ssrc: opts.remote_ssrc,
        report_interval: opts.rtcp_report_interval,
        fir_interval: opts.rtcp_fir_interval
      })
      |> to(:tracker, %Membrane.RTP.InboundPacketTracker{
        clock_rate: opts.clock_rate,
        repair_sequence_numbers?: true
      })
      |> then(if opts.secure?, do: maybe_link_decryptor, else: & &1)
      |> then(if opts.depayloader, do: maybe_link_depayloader_bin, else: & &1)
      |> to_bin_output()
    ]

    spec = %ParentSpec{
      links: links
    }

    {{:ok, spec: spec}, %{}}
  end

  defp to_filters(link_builder, filters) do
    Enum.reduce(filters, link_builder, fn {filter_name, filter}, builder ->
      builder |> to(filter_name, filter)
    end)
  end
end
