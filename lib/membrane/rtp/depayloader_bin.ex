defmodule Membrane.RTP.DepayloaderBin do
  @moduledoc """
  Modules responsible for reordering incoming RTP packets using a jitter buffer
  to later depayload packet's payload from RTP format.
  """

  use Membrane.Bin

  alias Membrane.RTP.JitterBuffer

  def_options depayloader: [
                spec: module(),
                description: "Depayloader module that should be used for incoming stream"
              ],
              clock_rate: [
                spec: RTP.clock_rate_t()
              ]

  def_input_pad :input,
    caps: RTP,
    demand_unit: :buffers

  def_output_pad :output,
    caps: RTP,
    demand_unit: :buffers

  @impl true
  def handle_init(opts) do
    links = [
      link_bin_input()
      |> to(:jitter_buffer, %JitterBuffer{clock_rate: opts.clock_rate})
      |> to(:depayloader, opts.depayloader)
      |> to_bin_output()
    ]

    {{:ok, spec: %ParentSpec{links: links}}, %{}}
  end
end
