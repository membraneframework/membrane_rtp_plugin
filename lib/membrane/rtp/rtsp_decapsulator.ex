defmodule Membrane.RTP.RTSP.Decapsulator do
  @moduledoc """
  This element provides functionality of decapsulating RTP Packets and redirecting RTSP messages
  received in the same TCP stream established with RTSP. The encapsulation is described in
  RFC 7826 Section 14.

  Encapsulated RTP packets interleaved in the stream will have the following structure:
  ["$" = 36 :: 1 byte][Channel id :: 1 byte][Length :: 2 bytes][packet :: <Length> bytes]

  RTSP Messages are not encapsulated this way, but can only be present between RTP packets.
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
    packets_binary = state.unprocessed_data <> payload

    {unprocessed_data, complete_packets_binaries} =
      get_complete_packets(packets_binary, state.rtp_channel_id, state.rtsp_session)

    packets_buffers =
      Enum.map(complete_packets_binaries, &%Buffer{payload: &1, metadata: metadata})

    {[buffer: {:output, packets_buffers}], %{state | unprocessed_data: unprocessed_data}}
  end

  @spec rtsp_response?(binary(), binary()) :: boolean()
  defp rtsp_response?(maybe_rtsp_response, new_payload) do
    String.starts_with?(new_payload, "$") and String.starts_with?(maybe_rtsp_response, "RTSP")
  end

  @spec get_complete_packets(binary(), non_neg_integer(), pid() | nil, [binary()]) ::
          {unprocessed_data :: binary(), complete_packets :: [binary()]}
  defp get_complete_packets(packets_binary, channel_id, rtsp_session, complete_packets \\ [])

  defp get_complete_packets(packets_binary, _channel_id, _rtsp_session, complete_packets)
       when byte_size(packets_binary) <= 4 do
    {packets_binary, Enum.reverse(complete_packets)}
  end

  defp get_complete_packets(
         <<"$", received_channel_id, payload_length::size(16), rest::binary>> = packets_binary,
         channel_id,
         _rtsp_session,
         complete_packets
       ) do
    case rest do
      <<complete_packet_binary::binary-size(payload_length)-unit(8), rest::binary>> ->
        complete_packets =
          if received_channel_id in [channel_id, channel_id + 1],
            do: [complete_packet_binary | complete_packets],
            else: complete_packets

        get_complete_packets(rest, channel_id, complete_packets)

      _incomplete_packet_binary ->
        {packets_binary, Enum.reverse(complete_packets)}
    end
  end

  defp get_complete_packets(
         <<"RTSP", _rest::binary>> = rtsp_message_start,
         channel_id,
         rtsp_session,
         complete_packets_binaries
       ) do
    case RTSP.Response.verify_content_length(rtsp_message_start) do
      {:ok, _expected_length, _actual_length} ->
        if rtsp_session != nil do
          {:ok, %RTSP.Response{status: 200}} =
            RTSP.handle_response(rtsp_session, rtsp_message_start)
        end

        {<<>>, complete_packets_binaries}

      {:error, expected_length, actual_length} when actual_length > expected_length ->
        rest_length = actual_length - expected_length
        rtsp_message_length = byte_size(rtsp_message_start) - rest_length

        <<rtsp_message::binary-size(rtsp_message_length)-unit(8), rest::binary>> =
          rtsp_message_start

        if rtsp_session != nil do
          {:ok, %RTSP.Response{status: 200}} = RTSP.handle_response(rtsp_session, rtsp_message)
        end

        get_complete_packets(rest, channel_id, rtsp_session, complete_packets_binaries)

      {:error, expected_length, actual_length} when actual_length <= expected_length ->
        {rtsp_message_start, Enum.reverse(complete_packets_binaries)}
    end
  end
end
