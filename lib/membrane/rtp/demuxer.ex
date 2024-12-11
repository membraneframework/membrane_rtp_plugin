defmodule Membrane.RTP.Demuxer do
  @moduledoc """
  Element capable of receiving a raw RTP stream and demuxing it into individual parsed streams based on packet ssrcs. 
  Whenever a new stream is recognized, a `t:new_rtp_stream_notification/0` is sent to the element's parent. In turn it should link a 
  `Membrane.Pad.ref({:output, ssrc})` output pad of this element to receive the stream specified in the notification.
  """

  use Membrane.Filter
  require Membrane.Pad

  require Membrane.Logger
  alias Membrane.{Buffer, Pad, RemoteStream, RTCP, RTP}

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
      ]
    ]

  def_options not_linked_pad_handling: [
                spec: %{action: :raise | :ignore, timeout: Membrane.Time.t()},
                default: %{action: :ignore, timeout: Membrane.Time.seconds(2)},
                description: """
                This option determines the action to be taken after a stream has been announced with a 
                `t:new_rtp_stream_notification/0` notification but the corresponding pad has not been connected within the specified timeout period.
                """
              ]

  defmodule State do
    @moduledoc false

    defmodule StreamState do
      @moduledoc false

      @type t :: %__MODULE__{
              queued_buffers: [ExRTP.Packet.t()],
              end_of_stream_buffered: boolean(),
              phase: :waiting_for_link | :linked | :timed_out,
              payload_type: RTP.payload_type(),
              link_timer: reference() | nil,
              pad: Pad.ref() | nil
            }

      @enforce_keys [:payload_type, :phase, :link_timer, :pad]

      defstruct @enforce_keys ++ [queued_buffers: [], end_of_stream_buffered: false]
    end

    @type t :: %__MODULE__{
            not_linked_pad_handling: %{action: :raise | :ignore, timeout: Membrane.Time.t()},
            stream_states: %{RTP.ssrc() => StreamState.t()},
            pads_waiting_for_stream: %{Pad.ref() => Membrane.RTP.Demuxer.stream_id()}
          }

    @enforce_keys [:not_linked_pad_handling]
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
  def handle_buffer(:input, %Membrane.Buffer{payload: payload}, _ctx, state) do
    case classify_packet(payload) do
      :rtp -> handle_rtp_packet(payload, state)
      :rtcp -> handle_rtcp_packets(payload, state)
    end
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, _ref) = pad, ctx, state) do
    matching_stream_ssrc =
      find_matching_stream_for_pad(ctx.pad_options.stream_id, state.stream_states)

    stream_state = state.stream_states[matching_stream_ssrc]

    case stream_state do
      nil ->
        state = %{
          state
          | pads_waiting_for_stream:
              Map.put(state.pads_waiting_for_stream, pad, ctx.pad_options.stream_id)
        }

        {[], state}

      %{phase: :waiting_for_link} ->
        Process.cancel_timer(state.stream_states[matching_stream_ssrc].link_timer)

        buffer_action = [buffer: {pad, Enum.reverse(stream_state.queued_buffers)}]

        end_of_stream_action =
          if stream_state.end_of_stream_buffered, do: [end_of_stream: pad], else: []

        state =
          Bunch.Struct.put_in(
            state,
            [:stream_states, matching_stream_ssrc],
            %{stream_state | phase: :linked, queued_buffers: [], pad: pad}
          )

        {[stream_format: {pad, %RTP{}}] ++ buffer_action ++ end_of_stream_action, state}

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

      :ignore ->
        Membrane.Logger.warning(
          "Pad corresponding to ssrc #{ssrc} not connected within specified timeout"
        )

        state =
          state
          |> Bunch.Struct.put_in([:stream_states, ssrc, :phase], :timed_out)
          |> Bunch.Struct.put_in([:stream_states, ssrc, :queued_buffers], [])

        {[], state}
    end
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    state =
      state.stream_states
      |> Enum.reduce(state, fn {ssrc, _stream_state}, state ->
        Bunch.Struct.put_in(state, [:stream_states, ssrc, :end_of_stream_buffered], true)
      end)

    {[forward: :end_of_stream], state}
  end

  @spec classify_packet(binary()) :: :rtp | :rtcp
  defp classify_packet(<<_first_byte, _marker::1, payload_type::7, _rest::binary>>) do
    if payload_type in 64..95,
      do: :rtcp,
      else: :rtp
  end

  @spec handle_rtp_packet(binary(), State.t()) ::
          {[Membrane.Element.Action.t()], State.t()}
  defp handle_rtp_packet(raw_rtp_packet, state) do
    {:ok, packet} = ExRTP.Packet.decode(raw_rtp_packet)

    {new_stream_actions, state} =
      if Map.has_key?(state.stream_states, packet.ssrc) do
        {[], state}
      else
        initialize_new_stream_state(packet, state)
      end

    buffer = put_packet_into_buffer(packet)

    {buffer_actions, state} =
      case state.stream_states[packet.ssrc].phase do
        :waiting_for_link ->
          {[], append_buffer_to_queued_buffers(packet.ssrc, buffer, state)}

        :linked ->
          buffer_action =
            {:buffer, {state.stream_states[packet.ssrc].pad, buffer}}

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
    case find_matching_pad_for_stream(packet, state.pads_waiting_for_stream) do
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
          pad: nil
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

      pad_waiting_for_stream ->
        stream_state = %State.StreamState{
          phase: :linked,
          link_timer: nil,
          payload_type: packet.payload_type,
          pad: pad_waiting_for_stream
        }

        state = Bunch.Struct.put_in(state, [:stream_states, packet.ssrc], stream_state)
        {[stream_format: {pad_waiting_for_stream, %RTP{}}], state}
    end
  end

  # @spec find_matching_pad(ExRTP.Packet.t(), MapSet.t({stream_id(), Pad.ref()})) :: Pad.ref() | nil
  # defp find_matching_pad(packet, pads_waiting_for_stream) do
  ## Enum.find_value(pads_waiting_for_stream, fn {stream_id, pad_ref} -> pad_data end)
  # end

  # @spec resolve_ssrc(
  # {:ssrc, RTP.ssrc()}
  # | {:encoding_name, RTP.encoding_name()}
  # | {:payload_type, RTP.payload_type()},
  # State.t()
  # ) :: RTP.ssrc() | nil
  # defp resolve_ssrc(stream_id, state) do
  # case stream_id do
  # {:ssrc, ssrc} ->
  # ssrc

  # {:encoding_name, encoding_name} ->
  # %{payload_type: payload_type} = RTP.PayloadFormat.resolve(encoding_name: encoding_name)
  # if payload_type == nil, do: raise("encoding name not recognized")
  # resolve_ssrc({:payload_type, payload_type}, state)

  # {:payload_type, payload_type} ->
  # Enum.find_value(state.stream_states, fn {ssrc, stream_state} ->
  # if stream_state.payload_type == payload_type, do: ssrc, else: false
  # end)
  # end
  # end

  @spec find_matching_pad_for_stream(ExRTP.Packet.t(), %{Pad.ref() => stream_id()}) ::
          Pad.ref() | nil
  defp find_matching_pad_for_stream(packet, pads_waiting_for_stream) do
    Enum.find(pads_waiting_for_stream, fn {_pad_ref, stream_id} ->
      pad_stream_match?(stream_id, packet.ssrc, packet.payload_type)
      # case stream_id do
      # {:ssrc, ssrc} ->
      # packet.ssrc == ssrc

      # {:payload_type, payload_type} ->
      # packet.payload_type == payload_type

      # {:encoding_name, encoding_name} ->
      # %{payload_type: payload_type} = RTP.PayloadFormat.resolve(encoding_name: encoding_name)
      # if payload_type == nil, do: raise("encoding name not recognized")
      # packet.payload_type == payload_type
      # end
    end)
    |> case do
      nil -> nil
      {pad_ref, _stream_id} -> pad_ref
    end
  end

  # 1. pad connected: check if a corresponding stream waiting for a pad exists. 
  # If not, add to waiting pads. 
  # If yes, add the pad to the stream state
  #
  # 2. new stream received: check if a corresponding pad waiting for a stream exists.
  # If not, set the phase to :waiting_for_link
  # If yes, remove the pad from waiting pads and add it to the stream state

  @spec find_matching_stream_for_pad(stream_id(), %{RTP.ssrc() => State.StreamState.t()}) ::
          RTP.ssrc() | nil
  defp find_matching_stream_for_pad(stream_id, stream_states) do
    Enum.find(stream_states, fn {ssrc, stream_state} ->
      pad_stream_match?(stream_id, ssrc, stream_state.payload_type)
    end)
    |> case do
      nil -> nil
      {ssrc, _stream_state} -> ssrc
    end
  end

  defp pad_stream_match?(pad_stream_id, stream_ssrc, stream_payload_type) do
    case pad_stream_id do
      {:ssrc, pad_ssrc} ->
        stream_ssrc == pad_ssrc

      {:payload_type, pad_payload_type} ->
        stream_payload_type == pad_payload_type

      {:encoding_name, pad_encoding_name} ->
        %{payload_type: pad_payload_type} =
          RTP.PayloadFormat.resolve(encoding_name: pad_encoding_name)

        if pad_payload_type == nil,
          do: raise("encoding name provided in pad options not recognized")

        stream_payload_type == pad_payload_type
    end
  end

  @spec append_buffer_to_queued_buffers(
          RTP.ssrc(),
          Buffer.t(),
          State.t()
        ) :: State.t()
  defp append_buffer_to_queued_buffers(ssrc, buffer, state) do
    Bunch.Struct.update_in(state, [:stream_states, ssrc, :queued_buffers], &[buffer | &1])
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
