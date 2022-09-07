defmodule Membrane.RTP.StreamReceiveBin do
  @moduledoc """
  This bin gets a parsed RTP stream on input and outputs raw media stream.

  Its responsibility is to depayload the RTP stream and compensate the
  jitter.
  """

  use Membrane.Bin

  alias Membrane.{ParentSpec, RTCP, RTP, SRTP}

  def_options srtp_policies: [
                spec: [ExLibSRTP.Policy.t()],
                default: []
              ],
              secure?: [
                type: :boolean,
                default: false
              ],
              extensions: [
                spec: [RTP.SessionBin.extension_t()],
                default: []
              ],
              clock_rate: [
                type: :integer,
                spec: RTP.clock_rate_t()
              ],
              depayloader: [spec: module() | nil],
              local_ssrc: [spec: RTP.ssrc_t()],
              remote_ssrc: [spec: RTP.ssrc_t()],
              rtcp_report_interval: [spec: Membrane.Time.t() | nil],
              telemetry_label: [
                spec: [{atom(), any()}],
                default: []
              ]

  def_input_pad :input, demand_unit: :buffers, caps: :any
  def_output_pad :output, caps: :any, demand_unit: :buffers

  @impl true
  def handle_init(opts) do
    if opts.secure? and not Code.ensure_loaded?(ExLibSRTP),
      do: raise("Optional dependency :ex_libsrtp is required when using secure? option")

    maybe_link_decryptor =
      &to(&1, :decryptor, struct(SRTP.Decryptor, %{policies: opts.srtp_policies}))

    maybe_link_depayloader_bin =
      &to(&1, :depayloader, %RTP.DepayloaderBin{
        depayloader: opts.depayloader,
        clock_rate: opts.clock_rate
      })

    links = [
      link_bin_input()
      |> to_extensions(opts.extensions)
      |> to(:rtcp_receiver, %RTCP.Receiver{
        local_ssrc: opts.local_ssrc,
        remote_ssrc: opts.remote_ssrc,
        report_interval: opts.rtcp_report_interval,
        telemetry_label: opts.telemetry_label
      })
      |> to(:packet_tracker, %RTP.InboundPacketTracker{
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

  defp to_extensions(link_builder, extensions) do
    Enum.reduce(extensions, link_builder, fn {extension_name, extension}, builder ->
      builder |> to(extension_name, extension)
    end)
  end
end
