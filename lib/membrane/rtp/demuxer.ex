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
  alias Membrane.{Pad, RemoteStream, RTCP, RTP, Time}
  alias Membrane.RTP.JitterBuffer.{BufferStore, Record}

  @max_timestamp Bitwise.bsl(1, 32) - 1

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
        default: nil
      ],
      use_jitter_buffer: [
        spec: boolean(),
        default: true
      ],
      jitter_buffer_latency: [
        spec: Membrane.Time.t(),
        default: Membrane.Time.milliseconds(200)
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

      @type t :: %__MODULE__{
              buffer_store: RTP.JitterBuffer.BufferStore.t(),
              end_of_stream_buffered: boolean(),
              phase: :waiting_for_link | :linked | :timed_out,
              payload_type: RTP.payload_type(),
              link_timer: reference() | nil,
              pad: Pad.ref() | nil,
              use_jitter_buffer: boolean() | nil,
              clock_rate: non_neg_integer() | nil,
              jitter_buffer_latency: Membrane.Time.t() | nil,
              initial_latency_waiting: boolean(),
              initialization_time: Membrane.Time.t(),
              max_latency_timer: reference() | nil,
              timestamp_base: Membrane.Time.t(),
              previous_timestamp: Membrane.Time.t()
            }

      @enforce_keys [
        :payload_type,
        :phase,
        :link_timer,
        :pad,
        :timestamp_base,
        :previous_timestamp,
        :initialization_time
      ]

      defstruct @enforce_keys ++
                  [
                    buffer_store: %RTP.JitterBuffer.BufferStore{},
                    end_of_stream_buffered: false,
                    initial_latency_waiting: true,
                    max_latency_timer: nil,
                    clock_rate: nil,
                    jitter_buffer_latency: nil,
                    use_jitter_buffer: nil
                  ]
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

    stream_state = state.stream_states[matching_stream_ssrc]

    case stream_state do
      nil ->
        state = put_in(state.pads_waiting_for_stream[pad], ctx.pad_options.stream_id)
        {[], state}

      %{phase: :waiting_for_link} ->
        Process.cancel_timer(stream_state.link_timer)

        %{clock_rate: clock_rate} =
          RTP.PayloadFormat.resolve(
            payload_type: stream_state.payload_type,
            clock_rate: ctx.pad_options.clock_rate,
            payload_type_mapping: state.payload_type_mapping
          )

        stream_state = %State.StreamState{
          stream_state
          | clock_rate: clock_rate,
            jitter_buffer_latency: ctx.pad_options.jitter_buffer_latency,
            use_jitter_buffer: ctx.pad_options.use_jitter_buffer
        }

        time_since_initialization = Time.monotonic_time() - stream_state.initialization_time

        if time_since_initialization < stream_state.jitter_buffer_latency do
          initial_latency_left = stream_state.jitter_buffer_latency - time_since_initialization

          Process.send_after(
            self(),
            {:initial_latency_passed, matching_stream_ssrc},
            initial_latency_left
          )
        end

        stream_state = %State.StreamState{stream_state | phase: :linked, pad: pad}
        {buffer_actions, stream_state} = send_buffers(matching_stream_ssrc, stream_state)

        {end_of_stream_actions, stream_state} =
          if stream_state.end_of_stream_buffered do
            get_end_of_stream_actions(stream_state)
          else
            {[], stream_state}
          end

        state =
          put_in(
            state.stream_states[matching_stream_ssrc],
            %State.StreamState{stream_state | phase: :linked, pad: pad}
          )

        {[stream_format: {pad, %RTP{}}] ++ buffer_actions ++ end_of_stream_actions, state}

      %{phase: :timed_out} ->
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

      :warn ->
        Membrane.Logger.warning(
          "Pad corresponding to ssrc #{ssrc} not connected within specified timeout"
        )

      :ignore ->
        :ok
    end

    state = put_in(state.stream_states[ssrc].phase, :timed_out)
    state = put_in(state.stream_states[ssrc].buffer_store, %BufferStore{})
    {[], state}
  end

  @impl true
  def handle_info({:initial_latency_passed, ssrc}, _context, state) do
    {actions, stream_state} =
      send_buffers(ssrc, %State.StreamState{
        state.stream_states[ssrc]
        | initial_latency_waiting: false
      })

    state = put_in(state.stream_states[ssrc], stream_state)
    {actions, state}
  end

  @impl true
  def handle_info({:send_buffers, ssrc}, _context, state) do
    {actions, stream_state} =
      send_buffers(ssrc, %State.StreamState{state.stream_states[ssrc] | max_latency_timer: nil})

    state = put_in(state.stream_states[ssrc], stream_state)
    {actions, state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    state.stream_states
    |> Enum.flat_map_reduce(state, fn {ssrc, _stream_state}, state ->
      {actions, stream_state} = get_end_of_stream_actions(state.stream_states[ssrc])

      state = put_in(state.stream_states[ssrc], %{stream_state | end_of_stream_buffered: true})
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
        initialize_new_stream_state(packet, ctx, state)
      end

    buffer = %Membrane.Buffer{
      payload: packet.payload,
      metadata: %{rtp: %{packet | payload: <<>>}}
    }

    stream_state =
      state.stream_states[packet.ssrc]
      |> insert_buffer_into_buffer_store(buffer)

    {buffer_actions, stream_state} =
      maybe_send_buffers(packet.ssrc, stream_state)

    state = put_in(state.stream_states[packet.ssrc], stream_state)
    # {buffer_actions, state} =
    # case stream_state.phase do
    # :waiting_for_link ->
    # stream_state =
    # case BufferStore.insert_buffer(stream_state.buffer_store, buffer) do
    # {:ok, buffer_store} ->
    # %State.StreamState{stream_state | buffer_store: buffer_store}

    # {:error, :late_packet} ->
    # Membrane.Logger.debug("Late packet has arrived")
    # stream_state
    # end

    # state = put_in(state.stream_states[packet.ssrc], stream_state)
    # {[], state}

    # :linked ->
    # buffer_action =
    # {:buffer, {state.stream_states[packet.ssrc].pad, buffer}}

    # {[buffer_action], state}

    # :timed_out ->
    # {[], state}
    # end

    {new_stream_actions ++ buffer_actions, state}
  end

  @spec insert_buffer_into_buffer_store(State.StreamState.t(), Membrane.Buffer.t()) ::
          State.StreamState.t()
  defp insert_buffer_into_buffer_store(stream_state, buffer) do
    case stream_state.phase do
      :timed_out ->
        stream_state

      phase when phase in [:waiting_for_link, :linked] ->
        case BufferStore.insert_buffer(stream_state.buffer_store, buffer) do
          {:ok, buffer_store} ->
            %State.StreamState{stream_state | buffer_store: buffer_store}

          {:error, :late_packet} ->
            Membrane.Logger.debug("Late packet has arrived")
            stream_state
        end
    end
  end

  @spec maybe_send_buffers(RTP.ssrc(), State.StreamState.t()) ::
          {[Membrane.Element.Action.t()], State.StreamState.t()}
  defp maybe_send_buffers(ssrc, stream_state) do
    if stream_state.phase == :linked and not stream_state.initial_latency_waiting do
      send_buffers(ssrc, stream_state)
    else
      {[], stream_state}
    end
  end

  @spec get_end_of_stream_actions(State.StreamState.t()) ::
          {[Membrane.Element.Action.t()], State.StreamState.t()}
  defp get_end_of_stream_actions(%State.StreamState{pad: nil} = stream_state) do
    {[], stream_state}
  end

  defp get_end_of_stream_actions(stream_state) do
    {buffer_actions, stream_state} =
      stream_state.buffer_store
      |> BufferStore.dump()
      |> Enum.flat_map_reduce(stream_state, &record_to_actions/2)

    {buffer_actions ++ [end_of_stream: stream_state.pad], stream_state}
  end

  @spec handle_rtcp_packets(binary(), State.t()) :: {[Membrane.Element.Action.t()], State.t()}
  defp handle_rtcp_packets(rtcp_packets, state) do
    Membrane.Logger.debug_verbose("Received RTCP Packet(s): #{inspect(rtcp_packets)}")
    {[], state}
  end

  @spec initialize_new_stream_state(ExRTP.Packet.t(), CallbackContext.t(), State.t()) ::
          {[Membrane.Element.Action.t()], State.t()}
  defp initialize_new_stream_state(packet, ctx, state) do
    case find_matching_pad_for_stream(
           packet,
           state.pads_waiting_for_stream,
           state.payload_type_mapping
         ) do
      nil ->
        stream_state = %State.StreamState{
          phase: :waiting_for_link,
          link_timer:
            Process.send_after(
              self(),
              {:link_timeout, packet.ssrc},
              Membrane.Time.as_milliseconds(state.not_linked_pad_handling.timeout, :round)
            ),
          payload_type: packet.payload_type,
          pad: nil,
          timestamp_base: packet.timestamp,
          previous_timestamp: packet.timestamp,
          initialization_time: Membrane.Time.monotonic_time()
        }

        state = put_in(state.stream_states[packet.ssrc], stream_state)

        {[notify_parent: create_new_stream_notification(packet)], state}

      pad_waiting_for_stream ->
        pad_options = ctx.pads[pad_waiting_for_stream].options

        %{clock_rate: clock_rate} =
          RTP.PayloadFormat.resolve(
            payload_type: packet.payload_type,
            clock_rate: pad_options.clock_rate,
            payload_type_mapping: state.payload_type_mapping
          )

        stream_state = %State.StreamState{
          phase: :linked,
          link_timer: nil,
          payload_type: packet.payload_type,
          pad: pad_waiting_for_stream,
          timestamp_base: packet.timestamp,
          previous_timestamp: packet.timestamp,
          initialization_time: Membrane.Time.monotonic_time(),
          jitter_buffer_latency: pad_options.jitter_buffer_latency,
          use_jitter_buffer: pad_options.use_jitter_buffer,
          clock_rate: clock_rate
        }

        Process.send_after(
          self(),
          {:initial_latency_passed, packet.ssrc},
          pad_options.jitter_buffer_latency
        )

        state = put_in(state.stream_states[packet.ssrc], stream_state)
        {_stream_id, state} = pop_in(state.pads_waiting_for_stream[pad_waiting_for_stream])

        {[stream_format: {pad_waiting_for_stream, %RTP{}}], state}
    end
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

  @spec send_buffers(RTP.ssrc(), State.StreamState.t()) ::
          {[Membrane.Element.Action.t()], State.StreamState.t()}
  defp send_buffers(ssrc, stream_state) do
    # Flushes buffers that stayed in queue longer than latency and any gaps before them
    {too_old_records, buffer_store} =
      BufferStore.flush_older_than(stream_state.buffer_store, stream_state.jitter_buffer_latency)

    # Additionally, flush buffers as long as there are no gaps
    {buffers, buffer_store} = BufferStore.flush_ordered(buffer_store)

    {actions, stream_state} =
      (too_old_records ++ buffers) |> Enum.flat_map_reduce(stream_state, &record_to_actions/2)

    stream_state = set_timer(ssrc, %{stream_state | buffer_store: buffer_store})

    {actions, stream_state}
  end

  @spec set_timer(RTP.ssrc(), State.StreamState.t()) :: State.StreamState.t()
  defp set_timer(
         ssrc,
         %State.StreamState{max_latency_timer: nil, jitter_buffer_latency: latency} =
           stream_state
       ) do
    new_timer =
      case BufferStore.first_record_timestamp(stream_state.buffer_store) do
        nil ->
          nil

        buffer_ts ->
          since_insertion = Time.monotonic_time() - buffer_ts
          send_after_time = max(0, latency - since_insertion) |> Time.as_milliseconds(:round)
          Process.send_after(self(), {:send_buffers, ssrc}, send_after_time)
      end

    %State.StreamState{stream_state | max_latency_timer: new_timer}
  end

  defp set_timer(_ssrc, %State.StreamState{max_latency_timer: timer} = stream_state)
       when timer != nil do
    stream_state
  end

  defp record_to_actions(nil, stream_state) do
    action = [event: {:output, %Membrane.Event.Discontinuity{}}]
    {action, stream_state}
  end

  defp record_to_actions(%Record{buffer: buffer}, stream_state) do
    rtp_timestamp = buffer.metadata.rtp.timestamp

    # timestamps in RTP don't have to be monotonic therefore there can be
    # a situation where in 2 consecutive packets the latter packet will have smaller timestamp
    # than the previous one while not overflowing the timestamp number
    # https://datatracker.ietf.org/doc/html/rfc3550#section-5.1

    timestamp_base =
      case RTP.Utils.from_which_rollover(
             stream_state.previous_timestamp,
             rtp_timestamp,
             @max_timestamp
           ) do
        :next -> stream_state.timestamp_base - @max_timestamp
        :previous -> stream_state.timestamp_base + @max_timestamp
        :current -> stream_state.timestamp_base
      end

    timestamp = div(Time.seconds(rtp_timestamp - timestamp_base), stream_state.clock_rate)
    buffer = %Membrane.Buffer{buffer | pts: timestamp}
    # An empty buffer is usually a WebRTC probing packet that should be skipped.
    actions = if buffer.payload == <<>>, do: [], else: [buffer: {stream_state.pad, buffer}]
    state = %{stream_state | timestamp_base: timestamp_base, previous_timestamp: rtp_timestamp}
    {actions, state}
  end
end
