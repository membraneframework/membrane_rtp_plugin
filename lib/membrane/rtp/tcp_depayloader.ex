defmodule Membrane.RTP.TCP.Depayloader do
  @moduledoc """
  This element provides functionality of depayloading RTP Packets received by TCP. The encapsulation
  is described in RFC 7826 Section 14.
  """
  use Membrane.Filter

  alias Membrane.{Buffer, RemoteStream, RTP}

  def_options discard_non_rtp_packets: [
                spec: bool(),
                default: true,
                description: """
                Discard any data that is not RTP packets.
                """
              ],
              rtp_channel_id: [
                spec: non_neg_integer(),
                default: 0,
                description: """
                Channel identifier which encapsulated RTP packets will have.
                """
              ]

  def_input_pad :input, accepted_format: %RemoteStream{type: :bytestream}

  def_output_pad :output, accepted_format: %RemoteStream{type: :packetized, content_format: RTP}

  @impl true
  def handle_init(_ctx, opts) do
    state =
      Map.from_struct(opts)
      |> Map.merge(%{
        incomplete_packet_binary: <<>>
      })

    {[], state}
  end

  @impl true
  def handle_stream_format(:input, _stream_format, _ctx, state) do
    stream_format = %RemoteStream{type: :packetized, content_format: RTP}
    {[stream_format: {:output, stream_format}], state}
  end

  @impl true
  def handle_buffer(:input, %Buffer{payload: payload, metadata: metadata}, _ctx, state) do
    packets_binary = state.incomplete_packet_binary <> payload

    {incomplete_packet_binary, complete_packets_binaries} =
      get_complete_packets_binaries(packets_binary, state.rtp_channel_id)

    packets_buffers =
      Enum.map(complete_packets_binaries, &%Buffer{payload: &1, metadata: metadata})

    {[buffer: {:output, packets_buffers}],
     %{state | incomplete_packet_binary: incomplete_packet_binary}}
  end

  @spec get_complete_packets_binaries(binary(), non_neg_integer()) ::
          {incomplete_packet_binary :: binary(), complete_packets_binaries :: [binary()]}
  defp get_complete_packets_binaries(packets_binary, channel_id, complete_packets_binaries \\ [])

  defp get_complete_packets_binaries(packets_binary, _channel_id, complete_packets_binaries)
       when byte_size(packets_binary) <= 4 do
    {packets_binary, Enum.reverse(complete_packets_binaries)}
  end

  defp get_complete_packets_binaries(
         <<"$", _rest::binary>> = packets_binary,
         channel_id,
         complete_packets_binaries
       ) do
    <<"$", received_channel_id, payload_length::size(16), rest::binary>> = packets_binary

    if payload_length > byte_size(rest) do
      {packets_binary, Enum.reverse(complete_packets_binaries)}
    else
      <<complete_packet_binary::binary-size(payload_length)-unit(8), rest::binary>> = rest

      complete_packets_binaries =
        if channel_id != received_channel_id,
          do: complete_packets_binaries,
          else: [complete_packet_binary | complete_packets_binaries]

      get_complete_packets_binaries(rest, channel_id, complete_packets_binaries)
    end
  end

  defp get_complete_packets_binaries(
         <<"RTSP", _rest::binary>>,
         _channel_id,
         _complete_packets_binaries
       ) do
    {<<>>, []}
  end
end
