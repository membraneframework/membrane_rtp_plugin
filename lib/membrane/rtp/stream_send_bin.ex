defmodule Membrane.RTP.StreamSendBin do
  @moduledoc """
  Bin payloading and serializing media stream to RTP.
  """
  use Membrane.Bin
  alias Membrane.RTP

  def_input_pad :input, demand_unit: :buffers, caps: :any

  def_output_pad :output, caps: :any, demand_unit: :buffers

  def_options payloader: [type: :module],
              ssrc: [spec: Membrane.RTP.ssrc_t()]

  @impl true
  def handle_init(opts) do
    children = [
      payloader: opts.payloader,
      serializer: %RTP.Serializer{ssrc: opts.ssrc}
    ]

    links = [link_bin_input() |> to(:payloader) |> to(:serializer) |> to_bin_output()]
    spec = %ParentSpec{children: children, links: links}
    {{:ok, spec: spec}, %{}}
  end
end
