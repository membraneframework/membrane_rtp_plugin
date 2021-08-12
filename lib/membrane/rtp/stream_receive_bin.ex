defmodule Membrane.RTP.StreamReceiveBin do
  @moduledoc """
  This bin gets a parsed RTP stream on input and outputs raw media stream.
  Its responsibility is to depayload the RTP stream and compensate the
  jitter.
  """

  use Membrane.Bin

  alias Membrane.ParentSpec

  def_options clock_rate: [type: :integer, spec: Membrane.RTP.clock_rate_t()],
              depayloader: [type: :module],
              local_ssrc: [spec: Membrane.RTP.ssrc_t()],
              remote_ssrc: [spec: Membrane.RTP.ssrc_t()],
              rtcp_report_interval: [spec: Membrane.Time.t() | nil],
              rtcp_fir_interval: [spec: Membrane.Time.t() | nil]

  def_input_pad :input, demand_unit: :buffers, caps: :any

  def_output_pad :output, caps: :any, demand_unit: :buffers

  @impl true
  def handle_init(opts) do
    children = [
      rtcp_receiver: %Membrane.RTCP.Receiver{
        local_ssrc: opts.local_ssrc,
        remote_ssrc: opts.remote_ssrc,
        report_interval: opts.rtcp_report_interval,
        fir_interval: opts.rtcp_fir_interval
      },
      jitter_buffer: %Membrane.RTP.JitterBuffer{clock_rate: opts.clock_rate},
      depayloader: opts.depayloader
    ]

    links = [
      link_bin_input()
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
end
