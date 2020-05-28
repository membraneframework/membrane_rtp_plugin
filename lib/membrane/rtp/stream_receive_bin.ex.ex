defmodule Membrane.RTP.StreamReceiveBin do
  @moduledoc """
  This bin gets a parsed RTP stream on input and outputs raw media stream.
  Its responsibility is to depayload the RTP stream and compensate the
  jitter.

  TODO: payload type demuxing
  """

  use Membrane.Bin

  alias Membrane.ParentSpec

  def_options clock_rate: [type: :integer, spec: Membrane.RTP.clock_rate_t()],
              depayloader: [type: :module],
              ssrc: [spec: Membrane.RTP.ssrc_t()]

  def_input_pad :input, demand_unit: :buffers, caps: :any

  def_output_pad :output, caps: :any, demand_unit: :buffers

  @impl true
  def handle_init(opts) do
    children = [
      jitter_buffer: %Membrane.RTP.JitterBuffer{clock_rate: opts.clock_rate},
      depayloader: opts.depayloader
    ]

    links = [
      link_bin_input()
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
