defmodule Membrane.RTP.TCP.Decapsulator do
  @moduledoc """
  This element provides functionality of packetizing bytestream from TCP
  into RTP and RTCP Packets. The encapsulation is described in RFC 4571.

  Packets in the stream will have the following structure:
  [Length :: 2 bytes][packet :: <Length> bytes]
  """
  use Membrane.Filter

  alias Membrane.{Buffer, RemoteStream, RTP}

  def_input_pad :input, accepted_format: %RemoteStream{type: :bytestream}

  def_output_pad :output, accepted_format: %RemoteStream{type: :packetized, content_format: RTP}

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %{unprocessed_data: <<>>}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    stream_format = %RemoteStream{type: :packetized, content_format: RTP}
    {[stream_format: {:output, stream_format}], state}
  end

  @impl true
  def handle_stream_format(:input, _stream_format, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_buffer(:input, %Buffer{payload: payload, metadata: metadata}, _ctx, state) do
    packets_binary = state.unprocessed_data <> payload

    {unprocessed_data, complete_packets_binaries} = get_complete_packets(packets_binary)

    packets_buffers =
      Enum.map(complete_packets_binaries, &%Buffer{payload: &1, metadata: metadata})

    {[buffer: {:output, packets_buffers}], %{state | unprocessed_data: unprocessed_data}}
  end

  @spec get_complete_packets(binary()) ::
          {unprocessed_data :: binary(), complete_packets :: [binary()]}
  defp get_complete_packets(packets_binary, complete_packets \\ [])

  defp get_complete_packets(
         <<payload_length::16, payload::binary-size(payload_length), rest::binary>>,
         complete_packets
       ) do
    get_complete_packets(rest, [payload | complete_packets])
  end

  defp get_complete_packets(unprocessed_data, complete_packets) do
    {unprocessed_data, Enum.reverse(complete_packets)}
  end
end
