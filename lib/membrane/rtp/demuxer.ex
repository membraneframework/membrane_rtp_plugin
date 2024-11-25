defmodule Membrane.RTP.Demuxer do
  @moduledoc """
  Element capable of receiving a raw RTP stream and demuxing it into individual parsed streams based on packet ssrcs. 
  Whenever a new is recognized, a `new_rtp_stream_notification` is sent to the element's parent. In turn it should link a 
  `Membrane.Pad.ref({:output, ssrc})` output pad of this element to receive the stream specified in the notification.
  """

  use Membrane.Filter
  require Membrane.Pad

  alias Membrane.Element.Action
  alias Membrane.{Pad, RemoteStream, RTCP, RTP}

  def_input_pad :input,
    accepted_format:
      %RemoteStream{type: :packetized, content_format: cf} when cf in [RTP, RTCP, nil]

  def_output_pad :output, accepted_format: RTP, availability: :on_request

  @typedoc """
  Metadata present in each output buffer. The `ExRTP.Packet.t()` struct contains parsed fields of the packet
  present in the buffer. The `payload` field of this struct will be set to `<<>>`, and the payload will
  be present in `payload` field of the buffer.
  """
  @type output_metadata :: %{rtp: ExRTP.Packet.t()}

  @typedoc """
  Notification sent by this element to it's parent when a new stream is received. Receiving a packet 
  with previously unseen ssrc is treated as receiving a new stream.
  """
  @type new_rtp_stream_notification ::
          {:new_rtp_stream, ssrc :: ExRTP.Packet.uint32(), payload_type :: ExRTP.Packet.uint7(),
           extensions :: [ExRTP.Packet.Extension.t()]}

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            stream_states: %{
              RTP.ssrc_t() => %{
                buffered_actions: [Action.buffer() | Action.end_of_stream()],
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
    buffered_actions = state.stream_states[ssrc].buffered_actions

    state =
      Bunch.Struct.update_in(
        state,
        [:stream_states, ssrc],
        &%{&1 | phase: :linked, buffered_actions: []}
      )

    {[stream_format: {pad, %RTP{}}] ++ Enum.reverse(buffered_actions), state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    state =
      state.stream_states
      |> Enum.reduce(state, fn {ssrc, _stream_state}, state ->
        append_action_to_buffered_actions(ssrc, {:end_of_stream, Pad.ref(:output, ssrc)}, state)
      end)

    {[forward: :end_of_stream], state}
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
          {[],
           append_action_to_buffered_actions(
             packet.ssrc,
             {:buffer, {Pad.ref(:output, packet.ssrc), put_packet_into_buffer(packet)}},
             state
           )}

        :linked ->
          {[buffer: {Pad.ref(:output, packet.ssrc), put_packet_into_buffer(packet)}], state}
      end

    {new_stream_actions ++ buffer_actions, state}
  end

  @spec handle_rtcp_packets(binary(), State.t()) :: {[Membrane.Element.Action.t()], State.t()}
  defp handle_rtcp_packets(_rtcp_packets, state) do
    {[], state}
  end

  @spec initialize_new_stream_state(ExRTP.Packet.t(), State.t()) ::
          {[Membrane.Element.Action.t()], State.t()}
  defp initialize_new_stream_state(packet, state) do
    stream_state = %{buffered_actions: [], phase: :waiting_for_link}

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

  @spec append_action_to_buffered_actions(
          ExRTP.Packet.uint32(),
          Action.buffer() | Action.end_of_stream(),
          State.t()
        ) :: State.t()
  defp append_action_to_buffered_actions(ssrc, action, state) do
    Bunch.Struct.update_in(state, [:stream_states, ssrc, :buffered_actions], &[action | &1])
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
