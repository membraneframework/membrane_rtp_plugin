defmodule Membrane.RTP.PayloaderBin do
  @moduledoc """
  Module responsible for payloading a stream to RTP format and preparing RTP headers.
  """

  use Membrane.Bin

  alias Membrane.{ParentSpec, RTP}

  def_input_pad :input, demand_unit: :buffers, caps: :any

  def_output_pad :output, caps: :any, demand_unit: :buffers

  def_options payloader: [
                spec: module(),
                description: "Payloader module used for payloading a stream to RTP format"
              ],
              ssrc: [spec: RTP.ssrc_t()],
              payload_type: [spec: RTP.payload_type_t()],
              clock_rate: [spec: RTP.clock_rate_t()]

  @impl true
  def handle_init(opts) do
    links = [
      link_bin_input()
      |> to(:payloader, opts.payloader)
      |> to(:header_generator, %RTP.HeaderGenerator{
        ssrc: opts.ssrc,
        payload_type: opts.payload_type,
        clock_rate: opts.clock_rate
      })
      |> to_bin_output()
    ]

    {{:ok, spec: %ParentSpec{links: links}}, %{}}
  end
end
