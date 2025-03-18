defmodule Membrane.RTP.Demuxer do
  @moduledoc """
  Element capable of receiving a raw RTP stream and demuxing it into individual parsed streams based on packet ssrcs.

  Output pads can be linked either before or after a corresponding stream has been recognized. In the first case the demuxer will 
  start sending buffers on the pad once a stream with payload type or SSRC matching the identification provided via the pad's options
  is recognized. In the second case, whenever a new stream is recognized and no waiting pad has matching identification, a 
  `t:new_rtp_stream_notification/0` is sent to the element's parent. In turn it should link an output pad of this element, passing
  the SSRC received in the notification as an option, to receive the stream.
  """

  use Membrane.Filter
  require Membrane.Pad

  require Membrane.Logger
  alias Membrane.Element.CallbackContext
  alias Membrane.{Pad, RemoteStream, RTCP, RTP}
  alias Membrane.RTP.Demuxer.JitterBuffer

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
          {:new_rtp_stream,
           %{
             ssrc: RTP.ssrc(),
             payload_type: RTP.payload_type(),
             extensions: [ExRTP.Packet.Extension.t()]
           }}

  @type stream_id ::
          {:ssrc, RTP.ssrc()}
          | {:encoding_name, RTP.encoding_name()}
          | {:payload_type, RTP.payload_type()}

  @type stream_phase :: :waiting_for_matching_pad | :matched_with_pad | :timed_out

  def_input_pad :input,
    accepted_format:
      %RemoteStream{type: :packetized, content_format: cf} when cf in [RTP, RTCP, nil]

  def_output_pad :output,
    accepted_format: RTP,
    availability: :on_request,
    options: [
      stream_id: [
        spec: stream_id(),
        description: """
        Specifies what stream will be sent on this pad. If ssrc of the stream is known (for example from `t:new_rtp_stream_notification/0`),
        then most likely it should be used, since it's unique for each stream. If it's not known (for example when the pad is being linked upfront),
        encoding or payload type should be provided, and the first identified stream of given encoding or payload type will be sent on this pad.
        """
      ],
      clock_rate: [
        spec: RTP.clock_rate() | nil,
        default: nil,
        description: """
        Clock rate of the stream. If not provided the demuxer will attempt to resolve it from payload type.
        """
      ],
      use_jitter_buffer: [
        spec: boolean(),
        default: true,
        description: """
        Specifies whether to use an internal jitter buffer or not. The jitter buffer ensures that incoming packets are reordered based on their sequence
        numbers. This functionality introduces some latency, so when the order of the packets is ensured by some other means the jitter buffer is redundant.
        """
      ],
      jitter_buffer_latency: [
        spec: Membrane.Time.t(),
        default: Membrane.Time.milliseconds(200),
        description: """
        Maximum latency introduced by the jitter buffer. Determines how long the element will wait for out-of-order packets if there are any gaps in sequence numbers.
        """
      ]
    ]

  def_options payload_type_mapping: [
                spec: RTP.PayloadFormat.payload_type_mapping(),
                default: %{},
                description: "Mapping of the custom RTP payload types ( > 95)."
              ],
              not_linked_pad_handling: [
                spec: %{action: :raise | :ignore | :warn, timeout: Membrane.Time.t()},
                default: %{action: :warn, timeout: Membrane.Time.seconds(2)},
                description: """
                This option determines the action to be taken after a stream has been announced with a 
                `t:new_rtp_stream_notification/0` notification but the corresponding pad has not been connected within the specified timeout period.
                """
              ]

  defmodule State do
    @moduledoc false
    alias Membrane.RTP

    defmodule StreamState do
      @moduledoc false
      alias Membrane.RTP
      alias Membrane.RTP.Demuxer.JitterBuffer

      @type t :: %__MODULE__{
              end_of_stream_buffered: boolean(),
              phase: RTP.Demuxer.stream_phase(),
              pad_match_timer: reference() | nil,
              payload_type: RTP.payload_type(),
              pad: Pad.ref() | nil,
              jitter_buffer_state: JitterBuffer.State.t()
            }

      @enforce_keys [:payload_type, :phase, :pad_match_timer, :pad, :jitter_buffer_state]
      defstruct @enforce_keys ++ [end_of_stream_buffered: false]
    end

    @type t :: %__MODULE__{
            payload_type_mapping: RTP.PayloadFormat.payload_type_mapping(),
            not_linked_pad_handling: %{action: :raise | :ignore, timeout: Membrane.Time.t()},
            stream_states: %{RTP.ssrc() => StreamState.t()},
            pads_waiting_for_stream: %{Pad.ref() => Membrane.RTP.Demuxer.stream_id()}
          }

    @enforce_keys [:not_linked_pad_handling, :payload_type_mapping]
    defstruct @enforce_keys ++ [stream_states: %{}, pads_waiting_for_stream: %{}]
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
  def handle_buffer(:input, %Membrane.Buffer{payload: payload}, ctx, state) do
    case classify_packet(payload) do
      :rtp -> handle_rtp_packet(payload, ctx, state)
      :rtcp -> handle_rtcp_packets(payload, state)
    end
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, _ref) = pad, ctx, state) do
    matching_stream_ssrc =
      find_matching_stream_for_pad(
        ctx.pad_options.stream_id,
        state.stream_states,
        state.payload_type_mapping
      )

    case state.stream_states[matching_stream_ssrc] do
      nil ->
        state = put_in(state.pads_waiting_for_stream[pad], ctx.pad_options.stream_id)
        {[], state}

      %{phase: :timed_out} ->
        Membrane.Logger.warning(
          "Connected a pad corresponding to a timed out stream, sending end_of_stream"
        )

        {[stream_format: {pad, %RTP{}}, end_of_stream: pad], state}

      %{phase: :waiting_for_matching_pad} = stream_state ->
        Process.cancel_timer(stream_state.pad_match_timer)

        {buffer_actions, jitter_buffer_state} =
          stream_state.jitter_buffer_state
          |> JitterBuffer.complete_state_initialization_with_pad_options(
            ctx.pad_options,
            stream_state.payload_type,
            matching_stream_ssrc,
            state.payload_type_mapping
          )
          |> JitterBuffer.get_actions(stream_state.phase, matching_stream_ssrc, pad)

        end_of_stream_actions =
          if stream_state.end_of_stream_buffered do
            JitterBuffer.get_end_of_stream_actions(jitter_buffer_state, pad)
          else
            []
          end

        stream_state = %State.StreamState{
          stream_state
          | phase: :matched_with_pad,
            pad: pad,
            jitter_buffer_state: jitter_buffer_state
        }

        state = put_in(state.stream_states[matching_stream_ssrc], stream_state)

        {[stream_format: {pad, %RTP{}}] ++ buffer_actions ++ end_of_stream_actions, state}
    end
  end

  @impl true
  def handle_info({:pad_match_timeout, ssrc}, _ctx, state) do
    case state.not_linked_pad_handling.action do
      :raise ->
        raise "Pad corresponding to ssrc #{ssrc} not connected within specified timeout"

      :warn ->
        Membrane.Logger.warning(
          "Pad corresponding to ssrc #{ssrc} not connected within specified timeout"
        )

      :ignore ->
        :ok
    end

    state = put_in(state.stream_states[ssrc].phase, :timed_out)
    {[], state}
  end

  @impl true
  def handle_info({:initial_latency_passed, ssrc}, _context, state) do
    stream_state = state.stream_states[ssrc]

    {actions, jitter_buffer_state} =
      stream_state.jitter_buffer_state
      |> JitterBuffer.get_actions(stream_state.phase, ssrc, stream_state.pad)

    state =
      put_in(
        state.stream_states[ssrc].jitter_buffer_state,
        %JitterBuffer.State{jitter_buffer_state | initial_latency_waiting: false}
      )

    {actions, state}
  end

  @impl true
  def handle_info({:get_actions, ssrc}, _context, state) do
    stream_state = state.stream_states[ssrc]

    {actions, jitter_buffer_state} =
      stream_state.jitter_buffer_state
      |> JitterBuffer.get_actions(stream_state.phase, ssrc, stream_state.pad)

    state =
      put_in(
        state.stream_states[ssrc].jitter_buffer_state,
        %JitterBuffer.State{jitter_buffer_state | max_latency_timer: nil}
      )

    {actions, state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    state.stream_states
    |> Enum.flat_map_reduce(state, fn {ssrc, stream_state}, state ->
      actions =
        JitterBuffer.get_end_of_stream_actions(stream_state.jitter_buffer_state, stream_state.pad)

      state = put_in(state.stream_states[ssrc].end_of_stream_buffered, true)

      {actions, state}
    end)
  end

  @spec classify_packet(binary()) :: :rtp | :rtcp
  defp classify_packet(<<_first_byte, _marker::1, payload_type::7, _rest::binary>>) do
    if payload_type in 64..95,
      do: :rtcp,
      else: :rtp
  end

  @spec handle_rtp_packet(binary(), CallbackContext.t(), State.t()) ::
          {[Membrane.Element.Action.t()], State.t()}
  defp handle_rtp_packet(raw_rtp_packet, ctx, state) do
    {:ok, packet} = ExRTP.Packet.decode(raw_rtp_packet)

    {new_stream_actions, state} =
      if Map.has_key?(state.stream_states, packet.ssrc) do
        {[], state}
      else
        find_matching_pad_for_stream(
          packet,
          state.pads_waiting_for_stream,
          state.payload_type_mapping
        )
        |> initialize_new_stream_state(packet, ctx, state)
      end

    stream_state = state.stream_states[packet.ssrc]

    buffer = %Membrane.Buffer{
      payload: packet.payload,
      metadata: %{rtp: %{packet | payload: <<>>}}
    }

    {buffer_actions, jitter_buffer_state} =
      stream_state.jitter_buffer_state
      |> JitterBuffer.insert_buffer(buffer, stream_state.phase)
      |> JitterBuffer.get_actions(stream_state.phase, packet.ssrc, stream_state.pad)

    state = put_in(state.stream_states[packet.ssrc].jitter_buffer_state, jitter_buffer_state)

    {new_stream_actions ++ buffer_actions, state}
  end

  @spec handle_rtcp_packets(binary(), State.t()) :: {[Membrane.Element.Action.t()], State.t()}
  defp handle_rtcp_packets(rtcp_packets, state) do
    Membrane.Logger.debug_verbose("Received RTCP Packet(s): #{inspect(rtcp_packets)}")
    {[], state}
  end

  @spec initialize_new_stream_state(
          matching_pad :: Pad.ref() | nil,
          ExRTP.Packet.t(),
          CallbackContext.t(),
          State.t()
        ) :: {[Membrane.Element.Action.t()], State.t()}
  defp initialize_new_stream_state(nil, packet, _ctx, state) do
    jitter_buffer_state =
      JitterBuffer.initialize_state_with_new_rtp_stream(packet, nil, state.payload_type_mapping)

    stream_state = %State.StreamState{
      phase: :waiting_for_matching_pad,
      pad: nil,
      pad_match_timer:
        Process.send_after(
          self(),
          {:pad_match_timeout, packet.ssrc},
          Membrane.Time.as_milliseconds(state.not_linked_pad_handling.timeout, :round)
        ),
      payload_type: packet.payload_type,
      jitter_buffer_state: jitter_buffer_state
    }

    state = put_in(state.stream_states[packet.ssrc], stream_state)

    {[notify_parent: create_new_stream_notification(packet)], state}
  end

  defp initialize_new_stream_state(pad_waiting_for_stream, packet, ctx, state) do
    jitter_buffer_state =
      JitterBuffer.initialize_state_with_new_rtp_stream(
        packet,
        ctx.pads[pad_waiting_for_stream].options,
        state.payload_type_mapping
      )

    stream_state = %State.StreamState{
      phase: :matched_with_pad,
      pad: pad_waiting_for_stream,
      pad_match_timer: nil,
      payload_type: packet.payload_type,
      jitter_buffer_state: jitter_buffer_state
    }

    state = put_in(state.stream_states[packet.ssrc], stream_state)
    {_stream_id, state} = pop_in(state.pads_waiting_for_stream[pad_waiting_for_stream])

    {[stream_format: {pad_waiting_for_stream, %RTP{}}], state}
  end

  @spec find_matching_pad_for_stream(
          ExRTP.Packet.t(),
          %{Pad.ref() => stream_id()},
          RTP.PayloadFormat.payload_type_mapping()
        ) :: Pad.ref() | nil
  defp find_matching_pad_for_stream(packet, pads_waiting_for_stream, payload_type_mapping) do
    Enum.find(pads_waiting_for_stream, fn {_pad_ref, stream_id} ->
      pad_stream_match?(stream_id, packet.ssrc, packet.payload_type, payload_type_mapping)
    end)
    |> case do
      nil -> nil
      {pad_ref, _stream_id} -> pad_ref
    end
  end

  @spec find_matching_stream_for_pad(
          stream_id(),
          %{RTP.ssrc() => State.StreamState.t()},
          RTP.PayloadFormat.payload_type_mapping()
        ) :: RTP.ssrc() | nil
  defp find_matching_stream_for_pad(stream_id, stream_states, payload_type_mapping) do
    Enum.find(stream_states, fn {ssrc, stream_state} ->
      pad_stream_match?(stream_id, ssrc, stream_state.payload_type, payload_type_mapping)
    end)
    |> case do
      nil -> nil
      {ssrc, _stream_state} -> ssrc
    end
  end

  @spec pad_stream_match?(
          stream_id(),
          RTP.ssrc(),
          RTP.payload_type(),
          RTP.PayloadFormat.payload_type_mapping()
        ) :: boolean()
  defp pad_stream_match?(
         pad_options_stream_id,
         stream_ssrc,
         stream_payload_type,
         payload_type_mapping
       ) do
    case pad_options_stream_id do
      {:ssrc, pad_ssrc} ->
        stream_ssrc == pad_ssrc

      {:payload_type, pad_payload_type} ->
        stream_payload_type == pad_payload_type

      {:encoding_name, pad_encoding_name} ->
        %{payload_type: pad_payload_type} =
          RTP.PayloadFormat.resolve(
            encoding_name: pad_encoding_name,
            payload_type_mapping: payload_type_mapping
          )

        stream_payload_type == pad_payload_type
    end
  end

  @spec create_new_stream_notification(ExRTP.Packet.t()) :: new_rtp_stream_notification()
  defp create_new_stream_notification(packet) do
    extensions =
      case packet.extensions do
        nil ->
          []

        extension when is_binary(extension) ->
          [ExRTP.Packet.Extension.new(packet.extension_profile, extension)]

        extensions when is_list(extensions) ->
          extensions
      end

    {:new_rtp_stream,
     %{ssrc: packet.ssrc, payload_type: packet.payload_type, extensions: extensions}}
  end
end
