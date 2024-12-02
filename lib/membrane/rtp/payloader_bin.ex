defmodule Membrane.RTP.PayloaderBin do
  @moduledoc """
  Module responsible for payloading a stream to RTP format and preparing RTP headers.
  """

  use Membrane.Bin

  alias Membrane.RTP

  def_input_pad :input, accepted_format: _any

  def_output_pad :output, accepted_format: RTP

  def_options payloader: [
                spec: module(),
                description: "Payloader module used for payloading a stream to RTP format"
              ],
              ssrc: [spec: RTP.ssrc()],
              payload_type: [spec: RTP.payload_type()],
              clock_rate: [spec: RTP.clock_rate()]

  @impl true
  def handle_init(_ctx, opts) do
    structure =
      bin_input()
      |> child(:payloader, opts.payloader)
      |> child(:header_generator, %RTP.HeaderGenerator{
        ssrc: opts.ssrc,
        payload_type: opts.payload_type,
        clock_rate: opts.clock_rate
      })
      |> bin_output()

    {[spec: structure], %{}}
  end
end
