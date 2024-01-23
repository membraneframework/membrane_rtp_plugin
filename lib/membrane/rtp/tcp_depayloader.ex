defmodule Membrane.RTP.TCP.Depayloader do
  @moduledoc """
  This element provides functionality of depayloading RTP Packets received by TCP and redirecting
  RTSP messages received in the same stream. The encapsulation is described in RFC 7826 Section 14.

  Encapsulated packets interleaved in the stream will have the following structure:
  ["$" = 36 :: 1 byte][Channel id :: 1 byte][Length :: 2 bytes][packet :: <Length> bytes]

  RTSP Messages
  """
  use Membrane.Filter

  alias Membrane.{Buffer, RemoteStream, RTP, RTSP}

  def_options rtp_channel_id: [
                spec: non_neg_integer(),
                default: 0,
                description: """
                Channel identifier which encapsulated RTP packets will have.
                """
              ],
              rtsp_session: [
                spec: pid() | nil,
                default: nil,
                description: """
                PID of a RTSP Session (returned from Membrane.RTSP.start or Membrane.RTSP.start_link)
                that received RTSP responses will be forwarded to. If nil the responses will be
                discarded.
                """
              ]

  def_input_pad :input, accepted_format: %RemoteStream{type: :bytestream}

  def_output_pad :output, accepted_format: %RemoteStream{type: :packetized, content_format: RTP}

  @impl true
  def handle_init(_ctx, opts) do
    state =
      Map.from_struct(opts)
      |> Map.merge(%{
        unprocessed_data: <<>>
      })

    {[], state}
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
    unprocessed_data =
      if rtsp_response?(state.unprocessed_data, payload) do
        if state.rtsp_session != nil do
          {:ok, %RTSP.Response{status: 200}} =
            RTSP.handle_response(state.rtsp_session, state.unprocessed_data)
        end

        <<>>
      else
        state.unprocessed_data
      end

    packets_binary = unprocessed_data <> payload

    {unprocessed_data, complete_packets_binaries} =
      get_complete_packets(packets_binary, state.rtp_channel_id)

    packets_buffers =
      Enum.map(complete_packets_binaries, &%Buffer{payload: &1, metadata: metadata})

    {[buffer: {:output, packets_buffers}], %{state | unprocessed_data: unprocessed_data}}
  end

  @spec rtsp_response?(binary(), binary()) :: boolean()
  defp rtsp_response?(maybe_rtsp_response, new_payload) do
    String.starts_with?(new_payload, "$") and String.starts_with?(maybe_rtsp_response, "RTSP")
  end

  @spec get_complete_packets(binary(), non_neg_integer()) ::
          {unprocessed_data :: binary(), complete_packets :: [binary()]}
  defp get_complete_packets(packets_binary, channel_id, complete_packets \\ [])

  defp get_complete_packets(packets_binary, _channel_id, complete_packets)
       when byte_size(packets_binary) <= 4 do
    {packets_binary, Enum.reverse(complete_packets)}
  end

  defp get_complete_packets(
         <<"$", _rest::binary>> = packets_binary,
         channel_id,
         complete_packets
       ) do
    <<"$", received_channel_id, payload_length::size(16), rest::binary>> = packets_binary

    if payload_length > byte_size(rest) do
      {packets_binary, Enum.reverse(complete_packets)}
    else
      <<complete_packet_binary::binary-size(payload_length)-unit(8), rest::binary>> = rest

      complete_packets =
        if channel_id != received_channel_id,
          do: complete_packets,
          else: [complete_packet_binary | complete_packets]

      get_complete_packets(rest, channel_id, complete_packets)
    end
  end

  defp get_complete_packets(rtsp_message, _channel_id, _complete_packets_binaries) do
    # If the payload doesn't start with a "$" then it must be a RTSP message (or a part of it)
    {rtsp_message, []}
  end
end
