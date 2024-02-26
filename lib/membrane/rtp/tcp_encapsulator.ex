defmodule Membrane.RTP.TCP.Encapsulator do
  @moduledoc """
  This element provides functionality of serializing RTP and RTCP packets into a bytestream
  that can be send over TCP connection. The encapsulation is described in RFC 4571.

  Packets in the stream will have the following structure:
  [Length :: 2 bytes][packet :: <Length> bytes]
  """
  use Membrane.Filter

  alias Membrane.{Buffer, RemoteStream, RTP}

  def_input_pad :input, accepted_format: %RemoteStream{type: :packetized, content_format: RTP}

  def_output_pad :output, accepted_format: %RemoteStream{type: :bytestream}

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %{}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    stream_format = %RemoteStream{type: :bytestream}
    {[stream_format: {:output, stream_format}], state}
  end

  @impl true
  def handle_stream_format(:input, _stream_format, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_buffer(:input, %Buffer{payload: payload, metadata: metadata}, _ctx, state) do
    buffer = %Buffer{
      payload: <<byte_size(payload)::size(16), payload::binary>>,
      metadata: metadata
    }

    {[buffer: {:output, [buffer]}], state}
  end
end
