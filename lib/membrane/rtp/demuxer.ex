defmodule Membrane.RTP.Demuxer do
  use Membrane.Filter
  alias Hex.State
  alias Hex.State
  alias Membrane.{RemoteStream, RTP, RTCP}

  def_input_pad :input,
    accepted_format:
      %RemoteStream{type: :packetized, content_format: cf} when cf in [RTP, RTCP, nil]

  def_output_pad :output, accepted_format: _any, availability: :on_request

  @type output_metadata :: %{rtp: ExRTP.Packet.t()}

  defmodule State do
    @type t :: %__MODULE__{
            stream_states: %{
              RTP.ssrc_t() => %{
                waiting_packets: [ExRTP.Packet.t()],
                phase: :waiting_for_link | :linked
              }
            }
          }

    @enforce_keys []
    defstruct @enforce_keys ++ [stream_states: %{}]
  end

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %State{}}
  end

  @impl true
  def handle_stream_format(_pad, _stream_format, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_buffer(:input, %Membrane.Buffer{payload: payload}, _ctx, state) do
    case classify_packet(payload) do
      :rtp -> handle_rtp_packet(payload, state)
      :rtcp -> handle_rtcp_packets(payload, state)
    end
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, ssrc) = pad, _ctx, state) do
    waiting_buffers =
      state.stream_states[ssrc].waiting_packets
      |> Enum.reverse()
      |> Enum.map(&put_packet_into_buffer/1)

    state =
      Bunch.Struct.update_in(
        state,
        [:stream_states, ssrc],
        &%{&1 | phase: :linked, waiting_packets: []}
      )

    {[stream_format: {pad, %RTP{}}, buffer: {pad, waiting_buffers}], state}
  end

  @spec classify_packet(binary()) :: :rtp | :rtcp
  defp classify_packet(<<_first_byte, _marker::1, payload_type::7, _rest::binary>>) do
    if payload_type in 64..95,
      do: :rtcp,
      else: :rtp
  end

  @spec handle_rtp_packet(binary(), State.t()) :: {[Membrane.Element.Action.t()], State.t()}
  defp handle_rtp_packet(raw_rtp_packet, state) do
    {:ok, packet} = ExRTP.Packet.decode(raw_rtp_packet)

    {new_stream_actions, state} =
      if Map.has_key?(state.stream_states, packet.ssrc) do
        {[], state}
      else
        initialize_new_stream_state(packet, state)
      end

    {buffer_actions, state} =
      case state.stream_states[packet.ssrc].phase do
        :waiting_for_link ->
          {[], append_packet_to_waiting_packets(packet, state)}

        :linked ->
          {[buffer: {Pad.ref(:output, packet.ssrc), put_packet_into_buffer(packet)}], state}
      end

    {new_stream_actions ++ buffer_actions, state}
  end

  @spec handle_rtcp_packets(binary(), State.t()) :: {[Membrane.Element.Action.t()], State.t()}
  defp handle_rtcp_packets(rtcp_packets, state) do
    {[], state}
  end

  @spec initialize_new_stream_state(ExRTP.Packet.t(), State.t()) ::
          {[Membrane.Element.Action.t()], State.t()}
  defp initialize_new_stream_state(packet, state) do
    stream_state = %{waiting_packets: [], phase: :waiting_for_link}

    extensions =
      case packet.extensions do
        nil ->
          []

        extension when is_binary(extension) ->
          [ExRTP.Packet.Extension.new(packet.extension_profile, extension)]

        extensions ->
          extensions
      end

    state = Bunch.Struct.put_in(state, [:stream_states, packet.ssrc], stream_state)
    {[notify_parent: {:new_rtp_stream, packet.ssrc, packet.payload_type, extensions}], state}
  end

  @spec append_packet_to_waiting_packets(ExRTP.Packet.t(), State.t()) :: State.t()
  defp append_packet_to_waiting_packets(packet, state) do
    Bunch.Struct.update_in(state, [:stream_states, packet.ssrc, :waiting_packets], &[packet | &1])
  end

  @spec put_packet_into_buffer(ExRTP.Packet.t()) :: Membrane.Buffer.t()
  defp put_packet_into_buffer(packet) do
    %Membrane.Buffer{
      payload: packet.payload,
      pts: packet.timestamp,
      metadata: %{rtp: %{packet | payload: <<>>}}
    }
  end
end
