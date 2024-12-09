defmodule Membrane.RTP.Demuxer do
  @moduledoc """
  Element capable of receiving a raw RTP stream and demuxing it into individual parsed streams based on packet ssrcs. 
  Whenever a new stream is recognized, a `t:new_rtp_stream_notification/0` is sent to the element's parent. In turn it should link a 
  `Membrane.Pad.ref({:output, ssrc})` output pad of this element to receive the stream specified in the notification.
  """

  use Membrane.Filter
  require Membrane.Pad

  require Membrane.Logger
  alias Membrane.Element.Action
  alias Membrane.{Pad, RemoteStream, RTCP, RTP}

  def_input_pad :input,
    accepted_format:
      %RemoteStream{type: :packetized, content_format: cf} when cf in [RTP, RTCP, nil]

  def_output_pad :output, accepted_format: RTP, availability: :on_request

  def_options not_linked_pad_handling: [
                spec: %{action: :raise | :ignore, timeout: Membrane.Time.t()},
                default: %{action: :ignore, timeout: Membrane.Time.seconds(2)},
                description: """
                This option determines the action to be taken after a stream has been announced with a 
                `t:new_rtp_stream_notification/0` notification but the corresponding pad has not been connected within the specified timeout period.
                """
              ]

  @typedoc """
  Metadata present in each output buffer. The `ExRTP.Packet.t()` struct contains 
  parsed fields of the packet's header. The `payload` field of this struct will 
  be set to `<<>>`, and the payload will be present in `payload` field of the buffer.
  """
  @type output_metadata :: %{rtp: ExRTP.Packet.t()}

  @typedoc """
  Notification sent by this element to it's parent when a new stream is received. Receiving a packet 
  with previously unseen ssrc is treated as receiving a new stream.
  """
  @type new_rtp_stream_notification ::
          {:new_rtp_stream, ssrc :: RTP.ssrc(), payload_type :: RTP.payload_type(),
           extensions :: [ExRTP.Packet.Extension.t()]}

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            not_linked_pad_handling: %{
              action: :raise | :ignore,
              timeout: Membrane.Time.t()
            },
            stream_states: %{
              RTP.ssrc() => %{
                buffered_actions: [Action.buffer() | Action.end_of_stream()],
                phase: :waiting_for_link | :linked | :timed_out,
                link_timer: reference()
              }
            }
          }

    @enforce_keys [:not_linked_pad_handling]
    defstruct @enforce_keys ++ [stream_states: %{}]
  end

  @impl true
  def handle_init(_ctx, opts) do
    {[], struct(State, Map.from_struct(opts))}
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
    stream_state = state.stream_states[ssrc]

    case stream_state.phase do
      :waiting_for_link ->
        state =
          Bunch.Struct.put_in(
            state,
            [:stream_states, ssrc],
            %{stream_state | phase: :linked, buffered_actions: []}
          )

        {[stream_format: {pad, %RTP{}}] ++ Enum.reverse(stream_state.buffered_actions), state}

      :timed_out ->
        Membrane.Logger.warning(
          "Connected a pad corresponding to a timed out stream, sending end_of_stream"
        )

        {[end_of_stream: pad], state}
    end
  end

  @impl true
  def handle_info({:link_timeout, ssrc}, _ctx, state) do
    case state.not_linked_pad_handling.action do
      :raise ->
        raise "Pad corresponding to ssrc #{ssrc} not connected within specified timeout"

      :ignore ->
        Membrane.Logger.warning(
          "Pad corresponding to ssrc #{ssrc} not connected within specified timeout"
        )

        state =
          state
          |> Bunch.Struct.put_in([:stream_states, ssrc, :phase], :timed_out)
          |> Bunch.Struct.put_in([:stream_states, ssrc, :buffered_actions], [])

        {[], state}
    end
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

    buffer_action =
      {:buffer, {Pad.ref(:output, packet.ssrc), put_packet_into_buffer(packet)}}

    {buffer_actions, state} =
      case state.stream_states[packet.ssrc].phase do
        :waiting_for_link ->
          Process.cancel_timer(state.stream_states[packet.ssrc].link_timer)
          {[], append_action_to_buffered_actions(packet.ssrc, buffer_action, state)}

        :linked ->
          {[buffer_action], state}

        :timed_out ->
          {[], state}
      end

    {new_stream_actions ++ buffer_actions, state}
  end

  @spec handle_rtcp_packets(binary(), State.t()) :: {[Membrane.Element.Action.t()], State.t()}
  defp handle_rtcp_packets(rtcp_packets, state) do
    Membrane.Logger.debug_verbose("Received RTCP Packet(s): #{inspect(rtcp_packets)}")
    {[], state}
  end

  @spec initialize_new_stream_state(ExRTP.Packet.t(), State.t()) ::
          {[Membrane.Element.Action.t()], State.t()}
  defp initialize_new_stream_state(packet, state) do
    stream_state = %{
      buffered_actions: [],
      phase: :waiting_for_link,
      link_timer:
        Process.send_after(
          self(),
          {:link_timeout, packet.ssrc},
          Membrane.Time.as_milliseconds(state.not_linked_pad_handling.timeout, :round)
        )
    }

    extensions =
      case packet.extensions do
        nil ->
          []

        extension when is_binary(extension) ->
          [ExRTP.Packet.Extension.new(packet.extension_profile, extension)]

        extensions when is_list(extensions) ->
          extensions
      end

    state = Bunch.Struct.put_in(state, [:stream_states, packet.ssrc], stream_state)
    {[notify_parent: {:new_rtp_stream, packet.ssrc, packet.payload_type, extensions}], state}
  end

  @spec append_action_to_buffered_actions(
          RTP.ssrc(),
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
